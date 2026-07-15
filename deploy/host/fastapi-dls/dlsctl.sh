#!/usr/bin/env bash
# Portable fastapi-dls Docker Compose deployment helper.

set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"
STATE_DIR="$SCRIPT_DIR/state"
CERT_DIR="$STATE_DIR/cert"
DATABASE_DIR="$STATE_DIR/database"
OUT_DIR="$SCRIPT_DIR/out"

log() {
    printf '[fastapi-dls] %s\n' "$*"
}

die() {
    printf '[fastapi-dls] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./dlsctl.sh deploy <address> [public-port [host-port]]
  ./dlsctl.sh deploy
  ./dlsctl.sh configure <address> [public-port [host-port]]
  ./dlsctl.sh set-address <address> [public-port [host-port]]
  ./dlsctl.sh up | down | restart | status | logs
  ./dlsctl.sh token [output-file]

Examples:
  ./dlsctl.sh deploy 192.168.30.127
  ./dlsctl.sh deploy dls.example.com 443 443
  ./dlsctl.sh set-address dls-new.example.com

address 必须是 IPv4 或 DNS 名，不要包含 https://、路径或端口。
首次 deploy 会创建私有 .env、TLS 证书、数据库并导出客户端 token。
EOF
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

validate_port() {
    local port=${1:-}
    [[ "$port" =~ ^[0-9]+$ ]] || die "非法端口: $port"
    (( port >= 1 && port <= 65535 )) || die "端口超出范围: $port"
}

is_ipv4() {
    local address=$1 part
    local -a parts
    [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a parts <<<"$address"
    for part in "${parts[@]}"; do
        (( ${#part} <= 3 )) || return 1
        (( 10#$part >= 0 && 10#$part <= 255 )) || return 1
    done
}

validate_address() {
    local address=${1:-} label
    [[ -n "$address" ]] || die 'DLS 地址不能为空'
    if is_ipv4 "$address"; then
        return 0
    fi
    [[ ! "$address" =~ ^[0-9.]+$ ]] || die "非法 IPv4: $address"
    [[ ${#address} -le 253 ]] || die "DNS 名过长: $address"
    [[ "$address" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || \
        die "非法地址（仅接受 IPv4 或 DNS 名）: $address"
    [[ "$address" != *".."* && "$address" != *".-"* && "$address" != *"-."* ]] || \
        die "非法 DNS 名: $address"
    while IFS= read -r label; do
        [[ -n "$label" && ${#label} -le 63 ]] || die "非法 DNS 标签: $label"
    done < <(tr '.' '\n' <<<"$address")
}

env_get() {
    local key=$1 value
    [[ -f "$ENV_FILE" ]] || return 1
    value=$(awk -v key="$key" '
        index($0, key "=") == 1 { value=substr($0, length(key) + 2) }
        END { if (value != "") print value }
    ' "$ENV_FILE")
    value=${value%$'\r'}
    value=${value#\"}
    value=${value%\"}
    [[ -n "$value" ]] || return 1
    printf '%s\n' "$value"
}

env_set() {
    local key=$1 value=$2 tmp
    tmp=$(mktemp "${ENV_FILE}.XXXXXX")
    awk -v key="$key" -v value="$value" '
        BEGIN { found=0 }
        index($0, key "=") == 1 { print key "=" value; found=1; next }
        { print }
        END { if (!found) print key "=" value }
    ' "$ENV_FILE" >"$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$ENV_FILE"
}

ensure_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        install -m 0600 "$ENV_EXAMPLE" "$ENV_FILE"
        log "已创建 $ENV_FILE"
    fi
    chmod 0600 "$ENV_FILE"
}

validate_env() {
    local address public_port host_port lease_days listen_address
    address=$(env_get DLS_URL) || die "请在 $ENV_FILE 设置 DLS_URL"
    public_port=$(env_get DLS_PORT) || public_port=443
    host_port=$(env_get HOST_PORT) || host_port=443
    lease_days=$(env_get LEASE_EXPIRE_DAYS) || lease_days=90
    listen_address=$(env_get LISTEN_ADDRESS) || listen_address=0.0.0.0

    validate_address "$address"
    validate_port "$public_port"
    validate_port "$host_port"
    [[ "$lease_days" =~ ^[0-9]+$ ]] || die "非法 LEASE_EXPIRE_DAYS: $lease_days"
    (( lease_days >= 1 && lease_days <= 90 )) || die 'LEASE_EXPIRE_DAYS 必须为 1..90'
    if [[ "$listen_address" != "0.0.0.0" && "$listen_address" != "127.0.0.1" ]]; then
        is_ipv4 "$listen_address" || die "LISTEN_ADDRESS 必须是本机 IPv4: $listen_address"
    fi
}

certificate_matches() {
    local address=$1 cert="$CERT_DIR/webserver.crt"
    [[ -s "$cert" ]] || return 1
    if is_ipv4 "$address"; then
        openssl x509 -in "$cert" -noout -checkip "$address" 2>/dev/null | \
            grep -Fq 'does match certificate'
    else
        openssl x509 -in "$cert" -noout -checkhost "$address" 2>/dev/null | \
            grep -Fq 'does match certificate'
    fi
}

generate_web_certificate() {
    local address=$1 san tmp
    need_command openssl
    if is_ipv4 "$address"; then
        san="IP:$address"
    else
        san="DNS:$address"
    fi

    mkdir -p "$CERT_DIR"
    chmod 0700 "$STATE_DIR" "$CERT_DIR"
    tmp=$(mktemp -d "$CERT_DIR/.webcert.XXXXXX")
    trap 'rm -rf -- "$tmp"' RETURN
    openssl req -x509 -nodes -days 3650 -newkey rsa:3072 \
        -keyout "$tmp/webserver.key" \
        -out "$tmp/webserver.crt" \
        -subj "/CN=$address" \
        -addext "subjectAltName=$san" \
        -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
        -addext 'extendedKeyUsage=serverAuth' \
        >/dev/null 2>&1
    install -m 0600 "$tmp/webserver.key" "$CERT_DIR/webserver.key"
    install -m 0644 "$tmp/webserver.crt" "$CERT_DIR/webserver.crt"
    rm -rf -- "$tmp"
    trap - RETURN
    log "已为 $address 生成 Web TLS 证书；内部 DLS 签名密钥未改动"
}

ensure_state() {
    local address
    address=$(env_get DLS_URL)
    mkdir -p "$CERT_DIR" "$DATABASE_DIR" "$OUT_DIR"
    chmod 0700 "$STATE_DIR" "$CERT_DIR" "$DATABASE_DIR" "$OUT_DIR"
    if ! certificate_matches "$address"; then
        generate_web_certificate "$address"
    fi
}

select_docker() {
    need_command docker
    if docker info >/dev/null 2>&1; then
        DOCKER=(docker)
    elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
        DOCKER=(sudo docker)
    else
        die "当前用户不能访问 Docker；请先加入 docker 组，或用 sudo 执行本脚本"
    fi
    "${DOCKER[@]}" compose version >/dev/null 2>&1 || die '缺少 Docker Compose v2'
}

compose() {
    "${DOCKER[@]}" compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

local_endpoint() {
    local listen_address host_port
    listen_address=$(env_get LISTEN_ADDRESS) || listen_address=0.0.0.0
    host_port=$(env_get HOST_PORT) || host_port=443
    if [[ "$listen_address" == "0.0.0.0" ]]; then
        listen_address=127.0.0.1
    fi
    printf 'https://%s:%s\n' "$listen_address" "$host_port"
}

public_endpoint() {
    local address port
    address=$(env_get DLS_URL)
    port=$(env_get DLS_PORT) || port=443
    if [[ "$port" == 443 ]]; then
        printf 'https://%s\n' "$address"
    else
        printf 'https://%s:%s\n' "$address" "$port"
    fi
}

wait_healthy() {
    local endpoint attempt
    endpoint=$(local_endpoint)
    need_command curl
    for attempt in $(seq 1 60); do
        if curl --insecure --fail --silent --show-error \
            "$endpoint/-/health" >/dev/null 2>&1; then
            log "健康检查通过: $endpoint/-/health"
            return 0
        fi
        sleep 1
    done
    compose ps >&2 || true
    compose logs --tail=80 fastapi-dls >&2 || true
    die '服务在 60 秒内未通过健康检查'
}

secure_runtime_files() {
    # 内部 CA/签名密钥由容器首次启动时创建；在容器内收紧权限也会作用于 bind mount。
    compose exec -T fastapi-dls sh -c '
        for file in /app/cert/*.key /app/cert/*private_key*.pem; do
            [ ! -f "$file" ] || chmod 0600 "$file"
        done
    '
}

verify_runtime_config() {
    local endpoint address port config
    endpoint=$(local_endpoint)
    address=$(env_get DLS_URL)
    port=$(env_get DLS_PORT) || port=443
    config=$(curl --insecure --fail --silent --show-error "$endpoint/-/config") || \
        die '无法读取正在运行的 DLS 配置'
    grep -Fq "\"DLS_URL\": \"$address\"" <<<"$config" && \
        grep -Fq "\"DLS_PORT\": \"$port\"" <<<"$config" || \
        die '运行中容器的地址与 .env 不一致；请先执行 ./dlsctl.sh deploy'
}

export_token() {
    local output=${1:-"$OUT_DIR/client_configuration_token.tok"}
    local endpoint tmp bytes
    need_command curl
    verify_runtime_config
    endpoint=$(local_endpoint)
    mkdir -p "$(dirname -- "$output")"
    tmp=$(mktemp "${output}.XXXXXX")
    if ! curl --insecure --fail --silent --show-error \
        "$endpoint/-/client-token" -o "$tmp"; then
        rm -f -- "$tmp"
        die '客户端 token 下载失败'
    fi
    bytes=$(wc -c <"$tmp")
    if (( bytes < 1000 )); then
        rm -f -- "$tmp"
        die "客户端 token 大小异常: $bytes bytes"
    fi
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$output"
    log "客户端 token: $output ($bytes bytes, mode 0600)"
}

configure() {
    local address=${1:-} public_port=${2:-} host_port=${3:-}
    ensure_env
    if [[ -n "$address" ]]; then
        validate_address "$address"
        public_port=${public_port:-443}
        host_port=${host_port:-$public_port}
        validate_port "$public_port"
        validate_port "$host_port"
        env_set DLS_URL "$address"
        env_set DLS_PORT "$public_port"
        env_set HOST_PORT "$host_port"
    elif ! env_get DLS_URL >/dev/null; then
        die '首次配置必须提供 address'
    fi
    validate_env
    ensure_state
    log "配置完成: $(public_endpoint)"
}

require_configured() {
    [[ -f "$ENV_FILE" ]] || die "尚未配置；先运行: ./dlsctl.sh deploy <address>"
    chmod 0600 "$ENV_FILE"
    validate_env
    ensure_state
}

cmd=${1:-help}
shift || true

case "$cmd" in
    deploy)
        (( $# <= 3 )) || die 'deploy 最多接受 address、public-port、host-port 三个参数'
        configure "${1:-}" "${2:-}" "${3:-}"
        select_docker
        compose config --quiet
        compose pull
        compose up -d --remove-orphans
        wait_healthy
        secure_runtime_files
        export_token
        log "部署完成: $(public_endpoint)"
        ;;
    configure)
        [[ $# -ge 1 && $# -le 3 ]] || die 'configure 需要 address，最多再接受两个端口'
        configure "$@"
        ;;
    set-address)
        [[ $# -ge 1 && $# -le 3 ]] || die 'set-address 需要新 address，最多再接受两个端口'
        configure "$@"
        select_docker
        compose config --quiet
        compose up -d --force-recreate
        wait_healthy
        secure_runtime_files
        export_token
        log '地址已更新；必须把新 token 重新安装到每台 guest'
        ;;
    up)
        require_configured
        select_docker
        compose config --quiet
        compose up -d --remove-orphans
        wait_healthy
        secure_runtime_files
        ;;
    down)
        [[ -f "$ENV_FILE" ]] || die '尚未配置'
        select_docker
        compose down
        ;;
    restart)
        require_configured
        select_docker
        compose restart fastapi-dls
        wait_healthy
        secure_runtime_files
        ;;
    status)
        require_configured
        select_docker
        compose ps
        printf 'public endpoint: %s\n' "$(public_endpoint)"
        curl --insecure --fail --silent --show-error \
            "$(local_endpoint)/-/config" || true
        printf '\n'
        ;;
    logs)
        [[ -f "$ENV_FILE" ]] || die '尚未配置'
        select_docker
        compose logs -f --tail=200 fastapi-dls
        ;;
    token)
        require_configured
        export_token "${1:-}"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        die "未知命令: $cmd"
        ;;
esac

#!/usr/bin/env bash
# Create a Cloudflare-protected 80/443 alias vhost for the existing VMate gateway.

set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEMPLATE="$SCRIPT_DIR/vmate-domain-alias.conf.template"
NGINX_CONF_DIR=${NGINX_CONF_DIR:-/etc/nginx/conf.d}

log() {
    printf '[vmate nginx] %s\n' "$*"
}

die() {
    printf '[vmate nginx] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  sudo ./nginx/install-vmate-domain-alias.sh install <domain> <upstream-port> <frontend-cert> <frontend-key>
  sudo ./nginx/install-vmate-domain-alias.sh status [upstream-port]

Example:
  sudo ./nginx/install-vmate-domain-alias.sh install gvmates.com 3001 \
    /etc/nginx/ssl/gvmates.com/gvmates.com.origin.pem \
    /etc/nginx/ssl/gvmates.com/gvmates.com.origin.key

install creates a distinct Cloudflare-protected 80/443 Nginx vhost that proxies
to the existing VMate gateway on 127.0.0.1:<upstream-port>. It never edits the
existing vmate.dgamef.com configuration and refuses to overwrite an existing
same-domain Nginx configuration.
EOF
}

need_root() {
    [[ $(id -u) -eq 0 ]] || die '请使用 root 或 sudo 运行'
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

validate_domain() {
    local domain=${1:-} label
    [[ -n "$domain" && ${#domain} -le 253 ]] || die '域名不能为空或过长'
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || \
        die "非法域名: $domain"
    [[ "$domain" == *.* && "$domain" != *".."* && "$domain" != *".-"* && "$domain" != *"-."* ]] || \
        die "非法域名: $domain"
    while IFS= read -r label; do
        [[ -n "$label" && ${#label} -le 63 ]] || die "非法 DNS 标签: $label"
    done < <(tr '.' '\n' <<<"$domain")
}

validate_port() {
    local port=${1:-}
    [[ "$port" =~ ^[0-9]+$ ]] || die "非法端口: $port"
    (( port >= 1 && port <= 65535 )) || die "端口超出范围: $port"
}

validate_path() {
    local path=$1 label=$2
    [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *'|'* ]] || \
        die "$label 必须是不包含换行或 | 的绝对路径: $path"
}

require_cloudflare_guard() {
    if ! nginx -T 2>&1 | grep -F 'origin_from_cloudflare' >/dev/null; then
        die '未检测到 $origin_from_cloudflare；先安装并启用 Cloudflare real-IP/源站保护配置'
    fi
}

certificate_covers_domain() {
    local certificate=$1 domain=$2
    openssl x509 -in "$certificate" -noout -checkhost "$domain" 2>/dev/null | \
        grep -Fq 'does match certificate'
}

vhost_identifier() {
    local domain=$1 identifier
    identifier=$(tr '[:upper:]' '[:lower:]' <<<"$domain" | tr '.-' '__')
    printf 'vmate_%s' "$identifier"
}

render() {
    local domain=$1 upstream_port=$2 frontend_cert=$3 frontend_key=$4 vhost_id
    vhost_id=$(vhost_identifier "$domain")
    sed \
        -e "s|__VMATE_DOMAIN__|$domain|g" \
        -e "s|__UPSTREAM_PORT__|$upstream_port|g" \
        -e "s|__FRONTEND_CERT__|$frontend_cert|g" \
        -e "s|__FRONTEND_KEY__|$frontend_key|g" \
        -e "s|__VHOST_ID__|$vhost_id|g" \
        "$TEMPLATE"
}

install_proxy() {
    local domain=$1 upstream_port=$2 frontend_cert=$3 frontend_key=$4
    local destination tmp failed_config key_mode

    validate_domain "$domain"
    validate_port "$upstream_port"
    validate_path "$frontend_cert" '前端证书路径'
    validate_path "$frontend_key" '前端私钥路径'
    need_root
    need_command nginx
    need_command install
    need_command openssl
    need_command stat
    need_command systemctl
    [[ -r "$TEMPLATE" ]] || die "缺少模板: $TEMPLATE"
    [[ -s "$frontend_cert" && -r "$frontend_cert" ]] || die "找不到前端证书: $frontend_cert"
    [[ -s "$frontend_key" && -r "$frontend_key" ]] || die "找不到前端私钥: $frontend_key"
    key_mode=$(stat -Lc '%a' "$frontend_key")
    (( (8#$key_mode & 8#077) == 0 )) || die "前端私钥权限必须禁止 group/other 访问: $frontend_key ($key_mode)"
    certificate_covers_domain "$frontend_cert" "$domain" || \
        die "前端证书 SAN 未覆盖 $domain: $frontend_cert"
    require_cloudflare_guard

    mkdir -p "$NGINX_CONF_DIR"
    destination="$NGINX_CONF_DIR/${domain}.conf"
    [[ ! -e "$destination" ]] || \
        die "为避免覆盖现有站点，拒绝写入: $destination"

    tmp=$(mktemp "${destination}.XXXXXX")
    trap 'rm -f -- "$tmp"' RETURN
    render "$domain" "$upstream_port" "$frontend_cert" "$frontend_key" >"$tmp"
    chmod 0644 "$tmp"
    install -m 0644 "$tmp" "$destination"
    rm -f -- "$tmp"
    trap - RETURN

    if ! nginx -t; then
        failed_config="${destination}.failed.$(date -u +%Y%m%dT%H%M%SZ)"
        mv -- "$destination" "$failed_config"
        die "Nginx 语法检查失败；未加载配置，保留失败文件: $failed_config"
    fi
    systemctl reload nginx
    log "VMate 域名别名已启用: https://$domain:443 -> http://127.0.0.1:$upstream_port"
}

status_proxy() {
    local upstream_port=${1:-3001}
    validate_port "$upstream_port"
    need_command nginx
    need_command curl
    nginx -t
    curl --silent --show-error --output /dev/null --connect-timeout 3 --max-time 10 \
        "http://127.0.0.1:${upstream_port}/"
    log "本机 VMate 网关可达: http://127.0.0.1:${upstream_port}/"
}

command=${1:-help}
shift || true

case "$command" in
    install)
        [[ $# -eq 4 ]] || die 'install 需要 domain、upstream-port、frontend-cert 和 frontend-key'
        install_proxy "$1" "$2" "$3" "$4"
        ;;
    status)
        [[ $# -le 1 ]] || die 'status 最多接受 upstream-port'
        status_proxy "${1:-3001}"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        die "未知命令: $command"
        ;;
esac

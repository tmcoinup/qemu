#!/usr/bin/env bash
# setup-fastapi-dls.sh — 本地 vGPU license 服务器 (fastapi-dls / Docker)
#
# 部署目录:       /opt/fastapi-dls
# 监听端口:       443 (HTTPS, 自签证书)
# Guest 导入 token 的方法见 deploy/guest/README 里「vGPU License 导入」一节

set -euo pipefail

WORKDIR=${WORKDIR:-/opt/fastapi-dls}
PORT=${PORT:-443}

sudo_run() {
    if sudo -n true 2>/dev/null; then
        sudo "$@"
    elif [[ -n "${SUDO_PASSWORD:-}" ]]; then
        echo "$SUDO_PASSWORD" | sudo -S "$@"
    else
        echo "需要 sudo 权限: 先 'sudo -v' 或设 SUDO_PASSWORD=xxx" >&2
        return 1
    fi
}

# 拿 br0 的 IPv4 (若不存在，回落到默认路由出口)
HOST_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
if [[ -z "$HOST_IP" ]]; then
    HOST_IP=$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src")print $(i+1)}')
fi
[[ -n "$HOST_IP" ]] || { echo "无法探测宿主 IP" >&2; exit 1; }
echo "使用宿主 IP: $HOST_IP"

echo "[1/4] 安装 docker (如缺)"
if ! command -v docker >/dev/null; then
    sudo_run apt-get update -qq
    sudo_run apt-get install -yqq docker.io docker-compose-v2
    sudo_run systemctl enable --now docker
fi

echo "[2/4] 生成自签名证书 (CN=$HOST_IP)"
sudo_run install -d -m 0755 "$WORKDIR/cert" "$WORKDIR/data"
if [[ ! -f "$WORKDIR/cert/webserver.crt" ]]; then
    sudo_run openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$WORKDIR/cert/webserver.key" \
        -out   "$WORKDIR/cert/webserver.crt" \
        -subj  "/CN=$HOST_IP" \
        -addext "subjectAltName=IP:$HOST_IP"
fi

echo "[3/4] 写 docker-compose.yml"
TMP=$(mktemp)
cat > "$TMP" <<EOF
services:
  fastapi-dls:
    image: collinwebdesigns/fastapi-dls:latest
    restart: always
    environment:
      - TZ=Asia/Shanghai
      - DLS_URL=$HOST_IP
      - DLS_PORT=$PORT
      - LEASE_EXPIRE_DAYS=90
      - DATABASE=sqlite:////app/database/db.sqlite
    ports:
      - "$PORT:443"
    volumes:
      - ./cert:/app/cert:ro
      - ./data:/app/database
EOF
sudo_run install -m 0644 "$TMP" "$WORKDIR/docker-compose.yml"
rm -f "$TMP"

echo "[4/4] 启动服务"
( cd "$WORKDIR" && sudo_run docker compose up -d )

echo
echo "✅ fastapi-dls 已就绪。"
echo "下一步: 从宿主生成 client-token，传入 Windows VM:"
echo "   curl -k -o /tmp/client_configuration_token.tok https://$HOST_IP/-/client-token"
echo "   scp /tmp/client_configuration_token.tok Administrator@<vm-ip>:/c:/"
echo "Windows 内 (管理员 PowerShell):"
echo "   Copy-Item C:\\client_configuration_token.tok 'C:\\Program Files\\NVIDIA Corporation\\vGPU Licensing\\ClientConfigToken\\' -Force"
echo "   Restart-Service NVDisplay.ContainerLocalSystem"
echo "   nvidia-smi -q | Select-String -Pattern 'License'"

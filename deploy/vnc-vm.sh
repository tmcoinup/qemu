#!/usr/bin/env bash
# vnc-vm.sh — 用 Remmina 连 vmN 的 VNC
#
# 用法:
#   ./vnc-vm.sh <vm_id>              # 端口按 :vm_id (VNC :1 = 5901)
#   ./vnc-vm.sh <vm_id> <host>       # 用指定 host
#
# VNC display 在 start-vm.sh 里用 --vnc :N 指定，默认 :vm_id。
# 等价命令:
#   remmina -c vnc://<host>:<port>

set -euo pipefail

VM_ID="${1:-}"
HOST="${2:-}"

if [[ -z "$VM_ID" || ! "$VM_ID" =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: $0 <vm_id> [host]" >&2
    exit 2
fi

: "${VNC_HOST:=}"
if [[ -z "$HOST" ]]; then
    if [[ -n "$VNC_HOST" ]]; then
        HOST="$VNC_HOST"
    else
        # 默认用 br0 的 IP
        HOST=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        [[ -n "$HOST" ]] || HOST=localhost
    fi
fi

PORT=$((5900 + VM_ID))

if ! ss -ltn 2>/dev/null | grep -q ":${PORT}\b"; then
    echo "⚠️  宿主 ${HOST}:${PORT} 上没监听，先 ./start-vm.sh ${VM_ID} ..." >&2
fi

echo "连接 VNC ${HOST}:${PORT}"
if command -v remmina >/dev/null; then
    exec remmina -c "vnc://${HOST}:${PORT}"
elif command -v xtigervncviewer >/dev/null; then
    exec xtigervncviewer "${HOST}:${PORT}"
elif command -v vncviewer >/dev/null; then
    exec vncviewer "${HOST}:${PORT}"
else
    echo "没装 remmina / TigerVNC viewer。试: sudo apt install -y remmina tigervnc-viewer" >&2
    exit 1
fi

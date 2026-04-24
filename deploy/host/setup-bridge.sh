#!/usr/bin/env bash
# setup-bridge.sh — 配置宿主 qemu-bridge-helper
#
# 不改 netplan（避免断网）；只做:
#   1. 确认 bridge-utils / iproute2 已装
#   2. 给 qemu-bridge-helper setuid root
#   3. 写 /etc/qemu/bridge.conf 允许 br0

set -euo pipefail

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

echo "[1/3] 安装 bridge-utils / iproute2 (若缺)"
if ! command -v brctl >/dev/null || ! command -v ip >/dev/null; then
    sudo_run apt-get update -qq
    sudo_run apt-get install -yqq bridge-utils iproute2
fi

HELPER=""
for c in /usr/lib/qemu/qemu-bridge-helper /usr/libexec/qemu-bridge-helper; do
    [[ -x "$c" ]] && HELPER=$c && break
done
if [[ -z "$HELPER" ]]; then
    HELPER="$(realpath "$(dirname "$0")/../../build/qemu-bridge-helper")"
fi
[[ -x "$HELPER" ]] || { echo "qemu-bridge-helper 不存在: $HELPER" >&2; exit 1; }

echo "[2/3] 给 $HELPER 置 setuid"
sudo_run chown root:root "$HELPER"
sudo_run chmod u+s "$HELPER"

echo "[3/3] /etc/qemu/bridge.conf allow br0"
sudo_run install -d -m 0755 /etc/qemu
if ! sudo_run grep -q '^allow br0$' /etc/qemu/bridge.conf 2>/dev/null; then
    TMP=$(mktemp)
    {
        sudo_run cat /etc/qemu/bridge.conf 2>/dev/null || true
        echo 'allow br0'
    } > "$TMP"
    sudo_run install -m 0644 "$TMP" /etc/qemu/bridge.conf
    rm -f "$TMP"
fi

echo
echo "✅ qemu-bridge-helper 就绪: $HELPER"
echo "   /etc/qemu/bridge.conf → $(sudo_run cat /etc/qemu/bridge.conf 2>/dev/null)"
echo
if ip -o link show br0 >/dev/null 2>&1; then
    echo "   (br0 已经存在，无需再改 netplan)"
else
    echo "   (br0 不存在，需要写 /etc/netplan/99-qemu-br0.yaml)"
fi

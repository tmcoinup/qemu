#!/usr/bin/env bash
# rdp-vm.sh — 用 xfreerdp3 连 vmN
#
# 用法:
#   ./rdp-vm.sh <vm_id>                        # 自动探 IP + 默认 Administrator/123456
#   ./rdp-vm.sh <vm_id> <ip>                   # 显式 IP
#   ./rdp-vm.sh <vm_id> <ip> <user> <pw>       # 自定义账号密码
#
# 默认:
#   user     = $RDP_USER            (默认 Administrator)
#   password = $RDP_PASSWORD        (默认 123456)
#   drive    = /tmp/nv-transfer 映射为 guest 里 \\tsclient\nv
#   参数     = /gfx:avc444 /dynamic-resolution /size:1920x1080 /cert:ignore
#
# IP 自动发现顺序:
#   1) 显式传入
#   2) ip neigh 在 br0 ARP 表里按 MAC 找
#   3) 若未找到: ARP 刷扫整个 br0 子网再查
#   4) 若仍未找到: 扫 /var/lib/misc/dnsmasq.leases 或 dhcpd.leases
#   5) 最后: 主动 arping -I br0 触发 ARP

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

VM_ID="${1:-}"
IP_OVERRIDE="${2:-}"
USER_ARG="${3:-}"
PW_ARG="${4:-}"

: "${NV_SHARE:=/tmp/nv-transfer}"
: "${RDP_SIZE:=1920x1080}"
: "${RDP_USER:=Administrator}"
: "${RDP_PASSWORD:=123456}"

if [[ -z "$VM_ID" || ! "$VM_ID" =~ ^[1-9][0-9]*$ ]]; then
    cat <<EOF >&2
usage: $0 <vm_id> [ip] [user] [password]

环境变量:
  RDP_USER       RDP 账号  (默认 Administrator)
  RDP_PASSWORD   密码      (默认 123456)
  NV_SHARE       共享给 guest 的目录 (默认 /tmp/nv-transfer)
  RDP_SIZE       分辨率    (默认 1920x1080)
EOF
    exit 2
fi

CONF="${VM_ROOT:-/home/ubuntu/images/vms}/configs/vm${VM_ID}.conf"
[[ -f "$CONF" ]] || { echo "$CONF 不存在" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

USER_FINAL="${USER_ARG:-$RDP_USER}"
PW_FINAL="${PW_ARG:-$RDP_PASSWORD}"

# ─── 探 VM IP ─────────────────────────────────────────────────────────────
find_ip_by_mac() {
    local mac_lc=$1
    ip -4 neigh show dev br0 2>/dev/null | \
        awk -v m="$mac_lc" 'tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}'
}

if [[ -n "$IP_OVERRIDE" ]]; then
    IP="$IP_OVERRIDE"
else
    mac_lc=$(echo "$VM_MAC" | tr 'A-Z' 'a-z')
    IP=$(find_ip_by_mac "$mac_lc")

    if [[ -z "$IP" ]]; then
        br_ip=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        [[ -n "$br_ip" ]] || { echo "br0 没 IP，VM 还没起来或桥接有问题" >&2; exit 1; }

        # ARP 扫全子网让内核自动填 neigh
        subnet_prefix=$(echo "$br_ip" | awk -F. '{print $1"."$2"."$3}')
        echo "ARP 扫 ${subnet_prefix}.0/24 找 MAC $VM_MAC ..." >&2
        for last in $(seq 1 254); do
            ping -c1 -W0.2 -q "${subnet_prefix}.${last}" >/dev/null 2>&1 &
        done
        wait 2>/dev/null
        IP=$(find_ip_by_mac "$mac_lc")
    fi

    # 再兜底：dnsmasq / dhcpd leases（如果有）
    if [[ -z "$IP" ]]; then
        for f in /var/lib/misc/dnsmasq.leases /var/lib/dhcp/dhcpd.leases; do
            [[ -f "$f" ]] || continue
            IP=$(grep -i "$VM_MAC" "$f" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}' | head -1)
            [[ -n "$IP" ]] && break
        done
    fi
fi

[[ -n "$IP" ]] || {
    cat >&2 <<EOF
未能探到 VM $VM_ID 的 IP (MAC=$VM_MAC)
解决:
  1) 确认 VM 启动了: ps aux | grep qemu-system
  2) 在 guest 里 \`ipconfig\` 看 IP
  3) 显式传: $0 $VM_ID <ip>
EOF
    exit 1
}

# ─── 宿主侧传递目录 ──────────────────────────────────────────────────────
mkdir -p "$NV_SHARE"

echo "VM $VM_ID → $IP (MAC=$VM_MAC)  user=$USER_FINAL"
echo "共享目录 \\\\tsclient\\nv  =  $NV_SHARE"

# 装 NVIDIA 驱动时 RDP 会断线，dwm/session 重启。这里做自动重连循环，
# xfreerdp3 自身的 /auto-reconnect 已经覆盖协议层 reconnect；外层 loop 处理
# server 完全下线 (shutdown/reboot) 的情况。Ctrl-C 真想退就按两次。
retries=${RDP_RETRIES:-60}
interval=${RDP_RETRY_INTERVAL:-3}
while true; do
    xfreerdp3 \
        "/v:${IP}" \
        "/u:${USER_FINAL}" \
        "/p:${PW_FINAL}" \
        "/size:${RDP_SIZE}" \
        /dynamic-resolution \
        /gfx:avc444 \
        /cert:ignore \
        /clipboard \
        /sound:sys:pulse \
        "/drive:nv,${NV_SHARE}" \
        /network:auto \
        /auto-reconnect \
        /auto-reconnect-max-retries:20 \
        +compression \
        /compression-level:2 \
        /timeout:30000
    ec=$?
    case $ec in
        0|62|131) echo "RDP 正常退出 (exit=$ec)"; exit 0 ;;
    esac
    (( --retries <= 0 )) && { echo "RDP 重试耗尽"; exit 1; }
    echo "RDP 断开 (exit=$ec)，${interval}s 后重连... (剩 $retries 次)"
    sleep "$interval"
done

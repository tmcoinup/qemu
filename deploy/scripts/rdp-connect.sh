#!/bin/bash
# rdp-connect.sh - RDP 到某个 stealth VM 实例
#
# 用法:
#   deploy/scripts/rdp-connect.sh                          # 实例 1，自动解析 LAN IP
#   deploy/scripts/rdp-connect.sh 2                        # 实例 2
#   deploy/scripts/rdp-connect.sh 1 --lan=192.168.30.185   # 手动指定 IP
#   deploy/scripts/rdp-connect.sh 1 --nat                  # 强制走 NAT hostfwd
#   RDP_USER=joe RDP_PASS=xxxx deploy/scripts/rdp-connect.sh 1
#
# 解析顺序:
#   1) --lan=<IP>
#   2) 从 stealth-instN.profile 读 NIC_MAC，在 `ip neigh` 表里找对应 IP
#   3) fallback: NAT hostfwd 127.0.0.1:$(13389+INSTANCE)
#
# 如果主机 arp/neigh 表里还没有 VM 的 MAC → IP 映射,
# 脚本会先尝试在本地子网上 broadcast ping 一轮 (需要 fping/ping 能用) 再重查。

set -u -o pipefail

INSTANCE=1
LAN_IP=""
FORCE_NAT=0
EXTRA=()

for a in "$@"; do
    case "$a" in
        --lan=*)  LAN_IP="${a#--lan=}" ;;
        --nat)    FORCE_NAT=1 ;;
        --help|-h)
            sed -n '1,18p' "$0"
            exit 0
            ;;
        *[!0-9]*) EXTRA+=("$a") ;;
        *)        INSTANCE="$a" ;;
    esac
done

USER_NAME="${RDP_USER:-Administrator}"
PASS="${RDP_PASS:-123456}"
SIZE="${RDP_SIZE:-1600x900}"
PROFILE="/home/ubuntu/images/stealth-inst${INSTANCE}.profile"

resolve_from_neigh() {
    local mac="$1"
    [[ -z "$mac" ]] && return 1
    mac="$(echo "$mac" | tr 'A-Z' 'a-z')"
    local ip
    ip="$(ip -4 neigh show 2>/dev/null | awk -v m="$mac" 'tolower($0) ~ m { print $1; exit }')"
    [[ -n "$ip" ]] && echo "$ip"
}

prime_neigh_cache() {
    # ping 一遍主 bridge 的广播地址，强制刷新邻居表
    local brip br_cidr
    brip="$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | head -1)"
    [[ -z "$brip" ]] && return
    br_cidr="${brip%/*}"
    local prefix="${br_cidr%.*}"
    # 顺序发 20 个后台 ping，1 秒后回收
    for i in $(seq 1 254); do
        ping -c 1 -W 1 -n -q "${prefix}.${i}" >/dev/null 2>&1 &
        (( i % 32 == 0 )) && wait
    done >/dev/null 2>&1
    wait
}

# --- determine target ---
if (( FORCE_NAT )); then
    TARGET="127.0.0.1:$((13389 + INSTANCE))"
    echo ">> [nat] 强制 NAT hostfwd: $TARGET"
elif [[ -n "$LAN_IP" ]]; then
    TARGET="$LAN_IP"
    echo ">> [manual] LAN IP = $LAN_IP"
else
    MAC=""
    if [[ -f "$PROFILE" ]]; then
        MAC="$(grep -E '^NIC_MAC=' "$PROFILE" | tail -1 | cut -d= -f2)"
    fi
    if [[ -n "$MAC" ]]; then
        echo ">> [auto] 查 NIC_MAC $MAC..."
        ip_found="$(resolve_from_neigh "$MAC")"
        if [[ -z "$ip_found" ]]; then
            echo ">> neigh 表里没有，先 prime 一下 (可能需要几秒)..."
            prime_neigh_cache
            ip_found="$(resolve_from_neigh "$MAC")"
        fi
        if [[ -n "$ip_found" ]]; then
            TARGET="$ip_found"
            echo ">> [auto] 解析到 LAN IP = $ip_found"
        fi
    fi
    if [[ -z "${TARGET:-}" ]]; then
        TARGET="127.0.0.1:$((13389 + INSTANCE))"
        echo ">> [fallback] 未解析到 LAN IP，退回 NAT hostfwd: $TARGET"
    fi
fi

# --- pre-flight TCP probe ---
HOST_PART="${TARGET%:*}"
PORT_PART="${TARGET#*:}"
[[ "$TARGET" != *:* ]] && { HOST_PART="$TARGET"; PORT_PART=3389; }

if ! timeout 3 bash -c "exec 3<>/dev/tcp/${HOST_PART}/${PORT_PART}" 2>/dev/null; then
    cat <<EOF
WARN: TCP ${HOST_PART}:${PORT_PART} 不可达。三种可能：
    (a) VM 还在开机 / 未装完系统
    (b) 客机里 TermService 没起: 以管理员身份跑 phase1.cmd
    (c) 客机里 bridge 被 Windows 判为 "公用网络", 防火墙挡 3389. 在客机管理员 PS 里跑:
        netsh advfirewall firewall set rule group="remote desktop" new enable=Yes profile=any
        Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
继续尝试 xfreerdp...
EOF
fi

# --- connect ---
set +e
exec xfreerdp \
    /v:"${TARGET}" \
    /u:"${USER_NAME}" \
    /p:"${PASS}" \
    /cert-ignore /sec:tls \
    /size:"${SIZE}" \
    /dynamic-resolution \
    +clipboard +fonts \
    /sound:sys:pulse \
    /log-level:WARN \
    "${EXTRA[@]}"

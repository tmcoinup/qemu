#!/usr/bin/env bash
#
# up.sh — 一键启动 vm + 连 RDP。
#
# 用法:
#   ./up.sh                               启动 vm1 (--rdp 模式)
#   ./up.sh --no-gpu                      std-vga + VNC，不挂 vGPU (装机 / 救援)
#   ./up.sh --connect                     启动 + 等 RDP + 自动 xfreerdp3 连进去
#   ./up.sh --connect-only                不启动，只连到已经在跑的 VM
#   ./up.sh --ip <ip>                     跳过 IP 自动发现，手动指定
#
# 环境变量:
#   VM_ID=N             选哪个 VM (默认 1)
#   GUEST_USER=...      RDP 账号 (默认 Administrator)
#   GUEST_PASS=...      RDP 密码 (默认 123456)
#   SUDO_PASSWORD=...   宿主 sudo 密码 (默认 123456；mdev 分配 / 清理需要)
#   STEALTH_OVMF=1      用源码重建的 stealth OVMF（默认用系统自带 stock）
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

# Ctrl+C / SIGTERM while we're polling RDP → don't kill VM (tmux keeps it
# alive). Just print a clear message so the user knows.
on_interrupt() {
    echo
    echo "[up] interrupted. VM 仍在跑（tmux session vm${VM_ID:-1}）。"
    echo "     接上: ./up.sh --connect-only      # 等 RDP 起来再连"
    echo "     关掉: ./down.sh                   # 或 ./down.sh --force"
    exit 130
}
trap on_interrupt INT TERM

VM_ID=${VM_ID:-1}
MODE=rdp
CONNECT=0
CONNECT_ONLY=0
IP_OVERRIDE=""
GUEST_USER=${GUEST_USER:-Administrator}
GUEST_PASS=${GUEST_PASS:-123456}
SUDO_PW=${SUDO_PASSWORD:-123456}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)         MODE="$2"; shift 2 ;;
        --rdp)          MODE=rdp; shift ;;
        --no-gpu)       MODE=no-gpu; shift ;;
        --gtk)          MODE=gtk; shift ;;
        --install)      MODE="install"; ISO="$2"; shift 2 ;;
        --connect)      CONNECT=1; shift ;;
        --connect-only) CONNECT_ONLY=1; shift ;;
        --ip)           IP_OVERRIDE="$2"; shift 2 ;;
        -h|--help)      sed -n '3,19p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1"; exit 2 ;;
    esac
done

# Stealth OVMF (FirmwareVendor rebuilt to "American Megatrends Inc."):
if [[ "${STEALTH_OVMF:-0}" == "1" && -f host/OVMF_CODE_4M_stealth.fd ]]; then
    export OVMF_CODE="$(pwd)/host/OVMF_CODE_4M_stealth.fd"
    echo "[up] using stealth OVMF: $OVMF_CODE"
fi

# ─────────────────────────────────────────────────────────────────────
# IP discovery — same logic as rdp-vm.sh: neigh table → ARP ping whole
# subnet → DHCP leases. Called only when user didn't pass --ip.
# ─────────────────────────────────────────────────────────────────────
find_vm_ip() {
    local conf="vm-configs/vm${VM_ID}.conf"
    [[ -f "$conf" ]] || { echo "missing $conf" >&2; return 1; }
    # shellcheck source=/dev/null
    source "$conf"
    local mac_lc ip
    mac_lc=$(echo "${VM_MAC:-}" | tr 'A-Z' 'a-z')
    if [[ -z "$mac_lc" ]]; then echo "no VM_MAC in $conf" >&2; return 1; fi

    # NOTE: don't pass `dev br0` — with the filter `ip` drops "dev br0" from
    # the output and MAC moves from $5 → $3. Without filter, columns are:
    #   $1=IP  $2=dev  $3=br0  $4=lladdr  $5=MAC  $6=state
    _by_mac() { ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}'; }

    ip=$(_by_mac)
    if [[ -z "$ip" ]]; then
        local br_ip subnet_prefix
        br_ip=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1) || return 1
        [[ -n "$br_ip" ]] || { echo "br0 无 IPv4，桥接可能没起" >&2; return 1; }
        subnet_prefix=$(echo "$br_ip" | awk -F. '{print $1"."$2"."$3}')
        echo "[up] ARP 扫 ${subnet_prefix}.0/24 找 MAC ${mac_lc}..." >&2
        local last
        for last in $(seq 1 254); do
            ping -c1 -W0.2 -q "${subnet_prefix}.${last}" >/dev/null 2>&1 &
        done
        wait 2>/dev/null || true
        ip=$(_by_mac)
    fi
    if [[ -z "$ip" ]]; then
        local f
        for f in /var/lib/misc/dnsmasq.leases /var/lib/dhcp/dhcpd.leases; do
            [[ -f "$f" ]] || continue
            ip=$(grep -i "$VM_MAC" "$f" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
            [[ -n "$ip" ]] && break
        done
    fi
    if [[ -z "$ip" ]]; then
        echo "[up] 未能探到 VM ${VM_ID} 的 IP (MAC=${VM_MAC})" >&2
        echo "     1) 确认 VM 已启动: tmux attach -t vm${VM_ID}  (或 pgrep qemu-system)" >&2
        echo "     2) 在 guest 里 ipconfig 看 IP" >&2
        echo "     3) 显式: $0 --ip <ip>" >&2
        return 1
    fi
    echo "$ip"
}

# ─────────────────────────────────────────────────────────────────────
# Mdev cleanup — prev QEMU got -9'd, mdev stays on GPU blocking next alloc.
# ─────────────────────────────────────────────────────────────────────
cleanup_stale_mdev() {
    local root=/sys/bus/mdev/devices
    [[ -d "$root" ]] || return 0
    shopt -s nullglob
    local entries=( "$root"/* ) uuid live pids p
    shopt -u nullglob
    (( ${#entries[@]} )) || return 0

    # cmdlines of live qemu-system processes
    live=""
    pids=$(pgrep -x qemu-system-x86_64 2>/dev/null || true)
    for p in $pids; do
        live+=" $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null || true)"
    done

    local removed=0
    for u in "${entries[@]}"; do
        uuid=${u##*/}
        if [[ "$live" != *"$uuid"* ]]; then
            echo "[up] cleaning stale mdev $uuid"
            echo "$SUDO_PW" | sudo -S -p '' sh -c "echo 1 > $u/remove" >/dev/null 2>&1 || true
            removed=$((removed + 1))
        fi
    done
    (( removed > 0 )) && echo "[up] cleaned $removed stale mdev(s)"
    return 0
}

# ─────────────────────────────────────────────────────────────────────
# launch_vm — kill old tmux, clean mdevs, write runner, tmux new -d.
# Bails out loud if tmux session doesn't actually come up.
# ─────────────────────────────────────────────────────────────────────
launch_vm() {
    echo "[up] starting vm${VM_ID} in mode=${MODE}"
    tmux kill-session -t "vm${VM_ID}" 2>/dev/null || true
    cleanup_stale_mdev

    local extra=()
    case "$MODE" in
        install) extra=( --install "$ISO" ) ;;
        no-gpu)  extra=( --no-gpu ) ;;
        gtk)     extra=( --gtk ) ;;
        rdp|*)   extra=( --rdp ) ;;
    esac

    # Small wrapper script avoids tmux quoting headaches — all env exported
    # gets inherited by the tmux-spawned shell.
    local runner=/tmp/vm${VM_ID}-runner.sh
    {
        echo '#!/usr/bin/env bash'
        echo "cd '$(pwd)'"
        echo "export SUDO_PASSWORD='${SUDO_PW}'"
        [[ -n "${OVMF_CODE:-}" ]] && echo "export OVMF_CODE='${OVMF_CODE}'"
        echo "exec ./start-vm.sh $VM_ID ${extra[*]} 2>&1 | tee /tmp/vm${VM_ID}.log"
    } > "$runner"
    chmod +x "$runner"

    tmux new -s "vm${VM_ID}" -d "$runner"
    sleep 2
    if ! tmux has-session -t "vm${VM_ID}" 2>/dev/null; then
        echo "[up] tmux session 'vm${VM_ID}' failed to start — runner may have errored:" >&2
        sed -n '1,20p' "/tmp/vm${VM_ID}.log" 2>/dev/null | sed 's/^/    /' >&2
        exit 1
    fi
    echo "[up] tmux session 'vm${VM_ID}' alive. QEMU log: /tmp/vm${VM_ID}.log"
}

wait_rdp() {
    local ip=$1
    echo -n "[up] waiting for RDP on ${ip}:3389 "
    local i
    for i in $(seq 1 180); do
        if nc -zv -w 1 "$ip" 3389 2>/dev/null; then
            echo " — up (T+$((i*3))s)"
            return 0
        fi
        echo -n "."
        sleep 3
    done
    echo " — timeout after 9 min"
    return 1
}

connect_rdp() {
    local ip=$1; shift || true
    # Initial window size. /dynamic-resolution handles later resize — starts
    # at 1920x1080 so RDP negotiates a useful desktop right away (anything
    # smaller and the IDD tends to collapse to 800x600 on first paint).
    # Override via RDP_SIZE env (e.g. RDP_SIZE=1024x768 ./up.sh ...).
    local size=${RDP_SIZE:-1920x1080}
    echo "[up] launching xfreerdp3 → ${ip}  /size:${size}"
    xfreerdp3 \
        /v:"$ip" \
        /u:"$GUEST_USER" \
        /p:"$GUEST_PASS" \
        /size:"$size" \
        /dynamic-resolution \
        /gfx:AVC444 \
        /sound:sys:pulse \
        /clipboard \
        /cert:ignore \
        /auto-reconnect \
        "$@" &
    disown
    echo "[up] xfreerdp3 launched (background)"
}

# ─── main ───
if (( CONNECT_ONLY )); then
    IP=${IP_OVERRIDE:-$(find_vm_ip)}
    [[ -n "$IP" ]] || exit 1
    wait_rdp "$IP" && connect_rdp "$IP"
    exit 0
fi

launch_vm

if (( CONNECT )); then
    # IP discovery only works after VM's network is up, so wait_rdp first
    # on a best-effort guess based on vmN.conf (we still need a target to
    # poll). Iterate: find IP each loop until neigh has it.
    echo -n "[up] discovering VM IP "
    IP=""
    for i in $(seq 1 60); do
        IP=$(find_vm_ip 2>/dev/null || true)
        if [[ -n "$IP" ]]; then echo " → $IP"; break; fi
        echo -n "."
        sleep 4
    done
    if [[ -z "$IP" ]]; then
        echo
        echo "[up] 没探到 IP，手动: $0 --connect-only --ip <IP>"
        exit 1
    fi
    wait_rdp "$IP" && connect_rdp "$IP"
else
    cat <<EOF
[up] VM 起来了。下一步：
     ./up.sh --connect-only      # 自动探 IP + xfreerdp3
     或指定: ./up.sh --connect-only --ip 192.168.30.191
     看 QEMU:   tmux attach -t vm${VM_ID}    (Ctrl-b d 退出不杀 VM)
     日志:      tail -f /tmp/vm${VM_ID}.log
     关机:      ./down.sh
     救援:      ./restore.sh
EOF
fi

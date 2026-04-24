#!/usr/bin/env bash
#
# down.sh — 关机 vm + 更新 baseline 备份。
#
#   ./down.sh              优雅关机 (WinRM shutdown /s) + cp --reflink 到 win10-ok.qcow2
#   ./down.sh --force      guest 不响应时强杀：SIGTERM→SIGKILL→tmux kill→清 run/、 mdev
#   ./down.sh --no-backup  关机后不更新 win10-ok.qcow2
#
# 兼容 Ctrl+C：用户在 down.sh 等 QEMU 退出那几十秒里按 Ctrl+C，脚本会退出
# 但 VM 不会被意外杀掉 —— 再次 `./down.sh` 继续关即可。
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VM_ID=${VM_ID:-1}
GUEST_IP_HINT=${GUEST_IP:-}
GUEST_USER=${GUEST_USER:-Administrator}
GUEST_PASS=${GUEST_PASS:-123456}
FORCE=0
BACKUP=1
SUDO_PW=${SUDO_PASSWORD:-123456}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)     FORCE=1; shift ;;
        --no-backup) BACKUP=0; shift ;;
        -h|--help)   sed -n '3,12p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1"; exit 2 ;;
    esac
done

QCOW_LIVE=/home/ubuntu/images/vms/win10-vm1.qcow2
QCOW_OK=/home/ubuntu/images/vms/win10-ok.qcow2

find_vm_ip() {
    local conf="vm-configs/vm${VM_ID}.conf"
    [[ -f "$conf" ]] || return 1
    # shellcheck source=/dev/null
    source "$conf"
    local mac_lc=${VM_MAC,,}
    ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}'
}

cleanup_run() {
    rm -f run/vm${VM_ID}.pid run/vm${VM_ID}.qmp run/vm${VM_ID}.mon 2>/dev/null || true
    # Remove mdevs the killed QEMU left behind
    shopt -s nullglob
    local root=/sys/bus/mdev/devices e uuid
    for e in "$root"/*; do
        uuid=${e##*/}
        echo "[down] releasing mdev $uuid"
        echo "$SUDO_PW" | sudo -S -p '' sh -c "echo 1 > $e/remove" >/dev/null 2>&1 || true
    done
    shopt -u nullglob
}

if pgrep -f "qemu-system-x86_64.*-name vm${VM_ID}" >/dev/null; then
    if (( FORCE )); then
        echo "[down] --force: TERM qemu-system-x86_64"
        pkill -TERM -f "qemu-system-x86_64.*-name vm${VM_ID}" || true
        for _ in $(seq 1 10); do
            pgrep -f "qemu-system-x86_64.*-name vm${VM_ID}" >/dev/null || break
            sleep 1
        done
        if pgrep -f "qemu-system-x86_64.*-name vm${VM_ID}" >/dev/null; then
            echo "[down] --force: KILL qemu-system-x86_64"
            pkill -KILL -f "qemu-system-x86_64.*-name vm${VM_ID}" || true
            sleep 2
        fi
        tmux kill-session -t "vm${VM_ID}" 2>/dev/null || true
        cleanup_run
    else
        local_ip=${GUEST_IP_HINT:-$(find_vm_ip || true)}
        if [[ -z "$local_ip" ]]; then
            echo "[down] guest IP 未知；直接 --force 吧（VM 仍在跑）"
            exit 1
        fi
        echo "[down] WinRM → ${local_ip}: shutdown /s"
        python3 - <<PY 2>/dev/null || echo "[down] WinRM unreachable"
from pypsrp.client import Client
Client('${local_ip}', username='${GUEST_USER}', password='${GUEST_PASS}', ssl=False, auth='ntlm') \
  .execute_ps('shutdown /s /t 3 /f /c "down.sh baseline"')
PY
        echo -n "[down] waiting QEMU exit "
        for _ in $(seq 1 60); do
            if ! pgrep -f "qemu-system-x86_64.*-name vm${VM_ID}" >/dev/null; then
                echo " — done"
                break
            fi
            echo -n "."
            sleep 3
        done
        if pgrep -f "qemu-system-x86_64.*-name vm${VM_ID}" >/dev/null; then
            echo
            echo "[down] still running after 3 min — 再来一次带 --force"
            exit 1
        fi
        tmux kill-session -t "vm${VM_ID}" 2>/dev/null || true
        cleanup_run
    fi
else
    echo "[down] no qemu-system for vm${VM_ID} — nothing to stop"
    cleanup_run
fi

if (( BACKUP )); then
    echo "[down] snapshotting $QCOW_LIVE → $QCOW_OK (cp --reflink=auto)"
    cp --reflink=auto "$QCOW_LIVE" "$QCOW_OK"
    ls -la "$QCOW_OK" "$QCOW_LIVE"
    echo "[down] baseline updated."
fi

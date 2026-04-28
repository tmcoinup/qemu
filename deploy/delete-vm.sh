#!/usr/bin/env bash
#
# delete-vm.sh — 删除一个 VM 的所有 host 文件。
#
# 用法:
#   ./delete-vm.sh <vm_id>            # 列出要删的，y/N 确认
#   ./delete-vm.sh <vm_id> -y         # 跳过确认
#
# 删的:
#   $VM_ROOT/configs/vmN.conf         # 配置
#   $VM_ROOT/run/vmN.{pid,qmp,mon}    # runtime sockets
#   $VM_ROOT/log/vmN.log              # QEMU stderr
#   $VM_ROOT/win10-vmN.qcow2          # 主盘
#   $VM_ROOT/vmN_VARS.fd              # OVMF UEFI 变量 (NVRAM / boot entries)
#   /dev/shm/nv-shmem-vmN             # ivshmem 后端
#
# 不动:
#   $VM_ROOT/win10-base.qcow2         # 公共 baseline
#
# 安全保护：检测到 QEMU 还在跑会拒绝删，先 ./stop-vm.sh <vm_id>。
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

export SUDO_PASSWORD="${SUDO_PASSWORD:-123456}"
export VM_ROOT="${VM_ROOT:-/home/ubuntu/images/vms}"

VM_ID=""
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)  ASSUME_YES=1; shift ;;
        -h|--help) sed -n '3,21p' "$0"; exit 0 ;;
        [0-9]*)    VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$VM_ID" ]] || { echo "usage: $0 <vm_id> [-y]" >&2; exit 2; }

# QEMU 还在跑 → 拒绝
if pgrep -f "qemu-system-x86_64.*-name vm${VM_ID}\b" >/dev/null; then
    echo "[delete-vm] !! vm${VM_ID} QEMU 还在跑，先：" >&2
    echo "             ./stop-vm.sh ${VM_ID}" >&2
    exit 1
fi

# 收集要删的文件
declare -a TARGETS
for f in \
    "$VM_ROOT/configs/vm${VM_ID}.conf" \
    "$VM_ROOT/run/vm${VM_ID}.pid" \
    "$VM_ROOT/run/vm${VM_ID}.qmp" \
    "$VM_ROOT/run/vm${VM_ID}.mon" \
    "$VM_ROOT/log/vm${VM_ID}.log" \
    "$VM_ROOT/win10-vm${VM_ID}.qcow2" \
    "$VM_ROOT/vm${VM_ID}_VARS.fd" \
    "/dev/shm/nv-shmem-vm${VM_ID}"; do
    [[ -e "$f" ]] && TARGETS+=("$f")
done

if (( ${#TARGETS[@]} == 0 )); then
    echo "[delete-vm] vm${VM_ID} 没找到任何文件，没事可干"
    exit 0
fi

echo "[delete-vm] 将删除 vm${VM_ID} 文件:"
total=0
for f in "${TARGETS[@]}"; do
    size=$(stat -c%s "$f" 2>/dev/null || echo 0)
    total=$((total + size))
    printf "  %10s  %s\n" "$(numfmt --to=iec-i --suffix=B $size)" "$f"
done
printf "  %10s  (合计)\n" "$(numfmt --to=iec-i --suffix=B $total)"

if (( ! ASSUME_YES )); then
    read -rp $'\n确认删除？(y/N) ' ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "[delete-vm] 取消"; exit 0; }
fi

# 释放可能残留的 mdev
shopt -s nullglob
for e in /sys/bus/mdev/devices/*; do
    uuid=${e##*/}
    echo "[delete-vm] releasing mdev $uuid"
    echo "$SUDO_PASSWORD" | sudo -S -p '' sh -c "echo 1 > $e/remove" >/dev/null 2>&1 || true
done
shopt -u nullglob

# 删文件 (先 user 权限，失败 fall back sudo — qcow2/VARS 可能被 root 写过)
for f in "${TARGETS[@]}"; do
    if rm -f "$f" 2>/dev/null; then
        echo "  rm $f"
    elif echo "$SUDO_PASSWORD" | sudo -S -p '' rm -f "$f" 2>/dev/null; then
        echo "  rm (sudo) $f"
    else
        echo "  !! 删除失败: $f"
    fi
done

echo
echo "[delete-vm] vm${VM_ID} 清理完成"
echo "  下一步: ./create-vm.sh ${VM_ID}              # 重新生成 conf"
echo "         ./create-disk.sh ${VM_ID}             # 建空白 qcow2"
echo "         ./start-vm.sh ${VM_ID} --install      # 装 Windows"

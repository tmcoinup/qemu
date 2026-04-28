#!/usr/bin/env bash
# create-disk.sh — 创建 VM 主盘 qcow2。
#
# 默认行为：
#   $VM_ROOT/win10-base.qcow2 存在 → 复制 base (含 driver/service 的干净 baseline，
#                                     秒级完成，无需重新装 driver)
#   不存在                        → 建空 qcow2 (用于装 Windows from ISO)
#
# 强制空盘: ./create-disk.sh <vm_id> --blank
#
# SSD 厂商标 "512GB" = 512 × 10^9 字节 (十进制 GB)，按这个建让 Windows 看到的
# 容量跟宣传一致。
#
# 用法:
#   ./create-disk.sh <vm_id>            # 默认从 base 复制 (512GB 空盘 fallback)
#   ./create-disk.sh <vm_id> --blank    # 强制空盘 (装 Windows from ISO)
#   ./create-disk.sh <vm_id> 1024       # 空盘 1TB (1e12 字节)
#   SIZE_BYTES=123456 ./create-disk.sh 1  # 精确字节数
#
# 环境变量:
#   VM_ROOT     /home/ubuntu/images/vms
#   SIZE_BYTES  精确字节数 (覆盖 CLI 的 GB 参数)

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

VM_ID=""
SIZE_GB=512
FORCE_BLANK=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --blank) FORCE_BLANK=1; shift ;;
        -h|--help) sed -n '3,21p' "$0"; exit 0 ;;
        [0-9]*[0-9]) [[ -z "$VM_ID" ]] && VM_ID="$1" || SIZE_GB="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
if [[ -z "$VM_ID" || ! "$VM_ID" =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: $0 <vm_id> [size_gb=512] [--blank]" >&2
    exit 2
fi

: "${VM_ROOT:=/home/ubuntu/images/vms}"
: "${VM_DISK_DIR:=$VM_ROOT}"
: "${QEMU_IMG:=$here/../build/qemu-img}"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img)
[[ -x "$QEMU_IMG" ]] || { echo "找不到 qemu-img" >&2; exit 1; }

mkdir -p "$VM_DISK_DIR"
TARGET="$VM_DISK_DIR/win10-vm${VM_ID}.qcow2"
BASE="$VM_DISK_DIR/win10-base.qcow2"

if [[ -f "$TARGET" ]]; then
    echo "⚠️  $TARGET 已存在。删除请 ./delete-vm.sh ${VM_ID} -y" >&2
    exit 1
fi

# Path A：base 存在且没显式 --blank → 复制 base (秒级，含 driver baseline)
if [[ -f "$BASE" && $FORCE_BLANK -eq 0 ]]; then
    echo "[create-disk] 从 baseline 复制：$BASE → $TARGET"
    cp --reflink=auto "$BASE" "$TARGET"
    "$QEMU_IMG" info "$TARGET" | head -8
    echo
    echo "✅ 已从 baseline 创建。下一步:"
    echo "   ./start-vm.sh $VM_ID            # 直接进 Windows (driver+service 已就绪)"
    exit 0
fi

# Path B：建空 qcow2 (装 Windows from ISO)
SIZE="${SIZE_BYTES:-$((SIZE_GB * 1000000000))}"
echo "[create-disk] 建空盘：$TARGET"
echo "  规格: ${SIZE_GB} GB (SSD 厂标)  = ${SIZE} 字节"
"$QEMU_IMG" create -f qcow2 -o cluster_size=64k,preallocation=metadata "$TARGET" "$SIZE"
"$QEMU_IMG" info "$TARGET" | head -8
echo
echo "✅ 已建空盘。下一步:"
echo "   ./start-vm.sh $VM_ID --install   # 默认 ISO /home/ubuntu/images/win10-ltsc.iso"

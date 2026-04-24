#!/usr/bin/env bash
# create-disk.sh — 创建 VM 主盘 qcow2 (SSD 厂家标称大小)
#
# SSD 厂商标 "512GB" = 512 × 10^9 字节 (十进制 GB)，并非 QEMU 默认的 512 GiB
# (2^30)。我们按厂家规格 512,000,000,000 字节建，Windows 设备管理器里看到的
# 容量才和宣传的 "512GB" 一致。
#
# 用法:
#   ./create-disk.sh <vm_id>            # 默认 512GB
#   ./create-disk.sh <vm_id> 1024       # 1TB (1e12 字节)
#   SIZE_BYTES=123456 ./create-disk.sh 1  # 精确字节数
#
# 环境变量:
#   VM_DISK_DIR   目标目录 (默认 /home/ubuntu/images/vms)
#   SIZE_BYTES    精确字节数 (覆盖 CLI 的 GB 参数)

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

VM_ID="${1:-}"
SIZE_GB="${2:-512}"  # 十进制 GB, 默认 512

if [[ -z "$VM_ID" || ! "$VM_ID" =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: $0 <vm_id> [size_gb=512]" >&2
    exit 2
fi

: "${VM_DISK_DIR:=/home/ubuntu/images/vms}"
: "${QEMU_IMG:=$here/../build/qemu-img}"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img)
[[ -x "$QEMU_IMG" ]] || { echo "找不到 qemu-img" >&2; exit 1; }

mkdir -p "$VM_DISK_DIR"
TARGET="$VM_DISK_DIR/win10-vm${VM_ID}.qcow2"

if [[ -f "$TARGET" ]]; then
    echo "⚠️  $TARGET 已存在。删除请 rm 手动操作，避免覆盖装好的系统。" >&2
    exit 1
fi

# 厂家 GB = 10^9 字节；允许 SIZE_BYTES 精确覆盖
SIZE="${SIZE_BYTES:-$((SIZE_GB * 1000000000))}"

echo "创建 $TARGET"
echo "  规格: ${SIZE_GB} GB (SSD 厂标)  = ${SIZE} 字节"
"$QEMU_IMG" create -f qcow2 -o cluster_size=64k,preallocation=metadata \
    "$TARGET" "$SIZE"

"$QEMU_IMG" info "$TARGET"
echo
echo "✅ 已建盘。下一步:"
echo "   ./start-vm.sh $VM_ID --install   # 用默认 ISO /home/ubuntu/images/win10-ltsc.iso"

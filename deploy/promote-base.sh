#!/usr/bin/env bash
#
# promote-base.sh — 把当前 vm1.qcow2 锁定为 win10-base.qcow2 baseline。
#
# 跑前提:
#   guest 已优雅 shutdown (./stop-vm.sh <vm_id>)
#   guest 内 driver/license/service 全部 working
#
# 跑完后所有 ./delete-vm.sh + ./start-vm.sh 都从这个干净 baseline 复制起，
# 不再需要 setup-guest 装 driver/license。
#
# 用法:
#   ./promote-base.sh           # vm1
#   ./promote-base.sh <vm_id>
#   ./promote-base.sh -y        # 跳过确认
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

export VM_ROOT="${VM_ROOT:-/home/ubuntu/images/vms}"
VM_ID=1
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) sed -n '3,15p' "$0"; exit 0 ;;
        [0-9]*) VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

VM_DISK="$VM_ROOT/win10-vm${VM_ID}.qcow2"
BASE="$VM_ROOT/win10-base.qcow2"
[[ -f "$VM_DISK" ]] || { echo "missing $VM_DISK" >&2; exit 1; }

# 安全保护
if pgrep -f "qemu-system-x86_64.*-name vm${VM_ID}\b" >/dev/null; then
    echo "[promote-base] !! vm${VM_ID} QEMU 还在跑，先：" >&2
    echo "  ./stop-vm.sh ${VM_ID}" >&2
    exit 1
fi

vm_size=$(stat -c%s "$VM_DISK")
echo "[promote-base] 把 $VM_DISK ($(numfmt --to=iec-i --suffix=B $vm_size)) 复制为 $BASE"
if [[ -f "$BASE" ]]; then
    base_size=$(stat -c%s "$BASE")
    echo "  (现有 $BASE = $(numfmt --to=iec-i --suffix=B $base_size) → 备份到 .old)"
fi

if (( ! ASSUME_YES )); then
    read -rp "确认？(y/N) " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "[promote-base] 取消"; exit 0; }
fi

# 旧 base 备份
if [[ -f "$BASE" ]]; then
    mv "$BASE" "${BASE}.old"
    echo "[promote-base] 旧 base 已 mv → ${BASE}.old"
fi

# qemu-img convert 而不是 cp，让新 base 是 standalone qcow2（不含 dirty
# 状态、不依赖 backing file）。也借机 compact 释放空洞。
QEMU_IMG="$(dirname "$(readlink -f "$0")")/../build/qemu-img"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img)

echo "[promote-base] qemu-img convert (compact + standalone)..."
"$QEMU_IMG" convert -O qcow2 -c "$VM_DISK" "$BASE"
new_size=$(stat -c%s "$BASE")
echo "[promote-base] 新 base = $(numfmt --to=iec-i --suffix=B $new_size) (compact)"

ls -la "$BASE" "$VM_DISK" "${BASE}.old" 2>/dev/null
echo
echo "[promote-base] 完成。下次:"
echo "  ./delete-vm.sh ${VM_ID} -y      # 删 vm${VM_ID} (不动 base)"
echo "  ./start-vm.sh ${VM_ID}          # create-disk 应自动从 base 复制（要改 create-disk.sh）"

#!/usr/bin/env bash
# seal-base.sh —— 把指定 instance 的 disk.qcow2 转成只读基础镜像，供后续克隆。
#
# 用法：
#   deploy/scripts/seal-base.sh <SRC_INSTANCE> <BASE_NAME>
#
# 例：
#   deploy/scripts/seal-base.sh 2 win10-ltsc-shallow
#       -> /home/ubuntu/images/vms/_base/win10-ltsc-shallow.qcow2
#
# 推荐流程：装好 1 个 VM（autounattend + shallow-stealth），关机后用本脚本固化为
# base，再用 clone-from-base.sh 克隆给后续 instance。新 instance 只存增量。
#
# 注意：
#   - 源 VM 必须先关机（lsof 检查）
#   - sysprep / 清掉 SID 等是 Windows 侧的事，本脚本不做 — 如果不 sysprep，
#     克隆出的 VM 会复用 SID/MachineGUID。仅做单机用途时可以忽略。
#   - 转换后源 disk.qcow2 不变，只是另存一份到 _base/。可选随后 rm 源 disk
#     腾空间，再用 clone-from-base.sh 重建该 instance 即可。

set -euo pipefail

SRC_INSTANCE="${1:-}"
BASE_NAME="${2:-}"

if [[ -z "$SRC_INSTANCE" || -z "$BASE_NAME" ]]; then
    echo "usage: $0 <SRC_INSTANCE> <BASE_NAME>" >&2
    exit 2
fi
if ! [[ "$SRC_INSTANCE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: SRC_INSTANCE 必须是正整数" >&2
    exit 2
fi
if [[ ! "$BASE_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: BASE_NAME 只能用字母/数字/下划线/短横线" >&2
    exit 2
fi

VM_DIR="/home/ubuntu/images/vms/${SRC_INSTANCE}"
SRC_DISK="$VM_DIR/disk.qcow2"
BASE_DIR="/home/ubuntu/images/vms/_base"
BASE_FILE="$BASE_DIR/${BASE_NAME}.qcow2"

if [[ ! -f "$SRC_DISK" ]]; then
    echo "ERROR: $SRC_DISK 不存在" >&2
    exit 1
fi
if [[ -f "$BASE_FILE" ]]; then
    echo "ERROR: $BASE_FILE 已存在 —— 拒绝覆盖" >&2
    exit 1
fi

# 检查 VM 是否在跑
if pgrep -f "qemu-system-x86.*win10-ryzen3-${SRC_INSTANCE}," >/dev/null; then
    echo "ERROR: instance $SRC_INSTANCE 还在运行，请先关机 (deploy/scripts/stop-vm.sh $SRC_INSTANCE)" >&2
    exit 1
fi

mkdir -p "$BASE_DIR"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_IMG="$REPO_ROOT/build/qemu-img"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=qemu-img

echo ">> 源 disk: $SRC_DISK ($(numfmt --to=iec --suffix=B "$(stat -c%s "$SRC_DISK")"))"
echo ">> 目标 base: $BASE_FILE"
echo ">> qemu-img convert (compress=on，把稀疏 qcow2 重写为更紧凑的形式)..."
"$QEMU_IMG" convert -p -O qcow2 -c "$SRC_DISK" "$BASE_FILE"

# 设为只读防止误改
chmod 0444 "$BASE_FILE"

echo ""
echo "=== Done ==="
echo "  base 镜像: $BASE_FILE"
echo "  size:     $(numfmt --to=iec --suffix=B "$(stat -c%s "$BASE_FILE")")"
echo ""
echo "下一步 — 用 clone-from-base.sh 创建新 instance:"
echo "  deploy/scripts/clone-from-base.sh $BASE_NAME <NEW_INSTANCE>"

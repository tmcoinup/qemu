#!/usr/bin/env bash
# clone-from-base.sh —— 用 _base/ 里的某个基础镜像快速创建一个新 instance。
#
# 用法：
#   deploy/scripts/clone-from-base.sh <BASE_NAME> <NEW_INSTANCE>
#
# 例：
#   deploy/scripts/clone-from-base.sh win10-ltsc-shallow 4
#       -> /home/ubuntu/images/vms/4/disk.qcow2 (qcow2 backed by base)
#       -> /home/ubuntu/images/vms/4/profile (重新随机硬件身份)
#
# 工作机制：
#   - qcow2 backing-file: 新 disk 只存增量，base 共享只读
#   - profile 一定是新随机的（CPU/主板/GPU/MAC/UUID/NVMe SN 全部新），
#     这样多份克隆给反作弊看是各自独立的硬件
#   - OVMF NVRAM 也是从 /usr/share/OVMF/OVMF_VARS_4M.fd 重新拷贝
#
# 之后启动：
#   DISPLAY=:1 deploy/scripts/start-vm.sh <NEW_INSTANCE>

set -euo pipefail

BASE_NAME="${1:-}"
NEW_INSTANCE="${2:-}"

if [[ -z "$BASE_NAME" || -z "$NEW_INSTANCE" ]]; then
    echo "usage: $0 <BASE_NAME> <NEW_INSTANCE>" >&2
    echo "" >&2
    echo "可用 base:" >&2
    ls /home/ubuntu/images/vms/_base/*.qcow2 2>/dev/null | sed 's|.*/||;s|\.qcow2$||;s|^|  - |' >&2
    exit 2
fi
if ! [[ "$NEW_INSTANCE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: NEW_INSTANCE 必须是正整数" >&2
    exit 2
fi

BASE_FILE="/home/ubuntu/images/vms/_base/${BASE_NAME}.qcow2"
if [[ ! -f "$BASE_FILE" ]]; then
    echo "ERROR: $BASE_FILE 不存在" >&2
    exit 1
fi

VM_DIR="/home/ubuntu/images/vms/${NEW_INSTANCE}"
DISK="$VM_DIR/disk.qcow2"
PROFILE="$VM_DIR/profile"
OVMF_VARS="$VM_DIR/ovmf-vars.fd"

if [[ -e "$DISK" ]]; then
    echo "ERROR: instance $NEW_INSTANCE 的 disk.qcow2 已存在 —— 拒绝覆盖" >&2
    echo "  如要重建，先 rm -rf $VM_DIR" >&2
    exit 1
fi

mkdir -p "$VM_DIR"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_IMG="$REPO_ROOT/build/qemu-img"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=qemu-img

echo ">> base:        $BASE_FILE"
echo ">> 创建增量盘:  $DISK"
"$QEMU_IMG" create -f qcow2 -F qcow2 -b "$BASE_FILE" "$DISK" >/dev/null
ls -la "$DISK"

# 重新随机 stealth 身份（保证 multi-clone 之间硬件 fingerprint 不同）
echo ">> 重新随机 stealth profile..."
source "$(dirname "$0")/stealth-lib.sh"
stealth_pick_profile
stealth_save_profile "$PROFILE"
echo ">> profile -> $PROFILE"
stealth_print_profile 2>&1

# 从 stock OVMF 模板拷一份新 NVRAM
OVMF_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.fd
if [[ -f "$OVMF_TEMPLATE" ]]; then
    cp "$OVMF_TEMPLATE" "$OVMF_VARS"
    echo ">> OVMF NVRAM -> $OVMF_VARS"
fi

echo ""
echo "=== Done ==="
echo "  instance:  $NEW_INSTANCE"
echo "  disk:      $DISK (qcow2 backed by base $BASE_NAME)"
echo ""
echo "下一步 — 启动:"
echo "  DISPLAY=:1 deploy/scripts/start-vm.sh $NEW_INSTANCE"
echo ""
echo "克隆出的 VM 会复用 base 系统盘内容（Windows 已装好 + shallow stealth 已应用），"
echo "但硬件身份是新的（CPU/主板/GPU/MAC/UUID/NVMe SN 全部随机）。"
echo ""
echo "⚠️ 没有 sysprep —— Windows SID/MachineGUID 与 base 同源；多机并发会有"
echo "   AD/Office 激活冲突；如果只是单机用，可忽略。需要彻底新机器请在 base"
echo "   sysprep /generalize /oobe 后再 seal-base.sh。"

#!/usr/bin/env bash
# host-inject-unattend.sh —— 离线把 deploy/autounattend/autounattend.xml 注入
# 到 Win10 guest，让 sysprep'd base 首启时 OOBE 自动跑完，不弹"区域设置"
# 这类交互界面，直接以 Administrator/123456 自动登录进 desktop。
#
# 工作机制：
#   Windows OOBE 启动时按以下顺序搜 unattend.xml，发现就用：
#     1. %WINDIR%\Panther\unattend.xml
#     2. %WINDIR%\Panther\Unattend\unattend.xml         <-- 本脚本写这里
#     3. %WINDIR%\System32\Sysprep\unattend.xml
#     4. C:\unattend.xml
#     5. 可移动介质根目录 unattend.xml / autounattend.xml
#   sysprep'd image 启动不走 windowsPE pass（只有 specialize + oobeSystem），
#   所以 autounattend.xml 里 windowsPE 段（DiskConfiguration 等）会被忽略，安全。
#
# 关键效果（来自 deploy/autounattend/autounattend.xml）：
#   - SkipMachineOOBE/SkipUserOOBE = true（跳过所有 OOBE wizard）
#   - HideEULAPage / HideOEMRegistrationScreen / HideOnlineAccountScreens
#     / HideLocalAccountScreen / HideWirelessSetupInOOBE = true
#   - AdministratorPassword = 123456，本地账户 Administrator 自动建
#   - AutoLogon: Username=Administrator, LogonCount=999, Enabled=true
#   - FirstLogonCommands: 启 RDP / 关 NLA / 注册 ms-gamingoverlay 等
#
# Per-instance customization:
#   <ComputerName> 设成 '*' —— 让 Windows OOBE 自己随机生成主机名（默认行为），
#   不带 'VM' 字样。'*' 生成的名字本身随机唯一，多机并发也不会同名 conflict。
#
# Usage:
#   sudo deploy/scripts/host-inject-unattend.sh <INSTANCE>
#
# Env overrides:
#   DISK=<path>     default /home/ubuntu/images/vms/<N>/disk.qcow2
#   NBD=/dev/nbdN   default /dev/nbd0
#   MOUNT=<path>    default /mnt/win10-inst<N>
#   UNATTEND=<path> default deploy/autounattend/autounattend.xml (脚本旁找)
#
# Prereqs (apt): qemu-utils ntfs-3g
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must be run as root" >&2; exit 1
fi

INSTANCE="${1:-}"
[[ -n "$INSTANCE" ]] || { echo "usage: $0 <INSTANCE>" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VM_DIR="/home/ubuntu/images/vms/${INSTANCE}"
DISK="${DISK:-$VM_DIR/disk.qcow2}"
: "${NBD:=/dev/nbd0}"
: "${MOUNT:=/mnt/win10-inst${INSTANCE}}"
: "${UNATTEND:=$REPO_ROOT/deploy/autounattend/autounattend.xml}"

log() { printf '[inject-unattend] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "$DISK" ]]     || die "disk not found: $DISK"
[[ -f "$UNATTEND" ]] || die "unattend.xml not found: $UNATTEND"
command -v qemu-nbd >/dev/null || die "need apt: qemu-utils"
command -v ntfsfix  >/dev/null || die "need apt: ntfs-3g"

modprobe nbd max_part=16 2>/dev/null || true

cleanup() {
    umount "$MOUNT" 2>/dev/null || true
    qemu-nbd --disconnect "$NBD" 2>/dev/null || true
}
trap cleanup EXIT

log "attaching $DISK to $NBD"
qemu-nbd --connect="$NBD" --format=qcow2 "$DISK"
sleep 1

SYSPART=""
for p in "${NBD}p3" "${NBD}p4" "${NBD}p2" "${NBD}p1"; do
    [[ -b "$p" ]] || continue
    if blkid -o value -s TYPE "$p" 2>/dev/null | grep -q '^ntfs$'; then
        SYSPART="$p"; break
    fi
done
[[ -n "$SYSPART" ]] || die "no NTFS partition under $NBD"

mkdir -p "$MOUNT"
ntfsfix --clear-dirty "$SYSPART" >/dev/null
mount -t ntfs-3g -o rw,remove_hiberfile "$SYSPART" "$MOUNT"

# 主要目标：%WINDIR%\Panther\Unattend\unattend.xml
# Windows OOBE 第二优先级搜这里，且不存在被覆盖风险（Panther 这个 Unattend 子目录
# 在 sysprep'd image 里要么空要么没有，写进去就是 fresh state）。
DEST_DIR="$MOUNT/Windows/Panther/Unattend"
DEST="$DEST_DIR/unattend.xml"

mkdir -p "$DEST_DIR"

# ComputerName 用 '*'：Windows OOBE 自己随机生成主机名（默认行为，无 'VM' 字样），
# 随机名天然唯一，多 clone 不会同 hostname。
COMPUTER_NAME="*"
log "writing unattend.xml -> $DEST  (ComputerName=$COMPUTER_NAME → Win 随机生成)"
sed "s|<ComputerName>[^<]*</ComputerName>|<ComputerName>${COMPUTER_NAME}</ComputerName>|" \
    "$UNATTEND" > "$DEST"

# 保险：在 C:\ 根 + Sysprep 目录也放一份。Windows OOBE 任意一处读到就行。
cp "$DEST" "$MOUNT/unattend.xml"
mkdir -p "$MOUNT/Windows/System32/Sysprep"
cp "$DEST" "$MOUNT/Windows/System32/Sysprep/unattend.xml"

# 验证 sed 替换成功（-F：COMPUTER_NAME 含 '*'，避免被当正则）
if ! grep -qF "<ComputerName>${COMPUTER_NAME}</ComputerName>" "$DEST"; then
    die "ComputerName 替换失败 — autounattend.xml 可能没 <ComputerName> 段"
fi
log "wrote 3 copies (Panther, C:\\ root, Sysprep)"

log "done. guest 首启走自动 OOBE → AutoLogon Administrator/123456"

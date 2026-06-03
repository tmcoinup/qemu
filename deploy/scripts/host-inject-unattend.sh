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
#   <ComputerName> = DESKTOP-<7位随机[A-Z0-9]> —— 跟全新消费级 Win10 出厂默认
#   主机名格式一模一样。**绝不能用 '*'**：'*' 会让 OOBE 拿 RegisteredOwner
#   ("Administrator") 的前 7 字符当前缀，生成 "ADMINIS-XXXXXXX"，一眼暴露
#   这是 sysprep 模板克隆（真机不会叫 ADMINIS-…）。显式 DESKTOP-XXXXXXX：
#     ① 无 'VM'/'ADMINIS' 破绽，长得像普通家用机
#     ② 7 位随机后缀天然唯一，多 clone 并发也不会撞 hostname
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
_NBD_PINNED="${NBD:+1}"   # 记录用户是否显式指定 NBD（忙时决定 fail-fast vs 自动选盘）
: "${NBD:=/dev/nbd0}"
: "${MOUNT:=/mnt/win10-inst${INSTANCE}}"
: "${UNATTEND:=$REPO_ROOT/deploy/autounattend/autounattend.xml}"

log() { printf '[inject-unattend] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "$DISK" ]]     || die "disk not found: $DISK"
[[ -f "$UNATTEND" ]] || die "unattend.xml not found: $UNATTEND"
command -v qemu-nbd >/dev/null || die "need apt: qemu-utils"
command -v ntfsfix  >/dev/null || die "need apt: ntfs-3g"

# 并发安全 (P2)：取全局 NBD 锁，串行化所有 host-*.sh 离线工具，防并发抢同一 nbd 设备。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nbd-lock.sh"
modprobe nbd max_part=16 2>/dev/null || true

cleanup() {
    umount "$MOUNT" 2>/dev/null || true
    nbd_disconnect_if_owned   # 只断本脚本成功连接的设备（不误断外部）
}
trap cleanup EXIT

log "attaching $DISK to $NBD"
nbd_connect NBD "$DISK"   # guard+选盘+connect，置 _NBD_CONNECTED；忙时显式→fail-fast / 默认→自动选盘
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

# ComputerName = DESKTOP-<7位随机[A-Z0-9]>，跟全新消费级 Win10 默认主机名格式
# 完全一致（见顶部注释，绝不用 '*'，否则 OOBE 生成 "ADMINIS-XXXXXXX" 暴露模板）。
# 纯 bash 生成：避开 `/dev/urandom | head` 在 set -euo pipefail 下的 SIGPIPE abort
# （历史教训 lib/nbd-lock.sh 那批离线工具就栽过 pipefail）。
gen_computer_name() {
    local chars='ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' out='' i seed
    # 用 /dev/urandom 给 $RANDOM 播种，保证同秒并发 clone 也不同名；失败则用 bash
    # 自带的逐进程种子（每次 clone 是独立进程，PID/时间不同 → 名字本就不同）。
    seed="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -dc '0-9' || true)"
    if [[ -n "$seed" ]]; then RANDOM="$seed"; fi
    for ((i=0; i<7; i++)); do out+="${chars:RANDOM%36:1}"; done
    printf 'DESKTOP-%s' "$out"   # "DESKTOP-"(8)+7=15，正好 NetBIOS 15 字符上限
}
COMPUTER_NAME="$(gen_computer_name)"
log "writing unattend.xml -> $DEST  (ComputerName=$COMPUTER_NAME — 仿全新 Win10 默认名)"
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

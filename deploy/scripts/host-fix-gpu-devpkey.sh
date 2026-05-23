#!/usr/bin/env bash
# host-fix-gpu-devpkey.sh — offline fix for DEVPKEY DriverProvider / DriverDesc
# on the virtio-gpu device of a shut-down Win10 guest.
#
# Why this script exists:
#   Device Manager → GPU → 驱动程序 → 驱动程序提供商 shows "未知" unless
#     (a) the SD of Enum\PCI\<hwid>\<inst>\Properties\{a8b865dd-...} is
#         readable by Administrators (Windows installs it as TrustedInstaller-
#         only), AND
#     (b) vk.type of the 00000000 value under pid 0004 / 0009 equals
#         0xFFFF0012 (DEVPROP_TYPE_STRING), NOT REG_SZ (0x1).
#
#   apply-gpu-spoof.ps1 handles (a) via Take-RegOwnership from inside the
#   guest, but `reg.exe add /t REG_SZ` can only produce type 0x1, and
#   SetupDiGetDeviceProperty fails (→ "未知") if the type word is wrong.
#
#   This script does both offline by raw-editing the hive on qcow2.
#
# 2026-05 改进：默认从 vms/<N>/profile **自动读** GPU_NAME / GPU_VENDOR，
# 不再需要手工传 PROVIDER / DEVICE_DESC；NVIDIA / AMD 都识别。
#
# Prereqs (apt 一行装齐)：
#   sudo apt install -y qemu-utils ntfs-3g python3-hivex
#
# 该脚本**纯离线** —— 直接读写 qcow2 文件，不连 guest、不联网。
# 唯一要 root 的原因是 qemu-nbd / mount NTFS 需要。
#
# Usage:
#   sudo deploy/scripts/host-fix-gpu-devpkey.sh <INSTANCE> [--dry-run]
#
# Must be run as root (it does qemu-nbd / ntfsfix / mount). If the VM is
# still running, it will invoke stop-vm.sh (as the original user) first.
#
# Environment overrides（不传就从 profile 自动派生）:
#   DISK=<path>           default /home/ubuntu/images/vms/<N>/disk.qcow2
#                         (auto-falls back to legacy win10-inst<N>.qcow2 layout)
#   NBD=/dev/nbdN         default /dev/nbd0
#   MOUNT=<path>          default /mnt/win10-inst<N>
#   PROVIDER=<string>     default = profile.GPU_VENDOR
#   DEVICE_DESC=<string>  default = profile.GPU_NAME
#   SUBSYS_RE=<regex>     default '^VEN_1AF4&DEV_1050' (virtio-vga 主 ID)
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must be run as root. Try: sudo $0 $*" >&2
    exit 1
fi

INSTANCE="${1:-1}"
shift || true

DRY=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

# The original user for invoking stop-vm.sh (QMP socket is under their uid).
ORIG_USER="${SUDO_USER:-ubuntu}"

# VM 目录（hardware pools v2 新布局；旧 win10-inst<N>.qcow2 还在的话回退过去）
VM_DIR="/home/ubuntu/images/vms/${INSTANCE}"
PROFILE_FILE="${VM_DIR}/profile"
if [[ -z "${DISK:-}" ]]; then
    if [[ -f "${VM_DIR}/disk.qcow2" ]]; then
        DISK="${VM_DIR}/disk.qcow2"
    else
        DISK="/home/ubuntu/images/win10-inst${INSTANCE}.qcow2"
    fi
fi
_NBD_PINNED="${NBD:+1}"   # 记录用户是否显式指定 NBD（忙时决定 fail-fast vs 自动选盘）
: "${NBD:=/dev/nbd0}"
: "${MOUNT:=/mnt/win10-inst${INSTANCE}}"
: "${SUBSYS_RE:=^VEN_1AF4&DEV_1050}"

log() { printf '[fix-devpkey] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

# 一次性自检：缺包给出一行装齐命令，不要分散提示
MISSING=()
command -v qemu-nbd >/dev/null || MISSING+=("qemu-utils")
command -v ntfsfix  >/dev/null || MISSING+=("ntfs-3g")
python3 -c 'import hivex' 2>/dev/null || MISSING+=("python3-hivex")
if (( ${#MISSING[@]} > 0 )); then
    log "缺以下 apt 包：${MISSING[*]}"
    log "一行装齐："
    log "  sudo apt install -y ${MISSING[*]}"
    exit 1
fi

[[ -f "$DISK" ]] || die "disk not found: $DISK"

# ----------------------------------------------------------------------
# 从 vms/<N>/profile 自动读 GPU 信息（PROVIDER / DEVICE_DESC 不传时用）
# ----------------------------------------------------------------------
# 默认值（兜底，profile 不存在时也能跑）
DEFAULT_PROVIDER="NVIDIA"
DEFAULT_DEVICE_DESC="NVIDIA GeForce GTX 1050"

# 安全 profile 解析器（P1#2）：只取字段，绝不 source/eval（被篡改的 profile 否则
# 等同在本 root 离线挂 hive 脚本里执行任意 shell 代码）。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/stealth-profile-io.sh"

if [[ -f "$PROFILE_FILE" ]]; then
    # 只取 GPU_VENDOR / GPU_NAME，经白名单安全解析（不执行 profile 内任何代码）
    PROF_GPU_VENDOR="$(stealth_profile_get GPU_VENDOR "$PROFILE_FILE" || true)"
    PROF_GPU_NAME="$(stealth_profile_get GPU_NAME "$PROFILE_FILE" || true)"
    if [[ -n "$PROF_GPU_VENDOR" ]]; then
        DEFAULT_PROVIDER="$PROF_GPU_VENDOR"
    fi
    if [[ -n "$PROF_GPU_NAME" ]]; then
        DEFAULT_DEVICE_DESC="$PROF_GPU_NAME"
    fi
    log "profile: ${PROFILE_FILE}"
    log "  GPU_VENDOR=${PROF_GPU_VENDOR:-<空，用默认 NVIDIA>}"
    log "  GPU_NAME=${PROF_GPU_NAME:-<空，用默认 GTX 1050>}"
else
    log "WARN: profile 文件不存在: $PROFILE_FILE"
    log "  用默认 PROVIDER=NVIDIA / DEVICE_DESC='NVIDIA GeForce GTX 1050'"
    log "  正常情况下 start-vm.sh 首启已生成 profile；手动传 env 也行："
    log "  PROVIDER=AMD DEVICE_DESC='AMD Radeon RX 550' sudo $0 $INSTANCE"
fi

# env 显式覆盖 profile（向后兼容旧用法）
: "${PROVIDER:=$DEFAULT_PROVIDER}"
: "${DEVICE_DESC:=$DEFAULT_DEVICE_DESC}"

log "将写入 Device Manager 字段："
log "  驱动程序提供商 (pid 0009): $PROVIDER"
log "  设备描述       (pid 0004): $DEVICE_DESC"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1) Ensure VM is stopped (stop-vm.sh talks to a user-owned QMP socket).
QMP_SOCK="/tmp/qemu-stealth-${INSTANCE}.qmp"
if [[ -S "$QMP_SOCK" ]]; then
    log "instance $INSTANCE looks running, invoking stop-vm.sh as $ORIG_USER"
    sudo -u "$ORIG_USER" "${SCRIPT_DIR}/stop-vm.sh" "$INSTANCE" --wait=120 || true
    sleep 1
fi

# 2) Attach NBD + ntfsfix + mount rw.
# 并发安全 (P2)：取全局 NBD 锁，串行化所有 host-*.sh 离线工具，防并发抢同一 nbd 设备。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nbd-lock.sh"
modprobe nbd max_part=16 2>/dev/null || true

cleanup() {
    local rc=$?
    umount "$MOUNT" 2>/dev/null || true
    nbd_disconnect_if_owned   # 只断本脚本成功连接的设备（不误断外部）
    exit $rc
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
[[ -n "$SYSPART" ]] || die "no NTFS partition found under $NBD"
log "system partition: $SYSPART"

mkdir -p "$MOUNT"
log "ntfsfix --clear-dirty $SYSPART"
ntfsfix --clear-dirty "$SYSPART" >/dev/null
log "mount -t ntfs-3g -o rw,remove_hiberfile $SYSPART $MOUNT"
MOUNT_ERR=$(mktemp)
if ! mount -t ntfs-3g -o rw,remove_hiberfile "$SYSPART" "$MOUNT" 2> "$MOUNT_ERR"; then
    cat "$MOUNT_ERR" >&2
    if grep -q "hibernated" "$MOUNT_ERR"; then
        cat >&2 <<'EOF'

[fix-devpkey] ⚠ Windows 处于 Fast Startup（混合关机）状态，hiberfil.sys 阻止 RW 挂载。
[fix-devpkey]   ntfs-3g 的 remove_hiberfile 选项在该情况下也失败。
[fix-devpkey]
[fix-devpkey] 永久修复（**只需一次**，往后 shutdown 永远干净）：
[fix-devpkey]   1) start-vm.sh <N>      # 重启 VM
[fix-devpkey]   2) guest 管理员 PowerShell:
[fix-devpkey]      powercfg -h off
[fix-devpkey]      Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
[fix-devpkey]          -Name HiberbootEnabled -Type DWord -Value 0
[fix-devpkey]      shutdown /s /t 0
[fix-devpkey]   3) host 重跑本脚本
[fix-devpkey]
[fix-devpkey] 副作用：hibernation 被禁用、hiberfil.sys 被删；shutdown /s 变成真正 power-off。
[fix-devpkey] 这跟 stealth 反作弊语义一致——hibernation 唤醒后 TPM/PCI 状态不一定能恢复。

EOF
    fi
    rm -f "$MOUNT_ERR"
    exit 1
fi
rm -f "$MOUNT_ERR"

HIVE="${MOUNT}/Windows/System32/config/SYSTEM"
[[ -f "$HIVE" ]] || die "SYSTEM hive not found at $HIVE"

# NB: 不要 truncate .LOG1/.LOG2 —— Win10 kernel mount SYSTEM hive 时 expects
# LOG1/LOG2 是 valid file（不是 0-byte），否则 winload reject hive → 0xc0000001
# 反复 reboot 后 Recovery 屏。Hive 真改了之后 stale LOG 由 Windows 自己 discard
# （比对 LOG 跟 hive 头 seq 不一致就丢）。

# 3a) Pre-fixup: 同步 primary/secondary seq + 重算 checksum 让 hivex 能打开。
#
# Windows 写 hive 用 dirty-vector 协议：先 ++primary_seq、写数据、再 ++secondary_seq。
# 中途断电 / cold shutdown 之间发生 race，primary > secondary 是常见现象（即"还
# 有未 commit 的写"），libhivex 1.3.x 看见 seq 不一致直接返回 "Operation not supported"。
#
# 我们的修改其实**会重写**这些位置，并且 Python 阶段末尾的 Phase C 会再次同步
# seq + 重算 checksum。所以这里安全地把 secondary 拉齐 primary 让 hivex 能打开，
# 不会丢任何数据（如果 LOG1/LOG2 里有 pending，那才是真要丢的——但本脚本只读
# Windows 已经稳定 commit 的 PCI Properties，pending 的临时 transactions 即使
# 丢了也无影响）。
log "pre-fixup: 同步 hive 头 primary/secondary seq + 拉齐 end_of_last_page + 重算 checksum"
python3 "$SCRIPT_DIR/lib/devpkey-prefixup.py" "$HIVE"

# 3b) Run the embedded Python patcher.
log "patching $HIVE (provider=$PROVIDER, desc=$DEVICE_DESC)"
if [[ $DRY -eq 1 ]]; then
    DRY_RUN=1
fi

DRY_RUN="${DRY_RUN:-0}" HIVE="$HIVE" \
    PROVIDER="$PROVIDER" DEVICE_DESC="$DEVICE_DESC" \
    SUBSYS_RE="$SUBSYS_RE" \
    python3 "$SCRIPT_DIR/lib/devpkey-patch.py"

log "done"

#!/usr/bin/env bash
# host-fix-power.sh — offline force monitor / sleep / hibernate / disk
# timeouts to 0 (永不息屏) in a Win10 guest's SYSTEM hive.
#
# Why this exists:
#   Win10 default power policy 把 monitor-timeout-ac=10min, sleep=30min.
#   闲置 10min 后 guest 主动关闭显示器, SDL 窗口看到的就是黑屏 (鼠标
#   动一下又亮 = guest 收到输入唤醒). 跟 host 屏保是两件事 (host 那个
#   走 gnome-session-inhibit).
#
#   powercfg /change monitor-timeout-ac 0 是在线方案, 但需要 SSH/RDP.
#   旧 VM 没法 SSH 时直接离线 patch hive 的 DefaultPowerSchemeValues.
#
#   也由 deploy/scripts/vm-bootstrap.ps1 在 fresh VM 跑 powercfg 命令
#   做永久修, 这个脚本是给已经在跑的旧 VM 用.
#
# Prereqs (apt): qemu-utils, ntfs-3g, python3-hivex
#
# Usage:
#   sudo deploy/scripts/host-fix-power.sh <INSTANCE> [--dry-run]
#
# Env overrides:
#   DISK=<path>     default /home/ubuntu/images/vms/<N>/disk.qcow2
#                   (auto-falls back to legacy win10-inst<N>.qcow2)
#   NBD=/dev/nbdN   default /dev/nbd0
#   MOUNT=<path>    default /mnt/win10-inst<N>
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

ORIG_USER="${SUDO_USER:-ubuntu}"

if [[ -z "${DISK:-}" ]]; then
    if [[ -f "/home/ubuntu/images/vms/${INSTANCE}/disk.qcow2" ]]; then
        DISK="/home/ubuntu/images/vms/${INSTANCE}/disk.qcow2"
    else
        DISK="/home/ubuntu/images/win10-inst${INSTANCE}.qcow2"
    fi
fi
_NBD_PINNED="${NBD:+1}"   # 记录用户是否显式指定 NBD（忙时决定 fail-fast vs 自动选盘）
: "${NBD:=/dev/nbd0}"
: "${MOUNT:=/mnt/win10-inst${INSTANCE}}"

log() { printf '[fix-power] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "$DISK" ]] || die "disk not found: $DISK"
command -v qemu-nbd >/dev/null || die "need apt: qemu-utils"
command -v ntfsfix  >/dev/null || die "need apt: ntfs-3g"
python3 -c 'import hivex' 2>/dev/null || die "need apt: python3-hivex"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

QMP_SOCK="/tmp/qemu-stealth-${INSTANCE}.qmp"
if [[ -S "$QMP_SOCK" ]]; then
    log "instance $INSTANCE looks running, invoking stop-vm.sh as $ORIG_USER"
    sudo -u "$ORIG_USER" "${SCRIPT_DIR}/stop-vm.sh" "$INSTANCE" --wait=120 || true
    sleep 1
fi

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
mount -t ntfs-3g -o rw,remove_hiberfile "$SYSPART" "$MOUNT"

HIVE="$MOUNT/Windows/System32/config/SYSTEM"
[[ -f "$HIVE" ]] || die "SYSTEM hive not found at $HIVE"

log "patching DefaultPowerSchemeValues (Ac/DcSettingIndex -> 0)"
DRY="$DRY" python3 - "$HIVE" <<'PY'
"""Force AcSettingIndex/DcSettingIndex = 0 for TurnOffDisplay /
SleepAfter / HibernateAfter / DiskTurnOff in every scheme under
ControlSet001 (and 002 if present). Idempotent: skip values already 0."""
import hivex, os, sys, struct

DRY = os.environ.get('DRY') == '1'
TARGETS = [
    ('7516b95f-f776-4464-8c53-06167f40cc99', '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e', 'TurnOffDisplay'),
    ('238c9fa8-0aad-41ed-83f4-97be242c8f20', '29f6c1db-86da-48c5-9fdb-f2b67b1f44da', 'SleepAfter'),
    ('238c9fa8-0aad-41ed-83f4-97be242c8f20', '9d7815a6-7ee4-497e-8888-515a05f02364', 'HibernateAfter'),
    ('0012ee47-9041-4b5d-9b77-535fba8b1442', '6738e2c4-e8a5-4a42-b16a-e040e769756e', 'DiskTurnOff'),
]
ZERO = struct.pack('<I', 0)

h = hivex.Hivex(sys.argv[1], write=not DRY)
fixes = 0
for cs in ['ControlSet001', 'ControlSet002']:
    cs_n = h.node_get_child(h.root(), cs)
    if cs_n is None:
        print(f'  skip {cs} (missing)'); continue
    n = cs_n
    for p in ['Control', 'Power', 'PowerSettings']:
        n = h.node_get_child(n, p)
        if n is None: break
    if n is None:
        print(f'  skip {cs}: no PowerSettings'); continue

    for grp_g, set_g, label in TARGETS:
        grp = h.node_get_child(n, grp_g)
        if grp is None: continue
        setn = h.node_get_child(grp, set_g)
        if setn is None: continue
        dpsv = h.node_get_child(setn, 'DefaultPowerSchemeValues')
        if dpsv is None: continue
        for sch in h.node_children(dpsv):
            sname = h.node_name(sch)
            for vname in ('AcSettingIndex', 'DcSettingIndex'):
                cur = None
                for v in h.node_values(sch):
                    if h.value_key(v) == vname:
                        cur = struct.unpack('<I', h.value_value(v)[1][:4])[0]
                        break
                if cur is None or cur == 0:
                    continue
                print(f'  {cs}/{label}/{sname}/{vname}: {cur} -> 0')
                if DRY:
                    continue
                h.node_set_value(sch, {'t': 4, 'key': vname, 'value': ZERO})
                fixes += 1
if not DRY:
    h.commit(None)
print(f'  {fixes} value writes' + (' (DRY-RUN)' if DRY else ''))
PY

log "done"

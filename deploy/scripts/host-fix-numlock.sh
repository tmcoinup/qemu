#!/usr/bin/env bash
# host-fix-numlock.sh — offline force NumLock ON in a Win10 guest's
# DEFAULT + per-user NTUSER.DAT hives.
#
# Why this exists:
#   QEMU SDL2 backend transparently bridges PS/2 NumLock LED state between
#   host XKB and guest. So whatever the guest WRITES to the PS/2 keyboard
#   LED at boot becomes the host's NumLock LED state too.
#
#   Stock Win10 ships with HKEY_USERS\.DEFAULT\Control Panel\Keyboard\
#   InitialKeyboardIndicators = "2147483648" (= 0x80000000), which means
#   "actively write LED at boot, NumLock = OFF". Result: every time the
#   guest reaches the Welcome screen, the host's NumLock LED flips OFF —
#   the user perceives this as "guest NumLock没同步". Pressing NumLock
#   toggles both back ON, but next boot it's OFF again.
#
#   Fix: rewrite the same value to "2147483650" (= 0x80000002) — same
#   "actively write LED" bit, but with NumLock ON. Patches DEFAULT and
#   every Users/<u>/NTUSER.DAT we can find.
#
#   Also installed by deploy/scripts/vm-bootstrap.ps1 for fresh VMs;
#   this script is for already-installed VMs that haven't re-run bootstrap.
#
# Prereqs (apt): qemu-utils, ntfs-3g, python3-hivex
#
# Usage:
#   sudo deploy/scripts/host-fix-numlock.sh <INSTANCE> [--dry-run]
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
: "${NBD:=/dev/nbd0}"
: "${MOUNT:=/mnt/win10-inst${INSTANCE}}"

log() { printf '[fix-numlock] %s\n' "$*"; }
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

modprobe nbd max_part=16 2>/dev/null || true

cleanup() {
    local rc=$?
    umount "$MOUNT" 2>/dev/null || true
    qemu-nbd --disconnect "$NBD" 2>/dev/null || true
    exit $rc
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
[[ -n "$SYSPART" ]] || die "no NTFS partition found under $NBD"
log "system partition: $SYSPART"

mkdir -p "$MOUNT"
log "ntfsfix --clear-dirty $SYSPART"
ntfsfix --clear-dirty "$SYSPART" >/dev/null
log "mount -t ntfs-3g -o rw,remove_hiberfile $SYSPART $MOUNT"
mount -t ntfs-3g -o rw,remove_hiberfile "$SYSPART" "$MOUNT"

# Collect hives: DEFAULT + every Users/<u>/NTUSER.DAT (skip Default User /
# Public / All Users — those don't have a real NTUSER.DAT or it's a junction).
mapfile -t HIVES < <(
    printf '%s\n' "${MOUNT}/Windows/System32/config/DEFAULT"
    find "${MOUNT}/Users" -maxdepth 2 -mindepth 2 -name 'NTUSER.DAT' \
        -not -path '*/Default User/*' \
        -not -path '*/All Users/*' \
        -not -path '*/Public/*' 2>/dev/null
)
[[ ${#HIVES[@]} -gt 0 ]] || die "no hives found"

log "hives to patch:"
for h in "${HIVES[@]}"; do log "  $h"; done

# NB: 不要 truncate .LOG1/.LOG2 —— Win10 kernel mount hive 时 expects
# LOG1/LOG2 是 valid file（不是 0-byte），否则 0xc0000001 + reboot loop。
# Hive 改了之后 LOG stale，Windows 会把它当 discardable 而不是 corruption；
# 改本就 in-place 走 hivex.commit() 也 update seq/checksum 让 LOG 自动失效。
# 历史 chntpw truncate 法对 Win10 22H2 不再适用。

DRY="$DRY" python3 - "${HIVES[@]}" <<'PY'
r"""Force InitialKeyboardIndicators=2147483650 (=0x80000002 = "actively
write LED at boot, NumLock=ON") into Control Panel\Keyboard of every
listed hive. Reads existing value first; reports unchanged hives.

r-string 前缀避免 Python 3.12+ 把 docstring 里的 '\K' 当作转义抛
SyntaxWarning (Control Panel\Keyboard 路径名含反斜线)。"""
import hivex, os, sys
WANT = '2147483650'
DRY = os.environ.get('DRY') == '1'

for hpath in sys.argv[1:]:
    print(f'=== {hpath} ===')
    h = hivex.Hivex(hpath, write=not DRY)
    n = h.root()
    for p in ['Control Panel', 'Keyboard']:
        c = h.node_get_child(n, p)
        if c is None:
            if DRY:
                print(f'  (would create node {p})')
                n = None; break
            c = h.node_add_child(n, p)
            print(f'  created node {p}')
        n = c
    if n is None:
        continue

    cur = None
    for v in h.node_values(n):
        if h.value_key(v) == 'InitialKeyboardIndicators':
            try:
                cur = h.value_string(v)
            except Exception:
                cur = repr(h.value_value(v))
            break
    if cur == WANT:
        print(f"  unchanged: '{WANT}'")
        continue
    print(f"  '{cur}' -> '{WANT}'")
    if DRY:
        continue
    h.node_set_value(n, {
        't': 1,  # REG_SZ
        'key': 'InitialKeyboardIndicators',
        'value': (WANT + '\0').encode('utf-16-le'),
    })
    h.commit(None)
PY

log "done"

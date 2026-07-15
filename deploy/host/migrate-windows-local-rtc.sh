#!/usr/bin/env bash
# One-time, host-only migration from QEMU base=utc + RealTimeIsUniversal=1
# to the legacy production contract: TZ=Asia/Shanghai + base=localtime.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISK=""
INSTANCE="guest"
BACKUP_DIR=""
EXPECTED_VM=""
EXPECTED_UUID=""
EXPECTED_GPU_NAME=""
EXPECTED_TOKEN_SHA256=""
EXPECTED_DRIVER_PROFILE=""
EXPECTED_DRIVER_VERSION=""
EXPECTED_PATCHED_INF_SHA256=""
_NBD_PINNED="${NBD:+1}"
NBD="${NBD:-/dev/nbd0}"

usage() {
    echo "usage: $0 --disk FILE.qcow2 --instance vmN --backup-dir DIR --expected-vm vmN --expected-uuid UUID --expected-gpu-name NAME --expected-token-sha256 HEX [--expected-driver-profile PROFILE --expected-driver-version VERSION --expected-patched-inf-sha256 HEX]" >&2
}
die() { echo "[rtc-migrate] ERROR: $*" >&2; exit 1; }
log() { echo "[rtc-migrate] $*"; }

while (( $# > 0 )); do
    case "$1" in
        --disk) DISK=${2:-}; shift 2 ;;
        --instance) INSTANCE=${2:-}; shift 2 ;;
        --backup-dir) BACKUP_DIR=${2:-}; shift 2 ;;
        --expected-vm) EXPECTED_VM=${2:-}; shift 2 ;;
        --expected-uuid) EXPECTED_UUID=${2:-}; shift 2 ;;
        --expected-gpu-name) EXPECTED_GPU_NAME=${2:-}; shift 2 ;;
        --expected-token-sha256) EXPECTED_TOKEN_SHA256=${2:-}; shift 2 ;;
        --expected-driver-profile) EXPECTED_DRIVER_PROFILE=${2:-}; shift 2 ;;
        --expected-driver-version) EXPECTED_DRIVER_VERSION=${2:-}; shift 2 ;;
        --expected-patched-inf-sha256) EXPECTED_PATCHED_INF_SHA256=${2:-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$DISK" && -n "$BACKUP_DIR" && -n "$EXPECTED_VM" &&
   -n "$EXPECTED_UUID" && -n "$EXPECTED_GPU_NAME" &&
   -n "$EXPECTED_TOKEN_SHA256" ]] || { usage; exit 2; }
[[ "$EXPECTED_VM" =~ ^vm[1-9][0-9]*$ ]] || die "invalid --expected-vm: $EXPECTED_VM"
[[ "$EXPECTED_UUID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || die "invalid --expected-uuid"
EXPECTED_UUID=${EXPECTED_UUID,,}
[[ "$INSTANCE" == "$EXPECTED_VM" ]] \
    || die "--instance and --expected-vm do not match"
gpu_name_re='^[A-Za-z0-9][A-Za-z0-9._+() -]{0,30}$'
[[ "$EXPECTED_GPU_NAME" =~ $gpu_name_re ]] \
    || die "invalid --expected-gpu-name"
unset gpu_name_re
[[ "$EXPECTED_TOKEN_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]] || die "invalid --expected-token-sha256"
EXPECTED_TOKEN_SHA256=${EXPECTED_TOKEN_SHA256^^}
DRIVER_EXPECTATION_COUNT=0
for expected_driver_value in "$EXPECTED_DRIVER_PROFILE" \
        "$EXPECTED_DRIVER_VERSION" "$EXPECTED_PATCHED_INF_SHA256"; do
    [[ -z "$expected_driver_value" ]] || ((DRIVER_EXPECTATION_COUNT += 1))
done
case "$DRIVER_EXPECTATION_COUNT" in
    0) EXPECT_STRICT_DRIVER=0 ;;
    3) EXPECT_STRICT_DRIVER=1 ;;
    *) die "driver marker expectations must be supplied together" ;;
esac
if (( EXPECT_STRICT_DRIVER )); then
    [[ "$EXPECTED_DRIVER_PROFILE" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] \
        || die "invalid --expected-driver-profile"
    [[ "$EXPECTED_DRIVER_VERSION" =~ ^[0-9]+(\.[0-9]+){3}$ ]] \
        || die "invalid --expected-driver-version"
    [[ "$EXPECTED_PATCHED_INF_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]] \
        || die "invalid --expected-patched-inf-sha256"
    EXPECTED_PATCHED_INF_SHA256=${EXPECTED_PATCHED_INF_SHA256,,}
fi
unset DRIVER_EXPECTATION_COUNT expected_driver_value
[[ $EUID -eq 0 ]] || die "需要 root（qemu-nbd / NTFS 离线写入）"
[[ -f "$DISK" ]] || die "disk not found: $DISK"
for command in qemu-nbd ntfs-3g.probe mount umount python3 tr; do
    command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
python3 -c 'import hivex' >/dev/null 2>&1 || die "missing python3-hivex"
if pgrep -af qemu-system-x86_64 2>/dev/null | grep -F -- "$DISK" >/dev/null; then
    die "$INSTANCE is running; refusing to mount its disk"
fi

# shellcheck source=../lib/nbd-lock.sh
source "$REPO_ROOT/deploy/lib/nbd-lock.sh"
modprobe nbd max_part=16 2>/dev/null || true

SAFE_INSTANCE=${INSTANCE//[^A-Za-z0-9_.-]/_}
MOUNT_POINT="/tmp/winmnt-rtc-${SAFE_INSTANCE}"
_RTC_MOUNTED=0
cleanup() {
    local rc=$?
    if [[ "${_RTC_MOUNTED:-0}" == 1 ]]; then
        umount "$MOUNT_POINT" 2>/dev/null || rc=70
        _RTC_MOUNTED=0
    fi
    if [[ "${_NBD_CONNECTED:-0}" == 1 && -n "${_NBD_DEV:-}" ]]; then
        qemu-nbd --disconnect "$_NBD_DEV" >/dev/null 2>&1 || rc=70
        _NBD_CONNECTED=0
    fi
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    exit "$rc"
}
trap cleanup EXIT

log "qemu-nbd connect: $DISK"
nbd_connect NBD "$DISK"
sleep 1

SYSTEM_PART=""
for partition in "${NBD}p3" "${NBD}p4" "${NBD}p2" "${NBD}p1" "${NBD}p5"; do
    [[ -b "$partition" ]] || continue
    blkid -o value -s TYPE "$partition" 2>/dev/null | grep -q '^ntfs$' || continue
    mkdir -p "$MOUNT_POINT"
    if mount -t ntfs-3g -o ro,norecover "$partition" "$MOUNT_POINT" 2>/dev/null; then
        _RTC_MOUNTED=1
        if [[ -f "$MOUNT_POINT/Windows/System32/config/SYSTEM" ]]; then
            umount "$MOUNT_POINT" || die "could not unmount probe mount"
            _RTC_MOUNTED=0
            SYSTEM_PART=$partition
            break
        fi
        umount "$MOUNT_POINT" || die "could not unmount probe mount"
        _RTC_MOUNTED=0
    fi
done
[[ -n "$SYSTEM_PART" ]] || die "Windows SYSTEM hive was not found"
log "Windows system partition: $SYSTEM_PART"

probe_rc=0
ntfs-3g.probe --readwrite "$SYSTEM_PART" || probe_rc=$?
case "$probe_rc" in
    0) ;;
    14) die "Windows is still hibernated/Fast Startup is active; run the guest EXE and fully shut down" ;;
    15) die "Windows volume is dirty; boot it and perform a normal full shutdown" ;;
    *) die "NTFS read-write probe failed (rc=$probe_rc)" ;;
esac

mkdir -p "$MOUNT_POINT"
mount -t ntfs-3g -o rw,norecover "$SYSTEM_PART" "$MOUNT_POINT"
_RTC_MOUNTED=1
HIVE="$MOUNT_POINT/Windows/System32/config/SYSTEM"
[[ -f "$HIVE" ]] || die "SYSTEM hive disappeared after read-write mount"

# This proves the universal administrator EXE completed token installation,
# device naming, and hibernation shutdown on this exact SMBIOS UUID.  Old
# per-VM V1 markers are intentionally ignored.
MARKER="$MOUNT_POINT/ProgramData/QemuVgpu/prepared-${EXPECTED_UUID}.txt"
[[ -f "$MARKER" ]] || die "guest completion marker is missing; run VgpuGuestFinish as Administrator"
MARKER_TEXT=$(tr -d '\r' <"$MARKER")
grep -Fqx "VM_UUID=${EXPECTED_UUID}" <<<"$MARKER_TEXT" \
    || die "guest completion marker UUID does not match vm.conf"
grep -Fqx "GPU_NAME=${EXPECTED_GPU_NAME}" <<<"$MARKER_TEXT" \
    || die "guest completion marker GPU name does not match vm.conf"
grep -Fqx "TOKEN_SHA256=${EXPECTED_TOKEN_SHA256}" <<<"$MARKER_TEXT" \
    || die "guest completion marker token hash does not match this run"
if (( EXPECT_STRICT_DRIVER )); then
    grep -Fqx 'QEMU_VGPU_PREPARED_V3' <<<"$MARKER_TEXT" \
        || die "strict consumer driver requires a V3 guest completion marker"
    grep -Fqx "DRIVER_PROFILE=${EXPECTED_DRIVER_PROFILE}" <<<"$MARKER_TEXT" \
        || die "guest completion marker driver profile does not match"
    grep -Fqx "DRIVER_VERSION=${EXPECTED_DRIVER_VERSION}" <<<"$MARKER_TEXT" \
        || die "guest completion marker driver version does not match"
    grep -Fqx "PATCHED_INF_SHA256=${EXPECTED_PATCHED_INF_SHA256}" <<<"$MARKER_TEXT" \
        || die "guest completion marker patched INF hash does not match"
    mapfile -t MARKER_DRIVER_INF_VALUES < <(
        sed -n 's/^DRIVER_INF=//p' <<<"$MARKER_TEXT"
    )
    (( ${#MARKER_DRIVER_INF_VALUES[@]} == 1 )) \
        || die "guest completion marker must contain exactly one DRIVER_INF"
    MARKER_DRIVER_INF=${MARKER_DRIVER_INF_VALUES[0]}
    [[ "$MARKER_DRIVER_INF" =~ ^oem[0-9]+\.inf$ ]] \
        || die "guest completion marker has an invalid published INF"
    EXPECTED_MARKER_TEXT=$(printf \
        'QEMU_VGPU_PREPARED_V3\nVM_UUID=%s\nGPU_NAME=%s\nTOKEN_SHA256=%s\nDRIVER_PROFILE=%s\nDRIVER_VERSION=%s\nDRIVER_INF=%s\nPATCHED_INF_SHA256=%s' \
        "$EXPECTED_UUID" "$EXPECTED_GPU_NAME" "$EXPECTED_TOKEN_SHA256" \
        "$EXPECTED_DRIVER_PROFILE" "$EXPECTED_DRIVER_VERSION" \
        "$MARKER_DRIVER_INF" "$EXPECTED_PATCHED_INF_SHA256")
else
    grep -Fqx 'QEMU_VGPU_PREPARED_V2' <<<"$MARKER_TEXT" \
        || die "guest completion marker has an unknown format"
    EXPECTED_MARKER_TEXT=$(printf \
        'QEMU_VGPU_PREPARED_V2\nVM_UUID=%s\nGPU_NAME=%s\nTOKEN_SHA256=%s' \
        "$EXPECTED_UUID" "$EXPECTED_GPU_NAME" "$EXPECTED_TOKEN_SHA256")
fi
[[ "$MARKER_TEXT" == "$EXPECTED_MARKER_TEXT" ]] \
    || die "guest completion marker has unexpected or duplicate fields"
unset EXPECTED_MARKER_TEXT
unset MARKER_TEXT
log "verified guest completion marker: $EXPECTED_VM / $EXPECTED_UUID / $EXPECTED_GPU_NAME"
if (( EXPECT_STRICT_DRIVER )); then
    log "verified strict consumer driver: $EXPECTED_DRIVER_PROFILE / $EXPECTED_DRIVER_VERSION / $MARKER_DRIVER_INF"
fi

mkdir -p "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"
backup="$BACKUP_DIR/SYSTEM.before-local-rtc-$(date -u +%Y%m%dT%H%M%SZ).hive"
install -m 0600 -- "$HIVE" "$backup"
log "backup: $backup"

# Normalize the regf header before hivex opens old Windows hives. The untouched
# original is already preserved above.
python3 - "$HIVE" <<'PY'
import struct
import sys

path = sys.argv[1]
hbin = 0x1000
data = bytearray(open(path, 'rb').read())
assert data[:4] == b'regf', 'not a Windows regf hive'
primary, secondary = struct.unpack_from('<I', data, 4)[0], struct.unpack_from('<I', data, 8)[0]
if primary != secondary:
    sequence = max(primary, secondary)
    struct.pack_into('<I', data, 4, sequence)
    struct.pack_into('<I', data, 8, sequence)
offset = hbin
last = hbin
while offset < len(data) and bytes(data[offset:offset + 4]) == b'hbin':
    size = struct.unpack_from('<I', data, offset + 8)[0]
    if size == 0 or offset + size > len(data):
        break
    last = offset + size
    offset += size
allocated_end = last - hbin
if struct.unpack_from('<I', data, 0x28)[0] > allocated_end:
    struct.pack_into('<I', data, 0x28, allocated_end)
checksum = 0
for index in range(0, 0x1fc, 4):
    checksum ^= struct.unpack_from('<I', data, index)[0]
struct.pack_into('<I', data, 0x1fc, checksum)
open(path, 'wb').write(data)
PY

HIVE="$HIVE" python3 - <<'PY'
import hivex
import os

hive_path = os.environ['HIVE']
hive = hivex.Hivex(hive_path, write=True)
root = hive.root()

def child(node, name):
    for candidate in hive.node_children(node):
        if hive.node_name(candidate).lower() == name.lower():
            return candidate
    return None

def walk(node, names):
    for name in names:
        node = child(node, name)
        if node is None:
            return None
    return node

deleted = 0
control_sets = [node for node in hive.node_children(root)
                if hive.node_name(node).lower().startswith('controlset')]
if not control_sets:
    raise RuntimeError('no ControlSetNNN keys found')

for control_set in control_sets:
    node = walk(control_set, ('Control', 'TimeZoneInformation'))
    if node is None:
        continue
    replacement = []
    removed_here = False
    for value in hive.node_values(node):
        key = hive.value_key(value)
        value_type, value_data = hive.value_value(value)
        if key.lower() == 'realtimeisuniversal':
            deleted += 1
            removed_here = True
            continue
        replacement.append({'key': key, 't': value_type, 'value': value_data})
    if removed_here:
        hive.node_set_values(node, replacement)
        print(f'[rtc-migrate] removed {hive.node_name(control_set)}\\Control\\TimeZoneInformation\\RealTimeIsUniversal')

if deleted:
    hive.commit(None)
del hive
print(f'[rtc-migrate] removed-values={deleted}; Windows now uses its default local-RTC interpretation')
PY

# Recompute the hive checksum after commit, then force all NTFS writes out.
python3 - "$HIVE" <<'PY'
import struct
import sys

path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
primary, secondary = struct.unpack_from('<I', data, 4)[0], struct.unpack_from('<I', data, 8)[0]
if primary != secondary:
    sequence = max(primary, secondary)
    struct.pack_into('<I', data, 4, sequence)
    struct.pack_into('<I', data, 8, sequence)
hbin = 0x1000
offset = hbin
last = hbin
while offset < len(data) and bytes(data[offset:offset + 4]) == b'hbin':
    size = struct.unpack_from('<I', data, offset + 8)[0]
    if size == 0 or offset + size > len(data):
        break
    last = offset + size
    offset += size
allocated_end = last - hbin
if struct.unpack_from('<I', data, 0x28)[0] > allocated_end:
    struct.pack_into('<I', data, 0x28, allocated_end)
checksum = 0
for index in range(0, 0x1fc, 4):
    checksum ^= struct.unpack_from('<I', data, index)[0]
struct.pack_into('<I', data, 0x1fc, checksum)
open(path, 'wb').write(data)
PY
sync

rm -f -- "$MARKER"
sync

umount "$MOUNT_POINT" || die "RTC migration was written, but NTFS could not be unmounted"
_RTC_MOUNTED=0
qemu-nbd --disconnect "$_NBD_DEV" >/dev/null || die "NBD could not be disconnected"
_NBD_CONNECTED=0
log "complete: next boot must use TZ=Asia/Shanghai + base=localtime"

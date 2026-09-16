#!/usr/bin/env bash
# Guard the native-console cadence override used before QEMU opens mdev.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MDEV_LIB="$REPO_ROOT/deploy/lib/vgpu-mdev.sh"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bash -n "$MDEV_LIB" "$START_VM"
grep -Fq 'mdev_configure_console_interval' "$MDEV_LIB" \
    || fail "R535 console interval helper is missing"
grep -Fq 'intervaltime=${interval_us},vgaintervaltime=${interval_us}' \
    "$MDEV_LIB" \
    || fail "both NVIDIA console-copy intervals must be configured together"
grep -Fq 'driver_version" != 535.*' "$MDEV_LIB" \
    || fail "undocumented console parameters lost their R535 version guard"
grep -Fq 'driver_version" != 570.172.07' "$MDEV_LIB" \
    || fail "R570 console parameters lost their exact vendor version guard"
grep -Fq 'VGPU_CONSOLE_INTERVAL_US="${VGPU_CONSOLE_INTERVAL_US:-8333}"' \
    "$START_VM" \
    || fail "native console no longer defaults to an approximately 120Hz copy period"
grep -Fq '"$MDEV_UUID" "$VGPU_CONSOLE_INTERVAL_US"' "$START_VM" \
    || fail "start-vm no longer configures the mdev before QEMU launch"
grep -Fq 'MDEV_RECOVERY_FILE=$(vm_storage_run_preferred_path "$VM_ID" mdev)' "$START_VM" \
    || fail "newly allocated mdev has no pre-configuration recovery record"
grep -Fq 'trap cleanup_allocated_mdev EXIT' "$START_VM" \
    || fail "newly allocated mdev is not protected during parameter setup"
grep -Fq 'MDEV_ALLOCATION_STATE=pending-new' "$START_VM" \
    || fail "new UUID allocation has no pending-new cleanup state"
grep -Fq 'MDEV_ALLOCATION_STATE=pending-existing' "$START_VM" \
    || fail "pre-existing UUID allocation has no non-owning pending state"
grep -Fq 'MDEV_ALLOCATION_STATE=active' "$START_VM" \
    || fail "successful allocation is not promoted to active cleanup state"
grep -Fq 'mdev_cleanup_allocation_state "$MDEV_ALLOCATION_STATE"' "$START_VM" \
    || fail "start-vm does not delegate cleanup to the tested ownership state machine"
grep -Fq 'declare -F cleanup_native_mdev' "$START_VM" \
    || fail "RDP fail-closed cleanup does not retry its exact mdev allocation guard"
grep -Fq '_mdev_release_locked "$uuid"' "$MDEV_LIB" \
    || fail "signal cleanup cannot reuse an allocator-held host lock"
trap_line=$(grep -nF 'trap cleanup_allocated_mdev EXIT' "$START_VM" |
    head -1 | cut -d: -f1)
allocate_line=$(grep -nF 'mdev_allocate "${VGPU_RESOURCE_PROFILE}"' "$START_VM" |
    head -1 | cut -d: -f1)
record_line=$(grep -nF 'MDEV_RECOVERY_FILE=$(vm_storage_run_preferred_path "$VM_ID" mdev)' \
    "$START_VM" | head -1 | cut -d: -f1)
active_line=$(grep -nF 'MDEV_ALLOCATION_STATE=active' "$START_VM" |
    head -1 | cut -d: -f1)
[[ "$trap_line" =~ ^[0-9]+$ && "$allocate_line" =~ ^[0-9]+$ &&
   "$record_line" =~ ^[0-9]+$ && "$active_line" =~ ^[0-9]+$ &&
   "$trap_line" -lt "$record_line" && "$record_line" -lt "$allocate_line" &&
   "$allocate_line" -lt "$active_line" ]] \
    || fail "new mdev recovery must be recorded before allocation, then promoted"
if grep -Fq 'disable_vnc=1' "$MDEV_LIB" "$START_VM"; then
    fail "disable_vnc would remove the console REGION required by native SDL"
fi

# Exercise the helper without touching real sysfs or sudo.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
UUID=12345678-1234-1234-1234-123456789abc
mkdir -p "$TMP_DIR/target/nvidia" "$TMP_DIR/devices"
touch "$TMP_DIR/target/nvidia/vgpu_params"
ln -s "$TMP_DIR/target" "$TMP_DIR/devices/$UUID"
printf '%s\n' 535.161.05 >"$TMP_DIR/nvidia-version"
MDEV_DEVICES_DIR="$TMP_DIR/devices"
NVIDIA_MODULE_VERSION_FILE="$TMP_DIR/nvidia-version"
# shellcheck source=../../../lib/vgpu-mdev.sh
source "$MDEV_LIB"

WRITE_CONTENT=""
WRITE_PATH=""
_mdev_sudo_write() {
    WRITE_CONTENT=$1
    WRITE_PATH=$2
}
mdev_configure_console_interval "$UUID" 16667 2>/dev/null
[[ "$WRITE_CONTENT" == 'intervaltime=16667,vgaintervaltime=16667' ]] \
    || fail "helper did not write both R535 console intervals"
[[ "$WRITE_PATH" == "$TMP_DIR/target/nvidia/vgpu_params" ||
   "$WRITE_PATH" == "$TMP_DIR/devices/$UUID/nvidia/vgpu_params" ]] \
    || fail "helper wrote an unexpected parameter path"

for invalid in 019000 4999 1000001 not-a-number; do
    if mdev_configure_console_interval "$UUID" "$invalid" 2>/dev/null; then
        fail "invalid interval was accepted: $invalid"
    fi
done
if mdev_configure_console_interval bad-uuid 16667 2>/dev/null; then
    fail "invalid UUID was accepted"
fi

printf '%s\n' 570.172.07 >"$TMP_DIR/nvidia-version"
WRITE_CONTENT=""
mdev_configure_console_interval "$UUID" 8333 0 2>"$TMP_DIR/r570.log"
[[ "$WRITE_CONTENT" == \
   'intervaltime=8333,vgaintervaltime=8333,frame_rate_limiter=0' ]] \
    || fail "exact R570 did not receive both intervals and the FRL override"
grep -Fq '静态审核' "$TMP_DIR/r570.log" \
    || fail "R570 static audit was presented as host validation"

for interval in 5000 1000000; do
    mdev_configure_console_interval "$UUID" "$interval" 1 2>/dev/null
    [[ "$WRITE_CONTENT" == \
       "intervaltime=$interval,vgaintervaltime=$interval,frame_rate_limiter=1" ]] \
        || fail "R570 rejected an interval boundary or FRL=1"
done
for invalid in 019000 4999 1000001 not-a-number; do
    if mdev_configure_console_interval "$UUID" "$invalid" 2>/dev/null; then
        fail "R570 accepted invalid interval: $invalid"
    fi
done
if mdev_configure_console_interval "$UUID" 8333 2 2>/dev/null; then
    fail "R570 accepted an invalid FRL value"
fi
WRITE_CONTENT=""
mdev_configure_console_interval "$UUID" 0 0 2>/dev/null
[[ -z "$WRITE_CONTENT" ]] || fail "interval=0 did not remain a no-op"

for version in 550.1 570.133.10 570.172.070 570.172.08 580.159.01 unknown; do
    printf '%s\n' "$version" >"$TMP_DIR/nvidia-version"
    WRITE_CONTENT=""
    VGPU_CONSOLE_INTERVAL_FORCE=0 \
        mdev_configure_console_interval "$UUID" 8333 0 2>/dev/null
    [[ -z "$WRITE_CONTENT" ]] \
        || fail "unreviewed driver was configured: $version"
done

_mdev_sudo_write() { return 1; }
for version in 535.161.05 570.172.07; do
    printf '%s\n' "$version" >"$TMP_DIR/nvidia-version"
    if mdev_configure_console_interval "$UUID" 8333 0 2>/dev/null; then
        fail "sysfs write failure was not propagated for $version"
    fi
done

rm -rf -- "$TMP_DIR"

echo "OK: R535 and exact R570 vGPU console interval mock checks passed"

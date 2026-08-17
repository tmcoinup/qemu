#!/usr/bin/env bash
# Guard the R535 native-console cadence override used before QEMU opens mdev.
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
grep -Fq 'VGPU_CONSOLE_INTERVAL_US="${VGPU_CONSOLE_INTERVAL_US:-16667}"' \
    "$START_VM" \
    || fail "native console no longer defaults to an approximately 60Hz copy period"
grep -Fq '"$MDEV_UUID" "$VGPU_CONSOLE_INTERVAL_US"' "$START_VM" \
    || fail "start-vm no longer configures the mdev before QEMU launch"
grep -Fq 'MDEV_RECOVERY_FILE=$(vm_storage_run_preferred_path "$VM_ID" mdev)' "$START_VM" \
    || fail "newly allocated mdev has no pre-configuration recovery record"
grep -Fq 'trap cleanup_allocated_mdev EXIT' "$START_VM" \
    || fail "newly allocated mdev is not protected during parameter setup"
if grep -Fq 'disable_vnc=1' "$MDEV_LIB" "$START_VM"; then
    fail "disable_vnc would remove the console REGION required by native SDL"
fi

# Exercise the helper without touching real sysfs or sudo.
TMP_DIR="$(mktemp -d)"
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

printf '%s\n' 550.1 >"$TMP_DIR/nvidia-version"
WRITE_CONTENT=""
mdev_configure_console_interval "$UUID" 16667 2>/dev/null
[[ -z "$WRITE_CONTENT" ]] \
    || fail "unverified non-R535 driver was configured without FORCE"

printf '%s\n' 535.161.05 >"$TMP_DIR/nvidia-version"
_mdev_sudo_write() { return 1; }
if mdev_configure_console_interval "$UUID" 16667 2>/dev/null; then
    fail "sysfs write failure was not propagated"
fi

rm -rf -- "$TMP_DIR"

echo "OK: R535 vGPU console interval static checks passed"

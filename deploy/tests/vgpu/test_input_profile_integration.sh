#!/usr/bin/env bash
# End-to-end regression for the active relative-mouse contract.  Everything is
# created below a temporary VM_ROOT and start-vm is dry-run only: no QEMU, mdev,
# TPM, monitor or host-network state may be touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CREATE_VM="$REPO_ROOT/deploy/scripts/create-vm.sh"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 label=$3

    [[ "$actual" == "$expected" ]] ||
        fail "$label: expected '$expected', got '$actual'"
}

require_text() {
    local needle=$1 file=$2 label=${3:-$1}

    grep -F -- "$needle" "$file" >/dev/null ||
        fail "$label missing from $(basename "$file")"
}

reject_text() {
    local needle=$1 file=$2 label=${3:-$1}

    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "$label unexpectedly present in $(basename "$file")"
    fi
}

require_config_assignment() {
    local assignment=$1 count

    count=$(grep -Fxc -- "$assignment" "$CONF" || true)
    assert_eq 1 "$count" "config assignment $assignment"
}

TMP_DIR="$(mktemp -d)"
IMAGE_ROOT="$TMP_DIR/images"
VM_ROOT="$TMP_DIR/vms"
VM_ID=61
CONF="$VM_ROOT/$VM_ID/vm.conf"
CREATE_OUT="$TMP_DIR/create.out"
CREATE_ERR="$TMP_DIR/create.err"
START_OUT="$TMP_DIR/start.out"
START_ERR="$TMP_DIR/start.err"
VGPU_HOST_CONFIG="$TMP_DIR/vgpu-host.conf"

cleanup() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

[[ -x "$CREATE_VM" ]] || fail "create-vm.sh is missing or not executable"
[[ -x "$START_VM" ]] || fail "start-vm.sh is missing or not executable"

touch "$TMP_DIR/OVMF_CODE.fd" "$TMP_DIR/OVMF_VARS.fd" \
    "$VGPU_HOST_CONFIG"

# --no-gpu dry-run must never execute QEMU.  Keep an executable sentinel so a
# launcher regression fails loudly instead of probing or starting host QEMU.
cat >"$TMP_DIR/qemu-system-x86_64" <<'EOF'
#!/bin/sh
echo "unexpected QEMU invocation: $*" >&2
exit 99
EOF
chmod +x "$TMP_DIR/qemu-system-x86_64"

env -i \
    HOME="${HOME:-/tmp}" \
    PATH=/usr/bin:/bin \
    LANG=C.UTF-8 \
    IMAGE_ROOT="$IMAGE_ROOT" \
    VM_ROOT="$VM_ROOT" \
    "$CREATE_VM" "$VM_ID" \
    --platform g3220-h81m-k-4g \
    --ssd-profile crucial-mx100-512gb \
    --gpu-profile gtx1050_2gb \
    --monitor-profile lenovo-d24-20 \
    --keyboard-profile dell-sk-8115 \
    --relative-mouse --mouse-profile dell-ms116 \
    >"$CREATE_OUT" 2>"$CREATE_ERR"

[[ -f "$CONF" ]] || fail "create-vm did not create $CONF"

# The persisted input-v2 contract is intentionally checked as complete literal
# assignments.  Loading a profile key alone is insufficient: every descriptor
# fact consumed by start-vm must be immutable in vm.conf.
for assignment in \
        'INPUT_COMPONENT_CONTRACT_VERSION=2' \
        'INPUT_PROFILE_CATALOG_REVISION=2026-08-03.1' \
        'POINTER_MODE=relative' \
        'KBD_PROFILE=dell-sk-8115' \
        'KBD_BRAND="Dell"' \
        'KBD_MODEL="SK-8115"' \
        'KBD_VID=0x413C' \
        'KBD_PID=0x2003' \
        'KBD_BCD_DEVICE=0x0301' \
        'KBD_USB_VERSION=1' \
        'KBD_MFR="Dell"' \
        'KBD_PRODUCT="Dell USB Keyboard"' \
        'KBD_SERIAL_POLICY=none' \
        'KBD_FIDELITY=identity_only_generic_report' \
        'MOUSE_PROFILE=dell-ms116' \
        'MOUSE_BRAND="Dell"' \
        'MOUSE_MODEL="MS116"' \
        'MOUSE_VID=0x413C' \
        'MOUSE_PID=0x301A' \
        'MOUSE_BCD_DEVICE=0x0100' \
        'MOUSE_USB_VERSION=2' \
        'MOUSE_MFR="PixArt"' \
        'MOUSE_PRODUCT="Dell MS116 USB Optical Mouse"' \
        'MOUSE_SERIAL_POLICY=none' \
        'MOUSE_FIDELITY=identity_only_generic_report'; do
    require_config_assignment "$assignment"
done

if grep -Eq '^(POINTER_(PROFILE|BRAND|MODEL|VID|PID|BCD_DEVICE|USB_VERSION|MFR|PRODUCT|SERIAL_POLICY|FIDELITY)|TABLET_[A-Z0-9_]+)=' \
        "$CONF"; then
    fail "relative-mouse config also persisted an absolute-pointer contract"
fi

require_text \
    '相对鼠标: Dell MS116（usb-mouse，USB 413C:301A，SN=none，identity_only_generic_report）' \
    "$CREATE_OUT" "create-vm relative-mouse summary"

env -i \
    HOME="${HOME:-/tmp}" \
    PATH=/usr/bin:/bin \
    LANG=C.UTF-8 \
    IMAGE_ROOT="$IMAGE_ROOT" \
    VM_ROOT="$VM_ROOT" \
    QEMU_BIN="$TMP_DIR/qemu-system-x86_64" \
    OVMF_CODE="$TMP_DIR/OVMF_CODE.fd" \
    OVMF_VARS="$TMP_DIR/OVMF_VARS.fd" \
    VGPU_HOST_CONFIG="$VGPU_HOST_CONFIG" \
    TPM=0 \
    CPU_ISOLATION=off \
    MONITOR_SYNC=0 \
    MEM_GUARD=0 \
    REPAIR_DISPLAY_VARS=off \
    "$START_VM" "$VM_ID" --dry-run --no-gpu --no-tpm \
    --no-monitor-sync --no-cpu-isolate \
    >"$START_OUT" 2>"$START_ERR"

require_text \
    '相对鼠标: Dell MS116 / usb-mouse / USB 413C:301A / SN=none / identity_only_generic_report' \
    "$START_OUT" "start-vm relative-mouse summary"
require_text \
    'usb-mouse\,bus=xhci.0\,usb_version=2\,vendorid=0x413C\,productid=0x301A\,bcd-device=0x0100\,manufacturer=PixArt\,product=Dell\ MS116\ USB\ Optical\ Mouse' \
    "$START_OUT" "Dell MS116 QEMU argv"
reject_text 'usb-tablet\,' "$START_OUT" "absolute usb-tablet QEMU argv"
reject_text '  绝对指针:' "$START_OUT" "absolute-pointer runtime summary"

mouse_count=$(grep -Fc -- 'usb-mouse\,' "$START_OUT" || true)
assert_eq 1 "$mouse_count" "QEMU usb-mouse device count"
mouse_argv=$(grep -F -- 'usb-mouse\,' "$START_OUT" || true)
[[ "$mouse_argv" != *serial=* ]] ||
    fail "usb-mouse QEMU argv invented a serial descriptor"

keyboard_argv=$(grep -F -- 'usb-kbd\,' "$START_OUT" || true)
[[ -n "$keyboard_argv" ]] || fail "QEMU usb-kbd device is missing"
[[ "$keyboard_argv" == *'id=kbd0'* ]] ||
    fail "QEMU usb-kbd lacks the stable kbd0 diagnostic id"
[[ "$keyboard_argv" == *'x-force-numlock-on=on'* ]] ||
    fail "QEMU usb-kbd does not enable guest-LED NumLock convergence"
[[ "$keyboard_argv" != *serial=* ]] ||
    fail "usb-kbd QEMU argv invented a serial descriptor"

echo "PASS: create-vm input v2 relative Dell MS116 -> serial-free usb-mouse dry-run"

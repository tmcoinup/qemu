#!/usr/bin/env bash
# Guard the G-11 Windows USB controller behavior identity.
#
# USBXHCI.SYS selects hardware workarounds from the PCI identity.  qemu-xhci
# must therefore keep the complete upstream identity instead of advertising a
# physical Intel PCH tuple that its virtual register model does not implement.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
QEMU="$BUILD_DIR/qemu-system-x86_64"
XHCI_C="$REPO_ROOT/hw/usb/hcd-xhci-pci.c"
XHCI_H="$REPO_ROOT/hw/usb/hcd-xhci-pci.h"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

reject_pattern() {
    local pattern=$1 message=$2 output status
    shift 2
    set +e
    output="$(rg -n -U "$pattern" "$@" 2>&1)"
    status=$?
    set -e
    case "$status" in
        0) printf '%s\n' "$output"; fail "$message" ;;
        1) return 0 ;;
        *) printf '%s\n' "$output" >&2; fail "rg scan failed" ;;
    esac
}

grep -E 'k->vendor_id[[:space:]]*=[[:space:]]*PCI_VENDOR_ID_REDHAT;' \
    "$XHCI_C" >/dev/null || fail "qemu-xhci vendor ID is not upstream"
grep -E 'k->device_id[[:space:]]*=[[:space:]]*PCI_DEVICE_ID_REDHAT_XHCI;' \
    "$XHCI_C" >/dev/null || fail "qemu-xhci device ID is not upstream"
grep -E 'k->revision[[:space:]]*=[[:space:]]*0x01;' \
    "$XHCI_C" >/dev/null || fail "qemu-xhci revision is not upstream"
grep -F 'k->subsystem_vendor_id = PCI_SUBVENDOR_ID_REDHAT_QUMRANET;' \
    "$XHCI_C" >/dev/null || fail "qemu-xhci subsystem vendor is not fixed"
grep -F 'k->subsystem_id        = PCI_SUBDEVICE_ID_QEMU;' \
    "$XHCI_C" >/dev/null || fail "qemu-xhci subsystem device is not fixed"

reject_pattern \
    'stealth_(vendor|device|revision)|DEFINE_PROP_UINT32\("x-pci-' \
    "qemu-xhci still exposes behavior-related PCI ID overrides" \
    "$XHCI_C" "$XHCI_H"
reject_pattern \
    'qemu-xhci[^\n]*(x-pci-vendor-id|x-pci-device-id|x-pci-revision)' \
    "G-11 launcher still projects physical PCI facts onto qemu-xhci" \
    "$START_VM"
grep -F -- \
    '-device "qemu-xhci,id=xhci,bus=${XHCI_PCI_BUS},addr=${XHCI_PCI_ADDR}"' \
    "$START_VM" >/dev/null || fail "G-11 launcher does not use fixed qemu-xhci"

[[ -x "$QEMU" ]] || fail "missing built QEMU: $QEMU"
help="$($QEMU -device qemu-xhci,help 2>&1)"
if grep -E 'x-pci-(vendor-id|device-id|revision)=' <<<"$help" >/dev/null; then
    fail "built qemu-xhci still exposes dangerous PCI ID override properties"
fi

# The launcher globally supplies the selected board's PCI subsystem defaults.
# Query config space with a non-upstream default and verify qemu-xhci pins all
# four identity fields to the upstream behavior contract.
python3 - "$QEMU" <<'PY'
import json
import os
import subprocess
import sys

qemu = sys.argv[1]
environment = os.environ.copy()
environment["QEMU_PCI_SUBVENDOR_ID"] = "0x1458"
environment["QEMU_PCI_SUBDEVICE_ID"] = "0x5001"
request = "\n".join([
    '{"execute":"qmp_capabilities"}',
    '{"execute":"query-pci"}',
    '{"execute":"quit"}',
    "",
])
result = subprocess.run(
    [
        qemu, "-machine", "q35,accel=tcg", "-display", "none",
        "-nodefaults", "-S", "-device",
        "qemu-xhci,id=xhci,bus=pcie.0,addr=0x6", "-qmp", "stdio",
    ],
    input=request,
    text=True,
    capture_output=True,
    timeout=15,
    check=False,
    env=environment,
)
if result.returncode != 0:
    raise SystemExit(f"qemu-xhci QMP launch failed:\n{result.stderr}")

responses = []
for line in result.stdout.splitlines():
    try:
        responses.append(json.loads(line))
    except json.JSONDecodeError:
        continue
pci_reply = next(
    item["return"] for item in responses
    if isinstance(item.get("return"), list)
)
identity = next(
    device["id"]
    for bus in pci_reply
    for device in bus["devices"]
    if device.get("qdev_id") == "xhci"
)
actual = (
    identity["vendor"],
    identity["device"],
    identity["subsystem-vendor"],
    identity["subsystem"],
)
expected = (0x1B36, 0x000D, 0x1AF4, 0x1100)
if actual != expected:
    raise SystemExit(f"unsafe qemu-xhci PCI identity: {actual!r} != {expected!r}")
PY

echo "OK: qemu-xhci behavior identity is fixed to 1B36:000D / SUBSYS 1AF4:1100"

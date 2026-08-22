#!/usr/bin/env bash
# Static contract for the explicit USB HID 1 ms polling trade-off.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
USB_HID="$REPO_ROOT/hw/usb/dev-hid.c"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bash -n "$START_VM" || fail "start-vm.sh syntax is invalid"

grep -F 'G11_USB_HID_LOW_LATENCY="${G11_USB_HID_LOW_LATENCY:-0}"' \
    "$START_VM" >/dev/null || fail "launcher low-latency mode is not default-off"
grep -F -- '--low-latency-input) G11_USB_HID_LOW_LATENCY=1' \
    "$START_VM" >/dev/null || fail "missing explicit enable switch"
grep -F -- '--no-low-latency-input) G11_USB_HID_LOW_LATENCY=0' \
    "$START_VM" >/dev/null || fail "missing explicit rollback switch"
grep -F "HID_LOW_LATENCY_PROP=',x-low-latency=on'" \
    "$START_VM" >/dev/null || fail "launcher does not pass the QEMU opt-in"

keyboard_line=$(grep -F -- '-device "usb-kbd,id=kbd0' "$START_VM")
mouse_line=$(grep -F -- '-device "usb-mouse,bus=xhci.0' "$START_VM")
tablet_line=$(grep -F -- '-device "usb-tablet,bus=xhci.0' "$START_VM")
[[ "$keyboard_line" == *'${HID_LOW_LATENCY_PROP}'* ]] ||
    fail "usb-kbd is not wired to the opt-in"
[[ "$mouse_line" == *'${HID_LOW_LATENCY_PROP}'* ]] ||
    fail "usb-mouse is not wired to the opt-in"
[[ "$tablet_line" != *'${HID_LOW_LATENCY_PROP}'* ]] ||
    fail "already-1ms high-speed usb-tablet must not gain a fingerprint-only flag"

[[ "$(grep -Fc 'DEFINE_PROP_BOOL("x-low-latency"' "$USB_HID")" -eq 2 ]] ||
    fail "x-low-latency must be exposed only by usb-kbd and usb-mouse"
[[ "$(grep -Fc '.bInterval             = 0x0a,' "$USB_HID")" -eq 3 ]] ||
    fail "default full-speed endpoint intervals changed"
[[ "$(grep -Fc '.bInterval             = 7,' "$USB_HID")" -eq 2 ]] ||
    fail "default high-speed keyboard/mouse intervals changed"
grep -F 'source->full, &us->low_latency_desc.full, 1,' \
    "$USB_HID" >/dev/null || fail "full-speed 1ms encoding is missing"
grep -F 'source->high, &us->low_latency_desc.high, 4,' \
    "$USB_HID" >/dev/null || fail "high-speed 1ms encoding is missing"
grep -F '.name = "usb-kbd/low-latency"' "$USB_HID" >/dev/null ||
    fail "keyboard migration compatibility marker is missing"
grep -F '.name = "usb-ptr/low-latency"' "$USB_HID" >/dev/null ||
    fail "pointer migration compatibility marker is missing"

echo "PASS: USB HID low latency remains explicit, reversible, and fingerprint-safe by default"

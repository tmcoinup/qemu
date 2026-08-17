#!/usr/bin/env bash
# Static contract for G-11's guest-LED-driven, idempotent NumLock wrapper.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
USB_HID="$REPO_ROOT/hw/usb/dev-hid.c"
UNATTEND="$REPO_ROOT/deploy/autounattend/autounattend.xml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -F -- '--numlock) GUEST_NUMLOCK=1' "$START_VM" >/dev/null ||
    fail "missing --numlock switch"
grep -F -- '--no-numlock) GUEST_NUMLOCK=0' "$START_VM" >/dev/null ||
    fail "missing --no-numlock switch"
grep -F 'GUEST_NUMLOCK="${GUEST_NUMLOCK:-1}"' "$START_VM" >/dev/null ||
    fail "NumLock is not enabled by default"
grep -F "KBD_NUMLOCK_PROP=',x-force-numlock-on=on'" "$START_VM" >/dev/null ||
    fail "usb-kbd argv does not enable the QEMU state machine"
grep -F 'usb-kbd,id=kbd0' "$START_VM" >/dev/null ||
    fail "usb-kbd lacks a stable QOM diagnostic id"
grep -F 'x-numlock-on-confirmed=<bool>' "$START_VM" >/dev/null ||
    fail "launcher does not reject an obsolete QEMU implementation"
grep -F 'DEFINE_PROP_BOOL("x-force-numlock-on"' "$USB_HID" >/dev/null ||
    fail "usb-kbd opt-in property is missing"
grep -F 'qemu_bh_new_guarded' "$USB_HID" >/dev/null ||
    fail "key injection is not deferred with a guarded BH"

if grep -q 'InitialKeyboardIndicators' "$UNATTEND"; then
    fail "obsolete per-user NumLock registry workaround remains"
fi

echo "PASS: G-11 guest-LED NumLock launcher contract"

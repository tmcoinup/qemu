#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_file="$repo_root/hw/usb/dev-hid.c"
qemu_bin="${QEMU_BIN:-$repo_root/build/qemu-system-x86_64}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -x "$qemu_bin" ]] || fail "QEMU binary is missing: $qemu_bin"

for device in usb-kbd usb-mouse usb-tablet; do
    help=$($qemu_bin -device "$device,help")
    grep -Fq 'bcd-device=<uint32>' <<<"$help" ||
        fail "$device does not expose per-instance bcdDevice"
    grep -Fq 'usb_version=<uint32>' <<<"$help" ||
        fail "$device does not expose an explicit USB version"
done

# The default absolute pointer must remain the honest QEMU generic device.
# Branded pen tablets stay in the shell compatibility catalog only.
grep -Fq '.idVendor          = 0x0627' "$source_file" ||
    fail 'generic absolute-pointer VID is missing'
grep -Fq '.idProduct         = 0x0001' "$source_file" ||
    fail 'generic absolute-pointer PID is missing'
grep -Fq '[STR_PRODUCT_TABLET]       = "QEMU USB Tablet"' "$source_file" ||
    fail 'generic absolute-pointer product string is missing'
grep -Fq 'uc->product_desc   = "QEMU USB Tablet"' "$source_file" ||
    fail 'usb-tablet class description is still branded'

# Every current HID descriptor intentionally has iSerialNumber=0.  Three
# device kinds each have USB1/USB2 descriptors, so exactly six definitions are
# expected and no launcher should ever add a serial property.
serial_none_count=$(grep -Fc '.iSerialNumber     = 0' "$source_file")
[[ "$serial_none_count" == 6 ]] ||
    fail "expected six HID iSerialNumber=0 descriptors, got $serial_none_count"

# QOM must accept all reviewed bcd values, including the intentional generic
# 0x0000 sentinel, while rejecting values outside the 16-bit descriptor field.
for spec in \
    'usb-kbd,bus=xhci.0,bcd-device=0x0110' \
    'usb-mouse,bus=xhci.0,bcd-device=0x7200' \
    'usb-tablet,bus=xhci.0,bcd-device=0x0000'; do
    timeout 5 "$qemu_bin" -machine q35,accel=tcg -nodefaults -display none \
        -monitor none -serial none -S -device qemu-xhci,id=xhci \
        -device "$spec" -qmp stdio <<'EOF' >/dev/null
{"execute":"qmp_capabilities"}
{"execute":"quit"}
EOF
done

if timeout 5 "$qemu_bin" -machine q35,accel=tcg -nodefaults -display none \
        -monitor none -serial none -S -device qemu-xhci,id=xhci \
        -device 'usb-kbd,bus=xhci.0,bcd-device=0x10000' \
        -qmp stdio <<'EOF' >/dev/null 2>&1; then
{"execute":"qmp_capabilities"}
{"execute":"quit"}
EOF
    fail 'usb-kbd accepted a bcdDevice wider than 16 bits'
fi

echo 'PASS: USB HID bcdDevice is profile-bound, generic tablet is honest, and all HID serials remain absent'

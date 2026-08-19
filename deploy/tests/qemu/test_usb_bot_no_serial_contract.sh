#!/usr/bin/env bash
# Contract guard: usb-bot serial="" is a real no-serial USB descriptor, not
# a nonzero string index backed by an invalid empty descriptor.
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_file="$root/hw/usb/dev-storage-bot.c"
classic_source="$root/hw/usb/dev-storage-classic.c"
scsi_source="$root/hw/scsi/scsi-bus.c"
state_header="$root/include/hw/usb/msd.h"

fail() { echo "FAIL: $*" >&2; exit 1; }

grep -Fq "dev->serial[0] == '\\0'" "$source_file" ||
    fail 'usb-bot does not distinguish an explicit empty serial'
grep -Fq 's->patched_desc->id.iSerialNumber = 0;' "$source_file" ||
    fail 'usb-bot does not encode no-serial as iSerialNumber=0'
grep -Fq 'DEFINE_PROP_BOOL("x-no-serial", MSDState, no_serial, false)' \
    "$source_file" || fail 'usb-bot does not expose the no-serial capability'
for property in vendorid productid bcd-device manufacturer product; do
    grep -Fq "\"$property\"" "$source_file" ||
        fail "usb-bot does not expose USB identity property: $property"
done
for property in x-no-serial vendorid productid bcd-device manufacturer product \
                scsi-vendor scsi-product scsi-version; do
    grep -Fq "\"$property\"" "$classic_source" ||
        fail "usb-storage does not expose hardware identity property: $property"
done
for property in vendor product ver; do
    grep -Fq "qdev_prop_set_string(dev, \"$property\"" "$scsi_source" ||
        fail "legacy SCSI creation does not project $property before realize"
done
grep -Fq 'usb_desc_set_string(dev, dev->usb_desc->id.iManufacturer,' \
    "$source_file" || fail 'usb-bot does not project its manufacturer string'
grep -Fq 'usb_desc_set_string(dev, dev->usb_desc->id.iProduct, s->product);' \
    "$source_file" || fail 'usb-bot does not project its product string'
grep -Fq 'g_clear_pointer(&s->patched_desc, g_free);' "$source_file" ||
    fail 'usb-bot does not release its per-instance descriptor'
grep -Fq 'USBDesc *patched_desc;' "$state_header" ||
    fail 'USB mass-storage state has no descriptor ownership slot'

echo 'PASS: USB storage supports no-serial and per-instance hardware identity'

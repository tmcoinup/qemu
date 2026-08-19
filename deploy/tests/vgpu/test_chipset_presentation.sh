#!/usr/bin/env bash
# Audit all current platform rows and the narrow QEMU LPC presentation hook.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
profiles="$root/deploy/lib/hardware-profiles.sh"
start_vm="$root/deploy/scripts/start-vm.sh"
lpc_source="$root/hw/isa/lpc_ich9.c"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    grep -F -- "$1" "$2" >/dev/null || fail "missing '$1' in ${2#$root/}"
}

# shellcheck source=/dev/null
source "$profiles"
hardware_profile_validate_catalog

declare -A expected=(
    [H81]='H81|H81|0x8086|0x8C5C|0x04'
    [H97]='H97|H97|0x8086|0x8CC6|0x00'
    [B150]='B150|B150|0x8086|0xA148|0x31'
    [B360]='B360|B360|0x8086|0xA308|0x10'
)

count=0
for row in "${HARDWARE_COMBINATIONS[@]}"; do
    IFS='|' read -r platform _ _ _ _ <<<"$row"
    hardware_profile_load "$platform"
    actual=$(hardware_chipset_identity_for_platform "$platform")
    [[ "$actual" == "${expected[$BOARD_CHIPSET]}" ]] ||
        fail "$platform maps $BOARD_CHIPSET to $actual"
    count=$((count + 1))
done
[[ "$count" == 264 ]] || fail "expected 264 platform rows, got $count"

require_text 'DEFINE_PROP_STRING("x-g11-chipset"' "$lpc_source"
for mapping in \
        '{ "H81",  0x8c5c, 0x04 }' \
        '{ "H97",  0x8cc6, 0x00 }' \
        '{ "B150", 0xa148, 0x31 }' \
        '{ "B360", 0xa308, 0x10 }'; do
    require_text "$mapping" "$lpc_source"
done
require_text 'ICH9-LPC.x-g11-chipset=${CHIPSET_QEMU_PRESENTATION_KEY}' \
    "$start_vm"
require_text 'G11_CHIPSET_PRESENTATION 必须是 catalog 或 off' "$start_vm"
if grep -Eq 'ICH9-(AHCI|SMB).*x-g11-chipset|qemu-xhci.*x-g11-chipset' \
        "$start_vm" "$lpc_source"; then
    fail 'chipset presentation leaked into AHCI/SMBus/xHCI identities'
fi

qemu="$root/build/qemu-system-x86_64"
if [[ -x "$qemu" ]]; then
    "$qemu" -device ICH9-LPC,help 2>&1 |
        grep -Eq '^  x-g11-chipset=<(str|string)>' ||
        fail 'built QEMU lacks x-g11-chipset'
    if "$qemu" -M q35 -global ICH9-LPC.x-g11-chipset=Z99 \
            -display none -nodefaults -S >/dev/null 2>&1; then
        fail 'QEMU accepted an unreviewed chipset value'
    fi
fi

echo 'PASS: all 264 G-11 platforms map to the four reviewed LPC identities'

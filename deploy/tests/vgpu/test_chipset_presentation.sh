#!/usr/bin/env bash
# Audit all current platform rows and the narrow QEMU LPC/CPU-DMI2 presentation
# hooks.  VM3 is only a live acceptance target; no assertion is VM-ID-specific.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
profiles="$root/deploy/lib/hardware-profiles.sh"
start_vm="$root/deploy/scripts/start-vm.sh"
lpc_source="$root/hw/isa/lpc_ich9.c"
mch_source="$root/hw/pci-host/q35.c"
ovmf_build="$root/deploy/host/build-stealth-ovmf.sh"
ovmf_patch="$root/deploy/host/ovmf-g11-host-bridge-handoff.patch"
ovmf_image="$root/deploy/host/OVMF_CODE_4M_stealth.fd"
ovmf_features="${ovmf_image}.features"

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
    [X79]='X79|X79|0x8086|0x1D41|0x06'
)

count=0
host_count=0
for row in "${HARDWARE_COMBINATIONS[@]}"; do
    IFS='|' read -r platform _ _ _ _ <<<"$row"
    hardware_profile_load "$platform"
    actual=$(hardware_chipset_identity_for_platform "$platform")
    [[ "$actual" == "${expected[$BOARD_CHIPSET]}" ]] ||
        fail "$platform maps $BOARD_CHIPSET to $actual"
    if [[ "$BOARD_CHIPSET" == X79 ]]; then
        case "$CPU_PROFILE" in
            i7-3820|i7-3930k)
                expected_host='SandyBridge-E|0x8086|0x3C00|0x07'
                ;;
            i7-4820k|i7-4930k|i7-4960x)
                expected_host='IvyBridge-E|0x8086|0x0E00|0x04'
                ;;
            *)
                fail "$platform has an unreviewed X79 CPU: $CPU_PROFILE"
                ;;
        esac
        actual_host=$(hardware_cpu_host_bridge_identity_for_platform "$platform")
        [[ "$actual_host" == "$expected_host" ]] ||
            fail "$platform maps $CPU_PROFILE host bridge to $actual_host"
        host_count=$((host_count + 1))
    elif hardware_cpu_host_bridge_identity_for_platform "$platform" \
            >/dev/null 2>&1; then
        fail "$platform unexpectedly enables the X79 CPU host bridge hook"
    fi
    count=$((count + 1))
done
[[ "$count" == 524 ]] || fail "expected 524 platform rows, got $count"
[[ "$host_count" == 260 ]] || fail "expected 260 X79 host-bridge rows, got $host_count"

require_text 'DEFINE_PROP_STRING("x-g11-chipset"' "$lpc_source"
for mapping in \
        '{ "H81",  0x8c5c, 0x04 }' \
        '{ "H97",  0x8cc6, 0x00 }' \
        '{ "B150", 0xa148, 0x31 }' \
        '{ "B360", 0xa308, 0x10 }' \
        '{ "X79",  0x1d41, 0x06 }'; do
    require_text "$mapping" "$lpc_source"
done
require_text 'DEFINE_PROP_STRING("x-g11-host-bridge"' "$mch_source"
for mapping in \
        '{ "SandyBridge-E", 0x3c00, 0x07 }' \
        '{ "IvyBridge-E",   0x0e00, 0x04 }'; do
    require_text "$mapping" "$mch_source"
done
require_text 'void mch_g11_firmware_handoff(MCHPCIState *mch)' "$mch_source"
require_text 'ICH9_APM_G11_HOST_BRIDGE_HANDOFF' "$lpc_source"
require_text 'G11_HOST_BRIDGE_HANDOFF_COMMAND  0x47' "$ovmf_patch"
require_text 'EVT_SIGNAL_EXIT_BOOT_SERVICES' "$ovmf_patch"
require_text 'ovmf-g11-host-bridge-handoff.patch' "$ovmf_build"
require_text 'g11_host_bridge_handoff=exit-boot-services-apm-0x47' \
    "$ovmf_features"
require_text 'OVMF 与 G-11 CPU DMI2 功能清单不匹配' "$start_vm"
expected_ovmf_sha=$(sed -n 's/^sha256=//p' "$ovmf_features")
[[ "$expected_ovmf_sha" =~ ^[0-9a-f]{64}$ ]] ||
    fail 'bundled OVMF feature manifest has an invalid sha256'
actual_ovmf_sha=$(sha256sum -- "$ovmf_image" | awk '{print $1}')
[[ "$actual_ovmf_sha" == "$expected_ovmf_sha" ]] ||
    fail 'bundled OVMF does not match its G-11 feature manifest'
require_text 'ICH9-LPC.x-g11-chipset=${CHIPSET_QEMU_PRESENTATION_KEY}' \
    "$start_vm"
require_text 'mch.x-g11-host-bridge=${CPU_HOST_BRIDGE_PRESENTATION_KEY}' \
    "$start_vm"
require_text 'G11_CHIPSET_PRESENTATION 必须是 catalog 或 off' "$start_vm"
require_text 'G11_HOST_BRIDGE_PRESENTATION 必须是 catalog 或 off' "$start_vm"
if grep -Eq 'ICH9-(AHCI|SMB).*x-g11-chipset|qemu-xhci.*x-g11-chipset' \
        "$start_vm" "$lpc_source"; then
    fail 'chipset presentation leaked into AHCI/SMBus/xHCI identities'
fi

qemu="$root/build/qemu-system-x86_64"
if [[ -x "$qemu" ]]; then
    "$qemu" -device ICH9-LPC,help 2>&1 |
        grep -Eq '^  x-g11-chipset=<(str|string)>' ||
        fail 'built QEMU lacks x-g11-chipset'
    "$qemu" -device mch,help 2>&1 |
        grep -Eq '^  x-g11-host-bridge=<(str|string)>' ||
        fail 'built QEMU lacks x-g11-host-bridge'
    if "$qemu" -M q35 -global ICH9-LPC.x-g11-chipset=Z99 \
            -display none -nodefaults -S >/dev/null 2>&1; then
        fail 'QEMU accepted an unreviewed chipset value'
    fi
    if "$qemu" -M q35 -global mch.x-g11-host-bridge=NetBurst \
            -display none -nodefaults -S >/dev/null 2>&1; then
        fail 'QEMU accepted an unreviewed CPU host bridge value'
    fi

    verify_firmware_handoff() {
        local profile=$1 expected=$2 output
        local -a ids=()
        local -a subsystems=()

        output=$(
            { printf '%s\n' 'info pci' 'o /b 0xb2 0x47' \
                'info pci' 'system_reset' 'info pci' 'quit'; } |
                QEMU_PCI_SUBVENDOR_ID=0x1043 \
                QEMU_PCI_SUBDEVICE_ID=0x8694 \
                "$qemu" -M q35 \
                    -global "mch.x-g11-host-bridge=$profile" \
                    -display none -nodefaults -S -monitor stdio 2>&1
        )
        mapfile -t ids < <(
            grep -oE 'Host bridge: PCI device 8086:[0-9a-f]+' <<<"$output" |
                awk '{print $NF}'
        )
        mapfile -t subsystems < <(
            awk '
                /Host bridge: PCI device/ { host_bridge = 1; next }
                host_bridge && /PCI subsystem/ {
                    value = $3
                    sub(/\r$/, "", value)
                    print value
                    host_bridge = 0
                }
            ' <<<"$output"
        )
        [[ "${ids[*]:-}" == "8086:29c0 8086:$expected 8086:29c0" ]] ||
            fail "$profile firmware handoff/reset sequence was: ${ids[*]:-missing}"
        [[ "${subsystems[*]:-}" == \
                "1043:8694 8086:$expected 1043:8694" ]] ||
            fail "$profile firmware subsystem/reset sequence was: ${subsystems[*]:-missing}"
    }

    verify_firmware_handoff SandyBridge-E 3c00
    verify_firmware_handoff IvyBridge-E 0e00
fi

echo 'PASS: 524 G-11 platforms map LPC identities; all 260 X79 rows map UEFI-handoff CPU DMI2 identities'

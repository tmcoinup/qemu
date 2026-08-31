#!/usr/bin/env bash
# End-to-end semantic checks for the root deploy/scripts/create-vm.sh -> start-vm.sh
# workflow.  Keep the allowlists here independent from the generator catalog:
# adding a random-pool entry must be an explicit, reviewed test change too.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CREATE_VM="$REPO_ROOT/deploy/scripts/create-vm.sh"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
SERIAL_LIB="$REPO_ROOT/deploy/lib/hardware-serials.sh"
MONITOR_LIB="$REPO_ROOT/deploy/lib/monitor-profiles.sh"

[[ -r "$SERIAL_LIB" ]] || {
    echo "FAIL: hardware serial library is missing" >&2
    exit 1
}
# shellcheck source=/dev/null
source "$SERIAL_LIB"
# shellcheck source=/dev/null
source "$MONITOR_LIB"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 label=$3

    [[ "$actual" == "$expected" ]] \
        || fail "$label: expected '$expected', got '$actual'"
}

require_text() {
    local needle=$1 file=$2 label=${3:-$1}

    grep -F -- "$needle" "$file" >/dev/null \
        || fail "$label missing from $(basename "$file")"
}

reject_text() {
    local needle=$1 file=$2 label=${3:-$1}

    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "$label unexpectedly present in $(basename "$file")"
    fi
}

assert_no_persistent_optical_contract() {
    local file=$1 label=$2 optical_line

    while IFS= read -r optical_line; do
        [[ "$optical_line" != *'id=g11-odd'* ]] ||
            fail "$label attached a default g11-odd optical drive: $optical_line"
        [[ "$optical_line" != *'model='* &&
           "$optical_line" != *'serial='* ]] ||
            fail "$label transient media exposed an unaudited identity: $optical_line"
    done < <(
        sed 's/ -/\n-/g' "$file" |
            grep -E -- '((ide|scsi)-cd|usb-storage)\\,' || true
    )
}

assert_serials() {
    local label=$1 expected_mem_serial_list

    g11_hardware_serial_board_validate "$BOARD_BRAND" "$SYS_SN" \
        "$BOARD_MODEL" "$BOARD_RELEASE_YEAR" \
        || fail "$label SYS_SN violates the $BOARD_SERIAL_POLICY board contract: '$SYS_SN'"
    g11_hardware_serial_board_validate "$BOARD_BRAND" "$MB_SN" \
        "$BOARD_MODEL" "$BOARD_RELEASE_YEAR" \
        || fail "$label MB_SN violates the $BOARD_SERIAL_POLICY board contract: '$MB_SN'"
    g11_hardware_serial_board_validate "$BOARD_BRAND" "$CHASSIS_SN" \
        "$BOARD_MODEL" "$BOARD_RELEASE_YEAR" \
        || fail "$label CHASSIS_SN violates the $BOARD_SERIAL_POLICY board contract: '$CHASSIS_SN'"
    [[ "$SYS_SN" != "$MB_SN" && "$SYS_SN" != "$CHASSIS_SN" &&
       "$MB_SN" != "$CHASSIS_SN" ]] \
        || fail "$label reused a system/baseboard/chassis serial"
    g11_hardware_serial_memory_validate "$MEM_SN" \
        || fail "$label MEM_SN violates the JEDEC 4-byte serial contract: '$MEM_SN'"
    expected_mem_serial_list=$(g11_hardware_serial_memory_list_generate \
        "$MEM_SN" "$MEM_SLOTS") || \
        fail "$label cannot derive its complete DIMM serial list"
    assert_eq "$expected_mem_serial_list" "${MEM_SERIAL_LIST-}" \
        "$label persisted per-slot memory serial list"
    g11_hardware_serial_ssd_validate "$SSD_PROFILE" "$SSD_SN" strict \
        || fail "$label SSD_SN violates the strict $SSD_PROFILE contract: '$SSD_SN'"
}

assert_intel_mac() {
    local label=$1 o1 o2 o3 _r1 _r2 _r3 oui

    [[ "$VM_MAC" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] \
        || fail "$label VM_MAC has an invalid format: '$VM_MAC'"
    IFS=: read -r o1 o2 o3 _r1 _r2 _r3 <<<"$VM_MAC"
    oui="$o1:$o2:$o3"
    case "$oui" in
        00:1B:21|00:1E:67|00:21:6A|00:22:FA|00:23:14|00:24:D7 \
        |8C:8D:28|A0:36:9F|A4:C3:F0) ;;
        *) fail "$label uses an OUI not registered to Intel: $oui" ;;
    esac
}

assert_ssd_profile() {
    local label=$1 expected_brand expected_model expected_bus expected_bytes expected_fw
    local expected_controller expected_form expected_gen expected_lanes
    local expected_logical=512 expected_physical=512

    case "$SSD_PROFILE" in
        samsung-840-pro-512gb)
            expected_brand=Samsung
            expected_model='Samsung SSD 840 PRO Series'
            expected_bus=sata
            expected_bytes=512110190592
            expected_fw=DXM06B0Q
            expected_controller=ahci
            expected_form=2.5-inch
            expected_gen=0
            expected_lanes=0
            ;;
        samsung-850-pro-512gb)
            expected_brand=Samsung
            expected_model='Samsung SSD 850 PRO 512GB'
            expected_bus=sata
            expected_bytes=512110190592
            expected_fw=EXM04B6Q
            expected_controller=ahci
            expected_form=2.5-inch
            expected_gen=0
            expected_lanes=0
            ;;
        samsung-860-pro-512gb)
            expected_brand=Samsung
            expected_model='Samsung SSD 860 PRO 512GB'
            expected_bus=sata
            expected_bytes=512110190592
            expected_fw=RVM02B6Q
            expected_controller=ahci
            expected_form=2.5-inch
            expected_gen=0
            expected_lanes=0
            ;;
        crucial-mx100-512gb)
            expected_brand=Crucial
            expected_model='Crucial_CT512MX100SSD1'
            expected_bus=sata
            expected_bytes=512110190592
            expected_fw=MU03
            expected_controller=ahci
            expected_form=2.5-inch
            expected_gen=0
            expected_lanes=0
            expected_physical=4096
            ;;
        kingston-kc400-512gb)
            expected_brand=Kingston
            expected_model='KINGSTON SKC400S37512G'
            expected_bus=sata
            expected_bytes=512110190592
            expected_fw=SAFM001B
            expected_controller=ahci
            expected_form=2.5-inch
            expected_gen=0
            expected_lanes=0
            ;;
        intel-545s-512gb)
            expected_brand=Intel
            expected_model='INTEL SSDSC2KW512G8'
            expected_bus=sata
            expected_bytes=512110190592
            expected_fw=LHF004C
            expected_controller=ahci
            expected_form=2.5-inch
            expected_gen=0
            expected_lanes=0
            ;;
        wd-pc-sa530-512gb)
            expected_brand='Western Digital'
            expected_model='WDC PC SA530 SDASB8Y512G'
            expected_bus=sata
            expected_bytes=512110190592
            expected_fw=40101000
            expected_controller=ahci
            expected_form=2.5-inch
            expected_gen=0
            expected_lanes=0
            ;;
        wd-black-pcie-512gb)
            expected_brand='Western Digital'
            expected_model='WDC WDS512G1X0C-00ENX0'
            expected_bus=nvme
            expected_bytes=512110190592
            expected_fw=B35900WD
            expected_controller=wd
            expected_form=m.2-2280
            expected_gen=3
            expected_lanes=4
            ;;
        samsung-970-pro-512gb)
            expected_brand=Samsung
            expected_model='Samsung SSD 970 PRO 512GB'
            expected_bus=nvme
            expected_bytes=512110190592
            expected_fw=1B2QEXP7
            expected_controller=samsung
            expected_form=m.2-2280
            expected_gen=3
            expected_lanes=4
            ;;
        samsung-960-pro-512gb)
            expected_brand=Samsung
            expected_model='Samsung SSD 960 PRO 512GB'
            expected_bus=nvme
            expected_bytes=512110190592
            expected_fw=2B6QCXP7
            expected_controller=samsung
            expected_form=m.2-2280
            expected_gen=3
            expected_lanes=4
            ;;
        *) fail "$label selected an unreviewed SSD profile: $SSD_PROFILE" ;;
    esac

    assert_eq "$expected_brand" "$SSD_BRAND" "$label SSD brand"
    assert_eq "$expected_model" "$SSD_MODEL" "$label SSD Identify model"
    assert_eq "$expected_bus" "$SSD_INTERFACE" "$label SSD interface"
    assert_eq "$expected_bytes" "$SSD_SIZE_BYTES" "$label SSD visible bytes"
    assert_eq "$expected_fw" "$SSD_FIRMWARE_REV" "$label SSD firmware"
    assert_eq "$expected_controller" "$SSD_CONTROLLER_PROFILE" \
        "$label SSD controller profile"
    assert_eq "$expected_form" "$SSD_FORM_FACTOR" "$label SSD form factor"
    assert_eq "$expected_gen" "$SSD_PCIE_GEN" "$label SSD PCIe generation"
    assert_eq "$expected_lanes" "$SSD_PCIE_LANES" "$label SSD PCIe lanes"
    assert_eq "$expected_logical" "$SSD_LOGICAL_BLOCK_SIZE" \
        "$label SSD logical sector"
    assert_eq "$expected_physical" "$SSD_PHYSICAL_BLOCK_SIZE" \
        "$label SSD physical sector"
}

assert_input_profiles() {
    local label=$1

    assert_eq 2 "$INPUT_COMPONENT_CONTRACT_VERSION" \
        "$label input component contract"
    assert_eq absolute "$POINTER_MODE" "$label default pointer mode"
    case "$KBD_PROFILE|$KBD_BRAND|$KBD_MODEL|$KBD_VID|$KBD_PID|$KBD_BCD_DEVICE|$KBD_USB_VERSION|$KBD_MFR|$KBD_PRODUCT|$KBD_SERIAL_POLICY|$KBD_FIDELITY" in
        'microsoft-wired-keyboard-600|Microsoft|Wired Keyboard 600|0x045E|0x0750|0x0110|2|Microsoft|Wired Keyboard 600|none|identity_only_generic_report'|\
        'logitech-k120-r64|Logitech|K120 revision 64.00|0x046D|0xC31C|0x6400|2|Logitech|USB Keyboard|none|identity_only_generic_report'|\
        'dell-sk-8115|Dell|SK-8115|0x413C|0x2003|0x0301|1|Dell|Dell USB Keyboard|none|identity_only_generic_report') ;;
        *) fail "$label selected an unreviewed keyboard contract: ${KBD_PROFILE:-missing}" ;;
    esac
    assert_eq \
        'qemu-generic-usb-tablet|virtual|QEMU USB Tablet|0x0627|0x0001|0x0000|2|QEMU|QEMU USB Tablet|none|generic_virtual_only' \
        "$POINTER_PROFILE|$POINTER_BRAND|$POINTER_MODEL|$POINTER_VID|$POINTER_PID|$POINTER_BCD_DEVICE|$POINTER_USB_VERSION|$POINTER_MFR|$POINTER_PRODUCT|$POINTER_SERIAL_POLICY|$POINTER_FIDELITY" \
        "$label honest generic absolute pointer contract"
}

# Component contract v3 deliberately keeps the machine allowlist normalized.
# Validate it from independent CPU/board/memory expectations instead of
# duplicating every Cartesian-looking whole-machine row in one giant case.
assert_platform() {
    local requested=$1 label=$2
    local expected_cpu_profile expected_board_profile expected_memory_profile
    local expected_lifecycle expected_cpu expected_tsc expected_cores
    local expected_threads expected_vcpus expected_l1 expected_l2 expected_l3
    local expected_family expected_socket expected_l2_assoc expected_l3_assoc
    local expected_board_brand expected_board_model expected_board_revision
    local expected_chipset expected_bios expected_bios_date expected_tpm
    local expected_board_slots expected_max_memory expected_nvme_gen
    local expected_nvme_lanes expected_xhci_vendor expected_xhci_device
    local expected_xhci_revision expected_mem_slots
    local expected_main_slot expected_aux_slot expected_aux_type
    local expected_main_type expected_aux_width expected_aux_length
    local expected_mem_family expected_mem_type expected_mem_speed
    local expected_mem_model_list expected_mem_module_list
    local expected_mem_device_width_list expected_mem_total
    local expected_mem_rank_list expected_mem_voltage expected_channel_mode
    local expected_module_jep106_list expected_dram_jep106_list
    local expected_board_release_year expected_board_serial_policy
    local actual_board_revision

    case "$requested" in
        i7-4960x-x79-up4-elpida-12g)
            expected_cpu_profile=i7-4960x
            expected_board_profile=gigabyte-x79-up4
            expected_memory_profile=elpida-ebj40ug8bfw0-3x4
            expected_lifecycle=new
            ;;
        i7-4930k-p9x79-samsung-4g)
            expected_cpu_profile=i7-4930k
            expected_board_profile=asus-p9x79
            expected_memory_profile=samsung-m378b5773dh0-1866-2x2
            expected_lifecycle=new
            ;;
        i7-4930k-x79-up4-elpida-12g)
            expected_cpu_profile=i7-4930k
            expected_board_profile=gigabyte-x79-up4
            expected_memory_profile=elpida-ebj40ug8bfw0-3x4
            expected_lifecycle=new
            ;;
        i7-4930k-x79-extreme4-hynix-16g)
            expected_cpu_profile=i7-4930k
            expected_board_profile=asrock-x79-extreme4
            expected_memory_profile=hynix-hmt351u6cfr8c-4x4
            expected_lifecycle=new
            ;;
        i7-4820k-p9x79-micron-16g)
            expected_cpu_profile=i7-4820k
            expected_board_profile=asus-p9x79
            expected_memory_profile=micron-mt8ktf51264az-4x4
            expected_lifecycle=new
            ;;
        i7-4820k-x79-up4-elpida-12g)
            expected_cpu_profile=i7-4820k
            expected_board_profile=gigabyte-x79-up4
            expected_memory_profile=elpida-ebj40ug8bfw0-3x4
            expected_lifecycle=new
            ;;
        i7-4820k-x79-extreme4-kingston-8g)
            expected_cpu_profile=i7-4820k
            expected_board_profile=asrock-x79-extreme4
            expected_memory_profile=kvr16n11s8-2x4
            expected_lifecycle=new
            ;;
        i7-3820-p9x79-kingston-4g)
            expected_cpu_profile=i7-3820
            expected_board_profile=asus-p9x79
            expected_memory_profile=kvr16n11s6-2x2
            expected_lifecycle=new
            ;;
        i7-3820-x79-up4-samsung-12g)
            expected_cpu_profile=i7-3820
            expected_board_profile=gigabyte-x79-up4
            expected_memory_profile=samsung-m378b5273dh0-3x4
            expected_lifecycle=new
            ;;
        i7-3820-x79-extreme4-samsung-16g)
            expected_cpu_profile=i7-3820
            expected_board_profile=asrock-x79-extreme4
            expected_memory_profile=samsung-m378b5273dh0-4x4
            expected_lifecycle=new
            ;;
        i7-3930k-p9x79-samsung-8g)
            expected_cpu_profile=i7-3930k
            expected_board_profile=asus-p9x79
            expected_memory_profile=samsung-m378b5273dh0-2x4
            expected_lifecycle=new
            ;;
        g3220-h81m-k-4g)
            expected_cpu_profile=g3220
            expected_board_profile=asus-h81m-k
            expected_memory_profile=kvr13n9s6-2x2
            expected_lifecycle=new
            ;;
        g3220-h81m-c-6g)
            expected_cpu_profile=g3220
            expected_board_profile=asus-h81m-c
            expected_memory_profile=kvr13n9-flex-4plus2
            expected_lifecycle=archived
            ;;
        i3-4130-h81m-p33-8g)
            expected_cpu_profile=i3-4130
            expected_board_profile=msi-h81m-p33
            expected_memory_profile=kvr16n11s8-2x4
            expected_lifecycle=new
            ;;
        i5-4460-h81m-s1-4g)
            expected_cpu_profile=i5-4460
            expected_board_profile=gigabyte-h81m-s1
            expected_memory_profile=kvr16n11s6-2x2
            expected_lifecycle=new
            ;;
        i5-4570-h81m-k-6g)
            expected_cpu_profile=i5-4570
            expected_board_profile=asus-h81m-k
            expected_memory_profile=kvr16n11-flex-4plus2
            expected_lifecycle=archived
            ;;
        i5-4590-h81m-s1-8g)
            expected_cpu_profile=i5-4590
            expected_board_profile=gigabyte-h81m-s1
            expected_memory_profile=kvr16n11s8-2x4
            expected_lifecycle=new
            ;;
        i3-4130-h81m-s1-samsung-6g)
            expected_cpu_profile=i3-4130
            expected_board_profile=gigabyte-h81m-s1
            expected_memory_profile=samsung-m378b5-flex-4plus2
            expected_lifecycle=archived
            ;;
        i3-4130-h81m-s1-kingston-1333-6g)
            expected_cpu_profile=i3-4130
            expected_board_profile=gigabyte-h81m-s1
            expected_memory_profile=kvr13n9-flex-4plus2
            expected_lifecycle=archived
            ;;
        i3-4130-h81m-s1-micron-1600-6g)
            expected_cpu_profile=i3-4130
            expected_board_profile=gigabyte-h81m-s1
            expected_memory_profile=micron-mtjtf-flex-4plus2
            expected_lifecycle=archived
            ;;
        i3-4130-h81m-s1-samsung-1333-4g)
            expected_cpu_profile=i3-4130
            expected_board_profile=gigabyte-h81m-s1
            expected_memory_profile=samsung-m378b5773dh0-1333-2x2
            expected_lifecycle=explicit-new
            ;;
        i3-4130-h81m-s1-micron-1333-6g)
            expected_cpu_profile=i3-4130
            expected_board_profile=gigabyte-h81m-s1
            expected_memory_profile=micron-mtjtf-1333-flex-4plus2
            expected_lifecycle=archived
            ;;
        i3-4130-h81m-s1-hynix-1333-8g)
            expected_cpu_profile=i3-4130
            expected_board_profile=gigabyte-h81m-s1
            expected_memory_profile=hynix-hmt351u6cfr8c-1333-2x4
            expected_lifecycle=explicit-new
            ;;
        i5-4460-h81m-c-micron-4g)
            expected_cpu_profile=i5-4460
            expected_board_profile=asus-h81m-c
            expected_memory_profile=micron-mt4jtf25664az-2x2
            expected_lifecycle=new
            ;;
        i5-4570-h81m-s1-hynix-8g)
            expected_cpu_profile=i5-4570
            expected_board_profile=gigabyte-h81m-s1
            expected_memory_profile=hynix-hmt351u6cfr8c-2x4
            expected_lifecycle=new
            ;;
        i7-4790-h81m-p33-8g)
            expected_cpu_profile=i7-4790
            expected_board_profile=msi-h81m-p33
            expected_memory_profile=kvr16n11s8-2x4
            expected_lifecycle=explicit-new
            ;;
        i3-4130-h81m-plus-crucial-8g)
            expected_cpu_profile=i3-4130
            expected_board_profile=asus-h81m-plus
            expected_memory_profile=crucial-ct51264bd160b-2x4
            expected_lifecycle=explicit-new
            ;;
        i3-4130-h81m-a-4g)
            expected_cpu_profile=i3-4130
            expected_board_profile=asus-h81m-a
            expected_memory_profile=kvr16n11s6-2x2
            expected_lifecycle=explicit-new
            ;;
        i3-4130-h81m-ds2-6g)
            expected_cpu_profile=i3-4130
            expected_board_profile=gigabyte-h81m-ds2
            expected_memory_profile=kvr16n11-flex-4plus2
            expected_lifecycle=archived
            ;;
        i3-4130-h81m-e33-8g)
            expected_cpu_profile=i3-4130
            expected_board_profile=msi-h81m-e33
            expected_memory_profile=kvr16n11s8-2x4
            expected_lifecycle=explicit-new
            ;;
        i3-4130-h81m-hds-4g)
            expected_cpu_profile=i3-4130
            expected_board_profile=asrock-h81m-hds
            expected_memory_profile=kvr16n11s6-2x2
            expected_lifecycle=explicit-new
            ;;
        i3-4130-h81h3-m4-samsung-6g)
            expected_cpu_profile=i3-4130
            expected_board_profile=ecs-h81h3-m4
            expected_memory_profile=samsung-m378b5-flex-4plus2
            expected_lifecycle=archived
            ;;
        i5-4590-h81m-plus-6g)
            expected_cpu_profile=i5-4590
            expected_board_profile=asus-h81m-plus
            expected_memory_profile=kvr16n11-flex-4plus2
            expected_lifecycle=archived
            ;;
        i5-4590)
            expected_cpu_profile=i5-4590
            expected_board_profile=gigabyte-h97-d3h
            expected_memory_profile=kvr16n11s8-2x4
            expected_lifecycle=legacy-compatibility
            ;;
        i5-6500)
            expected_cpu_profile=i5-6500
            expected_board_profile=gigabyte-b150m-d3h
            expected_memory_profile=kvr21n15s8-2x4
            expected_lifecycle=legacy-compatibility
            ;;
        i3-8100)
            expected_cpu_profile=i3-8100
            expected_board_profile=asus-prime-b360m-a
            expected_memory_profile=kvr24n17s8-2x4
            expected_lifecycle=legacy-compatibility
            ;;
        *) fail "test bug: unknown v3 platform $requested" ;;
    esac

    case "$expected_cpu_profile" in
        i7-3820)
            expected_cpu=Core-i7-3820 expected_tsc=3600000000
            expected_cores=4 expected_threads=2 expected_vcpus=8
            expected_l1=256 expected_l2=1024 expected_l3=10240
            expected_family=198 expected_socket=0x26
            expected_l2_assoc=7 expected_l3_assoc=14
            ;;
        i7-3930k)
            expected_cpu=Core-i7-3930K expected_tsc=3200000000
            expected_cores=6 expected_threads=2 expected_vcpus=12
            expected_l1=384 expected_l2=1536 expected_l3=12288
            expected_family=198 expected_socket=0x26
            expected_l2_assoc=7 expected_l3_assoc=8
            ;;
        i7-4820k)
            expected_cpu=Core-i7-4820K expected_tsc=3700000000
            expected_cores=4 expected_threads=2 expected_vcpus=8
            expected_l1=256 expected_l2=1024 expected_l3=10240
            expected_family=198 expected_socket=0x26
            expected_l2_assoc=7 expected_l3_assoc=14
            ;;
        i7-4930k)
            expected_cpu=Core-i7-4930K expected_tsc=3400000000
            expected_cores=6 expected_threads=2 expected_vcpus=12
            expected_l1=384 expected_l2=1536 expected_l3=12288
            expected_family=198 expected_socket=0x26
            expected_l2_assoc=7 expected_l3_assoc=8
            ;;
        i7-4960x)
            expected_cpu=Core-i7-4960X expected_tsc=3600000000
            expected_cores=6 expected_threads=2 expected_vcpus=12
            expected_l1=384 expected_l2=1536 expected_l3=15360
            expected_family=198 expected_socket=0x26
            expected_l2_assoc=7 expected_l3_assoc=14
            ;;
        g3220)
            expected_cpu=Intel-Pentium-G3220 expected_tsc=3000000000
            expected_cores=2 expected_threads=1 expected_vcpus=2
            expected_l1=128 expected_l2=512 expected_l3=3072
            expected_family=11 expected_socket=0x2D
            expected_l2_assoc=7 expected_l3_assoc=9
            ;;
        i3-4130)
            expected_cpu=Core-i3-4130 expected_tsc=3400000000
            expected_cores=2 expected_threads=2 expected_vcpus=4
            expected_l1=128 expected_l2=512 expected_l3=3072
            expected_family=206 expected_socket=0x2D
            expected_l2_assoc=7 expected_l3_assoc=9
            ;;
        i5-4460)
            expected_cpu=Core-i5-4460 expected_tsc=3200000000
            expected_cores=4 expected_threads=1 expected_vcpus=4
            expected_l1=256 expected_l2=1024 expected_l3=6144
            expected_family=205 expected_socket=0x2D
            expected_l2_assoc=7 expected_l3_assoc=9
            ;;
        i5-4570)
            expected_cpu=Core-i5-4570 expected_tsc=3200000000
            expected_cores=4 expected_threads=1 expected_vcpus=4
            expected_l1=256 expected_l2=1024 expected_l3=6144
            expected_family=205 expected_socket=0x2D
            expected_l2_assoc=7 expected_l3_assoc=9
            ;;
        i5-4590)
            expected_cpu=Core-i5-4590 expected_tsc=3300000000
            expected_cores=4 expected_threads=1 expected_vcpus=4
            expected_l1=256 expected_l2=1024 expected_l3=6144
            expected_family=205 expected_socket=0x2D
            expected_l2_assoc=7 expected_l3_assoc=9
            ;;
        i7-4790)
            expected_cpu=Core-i7-4790 expected_tsc=3600000000
            expected_cores=4 expected_threads=2 expected_vcpus=8
            expected_l1=256 expected_l2=1024 expected_l3=8192
            expected_family=198 expected_socket=0x2D
            expected_l2_assoc=7 expected_l3_assoc=9
            ;;
        i5-6500)
            expected_cpu=Core-i5-6500 expected_tsc=3200000000
            expected_cores=4 expected_threads=1 expected_vcpus=4
            expected_l1=256 expected_l2=1024 expected_l3=6144
            expected_family=205 expected_socket=0x32
            expected_l2_assoc=5 expected_l3_assoc=9
            ;;
        i3-8100)
            expected_cpu=Core-i3-8100 expected_tsc=3600000000
            expected_cores=4 expected_threads=1 expected_vcpus=4
            expected_l1=256 expected_l2=1024 expected_l3=6144
            expected_family=206 expected_socket=0x32
            expected_l2_assoc=5 expected_l3_assoc=9
            ;;
        *) fail "test bug: unknown CPU profile $expected_cpu_profile" ;;
    esac
    if [[ "$expected_cpu_profile" == i7-3820 ||
          "$expected_cpu_profile" == i7-3930k ]]; then
        expected_main_type=171
    else
        expected_main_type=177
    fi

    case "$expected_board_profile" in
        asus-p9x79)
            expected_board_brand='ASUSTeK COMPUTER INC.'
            expected_board_model=P9X79 expected_board_revision='Rev 1.xx'
            expected_chipset=X79 expected_bios=4701 expected_bios_date=06/23/2014
            expected_board_release_year=2011 expected_board_serial_policy=asus
            ;;
        gigabyte-x79-up4)
            expected_board_brand=Gigabyte expected_board_model=GA-X79-UP4
            expected_board_revision=1.0 expected_chipset=X79 expected_bios=F7
            expected_bios_date=03/20/2014
            expected_board_release_year=2012 expected_board_serial_policy=gigabyte
            ;;
        asrock-x79-extreme4)
            expected_board_brand=ASRock expected_board_model='X79 Extreme4'
            expected_board_revision=1.0 expected_chipset=X79 expected_bios=P3.20
            expected_bios_date=07/22/2013
            expected_board_release_year=2011 expected_board_serial_policy=asrock
            ;;
        asus-h81m-k)
            expected_board_brand='ASUSTeK COMPUTER INC.'
            expected_board_model=H81M-K expected_board_revision='Rev X.0x'
            expected_chipset=H81 expected_bios=3802 expected_bios_date=01/23/2024
            expected_board_release_year=2013 expected_board_serial_policy=asus
            ;;
        asus-h81m-c)
            expected_board_brand='ASUSTeK COMPUTER INC.'
            expected_board_model=H81M-C expected_board_revision='Rev X.0x'
            expected_chipset=H81 expected_bios=3602 expected_bios_date=04/14/2018
            expected_board_release_year=2013 expected_board_serial_policy=asus
            ;;
        gigabyte-h81m-s1)
            expected_board_brand=Gigabyte expected_board_model=GA-H81M-S1
            expected_board_revision=2.1 expected_chipset=H81 expected_bios=FH
            expected_bios_date=08/13/2015
            expected_board_release_year=2015 expected_board_serial_policy=gigabyte
            ;;
        msi-h81m-p33)
            expected_board_brand=MSI
            expected_board_model='H81M-P33 (MS-7817)'
            expected_board_revision=1.0 expected_chipset=H81 expected_bios=1.A
            expected_bios_date=07/17/2018
            expected_board_release_year=2013 expected_board_serial_policy=msi
            ;;
        gigabyte-h97-d3h)
            expected_board_brand=Gigabyte expected_board_model=GA-H97-D3H
            expected_board_revision=1.0 expected_chipset=H97 expected_bios=F7
            expected_bios_date=09/19/2015
            expected_board_release_year=2014 expected_board_serial_policy=gigabyte
            ;;
        gigabyte-b150m-d3h)
            expected_board_brand=Gigabyte expected_board_model=GA-B150M-D3H
            expected_board_revision=1.0 expected_chipset=B150 expected_bios=F21
            expected_bios_date=12/12/2016
            expected_board_release_year=2015 expected_board_serial_policy=gigabyte
            ;;
        asus-prime-b360m-a)
            expected_board_brand=ASUS expected_board_model='PRIME B360M-A'
            expected_board_revision=1.xx expected_chipset=B360 expected_bios=3202
            expected_bios_date=07/24/2021
            expected_board_release_year=2018 expected_board_serial_policy=asus
            ;;
        asus-h81m-plus)
            expected_board_brand='ASUSTeK COMPUTER INC.'
            expected_board_model=H81M-PLUS expected_board_revision='Rev X.0x'
            expected_chipset=H81 expected_bios=2205 expected_bios_date=06/18/2015
            expected_board_release_year=2013 expected_board_serial_policy=asus
            ;;
        asus-h81m-a)
            expected_board_brand='ASUSTeK COMPUTER INC.'
            expected_board_model=H81M-A expected_board_revision='Rev X.0x'
            expected_chipset=H81 expected_bios=2203 expected_bios_date=06/18/2015
            expected_board_release_year=2013 expected_board_serial_policy=asus
            ;;
        gigabyte-h81m-ds2)
            expected_board_brand=Gigabyte expected_board_model=GA-H81M-DS2
            expected_board_revision=3.0 expected_chipset=H81 expected_bios=F3
            expected_bios_date=08/21/2020
            expected_board_release_year=2014 expected_board_serial_policy=gigabyte
            ;;
        msi-h81m-e33)
            expected_board_brand=MSI
            expected_board_model='H81M-E33 (MS-7817)'
            expected_board_revision=1.0 expected_chipset=H81 expected_bios=6.7
            expected_bios_date=11/27/2015
            expected_board_release_year=2013 expected_board_serial_policy=msi
            ;;
        asrock-h81m-hds)
            expected_board_brand=ASRock expected_board_model=H81M-HDS
            expected_board_revision=1.0 expected_chipset=H81 expected_bios=2.20
            expected_bios_date=03/09/2016
            expected_board_release_year=2013 expected_board_serial_policy=asrock
            ;;
        ecs-h81h3-m4)
            expected_board_brand=ECS expected_board_model=H81H3-M4
            expected_board_revision=1.0A expected_chipset=H81 expected_bios=5.04.10
            expected_bios_date=04/10/2015
            expected_board_release_year=2013 expected_board_serial_policy=ecs
            ;;
        *) fail "test bug: unknown board profile $expected_board_profile" ;;
    esac
    case "$expected_board_profile" in
        asus-p9x79)
            expected_tpm=1.2 expected_board_slots=8 expected_max_memory=64
            expected_nvme_gen=0 expected_nvme_lanes=0
            expected_xhci_vendor=0x1B21 expected_xhci_device=0x1042
            expected_xhci_revision=0x00
            expected_main_slot=PCIEX16_1 expected_aux_slot=PCIEX1_1
            expected_aux_type=171 expected_aux_width=8 expected_aux_length=3
            ;;
        gigabyte-x79-up4)
            expected_tpm=1.2 expected_board_slots=8 expected_max_memory=64
            expected_nvme_gen=0 expected_nvme_lanes=0
            expected_xhci_vendor=0x1B73 expected_xhci_device=0x1009
            expected_xhci_revision=0x02
            expected_main_slot=PCIEX16_1 expected_aux_slot=PCIEX1_1
            expected_aux_type=171 expected_aux_width=8 expected_aux_length=3
            ;;
        asrock-x79-extreme4)
            expected_tpm=none expected_board_slots=4 expected_max_memory=32
            expected_nvme_gen=0 expected_nvme_lanes=0
            expected_xhci_vendor=0x1B21 expected_xhci_device=0x1042
            expected_xhci_revision=0x00
            expected_main_slot=PCIE1 expected_aux_slot=PCIE2
            expected_aux_type=171 expected_aux_width=8 expected_aux_length=3
            ;;
        asus-h81m-k|asus-h81m-c|gigabyte-h81m-s1|asus-h81m-a)
            expected_tpm=none expected_board_slots=2 expected_max_memory=16
            expected_nvme_gen=0 expected_nvme_lanes=0
            expected_xhci_vendor=0x8086
            expected_xhci_device=0x8C31 expected_xhci_revision=0x05
            expected_main_slot=PCIEX16 expected_aux_slot=PCIEX1_1
            expected_aux_type=171 expected_aux_width=8 expected_aux_length=3
            ;;
        msi-h81m-p33|msi-h81m-e33)
            expected_tpm=none expected_board_slots=2 expected_max_memory=16
            expected_nvme_gen=0 expected_nvme_lanes=0
            expected_xhci_vendor=0x8086
            expected_xhci_device=0x8C31 expected_xhci_revision=0x05
            expected_main_slot=PCI_E2 expected_aux_slot=PCI_E1
            expected_aux_type=171 expected_aux_width=8 expected_aux_length=3
            ;;
        asus-h81m-plus)
            expected_tpm=none expected_board_slots=2 expected_max_memory=16
            expected_nvme_gen=0 expected_nvme_lanes=0
            expected_xhci_vendor=0x8086
            expected_xhci_device=0x8C31 expected_xhci_revision=0x05
            expected_main_slot=PCIEX16_1 expected_aux_slot=PCIEX1_1
            expected_aux_type=171 expected_aux_width=8 expected_aux_length=3
            ;;
        gigabyte-h81m-ds2)
            expected_tpm=none expected_board_slots=2 expected_max_memory=16
            expected_nvme_gen=0 expected_nvme_lanes=0
            expected_xhci_vendor=0x8086
            expected_xhci_device=0x8C31 expected_xhci_revision=0x05
            expected_main_slot=PCIEX16 expected_aux_slot=PCIEX1
            expected_aux_type=171 expected_aux_width=8 expected_aux_length=3
            ;;
        asrock-h81m-hds)
            expected_tpm=none expected_board_slots=2 expected_max_memory=16
            expected_nvme_gen=0 expected_nvme_lanes=0
            expected_xhci_vendor=0x8086
            expected_xhci_device=0x8C31 expected_xhci_revision=0x05
            expected_main_slot=PCIE1 expected_aux_slot=PCIE2
            expected_aux_type=171 expected_aux_width=8 expected_aux_length=3
            ;;
        ecs-h81h3-m4)
            expected_tpm=none expected_board_slots=2 expected_max_memory=16
            expected_nvme_gen=0 expected_nvme_lanes=0
            expected_xhci_vendor=0x8086
            expected_xhci_device=0x8C31 expected_xhci_revision=0x05
            expected_main_slot=PCIEX16 expected_aux_slot=PCIEX1
            expected_aux_type=171 expected_aux_width=8 expected_aux_length=3
            ;;
        gigabyte-h97-d3h)
            expected_tpm=1.2 expected_board_slots=4 expected_max_memory=32
            expected_nvme_gen=2 expected_nvme_lanes=2
            expected_xhci_vendor=0x8086
            expected_xhci_device=0x8CB1 expected_xhci_revision=0x01
            expected_main_slot=PCIEX16 expected_aux_slot=PCIEX1_1
            expected_aux_type=171 expected_aux_width=8 expected_aux_length=3
            ;;
        gigabyte-b150m-d3h)
            expected_tpm=2.0 expected_board_slots=4 expected_max_memory=64
            expected_nvme_gen=3 expected_nvme_lanes=4
            expected_xhci_vendor=0x8086
            expected_xhci_device=0xA12F expected_xhci_revision=0x01
            expected_main_slot=PCIEX16 expected_aux_slot=PCIEX4
            expected_aux_type=177 expected_aux_width=10 expected_aux_length=4
            ;;
        asus-prime-b360m-a)
            expected_tpm=2.0 expected_board_slots=4 expected_max_memory=64
            expected_nvme_gen=3 expected_nvme_lanes=4
            expected_xhci_vendor=0x8086
            expected_xhci_device=0xA36D expected_xhci_revision=0x01
            expected_main_slot=PCIEX16 expected_aux_slot=PCIEX1_1
            expected_aux_type=177 expected_aux_width=8 expected_aux_length=3
            ;;
    esac

    case "$expected_memory_profile" in
        samsung-m378b5773dh0-1866-2x2)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1866
            expected_mem_model_list='M378B5773DH0-CMA,M378B5773DH0-CMA'
            expected_mem_module_list=2048,2048 expected_mem_device_width_list=8,8
            expected_mem_total=4096 expected_mem_voltage=1500
            expected_channel_mode=dual-channel
            ;;
        micron-mt8ktf51264az-4x4)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1866
            expected_mem_model_list='MT8KTF51264AZ-1G9,MT8KTF51264AZ-1G9,MT8KTF51264AZ-1G9,MT8KTF51264AZ-1G9'
            expected_mem_module_list=4096,4096,4096,4096
            expected_mem_device_width_list=8,8,8,8
            expected_mem_total=16384 expected_mem_voltage=1500
            expected_channel_mode=quad-channel
            ;;
        elpida-ebj40ug8bfw0-3x4)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1866
            expected_mem_model_list='EBJ40UG8BFW0-JS-F,EBJ40UG8BFW0-JS-F,EBJ40UG8BFW0-JS-F'
            expected_mem_module_list=4096,4096,4096
            expected_mem_device_width_list=8,8,8
            expected_mem_total=12288 expected_mem_voltage=1500
            expected_channel_mode=triple-channel
            ;;
        samsung-m378b5273dh0-3x4)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1600
            expected_mem_model_list='M378B5273DH0-CK0,M378B5273DH0-CK0,M378B5273DH0-CK0'
            expected_mem_module_list=4096,4096,4096
            expected_mem_device_width_list=8,8,8
            expected_mem_total=12288 expected_mem_voltage=1500
            expected_channel_mode=triple-channel
            ;;
        samsung-m378b5273dh0-2x4)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1600
            expected_mem_model_list='M378B5273DH0-CK0,M378B5273DH0-CK0'
            expected_mem_module_list=4096,4096
            expected_mem_device_width_list=8,8
            expected_mem_total=8192 expected_mem_voltage=1500
            expected_channel_mode=dual-channel
            ;;
        samsung-m378b5273dh0-4x4)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1600
            expected_mem_model_list='M378B5273DH0-CK0,M378B5273DH0-CK0,M378B5273DH0-CK0,M378B5273DH0-CK0'
            expected_mem_module_list=4096,4096,4096,4096
            expected_mem_device_width_list=8,8,8,8
            expected_mem_total=16384 expected_mem_voltage=1500
            expected_channel_mode=quad-channel
            ;;
        kvr13n9s6-2x2)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1333
            expected_mem_model_list='KVR13N9S6/2,KVR13N9S6/2'
            expected_mem_module_list=2048,2048 expected_mem_device_width_list=16,16
            expected_mem_total=4096 expected_mem_voltage=1500
            expected_channel_mode=dual-channel
            ;;
        kvr13n9-flex-4plus2)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1333
            expected_mem_model_list='KVR13N9S8/4,KVR13N9S6/2'
            expected_mem_module_list=4096,2048 expected_mem_device_width_list=8,16
            expected_mem_total=6144 expected_mem_voltage=1500
            expected_channel_mode=flex
            ;;
        kvr16n11s6-2x2)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1600
            expected_mem_model_list='KVR16N11S6/2,KVR16N11S6/2'
            expected_mem_module_list=2048,2048 expected_mem_device_width_list=16,16
            expected_mem_total=4096 expected_mem_voltage=1500
            expected_channel_mode=dual-channel
            ;;
        kvr16n11-flex-4plus2)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1600
            expected_mem_model_list='KVR16N11S8/4,KVR16N11S6/2'
            expected_mem_module_list=4096,2048 expected_mem_device_width_list=8,16
            expected_mem_total=6144 expected_mem_voltage=1500
            expected_channel_mode=flex
            ;;
        kvr13n9s8-2x4)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1333
            expected_mem_model_list='KVR13N9S8/4,KVR13N9S8/4'
            expected_mem_module_list=4096,4096 expected_mem_device_width_list=8,8
            expected_mem_total=8192 expected_mem_voltage=1500
            expected_channel_mode=dual-channel
            ;;
        kvr16n11s8-2x4)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1600
            expected_mem_model_list='KVR16N11S8/4,KVR16N11S8/4'
            expected_mem_module_list=4096,4096 expected_mem_device_width_list=8,8
            expected_mem_total=8192 expected_mem_voltage=1500
            expected_channel_mode=dual-channel
            ;;
        samsung-m378b5-flex-4plus2)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1600
            expected_mem_model_list='M378B5273DH0-CK0,M378B5773DH0-CK0'
            expected_mem_module_list=4096,2048 expected_mem_device_width_list=8,8
            expected_mem_total=6144 expected_mem_voltage=1500
            expected_channel_mode=flex
            ;;
        samsung-m378b5773dh0-1333-2x2)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1333
            expected_mem_model_list='M378B5773DH0-CH9,M378B5773DH0-CH9'
            expected_mem_module_list=2048,2048 expected_mem_device_width_list=8,8
            expected_mem_total=4096 expected_mem_voltage=1500
            expected_channel_mode=dual-channel
            ;;
        micron-mt4jtf25664az-2x2)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1600
            expected_mem_model_list='MT4JTF25664AZ-1G6,MT4JTF25664AZ-1G6'
            expected_mem_module_list=2048,2048 expected_mem_device_width_list=16,16
            expected_mem_total=4096 expected_mem_voltage=1500
            expected_channel_mode=dual-channel
            ;;
        micron-mtjtf-flex-4plus2)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1600
            expected_mem_model_list='MT8JTF51264AZ-1G6,MT4JTF25664AZ-1G6'
            expected_mem_module_list=4096,2048 expected_mem_device_width_list=8,16
            expected_mem_total=6144 expected_mem_voltage=1500
            expected_channel_mode=flex
            ;;
        micron-mtjtf-1333-flex-4plus2)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1333
            expected_mem_model_list='MT8JTF51264AZ-1G4,MT8JTF25664AZ-1G4'
            expected_mem_module_list=4096,2048 expected_mem_device_width_list=8,8
            expected_mem_total=6144 expected_mem_voltage=1500
            expected_channel_mode=flex
            ;;
        hynix-hmt351u6cfr8c-2x4)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1600
            expected_mem_model_list='HMT351U6CFR8C-PB,HMT351U6CFR8C-PB'
            expected_mem_module_list=4096,4096 expected_mem_device_width_list=8,8
            expected_mem_total=8192 expected_mem_voltage=1500
            expected_channel_mode=dual-channel
            ;;
        hynix-hmt351u6cfr8c-4x4)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1600
            expected_mem_model_list='HMT351U6CFR8C-PB,HMT351U6CFR8C-PB,HMT351U6CFR8C-PB,HMT351U6CFR8C-PB'
            expected_mem_module_list=4096,4096,4096,4096
            expected_mem_device_width_list=8,8,8,8
            expected_mem_total=16384 expected_mem_voltage=1500
            expected_channel_mode=quad-channel
            ;;
        hynix-hmt351u6cfr8c-1333-2x4)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1333
            expected_mem_model_list='HMT351U6CFR8C-H9,HMT351U6CFR8C-H9'
            expected_mem_module_list=4096,4096 expected_mem_device_width_list=8,8
            expected_mem_total=8192 expected_mem_voltage=1500
            expected_channel_mode=dual-channel
            ;;
        kvr21n15s8-2x4)
            expected_mem_family=DDR4 expected_mem_type=0x1A expected_mem_speed=2133
            expected_mem_model_list='KVR21N15S8/4,KVR21N15S8/4'
            expected_mem_module_list=4096,4096 expected_mem_device_width_list=8,8
            expected_mem_total=8192 expected_mem_voltage=1200
            expected_channel_mode=dual-channel
            ;;
        kvr24n17s8-2x4)
            expected_mem_family=DDR4 expected_mem_type=0x1A expected_mem_speed=2400
            expected_mem_model_list='KVR24N17S8/4,KVR24N17S8/4'
            expected_mem_module_list=4096,4096 expected_mem_device_width_list=8,8
            expected_mem_total=8192 expected_mem_voltage=1200
            expected_channel_mode=dual-channel
            ;;
        crucial-ct51264bd160b-2x4)
            expected_mem_family=DDR3 expected_mem_type=0x18 expected_mem_speed=1600
            expected_mem_model_list='CT51264BD160B,CT51264BD160B'
            expected_mem_module_list=4096,4096 expected_mem_device_width_list=8,8
            expected_mem_total=8192 expected_mem_voltage=1500
            expected_channel_mode=dual-channel
            ;;
        *) fail "test bug: unknown memory profile $expected_memory_profile" ;;
    esac

    IFS=',' read -r -a expected_mem_modules <<<"$expected_mem_module_list"
    expected_mem_slots=${#expected_mem_modules[@]}

    case "$expected_memory_profile" in
        kvr16n11s8-3x4|kvr16n11s8-4x4|kvr*)
            expected_mem_rank_list=$(printf '1,%.0s' $(seq 2 "$expected_mem_slots"))1
            expected_module_jep106_list=$(printf '0198,%.0s' $(seq 2 "$expected_mem_slots"))0198
            expected_dram_jep106_list=$(printf '0000,%.0s' $(seq 2 "$expected_mem_slots"))0000
            ;;
        elpida-ebj40ug8bfw0-2x4|elpida-ebj40ug8bfw0-3x4|elpida-ebj40ug8bfw0-4x4)
            expected_mem_rank_list=$(printf '1,%.0s' $(seq 2 "$expected_mem_slots"))1
            expected_module_jep106_list=$(printf '02FE,%.0s' $(seq 2 "$expected_mem_slots"))02FE
            expected_dram_jep106_list=$(printf '02FE,%.0s' $(seq 2 "$expected_mem_slots"))02FE
            ;;
        micron-mt8ktf51264az-2x4|micron-mt8ktf51264az-3x4|micron-mt8ktf51264az-4x4)
            expected_mem_rank_list=$(printf '1,%.0s' $(seq 2 "$expected_mem_slots"))1
            expected_module_jep106_list=$(printf '802C,%.0s' $(seq 2 "$expected_mem_slots"))802C
            expected_dram_jep106_list=$(printf '802C,%.0s' $(seq 2 "$expected_mem_slots"))802C
            ;;
        samsung-m378b5773dh0-1866-2x2|\
        samsung-m378b5173qh0-1866-2x4|\
        samsung-m378b5173qh0-1866-3x4|\
        samsung-m378b5173qh0-1866-4x4)
            expected_mem_rank_list=$(printf '1,%.0s' $(seq 2 "$expected_mem_slots"))1
            expected_module_jep106_list=$(printf '80CE,%.0s' $(seq 2 "$expected_mem_slots"))80CE
            expected_dram_jep106_list=$(printf '80CE,%.0s' $(seq 2 "$expected_mem_slots"))80CE
            ;;
        samsung-m378b5273dh0-2x4|samsung-m378b5273dh0-3x4|samsung-m378b5273dh0-4x4)
            expected_mem_rank_list=$(printf '2,%.0s' $(seq 2 "$expected_mem_slots"))2
            expected_module_jep106_list=$(printf '80CE,%.0s' $(seq 2 "$expected_mem_slots"))80CE
            expected_dram_jep106_list=$(printf '80CE,%.0s' $(seq 2 "$expected_mem_slots"))80CE
            ;;
        kvr*)
            expected_mem_rank_list=1,1
            expected_module_jep106_list=0198,0198
            expected_dram_jep106_list=0000,0000
            ;;
        samsung-m378b5-flex-4plus2)
            expected_mem_rank_list=2,1
            expected_module_jep106_list=80CE,80CE
            expected_dram_jep106_list=80CE,80CE
            ;;
        samsung-m378b5773dh0-1333-2x2)
            expected_mem_rank_list=1,1
            expected_module_jep106_list=80CE,80CE
            expected_dram_jep106_list=80CE,80CE
            ;;
        micron-mt4jtf25664az-2x2|micron-mtjtf-flex-4plus2|micron-mtjtf-1333-flex-4plus2)
            expected_mem_rank_list=1,1
            expected_module_jep106_list=802C,802C
            expected_dram_jep106_list=802C,802C
            ;;
        hynix-hmt351u6cfr8c-2x4|hynix-hmt351u6cfr8c-3x4|hynix-hmt351u6cfr8c-4x4|hynix-hmt351u6cfr8c-1333-2x4)
            expected_mem_rank_list=$(printf '2,%.0s' $(seq 2 "$expected_mem_slots"))2
            expected_module_jep106_list=$(printf '80AD,%.0s' $(seq 2 "$expected_mem_slots"))80AD
            expected_dram_jep106_list=$(printf '80AD,%.0s' $(seq 2 "$expected_mem_slots"))80AD
            ;;
        crucial-ct51264bd160b-2x4)
            expected_mem_rank_list=1,1
            expected_module_jep106_list=802C,802C
            expected_dram_jep106_list=802C,802C
            ;;
        *) fail "test bug: missing v3 SPD contract for $expected_memory_profile" ;;
    esac

    assert_eq "$requested" "$PLATFORM" "$label platform override"
    assert_eq 3 "$G11_HARDWARE_CONTRACT_VERSION" \
        "$label root hardware contract version"
    assert_eq 3 "$HARDWARE_COMPONENT_CONTRACT_VERSION" \
        "$label component contract version"
    assert_eq "$expected_cpu_profile" "$CPU_PROFILE" "$label CPU profile"
    assert_eq "$expected_board_profile" "$BOARD_PROFILE" "$label board profile"
    assert_eq "$expected_memory_profile" "$MEMORY_PROFILE" "$label memory profile"
    assert_eq "$expected_cpu" "$CPU_MODEL" "$label CPU model"
    assert_eq "$expected_tsc" "$TSC_FREQ" "$label TSC frequency"
    assert_eq "$expected_cores" "$CPU_CORES" "$label physical core count"
    assert_eq "$expected_threads" "$CPU_THREADS_PER_CORE" "$label threads per core"
    assert_eq "$expected_vcpus" "$CPU_VCPUS" "$label vCPU count"
    assert_eq "$expected_l1" "$CPU_L1_CACHE_KB" "$label aggregate L1 cache"
    assert_eq "$expected_l2" "$CPU_L2_CACHE_KB" "$label aggregate L2 cache"
    assert_eq "$expected_l3" "$CPU_L3_CACHE_KB" "$label L3 cache"
    assert_eq "$expected_l2_assoc" "$CPU_L2_ASSOC" "$label L2 associativity"
    assert_eq "$expected_l3_assoc" "$CPU_L3_ASSOC" "$label L3 associativity"
    actual_board_revision=${BOARD_REVISION:-${BOARD_VERSION:-}}
    assert_eq "$expected_board_brand" "$BOARD_BRAND" "$label board brand"
    assert_eq "$expected_board_model" "$BOARD_MODEL" "$label board model"
    assert_eq "$expected_board_revision" "$actual_board_revision" "$label board revision"
    assert_eq "$expected_chipset" "$BOARD_CHIPSET" "$label board chipset"
    assert_eq "$expected_bios" "$BIOS_VER" "$label BIOS version"
    assert_eq "$expected_bios_date" "$BIOS_DATE" "$label BIOS date"
    assert_eq "$expected_board_release_year" "$BOARD_RELEASE_YEAR" \
        "$label board release year"
    assert_eq "$expected_board_serial_policy" "$BOARD_SERIAL_POLICY" \
        "$label board serial policy"
    assert_eq "$expected_tpm" "$BOARD_TPM_VERSION" "$label board TPM capability"
    assert_eq "$expected_board_slots" "$MEM_BOARD_SLOTS" "$label physical DIMM slots"
    assert_eq "$expected_max_memory" "$MEM_MAX_CAPACITY_GB" "$label board max memory"
    assert_eq "$expected_nvme_gen" "$BOARD_NVME_PCIE_GEN" "$label native M.2 gen"
    assert_eq "$expected_nvme_lanes" "$BOARD_NVME_PCIE_LANES" "$label native M.2 lanes"
    assert_eq "$expected_xhci_device" "$XHCI_PCI_DEVICE_ID" "$label xHCI device"
    assert_eq "$expected_xhci_revision" "$XHCI_PCI_REVISION" "$label xHCI revision"
    assert_eq "$expected_xhci_vendor" "$XHCI_PCI_VENDOR_ID" "$label xHCI vendor"
    assert_eq pcie.0 "$XHCI_PCI_BUS" "$label xHCI bus"
    assert_eq 0x6 "$XHCI_PCI_ADDR" "$label xHCI address"
    assert_eq "$expected_mem_family" "$MEM_FAMILY" "$label memory family"
    assert_eq "$expected_mem_type" "$MEM_TYPE_BYTE" "$label memory SMBIOS type"
    assert_eq "$expected_mem_speed" "$MEM_SPEED" "$label memory speed"
    assert_eq "$expected_mem_model_list" "$MEM_MODEL_LIST" "$label per-slot parts"
    assert_eq "$expected_mem_module_list" "$MEM_MODULE_MB_LIST" "$label per-slot sizes"
    assert_eq "$expected_mem_device_width_list" "$MEM_DEVICE_WIDTH_LIST" \
        "$label per-slot device widths"
    assert_eq "$expected_mem_rank_list" "$MEM_RANK_LIST" \
        "$label per-slot ranks"
    assert_eq "$expected_module_jep106_list" "$MEM_MODULE_MFR_JEP106_LIST" \
        "$label per-slot module JEP106 codes"
    assert_eq "$expected_dram_jep106_list" "$MEM_DRAM_MFR_JEP106_LIST" \
        "$label per-slot DRAM JEP106 codes"
    assert_eq "$expected_mem_total" "$MEM_TOTAL_MB" "$label total memory"
    assert_eq "$expected_mem_voltage" "$MEM_VOLTAGE_MV" "$label memory voltage"
    assert_eq "$expected_channel_mode" "$MEM_CHANNEL_MODE" "$label channel mode"
    assert_eq "$expected_mem_slots" "$MEM_SLOTS" "$label populated DIMM count"
    assert_eq "${expected_mem_rank_list%%,*}" "$MEM_RANK" \
        "$label v1 DIMM-rank alias"
    assert_eq 64 "$MEM_WIDTH" "$label memory bus width"
    assert_eq "${expected_mem_model_list%%,*}" "$MEM_MODEL" \
        "$label v1 part alias"
    assert_eq "${expected_mem_module_list%%,*}" "$MEM_MODULE_MB" \
        "$label v1 capacity alias"
    assert_eq "${expected_mem_device_width_list%%,*}" "$MEM_DEVICE_WIDTH" \
        "$label v1 device-width alias"

    [[ "$MEM_MODEL_LIST" != */8* && "$MEM_MODEL_LIST" != *SO-DIMM* ]] ||
        fail "$label contains an 8 GiB or SO-DIMM part: $MEM_MODEL_LIST"
    PLATFORM_EXPECTED_LIFECYCLE=$expected_lifecycle
    PLATFORM_EXPECTED_CPU_FAMILY=$expected_family
    PLATFORM_EXPECTED_CPU_SOCKET=$expected_socket
    PLATFORM_EXPECTED_BOARD_REVISION=$expected_board_revision
    PLATFORM_EXPECTED_BOARD_SLOTS=$expected_board_slots
    PLATFORM_EXPECTED_MAX_MEMORY=$expected_max_memory
    PLATFORM_EXPECTED_L2_ASSOC=$expected_l2_assoc
    PLATFORM_EXPECTED_L3_ASSOC=$expected_l3_assoc
    PLATFORM_EXPECTED_MAIN_SLOT=$expected_main_slot
    PLATFORM_EXPECTED_MAIN_TYPE=$expected_main_type
    PLATFORM_EXPECTED_AUX_SLOT=$expected_aux_slot
    PLATFORM_EXPECTED_AUX_TYPE=$expected_aux_type
    PLATFORM_EXPECTED_AUX_WIDTH=$expected_aux_width
    PLATFORM_EXPECTED_AUX_LENGTH=$expected_aux_length
}

TMP_DIR="$(mktemp -d)"
export IMAGE_ROOT="$TMP_DIR"
VM_ROOT="$TMP_DIR/vms"
EMPTY_VGPU_CONFIG="$TMP_DIR/vgpu-host.conf"
HOST_1GB_CONFIG="$TMP_DIR/vgpu-host-1gb.conf"
HOST_2GB_CONFIG="$TMP_DIR/vgpu-host-2gb.conf"
HOST_DRIVER_VERSION_FILE="$TMP_DIR/nvidia-version"

cleanup() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

[[ -x "$CREATE_VM" ]] || fail "create-vm.sh is missing or not executable"
[[ -x "$START_VM" ]] || fail "start-vm.sh is missing or not executable"

touch "$TMP_DIR/OVMF_CODE.fd" "$TMP_DIR/OVMF_VARS.fd" "$EMPTY_VGPU_CONFIG"
printf '%s\n' 'VGPU_HOST_FB_TIER_MB=1024' >"$HOST_1GB_CONFIG"
printf '%s\n' 'VGPU_HOST_FB_TIER_MB=2048' >"$HOST_2GB_CONFIG"
printf '%s\n' '535.161.05' >"$HOST_DRIVER_VERSION_FILE"
cat >"$TMP_DIR/qemu-system-x86_64" <<'EOF'
#!/bin/sh
if [ "$#" -eq 2 ] && [ "$1" = -display ] && [ "$2" = help ]; then
    printf '%s\n' gtk sdl
    exit 0
fi
if [ "$#" -eq 2 ] && [ "$1" = -device ] \
        && [ "$2" = vfio-pci-nohotplug,help ]; then
    printf '  ramfb=<bool>\n'
    exit 0
fi
if [ "$#" -eq 2 ] && [ "$1" = -device ] \
        && [ "$2" = pcie-root-port,help ]; then
    printf '%s\n' \
        '  x-speed=<PCIELinkSpeed>' \
        '  x-width=<PCIELinkWidth>' \
        '  x-pci-vendor-id=<uint32>' \
        '  x-pci-device-id=<uint32>' \
        '  x-pci-revision=<uint32>'
    exit 0
fi
if [ "$#" -eq 2 ] && [ "$1" = -object ] && [ "$2" = fb-shm,help ]; then
    printf 'fb-shm options:\n  path=<string>\n  rate=<uint32>\n'
    exit 0
fi
echo "unexpected fake QEMU invocation: $*" >&2
exit 99
EOF
chmod +x "$TMP_DIR/qemu-system-x86_64"

# Root lifecycle entry points use the same signed 32-bit VM ID contract as the
# guest manifest/launcher.  Oversized IDs must fail before creating storage.
range_root="$TMP_DIR/id-range-root"
if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
        IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$range_root" \
        "$CREATE_VM" 2147483648 \
        >"$TMP_DIR/create-oversized.out" 2>"$TMP_DIR/create-oversized.err"; then
    fail 'create-vm accepted an ID beyond 2147483647'
fi
require_text '1..2147483647' "$TMP_DIR/create-oversized.err" \
    "create-vm ID range"
[[ ! -e "$range_root" && ! -L "$range_root" ]] ||
    fail 'create-vm oversized ID created storage'
if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
        IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$range_root" \
        "$START_VM" 2147483648 \
        >"$TMP_DIR/start-oversized.out" 2>"$TMP_DIR/start-oversized.err"; then
    fail 'start-vm accepted an ID beyond 2147483647'
fi
require_text '1..2147483647' "$TMP_DIR/start-oversized.err" \
    "start-vm ID range"
[[ ! -e "$range_root" && ! -L "$range_root" ]] ||
    fail 'start-vm oversized ID created storage'

create_vm() {
    local id=$1 platform=$2 ssd_profile=$3 output=$4
    local -a compatibility_args=()

    if [[ "$platform" == i5-4590 || "$platform" == i5-6500 ||
          "$platform" == i3-8100 ]]; then
        # Compatibility-only rows are never accepted as fresh VMs.  Seed the
        # minimum immutable historical identity and exercise the supported
        # --force metadata-refresh path instead.
        mkdir -p "$VM_ROOT/$id"
        printf 'PLATFORM=%s\n' "$platform" >"$VM_ROOT/$id/vm.conf"
        chmod 444 "$VM_ROOT/$id/vm.conf"
        compatibility_args+=(--force)
    fi

    env -i \
        HOME="${HOME:-/tmp}" \
        PATH=/usr/bin:/bin \
        IMAGE_ROOT="$IMAGE_ROOT" \
        VM_ROOT="$VM_ROOT" \
        VGPU_HOST_CONFIG="$HOST_2GB_CONFIG" \
        "$CREATE_VM" "$id" \
        "${compatibility_args[@]}" \
        --platform "$platform" \
        --ssd-profile "$ssd_profile" \
        --gpu-profile gtx1050_2gb \
        --monitor-profile lenovo-d24-20 >"$output"
}

create_vm_default_ssd() {
    local id=$1 platform=$2 output=$3
    local -a compatibility_args=()

    if [[ "$platform" == i5-4590 || "$platform" == i5-6500 ||
          "$platform" == i3-8100 ]]; then
        mkdir -p "$VM_ROOT/$id"
        printf 'PLATFORM=%s\n' "$platform" >"$VM_ROOT/$id/vm.conf"
        chmod 444 "$VM_ROOT/$id/vm.conf"
        compatibility_args+=(--force)
    fi

    env -i \
        HOME="${HOME:-/tmp}" \
        PATH=/usr/bin:/bin \
        IMAGE_ROOT="$IMAGE_ROOT" \
        VM_ROOT="$VM_ROOT" \
        VGPU_HOST_CONFIG="$HOST_2GB_CONFIG" \
        "$CREATE_VM" "$id" \
        "${compatibility_args[@]}" \
        --platform "$platform" \
        --gpu-profile gtx1050_2gb \
        --monitor-profile lenovo-d24-20 >"$output"
}

run_start() {
    local id=$1 output=$2 error=$3
    local -a optional_env=()
    shift 3

    if [[ -v VGPU_MDEV_FRL_ENABLED ]]; then
        optional_env+=("VGPU_MDEV_FRL_ENABLED=$VGPU_MDEV_FRL_ENABLED")
    fi
    if [[ -v VGPU_PATCHED_DRIVER_VERSION ]]; then
        optional_env+=("VGPU_PATCHED_DRIVER_VERSION=$VGPU_PATCHED_DRIVER_VERSION")
    fi
    if [[ -v QEMU_SDL_DISABLE_IBUS ]]; then
        optional_env+=("QEMU_SDL_DISABLE_IBUS=$QEMU_SDL_DISABLE_IBUS")
    fi
    if [[ -v ODD_MODEL ]]; then
        optional_env+=("ODD_MODEL=$ODD_MODEL")
    fi
    if [[ -v ODD_SERIAL ]]; then
        optional_env+=("ODD_SERIAL=$ODD_SERIAL")
    fi

    env -i \
        HOME="${HOME:-/tmp}" \
        PATH=/usr/bin:/bin \
        DISPLAY=:99 \
        IMAGE_ROOT="$IMAGE_ROOT" \
        VM_ROOT="$VM_ROOT" \
        QEMU_BIN="$TMP_DIR/qemu-system-x86_64" \
        NVIDIA_MODULE_VERSION_FILE="$HOST_DRIVER_VERSION_FILE" \
        OVMF_CODE="$TMP_DIR/OVMF_CODE.fd" \
        OVMF_VARS="$TMP_DIR/OVMF_VARS.fd" \
        VGPU_HOST_CONFIG="$EMPTY_VGPU_CONFIG" \
        VGPU_MDEV_INTERNAL_PCI_IDENTITY="${VGPU_MDEV_INTERNAL_PCI_IDENTITY:-0}" \
        "${optional_env[@]}" \
        REPAIR_DISPLAY_VARS=off \
        "$START_VM" "$id" --dry-run "$@" >"$output" 2>"$error"
}

rewrite_conf() {
    local source_id=$1 target_id=$2 tpm_value=$3
    local source_conf="$VM_ROOT/${source_id}/vm.conf"
    local target_dir="$VM_ROOT/${target_id}"
    local target_conf="$target_dir/vm.conf"

    mkdir -p "$target_dir"
    awk -v id="$target_id" -v tpm="$tpm_value" '
        /^VM_ID=/ { print "VM_ID=" id; next }
        /^VM_UUID=/ {
            printf "VM_UUID=00000000-0000-4000-8000-%012d\n", id
            next
        }
        /^BOARD_TPM_VERSION=/ {
            seen = 1
            if (tpm != "omit") print "BOARD_TPM_VERSION=" tpm
            next
        }
        { print }
        END {
            if (!seen && tpm != "omit") print "BOARD_TPM_VERSION=" tpm
        }
    ' "$source_conf" >"$target_conf"

    # A copied hardware contract represents another physical machine.  Keep
    # the test fixture legal under the fleet-wide identity gate by rerolling
    # every persisted serial/MAC instead of changing only VM_UUID.
    mapfile -d '' -t fresh_identity < <(
        # shellcheck source=/dev/null
        source "$target_conf"
        fresh_sys=$(g11_hardware_serial_board_generate "$BOARD_BRAND" \
            "$BOARD_MODEL" "$BOARD_RELEASE_YEAR")
        while :; do
            fresh_mb=$(g11_hardware_serial_board_generate "$BOARD_BRAND" \
                "$BOARD_MODEL" "$BOARD_RELEASE_YEAR")
            [[ "$fresh_mb" != "$fresh_sys" ]] && break
        done
        while :; do
            fresh_chassis=$(g11_hardware_serial_board_generate "$BOARD_BRAND" \
                "$BOARD_MODEL" "$BOARD_RELEASE_YEAR")
            [[ "$fresh_chassis" != "$fresh_sys" && \
               "$fresh_chassis" != "$fresh_mb" ]] && break
        done
        fresh_mem=$(g11_hardware_serial_memory_generate)
        fresh_mem_list=$(g11_hardware_serial_memory_list_generate \
            "$fresh_mem" "$MEM_SLOTS")
        fresh_ssd=$(g11_hardware_serial_ssd_generate "$SSD_PROFILE")
        fresh_monitor=$(monitor_profile_generate_serial "$MONITOR_SERIAL_PREFIX")
        fresh_mac=$(g11_hardware_mac_generate \
            00:1B:21 00:1E:67 00:21:6A 00:22:FA 00:23:14 00:24:D7)
        printf '%s\0' "$fresh_sys" "$fresh_mb" "$fresh_chassis" \
            "$fresh_mem" "$fresh_mem_list" "$fresh_ssd" \
            "$fresh_monitor" "$fresh_mac"
    )
    [[ ${#fresh_identity[@]} == 8 ]] || fail 'cannot reroll copied VM identity'
    awk \
        -v sys="${fresh_identity[0]}" \
        -v mb="${fresh_identity[1]}" \
        -v chassis="${fresh_identity[2]}" \
        -v mem="${fresh_identity[3]}" \
        -v mem_list="${fresh_identity[4]}" \
        -v ssd="${fresh_identity[5]}" \
        -v monitor="${fresh_identity[6]}" \
        -v mac="${fresh_identity[7]}" '
        /^SYS_SN=/ { print "SYS_SN=\"" sys "\""; next }
        /^MB_SN=/ { print "MB_SN=\"" mb "\""; next }
        /^CHASSIS_SN=/ { print "CHASSIS_SN=\"" chassis "\""; next }
        /^MEM_SN=/ { print "MEM_SN=\"" mem "\""; next }
        /^MEM_SERIAL_LIST=/ {
            print "MEM_SERIAL_LIST=\"" mem_list "\""
            next
        }
        /^SSD_SN=/ { print "SSD_SN=\"" ssd "\""; next }
        /^MONITOR_SERIAL=/ { print "MONITOR_SERIAL=\"" monitor "\""; next }
        /^VM_MAC=/ { print "VM_MAC=" mac; next }
        { print }
    ' "$target_conf" >"$target_conf.rerolled"
    mv -f -- "$target_conf.rerolled" "$target_conf"
    unset fresh_identity
    chmod 444 "$target_conf"
}

# The listing is both the public deterministic test interface and a guard
# against silently adding an unreviewed model to the random pool.
mapfile -t listed_ssds < <(
    "$CREATE_VM" --list-ssd-profiles \
        | awk 'NF && $1 != "PROFILE" { print $1 }' | sort
)
expected_ssds=(
    crucial-mx100-512gb
    intel-545s-512gb
    kingston-kc400-512gb
    samsung-840-pro-512gb
    samsung-850-pro-512gb
    samsung-860-pro-512gb
    samsung-960-pro-512gb
    samsung-970-pro-512gb
    wd-black-pcie-512gb
    wd-pc-sa530-512gb
)
mapfile -t expected_ssds_sorted < <(printf '%s\n' "${expected_ssds[@]}" | sort)
assert_eq "${expected_ssds_sorted[*]}" "${listed_ssds[*]}" "SSD profile list"

HARDWARE_PROFILES="$REPO_ROOT/deploy/lib/hardware-profiles.sh"
[[ -r "$HARDWARE_PROFILES" ]] || fail "hardware profile library is missing"
# shellcheck source=/dev/null
source "$HARDWARE_PROFILES"
assert_eq 13 "${#CPU_PROFILES[@]}" 'CPU component catalog count'
assert_eq 16 "${#BOARD_PROFILES[@]}" 'board component catalog count'
assert_eq 5 "${#CHIPSET_PRESENTATION_PROFILES[@]}" \
    'chipset presentation catalog count'
assert_eq 5 "${#CPU_HOST_BRIDGE_PRESENTATION_PROFILES[@]}" \
    'active X79 CPU host bridge presentation catalog count'
assert_eq 45 "${#MEMORY_PROFILES[@]}" 'memory component catalog count'
assert_eq 524 "${#HARDWARE_COMBINATIONS[@]}" 'reviewed combination count'
assert_eq 276 "${#HARDWARE_NEW_PROFILE_KEYS[@]}" 'default-new combination count'
assert_eq 158 "${#HARDWARE_EXPLICIT_NEW_PROFILE_KEYS[@]}" \
    'explicit-new combination count'
assert_eq 87 "${#HARDWARE_ARCHIVED_PROFILE_KEYS[@]}" \
    'archived combination count'
assert_eq 3 "${#HARDWARE_LEGACY_COMPAT_PROFILE_KEYS[@]}" \
    'legacy combination count'

assert_eq \
    'g3220 i3-4130 i5-4460 i5-4570 i5-4590 i7-4790 i5-6500 i3-8100 i7-3820 i7-3930k i7-4820k i7-4930k i7-4960x' \
    "$(cpu_profile_keys | tr '\n' ' ' | sed 's/ $//')" \
    'exact CPU component keys'
assert_eq \
    'asus-h81m-k asus-h81m-c gigabyte-h81m-s1 msi-h81m-p33 gigabyte-h97-d3h gigabyte-b150m-d3h asus-prime-b360m-a asus-h81m-plus asus-h81m-a gigabyte-h81m-ds2 msi-h81m-e33 asrock-h81m-hds ecs-h81h3-m4 asus-p9x79 gigabyte-x79-up4 asrock-x79-extreme4' \
    "$(board_profile_keys | tr '\n' ' ' | sed 's/ $//')" \
    'exact board component keys'
assert_eq 'H81|H81|0x8086|0x8C5C|0x04' \
    "$(hardware_chipset_identity_for_platform i3-4130-h81m-s1-6g)" \
    'GA-H81M-S1 presents H81 LPC instead of ICH9'
assert_eq 'H97|H97|0x8086|0x8CC6|0x00' \
    "$(hardware_chipset_identity_for_platform i5-4590)" \
    'H97 legacy platform LPC identity'
assert_eq 'B150|B150|0x8086|0xA148|0x31' \
    "$(hardware_chipset_identity_for_platform i5-6500)" \
    'B150 legacy platform LPC identity'
assert_eq 'B360|B360|0x8086|0xA308|0x10' \
    "$(hardware_chipset_identity_for_platform i3-8100)" \
    'B360 legacy platform LPC identity'
assert_eq 'X79|X79|0x8086|0x1D41|0x06' \
    "$(hardware_chipset_identity_for_platform i7-4820k-p9x79-micron-16g)" \
    'P9X79 presents the reviewed X79 LPC identity'
assert_eq 'IvyBridge-E|0x8086|0x0E00|0x04' \
    "$(hardware_cpu_host_bridge_identity_for_platform i7-4820k-p9x79-micron-16g)" \
    'i7-4820K X79 presents the reviewed Ivytown DMI2 identity'
assert_eq 'IvyBridge-E|0x8086|0x0E00|0x04' \
    "$(hardware_cpu_host_bridge_identity_for_platform i7-4930k-p9x79-samsung-4g)" \
    'i7-4930K X79 presents the reviewed Ivy Bridge-E DMI2 identity'
assert_eq 'SandyBridge-E|0x8086|0x3C00|0x07' \
    "$(hardware_cpu_host_bridge_identity_for_platform i7-3820-p9x79-kingston-4g)" \
    'i7-3820 X79 presents the reviewed Sandy Bridge-E DMI2 identity'
assert_eq 'SandyBridge-E|0x8086|0x3C00|0x07' \
    "$(hardware_cpu_host_bridge_identity_for_platform i7-3930k-p9x79-samsung-8g)" \
    'i7-3930K X79 presents the reviewed Sandy Bridge-E DMI2 identity'
assert_eq 'IvyBridge-E|0x8086|0x0E00|0x04' \
    "$(hardware_cpu_host_bridge_identity_for_platform i7-4960x-x79-up4-elpida-12g)" \
    'i7-4960X X79 presents the reviewed Ivy Bridge-E DMI2 identity'
if hardware_cpu_host_bridge_identity_for_platform i3-4130-h81m-s1-6g \
        >/dev/null 2>&1; then
    fail 'archived H81 platform unexpectedly received an X79 CPU host bridge identity'
fi
assert_eq \
    'kvr13n9s6-2x2 kvr13n9-flex-4plus2 kvr13n9s8-2x4 kvr16n11s6-2x2 kvr16n11-flex-4plus2 kvr16n11s8-2x4 samsung-m378b5773dh0-2x2 samsung-m378b5-flex-4plus2 samsung-m378b5273dh0-2x4 micron-mt4jtf25664az-2x2 micron-mtjtf-flex-4plus2 micron-mt8jtf51264az-2x4 hynix-hmt325u6cfr8c-2x2 hynix-hmt3x5-flex-4plus2 hynix-hmt351u6cfr8c-2x4 samsung-m378b5773dh0-1333-2x2 samsung-m378b5-1333-flex-4plus2 samsung-m378b5273dh0-1333-2x4 micron-mt8jtf25664az-1333-2x2 micron-mtjtf-1333-flex-4plus2 micron-mt8jtf51264az-1333-2x4 hynix-hmt325u6cfr8c-1333-2x2 hynix-hmt3x5-1333-flex-4plus2 hynix-hmt351u6cfr8c-1333-2x4 kvr16n11s8-3x4 kvr16n11s8-4x4 samsung-m378b5273dh0-3x4 samsung-m378b5273dh0-4x4 micron-mt8jtf51264az-3x4 micron-mt8jtf51264az-4x4 hynix-hmt351u6cfr8c-3x4 hynix-hmt351u6cfr8c-4x4 elpida-ebj40ug8bfw0-2x4 elpida-ebj40ug8bfw0-3x4 elpida-ebj40ug8bfw0-4x4 micron-mt8ktf51264az-2x4 micron-mt8ktf51264az-3x4 micron-mt8ktf51264az-4x4 samsung-m378b5773dh0-1866-2x2 samsung-m378b5173qh0-1866-2x4 samsung-m378b5173qh0-1866-3x4 samsung-m378b5173qh0-1866-4x4 kvr21n15s8-2x4 kvr24n17s8-2x4 crucial-ct51264bd160b-2x4' \
    "$(memory_profile_keys | tr '\n' ' ' | sed 's/ $//')" \
    'exact memory component keys'

# Every memory row is a two-to-four-slot desktop layout with an explicit v3
# physical rank/device/JEP106 tuple.  This audits all 45 rows, including profiles not
# selected by the smaller end-to-end representative set below.
for memory_key in $(memory_profile_keys); do
    memory_profile_load "$memory_key"
    [[ "$MEM_SLOTS" =~ ^[234]$ ]] || \
        fail "$memory_key has an invalid populated slot count: $MEM_SLOTS"
    assert_eq DIMM "$MEM_FORM_FACTOR" "$memory_key desktop form factor"
    [[ "$MEM_MODULE_MB_LIST" =~ ^(2048|4096)(,(2048|4096)){1,3}$ ]] \
        || fail "$memory_key has an invalid capacity list: $MEM_MODULE_MB_LIST"
    [[ "$MEM_RANK_LIST" =~ ^[12](,[12]){1,3}$ ]] \
        || fail "$memory_key has an invalid rank list: $MEM_RANK_LIST"
    [[ "$MEM_DEVICE_WIDTH_LIST" =~ ^(8|16)(,(8|16)){1,3}$ ]] \
        || fail "$memory_key has an invalid device-width list: $MEM_DEVICE_WIDTH_LIST"
    [[ "$MEM_MODULE_MFR_JEP106_LIST" =~ ^[0-9A-F]{4}(,[0-9A-F]{4}){1,3}$ ]] \
        || fail "$memory_key has invalid module JEP106 codes: $MEM_MODULE_MFR_JEP106_LIST"
    [[ "$MEM_DRAM_MFR_JEP106_LIST" =~ ^[0-9A-F]{4}(,[0-9A-F]{4}){1,3}$ ]] \
        || fail "$memory_key has invalid DRAM JEP106 codes: $MEM_DRAM_MFR_JEP106_LIST"
done

# The active pool restores the six mainstream CPUs and keeps five X79 CPUs.
active_cpu_keys=()
legacy_only_cpu_keys=()
for cpu_key in $(cpu_profile_keys); do
    active_count=0
    legacy_count=0
    for combination in "${HARDWARE_COMBINATIONS[@]}"; do
        IFS='|' read -r _ combination_cpu _ _ combination_lifecycle \
            <<<"$combination"
        [[ "$combination_cpu" == "$cpu_key" ]] || continue
        case "$combination_lifecycle" in
            new|explicit-new) active_count=$((active_count + 1)) ;;
            legacy-compatibility) legacy_count=$((legacy_count + 1)) ;;
        esac
    done
    (( active_count == 0 )) || active_cpu_keys+=("$cpu_key")
    (( active_count != 0 || legacy_count == 0 )) || legacy_only_cpu_keys+=("$cpu_key")
done
assert_eq 'g3220 i3-4130 i5-4460 i5-4570 i5-4590 i7-4790 i7-3820 i7-3930k i7-4820k i7-4930k i7-4960x' \
    "${active_cpu_keys[*]}" 'eleven active CPU profiles'
assert_eq 'i5-6500 i3-8100' "${legacy_only_cpu_keys[*]}" \
    'two legacy-only CPU profiles'

# Active boards contain ten reviewed H81 models plus three consumer X79 models.
mapfile -t active_board_keys < <(
    for combination in "${HARDWARE_COMBINATIONS[@]}"; do
        IFS='|' read -r _ _ combination_board _ combination_lifecycle \
            <<<"$combination"
        [[ "$combination_lifecycle" == new ||
           "$combination_lifecycle" == explicit-new ]] || continue
        printf '%s\n' "$combination_board"
    done | awk '!seen[$0]++'
)
assert_eq 'asus-h81m-k gigabyte-h81m-s1 asus-h81m-c msi-h81m-p33 asus-h81m-plus asus-h81m-a msi-h81m-e33 gigabyte-h81m-ds2 asrock-h81m-hds ecs-h81h3-m4 asus-p9x79 gigabyte-x79-up4 asrock-x79-extreme4' \
    "${active_board_keys[*]}" 'thirteen active board profiles'
for board_key in "${active_board_keys[@]}"; do
    board_profile_load "$board_key"
    case "$BOARD_CHIPSET:$MEM_BOARD_SLOTS" in
        H81:2|X79:4|X79:8) ;;
        *) fail "$board_key has an unsupported active board layout" ;;
    esac
done
for board_key in gigabyte-h97-d3h gigabyte-b150m-d3h asus-prime-b360m-a; do
    board_profile_load "$board_key"
    assert_eq 4 "$MEM_BOARD_SLOTS" "$board_key legacy DIMM slots"
done
if memory_profile_keys | grep -Eq -- '(^|-)4x2($|-)'; then
    fail '4x2 GiB memory profile returned to the catalog'
fi
for combination in "${HARDWARE_COMBINATIONS[@]}"; do
    IFS='|' read -r combination_key _ combination_board combination_memory \
        combination_lifecycle <<<"$combination"
    [[ "$combination_lifecycle" == new ||
       "$combination_lifecycle" == explicit-new ]] || continue
    board_profile_load "$combination_board"
    memory_profile_load "$combination_memory"
    case "$MEM_TOTAL_MB:$MEM_SLOTS:$MEM_CHANNEL_MODE" in
        4096:2:dual-channel|8192:2:dual-channel|\
        12288:3:triple-channel|16384:4:quad-channel) ;;
        *) fail "$combination_key violates the 4/8/12/16 channel contract" ;;
    esac
    if (( MEM_TOTAL_MB >= 12288 && MEM_BOARD_SLOTS < 4 )); then
        fail "$combination_key offers 12/16 GiB on a board with fewer than four slots"
    fi
done
mapfile -t default_ssds < <(ssd_default_profile_keys)
assert_eq 'samsung-840-pro-512gb samsung-850-pro-512gb samsung-860-pro-512gb crucial-mx100-512gb kingston-kc400-512gb intel-545s-512gb wd-pc-sa530-512gb' \
    "${default_ssds[*]}" "default exact-512 GB SSD pool"

best_default_ssds_for_platform() {
    local platform=$1 candidate candidate_tier best_tier=999
    local -a candidates=()

    while IFS= read -r candidate; do
        ssd_profile_load "$candidate" || return
        hardware_storage_combination_allowed "$platform" "$SSD_INTERFACE" \
            "$SSD_PCIE_GEN" "$SSD_PCIE_LANES" "$SSD_FORM_FACTOR" || continue
        candidate_tier=$(hardware_storage_preference_tier \
            "$SSD_INTERFACE" "$SSD_PCIE_GEN" "$SSD_PCIE_LANES")
        if (( candidate_tier < best_tier )); then
            candidates=()
            best_tier=$candidate_tier
        fi
        (( candidate_tier == best_tier )) || continue
        candidates+=("$candidate")
    done < <(ssd_auto_profile_keys)
    printf '%s\n' "${candidates[@]}" | sort
}

assert_eq \
    'crucial-mx100-512gb intel-545s-512gb kingston-kc400-512gb samsung-840-pro-512gb samsung-850-pro-512gb samsung-860-pro-512gb wd-pc-sa530-512gb' \
    "$(best_default_ssds_for_platform i7-3820-p9x79-kingston-4g | tr '\n' ' ' | sed 's/ $//')" \
    "i7-3820 Gen2 CPU falls back to the exact SATA tier"
assert_eq \
    'samsung-960-pro-512gb samsung-970-pro-512gb wd-black-pcie-512gb' \
    "$(best_default_ssds_for_platform i7-4820k-p9x79-micron-16g | tr '\n' ' ' | sed 's/ $//')" \
    "i7-4820K X79 passive-adapter Gen3 x4 NVMe tier"
assert_eq \
    'samsung-960-pro-512gb samsung-970-pro-512gb wd-black-pcie-512gb' \
    "$(best_default_ssds_for_platform i7-4930k-p9x79-samsung-4g | tr '\n' ' ' | sed 's/ $//')" \
    "i7-4930K X79 passive-adapter Gen3 x4 NVMe tier"
assert_eq \
    'samsung-960-pro-512gb samsung-970-pro-512gb wd-black-pcie-512gb' \
    "$(best_default_ssds_for_platform i5-6500 | tr '\n' ' ' | sed 's/ $//')" \
    "B150 best-tier NVMe candidate set"
assert_eq \
    'samsung-960-pro-512gb samsung-970-pro-512gb wd-black-pcie-512gb' \
    "$(best_default_ssds_for_platform i3-8100 | tr '\n' ' ' | sed 's/ $//')" \
    "B360 best-tier NVMe candidate set"
for catalog_oui in "${INTEL_OUIS[@]}"; do
    case "$catalog_oui" in
        00:1B:21|00:1E:67|00:21:6A|00:22:FA|00:23:14|00:24:D7 \
        |8C:8D:28|A0:36:9F|A4:C3:F0) ;;
        *) fail "hardware catalog contains an OUI not registered to Intel: $catalog_oui" ;;
    esac
done

# These four OUIs belonged to ASUS, Dell and ECS, not Intel.  Reject them
# statically as well as checking every generated MAC against the Intel list.
for non_intel_oui in 00:1F:C6 00:25:64 1C:69:7A 18:66:DA; do
    reject_text "\"$non_intel_oui\"" "$CREATE_VM" "non-Intel OUI $non_intel_oui"
done

platform_catalog="$TMP_DIR/platform-catalog.out"
"$CREATE_VM" --list-platforms >"$platform_catalog"
fallback_platform_catalog="$TMP_DIR/platform-catalog-fallback.out"
"$CREATE_VM" --include-fallback --list-platforms >"$fallback_platform_catalog"
cpu_catalog="$TMP_DIR/cpu-catalog.out"
"$CREATE_VM" --list-cpu-profiles >"$cpu_catalog"
fallback_cpu_catalog="$TMP_DIR/cpu-catalog-fallback.out"
"$CREATE_VM" --include-fallback --list-cpu-profiles >"$fallback_cpu_catalog"
assert_eq 434 "$(( $(wc -l <"$platform_catalog") - 1 ))" \
    'default visible platform count'
assert_eq 524 "$(( $(wc -l <"$fallback_platform_catalog") - 1 ))" \
    'fallback-visible platform count'
assert_eq 11 "$(( $(wc -l <"$cpu_catalog") - 1 ))" \
    'default visible CPU count'
assert_eq 13 "$(( $(wc -l <"$fallback_cpu_catalog") - 1 ))" \
    'fallback-visible CPU count'
require_text $'i7-4820k\tCore-i7-4820K\t4C/8T\t3700/3900\t10240' \
    "$cpu_catalog" 'i7-4820K 4C/8T and 10 MiB LLC catalog row'
require_text $'i7-3820\tCore-i7-3820\t4C/8T\t3600/3800\t10240' \
    "$cpu_catalog" 'i7-3820 4C/8T and 10 MiB LLC catalog row'
require_text $'i7-4930k\tCore-i7-4930K\t6C/12T\t3400/3900\t12288' \
    "$cpu_catalog" 'i7-4930K 6C/12T and 12 MiB LLC catalog row'
require_text $'i7-3930k\tCore-i7-3930K\t6C/12T\t3200/3800\t12288' \
    "$cpu_catalog" 'i7-3930K 6C/12T and 12 MiB LLC catalog row'
require_text $'i7-4960x\tCore-i7-4960X\t6C/12T\t3600/4000\t15360' \
    "$cpu_catalog" 'i7-4960X 6C/12T and 15 MiB LLC catalog row'
require_text $'i7-4820k-p9x79-micron-16g\tCore-i7-4820K 4C/8T\tASUSTeK COMPUTER INC. P9X79\tX79' \
    "$platform_catalog" 'ASUS X79 high-frequency quad-channel row'
require_text $'i7-4820k-x79-up4-elpida-12g\tCore-i7-4820K 4C/8T\tGigabyte GA-X79-UP4\tX79' \
    "$platform_catalog" 'Gigabyte X79 high-frequency triple-channel row'
require_text $'i7-3820-x79-extreme4-samsung-16g\tCore-i7-3820 4C/8T\tASRock X79 Extreme4\tX79' \
    "$platform_catalog" 'ASRock X79 quad-channel row'
require_text $'i7-4930k-p9x79-samsung-4g\tCore-i7-4930K 6C/12T\tASUSTeK COMPUTER INC. P9X79\tX79' \
    "$platform_catalog" 'normal-pool i7-4930K/Samsung DDR3-1866 row'
require_text $'i7-4930k-x79-up4-elpida-12g\tCore-i7-4930K 6C/12T\tGigabyte GA-X79-UP4\tX79' \
    "$platform_catalog" 'normal-pool i7-4930K/Gigabyte/Elpida row'
require_text $'i7-4930k-x79-extreme4-hynix-16g\tCore-i7-4930K 6C/12T\tASRock X79 Extreme4\tX79' \
    "$platform_catalog" 'normal-pool i7-4930K/ASRock/SK hynix row'
require_text $'i7-3930k-p9x79-samsung-8g\tCore-i7-3930K 6C/12T\tASUSTeK COMPUTER INC. P9X79\tX79' \
    "$platform_catalog" 'normal-pool i7-3930K/ASUS/Samsung row'
require_text $'i7-4960x-x79-up4-elpida-12g\tCore-i7-4960X 6C/12T\tGigabyte GA-X79-UP4\tX79' \
    "$platform_catalog" 'normal-pool i7-4960X/Gigabyte/Elpida row'
reject_text $'i5-6500\tCore-i5-6500' "$platform_catalog" \
    'default platform catalog legacy B150 row'
require_text $'g3220-h81m-k-4g\tIntel-Pentium-G3220 2C/2T\tASUSTeK COMPUTER INC. H81M-K\tH81' \
    "$platform_catalog" 'default platform catalog restored G3220/H81 row'
require_text $'i3-4130-h81m-p33-8g\tCore-i3-4130 2C/4T\tMSI H81M-P33 (MS-7817)\tH81' \
    "$platform_catalog" 'default platform catalog restored i3/H81 row'
reject_text '-6g' "$platform_catalog" 'default platform catalog archived 6G row'
reject_text 'legacy-compatibility' "$platform_catalog" \
    'default platform catalog compatibility policy'
require_text $'i5-6500\tCore-i5-6500' "$fallback_platform_catalog" \
    'legacy B150 platform catalog row'
require_text 'archived' "$fallback_platform_catalog" \
    'fallback catalog archived policy'
require_text 'legacy-compatibility' "$fallback_platform_catalog" \
    'platform catalog compatibility policy'

fresh_compat_id=779998
if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
        IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
        VGPU_HOST_CONFIG="$HOST_2GB_CONFIG" \
        "$CREATE_VM" "$fresh_compat_id" --platform i5-6500 \
        --gpu-profile gtx1050_2gb --monitor-profile lenovo-d24-20 \
        >"$TMP_DIR/fresh-compat.out" 2>"$TMP_DIR/fresh-compat.err"; then
    fail 'fresh VM accepted a compatibility-only CPU/platform'
fi
require_text '仅保留给已有 VM' "$TMP_DIR/fresh-compat.err" \
    'fresh compatibility platform refusal'

fresh_authorized_compat_id=779997
env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
    IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
    VGPU_HOST_CONFIG="$HOST_2GB_CONFIG" \
    "$CREATE_VM" "$fresh_authorized_compat_id" --platform i5-6500 \
    --allow-fallback-platform --ssd-profile samsung-970-pro-512gb \
    --gpu-profile gtx1050_2gb --monitor-profile lenovo-d24-20 \
    >"$TMP_DIR/fresh-authorized-compat.out" \
    2>"$TMP_DIR/fresh-authorized-compat.err"
# shellcheck source=/dev/null
source "$VM_ROOT/${fresh_authorized_compat_id}/vm.conf"
assert_eq i5-6500 "$PLATFORM" 'authorized compatibility platform'
assert_eq legacy-compatibility "$CPU_REALIZATION_POLICY" \
    'authorized compatibility CPU policy'
require_text '用户显式授权新建旧平台兜底配置' \
    "$TMP_DIR/fresh-authorized-compat.err" \
    'authorized compatibility warning'

default_new_id=779999
env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
    IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
    VGPU_HOST_CONFIG="$HOST_2GB_CONFIG" \
    "$CREATE_VM" "$default_new_id" --gpu-profile gtx1050_2gb \
    --monitor-profile lenovo-d24-20 >"$TMP_DIR/default-new.out"
# shellcheck source=/dev/null
source "$VM_ROOT/${default_new_id}/vm.conf"
assert_eq new "$(hardware_profile_lifecycle_class "$PLATFORM")" \
    'implicit creation active lifecycle'
assert_eq enforced "$CPU_REALIZATION_POLICY" \
    'implicit creation enforced CPU realization'
assert_eq 3 "$G11_HARDWARE_CONTRACT_VERSION" \
    'implicit creation hardware contract'
assert_eq i7-4960x "$CPU_PROFILE" \
    'implicit creation performance-first CPU'
assert_eq 1866 "$MEM_SPEED" \
    'implicit creation performance-first memory speed'
assert_eq 8192 "$MEM_TOTAL_MB" \
    'implicit creation default 8G memory capacity'
assert_eq X79 "$BOARD_CHIPSET" 'implicit creation X79 chipset'

# Component selectors resolve only to a reviewed combination.  A valid exact
# triple succeeds; a plausible but unreviewed Cartesian mix fails before any
# VM directory is created.
component_id=780000
env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
    IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
    VGPU_HOST_CONFIG="$HOST_2GB_CONFIG" \
    "$CREATE_VM" "$component_id" \
    --cpu-profile i7-4820k --board-profile gigabyte-x79-up4 \
    --memory-profile elpida-ebj40ug8bfw0-3x4 \
    --ssd-profile samsung-850-pro-512gb \
    --gpu-profile gtx1050_2gb --monitor-profile lenovo-d24-20 \
    >"$TMP_DIR/component-valid.out"
# shellcheck source=/dev/null
source "$VM_ROOT/${component_id}/vm.conf"
assert_eq i7-4820k-x79-up4-elpida-12g "$PLATFORM" \
    'component selector combination'

illegal_component_id=780099
if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
        IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
        VGPU_HOST_CONFIG="$HOST_2GB_CONFIG" \
        "$CREATE_VM" "$illegal_component_id" \
        --cpu-profile i7-3820 --board-profile asus-p9x79 \
        --memory-profile elpida-ebj40ug8bfw0-3x4 \
        >"$TMP_DIR/component-illegal.out" \
        2>"$TMP_DIR/component-illegal.err"; then
    fail 'unreviewed CPU/board/memory Cartesian product was accepted'
fi
require_text '没有通过审核的 CPU/主板/内存组合' \
    "$TMP_DIR/component-illegal.err" 'illegal component combination refusal'
[[ ! -e "$VM_ROOT/${illegal_component_id}/vm.conf" ]] || \
    fail 'illegal component selection persisted a VM hardware contract'

# Capacity selectors keep the operator-facing choice small while source still
# persists one complete audited platform/GPU row.
capacity_selector_id=780098
capacity_vm_root="$TMP_DIR/capacity-vms"
env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
    IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$capacity_vm_root" \
    VGPU_HOST_CONFIG="$HOST_1GB_CONFIG" \
    "$CREATE_VM" "$capacity_selector_id" \
    --memory-size 12G --ssd-profile samsung-970-pro-512gb \
    --gpu-vram 1024 --monitor-profile lenovo-d24-20 \
    >"$TMP_DIR/capacity-selector.out"
# shellcheck source=/dev/null
source "$capacity_vm_root/${capacity_selector_id}/vm.conf"
assert_eq 12288 "$MEM_TOTAL_MB" 'memory capacity selector'
assert_eq 3 "$MEM_SLOTS" '12G populated DIMM count'
assert_eq triple-channel "$MEM_CHANNEL_MODE" '12G channel mode'
assert_eq 1024 "$GPU_VRAM_MB" 'GPU VRAM capacity selector'
assert_eq nvidia-256 "$VGPU_MDEV_PROFILE" '1GB GPU resource mapping'
[[ "$(hardware_profile_lifecycle_class "$PLATFORM")" != legacy-compatibility ]] || \
    fail 'capacity selectors pulled a hidden compatibility platform'

declare -A PLATFORM_IDS=()
next_id=780001
for platform in \
        i7-4960x-x79-up4-elpida-12g \
        i7-4930k-p9x79-samsung-4g \
        i7-4930k-x79-up4-elpida-12g \
        i7-4930k-x79-extreme4-hynix-16g \
        i7-4820k-p9x79-micron-16g \
        i7-4820k-x79-up4-elpida-12g \
        i7-4820k-x79-extreme4-kingston-8g \
        i7-3820-p9x79-kingston-4g \
        i7-3820-x79-up4-samsung-12g \
        i7-3820-x79-extreme4-samsung-16g \
        i7-3930k-p9x79-samsung-8g \
        i5-4590 i5-6500 i3-8100; do
    id=$next_id
    next_id=$((next_id + 1))
    output="$TMP_DIR/create-$id.out"
    platform_ssd=samsung-860-pro-512gb
    if [[ "$platform" == i7-4820k-* || "$platform" == i7-4930k-* ||
          "$platform" == i7-4960x-* ||
          "$platform" == i5-6500 || "$platform" == i3-8100 ]]; then
        platform_ssd=samsung-970-pro-512gb
    fi
    create_vm "$id" "$platform" "$platform_ssd" "$output"
    require_text 'B 模式 PCI identity 保持宿主 mdev' "$output" \
        "$platform create summary B-mode identity"
    require_text '  键盘:' "$output" "$platform create keyboard summary"
    require_text '  绝对指针:' "$output" "$platform create pointer summary"
    conf="$VM_ROOT/${id}/vm.conf"
    [[ -r "$conf" ]] || fail "$platform did not create vm.conf"
    # shellcheck source=/dev/null
    source "$conf"
    assert_platform "$platform" "$platform"
    expected_family=$PLATFORM_EXPECTED_CPU_FAMILY
    expected_socket=$PLATFORM_EXPECTED_CPU_SOCKET
    expected_board_revision=$PLATFORM_EXPECTED_BOARD_REVISION
    expected_board_revision_argv=${expected_board_revision// /\\ }
    expected_board_slots=$PLATFORM_EXPECTED_BOARD_SLOTS
    expected_max_memory=$PLATFORM_EXPECTED_MAX_MEMORY
    expected_l2_assoc=$PLATFORM_EXPECTED_L2_ASSOC
    expected_l3_assoc=$PLATFORM_EXPECTED_L3_ASSOC
    expected_main_slot=$PLATFORM_EXPECTED_MAIN_SLOT
    expected_main_type=$PLATFORM_EXPECTED_MAIN_TYPE
    expected_aux_slot=$PLATFORM_EXPECTED_AUX_SLOT
    expected_aux_type=$PLATFORM_EXPECTED_AUX_TYPE
    expected_aux_width=$PLATFORM_EXPECTED_AUX_WIDTH
    expected_aux_length=$PLATFORM_EXPECTED_AUX_LENGTH
    assert_serials "$platform"
    assert_intel_mac "$platform"
    assert_ssd_profile "$platform"
    assert_input_profiles "$platform"
    PLATFORM_IDS[$platform]=$id

    runtime_out="$TMP_DIR/runtime-$id.out"
    runtime_err="$TMP_DIR/runtime-$id.err"
    if ! run_start "$id" "$runtime_out" "$runtime_err" --no-gpu --no-tpm; then
        sed "s/^/${platform}: /" "$runtime_err" >&2 || true
        fail "$platform start-vm dry-run failed"
    fi
    if [[ "$PLATFORM_EXPECTED_LIFECYCLE" == new ||
          "$PLATFORM_EXPECTED_LIFECYCLE" == explicit-new ]]; then
        require_text 'CPU realization: policy=enforced class=not-probed-dry-run enforce=on' \
            "$runtime_out" "$platform enforced CPU policy"
        require_text "${CPU_MODEL}\\,enforce=on" "$runtime_out" \
            "$platform enforced QEMU CPU argv"
    else
        require_text 'CPU realization: policy=legacy-compatibility class=not-probed-dry-run enforce=off' \
            "$runtime_out" "$platform compatibility CPU policy"
        require_text "${CPU_MODEL}\\,enforce=off" "$runtime_out" \
            "$platform compatibility QEMU CPU argv"
    fi
    require_text '硬件合法性: strict/OK' "$runtime_out" \
        "$platform strict hardware gate summary"
    require_text "processor-family=${expected_family}" "$runtime_out" \
        "$platform SMBIOS processor family"
    require_text "processor-upgrade=${expected_socket}" "$runtime_out" \
        "$platform SMBIOS processor socket"
    require_text "version=${expected_board_revision_argv}\\,serial=${MB_SN}" \
        "$runtime_out" "$platform SMBIOS board revision"
    require_text "slot_designation=${expected_main_slot}\\,slot_type=${expected_main_type}\\,slot_data_bus_width=13" \
        "$runtime_out" "$platform SMBIOS CPU-side PCIe x16 slot"
    require_text "slot_designation=${expected_aux_slot}\\,slot_type=${expected_aux_type}\\,slot_data_bus_width=${expected_aux_width}\\,current_usage=4\\,slot_length=${expected_aux_length}" \
        "$runtime_out" "$platform SMBIOS occupied auxiliary PCIe slot"
    require_text 'type=17\,' "$runtime_out" "$platform SMBIOS Type 17"
    if grep -F -- 'type=17\,' "$runtime_out" | grep -Fq -- 'asset='; then
        fail "$platform SMBIOS Type 17 invented a DIMM asset tag"
    fi
    assert_no_persistent_optical_contract "$runtime_out" \
        "$platform normal dry-run"
    require_text "type=16\,max-capacity=${expected_max_memory}G\,num-devices=${expected_board_slots}" \
        "$runtime_out" "$platform SMBIOS physical memory array"
    if [[ "$BOARD_CHIPSET" == X79 && "$expected_board_slots" == 8 ]]; then
        require_text 'loc_pfx=DIMM_A1\|DIMM_B1\|DIMM_C1\|DIMM_D1\|DIMM_A2\|DIMM_B2\|DIMM_C2\|DIMM_D2' \
            "$runtime_out" "$platform exact X79 eight-slot DIMM locators"
        require_text 'bank=P0\ CHANNEL\ A\|P0\ CHANNEL\ B\|P0\ CHANNEL\ C\|P0\ CHANNEL\ D\|P0\ CHANNEL\ A\|P0\ CHANNEL\ B\|P0\ CHANNEL\ C\|P0\ CHANNEL\ D' \
            "$runtime_out" "$platform exact X79 eight-slot DIMM banks"
    elif [[ "$BOARD_CHIPSET" == X79 && "$expected_board_slots" == 4 ]]; then
        require_text 'loc_pfx=DIMM_A1\|DIMM_B1\|DIMM_C1\|DIMM_D1' \
            "$runtime_out" "$platform exact X79 four-slot DIMM locators"
        require_text 'bank=P0\ CHANNEL\ A\|P0\ CHANNEL\ B\|P0\ CHANNEL\ C\|P0\ CHANNEL\ D' \
            "$runtime_out" "$platform exact X79 four-slot DIMM banks"
    elif [[ "$expected_board_slots" == 4 && "$MEM_SLOTS" == 4 ]]; then
        require_text 'loc_pfx=DIMM_A1\|DIMM_A2\|DIMM_B1\|DIMM_B2' \
            "$runtime_out" "$platform exact DIMM locators"
        require_text 'bank=P0\ CHANNEL\ A\|P0\ CHANNEL\ A\|P0\ CHANNEL\ B\|P0\ CHANNEL\ B' \
            "$runtime_out" "$platform exact DIMM banks"
    elif [[ "$expected_board_slots" == 4 && "$MEM_SLOTS" == 2 ]]; then
        require_text 'loc_pfx=DIMM_A2\|DIMM_B2\|DIMM_A1\|DIMM_B1' \
            "$runtime_out" "$platform exact two-of-four DIMM locators"
        require_text 'bank=P0\ CHANNEL\ A\|P0\ CHANNEL\ B\|P0\ CHANNEL\ A\|P0\ CHANNEL\ B' \
            "$runtime_out" "$platform exact two-of-four DIMM banks"
    else
        require_text 'loc_pfx=DIMM_A1\|DIMM_B1' "$runtime_out" \
            "$platform exact two-slot DIMM locators"
        require_text 'bank=P0\ CHANNEL\ A\|P0\ CHANNEL\ B' "$runtime_out" \
            "$platform exact two-slot DIMM banks"
    fi
    expected_part_argv=${MEM_MODEL_LIST//,/\\|}
    require_text "part=${expected_part_argv}" "$runtime_out" \
        "$platform per-slot DIMM parts"
    expected_mem_serial_list=$MEM_SERIAL_LIST
    expected_mem_serial_pipe=${MEM_SERIAL_LIST//,/|}
    expected_mem_serial_pipe_argv=${expected_mem_serial_pipe//|/\\|}
    require_text "serial=${expected_mem_serial_pipe_argv}" "$runtime_out" \
        "$platform exact distinct per-DIMM serial list"
    printf -v expected_spd_list_argv '%q' "$MEM_MODULE_MB_LIST"
    require_text "QEMU_SPD_TYPE=${MEM_FAMILY}" "$runtime_out" \
        "$platform SPD memory family"
    require_text "QEMU_SPD_SPEED_MT=${MEM_SPEED}" "$runtime_out" \
        "$platform SPD transfer rate"
    require_text "QEMU_SPD_SLOTS=${MEM_SLOTS}" "$runtime_out" \
        "$platform SPD populated slots"
    require_text "QEMU_SPD_MODULE_MB_LIST=${expected_spd_list_argv}" \
        "$runtime_out" "$platform per-slot SPD capacity list"
    reject_text 'QEMU_SPD_MODULE_MB=' "$runtime_out" \
        "$platform obsolete scalar SPD capacity"
    if [[ "$MEM_FAMILY" == DDR3 ]]; then
        printf -v expected_spd_rank_argv '%q' "$MEM_RANK_LIST"
        printf -v expected_spd_width_argv '%q' "$MEM_DEVICE_WIDTH_LIST"
        printf -v expected_spd_module_jep_argv '%q' \
            "$MEM_MODULE_MFR_JEP106_LIST"
        printf -v expected_spd_dram_jep_argv '%q' \
            "$MEM_DRAM_MFR_JEP106_LIST"
        printf -v expected_spd_serial_argv '%q' "$expected_mem_serial_list"
        printf -v expected_spd_part_argv '%q' "$MEM_MODEL_LIST"
        require_text "QEMU_SPD_RANK_LIST=${expected_spd_rank_argv}" \
            "$runtime_out" "$platform per-slot SPD rank list"
        require_text "QEMU_SPD_DEVICE_WIDTH_LIST=${expected_spd_width_argv}" \
            "$runtime_out" "$platform per-slot SPD device widths"
        require_text "QEMU_SPD_MODULE_MFR_JEP106_LIST=${expected_spd_module_jep_argv}" \
            "$runtime_out" "$platform per-slot SPD module JEP106 codes"
        require_text "QEMU_SPD_DRAM_MFR_JEP106_LIST=${expected_spd_dram_jep_argv}" \
            "$runtime_out" "$platform per-slot SPD DRAM JEP106 codes"
        require_text "QEMU_SPD_SERIAL_LIST=${expected_spd_serial_argv}" \
            "$runtime_out" "$platform per-slot SPD serial list"
        require_text "QEMU_SPD_PART_LIST=${expected_spd_part_argv}" \
            "$runtime_out" "$platform per-slot SPD part list"
    else
        for detailed_spd_var in QEMU_SPD_RANK_LIST \
                QEMU_SPD_DEVICE_WIDTH_LIST QEMU_SPD_MODULE_MFR_JEP106_LIST \
                QEMU_SPD_DRAM_MFR_JEP106_LIST QEMU_SPD_SERIAL_LIST \
                QEMU_SPD_PART_LIST; do
            reject_text "${detailed_spd_var}=" "$runtime_out" \
                "$platform DDR3-only detailed SPD variable $detailed_spd_var"
        done
    fi
    require_text 'e1000e\,netdev=net0' "$runtime_out" \
        "$platform Intel network device"
    require_text 'subsys_ven=0x8086' "$runtime_out" \
        "$platform Intel network subsystem vendor"
    require_text 'i8042=off' "$runtime_out" \
        "$platform legacy PS/2 input disabled"
    require_text "qemu-xhci\,id=xhci\,bus=${XHCI_PCI_BUS}\,addr=${XHCI_PCI_ADDR}" \
        "$runtime_out" "$platform fixed qemu-xhci placement"
    if grep -F -- 'qemu-xhci\,' "$runtime_out" |
            grep -Eq 'x-pci-(vendor-id|device-id|revision)'; then
        fail "$platform projected physical PCI facts onto qemu-xhci"
    fi
    require_text 'xHCI: qemu-xhci 1B36:000D rev01 / SUBSYS 1AF4:1100' \
        "$runtime_out" "$platform qemu-xhci behavior identity summary"
    reject_text '旧 vm.conf 缺少 xHCI PCI identity' "$runtime_err" \
        "$platform false legacy xHCI warning"
    require_text '  键盘:' "$runtime_out" "$platform runtime keyboard summary"
    require_text '  绝对指针:' "$runtime_out" "$platform runtime pointer summary"
    require_text "usb-kbd\\,id=kbd0\\,bus=xhci.0\\,usb_version=${KBD_USB_VERSION}\\,vendorid=${KBD_VID}\\,productid=${KBD_PID}\\,bcd-device=${KBD_BCD_DEVICE}" \
        "$runtime_out" "$platform USB keyboard device"
    require_text 'x-force-numlock-on=on' "$runtime_out" \
        "$platform guest-LED NumLock convergence"
    require_text "usb-tablet\\,bus=xhci.0\\,usb_version=${POINTER_USB_VERSION}\\,vendorid=${POINTER_VID}\\,productid=${POINTER_PID}\\,bcd-device=${POINTER_BCD_DEVICE}" \
        "$runtime_out" "$platform absolute USB pointer device"
    [[ "$(grep -Fc -- 'usb-kbd\,' "$runtime_out")" -eq 1 ]] \
        || fail "$platform runtime must contain exactly one usb-kbd"
    [[ "$(grep -Fc -- 'usb-tablet\,' "$runtime_out")" -eq 1 ]] \
        || fail "$platform runtime must contain exactly one usb-tablet"
    if grep -F -- 'usb-kbd\,' "$runtime_out" | grep -Fq -- 'serial=' ||
            grep -F -- 'usb-tablet\,' "$runtime_out" | grep -Fq -- 'serial='; then
        fail "$platform USB HID descriptor must not invent a serial number"
    fi
    require_text "socket_designation=L1\\ Cache\\,level=1\\,installed_size=${CPU_L1_CACHE_KB}\\,max_size=${CPU_L1_CACHE_KB}\\,associativity=7" \
        "$runtime_out" "$platform aggregate L1 cache"
    require_text "socket_designation=L2\\ Cache\\,level=2\\,installed_size=${CPU_L2_CACHE_KB}\\,max_size=${CPU_L2_CACHE_KB}\\,associativity=${expected_l2_assoc}" \
        "$runtime_out" "$platform L2 associativity"
    require_text "socket_designation=L3\\ Cache\\,level=3\\,installed_size=${CPU_L3_CACHE_KB}\\,max_size=${CPU_L3_CACHE_KB}\\,associativity=${expected_l3_assoc}" \
        "$runtime_out" "$platform L3 associativity"
    require_text '  -smp' "$runtime_out" "$platform QEMU -smp option"
    require_text "  ${CPU_VCPUS}\\,sockets=1\\,cores=${CPU_CORES}\\,threads=${CPU_THREADS_PER_CORE}" \
        "$runtime_out" "$platform QEMU topology"
    expected_rank_list_argv=${MEM_RANK_LIST//,/\\|}
    require_text "rank=${MEM_RANK}\\,rank-list=${expected_rank_list_argv}\\,voltage=${MEM_VOLTAGE_MV}" \
        "$runtime_out" "$platform SMBIOS DIMM rank-list/voltage"
    grep -Fx -- "  ${MEM_TOTAL_MB}" "$runtime_out" >/dev/null \
        || fail "$platform runtime memory is not ${MEM_TOTAL_MB} MiB"
done

# Normal modes have no optical drive.  USB/helper/answer install transports
# stay generic, and historical ODD_MODEL/ODD_SERIAL values from either the
# caller or vm.conf must not create a default drive or reach a transient one.
install_odd_id=${PLATFORM_IDS[i7-4820k-x79-extreme4-kingston-8g]}
install_odd_conf="$VM_ROOT/${install_odd_id}/vm.conf"
install_odd_iso="$TMP_DIR/install-odd.iso"
cp -- "$install_odd_conf" "$TMP_DIR/install-odd.vm.conf"
chmod u+w "$install_odd_conf"
cat >>"$install_odd_conf" <<'EOF'
ODD_MODEL='CONFIG ODD,serial=CONFIG-MODEL-INJECT'
ODD_SERIAL='CONFIG-SERIAL-INJECT'
INSTALL_MEDIA_BACKEND='ide'
EOF
chmod 444 "$install_odd_conf"
printf 'test ISO\n' >"$install_odd_iso"
if ! ODD_MODEL='ENV ODD,serial=ENV-MODEL-INJECT' \
        ODD_SERIAL='ENV-SERIAL-INJECT' \
        run_start "$install_odd_id" "$TMP_DIR/install-odd.out" \
            "$TMP_DIR/install-odd.err" --no-gpu --no-tpm \
            --install "$install_odd_iso"; then
    sed 's/^/install-odd: /' "$TMP_DIR/install-odd.err" >&2 || true
    fail 'generic install ODD dry-run failed before identity assertions'
fi
require_text 'id=installboot\,format=raw\,readonly=on' \
    "$TMP_DIR/install-odd.out" 'source-built install boot helper backend'
require_text 'usb-storage\,id=installboot-usb\,drive=installboot\,bus=xhci.0\,port=4\,bootindex=1\,removable=on' \
    "$TMP_DIR/install-odd.out" 'source-built install boot helper frontend'
require_text 'usb-storage\,id=odd0-usb\,drive=odd0\,bus=xhci.0\,port=3\,bootindex=3\,removable=on' \
    "$TMP_DIR/install-odd.out" 'install ISO generic optical device'
reject_text 'ide-cd\,drive=odd0' "$TMP_DIR/install-odd.out" \
    'vm.conf must not inject the slow ATAPI compatibility backend'
require_text 'ide-cd\,drive=answer0\,bus=ide.2' \
    "$TMP_DIR/install-odd.out" 'answer ISO generic optical device'
assert_no_persistent_optical_contract "$TMP_DIR/install-odd.out" \
    'install dry-run'
reject_text 'id=g11-odd' "$TMP_DIR/install-odd.out" \
    'USB install must not add the manual optical device'
for injected_odd_identity in CONFIG-MODEL-INJECT CONFIG-SERIAL-INJECT \
        ENV-MODEL-INJECT ENV-SERIAL-INJECT; do
    reject_text "$injected_odd_identity" "$TMP_DIR/install-odd.out" \
        'ODD environment/config injection'
done
mv -- "$TMP_DIR/install-odd.vm.conf" "$install_odd_conf"
require_text 'unset ODD_PROFILE ODD_BRAND ODD_MODEL ODD_FIRMWARE_REV ODD_INTERFACE' "$START_VM" \
    'ODD environment/config scrub'

# Hardware-v3 predates the persisted final per-slot list.  A missing list is
# derived from MEM_SN+MEM_SLOTS for both uniqueness and QEMU argv, but the
# immutable historical config must remain byte-for-byte unchanged.
legacy_v3_mem_list_id=$next_id
next_id=$((next_id + 1))
legacy_v3_mem_list_conf="$VM_ROOT/${legacy_v3_mem_list_id}/vm.conf"
rewrite_conf "${PLATFORM_IDS[i7-4820k-x79-extreme4-kingston-8g]}" \
    "$legacy_v3_mem_list_id" none
chmod u+w "$legacy_v3_mem_list_conf"
sed -i '/^MEM_SERIAL_LIST=/d' "$legacy_v3_mem_list_conf"
chmod 444 "$legacy_v3_mem_list_conf"
legacy_v3_mem_base=$(sed -n 's/^MEM_SN="\?\([^"[:space:]]*\)"\?$/\1/p' \
    "$legacy_v3_mem_list_conf")
legacy_v3_mem_slot2=$(g11_hardware_serial_memory_for_slot \
    "$legacy_v3_mem_base" 2) || fail 'cannot derive old-v3 DIMM slot 2'
legacy_v3_before=$(sha256sum "$legacy_v3_mem_list_conf" | awk '{print $1}')
run_start "$legacy_v3_mem_list_id" "$TMP_DIR/legacy-v3-mem-list.out" \
    "$TMP_DIR/legacy-v3-mem-list.err" --no-gpu --no-tpm
legacy_v3_after=$(sha256sum "$legacy_v3_mem_list_conf" | awk '{print $1}')
assert_eq "$legacy_v3_before" "$legacy_v3_after" \
    'old-v3 missing memory list remained immutable'
require_text '旧 v3 配置缺少 MEM_SERIAL_LIST，已按 MEM_SN+slot 稳定派生（未改写 vm.conf）' \
    "$TMP_DIR/legacy-v3-mem-list.err" 'old-v3 memory list warning'
require_text "serial=${legacy_v3_mem_base}\\|${legacy_v3_mem_slot2}" \
    "$TMP_DIR/legacy-v3-mem-list.out" 'old-v3 derived DIMM serials'

# Component contract v2 predates the vendor-bound MEM_SN/rank/JEP106 fields.
# Its missing optional serial must not trip set -u, and both DIMM serials must
# remain stable across boots by deriving them from VM_UUID.
legacy_mem_sn_id=$next_id
next_id=$((next_id + 1))
legacy_mem_sn_conf="$VM_ROOT/${legacy_mem_sn_id}/vm.conf"
rewrite_conf "${PLATFORM_IDS[i7-4820k-x79-extreme4-kingston-8g]}" \
    "$legacy_mem_sn_id" none
chmod u+w "$legacy_mem_sn_conf"
sed -i \
    -e 's/^G11_HARDWARE_CONTRACT_VERSION=.*/G11_HARDWARE_CONTRACT_VERSION=2/' \
    -e 's/^HARDWARE_COMPONENT_CONTRACT_VERSION=.*/HARDWARE_COMPONENT_CONTRACT_VERSION=2/' \
    -e '/^BOARD_RELEASE_YEAR=/d' \
    -e '/^BOARD_SERIAL_POLICY=/d' \
    -e '/^MEM_RANK_LIST=/d' \
    -e '/^MEM_MODULE_MFR_JEP106_LIST=/d' \
    -e '/^MEM_DRAM_MFR_JEP106_LIST=/d' \
    -e '/^MEM_SN=/d' \
    -e '/^MEM_SERIAL_LIST=/d' \
    "$legacy_mem_sn_conf"
chmod 444 "$legacy_mem_sn_conf"
legacy_mem_uuid=$(sed -n 's/^VM_UUID=//p' "$legacy_mem_sn_conf")
legacy_mem_seed="${legacy_mem_uuid}:memory"
for ((legacy_mem_attempt = 0; legacy_mem_attempt < 256; legacy_mem_attempt += 1)); do
    legacy_mem_serial_1=$(printf '%s-attempt%s' "$legacy_mem_seed" \
        "$legacy_mem_attempt" | sha256sum)
    legacy_mem_serial_1=${legacy_mem_serial_1:0:8}
    legacy_mem_serial_1=${legacy_mem_serial_1^^}
    g11_hardware_serial_memory_validate "$legacy_mem_serial_1" && break
done
legacy_mem_serial_2=$(g11_hardware_serial_memory_for_slot \
    "$legacy_mem_serial_1" 2) \
    || fail 'could not derive the legacy second DIMM serial'
for legacy_mem_run in 1 2; do
    run_start "$legacy_mem_sn_id" \
        "$TMP_DIR/legacy-mem-sn-${legacy_mem_run}.out" \
        "$TMP_DIR/legacy-mem-sn-${legacy_mem_run}.err" --no-gpu --no-tpm
    require_text '旧配置缺少 MEM_SN，已用 VM_UUID 稳定派生' \
        "$TMP_DIR/legacy-mem-sn-${legacy_mem_run}.err" \
        'missing MEM_SN compatibility warning'
    require_text \
        "serial=${legacy_mem_serial_1}\\|${legacy_mem_serial_2}" \
        "$TMP_DIR/legacy-mem-sn-${legacy_mem_run}.out" \
        'stable VM_UUID-derived DIMM serials'
done

# The normalized component contract is immutable at launch.  Editing one
# topology field must fail closed rather than silently falling back to the flat
# PLATFORM row.
component_tamper_id=$next_id
next_id=$((next_id + 1))
component_tamper_conf="$VM_ROOT/${component_tamper_id}/vm.conf"
rewrite_conf "${PLATFORM_IDS[i7-4820k-x79-extreme4-kingston-8g]}" \
    "$component_tamper_id" none
chmod u+w "$component_tamper_conf"
sed -i 's/^CPU_CORES=.*/CPU_CORES=2/' "$component_tamper_conf"
chmod 444 "$component_tamper_conf"
if run_start "$component_tamper_id" "$TMP_DIR/component-tamper.out" \
        "$TMP_DIR/component-tamper.err" --no-gpu --no-tpm; then
    fail 'tampered CPU component contract was accepted'
fi
require_text 'COMPONENT_CONTRACT_MISMATCH' "$TMP_DIR/component-tamper.err" \
    'tampered component contract refusal code'
require_text 'CPU_CORES=2' "$TMP_DIR/component-tamper.err" \
    'tampered component contract diagnostic'

# The audited physical-board xHCI facts and virtual placement form one atomic
# profile tuple.  They are not projected onto qemu-xhci, but partial/corrupt
# profile facts must still be rejected rather than guessed.
partial_xhci_id=$next_id
next_id=$((next_id + 1))
partial_xhci_conf="$VM_ROOT/${partial_xhci_id}/vm.conf"
rewrite_conf "${PLATFORM_IDS[i3-8100]}" "$partial_xhci_id" 2.0
chmod u+w "$partial_xhci_conf"
sed -i \
    -e '/^XHCI_PCI_DEVICE_ID=/d' \
    -e '/^XHCI_PCI_REVISION=/d' \
    -e '/^XHCI_PCI_BUS=/d' \
    -e '/^XHCI_PCI_ADDR=/d' \
    "$partial_xhci_conf"
chmod 444 "$partial_xhci_conf"
if run_start "$partial_xhci_id" "$TMP_DIR/partial-xhci.out" \
        "$TMP_DIR/partial-xhci.err" --no-gpu --no-tpm; then
    fail "partially populated xHCI PCI identity was accepted"
fi
require_text 'XHCI_PCI_VENDOR_ID/XHCI_PCI_DEVICE_ID/XHCI_PCI_REVISION/XHCI_PCI_BUS/XHCI_PCI_ADDR 必须同时设置' \
    "$TMP_DIR/partial-xhci.err" "partial xHCI identity refusal"

invalid_xhci_id=$next_id
next_id=$((next_id + 1))
invalid_xhci_conf="$VM_ROOT/${invalid_xhci_id}/vm.conf"
rewrite_conf "${PLATFORM_IDS[i3-8100]}" "$invalid_xhci_id" 2.0
chmod u+w "$invalid_xhci_conf"
sed -i 's/^XHCI_PCI_BUS=.*/XHCI_PCI_BUS=pcie.1/' "$invalid_xhci_conf"
chmod 444 "$invalid_xhci_conf"
if run_start "$invalid_xhci_id" "$TMP_DIR/invalid-xhci.out" \
        "$TMP_DIR/invalid-xhci.err" --no-gpu --no-tpm; then
    fail "invalid xHCI PCI topology was accepted"
fi
require_text 'vm.conf 中 xHCI PCI identity 非法' \
    "$TMP_DIR/invalid-xhci.err" "invalid xHCI identity refusal"

# Pre-link/block-metadata generators allowed H97 + NVMe.  That immutable
# historical config must still dry-run/boot (with a warning and 512/512 sector
# fallback), while newly generated configs remain subject to strict checks.
legacy_storage_id=$next_id
next_id=$((next_id + 1))
legacy_storage_dir="$VM_ROOT/${legacy_storage_id}"
legacy_storage_conf="$legacy_storage_dir/vm.conf"
rewrite_conf "${PLATFORM_IDS[i5-4590]}" "$legacy_storage_id" omit
chmod u+w "$legacy_storage_conf"
sed -i \
    -e '/^G11_HARDWARE_CONTRACT_VERSION=/d' \
    -e '/^CPU_REALIZATION_POLICY=/d' \
    -e '/^BOARD_NVME_PCIE_GEN=/d' \
    -e '/^BOARD_NVME_PCIE_LANES=/d' \
    -e '/^SSD_FORM_FACTOR=/d' \
    -e '/^SSD_PCIE_GEN=/d' \
    -e '/^SSD_PCIE_LANES=/d' \
    -e '/^SSD_LOGICAL_BLOCK_SIZE=/d' \
    -e '/^SSD_PHYSICAL_BLOCK_SIZE=/d' \
    -e '/^SSD_PROFILE=/d' \
    -e 's/^SSD_BRAND=.*/SSD_BRAND="Samsung"/' \
    -e 's/^SSD_MODEL=.*/SSD_MODEL="Samsung SSD 970 PRO 512GB"/' \
    -e 's/^SSD_INTERFACE=.*/SSD_INTERFACE=nvme/' \
    -e 's/^SSD_FIRMWARE_REV=.*/SSD_FIRMWARE_REV="1B2QEXP7"/' \
    -e 's/^SSD_CONTROLLER_PROFILE=.*/SSD_CONTROLLER_PROFILE=samsung/' \
    "$legacy_storage_conf"
chmod 444 "$legacy_storage_conf"
run_start "$legacy_storage_id" "$TMP_DIR/legacy-storage.out" \
    "$TMP_DIR/legacy-storage.err" --no-gpu --no-tpm
require_text '旧 vm.conf 缺少 SSD PCIe 链路元数据' \
    "$TMP_DIR/legacy-storage.err" "legacy H97/NVMe compatibility warning"
require_text 'nvme\,drive=ssd0' "$TMP_DIR/legacy-storage.out" \
    "legacy H97/NVMe still reaches QEMU argv"
require_text 'logical_block_size=512' "$TMP_DIR/legacy-storage.out" \
    "legacy SSD logical-sector fallback"
require_text 'physical_block_size=512' "$TMP_DIR/legacy-storage.out" \
    "legacy SSD physical-sector fallback"

partial_storage_id=$next_id
next_id=$((next_id + 1))
partial_storage_dir="$VM_ROOT/${partial_storage_id}"
partial_storage_conf="$partial_storage_dir/vm.conf"
rewrite_conf "${PLATFORM_IDS[i5-4590]}" "$partial_storage_id" omit
chmod u+w "$partial_storage_conf"
sed -i -e '/^SSD_PCIE_GEN=/d' -e '/^SSD_PCIE_LANES=/d' \
    "$partial_storage_conf"
chmod 444 "$partial_storage_conf"
if run_start "$partial_storage_id" "$TMP_DIR/partial-storage.out" \
        "$TMP_DIR/partial-storage.err" --no-gpu --no-tpm; then
    fail "partially populated SSD topology metadata was accepted"
fi
require_text 'SSD_FORM_FACTOR/SSD_PCIE_GEN/SSD_PCIE_LANES 必须同时设置' \
    "$TMP_DIR/partial-storage.err" "partial SSD topology metadata refusal"

strict_storage_id=$next_id
next_id=$((next_id + 1))
strict_storage_dir="$VM_ROOT/${strict_storage_id}"
strict_storage_conf="$strict_storage_dir/vm.conf"
rewrite_conf "${PLATFORM_IDS[i5-4590]}" "$strict_storage_id" omit
chmod u+w "$strict_storage_conf"
sed -i \
    -e 's/^SSD_PROFILE=.*/SSD_PROFILE=samsung-970-pro-512gb/' \
    -e 's/^SSD_MODEL=.*/SSD_MODEL="Samsung SSD 970 PRO 512GB"/' \
    -e 's/^SSD_INTERFACE=.*/SSD_INTERFACE=nvme/' \
    -e 's/^SSD_FIRMWARE_REV=.*/SSD_FIRMWARE_REV="1B2QEXP7"/' \
    -e 's/^SSD_CONTROLLER_PROFILE=.*/SSD_CONTROLLER_PROFILE=samsung/' \
    -e 's/^SSD_FORM_FACTOR=.*/SSD_FORM_FACTOR=m.2-2280/' \
    -e 's/^SSD_PCIE_GEN=.*/SSD_PCIE_GEN=3/' \
    -e 's/^SSD_PCIE_LANES=.*/SSD_PCIE_LANES=4/' \
    "$strict_storage_conf"
chmod 444 "$strict_storage_conf"
if run_start "$strict_storage_id" "$TMP_DIR/strict-storage.out" \
        "$TMP_DIR/strict-storage.err" --no-gpu --no-tpm; then
    fail "strict H97 + Gen3 x4 NVMe metadata was accepted by start-vm"
fi
require_text '已审核拓扑不兼容' "$TMP_DIR/strict-storage.err" \
    "strict H97/NVMe start refusal"

# The H97 board's M.2 socket is PCIe 2.0 x2, so the QEMU controller identity
# that advertises Samsung PCIe 3.0 x4 must not be paired with that platform.
if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
        IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
        VGPU_HOST_CONFIG="$HOST_2GB_CONFIG" \
        "$CREATE_VM" 780099 --platform i5-4590 \
        --ssd-profile samsung-970-pro-512gb \
        --gpu-profile gtx1050_2gb --monitor-profile lenovo-d24-20 \
        >"$TMP_DIR/h97-nvme.out" 2>"$TMP_DIR/h97-nvme.err"; then
    fail "H97 accepted the incompatible Gen3 x4 NVMe identity"
fi
require_text '与平台 i5-4590 不兼容' "$TMP_DIR/h97-nvme.err" \
    "H97/NVMe compatibility refusal"

# A removed 500 GB profile remains start-compatible when its full identity was
# already persisted, but --force must not silently grow/relabel its existing
# disk as one of the new 512 GB profiles.
guard_id=${PLATFORM_IDS[i5-4590]}
guard_dir="$VM_ROOT/${guard_id}"
guard_conf="$guard_dir/vm.conf"
: >"$guard_dir/disk.qcow2"
guard_hash=$(sha256sum "$guard_conf")

capacity_guard_id=$next_id
next_id=$((next_id + 1))
capacity_guard_dir="$VM_ROOT/${capacity_guard_id}"
capacity_guard_conf="$capacity_guard_dir/vm.conf"
rewrite_conf "$guard_id" "$capacity_guard_id" omit
chmod u+w "$capacity_guard_conf"
sed -i \
    -e '/^G11_HARDWARE_CONTRACT_VERSION=/d' \
    -e '/^CPU_REALIZATION_POLICY=/d' \
    -e 's/^SSD_PROFILE=.*/SSD_PROFILE=samsung-860-evo-500gb/' \
    -e 's/^SSD_MODEL=.*/SSD_MODEL="Samsung SSD 860 EVO 500GB"/' \
    -e 's/^SSD_SIZE_BYTES=.*/SSD_SIZE_BYTES=500107862016/' \
    -e 's/^SSD_FIRMWARE_REV=.*/SSD_FIRMWARE_REV="RVT04B6Q"/' \
    "$capacity_guard_conf"
chmod 444 "$capacity_guard_conf"
: >"$capacity_guard_dir/disk.qcow2"
capacity_guard_hash=$(sha256sum "$capacity_guard_conf")
run_start "$capacity_guard_id" "$TMP_DIR/legacy-500-start.out" \
    "$TMP_DIR/legacy-500-start.err" --no-gpu --no-tpm
require_text 'Samsung\ SSD\ 860\ EVO\ 500GB' \
    "$TMP_DIR/legacy-500-start.out" "removed 500 GB profile start compatibility"
require_text '500107862016 bytes' "$TMP_DIR/legacy-500-start.out" \
    "removed 500 GB profile visible capacity"
if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
        IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
        VGPU_HOST_CONFIG="$HOST_2GB_CONFIG" \
        "$CREATE_VM" "$capacity_guard_id" --force --platform i5-4590 \
        --ssd-profile samsung-850-pro-512gb \
        --gpu-profile gtx1050_2gb --monitor-profile lenovo-d24-20 \
        >"$TMP_DIR/force-size.out" 2>"$TMP_DIR/force-size.err"; then
    fail "--force changed the profile capacity underneath an existing disk"
fi
require_text '已有磁盘不能用 --force 改变厂标容量' \
    "$TMP_DIR/force-size.err" "--force disk-capacity guard"
assert_eq "$capacity_guard_hash" "$(sha256sum "$capacity_guard_conf")" \
    "failed storage rewrite preserved vm.conf"

# Two exact-512 GB NVMe profiles still have different PCI controller IDs.
# Never let --force swap the Windows boot controller beneath an existing disk.
controller_guard_id=${PLATFORM_IDS[i5-6500]}
controller_guard_dir="$VM_ROOT/${controller_guard_id}"
controller_guard_conf="$controller_guard_dir/vm.conf"
: >"$controller_guard_dir/disk.qcow2"
controller_guard_hash=$(sha256sum "$controller_guard_conf")
if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
        IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
        VGPU_HOST_CONFIG="$HOST_2GB_CONFIG" \
        "$CREATE_VM" "$controller_guard_id" --force --platform i5-6500 \
        --ssd-profile wd-black-pcie-512gb \
        --gpu-profile gtx1050_2gb --monitor-profile lenovo-d24-20 \
        >"$TMP_DIR/force-controller.out" \
        2>"$TMP_DIR/force-controller.err"; then
    fail "--force changed the PCI identity underneath an existing NVMe disk"
fi
require_text '已有磁盘不能用 --force 改变 NVMe 控制器身份' \
    "$TMP_DIR/force-controller.err" "--force NVMe controller guard"
assert_eq "$controller_guard_hash" "$(sha256sum "$controller_guard_conf")" \
    "failed NVMe controller rewrite preserved vm.conf"

mkdir -p "$guard_dir/tpm/state"
truncate -s 4096 "$guard_dir/tpm/state/tpm-00.permall"
if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
        IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
        VGPU_HOST_CONFIG="$HOST_2GB_CONFIG" \
        "$CREATE_VM" "$guard_id" --force --platform i5-6500 \
        --ssd-profile samsung-860-pro-512gb \
        --gpu-profile gtx1050_2gb --monitor-profile lenovo-d24-20 \
        >"$TMP_DIR/force-tpm.out" 2>"$TMP_DIR/force-tpm.err"; then
    fail "--force rebound persistent TPM state to a different board"
fi
require_text '绑定的 TPM 持久状态' "$TMP_DIR/force-tpm.err" \
    "--force TPM platform guard"
assert_eq "$guard_hash" "$(sha256sum "$guard_conf")" \
    "failed TPM rewrite preserved vm.conf"

# The implicit path selects the fastest compatible exact-512 GB tier: Gen3 x4
# NVMe on Ivy Bridge-E/native-Gen3 boards, and SATA on i7-3820 or older links.
for default_platform in i7-4820k-p9x79-micron-16g \
        i7-4930k-p9x79-samsung-4g \
        i7-3820-p9x79-kingston-4g i5-4590 i5-6500 i3-8100; do
    default_ssd_id=$next_id
    next_id=$((next_id + 1))
    create_vm_default_ssd "$default_ssd_id" "$default_platform" \
        "$TMP_DIR/create-default-ssd-${default_platform}.out"
    # shellcheck source=/dev/null
    source "$VM_ROOT/${default_ssd_id}/vm.conf"
    [[ "$SSD_SIZE_BYTES" == 512110190592 ]] \
        || fail "$default_platform implicit SSD is not exact 512 GB: $SSD_SIZE_BYTES"
    case "$default_platform|$SSD_INTERFACE|$SSD_PCIE_GEN|$SSD_PCIE_LANES" in
        'i7-4820k-p9x79-micron-16g|nvme|3|4'|\
        'i7-4930k-p9x79-samsung-4g|nvme|3|4'|\
        'i7-3820-p9x79-kingston-4g|sata|0|0'|\
        'i5-4590|sata|0|0'|\
        'i5-6500|nvme|3|4'|\
        'i3-8100|nvme|3|4') ;;
        *) fail "$default_platform implicit SSD escaped its best compatible tier: $SSD_PROFILE" ;;
    esac
    assert_serials "$default_platform default SSD"
    assert_intel_mac "$default_platform default SSD"
    assert_ssd_profile "$default_platform default SSD"
    assert_input_profiles "$default_platform default input"
done

# Exercise every storage profile through both scripts.  This verifies that a
# SATA Identify model never becomes an NVMe controller (and vice versa), and
# that start-vm passes the exact catalog model instead of prepending the brand.
for ssd_profile in "${expected_ssds[@]}"; do
    id=$next_id
    next_id=$((next_id + 1))
    create_out="$TMP_DIR/create-$id.out"
    create_vm "$id" i3-8100 "$ssd_profile" "$create_out"
    conf="$VM_ROOT/${id}/vm.conf"
    # shellcheck source=/dev/null
    source "$conf"
    assert_serials "$ssd_profile"
    assert_intel_mac "$ssd_profile"
    assert_ssd_profile "$ssd_profile"

    runtime_out="$TMP_DIR/storage-$id.out"
    runtime_err="$TMP_DIR/storage-$id.err"
    run_start "$id" "$runtime_out" "$runtime_err" --no-gpu --no-tpm
    quoted_model=$(printf '%q' "$SSD_MODEL")
    quoted_duplicate=$(printf '%q' "$SSD_BRAND $SSD_MODEL")
    if [[ "$SSD_INTERFACE" == sata ]]; then
        require_text 'ide-hd\,drive=ssd0' "$runtime_out" "$ssd_profile SATA device"
        reject_text 'nvme\,drive=ssd0' "$runtime_out" "$ssd_profile false NVMe device"
        require_text "model=${quoted_model}" "$runtime_out" "$ssd_profile exact SATA model"
        require_text "ver=${SSD_FIRMWARE_REV}" "$runtime_out" "$ssd_profile SATA firmware"
        require_text "logical_block_size=${SSD_LOGICAL_BLOCK_SIZE}" "$runtime_out" \
            "$ssd_profile SATA logical sector"
        require_text "physical_block_size=${SSD_PHYSICAL_BLOCK_SIZE}" "$runtime_out" \
            "$ssd_profile SATA physical sector"
        reject_text 'use-samsung-id=on' "$runtime_out" \
            "$ssd_profile false NVMe controller identity"
        reject_text 'use-wd-id=on' "$runtime_out" \
            "$ssd_profile false WD NVMe controller identity"
    else
        require_text 'nvme\,drive=ssd0' "$runtime_out" "$ssd_profile NVMe device"
        reject_text 'ide-hd\,drive=ssd0' "$runtime_out" "$ssd_profile false SATA device"
        require_text "model-number=${quoted_model}" "$runtime_out" "$ssd_profile exact NVMe model"
        require_text "firmware-rev=${SSD_FIRMWARE_REV}" "$runtime_out" \
            "$ssd_profile NVMe firmware"
        require_text "serial=${SSD_SN}" "$runtime_out" \
            "$ssd_profile NVMe serial"
        require_text "logical_block_size=${SSD_LOGICAL_BLOCK_SIZE}" "$runtime_out" \
            "$ssd_profile NVMe logical sector"
        require_text "physical_block_size=${SSD_PHYSICAL_BLOCK_SIZE}" "$runtime_out" \
            "$ssd_profile NVMe physical sector"
        case "$SSD_CONTROLLER_PROFILE" in
            samsung)
                require_text 'use-samsung-id=on' "$runtime_out" \
                    "$ssd_profile Samsung NVMe controller identity"
                reject_text 'use-wd-id=on' "$runtime_out" \
                    "$ssd_profile false WD NVMe controller identity"
                ;;
            wd)
                require_text 'use-wd-id=on' "$runtime_out" \
                    "$ssd_profile WD NVMe controller identity"
                reject_text 'use-samsung-id=on' "$runtime_out" \
                    "$ssd_profile false Samsung NVMe controller identity"
                ;;
            *) fail "$ssd_profile has an unreviewed NVMe controller: $SSD_CONTROLLER_PROFILE" ;;
        esac
    fi
    if [[ "$SSD_MODEL" == "$SSD_BRAND "* ]]; then
        reject_text "$quoted_duplicate" "$runtime_out" "$ssd_profile duplicated brand"
    else
        reject_text "$(printf '%q' "$SSD_BRAND $SSD_MODEL")" "$runtime_out" \
            "$ssd_profile invented brand prefix"
    fi
done

# TPM 2.0-capable boards get CRB while the audited H97 TPM 1.2 profile gets
# TIS.  A synthetic no-TPM profile gets neither, --no-tpm wins, and a
# pre-profile vm.conf keeps the historical TPM 2.0 default.
tpm2_id=${PLATFORM_IDS[i3-8100]}
tpm12_id=${PLATFORM_IDS[i5-4590]}
run_start "$tpm2_id" "$TMP_DIR/tpm2.out" "$TMP_DIR/tpm2.err" --no-gpu
require_text 'tpm-crb\,tpmdev=tpm0' "$TMP_DIR/tpm2.out" "TPM 2.0 board CRB"
reject_text 'tpm-tis\,tpmdev=tpm0' "$TMP_DIR/tpm2.out" "TPM 2.0 false TIS"

run_start "$tpm12_id" "$TMP_DIR/tpm12.out" "$TMP_DIR/tpm12.err" --no-gpu
require_text 'tpm-tis\,tpmdev=tpm0' "$TMP_DIR/tpm12.out" "TPM 1.2 board TIS"
reject_text 'tpm-crb\,tpmdev=tpm0' "$TMP_DIR/tpm12.out" "TPM 1.2 false CRB"

no_tpm_id=${PLATFORM_IDS[i7-4820k-x79-extreme4-kingston-8g]}
run_start "$no_tpm_id" "$TMP_DIR/no-board-tpm.out" \
    "$TMP_DIR/no-board-tpm.err" --no-gpu
reject_text 'tpm-crb\,tpmdev=tpm0' "$TMP_DIR/no-board-tpm.out" \
    "board without TPM"
reject_text 'tpm-tis\,tpmdev=tpm0' "$TMP_DIR/no-board-tpm.out" \
    "board without TPM TIS"

if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin DISPLAY=:99 \
        IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
        QEMU_BIN="$TMP_DIR/qemu-system-x86_64" \
        OVMF_CODE="$TMP_DIR/OVMF_CODE.fd" OVMF_VARS="$TMP_DIR/OVMF_VARS.fd" \
        VGPU_HOST_CONFIG="$EMPTY_VGPU_CONFIG" REPAIR_DISPLAY_VARS=off TPM=1 \
        "$START_VM" "$no_tpm_id" --dry-run --no-gpu \
        >"$TMP_DIR/forced-no-board-tpm.out" \
        2>"$TMP_DIR/forced-no-board-tpm.err"; then
    fail "TPM=1 forced a TPM onto a board profile without TPM support"
fi
require_text '不支持 TPM 的主板 profile' \
    "$TMP_DIR/forced-no-board-tpm.err" "no-TPM board override refusal"

run_start "$tpm2_id" "$TMP_DIR/cli-no-tpm.out" "$TMP_DIR/cli-no-tpm.err" \
    --no-gpu --no-tpm
reject_text 'tpm-crb\,tpmdev=tpm0' "$TMP_DIR/cli-no-tpm.out" \
    "--no-tpm precedence"
reject_text 'tpm-tis\,tpmdev=tpm0' "$TMP_DIR/cli-no-tpm.out" \
    "--no-tpm TIS precedence"

legacy_id=$next_id
next_id=$((next_id + 1))
rewrite_conf "$tpm2_id" "$legacy_id" omit
chmod u+w "$VM_ROOT/${legacy_id}/vm.conf"
sed -i -e '/^G11_HARDWARE_CONTRACT_VERSION=/d' \
    -e '/^CPU_REALIZATION_POLICY=/d' "$VM_ROOT/${legacy_id}/vm.conf"
chmod 444 "$VM_ROOT/${legacy_id}/vm.conf"
run_start "$legacy_id" "$TMP_DIR/legacy-tpm.out" "$TMP_DIR/legacy-tpm.err" --no-gpu
require_text 'tpm-crb\,tpmdev=tpm0' "$TMP_DIR/legacy-tpm.out" \
    "legacy config TPM compatibility"

# SPOOF_MODE=B is name-only: the summary must say that PCI identity remains the
# host mdev and the vfio device must not receive the consumer-card PCI IDs.
gpu_id=${PLATFORM_IDS[i3-8100]}
# shellcheck source=/dev/null
source "$VM_ROOT/${gpu_id}/vm.conf"
run_start "$gpu_id" "$TMP_DIR/gpu-b.out" "$TMP_DIR/gpu-b.err" --no-tpm
require_text 'PCI identity remains host mdev' "$TMP_DIR/gpu-b.out" \
    "SPOOF_MODE=B identity explanation"
require_text 'pcie-root-port\,id=gpu-root-port\,bus=pcie.0\,addr=0x10' \
    "$TMP_DIR/gpu-b.out" "vGPU PCIe root port"
require_text 'x-speed=8\,x-width=16\,x-pci-vendor-id=0x8086\,x-pci-device-id=0x1901\,x-pci-revision=0x07' \
    "$TMP_DIR/gpu-b.out" "B360 GPU root-port PCIe 3.0 x16 identity"
require_text 'bus=gpu-root-port\,addr=0x0' "$TMP_DIR/gpu-b.out" \
    "vGPU downstream endpoint"
reject_text "x-pci-device-id=${GPU_PCI_DID}" "$TMP_DIR/gpu-b.out" \
    "SPOOF_MODE=B consumer PCI device"
reject_text "x-pci-sub-device-id=${GPU_SUB_DID}" "$TMP_DIR/gpu-b.out" \
    "SPOOF_MODE=B consumer PCI subsystem"

# No A marker or CLI override is currently a production-signature attestation.
# Every A request must fail closed.
if run_start "$gpu_id" "$TMP_DIR/gpu-a-unprepared.out" \
        "$TMP_DIR/gpu-a-unprepared.err" --no-tpm --spoof-mode A; then
    fail 'legacy full-consumer GTX 1050 entered A mode'
fi
require_text 'strict-A startup is disabled' \
    "$TMP_DIR/gpu-a-unprepared.err" "A-mode production-signature refusal"

# Rescue must explicitly select off/B; retaining A even on a no-vGPU command is
# ambiguous and must not bypass the early guard.
if run_start "$gpu_id" "$TMP_DIR/gpu-a-rescue-reject.out" \
        "$TMP_DIR/gpu-a-rescue-reject.err" --no-tpm --rescue-sdl \
        --spoof-mode A; then
    fail 'rescue mode bypassed the strict-A startup guard'
fi
require_text 'strict-A startup is disabled' \
    "$TMP_DIR/gpu-a-rescue-reject.err" "A-mode rescue refusal"
run_start "$gpu_id" "$TMP_DIR/gpu-a-rescue.out" \
    "$TMP_DIR/gpu-a-rescue.err" --no-tpm --rescue-sdl --no-spoof
require_text '标准显卡 -> SDL 本地救援' "$TMP_DIR/gpu-a-rescue.out" \
    "explicit off-mode rescue display"
reject_text 'vfio-pci-nohotplug' "$TMP_DIR/gpu-a-rescue.out" \
    "off-mode rescue vGPU attachment"

# Even the complete legacy tuple/internal/FRL/version marker set is not proof of
# a production-signed guest driver.
if VGPU_MDEV_INTERNAL_PCI_IDENTITY=1 VGPU_MDEV_FRL_ENABLED=0 \
        VGPU_PATCHED_DRIVER_VERSION=31.0.15.3833 \
        run_start "$gpu_id" "$TMP_DIR/gpu-a-markers.out" \
            "$TMP_DIR/gpu-a-markers.err" --no-tpm --spoof-mode A; then
    fail 'legacy completion markers bypassed the strict-A startup guard'
fi
require_text 'strict-A startup is disabled' "$TMP_DIR/gpu-a-markers.err" \
    "legacy marker A-mode refusal"

# The last real spoof CLI selector wins.  A token consumed as --extra's value
# must never be mistaken for a recovery override.
run_start "$gpu_id" "$TMP_DIR/gpu-spoof-order-off.out" \
    "$TMP_DIR/gpu-spoof-order-off.err" --no-tpm --spoof --no-spoof
require_text 'GPU target: disabled' "$TMP_DIR/gpu-spoof-order-off.out" \
    "last off selector"
if run_start "$gpu_id" "$TMP_DIR/gpu-spoof-order-a.out" \
        "$TMP_DIR/gpu-spoof-order-a.err" --no-tpm --no-spoof --spoof; then
    fail 'a trailing --spoof did not override the earlier recovery selector'
fi
require_text 'strict-A startup is disabled' "$TMP_DIR/gpu-spoof-order-a.err" \
    "last A selector refusal"

extra_value_a_id=$next_id
next_id=$((next_id + 1))
rewrite_conf "$gpu_id" "$extra_value_a_id" 2.0
chmod u+w "$VM_ROOT/${extra_value_a_id}/vm.conf"
sed -i 's/^SPOOF_MODE=.*/SPOOF_MODE=A/' \
    "$VM_ROOT/${extra_value_a_id}/vm.conf"
chmod 444 "$VM_ROOT/${extra_value_a_id}/vm.conf"
if run_start "$extra_value_a_id" "$TMP_DIR/gpu-extra-value.out" \
        "$TMP_DIR/gpu-extra-value.err" --no-tpm --extra --no-spoof; then
    fail '--extra value was mistaken for an off-mode recovery selector'
fi
require_text 'strict-A startup is disabled' "$TMP_DIR/gpu-extra-value.err" \
    "--extra spoof-token isolation"

VGPU_MDEV_INTERNAL_PCI_IDENTITY=1 \
    run_start "$gpu_id" "$TMP_DIR/gpu-b-internal.out" \
        "$TMP_DIR/gpu-b-internal.err" --no-tpm --spoof-mode B
require_text 'vGPU internal PCI identity: inactive (requires SPOOF_MODE=A' \
    "$TMP_DIR/gpu-b-internal.out" "B-mode internal PCI identity gate"
reject_text 'vdev_id=' "$TMP_DIR/gpu-b-internal.out" \
    "B-mode internal vdev_id"

if VGPU_MDEV_INTERNAL_PCI_IDENTITY=2 \
        run_start "$gpu_id" "$TMP_DIR/gpu-invalid-internal.out" \
            "$TMP_DIR/gpu-invalid-internal.err" --no-tpm --spoof-mode B; then
    fail 'invalid VGPU_MDEV_INTERNAL_PCI_IDENTITY value was accepted'
fi
require_text 'VGPU_MDEV_INTERNAL_PCI_IDENTITY 必须是 0 或 1' \
    "$TMP_DIR/gpu-invalid-internal.err" "internal PCI identity input validation"

# A persisted legacy FRL marker must not leak into either supported B or off.
VGPU_MDEV_FRL_ENABLED=0 \
    run_start "$gpu_id" "$TMP_DIR/gpu-b-frl.out" \
        "$TMP_DIR/gpu-b-frl.err" --no-tpm --spoof-mode B
require_text 'vGPU frame-rate limiter: inherited from resource profile' \
    "$TMP_DIR/gpu-b-frl.out" "B-mode FRL inheritance"
reject_text 'per-mdev frl_enabled=0' "$TMP_DIR/gpu-b-frl.out" \
    "B-mode stale FRL override"

VGPU_MDEV_FRL_ENABLED=0 \
    run_start "$gpu_id" "$TMP_DIR/gpu-off-frl.out" \
        "$TMP_DIR/gpu-off-frl.err" --no-tpm --spoof-mode off
require_text 'vGPU frame-rate limiter: inherited from resource profile' \
    "$TMP_DIR/gpu-off-frl.out" "off-mode FRL inheritance"
reject_text 'per-mdev frl_enabled=0' "$TMP_DIR/gpu-off-frl.out" \
    "off-mode stale FRL override"

if VGPU_MDEV_FRL_ENABLED=2 \
        run_start "$gpu_id" "$TMP_DIR/gpu-invalid-frl.out" \
            "$TMP_DIR/gpu-invalid-frl.err" --no-tpm --spoof-mode B; then
    fail 'invalid VGPU_MDEV_FRL_ENABLED value was accepted'
fi
require_text 'VGPU_MDEV_FRL_ENABLED 必须是 0 或 1' \
    "$TMP_DIR/gpu-invalid-frl.err" "per-mdev FRL input validation"

# A persisted A config must be rejected before the launcher creates global or
# per-instance runtime/storage paths.
strict_guard_root="$TMP_DIR/strict-start-zero-write"
strict_guard_id=456
mkdir -p "$strict_guard_root/${strict_guard_id}"
printf 'SPOOF_MODE=A\n' \
    >"$strict_guard_root/${strict_guard_id}/vm.conf"
if VM_ROOT="$strict_guard_root" \
        "$START_VM" "$strict_guard_id" \
        >"$TMP_DIR/strict-start-zero-write.out" \
        2>"$TMP_DIR/strict-start-zero-write.err"; then
    fail 'persisted A config passed the pre-storage startup guard'
fi
require_text 'strict-A startup is disabled' \
    "$TMP_DIR/strict-start-zero-write.err" "pre-storage A-mode refusal"
for forbidden in \
        "$strict_guard_root/control" \
        "$strict_guard_root/shared/assets" \
        "$strict_guard_root/_base" \
        "$strict_guard_root/${strict_guard_id}/run" \
        "$strict_guard_root/${strict_guard_id}/log" \
        "$strict_guard_root/${strict_guard_id}/backups"; do
    [[ ! -e "$forbidden" && ! -L "$forbidden" ]] ||
        fail "strict-A preflight created forbidden path: $forbidden"
done

legacy_spoof_root="$TMP_DIR/legacy-spoof-zero-write"
legacy_spoof_id=458
mkdir -p "$legacy_spoof_root/${legacy_spoof_id}"
printf '%s\n' 'SPOOF_MODE=B' 'SPOOF=1' \
    >"$legacy_spoof_root/${legacy_spoof_id}/vm.conf"
if VM_ROOT="$legacy_spoof_root" \
        "$START_VM" "$legacy_spoof_id" \
        >"$TMP_DIR/legacy-spoof-zero-write.out" \
        2>"$TMP_DIR/legacy-spoof-zero-write.err"; then
    fail 'legacy SPOOF=1 did not override SPOOF_MODE=B in preflight'
fi
require_text 'strict-A startup is disabled' \
    "$TMP_DIR/legacy-spoof-zero-write.err" "legacy SPOOF preflight refusal"
[[ ! -e "$legacy_spoof_root/control" && ! -L "$legacy_spoof_root/control" ]] ||
    fail 'legacy SPOOF preflight created a run directory'

env_spoof_root="$TMP_DIR/env-spoof-zero-write"
env_spoof_id=459
mkdir -p "$env_spoof_root/${env_spoof_id}"
printf '%s\n' 'SPOOF_MODE=B' \
    >"$env_spoof_root/${env_spoof_id}/vm.conf"
if env VM_ROOT="$env_spoof_root" SPOOF=1 \
        "$START_VM" "$env_spoof_id" \
        >"$TMP_DIR/env-spoof-zero-write.out" \
        2>"$TMP_DIR/env-spoof-zero-write.err"; then
    fail 'caller SPOOF=1 bypassed the pre-storage A guard'
fi
require_text 'strict-A startup is disabled' \
    "$TMP_DIR/env-spoof-zero-write.err" "environment SPOOF preflight refusal"
[[ ! -e "$env_spoof_root/control" && ! -L "$env_spoof_root/control" ]] ||
    fail 'environment SPOOF preflight created a run directory'

spaced_a_root="$TMP_DIR/spaced-a-zero-write"
spaced_a_id=460
mkdir -p "$spaced_a_root/${spaced_a_id}"
printf '  SPOOF_MODE=A\n' \
    >"$spaced_a_root/${spaced_a_id}/vm.conf"
if VM_ROOT="$spaced_a_root" \
        "$START_VM" "$spaced_a_id" \
        >"$TMP_DIR/spaced-a-zero-write.out" \
        2>"$TMP_DIR/spaced-a-zero-write.err"; then
    fail 'leading whitespace hid A from the pre-storage guard'
fi
require_text 'strict-A startup is disabled' \
    "$TMP_DIR/spaced-a-zero-write.err" "spaced A preflight refusal"
[[ ! -e "$spaced_a_root/control" && ! -L "$spaced_a_root/control" ]] ||
    fail 'spaced A preflight created a run directory'

symlink_conf_root="$TMP_DIR/symlink-conf-zero-write"
symlink_conf_id=461
mkdir -p "$symlink_conf_root/${symlink_conf_id}"
printf 'SPOOF_MODE=B\n' >"$symlink_conf_root/outside.conf"
ln -s "$symlink_conf_root/outside.conf" \
    "$symlink_conf_root/${symlink_conf_id}/vm.conf"
if VM_ROOT="$symlink_conf_root" \
        "$START_VM" "$symlink_conf_id" --no-spoof \
        >"$TMP_DIR/symlink-conf-zero-write.out" \
        2>"$TMP_DIR/symlink-conf-zero-write.err"; then
    fail 'explicit off mode bypassed vm.conf symlink validation'
fi
require_text 'regular non-symlink file' \
    "$TMP_DIR/symlink-conf-zero-write.err" "symlink config refusal"
[[ ! -e "$symlink_conf_root/control" && ! -L "$symlink_conf_root/control" ]] ||
    fail 'symlink config preflight created a run directory'

vm_id_mismatch_root="$TMP_DIR/vm-id-mismatch-zero-write"
vm_id_mismatch_requested=462
mkdir -p \
    "$vm_id_mismatch_root/${vm_id_mismatch_requested}"
printf '%s\n' 'VM_ID=463' 'SPOOF_MODE=B' \
    >"$vm_id_mismatch_root/${vm_id_mismatch_requested}/vm.conf"
if VM_ROOT="$vm_id_mismatch_root" \
        "$START_VM" "$vm_id_mismatch_requested" \
        >"$TMP_DIR/vm-id-mismatch-zero-write.out" \
        2>"$TMP_DIR/vm-id-mismatch-zero-write.err"; then
    fail 'vm.conf redirected the requested VM ID'
fi
require_text 'must exactly match requested vm462' \
    "$TMP_DIR/vm-id-mismatch-zero-write.err" "vm.conf ID mismatch refusal"
[[ ! -e "$vm_id_mismatch_root/control" && ! -L "$vm_id_mismatch_root/control" ]] ||
    fail 'vm.conf ID mismatch created a run directory'

vm_id_oversized_root="$TMP_DIR/vm-id-oversized-zero-write"
vm_id_oversized_requested=464
mkdir -p \
    "$vm_id_oversized_root/${vm_id_oversized_requested}"
printf '%s\n' 'VM_ID=2147483648' 'SPOOF_MODE=B' \
    >"$vm_id_oversized_root/${vm_id_oversized_requested}/vm.conf"
if VM_ROOT="$vm_id_oversized_root" \
        "$START_VM" "$vm_id_oversized_requested" \
        >"$TMP_DIR/vm-id-oversized-zero-write.out" \
        2>"$TMP_DIR/vm-id-oversized-zero-write.err"; then
    fail 'vm.conf supplied an oversized VM ID'
fi
require_text 'must exactly match requested vm464' \
    "$TMP_DIR/vm-id-oversized-zero-write.err" "vm.conf oversized ID refusal"
[[ ! -e "$vm_id_oversized_root/control" && ! -L "$vm_id_oversized_root/control" ]] ||
    fail 'vm.conf oversized ID created a run directory'

host_spoof_root="$TMP_DIR/host-spoof-zero-write"
host_spoof_id=465
host_spoof_conf="$TMP_DIR/host-spoof.conf"
mkdir -p "$host_spoof_root/${host_spoof_id}"
printf '%s\n' "VM_ID=$host_spoof_id" 'SPOOF_MODE=B' \
    >"$host_spoof_root/${host_spoof_id}/vm.conf"
printf 'SPOOF=1\n' >"$host_spoof_conf"
if VM_ROOT="$host_spoof_root" VGPU_HOST_CONFIG="$host_spoof_conf" \
        "$START_VM" "$host_spoof_id" \
        >"$TMP_DIR/host-spoof-zero-write.out" \
        2>"$TMP_DIR/host-spoof-zero-write.err"; then
    fail 'host config SPOOF=1 bypassed the pre-storage guard'
fi
require_text 'strict-A startup is disabled' \
    "$TMP_DIR/host-spoof-zero-write.err" "host config SPOOF refusal"
[[ ! -e "$host_spoof_root/control" && ! -L "$host_spoof_root/control" ]] ||
    fail 'host config SPOOF preflight created a run directory'

legacy_marker_root="$TMP_DIR/legacy-marker-zero-write"
legacy_marker_id=457
mkdir -p "$legacy_marker_root/${legacy_marker_id}"
printf '%s\n' \
    'SPOOF_MODE=B' \
    'VGPU_PATCHED_DRIVER_VERSION=31.0.15.3833' \
    >"$legacy_marker_root/${legacy_marker_id}/vm.conf"
if VM_ROOT="$legacy_marker_root" \
        "$START_VM" "$legacy_marker_id" \
        >"$TMP_DIR/legacy-marker-zero-write.out" \
        2>"$TMP_DIR/legacy-marker-zero-write.err"; then
    fail 'legacy completion marker passed without an explicit B/off override'
fi
require_text 'strict-A startup is disabled' \
    "$TMP_DIR/legacy-marker-zero-write.err" "legacy marker preflight refusal"
for forbidden in \
        "$legacy_marker_root/control" \
        "$legacy_marker_root/shared/assets" \
        "$legacy_marker_root/_base" \
        "$legacy_marker_root/${legacy_marker_id}/run" \
        "$legacy_marker_root/${legacy_marker_id}/log" \
        "$legacy_marker_root/${legacy_marker_id}/backups"; do
    [[ ! -e "$forbidden" && ! -L "$forbidden" ]] ||
        fail "legacy-marker preflight created forbidden path: $forbidden"
done

require_text 'source /dev/stdin <<<"$EARLY_CONF_SNAPSHOT"' "$START_VM" \
    "pinned vm.conf snapshot source"
if grep -F 'source "$CONF"' "$START_VM" >/dev/null; then
    fail 'start-vm reopens vm.conf instead of sourcing the pinned snapshot'
fi

if QEMU_SDL_DISABLE_IBUS=invalid \
        run_start "$gpu_id" "$TMP_DIR/gpu-invalid-sdl-ibus.out" \
            "$TMP_DIR/gpu-invalid-sdl-ibus.err" --no-tpm; then
    fail 'invalid QEMU_SDL_DISABLE_IBUS value was accepted'
fi
require_text 'QEMU_SDL_DISABLE_IBUS 必须是 auto 或 0/1' \
    "$TMP_DIR/gpu-invalid-sdl-ibus.err" "SDL IBus isolation input validation"

echo "PASS: root hardware profiles and dry-run semantics"

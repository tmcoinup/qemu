#!/usr/bin/env bash
# End-to-end semantic checks for the root deploy/create-vm.sh -> start-vm.sh
# workflow.  Keep the allowlists here independent from the generator catalog:
# adding a random-pool entry must be an explicit, reviewed test change too.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CREATE_VM="$REPO_ROOT/deploy/create-vm.sh"
START_VM="$REPO_ROOT/deploy/start-vm.sh"

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

assert_serials() {
    local label=$1

    [[ "$SYS_SN" =~ ^[A-Z0-9]{10}$ ]] \
        || fail "$label SYS_SN is not exactly 10 uppercase alphanumerics: '$SYS_SN'"
    [[ "$MB_SN" =~ ^[A-Z0-9]{12}$ ]] \
        || fail "$label MB_SN is not exactly 12 uppercase alphanumerics: '$MB_SN'"
    [[ "$CHASSIS_SN" =~ ^[A-Z0-9]{8}$ ]] \
        || fail "$label CHASSIS_SN is not exactly 8 uppercase alphanumerics: '$CHASSIS_SN'"
    [[ "$MEM_SN" =~ ^[0-9A-F]{8}$ ]] \
        || fail "$label MEM_SN is not an eight-digit SPD-style hex serial: '$MEM_SN'"
    case "$SSD_PROFILE" in
        crucial-mx100-512gb)
            [[ "$SSD_SN" =~ ^[0-9A-F]{12}$ ]] \
                || fail "$label MX100 serial has an invalid format: '$SSD_SN'"
            ;;
        kingston-kc400-512gb)
            [[ "$SSD_SN" =~ ^50026B72[0-9A-F]{8}$ ]] \
                || fail "$label KC400 serial has an invalid format: '$SSD_SN'"
            ;;
        intel-545s-512gb)
            [[ "$SSD_SN" =~ ^(BTLA|PHLA)[A-Z0-9]{8}512DGN$ ]] \
                || fail "$label Intel 545s serial has an invalid format: '$SSD_SN'"
            ;;
        wd-pc-sa530-512gb)
            [[ "$SSD_SN" =~ ^[A-Z0-9]{12}$ ]] \
                || fail "$label WD PC SA530 serial has an invalid format: '$SSD_SN'"
            ;;
        wd-black-pcie-512gb)
            [[ "$SSD_SN" =~ ^[0-9]{12}$ ]] \
                || fail "$label WD Black serial has an invalid format: '$SSD_SN'"
            ;;
        *)
            [[ "$SSD_SN" =~ ^[A-Z0-9]{16}$ ]] \
                || fail "$label SSD_SN is not exactly 16 uppercase alphanumerics: '$SSD_SN'"
            ;;
    esac
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

    case "$KBD_VID|$KBD_PID|$KBD_MFR|$KBD_PRODUCT" in
        '0x045E|0x0750|Microsoft|Microsoft Wired Keyboard 600'|\
        '0x046D|0xC31C|Logitech|Logitech USB Keyboard K120'|\
        '0x09DA|0x1F12|A4TECH|A4TECH USB Keyboard KK-3'|\
        '0x24AE|0x200A|Rapoo|Rapoo USB Keyboard N1820'|\
        '0x413C|0x2003|Dell|Dell USB Keyboard') ;;
        *) fail "$label selected an unreviewed keyboard: $KBD_VID:$KBD_PID $KBD_PRODUCT" ;;
    esac
    case "$TABLET_VID|$TABLET_PID|$TABLET_MFR|$TABLET_PRODUCT" in
        '0x256C|0x006D|HUION|HUION PenTablet'|\
        '0x256C|0x006E|HUION|HUION H640P'|\
        '0x2FEB|0x0001|VEIKK|VEIKK A30'|\
        '0x28BD|0x0094|XP-PEN|XP-Pen Star G640') ;;
        *) fail "$label selected an unreviewed absolute pointer: $TABLET_VID:$TABLET_PID $TABLET_PRODUCT" ;;
    esac
}

assert_platform() {
    local requested=$1 label=$2 expected_cpu expected_tsc expected_mem_family
    local expected_mem_type expected_mem_speed expected_tpm expected_family
    local expected_socket expected_max_memory expected_l2_assoc
    local expected_main_slot expected_aux_slot expected_aux_type expected_aux_width
    local expected_aux_length expected_nvme_gen expected_nvme_lanes
    local expected_board_brand expected_board_model expected_board_revision
    local expected_chipset expected_bios expected_bios_date expected_mem_model
    local expected_xhci_device actual_board_revision

    case "$requested" in
        i5-4590)
            expected_cpu=Core-i5-4590
            expected_tsc=3300000000
            expected_mem_family=DDR3
            expected_mem_type=0x18
            expected_mem_speed=1600
            expected_tpm=1.2
            expected_family=205
            expected_socket=0x2D
            expected_board_brand=Gigabyte
            expected_board_model=GA-H97-D3H
            expected_board_revision=1.0
            expected_chipset=H97
            expected_bios=F7
            expected_bios_date=09/19/2015
            expected_mem_model=KVR16N11S8/4
            expected_max_memory=32
            expected_l2_assoc=7
            expected_main_slot=PCIEX16
            expected_aux_slot=PCIEX1_1
            expected_aux_type=171
            expected_aux_width=8
            expected_aux_length=3
            expected_nvme_gen=2
            expected_nvme_lanes=2
            expected_xhci_device=0x8CB1
            ;;
        i5-6500)
            expected_cpu=Core-i5-6500
            expected_tsc=3200000000
            expected_mem_family=DDR4
            expected_mem_type=0x1A
            expected_mem_speed=2133
            expected_tpm=2.0
            expected_family=205
            expected_socket=0x32
            expected_board_brand=Gigabyte
            expected_board_model=GA-B150M-D3H
            expected_board_revision=1.0
            expected_chipset=B150
            expected_bios=F21
            expected_bios_date=12/12/2016
            expected_mem_model=KVR21N15S8/4
            expected_max_memory=64
            expected_l2_assoc=5
            expected_main_slot=PCIEX16
            expected_aux_slot=PCIEX4
            expected_aux_type=177
            expected_aux_width=10
            expected_aux_length=4
            expected_nvme_gen=3
            expected_nvme_lanes=4
            expected_xhci_device=0xA12F
            ;;
        i3-8100)
            expected_cpu=Core-i3-8100
            expected_tsc=3600000000
            expected_mem_family=DDR4
            expected_mem_type=0x1A
            expected_mem_speed=2400
            expected_tpm=2.0
            expected_family=206
            expected_socket=0x32
            expected_board_brand=ASUS
            expected_board_model='PRIME B360M-A'
            expected_board_revision=1.xx
            expected_chipset=B360
            expected_bios=3202
            expected_bios_date=07/24/2021
            expected_mem_model=KVR24N17S8/4
            expected_max_memory=64
            expected_l2_assoc=5
            expected_main_slot=PCIEX16
            expected_aux_slot=PCIEX1_1
            expected_aux_type=177
            expected_aux_width=8
            expected_aux_length=3
            expected_nvme_gen=3
            expected_nvme_lanes=4
            expected_xhci_device=0xA36D
            ;;
        *) fail "test bug: unknown requested platform $requested" ;;
    esac

    assert_eq "$requested" "$PLATFORM" "$label platform override"
    assert_eq "$expected_cpu" "$CPU_MODEL" "$label CPU model"
    assert_eq "$expected_tsc" "$TSC_FREQ" "$label TSC frequency"
    actual_board_revision=${BOARD_REVISION:-${BOARD_VERSION:-}}
    assert_eq "$expected_board_brand" "$BOARD_BRAND" "$label board brand"
    assert_eq "$expected_board_model" "$BOARD_MODEL" "$label board model"
    assert_eq "$expected_board_revision" "$actual_board_revision" \
        "$label board revision"
    assert_eq "$expected_chipset" "$BOARD_CHIPSET" "$label board chipset"
    assert_eq "$expected_bios" "$BIOS_VER" "$label BIOS version"
    assert_eq "$expected_bios_date" "$BIOS_DATE" "$label BIOS date"
    assert_eq "$expected_mem_family" "$MEM_FAMILY" "$label memory family"
    assert_eq "$expected_mem_model" "$MEM_MODEL" "$label memory part"
    assert_eq "$expected_mem_type" "$MEM_TYPE_BYTE" "$label SMBIOS memory type"
    assert_eq "$expected_mem_speed" "$MEM_SPEED" "$label memory speed"
    assert_eq 64 "$MEM_WIDTH" "$label memory width"
    assert_eq 4096 "$MEM_MODULE_MB" "$label DIMM capacity"
    assert_eq 2 "$MEM_SLOTS" "$label populated DIMM count"
    assert_eq 4 "$MEM_BOARD_SLOTS" "$label physical DIMM slot count"
    assert_eq "$expected_max_memory" "$MEM_MAX_CAPACITY_GB" \
        "$label board maximum memory"
    assert_eq 8192 "$MEM_TOTAL_MB" "$label total memory"
    assert_eq "$expected_tpm" "$BOARD_TPM_VERSION" "$label board TPM capability"
    assert_eq "$expected_nvme_gen" "$BOARD_NVME_PCIE_GEN" \
        "$label board native M.2 PCIe generation"
    assert_eq "$expected_nvme_lanes" "$BOARD_NVME_PCIE_LANES" \
        "$label board native M.2 PCIe lanes"
    assert_eq 0x8086 "$XHCI_PCI_VENDOR_ID" "$label xHCI PCI vendor"
    assert_eq "$expected_xhci_device" "$XHCI_PCI_DEVICE_ID" \
        "$label xHCI PCI device"
    assert_eq 0x01 "$XHCI_PCI_REVISION" "$label xHCI PCI revision"
    assert_eq pcie.0 "$XHCI_PCI_BUS" "$label xHCI PCI bus"
    assert_eq 0x6 "$XHCI_PCI_ADDR" "$label xHCI PCI address"

    # The audited pool contains desktop 4 GiB UDIMMs.  These patterns catch
    # the old 8 GiB/SO-DIMM rows even if their metadata is accidentally copied.
    case "$MEM_MODEL" in
        */8|*8G|M471*|HMT41GS*|CT102464BF*|CMSO*)
            fail "$label contains an 8 GiB or SO-DIMM part in a 4 GiB desktop slot: $MEM_MODEL"
            ;;
    esac
    PLATFORM_EXPECTED_CPU_FAMILY=$expected_family
    PLATFORM_EXPECTED_CPU_SOCKET=$expected_socket
    PLATFORM_EXPECTED_BOARD_REVISION=$expected_board_revision
    PLATFORM_EXPECTED_MAX_MEMORY=$expected_max_memory
    PLATFORM_EXPECTED_L2_ASSOC=$expected_l2_assoc
    PLATFORM_EXPECTED_MAIN_SLOT=$expected_main_slot
    PLATFORM_EXPECTED_AUX_SLOT=$expected_aux_slot
    PLATFORM_EXPECTED_AUX_TYPE=$expected_aux_type
    PLATFORM_EXPECTED_AUX_WIDTH=$expected_aux_width
    PLATFORM_EXPECTED_AUX_LENGTH=$expected_aux_length
}

TMP_DIR="$(mktemp -d)"
VM_ROOT="$TMP_DIR/vms"
EMPTY_VGPU_CONFIG="$TMP_DIR/vgpu-host.conf"

cleanup() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

[[ -x "$CREATE_VM" ]] || fail "create-vm.sh is missing or not executable"
[[ -x "$START_VM" ]] || fail "start-vm.sh is missing or not executable"

touch "$TMP_DIR/OVMF_CODE.fd" "$TMP_DIR/OVMF_VARS.fd" "$EMPTY_VGPU_CONFIG"
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
echo "unexpected fake QEMU invocation: $*" >&2
exit 99
EOF
chmod +x "$TMP_DIR/qemu-system-x86_64"

create_vm() {
    local id=$1 platform=$2 ssd_profile=$3 output=$4

    env -i \
        HOME="${HOME:-/tmp}" \
        PATH=/usr/bin:/bin \
        VM_ROOT="$VM_ROOT" \
        "$CREATE_VM" "$id" \
        --platform "$platform" \
        --ssd-profile "$ssd_profile" \
        --gpu-profile gtx1050_2gb \
        --monitor-profile lenovo-d24-20 >"$output"
}

create_vm_default_ssd() {
    local id=$1 platform=$2 output=$3

    env -i \
        HOME="${HOME:-/tmp}" \
        PATH=/usr/bin:/bin \
        VM_ROOT="$VM_ROOT" \
        "$CREATE_VM" "$id" \
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

    env -i \
        HOME="${HOME:-/tmp}" \
        PATH=/usr/bin:/bin \
        DISPLAY=:99 \
        VM_ROOT="$VM_ROOT" \
        QEMU_BIN="$TMP_DIR/qemu-system-x86_64" \
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
    local source_conf="$VM_ROOT/instances/vm${source_id}/vm.conf"
    local target_dir="$VM_ROOT/instances/vm${target_id}"
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
mapfile -t default_ssds < <(ssd_default_profile_keys)
assert_eq 'samsung-840-pro-512gb samsung-850-pro-512gb samsung-860-pro-512gb crucial-mx100-512gb kingston-kc400-512gb intel-545s-512gb wd-pc-sa530-512gb wd-black-pcie-512gb samsung-970-pro-512gb' \
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
    done < <(ssd_default_profile_keys)
    printf '%s\n' "${candidates[@]}" | sort
}

assert_eq \
    'crucial-mx100-512gb intel-545s-512gb kingston-kc400-512gb samsung-840-pro-512gb samsung-850-pro-512gb samsung-860-pro-512gb wd-pc-sa530-512gb' \
    "$(best_default_ssds_for_platform i5-4590 | tr '\n' ' ' | sed 's/ $//')" \
    "H97 exact best-tier SATA candidate set"
assert_eq 'samsung-970-pro-512gb wd-black-pcie-512gb' \
    "$(best_default_ssds_for_platform i5-6500 | tr '\n' ' ' | sed 's/ $//')" \
    "B150 exact best-tier NVMe candidate set"
assert_eq 'samsung-970-pro-512gb wd-black-pcie-512gb' \
    "$(best_default_ssds_for_platform i3-8100 | tr '\n' ' ' | sed 's/ $//')" \
    "B360 exact best-tier NVMe candidate set"
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

declare -A PLATFORM_IDS=()
next_id=780001
for platform in i5-4590 i5-6500 i3-8100; do
    id=$next_id
    next_id=$((next_id + 1))
    output="$TMP_DIR/create-$id.out"
    platform_ssd=samsung-970-pro-512gb
    [[ "$platform" == i5-4590 ]] && platform_ssd=samsung-860-pro-512gb
    create_vm "$id" "$platform" "$platform_ssd" "$output"
    require_text 'B 模式 PCI identity 保持宿主 mdev' "$output" \
        "$platform create summary B-mode identity"
    require_text '  键盘:' "$output" "$platform create keyboard summary"
    require_text '  鼠标:' "$output" "$platform create pointer summary"
    conf="$VM_ROOT/instances/vm${id}/vm.conf"
    [[ -r "$conf" ]] || fail "$platform did not create vm.conf"
    # shellcheck source=/dev/null
    source "$conf"
    assert_platform "$platform" "$platform"
    expected_family=$PLATFORM_EXPECTED_CPU_FAMILY
    expected_socket=$PLATFORM_EXPECTED_CPU_SOCKET
    expected_board_revision=$PLATFORM_EXPECTED_BOARD_REVISION
    expected_max_memory=$PLATFORM_EXPECTED_MAX_MEMORY
    expected_l2_assoc=$PLATFORM_EXPECTED_L2_ASSOC
    expected_main_slot=$PLATFORM_EXPECTED_MAIN_SLOT
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
    run_start "$id" "$runtime_out" "$runtime_err" --no-gpu --no-tpm
    require_text "processor-family=${expected_family}" "$runtime_out" \
        "$platform SMBIOS processor family"
    require_text "processor-upgrade=${expected_socket}" "$runtime_out" \
        "$platform SMBIOS processor socket"
    require_text "version=${expected_board_revision}\\,serial=${MB_SN}" \
        "$runtime_out" "$platform SMBIOS board revision"
    require_text "slot_designation=${expected_main_slot}\\,slot_type=177\\,slot_data_bus_width=13" \
        "$runtime_out" "$platform SMBIOS PCIe Gen3 x16 slot"
    require_text "slot_designation=${expected_aux_slot}\\,slot_type=${expected_aux_type}\\,slot_data_bus_width=${expected_aux_width}\\,current_usage=4\\,slot_length=${expected_aux_length}" \
        "$runtime_out" "$platform SMBIOS occupied auxiliary PCIe slot"
    require_text 'type=17\,' "$runtime_out" "$platform SMBIOS Type 17"
    require_text "type=16\,max-capacity=${expected_max_memory}G\,num-devices=4" \
        "$runtime_out" "$platform SMBIOS physical memory array"
    require_text 'loc_pfx=DIMM_A2\|DIMM_B2\|DIMM_A1\|DIMM_B1' \
        "$runtime_out" "$platform exact DIMM locators"
    require_text 'bank=P0\ CHANNEL\ A\|P0\ CHANNEL\ B\|P0\ CHANNEL\ A\|P0\ CHANNEL\ B' \
        "$runtime_out" "$platform exact DIMM banks"
    require_text "part=${MEM_MODEL}" "$runtime_out" "$platform DIMM part"
    require_text "serial=${MEM_SN}\\|" "$runtime_out" \
        "$platform distinct per-DIMM serial list"
    require_text 'e1000e\,netdev=net0' "$runtime_out" \
        "$platform Intel network device"
    require_text 'subsys_ven=0x8086' "$runtime_out" \
        "$platform Intel network subsystem vendor"
    require_text 'i8042=off' "$runtime_out" \
        "$platform legacy PS/2 input disabled"
    require_text "qemu-xhci\,id=xhci\,bus=${XHCI_PCI_BUS}\,addr=${XHCI_PCI_ADDR}\,x-pci-vendor-id=${XHCI_PCI_VENDOR_ID}\,x-pci-device-id=${XHCI_PCI_DEVICE_ID}\,x-pci-revision=${XHCI_PCI_REVISION}" \
        "$runtime_out" "$platform persisted xHCI PCI identity"
    reject_text '旧 vm.conf 缺少 xHCI PCI identity' "$runtime_err" \
        "$platform false legacy xHCI warning"
    require_text '  键盘:' "$runtime_out" "$platform runtime keyboard summary"
    require_text '  鼠标:' "$runtime_out" "$platform runtime pointer summary"
    require_text "usb-kbd\\,bus=xhci.0\\,vendorid=${KBD_VID}\\,productid=${KBD_PID}" \
        "$runtime_out" "$platform USB keyboard device"
    require_text "usb-tablet\\,bus=xhci.0\\,vendorid=${TABLET_VID}\\,productid=${TABLET_PID}" \
        "$runtime_out" "$platform absolute USB pointer device"
    [[ "$(grep -Fc -- 'usb-kbd\,' "$runtime_out")" -eq 1 ]] \
        || fail "$platform runtime must contain exactly one usb-kbd"
    [[ "$(grep -Fc -- 'usb-tablet\,' "$runtime_out")" -eq 1 ]] \
        || fail "$platform runtime must contain exactly one usb-tablet"
    if grep -F -- 'usb-kbd\,' "$runtime_out" | grep -Fq -- 'serial=' ||
            grep -F -- 'usb-tablet\,' "$runtime_out" | grep -Fq -- 'serial='; then
        fail "$platform USB HID descriptor must not invent a serial number"
    fi
    require_text 'socket_designation=L1\ Cache\,level=1\,installed_size=256\,max_size=256\,associativity=7' \
        "$runtime_out" "$platform aggregate L1 cache"
    require_text "socket_designation=L2\\ Cache\\,level=2\\,installed_size=1024\\,max_size=1024\\,associativity=${expected_l2_assoc}" \
        "$runtime_out" "$platform L2 associativity"
    require_text 'socket_designation=L3\ Cache\,level=3\,installed_size=6144\,max_size=6144\,associativity=9' \
        "$runtime_out" "$platform L3 associativity"
    grep -Fx -- '  8192' "$runtime_out" >/dev/null \
        || fail "$platform runtime memory is not 8192 MiB"
done

# The xHCI identity is one atomic Windows PnP tuple.  Never fill a missing
# member from a newer launcher/catalog, and reject a syntactically complete
# tuple that changes the fixed root-bus topology.
partial_xhci_id=$next_id
next_id=$((next_id + 1))
partial_xhci_conf="$VM_ROOT/instances/vm${partial_xhci_id}/vm.conf"
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
invalid_xhci_conf="$VM_ROOT/instances/vm${invalid_xhci_id}/vm.conf"
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
legacy_storage_dir="$VM_ROOT/instances/vm${legacy_storage_id}"
legacy_storage_conf="$legacy_storage_dir/vm.conf"
rewrite_conf "${PLATFORM_IDS[i5-4590]}" "$legacy_storage_id" omit
chmod u+w "$legacy_storage_conf"
sed -i \
    -e '/^BOARD_NVME_PCIE_GEN=/d' \
    -e '/^BOARD_NVME_PCIE_LANES=/d' \
    -e '/^SSD_FORM_FACTOR=/d' \
    -e '/^SSD_PCIE_GEN=/d' \
    -e '/^SSD_PCIE_LANES=/d' \
    -e '/^SSD_LOGICAL_BLOCK_SIZE=/d' \
    -e '/^SSD_PHYSICAL_BLOCK_SIZE=/d' \
    -e 's/^SSD_PROFILE=.*/SSD_PROFILE=legacy-samsung-nvme/' \
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
partial_storage_dir="$VM_ROOT/instances/vm${partial_storage_id}"
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
strict_storage_dir="$VM_ROOT/instances/vm${strict_storage_id}"
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
if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin VM_ROOT="$VM_ROOT" \
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
guard_dir="$VM_ROOT/instances/vm${guard_id}"
guard_conf="$guard_dir/vm.conf"
: >"$guard_dir/disk.qcow2"
guard_hash=$(sha256sum "$guard_conf")

capacity_guard_id=$next_id
next_id=$((next_id + 1))
capacity_guard_dir="$VM_ROOT/instances/vm${capacity_guard_id}"
capacity_guard_conf="$capacity_guard_dir/vm.conf"
rewrite_conf "$guard_id" "$capacity_guard_id" omit
chmod u+w "$capacity_guard_conf"
sed -i \
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
if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin VM_ROOT="$VM_ROOT" \
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
controller_guard_dir="$VM_ROOT/instances/vm${controller_guard_id}"
controller_guard_conf="$controller_guard_dir/vm.conf"
: >"$controller_guard_dir/disk.qcow2"
controller_guard_hash=$(sha256sum "$controller_guard_conf")
if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin VM_ROOT="$VM_ROOT" \
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
if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin VM_ROOT="$VM_ROOT" \
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

# The implicit path first chooses the best compatible topology tier; every
# selectable model now has the same exact 512 GB capacity as the shared base.
# H97/DDR3 falls back to SATA; both Gen3 x4 boards must prefer NVMe.
for default_platform in i5-4590 i5-6500 i3-8100; do
    default_ssd_id=$next_id
    next_id=$((next_id + 1))
    create_vm_default_ssd "$default_ssd_id" "$default_platform" \
        "$TMP_DIR/create-default-ssd-${default_platform}.out"
    # shellcheck source=/dev/null
    source "$VM_ROOT/instances/vm${default_ssd_id}/vm.conf"
    [[ "$SSD_SIZE_BYTES" == 512110190592 ]] \
        || fail "$default_platform implicit SSD is not exact 512 GB: $SSD_SIZE_BYTES"
    case "$default_platform|$SSD_INTERFACE|$SSD_PCIE_GEN|$SSD_PCIE_LANES" in
        'i5-4590|sata|0|0'|\
        'i5-6500|nvme|3|4'|\
        'i3-8100|nvme|3|4') ;;
        *) fail "$default_platform did not select its highest compatible storage tier: $SSD_PROFILE" ;;
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
    conf="$VM_ROOT/instances/vm${id}/vm.conf"
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

no_tpm_id=$next_id
next_id=$((next_id + 1))
rewrite_conf "$tpm2_id" "$no_tpm_id" none
run_start "$no_tpm_id" "$TMP_DIR/no-board-tpm.out" \
    "$TMP_DIR/no-board-tpm.err" --no-gpu
reject_text 'tpm-crb\,tpmdev=tpm0' "$TMP_DIR/no-board-tpm.out" \
    "board without TPM"
reject_text 'tpm-tis\,tpmdev=tpm0' "$TMP_DIR/no-board-tpm.out" \
    "board without TPM TIS"

if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin DISPLAY=:99 \
        VM_ROOT="$VM_ROOT" QEMU_BIN="$TMP_DIR/qemu-system-x86_64" \
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
run_start "$legacy_id" "$TMP_DIR/legacy-tpm.out" "$TMP_DIR/legacy-tpm.err" --no-gpu
require_text 'tpm-crb\,tpmdev=tpm0' "$TMP_DIR/legacy-tpm.out" \
    "legacy config TPM compatibility"

# SPOOF_MODE=B is name-only: the summary must say that PCI identity remains the
# host mdev and the vfio device must not receive the consumer-card PCI IDs.
gpu_id=${PLATFORM_IDS[i3-8100]}
# shellcheck source=/dev/null
source "$VM_ROOT/instances/vm${gpu_id}/vm.conf"
run_start "$gpu_id" "$TMP_DIR/gpu-b.out" "$TMP_DIR/gpu-b.err" --no-tpm
require_text 'PCI identity remains host mdev' "$TMP_DIR/gpu-b.out" \
    "SPOOF_MODE=B identity explanation"
reject_text "x-pci-device-id=${GPU_PCI_DID}" "$TMP_DIR/gpu-b.out" \
    "SPOOF_MODE=B consumer PCI device"
reject_text "x-pci-sub-device-id=${GPU_SUB_DID}" "$TMP_DIR/gpu-b.out" \
    "SPOOF_MODE=B consumer PCI subsystem"

# A freshly generated full-consumer target must not enter A before the audited
# driver receipt has been recorded; otherwise it would boot Basic Display.
if run_start "$gpu_id" "$TMP_DIR/gpu-a-unprepared.out" \
        "$TMP_DIR/gpu-a-unprepared.err" --no-tpm --spoof-mode A; then
    fail 'unprepared full-consumer GTX 1050 entered A mode'
fi
require_text 'full-consumer A 尚未完成 V3 驱动收尾' \
    "$TMP_DIR/gpu-a-unprepared.err" "unprepared A-mode refusal"

# The same half-migrated policy must still permit a no-vGPU rescue, otherwise
# finish-vgpu-install.sh would tell the user to invoke itself and then be
# rejected by start-vm.sh before its EXE could repair the guest.
run_start "$gpu_id" "$TMP_DIR/gpu-a-rescue.out" \
    "$TMP_DIR/gpu-a-rescue.err" --no-tpm --rescue-sdl --spoof-mode A
require_text '仅允许无 vGPU 救援' "$TMP_DIR/gpu-a-rescue.err" \
    "unprepared A-mode rescue allowance"
require_text '标准显卡 -> SDL 本地救援' "$TMP_DIR/gpu-a-rescue.out" \
    "unprepared A-mode rescue display"
reject_text 'vfio-pci-nohotplug' "$TMP_DIR/gpu-a-rescue.out" \
    "unprepared A-mode rescue vGPU attachment"

# Positive control: the complete receipt-derived policy really does add both
# the outer PCI tuple and the internal vdev/pdev pair.
VGPU_MDEV_INTERNAL_PCI_IDENTITY=1 VGPU_MDEV_FRL_ENABLED=0 \
VGPU_PATCHED_DRIVER_VERSION=31.0.15.3833 \
    run_start "$gpu_id" "$TMP_DIR/gpu-a.out" "$TMP_DIR/gpu-a.err" \
        --no-tpm --spoof-mode A
require_text "x-pci-device-id=${GPU_PCI_DID}" "$TMP_DIR/gpu-a.out" \
    "SPOOF_MODE=A consumer PCI device"
require_text "x-pci-sub-device-id=${GPU_SUB_DID}" "$TMP_DIR/gpu-a.out" \
    "SPOOF_MODE=A consumer PCI subsystem"
require_text 'vGPU internal PCI identity: ENABLED audited GTX1050 (vdev_id=0x1C8111C0, pdev_id=0x1C81)' \
    "$TMP_DIR/gpu-a.out" "audited A-mode internal PCI identity"
require_text 'vGPU frame-rate limiter: per-mdev frl_enabled=0' \
    "$TMP_DIR/gpu-a.out" "audited per-mdev FRL disable"

# The second-stage RM/licensing experiment is deliberately independent from
# outer A-mode PCI spoofing.  One explicit environment variable enables the
# exact NVIDIA DEV_16:SUBDEV_16 / DEV_16 pair; B mode remains name-only.
VGPU_MDEV_INTERNAL_PCI_IDENTITY=1 VGPU_MDEV_FRL_ENABLED=0 \
VGPU_PATCHED_DRIVER_VERSION=31.0.15.3833 \
    run_start "$gpu_id" "$TMP_DIR/gpu-a-internal.out" \
        "$TMP_DIR/gpu-a-internal.err" --no-tpm --spoof-mode A
require_text 'vGPU internal PCI identity: ENABLED audited GTX1050 (vdev_id=0x1C8111C0, pdev_id=0x1C81)' \
    "$TMP_DIR/gpu-a-internal.out" "explicit A-mode internal PCI identity"

VGPU_MDEV_INTERNAL_PCI_IDENTITY=1 \
    run_start "$gpu_id" "$TMP_DIR/gpu-b-internal.out" \
        "$TMP_DIR/gpu-b-internal.err" --no-tpm --spoof-mode B
require_text 'vGPU internal PCI identity: inactive (requires SPOOF_MODE=A' \
    "$TMP_DIR/gpu-b-internal.out" "B-mode internal PCI identity gate"
reject_text 'vdev_id=' "$TMP_DIR/gpu-b-internal.out" \
    "B-mode internal vdev_id"

if VGPU_MDEV_INTERNAL_PCI_IDENTITY=2 \
        run_start "$gpu_id" "$TMP_DIR/gpu-invalid-internal.out" \
            "$TMP_DIR/gpu-invalid-internal.err" --no-tpm --spoof-mode A; then
    fail 'invalid VGPU_MDEV_INTERNAL_PCI_IDENTITY value was accepted'
fi
require_text 'VGPU_MDEV_INTERNAL_PCI_IDENTITY 必须是 0 或 1' \
    "$TMP_DIR/gpu-invalid-internal.err" "internal PCI identity input validation"

VGPU_MDEV_INTERNAL_PCI_IDENTITY=1 VGPU_MDEV_FRL_ENABLED=0 \
VGPU_PATCHED_DRIVER_VERSION=31.0.15.3833 \
    run_start "$gpu_id" "$TMP_DIR/gpu-a-frl.out" \
        "$TMP_DIR/gpu-a-frl.err" --no-tpm --spoof-mode A
require_text 'vGPU frame-rate limiter: per-mdev frl_enabled=0' \
    "$TMP_DIR/gpu-a-frl.out" "explicit per-mdev FRL disable"

# A persisted FRL override is an A/B identity feature.  --no-spoof is the
# established driver install/recovery path and must temporarily inherit the
# resource profile instead of becoming impossible to start.
VGPU_MDEV_FRL_ENABLED=0 \
    run_start "$gpu_id" "$TMP_DIR/gpu-off-frl.out" \
        "$TMP_DIR/gpu-off-frl.err" --no-tpm --spoof-mode off
require_text 'vGPU frame-rate limiter: inherited from resource profile' \
    "$TMP_DIR/gpu-off-frl.out" "off-mode FRL inheritance"
reject_text 'per-mdev frl_enabled=0' "$TMP_DIR/gpu-off-frl.out" \
    "off-mode stale FRL override"

if VGPU_MDEV_FRL_ENABLED=2 \
        run_start "$gpu_id" "$TMP_DIR/gpu-invalid-frl.out" \
            "$TMP_DIR/gpu-invalid-frl.err" --no-tpm --spoof-mode A; then
    fail 'invalid VGPU_MDEV_FRL_ENABLED value was accepted'
fi
require_text 'VGPU_MDEV_FRL_ENABLED 必须是 0 或 1' \
    "$TMP_DIR/gpu-invalid-frl.err" "per-mdev FRL input validation"

if QEMU_SDL_DISABLE_IBUS=invalid \
        run_start "$gpu_id" "$TMP_DIR/gpu-invalid-sdl-ibus.out" \
            "$TMP_DIR/gpu-invalid-sdl-ibus.err" --no-tpm; then
    fail 'invalid QEMU_SDL_DISABLE_IBUS value was accepted'
fi
require_text 'QEMU_SDL_DISABLE_IBUS 必须是 auto 或 0/1' \
    "$TMP_DIR/gpu-invalid-sdl-ibus.err" "SDL IBus isolation input validation"

echo "PASS: root hardware profiles and dry-run semantics"

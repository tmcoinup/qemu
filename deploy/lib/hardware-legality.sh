#!/usr/bin/env bash
# shellcheck shell=bash
#
# G-11 hardware-combination legality checks.
#
# This library is deliberately read-only: it neither rewrites vm.conf nor
# starts host/guest components.  Source it after (or instead of) the hardware
# catalogs and call:
#
#   if ! g11_hardware_combination_validate strict; then
#       printf '%s: %s\n' "$G11_HW_LEGALITY_CODE" \
#           "$G11_HW_LEGALITY_MESSAGE" >&2
#       exit 2
#   fi
#
# The function reads the conventional vm.conf/runtime variable names.  Its
# only outputs are the G11_HW_LEGALITY_* result variables.  It returns zero for
# a legal combination and one for an illegal combination.  Result codes are a
# stable machine-facing contract; messages are operator-facing diagnostics.
#
# Policies:
#   strict  - current G-11 profiles; audited metadata must be complete.
#   legacy  - an old config may omit newer metadata as a whole.  Known catalog
#             facts are inferred for validation without modifying the caller.
#             Contradictory or partially populated metadata still fails.

_g11_hw_legality_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -p HARDWARE_PROFILES SSD_PROFILES >/dev/null 2>&1; then
    # shellcheck source=hardware-profiles.sh
    source "$_g11_hw_legality_lib_dir/hardware-profiles.sh"
fi
if ! declare -p VGPU_PROFILE_CATALOG >/dev/null 2>&1; then
    # shellcheck source=vgpu-profiles.sh
    source "$_g11_hw_legality_lib_dir/vgpu-profiles.sh"
fi
unset _g11_hw_legality_lib_dir

G11_HW_LEGALITY_CODE=NOT_RUN
G11_HW_LEGALITY_MESSAGE='hardware combination has not been checked'
G11_HW_LEGALITY_POLICY=''
G11_HW_LEGALITY_LEGACY_FIELDS=''

_g11_hw_legality_reset() {
    G11_HW_LEGALITY_CODE=NOT_RUN
    G11_HW_LEGALITY_MESSAGE='hardware combination has not been checked'
    G11_HW_LEGALITY_POLICY=${1:-}
    G11_HW_LEGALITY_LEGACY_FIELDS=''
}

_g11_hw_legality_fail() {
    G11_HW_LEGALITY_CODE=$1
    G11_HW_LEGALITY_MESSAGE=$2
    return 1
}

_g11_hw_legality_note_legacy() {
    local field=$1

    case ",${G11_HW_LEGALITY_LEGACY_FIELDS}," in
        *",${field},"*) return 0 ;;
    esac
    if [[ -n "$G11_HW_LEGALITY_LEGACY_FIELDS" ]]; then
        G11_HW_LEGALITY_LEGACY_FIELDS+=",$field"
    else
        G11_HW_LEGALITY_LEGACY_FIELDS=$field
    fi
}

_g11_hw_legality_exact_or_legacy() {
    local policy=$1 field=$2 actual=$3 expected=$4
    local missing_code=$5 mismatch_code=$6

    if [[ -z "$actual" ]]; then
        if [[ "$policy" == legacy ]]; then
            _g11_hw_legality_note_legacy "$field"
            return 0
        fi
        _g11_hw_legality_fail "$missing_code" \
            "$field is required by the strict hardware contract"
        return 1
    fi
    if [[ "$actual" != "$expected" ]]; then
        _g11_hw_legality_fail "$mismatch_code" \
            "$field=$actual does not match the audited value $expected"
        return 1
    fi
}

# Print the reviewed desktop generation represented by a platform catalog key.
# The CPU catalog is the single source of truth; adding a combination cannot
# silently bypass this lookup with another hard-coded case list.
g11_hardware_platform_generation() {
    local requested=${1:-} generation
    generation=$(
        hardware_profile_load "$requested" || exit
        printf '%s\n' "$CPU_GENERATION"
    ) || return
    printf '%s\n' "$generation"
}

g11_hardware_expected_tpm_frontend() {
    case "${1:-}" in
        none) printf 'none\n' ;;
        1.2)  printf 'tpm-tis\n' ;;
        2.0)  printf 'tpm-crb\n' ;;
        *) return 1 ;;
    esac
}

# Validate the complete set of conventional G-11 hardware variables in the
# caller's shell.  This function never assigns those variables.
g11_hardware_combination_validate() {
    local policy=${1:-strict}
    local platform=${PLATFORM-} platform_generation=${PLATFORM_GENERATION-}
    local cpu_model=${CPU_MODEL-} tsc_freq=${TSC_FREQ-}
    local board_brand=${BOARD_BRAND-} board_model=${BOARD_MODEL-}
    local board_revision=${BOARD_REVISION-} board_chipset=${BOARD_CHIPSET-}
    local board_version=${BOARD_VERSION-}
    local bios_version=${BIOS_VER-} bios_date=${BIOS_DATE-}
    local board_tpm=${BOARD_TPM_VERSION-}
    local board_nvme_gen=${BOARD_NVME_PCIE_GEN-}
    local board_nvme_lanes=${BOARD_NVME_PCIE_LANES-}
    local board_release_year=${BOARD_RELEASE_YEAR-}
    local board_serial_policy=${BOARD_SERIAL_POLICY-}
    local mem_brand=${MEM_BRAND-} mem_model=${MEM_MODEL-}
    local mem_model_list=${MEM_MODEL_LIST-}
    local mem_speed=${MEM_SPEED-} mem_family=${MEM_FAMILY-}
    local mem_type=${MEM_TYPE_BYTE-} mem_width=${MEM_WIDTH-}
    local mem_module_mb=${MEM_MODULE_MB-}
    local mem_module_list=${MEM_MODULE_MB_LIST-} mem_slots=${MEM_SLOTS-}
    local mem_total_mb=${MEM_TOTAL_MB-} mem_form=${MEM_FORM_FACTOR-}
    local mem_board_slots=${MEM_BOARD_SLOTS-}
    local mem_max_gb=${MEM_MAX_CAPACITY_GB-}
    local mem_device_width_list=${MEM_DEVICE_WIDTH_LIST-}
    local mem_channel_mode=${MEM_CHANNEL_MODE-}
    local mem_rank_list=${MEM_RANK_LIST-}
    local mem_module_jep106_list=${MEM_MODULE_MFR_JEP106_LIST-}
    local mem_dram_jep106_list=${MEM_DRAM_MFR_JEP106_LIST-}
    local ssd_profile=${SSD_PROFILE-} ssd_interface=${SSD_INTERFACE-}
    local ssd_controller=${SSD_CONTROLLER_PROFILE-}
    local ssd_form=${SSD_FORM_FACTOR-} ssd_gen=${SSD_PCIE_GEN-}
    local ssd_lanes=${SSD_PCIE_LANES-}
    local ssd_model=${SSD_MODEL-} ssd_size=${SSD_SIZE_BYTES-}
    local ssd_firmware=${SSD_FIRMWARE_REV-}
    local ssd_logical_sector=${SSD_LOGICAL_BLOCK_SIZE-}
    local ssd_physical_sector=${SSD_PHYSICAL_BLOCK_SIZE-}
    local gpu_profile=${GPU_PROFILE-} gpu_mdev=${VGPU_MDEV_PROFILE-}
    local gpu_fb=${VGPU_FB_MB-} gpu_vram=${GPU_VRAM_MB-}
    local gpu_width=${GPU_PCIE_WIDTH-}
    local resource_profile=${VGPU_RESOURCE_PROFILE-}
    local resource_fb=${VGPU_RESOURCE_FB_MB-}
    local tpm_switch=${TPM-}
    local tpm_effective_a=${TPM_EFFECTIVE_VERSION-}
    local tpm_effective_b=${VM_TPM_VERSION-}
    local tpm_frontend_a=${TPM_FRONTEND-}
    local tpm_frontend_b=${VM_TPM_QEMU_DEVICE-}
    local row key found=0
    local exp_cpu exp_tsc exp_board_brand exp_board_model exp_board_revision
    local exp_chipset exp_bios exp_bios_date exp_board_tpm
    local exp_mem_brand exp_mem_model exp_mem_speed exp_mem_family exp_mem_type
    local exp_mem_width exp_mem_module_mb exp_mem_slots exp_mem_form
    local exp_mem_board_slots exp_mem_max_gb exp_board_nvme_gen
    local exp_board_nvme_lanes exp_generation
    local exp_mem_model_list exp_mem_module_list exp_mem_device_width_list
    local exp_mem_channel_mode exp_mem_rank_list exp_mem_module_jep106_list
    local exp_mem_dram_jep106_list exp_mem_total_mb expected_memory_detail
    local exp_board_release_year exp_board_serial_policy expected_identity_detail
    local exp_ssd_model exp_ssd_interface exp_ssd_size exp_ssd_firmware
    local exp_ssd_controller exp_ssd_form exp_ssd_gen exp_ssd_lanes
    local exp_ssd_logical_sector exp_ssd_physical_sector
    local exp_gpu_mdev exp_gpu_vram exp_gpu_width
    local _name _vid _did _subvid _subdid _rev _vbios _core _boost _memory
    local _bus _bandwidth _ram_type _ram_maker _nvapi_type _nvapi_maker
    local _cuda _subpipes _rop _tmu _arch _impl _chiprev
    local topology_count=0 sector_count=0 resource_count=0
    local tpm_effective tpm_frontend expected_frontend expected_tpm
    local board_tpm_was_missing=0 memory_detail_policy=$policy
    local identity_detail_policy=legacy
    local memory_detail_count=0 memory_detail_field

    _g11_hw_legality_reset "$policy"
    case "$policy" in
        strict|legacy) ;;
        *)
            _g11_hw_legality_fail INVALID_POLICY \
                "policy must be strict or legacy (got: ${policy:-<empty>})"
            return 1
            ;;
    esac

    if ! hardware_profile_validate_catalog >/dev/null 2>&1 ||
            ! vgpu_profile_validate_catalog >/dev/null 2>&1; then
        _g11_hw_legality_fail CATALOG_INVALID \
            'the G-11 hardware or vGPU catalog failed its own validation'
        return 1
    fi

    if [[ -z "$platform" ]]; then
        _g11_hw_legality_fail PLATFORM_REQUIRED \
            'PLATFORM is required to validate board generation and topology'
        return 1
    fi
    for row in "${HARDWARE_PROFILES[@]}"; do
        IFS='|' read -r key exp_cpu exp_tsc exp_board_brand exp_board_model \
            exp_board_revision exp_chipset exp_bios exp_bios_date \
            exp_board_tpm exp_mem_brand exp_mem_model exp_mem_speed \
            exp_mem_family exp_mem_type exp_mem_width exp_mem_module_mb \
            exp_mem_slots exp_mem_form exp_mem_board_slots exp_mem_max_gb \
            exp_board_nvme_gen exp_board_nvme_lanes <<<"$row"
        if [[ "$key" == "$platform" ]]; then
            found=1
            break
        fi
    done
    if (( ! found )); then
        _g11_hw_legality_fail PLATFORM_UNKNOWN \
            "PLATFORM=$platform is not in the reviewed G-11 catalog"
        return 1
    fi
    expected_memory_detail=$(
        hardware_profile_load "$platform" || exit
        printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$MEM_MODEL_LIST" \
            "$MEM_MODULE_MB_LIST" "$MEM_DEVICE_WIDTH_LIST" \
            "$MEM_CHANNEL_MODE" "$MEM_RANK_LIST" \
            "$MEM_MODULE_MFR_JEP106_LIST" "$MEM_DRAM_MFR_JEP106_LIST" \
            "$MEM_TOTAL_MB"
    ) || {
        _g11_hw_legality_fail PLATFORM_METADATA_REQUIRED \
            "PLATFORM=$platform has no reviewed per-slot memory contract"
        return 1
    }
    IFS='|' read -r exp_mem_model_list exp_mem_module_list \
        exp_mem_device_width_list exp_mem_channel_mode exp_mem_rank_list \
        exp_mem_module_jep106_list exp_mem_dram_jep106_list exp_mem_total_mb \
        <<<"$expected_memory_detail"
    expected_identity_detail=$(
        hardware_profile_load "$platform" || exit
        printf '%s|%s\n' "$BOARD_RELEASE_YEAR" "$BOARD_SERIAL_POLICY"
    ) || {
        _g11_hw_legality_fail PLATFORM_METADATA_REQUIRED \
            "PLATFORM=$platform has no reviewed board identity contract"
        return 1
    }
    IFS='|' read -r exp_board_release_year exp_board_serial_policy \
        <<<"$expected_identity_detail"
    # Component contract v1 predates per-slot lists, so its four per-slot
    # fields may be omitted only as one atomic legacy group.  If any one is
    # persisted, all four become mandatory and must match the catalog.  The v2
    # contract always requires the complete group, even under legacy policy.
    for memory_detail_field in MEM_MODEL_LIST MEM_MODULE_MB_LIST \
            MEM_DEVICE_WIDTH_LIST MEM_CHANNEL_MODE; do
        [[ ! -v $memory_detail_field ]] || \
            memory_detail_count=$((memory_detail_count + 1))
    done
    case "${HARDWARE_COMPONENT_CONTRACT_VERSION-}" in
        1)
            if (( memory_detail_count != 0 && memory_detail_count != 4 )); then
                _g11_hw_legality_fail COMPONENT_CONTRACT_MISMATCH \
                    'component contract v1 per-slot memory metadata must be all present or all absent'
                return 1
            fi
            if (( memory_detail_count == 0 )); then
                memory_detail_policy=legacy
            else
                memory_detail_policy=strict
            fi
            ;;
        2)
            memory_detail_policy=strict
            ;;
        3)
            memory_detail_policy=strict
            identity_detail_policy=strict
            ;;
    esac
    if ! hardware_profile_component_contract_validate "$platform"; then
        _g11_hw_legality_fail COMPONENT_CONTRACT_MISMATCH \
            "$HARDWARE_COMPONENT_CONTRACT_ERROR"
        return 1
    fi
    exp_generation=$(g11_hardware_platform_generation "$platform") || {
        _g11_hw_legality_fail PLATFORM_GENERATION_UNKNOWN \
            "PLATFORM=$platform has no reviewed desktop-generation mapping"
        return 1
    }
    if [[ -n "$platform_generation" &&
          "$platform_generation" != "$exp_generation" ]]; then
        _g11_hw_legality_fail PLATFORM_GENERATION_MISMATCH \
            "PLATFORM_GENERATION=$platform_generation conflicts with $platform (generation $exp_generation)"
        return 1
    fi

    _g11_hw_legality_exact_or_legacy "$policy" CPU_MODEL "$cpu_model" \
        "$exp_cpu" PLATFORM_METADATA_REQUIRED PLATFORM_CPU_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" TSC_FREQ "$tsc_freq" \
        "$exp_tsc" PLATFORM_METADATA_REQUIRED PLATFORM_TSC_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" BOARD_BRAND "$board_brand" \
        "$exp_board_brand" PLATFORM_METADATA_REQUIRED \
        PLATFORM_BOARD_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" BOARD_MODEL "$board_model" \
        "$exp_board_model" PLATFORM_METADATA_REQUIRED \
        PLATFORM_BOARD_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" BOARD_REVISION \
        "$board_revision" "$exp_board_revision" PLATFORM_METADATA_REQUIRED \
        PLATFORM_BOARD_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" BOARD_VERSION \
        "$board_version" "$exp_board_revision" PLATFORM_METADATA_REQUIRED \
        BOARD_VERSION_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" BOARD_CHIPSET "$board_chipset" \
        "$exp_chipset" PLATFORM_METADATA_REQUIRED \
        PLATFORM_BOARD_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" BIOS_VER "$bios_version" \
        "$exp_bios" PLATFORM_METADATA_REQUIRED BIOS_VERSION_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" BIOS_DATE "$bios_date" \
        "$exp_bios_date" PLATFORM_METADATA_REQUIRED BIOS_DATE_MISMATCH || return 1
    if [[ -z "$board_tpm" ||
          ( "$policy" == legacy && "$board_tpm" == legacy ) ]]; then
        board_tpm_was_missing=1
    fi
    if [[ "$policy" == legacy && "$board_tpm" == legacy ]]; then
        _g11_hw_legality_note_legacy BOARD_TPM_VERSION
    else
        _g11_hw_legality_exact_or_legacy "$policy" BOARD_TPM_VERSION "$board_tpm" \
            "$exp_board_tpm" PLATFORM_METADATA_REQUIRED \
            TPM_BOARD_VERSION_MISMATCH || return 1
    fi
    _g11_hw_legality_exact_or_legacy "$policy" BOARD_NVME_PCIE_GEN \
        "$board_nvme_gen" "$exp_board_nvme_gen" PLATFORM_METADATA_REQUIRED \
        PLATFORM_PCIE_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" BOARD_NVME_PCIE_LANES \
        "$board_nvme_lanes" "$exp_board_nvme_lanes" \
        PLATFORM_METADATA_REQUIRED PLATFORM_PCIE_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$identity_detail_policy" \
        BOARD_RELEASE_YEAR "$board_release_year" "$exp_board_release_year" \
        PLATFORM_METADATA_REQUIRED PLATFORM_BOARD_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$identity_detail_policy" \
        BOARD_SERIAL_POLICY "$board_serial_policy" "$exp_board_serial_policy" \
        PLATFORM_METADATA_REQUIRED PLATFORM_BOARD_MISMATCH || return 1

    _g11_hw_legality_exact_or_legacy "$policy" MEM_BRAND "$mem_brand" \
        "$exp_mem_brand" MEMORY_METADATA_REQUIRED MEMORY_MODEL_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" MEM_MODEL "$mem_model" \
        "$exp_mem_model" MEMORY_METADATA_REQUIRED MEMORY_MODEL_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$memory_detail_policy" MEM_MODEL_LIST \
        "$mem_model_list" "$exp_mem_model_list" MEMORY_METADATA_REQUIRED \
        MEMORY_MODEL_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" MEM_FAMILY "$mem_family" \
        "$exp_mem_family" MEMORY_METADATA_REQUIRED \
        MEMORY_FAMILY_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" MEM_SPEED "$mem_speed" \
        "$exp_mem_speed" MEMORY_METADATA_REQUIRED MEMORY_SPEED_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" MEM_TYPE_BYTE "$mem_type" \
        "$exp_mem_type" MEMORY_METADATA_REQUIRED MEMORY_TYPE_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" MEM_WIDTH "$mem_width" \
        "$exp_mem_width" MEMORY_METADATA_REQUIRED MEMORY_LAYOUT_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" MEM_MODULE_MB "$mem_module_mb" \
        "$exp_mem_module_mb" MEMORY_METADATA_REQUIRED \
        MEMORY_LAYOUT_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$memory_detail_policy" \
        MEM_MODULE_MB_LIST "$mem_module_list" "$exp_mem_module_list" \
        MEMORY_METADATA_REQUIRED MEMORY_LAYOUT_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$memory_detail_policy" \
        MEM_DEVICE_WIDTH_LIST "$mem_device_width_list" \
        "$exp_mem_device_width_list" MEMORY_METADATA_REQUIRED \
        MEMORY_LAYOUT_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$memory_detail_policy" \
        MEM_CHANNEL_MODE "$mem_channel_mode" "$exp_mem_channel_mode" \
        MEMORY_METADATA_REQUIRED MEMORY_LAYOUT_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$identity_detail_policy" MEM_RANK_LIST \
        "$mem_rank_list" "$exp_mem_rank_list" MEMORY_METADATA_REQUIRED \
        MEMORY_LAYOUT_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$identity_detail_policy" \
        MEM_MODULE_MFR_JEP106_LIST "$mem_module_jep106_list" \
        "$exp_mem_module_jep106_list" MEMORY_METADATA_REQUIRED \
        MEMORY_MODEL_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$identity_detail_policy" \
        MEM_DRAM_MFR_JEP106_LIST "$mem_dram_jep106_list" \
        "$exp_mem_dram_jep106_list" MEMORY_METADATA_REQUIRED \
        MEMORY_MODEL_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" MEM_SLOTS "$mem_slots" \
        "$exp_mem_slots" MEMORY_METADATA_REQUIRED MEMORY_LAYOUT_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" MEM_FORM_FACTOR "$mem_form" \
        "$exp_mem_form" MEMORY_METADATA_REQUIRED MEMORY_LAYOUT_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" MEM_BOARD_SLOTS \
        "$mem_board_slots" "$exp_mem_board_slots" MEMORY_METADATA_REQUIRED \
        MEMORY_LAYOUT_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" MEM_MAX_CAPACITY_GB \
        "$mem_max_gb" "$exp_mem_max_gb" MEMORY_METADATA_REQUIRED \
        MEMORY_LAYOUT_MISMATCH || return 1
    if [[ -z "$mem_total_mb" ]]; then
        if [[ "$policy" == strict ]]; then
            _g11_hw_legality_fail MEMORY_METADATA_REQUIRED \
                'MEM_TOTAL_MB is required by the strict hardware contract'
            return 1
        fi
        _g11_hw_legality_note_legacy MEM_TOTAL_MB
    elif ! [[ "$mem_total_mb" =~ ^[1-9][0-9]*$ ]] ||
            (( mem_total_mb != exp_mem_total_mb )); then
        _g11_hw_legality_fail MEMORY_CAPACITY_MISMATCH \
            "MEM_TOTAL_MB=$mem_total_mb is inconsistent with reviewed per-slot layout ${exp_mem_module_list} MiB"
        return 1
    fi

    found=0
    if [[ -n "$ssd_profile" ]]; then
        for row in "${SSD_PROFILES[@]}"; do
            IFS='|' read -r key _ exp_ssd_model exp_ssd_interface \
                exp_ssd_size exp_ssd_firmware exp_ssd_controller \
                exp_ssd_form exp_ssd_gen exp_ssd_lanes \
                exp_ssd_logical_sector exp_ssd_physical_sector <<<"$row"
            if [[ "$key" == "$ssd_profile" ]]; then
                found=1
                break
            fi
        done
        if (( ! found )); then
            if [[ "$policy" == legacy ]]; then
                # Historical generators shipped exact drive identities that
                # were later retired from the random pool.  Preserve those
                # immutable VMs only when the independently persisted bus,
                # controller and topology checks below are self-consistent.
                _g11_hw_legality_note_legacy SSD_PROFILE_UNCATALOGED
            else
                _g11_hw_legality_fail STORAGE_PROFILE_UNKNOWN \
                    "SSD_PROFILE=$ssd_profile is not in the reviewed G-11 catalog"
                return 1
            fi
        fi
    elif [[ "$policy" == strict ]]; then
        _g11_hw_legality_fail STORAGE_PROFILE_REQUIRED \
            'SSD_PROFILE is required by the strict hardware contract'
        return 1
    else
        _g11_hw_legality_note_legacy SSD_PROFILE
    fi

    # The drive profile is not just a controller choice.  Windows and common
    # inventory tools observe model, namespace/ATA capacity, firmware and both
    # sector sizes, so a current profile must carry the catalog's exact tuple.
    # A legacy, uncataloged profile keeps its historical strings, but its raw
    # numeric/sector metadata must still be internally safe when present.
    if (( found )); then
        _g11_hw_legality_exact_or_legacy "$policy" SSD_MODEL "$ssd_model" \
            "$exp_ssd_model" STORAGE_IDENTITY_REQUIRED \
            STORAGE_MODEL_MISMATCH || return 1
        _g11_hw_legality_exact_or_legacy "$policy" SSD_SIZE_BYTES "$ssd_size" \
            "$exp_ssd_size" STORAGE_IDENTITY_REQUIRED \
            STORAGE_CAPACITY_MISMATCH || return 1
        _g11_hw_legality_exact_or_legacy "$policy" SSD_FIRMWARE_REV \
            "$ssd_firmware" "$exp_ssd_firmware" STORAGE_IDENTITY_REQUIRED \
            STORAGE_FIRMWARE_MISMATCH || return 1
    else
        if [[ -z "$ssd_model" ]]; then
            _g11_hw_legality_note_legacy SSD_MODEL
        fi
        if [[ -z "$ssd_size" ]]; then
            _g11_hw_legality_note_legacy SSD_SIZE_BYTES
        elif ! [[ "$ssd_size" =~ ^[1-9][0-9]{0,17}$ ]]; then
            _g11_hw_legality_fail STORAGE_CAPACITY_INVALID \
                "SSD_SIZE_BYTES=$ssd_size must be a positive 64-bit-safe integer"
            return 1
        fi
        if [[ -z "$ssd_firmware" ]]; then
            _g11_hw_legality_note_legacy SSD_FIRMWARE_REV
        elif (( ${#ssd_firmware} > 8 )) || [[ "$ssd_firmware" == *'|'* ]]; then
            _g11_hw_legality_fail STORAGE_FIRMWARE_INVALID \
                'SSD_FIRMWARE_REV must be 1..8 characters without a field delimiter'
            return 1
        fi
    fi

    [[ -n "$ssd_logical_sector" ]] && sector_count=$((sector_count + 1))
    [[ -n "$ssd_physical_sector" ]] && sector_count=$((sector_count + 1))
    if (( sector_count == 0 )); then
        if [[ "$policy" == strict ]]; then
            _g11_hw_legality_fail STORAGE_IDENTITY_REQUIRED \
                'SSD_LOGICAL_BLOCK_SIZE/SSD_PHYSICAL_BLOCK_SIZE are required together'
            return 1
        fi
        _g11_hw_legality_note_legacy SSD_SECTOR_SIZES
    elif (( sector_count != 2 )); then
        _g11_hw_legality_fail STORAGE_SECTOR_METADATA_PARTIAL \
            'SSD_LOGICAL_BLOCK_SIZE/SSD_PHYSICAL_BLOCK_SIZE must be both set or both absent'
        return 1
    elif (( found )); then
        if [[ "$ssd_logical_sector" != "$exp_ssd_logical_sector" ||
              "$ssd_physical_sector" != "$exp_ssd_physical_sector" ]]; then
            _g11_hw_legality_fail STORAGE_SECTOR_SIZE_MISMATCH \
                "SSD sectors ${ssd_logical_sector}/${ssd_physical_sector} conflict with profile ${exp_ssd_logical_sector}/${exp_ssd_physical_sector}"
            return 1
        fi
    elif ! [[ "$ssd_logical_sector" =~ ^[1-9][0-9]*$ &&
              "$ssd_physical_sector" =~ ^[1-9][0-9]*$ ]] ||
            (( ssd_logical_sector < 512 ||
               ssd_physical_sector < ssd_logical_sector ||
               ssd_logical_sector > 2097152 ||
               ssd_physical_sector > 2097152 ||
               (ssd_logical_sector & (ssd_logical_sector - 1)) != 0 ||
               (ssd_physical_sector & (ssd_physical_sector - 1)) != 0 ||
               ssd_physical_sector % ssd_logical_sector != 0 )); then
        _g11_hw_legality_fail STORAGE_SECTOR_SIZE_INVALID \
            "SSD sector sizes are invalid: ${ssd_logical_sector}/${ssd_physical_sector}"
        return 1
    elif [[ -n "$ssd_size" ]] && (( ssd_size % ssd_physical_sector != 0 )); then
        _g11_hw_legality_fail STORAGE_CAPACITY_SECTOR_MISMATCH \
            "SSD_SIZE_BYTES=$ssd_size is not aligned to physical sector $ssd_physical_sector"
        return 1
    fi

    case "$ssd_interface" in
        sata|nvme) ;;
        '')
            if (( found )) && [[ "$policy" == legacy ]]; then
                _g11_hw_legality_note_legacy SSD_INTERFACE
                ssd_interface=$exp_ssd_interface
            else
                _g11_hw_legality_fail STORAGE_INTERFACE_REQUIRED \
                    'SSD_INTERFACE must be sata or nvme'
                return 1
            fi
            ;;
        *)
            _g11_hw_legality_fail STORAGE_INTERFACE_INVALID \
                "SSD_INTERFACE=$ssd_interface must be sata or nvme"
            return 1
            ;;
    esac
    if (( found )) && [[ "$ssd_interface" != "$exp_ssd_interface" ]]; then
        _g11_hw_legality_fail STORAGE_INTERFACE_MISMATCH \
            "SSD_INTERFACE=$ssd_interface conflicts with SSD_PROFILE=$ssd_profile"
        return 1
    fi
    if [[ -z "$ssd_controller" ]]; then
        if [[ "$policy" == strict ]]; then
            _g11_hw_legality_fail STORAGE_CONTROLLER_REQUIRED \
                'SSD_CONTROLLER_PROFILE is required by the strict hardware contract'
            return 1
        fi
        _g11_hw_legality_note_legacy SSD_CONTROLLER_PROFILE
        if (( found )); then
            ssd_controller=$exp_ssd_controller
        elif [[ "$ssd_interface" == sata ]]; then
            ssd_controller=ahci
        else
            ssd_controller=generic
        fi
    fi
    if (( found )) && [[ "$ssd_controller" != "$exp_ssd_controller" ]]; then
        _g11_hw_legality_fail STORAGE_CONTROLLER_MISMATCH \
            "SSD_CONTROLLER_PROFILE=$ssd_controller conflicts with SSD_PROFILE=$ssd_profile"
        return 1
    fi
    if [[ "$ssd_interface" == sata && "$ssd_controller" != ahci ]] ||
            [[ "$ssd_interface" == nvme && "$ssd_controller" == ahci ]]; then
        _g11_hw_legality_fail STORAGE_CONTROLLER_MISMATCH \
            "controller $ssd_controller cannot back a $ssd_interface drive"
        return 1
    fi
    if [[ "$ssd_interface" == sata && "$sector_count" == 2 &&
          "$ssd_logical_sector" != 512 ]]; then
        _g11_hw_legality_fail STORAGE_SECTOR_SIZE_INVALID \
            "SATA/AHCI requires a 512-byte logical sector, got $ssd_logical_sector"
        return 1
    fi

    [[ -n "$ssd_form" ]] && topology_count=$((topology_count + 1))
    [[ -n "$ssd_gen" ]] && topology_count=$((topology_count + 1))
    [[ -n "$ssd_lanes" ]] && topology_count=$((topology_count + 1))
    if (( topology_count == 0 )); then
        if [[ "$policy" == strict ]]; then
            _g11_hw_legality_fail STORAGE_TOPOLOGY_REQUIRED \
                'SSD_FORM_FACTOR/SSD_PCIE_GEN/SSD_PCIE_LANES are required together'
            return 1
        fi
        _g11_hw_legality_note_legacy SSD_TOPOLOGY
    elif (( topology_count != 3 )); then
        _g11_hw_legality_fail STORAGE_METADATA_PARTIAL \
            'SSD_FORM_FACTOR/SSD_PCIE_GEN/SSD_PCIE_LANES must be all set or all absent'
        return 1
    else
        if [[ "$ssd_interface" == sata ]]; then
            if [[ "$ssd_form" != 2.5-inch || "$ssd_gen" != 0 ||
                  "$ssd_lanes" != 0 ]]; then
                _g11_hw_legality_fail STORAGE_FORM_FACTOR_MISMATCH \
                    "SATA requires 2.5-inch/Gen0/x0, got $ssd_form/Gen${ssd_gen}/x${ssd_lanes}"
                return 1
            fi
        elif [[ "$ssd_form" != m.2-2280 ||
                ! "$ssd_gen" =~ ^[1-9][0-9]*$ ||
                ! "$ssd_lanes" =~ ^[1-9][0-9]*$ ]]; then
            _g11_hw_legality_fail STORAGE_PCIE_INVALID \
                "NVMe requires m.2-2280 and positive PCIe generation/lanes"
            return 1
        fi
        if (( found )); then
            if [[ "$ssd_form" != "$exp_ssd_form" ||
                  "$ssd_gen" != "$exp_ssd_gen" ||
                  "$ssd_lanes" != "$exp_ssd_lanes" ]]; then
                _g11_hw_legality_fail STORAGE_PROFILE_TOPOLOGY_MISMATCH \
                    "SSD topology conflicts with SSD_PROFILE=$ssd_profile"
                return 1
            fi
        fi
        if ! hardware_storage_combination_allowed "$platform" \
                "$ssd_interface" "$ssd_gen" "$ssd_lanes" "$ssd_form"; then
            _g11_hw_legality_fail STORAGE_TOPOLOGY_UNSUPPORTED \
                "$platform cannot provide the reviewed $ssd_form Gen${ssd_gen} x${ssd_lanes} path"
            return 1
        fi
    fi

    if [[ -z "$gpu_profile" ]]; then
        _g11_hw_legality_fail GPU_PROFILE_REQUIRED \
            'GPU_PROFILE is required for a G-11 vGPU combination'
        return 1
    fi
    found=0
    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        IFS='|' read -r key exp_gpu_mdev _name _vid _did _subvid _subdid \
            _rev exp_gpu_vram _vbios _core _boost _memory _bus _bandwidth \
            _ram_type _ram_maker _nvapi_type _nvapi_maker _cuda _subpipes \
            _rop _tmu _arch _impl _chiprev exp_gpu_width <<<"$row"
        if [[ "$key" == "$gpu_profile" ]]; then
            found=1
            break
        fi
    done
    if (( ! found )); then
        _g11_hw_legality_fail GPU_PROFILE_UNKNOWN \
            "GPU_PROFILE=$gpu_profile is not in the reviewed G-11 catalog"
        return 1
    fi
    case "$exp_gpu_vram:$exp_gpu_mdev" in
        1024:nvidia-256|2048:nvidia-257) ;;
        *)
            _g11_hw_legality_fail GPU_CATALOG_RESOURCE_MISMATCH \
                "GPU_PROFILE=$gpu_profile has an unsupported mdev/framebuffer pair: ${exp_gpu_mdev}/${exp_gpu_vram}MB"
            return 1
            ;;
    esac
    _g11_hw_legality_exact_or_legacy "$policy" VGPU_MDEV_PROFILE "$gpu_mdev" \
        "$exp_gpu_mdev" GPU_METADATA_REQUIRED GPU_MDEV_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" GPU_VRAM_MB "$gpu_vram" \
        "$exp_gpu_vram" GPU_METADATA_REQUIRED GPU_FRAMEBUFFER_MISMATCH || return 1
    _g11_hw_legality_exact_or_legacy "$policy" VGPU_FB_MB "$gpu_fb" \
        "$exp_gpu_vram" GPU_METADATA_REQUIRED GPU_FRAMEBUFFER_MISMATCH || return 1
    if [[ -n "$gpu_width" ]]; then
        case "$gpu_width" in
            1|2|4|8|16) ;;
            *)
                _g11_hw_legality_fail GPU_PCIE_WIDTH_INVALID \
                    "GPU_PCIE_WIDTH=$gpu_width must be 1, 2, 4, 8, or 16"
                return 1
                ;;
        esac
    fi
    _g11_hw_legality_exact_or_legacy "$policy" GPU_PCIE_WIDTH "$gpu_width" \
        "$exp_gpu_width" GPU_METADATA_REQUIRED \
        GPU_PCIE_WIDTH_MISMATCH || return 1
    if (( exp_gpu_width > 16 )); then
        _g11_hw_legality_fail GPU_PCIE_WIDTH_UNSUPPORTED \
            "GPU_PROFILE=$gpu_profile needs x$exp_gpu_width but the reviewed main slot is x16"
        return 1
    fi

    [[ -n "$resource_profile" ]] && resource_count=$((resource_count + 1))
    [[ -n "$resource_fb" ]] && resource_count=$((resource_count + 1))
    if (( resource_count == 1 )); then
        _g11_hw_legality_fail GPU_RESOURCE_METADATA_PARTIAL \
            'VGPU_RESOURCE_PROFILE and VGPU_RESOURCE_FB_MB must be supplied together'
        return 1
    elif (( resource_count == 2 )); then
        if ! [[ "$resource_profile" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
            _g11_hw_legality_fail GPU_RESOURCE_PROFILE_INVALID \
                "VGPU_RESOURCE_PROFILE contains unsupported characters"
            return 1
        fi
        if [[ "$resource_fb" != "$exp_gpu_vram" ]]; then
            _g11_hw_legality_fail GPU_RESOURCE_FRAMEBUFFER_MISMATCH \
                "host mdev framebuffer ${resource_fb}MB does not match guest ${exp_gpu_vram}MB"
            return 1
        fi
    fi

    if [[ -n "$tpm_effective_a" && -n "$tpm_effective_b" &&
          "$tpm_effective_a" != "$tpm_effective_b" ]]; then
        _g11_hw_legality_fail TPM_EFFECTIVE_VERSION_CONFLICT \
            "TPM_EFFECTIVE_VERSION=$tpm_effective_a conflicts with VM_TPM_VERSION=$tpm_effective_b"
        return 1
    fi
    tpm_effective=${tpm_effective_a:-$tpm_effective_b}
    if [[ -n "$tpm_frontend_a" && -n "$tpm_frontend_b" &&
          "$tpm_frontend_a" != "$tpm_frontend_b" ]]; then
        _g11_hw_legality_fail TPM_FRONTEND_CONFLICT \
            "TPM_FRONTEND=$tpm_frontend_a conflicts with VM_TPM_QEMU_DEVICE=$tpm_frontend_b"
        return 1
    fi
    tpm_frontend=${tpm_frontend_a:-$tpm_frontend_b}
    case "$tpm_switch" in
        ''|0|1) ;;
        *)
            _g11_hw_legality_fail TPM_ENABLE_INVALID \
                "TPM must be 0 or 1 (got: $tpm_switch)"
            return 1
            ;;
    esac

    if [[ -z "$tpm_effective" ]]; then
        if [[ "$policy" == strict ]]; then
            _g11_hw_legality_fail TPM_EFFECTIVE_VERSION_REQUIRED \
                'TPM_EFFECTIVE_VERSION (or VM_TPM_VERSION) is required in strict mode'
            return 1
        fi
        _g11_hw_legality_note_legacy TPM_EFFECTIVE_VERSION
        if [[ "$tpm_switch" == 0 ]]; then
            tpm_effective=none
        elif (( board_tpm_was_missing )); then
            # start-vm's pre-profile compatibility contract is TPM 2.0/CRB.
            tpm_effective=2.0
        else
            tpm_effective=$exp_board_tpm
        fi
    fi
    case "$tpm_effective" in
        none|1.2|2.0) ;;
        *)
            _g11_hw_legality_fail TPM_EFFECTIVE_VERSION_INVALID \
                "effective TPM version must be none, 1.2, or 2.0 (got: $tpm_effective)"
            return 1
            ;;
    esac
    if [[ "$tpm_switch" == 0 && "$tpm_effective" != none ]] ||
            [[ "$tpm_switch" == 1 && "$tpm_effective" == none ]]; then
        _g11_hw_legality_fail TPM_ENABLE_VERSION_MISMATCH \
            "TPM=$tpm_switch conflicts with effective version $tpm_effective"
        return 1
    fi
    if [[ "$tpm_effective" != none ]]; then
        if (( board_tpm_was_missing )); then
            expected_tpm=2.0
        else
            expected_tpm=$exp_board_tpm
        fi
        if [[ "$tpm_effective" != "$expected_tpm" ]]; then
            _g11_hw_legality_fail TPM_VERSION_MISMATCH \
                "effective TPM $tpm_effective conflicts with the board contract $expected_tpm"
            return 1
        fi
    fi
    expected_frontend=$(g11_hardware_expected_tpm_frontend "$tpm_effective") || {
        _g11_hw_legality_fail TPM_EFFECTIVE_VERSION_INVALID \
            "no QEMU frontend mapping exists for TPM $tpm_effective"
        return 1
    }
    if [[ -z "$tpm_frontend" ]]; then
        if [[ "$tpm_effective" == none ]]; then
            : # A disabled TPM has no QEMU device to plan.
        elif [[ "$policy" == legacy ]]; then
            _g11_hw_legality_note_legacy TPM_FRONTEND
        else
            _g11_hw_legality_fail TPM_FRONTEND_REQUIRED \
                "TPM $tpm_effective requires frontend $expected_frontend"
            return 1
        fi
    elif [[ "$tpm_frontend" != "$expected_frontend" ]]; then
        _g11_hw_legality_fail TPM_FRONTEND_MISMATCH \
            "TPM $tpm_effective requires $expected_frontend, got $tpm_frontend"
        return 1
    fi

    if [[ -n "$G11_HW_LEGALITY_LEGACY_FIELDS" ]]; then
        G11_HW_LEGALITY_CODE=OK_LEGACY
        G11_HW_LEGALITY_MESSAGE="legal legacy combination; inferred/skipped: $G11_HW_LEGALITY_LEGACY_FIELDS"
    else
        G11_HW_LEGALITY_CODE=OK
        G11_HW_LEGALITY_MESSAGE='legal audited G-11 hardware combination'
    fi
    return 0
}

g11_hardware_legality_print_result() {
    printf '%s: %s\n' "$G11_HW_LEGALITY_CODE" \
        "$G11_HW_LEGALITY_MESSAGE"
}

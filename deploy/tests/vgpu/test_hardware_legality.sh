#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=../../lib/hardware-legality.sh
source "$REPO_ROOT/deploy/lib/hardware-legality.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 label=$3
    [[ "$actual" == "$expected" ]] || \
        fail "$label: expected '$expected', got '$actual'"
}

assert_ok() {
    local policy=$1 expected_code=${2:-OK}
    g11_hardware_combination_validate "$policy" || \
        fail "expected $policy success, got $G11_HW_LEGALITY_CODE: $G11_HW_LEGALITY_MESSAGE"
    assert_eq "$expected_code" "$G11_HW_LEGALITY_CODE" \
        "$policy success code"
}

assert_rejected() {
    local policy=$1 expected_code=$2
    if g11_hardware_combination_validate "$policy"; then
        fail "expected $policy rejection $expected_code, got success"
    fi
    assert_eq "$expected_code" "$G11_HW_LEGALITY_CODE" \
        "$policy rejection code"
}

clear_runtime_fields() {
    unset PLATFORM_GENERATION TPM TPM_EFFECTIVE_VERSION VM_TPM_VERSION
    unset TPM_FRONTEND VM_TPM_QEMU_DEVICE
    unset VGPU_RESOURCE_PROFILE VGPU_RESOURCE_FB_MB
}

clear_component_contract() {
    unset HARDWARE_COMPONENT_CONTRACT_VERSION
    unset CPU_PROFILE BOARD_PROFILE MEMORY_PROFILE CPU_CORES
    unset CPU_THREADS_PER_CORE CPU_VCPUS CPU_BASE_MHZ CPU_MAX_MHZ
    unset CPU_L1_CACHE_KB CPU_L2_CACHE_KB CPU_L3_CACHE_KB
    unset CPU_L2_ASSOC CPU_L3_ASSOC MEM_RANK MEM_DEVICE_WIDTH
    unset MEM_VOLTAGE_MV
    unset MEM_MODEL_LIST MEM_MODULE_MB_LIST MEM_DEVICE_WIDTH_LIST
    unset MEM_CHANNEL_MODE MEM_RANK_LIST MEM_MODULE_MFR_JEP106_LIST
    unset MEM_DRAM_MFR_JEP106_LIST BOARD_RELEASE_YEAR BOARD_SERIAL_POLICY
}

load_valid() {
    local platform=${1:-i7-4820k-p9x79-micron-16g}
    local ssd=${2:-samsung-970-pro-512gb}
    local gpu=${3:-gtx1050_2gb}

    clear_runtime_fields
    hardware_profile_load "$platform"
    HARDWARE_COMPONENT_CONTRACT_VERSION=3
    BOARD_VERSION=$BOARD_REVISION
    ssd_profile_load "$ssd"
    vgpu_profile_load "$gpu"
    VGPU_FB_MB=$GPU_VRAM_MB
    VGPU_RESOURCE_PROFILE=$VGPU_MDEV_PROFILE
    VGPU_RESOURCE_FB_MB=$VGPU_FB_MB
    TPM_EFFECTIVE_VERSION=$BOARD_TPM_VERSION
    if [[ "$BOARD_TPM_VERSION" == none ]]; then
        TPM=0
    else
        TPM=1
    fi
    TPM_FRONTEND=$(g11_hardware_expected_tpm_frontend "$TPM_EFFECTIVE_VERSION")
}

# The normalized catalog is itself a contract.  New VMs use only the reviewed
# consumer X79 pool: two 4C/8T CPUs plus three 6C/12T CPUs, three real board
# brands and the 4/8/12/16 GiB capacity policy.  Historical H81/H97/
# B150/B360 rows remain loadable only as archived or legacy compatibility
# records; in particular, 6 GiB is not selectable for a new VM.
hardware_profile_validate_catalog || fail 'hardware catalog validation failed'
vgpu_profile_validate_catalog || fail 'vGPU catalog validation failed'
# The legality function defensively revalidates both immutable catalogs on
# every call.  This test validates them once above, then exercises many field
# mutations; stubbing only the repeated catalog scan keeps the 524-row matrix
# from turning the assertions into a quadratic-time test.
hardware_profile_validate_catalog() { return 0; }
vgpu_profile_validate_catalog() { return 0; }
assert_eq 13 "${#CPU_PROFILES[@]}" 'CPU catalog count'
assert_eq 16 "${#BOARD_PROFILES[@]}" 'board catalog count'
assert_eq 45 "${#MEMORY_PROFILES[@]}" 'memory catalog count'
assert_eq 524 "${#HARDWARE_COMBINATIONS[@]}" 'combination catalog count'
assert_eq 260 "${#HARDWARE_NEW_PROFILE_KEYS[@]}" 'default-new count'
assert_eq 0 "${#HARDWARE_EXPLICIT_NEW_PROFILE_KEYS[@]}" 'explicit-new count'
assert_eq 261 "${#HARDWARE_ARCHIVED_PROFILE_KEYS[@]}" 'archived count'
assert_eq 3 "${#HARDWARE_LEGACY_COMPAT_PROFILE_KEYS[@]}" 'legacy count'
assert_eq "${#HARDWARE_COMBINATIONS[@]}" \
    "${#_HARDWARE_COMBINATION_ROW_BY_KEY[@]}" 'combination index count'
for fixture_row in "${HARDWARE_COMBINATIONS[@]}"; do
    fixture_key=${fixture_row%%|*}
    assert_eq "$fixture_row" "${_HARDWARE_COMBINATION_ROW_BY_KEY[$fixture_key]}" \
        "$fixture_key indexed combination row"
done

assert_eq $'i7-3820\ni7-3930k\ni7-4820k\ni7-4930k\ni7-4960x' \
    "$(for cpu in $(cpu_profile_keys); do
        [[ -n "$(hardware_profile_component_candidates "$cpu" '' '')" ]] &&
            printf '%s\n' "$cpu"
    done)" 'five active consumer X79 CPU profiles'
assert_eq $'g3220\ni3-4130\ni5-4460\ni5-4570\ni5-4590\ni7-4790\ni5-6500\ni3-8100' \
    "$(for cpu in $(cpu_profile_keys); do
        [[ -z "$(hardware_profile_component_candidates "$cpu" '' '')" ]] &&
            printf '%s\n' "$cpu"
    done)" 'eight archived or legacy-only CPU profiles'

active_boards='|'
active_cpu_board_capacity_seen='|'
active_memory_brands='|'
count_4g=0
count_6g=0
count_8g=0
count_12g=0
count_16g=0
for fixture_row in "${HARDWARE_COMBINATIONS[@]}"; do
    IFS='|' read -r fixture_platform _fixture_cpu fixture_board \
        _fixture_memory fixture_lifecycle <<<"$fixture_row"
    [[ "$fixture_lifecycle" == new ||
       "$fixture_lifecycle" == explicit-new ]] || continue
    hardware_profile_load "$fixture_platform"
    assert_eq X79 "$BOARD_CHIPSET" "$fixture_platform active chipset"
    [[ "$MEM_BOARD_SLOTS" == 4 || "$MEM_BOARD_SLOTS" == 8 ]] || \
        fail "$fixture_platform does not expose a quad-channel-capable board"
    active_boards+="$fixture_board|"
    active_cpu_board_capacity_seen+="$_fixture_cpu:$fixture_board:$MEM_TOTAL_MB|"
    active_memory_brands+="$MEM_BRAND|"
    case "$MEM_TOTAL_MB" in
        4096)
            count_4g=$((count_4g + 1))
            assert_eq 2 "$MEM_SLOTS" "$fixture_platform populated DIMM count"
            assert_eq dual-channel "$MEM_CHANNEL_MODE" "$fixture_platform channel mode"
            ;;
        6144) count_6g=$((count_6g + 1)) ;;
        8192)
            count_8g=$((count_8g + 1))
            assert_eq 2 "$MEM_SLOTS" "$fixture_platform populated DIMM count"
            assert_eq dual-channel "$MEM_CHANNEL_MODE" "$fixture_platform channel mode"
            ;;
        12288)
            count_12g=$((count_12g + 1))
            assert_eq 3 "$MEM_SLOTS" "$fixture_platform populated DIMM count"
            assert_eq triple-channel "$MEM_CHANNEL_MODE" "$fixture_platform channel mode"
            assert_eq 4096,4096,4096 "$MEM_MODULE_MB_LIST" \
                "$fixture_platform 3x4 GiB module layout"
            ;;
        16384)
            count_16g=$((count_16g + 1))
            assert_eq 4 "$MEM_SLOTS" "$fixture_platform populated DIMM count"
            assert_eq quad-channel "$MEM_CHANNEL_MODE" "$fixture_platform channel mode"
            assert_eq 4096,4096,4096,4096 "$MEM_MODULE_MB_LIST" \
                "$fixture_platform 4x4 GiB module layout"
            ;;
        *) fail "$fixture_platform has unsupported active capacity $MEM_TOTAL_MB" ;;
    esac
done
assert_eq 62 "$count_4g" 'active 4 GiB combination count'
assert_eq 0 "$count_6g" 'active 6 GiB combination count'
assert_eq 66 "$count_8g" 'active 8 GiB combination count'
assert_eq 66 "$count_12g" 'active 12 GiB combination count'
assert_eq 66 "$count_16g" 'active 16 GiB combination count'
for fixture_board in asus-p9x79 gigabyte-x79-up4 asrock-x79-extreme4; do
    [[ "$active_boards" == *"|$fixture_board|"* ]] || \
        fail "active X79 board is missing: $fixture_board"
done
for fixture_brand in Kingston Samsung Elpida Micron 'SK hynix'; do
    [[ "$active_memory_brands" == *"|$fixture_brand|"* ]] || \
        fail "active memory brand is missing: $fixture_brand"
done
for fixture_cpu in i7-3820 i7-3930k i7-4820k i7-4930k i7-4960x; do
    for fixture_board in asus-p9x79 gigabyte-x79-up4 asrock-x79-extreme4; do
        for fixture_capacity in 4096 8192 12288 16384; do
            [[ "$active_cpu_board_capacity_seen" == \
               *"|$fixture_cpu:$fixture_board:$fixture_capacity|"* ]] ||
                fail "$fixture_cpu/$fixture_board lacks ${fixture_capacity} MiB"
        done
    done
done

# Every reviewed whole-machine combination must satisfy the v3 strict
# contract. SATA is valid on every board; dedicated checks below exercise the
# reviewed X79 passive-adapter NVMe path and reject Gen2 CPU-side links.
for fixture_row in "${HARDWARE_COMBINATIONS[@]}"; do
    IFS='|' read -r fixture_platform _ <<<"$fixture_row"
    load_valid "$fixture_platform" samsung-850-pro-512gb gtx1050_2gb
    assert_ok strict
done

# Every 1 GiB and 2 GiB atomic vGPU identity is independently legal on the
# same reviewed platform; a Cartesian repetition over every machine adds no
# new boundary.
for fixture_gpu in $(vgpu_profile_keys); do
    load_valid i7-4820k-p9x79-micron-16g samsung-970-pro-512gb "$fixture_gpu"
    assert_ok strict
done

# Component selection is a reviewed allowlist, never a Cartesian product.
assert_eq i7-3820-p9x79-kingston-4g \
    "$(hardware_profile_component_candidates i7-3820 asus-p9x79 kvr16n11s6-2x2)" \
    'reviewed default 4 GiB component combination'
assert_eq i7-4820k-p9x79-elpida-12g \
    "$(hardware_profile_component_candidates i7-4820k asus-p9x79 elpida-ebj40ug8bfw0-3x4)" \
    'reviewed high-frequency 12 GiB component combination'
assert_eq i7-4930k-p9x79-samsung-4g \
    "$(hardware_profile_component_candidates i7-4930k asus-p9x79 samsung-m378b5773dh0-1866-2x2)" \
    'reviewed Samsung DDR3-1866 minimum-capacity 6C/12T combination'
assert_eq i7-3930k-p9x79-samsung-8g \
    "$(hardware_profile_component_candidates i7-3930k asus-p9x79 samsung-m378b5273dh0-2x4)" \
    'reviewed Sandy Bridge-E 6C/12T DDR3-1600 combination'
assert_eq i7-4960x-p9x79-samsung-8g \
    "$(hardware_profile_component_candidates i7-4960x asus-p9x79 samsung-m378b5173qh0-1866-2x4)" \
    'reviewed Ivy Bridge-E 6C/12T DDR3-1866 combination'
assert_eq '' \
    "$(hardware_profile_component_candidates g3220 gigabyte-h97-d3h kvr16n11s8-2x4)" \
    'archived board excluded from new component selection'
assert_eq 4096 "$(hardware_memory_size_mb_normalize '4G')" \
    '4G memory capacity normalization'
assert_eq 8192 "$(hardware_memory_size_mb_normalize '8GiB')" \
    '8GiB memory capacity normalization'
assert_eq 12288 "$(hardware_memory_size_mb_normalize '12G')" \
    '12G memory capacity normalization'
assert_eq 16384 "$(hardware_memory_size_mb_normalize '16 GiB')" \
    '16G memory capacity normalization'
if hardware_memory_size_mb_normalize 6G >/dev/null 2>&1; then
    fail 'archived 6G memory capacity was normalized for a new VM'
fi

# Persisted component metadata is immutable.  A single mismatched key or
# topology field must fail before the older flat-platform checks can mask it.
load_valid g3220-h81m-k-4g samsung-850-pro-512gb
CPU_PROFILE=i3-4130
assert_rejected strict COMPONENT_CONTRACT_MISMATCH

load_valid g3220-h81m-k-4g samsung-850-pro-512gb
BOARD_PROFILE=asus-h81m-c
assert_rejected strict COMPONENT_CONTRACT_MISMATCH

load_valid g3220-h81m-k-4g samsung-850-pro-512gb
MEMORY_PROFILE=kvr13n9s8-2x4
assert_rejected strict COMPONENT_CONTRACT_MISMATCH

load_valid g3220-h81m-k-4g samsung-850-pro-512gb
CPU_CORES=4
assert_rejected strict COMPONENT_CONTRACT_MISMATCH

load_valid g3220-h81m-k-4g samsung-850-pro-512gb
unset HARDWARE_COMPONENT_CONTRACT_VERSION
assert_rejected strict COMPONENT_CONTRACT_MISMATCH

# Component contract v1 may omit the entire per-slot metadata group, but a
# partially persisted group is invalid under both strict and legacy policy.
load_valid g3220-h81m-k-4g samsung-850-pro-512gb
HARDWARE_COMPONENT_CONTRACT_VERSION=1
assert_ok strict

load_valid g3220-h81m-k-4g samsung-850-pro-512gb
HARDWARE_COMPONENT_CONTRACT_VERSION=1
unset MEM_MODEL_LIST MEM_MODULE_MB_LIST MEM_DEVICE_WIDTH_LIST MEM_CHANNEL_MODE
assert_ok strict OK_LEGACY
assert_ok legacy OK_LEGACY

for fixture_field in MEM_MODEL_LIST MEM_MODULE_MB_LIST \
        MEM_DEVICE_WIDTH_LIST MEM_CHANNEL_MODE; do
    load_valid g3220-h81m-k-4g samsung-850-pro-512gb
    HARDWARE_COMPONENT_CONTRACT_VERSION=1
    unset "$fixture_field"
    assert_rejected strict COMPONENT_CONTRACT_MISMATCH
    assert_rejected legacy COMPONENT_CONTRACT_MISMATCH
done

# Immutable component-v2 configs predate rank/JEP106/board-serial metadata.
# They remain bootable only when the complete newer group is absent; any
# conflicting value that is present still fails against the catalog.
load_valid g3220-h81m-k-4g samsung-850-pro-512gb
HARDWARE_COMPONENT_CONTRACT_VERSION=2
unset MEM_RANK_LIST MEM_MODULE_MFR_JEP106_LIST MEM_DRAM_MFR_JEP106_LIST
unset BOARD_RELEASE_YEAR BOARD_SERIAL_POLICY
assert_ok strict OK_LEGACY

# v3 persists every slot and its JEDEC identity. A Flex VM must not be flattened, reordered, or
# relabelled as fully dual-channel after creation.
load_valid g3220-h81m-c-6g samsung-850-pro-512gb
MEM_MODEL_LIST=KVR13N9S8/4,KVR13N9S8/4
assert_rejected strict COMPONENT_CONTRACT_MISMATCH

load_valid g3220-h81m-c-6g samsung-850-pro-512gb
MEM_MODULE_MB_LIST=2048,4096
assert_rejected strict COMPONENT_CONTRACT_MISMATCH

load_valid g3220-h81m-c-6g samsung-850-pro-512gb
MEM_DEVICE_WIDTH_LIST=8,8
assert_rejected strict COMPONENT_CONTRACT_MISMATCH

load_valid g3220-h81m-c-6g samsung-850-pro-512gb
MEM_CHANNEL_MODE=dual-channel
assert_rejected strict COMPONENT_CONTRACT_MISMATCH

load_valid i5-4570-h81m-c-hynix-6g samsung-850-pro-512gb
MEM_RANK_LIST=1,1
assert_rejected strict COMPONENT_CONTRACT_MISMATCH

load_valid i5-4460-h81m-c-micron-4g samsung-850-pro-512gb
MEM_MODULE_MFR_JEP106_LIST=0198,0198
assert_rejected strict COMPONENT_CONTRACT_MISMATCH

load_valid i3-4130-h81m-k-samsung-4g samsung-850-pro-512gb
MEM_DRAM_MFR_JEP106_LIST=0000,0000
assert_rejected strict COMPONENT_CONTRACT_MISMATCH

load_valid g3220-h81m-k-4g samsung-850-pro-512gb
BOARD_RELEASE_YEAR=2015
assert_rejected strict COMPONENT_CONTRACT_MISMATCH

load_valid g3220-h81m-k-4g samsung-850-pro-512gb
BOARD_SERIAL_POLICY=gigabyte
assert_rejected strict COMPONENT_CONTRACT_MISMATCH

for fixture_field in MEM_MODEL_LIST MEM_MODULE_MB_LIST \
        MEM_DEVICE_WIDTH_LIST MEM_CHANNEL_MODE MEM_RANK_LIST \
        MEM_MODULE_MFR_JEP106_LIST MEM_DRAM_MFR_JEP106_LIST; do
    load_valid g3220-h81m-c-6g samsung-850-pro-512gb
    unset "$fixture_field"
    assert_rejected strict COMPONENT_CONTRACT_MISMATCH
    assert_rejected legacy COMPONENT_CONTRACT_MISMATCH
done

load_valid
PLATFORM_GENERATION=3
assert_ok strict
PLATFORM_GENERATION=8
assert_rejected strict PLATFORM_GENERATION_MISMATCH

load_valid
BOARD_MODEL=GA-H97-D3H
assert_rejected strict PLATFORM_BOARD_MISMATCH

load_valid
TSC_FREQ=3100000000
assert_rejected strict PLATFORM_TSC_MISMATCH

load_valid
BIOS_VER=F20
assert_rejected strict BIOS_VERSION_MISMATCH

load_valid
BIOS_DATE=01/01/2017
assert_rejected strict BIOS_DATE_MISMATCH

load_valid
BOARD_VERSION=Rev-X
assert_rejected strict BOARD_VERSION_MISMATCH

load_valid
MEM_FAMILY=DDR4
assert_rejected strict MEMORY_FAMILY_MISMATCH

load_valid
MEM_SPEED=2400
assert_rejected strict MEMORY_SPEED_MISMATCH

load_valid
MEM_TOTAL_MB=4096
assert_rejected strict MEMORY_CAPACITY_MISMATCH

load_valid i7-4820k-p9x79-micron-16g samsung-970-pro-512gb
assert_ok strict

load_valid i7-3820-p9x79-kingston-16g samsung-970-pro-512gb
assert_rejected strict STORAGE_TOPOLOGY_UNSUPPORTED

load_valid i5-6500 samsung-970-pro-512gb
unset SSD_PCIE_LANES
assert_rejected strict STORAGE_METADATA_PARTIAL
assert_rejected legacy STORAGE_METADATA_PARTIAL

load_valid i5-6500 samsung-850-pro-512gb
SSD_FORM_FACTOR=m.2-2280
SSD_PCIE_GEN=3
SSD_PCIE_LANES=4
assert_rejected strict STORAGE_FORM_FACTOR_MISMATCH

load_valid
SSD_CONTROLLER_PROFILE=ahci
assert_rejected strict STORAGE_CONTROLLER_MISMATCH

load_valid
SSD_MODEL='Samsung SSD 980 PRO 512GB'
assert_rejected strict STORAGE_MODEL_MISMATCH

load_valid
SSD_SIZE_BYTES=512000000000
assert_rejected strict STORAGE_CAPACITY_MISMATCH

load_valid
SSD_FIRMWARE_REV=BADREV
assert_rejected strict STORAGE_FIRMWARE_MISMATCH

load_valid
SSD_PHYSICAL_BLOCK_SIZE=4096
assert_rejected strict STORAGE_SECTOR_SIZE_MISMATCH

load_valid
unset SSD_PHYSICAL_BLOCK_SIZE
assert_rejected strict STORAGE_SECTOR_METADATA_PARTIAL
assert_rejected legacy STORAGE_SECTOR_METADATA_PARTIAL

load_valid
VGPU_MDEV_PROFILE=V100-2Q
assert_rejected strict GPU_MDEV_MISMATCH

load_valid
VGPU_FB_MB=1024
assert_rejected strict GPU_FRAMEBUFFER_MISMATCH

load_valid
VGPU_RESOURCE_FB_MB=1024
assert_rejected strict GPU_RESOURCE_FRAMEBUFFER_MISMATCH

load_valid
GPU_PCIE_WIDTH=3
assert_rejected strict GPU_PCIE_WIDTH_INVALID

load_valid i5-6500 samsung-970-pro-512gb gt1030_2gb
GPU_PCIE_WIDTH=16
assert_rejected strict GPU_PCIE_WIDTH_MISMATCH

load_valid
TPM_FRONTEND=tpm-crb
assert_rejected strict TPM_FRONTEND_MISMATCH

load_valid
TPM_EFFECTIVE_VERSION=2.0
assert_rejected strict TPM_VERSION_MISMATCH

load_valid
TPM=0
TPM_EFFECTIVE_VERSION=none
TPM_FRONTEND=none
assert_ok strict

load_valid
unset TPM_EFFECTIVE_VERSION
assert_rejected strict TPM_EFFECTIVE_VERSION_REQUIRED

# Legacy policy permits entirely absent post-profile topology and derives old
# TPM/GPU facts.  It does not mutate the caller's immutable config variables.
load_valid i5-4590 samsung-970-pro-512gb
unset BOARD_NVME_PCIE_GEN BOARD_NVME_PCIE_LANES BOARD_TPM_VERSION
unset TSC_FREQ BIOS_VER BIOS_DATE BOARD_VERSION
unset SSD_FORM_FACTOR SSD_PCIE_GEN SSD_PCIE_LANES
unset SSD_MODEL SSD_SIZE_BYTES SSD_FIRMWARE_REV
unset SSD_LOGICAL_BLOCK_SIZE SSD_PHYSICAL_BLOCK_SIZE
unset VGPU_MDEV_PROFILE VGPU_FB_MB GPU_VRAM_MB GPU_PCIE_WIDTH
unset TPM_EFFECTIVE_VERSION TPM_FRONTEND
clear_component_contract
assert_ok legacy OK_LEGACY
[[ ! -v TSC_FREQ && ! -v BIOS_VER && ! -v BOARD_VERSION &&
   ! -v SSD_MODEL && ! -v SSD_LOGICAL_BLOCK_SIZE &&
   ! -v SSD_FORM_FACTOR && ! -v GPU_PCIE_WIDTH && ! -v BOARD_TPM_VERSION ]] || \
    fail 'legacy validation mutated caller hardware variables'
[[ "$G11_HW_LEGALITY_LEGACY_FIELDS" == *SSD_TOPOLOGY* ]] || \
    fail 'legacy result did not report skipped storage topology'
[[ "$G11_HW_LEGALITY_LEGACY_FIELDS" == *SSD_SECTOR_SIZES* ]] || \
    fail 'legacy result did not report inferred SSD sector sizes'
[[ "$G11_HW_LEGALITY_LEGACY_FIELDS" == *TPM_FRONTEND* ]] || \
    fail 'legacy result did not report inferred TPM frontend'

# A contradiction is never waived by the legacy policy.
load_valid i5-4590 samsung-850-pro-512gb
MEM_FAMILY=DDR4
assert_rejected legacy MEMORY_FAMILY_MISMATCH

load_valid i5-4590 samsung-850-pro-512gb
BIOS_VER=unreviewed
assert_rejected legacy BIOS_VERSION_MISMATCH

load_valid i5-4590 samsung-850-pro-512gb
SSD_FIRMWARE_REV=unreviewed
assert_rejected legacy STORAGE_FIRMWARE_MISMATCH

# Retired legacy drive identities remain bootable when their independently
# persisted protocol, controller, topology and raw sector tuple are coherent.
load_valid i5-4590 samsung-850-pro-512gb
SSD_PROFILE=retired-sata-512gb
SSD_MODEL='Legacy SATA SSD 512GB'
SSD_SIZE_BYTES=512000000000
SSD_FIRMWARE_REV=1.0
SSD_LOGICAL_BLOCK_SIZE=512
SSD_PHYSICAL_BLOCK_SIZE=512
assert_ok legacy OK_LEGACY

SSD_LOGICAL_BLOCK_SIZE=4096
SSD_PHYSICAL_BLOCK_SIZE=4096
assert_rejected legacy STORAGE_SECTOR_SIZE_INVALID

load_valid
GPU_PROFILE=unreviewed-gpu
assert_rejected strict GPU_PROFILE_UNKNOWN

load_valid
assert_rejected permissive INVALID_POLICY

assert_eq 4 "$(g11_hardware_platform_generation i5-4590)" \
    'Haswell platform generation'
assert_eq 4 "$(g11_hardware_platform_generation i5-4570-h81m-c-8g)" \
    'Core i5 Haswell H81 platform generation'
assert_eq 4 "$(g11_hardware_platform_generation g3220-h81m-k-4g)" \
    'Pentium Haswell platform generation'
assert_eq 4 "$(g11_hardware_platform_generation i3-4130-h81m-s1-6g)" \
    'Core i3 Haswell platform generation'
assert_eq 2 "$(g11_hardware_platform_generation i7-3820-p9x79-kingston-4g)" \
    'Sandy Bridge-E X79 platform generation'
assert_eq 3 "$(g11_hardware_platform_generation i7-4820k-p9x79-micron-16g)" \
    'Ivy Bridge-E X79 platform generation'
assert_eq tpm-tis "$(g11_hardware_expected_tpm_frontend 1.2)" \
    'TPM 1.2 frontend'
assert_eq tpm-crb "$(g11_hardware_expected_tpm_frontend 2.0)" \
    'TPM 2.0 frontend'

echo 'PASS: G-11 hardware combination legality and legacy policy'

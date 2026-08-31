#!/usr/bin/env bash
# Regression coverage for the guest-visible vGPU identity catalog and VM
# creation.  The test only creates files below a temporary VM_ROOT; it never
# probes or writes the host mdev sysfs hierarchy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROFILE_LIB="$REPO_ROOT/deploy/lib/vgpu-profiles.sh"
CREATE_VM="$REPO_ROOT/deploy/scripts/create-vm.sh"
FINISH_VGPU="$REPO_ROOT/deploy/finish-vgpu-install.sh"
PATCH_GRID="$REPO_ROOT/deploy/guest/patch-grid-strings.ps1"
APPLY_PROFILE="$REPO_ROOT/deploy/guest/apply-vm-profile.ps1"
SETUP_GUEST="$REPO_ROOT/deploy/setup-guest.sh"
INF_PATCH="$REPO_ROOT/deploy/guest/spoof-inf/inf-patch.ps1"
EVIDENCE_TSV="$REPO_ROOT/deploy/docs/G11-1GB-GPU-EVIDENCE.tsv"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [[ "$actual" == "$expected" ]] \
        || fail "$label: expected '$expected', got '$actual'"
}

[[ -r "$PROFILE_LIB" ]] || fail "missing profile catalog: $PROFILE_LIB"
[[ -x "$CREATE_VM" ]] || fail "create-vm.sh is not executable: $CREATE_VM"

# shellcheck source=../../../lib/vgpu-profiles.sh
source "$PROFILE_LIB"

assert_eq 'PCI\VEN_10DE&DEV_1E30&SUBSYS_132510DE' \
    "$(vgpu_profile_native_grid_pnp_id nvidia-256)" \
    'nvidia-256 native GRID PnP mapping'
assert_eq 'PCI\VEN_10DE&DEV_1E30&SUBSYS_132610DE' \
    "$(vgpu_profile_native_grid_pnp_id nvidia-257)" \
    'nvidia-257 native GRID PnP mapping'
assert_eq 'PCI\VEN_10DE&DEV_1DB1&SUBSYS_125A10DE' \
    "$(vgpu_profile_native_grid_pnp_id nvidia-256 V100X-1Q)" \
    'V100X-1Q R535 native GRID PnP mapping'
if vgpu_profile_native_grid_pnp_id nvidia-257 V100X-2Q >/dev/null 2>&1; then
    fail 'unverified V100X-2Q received an R535 native GRID PnP mapping'
fi
if vgpu_profile_native_grid_pnp_id nvidia-999 >/dev/null 2>&1; then
    fail 'unknown mdev profile received a native GRID PnP mapping'
fi

assert_eq 1024 "$(vgpu_profile_normalize_vram_mb '1024 MB')" \
    '1024 MB capacity normalization'
assert_eq 2048 "$(vgpu_profile_normalize_vram_mb '2048 MB')" \
    '2048 MB capacity normalization'
mapfile -t default_1gb_profiles < <(vgpu_profile_default_keys_for_vram 1024)
mapfile -t default_2gb_profiles < <(vgpu_profile_default_keys_for_vram 2048)
assert_eq 4 "${#default_1gb_profiles[@]}" 'R535-safe 1024 MB GPU pool size'
assert_eq 12 "${#default_2gb_profiles[@]}" 'default 2048 MB GPU pool size'
if vgpu_profile_normalize_vram_mb 4096 >/dev/null 2>&1; then
    fail 'unsupported GPU VRAM capacity was normalized'
fi
for requested_vram in 1024 2048; do
    vgpu_profile_pick_random_vram "$requested_vram"
    assert_eq "$requested_vram" "$GPU_VRAM_MB" \
        "$requested_vram MB constrained GPU random"
done

# Catalog validation must be side-effect free. Otherwise validating all rows
# immediately before launch can leak the last row's RAM maker into another VM.
vgpu_profile_load gtx750ti_asus_2gb
vgpu_profile_load_memory_maker_metadata \
    "$GPU_MEMORY_MAKER" "$GPU_MEMORY_MAKER_NVAPI"
maker_before=$GPU_MEMORY_MAKER_NVAPI_NAME
rm_vendor_before=$GPU_MEMORY_VENDOR_RM
vgpu_profile_validate_catalog
[[ "$GPU_MEMORY_MAKER_NVAPI_NAME" == "$maker_before" &&
   "$GPU_MEMORY_VENDOR_RM" == "$rm_vendor_before" ]] ||
    fail 'catalog validation leaked another profile RAM maker into runtime state'

declare -A SEEN_KEYS=()
declare -A SEEN_PCI_IDS=()

test_catalog() {
    local row fields key mdev_profile name vid did subvid subdid rev
    local vram_mb vbios core_mhz boost_mhz memory_mhz bus_bits
    local bandwidth_mbps ram_type ram_maker memory_type_nvapi
    local memory_maker_nvapi cuda_cores shader_subpipes rop_count tmu_count
    local architecture implementation chip_revision pcie_width
    local pci_id did_hex loaded registry_name expected_board_brand
    local expected_board_identity print_catalog rm_memory_vendor

    ((${#VGPU_PROFILE_CATALOG[@]} > 0)) || fail "vGPU profile catalog is empty"
    assert_eq FEEA5430609C81C495617607A3500F7A7BEA6CB6AFB4A5156F1918A1ACDCED7B \
        "$(vgpu_profile_catalog_sha256)" "canonical vGPU profile catalog SHA"
    assert_eq 25 "${#VGPU_PROFILE_CATALOG[@]}" \
        "multi-brand catalog profile count"
    assert_eq 12 "${#VGPU_DEFAULT_PROFILE_KEYS[@]}" \
        "single-tier default GPU count"
    assert_eq 4 "${#VGPU_TIER_1024_PROFILE_KEYS[@]}" \
        "R535-safe 1 GiB tier count"
    assert_eq 1 "${#VGPU_EXPLICIT_PROFILE_KEYS[@]}" \
        "manual expansion GPU count"
    assert_eq 8 "${#VGPU_LEGACY_PROFILE_KEYS[@]}" \
        "Kepler legacy-only GPU count"
    assert_eq "${#VGPU_PROFILE_CATALOG[@]}" \
        "${#VGPU_PROFILE_BOARD_METADATA[@]}" \
        "board metadata catalog coverage"
    grep -Fq "'all_2gb'" "$INF_PATCH" \
        || fail "guest INF patcher has no universal all_2gb profile"

    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        fields="$(awk -F'|' '{ print NF }' <<<"$row")"
        assert_eq 27 "$fields" "catalog field count"

        IFS='|' read -r \
            key mdev_profile name vid did subvid subdid rev vram_mb vbios \
            core_mhz boost_mhz memory_mhz bus_bits bandwidth_mbps ram_type \
            ram_maker memory_type_nvapi memory_maker_nvapi cuda_cores \
            shader_subpipes rop_count tmu_count architecture implementation \
            chip_revision pcie_width <<<"$row"

        [[ -n "$key" ]] || fail "catalog contains an empty profile key"
        [[ -z "${SEEN_KEYS[$key]+present}" ]] \
            || fail "duplicate vGPU profile key: $key"
        SEEN_KEYS[$key]=1

        pci_id="${vid,,}:${did,,}:${subvid,,}:${subdid,,}"
        [[ -z "${SEEN_PCI_IDS[$pci_id]+present}" ]] \
            || fail "duplicate vGPU PCI identity: $pci_id"
        SEEN_PCI_IDS[$pci_id]="$key"

        case "$vram_mb:$mdev_profile" in
            1024:nvidia-256|2048:nvidia-257) ;;
            *) fail "$key has an invalid VRAM/mdev resource pair" ;;
        esac
        assert_eq GDDR5 "$ram_type" "$key catalog memory type"
        assert_eq 8 "$memory_type_nvapi" "$key NVAPI memory type"
        case "$ram_maker|$memory_maker_nvapi" in
            'Samsung|1'|'Elpida|3'|'SK hynix|6'|'Micron|10') ;;
            *) fail "$key has a split/unknown memory-maker mapping" ;;
        esac
        rm_memory_vendor=$(vgpu_profile_rm_memory_vendor_value \
            "$ram_maker" "$memory_maker_nvapi") || \
            fail "$key has no RM memory-vendor mapping"
        vgpu_profile_validate_rm_fb_identity_values \
            "$bus_bits" "$memory_type_nvapi" "$rm_memory_vendor" || \
            fail "$key cannot form a safe RM FB descriptor tuple"
        case "$ram_maker|$rm_memory_vendor" in
            'Samsung|1'|'Elpida|3'|'SK hynix|6'|'Micron|15') ;;
            *) fail "$key maps to the wrong NVIDIA RM memory-vendor enum" ;;
        esac
        local raw_memory_khz=$((memory_mhz * 2000))
        local derived_bandwidth=$((raw_memory_khz * 2 * bus_bits / 8000))
        local bandwidth_difference=$((derived_bandwidth - bandwidth_mbps))
        (( bandwidth_difference >= 0 )) || \
            bandwidth_difference=$((-bandwidth_difference))
        (( bandwidth_difference * 100 <= bandwidth_mbps )) ||
            fail "$key memory clock/bus/bandwidth exceeds one-percent tolerance"

        expected_board_identity="subsystem=${subvid}:${subdid}"
        case "$subvid" in
            0x10DE)
                case "$key" in
                    gt1030_galax_2gb) expected_board_brand=GALAX ;;
                    *) expected_board_brand=NVIDIA ;;
                esac
                ;;
            0x1043) expected_board_brand=ASUS ;;
            0x1028) expected_board_brand=Dell ;;
            0x1462) expected_board_brand=MSI ;;
            0x1458) expected_board_brand=Gigabyte ;;
            0x19DA) expected_board_brand=ZOTAC ;;
            0x7377) expected_board_brand=Colorful ;;
            0x3842) expected_board_brand=EVGA ;;
            *) fail "$key has an unmapped board subvendor $subvid" ;;
        esac
        case "$key" in
            gtx750ti_2gb)
                assert_eq 1020 "$core_mhz" "$key core clock"
                assert_eq 1085 "$boost_mhz" "$key boost clock"
                assert_eq 1350 "$memory_mhz" "$key displayed memory clock"
                assert_eq 128 "$bus_bits" "$key memory bus"
                assert_eq 86400 "$bandwidth_mbps" "$key bandwidth"
                assert_eq 640 "$cuda_cores" "$key CUDA cores"
                assert_eq 5 "$shader_subpipes" "$key shader subpipes"
                assert_eq 16 "$rop_count" "$key ROP count"
                assert_eq 40 "$tmu_count" "$key TMU count"
                assert_eq 0x110 "$architecture" "$key architecture"
                assert_eq 7 "$implementation" "$key implementation"
                assert_eq 0x12 "$chip_revision" "$key chip revision"
                assert_eq 16 "$pcie_width" "$key PCIe width"
                ;;
            gt1030_2gb)
                assert_eq 1227 "$core_mhz" "$key core clock"
                assert_eq 1468 "$boost_mhz" "$key boost clock"
                assert_eq 1502 "$memory_mhz" "$key displayed memory clock"
                assert_eq 64 "$bus_bits" "$key memory bus"
                assert_eq 48100 "$bandwidth_mbps" "$key bandwidth"
                assert_eq 384 "$cuda_cores" "$key CUDA cores"
                assert_eq 3 "$shader_subpipes" "$key shader subpipes"
                assert_eq 16 "$rop_count" "$key ROP count"
                assert_eq 24 "$tmu_count" "$key TMU count"
                assert_eq 0x130 "$architecture" "$key architecture"
                assert_eq 8 "$implementation" "$key implementation"
                assert_eq 0x11 "$chip_revision" "$key chip revision"
                assert_eq 4 "$pcie_width" "$key PCIe width"
                ;;
            gtx1050_2gb)
                assert_eq 'Version 86.07.39.40.F4' "$vbios" \
                    "$key corrected Dell VBIOS"
                assert_eq 1354 "$core_mhz" "$key core clock"
                assert_eq 1455 "$boost_mhz" "$key boost clock"
                assert_eq 1752 "$memory_mhz" "$key displayed memory clock"
                assert_eq 128 "$bus_bits" "$key memory bus"
                assert_eq 112000 "$bandwidth_mbps" "$key bandwidth"
                assert_eq 640 "$cuda_cores" "$key CUDA cores"
                assert_eq 5 "$shader_subpipes" "$key shader subpipes"
                assert_eq 32 "$rop_count" "$key ROP count"
                assert_eq 40 "$tmu_count" "$key TMU count"
                assert_eq 0x130 "$architecture" "$key architecture"
                assert_eq 7 "$implementation" "$key implementation"
                assert_eq 0x11 "$chip_revision" "$key chip revision"
                assert_eq 16 "$pcie_width" "$key PCIe width"
                ;;
        esac
        case "$did" in
            0x0FC8)
                assert_eq 1024 "$vram_mb" "$key GT 740 VRAM"
                assert_eq 128 "$bus_bits" "$key GT 740 memory bus"
                assert_eq 384 "$cuda_cores" "$key GT 740 CUDA cores"
                assert_eq 16 "$rop_count" "$key GT 740 ROP count"
                ;;
            0x1287)
                assert_eq 1024 "$vram_mb" "$key GT 730 VRAM"
                assert_eq 64 "$bus_bits" "$key GT 730 memory bus"
                assert_eq 384 "$cuda_cores" "$key GT 730 CUDA cores"
                assert_eq 8 "$rop_count" "$key GT 730 ROP count"
                ;;
            0x1381)
                assert_eq 1024 "$vram_mb" "$key GTX 750 VRAM"
                assert_eq 128 "$bus_bits" "$key GTX 750 memory bus"
                assert_eq 512 "$cuda_cores" "$key GTX 750 CUDA cores"
                assert_eq 0x12 "$chip_revision" "$key GTX 750 chip revision"
                ;;
        esac

        did_hex="${did#0x}"
        grep -Fq "VEN_10DE&DEV_${did_hex^^}" "$PATCH_GRID" \
            || fail "$key PCI device is missing from patch-grid-strings.ps1"
        case "$key" in
            gtx750ti_2gb|gt1030_2gb|gtx1050_2gb)
                grep -Fq "'$key'" "$INF_PATCH" \
                    || fail "$key is missing from guest INF profile map"
                grep -Fq "Hex = '${did_hex^^}'" "$INF_PATCH" \
                    || fail "$key PCI device is missing from guest INF target map"
                ;;
        esac

        vgpu_profile_load "$key" || fail "cannot load catalog profile: $key"
        loaded="$GPU_PROFILE|$VGPU_MDEV_PROFILE|$GPU_NAME|$GPU_PCI_VID|$GPU_PCI_DID|$GPU_SUB_VID|$GPU_SUB_DID|$GPU_REV|$GPU_VRAM_MB|$GPU_VBIOS|$GPU_CORE_MHZ|$GPU_BOOST_MHZ|$GPU_MEMORY_MHZ|$GPU_MEMORY_BUS_BITS|$GPU_MEMORY_BANDWIDTH_MBPS|$GPU_MEMORY_TYPE|$GPU_MEMORY_MAKER|$GPU_MEMORY_TYPE_NVAPI|$GPU_MEMORY_MAKER_NVAPI|$GPU_CUDA_CORES|$GPU_SHADER_SUBPIPES|$GPU_ROP_COUNT|$GPU_TMU_COUNT|$GPU_ARCHITECTURE|$GPU_IMPLEMENTATION|$GPU_CHIP_REVISION|$GPU_PCIE_WIDTH"
        assert_eq "$row" "$loaded" "$key loaded profile"
        assert_eq "$expected_board_brand" "$GPU_BOARD_BRAND" \
            "$key loaded board brand"
        assert_eq "$expected_board_identity" "$GPU_BOARD_IDENTITY" \
            "$key loaded board identity"
        assert_eq not-exposed "$GPU_SERIAL_POLICY" \
            "$key loaded serial policy"
        assert_eq 'B:system-pci=host-mdev,catalog=protected-user-mode' \
            "$GPU_IDENTITY_SCOPE" "$key loaded identity scope"
    done

    print_catalog="$(vgpu_profile_print_catalog)"
    grep -Eq '^PROFILE[[:space:]]+NAME[[:space:]]+VRAM[[:space:]]+CLOCKS[[:space:]]+BOARD[[:space:]]+VRAM-MAKER[[:space:]]+SERIAL[[:space:]]+MDEV$' \
        <<<"$print_catalog" || fail "printed catalog omits BOARD/VRAM-MAKER/SERIAL columns"
    for expected_board_brand in NVIDIA ASUS Dell MSI Gigabyte ZOTAC GALAX Colorful EVGA; do
        grep -Eq "[[:space:]]${expected_board_brand}[[:space:]]+.*not-exposed[[:space:]]+nvidia-25[67]$" \
            <<<"$print_catalog" || \
            fail "printed catalog omits $expected_board_brand/not-exposed"
    done

    local tsv_catalog tsv_1gb_catalog tsv_mixed_catalog tsv_rows
    tsv_catalog=$(vgpu_profile_print_tsv_catalog) || \
        fail "machine-readable GPU catalog could not be generated"
    assert_eq $'PROFILE\tMODEL\tBOARD_BRAND\tBOARD_MODEL\tVRAM_MIB\tVRAM_MAKER\tMDEV\tAUTO_RANDOM' \
        "$(head -n1 <<<"$tsv_catalog")" \
        "machine-readable GPU catalog header"
    if ! awk -F '\t' 'NR > 1 && NF != 8 { exit 1 }' <<<"$tsv_catalog"; then
        fail "machine-readable GPU catalog has a non-eight-column row"
    fi
    tsv_rows=$(tail -n +2 <<<"$tsv_catalog" | wc -l)
    assert_eq "${#VGPU_PROFILE_CATALOG[@]}" "$tsv_rows" \
        "machine-readable GPU catalog row count"
    grep -Fqx $'gt1030_asus_2gb\tNVIDIA GeForce GT 1030\tASUS\tSilent\t2048\tSK hynix\tnvidia-257\t1' \
        <<<"$tsv_catalog" || fail "machine-readable GPU catalog lost model/brand fields"
    grep -Fqx $'gtx750ti_evga_sc_2gb\tNVIDIA GeForce GTX 750 Ti\tEVGA\t02G-P4-3753-KR\t2048\tSamsung\tnvidia-257\t0' \
        <<<"$tsv_catalog" || fail "manual EVGA expansion lost AUTO_RANDOM=0"
    assert_eq 12 \
        "$(awk -F '\t' 'NR > 1 && $8 == 1 { count++ } END { print count + 0 }' \
            <<<"$tsv_catalog")" \
        '2 GiB host catalog AUTO_RANDOM count'

    tsv_1gb_catalog=$(vgpu_profile_print_tsv_catalog 1024) || \
        fail "1 GiB machine-readable GPU catalog could not be generated"
    assert_eq 4 \
        "$(awk -F '\t' 'NR > 1 && $8 == 1 { count++ } END { print count + 0 }' \
            <<<"$tsv_1gb_catalog")" \
        '1 GiB host catalog AUTO_RANDOM count'
    grep -Fqx $'gtx750_asus_1gb\tNVIDIA GeForce GTX 750\tASUS\tGTX750-PHOC-1GD5\t1024\tSamsung\tnvidia-256\t1' \
        <<<"$tsv_1gb_catalog" || \
        fail '1 GiB host catalog did not publish Maxwell AUTO_RANDOM=1'
    if awk -F '\t' '
            NR > 1 && $8 == 1 && ($5 != 1024 || $1 ~ /^gt(730|740)/) {
                bad = 1
            }
            END { exit bad ? 0 : 1 }
        ' \
            <<<"$tsv_1gb_catalog"; then
        fail '1 GiB host catalog randomized another tier or Kepler identity'
    fi

    tsv_mixed_catalog=$(vgpu_profile_print_tsv_catalog mixed) || \
        fail "mixed-size machine-readable GPU catalog could not be generated"
    assert_eq 16 \
        "$(awk -F '\t' 'NR > 1 && $8 == 1 { count++ } END { print count + 0 }' \
            <<<"$tsv_mixed_catalog")" \
        'mixed-size host catalog AUTO_RANDOM count'
    grep -Fqx $'gtx750_asus_1gb\tNVIDIA GeForce GTX 750\tASUS\tGTX750-PHOC-1GD5\t1024\tSamsung\tnvidia-256\t1' \
        <<<"$tsv_mixed_catalog" || \
        fail 'mixed-size catalog omitted reviewed 1 GiB rows'
    grep -Fqx $'gt1030_asus_2gb\tNVIDIA GeForce GT 1030\tASUS\tSilent\t2048\tSK hynix\tnvidia-257\t1' \
        <<<"$tsv_mixed_catalog" || \
        fail 'mixed-size catalog omitted reviewed 2 GiB rows'

    [[ -r "$EVIDENCE_TSV" ]] || fail "1GB manufacturer evidence TSV is missing"
    assert_eq 13 "$(wc -l <"$EVIDENCE_TSV")" \
        "1GB evidence header plus twelve rows"
    awk -F '\t' '
        NR == 1 {
            if (NF != 12 || $1 != "profile" ||
                    $8 != "g11_subsystem_projection" ||
                    $9 != "g11_vbios_projection" ||
                    $12 != "physical_unit_serial_policy") exit 1
            next
        }
        NF != 12 || $6 !~ /^https:\/\// || $10 != 1024 ||
                $12 !~ /^not-exposed/ { exit 1 }
    ' "$EVIDENCE_TSV" || fail "1GB manufacturer evidence TSV is malformed"
    while IFS='|' read -r evidence_key evidence_vram; do
        [[ "$evidence_vram" == 1024 ]] || continue
        assert_eq 1 "$(awk -F '\t' -v key="$evidence_key" \
            'NR > 1 && $1 == key { count++ } END { print count + 0 }' \
            "$EVIDENCE_TSV")" "$evidence_key evidence row coverage"
    done < <(printf '%s\n' "${VGPU_PROFILE_CATALOG[@]}" |
        awk -F '|' '{print $1 "|" $9}')

    # Catalog validation itself must fail closed on a plausible-looking row
    # whose displayed clock and bandwidth cannot describe the same GDDR5 bus.
    local original_catalog=("${VGPU_PROFILE_CATALOG[@]}")
    VGPU_PROFILE_CATALOG=(
        "${original_catalog[0]%|86400|GDDR5|Samsung|8|1|640|5|16|40|0x110|7|0x12|16}|64000|GDDR5|Samsung|8|1|640|5|16|40|0x110|7|0x12|16"
    )
    if vgpu_profile_validate_catalog >/dev/null 2>&1; then
        fail "catalog validator accepted an incoherent memory bandwidth"
    fi
    VGPU_PROFILE_CATALOG=(
        "${original_catalog[0]/|1020|1085|/|1086|1085|}"
    )
    if vgpu_profile_validate_catalog >/dev/null 2>&1; then
        fail "catalog validator accepted boost below core"
    fi
    VGPU_PROFILE_CATALOG=(
        "${original_catalog[0]%|16}|3"
    )
    if vgpu_profile_validate_catalog >/dev/null 2>&1; then
        fail "catalog validator accepted a non-lane PCIe width"
    fi
    VGPU_PROFILE_CATALOG=(
        "${original_catalog[0]/|640|5|16|40|/|640|5|16|41|}"
    )
    if vgpu_profile_validate_catalog >/dev/null 2>&1; then
        fail "catalog validator accepted an incoherent TMU count"
    fi
    VGPU_PROFILE_CATALOG=("${original_catalog[@]}")
    vgpu_profile_validate_catalog ||
        fail "catalog validator did not recover after the negative case"

    # Companion metadata must cover every profile, match the existing
    # subsystem identity and never claim a guest-visible board serial.  It is
    # included in the portable digest, so any companion change invalidates
    # every generated/compiled consumer.
    local original_board_metadata=("${VGPU_PROFILE_BOARD_METADATA[@]}")
    VGPU_PROFILE_BOARD_METADATA=(
        "${original_board_metadata[0]/|not-exposed|/|synthetic|}"
        "${original_board_metadata[@]:1}"
    )
    if vgpu_profile_validate_catalog >/dev/null 2>&1; then
        fail "catalog validator accepted an exposed/synthetic GPU serial policy"
    fi
    [[ "$(vgpu_profile_catalog_sha256)" != \
       FEEA5430609C81C495617607A3500F7A7BEA6CB6AFB4A5156F1918A1ACDCED7B ]] \
        || fail "companion metadata change did not alter the catalog SHA"
    VGPU_PROFILE_BOARD_METADATA=(
        "${original_board_metadata[0]/|NVIDIA|/|ASUS|}"
        "${original_board_metadata[@]:1}"
    )
    if vgpu_profile_validate_catalog >/dev/null 2>&1; then
        fail "catalog validator accepted a board/subvendor brand mismatch"
    fi
    VGPU_PROFILE_BOARD_METADATA=("${original_board_metadata[@]:1}")
    if vgpu_profile_validate_catalog >/dev/null 2>&1; then
        fail "catalog validator accepted missing board metadata"
    fi
    VGPU_PROFILE_BOARD_METADATA=("${original_board_metadata[@]}")
    vgpu_profile_validate_catalog ||
        fail "board metadata validator did not recover after negative cases"

    for registry_name in \
            IdentityMemoryClockNVAPIKHz \
            IdentityPciVendorId IdentityPciDeviceId \
            IdentityPciSubVendorId IdentityPciSubDeviceId \
            IdentityPciRevisionId \
            IdentityMemoryType IdentityMemoryMaker IdentityCudaCores \
            IdentityShaderSubPipes IdentityRopCount IdentityTmuCount IdentityArchitecture \
            IdentityImplementation IdentityChipRevision IdentityPcieWidth \
            IdentityVbiosVersion; do
        grep -Fq "$registry_name" "$PATCH_GRID" \
            || fail "registry writer lacks $registry_name"
        grep -Fq "$registry_name" "$APPLY_PROFILE" \
            || fail "staged verifier lacks $registry_name"
    done
    for patch_parameter in \
            MemoryType MemoryMaker CudaCores ShaderSubPipes RopCount TmuCount \
            NvapiPciVendorId NvapiPciDeviceId NvapiPciSubVendorId \
            NvapiPciSubDeviceId NvapiPciRevisionId \
            Architecture Implementation ChipRevision PcieWidth \
            VbiosVersion; do
        [[ $(grep -Fc -- "-$patch_parameter" "$SETUP_GUEST") -ge 2 ]] \
            || fail "legacy sync does not persist $patch_parameter in both its immediate and startup writes"
    done
    grep -Fq 'NVAPI identity registry write verified' "$PATCH_GRID" \
        && fail "registry writer still reports the removed pre-contract message"
    grep -Fq 'NVAPI identity registry contract committed' "$PATCH_GRID" \
        || fail "common legacy/staged writer does not commit a complete contract"
    grep -Fq 'IdentityProfileKey' "$PATCH_GRID" \
        || fail "registry writer omits the catalog profile key"
    grep -Fq 'IdentityContractVersion' "$PATCH_GRID" \
        || fail "registry writer omits the fail-closed completion marker"
    grep -Fq '$memoryRawClockKHz = [int64]$MemoryClockMHz * 2000' \
        "$PATCH_GRID" || fail "registry writer lacks the audited GDDR5 raw clock"
    grep -Fq '$expectedMemoryRawKHz = [int64]$Gpu.MemoryClockMHz * 2000' \
        "$APPLY_PROFILE" || fail "staged verifier lacks the audited GDDR5 raw clock"
    grep -Fq 'patch-grid-strings.ps1 failed with exit code $LASTEXITCODE' \
        "$SETUP_GUEST" || fail "legacy identity sync ignores the registry writer exit code"
    grep -Fq 'install-nvapi-shim.ps1 failed with exit code $LASTEXITCODE' \
        "$SETUP_GUEST" || fail "legacy identity sync ignores the shim installer exit code"
    grep -Fq 'out, streams, had_errors = c.execute_ps(ps)' \
        "$SETUP_GUEST" || fail "legacy identity sync discards the WinRM error flag"
    grep -Fq 'if had_errors or errors:' \
        "$SETUP_GUEST" || fail "legacy identity sync does not fail on WinRM errors"
    for strict_line in \
            'GPU_VBIOS="Version 86.07.39.40.F4"' \
            'GPU_MEMORY_TYPE_NVAPI=8' 'GPU_MEMORY_MAKER_NVAPI=1' \
            'GPU_CUDA_CORES=640' 'GPU_SHADER_SUBPIPES=5' \
            'GPU_ROP_COUNT=32' 'GPU_TMU_COUNT=40' 'GPU_ARCHITECTURE=0x130' \
            'GPU_IMPLEMENTATION=7' 'GPU_CHIP_REVISION=0x11' \
            'GPU_PCIE_WIDTH=16'; do
        grep -Fq "$strict_line" "$FINISH_VGPU" \
            || fail "strict GTX 1050 finish persistence lacks $strict_line"
    done
}

test_random_picker() {
    local actual_index forced_index expected_key

    actual_index=$(_vgpu_profile_random_index \
        "${#VGPU_DEFAULT_PROFILE_KEYS[@]}") ||
        fail "real random GPU index selection failed"
    [[ "$actual_index" =~ ^[0-9]+$ ]] ||
        fail "random GPU selector returned a non-numeric index"
    ((actual_index < ${#VGPU_DEFAULT_PROFILE_KEYS[@]})) ||
        fail "random GPU selector escaped the default catalog"

    # Override only inside this subshell so every possible index is exercised
    # deterministically without making the regression probabilistic.
    (
        FORCED_VGPU_INDEX=0
        _vgpu_profile_random_index() {
            printf '%s\n' "$FORCED_VGPU_INDEX"
        }
        for ((forced_index = 0;
             forced_index < ${#VGPU_DEFAULT_PROFILE_KEYS[@]};
             forced_index += 1)); do
            FORCED_VGPU_INDEX=$forced_index
            expected_key=${VGPU_DEFAULT_PROFILE_KEYS[$forced_index]}
            vgpu_profile_pick_random ||
                fail "random GPU picker could not load index $forced_index"
            assert_eq "$expected_key" "$GPU_PROFILE" \
                "random GPU index $forced_index"
        done
        [[ "$GPU_PROFILE" != gtx750ti_evga_sc_2gb ]] ||
            fail 'manual EVGA profile entered default random selection'
    )
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
IMAGE_ROOT="$TMP_DIR"
VM_ROOT="$TMP_DIR/vms"
export IMAGE_ROOT VM_ROOT
HOST_1GB_CONFIG="$TMP_DIR/vgpu-host-1gb.conf"
HOST_2GB_CONFIG="$TMP_DIR/vgpu-host-2gb.conf"
printf '%s\n' 'VGPU_HOST_FB_TIER_MB=1024' >"$HOST_1GB_CONFIG"
printf '%s\n' 'VGPU_HOST_FB_TIER_MB=2048' >"$HOST_2GB_CONFIG"
export VGPU_HOST_CONFIG="$HOST_2GB_CONFIG"

VGPU_HOST_CONFIG="$HOST_1GB_CONFIG" "$CREATE_VM" \
    --list-gpu-profiles-tsv >"$TMP_DIR/gpu-catalog-1gb.tsv" \
    2>"$TMP_DIR/gpu-catalog-1gb.err"
assert_eq 4 \
    "$(awk -F '\t' 'NR > 1 && $8 == 1 { count++ } END { print count + 0 }' \
        "$TMP_DIR/gpu-catalog-1gb.tsv")" \
    'create-vm management TSV follows the configured 1 GiB host tier'

# Host tier input is a scheduler boundary.  Existing unsafe files and source
# errors must never be swallowed into inferred/default 2 GiB behavior.
ln -s "$HOST_1GB_CONFIG" "$TMP_DIR/vgpu-host-link.conf"
if VGPU_HOST_CONFIG="$TMP_DIR/vgpu-host-link.conf" "$CREATE_VM" \
        --list-gpu-profiles-tsv >"$TMP_DIR/host-link.out" \
        2>"$TMP_DIR/host-link.err"; then
    fail 'create-vm followed a symlinked host vGPU config'
fi
grep -Fq '可读普通非符号链接文件' "$TMP_DIR/host-link.err" || \
    fail 'create-vm host config symlink refusal was not clear'

mkdir "$TMP_DIR/vgpu-host-directory.conf"
if VGPU_HOST_CONFIG="$TMP_DIR/vgpu-host-directory.conf" "$CREATE_VM" \
        --list-gpu-profiles-tsv >"$TMP_DIR/host-directory.out" \
        2>"$TMP_DIR/host-directory.err"; then
    fail 'create-vm sourced a directory as host vGPU config'
fi
grep -Fq '可读普通非符号链接文件' "$TMP_DIR/host-directory.err" || \
    fail 'create-vm host config directory refusal was not clear'

printf '%s\n' 'VGPU_HOST_FB_TIER_MB=(' >"$TMP_DIR/vgpu-host-bad-syntax.conf"
if VGPU_HOST_CONFIG="$TMP_DIR/vgpu-host-bad-syntax.conf" "$CREATE_VM" \
        --list-gpu-profiles-tsv >"$TMP_DIR/host-syntax.out" \
        2>"$TMP_DIR/host-syntax.err"; then
    fail 'create-vm swallowed a host vGPU config syntax error'
fi
if ! grep -Fq 'VGPU_HOST_CONFIG 加载失败' "$TMP_DIR/host-syntax.err" &&
        ! grep -Eq 'syntax error|unexpected EOF' "$TMP_DIR/host-syntax.err"; then
    fail 'create-vm host config syntax refusal was not clear'
fi

printf '%s\n' 'VGPU_HOST_FB_TIER_MB=1024' \
    >"$TMP_DIR/vgpu-host-unreadable.conf"
chmod 000 "$TMP_DIR/vgpu-host-unreadable.conf"
if VGPU_HOST_CONFIG="$TMP_DIR/vgpu-host-unreadable.conf" "$CREATE_VM" \
        --list-gpu-profiles-tsv >"$TMP_DIR/host-unreadable.out" \
        2>"$TMP_DIR/host-unreadable.err"; then
    chmod 600 "$TMP_DIR/vgpu-host-unreadable.conf"
    fail 'create-vm accepted an unreadable host vGPU config'
fi
chmod 600 "$TMP_DIR/vgpu-host-unreadable.conf"
grep -Fq '可读普通非符号链接文件' "$TMP_DIR/host-unreadable.err" || \
    fail 'create-vm unreadable host config refusal was not clear'

if VGPU_HOST_CONFIG="$TMP_DIR/missing-vgpu-host.conf" "$CREATE_VM" \
        --list-gpu-profiles-tsv >"$TMP_DIR/host-missing.out" \
        2>"$TMP_DIR/host-missing.err"; then
    fail 'create-vm accepted a missing explicit host vGPU config'
fi
grep -Fq 'VGPU_HOST_CONFIG 不存在' "$TMP_DIR/host-missing.err" || \
    fail 'create-vm missing explicit host config refusal was not clear'

test_create_profile() {
    local key="$1" vm_id="$2" order="$3" conf
    local expected_name expected_vid expected_did expected_subvid expected_subdid
    local expected_mdev expected_vram
    local expected_core expected_boost expected_memory
    local expected_vbios expected_memory_maker expected_memory_type_nvapi
    local expected_memory_maker_nvapi
    local expected_cuda expected_subpipes expected_rops expected_tmus expected_architecture
    local expected_implementation expected_chip_revision expected_pcie_width

    vgpu_profile_load "$key" || fail "required test profile is absent: $key"
    expected_name="$GPU_NAME"
    expected_vid="$GPU_PCI_VID"
    expected_did="$GPU_PCI_DID"
    expected_subvid="$GPU_SUB_VID"
    expected_subdid="$GPU_SUB_DID"
    expected_mdev="$VGPU_MDEV_PROFILE"
    expected_vram="$GPU_VRAM_MB"
    expected_core="$GPU_CORE_MHZ"
    expected_boost="$GPU_BOOST_MHZ"
    expected_memory="$GPU_MEMORY_MHZ"
    expected_vbios="$GPU_VBIOS"
    expected_memory_maker="$GPU_MEMORY_MAKER"
    expected_memory_type_nvapi="$GPU_MEMORY_TYPE_NVAPI"
    expected_memory_maker_nvapi="$GPU_MEMORY_MAKER_NVAPI"
    expected_cuda="$GPU_CUDA_CORES"
    expected_subpipes="$GPU_SHADER_SUBPIPES"
    expected_rops="$GPU_ROP_COUNT"
    expected_tmus="$GPU_TMU_COUNT"
    expected_architecture="$GPU_ARCHITECTURE"
    expected_implementation="$GPU_IMPLEMENTATION"
    expected_chip_revision="$GPU_CHIP_REVISION"
    expected_pcie_width="$GPU_PCIE_WIDTH"
    local -a create_env=()
    if [[ "$expected_vram" == 1024 ]]; then
        create_env=(env "VGPU_HOST_CONFIG=$HOST_1GB_CONFIG")
    fi
    if [[ "$order" == "option-first" ]]; then
        "${create_env[@]}" "$CREATE_VM" --gpu-profile "$key" "$vm_id" \
            >"$TMP_DIR/create-$vm_id.out" 2>"$TMP_DIR/create-$vm_id.err"
    else
        "${create_env[@]}" "$CREATE_VM" "$vm_id" --gpu-profile "$key" \
            >"$TMP_DIR/create-$vm_id.out" 2>"$TMP_DIR/create-$vm_id.err"
    fi

    conf="$VM_ROOT/${vm_id}/vm.conf"
    [[ -f "$conf" ]] || fail "$key did not create $conf"

    (
        unset GPU_PROFILE SPOOF_MODE VGPU_IDENTITY_TARGET
        unset VGPU_MDEV_INTERNAL_PCI_IDENTITY VGPU_MDEV_FRL_ENABLED
        unset VGPU_PATCHED_DRIVER_REQUIRED_VERSION
        unset VGPU_PATCHED_DRIVER_VERSION VGPU_PATCHED_DRIVER_INF
        unset VGPU_MDEV_PROFILE VGPU_FB_MB GPU_NAME GPU_VRAM_MB
        unset GPU_PCI_VID GPU_PCI_DID GPU_SUB_VID GPU_SUB_DID
        unset GPU_CORE_MHZ GPU_BOOST_MHZ GPU_MEMORY_MHZ
        unset GPU_VBIOS GPU_MEMORY_MAKER GPU_MEMORY_TYPE_NVAPI
        unset GPU_MEMORY_MAKER_NVAPI
        unset GPU_CUDA_CORES GPU_SHADER_SUBPIPES GPU_ROP_COUNT GPU_TMU_COUNT
        unset GPU_ARCHITECTURE GPU_IMPLEMENTATION GPU_CHIP_REVISION
        unset GPU_PCIE_WIDTH
        # shellcheck disable=SC1090
        source "$conf"

        assert_eq "$key" "${GPU_PROFILE-}" "$key conf profile key"
        assert_eq B "${SPOOF_MODE-}" "$key safe default spoof mode"
        assert_eq name-only "${VGPU_IDENTITY_TARGET-}" \
            "$key identity target"
        [[ ! -v VGPU_PATCHED_DRIVER_REQUIRED_VERSION ]] || \
            fail "$key unexpectedly requires a patched full-consumer driver"
        [[ ! -v VGPU_MDEV_INTERNAL_PCI_IDENTITY ]] || \
            fail "$key new config enabled internal PCI identity"
        [[ ! -v VGPU_MDEV_FRL_ENABLED ]] || \
            fail "$key new config pinned a per-mdev FRL policy"
        [[ ! -v VGPU_PATCHED_DRIVER_VERSION ]] || \
            fail "$key new config invented an installed patched-driver version"
        [[ ! -v VGPU_PATCHED_DRIVER_INF ]] || \
            fail "$key new config hard-coded an installed OEM INF"
        assert_eq "$expected_mdev" "${VGPU_MDEV_PROFILE-}" "$key conf mdev profile"
        assert_eq "$expected_vram" "${VGPU_FB_MB-}" "$key conf allocated framebuffer"
        assert_eq "$expected_vram" "${GPU_VRAM_MB-}" "$key conf advertised VRAM"
        assert_eq "$expected_name" "${GPU_NAME-}" "$key conf GPU name"
        assert_eq "$expected_vid" "${GPU_PCI_VID-}" "$key conf PCI vendor"
        assert_eq "$expected_did" "${GPU_PCI_DID-}" "$key conf PCI device"
        assert_eq "$expected_subvid" "${GPU_SUB_VID-}" "$key conf subsystem vendor"
        assert_eq "$expected_subdid" "${GPU_SUB_DID-}" "$key conf subsystem device"
        assert_eq "$expected_core" "${GPU_CORE_MHZ-}" "$key conf core clock"
        assert_eq "$expected_boost" "${GPU_BOOST_MHZ-}" "$key conf boost clock"
        assert_eq "$expected_memory" "${GPU_MEMORY_MHZ-}" "$key conf memory clock"
        assert_eq "$expected_vbios" "${GPU_VBIOS-}" "$key conf VBIOS"
        assert_eq "$expected_memory_maker" "${GPU_MEMORY_MAKER-}" \
            "$key conf memory maker"
        assert_eq "$expected_memory_type_nvapi" "${GPU_MEMORY_TYPE_NVAPI-}" \
            "$key conf NVAPI memory type"
        assert_eq "$expected_memory_maker_nvapi" "${GPU_MEMORY_MAKER_NVAPI-}" \
            "$key conf NVAPI memory maker"
        assert_eq "$expected_cuda" "${GPU_CUDA_CORES-}" "$key conf CUDA cores"
        assert_eq "$expected_subpipes" "${GPU_SHADER_SUBPIPES-}" \
            "$key conf shader subpipes"
        assert_eq "$expected_rops" "${GPU_ROP_COUNT-}" "$key conf ROP count"
        assert_eq "$expected_tmus" "${GPU_TMU_COUNT-}" "$key conf TMU count"
        assert_eq "$expected_architecture" "${GPU_ARCHITECTURE-}" \
            "$key conf architecture"
        assert_eq "$expected_implementation" "${GPU_IMPLEMENTATION-}" \
            "$key conf implementation"
        assert_eq "$expected_chip_revision" "${GPU_CHIP_REVISION-}" \
            "$key conf chip revision"
        assert_eq "$expected_pcie_width" "${GPU_PCIE_WIDTH-}" \
            "$key conf PCIe width"
    )
}

test_force_gpu_policy() {
    local vm_id=102 conf="$VM_ROOT/102/vm.conf"
    local before_hash after_hash backup="$TMP_DIR/vm102-valid.conf"

    chmod 0644 "$conf"
    {
        # Later assignments intentionally model a completed VM that advanced
        # beyond the new-VM B baseline.
        printf '%s\n' \
            'SPOOF_MODE=A' \
            'VGPU_IDENTITY_TARGET=full-consumer' \
            'VGPU_MDEV_INTERNAL_PCI_IDENTITY=1' \
            'VGPU_MDEV_FRL_ENABLED=0' \
            'VGPU_PATCHED_DRIVER_REQUIRED_VERSION=31.0.15.3833' \
            'VGPU_PATCHED_DRIVER_VERSION=31.0.15.3833' \
            'VGPU_PATCHED_DRIVER_INF=oem42.inf'
    } >>"$conf"
    chmod 0444 "$conf"

    # An inherited environment selector is not an explicit migration request.
    # --force without --gpu-profile must retain both the card and its completed
    # policy instead of randomly selecting/resetting either one.
    GPU_PROFILE=gt1030_2gb "$CREATE_VM" "$vm_id" --force \
        >"$TMP_DIR/create-force-preserve.out" \
        2>"$TMP_DIR/create-force-preserve.err" || \
        fail "--force failed to preserve a valid completed GPU policy"

    (
        unset GPU_PROFILE SPOOF_MODE VGPU_IDENTITY_TARGET
        unset VGPU_MDEV_INTERNAL_PCI_IDENTITY VGPU_MDEV_FRL_ENABLED
        unset VGPU_PATCHED_DRIVER_REQUIRED_VERSION
        unset VGPU_PATCHED_DRIVER_VERSION VGPU_PATCHED_DRIVER_INF
        # shellcheck disable=SC1090
        source "$conf"
        assert_eq gtx1050_2gb "$GPU_PROFILE" "--force preserved GPU profile"
        assert_eq A "$SPOOF_MODE" "--force preserved spoof mode"
        assert_eq full-consumer "$VGPU_IDENTITY_TARGET" \
            "--force preserved identity target"
        assert_eq 1 "$VGPU_MDEV_INTERNAL_PCI_IDENTITY" \
            "--force preserved internal PCI policy"
        assert_eq 0 "$VGPU_MDEV_FRL_ENABLED" "--force preserved FRL policy"
        assert_eq 31.0.15.3833 "$VGPU_PATCHED_DRIVER_REQUIRED_VERSION" \
            "--force preserved required driver version"
        assert_eq 31.0.15.3833 "$VGPU_PATCHED_DRIVER_VERSION" \
            "--force preserved installed driver version"
        assert_eq oem42.inf "$VGPU_PATCHED_DRIVER_INF" \
            "--force preserved non-hard-coded OEM INF"
    )
    for field in GPU_PROFILE SPOOF_MODE VGPU_IDENTITY_TARGET \
            VGPU_MDEV_INTERNAL_PCI_IDENTITY VGPU_MDEV_FRL_ENABLED \
            VGPU_PATCHED_DRIVER_REQUIRED_VERSION \
            VGPU_PATCHED_DRIVER_VERSION VGPU_PATCHED_DRIVER_INF; do
        [[ $(grep -c "^${field}=" "$conf") -eq 1 ]] || \
            fail "--force emitted duplicate $field policy"
    done

    # OEM publication is host-specific.  Accept oemN.inf, but fail closed on
    # any other persisted name and leave the existing config byte-for-byte.
    cp -- "$conf" "$backup"
    chmod 0644 "$conf"
    printf '%s\n' 'VGPU_PATCHED_DRIVER_INF=nvgridsw.inf' >>"$conf"
    chmod 0444 "$conf"
    before_hash=$(sha256sum "$conf" | awk '{print $1}')
    if "$CREATE_VM" "$vm_id" --force \
            >"$TMP_DIR/create-force-bad-inf.out" \
            2>"$TMP_DIR/create-force-bad-inf.err"; then
        fail "--force accepted a non-oemN patched-driver INF"
    fi
    after_hash=$(sha256sum "$conf" | awk '{print $1}')
    assert_eq "$before_hash" "$after_hash" "invalid INF preserved config"
    grep -Fq '必须是 oemN.inf' "$TMP_DIR/create-force-bad-inf.err" || \
        fail "invalid OEM INF rejection was not clear"
    chmod 0644 "$conf"
    cp -- "$backup" "$conf"
    chmod 0444 "$conf"

    # An explicit profile selector is the opt-in migration boundary and gets
    # the selected profile's safe new-VM defaults, not stale 1050 policy.
    "$CREATE_VM" "$vm_id" --force --gpu-profile gt1030_2gb \
        >"$TMP_DIR/create-force-explicit.out" \
        2>"$TMP_DIR/create-force-explicit.err" || \
        fail "explicit --gpu-profile migration failed"
    (
        unset GPU_PROFILE SPOOF_MODE VGPU_IDENTITY_TARGET
        unset VGPU_MDEV_INTERNAL_PCI_IDENTITY VGPU_MDEV_FRL_ENABLED
        unset VGPU_PATCHED_DRIVER_REQUIRED_VERSION
        unset VGPU_PATCHED_DRIVER_VERSION VGPU_PATCHED_DRIVER_INF
        # shellcheck disable=SC1090
        source "$conf"
        assert_eq gt1030_2gb "$GPU_PROFILE" "explicit GPU migration profile"
        assert_eq B "$SPOOF_MODE" "explicit GPU migration safe mode"
        assert_eq name-only "$VGPU_IDENTITY_TARGET" \
            "explicit GPU migration identity target"
        [[ ! -v VGPU_MDEV_INTERNAL_PCI_IDENTITY ]] || \
            fail "explicit migration retained internal PCI policy"
        [[ ! -v VGPU_MDEV_FRL_ENABLED ]] || \
            fail "explicit migration retained FRL policy"
        [[ ! -v VGPU_PATCHED_DRIVER_REQUIRED_VERSION ]] || \
            fail "GT 1030 migration retained GTX 1050 required version"
        [[ ! -v VGPU_PATCHED_DRIVER_VERSION ]] || \
            fail "explicit migration retained installed driver version"
        [[ ! -v VGPU_PATCHED_DRIVER_INF ]] || \
            fail "explicit migration retained installed OEM INF"
    )
}

test_force_missing_gpu_profile_fails() {
    local vm_id=101 conf="$VM_ROOT/101/vm.conf"
    local backup="$TMP_DIR/vm101-with-gpu.conf"
    local replacement="$TMP_DIR/vm101-without-gpu.conf" before_hash after_hash

    cp -- "$conf" "$backup"
    sed '/^GPU_PROFILE=/d' "$conf" >"$replacement"
    chmod 0644 "$conf"
    cp -- "$replacement" "$conf"
    chmod 0444 "$conf"
    before_hash=$(sha256sum "$conf" | awk '{print $1}')
    if "$CREATE_VM" "$vm_id" --force \
            >"$TMP_DIR/create-force-missing-gpu.out" \
            2>"$TMP_DIR/create-force-missing-gpu.err"; then
        fail "--force randomly replaced a missing legacy GPU_PROFILE"
    fi
    after_hash=$(sha256sum "$conf" | awk '{print $1}')
    assert_eq "$before_hash" "$after_hash" "missing GPU profile preserved config"
    grep -Fq '拒绝 --force 自动换卡' \
        "$TMP_DIR/create-force-missing-gpu.err" || \
        fail "missing GPU_PROFILE refusal was not clear"
    chmod 0644 "$conf"
    cp -- "$backup" "$conf"
    chmod 0444 "$conf"
}

test_unknown_profile_fails() {
    local vm_id=103 conf="$VM_ROOT/103/vm.conf"

    if "$CREATE_VM" "$vm_id" --gpu-profile definitely-not-a-gpu \
        >"$TMP_DIR/create-unknown.out" 2>"$TMP_DIR/create-unknown.err"; then
        fail "create-vm accepted an unknown GPU profile"
    fi
    [[ ! -e "$conf" ]] || fail "unknown GPU profile created a VM config: $conf"
}

test_create_random_profile() {
    local vm_id=104 conf="$VM_ROOT/104/vm.conf"
    local selected after_profile

    env -u GPU_PROFILE "$CREATE_VM" "$vm_id" \
        --platform i7-4820k-p9x79-elpida-8g \
        --ssd-profile samsung-850-pro-512gb \
        --monitor-profile lenovo-d24-20 \
        >"$TMP_DIR/create-random.out" 2>"$TMP_DIR/create-random.err" || {
        sed -n '1,120p' "$TMP_DIR/create-random.err" >&2
        fail "create-vm could not choose a random audited GPU"
    }
    [[ -f "$conf" ]] || fail "random GPU creation did not publish vm.conf"
    selected=$(
        unset GPU_PROFILE
        # shellcheck source=/dev/null
        source "$conf"
        printf '%s' "$GPU_PROFILE"
    )
    vgpu_profile_load "$selected" ||
        fail "create-vm persisted a GPU outside the audited catalog: $selected"
    grep -Fq "显卡名称目标: $selected /" "$TMP_DIR/create-random.out" ||
        fail "create-vm did not report the selected random GPU"

    # A metadata refresh without an explicit --gpu-profile must retain the
    # one-time selection instead of drawing a new card.
    env -u GPU_PROFILE "$CREATE_VM" "$vm_id" --force \
        >"$TMP_DIR/create-random-force.out" \
        2>"$TMP_DIR/create-random-force.err" ||
        fail "--force could not retain a randomly selected GPU"
    after_profile=$(
        unset GPU_PROFILE
        # shellcheck source=/dev/null
        source "$conf"
        printf '%s' "$GPU_PROFILE"
    )
    assert_eq "$selected" "$after_profile" \
        "--force retained one-time random GPU"
}

test_catalog
test_random_picker
test_create_profile gtx750ti_2gb 1 option-first
test_create_profile gt1030_2gb 101 vm-first
test_create_profile gtx1050_2gb 102 option-first
# Exercise shell-safe vm.conf serialization for the only catalog label that
# contains whitespace; fixed Samsung defaults used to hide this failure.
test_create_profile gtx750ti_msi_2gb 105 vm-first
# Exercises the fourth audited VRAM maker and the GTX 750 (not RTX 750) row.
test_create_profile gtx750_gigabyte_1gb 108 option-first
if VGPU_HOST_CONFIG="$HOST_1GB_CONFIG" "$CREATE_VM" 106 \
        --gpu-profile gt740_zotac_1gb \
        >"$TMP_DIR/create-legacy.out" 2>"$TMP_DIR/create-legacy.err"; then
    fail 'new VM accepted a Kepler legacy-only identity'
fi
grep -Fq 'Kepler/R470' "$TMP_DIR/create-legacy.err" || \
    fail 'Kepler new-VM refusal was not clear'
test_create_random_profile
test_unknown_profile_fails
test_force_gpu_policy
test_force_missing_gpu_profile_fails

if grep -Fq 'oem6.inf' "$CREATE_VM"; then
    fail "create-vm hard-codes VM3's published OEM INF"
fi

exec {START_HOLDER_FD}>"$VM_ROOT/102/run/start.lock"
flock -x "$START_HOLDER_FD"
if "$CREATE_VM" 102 --force >"$TMP_DIR/create-locked.out" \
        2>"$TMP_DIR/create-locked.err"; then
    fail "create-vm rewrote a config while the VM start lock was busy"
fi
exec {START_HOLDER_FD}>&-
grep -Fq '正在启动或运行' "$TMP_DIR/create-locked.err" \
    || fail "create-vm start-lock refusal was not clear"

echo "OK: vGPU profile catalog and create-vm checks passed"

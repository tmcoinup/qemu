#!/usr/bin/env bash
# Regression coverage for the guest-visible vGPU identity catalog and VM
# creation.  The test only creates files below a temporary VM_ROOT; it never
# probes or writes the host mdev sysfs hierarchy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROFILE_LIB="$REPO_ROOT/deploy/lib/vgpu-profiles.sh"
CREATE_VM="$REPO_ROOT/deploy/create-vm.sh"
FINISH_VGPU="$REPO_ROOT/deploy/finish-vgpu-install.sh"
PATCH_GRID="$REPO_ROOT/deploy/guest/patch-grid-strings.ps1"
APPLY_PROFILE="$REPO_ROOT/deploy/guest/apply-vm-profile.ps1"
SETUP_GUEST="$REPO_ROOT/deploy/setup-guest.sh"
INF_PATCH="$REPO_ROOT/deploy/guest/spoof-inf/inf-patch.ps1"

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

declare -A SEEN_KEYS=()
declare -A SEEN_PCI_IDS=()

test_catalog() {
    local row fields key mdev_profile name vid did subvid subdid rev
    local vram_mb vbios core_mhz boost_mhz memory_mhz bus_bits
    local bandwidth_mbps ram_type ram_maker memory_type_nvapi
    local memory_maker_nvapi cuda_cores shader_subpipes rop_count tmu_count
    local architecture implementation chip_revision pcie_width
    local pci_id did_hex loaded registry_name

    ((${#VGPU_PROFILE_CATALOG[@]} > 0)) || fail "vGPU profile catalog is empty"
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

        assert_eq 2048 "$vram_mb" "$key catalog VRAM"
        assert_eq nvidia-257 "$mdev_profile" "$key catalog mdev profile"
        assert_eq GDDR5 "$ram_type" "$key catalog memory type"
        assert_eq Samsung "$ram_maker" "$key catalog memory maker"
        assert_eq 8 "$memory_type_nvapi" "$key NVAPI memory type"
        assert_eq 1 "$memory_maker_nvapi" "$key NVAPI memory maker"
        local raw_memory_khz=$((memory_mhz * 2000))
        local derived_bandwidth=$((raw_memory_khz * 2 * bus_bits / 8000))
        local bandwidth_difference=$((derived_bandwidth - bandwidth_mbps))
        (( bandwidth_difference >= 0 )) || \
            bandwidth_difference=$((-bandwidth_difference))
        (( bandwidth_difference * 100 <= bandwidth_mbps )) ||
            fail "$key memory clock/bus/bandwidth exceeds one-percent tolerance"

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

        did_hex="${did#0x}"
        grep -Fq "VEN_10DE&DEV_${did_hex^^}" "$PATCH_GRID" \
            || fail "$key PCI device is missing from patch-grid-strings.ps1"
        grep -Fq "'$key'" "$INF_PATCH" \
            || fail "$key is missing from guest INF profile map"
        grep -Fq "Hex = '${did_hex^^}'" "$INF_PATCH" \
            || fail "$key PCI device is missing from guest INF target map"

        vgpu_profile_load "$key" || fail "cannot load catalog profile: $key"
        loaded="$GPU_PROFILE|$VGPU_MDEV_PROFILE|$GPU_NAME|$GPU_PCI_VID|$GPU_PCI_DID|$GPU_SUB_VID|$GPU_SUB_DID|$GPU_REV|$GPU_VRAM_MB|$GPU_VBIOS|$GPU_CORE_MHZ|$GPU_BOOST_MHZ|$GPU_MEMORY_MHZ|$GPU_MEMORY_BUS_BITS|$GPU_MEMORY_BANDWIDTH_MBPS|$GPU_MEMORY_TYPE|$GPU_MEMORY_MAKER|$GPU_MEMORY_TYPE_NVAPI|$GPU_MEMORY_MAKER_NVAPI|$GPU_CUDA_CORES|$GPU_SHADER_SUBPIPES|$GPU_ROP_COUNT|$GPU_TMU_COUNT|$GPU_ARCHITECTURE|$GPU_IMPLEMENTATION|$GPU_CHIP_REVISION|$GPU_PCIE_WIDTH"
        assert_eq "$row" "$loaded" "$key loaded profile"
    done

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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
IMAGE_ROOT="$TMP_DIR"
VM_ROOT="$TMP_DIR/vms"
export IMAGE_ROOT VM_ROOT

test_create_profile() {
    local key="$1" vm_id="$2" order="$3" conf
    local expected_name expected_vid expected_did expected_subvid expected_subdid
    local expected_core expected_boost expected_memory
    local expected_vbios expected_memory_type_nvapi expected_memory_maker_nvapi
    local expected_cuda expected_subpipes expected_rops expected_tmus expected_architecture
    local expected_implementation expected_chip_revision expected_pcie_width

    vgpu_profile_load "$key" || fail "required test profile is absent: $key"
    expected_name="$GPU_NAME"
    expected_vid="$GPU_PCI_VID"
    expected_did="$GPU_PCI_DID"
    expected_subvid="$GPU_SUB_VID"
    expected_subdid="$GPU_SUB_DID"
    expected_core="$GPU_CORE_MHZ"
    expected_boost="$GPU_BOOST_MHZ"
    expected_memory="$GPU_MEMORY_MHZ"
    expected_vbios="$GPU_VBIOS"
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
    if [[ "$order" == "option-first" ]]; then
        "$CREATE_VM" --gpu-profile "$key" "$vm_id" \
            >"$TMP_DIR/create-$vm_id.out" 2>"$TMP_DIR/create-$vm_id.err"
    else
        "$CREATE_VM" "$vm_id" --gpu-profile "$key" \
            >"$TMP_DIR/create-$vm_id.out" 2>"$TMP_DIR/create-$vm_id.err"
    fi

    conf="$VM_ROOT/vm${vm_id}/vm.conf"
    [[ -f "$conf" ]] || fail "$key did not create $conf"

    (
        unset GPU_PROFILE SPOOF_MODE VGPU_IDENTITY_TARGET
        unset VGPU_MDEV_INTERNAL_PCI_IDENTITY VGPU_MDEV_FRL_ENABLED
        unset VGPU_PATCHED_DRIVER_REQUIRED_VERSION
        unset VGPU_PATCHED_DRIVER_VERSION VGPU_PATCHED_DRIVER_INF
        unset VGPU_MDEV_PROFILE VGPU_FB_MB GPU_NAME GPU_VRAM_MB
        unset GPU_PCI_VID GPU_PCI_DID GPU_SUB_VID GPU_SUB_DID
        unset GPU_CORE_MHZ GPU_BOOST_MHZ GPU_MEMORY_MHZ
        unset GPU_VBIOS GPU_MEMORY_TYPE_NVAPI GPU_MEMORY_MAKER_NVAPI
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
        assert_eq nvidia-257 "${VGPU_MDEV_PROFILE-}" "$key conf mdev profile"
        assert_eq 2048 "${VGPU_FB_MB-}" "$key conf allocated framebuffer"
        assert_eq 2048 "${GPU_VRAM_MB-}" "$key conf advertised VRAM"
        assert_eq "$expected_name" "${GPU_NAME-}" "$key conf GPU name"
        assert_eq "$expected_vid" "${GPU_PCI_VID-}" "$key conf PCI vendor"
        assert_eq "$expected_did" "${GPU_PCI_DID-}" "$key conf PCI device"
        assert_eq "$expected_subvid" "${GPU_SUB_VID-}" "$key conf subsystem vendor"
        assert_eq "$expected_subdid" "${GPU_SUB_DID-}" "$key conf subsystem device"
        assert_eq "$expected_core" "${GPU_CORE_MHZ-}" "$key conf core clock"
        assert_eq "$expected_boost" "${GPU_BOOST_MHZ-}" "$key conf boost clock"
        assert_eq "$expected_memory" "${GPU_MEMORY_MHZ-}" "$key conf memory clock"
        assert_eq "$expected_vbios" "${GPU_VBIOS-}" "$key conf VBIOS"
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
    local vm_id=102 conf="$VM_ROOT/vm102/vm.conf"
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
    local vm_id=101 conf="$VM_ROOT/vm101/vm.conf"
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
    local vm_id=103 conf="$VM_ROOT/vm103/vm.conf"

    if "$CREATE_VM" "$vm_id" --gpu-profile definitely-not-a-gpu \
        >"$TMP_DIR/create-unknown.out" 2>"$TMP_DIR/create-unknown.err"; then
        fail "create-vm accepted an unknown GPU profile"
    fi
    [[ ! -e "$conf" ]] || fail "unknown GPU profile created a VM config: $conf"
}

test_catalog
test_create_profile gtx750ti_2gb 1 option-first
test_create_profile gt1030_2gb 101 vm-first
test_create_profile gtx1050_2gb 102 option-first
test_unknown_profile_fails
test_force_gpu_policy
test_force_missing_gpu_profile_fails

if grep -Fq 'oem6.inf' "$CREATE_VM"; then
    fail "create-vm hard-codes VM3's published OEM INF"
fi

exec {START_HOLDER_FD}>"$VM_ROOT/control/vm102.start.lock"
flock -x "$START_HOLDER_FD"
if "$CREATE_VM" 102 --force >"$TMP_DIR/create-locked.out" \
        2>"$TMP_DIR/create-locked.err"; then
    fail "create-vm rewrote a config while the VM start lock was busy"
fi
exec {START_HOLDER_FD}>&-
grep -Fq '正在启动或运行' "$TMP_DIR/create-locked.err" \
    || fail "create-vm start-lock refusal was not clear"

echo "OK: vGPU profile catalog and create-vm checks passed"

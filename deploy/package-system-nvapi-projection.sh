#!/usr/bin/env bash
# Build one private, VM-bound and HTTP-free system NVAPI projection package.
# This command is build-only: it does not start/stop a VM, modify its disk,
# touch BCD, install a driver or use any host/guest credential.
set -euo pipefail
umask 077
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
# shellcheck source=lib/signed-consumer-catalog.sh
source "$here/lib/signed-consumer-catalog.sh"
# shellcheck source=lib/monitor-profiles.sh
source "$here/lib/monitor-profiles.sh"
# shellcheck source=lib/vgpu-driver-assets.sh
source "$here/lib/vgpu-driver-assets.sh"

usage() {
    cat <<'EOF'
usage: ./deploy/package-system-nvapi-projection.sh VM_ID [options]

Options:
  --output-root DIR   Explicit private export root; an external override is
                      not managed by delete-vm
                      (default: VM_DIR/packages/SystemNvapiProjection)
  --list-profiles     Show every supported atomic GPU/VRAM-maker profile
  -h, --help          Show this help

Output:
  DIR/vmN-UUID-CONTRACT.iso
  DIR/vmN-UUID-CONTRACT/Run-As-Administrator.cmd

The package is bound to the exact VM UUID, GPU/monitor profiles, present
Display PnP route and production NVIDIA driver version. It installs the
x86/x64 forwarding NVAPI user-mode pair and a profile-driven monitor identity
publisher for future PnP instances, keeps signed NVIDIA originals beside it,
and includes one-click rollback. It never changes BCD, INF/CAT/SYS,
certificates or kernel drivers.
EOF
}

die() { echo "[system-nvapi-package] ERROR: $*" >&2; exit 1; }
log() { echo "[system-nvapi-package] $*"; }
sha256_upper() { sha256sum -- "$1" | awk '{print toupper($1)}'; }

VM_ID=""
OUTPUT_ROOT=""
while (($#)); do
    case "$1" in
        --output-root)
            (($# >= 2)) || die '--output-root requires an absolute directory'
            OUTPUT_ROOT=$2
            shift 2
            ;;
        --list-profiles)
            vgpu_profile_print_catalog
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if vm_storage_id_is_supported "$1" && [[ -z "$VM_ID" ]]; then
                VM_ID=$1
                shift
            else
                die "unknown argument or unsupported VM_ID: $1"
            fi
            ;;
    esac
done
[[ -n "$VM_ID" ]] || { usage >&2; exit 2; }

for dependency in jq sha256sum xorriso mktemp realpath stat install sed grep \
        awk find sort mv cp python3; do
    command -v "$dependency" >/dev/null 2>&1 \
        || die "missing host dependency: $dependency"
done
vgpu_profile_validate_catalog || die 'GPU profile catalog validation failed'
monitor_profiles_validate || die 'monitor profile catalog validation failed'
"$here/guest/generate-vgpu-profile-catalog.sh" --check \
    || die 'generated guest identity catalog is stale'

vm_storage_init
vm_storage_require_namespace_ready "$VM_ID" \
    || die 'VM storage still uses an old/conflicting layout'
vm_storage_validate_instance_tree "$VM_ID" \
    || die 'VM instance tree is unsafe'
CONF=$(vm_storage_config_path "$VM_ID")
[[ -f "$CONF" && ! -L "$CONF" && -r "$CONF" ]] \
    || die "VM config is not a safe readable file: $CONF"
CONFIG_SHA256=$(sha256_upper "$CONF")

config_literal() {
    local field=$1 value
    local -a values=()
    mapfile -t values < <(sed -n -E "s/^[[:space:]]*${field}=//p" "$CONF")
    ((${#values[@]} == 1)) \
        || die "vm.conf must contain exactly one literal ${field}="
    value=${values[0]%$'\r'}
    value=$(sed -E \
        's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
        <<<"$value")
    value=${value#\"}; value=${value%\"}; value=${value#\'}; value=${value%\'}
    [[ -n "$value" ]] || die "vm.conf ${field} is empty"
    printf '%s\n' "$value"
}

config_optional_literal() {
    local field=$1 fallback=$2 count
    count=$(grep -Ec "^[[:space:]]*${field}=" "$CONF")
    case "$count" in
        0) printf '%s\n' "$fallback" ;;
        1) config_literal "$field" ;;
        *) die "vm.conf contains duplicate ${field}=" ;;
    esac
}

CONFIG_VM_ID=$(config_literal VM_ID)
[[ "$CONFIG_VM_ID" == "$VM_ID" ]] || die 'VM_ID does not match instance path'
VM_UUID=$(config_literal VM_UUID)
[[ "$VM_UUID" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]] \
    || die 'VM_UUID is invalid'
VM_UUID=${VM_UUID,,}
SPOOF_MODE=$(config_literal SPOOF_MODE)
IDENTITY_TARGET=$(config_literal VGPU_IDENTITY_TARGET)
[[ "$SPOOF_MODE" == B && "$IDENTITY_TARGET" == name-only ]] \
    || die 'system NVAPI projection requires SPOOF_MODE=B / name-only'

declare -A configured=()
profile_fields=(
    GPU_PROFILE GPU_NAME GPU_PCI_VID GPU_PCI_DID GPU_SUB_VID GPU_SUB_DID
    GPU_REV GPU_VRAM_MB GPU_VBIOS GPU_CORE_MHZ GPU_BOOST_MHZ GPU_MEMORY_MHZ
    GPU_MEMORY_BUS_BITS GPU_MEMORY_BANDWIDTH_MBPS GPU_MEMORY_TYPE
    GPU_MEMORY_MAKER GPU_MEMORY_TYPE_NVAPI GPU_MEMORY_MAKER_NVAPI
    GPU_CUDA_CORES GPU_SHADER_SUBPIPES GPU_ROP_COUNT GPU_TMU_COUNT
    GPU_ARCHITECTURE GPU_IMPLEMENTATION GPU_CHIP_REVISION GPU_PCIE_WIDTH
    VGPU_MDEV_PROFILE
)
for field in "${profile_fields[@]}"; do
    configured[$field]=$(config_literal "$field")
done
requested_profile=${configured[GPU_PROFILE]}
vgpu_profile_load "$requested_profile" \
    || die 'vm.conf selects an unknown atomic GPU profile'
vgpu_profile_capability_load "$requested_profile" \
    || die 'vm.conf GPU profile has no reviewed D3D12 capability contract'

assert_profile_field() {
    local field=$1 canonical=$2 actual
    actual=${configured[$field]}
    if [[ "$field" == GPU_PCI_* || "$field" == GPU_SUB_* ||
          "$field" == GPU_REV || "$field" == GPU_ARCHITECTURE ||
          "$field" == GPU_CHIP_REVISION ]]; then
        [[ "${actual^^}" == "${canonical^^}" ]] \
            || die "vm.conf $field differs from canonical profile"
    else
        [[ "$actual" == "$canonical" ]] \
            || die "vm.conf $field differs from canonical profile"
    fi
}
assert_profile_field GPU_PROFILE "$GPU_PROFILE"
assert_profile_field GPU_NAME "$GPU_NAME"
assert_profile_field GPU_PCI_VID "$GPU_PCI_VID"
assert_profile_field GPU_PCI_DID "$GPU_PCI_DID"
assert_profile_field GPU_SUB_VID "$GPU_SUB_VID"
assert_profile_field GPU_SUB_DID "$GPU_SUB_DID"
assert_profile_field GPU_REV "$GPU_REV"
assert_profile_field GPU_VRAM_MB "$GPU_VRAM_MB"
assert_profile_field GPU_VBIOS "$GPU_VBIOS"
assert_profile_field GPU_CORE_MHZ "$GPU_CORE_MHZ"
assert_profile_field GPU_BOOST_MHZ "$GPU_BOOST_MHZ"
assert_profile_field GPU_MEMORY_MHZ "$GPU_MEMORY_MHZ"
assert_profile_field GPU_MEMORY_BUS_BITS "$GPU_MEMORY_BUS_BITS"
assert_profile_field GPU_MEMORY_BANDWIDTH_MBPS "$GPU_MEMORY_BANDWIDTH_MBPS"
assert_profile_field GPU_MEMORY_TYPE "$GPU_MEMORY_TYPE"
assert_profile_field GPU_MEMORY_MAKER "$GPU_MEMORY_MAKER"
assert_profile_field GPU_MEMORY_TYPE_NVAPI "$GPU_MEMORY_TYPE_NVAPI"
assert_profile_field GPU_MEMORY_MAKER_NVAPI "$GPU_MEMORY_MAKER_NVAPI"
assert_profile_field GPU_CUDA_CORES "$GPU_CUDA_CORES"
assert_profile_field GPU_SHADER_SUBPIPES "$GPU_SHADER_SUBPIPES"
assert_profile_field GPU_ROP_COUNT "$GPU_ROP_COUNT"
assert_profile_field GPU_TMU_COUNT "$GPU_TMU_COUNT"
assert_profile_field GPU_ARCHITECTURE "$GPU_ARCHITECTURE"
assert_profile_field GPU_IMPLEMENTATION "$GPU_IMPLEMENTATION"
assert_profile_field GPU_CHIP_REVISION "$GPU_CHIP_REVISION"
assert_profile_field GPU_PCIE_WIDTH "$GPU_PCIE_WIDTH"
assert_profile_field VGPU_MDEV_PROFILE "$VGPU_MDEV_PROFILE"

# Bind the same package to the canonical monitor profile.  This lets the
# guest-side publisher repair a newly enumerated DISPLAY instance without
# knowing anything about the caller, while the EDID bytes remain generated
# from the shared host catalog.
declare -A configured_monitor=()
monitor_fields=(
    MONITOR_PROFILE MONITOR_VENDOR MONITOR_PRODUCT_ID MONITOR_EDID_NAME
    MONITOR_DISPLAY_NAME MONITOR_MANUFACTURER MONITOR_BRAND_NAME
    MONITOR_MODEL_NAME MONITOR_WIDTH_MM MONITOR_HEIGHT_MM MONITOR_NATIVE_X
    MONITOR_NATIVE_Y MONITOR_REFRESH_HZ MONITOR_MIN_V MONITOR_MAX_V
    MONITOR_MIN_H MONITOR_MAX_H MONITOR_MAX_CLOCK_MHZ MONITOR_VIDEO_INPUT
    MONITOR_YEAR MONITOR_WEEK MONITOR_SERIAL_PREFIX MONITOR_MODE_SET
)
for field in "${monitor_fields[@]}"; do
    configured_monitor[$field]=$(config_literal "$field")
done
requested_monitor_profile=${configured_monitor[MONITOR_PROFILE]}
monitor_profile_load "$requested_monitor_profile" \
    || die 'vm.conf selects an unknown monitor profile'
for field in "${monitor_fields[@]}"; do
    [[ "${configured_monitor[$field]}" == "${!field}" ]] \
        || die "vm.conf $field differs from canonical monitor profile"
done
MONITOR_SERIAL=$(config_literal MONITOR_SERIAL)
monitor_profile_serial_validate "$MONITOR_SERIAL" \
    || die 'vm.conf MONITOR_SERIAL violates the selected profile policy'

SIGNED_STATE=$(config_optional_literal VGPU_SIGNED_CONSUMER_STATE none)
if [[ "$SIGNED_STATE" == validated ]]; then
    SIGNED_PROFILE=$(config_literal VGPU_SIGNED_CONSUMER_PROFILE)
    DRIVER_KEY=$(config_literal VGPU_SIGNED_CONSUMER_DRIVER_KEY)
    [[ "$SIGNED_PROFILE" == "$GPU_PROFILE" ]] \
        || die 'validated signed-consumer profile differs from GPU_PROFILE'
    signed_consumer_profile_load_canonical "$GPU_PROFILE" \
        || die 'could not load signed-consumer canonical profile'
    signed_consumer_driver_load "$DRIVER_KEY" \
        || die 'validated signed-consumer driver key is unknown'
    signed_consumer_driver_assert_production_enabled \
        || die 'validated signed-consumer route has since been quarantined'
    signed_consumer_driver_assert_profile \
        || die 'signed-consumer driver does not match canonical profile'
    TARGET_PNP=$SC_CANONICAL_TARGET_PNP
    DRIVER_VERSION=$SC_DRIVER_VERSION
    TRANSPORT_KIND=qualified-signed-consumer
    MONITOR_DRIVER_POLICY=$SC_DRIVER_KEY
    MONITOR_DRIVER_INF_SHA256=$SC_INF_SHA256
    MONITOR_DRIVER_CATALOG_SHA256=$SC_CATALOG_SHA256
    MONITOR_DRIVER_PNP_ID=$SC_CANONICAL_TARGET_PNP
else
    vgpu_select_driver_stack \
        || die 'could not select the reviewed host/guest driver pair'
    [[ "$VGPU_SELECTED_DRIVER_MONITOR_SYNC_MODE" != off &&
       -n "$VGPU_SELECTED_DRIVER_MONITOR_POLICY" &&
       "$VGPU_SELECTED_DRIVER_INF_SHA256" =~ ^[0-9a-f]{64}$ &&
       "$VGPU_SELECTED_DRIVER_CATALOG_SHA256" =~ ^[0-9a-f]{64}$ ]] \
        || die "${VGPU_SELECTED_DRIVER_BRANCH:-unknown} has no reviewed B/native system projection policy"
    TARGET_PNP='PCI\VEN_10DE&DEV_1E30'
    DRIVER_VERSION=$VGPU_SELECTED_DRIVER_VERSION
    TRANSPORT_KIND=native-vgpu
    MONITOR_DRIVER_POLICY=$VGPU_SELECTED_DRIVER_MONITOR_POLICY
    MONITOR_DRIVER_INF_SHA256=$VGPU_SELECTED_DRIVER_INF_SHA256
    MONITOR_DRIVER_CATALOG_SHA256=$VGPU_SELECTED_DRIVER_CATALOG_SHA256
    MONITOR_DRIVER_PNP_ID=$(vgpu_profile_guest_grid_pnp_id \
        "$VGPU_MDEV_PROFILE" "${VGPU_RESOURCE_PROFILE:-}") \
        || die 'GPU resource has no reviewed guest GRID PnP mapping'
fi

# The system shim must identify the same logical adapter as Windows PnP.  The
# transport vendor/device are therefore carried independently from the atomic
# consumer board subsystem.  This keeps the production GRID binding intact
# while allowing hardware tools to merge PnP and NVAPI into one adapter.
transport_tail=${TARGET_PNP#PCI\\VEN_}
TRANSPORT_PCI_VENDOR_HEX=${transport_tail%%&*}
transport_tail=${transport_tail#*&DEV_}
TRANSPORT_PCI_DEVICE_HEX=${transport_tail%%&*}
[[ "$TRANSPORT_PCI_VENDOR_HEX" =~ ^[0-9A-Fa-f]{4}$ &&
   "$TRANSPORT_PCI_DEVICE_HEX" =~ ^[0-9A-Fa-f]{4}$ ]] \
    || die 'target PnP ID does not contain a valid PCI vendor/device tuple'
TRANSPORT_PCI_VENDOR_ID=$((16#$TRANSPORT_PCI_VENDOR_HEX))
TRANSPORT_PCI_DEVICE_ID=$((16#$TRANSPORT_PCI_DEVICE_HEX))
PCI_PROJECTION_MODE=transport-device-profile-subsystem
unset transport_tail TRANSPORT_PCI_VENDOR_HEX TRANSPORT_PCI_DEVICE_HEX

if [[ -z "$OUTPUT_ROOT" ]]; then
    VM_PACKAGE_ROOT=$(vm_storage_instance_package_dir "$VM_ID") \
        || die 'could not resolve the VM package directory'
    OUTPUT_ROOT="$VM_PACKAGE_ROOT/SystemNvapiProjection"
    for directory in "$VM_PACKAGE_ROOT" "$OUTPUT_ROOT"; do
        [[ ! -L "$directory" && ( ! -e "$directory" || -d "$directory" ) ]] \
            || die "VM package path is not a real directory: $directory"
    done
    install -d -m 0700 -- "$VM_PACKAGE_ROOT" "$OUTPUT_ROOT"
fi
[[ "$OUTPUT_ROOT" == /* && "$OUTPUT_ROOT" != / ]] \
    || die '--output-root must be a non-root absolute path'
OUTPUT_ROOT=$(realpath -m -- "$OUTPUT_ROOT")
mkdir -p -- "$OUTPUT_ROOT"
[[ -d "$OUTPUT_ROOT" && ! -L "$OUTPUT_ROOT" ]] \
    || die 'output root must be a real directory'

work=$(mktemp -d "$OUTPUT_ROOT/.build-vm${VM_ID}.XXXXXX")
trap '[[ -z "${work:-}" ]] || rm -rf -- "$work"' EXIT
PUBLISHED="$work/payload"
mkdir -p "$PUBLISHED"

assets=(
    guest/install-system-nvapi-projection.ps1
    guest/install-nvapi-shim.ps1
    guest/patch-grid-strings.ps1
    guest/vgpu-profile-catalog.json
    guest/nvapi-shim/nvapi.dll
    guest/nvapi-shim/nvapi64.dll
    guest/nvapi-shim/SystemNvapiProbe32.exe
    guest/nvapi-shim/SystemNvapiProbe64.exe
    guest/d3d12-capability-probe/D3D12CapabilityProbe32.exe
    guest/d3d12-capability-probe/D3D12CapabilityProbe64.exe
)
for relative in "${assets[@]}"; do
    source_path="$here/$relative"
    [[ -f "$source_path" && ! -L "$source_path" ]] \
        || die "missing/unsafe package asset: $relative"
    install -m 0600 "$source_path" "$PUBLISHED/$(basename -- "$relative")"
done

if [[ -z "${QEMU_EDID:-}" ]]; then
    for candidate in \
            /opt/vmate/qemu-edid.g11 \
            "$here/../build/qemu-edid"; do
        if [[ -x "$candidate" && ! -L "$candidate" ]]; then
            QEMU_EDID=$candidate
            break
        fi
    done
fi
[[ -n "${QEMU_EDID:-}" && -x "$QEMU_EDID" && ! -L "$QEMU_EDID" ]] \
    || die 'missing/unsafe qemu-edid.g11; reinstall VMate or set QEMU_EDID'
"$here/host/sync-monitor-cache.sh" \
    --generate-only "$PUBLISHED/monitor-edid.bin" \
    --qemu-edid "$QEMU_EDID" \
    --catalog "$MONITOR_PROFILE_CATALOG" \
    --monitor-profile "$MONITOR_PROFILE" \
    --serial "$MONITOR_SERIAL" \
    --instance "package-vm${VM_ID}" \
    --driver-version "$DRIVER_VERSION" \
    --driver-inf-sha256 "$MONITOR_DRIVER_INF_SHA256" \
    --driver-catalog-sha256 "$MONITOR_DRIVER_CATALOG_SHA256" \
    --driver-policy "$MONITOR_DRIVER_POLICY" \
    --nvidia-pnp-id "$MONITOR_DRIVER_PNP_ID" >/dev/null
[[ -f "$PUBLISHED/monitor-edid.bin" && ! -L "$PUBLISHED/monitor-edid.bin" &&
   $(stat -c %s -- "$PUBLISHED/monitor-edid.bin") == 256 ]] \
    || die 'monitor EDID generation did not produce exactly 256 bytes'

SHIM_X86_SHA=$(sha256_upper "$PUBLISHED/nvapi.dll")
SHIM_X64_SHA=$(sha256_upper "$PUBLISHED/nvapi64.dll")
PROBE_X86_SHA=$(sha256_upper "$PUBLISHED/SystemNvapiProbe32.exe")
PROBE_X64_SHA=$(sha256_upper "$PUBLISHED/SystemNvapiProbe64.exe")
D3D_PROBE_X86_SHA=$(sha256_upper "$PUBLISHED/D3D12CapabilityProbe32.exe")
D3D_PROBE_X64_SHA=$(sha256_upper "$PUBLISHED/D3D12CapabilityProbe64.exe")
MONITOR_EDID_SHA=$(sha256_upper "$PUBLISHED/monitor-edid.bin")
COORDINATOR_SHA=$(sha256_upper \
    "$PUBLISHED/install-system-nvapi-projection.ps1")
LOW_LEVEL_INSTALLER_SHA=$(sha256_upper \
    "$PUBLISHED/install-nvapi-shim.ps1")
PROFILE_WRITER_SHA=$(sha256_upper "$PUBLISHED/patch-grid-strings.ps1")
IDENTITY_CATALOG_JSON_SHA=$(sha256_upper \
    "$PUBLISHED/vgpu-profile-catalog.json")
IDENTITY_CATALOG_SHA=$(vgpu_profile_catalog_sha256)
JSON_CATALOG_SHA=$(jq -er '.catalogSha256' \
    "$PUBLISHED/vgpu-profile-catalog.json")
[[ "$JSON_CATALOG_SHA" == "$IDENTITY_CATALOG_SHA" ]] \
    || die 'shell/JSON identity catalog digests disagree'

VBIOS_VERSION=${GPU_VBIOS#Version }
CONTRACT="$PUBLISHED/system-nvapi-contract.json"
CONTRACT_BASE="$work/contract-base.json"
jq -n \
    --arg purpose g11-system-nvapi-projection \
    --arg vmId "$VM_ID" --arg vmUuid "$VM_UUID" \
    --arg sourceConfigSha256 "$CONFIG_SHA256" \
    --arg identityCatalogSha256 "$IDENTITY_CATALOG_SHA" \
    --arg targetPnpId "$TARGET_PNP" --arg driverVersion "$DRIVER_VERSION" \
    --arg pciProjectionMode "$PCI_PROJECTION_MODE" \
    --arg gpuName "$GPU_NAME" --arg profile "$GPU_PROFILE" \
    --arg boardBrand "$GPU_BOARD_BRAND" --arg boardModel "$GPU_BOARD_MODEL" \
    --arg memoryTypeName "$GPU_MEMORY_TYPE" \
    --arg memoryMakerName "$GPU_MEMORY_MAKER" \
    --arg memoryMakerNvapiName "$GPU_MEMORY_MAKER_NVAPI_NAME" \
    --arg identityScope "$GPU_IDENTITY_SCOPE" --arg vbiosVersion "$VBIOS_VERSION" \
    --arg monitorProfile "$MONITOR_PROFILE" \
    --arg monitorPnpVendor "$MONITOR_VENDOR" \
    --arg monitorPnpId "${MONITOR_VENDOR}${MONITOR_PRODUCT_ID#0x}" \
    --arg monitorEdidName "$MONITOR_EDID_NAME" \
    --arg monitorDisplayName "$MONITOR_DISPLAY_NAME" \
    --arg monitorManufacturer "$MONITOR_MANUFACTURER" \
    --arg monitorSerial "$MONITOR_SERIAL" \
    --arg monitorEdidSha256 "$MONITOR_EDID_SHA" \
    --arg coordinatorSha256 "$COORDINATOR_SHA" \
    --arg lowLevelInstallerSha256 "$LOW_LEVEL_INSTALLER_SHA" \
    --arg profileWriterSha256 "$PROFILE_WRITER_SHA" \
    --arg identityCatalogJsonSha256 "$IDENTITY_CATALOG_JSON_SHA" \
    --arg shimX86Sha256 "$SHIM_X86_SHA" --arg shimX64Sha256 "$SHIM_X64_SHA" \
    --arg probeX86Sha256 "$PROBE_X86_SHA" --arg probeX64Sha256 "$PROBE_X64_SHA" \
    --arg d3dProbeX86Sha256 "$D3D_PROBE_X86_SHA" \
    --arg d3dProbeX64Sha256 "$D3D_PROBE_X64_SHA" \
    --argjson pciVendorId "$((GPU_PCI_VID))" \
    --argjson pciDeviceId "$((GPU_PCI_DID))" \
    --argjson pciSubVendorId "$((GPU_SUB_VID))" \
    --argjson pciSubDeviceId "$((GPU_SUB_DID))" \
    --argjson pciRevisionId "$((GPU_REV))" \
    --argjson coreClockMHz "$GPU_CORE_MHZ" \
    --argjson boostClockMHz "$GPU_BOOST_MHZ" \
    --argjson memoryClockMHz "$GPU_MEMORY_MHZ" \
    --argjson memoryBusBits "$GPU_MEMORY_BUS_BITS" \
    --argjson memoryBandwidthMBps "$GPU_MEMORY_BANDWIDTH_MBPS" \
    --argjson vramMB "$GPU_VRAM_MB" \
    --argjson memoryType "$GPU_MEMORY_TYPE_NVAPI" \
    --argjson memoryMaker "$GPU_MEMORY_MAKER_NVAPI" \
    --argjson cudaCores "$GPU_CUDA_CORES" \
    --argjson shaderSubPipes "$GPU_SHADER_SUBPIPES" \
    --argjson ropCount "$GPU_ROP_COUNT" --argjson tmuCount "$GPU_TMU_COUNT" \
    --argjson architecture "$((GPU_ARCHITECTURE))" \
    --argjson implementation "$GPU_IMPLEMENTATION" \
    --argjson chipRevision "$((GPU_CHIP_REVISION))" \
    --argjson pcieWidth "$GPU_PCIE_WIDTH" \
    --argjson d3d12RaytracingTier "$GPU_D3D12_RAYTRACING_TIER" \
    --argjson rayTracingCores "$GPU_RAY_TRACING_CORES" \
    --argjson tensorCores "$GPU_TENSOR_CORES" \
    --argjson transportPciVendorId "$TRANSPORT_PCI_VENDOR_ID" \
    --argjson transportPciDeviceId "$TRANSPORT_PCI_DEVICE_ID" \
    --argjson monitorProductId "$((MONITOR_PRODUCT_ID))" '
    {
      schemaVersion: 4,
      purpose: $purpose,
      contractId: "",
      vmId: ($vmId | tonumber),
      vmUuid: $vmUuid,
      sourceConfigSha256: $sourceConfigSha256,
      identityCatalogSha256: $identityCatalogSha256,
      transport: {
        targetPnpId: $targetPnpId,
        driverVersion: $driverVersion,
        gpuName: $gpuName,
        pciVendorId: $transportPciVendorId,
        pciDeviceId: $transportPciDeviceId,
        pciProjectionMode: $pciProjectionMode
      },
      profile: {
        key: $profile, name: $gpuName,
        boardBrand: $boardBrand, boardModel: $boardModel,
        memoryTypeName: $memoryTypeName,
        memoryMakerName: $memoryMakerName,
        memoryMakerNvapiName: $memoryMakerNvapiName,
        identityScope: $identityScope,
        pciVendorId: $pciVendorId, pciDeviceId: $pciDeviceId,
        pciSubVendorId: $pciSubVendorId,
        pciSubDeviceId: $pciSubDeviceId, pciRevisionId: $pciRevisionId,
        coreClockMHz: $coreClockMHz, boostClockMHz: $boostClockMHz,
        memoryClockMHz: $memoryClockMHz, memoryBusBits: $memoryBusBits,
        memoryBandwidthMBps: $memoryBandwidthMBps, vramMB: $vramMB,
        memoryType: $memoryType, memoryMaker: $memoryMaker,
        cudaCores: $cudaCores, shaderSubPipes: $shaderSubPipes,
        ropCount: $ropCount, tmuCount: $tmuCount,
        architecture: $architecture, implementation: $implementation,
        chipRevision: $chipRevision, pcieWidth: $pcieWidth,
        d3d12RaytracingTier: $d3d12RaytracingTier,
        rayTracingCores: $rayTracingCores, tensorCores: $tensorCores,
        vbiosVersion: $vbiosVersion
      },
      monitor: {
        key: $monitorProfile,
        pnpVendor: $monitorPnpVendor,
        productId: $monitorProductId,
        pnpId: $monitorPnpId,
        edidName: $monitorEdidName,
        displayName: $monitorDisplayName,
        manufacturer: $monitorManufacturer,
        serial: $monitorSerial,
        edidSha256: $monitorEdidSha256
      },
      payload: {
        coordinatorSha256: $coordinatorSha256,
        lowLevelInstallerSha256: $lowLevelInstallerSha256,
        profileWriterSha256: $profileWriterSha256,
        identityCatalogJsonSha256: $identityCatalogJsonSha256,
        shimX86Sha256: $shimX86Sha256,
        shimX64Sha256: $shimX64Sha256,
        probeX86Sha256: $probeX86Sha256,
        probeX64Sha256: $probeX64Sha256,
        d3dProbeX86Sha256: $d3dProbeX86Sha256,
        d3dProbeX64Sha256: $d3dProbeX64Sha256
      }
    }' >"$CONTRACT_BASE"
CONTRACT_ID=$(jq -cS 'del(.contractId)' "$CONTRACT_BASE" | sha256sum | \
    awk '{print toupper($1)}')
jq --arg contractId "$CONTRACT_ID" '.contractId = $contractId' \
    "$CONTRACT_BASE" >"$CONTRACT"
chmod 0600 "$CONTRACT"

manifest_files=(
    install-system-nvapi-projection.ps1
    install-nvapi-shim.ps1
    patch-grid-strings.ps1
    vgpu-profile-catalog.json
    nvapi.dll
    nvapi64.dll
    SystemNvapiProbe32.exe
    SystemNvapiProbe64.exe
    D3D12CapabilityProbe32.exe
    D3D12CapabilityProbe64.exe
    monitor-edid.bin
    system-nvapi-contract.json
)
MANIFEST="$PUBLISHED/system-nvapi-manifest.json"
jq -n --arg contractId "$CONTRACT_ID" '{
    schemaVersion: 1,
    purpose: "g11-system-nvapi-projection",
    contractId: $contractId,
    files: []
}' >"$MANIFEST"
for name in "${manifest_files[@]}"; do
    bytes=$(stat -c %s -- "$PUBLISHED/$name")
    digest=$(sha256_upper "$PUBLISHED/$name")
    next="$work/manifest-next.json"
    jq --arg path "$name" --arg sha256 "$digest" --argjson bytes "$bytes" \
        '.files += [{path:$path,bytes:$bytes,sha256:$sha256}]' \
        "$MANIFEST" >"$next"
    mv -- "$next" "$MANIFEST"
done
chmod 0600 "$MANIFEST"

cat >"$PUBLISHED/Run-As-Administrator.cmd" <<'EOF'
@echo off
setlocal
cd /d "%~dp0"
fltmc >nul 2>&1
if errorlevel 1 (
  set "G11_SYSTEM_NVAPI_ENTRY=%~f0"
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:G11_SYSTEM_NVAPI_ENTRY -Verb RunAs"
  exit /b
)
set "LOG=%SystemRoot%\Temp\G11-System-NVAPI-Install.log"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-system-nvapi-projection.ps1" -Action Install -Reboot >"%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  type "%LOG%"
  echo.
  echo 安装失败，日志已保留在：%LOG%
  pause
)
exit /b %RC%
EOF

cat >"$PUBLISHED/Verify-As-Administrator.cmd" <<'EOF'
@echo off
setlocal
cd /d "%~dp0"
fltmc >nul 2>&1
if errorlevel 1 (
  set "G11_SYSTEM_NVAPI_ENTRY=%~f0"
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:G11_SYSTEM_NVAPI_ENTRY -Verb RunAs"
  exit /b
)
set "LOG=%SystemRoot%\Temp\G11-System-NVAPI-Verify.log"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-system-nvapi-projection.ps1" -Action Verify >"%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
type "%LOG%"
pause
exit /b %RC%
EOF

cat >"$PUBLISHED/Rollback-As-Administrator.cmd" <<'EOF'
@echo off
setlocal
cd /d "%~dp0"
fltmc >nul 2>&1
if errorlevel 1 (
  set "G11_SYSTEM_NVAPI_ENTRY=%~f0"
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:G11_SYSTEM_NVAPI_ENTRY -Verb RunAs"
  exit /b
)
set "LOG=%SystemRoot%\Temp\G11-System-NVAPI-Rollback.log"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-system-nvapi-projection.ps1" -Action Uninstall -Reboot >"%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  type "%LOG%"
  echo.
  echo 回滚失败，日志已保留在：%LOG%
  pause
)
exit /b %RC%
EOF

cat >"$PUBLISHED/README-运行说明.txt" <<EOF
G-11 通用系统硬件身份投影（vm${VM_ID}）

目标：${GPU_NAME} / ${GPU_BOARD_BRAND} / ${GPU_MEMORY_TYPE} ${GPU_MEMORY_MAKER}
NVAPI 能力：RT cores=${GPU_RAY_TRACING_CORES} / Tensor cores=${GPU_TENSOR_CORES}
D3D12 目标：raytracing tier=${GPU_D3D12_RAYTRACING_TIER}；安装前与验收均审计原生 x86/x64 路径，签名 transport 的实际能力可能更高
显示器：${MONITOR_DISPLAY_NAME} / ${MONITOR_VENDOR}${MONITOR_PRODUCT_ID#0x}
绑定：${VM_UUID}
Display：${TARGET_PNP} / ${DRIVER_VERSION}

安装：双击 Run-As-Administrator.cmd，确认 UAC；原生 x86/x64 D3D12 都能正常
      查询后，Windows 会安装、自动重启并验收。
复核：重启后可右键 Verify-As-Administrator.cmd -> 以管理员身份运行。
回滚：双击 Rollback-As-Administrator.cmd；Windows 会重启并恢复签名原件。

本包不修改 BCD，不开启 testsigning/nointegritychecks，不修改或安装 INF/CAT/SYS，
不导入证书，不安装任何内核驱动。x86/x64 未识别 NVAPI 调用转发给原始 NVIDIA DLL。
显示器发布器只按合同 EDID 处理匹配的 DISPLAY 实例，用于驱动换代后新实例的
FriendlyName/EDID_OVERRIDE 收敛；它不检测、修改或注入任何具体应用。
所有硬件检测工具仅用于重新扫描和交叉验收。本包会在任何系统投影写入前，
直接用 ID3D12Device::CheckFeatureSupport(D3D12_OPTIONS5) 审计 x86/x64。任一路径
无法枚举/查询 NVIDIA adapter 才拒绝安装；若签名 vGPU transport 暴露的原生 DXR
能力高于目标旧卡，则明确警告但不谎称已改写 D3D12，也不阻断 NVAPI 投影。
不要放置应用专用 d3d12.dll，也不要替换 Windows 系统 d3d12.dll。
本包不安装应用专用 DLL，不按进程名匹配，也不修改任何检测工具。
EOF
# cmd.exe consumes a byte after bare LF in batch files on affected Windows
# builds.  Publish launchers with canonical CRLF so every line keeps its first
# character whether the ISO is mounted or the directory is copied elsewhere.
for launcher in \
        "$PUBLISHED/Run-As-Administrator.cmd" \
        "$PUBLISHED/Verify-As-Administrator.cmd" \
        "$PUBLISHED/Rollback-As-Administrator.cmd"; do
    sed -i 's/$/\r/' "$launcher"
done
chmod 0600 "$PUBLISHED"/*.cmd "$PUBLISHED/README-运行说明.txt"

[[ "$(sha256_upper "$CONF")" == "$CONFIG_SHA256" ]] \
    || die 'vm.conf changed while packaging; discard this build'
OUTPUT_BASENAME="vm${VM_ID}-${VM_UUID}-${CONTRACT_ID:0:16}"
OUTPUT_DIR="$OUTPUT_ROOT/$OUTPUT_BASENAME"
OUTPUT_ISO="$OUTPUT_ROOT/${OUTPUT_BASENAME}.iso"
[[ ! -e "$OUTPUT_DIR" && ! -e "$OUTPUT_ISO" ]] \
    || die "output already exists (content-addressed): $OUTPUT_BASENAME (root: $OUTPUT_ROOT)"
ISO_WORK="$work/SystemNvapiProjection.iso"
xorriso -as mkisofs -quiet -iso-level 3 -J -joliet-long -r \
    -V "G11_NVAPI_VM${VM_ID}" -o "$ISO_WORK" "$PUBLISHED"
[[ -s "$ISO_WORK" && ! -L "$ISO_WORK" ]] || die 'ISO build failed'
ISO_SHA256=$(sha256_upper "$ISO_WORK")
mv -T -- "$PUBLISHED" "$OUTPUT_DIR"
mv -- "$ISO_WORK" "$OUTPUT_ISO"
chmod 0700 "$OUTPUT_DIR"
chmod 0600 "$OUTPUT_DIR"/* "$OUTPUT_ISO"
rm -rf -- "$work"
work=""
printf -v MOUNT_COMMAND '%q ' ./deploy/scripts/vmctl.sh cdrom "$VM_ID" mount "$OUTPUT_ISO"
MOUNT_COMMAND=${MOUNT_COMMAND% }

cat <<EOF
[system-nvapi-package] PASS
  VM:              vm${VM_ID} / ${VM_UUID}
  profile:         ${GPU_PROFILE}
  board:           ${GPU_BOARD_BRAND} ${GPU_BOARD_MODEL}
  VRAM identity:   ${GPU_MEMORY_TYPE} / ${GPU_MEMORY_MAKER} (NVAPI ${GPU_MEMORY_MAKER_NVAPI_NAME}=${GPU_MEMORY_MAKER_NVAPI})
  NVAPI capability: RT cores=${GPU_RAY_TRACING_CORES} / Tensor cores=${GPU_TENSOR_CORES}
  D3D12 target:    raytracing tier=${GPU_D3D12_RAYTRACING_TIER} (native x86/x64 audit; transport may expose more)
  monitor:         ${MONITOR_DISPLAY_NAME} / ${MONITOR_VENDOR}${MONITOR_PRODUCT_ID#0x}
  transport:       ${TRANSPORT_KIND} / ${TARGET_PNP} / ${DRIVER_VERSION}
  contract:        ${CONTRACT_ID}
  directory:       ${OUTPUT_DIR}
  read-only ISO:   ${OUTPUT_ISO}
  ISO SHA256:      ${ISO_SHA256}

VM 生命周期：默认产物位于 vm${VM_ID}/packages，delete-vm 删除该 VM 时会一并清理。

傻瓜步骤：
  1. 宿主在仓库根目录执行（命令强制只读挂载）：
     ${MOUNT_COMMAND}
  2. 双击 Run-As-Administrator.cmd，确认一次 UAC。
  3. 写入前先审计原生 x86/x64 D3D12；无法查询时才停止，能力高于目标时会显示警告并继续。
  4. 打开设备管理器；监视器应为 ${MONITOR_DISPLAY_NAME}。
  5. 打开多个硬件工具重新扫描；显卡厂商/显存厂家应为 ${GPU_BOARD_BRAND} / ${GPU_MEMORY_MAKER}，NVAPI RT/Tensor 应为 ${GPU_RAY_TRACING_CORES}/${GPU_TENSOR_CORES}。
     原生 D3D12 是否显示光追由签名 vGPU transport 决定；脚本会如实警告，不会伪造该结果或安装应用专用 DLL。
  6. 需要恢复时双击 Rollback-As-Administrator.cmd。
  7. 用完后宿主执行：./deploy/scripts/vmctl.sh cdrom ${VM_ID} eject

不写 BCD，不开启 testsigning/nointegritychecks，不改 INF/CAT/SYS，不安装内核驱动。
EOF

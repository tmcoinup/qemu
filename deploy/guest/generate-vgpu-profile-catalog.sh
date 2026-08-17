#!/usr/bin/env bash
# Generate the guest-readable schema-2 identity catalog from the host catalog.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
# shellcheck source=../lib/vgpu-profiles.sh
source "$repo_root/deploy/lib/vgpu-profiles.sh"

output="$here/vgpu-profile-catalog.json"
check_only=0
case "${1:-}" in
    '') ;;
    --check) check_only=1 ;;
    *)
        echo "usage: $0 [--check]" >&2
        exit 2
        ;;
esac

vgpu_profile_validate_catalog
catalog_sha256=$(vgpu_profile_catalog_sha256)
profiles='[]'
while IFS= read -r profile_key; do
    vgpu_profile_load "$profile_key"
    row=$(jq -cn \
        --arg profile "$GPU_PROFILE" \
        --arg name "$GPU_NAME" \
        --arg boardBrand "$GPU_BOARD_BRAND" \
        --arg boardModel "$GPU_BOARD_MODEL" \
        --arg boardIdentity "$GPU_BOARD_IDENTITY" \
        --arg serialPolicy "$GPU_SERIAL_POLICY" \
        --arg identityScope "$GPU_IDENTITY_SCOPE" \
        --arg expectedPnpId 'PCI\VEN_10DE&DEV_1E30' \
        --arg memoryTypeName "$GPU_MEMORY_TYPE" \
        --arg memoryMakerName "$GPU_MEMORY_MAKER" \
        --arg memoryMakerNvapiName "$GPU_MEMORY_MAKER_NVAPI_NAME" \
        --arg vbiosVersion "${GPU_VBIOS#Version }" \
        --argjson nvapiPciVendorId "$((GPU_PCI_VID))" \
        --argjson nvapiPciDeviceId "$((GPU_PCI_DID))" \
        --argjson nvapiPciSubVendorId "$((GPU_SUB_VID))" \
        --argjson nvapiPciSubDeviceId "$((GPU_SUB_DID))" \
        --argjson nvapiPciRevisionId "$((GPU_REV))" \
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
        --argjson ropCount "$GPU_ROP_COUNT" \
        --argjson tmuCount "$GPU_TMU_COUNT" \
        --argjson architecture "$((GPU_ARCHITECTURE))" \
        --argjson implementation "$GPU_IMPLEMENTATION" \
        --argjson chipRevision "$((GPU_CHIP_REVISION))" \
        --argjson pcieWidth "$GPU_PCIE_WIDTH" '
        {
            profile: $profile,
            name: $name,
            boardBrand: $boardBrand,
            boardModel: $boardModel,
            boardIdentity: $boardIdentity,
            serialPolicy: $serialPolicy,
            identityScope: $identityScope,
            expectedPnpId: $expectedPnpId,
            nvapiPciVendorId: $nvapiPciVendorId,
            nvapiPciDeviceId: $nvapiPciDeviceId,
            nvapiPciSubVendorId: $nvapiPciSubVendorId,
            nvapiPciSubDeviceId: $nvapiPciSubDeviceId,
            nvapiPciRevisionId: $nvapiPciRevisionId,
            coreClockMHz: $coreClockMHz,
            boostClockMHz: $boostClockMHz,
            memoryClockMHz: $memoryClockMHz,
            memoryBusBits: $memoryBusBits,
            memoryBandwidthMBps: $memoryBandwidthMBps,
            vramMB: $vramMB,
            memoryType: $memoryType,
            memoryTypeName: $memoryTypeName,
            memoryMaker: $memoryMaker,
            memoryMakerName: $memoryMakerName,
            memoryMakerNvapiName: $memoryMakerNvapiName,
            cudaCores: $cudaCores,
            shaderSubPipes: $shaderSubPipes,
            ropCount: $ropCount,
            tmuCount: $tmuCount,
            architecture: $architecture,
            implementation: $implementation,
            chipRevision: $chipRevision,
            pcieWidth: $pcieWidth,
            vbiosVersion: $vbiosVersion
        }')
    profiles=$(jq -cn --argjson profiles "$profiles" --argjson row "$row" \
        '$profiles + [$row]')
done < <(vgpu_profile_keys)

tmp=$(mktemp "$here/.vgpu-profile-catalog.XXXXXXXX")
trap 'rm -f -- "$tmp"' EXIT
jq -S -n \
    --argjson schemaVersion "$VGPU_PROFILE_CATALOG_SCHEMA" \
    --arg catalogSha256 "$catalog_sha256" \
    --arg identityMode protected-user-mode \
    --arg transportPnpId 'PCI\VEN_10DE&DEV_1E30' \
    --argjson profiles "$profiles" '
    {
        schemaVersion: $schemaVersion,
        catalogSha256: $catalogSha256,
        identityMode: $identityMode,
        transportPnpId: $transportPnpId,
        profiles: $profiles
    }' >"$tmp"

if ((check_only)); then
    cmp -s -- "$tmp" "$output" || {
        echo "stale generated guest catalog: $output" >&2
        exit 1
    }
else
    chmod 0644 "$tmp"
    mv -fT -- "$tmp" "$output"
    trap - EXIT
fi

#!/usr/bin/env bash
# Stage a per-VM, whitelist-only identity profile for the Windows guest.
# The generated JSON is consumed by guest/apply-vm-profile.ps1; the complete
# vm.conf is never exposed by the HTTP staging server.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
# shellcheck source=lib/monitor-profiles.sh
source "$here/lib/monitor-profiles.sh"

usage() {
    cat >&2 <<'EOF'
usage: ./deploy/stage-vm-profile.sh VM_ID [options]

Options:
  --host-ip IP              URL advertised to the guest (default: br0 IPv4)
  --port PORT               HTTP port (default: 8080)
  --transfer-dir DIR        publish an HTTP-free bundle to DIR/vmN
  --online-monitor-rescue   also run the one-shot online monitor repair
  --serve                   serve staging in the foreground after preparation

Preferred HTTP-free RDP drive transfer:
  ./deploy/stage-vm-profile.sh 2 --transfer-dir /tmp/nv-transfer
  ./deploy/rdp-vm.sh 2

Legacy one-shot HTTP staging:
  ./deploy/stage-vm-profile.sh 2 --serve
EOF
}

VM_ID=""
HOST_IP=""
PORT=8080
TRANSFER_DIR=""
ONLINE_MONITOR_RESCUE=0
SERVE=0

while (( $# > 0 )); do
    case "$1" in
        --host-ip)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            HOST_IP=$2
            shift 2
            ;;
        --port)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            PORT=$2
            shift 2
            ;;
        --transfer-dir)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            TRANSFER_DIR=$2
            shift 2
            ;;
        --online-monitor-rescue)
            ONLINE_MONITOR_RESCUE=1
            shift
            ;;
        --serve)
            SERVE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        [1-9]|[1-9][0-9]*)
            [[ -z "$VM_ID" ]] || { usage; exit 2; }
            VM_ID=$1
            shift
            ;;
        *)
            echo "[stage-vm-profile] 未知参数: $1" >&2
            usage
            exit 2
            ;;
    esac
done

[[ -n "$VM_ID" ]] || { usage; exit 2; }
[[ ${#VM_ID} -lt 10 ||
   ( ${#VM_ID} -eq 10 && "$VM_ID" < 2147483648 ) ]] || {
    echo "[stage-vm-profile] VM_ID 超出 guest 支持范围: $VM_ID" >&2
    exit 2
}
[[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( PORT <= 65535 )) || {
    echo "[stage-vm-profile] 非法端口: $PORT" >&2
    exit 2
}
if [[ -n "$TRANSFER_DIR" ]]; then
    [[ "$TRANSFER_DIR" == /* && "$TRANSFER_DIR" != / ]] || {
        echo "[stage-vm-profile] --transfer-dir 必须是非根目录的绝对路径: $TRANSFER_DIR" >&2
        exit 2
    }
    (( SERVE == 0 )) || {
        echo "[stage-vm-profile] --transfer-dir 与 --serve 不能同时使用" >&2
        exit 2
    }
fi
for dependency in jq sha256sum flock mktemp; do
    command -v "$dependency" >/dev/null 2>&1 || {
        echo "[stage-vm-profile] 缺少 $dependency" >&2
        exit 1
    }
done

fail_config() {
    echo "[stage-vm-profile] $*" >&2
    exit 1
}

normalize_ascii_string() {
    local value=$1 maximum=$2 name=$3 normalized
    normalized=$(jq -nr --arg value "$value" \
        '$value | sub("^\\s+"; "") | sub("\\s+$"; "")') || return
    jq -ne --arg value "$normalized" --argjson maximum "$maximum" '
        ($value | explode) as $codepoints |
        ($codepoints | length) >= 1 and
        ($codepoints | length) <= $maximum and
        all($codepoints[]; . >= 32 and . <= 126)
    ' >/dev/null || fail_config "$name 必须是 1..${maximum} 个 ASCII 可打印字符"
    printf '%s\n' "$normalized"
}

validate_positive_int() {
    local name=$1 value=$2 minimum=$3 maximum=$4
    [[ "$value" =~ ^[1-9][0-9]*$ && ${#value} -le 10 ]] || \
        fail_config "$name 必须是 ${minimum}..${maximum} 的十进制整数: $value"
    (( value >= minimum && value <= maximum )) || \
        fail_config "$name 超出范围 ${minimum}..${maximum}: $value"
}

validate_hex_word() {
    local name=$1 value=$2 minimum=$3
    [[ "$value" =~ ^0x[0-9A-Fa-f]{1,4}$ ]] || \
        fail_config "$name 必须是 0x0000..0xFFFF 的十六进制整数: $value"
    (( value >= minimum )) || \
        fail_config "$name 必须不小于 0x$(printf '%X' "$minimum"): $value"
}

valid_ipv4() {
    local address=$1 octet
    local -a octets=()
    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<<"$address"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
        # Reject ambiguous leading-zero forms as well as values above 255.
        [[ "$octet" == 0 || "$octet" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

sha256_file() {
    sha256sum "$1" | awk '{print toupper($1)}'
}

vm_storage_init
CONF=$(vm_storage_config_path "$VM_ID")
[[ -r "$CONF" ]] || {
    echo "[stage-vm-profile] 配置不存在: $CONF" >&2
    exit 1
}

# shellcheck source=/dev/null
source "$CONF"
configured_spoof_mode=${SPOOF_MODE:-}
configured_gpu_profile=${GPU_PROFILE:-}
configured_mdev_profile=${VGPU_MDEV_PROFILE:-}
configured_gpu_name=${GPU_NAME:-}
configured_gpu_core_mhz=${GPU_CORE_MHZ:-}
configured_gpu_boost_mhz=${GPU_BOOST_MHZ:-}
configured_gpu_memory_mhz=${GPU_MEMORY_MHZ:-}
configured_gpu_memory_bus_bits=${GPU_MEMORY_BUS_BITS:-}
configured_gpu_memory_bandwidth_mbps=${GPU_MEMORY_BANDWIDTH_MBPS:-}
configured_gpu_vram_mb=${GPU_VRAM_MB:-}
configured_gpu_vbios=${GPU_VBIOS:-}
configured_gpu_memory_type_nvapi=${GPU_MEMORY_TYPE_NVAPI:-}
configured_gpu_memory_maker_nvapi=${GPU_MEMORY_MAKER_NVAPI:-}
configured_gpu_cuda_cores=${GPU_CUDA_CORES:-}
configured_gpu_shader_subpipes=${GPU_SHADER_SUBPIPES:-}
configured_gpu_rop_count=${GPU_ROP_COUNT:-}
configured_gpu_tmu_count=${GPU_TMU_COUNT:-}
configured_gpu_architecture=${GPU_ARCHITECTURE:-}
configured_gpu_implementation=${GPU_IMPLEMENTATION:-}
configured_gpu_chip_revision=${GPU_CHIP_REVISION:-}
configured_gpu_pcie_width=${GPU_PCIE_WIDTH:-}
configured_monitor_profile=${MONITOR_PROFILE:-}
configured_monitor_serial=${MONITOR_SERIAL:-}
configured_vm_uuid=${VM_UUID:-}

[[ "$configured_spoof_mode" == B ]] || \
    fail_config "SPOOF_MODE 必须在 vm.conf 中显式设为 B（当前: ${configured_spoof_mode:-<缺失>}）"

vgpu_profile_validate_catalog
monitor_profiles_validate
vgpu_profile_load "$configured_gpu_profile"
# vm.conf is the per-instance source of truth.  The catalog validates the key
# and supplies backward-compatible defaults for older configs, but explicit
# persisted name/spec fields must not be silently replaced by catalog values.
GPU_NAME=${configured_gpu_name:-$GPU_NAME}
GPU_CORE_MHZ=${configured_gpu_core_mhz:-$GPU_CORE_MHZ}
GPU_BOOST_MHZ=${configured_gpu_boost_mhz:-$GPU_BOOST_MHZ}
GPU_MEMORY_MHZ=${configured_gpu_memory_mhz:-$GPU_MEMORY_MHZ}
GPU_MEMORY_BUS_BITS=${configured_gpu_memory_bus_bits:-$GPU_MEMORY_BUS_BITS}
GPU_MEMORY_BANDWIDTH_MBPS=${configured_gpu_memory_bandwidth_mbps:-$GPU_MEMORY_BANDWIDTH_MBPS}
GPU_VRAM_MB=${configured_gpu_vram_mb:-$GPU_VRAM_MB}
GPU_VBIOS=${configured_gpu_vbios:-$GPU_VBIOS}
GPU_MEMORY_TYPE_NVAPI=${configured_gpu_memory_type_nvapi:-$GPU_MEMORY_TYPE_NVAPI}
GPU_MEMORY_MAKER_NVAPI=${configured_gpu_memory_maker_nvapi:-$GPU_MEMORY_MAKER_NVAPI}
GPU_CUDA_CORES=${configured_gpu_cuda_cores:-$GPU_CUDA_CORES}
GPU_SHADER_SUBPIPES=${configured_gpu_shader_subpipes:-$GPU_SHADER_SUBPIPES}
GPU_ROP_COUNT=${configured_gpu_rop_count:-$GPU_ROP_COUNT}
GPU_TMU_COUNT=${configured_gpu_tmu_count:-$GPU_TMU_COUNT}
GPU_ARCHITECTURE=${configured_gpu_architecture:-$GPU_ARCHITECTURE}
GPU_IMPLEMENTATION=${configured_gpu_implementation:-$GPU_IMPLEMENTATION}
GPU_CHIP_REVISION=${configured_gpu_chip_revision:-$GPU_CHIP_REVISION}
GPU_PCIE_WIDTH=${configured_gpu_pcie_width:-$GPU_PCIE_WIDTH}
if [[ -n "$configured_mdev_profile" && "$configured_mdev_profile" != nvidia-257 ]]; then
    fail_config "VGPU_MDEV_PROFILE 在 B 模式下必须为 nvidia-257: $configured_mdev_profile"
fi
VGPU_MDEV_PROFILE=${configured_mdev_profile:-$VGPU_MDEV_PROFILE}
[[ "$VGPU_MDEV_PROFILE" == nvidia-257 ]] || \
    fail_config "catalog 的 B 模式 mdev profile 必须为 nvidia-257: $VGPU_MDEV_PROFILE"
monitor_profile_load "$configured_monitor_profile"
MONITOR_SERIAL=$configured_monitor_serial

# R535 vgpu_unlock stores vgpu_name in a 32-byte buffer including NUL.  Keep
# the guest profile on the same boundary as the host per-mdev identity.
GPU_NAME=$(normalize_ascii_string "$GPU_NAME" 31 GPU_NAME)
MONITOR_DISPLAY_NAME=$(normalize_ascii_string \
    "$MONITOR_DISPLAY_NAME" 128 MONITOR_DISPLAY_NAME)
[[ "$MONITOR_SERIAL" =~ ^[A-Z0-9]{1,12}$ ]] || {
    echo "[stage-vm-profile] MONITOR_SERIAL 非法: $MONITOR_SERIAL" >&2
    exit 1
}
[[ "$configured_vm_uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
    echo "[stage-vm-profile] VM_UUID 非法: $configured_vm_uuid" >&2
    exit 1
}
validate_positive_int GPU_CORE_MHZ "$GPU_CORE_MHZ" 1 10000
validate_positive_int GPU_BOOST_MHZ "$GPU_BOOST_MHZ" 1 10000
validate_positive_int GPU_MEMORY_MHZ "$GPU_MEMORY_MHZ" 1 10000
validate_positive_int GPU_MEMORY_BUS_BITS "$GPU_MEMORY_BUS_BITS" 1 1024
validate_positive_int GPU_MEMORY_BANDWIDTH_MBPS \
    "$GPU_MEMORY_BANDWIDTH_MBPS" 1 1000000
validate_positive_int GPU_VRAM_MB "$GPU_VRAM_MB" 2048 2048
validate_positive_int GPU_MEMORY_TYPE_NVAPI "$GPU_MEMORY_TYPE_NVAPI" 8 8
validate_positive_int GPU_MEMORY_MAKER_NVAPI "$GPU_MEMORY_MAKER_NVAPI" 1 255
validate_positive_int GPU_CUDA_CORES "$GPU_CUDA_CORES" 1 1000000
validate_positive_int GPU_SHADER_SUBPIPES "$GPU_SHADER_SUBPIPES" 1 65535
validate_positive_int GPU_ROP_COUNT "$GPU_ROP_COUNT" 1 65535
validate_positive_int GPU_TMU_COUNT "$GPU_TMU_COUNT" 1 1000000
validate_hex_word GPU_ARCHITECTURE "$GPU_ARCHITECTURE" 1
validate_positive_int GPU_IMPLEMENTATION "$GPU_IMPLEMENTATION" 1 65535
validate_hex_word GPU_CHIP_REVISION "$GPU_CHIP_REVISION" 0
validate_positive_int GPU_PCIE_WIDTH "$GPU_PCIE_WIDTH" 1 32
(( GPU_BOOST_MHZ >= GPU_CORE_MHZ )) || \
    fail_config "GPU_BOOST_MHZ 不能低于 GPU_CORE_MHZ"
(( GPU_TMU_COUNT == GPU_SHADER_SUBPIPES * 8 )) || \
    fail_config "GPU_TMU_COUNT 必须等于 GPU_SHADER_SUBPIPES * 8"
case "$GPU_PCIE_WIDTH" in
    1|2|4|8|16|32) ;;
    *) fail_config "GPU_PCIE_WIDTH 必须是 1/2/4/8/16/32" ;;
esac
# The current catalog is deliberately GDDR5-only.  GPU-Z 2.70 renders half
# of the raw NVAPI memory-domain clock, so display MHz -> raw kHz is *2000.
# Reject inconsistent per-VM overrides instead of publishing a mixed profile.
GPU_MEMORY_RAW_KHZ=$((GPU_MEMORY_MHZ * 2000))
GPU_DERIVED_BANDWIDTH_MBPS=$(( \
    GPU_MEMORY_RAW_KHZ * 2 * GPU_MEMORY_BUS_BITS / 8000 \
))
GPU_BANDWIDTH_DIFFERENCE=$(( \
    GPU_DERIVED_BANDWIDTH_MBPS - GPU_MEMORY_BANDWIDTH_MBPS \
))
(( GPU_BANDWIDTH_DIFFERENCE >= 0 )) || \
    GPU_BANDWIDTH_DIFFERENCE=$((-GPU_BANDWIDTH_DIFFERENCE))
(( GPU_BANDWIDTH_DIFFERENCE * 100 <= GPU_MEMORY_BANDWIDTH_MBPS )) || \
    fail_config "GPU memory clock/bus/bandwidth 不一致（GDDR5 容差 1%，推导 ${GPU_DERIVED_BANDWIDTH_MBPS} MB/s）"
[[ "$GPU_VBIOS" == 'Version '* ]] || \
    fail_config "GPU_VBIOS 必须以 'Version ' 开头: $GPU_VBIOS"
GPU_VBIOS_VERSION=${GPU_VBIOS#Version }
[[ "$GPU_VBIOS_VERSION" =~ ^[0-9A-Fa-f]{2}(\.[0-9A-Fa-f]{2}){4}$ ]] || \
    fail_config "GPU_VBIOS 必须包含五段十六进制版本号: $GPU_VBIOS"
GPU_ARCHITECTURE_DECIMAL=$((GPU_ARCHITECTURE))
GPU_CHIP_REVISION_DECIMAL=$((GPU_CHIP_REVISION))
GPU_PCI_VID_DECIMAL=$((GPU_PCI_VID))
GPU_PCI_DID_DECIMAL=$((GPU_PCI_DID))
GPU_SUB_VID_DECIMAL=$((GPU_SUB_VID))
GPU_SUB_DID_DECIMAL=$((GPU_SUB_DID))
GPU_REV_DECIMAL=$((GPU_REV))
validate_positive_int MONITOR_NATIVE_X "$MONITOR_NATIVE_X" 320 16384
validate_positive_int MONITOR_NATIVE_Y "$MONITOR_NATIVE_Y" 200 16384
validate_positive_int MONITOR_REFRESH_HZ "$MONITOR_REFRESH_HZ" 1 1000

EXPECTED_PNP_ID='PCI\VEN_10DE&DEV_1E30'

# A transferred bundle contains only local files and deliberately has no host
# address.  Preserve the existing URL behavior when --transfer-dir is absent.
if [[ -z "$TRANSFER_DIR" ]]; then
    if [[ -z "$HOST_IP" ]]; then
        HOST_IP=$(ip -4 -o addr show br0 2>/dev/null |
            awk '{print $4}' | cut -d/ -f1 | head -1)
    fi
    valid_ipv4 "$HOST_IP" || {
        echo "[stage-vm-profile] 无法确定 br0 IPv4；请传 --host-ip，或改用 --transfer-dir" >&2
        exit 1
    }
elif [[ -n "$HOST_IP" ]]; then
    echo "[stage-vm-profile] --transfer-dir 模式不接受 --host-ip" >&2
    exit 2
fi

IMAGE_ROOT=${IMAGE_ROOT:-/home/ubuntu/images}
STAGE_DIR=${STAGE_DIR:-$IMAGE_ROOT/staging}
mkdir -p "$STAGE_DIR"

assets=(apply-vm-profile.ps1 patch-grid-strings.ps1)
if (( ONLINE_MONITOR_RESCUE )); then
    assets+=(spoof-monitor.ps1)
fi
for asset in "${assets[@]}"; do
    [[ -s "$here/guest/$asset" ]] || {
        echo "[stage-vm-profile] 缺少 guest 资产: $here/guest/$asset" >&2
        exit 1
    }
done
if (( ONLINE_MONITOR_RESCUE )) && \
   [[ ! -s "$here/config/monitor-profiles.tsv" ]]; then
    echo "[stage-vm-profile] 缺少显示器目录: $here/config/monitor-profiles.tsv" >&2
    exit 1
fi

LOCK_FILE="$STAGE_DIR/.stage-vm-profile.lock"
exec {STAGE_LOCK_FD}>"$LOCK_FILE"
flock -x "$STAGE_LOCK_FD"

PUBLISH_DIR=$(mktemp -d "$STAGE_DIR/.stage-vm${VM_ID}.XXXXXXXX")
cleanup_publish() {
    [[ -n "${PUBLISH_DIR:-}" ]] && rm -rf -- "$PUBLISH_DIR"
}
trap cleanup_publish EXIT

for asset in "${assets[@]}"; do
    cp -- "$here/guest/$asset" "$PUBLISH_DIR/$asset"
    chmod 0644 "$PUBLISH_DIR/$asset"
done
if (( ONLINE_MONITOR_RESCUE )); then
    cp -- "$here/config/monitor-profiles.tsv" \
        "$PUBLISH_DIR/monitor-profiles.tsv"
    chmod 0644 "$PUBLISH_DIR/monitor-profiles.tsv"
fi

PROFILE_NAME="vm${VM_ID}-profile.json"
MANIFEST_NAME="vm${VM_ID}-manifest.json"
PROFILE_TMP="$PUBLISH_DIR/$PROFILE_NAME"
MANIFEST_TMP="$PUBLISH_DIR/$MANIFEST_NAME"
jq -n \
    --argjson schemaVersion 1 \
    --argjson vmId "$VM_ID" \
    --arg vmUuid "$configured_vm_uuid" \
    --arg spoofMode "$configured_spoof_mode" \
    --arg gpuProfile "$GPU_PROFILE" \
    --arg gpuName "$GPU_NAME" \
    --arg expectedPnpId "$EXPECTED_PNP_ID" \
    --argjson nvapiPciVendorId "$GPU_PCI_VID_DECIMAL" \
    --argjson nvapiPciDeviceId "$GPU_PCI_DID_DECIMAL" \
    --argjson nvapiPciSubVendorId "$GPU_SUB_VID_DECIMAL" \
    --argjson nvapiPciSubDeviceId "$GPU_SUB_DID_DECIMAL" \
    --argjson nvapiPciRevisionId "$GPU_REV_DECIMAL" \
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
    --argjson architecture "$GPU_ARCHITECTURE_DECIMAL" \
    --argjson implementation "$GPU_IMPLEMENTATION" \
    --argjson chipRevision "$GPU_CHIP_REVISION_DECIMAL" \
    --argjson pcieWidth "$GPU_PCIE_WIDTH" \
    --arg vbiosVersion "$GPU_VBIOS_VERSION" \
    --arg monitorProfile "$MONITOR_PROFILE" \
    --arg monitorSerial "$MONITOR_SERIAL" \
    --arg monitorDisplayName "$MONITOR_DISPLAY_NAME" \
    --argjson nativeX "$MONITOR_NATIVE_X" \
    --argjson nativeY "$MONITOR_NATIVE_Y" \
    --argjson refreshHz "$MONITOR_REFRESH_HZ" \
    '{
        schemaVersion: $schemaVersion,
        vmId: $vmId,
        vmUuid: $vmUuid,
        spoofMode: $spoofMode,
        gpu: {
            profile: $gpuProfile,
            name: $gpuName,
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
            memoryMaker: $memoryMaker,
            cudaCores: $cudaCores,
            shaderSubPipes: $shaderSubPipes,
            ropCount: $ropCount,
            tmuCount: $tmuCount,
            architecture: $architecture,
            implementation: $implementation,
            chipRevision: $chipRevision,
            pcieWidth: $pcieWidth,
            vbiosVersion: $vbiosVersion
        },
        monitor: {
            profile: $monitorProfile,
            serial: $monitorSerial,
            displayName: $monitorDisplayName,
            nativeX: $nativeX,
            nativeY: $nativeY,
            refreshHz: $refreshHz
        }
    }' >"$PROFILE_TMP"
chmod 0644 "$PROFILE_TMP"
jq -e . "$PROFILE_TMP" >/dev/null

PROFILE_SHA256=$(sha256_file "$PROFILE_TMP")
PATCH_SHA256=$(sha256_file "$PUBLISH_DIR/patch-grid-strings.ps1")
APPLY_SHA256=$(sha256_file "$PUBLISH_DIR/apply-vm-profile.ps1")
if (( ONLINE_MONITOR_RESCUE )); then
    MONITOR_SCRIPT_SHA256=$(sha256_file "$PUBLISH_DIR/spoof-monitor.ps1")
    MONITOR_CATALOG_SHA256=$(sha256_file "$PUBLISH_DIR/monitor-profiles.tsv")
    ONLINE_JSON=true
else
    MONITOR_SCRIPT_SHA256=''
    MONITOR_CATALOG_SHA256=''
    ONLINE_JSON=false
fi

jq -n \
    --argjson schemaVersion 1 \
    --argjson vmId "$VM_ID" \
    --arg profileName "$PROFILE_NAME" \
    --arg profileSha256 "$PROFILE_SHA256" \
    --arg patchName patch-grid-strings.ps1 \
    --arg patchSha256 "$PATCH_SHA256" \
    --argjson online "$ONLINE_JSON" \
    --arg monitorScriptName spoof-monitor.ps1 \
    --arg monitorScriptSha256 "$MONITOR_SCRIPT_SHA256" \
    --arg monitorCatalogName monitor-profiles.tsv \
    --arg monitorCatalogSha256 "$MONITOR_CATALOG_SHA256" '
    {
        schemaVersion: $schemaVersion,
        vmId: $vmId,
        profile: {name: $profileName, sha256: $profileSha256},
        patch: {name: $patchName, sha256: $patchSha256},
        monitorScript: (if $online then
            {name: $monitorScriptName, sha256: $monitorScriptSha256}
        else null end),
        monitorCatalog: (if $online then
            {name: $monitorCatalogName, sha256: $monitorCatalogSha256}
        else null end)
    }' >"$MANIFEST_TMP"
chmod 0644 "$MANIFEST_TMP"
jq -e . "$MANIFEST_TMP" >/dev/null
MANIFEST_SHA256=$(sha256_file "$MANIFEST_TMP")

# Each rename publishes a complete file.  The manifest is the commit point and
# is deliberately last: if publication is interrupted, a consumer either sees
# the previous valid set or rejects the mixed set by hash.
publish_order=(apply-vm-profile.ps1 patch-grid-strings.ps1)
if (( ONLINE_MONITOR_RESCUE )); then
    publish_order+=(spoof-monitor.ps1 monitor-profiles.tsv)
fi
publish_order+=("$PROFILE_NAME" "$MANIFEST_NAME")
for asset in "${publish_order[@]}"; do
    mv -fT -- "$PUBLISH_DIR/$asset" "$STAGE_DIR/$asset"
done
rmdir -- "$PUBLISH_DIR"
PUBLISH_DIR=''
trap - EXIT

PROFILE_JSON="$STAGE_DIR/$PROFILE_NAME"
MANIFEST_JSON="$STAGE_DIR/$MANIFEST_NAME"
flock -u "$STAGE_LOCK_FD"
exec {STAGE_LOCK_FD}>&-

if [[ -n "$TRANSFER_DIR" ]]; then
    BUNDLE_DIR="$TRANSFER_DIR/vm${VM_ID}"
    TRANSFER_EXTRA_ARG=""
    (( ONLINE_MONITOR_RESCUE == 0 )) || \
        TRANSFER_EXTRA_ARG=" -OnlineMonitorRescue"
    mkdir -p "$BUNDLE_DIR"
    BUNDLE_TMP=$(mktemp -d "$TRANSFER_DIR/.vm${VM_ID}-bundle.XXXXXXXX")
    cleanup_bundle() {
        [[ -n "${BUNDLE_TMP:-}" ]] && rm -rf -- "$BUNDLE_TMP"
    }
    trap cleanup_bundle EXIT

    bundle_assets=(
        apply-vm-profile.ps1
        patch-grid-strings.ps1
        "$PROFILE_NAME"
    )
    if (( ONLINE_MONITOR_RESCUE )); then
        bundle_assets+=(spoof-monitor.ps1 monitor-profiles.tsv)
    fi
    for asset in "${bundle_assets[@]}"; do
        cp -- "$STAGE_DIR/$asset" "$BUNDLE_TMP/$asset"
        chmod 0644 "$BUNDLE_TMP/$asset"
    done
    {
        printf 'vm_id=%s\n' "$VM_ID"
        printf 'profile_sha256=%s\n' "$PROFILE_SHA256"
        printf 'apply_sha256=%s\n' "$APPLY_SHA256"
        printf 'patch_sha256=%s\n' "$PATCH_SHA256"
    } >"$BUNDLE_TMP/READY"
    chmod 0644 "$BUNDLE_TMP/READY"

    # Publish complete files with READY last.  A user following the printed
    # command cannot observe a partial bundle after this process returns.
    rm -f -- "$BUNDLE_DIR/READY"
    for asset in "${bundle_assets[@]}"; do
        mv -fT -- "$BUNDLE_TMP/$asset" "$BUNDLE_DIR/$asset"
    done
    mv -fT -- "$BUNDLE_TMP/READY" "$BUNDLE_DIR/READY"
    rmdir -- "$BUNDLE_TMP"
    BUNDLE_TMP=''
    trap - EXIT

    printf '[stage-vm-profile] vm%s: %s\n' "$VM_ID" "$GPU_NAME"
    printf '[stage-vm-profile] HTTP-free bundle: %s\n' "$BUNDLE_DIR"
    printf '%s\n' '[stage-vm-profile] 用 ./deploy/rdp-vm.sh 映射默认目录后，在 guest 管理员 PowerShell 执行：'
    printf '%s\n' "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File '\\\\tsclient\\nv\\vm${VM_ID}\\apply-vm-profile.ps1' -ConfigPath '\\\\tsclient\\nv\\vm${VM_ID}\\${PROFILE_NAME}'${TRANSFER_EXTRA_ARG}"
    printf '%s\n' '[stage-vm-profile] 文件会安装到 guest 本地；重启任务不依赖 RDP、HTTP 或旧 IP。'
    exit 0
fi

BASE_URL="http://${HOST_IP}:${PORT}"
EXTRA_ARG=""
if (( ONLINE_MONITOR_RESCUE )); then
    EXTRA_ARG=" -OnlineMonitorRescue"
fi

printf '[stage-vm-profile] vm%s: %s\n' "$VM_ID" "$GPU_NAME"
printf '[stage-vm-profile] profile: %s\n' "$PROFILE_JSON"
printf '[stage-vm-profile] manifest: %s\n' "$MANIFEST_JSON"
printf '%s\n' '[stage-vm-profile] guest 管理员 PowerShell 执行：'
printf '%s\n' '  New-Item C:\nv -ItemType Directory -Force | Out-Null'
printf '%s\n' "  \$applyPath = 'C:\\nv\\apply-vm-profile.ps1'"
printf '%s\n' "  curl.exe -f '${BASE_URL}/apply-vm-profile.ps1' -o \$applyPath"
printf '%s\n' "  if ((Get-FileHash -Algorithm SHA256 -LiteralPath \$applyPath).Hash -ne '${APPLY_SHA256}') { Remove-Item -LiteralPath \$applyPath -Force -ErrorAction SilentlyContinue; throw 'apply-vm-profile.ps1 SHA256 mismatch' }"
printf '%s\n' "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File \$applyPath -ManifestUrl '${BASE_URL}/${MANIFEST_NAME}' -ManifestSha256 '${MANIFEST_SHA256}' -BaseUrl '${BASE_URL}'${EXTRA_ARG}"
printf '%s\n' '[stage-vm-profile] 本流程保持 GRID 驱动和 mdev PCI ID；只同步设备名称/规格。'

if (( SERVE )); then
    exec python3 "$here/server.py" --dir "$STAGE_DIR" --port "$PORT" \
        --bind "$HOST_IP" --no-sync
fi

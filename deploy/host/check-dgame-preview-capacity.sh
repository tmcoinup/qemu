#!/usr/bin/env bash
# Read-only sizing/preflight for the local GPU that owns DGame preview windows.
set -euo pipefail

usage() {
    cat <<'EOF'
usage: check-dgame-preview-capacity.sh [options]

Options:
  --instances N      simultaneous preview windows (default: 16)
  --source-size WxH  guest DisplaySurface size (default: 1920x1080)
  --size WxH         preview ROI size; repeatable (default: 800x600 and 1067x600)
  --rate HZ          producer frame rate (default: 60)
  --render-node PATH inspect a specific /dev/dri/renderD* node

This command does not start or stop a VM.  It reports the upper-bound pixel
traffic and validates the DRM render-node contract.  Runtime EGL/dma-buf
failure remains safe because each DGame source independently falls back to SHM.
EOF
}

INSTANCES=16
RATE=60
SOURCE_SIZE=1920x1080
RENDER_NODE=${DGAME_RENDER_NODE:-}
SIZES=()
DRM_SYSFS_ROOT=${DRM_SYSFS_ROOT:-/sys/class/drm}
DRI_DEV_ROOT=${DRI_DEV_ROOT:-/dev/dri}

validate_uint() {
    local label=$1 value=$2 min=$3 max=$4

    [[ "$value" =~ ^[0-9]+$ ]] || {
        echo "$label 必须是整数" >&2
        exit 2
    }
    ((10#$value >= min && 10#$value <= max)) || {
        echo "$label 必须在 ${min}..${max} 范围" >&2
        exit 2
    }
}

parse_size() {
    local label=$1 size=$2

    [[ "$size" =~ ^([1-9][0-9]{0,4})x([1-9][0-9]{0,4})$ ]] || {
        echo "$label 必须是 WxH: $size" >&2
        exit 2
    }
    PARSED_WIDTH=$((10#${BASH_REMATCH[1]}))
    PARSED_HEIGHT=$((10#${BASH_REMATCH[2]}))
    ((PARSED_WIDTH <= 16384 && PARSED_HEIGHT <= 16384)) || {
        echo "$label 超过 fb-shm 上限 16384x16384: $size" >&2
        exit 2
    }
}

while (($#)); do
    case "$1" in
        --instances)
            (($# >= 2)) || { usage >&2; exit 2; }
            INSTANCES=$2
            shift 2
            ;;
        --size)
            (($# >= 2)) || { usage >&2; exit 2; }
            SIZES+=("$2")
            shift 2
            ;;
        --source-size)
            (($# >= 2)) || { usage >&2; exit 2; }
            SOURCE_SIZE=$2
            shift 2
            ;;
        --rate)
            (($# >= 2)) || { usage >&2; exit 2; }
            RATE=$2
            shift 2
            ;;
        --render-node)
            (($# >= 2)) || { usage >&2; exit 2; }
            RENDER_NODE=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

validate_uint instances "$INSTANCES" 1 256
validate_uint rate "$RATE" 1 240
((${#SIZES[@]})) || SIZES=(800x600 1067x600)
parse_size source-size "$SOURCE_SIZE"
source_width=$PARSED_WIDTH
source_height=$PARSED_HEIGHT

nodes=()
for sys_node in "$DRM_SYSFS_ROOT"/renderD*; do
    [[ -d "$sys_node/device" ]] || continue
    nodes+=("$DRI_DEV_ROOT/${sys_node##*/}")
done
if [[ -z "$RENDER_NODE" ]]; then
    if ((${#nodes[@]} == 1)); then
        RENDER_NODE=${nodes[0]}
    elif ((${#nodes[@]} == 0)); then
        echo "RESULT=FAIL no DRM render node; GPU preview will use SHM" >&2
        exit 1
    else
        echo "RESULT=WARN multiple DRM render nodes: ${nodes[*]}"
        echo "Set --render-node to the SDL/GTK display GPU for an exact audit."
        RENDER_NODE=${nodes[0]}
    fi
fi

node_name=${RENDER_NODE##*/}
[[ "$node_name" =~ ^renderD[0-9]+$ ]] || {
    echo "render node 名称非法: $RENDER_NODE" >&2
    exit 2
}
sys_device="$DRM_SYSFS_ROOT/$node_name/device"
[[ -d "$sys_device" ]] || {
    echo "render node 没有对应 sysfs device: $RENDER_NODE" >&2
    exit 1
}
vendor=$(<"$sys_device/vendor")
device=$(<"$sys_device/device")
driver=$(basename "$(readlink -f "$sys_device/driver")")
if [[ -e "$RENDER_NODE" && ! -r "$RENDER_NODE" ]]; then
    echo "render node 当前用户不可读: $RENDER_NODE" >&2
    exit 1
fi

printf 'RENDER_NODE=%s\n' "$RENDER_NODE"
printf 'GPU_PCI=%s:%s\n' "${vendor#0x}" "${device#0x}"
printf 'GPU_DRIVER=%s\n' "$driver"
if [[ "$vendor" == 0x1002 && "$driver" == amdgpu ]]; then
    echo "GPU_CLASS=AMD amdgpu (RX570/RX550-compatible provider selection)"
else
    echo "GPU_CLASS=generic; verify EGL_MESA_image_dma_buf_export at runtime"
fi

source_bytes_per_second=$((
    source_width * source_height * 4 * INSTANCES * RATE
))
source_mib_per_second=$(((source_bytes_per_second + 1048575) / 1048576))
source_texture_bytes=$((source_width * source_height * 4 * INSTANCES))
source_texture_mib=$(((source_texture_bytes + 1048575) / 1048576))
printf 'SOURCE_UPLOAD size=%sx%s instances=%s rate=%s pixel_mib_s=%s texture_mib=%s\n' \
    "$source_width" "$source_height" "$INSTANCES" "$RATE" \
    "$source_mib_per_second" "$source_texture_mib"

for size in "${SIZES[@]}"; do
    parse_size size "$size"
    width=$PARSED_WIDTH
    height=$PARSED_HEIGHT
    roi_bytes_per_second=$((width * height * 4 * INSTANCES * RATE))
    roi_mib_per_second=$(((roi_bytes_per_second + 1048575) / 1048576))
    combined_bytes_per_second=$((
        source_bytes_per_second + roi_bytes_per_second
    ))
    combined_mib_per_second=$((
        (combined_bytes_per_second + 1048575) / 1048576
    ))
    # Full SDL/GTK source texture plus ROI staging and an imported-texture
    # allowance.  Actual dma-buf import shares storage, so this is conservative.
    resident_bytes=$((
        source_texture_bytes + width * height * 4 * INSTANCES * 2
    ))
    resident_mib=$(((resident_bytes + 1048575) / 1048576))
    printf 'LOAD roi=%sx%s instances=%s rate=%s roi_mib_s=%s combined_mib_s=%s texture_mib_est=%s\n' \
        "$width" "$height" "$INSTANCES" "$RATE" \
        "$roi_mib_per_second" "$combined_mib_per_second" "$resident_mib"
done

echo "RESULT=ELIGIBLE provider is ready; dynamic 16-VM soak is still required"
echo "FALLBACK=per-VM SHM remains available after EGL/dma-buf failure"

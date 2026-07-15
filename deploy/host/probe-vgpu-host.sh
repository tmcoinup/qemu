#!/usr/bin/env bash
# Read-only mdev/vGPU host probe.  It never creates an mdev or writes sysfs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy_dir="$(cd "$here/.." && pwd)"

config_was_set=0
[[ -v VGPU_HOST_CONFIG ]] && config_was_set=1
VGPU_HOST_CONFIG="${VGPU_HOST_CONFIG:-$here/vgpu-host.conf}"
profile_arg=""

usage() {
    cat <<'EOF'
usage: probe-vgpu-host.sh [--config FILE] [--profile NAME]

Lists every mdev type exposed by the selected/auto-detected GPU parent and
validates the configured VGPU_RESOURCE_PROFILE without writing host state.
EOF
}

while (($#)); do
    case "$1" in
        --config)
            [[ $# -ge 2 ]] || { echo '--config requires a file' >&2; exit 2; }
            VGPU_HOST_CONFIG=$2
            config_was_set=1
            shift 2
            ;;
        --profile)
            [[ $# -ge 2 ]] || { echo '--profile requires a name' >&2; exit 2; }
            profile_arg=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            echo "unknown option: $1" >&2
            exit 2
            ;;
    esac
done

if [[ -r "$VGPU_HOST_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$VGPU_HOST_CONFIG"
elif ((config_was_set)); then
    echo "VGPU_HOST_CONFIG does not exist or is unreadable: $VGPU_HOST_CONFIG" >&2
    exit 1
fi

# shellcheck source=../lib/vgpu-mdev.sh
source "$deploy_dir/lib/vgpu-mdev.sh"

roots_output=$(mdev_type_roots)
mapfile -t roots <<<"$roots_output"

printf 'NVIDIA module : %s\n' \
    "$(cat "$NVIDIA_MODULE_VERSION_FILE" 2>/dev/null || echo not-loaded)"
printf 'GPU selector  : %s\n' "$VGPU_MGPU"
printf 'Capacity cap  : %s MB (%s)\n' "$VGPU_TOTAL_FB_MB" "$VGPU_CAPACITY_CHECK"

for root in "${roots[@]}"; do
    parent=$(readlink -f "$(dirname "$root")")
    bdf=$(basename "$parent")
    vendor=$(cat "$parent/vendor" 2>/dev/null || echo unknown)
    device=$(cat "$parent/device" 2>/dev/null || echo unknown)
    driver_path=$(readlink -f "$parent/driver" 2>/dev/null || true)
    iommu_path=$(readlink -f "$parent/iommu_group" 2>/dev/null || true)
    driver=${driver_path:+$(basename "$driver_path")}
    iommu_group=${iommu_path:+$(basename "$iommu_path")}
    pci_label=$(lspci -s "$bdf" 2>/dev/null || true)

    printf '\nparent %s  vendor:device=%s:%s  driver=%s  iommu_group=%s\n' \
        "$bdf" "${vendor#0x}" "${device#0x}" "${driver:-none}" \
        "${iommu_group:-none}"
    [[ -n "$pci_label" ]] && printf '  %s\n' "$pci_label"
    printf '  %-12s %-28s %10s %10s %s\n' \
        TYPE NAME FB_MB AVAILABLE API

    for type_dir in "$root"/*; do
        [[ -d "$type_dir" ]] || continue
        name=$(cat "$type_dir/name" 2>/dev/null || echo unknown)
        fb=$(mdev_type_framebuffer_mb "$type_dir" 2>/dev/null || echo unknown)
        available=$(cat "$type_dir/available_instances" 2>/dev/null || echo unknown)
        device_api=$(cat "$type_dir/device_api" 2>/dev/null || echo unknown)
        printf '  %-12s %-28s %10s %10s %s\n' \
            "$(basename "$type_dir")" "$name" "$fb" "$available" "$device_api"
    done
done

profile=${profile_arg:-${VGPU_RESOURCE_PROFILE:-}}
if [[ -n "$profile" ]]; then
    selected=$(mdev_find_type "$profile")
    mdev_validate_type_parent "$selected"
    selected_fb=$(mdev_type_framebuffer_mb "$selected")
    selected_available=$(cat "$selected/available_instances")

    if [[ -n "${VGPU_RESOURCE_FB_MB:-}" &&
          "$selected_fb" != "$VGPU_RESOURCE_FB_MB" ]]; then
        echo "selected profile framebuffer mismatch: sysfs=${selected_fb}MB config=${VGPU_RESOURCE_FB_MB}MB" >&2
        exit 1
    fi
    printf '\nselected      : %s (%s, %s MB, available=%s)\n' \
        "$selected" "$(cat "$selected/name")" "$selected_fb" \
        "$selected_available"
fi

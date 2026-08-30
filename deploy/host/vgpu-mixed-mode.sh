#!/usr/bin/env bash
# Keep the official R580 V100 heterogeneous time-slice mode enabled.
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly NVIDIA_SMI=/usr/bin/nvidia-smi
readonly HOST_LOCK=/opt/nvidia-modes/state/current
readonly LOCK_WAIT_SECONDS=30

die() {
    echo "[vgpu-mixed-mode] $*" >&2
    exit 1
}

usage() {
    echo "usage: $0 apply|status DDDD:BB:SS.F" >&2
    exit 2
}

(( EUID == 0 )) || die "must run as root"
(( $# == 2 )) || usage
action=$1
bdf=${2,,}
[[ "$action" == apply || "$action" == status ]] || usage
[[ "$bdf" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || usage

gpu_sysfs="/sys/bus/pci/devices/$bdf"
[[ -d "$gpu_sysfs" && ! -L "$gpu_sysfs/vendor" ]] || \
    die "GPU sysfs path is missing or unsafe: $bdf"
[[ "$(tr 'A-F' 'a-f' <"$gpu_sysfs/vendor")" == 0x10de ]] || \
    die "$bdf is not an NVIDIA device"
device_id=$(tr 'A-F' 'a-f' <"$gpu_sysfs/device")
device_id=${device_id#0x}
[[ "$device_id" =~ ^(1db[1-8]|1df[56])$ ]] || \
    die "$bdf is not a reviewed Tesla V100 device (10de:$device_id)"

driver_version=$(cat /sys/module/nvidia/version 2>/dev/null || true)
case "$driver_version" in
    580.159.01) ;;
    *)
        die "mixed-size is restricted to validated vGPU 19.5/R580.159.01 (loaded ${driver_version:-none})"
        ;;
esac
[[ -x "$NVIDIA_SMI" && ! -L "$NVIDIA_SMI" ]] || \
    die "trusted nvidia-smi is missing: $NVIDIA_SMI"

install -d -o root -g root -m 0755 "${HOST_LOCK%/*}"
if [[ ! -e "$HOST_LOCK" ]]; then
    printf 'unknown\n' >"$HOST_LOCK"
fi
[[ -f "$HOST_LOCK" && ! -L "$HOST_LOCK" ]] || \
    die "host lock is not a regular file: $HOST_LOCK"
chown root:root "$HOST_LOCK"
chmod 0644 "$HOST_LOCK"
exec {HOST_LOCK_FD}<>"$HOST_LOCK"
flock -x -w "$LOCK_WAIT_SECONDS" "$HOST_LOCK_FD" || \
    die "timed out waiting for the host vGPU lock"

query_state() {
    local query
    query=$($NVIDIA_SMI -q -i "$bdf" 2>/dev/null) || \
        die "cannot query vGPU capability for $bdf"
    mixed_capability=$(awk -F: '
        /Heterogeneous Time-Slice Sizes/ {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' <<<"$query")
    mixed_mode=$(awk -F: '
        /vGPU Heterogeneous Mode/ {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' <<<"$query")
    [[ "$mixed_capability" == Supported ]] || \
        die "$bdf does not report heterogeneous time-slice size support"
    [[ "$mixed_mode" == Enabled || "$mixed_mode" == Disabled ]] || \
        die "$bdf returned an unknown heterogeneous mode: ${mixed_mode:-missing}"
}

target_has_active_mdev() {
    local mdev type_path
    shopt -s nullglob
    for mdev in /sys/bus/mdev/devices/*; do
        [[ -d "$mdev" ]] || continue
        type_path=$(readlink -f "$mdev/mdev_type" 2>/dev/null || true)
        [[ "$type_path" == "$gpu_sysfs/mdev_supported_types/"* ]] && return 0
    done
    shopt -u nullglob
    return 1
}

query_state
if [[ "$action" == status ]]; then
    [[ "$mixed_mode" == Enabled ]] || \
        die "$bdf heterogeneous mode is disabled"
    echo "[vgpu-mixed-mode] $bdf R$driver_version capability=$mixed_capability mode=$mixed_mode"
    exit 0
fi

if [[ "$mixed_mode" == Enabled ]]; then
    echo "[vgpu-mixed-mode] $bdf is already enabled"
    exit 0
fi
target_has_active_mdev && \
    die "refusing to change framebuffer mode while $bdf has active mdev devices"

$NVIDIA_SMI vgpu -i "$bdf" -shm 1
query_state
[[ "$mixed_mode" == Enabled ]] || \
    die "$bdf did not enter heterogeneous mode after nvidia-smi returned"
echo "[vgpu-mixed-mode] enabled $bdf heterogeneous 1Q/2Q mode"

#!/usr/bin/env bash
# Persist a real monitor profile and refresh Windows' EDID cache while the VM
# is stopped.  Nothing is installed or scheduled inside the guest.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/monitor-profiles.sh
source "$here/lib/monitor-profiles.sh"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
monitor_profiles_validate
vm_storage_init

usage() {
    echo "usage: $0 <vm_id> [--monitor PROFILE] [--force]" >&2
    echo "       $0 --list-monitor-profiles" >&2
}

VM_ID=""
MONITOR_REQUEST=""
FORCE=0
while (( $# > 0 )); do
    case "$1" in
        --monitor|--monitor-profile)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            MONITOR_REQUEST=$2
            shift 2
            ;;
        --force) FORCE=1; shift ;;
        --list-monitor-profiles)
            monitor_profile_print_catalog
            exit 0
            ;;
        -h|--help) usage; exit 0 ;;
        [1-9]|[1-9][0-9]*)
            [[ -z "$VM_ID" ]] || { usage; exit 2; }
            VM_ID=$1
            shift
            ;;
        *) echo "未知参数: $1" >&2; usage; exit 2 ;;
    esac
done
[[ -n "$VM_ID" ]] || { usage; exit 2; }

mkdir -p "$VM_RUN_DIR"
exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -s "$STORAGE_LOCK_FD"
vm_storage_prepare
vm_storage_prepare_instance "$VM_ID"

if [[ "${VM_START_LOCK_HELD:-0}" != 1 ]]; then
    START_LOCK=$(vm_storage_run_path "$VM_ID" start.lock)
    exec {START_LOCK_FD}>"$START_LOCK"
    if ! flock -n "$START_LOCK_FD"; then
        echo "[monitor-sync] vm${VM_ID} 正在启动或运行，拒绝离线挂载磁盘" >&2
        exit 1
    fi
fi

CONF=$(vm_storage_config_path "$VM_ID")
DISK=$(vm_storage_disk_path "$VM_ID")
[[ -r "$CONF" ]] || { echo "[monitor-sync] 配置不存在: $CONF" >&2; exit 1; }
[[ -f "$DISK" ]] || { echo "[monitor-sync] 磁盘不存在: $DISK" >&2; exit 1; }
if pgrep -af qemu-system-x86_64 2>/dev/null | grep -F -- "$DISK" >/dev/null; then
    echo "[monitor-sync] vm${VM_ID} 正在运行，拒绝修改配置或离线挂载" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONF"
old_profile=${MONITOR_PROFILE:-}
old_serial=${MONITOR_SERIAL:-}
monitor_profile_load "${MONITOR_REQUEST:-${old_profile:-dell-p2419h}}"

if [[ "$old_profile" == "$MONITOR_PROFILE" &&
      "$old_serial" =~ ^[A-Z0-9]{1,12}$ ]]; then
    MONITOR_SERIAL=$old_serial
else
    MONITOR_SERIAL=$(monitor_profile_generate_serial \
        "$MONITOR_SERIAL_PREFIX" "${VM_UUID:-vm${VM_ID}}-${MONITOR_PROFILE}")
fi

monitor_config_block() {
    printf '%s\n' \
        "MONITOR_PROFILE=${MONITOR_PROFILE}" \
        "MONITOR_VENDOR=${MONITOR_VENDOR}" \
        "MONITOR_PRODUCT_ID=${MONITOR_PRODUCT_ID}" \
        "MONITOR_EDID_NAME=\"${MONITOR_EDID_NAME}\"" \
        "MONITOR_DISPLAY_NAME=\"${MONITOR_DISPLAY_NAME}\"" \
        "MONITOR_MANUFACTURER=\"${MONITOR_MANUFACTURER}\"" \
        "MONITOR_BRAND_NAME=\"${MONITOR_BRAND_NAME}\"" \
        "MONITOR_MODEL_NAME=\"${MONITOR_MODEL_NAME}\"" \
        "MONITOR_WIDTH_MM=${MONITOR_WIDTH_MM}" \
        "MONITOR_HEIGHT_MM=${MONITOR_HEIGHT_MM}" \
        "MONITOR_NATIVE_X=${MONITOR_NATIVE_X}" \
        "MONITOR_NATIVE_Y=${MONITOR_NATIVE_Y}" \
        "MONITOR_REFRESH_HZ=${MONITOR_REFRESH_HZ}" \
        "MONITOR_MIN_V=${MONITOR_MIN_V}" \
        "MONITOR_MAX_V=${MONITOR_MAX_V}" \
        "MONITOR_MIN_H=${MONITOR_MIN_H}" \
        "MONITOR_MAX_H=${MONITOR_MAX_H}" \
        "MONITOR_MAX_CLOCK_MHZ=${MONITOR_MAX_CLOCK_MHZ}" \
        "MONITOR_VIDEO_INPUT=${MONITOR_VIDEO_INPUT}" \
        "MONITOR_YEAR=${MONITOR_YEAR}" \
        "MONITOR_WEEK=${MONITOR_WEEK}" \
        "MONITOR_SERIAL_PREFIX=\"${MONITOR_SERIAL_PREFIX}\"" \
        "MONITOR_MODE_SET=${MONITOR_MODE_SET}" \
        "MONITOR_SERIAL=\"${MONITOR_SERIAL}\""
}

expected_block=$(monitor_config_block)
current_block=$(sed -n '/^MONITOR_[A-Z0-9_]*=/p' "$CONF")
if [[ "$current_block" != "$expected_block" ]]; then
    tmp="$(dirname "$CONF")/.$(basename "$CONF").monitor.$$.$RANDOM"
    cleanup_tmp() { rm -f -- "$tmp"; }
    trap cleanup_tmp EXIT
    awk '!/^MONITOR_[A-Z0-9_]*=/' "$CONF" >"$tmp"
    {
        printf '\n# Real monitor identity (deploy/config/monitor-profiles.tsv).\n'
        monitor_config_block
    } >>"$tmp"
    chmod --reference="$CONF" "$tmp"
    mv -T -- "$tmp" "$CONF"
    trap - EXIT
    echo "[monitor-sync] vm.conf → ${MONITOR_PROFILE} / ${MONITOR_SERIAL}"
fi

QEMU_EDID="${QEMU_EDID:-$here/../build/qemu-edid}"
[[ -x "$QEMU_EDID" ]] || {
    echo "[monitor-sync] 缺少 $QEMU_EDID（先构建 qemu-edid）" >&2
    exit 1
}
MARKER=$(vm_storage_run_preferred_path "$VM_ID" monitor-edid)
disk_identity=$(stat -Lc '%d:%i' "$DISK") || {
    echo "[monitor-sync] 无法读取磁盘身份: $DISK" >&2
    exit 1
}
spec_hash=$({
    monitor_config_block
    # A PCI spoof/driver change can make Windows enumerate a new
    # Enum\DISPLAY instance even when the monitor profile itself is unchanged.
    # Bind the completion marker to the display parent and driver identity so
    # that the new instance gets one offline cache refresh instead of reusing a
    # stale marker from the previous GPU tuple.
    # start-vm passes its post-CLI value explicitly; direct invocations fall
    # back to the persisted vm.conf value.
    printf 'spoof_mode=%s\n' \
        "${MONITOR_SYNC_SPOOF_MODE:-${SPOOF_MODE:-B}}"
    printf 'vgpu_mdev_profile=%s\n' "${VGPU_MDEV_PROFILE:-nvidia-257}"
    printf 'gpu_pci=%s:%s\n' "${GPU_PCI_VID:-}" "${GPU_PCI_DID:-}"
    printf 'gpu_subsystem=%s:%s\n' "${GPU_SUB_VID:-}" "${GPU_SUB_DID:-}"
    printf 'patched_driver=%s:%s\n' \
        "${VGPU_PATCHED_DRIVER_INF:-}" "${VGPU_PATCHED_DRIVER_VERSION:-}"
    sha256sum "$MONITOR_PROFILE_CATALOG" "$QEMU_EDID" \
        "$here/host/sync-monitor-cache.sh"
    printf 'disk=%s:%s\n' "$(readlink -m -- "$DISK")" "$disk_identity"
    printf 'host-edid-sync-v4\n'
} | sha256sum | awk '{print $1}')

if (( ! FORCE )) && [[ -r "$MARKER" ]] && grep -qxF "$spec_hash" "$MARKER"; then
    echo "[monitor-sync] ${MONITOR_PROFILE} 已离线同步，无需改 guest"
    exit 0
fi

args=(
    "$here/host/sync-monitor-cache.sh"
    --disk "$DISK"
    --qemu-edid "$QEMU_EDID"
    --catalog "$MONITOR_PROFILE_CATALOG"
    --monitor-profile "$MONITOR_PROFILE"
    --serial "$MONITOR_SERIAL"
    --instance "vm${VM_ID}"
    --marker "$MARKER"
    --marker-value "$spec_hash"
)

if (( EUID == 0 )); then
    "${args[@]}"
elif sudo -n true 2>/dev/null; then
    sudo -- "${args[@]}"
elif [[ -n "${SUDO_PASSWORD:-}" ]]; then
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' -- "${args[@]}"
else
    echo "[monitor-sync] 离线挂载需要 sudo；请先 sudo -v 或设置 SUDO_PASSWORD" >&2
    exit 1
fi

echo "[monitor-sync] 完成：guest 内未安装脚本、服务或计划任务"

#!/usr/bin/env bash
# Persist a real monitor profile and refresh Windows' EDID cache while the VM
# is stopped.  Nothing is installed or scheduled inside the guest.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/monitor-profiles.sh
source "$here/lib/monitor-profiles.sh"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/vgpu-host-config.sh
source "$here/lib/vgpu-host-config.sh"
# shellcheck source=lib/vgpu-driver-assets.sh
source "$here/lib/vgpu-driver-assets.sh"
# shellcheck source=lib/signed-consumer-catalog.sh
source "$here/lib/signed-consumer-catalog.sh"
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
vm_storage_require_namespace_ready "$VM_ID"

vm_storage_validate_root_path "$VM_ROOT" "VM root"
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

# nvidia-256 is used by both the RTX6000-1Q unlock path and the native
# V100X-1Q/R535 path, but Windows exposes different production PnP IDs for
# them.  The safe driver-install wrapper exports the root-managed host policy
# path.  Read only its reviewed resource selector in a subshell so the host
# assignments cannot overwrite this VM's persisted identity fields.
HOST_RESOURCE_PROFILE=""
if [[ -n "${VGPU_HOST_CONFIG:-}" ]]; then
    HOST_RESOURCE_PROFILE=$(
        (
            vgpu_host_config_load "$VGPU_HOST_CONFIG" '[monitor-sync]' \
                VGPU_HOST_FB_MODE VGPU_RESOURCE_PROFILE \
                VGPU_RESOURCE_PROFILE_1024 VGPU_RESOURCE_PROFILE_2048 || exit
            case "${VGPU_HOST_FB_MODE:-equal}" in
                equal)
                    printf '%s\n' "${VGPU_RESOURCE_PROFILE:-}"
                    ;;
                mixed)
                    case "${VGPU_FB_MB:-}" in
                        1024) printf '%s\n' "${VGPU_RESOURCE_PROFILE_1024:-}" ;;
                        2048) printf '%s\n' "${VGPU_RESOURCE_PROFILE_2048:-}" ;;
                        *)
                            echo '[monitor-sync] mixed host 无法按 VM framebuffer 选择 resource profile' >&2
                            exit 2
                            ;;
                    esac
                    ;;
                *)
                    echo '[monitor-sync] VGPU_HOST_FB_MODE 必须是 equal 或 mixed' >&2
                    exit 2
                    ;;
            esac
        )
    ) || exit
fi

# Select the exact host/guest pair.  R535 uses the reviewed page-safe
# NV_Modes contract; R570 authenticates the official INF/CAT but leaves its
# private NV_Modes untouched and publishes only standard EDID state.
vgpu_select_driver_stack || exit 1
[[ "$VGPU_SELECTED_DRIVER_MONITOR_SYNC_MODE" != off &&
   -n "$VGPU_SELECTED_DRIVER_MONITOR_POLICY" &&
   "$VGPU_SELECTED_DRIVER_INF_SHA256" =~ ^[0-9a-f]{64}$ &&
   "$VGPU_SELECTED_DRIVER_CATALOG_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "[monitor-sync] ${VGPU_SELECTED_DRIVER_BRANCH:-unknown} 没有审核过的离线 monitor 策略" >&2
    exit 1
}
NATIVE_GRID_PNP_ID=$(vgpu_profile_guest_grid_pnp_id \
    "${VGPU_MDEV_PROFILE:-}" "$HOST_RESOURCE_PROFILE") || {
    echo "[monitor-sync] GPU resource 没有审核过的 guest GRID PnP 映射" >&2
    exit 1
}
MONITOR_DRIVER_POLICY=$VGPU_SELECTED_DRIVER_MONITOR_POLICY
MONITOR_DRIVER_VERSION=$VGPU_SELECTED_DRIVER_VERSION
MONITOR_DRIVER_INF_SHA256=$VGPU_SELECTED_DRIVER_INF_SHA256
MONITOR_DRIVER_CATALOG_SHA256=$VGPU_SELECTED_DRIVER_CATALOG_SHA256
MONITOR_DRIVER_PNP_ID=$NATIVE_GRID_PNP_ID

# A qualified outer-only consumer route enumerates a new Display parent and
# uses a different original NVIDIA INF. Select that audited row from the same
# canonical catalog instead of applying GRID-only private NV_Modes semantics.
if [[ "${VGPU_SIGNED_CONSUMER_STATE:-}" == validated ]]; then
    [[ "${VGPU_SIGNED_CONSUMER_PROFILE:-}" == "${GPU_PROFILE:-}" ]] || {
        echo "[monitor-sync] signed-consumer profile 与 GPU_PROFILE 不一致" >&2
        exit 1
    }
    signed_consumer_profile_assert_config \
        "$GPU_PROFILE" "$GPU_NAME" "$GPU_PCI_VID" "$GPU_PCI_DID" \
        "$GPU_SUB_VID" "$GPU_SUB_DID" "$VGPU_MDEV_PROFILE" || {
        echo "[monitor-sync] signed-consumer GPU 字段不符合 canonical profile" >&2
        exit 1
    }
    signed_consumer_driver_load "${VGPU_SIGNED_CONSUMER_DRIVER_KEY:-}" || {
        echo "[monitor-sync] signed-consumer driver key 不在审核目录" >&2
        exit 1
    }
    signed_consumer_driver_assert_production_enabled || {
        echo "[monitor-sync] signed-consumer driver 已被运行时稳定性隔离" >&2
        exit 1
    }
    signed_consumer_driver_assert_profile || {
        echo "[monitor-sync] signed-consumer driver 与 GPU profile 不匹配" >&2
        exit 1
    }
    MONITOR_DRIVER_POLICY=$SC_DRIVER_KEY
    MONITOR_DRIVER_VERSION=$SC_DRIVER_VERSION
    MONITOR_DRIVER_INF_SHA256=${SC_INF_SHA256,,}
    MONITOR_DRIVER_CATALOG_SHA256=${SC_CATALOG_SHA256,,}
    MONITOR_DRIVER_PNP_ID=$SC_CANONICAL_TARGET_PNP
fi

if [[ -n "${MONITOR_REQUEST:-}" ]]; then
    selected_monitor_profile=$MONITOR_REQUEST
elif [[ -n "$old_profile" ]]; then
    selected_monitor_profile=$old_profile
else
    echo "[monitor-sync] vm${VM_ID} 缺少 MONITOR_PROFILE；拒绝静默套用固定 Dell 身份" >&2
    echo "[monitor-sync] 请先显式运行: ./deploy/scripts/sync-monitor-profile.sh ${VM_ID} --monitor PROFILE" >&2
    exit 1
fi
monitor_profile_load "$selected_monitor_profile"

if [[ "$old_profile" == "$MONITOR_PROFILE" && -n "$old_serial" ]]; then
    monitor_profile_serial_validate "$old_serial" || {
        echo "[monitor-sync] MONITOR_SERIAL 不符合 ${MONITOR_PROFILE} 的 ${MONITOR_SERIAL_POLICY} 策略或命中证据样本保留值: $old_serial" >&2
        exit 1
    }
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
    if (( EUID == 0 )); then
        chown --reference="$CONF" "$tmp"
    fi
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
marker_file_digest() {
    local label=$1 path=$2 digest
    digest=$(sha256sum -- "$path" | awk '{print $1}') || return 1
    printf 'file.%s=%s\n' "$label" "$digest"
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
    printf 'patched_driver_required=%s\n' \
        "${VGPU_PATCHED_DRIVER_REQUIRED_VERSION:-}"
    printf 'production_migration=%s\n' "${VGPU_PRODUCTION_MIGRATION_ID:-}"
    printf 'production_driver=%s:%s:%s\n' \
        "$MONITOR_DRIVER_VERSION" "$MONITOR_DRIVER_INF_SHA256" \
        "$MONITOR_DRIVER_CATALOG_SHA256"
    printf 'production_driver_policy=%s:%s\n' \
        "$MONITOR_DRIVER_POLICY" "$MONITOR_DRIVER_PNP_ID"
    printf 'vgpu_display_contract=1:1920:1080:2073600\n'
    # Bind to content, not the absolute checkout/container path printed by
    # sha256sum. The same reviewed files must yield one marker in CLI, GUI,
    # package-maintenance containers and relocated installations.
    marker_file_digest monitor-profile-catalog "$MONITOR_PROFILE_CATALOG"
    marker_file_digest qemu-edid "$QEMU_EDID"
    marker_file_digest sync-monitor-cache "$here/host/sync-monitor-cache.sh"
    marker_file_digest nvidia-modes "$here/lib/nvidia_modes.py"
    marker_file_digest windows-hive "$here/lib/windows_hive.py"
    marker_file_digest profile-override "$here/host/profile_override.toml"
    marker_file_digest update-vgpu-mdev-identity \
        "$here/host/update-vgpu-mdev-identity.py"
    printf 'disk=%s:%s\n' "$(readlink -m -- "$DISK")" "$disk_identity"
    # v11 keeps the R535 page-safe policy and adds exact R570 EDID-only
    # authentication without importing R535 NV_Modes into the newer branch.
    printf 'host-edid-sync-v11-reviewed-stack-page-safe\n'
} | sha256sum | awk '{print $1}')

if (( ! FORCE )) && [[ -r "$MARKER" ]] && grep -qxF "$spec_hash" "$MARKER"; then
    echo "[monitor-sync] ${MONITOR_PROFILE} 的 Windows EDID_OVERRIDE/EDID/模式缓存已同步"
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
    --driver-version "$MONITOR_DRIVER_VERSION"
    --driver-inf-sha256 "$MONITOR_DRIVER_INF_SHA256"
    --driver-catalog-sha256 "$MONITOR_DRIVER_CATALOG_SHA256"
    --driver-policy "$MONITOR_DRIVER_POLICY"
    --nvidia-pnp-id "$MONITOR_DRIVER_PNP_ID"
    --marker "$MARKER"
    --marker-value "$spec_hash"
)

helper_rc=0
if (( EUID == 0 )); then
    "${args[@]}" || helper_rc=$?
elif sudo -n true 2>/dev/null; then
    sudo -- "${args[@]}" || helper_rc=$?
elif [[ -n "${SUDO_PASSWORD:-}" ]]; then
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' -- "${args[@]}" || helper_rc=$?
elif [[ -t 0 ]]; then
    echo "[monitor-sync] 正在通过当前终端安全取得临时 sudo 票据（凭据不会写入仓库或参数）"
    sudo -v
    sudo -- "${args[@]}" || helper_rc=$?
else
    echo "[monitor-sync] 非交互运行缺少 sudo 票据；请预先 sudo -v，或通过安全环境变量 SUDO_PASSWORD 提供" >&2
    exit 1
fi

case "$helper_rc" in
    0)
        echo "[monitor-sync] 完成：Windows 标准 EDID_OVERRIDE 已按 128B block 写入；设备管理器 live 名称由私有克隆的 SYSTEM 身份任务在下次启动通过 SetupAPI 发布"
        ;;
    12)
        echo "[monitor-sync] 预驱动完成：安全 EDID/模式缓存已落盘；安装 GRID 并完整关机后会自动补齐认证 NV_Modes"
        exit 12
        ;;
    *)
        exit "$helper_rc"
        ;;
esac

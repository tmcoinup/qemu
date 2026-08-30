#!/usr/bin/env bash
# create-vm.sh — 一次性生成 G-11 的 $VM_ROOT/<N>/vm.conf。
#
#   用法:  ./deploy/scripts/create-vm.sh <vm_id> [--platform PLATFORM]
#          ./deploy/scripts/create-vm.sh <vm_id> [--cpu-spec 4c8t|6c12t|--cpu-profile CPU]
#                                  [--board-profile BOARD]
#                                  [--memory-profile MEMORY|--memory-size 4G|8G|12G|16G]
#                                  [--ssd-profile PROFILE]
#                                  [--gpu-profile PROFILE|--gpu-vram 1024|2048]
#                                  [--allow-fallback-platform]
#                                  [--monitor-profile PROFILE]
#                                  [--keyboard-profile PROFILE]
#                                  [--relative-mouse [--mouse-profile PROFILE]]
#          ./deploy/scripts/create-vm.sh <vm_id> --force  # 覆盖已存在配置
#          ./deploy/scripts/create-vm.sh --list-platforms
#          ./deploy/scripts/create-vm.sh --list-archived-platforms
#          ./deploy/scripts/create-vm.sh --list-cpu-profiles|--list-board-profiles
#                         --list-memory-profiles
#          ./deploy/scripts/create-vm.sh --list-ssd-profiles
#          ./deploy/scripts/create-vm.sh --list-gpu-profiles
#          ./deploy/scripts/create-vm.sh --list-gpu-profiles-tsv
#          ./deploy/scripts/create-vm.sh --list-monitor-profiles
#          ./deploy/scripts/create-vm.sh --list-keyboard-profiles|--list-mouse-profiles
#                         --list-pointer-profiles|--list-input-compat
#
# 挑选一套「平台 + 主板 + 内存 + SSD + NVIDIA 1GB/2GB 显卡 + 真实显示器」；
# 未显式指定显卡时，先按宿主 framebuffer 档位收窄，再从该档的生产审核层
# 等概率随机一条原子 profile；追加的显式层只在用户选中时使用。生成 UUID /
# 各种序列号 / MAC，写入实例自己的 vm.conf 后仅作只读。
# start-vm.sh 只读这个文件，确保同一个 VM 每次开机表现一致。

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"
# shellcheck source=lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
# shellcheck source=lib/vgpu-host-config.sh
source "$here/lib/vgpu-host-config.sh"
# shellcheck source=lib/monitor-profiles.sh
source "$here/lib/monitor-profiles.sh"
# shellcheck source=lib/hardware-profiles.sh
source "$here/lib/hardware-profiles.sh"
# shellcheck source=lib/hardware-legality.sh
source "$here/lib/hardware-legality.sh"
# shellcheck source=lib/hardware-serials.sh
source "$here/lib/hardware-serials.sh"
# shellcheck source=lib/identity-uniqueness.sh
source "$here/lib/identity-uniqueness.sh"
# shellcheck source=lib/cpu-realization.sh
source "$here/lib/cpu-realization.sh"
# shellcheck source=lib/input-profiles.sh
source "$here/lib/input-profiles.sh"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
vgpu_profile_validate_catalog
monitor_create_pool_validate
hardware_profile_validate_catalog
input_profile_validate_catalog
vm_storage_init

VM_ID=""
FORCE=0
PLATFORM_REQUEST=""
CPU_PROFILE_REQUEST=""
CPU_SPEC_REQUEST=""
BOARD_PROFILE_REQUEST=""
MEMORY_PROFILE_REQUEST=""
MEMORY_SIZE_MB_REQUEST=""
SSD_PROFILE_REQUEST="${SSD_PROFILE:-}"
GPU_PROFILE_REQUEST="${GPU_PROFILE:-}"
GPU_PROFILE_EXPLICIT=0
GPU_VRAM_MB_REQUEST=""
GPU_VRAM_EXPLICIT=0
MONITOR_PROFILE_REQUEST="${MONITOR_PROFILE:-}"
KBD_PROFILE_REQUEST=""
MOUSE_PROFILE_REQUEST=""
POINTER_MODE_REQUEST=absolute
INCLUDE_FALLBACK=0
ALLOW_FALLBACK_PLATFORM=0
LIST_ACTION=""
while (( $# > 0 )); do
    case "$1" in
        --force) FORCE=1; shift ;;
        --gpu-profile)
            [[ $# -ge 2 ]] || { echo "--gpu-profile 缺少参数" >&2; exit 2; }
            GPU_PROFILE_REQUEST=$2
            GPU_PROFILE_EXPLICIT=1
            shift 2
            ;;
        --gpu-vram)
            [[ $# -ge 2 ]] || { echo "--gpu-vram 缺少参数" >&2; exit 2; }
            GPU_VRAM_MB_REQUEST=$(vgpu_profile_normalize_vram_mb "$2") || exit $?
            GPU_VRAM_EXPLICIT=1
            shift 2
            ;;
        --platform)
            [[ $# -ge 2 ]] || { echo "--platform 缺少参数" >&2; exit 2; }
            PLATFORM_REQUEST=$2
            shift 2
            ;;
        --cpu-profile)
            [[ $# -ge 2 ]] || { echo "--cpu-profile 缺少参数" >&2; exit 2; }
            CPU_PROFILE_REQUEST=$2
            shift 2
            ;;
        --cpu-spec)
            [[ $# -ge 2 ]] || { echo "--cpu-spec 缺少参数" >&2; exit 2; }
            case "${2,,}" in
                4c8t) CPU_SPEC_REQUEST=4c8t ;;
                6c12t) CPU_SPEC_REQUEST=6c12t ;;
                *)
                    echo "--cpu-spec 只支持 4c8t 或 6c12t" >&2
                    exit 2
                    ;;
            esac
            shift 2
            ;;
        --board-profile)
            [[ $# -ge 2 ]] || { echo "--board-profile 缺少参数" >&2; exit 2; }
            BOARD_PROFILE_REQUEST=$2
            shift 2
            ;;
        --memory-profile)
            [[ $# -ge 2 ]] || { echo "--memory-profile 缺少参数" >&2; exit 2; }
            MEMORY_PROFILE_REQUEST=$2
            shift 2
            ;;
        --memory-size)
            [[ $# -ge 2 ]] || { echo "--memory-size 缺少参数" >&2; exit 2; }
            MEMORY_SIZE_MB_REQUEST=$(hardware_memory_size_mb_normalize "$2") || exit $?
            shift 2
            ;;
        --include-fallback)
            INCLUDE_FALLBACK=1
            shift
            ;;
        --allow-fallback-platform)
            ALLOW_FALLBACK_PLATFORM=1
            shift
            ;;
        --ssd-profile)
            [[ $# -ge 2 ]] || { echo "--ssd-profile 缺少参数" >&2; exit 2; }
            SSD_PROFILE_REQUEST=$2
            shift 2
            ;;
        --list-ssd-profiles)
            LIST_ACTION=ssd
            shift
            ;;
        --list-platforms)
            LIST_ACTION=platform
            shift
            ;;
        --list-archived-platforms)
            LIST_ACTION=platform-archived
            shift
            ;;
        --list-cpu-profiles)
            LIST_ACTION=cpu
            shift
            ;;
        --list-board-profiles)
            LIST_ACTION=board
            shift
            ;;
        --list-memory-profiles)
            LIST_ACTION=memory
            shift
            ;;
        --list-gpu-profiles)
            LIST_ACTION=gpu
            shift
            ;;
        --list-gpu-profiles-tsv)
            LIST_ACTION=gpu-tsv
            shift
            ;;
        --keyboard-profile)
            [[ $# -ge 2 ]] || { echo "--keyboard-profile 缺少参数" >&2; exit 2; }
            KBD_PROFILE_REQUEST=$2
            shift 2
            ;;
        --mouse-profile)
            [[ $# -ge 2 ]] || { echo "--mouse-profile 缺少参数" >&2; exit 2; }
            MOUSE_PROFILE_REQUEST=$2
            POINTER_MODE_REQUEST=relative
            shift 2
            ;;
        --relative-mouse)
            POINTER_MODE_REQUEST=relative
            shift
            ;;
        --list-input-profiles)
            LIST_ACTION=input
            shift
            ;;
        --list-keyboard-profiles)
            LIST_ACTION=keyboard
            shift
            ;;
        --list-mouse-profiles)
            LIST_ACTION=mouse
            shift
            ;;
        --list-pointer-profiles)
            LIST_ACTION=pointer
            shift
            ;;
        --list-input-compat)
            LIST_ACTION=input-compat
            shift
            ;;
        --monitor-profile)
            [[ $# -ge 2 ]] || { echo "--monitor-profile 缺少参数" >&2; exit 2; }
            MONITOR_PROFILE_REQUEST=$2
            shift 2
            ;;
        --list-monitor-profiles)
            LIST_ACTION=monitor
            shift
            ;;
        -h|--help)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        [1-9]|[1-9][0-9]*)
            [[ -z "$VM_ID" ]] || { echo "只能指定一个 vm_id" >&2; exit 2; }
            VM_ID=$1
            shift
            ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

infer_existing_vgpu_host_tier() {
    local conf value seen="" count
    local -a values=()

    for conf in "$VM_ROOT"/*/vm.conf; do
        [[ -f "$conf" && ! -L "$conf" ]] || continue
        values=()
        mapfile -t values < <(sed -n -E \
            's/^[[:space:]]*GPU_VRAM_MB=(1024|2048)[[:space:]]*$/\1/p' \
            "$conf")
        count=${#values[@]}
        (( count == 1 )) || {
            echo "已有配置无法唯一读取 GPU_VRAM_MB: $conf" >&2
            return 2
        }
        value=${values[0]}
        if [[ -n "$seen" && "$seen" != "$value" ]]; then
            echo "已有 VM 同时包含 ${seen}MB 与 ${value}MB vGPU 档位" >&2
            return 3
        fi
        seen=$value
    done
    [[ -n "$seen" ]] || return 1
    printf '%s\n' "$seen"
}

# Resolve the physical-GPU framebuffer policy for both VM creation and the
# management TSV.  The return value is 1024/2048 for equal-size mode or
# "mixed" for a V100/R580 host that has published both reviewed mappings.
# AUTO_RANDOM stays an eight-column backward-compatible flag.
resolve_vgpu_host_tier() {
    local quiet=${1:-0} config_was_set=0 config mode tier inferred_tier infer_rc
    local config_rc=0

    if [[ -v VGPU_HOST_CONFIG ]]; then
        config_was_set=1
        config=$VGPU_HOST_CONFIG
    else
        config=$here/host/vgpu-host.conf
    fi
    if vgpu_host_config_load "$config" '[create-vm]' \
            VGPU_HOST_FB_MODE VGPU_HOST_FB_TIER_MB VGPU_HOST_VRAM_MB \
            VGPU_RESOURCE_PROFILE_1024 VGPU_RESOURCE_PROFILE_2048; then
        config_rc=0
    else
        config_rc=$?
        if ((config_rc != 3)); then
            return "$config_rc"
        fi
        if ((config_was_set)); then
            echo "VGPU_HOST_CONFIG 不存在: $config" >&2
            return 1
        fi
    fi
    mode=${VGPU_HOST_FB_MODE:-equal}
    case "$mode" in
        equal|mixed) ;;
        *)
            echo "VGPU_HOST_FB_MODE 必须是 equal 或 mixed: $mode" >&2
            return 2
            ;;
    esac
    if [[ -n "${VGPU_HOST_FB_TIER_MB:-}" &&
          -n "${VGPU_HOST_VRAM_MB:-}" &&
          "$VGPU_HOST_FB_TIER_MB" != "$VGPU_HOST_VRAM_MB" ]]; then
        echo "VGPU_HOST_FB_TIER_MB 与兼容变量 VGPU_HOST_VRAM_MB 冲突" >&2
        return 2
    fi
    tier=${VGPU_HOST_FB_TIER_MB:-${VGPU_HOST_VRAM_MB:-}}
    if [[ "$mode" == mixed ]]; then
        if [[ -n "$tier" ]]; then
            echo 'mixed-size 配置不能同时声明 VGPU_HOST_FB_TIER_MB/VGPU_HOST_VRAM_MB' >&2
            return 2
        fi
        if [[ -z "${VGPU_RESOURCE_PROFILE_1024:-}" ||
              -z "${VGPU_RESOURCE_PROFILE_2048:-}" ]]; then
            echo 'mixed-size 配置必须同时声明 1024/2048MB resource profile' >&2
            return 2
        fi
        printf '%s\n' mixed
        return 0
    fi
    if [[ -z "$tier" ]]; then
        if inferred_tier=$(infer_existing_vgpu_host_tier); then
            tier=$inferred_tier
            (( quiet )) || \
                echo "[create-vm] WARN: 未配置宿主 vGPU 档位；沿用现有 VM 的 ${tier}MB" >&2
        else
            infer_rc=$?
            if (( infer_rc > 1 )); then
                echo "请先运行 ./deploy/configure-g11-vgpu-host.sh 固定单一宿主档位" >&2
                return 2
            fi
            tier=2048
            (( quiet )) || \
                echo "[create-vm] WARN: 空池未配置宿主 vGPU 档位；使用生产默认 2048MB" >&2
        fi
    fi
    vgpu_profile_normalize_vram_mb "$tier"
}

if [[ -n "$LIST_ACTION" ]]; then
    [[ -z "$VM_ID" ]] || {
        echo "目录查询不能同时指定 vm_id" >&2
        exit 2
    }
    case "$LIST_ACTION" in
        platform) hardware_profile_print_catalog "$INCLUDE_FALLBACK" active ;;
        platform-archived) hardware_profile_print_catalog 1 archived ;;
        cpu) cpu_profile_print_catalog "$INCLUDE_FALLBACK" ;;
        board) board_profile_print_catalog "$INCLUDE_FALLBACK" ;;
        memory) memory_profile_print_catalog "$INCLUDE_FALLBACK" ;;
        ssd) ssd_profile_print_catalog ;;
        gpu) vgpu_profile_print_catalog ;;
        gpu-tsv)
            VGPU_CATALOG_HOST_SELECTOR=$(resolve_vgpu_host_tier 1) || exit $?
            vgpu_profile_print_tsv_catalog "$VGPU_CATALOG_HOST_SELECTOR"
            ;;
        monitor) monitor_create_pool_print_catalog ;;
        input) input_profile_print_catalog active all ;;
        keyboard) input_keyboard_profile_print_catalog active ;;
        mouse) input_mouse_profile_print_catalog active ;;
        pointer) input_pointer_profile_print_catalog active ;;
        input-compat) input_profile_print_catalog compat all ;;
    esac
    exit 0
fi

# Prefer an explicit gitignored host config.  Equal-size legacy hosts infer one
# unambiguous tier from existing vm.conf files and otherwise default to 2 GiB.
# Mixed-size is never inferred: it is accepted only from an explicit config
# that publishes both mappings.
VGPU_HOST_FB_POLICY=$(resolve_vgpu_host_tier) || exit $?
if [[ "$VGPU_HOST_FB_POLICY" == mixed ]]; then
    VGPU_HOST_FB_MODE=mixed
    VGPU_HOST_FB_TIER_MB=
else
    VGPU_HOST_FB_MODE=equal
    VGPU_HOST_FB_TIER_MB=$VGPU_HOST_FB_POLICY
fi

if (( GPU_PROFILE_EXPLICIT && GPU_VRAM_EXPLICIT )); then
    echo "--gpu-profile 与 --gpu-vram 不能同时使用" >&2
    exit 2
fi
if (( GPU_VRAM_EXPLICIT )); then
    # An explicit command-line capacity choice takes precedence over an
    # inherited GPU_PROFILE environment value.
    GPU_PROFILE_REQUEST=""
fi
if [[ -n "$MEMORY_PROFILE_REQUEST" && -n "$MEMORY_SIZE_MB_REQUEST" ]]; then
    echo "--memory-profile 与 --memory-size 不能同时使用" >&2
    exit 2
fi
if [[ -n "$CPU_PROFILE_REQUEST" && -n "$CPU_SPEC_REQUEST" ]]; then
    echo "--cpu-profile 与 --cpu-spec 不能同时使用" >&2
    exit 2
fi

COMPONENT_SELECTOR_COUNT=0
[[ -z "$CPU_PROFILE_REQUEST" ]] || COMPONENT_SELECTOR_COUNT=$((COMPONENT_SELECTOR_COUNT + 1))
[[ -z "$CPU_SPEC_REQUEST" ]] || COMPONENT_SELECTOR_COUNT=$((COMPONENT_SELECTOR_COUNT + 1))
[[ -z "$BOARD_PROFILE_REQUEST" ]] || COMPONENT_SELECTOR_COUNT=$((COMPONENT_SELECTOR_COUNT + 1))
[[ -z "$MEMORY_PROFILE_REQUEST" ]] || COMPONENT_SELECTOR_COUNT=$((COMPONENT_SELECTOR_COUNT + 1))
[[ -z "$MEMORY_SIZE_MB_REQUEST" ]] || COMPONENT_SELECTOR_COUNT=$((COMPONENT_SELECTOR_COUNT + 1))
if [[ -n "$PLATFORM_REQUEST" && "$COMPONENT_SELECTOR_COUNT" != 0 ]]; then
    echo "--platform 与 --cpu-spec/--cpu-profile/--board-profile/--memory-profile/--memory-size 不能混用" >&2
    echo "整机组合只从审核白名单选择；请任选一种选择方式" >&2
    exit 2
fi

if ! vm_storage_id_is_supported "$VM_ID"; then
    echo "usage: $0 <vm_id> [--force] [--platform PLATFORM|--cpu-spec 4c8t|6c12t|--cpu-profile CPU --board-profile BOARD (--memory-profile MEMORY|--memory-size 4G|8G|12G|16G)] [--allow-fallback-platform] [--ssd-profile PROFILE] [--gpu-profile PROFILE|--gpu-vram 1024|2048] [--monitor-profile PROFILE] [--keyboard-profile PROFILE] [--relative-mouse [--mouse-profile PROFILE]]" >&2
    echo "vm_id must be in 1..2147483647" >&2
    exit 2
fi
vm_storage_require_namespace_ready "$VM_ID"

vm_storage_validate_root_path "$VM_ROOT" "VM root"
mkdir -p "$VM_RUN_DIR"
exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -s "$STORAGE_LOCK_FD"
# Serialize identity selection through the final atomic vm.conf rename.  The
# read-only collision scan alone would leave a tiny check/publish race between
# two simultaneous create-vm processes, most notably in the 24-bit MAC suffix.
exec {IDENTITY_LOCK_FD}>"$VM_RUN_DIR/.identity.lock"
flock -x "$IDENTITY_LOCK_FD"
vm_storage_prepare
vm_storage_prepare_instance "$VM_ID"
if [[ "${VM_START_LOCK_HELD:-0}" != 1 ]]; then
    START_LOCK=$(vm_storage_run_path "$VM_ID" start.lock)
    exec {START_LOCK_FD}>"$START_LOCK"
    if ! flock -n "$START_LOCK_FD"; then
        echo "VM $VM_ID 正在启动或运行，不能改写配置" >&2
        exit 1
    fi
fi
DISK_LOCK=$(vm_storage_run_path "$VM_ID" disk.lock)
exec {CREATE_LOCK_FD}>"$DISK_LOCK"
if ! flock -n -x "$CREATE_LOCK_FD"; then
    echo "VM $VM_ID 正在执行其它创建/删除操作" >&2
    exit 1
fi
CONF=$(vm_storage_config_path "$VM_ID")
CONFIG_WAS_PRESENT=0
[[ -f "$CONF" ]] && CONFIG_WAS_PRESENT=1
if [[ -f "$CONF" && $FORCE -eq 0 ]]; then
    echo "VM $VM_ID 已存在 ($CONF)，--force 覆盖" >&2
    exit 0
fi
if ((FORCE)) && pgrep -f \
        "qemu-system-x86_64.*-name[[:space:]]+vm${VM_ID}([,[:space:]]|$)" \
        >/dev/null; then
    echo "VM $VM_ID 正在运行，拒绝 --force 改写硬件身份" >&2
    exit 1
fi

# A config rewrite must not silently change the protocol/capacity underneath an
# existing Windows disk, nor select a different TPM generation over persistent
# state.  With no explicit selector, preserve those bound choices; an explicit
# incompatible request fails with migration guidance before vm.conf is touched.
OLD_PLATFORM=""
OLD_SSD_PROFILE=""
OLD_SSD_INTERFACE=""
OLD_SSD_SIZE_BYTES=""
OLD_SSD_CONTROLLER_PROFILE=""
OLD_TPM_VERSION=""
PRESERVE_OLD_GPU_POLICY=0
OLD_GPU_PROFILE=""
OLD_SPOOF_MODE=""
OLD_VGPU_IDENTITY_TARGET=""
OLD_VGPU_MDEV_INTERNAL_PCI_IDENTITY_SET=0
OLD_VGPU_MDEV_INTERNAL_PCI_IDENTITY=""
OLD_VGPU_MDEV_FRL_ENABLED_SET=0
OLD_VGPU_MDEV_FRL_ENABLED=""
OLD_VGPU_PATCHED_DRIVER_REQUIRED_VERSION_SET=0
OLD_VGPU_PATCHED_DRIVER_REQUIRED_VERSION=""
OLD_VGPU_PATCHED_DRIVER_VERSION_SET=0
OLD_VGPU_PATCHED_DRIVER_VERSION=""
OLD_VGPU_PATCHED_DRIVER_INF_SET=0
OLD_VGPU_PATCHED_DRIVER_INF=""
GPUZ_PACKAGE_ENABLED=1
OLD_GPUZ_PACKAGE_ENABLED_SET=0
OLD_GPUZ_PACKAGE_ENABLED=""
EXISTING_DISK=$(vm_storage_disk_path "$VM_ID")
if (( FORCE )) && [[ -f "$CONF" ]]; then
    mapfile -d '' -t OLD_IDENTITY < <(
        unset PLATFORM SSD_PROFILE SSD_INTERFACE SSD_SIZE_BYTES \
            SSD_CONTROLLER_PROFILE BOARD_TPM_VERSION
        # shellcheck source=/dev/null
        source "$CONF"
        printf '%s\0' "${PLATFORM:-}" "${SSD_PROFILE:-}" \
            "${SSD_INTERFACE:-}" "${SSD_SIZE_BYTES:-}" \
            "${SSD_CONTROLLER_PROFILE:-}" "${BOARD_TPM_VERSION:-}"
    )
    if (( ${#OLD_IDENTITY[@]} == 6 )); then
        OLD_PLATFORM=${OLD_IDENTITY[0]}
        OLD_SSD_PROFILE=${OLD_IDENTITY[1]}
        OLD_SSD_INTERFACE=${OLD_IDENTITY[2]}
        OLD_SSD_SIZE_BYTES=${OLD_IDENTITY[3]}
        OLD_SSD_CONTROLLER_PROFILE=${OLD_IDENTITY[4]}
        OLD_TPM_VERSION=${OLD_IDENTITY[5]}
    fi
    unset OLD_IDENTITY

    # A forced metadata refresh must not randomly choose a new guest-visible
    # GPU or erase a completed A/full-consumer installation.  Capture optional
    # policy fields together with presence bits so "unset" remains distinct
    # from an invalid empty value.
    mapfile -d '' -t OLD_GPU_POLICY < <(
        unset GPU_PROFILE SPOOF_MODE VGPU_IDENTITY_TARGET
        unset VGPU_MDEV_INTERNAL_PCI_IDENTITY VGPU_MDEV_FRL_ENABLED
        unset VGPU_PATCHED_DRIVER_REQUIRED_VERSION
        unset VGPU_PATCHED_DRIVER_VERSION VGPU_PATCHED_DRIVER_INF
        unset GPUZ_PACKAGE_ENABLED
        # shellcheck source=/dev/null
        source "$CONF"
        printf '%s\0' \
            "${GPU_PROFILE:-}" \
            "${SPOOF_MODE:-}" \
            "${VGPU_IDENTITY_TARGET:-}" \
            "${VGPU_MDEV_INTERNAL_PCI_IDENTITY+x}" \
            "${VGPU_MDEV_INTERNAL_PCI_IDENTITY:-}" \
            "${VGPU_MDEV_FRL_ENABLED+x}" \
            "${VGPU_MDEV_FRL_ENABLED:-}" \
            "${VGPU_PATCHED_DRIVER_REQUIRED_VERSION+x}" \
            "${VGPU_PATCHED_DRIVER_REQUIRED_VERSION:-}" \
            "${VGPU_PATCHED_DRIVER_VERSION+x}" \
            "${VGPU_PATCHED_DRIVER_VERSION:-}" \
            "${VGPU_PATCHED_DRIVER_INF+x}" \
            "${VGPU_PATCHED_DRIVER_INF:-}" \
            "${GPUZ_PACKAGE_ENABLED+x}" \
            "${GPUZ_PACKAGE_ENABLED:-}"
    )
    if (( ${#OLD_GPU_POLICY[@]} != 15 )); then
        echo "无法安全读取旧 vm.conf 的 GPU policy，拒绝 --force" >&2
        exit 1
    fi
    OLD_GPU_PROFILE=${OLD_GPU_POLICY[0]}
    OLD_SPOOF_MODE=${OLD_GPU_POLICY[1]}
    OLD_VGPU_IDENTITY_TARGET=${OLD_GPU_POLICY[2]}
    OLD_VGPU_MDEV_INTERNAL_PCI_IDENTITY_SET=${OLD_GPU_POLICY[3]}
    OLD_VGPU_MDEV_INTERNAL_PCI_IDENTITY=${OLD_GPU_POLICY[4]}
    OLD_VGPU_MDEV_FRL_ENABLED_SET=${OLD_GPU_POLICY[5]}
    OLD_VGPU_MDEV_FRL_ENABLED=${OLD_GPU_POLICY[6]}
    OLD_VGPU_PATCHED_DRIVER_REQUIRED_VERSION_SET=${OLD_GPU_POLICY[7]}
    OLD_VGPU_PATCHED_DRIVER_REQUIRED_VERSION=${OLD_GPU_POLICY[8]}
    OLD_VGPU_PATCHED_DRIVER_VERSION_SET=${OLD_GPU_POLICY[9]}
    OLD_VGPU_PATCHED_DRIVER_VERSION=${OLD_GPU_POLICY[10]}
    OLD_VGPU_PATCHED_DRIVER_INF_SET=${OLD_GPU_POLICY[11]}
    OLD_VGPU_PATCHED_DRIVER_INF=${OLD_GPU_POLICY[12]}
    OLD_GPUZ_PACKAGE_ENABLED_SET=${OLD_GPU_POLICY[13]}
    OLD_GPUZ_PACKAGE_ENABLED=${OLD_GPU_POLICY[14]}
    unset OLD_GPU_POLICY

    if [[ "$OLD_GPUZ_PACKAGE_ENABLED_SET" == x ]]; then
        case "$OLD_GPUZ_PACKAGE_ENABLED" in
            0|1) GPUZ_PACKAGE_ENABLED=$OLD_GPUZ_PACKAGE_ENABLED ;;
            *)
                echo "旧 vm.conf 的 GPUZ_PACKAGE_ENABLED 非法，必须是 0 或 1，拒绝 --force" >&2
                exit 1
                ;;
        esac
    fi

    if (( ! GPU_PROFILE_EXPLICIT && ! GPU_VRAM_EXPLICIT )); then
        [[ -n "$OLD_GPU_PROFILE" ]] || {
            echo "旧 vm.conf 缺少 GPU_PROFILE，拒绝 --force 自动换卡；请显式传 --gpu-profile" >&2
            exit 1
        }
        case "$OLD_SPOOF_MODE" in
            ""|A|B|off) ;;
            *) echo "旧 vm.conf 的 SPOOF_MODE 非法，拒绝 --force: $OLD_SPOOF_MODE" >&2; exit 1 ;;
        esac
        case "$OLD_VGPU_IDENTITY_TARGET" in
            ""|name-only|full-consumer) ;;
            *) echo "旧 vm.conf 的 VGPU_IDENTITY_TARGET 非法，拒绝 --force: $OLD_VGPU_IDENTITY_TARGET" >&2; exit 1 ;;
        esac
        if [[ "$OLD_VGPU_MDEV_INTERNAL_PCI_IDENTITY_SET" == x &&
              "$OLD_VGPU_MDEV_INTERNAL_PCI_IDENTITY" != 0 &&
              "$OLD_VGPU_MDEV_INTERNAL_PCI_IDENTITY" != 1 ]]; then
            echo "旧 vm.conf 的 VGPU_MDEV_INTERNAL_PCI_IDENTITY 非法，拒绝 --force" >&2
            exit 1
        fi
        if [[ "$OLD_VGPU_MDEV_FRL_ENABLED_SET" == x &&
              "$OLD_VGPU_MDEV_FRL_ENABLED" != 0 &&
              "$OLD_VGPU_MDEV_FRL_ENABLED" != 1 ]]; then
            echo "旧 vm.conf 的 VGPU_MDEV_FRL_ENABLED 非法，拒绝 --force" >&2
            exit 1
        fi
        if [[ "$OLD_VGPU_PATCHED_DRIVER_REQUIRED_VERSION_SET" == x ]] &&
                ! [[ "$OLD_VGPU_PATCHED_DRIVER_REQUIRED_VERSION" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
            echo "旧 vm.conf 的 VGPU_PATCHED_DRIVER_REQUIRED_VERSION 非法，拒绝 --force" >&2
            exit 1
        fi
        if [[ "$OLD_VGPU_PATCHED_DRIVER_VERSION_SET" == x ]]; then
            if ! [[ "$OLD_VGPU_PATCHED_DRIVER_VERSION" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
                echo "旧 vm.conf 的 VGPU_PATCHED_DRIVER_VERSION 非法，拒绝 --force" >&2
                exit 1
            fi
        fi
        if [[ "$OLD_VGPU_PATCHED_DRIVER_INF_SET" == x ]]; then
            if ! [[ "$OLD_VGPU_PATCHED_DRIVER_INF" =~ ^oem(0|[1-9][0-9]*)\.inf$ ]]; then
                echo "旧 vm.conf 的 VGPU_PATCHED_DRIVER_INF 必须是 oemN.inf，拒绝 --force" >&2
                exit 1
            fi
        fi
        GPU_PROFILE_REQUEST=$OLD_GPU_PROFILE
        PRESERVE_OLD_GPU_POLICY=1
    fi

    if [[ -z "$PLATFORM_REQUEST" && "$COMPONENT_SELECTOR_COUNT" == 0 ]]; then
        PLATFORM_REQUEST=$OLD_PLATFORM
    fi
    if [[ -f "$EXISTING_DISK" ]]; then
        if [[ -z "$OLD_SSD_PROFILE" || -z "$OLD_SSD_INTERFACE" ||
              -z "$OLD_SSD_SIZE_BYTES" ||
              -z "$OLD_SSD_CONTROLLER_PROFILE" ]]; then
            echo "旧 vm.conf 缺少 SSD_PROFILE/SSD_INTERFACE/SSD_SIZE_BYTES/SSD_CONTROLLER_PROFILE，无法证明已有盘与新 profile 一致" >&2
            echo "拒绝 --force 猜测；请先备份并显式补齐存储元数据，或使用新 VM_ID" >&2
            exit 1
        fi
        [[ -n "$SSD_PROFILE_REQUEST" ]] || SSD_PROFILE_REQUEST=$OLD_SSD_PROFILE
    fi
fi

# For an unqualified default creation, try reviewed new combinations in their
# performance-first order (three 6C/12T CPUs, then two 4C/8T X79 CPUs), with
# 8 GiB as the ordinary memory default and native DDR3-1866 preferred, against
# this host before materializing identity.  If all active CPUs fail,
# creation fails instead of silently selecting an older, slower platform.  If
# probing is unavailable (missing KVM/QEMU/timeout), keep a new X79 profile and
# let the launcher fail closed.
AUTO_LEGACY_FALLBACK=0
HOST_PLATFORM_SELECTION_REASON=explicit
select_default_platform_for_host() {
    local qemu_bin=${QEMU_BIN:-"$here/../build/qemu-system-x86_64"}
    local start_index index platform cpu_key cpu_model capability priority
    local new_probe_fallback_platform unavailable_platform=
    local saw_unavailable=0
    local -a candidates priorities tier_candidates
    local -A probed_class=()

    mapfile -t candidates < <(hardware_profile_new_keys)
    (( ${#candidates[@]} > 0 )) || return 1
    mapfile -t priorities < <(
        for platform in "${candidates[@]}"; do
            hardware_profile_performance_priority "$platform"
        done | LC_ALL=C sort -n -u
    )
    for priority in "${priorities[@]}"; do
        tier_candidates=()
        for platform in "${candidates[@]}"; do
            [[ "$(hardware_profile_performance_priority "$platform")" == \
                "$priority" ]] || continue
            tier_candidates+=("$platform")
        done
        (( ${#tier_candidates[@]} > 0 )) || continue
        start_index=$((RANDOM % ${#tier_candidates[@]}))
        : "${new_probe_fallback_platform:=${tier_candidates[$start_index]}}"
        for ((index = 0; index < ${#tier_candidates[@]}; index += 1)); do
            platform=${tier_candidates[$(((start_index + index) % ${#tier_candidates[@]}))]}
            hardware_combination_load "$platform" || return 1
            cpu_key=$CPU_PROFILE
            if [[ ! -v 'probed_class[$cpu_key]' ]]; then
                cpu_profile_load "$cpu_key" || return 1
                cpu_model=$CPU_MODEL
                if g11_cpu_capability_probe "$qemu_bin" "$cpu_model"; then
                    probed_class[$cpu_key]=$G11_CPU_CAPABILITY_CLASS
                else
                    probed_class[$cpu_key]=$G11_CPU_CAPABILITY_CLASS
                fi
            fi
            capability=${probed_class[$cpu_key]}
            if [[ "$capability" == supported ]]; then
                PLATFORM=$platform
                HOST_PLATFORM_SELECTION_REASON=host-supported-performance-first
                return 0
            fi
            if [[ "$capability" == unavailable ]]; then
                saw_unavailable=1
                : "${unavailable_platform:=$platform}"
            fi
        done
    done

    # Keep the explicit-new tier generic even though the current X79 policy
    # leaves it empty.  Future reviewed performance tiers still pass through
    # the same strict KVM realization gate.
    mapfile -t candidates < <(hardware_profile_explicit_new_keys)
    for platform in "${candidates[@]}"; do
        hardware_combination_load "$platform" || return 1
        cpu_key=$CPU_PROFILE
        if [[ ! -v 'probed_class[$cpu_key]' ]]; then
            cpu_profile_load "$cpu_key" || return 1
            cpu_model=$CPU_MODEL
            if g11_cpu_capability_probe "$qemu_bin" "$cpu_model"; then
                probed_class[$cpu_key]=$G11_CPU_CAPABILITY_CLASS
            else
                probed_class[$cpu_key]=$G11_CPU_CAPABILITY_CLASS
            fi
        fi
        capability=${probed_class[$cpu_key]}
        if [[ "$capability" == supported ]]; then
            PLATFORM=$platform
            HOST_PLATFORM_SELECTION_REASON=no-supported-default-explicit-new-fallback
            return 0
        fi
        if [[ "$capability" == unavailable ]]; then
            saw_unavailable=1
            : "${unavailable_platform:=$platform}"
        fi
    done
    if (( saw_unavailable )); then
        PLATFORM=${unavailable_platform:-$new_probe_fallback_platform}
        HOST_PLATFORM_SELECTION_REASON=probe-unavailable-new-fail-closed
        return 0
    fi

    return 1
}

# Select only the requested home-CPU topology while retaining the same
# enforce=on host-capability fallback used by the unqualified default.  Board,
# memory-model and memory-capacity selectors are applied before probing, so a
# request can never escape the reviewed atomic platform whitelist.
select_cpu_spec_platform_for_host() {
    local qemu_bin=${QEMU_BIN:-"$here/../build/qemu-system-x86_64"}
    local expected_cores expected_vcpus start_index index platform
    local cpu_key cpu_model capability priority fallback_platform=
    local unavailable_platform='' saw_unavailable=0
    local -a candidates filtered priorities tier_candidates
    local -A probed_class=()

    case "$CPU_SPEC_REQUEST" in
        4c8t) expected_cores=4; expected_vcpus=8 ;;
        6c12t) expected_cores=6; expected_vcpus=12 ;;
        *) return 2 ;;
    esac

    mapfile -t candidates < <(hardware_profile_component_candidates \
        '' "$BOARD_PROFILE_REQUEST" "$MEMORY_PROFILE_REQUEST" \
        "$MEMORY_SIZE_MB_REQUEST" 0)
    filtered=()
    for platform in "${candidates[@]}"; do
        hardware_profile_load "$platform" || return 1
        [[ "$CPU_CORES" == "$expected_cores" && \
           "$CPU_VCPUS" == "$expected_vcpus" ]] || continue
        filtered+=("$platform")
    done
    (( ${#filtered[@]} > 0 )) || return 1

    mapfile -t priorities < <(
        for platform in "${filtered[@]}"; do
            hardware_profile_performance_priority "$platform"
        done | LC_ALL=C sort -n -u
    )
    for priority in "${priorities[@]}"; do
        tier_candidates=()
        for platform in "${filtered[@]}"; do
            [[ "$(hardware_profile_performance_priority "$platform")" == \
                "$priority" ]] || continue
            tier_candidates+=("$platform")
        done
        (( ${#tier_candidates[@]} > 0 )) || continue
        start_index=$((RANDOM % ${#tier_candidates[@]}))
        : "${fallback_platform:=${tier_candidates[$start_index]}}"
        for ((index = 0; index < ${#tier_candidates[@]}; index += 1)); do
            platform=${tier_candidates[$(((start_index + index) % ${#tier_candidates[@]}))]}
            hardware_combination_load "$platform" || return 1
            cpu_key=$CPU_PROFILE
            if [[ ! -v 'probed_class[$cpu_key]' ]]; then
                cpu_profile_load "$cpu_key" || return 1
                cpu_model=$CPU_MODEL
                if g11_cpu_capability_probe "$qemu_bin" "$cpu_model"; then
                    probed_class[$cpu_key]=$G11_CPU_CAPABILITY_CLASS
                else
                    probed_class[$cpu_key]=$G11_CPU_CAPABILITY_CLASS
                fi
            fi
            capability=${probed_class[$cpu_key]}
            if [[ "$capability" == supported ]]; then
                PLATFORM=$platform
                HOST_PLATFORM_SELECTION_REASON=host-supported-performance-first
                return 0
            fi
            if [[ "$capability" == unavailable ]]; then
                saw_unavailable=1
                : "${unavailable_platform:=$platform}"
            fi
        done
    done

    if (( saw_unavailable )); then
        PLATFORM=${unavailable_platform:-$fallback_platform}
        HOST_PLATFORM_SELECTION_REASON=probe-unavailable-new-fail-closed
        return 0
    fi
    return 1
}

# ─── 平台选择 ────────────────────────────────────────────────────────────────
if [[ -n "$PLATFORM_REQUEST" ]]; then
    PLATFORM=$PLATFORM_REQUEST
elif [[ -n "$CPU_SPEC_REQUEST" ]]; then
    if ! select_cpu_spec_platform_for_host; then
        echo "普通新建池中没有可由本机 KVM enforce=on 实现的 $CPU_SPEC_REQUEST 平台" >&2
        echo "请运行 ./deploy/scripts/check-hardware-pool.sh 查看逐 CPU 原因" >&2
        exit 2
    fi
elif (( COMPONENT_SELECTOR_COUNT )); then
    mapfile -t PLATFORM_COMPONENT_CANDIDATES < <(hardware_profile_component_candidates \
        "$CPU_PROFILE_REQUEST" "$BOARD_PROFILE_REQUEST" \
        "$MEMORY_PROFILE_REQUEST" "$MEMORY_SIZE_MB_REQUEST")
    PLATFORMS=()
    for candidate in "${PLATFORM_COMPONENT_CANDIDATES[@]}"; do
        candidate_lifecycle=$(hardware_profile_lifecycle_class "$candidate") || exit $?
        if [[ "$candidate_lifecycle" == legacy-compatibility ]] && \
                (( ! ALLOW_FALLBACK_PLATFORM )); then
            continue
        fi
        PLATFORMS+=("$candidate")
    done
    if (( ${#PLATFORMS[@]} == 0 )); then
        echo "没有通过审核的 CPU/主板/内存组合:" >&2
        echo "  CPU=${CPU_PROFILE_REQUEST:-任意}" >&2
        echo "  CPU规格=${CPU_SPEC_REQUEST:-任意}" >&2
        echo "  主板=${BOARD_PROFILE_REQUEST:-任意}" >&2
        echo "  内存=${MEMORY_PROFILE_REQUEST:-任意}" >&2
        if [[ -n "$MEMORY_SIZE_MB_REQUEST" ]]; then
            echo "  内存容量=${MEMORY_SIZE_MB_REQUEST}MiB" >&2
        fi
        echo "用 --list-platforms 查看合法整机组合；组件不会做笛卡尔积乱配" >&2
        exit 2
    fi
    # A broad component query can still match several reviewed tuples.  Keep
    # only the fastest tier, then randomize within that equally ranked tier.
    PLATFORM_PRIORITY=999999
    PLATFORM_PREFERRED=()
    for candidate in "${PLATFORMS[@]}"; do
        candidate_priority=$(hardware_profile_performance_priority "$candidate") || exit $?
        if (( candidate_priority < PLATFORM_PRIORITY )); then
            PLATFORM_PRIORITY=$candidate_priority
            PLATFORM_PREFERRED=()
        fi
        (( candidate_priority == PLATFORM_PRIORITY )) || continue
        PLATFORM_PREFERRED+=("$candidate")
    done
    PLATFORMS=("${PLATFORM_PREFERRED[@]}")
    PLATFORM=${PLATFORMS[$((RANDOM % ${#PLATFORMS[@]}))]}
else
    if ! select_default_platform_for_host; then
        echo "普通新建池中的 X79 CPU 均无法由本机 KVM enforce=on 实现；拒绝降级到旧慢平台" >&2
        echo "请先运行 ./deploy/scripts/check-hardware-pool.sh 查看逐 CPU 原因" >&2
        exit 2
    fi
fi
hardware_profile_load "$PLATFORM" || exit $?
HARDWARE_COMPONENT_CONTRACT_VERSION=3
PLATFORM_LIFECYCLE_CLASS=$(hardware_profile_lifecycle_class "$PLATFORM") || {
    echo "平台 $PLATFORM 缺少新建/兼容生命周期分类" >&2
    exit 2
}
PLATFORM_COMPAT_NEW_REJECT=0
if [[ "$PLATFORM_LIFECYCLE_CLASS" == archived ]]; then
    if (( ! FORCE || ! CONFIG_WAS_PRESENT )) || [[ "$OLD_PLATFORM" != "$PLATFORM" ]]; then
        echo "平台 $PLATFORM 属于旧硬件/已取消 6G 方案归档，只允许原 VM 使用 --force 保持原平台" >&2
        echo "新建请改用 X79 上的 4G/8G 双通道或 12G/16G 三/四通道方案" >&2
        exit 2
    fi
    CPU_REALIZATION_POLICY=enforced
elif [[ "$PLATFORM_LIFECYCLE_CLASS" == legacy-compatibility ]]; then
    if (( AUTO_LEGACY_FALLBACK || ALLOW_FALLBACK_PLATFORM )); then
        PLATFORM_COMPAT_NEW_REJECT=0
    elif (( ! FORCE || ! CONFIG_WAS_PRESENT )) || [[ "$OLD_PLATFORM" != "$PLATFORM" ]]; then
        PLATFORM_COMPAT_NEW_REJECT=1
    fi
    CPU_REALIZATION_POLICY=legacy-compatibility
else
    CPU_REALIZATION_POLICY=enforced
fi
if [[ "$PLATFORM_LIFECYCLE_CLASS" == legacy-compatibility ]] && \
        (( ALLOW_FALLBACK_PLATFORM )); then
    echo "[create-vm] WARN: 用户显式授权新建旧平台兜底配置: $PLATFORM" >&2
elif [[ "$HOST_PLATFORM_SELECTION_REASON" == no-supported-default-explicit-new-fallback ]]; then
    echo "[create-vm] WARN: 默认性能层不可用；仅本次使用通过审核的显式新平台: $PLATFORM" >&2
fi
BOARD_VERSION=$BOARD_REVISION
XHCI_IDENTITY=$(hardware_xhci_identity_for_platform "$PLATFORM")
IFS='|' read -r XHCI_PCI_VENDOR_ID XHCI_PCI_DEVICE_ID \
    XHCI_PCI_REVISION XHCI_PCI_BUS XHCI_PCI_ADDR <<<"$XHCI_IDENTITY"
unset XHCI_IDENTITY

# 主板、官方 BIOS、内存形态与容量已由 hardware_profile_load
# 作为一个整体加载，不再进行彼此独立的随机抽签。

gen_id() {
    local n=$1 out="" chunk
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "gen_id: 非法长度: $n" >&2; return 2; }
    # 过滤 urandom 后可能字符不足；循环补齐，保证调用者要求的长度。
    while (( ${#out} < n )); do
        chunk=$(LC_ALL=C head -c $((n * 8 + 32)) /dev/urandom \
            | LC_ALL=C tr -dc 'A-Z0-9')
        out+=$chunk
    done
    printf '%s\n' "${out:0:n}"
}

gen_hex() {
    local n=$1 out
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "gen_hex: 非法长度: $n" >&2; return 2; }
    out=$(od -An -N "$(((n + 1) / 2))" -tx1 /dev/urandom \
        | LC_ALL=C tr -d '[:space:]' | LC_ALL=C tr '[:lower:]' '[:upper:]')
    printf '%s\n' "${out:0:n}"
}

gen_digits() {
    local n=$1 out="" chunk
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "gen_digits: 非法长度: $n" >&2; return 2; }
    while (( ${#out} < n )); do
        chunk=$(LC_ALL=C head -c $((n * 8 + 32)) /dev/urandom \
            | LC_ALL=C tr -dc '0-9')
        out+=$chunk
    done
    printf '%s\n' "${out:0:n}"
}

if [[ -z "$SSD_PROFILE_REQUEST" ]]; then
    SSD_PROFILE_REQUESTS=()
    SSD_PREFERENCE_TIER=999
    while IFS= read -r candidate; do
        ssd_profile_load "$candidate" || exit $?
        if hardware_storage_combination_allowed "$PLATFORM" "$SSD_INTERFACE" \
                "$SSD_PCIE_GEN" "$SSD_PCIE_LANES" "$SSD_FORM_FACTOR"; then
            candidate_tier=$(hardware_storage_preference_tier \
                "$SSD_INTERFACE" "$SSD_PCIE_GEN" "$SSD_PCIE_LANES")
            if (( candidate_tier < SSD_PREFERENCE_TIER )); then
                SSD_PROFILE_REQUESTS=()
                SSD_PREFERENCE_TIER=$candidate_tier
            fi
            (( candidate_tier == SSD_PREFERENCE_TIER )) || continue
            SSD_PROFILE_REQUESTS+=("$candidate")
        fi
    done < <(ssd_auto_profile_keys)
    (( ${#SSD_PROFILE_REQUESTS[@]} > 0 )) || {
        echo "平台 $PLATFORM 没有经审核的默认 SSD 组合" >&2
        exit 1
    }
    SSD_PROFILE_REQUEST=${SSD_PROFILE_REQUESTS[$((RANDOM % ${#SSD_PROFILE_REQUESTS[@]}))]}
fi
ssd_profile_load "$SSD_PROFILE_REQUEST" || exit $?
if ! hardware_storage_combination_allowed "$PLATFORM" "$SSD_INTERFACE" \
        "$SSD_PCIE_GEN" "$SSD_PCIE_LANES" "$SSD_FORM_FACTOR"; then
    echo "SSD profile $SSD_PROFILE 与平台 $PLATFORM 不兼容: $SSD_INTERFACE" >&2
    if [[ "$PLATFORM" == i5-4590 && "$SSD_INTERFACE" == nvme ]]; then
        echo "GA-H97-D3H 板载 M.2 仅 PCIe 2.0 x2，不与当前 Gen3 x4 NVMe 身份混用；请选 SATA profile" >&2
    fi
    exit 2
fi
if [[ -f "$EXISTING_DISK" ]]; then
    if [[ -n "$OLD_SSD_INTERFACE" && "$SSD_INTERFACE" != "$OLD_SSD_INTERFACE" ]]; then
        echo "已有磁盘不能用 --force 从 $OLD_SSD_INTERFACE 直接改为 $SSD_INTERFACE" >&2
        echo "请先备份/迁移磁盘，或为新存储 profile 创建新 VM_ID" >&2
        exit 1
    fi
    if [[ -n "$OLD_SSD_SIZE_BYTES" && "$SSD_SIZE_BYTES" != "$OLD_SSD_SIZE_BYTES" ]]; then
        echo "已有磁盘不能用 --force 改变厂标容量: $OLD_SSD_SIZE_BYTES -> $SSD_SIZE_BYTES" >&2
        echo "请先完成 qcow2/分区迁移，或使用新 VM_ID" >&2
        exit 1
    fi
    if [[ -n "$OLD_SSD_CONTROLLER_PROFILE" &&
          "$SSD_CONTROLLER_PROFILE" != "$OLD_SSD_CONTROLLER_PROFILE" ]]; then
        echo "已有磁盘不能用 --force 改变 NVMe 控制器身份: $OLD_SSD_CONTROLLER_PROFILE -> $SSD_CONTROLLER_PROFILE" >&2
        echo "这会改变启动盘 PCI identity；请使用新 VM_ID 或先完成 guest 驱动迁移" >&2
        exit 1
    fi
fi

TPM_STATE_DIR="$(vm_storage_instance_dir "$VM_ID")/tpm/state"
TPM_STATE_PRESENT=0
if [[ -d "$TPM_STATE_DIR" ]] && \
        find "$TPM_STATE_DIR" -mindepth 1 -maxdepth 1 -print -quit \
            2>/dev/null | grep -q .; then
    TPM_STATE_PRESENT=1
fi
if (( TPM_STATE_PRESENT )); then
    # Pre-profile configs followed start-vm's historical TPM 2.0 default.
    # Prefer the actual state filename when available so even an omitted or
    # stale BOARD_TPM_VERSION cannot bypass the migration guard.
    if [[ -f "$TPM_STATE_DIR/tpm2-00.permall" ]]; then
        OLD_TPM_VERSION=2.0
    elif [[ -f "$TPM_STATE_DIR/tpm-00.permall" ]]; then
        OLD_TPM_VERSION=1.2
    elif [[ -z "$OLD_TPM_VERSION" ]]; then
        OLD_TPM_VERSION=2.0
    fi
    # TPM platform/EK certificates are manufactured with the original board
    # identity.  Even 2.0 -> 2.0 cannot safely reuse them across motherboard
    # profiles, so guard any re-platform rather than only generation changes.
    if [[ -z "$OLD_PLATFORM" || "$PLATFORM" != "$OLD_PLATFORM" ]]; then
        echo "已有与原主板 ${OLD_PLATFORM:-<legacy/unknown>} 绑定的 TPM 持久状态，拒绝改为 $PLATFORM" >&2
        echo "请先在 guest 内备份 BitLocker 恢复密钥并关闭依赖，再显式重置 TPM 状态或使用新 VM_ID" >&2
        exit 1
    fi
    if [[ "$BOARD_TPM_VERSION" != "$OLD_TPM_VERSION" ]]; then
        echo "已有 TPM $OLD_TPM_VERSION 持久状态，拒绝直接改为 $BOARD_TPM_VERSION" >&2
        echo "请先在 guest 内备份 BitLocker 恢复密钥并关闭依赖，再显式重置 TPM 状态或使用新 VM_ID" >&2
        exit 1
    fi
fi

if (( PLATFORM_COMPAT_NEW_REJECT )); then
    echo "平台 $PLATFORM 仅保留给已有 VM 的宿主兼容启动，不能新建实例" >&2
    echo "请改选正常平台；确需兜底时必须显式传 --allow-fallback-platform" >&2
    exit 2
fi

if [[ -z "$GPU_PROFILE_REQUEST" ]]; then
    if [[ -n "$GPU_VRAM_MB_REQUEST" ]]; then
        if [[ "$VGPU_HOST_FB_MODE" == equal &&
              "$GPU_VRAM_MB_REQUEST" != "$VGPU_HOST_FB_TIER_MB" ]]; then
            echo "请求 ${GPU_VRAM_MB_REQUEST}MB 与宿主固定档 ${VGPU_HOST_FB_TIER_MB}MB 冲突" >&2
            exit 2
        fi
        vgpu_profile_pick_random_vram "$GPU_VRAM_MB_REQUEST"
    else
        # mixed-size 允许显式选择两档，但保持原生产默认随机池为 2 GiB。
        vgpu_profile_pick_random_vram \
            "${VGPU_HOST_FB_TIER_MB:-2048}"
    fi
    GPU_PROFILE_REQUEST=$GPU_PROFILE
else
    vgpu_profile_load "$GPU_PROFILE_REQUEST"
fi
if vgpu_profile_is_legacy "$GPU_PROFILE"; then
    if (( ! PRESERVE_OLD_GPU_POLICY )); then
        echo "GPU profile $GPU_PROFILE 是仅供旧 VM 读取的 Kepler/R470 身份，不能与当前 GRID 538.33/R535 基线新建组合" >&2
        exit 2
    fi
fi
if [[ "$VGPU_HOST_FB_MODE" == equal &&
      "$GPU_VRAM_MB" != "$VGPU_HOST_FB_TIER_MB" ]]; then
    echo "GPU profile $GPU_PROFILE/${GPU_VRAM_MB}MB 与宿主固定档 ${VGPU_HOST_FB_TIER_MB}MB 冲突" >&2
    echo "先关停该物理 GPU 上全部 VM，再用 configure-g11-vgpu-host.sh 统一切档" >&2
    exit 2
fi

# Validate the complete combination before generating identity values or
# publishing vm.conf.  This catches cross-generation boards, DDR drift,
# impossible storage links, mismatched mdev resources, GPU lane mismatches and
# TPM frontend/version contradictions as one atomic profile contract.
VGPU_FB_MB=$GPU_VRAM_MB
TPM=1
TPM_EFFECTIVE_VERSION=$BOARD_TPM_VERSION
TPM_FRONTEND=$(g11_hardware_expected_tpm_frontend "$TPM_EFFECTIVE_VERSION") || {
    echo "平台 $PLATFORM 的 TPM 版本无法映射到 QEMU frontend: $BOARD_TPM_VERSION" >&2
    exit 2
}
if [[ "$BOARD_TPM_VERSION" == none ]]; then
    TPM=0
fi
if ! g11_hardware_combination_validate strict; then
    echo "硬件组合不合法 [$G11_HW_LEGALITY_CODE]: $G11_HW_LEGALITY_MESSAGE" >&2
    exit 2
fi

# New VMs always use the production-driver-safe B mode.  The consumer name,
# specs and app-local NVAPI PCI presentation come from the audited catalog;
# Windows PnP remains the native DEV_1E30 required by the unmodified GRID
# package.  Do not persist any legacy patched-driver/full-consumer marker in a
# new instance.
SPOOF_MODE=B
VGPU_IDENTITY_TARGET=name-only
unset VGPU_MDEV_INTERNAL_PCI_IDENTITY VGPU_MDEV_FRL_ENABLED
unset VGPU_PATCHED_DRIVER_REQUIRED_VERSION
unset VGPU_PATCHED_DRIVER_VERSION VGPU_PATCHED_DRIVER_INF

if (( PRESERVE_OLD_GPU_POLICY )); then
    [[ -z "$OLD_SPOOF_MODE" ]] || SPOOF_MODE=$OLD_SPOOF_MODE
    [[ -z "$OLD_VGPU_IDENTITY_TARGET" ]] || \
        VGPU_IDENTITY_TARGET=$OLD_VGPU_IDENTITY_TARGET
    if [[ "$OLD_VGPU_MDEV_INTERNAL_PCI_IDENTITY_SET" == x ]]; then
        VGPU_MDEV_INTERNAL_PCI_IDENTITY=$OLD_VGPU_MDEV_INTERNAL_PCI_IDENTITY
    fi
    if [[ "$OLD_VGPU_MDEV_FRL_ENABLED_SET" == x ]]; then
        VGPU_MDEV_FRL_ENABLED=$OLD_VGPU_MDEV_FRL_ENABLED
    fi
    if [[ "$OLD_VGPU_PATCHED_DRIVER_REQUIRED_VERSION_SET" == x ]]; then
        VGPU_PATCHED_DRIVER_REQUIRED_VERSION=$OLD_VGPU_PATCHED_DRIVER_REQUIRED_VERSION
    fi
    if [[ "$OLD_VGPU_PATCHED_DRIVER_VERSION_SET" == x ]]; then
        VGPU_PATCHED_DRIVER_VERSION=$OLD_VGPU_PATCHED_DRIVER_VERSION
    fi
    if [[ "$OLD_VGPU_PATCHED_DRIVER_INF_SET" == x ]]; then
        VGPU_PATCHED_DRIVER_INF=$OLD_VGPU_PATCHED_DRIVER_INF
    fi
fi

if [[ -z "$MONITOR_PROFILE_REQUEST" ]]; then
    monitor_profile_pick_create_random
    MONITOR_PROFILE_REQUEST=$MONITOR_PROFILE
else
    if ! monitor_create_pool_contains "$MONITOR_PROFILE_REQUEST"; then
        echo "显示器型号不在中国大陆常见 FHD/1K 新建池中: $MONITOR_PROFILE_REQUEST" >&2
        echo "用 --list-monitor-profiles 查看允许的新建型号" >&2
        exit 2
    fi
    monitor_profile_load "$MONITOR_PROFILE_REQUEST"
fi
if [[ -n "$KBD_PROFILE_REQUEST" ]]; then
    input_keyboard_profile_load "$KBD_PROFILE_REQUEST" || {
        echo "未知或非 active 键盘 profile: $KBD_PROFILE_REQUEST" >&2
        echo "用 --list-keyboard-profiles 查看可选项" >&2
        exit 2
    }
else
    input_profile_pick_keyboard_random
fi
case "$POINTER_MODE_REQUEST" in
    absolute)
        input_profile_load_pointer_default
        POINTER_MODE=absolute
        ;;
    relative)
        if [[ -n "$MOUSE_PROFILE_REQUEST" ]]; then
            input_mouse_profile_load "$MOUSE_PROFILE_REQUEST" || {
                echo "未知或非 active 鼠标 profile: $MOUSE_PROFILE_REQUEST" >&2
                echo "用 --list-mouse-profiles 查看可选项" >&2
                exit 2
            }
        else
            input_profile_pick_mouse_random
        fi
        POINTER_MODE=relative
        ;;
    *)
        echo "内部指针模式非法: $POINTER_MODE_REQUEST" >&2
        exit 2
        ;;
esac

# Generate the whole identity set under the fleet lock, validate each vendor
# format, then scan every other numeric VM bundle without sourcing it.  A
# collision rerolls only identities, never the selected hardware models.
IDENTITY_SET_UNIQUE=0
for ((fleet_identity_attempt = 0;
      fleet_identity_attempt < 256;
      fleet_identity_attempt += 1)); do
    MONITOR_SERIAL=$(monitor_profile_generate_serial "$MONITOR_SERIAL_PREFIX")
    VM_UUID=$(uuidgen)

    # Hardware contract v3 keeps the established three-label policy.  The
    # values share the selected board vendor syntax, but may never be reused
    # inside this VM or anywhere else in the managed fleet.
    SYS_SN=$(g11_hardware_serial_board_generate "$BOARD_BRAND" \
        "$BOARD_MODEL" "$BOARD_RELEASE_YEAR")
    for ((identity_attempt = 0; identity_attempt < 64;
          identity_attempt += 1)); do
        MB_SN=$(g11_hardware_serial_board_generate "$BOARD_BRAND" \
            "$BOARD_MODEL" "$BOARD_RELEASE_YEAR")
        [[ "$MB_SN" != "$SYS_SN" ]] && break
    done
    for ((identity_attempt = 0; identity_attempt < 64;
          identity_attempt += 1)); do
        CHASSIS_SN=$(g11_hardware_serial_board_generate "$BOARD_BRAND" \
            "$BOARD_MODEL" "$BOARD_RELEASE_YEAR")
        [[ "$CHASSIS_SN" != "$SYS_SN" && "$CHASSIS_SN" != "$MB_SN" ]] \
            && break
    done
    if [[ "$SYS_SN" == "$MB_SN" || "$SYS_SN" == "$CHASSIS_SN" ||
          "$MB_SN" == "$CHASSIS_SN" ]]; then
        continue
    fi

    MEM_SN=$(g11_hardware_serial_memory_generate)
    MEM_SERIAL_LIST=$(g11_hardware_serial_memory_list_generate \
        "$MEM_SN" "$MEM_SLOTS") || continue
    SSD_SN=$(g11_hardware_serial_ssd_generate "$SSD_PROFILE")
    VM_MAC=$(g11_hardware_mac_generate "${INTEL_OUIS[@]}") || {
        echo "无法生成符合 Intel OUI 合同的全局单播 MAC" >&2
        exit 2
    }

    SERIAL_SET_VALID=1
    for identity_pair in "SYS_SN:$SYS_SN" "MB_SN:$MB_SN" \
            "CHASSIS_SN:$CHASSIS_SN"; do
        identity_name=${identity_pair%%:*}
        identity_value=${identity_pair#*:}
        if ! g11_hardware_serial_board_validate "$BOARD_BRAND" \
                "$identity_value" "$BOARD_MODEL" "$BOARD_RELEASE_YEAR"; then
            SERIAL_SET_VALID=0
            break
        fi
    done
    ((SERIAL_SET_VALID)) || continue
    g11_hardware_serial_memory_validate "$MEM_SN" || continue
    g11_hardware_serial_memory_list_validate \
        "$MEM_SN" "$MEM_SLOTS" "$MEM_SERIAL_LIST" || continue
    g11_hardware_serial_ssd_validate "$SSD_PROFILE" "$SSD_SN" strict \
        || continue
    g11_hardware_mac_validate "$VM_MAC" "${INTEL_OUIS[@]}" || continue

    if g11_identity_candidates_are_unique "$VM_ID" "$VM_ROOT" \
            VM_UUID "$VM_UUID" \
            VM_MAC "$VM_MAC" \
            SYS_SN "$SYS_SN" \
            MB_SN "$MB_SN" \
            CHASSIS_SN "$CHASSIS_SN" \
            MEM_SERIAL_LIST "$MEM_SERIAL_LIST" \
            SSD_SN "$SSD_SN" \
            MONITOR_SERIAL "$MONITOR_SERIAL"; then
        IDENTITY_SET_UNIQUE=1
        break
    else
        uniqueness_rc=$?
    fi
    if ((uniqueness_rc == 2)); then
        echo "无法安全扫描现有 VM 身份: ${G11_IDENTITY_UNIQUENESS_MESSAGE}" >&2
        [[ -z "$G11_IDENTITY_CONFLICT_CONFIG" ]] || \
            echo "  配置: $G11_IDENTITY_CONFLICT_CONFIG" >&2
        exit 2
    fi
done
if ((IDENTITY_SET_UNIQUE == 0)); then
    echo "256 次尝试后仍无法生成全局唯一的硬件身份集" >&2
    exit 2
fi
unset IDENTITY_SET_UNIQUE SERIAL_SET_VALID fleet_identity_attempt \
    identity_attempt identity_pair identity_name identity_value uniqueness_rc

gpu_policy_config_block() {
    printf 'SPOOF_MODE=%s\n' "$SPOOF_MODE"
    printf 'VGPU_IDENTITY_TARGET=%s\n' "$VGPU_IDENTITY_TARGET"
    if [[ -v VGPU_MDEV_INTERNAL_PCI_IDENTITY ]]; then
        printf 'VGPU_MDEV_INTERNAL_PCI_IDENTITY=%s\n' \
            "$VGPU_MDEV_INTERNAL_PCI_IDENTITY"
    fi
    if [[ -v VGPU_MDEV_FRL_ENABLED ]]; then
        printf 'VGPU_MDEV_FRL_ENABLED=%s\n' "$VGPU_MDEV_FRL_ENABLED"
    fi
    if [[ -v VGPU_PATCHED_DRIVER_REQUIRED_VERSION ]]; then
        printf 'VGPU_PATCHED_DRIVER_REQUIRED_VERSION=%s\n' \
            "$VGPU_PATCHED_DRIVER_REQUIRED_VERSION"
    fi
    if [[ -v VGPU_PATCHED_DRIVER_VERSION ]]; then
        printf 'VGPU_PATCHED_DRIVER_VERSION=%s\n' \
            "$VGPU_PATCHED_DRIVER_VERSION"
    fi
    if [[ -v VGPU_PATCHED_DRIVER_INF ]]; then
        printf 'VGPU_PATCHED_DRIVER_INF=%s\n' "$VGPU_PATCHED_DRIVER_INF"
    fi
}
GPU_POLICY_CONFIG=$(gpu_policy_config_block)

input_policy_config_block() {
    printf 'INPUT_COMPONENT_CONTRACT_VERSION=%s\n' \
        "$INPUT_COMPONENT_CONTRACT_CURRENT_VERSION"
    printf 'INPUT_PROFILE_CATALOG_REVISION=%s\n' \
        "$INPUT_PROFILE_CATALOG_CURRENT_REVISION"
    printf 'POINTER_MODE=%s\n' "$POINTER_MODE"
    printf 'KBD_PROFILE=%s\n' "$KBD_PROFILE"
    printf 'KBD_BRAND="%s"\n' "$KBD_BRAND"
    printf 'KBD_MODEL="%s"\n' "$KBD_MODEL"
    printf 'KBD_VID=%s\n' "$KBD_VID"
    printf 'KBD_PID=%s\n' "$KBD_PID"
    printf 'KBD_BCD_DEVICE=%s\n' "$KBD_BCD_DEVICE"
    printf 'KBD_USB_VERSION=%s\n' "$KBD_USB_VERSION"
    printf 'KBD_MFR="%s"\n' "$KBD_MFR"
    printf 'KBD_PRODUCT="%s"\n' "$KBD_PRODUCT"
    printf 'KBD_SERIAL_POLICY=%s\n' "$KBD_SERIAL_POLICY"
    printf 'KBD_FIDELITY=%s\n' "$KBD_FIDELITY"
    case "$POINTER_MODE" in
        absolute)
            printf 'POINTER_PROFILE=%s\n' "$POINTER_PROFILE"
            printf 'POINTER_BRAND="%s"\n' "$POINTER_BRAND"
            printf 'POINTER_MODEL="%s"\n' "$POINTER_MODEL"
            printf 'POINTER_VID=%s\n' "$POINTER_VID"
            printf 'POINTER_PID=%s\n' "$POINTER_PID"
            printf 'POINTER_BCD_DEVICE=%s\n' "$POINTER_BCD_DEVICE"
            printf 'POINTER_USB_VERSION=%s\n' "$POINTER_USB_VERSION"
            printf 'POINTER_MFR="%s"\n' "$POINTER_MFR"
            printf 'POINTER_PRODUCT="%s"\n' "$POINTER_PRODUCT"
            printf 'POINTER_SERIAL_POLICY=%s\n' "$POINTER_SERIAL_POLICY"
            printf 'POINTER_FIDELITY=%s\n' "$POINTER_FIDELITY"
            ;;
        relative)
            printf 'MOUSE_PROFILE=%s\n' "$MOUSE_PROFILE"
            printf 'MOUSE_BRAND="%s"\n' "$MOUSE_BRAND"
            printf 'MOUSE_MODEL="%s"\n' "$MOUSE_MODEL"
            printf 'MOUSE_VID=%s\n' "$MOUSE_VID"
            printf 'MOUSE_PID=%s\n' "$MOUSE_PID"
            printf 'MOUSE_BCD_DEVICE=%s\n' "$MOUSE_BCD_DEVICE"
            printf 'MOUSE_USB_VERSION=%s\n' "$MOUSE_USB_VERSION"
            printf 'MOUSE_MFR="%s"\n' "$MOUSE_MFR"
            printf 'MOUSE_PRODUCT="%s"\n' "$MOUSE_PRODUCT"
            printf 'MOUSE_SERIAL_POLICY=%s\n' "$MOUSE_SERIAL_POLICY"
            printf 'MOUSE_FIDELITY=%s\n' "$MOUSE_FIDELITY"
            ;;
    esac
}
INPUT_POLICY_CONFIG=$(input_policy_config_block)

CONF_TMP="$(dirname "$CONF")/.$(basename "$CONF").partial.$$.$RANDOM"
cleanup_create_vm() {
    rm -f -- "$CONF_TMP"
}
trap cleanup_create_vm EXIT

cat > "$CONF_TMP" <<EOF
# === 自动生成于 $(date -Iseconds) ===
# ${VM_ID}/vm.conf — 只读，任何时候修改都可能让 guest 内 license/driver
# / Windows 激活等失效。更换硬件指纹请用新 VM_ID + --force。

VM_ID=${VM_ID}
VM_UUID=${VM_UUID}
# Windows uses its normal local-RTC interpretation.  The launcher pins the
# QEMU process to Asia/Shanghai and supplies base=localtime; do not add
# RealTimeIsUniversal inside the guest.
RTC_CONTRACT=localtime
G11_HARDWARE_CONTRACT_VERSION=3
HARDWARE_COMPONENT_CONTRACT_VERSION=${HARDWARE_COMPONENT_CONTRACT_VERSION}
CPU_REALIZATION_POLICY=${CPU_REALIZATION_POLICY}
PLATFORM_SELECTION_POLICY=${HOST_PLATFORM_SELECTION_REASON}
PLATFORM=${PLATFORM}
CPU_PROFILE=${CPU_PROFILE}
BOARD_PROFILE=${BOARD_PROFILE}
MEMORY_PROFILE=${MEMORY_PROFILE}
CPU_MODEL=${CPU_MODEL}
TSC_FREQ=${TSC_FREQ}
CPU_CORES=${CPU_CORES}
CPU_THREADS_PER_CORE=${CPU_THREADS_PER_CORE}
CPU_VCPUS=${CPU_VCPUS}
CPU_BASE_MHZ=${CPU_BASE_MHZ}
CPU_MAX_MHZ=${CPU_MAX_MHZ}
CPU_L1_CACHE_KB=${CPU_L1_CACHE_KB}
CPU_L2_CACHE_KB=${CPU_L2_CACHE_KB}
CPU_L3_CACHE_KB=${CPU_L3_CACHE_KB}
CPU_L2_ASSOC=${CPU_L2_ASSOC}
CPU_L3_ASSOC=${CPU_L3_ASSOC}
GUEST_MEM_MB=${MEM_TOTAL_MB}

BOARD_BRAND="${BOARD_BRAND}"
BOARD_MODEL="${BOARD_MODEL}"
BOARD_REVISION="${BOARD_REVISION}"
BIOS_VER="${BIOS_VER}"
BIOS_DATE="${BIOS_DATE}"
BOARD_VERSION="${BOARD_VERSION}"
BOARD_CHIPSET="${BOARD_CHIPSET}"
BOARD_TPM_VERSION=${BOARD_TPM_VERSION}
BOARD_NVME_PCIE_GEN=${BOARD_NVME_PCIE_GEN}
BOARD_NVME_PCIE_LANES=${BOARD_NVME_PCIE_LANES}
BOARD_RELEASE_YEAR=${BOARD_RELEASE_YEAR}
BOARD_SERIAL_POLICY=${BOARD_SERIAL_POLICY}

# Audited physical-board xHCI facts plus the virtual controller placement.
# The launcher validates these values but deliberately does not project the
# physical PCI ID onto qemu-xhci (its behavior identity stays upstream).
XHCI_PCI_VENDOR_ID=${XHCI_PCI_VENDOR_ID}
XHCI_PCI_DEVICE_ID=${XHCI_PCI_DEVICE_ID}
XHCI_PCI_REVISION=${XHCI_PCI_REVISION}
XHCI_PCI_BUS=${XHCI_PCI_BUS}
XHCI_PCI_ADDR=${XHCI_PCI_ADDR}

SYS_SN="${SYS_SN}"
MB_SN="${MB_SN}"
CHASSIS_SN="${CHASSIS_SN}"

MEM_BRAND="${MEM_BRAND}"
MEM_MODEL="${MEM_MODEL}"
MEM_MODEL_LIST="${MEM_MODEL_LIST}"
MEM_SPEED=${MEM_SPEED}
MEM_FAMILY=${MEM_FAMILY}
MEM_TYPE_BYTE=${MEM_TYPE_BYTE}
MEM_WIDTH=${MEM_WIDTH}
MEM_MODULE_MB=${MEM_MODULE_MB}
MEM_MODULE_MB_LIST="${MEM_MODULE_MB_LIST}"
MEM_SLOTS=${MEM_SLOTS}
MEM_TOTAL_MB=${MEM_TOTAL_MB}
MEM_FORM_FACTOR=${MEM_FORM_FACTOR}
MEM_RANK=${MEM_RANK}
MEM_RANK_LIST="${MEM_RANK_LIST}"
MEM_DEVICE_WIDTH=${MEM_DEVICE_WIDTH}
MEM_DEVICE_WIDTH_LIST="${MEM_DEVICE_WIDTH_LIST}"
MEM_MODULE_MFR_JEP106_LIST="${MEM_MODULE_MFR_JEP106_LIST}"
MEM_DRAM_MFR_JEP106_LIST="${MEM_DRAM_MFR_JEP106_LIST}"
MEM_VOLTAGE_MV=${MEM_VOLTAGE_MV}
MEM_CHANNEL_MODE=${MEM_CHANNEL_MODE}
MEM_BOARD_SLOTS=${MEM_BOARD_SLOTS}
MEM_MAX_CAPACITY_GB=${MEM_MAX_CAPACITY_GB}
MEM_SN="${MEM_SN}"
MEM_SERIAL_LIST="${MEM_SERIAL_LIST}"

SSD_PROFILE=${SSD_PROFILE}
SSD_BRAND="${SSD_BRAND}"
SSD_MODEL="${SSD_MODEL}"
SSD_INTERFACE=${SSD_INTERFACE}
SSD_SIZE_BYTES=${SSD_SIZE_BYTES}
SSD_FIRMWARE_REV="${SSD_FIRMWARE_REV}"
SSD_CONTROLLER_PROFILE=${SSD_CONTROLLER_PROFILE}
SSD_FORM_FACTOR=${SSD_FORM_FACTOR}
SSD_PCIE_GEN=${SSD_PCIE_GEN}
SSD_PCIE_LANES=${SSD_PCIE_LANES}
SSD_LOGICAL_BLOCK_SIZE=${SSD_LOGICAL_BLOCK_SIZE}
SSD_PHYSICAL_BLOCK_SIZE=${SSD_PHYSICAL_BLOCK_SIZE}
SSD_SN="${SSD_SN}"

# 通用 GPU-Z 封装生命周期开关。设为 0 时批量封装应跳过这个实例；
# --force 会保留并校验旧值，不会把已淘汰实例静默重新启用。
GPUZ_PACKAGE_ENABLED=${GPUZ_PACKAGE_ENABLED}
GPU_PROFILE=${GPU_PROFILE}
# 新 VM 统一使用 B/name-only：系统 PnP 保持原版生产签名驱动所需的
# DEV_1E30，消费级 PCI tuple 只在受验收的应用本地 NVAPI 层呈现。
${GPU_POLICY_CONFIG}
VGPU_MDEV_PROFILE=${VGPU_MDEV_PROFILE}
VGPU_FB_MB=${VGPU_FB_MB}
GPU_NAME="${GPU_NAME}"
GPU_PCI_VID=${GPU_PCI_VID}
GPU_PCI_DID=${GPU_PCI_DID}
GPU_SUB_VID=${GPU_SUB_VID}
GPU_SUB_DID=${GPU_SUB_DID}
GPU_REV=${GPU_REV}
GPU_VRAM_MB=${GPU_VRAM_MB}
GPU_VBIOS="${GPU_VBIOS}"
GPU_CORE_MHZ=${GPU_CORE_MHZ}
GPU_BOOST_MHZ=${GPU_BOOST_MHZ}
GPU_MEMORY_MHZ=${GPU_MEMORY_MHZ}
GPU_MEMORY_BUS_BITS=${GPU_MEMORY_BUS_BITS}
GPU_MEMORY_BANDWIDTH_MBPS=${GPU_MEMORY_BANDWIDTH_MBPS}
GPU_MEMORY_TYPE=${GPU_MEMORY_TYPE}
GPU_MEMORY_MAKER="${GPU_MEMORY_MAKER}"
GPU_MEMORY_TYPE_NVAPI=${GPU_MEMORY_TYPE_NVAPI}
GPU_MEMORY_MAKER_NVAPI=${GPU_MEMORY_MAKER_NVAPI}
GPU_CUDA_CORES=${GPU_CUDA_CORES}
GPU_SHADER_SUBPIPES=${GPU_SHADER_SUBPIPES}
GPU_ROP_COUNT=${GPU_ROP_COUNT}
GPU_TMU_COUNT=${GPU_TMU_COUNT}
GPU_ARCHITECTURE=${GPU_ARCHITECTURE}
GPU_IMPLEMENTATION=${GPU_IMPLEMENTATION}
GPU_CHIP_REVISION=${GPU_CHIP_REVISION}
GPU_PCIE_WIDTH=${GPU_PCIE_WIDTH}
# VGPU_MDEV_PROFILE 是旧 RTX 宿主 fallback；真实宿主资源可由
# deploy/host/vgpu-host.conf 的 VGPU_RESOURCE_PROFILE 覆盖。
# 运行时由 start-vm.sh 动态分配 MDEV_UUID（mdev 回池）

# 真实显示器身份。NVIDIA mdev 路径由 host 离线同步到 Windows 自己的 EDID
# 缓存；virtio 路径把同一组字段直接传给 QEMU，不在 guest 安装常驻组件。
MONITOR_PROFILE=${MONITOR_PROFILE}
MONITOR_VENDOR=${MONITOR_VENDOR}
MONITOR_PRODUCT_ID=${MONITOR_PRODUCT_ID}
MONITOR_EDID_NAME="${MONITOR_EDID_NAME}"
MONITOR_DISPLAY_NAME="${MONITOR_DISPLAY_NAME}"
MONITOR_MANUFACTURER="${MONITOR_MANUFACTURER}"
MONITOR_BRAND_NAME="${MONITOR_BRAND_NAME}"
MONITOR_MODEL_NAME="${MONITOR_MODEL_NAME}"
MONITOR_WIDTH_MM=${MONITOR_WIDTH_MM}
MONITOR_HEIGHT_MM=${MONITOR_HEIGHT_MM}
MONITOR_NATIVE_X=${MONITOR_NATIVE_X}
MONITOR_NATIVE_Y=${MONITOR_NATIVE_Y}
MONITOR_REFRESH_HZ=${MONITOR_REFRESH_HZ}
MONITOR_MIN_V=${MONITOR_MIN_V}
MONITOR_MAX_V=${MONITOR_MAX_V}
MONITOR_MIN_H=${MONITOR_MIN_H}
MONITOR_MAX_H=${MONITOR_MAX_H}
MONITOR_MAX_CLOCK_MHZ=${MONITOR_MAX_CLOCK_MHZ}
MONITOR_VIDEO_INPUT=${MONITOR_VIDEO_INPUT}
MONITOR_YEAR=${MONITOR_YEAR}
MONITOR_WEEK=${MONITOR_WEEK}
MONITOR_SERIAL_PREFIX="${MONITOR_SERIAL_PREFIX}"
MONITOR_MODE_SET=${MONITOR_MODE_SET}
MONITOR_SERIAL="${MONITOR_SERIAL}"

# USB HID identity contract.  serial-policy=none maps to descriptor
# iSerialNumber=0; no made-up serial token is generated or passed to QEMU.
# Default absolute mode keeps the honest generic QEMU tablet.  Relative mode
# is opt-in because it requires viewer pointer grab.
${INPUT_POLICY_CONFIG}

VM_MAC=${VM_MAC}
EOF
chmod 444 "$CONF_TMP"
mv -T -- "$CONF_TMP" "$CONF"
trap - EXIT

printf '创建成功: %s\n' "$CONF"
printf '  合法性: strict / CPU policy=%s\n' "$CPU_REALIZATION_POLICY"
printf '  平台:   %s (CPU %s, %sC/%sT, TSC %d Hz)\n' \
    "$PLATFORM" "$CPU_MODEL" "$CPU_CORES" "$CPU_VCPUS" "$TSC_FREQ"
printf '  主板:   %s %s rev %s / %s，BIOS %s %s，TPM %s\n' \
    "$BOARD_BRAND" "$BOARD_MODEL" "$BOARD_REVISION" "$BOARD_CHIPSET" \
    "$BIOS_VER" "$BIOS_DATE" "$BOARD_TPM_VERSION"
printf '  内存:   %s MiB（%s；主板 %d 槽/最大 %d GiB） %s %s %s@%dMT/s (%d-bit %s)\n' \
    "${MEM_MODULE_MB_LIST//,/+}" "$MEM_CHANNEL_MODE" "$MEM_BOARD_SLOTS" \
    "$MEM_MAX_CAPACITY_GB" "$MEM_BRAND" "${MEM_MODEL_LIST//,/ + }" \
    "$MEM_FAMILY" "$MEM_SPEED" "$MEM_WIDTH" "$MEM_FORM_FACTOR"
if [[ "$SSD_INTERFACE" == nvme ]]; then
    printf '  硬盘:   %s（%s/%s，PCIe %s.0 x%s %s，%d 字节，FW %s，扇区 %s/%s）\n' \
        "$SSD_MODEL" "$SSD_INTERFACE" "$SSD_CONTROLLER_PROFILE" \
        "$SSD_PCIE_GEN" "$SSD_PCIE_LANES" "$SSD_FORM_FACTOR" \
        "$SSD_SIZE_BYTES" "$SSD_FIRMWARE_REV" \
        "$SSD_LOGICAL_BLOCK_SIZE" "$SSD_PHYSICAL_BLOCK_SIZE"
else
    printf '  硬盘:   %s（%s/%s，SATA 6Gb/s %s，%d 字节，FW %s，扇区 %s/%s）\n' \
        "$SSD_MODEL" "$SSD_INTERFACE" "$SSD_CONTROLLER_PROFILE" \
        "$SSD_FORM_FACTOR" "$SSD_SIZE_BYTES" "$SSD_FIRMWARE_REV" \
        "$SSD_LOGICAL_BLOCK_SIZE" "$SSD_PHYSICAL_BLOCK_SIZE"
fi
printf '  显卡名称目标: %s / %s，%d MB，core/boost/mem=%d/%d/%d MHz\n' \
    "$GPU_PROFILE" "$GPU_NAME" "$GPU_VRAM_MB" \
    "$GPU_CORE_MHZ" "$GPU_BOOST_MHZ" "$GPU_MEMORY_MHZ"
printf '          板卡身份=%s %s；板卡序列号=%s\n' \
    "$GPU_BOARD_BRAND" "$GPU_BOARD_IDENTITY" "$GPU_SERIAL_POLICY"
printf '          B 模式 PCI identity 保持宿主 mdev；仅 A 模式使用 catalog %s:%s sub %s:%s\n' \
    "$GPU_PCI_VID" "$GPU_PCI_DID" "$GPU_SUB_VID" "$GPU_SUB_DID"
printf '          mdev 资源 fallback=%s/%d MB（宿主配置可覆盖）\n' \
    "$VGPU_MDEV_PROFILE" "$VGPU_FB_MB"
printf '  显示器: %s %s / %s（%s%s，%dx%d@%dHz，%dx%d mm，SN=%s）\n' \
    "$MONITOR_BRAND_NAME" "$MONITOR_MODEL_NAME" "$MONITOR_PROFILE" "$MONITOR_VENDOR" \
    "${MONITOR_PRODUCT_ID#0x}" "$MONITOR_NATIVE_X" "$MONITOR_NATIVE_Y" \
    "$MONITOR_REFRESH_HZ" "$MONITOR_WIDTH_MM" "$MONITOR_HEIGHT_MM" \
    "$MONITOR_SERIAL"
printf '  键盘:   %s %s（usb-kbd，USB %s:%s，SN=%s，%s）\n' \
    "$KBD_BRAND" "$KBD_MODEL" "${KBD_VID#0x}" "${KBD_PID#0x}" \
    "$KBD_SERIAL_POLICY" "$KBD_FIDELITY"
if [[ "$POINTER_MODE" == absolute ]]; then
    printf '  绝对指针: %s（usb-tablet，USB %s:%s，SN=%s，%s）\n' \
        "$POINTER_MODEL" "${POINTER_VID#0x}" "${POINTER_PID#0x}" \
        "$POINTER_SERIAL_POLICY" "$POINTER_FIDELITY"
else
    printf '  相对鼠标: %s %s（usb-mouse，USB %s:%s，SN=%s，%s）\n' \
        "$MOUSE_BRAND" "$MOUSE_MODEL" "${MOUSE_VID#0x}" \
        "${MOUSE_PID#0x}" "$MOUSE_SERIAL_POLICY" "$MOUSE_FIDELITY"
fi
printf '  MAC:    %s\n' "$VM_MAC"
printf '  UUID:   %s\n' "$VM_UUID"

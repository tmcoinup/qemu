#!/usr/bin/env bash
# create-vm.sh — 一次性生成 $VM_ROOT/instances/vmN/vm.conf。
#
#   用法:  ./create-vm.sh <vm_id> [--platform PLATFORM] [--ssd-profile PROFILE]
#                                  [--gpu-profile PROFILE] [--monitor-profile PROFILE]
#          ./create-vm.sh <vm_id> --force  # 覆盖已存在配置
#          ./create-vm.sh --list-ssd-profiles
#          ./create-vm.sh --list-gpu-profiles
#          ./create-vm.sh --list-monitor-profiles
#
# 随机挑选一套「平台 + 主板 + 内存 + SSD + NVIDIA 2GB 显卡 + 真实显示器」，
# 生成 UUID / 各种序列号 / MAC，写入实例自己的 vm.conf 后仅作只读。
# start-vm.sh 只读这个文件，确保同一个 VM 每次开机表现一致。

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
# shellcheck source=lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
# shellcheck source=lib/monitor-profiles.sh
source "$here/lib/monitor-profiles.sh"
# shellcheck source=lib/hardware-profiles.sh
source "$here/lib/hardware-profiles.sh"
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
SSD_PROFILE_REQUEST="${SSD_PROFILE:-}"
GPU_PROFILE_REQUEST="${GPU_PROFILE:-}"
GPU_PROFILE_EXPLICIT=0
MONITOR_PROFILE_REQUEST="${MONITOR_PROFILE:-}"
while (( $# > 0 )); do
    case "$1" in
        --force) FORCE=1; shift ;;
        --gpu-profile)
            [[ $# -ge 2 ]] || { echo "--gpu-profile 缺少参数" >&2; exit 2; }
            GPU_PROFILE_REQUEST=$2
            GPU_PROFILE_EXPLICIT=1
            shift 2
            ;;
        --platform)
            [[ $# -ge 2 ]] || { echo "--platform 缺少参数" >&2; exit 2; }
            PLATFORM_REQUEST=$2
            shift 2
            ;;
        --ssd-profile)
            [[ $# -ge 2 ]] || { echo "--ssd-profile 缺少参数" >&2; exit 2; }
            SSD_PROFILE_REQUEST=$2
            shift 2
            ;;
        --list-ssd-profiles)
            ssd_profile_print_catalog
            exit 0
            ;;
        --list-gpu-profiles)
            vgpu_profile_print_catalog
            exit 0
            ;;
        --monitor-profile)
            [[ $# -ge 2 ]] || { echo "--monitor-profile 缺少参数" >&2; exit 2; }
            MONITOR_PROFILE_REQUEST=$2
            shift 2
            ;;
        --list-monitor-profiles)
            monitor_create_pool_print_catalog
            exit 0
            ;;
        -h|--help)
            sed -n '2,10p' "$0"
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

if [[ -z "$VM_ID" || ! "$VM_ID" =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: $0 <vm_id> [--force] [--platform PLATFORM] [--ssd-profile PROFILE] [--gpu-profile PROFILE] [--monitor-profile PROFILE]" >&2
    exit 2
fi

mkdir -p "$VM_RUN_DIR"
exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -s "$STORAGE_LOCK_FD"
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
vm_storage_prepare
vm_storage_prepare_instance "$VM_ID"
CONF=$(vm_storage_config_path "$VM_ID")
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
            "${VGPU_PATCHED_DRIVER_INF:-}"
    )
    if (( ${#OLD_GPU_POLICY[@]} != 13 )); then
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
    unset OLD_GPU_POLICY

    if (( ! GPU_PROFILE_EXPLICIT )); then
        [[ -n "$OLD_GPU_PROFILE" ]] || {
            echo "旧 vm.conf 缺少 GPU_PROFILE，拒绝 --force 随机换卡；请显式传 --gpu-profile" >&2
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

    [[ -n "$PLATFORM_REQUEST" ]] || PLATFORM_REQUEST=$OLD_PLATFORM
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

# ─── 平台选择 ────────────────────────────────────────────────────────────────
mapfile -t PLATFORMS < <(hardware_profile_keys)
if [[ -n "$PLATFORM_REQUEST" ]]; then
    PLATFORM=$PLATFORM_REQUEST
else
    PLATFORM=${PLATFORMS[$((RANDOM % ${#PLATFORMS[@]}))]}
fi
hardware_profile_load "$PLATFORM" || exit $?
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
    done < <(ssd_default_profile_keys)
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

OUI=${INTEL_OUIS[$((RANDOM % ${#INTEL_OUIS[@]}))]}
if [[ -z "$GPU_PROFILE_REQUEST" ]]; then
    mapfile -t GPU_PROFILE_REQUESTS < <(vgpu_profile_keys)
    GPU_PROFILE_REQUEST=${GPU_PROFILE_REQUESTS[$((RANDOM % ${#GPU_PROFILE_REQUESTS[@]}))]}
fi
vgpu_profile_load "$GPU_PROFILE_REQUEST"

# New VMs always boot in the driver-safe B mode.  The target records whether
# this identity has a reviewed full-consumer driver path available; it does
# not silently enable A mode before that driver is actually staged and bound.
SPOOF_MODE=B
unset VGPU_MDEV_INTERNAL_PCI_IDENTITY VGPU_MDEV_FRL_ENABLED
unset VGPU_PATCHED_DRIVER_REQUIRED_VERSION
unset VGPU_PATCHED_DRIVER_VERSION VGPU_PATCHED_DRIVER_INF
case "$GPU_PROFILE" in
    gtx1050_2gb)
        VGPU_IDENTITY_TARGET=full-consumer
        VGPU_PATCHED_DRIVER_REQUIRED_VERSION=31.0.15.3833
        ;;
    gtx750ti_2gb|gt1030_2gb)
        VGPU_IDENTITY_TARGET=name-only
        ;;
    *)
        echo "GPU profile 缺少安全 identity policy: $GPU_PROFILE" >&2
        exit 1
        ;;
esac

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
MONITOR_SERIAL=$(monitor_profile_generate_serial "$MONITOR_SERIAL_PREFIX")
input_profile_pick_keyboard_random
input_profile_pick_tablet_random

VM_UUID=$(uuidgen)
SYS_SN=$(gen_id 10)
MB_SN=$(gen_id 12)
CHASSIS_SN=$(gen_id 8)
MEM_SN=$(gen_hex 8)
case "$SSD_PROFILE" in
    crucial-mx100-512gb)
        SSD_SN=$(gen_hex 12)
        ;;
    kingston-kc400-512gb)
        SSD_SN="50026B72$(gen_hex 8)"
        ;;
    intel-545s-512gb)
        if (( RANDOM % 2 )); then
            SSD_SN="BTLA$(gen_id 8)512DGN"
        else
            SSD_SN="PHLA$(gen_id 8)512DGN"
        fi
        ;;
    wd-pc-sa530-512gb)
        # SA530 field samples use a 12-character ATA serial.  Western Digital
        # does not publish a stricter per-model serial grammar.
        SSD_SN=$(gen_id 12)
        ;;
    wd-black-pcie-512gb)
        SSD_SN=$(gen_digits 12)
        ;;
    *)
        case "$SSD_BRAND" in
            Samsung) SSD_SN="S$(gen_id 15)" ;;
            Crucial) SSD_SN=$(gen_hex 16) ;;
            *)       SSD_SN=$(gen_id 16) ;;
        esac
        ;;
esac
VM_MAC="${OUI}:$(printf '%02X:%02X:%02X' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))"

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

CONF_TMP="$(dirname "$CONF")/.$(basename "$CONF").partial.$$.$RANDOM"
cleanup_create_vm() {
    rm -f -- "$CONF_TMP"
}
trap cleanup_create_vm EXIT

cat > "$CONF_TMP" <<EOF
# === 自动生成于 $(date -Iseconds) ===
# instances/vm${VM_ID}/vm.conf — 只读，任何时候修改都可能让 guest 内 license/driver
# / Windows 激活等失效。更换硬件指纹请用新 VM_ID + --force。

VM_ID=${VM_ID}
VM_UUID=${VM_UUID}
# Windows uses its normal local-RTC interpretation.  The launcher pins the
# QEMU process to Asia/Shanghai and supplies base=localtime; do not add
# RealTimeIsUniversal inside the guest.
RTC_CONTRACT=localtime
PLATFORM=${PLATFORM}
CPU_MODEL=${CPU_MODEL}
TSC_FREQ=${TSC_FREQ}

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

# Windows PCI PnP identity for the board xHCI controller.  These exact values
# are persisted so a future launcher/catalog update cannot re-enumerate it.
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
MEM_SPEED=${MEM_SPEED}
MEM_FAMILY=${MEM_FAMILY}
MEM_TYPE_BYTE=${MEM_TYPE_BYTE}
MEM_WIDTH=${MEM_WIDTH}
MEM_MODULE_MB=${MEM_MODULE_MB}
MEM_SLOTS=${MEM_SLOTS}
MEM_TOTAL_MB=${MEM_TOTAL_MB}
MEM_FORM_FACTOR=${MEM_FORM_FACTOR}
MEM_BOARD_SLOTS=${MEM_BOARD_SLOTS}
MEM_MAX_CAPACITY_GB=${MEM_MAX_CAPACITY_GB}
MEM_SN="${MEM_SN}"

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

GPU_PROFILE=${GPU_PROFILE}
# B 始终是新 VM 的安全启动模式。VGPU_IDENTITY_TARGET 记录最终身份策略；
# full-consumer 仍须先满足 required driver policy，不能据此自动切 A。
${GPU_POLICY_CONFIG}
VGPU_MDEV_PROFILE=${VGPU_MDEV_PROFILE}
VGPU_FB_MB=2048
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
GPU_MEMORY_MAKER=${GPU_MEMORY_MAKER}
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

# USB HID identity.  The native pointer remains usb-tablet (absolute
# coordinates) so the cursor can leave the viewer without relative grab.
KBD_VID=${KBD_VID}
KBD_PID=${KBD_PID}
KBD_MFR="${KBD_MFR}"
KBD_PRODUCT="${KBD_PRODUCT}"
TABLET_VID=${TABLET_VID}
TABLET_PID=${TABLET_PID}
TABLET_MFR="${TABLET_MFR}"
TABLET_PRODUCT="${TABLET_PRODUCT}"

VM_MAC=${VM_MAC}
EOF
chmod 444 "$CONF_TMP"
mv -T -- "$CONF_TMP" "$CONF"
trap - EXIT

printf '创建成功: %s\n' "$CONF"
printf '  平台:   %s (CPU %s, TSC %d Hz)\n' "$PLATFORM" "$CPU_MODEL" "$TSC_FREQ"
printf '  主板:   %s %s rev %s / %s，BIOS %s %s，TPM %s\n' \
    "$BOARD_BRAND" "$BOARD_MODEL" "$BOARD_REVISION" "$BOARD_CHIPSET" \
    "$BIOS_VER" "$BIOS_DATE" "$BOARD_TPM_VERSION"
printf '  内存:   %dx%d MiB（主板 %d 槽/最大 %d GiB） %s %s %s@%dMT/s (%d-bit %s)\n' \
    "$MEM_SLOTS" "$MEM_MODULE_MB" "$MEM_BOARD_SLOTS" "$MEM_MAX_CAPACITY_GB" \
    "$MEM_BRAND" "$MEM_MODEL" "$MEM_FAMILY" "$MEM_SPEED" "$MEM_WIDTH" \
    "$MEM_FORM_FACTOR"
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
printf '          B 模式 PCI identity 保持宿主 mdev；仅 A 模式使用 catalog %s:%s sub %s:%s\n' \
    "$GPU_PCI_VID" "$GPU_PCI_DID" "$GPU_SUB_VID" "$GPU_SUB_DID"
printf '          mdev 资源 fallback=%s/%d MB（宿主配置可覆盖）\n' \
    "$VGPU_MDEV_PROFILE" 2048
printf '  显示器: %s %s / %s（%s%s，%dx%d@%dHz，%dx%d mm，SN=%s）\n' \
    "$MONITOR_BRAND_NAME" "$MONITOR_MODEL_NAME" "$MONITOR_PROFILE" "$MONITOR_VENDOR" \
    "${MONITOR_PRODUCT_ID#0x}" "$MONITOR_NATIVE_X" "$MONITOR_NATIVE_Y" \
    "$MONITOR_REFRESH_HZ" "$MONITOR_WIDTH_MM" "$MONITOR_HEIGHT_MM" \
    "$MONITOR_SERIAL"
printf '  键盘:   %s（usb-kbd，USB %s:%s）\n' \
    "$KBD_PRODUCT" "${KBD_VID#0x}" "${KBD_PID#0x}"
printf '  鼠标:   %s（usb-tablet 绝对坐标，USB %s:%s）\n' \
    "$TABLET_PRODUCT" "${TABLET_VID#0x}" "${TABLET_PID#0x}"
printf '  MAC:    %s\n' "$VM_MAC"
printf '  UUID:   %s\n' "$VM_UUID"

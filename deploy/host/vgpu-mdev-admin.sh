#!/usr/bin/bash
# Narrow privileged helper for G-11 mdev lifecycle and per-VM identity.
#
# This file is installed root:root as
# /usr/local/libexec/qemu-vgpu-mdev-admin.  The matching sudoers rule may
# expose every command below to the VM launcher, so every argument and every
# filesystem target is validated again here.  No caller-provided path is ever
# written.
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 022

readonly INSTALLED_SELF=/usr/local/libexec/qemu-vgpu-mdev-admin
readonly DEFAULT_IDENTITY_HELPER=/usr/local/libexec/qemu-vgpu-mdev-identity.py
readonly DEFAULT_IDENTITY_CONFIG=/etc/vgpu_unlock/profile_override.toml
readonly DEFAULT_MDEV_BUS_DIR=/sys/class/mdev_bus
readonly DEFAULT_MDEV_DEVICES_DIR=/sys/bus/mdev/devices
readonly DEFAULT_NVIDIA_VERSION_FILE=/sys/module/nvidia/version
readonly DEFAULT_PROC_DIR=/proc
readonly DEFAULT_LOCK_FILE=/run/lock/qemu-vgpu-mdev-admin.lock
IDENTITY_TRANSACTION=

cleanup() {
    if [[ -n "$IDENTITY_TRANSACTION" ]]; then
        rm -f -- "$IDENTITY_TRANSACTION"
    fi
}
trap cleanup EXIT

# The source helper has a path-overridable mode for its unprivileged unit
# tests.  A root invocation, and the installed sudoers target in particular,
# always uses the fixed production paths above.
TEST_MODE=0
SELF_PATH=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || true)
if [[ "${VGPU_MDEV_ADMIN_TEST_MODE:-0}" == 1 &&
      "$SELF_PATH" != "$INSTALLED_SELF" ]]; then
    TEST_MODE=1
fi

if ((TEST_MODE)); then
    IDENTITY_HELPER=${VGPU_MDEV_ADMIN_IDENTITY_HELPER:?test identity helper is required}
    IDENTITY_CONFIG=${VGPU_MDEV_ADMIN_IDENTITY_CONFIG:?test identity config is required}
    MDEV_BUS_DIR=${VGPU_MDEV_ADMIN_BUS_DIR:?test mdev bus directory is required}
    MDEV_DEVICES_DIR=${VGPU_MDEV_ADMIN_DEVICES_DIR:?test mdev devices directory is required}
    NVIDIA_VERSION_FILE=${VGPU_MDEV_ADMIN_NVIDIA_VERSION_FILE:?test NVIDIA version file is required}
    PROC_DIR=${VGPU_MDEV_ADMIN_PROC_DIR:?test proc directory is required}
    LOCK_FILE=${VGPU_MDEV_ADMIN_LOCK_FILE:?test lock file is required}
else
    [[ $EUID -eq 0 ]] || {
        echo "vgpu-mdev-admin: production commands require root" >&2
        exit 1
    }
    IDENTITY_HELPER=$DEFAULT_IDENTITY_HELPER
    IDENTITY_CONFIG=$DEFAULT_IDENTITY_CONFIG
    MDEV_BUS_DIR=$DEFAULT_MDEV_BUS_DIR
    MDEV_DEVICES_DIR=$DEFAULT_MDEV_DEVICES_DIR
    NVIDIA_VERSION_FILE=$DEFAULT_NVIDIA_VERSION_FILE
    PROC_DIR=$DEFAULT_PROC_DIR
    LOCK_FILE=$DEFAULT_LOCK_FILE
fi

die() {
    echo "vgpu-mdev-admin: $*" >&2
    exit 1
}

valid_uuid() {
    [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

valid_bdf() {
    [[ "$1" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$ ]]
}

valid_type_id() {
    [[ "$1" =~ ^nvidia-[1-9][0-9]{0,9}$ ]]
}

valid_u32() {
    [[ "$1" =~ ^(0|[1-9][0-9]{0,9}|0[xX][0-9A-Fa-f]{1,8})$ ]] || return 1
    (( $1 >= 0 && $1 <= 0xffffffff ))
}

valid_identity_name() {
    local value=$1
    [[ -n "$value" && ${#value} -le 31 && "$value" != *$'\n'* &&
       "$value" != *$'\r'* && "$value" != *$'\t'* ]]
}

caller_uid_gid() {
    local uid=${SUDO_UID:-0} gid=${SUDO_GID:-0}
    [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] ||
        die "invalid sudo caller UID/GID"
    printf '%s:%s\n' "$uid" "$gid"
}

uuid_owner_pid() {
    local uuid=$1 cmdline pid
    for cmdline in "$PROC_DIR"/[0-9]*/cmdline; do
        [[ -r "$cmdline" ]] || continue
        if grep -aFq -- "/sys/bus/mdev/devices/$uuid" "$cmdline" 2>/dev/null; then
            pid=${cmdline#"$PROC_DIR"/}
            printf '%s\n' "${pid%/cmdline}"
            return 0
        fi
    done
    return 1
}

require_safe_identity_assets() {
    local config_dir helper_owner config_owner config_mode
    [[ -f "$IDENTITY_HELPER" && ! -L "$IDENTITY_HELPER" &&
       -x "$IDENTITY_HELPER" ]] || die "identity generator is missing or unsafe"
    [[ -f "$IDENTITY_CONFIG" && ! -L "$IDENTITY_CONFIG" ]] ||
        die "identity config is missing or unsafe"
    config_dir=$(dirname -- "$IDENTITY_CONFIG")
    [[ -d "$config_dir" && ! -L "$config_dir" ]] ||
        die "identity config directory is unsafe"
    if ((!TEST_MODE)); then
        helper_owner=$(stat -c %u -- "$IDENTITY_HELPER")
        config_owner=$(stat -c %u -- "$IDENTITY_CONFIG")
        config_mode=$(stat -c %a -- "$config_dir")
        [[ "$helper_owner" == 0 && "$config_owner" == 0 ]] ||
            die "identity assets must be root-owned"
        (( (8#$config_mode & 0022) == 0 )) ||
            die "identity config directory is group/world writable"
    fi
}

identity_update() {
    local action=$1 uuid=$2 name=${3:--}
    local pci_id=${4:--} pci_device_id=${5:--} frl=${6:--}
    local fb_bus=${7:--} ram_type=${8:--} memory_vendor=${9:--}
    local owner temporary config_dir
    local -a generator_args

    valid_uuid "$uuid" || die "invalid mdev UUID: $uuid"
    if owner=$(uuid_owner_pid "$uuid"); then
        die "mdev $uuid is owned by QEMU pid $owner"
    fi
    require_safe_identity_assets

    generator_args=(--config "$IDENTITY_CONFIG" --uuid "$uuid")
    case "$action" in
        identity-remove)
            [[ "$name" == - && "$pci_id" == - && "$pci_device_id" == - &&
               "$frl" == - && "$fb_bus" == - && "$ram_type" == - &&
               "$memory_vendor" == - ]] || die "identity-remove takes only UUID"
            generator_args+=(--remove)
            ;;
        identity-set)
            valid_identity_name "$name" || die "invalid GPU identity name"
            generator_args+=(--name "$name")
            if [[ "$pci_id" != - || "$pci_device_id" != - ]]; then
                [[ "$pci_id" != - && "$pci_device_id" != - ]] ||
                    die "PCI identity must be supplied as a pair"
                valid_u32 "$pci_id" && valid_u32 "$pci_device_id" ||
                    die "invalid PCI identity"
                generator_args+=(--pci-id "$pci_id" --pci-device-id "$pci_device_id")
            fi
            if [[ "$frl" != - ]]; then
                [[ "$frl" == 0 || "$frl" == 1 ]] || die "frl_enabled must be 0 or 1"
                generator_args+=(--frl-enabled "$frl")
            fi
            if [[ "$fb_bus" != - || "$ram_type" != - || "$memory_vendor" != - ]]; then
                [[ "$fb_bus" != - && "$ram_type" != - && "$memory_vendor" != - ]] ||
                    die "RM framebuffer identity must be a complete tuple"
                valid_u32 "$fb_bus" && valid_u32 "$ram_type" &&
                    valid_u32 "$memory_vendor" || die "invalid RM framebuffer identity"
                generator_args+=(
                    --rm-fb-bus-width "$fb_bus"
                    --rm-fb-ram-type "$ram_type"
                    --rm-fb-memory-vendor "$memory_vendor"
                )
            fi
            ;;
        *) die "internal identity action error" ;;
    esac

    config_dir=$(dirname -- "$IDENTITY_CONFIG")
    temporary=$(mktemp "$config_dir/.profile_override.XXXXXXXX") ||
        die "cannot create identity transaction"
    IDENTITY_TRANSACTION=$temporary
    /usr/bin/python3 "$IDENTITY_HELPER" "${generator_args[@]}" --output "$temporary"
    chmod 0644 "$temporary"
    if ((!TEST_MODE)); then
        chown root:root "$temporary"
    fi
    mv -fT -- "$temporary" "$IDENTITY_CONFIG"
    IDENTITY_TRANSACTION=
    echo "vgpu-mdev-admin: $action uuid=$uuid committed"
}

resolve_type_dir() {
    local bdf=$1 type_id=$2 parent type_dir vendor api
    valid_bdf "$bdf" || die "invalid NVIDIA parent BDF: $bdf"
    valid_type_id "$type_id" || die "invalid NVIDIA mdev type: $type_id"
    parent="$MDEV_BUS_DIR/$bdf"
    type_dir="$parent/mdev_supported_types/$type_id"
    [[ -d "$parent" && -d "$type_dir" ]] || die "mdev type does not exist"
    vendor=$(cat "$parent/vendor" 2>/dev/null || true)
    [[ "${vendor,,}" == 0x10de ]] || die "mdev parent is not NVIDIA"
    api=$(cat "$type_dir/device_api" 2>/dev/null || true)
    [[ "$api" == vfio-pci ]] || die "mdev type is not vfio-pci"
    printf '%s\n' "$type_dir"
}

chown_vfio_nodes() {
    local uuid=$1 owner group vfio_name found=0
    owner=$(caller_uid_gid)
    group=$(basename "$(readlink -f "$MDEV_DEVICES_DIR/$uuid/iommu_group" 2>/dev/null || true)")
    if [[ "$group" =~ ^[0-9]+$ && -c "/dev/vfio/$group" ]]; then
        chown "$owner" "/dev/vfio/$group"
        found=1
    fi
    for vfio_name in "$MDEV_DEVICES_DIR/$uuid"/vfio-dev/vfio*; do
        [[ -e "$vfio_name" ]] || continue
        vfio_name=${vfio_name##*/}
        if [[ "$vfio_name" =~ ^vfio[0-9]+$ && -c "/dev/vfio/devices/$vfio_name" ]]; then
            chown "$owner" "/dev/vfio/devices/$vfio_name"
            found=1
        fi
    done
    ((found)) || return 1
}

mdev_create() {
    local bdf=$1 type_id=$2 uuid=$3 type_dir existing_type attempt
    local newly_created=0
    valid_uuid "$uuid" || die "invalid mdev UUID: $uuid"
    type_dir=$(resolve_type_dir "$bdf" "$type_id")

    if [[ -L "$MDEV_DEVICES_DIR/$uuid" ]]; then
        existing_type=$(readlink -f "$MDEV_DEVICES_DIR/$uuid/mdev_type" 2>/dev/null || true)
        [[ "$existing_type" == "$(readlink -f "$type_dir")" ]] ||
            die "UUID already belongs to a different mdev type"
    else
        printf '%s\n' "$uuid" >"$type_dir/create"
        newly_created=1
    fi
    if ((TEST_MODE)); then
        echo "vgpu-mdev-admin: mdev-create uuid=$uuid test-write-complete"
        return 0
    fi
    for ((attempt=0; attempt<150; attempt++)); do
        if [[ -L "$MDEV_DEVICES_DIR/$uuid" ]] && chown_vfio_nodes "$uuid"; then
            echo "vgpu-mdev-admin: mdev-create uuid=$uuid owner=$(caller_uid_gid)"
            return 0
        fi
        sleep 0.02
    done
    # QEMU has not been handed the mdev yet. If this invocation created it
    # but VFIO never exposed an accessible node, restore the prior host state
    # instead of leaking an unusable mdev into the next launch attempt.
    if ((newly_created)) && [[ -e "$MDEV_DEVICES_DIR/$uuid/remove" ]]; then
        printf '1\n' >"$MDEV_DEVICES_DIR/$uuid/remove" || true
    fi
    die "mdev appeared without an accessible VFIO device node: $uuid"
}

mdev_remove() {
    local uuid=$1 owner
    valid_uuid "$uuid" || die "invalid mdev UUID: $uuid"
    [[ -L "$MDEV_DEVICES_DIR/$uuid" ]] || {
        echo "vgpu-mdev-admin: mdev-remove uuid=$uuid already-absent"
        return 0
    }
    if owner=$(uuid_owner_pid "$uuid"); then
        die "mdev $uuid is owned by QEMU pid $owner"
    fi
    [[ -e "$MDEV_DEVICES_DIR/$uuid/remove" ]] || die "mdev remove node is missing"
    printf '1\n' >"$MDEV_DEVICES_DIR/$uuid/remove"
    echo "vgpu-mdev-admin: mdev-remove uuid=$uuid requested"
}

console_interval() {
    local uuid=$1 interval=$2 frl=${3:-} version params
    valid_uuid "$uuid" || die "invalid mdev UUID: $uuid"
    [[ "$interval" =~ ^(0|[1-9][0-9]{0,6})$ ]] || die "invalid console interval"
    ((interval == 0)) && return 0
    ((interval >= 5000 && interval <= 1000000)) ||
        die "R535 console interval must be 5000..1000000us"
    # frame_rate_limiter 是布尔键：0 禁用 FRL，1 保持 profile 的 frlConfig。
    # 省略该参数时不写这个键，vGPU 保持 vgpuConfig.xml 的默认值。
    [[ -z "$frl" || "$frl" == 0 || "$frl" == 1 ]] ||
        die "frame_rate_limiter must be 0 or 1"
    version=$(cat "$NVIDIA_VERSION_FILE" 2>/dev/null || true)
    [[ "$version" == 535.* ]] || die "console interval is validated only for NVIDIA R535"
    params="$MDEV_DEVICES_DIR/$uuid/nvidia/vgpu_params"
    [[ -L "$MDEV_DEVICES_DIR/$uuid" && -e "$params" ]] ||
        die "mdev console parameter node is missing"
    if [[ -n "$frl" ]]; then
        printf 'intervaltime=%s,vgaintervaltime=%s,frame_rate_limiter=%s\n' \
            "$interval" "$interval" "$frl" >"$params"
    else
        printf 'intervaltime=%s,vgaintervaltime=%s\n' "$interval" "$interval" >"$params"
    fi
    echo "vgpu-mdev-admin: console-interval uuid=$uuid interval_us=$interval frl=${frl:-default}"
}

# vGPU 低负载时 SM 时钟会掉到最低档，交互场景表现为"动一下才升频"的迟滞。
# 锁定下限让每帧都在高频上渲染；上限保持硬件最大值，不动功耗墙。
gpu_clocks() {
    local action=$1 bdf=$2 maxsm minsm
    [[ "$bdf" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]] ||
        die "invalid PCI address: $bdf"
    command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi is unavailable"
    case "$action" in
        lock)
            maxsm=$(nvidia-smi -i "$bdf" --query-gpu=clocks.max.sm \
                --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
            [[ "$maxsm" =~ ^[0-9]+$ ]] || die "cannot read max SM clock for $bdf"
            minsm=$((maxsm * 64 / 100))
            nvidia-smi -i "$bdf" -lgc "${minsm},${maxsm}" >/dev/null 2>&1 ||
                die "failed to lock GPU clocks for $bdf"
            echo "vgpu-mdev-admin: gpu-clocks lock bdf=$bdf range=${minsm}-${maxsm}MHz"
            ;;
        reset)
            nvidia-smi -i "$bdf" -rgc >/dev/null 2>&1 ||
                die "failed to reset GPU clocks for $bdf"
            echo "vgpu-mdev-admin: gpu-clocks reset bdf=$bdf"
            ;;
        *) die "gpu-clocks action must be lock or reset" ;;
    esac
}

self_check() {
    [[ $# == 0 ]] || die "check takes no arguments"
    require_safe_identity_assets
    [[ -d "$MDEV_BUS_DIR" && -d "$MDEV_DEVICES_DIR" ]] ||
        die "mdev sysfs is unavailable"
    echo "vgpu-mdev-admin: schema=1 ready identity_config=$IDENTITY_CONFIG"
}

usage() {
    echo "usage: $INSTALLED_SELF {check|identity-set|identity-remove|mdev-create|mdev-remove|console-interval|gpu-clocks} ..." >&2
    exit 2
}

command -v flock >/dev/null 2>&1 || die "flock is unavailable"
mkdir -p -- "$(dirname -- "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -x -w 30 9 || die "timed out waiting for the mdev admin lock"

action=${1:-}
[[ -n "$action" ]] || usage
shift
case "$action" in
    check)
        self_check "$@"
        ;;
    identity-set)
        [[ $# == 8 ]] || usage
        identity_update identity-set "$@"
        ;;
    identity-remove)
        [[ $# == 1 ]] || usage
        identity_update identity-remove "$1"
        ;;
    mdev-create)
        [[ $# == 3 ]] || usage
        mdev_create "$@"
        ;;
    mdev-remove)
        [[ $# == 1 ]] || usage
        mdev_remove "$1"
        ;;
    console-interval)
        [[ $# == 2 || $# == 3 ]] || usage
        console_interval "$@"
        ;;
    gpu-clocks)
        [[ $# == 2 ]] || usage
        gpu_clocks "$@"
        ;;
    *) usage ;;
esac

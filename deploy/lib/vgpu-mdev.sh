# shellcheck shell=bash
# deploy/lib/vgpu-mdev.sh — vGPU mdev 分配/回收 helper
#
# 默认兼容本机 RTX 2080 魔改 16 GB / 1 GB 或 2 GB-per-VM 环境，但
# 物理 GPU、mdev type 和 guest 显卡身份不再绑定。Tesla V100 等卡应
# 通过 VGPU_RESOURCE_PROFILE 按 sysfs name 选择 type，不要猜 nvidia-NNN。
#
# 容量同时受两层保护：
#   * 只统计选定物理 GPU parent 下的活动 mdev；
#   * 校验 type/active mdev description 里的 framebuffer 与
#     available_instances。RTX 2080 unlock 环境仍保留可配置的显存硬上限。
#   * GPU passthrough **严禁**，永远走 mdev 拆分。
#
# API:
#   mdev_find_type <profile>        # 根据 profile 匹配 /sys 下的 type name
#   mdev_allocate <profile> <uuid> [framebuffer_mb] [guest_gpu_name]
#                 [vgpu_pci_id vgpu_pci_device_id] [frl_enabled]
#                 [rm_fb_bus_width rm_fb_ram_type rm_fb_memory_vendor]
#                                   # 用 <uuid> 在 type 下创建 mdev。
#                                   # 第 4 参数写入/移除 per-VM 名称；可选
#                                   # 的成对第 5/6 参数写入 vgpu_unlock
#                                   # 内部 vdev_id/pdev_id。可选第 7 参数
#                                   # 写 per-mdev frl_enabled；无 PCI ID 时
#                                   # 第 5/6 参数传空。完整 RM 显存描述使用
#                                   # 固定第 8-10 参数，第 5-7 参数可留空；
#                                   # 旧 1-7 参数兼容。
#   mdev_configure_console_interval <uuid> <microseconds>
#                                   # R535 console REGION copy 周期。
#   mdev_set_identity_override <uuid> <guest_gpu_name>
#                 [vgpu_pci_id vgpu_pci_device_id frl_enabled
#                  rm_fb_bus_width rm_fb_ram_type rm_fb_memory_vendor]
#                                   # VM 未运行时把 per-mdev contract 原子
#                                   # 恢复为 B；probe rollback 用。
#   mdev_release <uuid>             # VM 退出时拆除 mdev（通过 remove sysfs）
#   mdev_count_active [type_dir]    # 统计同一物理 GPU 下已分配的 mdev

: "${VGPU_MGPU:=0000:04:00.0}"      # 物理 GPU BDF；也可设 auto 后按 profile 唯一匹配
: "${VGPU_TYPES_DIR:=}"             # 测试/特殊拓扑可直接覆盖 type root
: "${MDEV_BUS_CLASS_DIR:=/sys/class/mdev_bus}"
: "${VGPU_TOTAL_FB_GB:=16}"         # 旧配置兼容
: "${VGPU_TOTAL_FB_MB:=$((VGPU_TOTAL_FB_GB * 1024))}"
: "${VGPU_PER_VM_FB_GB:=2}"         # 旧 API 未传 framebuffer_mb 时的 fallback
: "${VGPU_PER_VM_FB_MB:=$((VGPU_PER_VM_FB_GB * 1024))}"
: "${VGPU_CAPACITY_CHECK:=both}"    # both | framebuffer | sysfs | none
: "${VGPU_HOST_FB_MODE:=equal}"      # equal | mixed (V100 + R580 only)
: "${MDEV_DEVICES_DIR:=/sys/bus/mdev/devices}"
: "${MDEV_PROC_DIR:=/proc}"
: "${NVIDIA_MODULE_VERSION_FILE:=/sys/module/nvidia/version}"
: "${VGPU_HOST_LOCK_FILE:=/opt/nvidia-modes/state/current}"
: "${VGPU_HOST_LOCK_WAIT_SECONDS:=30}"
: "${VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG_PATH:=${VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG:-/etc/vgpu_unlock/profile_override.toml}}"
: "${VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG:=$VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG_PATH}"
: "${VGPU_MDEV_IDENTITY_MODE:=auto}" # auto | required | off
: "${VGPU_MDEV_ADMIN_HELPER:=/usr/local/libexec/qemu-vgpu-mdev-admin}"
: "${VGPU_MDEV_ADMIN_INSTALLER:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../host/install-vgpu-mdev-admin.sh}"
_MDEV_MANAGED_IDENTITY_CONFIG=/etc/vgpu_unlock/profile_override.toml
_MDEV_TRUSTED_IDENTITY_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../host/update-vgpu-mdev-identity.py"
# Internal state lets an EXIT cleanup reuse a lock already held by an
# interrupted allocator instead of waiting on a second flock owned by itself.
# Callers must treat values other than "held" as not safe for a locked helper.
_MDEV_HOST_LOCK_STATE=none
if [[ -z "${VGPU_MDEV_IDENTITY_HELPER:-}" ]]; then
    VGPU_MDEV_IDENTITY_HELPER=$_MDEV_TRUSTED_IDENTITY_HELPER
fi

mdev_err() { printf 'mdev: %s\n' "$*" >&2; }

_mdev_admin_available() {
    [[ -f "$VGPU_MDEV_ADMIN_HELPER" &&
       ! -L "$VGPU_MDEV_ADMIN_HELPER" &&
       -x "$VGPU_MDEV_ADMIN_HELPER" ]]
}

# Invoke only the installed, root-owned helper's validated verbs.  -n is
# deliberate: a missing/stale sudoers contract must fail in the terminal and
# must never open a graphical password dialog during VM startup or cleanup.
_mdev_admin_run() {
    _mdev_admin_available || {
        mdev_err "受限 mdev admin helper 未安装: $VGPU_MDEV_ADMIN_HELPER"
        mdev_err "一次性安装: sudo $VGPU_MDEV_ADMIN_INSTALLER"
        return 1
    }
    if (( EUID == 0 )); then
        "$VGPU_MDEV_ADMIN_HELPER" "$@"
    elif ! sudo -n -- "$VGPU_MDEV_ADMIN_HELPER" "$@"; then
        mdev_err "mdev admin helper/sudoers 未就绪（已禁止密码弹窗）"
        mdev_err "一次性修复: sudo $VGPU_MDEV_ADMIN_INSTALLER"
        return 1
    fi
}

_mdev_is_production_sysfs() {
    [[ "$MDEV_DEVICES_DIR" == /sys/bus/mdev/devices &&
       "$MDEV_BUS_CLASS_DIR" == /sys/class/mdev_bus &&
       "$NVIDIA_MODULE_VERSION_FILE" == /sys/module/nvidia/version ]]
}

mdev_uuid_in_use() {
    local uuid=$1 cmdline pid
    for cmdline in "$MDEV_PROC_DIR"/[0-9]*/cmdline; do
        [[ -r "$cmdline" ]] || continue
        if grep -aFq -- "/sys/bus/mdev/devices/$uuid" "$cmdline" 2>/dev/null; then
            pid=${cmdline#"$MDEV_PROC_DIR"/}
            printf '%s\n' "${pid%/cmdline}"
            return 0
        fi
    done
    return 1
}

# mdev create/remove, host driver mode switching and host GPU recovery use the
# persistent, root-owned mode-state file as their shared flock inode.  Opening
# it read-only lets an unprivileged VM launcher coordinate without truncating
# or replacing it; unlike /run, this inode also survives a host reboot.
_mdev_host_lock_acquire() {
    [[ "$_MDEV_HOST_LOCK_STATE" == none ]] || {
        mdev_err "vGPU host 全局锁状态不可重入: $_MDEV_HOST_LOCK_STATE"
        return 1
    }
    [[ "$VGPU_HOST_LOCK_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
        mdev_err "VGPU_HOST_LOCK_WAIT_SECONDS 必须是正整数: $VGPU_HOST_LOCK_WAIT_SECONDS"
        return 1
    }
    [[ -f "$VGPU_HOST_LOCK_FILE" && ! -L "$VGPU_HOST_LOCK_FILE" &&
       -r "$VGPU_HOST_LOCK_FILE" ]] || {
        mdev_err "vGPU host 全局锁缺失/不安全: $VGPU_HOST_LOCK_FILE（先初始化 gpu-mode）"
        return 1
    }
    command -v flock >/dev/null 2>&1 || {
        mdev_err "缺少 flock，不能安全分配/释放 mdev"
        return 1
    }

    _MDEV_HOST_LOCK_STATE=acquiring
    exec {MDEV_HOST_LOCK_FD}<"$VGPU_HOST_LOCK_FILE" || {
        _MDEV_HOST_LOCK_STATE=none
        mdev_err "无法打开 vGPU host 全局锁: $VGPU_HOST_LOCK_FILE"
        return 1
    }
    flock -x -w "$VGPU_HOST_LOCK_WAIT_SECONDS" "$MDEV_HOST_LOCK_FD" || {
        mdev_err "等待 vGPU host 全局锁超时: $VGPU_HOST_LOCK_FILE"
        exec {MDEV_HOST_LOCK_FD}<&-
        unset MDEV_HOST_LOCK_FD
        _MDEV_HOST_LOCK_STATE=none
        return 1
    }
    _MDEV_HOST_LOCK_STATE=held
}

_mdev_host_lock_release() {
    local rc=0
    if [[ -z "${MDEV_HOST_LOCK_FD:-}" ]]; then
        _MDEV_HOST_LOCK_STATE=none
        return 0
    fi
    _MDEV_HOST_LOCK_STATE=releasing
    flock -u "$MDEV_HOST_LOCK_FD" || rc=1
    exec {MDEV_HOST_LOCK_FD}<&- || rc=1
    unset MDEV_HOST_LOCK_FD
    _MDEV_HOST_LOCK_STATE=none
    return "$rc"
}

# sudo wrapper：先试 -n；失败则用 SUDO_PASSWORD；都不行就报错。
_mdev_sudo_write() {
    local content=$1 path=$2
    if sudo -n true 2>/dev/null; then
        printf '%s\n' "$content" | sudo tee -- "$path" >/dev/null 2>&1
    elif [[ -n "${SUDO_PASSWORD:-}" ]]; then
        {
            printf '%s\n' "$SUDO_PASSWORD"
            printf '%s\n' "$content"
        } | sudo -S -p '' tee -- "$path" >/dev/null 2>&1
    else
        mdev_err "写 $path 需要 sudo；请先 sudo -v 或设 SUDO_PASSWORD"
        return 1
    fi
}

_mdev_sudo_run() {
    if sudo -n true 2>/dev/null; then
        sudo -- "$@"
    elif [[ -n "${SUDO_PASSWORD:-}" ]]; then
        printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' -- "$@"
    else
        mdev_err "执行 host identity 更新需要 sudo；请先 sudo -v 或设 SUDO_PASSWORD"
        return 1
    fi
}

_mdev_sync_identity_override_locked() {
    local uuid=$1 identity_name=$2 config=$VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG
    local helper=$VGPU_MDEV_IDENTITY_HELPER directory temporary root_temporary
    local canonical_config canonical_helper trusted_helper used_admin=0
    local admin_pci_id admin_pci_device_id admin_frl admin_fb_bus
    local admin_ram_type admin_memory_vendor
    local -a helper_identity_args=()
    local identity_pci_id="" identity_pci_device_id="" identity_frl_enabled=""
    local identity_rm_fb_bus_width="" identity_rm_fb_ram_type=""
    local identity_rm_fb_memory_vendor=""

    case $# in
        2) ;;
        3) identity_frl_enabled=$3 ;;
        4)
            identity_pci_id=$3
            identity_pci_device_id=$4
            ;;
        5)
            identity_pci_id=$3
            identity_pci_device_id=$4
            identity_frl_enabled=$5
            ;;
        8)
            identity_pci_id=$3
            identity_pci_device_id=$4
            identity_frl_enabled=$5
            identity_rm_fb_bus_width=$6
            identity_rm_fb_ram_type=$7
            identity_rm_fb_memory_vendor=$8
            ;;
        *)
            mdev_err "per-mdev identity 参数必须是旧 name/PCI/FRL 合同或完整 RM FB 合同"
            return 1
            ;;
    esac
    if [[ -z "$identity_name" && $# -gt 2 ]]; then
        mdev_err "移除 per-mdev identity 时不能同时写 PCI/FRL/RM override"
        return 1
    fi
    if [[ -n "$identity_frl_enabled" &&
          "$identity_frl_enabled" != 0 && "$identity_frl_enabled" != 1 ]]; then
        mdev_err "per-mdev frl_enabled 必须是 0 或 1: $identity_frl_enabled"
        return 1
    fi
    if (( $# == 8 )) &&
            [[ -z "$identity_rm_fb_bus_width" ||
               -z "$identity_rm_fb_ram_type" ||
               -z "$identity_rm_fb_memory_vendor" ]]; then
        mdev_err "per-mdev RM FB 位宽、显存类型、显存厂商必须完整提供"
        return 1
    fi
    [[ "$config" == "$VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG_PATH" ]] || {
        mdev_err "identity config 路径与 hook 路径不一致: $config != $VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG_PATH"
        return 1
    }

    [[ -f "$config" && ! -L "$config" && -r "$config" ]] || {
        mdev_err "vgpu_unlock profile override 缺失/不安全: $config"
        return 1
    }
    [[ -f "$helper" && -r "$helper" ]] || {
        mdev_err "per-mdev identity helper 缺失: $helper"
        return 1
    }

    canonical_config=$(readlink -f -- "$config") || return 1
    canonical_helper=$(readlink -f -- "$helper") || return 1
    trusted_helper=$(readlink -f -- "$_MDEV_TRUSTED_IDENTITY_HELPER") || return 1
    if [[ "$canonical_config" == "$_MDEV_MANAGED_IDENTITY_CONFIG" &&
          "$canonical_helper" == "$trusted_helper" ]] &&
            _mdev_admin_available; then
        if [[ -n "$identity_name" ]]; then
            admin_pci_id=${identity_pci_id:--}
            admin_pci_device_id=${identity_pci_device_id:--}
            admin_frl=${identity_frl_enabled:--}
            admin_fb_bus=${identity_rm_fb_bus_width:--}
            admin_ram_type=${identity_rm_fb_ram_type:--}
            admin_memory_vendor=${identity_rm_fb_memory_vendor:--}
            _mdev_admin_run identity-set "$uuid" "$identity_name" \
                "$admin_pci_id" "$admin_pci_device_id" "$admin_frl" \
                "$admin_fb_bus" "$admin_ram_type" "$admin_memory_vendor" ||
                return 1
        else
            _mdev_admin_run identity-remove "$uuid" || return 1
        fi
        used_admin=1
    fi

    if ((used_admin == 0)); then
    directory=$(dirname "$config")
    if [[ -w "$directory" ]]; then
        temporary=$(mktemp "$directory/.profile_override.XXXXXXXX") || return 1
    else
        temporary=$(mktemp) || return 1
    fi
    root_temporary="$config.tmp.$$"
    if [[ -n "$identity_name" ]]; then
        helper_identity_args=(--name "$identity_name")
        if [[ -n "$identity_pci_id" ]]; then
            helper_identity_args+=(
                --pci-id "$identity_pci_id"
                --pci-device-id "$identity_pci_device_id"
            )
        fi
        if [[ -n "$identity_frl_enabled" ]]; then
            helper_identity_args+=(--frl-enabled "$identity_frl_enabled")
        fi
        if [[ -n "$identity_rm_fb_bus_width" ]]; then
            helper_identity_args+=(
                --rm-fb-bus-width "$identity_rm_fb_bus_width"
                --rm-fb-ram-type "$identity_rm_fb_ram_type"
                --rm-fb-memory-vendor "$identity_rm_fb_memory_vendor"
            )
        fi
        python3 "$helper" --config "$config" --output "$temporary" \
            --uuid "$uuid" "${helper_identity_args[@]}" || {
            rm -f "$temporary"
            return 1
        }
    else
        python3 "$helper" --config "$config" --output "$temporary" \
            --uuid "$uuid" --remove || {
            rm -f "$temporary"
            return 1
        }
    fi

    if [[ -w "$config" && -w "$directory" ]]; then
        chmod 0644 "$temporary" && mv -fT "$temporary" "$config" || {
            rm -f "$temporary"
            return 1
        }
    else
        [[ "$canonical_config" == "$_MDEV_MANAGED_IDENTITY_CONFIG" ]] || {
            mdev_err "拒绝 sudo 覆盖非受管 identity config: $canonical_config"
            rm -f "$temporary"
            return 1
        }
        [[ "$canonical_helper" == "$trusted_helper" ]] || {
            mdev_err "拒绝用非受信 helper 生成 root identity config: $canonical_helper"
            rm -f "$temporary"
            return 1
        }
        _mdev_sudo_run install -o root -g root -m 0644 \
            "$temporary" "$root_temporary" &&
        _mdev_sudo_run mv -fT "$root_temporary" "$config" || {
            _mdev_sudo_run rm -f "$root_temporary" >/dev/null 2>&1 || true
            rm -f "$temporary"
            return 1
        }
        rm -f "$temporary"
    fi
    fi
    if [[ -n "$identity_name" && -n "$identity_frl_enabled" &&
          -n "$identity_pci_id" ]]; then
        mdev_err "host per-mdev GPU identity 设置为 '$identity_name', vdev_id=$identity_pci_id, pdev_id=$identity_pci_device_id, frl_enabled=$identity_frl_enabled: $uuid"
    elif [[ -n "$identity_name" && -n "$identity_frl_enabled" ]]; then
        mdev_err "host per-mdev GPU identity 设置为 '$identity_name', frl_enabled=$identity_frl_enabled: $uuid"
    elif [[ -n "$identity_name" && -n "$identity_pci_id" ]]; then
        mdev_err "host per-mdev GPU identity 设置为 '$identity_name', vdev_id=$identity_pci_id, pdev_id=$identity_pci_device_id: $uuid"
    elif [[ -n "$identity_name" ]]; then
        mdev_err "host per-mdev GPU name 设置为 '$identity_name': $uuid"
    else
        mdev_err "host per-mdev GPU identity 已移除: $uuid"
    fi
    if [[ -n "$identity_name" ]]; then
        mdev_err "host per-mdev 显示合同：1 head / 1920x1080 / max_pixels=2073600: $uuid"
    fi
    if [[ -n "$identity_rm_fb_bus_width" ]]; then
        mdev_err "host per-mdev RM 显存合同：${identity_rm_fb_bus_width}-bit / RAM type ${identity_rm_fb_ram_type} / vendor ${identity_rm_fb_memory_vendor}: $uuid"
    fi
}

# Public, lock-safe B-contract reset used by the isolated signed-consumer probe.
# Refuse while QEMU owns the UUID.  If an unused mdev survived a prior failure,
# remove it before rewriting TOML: vgpu_unlock reads per-mdev identity while a
# fresh UUID is created, so reusing the old object would silently keep the old
# identity even though the configuration file looks correct.
mdev_set_identity_override() {
    local uuid=$1 identity_name=$2 owner_pid rc=0
    local -a identity_field_args=("${@:3}")

    case $# in
        2|3|4|5|8|10) ;;
        *)
            mdev_err "mdev_set_identity_override 参数合同非法"
            return 1
            ;;
    esac

    [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
        mdev_err "非法 mdev UUID: $uuid"
        return 1
    }
    [[ -n "$identity_name" ]] || {
        mdev_err "B identity 名称不能为空"
        return 1
    }

    _mdev_host_lock_acquire || return 1
    if owner_pid=$(mdev_uuid_in_use "$uuid"); then
        mdev_err "UUID $uuid 正被 PID $owner_pid 使用，拒绝在线修改 identity"
        rc=1
    elif [[ -L "$MDEV_DEVICES_DIR/$uuid" ]] &&
            ! _mdev_release_locked "$uuid"; then
        mdev_err "无法释放 probe 遗留的未占用 mdev: $uuid"
        rc=1
    elif [[ -L "$MDEV_DEVICES_DIR/$uuid" ]]; then
        mdev_err "mdev remove 返回后 UUID 仍存在，拒绝写入可误导的 identity: $uuid"
        rc=1
    elif ! _mdev_sync_identity_override_locked \
            "$uuid" "$identity_name" "${identity_field_args[@]}"; then
        rc=$?
        ((rc != 0)) || rc=1
    fi
    _mdev_host_lock_release || { ((rc != 0)) || rc=1; }
    return "$rc"
}

# profile 名 → NVIDIA vGPU type name 的关键子串。
# 本机实际 name 长这样 (见 `cat .../mdev_supported_types/nvidia-NNN/name`):
#   nvidia-256 = GRID RTX6000-1Q  (1 GB)
#   nvidia-257 = GRID RTX6000-2Q  (2 GB)  ← 本项目主用 (每 VM 2 GB)
#   nvidia-258 = GRID RTX6000-3Q  (3 GB)
#   nvidia-259 = GRID RTX6000-4Q  (4 GB)
_profile_to_keyword() {
    case "$1" in
        *_2gb|nvidia-257|2Q|RTX6000-2Q) echo "RTX6000-2Q" ;;
        gt740*_1gb|gt730*_1gb|gtx750*_1gb|nvidia-256|1Q|RTX6000-1Q) echo "RTX6000-1Q" ;;
        gt1030_4gb|nvidia-259|4Q|RTX6000-4Q)             echo "RTX6000-4Q" ;;
        3Q|RTX6000-3Q|nvidia-258)                        echo "RTX6000-3Q" ;;
        *)                                                echo "$1" ;;
    esac
}

# 列出可搜索的 mdev_supported_types root。指定 BDF 时只搜该卡；
# VGPU_MGPU=auto 时搜索所有 mdev parent，最后由 mdev_find_type 要求
# profile 只命中一张卡，避免静默选错 GPU。
mdev_type_roots() {
    local root parent found=0

    if [[ -n "$VGPU_TYPES_DIR" ]]; then
        [[ -d "$VGPU_TYPES_DIR" ]] || {
            mdev_err "mdev type 目录不存在: $VGPU_TYPES_DIR"
            return 1
        }
        printf '%s\n' "${VGPU_TYPES_DIR%/}"
        return 0
    fi

    if [[ "$VGPU_MGPU" != auto ]]; then
        [[ "$VGPU_MGPU" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$ ]] || {
            mdev_err "VGPU_MGPU 必须是完整 PCI BDF 或 auto: $VGPU_MGPU"
            return 1
        }
        root="/sys/bus/pci/devices/${VGPU_MGPU}/mdev_supported_types"
        [[ -d "$root" ]] || {
            mdev_err "GPU ${VGPU_MGPU} 没有 mdev_supported_types: $root"
            return 1
        }
        printf '%s\n' "$root"
        return 0
    fi

    for parent in "$MDEV_BUS_CLASS_DIR"/*; do
        root="$parent/mdev_supported_types"
        [[ -d "$root" ]] || continue
        printf '%s\n' "$root"
        found=1
    done
    (( found == 1 )) || {
        mdev_err "${MDEV_BUS_CLASS_DIR} 下没有可用的 mdev parent"
        return 1
    }
}

_mdev_legacy_type_id() {
    case "$1" in
        *_2gb|nvidia-257|2Q|RTX6000-2Q) echo nvidia-257 ;;
        gt740*_1gb|gt730*_1gb|gtx750*_1gb|nvidia-256|1Q|RTX6000-1Q) echo nvidia-256 ;;
        gt1030_4gb|nvidia-259|4Q|RTX6000-4Q)                         echo nvidia-259 ;;
        3Q|RTX6000-3Q|nvidia-258)                                    echo nvidia-258 ;;
        nvidia-[0-9]*)                                                echo "$1" ;;
        *)                                                            return 1 ;;
    esac
}

mdev_find_type() {
    # nvidia-NNN 仅作为旧 RTX 2080 环境的快速路径。V100 等新
    # backend 使用 sysfs 里的显示名（例如 V100-2Q/V100D-2Q），
    # 因为 nvidia-NNN 会随 SKU/驱动 profile 变化。名称可以带 shell glob，
    # 但最终必须全宿主唯一匹配。
    local profile=$1 keyword roots_output root type_dir type_id name canonical
    local profile_lc keyword_lc name_lc canonical_lc
    local -a roots=() matches=() match_names=()

    [[ -n "$profile" ]] || { mdev_err "mdev profile 不能为空"; return 1; }
    roots_output=$(mdev_type_roots) || return 1
    mapfile -t roots <<<"$roots_output"

    type_id=$(_mdev_legacy_type_id "$profile" 2>/dev/null || true)
    if [[ -n "$type_id" ]]; then
        for root in "${roots[@]}"; do
            type_dir="$root/$type_id"
            [[ -d "$type_dir" ]] || continue
            matches+=("$type_dir")
            match_names+=("$(cat "$type_dir/name" 2>/dev/null || echo unknown)")
        done
    fi

    if ((${#matches[@]} == 0)); then
        keyword=$(_profile_to_keyword "$profile")
        profile_lc=${profile,,}
        keyword_lc=${keyword,,}
        for root in "${roots[@]}"; do
            for type_dir in "$root"/*/; do
                [[ -d "$type_dir" ]] || continue
                name=$(cat "$type_dir/name" 2>/dev/null || true)
                [[ -n "$name" ]] || continue
                canonical=${name#GRID }
                name_lc=${name,,}
                canonical_lc=${canonical,,}

                if [[ "$name_lc" == $profile_lc ||
                      "$canonical_lc" == $profile_lc ||
                      "$name_lc" == *"$keyword_lc"* ||
                      "$canonical_lc" == *"$keyword_lc"* ]]; then
                    matches+=("${type_dir%/}")
                    match_names+=("$name")
                fi
            done
        done
    fi

    if ((${#matches[@]} == 1)); then
        printf '%s\n' "${matches[0]}"
        return 0
    fi
    if ((${#matches[@]} > 1)); then
        mdev_err "profile=$profile 匹配到多个 mdev type；请设 VGPU_MGPU=<BDF> 或使用更精确的名称"
        local i
        for ((i = 0; i < ${#matches[@]}; i++)); do
            mdev_err "  ${matches[i]} (${match_names[i]})"
        done
        return 1
    fi

    mdev_err "未找到 profile 对应的 type (profile=$profile)"
    return 1
}

# 从 NVIDIA type description 取实际 framebuffer。主路径是
# "framebuffer=2048M"；老驱动没有该字段时再用 -2Q/-4Q 名称兜底。
mdev_type_framebuffer_mb() {
    local type_dir=$1 description name value unit
    description=$(tr -d '\n' <"$type_dir/description" 2>/dev/null || true)
    if [[ "$description" =~ framebuffer[=:[:space:]]+([0-9]+)[[:space:]]*([KkMmGg]?) ]]; then
        value=${BASH_REMATCH[1]}
        unit=${BASH_REMATCH[2],,}
        case "$unit" in
            g) echo $((value * 1024)) ;;
            k) echo $(((value + 1023) / 1024)) ;;
            *) echo "$value" ;;
        esac
        return 0
    fi

    name=$(cat "$type_dir/name" 2>/dev/null || true)
    if [[ "$name" =~ -([0-9]+)[QqBbAaCc]$ ]]; then
        echo $((BASH_REMATCH[1] * 1024))
        return 0
    fi
    return 1
}

_mdev_parent_for_type() {
    local type_dir=$1
    readlink -f "$(dirname "$(dirname "$type_dir")")"
}

# Return the host NUMA node of an already-created mdev.  The mdev sysfs link
# resolves below its physical PCI parent, so this follows the allocation that
# QEMU will actually open instead of guessing from a configured BDF.
mdev_numa_node() {
    local uuid=$1 resolved parent node

    [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
        mdev_err "NUMA 查询收到非法 mdev UUID: $uuid"
        return 1
    }
    resolved=$(readlink -f "$MDEV_DEVICES_DIR/$uuid" 2>/dev/null) || return 1
    parent=$(dirname "$resolved")
    node=$(cat "$parent/numa_node" 2>/dev/null || true)
    [[ "$node" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$node"
}

mdev_validate_type_parent() {
    local type_dir=$1 parent vendor device_api
    parent=$(_mdev_parent_for_type "$type_dir") || return 1
    vendor=$(cat "$parent/vendor" 2>/dev/null || true)
    if [[ "${vendor,,}" != 0x10de ]]; then
        mdev_err "mdev parent 不是 NVIDIA (0x10de): ${parent} vendor=${vendor:-unknown}"
        return 1
    fi
    device_api=$(cat "$type_dir/device_api" 2>/dev/null || true)
    if [[ "$device_api" != vfio-pci ]]; then
        mdev_err "mdev type 不是 vfio-pci API: ${type_dir} api=${device_api:-unknown}"
        return 1
    fi
}

_mdev_active_on_parent() {
    local mdev_dir=$1 parent=$2 resolved
    resolved=$(readlink -f "$mdev_dir" 2>/dev/null || true)
    [[ -n "$resolved" && "$resolved" == "$parent"/* ]]
}

mdev_count_active() {
    local type_dir=${1:-} parent="" d n=0 roots_output
    [[ -d "$MDEV_DEVICES_DIR" ]] || { echo 0; return; }

    if [[ -n "$type_dir" ]]; then
        parent=$(_mdev_parent_for_type "$type_dir") || return 1
    else
        roots_output=$(mdev_type_roots) || return 1
        local -a roots=()
        mapfile -t roots <<<"$roots_output"
        if ((${#roots[@]} == 1)); then
            parent=$(readlink -f "$(dirname "${roots[0]}")")
        elif ((${#roots[@]} > 1)); then
            mdev_err "多 GPU 环境调用 mdev_count_active 必须传 type_dir"
            return 1
        fi
    fi

    for d in "$MDEV_DEVICES_DIR"/*; do
        [[ -L "$d" ]] || continue
        if [[ -z "$parent" ]] || _mdev_active_on_parent "$d" "$parent"; then
            n=$((n + 1))
        fi
    done
    echo "$n"
}

mdev_active_framebuffer_mb() {
    local type_dir=$1 fallback_mb=$2 parent d fb total=0
    parent=$(_mdev_parent_for_type "$type_dir") || return 1
    [[ -d "$MDEV_DEVICES_DIR" ]] || { echo 0; return; }

    for d in "$MDEV_DEVICES_DIR"/*; do
        [[ -L "$d" ]] || continue
        _mdev_active_on_parent "$d" "$parent" || continue
        fb=$(mdev_type_framebuffer_mb "$d/mdev_type" 2>/dev/null || true)
        [[ "$fb" =~ ^[1-9][0-9]*$ ]] || fb=$fallback_mb
        total=$((total + fb))
    done
    echo "$total"
}

# Read every active mdev's real type while the host allocation lock is held.
# Equal-size rejects a different amount; mixed-size still performs the full
# structural/framebuffer audit but permits 1Q+2Q after the R580 runtime mode is
# independently proven enabled.  Unreadable state always fails closed.
mdev_validate_active_framebuffer_tier() {
    local type_dir=$1 requested_fb_mb=$2 policy=${3:-equal}
    local parent d fb active_type active_name
    local resolved active_parent uuid

    [[ "$requested_fb_mb" =~ ^[1-9][0-9]*$ ]] || {
        mdev_err "请求 framebuffer 档位必须是正整数: $requested_fb_mb"
        return 1
    }
    case "$policy" in
        equal|mixed) ;;
        *)
            mdev_err "framebuffer policy 必须是 equal 或 mixed: $policy"
            return 1
            ;;
    esac
    parent=$(_mdev_parent_for_type "$type_dir") || return 1
    if [[ ! -d "$MDEV_DEVICES_DIR" || -L "$MDEV_DEVICES_DIR" ||
          ! -r "$MDEV_DEVICES_DIR" || ! -x "$MDEV_DEVICES_DIR" ]]; then
        mdev_err "mdev devices 目录缺失、不可遍历或不安全: $MDEV_DEVICES_DIR"
        return 1
    fi

    for d in "$MDEV_DEVICES_DIR"/*; do
        # An unmatched glob is the only valid non-entry.  Real mdev bus entries
        # are UUID symlinks; anything else means the active set is not safely
        # enumerable and must not be interpreted as an empty GPU.
        [[ -e "$d" || -L "$d" ]] || continue
        if [[ ! -L "$d" ]]; then
            mdev_err "mdev devices 目录含非符号链接条目，无法安全归属: $d"
            return 1
        fi
        uuid=$(basename -- "$d")
        if [[ ! "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
            mdev_err "mdev devices 目录含非法 UUID 条目: $uuid"
            return 1
        fi
        resolved=$(readlink -f "$d" 2>/dev/null || true)
        active_type=$(readlink -f "$d/mdev_type" 2>/dev/null || true)
        if [[ -z "$resolved" || ! -d "$resolved" ||
              "${resolved##*/}" != "$uuid" ||
              -z "$active_type" || ! -d "$active_type" ]]; then
            mdev_err "无法确认活动 mdev $uuid 的 parent/type 归属"
            return 1
        fi
        active_parent=$(_mdev_parent_for_type "$active_type" 2>/dev/null || true)
        if [[ -z "$active_parent" || "$active_parent" != "${resolved%/*}" ]]; then
            mdev_err "活动 mdev $uuid 的设备 parent 与 mdev_type 不一致"
            return 1
        fi
        # A fully resolved instance on another physical GPU is irrelevant to
        # this allocation.  Only that positive attribution may be skipped.
        [[ "$active_parent" == "$parent" ]] || continue
        fb=$(mdev_type_framebuffer_mb "$d/mdev_type" 2>/dev/null || true)
        if [[ ! "$fb" =~ ^[1-9][0-9]*$ ]]; then
            mdev_err "无法确认活动 mdev $(basename "$d") 的 framebuffer 档位: ${active_type:-unknown}"
            return 1
        fi
        if [[ "$policy" == equal ]] && (( fb != requested_fb_mb )); then
            active_name=$(cat "$d/mdev_type/name" 2>/dev/null || true)
            mdev_err "同一物理 GPU 禁止混合 framebuffer 档位: 活动 $(basename "$d")=${active_name:-$(basename "$active_type")}/${fb}MB，请求 ${requested_fb_mb}MB"
            return 1
        fi
    done
}

mdev_validate_mixed_size_runtime() {
    local type_dir=$1 parent bdf driver_version smi output

    driver_version=$(cat "$NVIDIA_MODULE_VERSION_FILE" 2>/dev/null || true)
    if [[ "$driver_version" != 580.* ]]; then
        mdev_err "mixed-size 仅在已验证的 NVIDIA R580 路径开放，当前 ${driver_version:-unknown}"
        return 1
    fi
    parent=$(_mdev_parent_for_type "$type_dir") || return 1
    bdf=$(basename -- "$parent")
    if _mdev_is_production_sysfs; then
        smi=/usr/bin/nvidia-smi
    else
        smi=${VGPU_NVIDIA_SMI_BIN:-nvidia-smi}
    fi
    [[ -x "$smi" ]] || {
        mdev_err "mixed-size 无法执行可信 nvidia-smi: $smi"
        return 1
    }
    output=$("$smi" -q -i "$bdf" 2>/dev/null) || {
        mdev_err "mixed-size 无法读取 GPU $bdf 的 vGPU capability/mode"
        return 1
    }
    if ! grep -Eqi 'Heterogeneous Time-Slice Sizes[[:space:]]*:[[:space:]]*Supported' \
            <<<"$output"; then
        mdev_err "GPU $bdf 未报告 Heterogeneous Time-Slice Sizes: Supported"
        return 1
    fi
    if ! grep -Eqi 'vGPU Heterogeneous Mode[[:space:]]*:[[:space:]]*Enabled' \
            <<<"$output"; then
        mdev_err "GPU $bdf 尚未启用 mixed-size；先执行受管的 nvidia-smi vgpu -shm 1 修复"
        return 1
    fi
}

mdev_validate_active_framebuffer_policy() {
    local type_dir=$1 requested_fb_mb=$2

    case "$VGPU_HOST_FB_MODE" in
        equal)
            mdev_validate_active_framebuffer_tier \
                "$type_dir" "$requested_fb_mb" equal
            ;;
        mixed)
            mdev_validate_mixed_size_runtime "$type_dir" &&
                mdev_validate_active_framebuffer_tier \
                    "$type_dir" "$requested_fb_mb" mixed
            ;;
        *)
            mdev_err "VGPU_HOST_FB_MODE 必须是 equal 或 mixed: $VGPU_HOST_FB_MODE"
            return 1
            ;;
    esac
}

# 锁定物理 GPU 的 SM 时钟下限。vGPU 在低负载时会掉到最低档，交互场景表现为
# "动一下才升频"的迟滞。失败一律非致命：这只是优化，不该挡住 VM 启动。
mdev_lock_gpu_clocks() {
    local bdf=${1:-}
    [[ "$bdf" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$ ]] || {
        mdev_err "跳过 GPU 时钟锁定：VGPU_MGPU 不是具体 BDF (${bdf:-unset})"
        return 0
    }
    _mdev_is_production_sysfs && _mdev_admin_available || return 0
    _mdev_admin_run gpu-clocks lock "$bdf" ||
        mdev_err "GPU 时钟锁定失败（非致命，继续启动）"
    return 0
}

mdev_configure_console_interval() {
    local uuid=$1 interval_us=$2 frl=${3:-}
    local mdev_dir=$MDEV_DEVICES_DIR/$uuid
    local params_path=$mdev_dir/nvidia/vgpu_params
    local driver_version

    [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
        mdev_err "非法 mdev UUID: $uuid"
        return 1
    }
    [[ "$interval_us" =~ ^(0|[1-9][0-9]{0,6})$ ]] || {
        mdev_err "console interval 必须是无前导零的整数微秒: $interval_us"
        return 1
    }
    (( interval_us == 0 )) && return 0
    if (( interval_us < 5000 || interval_us > 1000000 )); then
        mdev_err "NVIDIA R535 console interval 必须为 5000..1000000us: $interval_us"
        return 1
    fi
    # frame_rate_limiter：0 禁用 FRL（vGPU 输出跟随 guest 渲染帧率），
    # 1 保持 profile 的 frlConfig，空则不写该键。FRL 默认把 scanout 锁在
    # 60 FPS，与 QEMU 60Hz 的 QUERY_GFX_PLANE 同频不同步会产生拍频，
    # 实测只能接住约一半的帧。
    if [[ -n "$frl" && "$frl" != 0 && "$frl" != 1 ]]; then
        mdev_err "VGPU_FRAME_RATE_LIMITER 必须是 0 或 1: $frl"
        return 1
    fi
    [[ -L "$mdev_dir" && -e "$params_path" ]] || {
        mdev_err "mdev console 参数节点不存在: $params_path"
        return 1
    }

    driver_version=$(cat "$NVIDIA_MODULE_VERSION_FILE" 2>/dev/null || true)
    if [[ "$driver_version" != 535.* &&
          "${VGPU_CONSOLE_INTERVAL_FORCE:-0}" != 1 ]]; then
        mdev_err "跳过未验证的 console interval 参数: NVIDIA ${driver_version:-unknown}（仅 R535 已验证）"
        return 0
    fi

    # NVIDIA R535 的默认 console-copy / VGA-copy 周期都是 100000us，
    # 所以 QEMU 即使以 60Hz QUERY_GFX_PLANE，也只能看到约 10 个新帧/秒。
    # 这两个内部键必须在 QEMU 打开 mdev 之前一起设置。
    local params="intervaltime=${interval_us},vgaintervaltime=${interval_us}"
    [[ -z "$frl" ]] || params+=",frame_rate_limiter=${frl}"
    if _mdev_is_production_sysfs && _mdev_admin_available; then
        _mdev_admin_run console-interval "$uuid" "$interval_us" ${frl:+"$frl"} || {
            mdev_err "设置 R535 console REGION 周期失败"
            return 1
        }
    elif ! _mdev_sudo_write "$params" "$params_path"; then
        mdev_err "设置 R535 console REGION 周期失败"
        return 1
    fi
    mdev_err "R535 console REGION 周期=${interval_us}us FRL=${frl:-profile默认}（实验性内部参数）"
}

_mdev_allocate_locked() {
    local profile=$1 uuid=$2 requested_fb_mb=${3:-$VGPU_PER_VM_FB_MB}
    local identity_argument_present=0 identity_name=""
    local type_dir mdev_dir actual_fb_mb available fb_used existing_type
    local parent bdf type_id create_via_admin=0
    local -a identity_field_args=()

    if (( $# == 5 || $# == 8 || $# == 9 || $# > 10 )); then
        mdev_err "mdev_allocate identity 参数必须是旧 PCI/FRL 或完整 RM FB 合同"
        return 1
    fi

    if (( $# >= 4 )); then
        identity_argument_present=1
        identity_name=$4
    fi
    if (( $# == 6 || $# == 7 || $# == 10 )); then
        [[ -n "$identity_name" ]] || {
            mdev_err "mdev_allocate 写 PCI/FRL/RM identity 时 guest_gpu_name 不能为空"
            return 1
        }
        if [[ -n "$5" || -n "$6" ]]; then
            [[ -n "$5" && -n "$6" ]] || {
                mdev_err "mdev_allocate PCI identity 必须成对传入"
                return 1
            }
            identity_field_args=("$5" "$6")
        elif (( $# == 6 )); then
            mdev_err "mdev_allocate 第 5/6 参数不能同时为空"
            return 1
        fi
    fi
    if (( $# == 7 )); then
        [[ "$7" == 0 || "$7" == 1 ]] || {
            mdev_err "mdev_allocate frl_enabled 必须是 0 或 1: $7"
            return 1
        }
        identity_field_args+=("$7")
    fi
    if (( $# == 10 )); then
        if [[ -n "$7" && "$7" != 0 && "$7" != 1 ]]; then
            mdev_err "mdev_allocate frl_enabled 必须留空或为 0/1: $7"
            return 1
        fi
        if [[ -z "$8" || -z "$9" || -z "${10}" ]]; then
            mdev_err "mdev_allocate RM FB 位宽、显存类型、显存厂商必须完整提供"
            return 1
        fi
        # The full contract is positional so empty PCI/FRL placeholders are
        # preserved all the way into the atomic TOML generator.
        identity_field_args=("$5" "$6" "$7" "$8" "$9" "${10}")
    fi
    [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
        mdev_err "非法 mdev UUID: $uuid"
        return 1
    }
    [[ "$requested_fb_mb" =~ ^[1-9][0-9]*$ ]] || {
        mdev_err "framebuffer_mb 必须是正整数: $requested_fb_mb"
        return 1
    }
    [[ "$VGPU_TOTAL_FB_MB" =~ ^[1-9][0-9]*$ ]] || {
        mdev_err "VGPU_TOTAL_FB_MB 必须是正整数: $VGPU_TOTAL_FB_MB"
        return 1
    }
    case "$VGPU_CAPACITY_CHECK" in
        both|framebuffer|sysfs|none) ;;
        *) mdev_err "VGPU_CAPACITY_CHECK 必须是 both/framebuffer/sysfs/none"; return 1 ;;
    esac

    type_dir=$(mdev_find_type "$profile") || return 1
    mdev_validate_type_parent "$type_dir" || return 1
    actual_fb_mb=$(mdev_type_framebuffer_mb "$type_dir" 2>/dev/null || true)
    if [[ ! "$actual_fb_mb" =~ ^[1-9][0-9]*$ ]]; then
        mdev_err "无法从 $(basename "$type_dir")/description 确认 framebuffer"
        return 1
    fi
    if (( actual_fb_mb != requested_fb_mb )); then
        mdev_err "profile 显存不匹配: $profile 实际 ${actual_fb_mb}MB，请求 ${requested_fb_mb}MB"
        return 1
    fi
    mdev_validate_active_framebuffer_policy "$type_dir" "$requested_fb_mb" || return 1

    mdev_dir=$MDEV_DEVICES_DIR/$uuid
    if [[ -L "$mdev_dir" ]]; then
        local owner_pid
        existing_type=$(readlink -f "$mdev_dir/mdev_type" 2>/dev/null || true)
        if [[ -n "$existing_type" && "$existing_type" != "$(readlink -f "$type_dir")" ]]; then
            mdev_err "UUID $uuid 已属于其他 type: $existing_type"
            return 1
        fi
        if owner_pid=$(mdev_uuid_in_use "$uuid"); then
            mdev_err "UUID $uuid 正被 PID $owner_pid 使用，拒绝修改身份或复用"
            return 1
        fi
        if (( identity_argument_present )); then
            _mdev_sync_identity_override_locked \
                "$uuid" "$identity_name" "${identity_field_args[@]}" || return 1
        fi
        mdev_err "UUID $uuid 已存在，复用"
        echo "$uuid"
        return 0
    fi

    if [[ "$VGPU_CAPACITY_CHECK" == both || "$VGPU_CAPACITY_CHECK" == sysfs ]]; then
        available=$(cat "$type_dir/available_instances" 2>/dev/null || true)
        if [[ ! "$available" =~ ^[0-9]+$ ]]; then
            mdev_err "available_instances 不可读或格式错误: $type_dir"
            return 1
        fi
        if (( available < 1 )); then
            mdev_err "profile=$profile 已无可用实例"
            return 1
        fi
    fi

    # 按当前物理 parent 下各 active mdev 的实际 framebuffer 求和。
    # 这一层是 unlock 驱动错报 available_instances 时的必要保护，
    # 也避免另一张 GPU 上的 mdev 误占本卡容量。
    if [[ "$VGPU_CAPACITY_CHECK" == both || "$VGPU_CAPACITY_CHECK" == framebuffer ]]; then
        fb_used=$(mdev_active_framebuffer_mb "$type_dir" "$requested_fb_mb") || return 1
        if (( fb_used + requested_fb_mb > VGPU_TOTAL_FB_MB )); then
            mdev_err "超出物理显存上限: 已用 ${fb_used}MB + 请求 ${requested_fb_mb}MB > ${VGPU_TOTAL_FB_MB}MB"
            return 1
        fi
    fi

    if (( identity_argument_present )); then
        _mdev_sync_identity_override_locked \
            "$uuid" "$identity_name" "${identity_field_args[@]}" || return 1
    fi

    if _mdev_is_production_sysfs && _mdev_admin_available; then
        parent=$(_mdev_parent_for_type "$type_dir") || return 1
        bdf=$(basename -- "$parent")
        type_id=$(basename -- "$type_dir")
        _mdev_admin_run mdev-create "$bdf" "$type_id" "$uuid" || return 1
        create_via_admin=1
    else
        if ! _mdev_sudo_write "$uuid" "$type_dir/create"; then
            mdev_err "写入 $type_dir/create 失败"
            return 1
        fi
    fi

    # mdev 创建后内核自动生成 /dev/vfio/<iommu_group>，默认仅 root:root 0600，
    # 当前用户 (ubuntu) 打不开；直接 chown 给调用者，免改 udev 规则。
    local group
    group=$(basename "$(readlink -f "$mdev_dir/iommu_group" 2>/dev/null)") || true
    if ((create_via_admin == 0)) && [[ -n "$group" && -c "/dev/vfio/$group" ]]; then
        if sudo -n true 2>/dev/null; then
            sudo chown "$(id -u):$(id -g)" "/dev/vfio/$group" 2>/dev/null
        elif [[ -n "${SUDO_PASSWORD:-}" ]]; then
            echo "$SUDO_PASSWORD" | sudo -S chown "$(id -u):$(id -g)" "/dev/vfio/$group" 2>/dev/null
        fi
    fi

    echo "$uuid"
}

mdev_allocate() {
    local rc release_rc=0 uuid=${2:-} existed_before=0
    _mdev_host_lock_acquire || return 1
    # Take the ownership snapshot under the same host lock as create/remove.
    # Otherwise a concurrent creator of the same UUID could be mistaken for
    # an object owned by this call and be removed by the failure rollback.
    [[ -z "$uuid" || ! -L "$MDEV_DEVICES_DIR/$uuid" ]] || existed_before=1
    if _mdev_allocate_locked "$@"; then rc=0; else rc=$?; fi
    # A privileged create can succeed just before a later validation/helper
    # reports failure.  While the original host lock is still held, roll back
    # only a UUID that did not exist when this API call began.
    if ((rc != 0 && existed_before == 0)) &&
            [[ -n "$uuid" && -L "$MDEV_DEVICES_DIR/$uuid" ]]; then
        mdev_err "分配失败后检测到本次新建 mdev，执行锁内回滚: $uuid"
        if ! _mdev_release_locked "$uuid" ||
                [[ -L "$MDEV_DEVICES_DIR/$uuid" ]]; then
            mdev_err "分配失败后的 mdev 回滚未完成，保留上层 recovery 记录: $uuid"
        fi
    fi
    if _mdev_host_lock_release; then
        release_rc=0
    else
        release_rc=$?
        ((release_rc != 0)) || release_rc=1
    fi
    # A successful create followed by a lock-release error is still an API
    # failure.  Reacquire before best-effort rollback; start-vm's pending-new
    # recovery guard covers the exceptional case where reacquire also fails.
    if ((rc == 0 && release_rc != 0)); then
        rc=$release_rc
        if ((existed_before == 0)) && [[ -n "$uuid" ]]; then
            mdev_err "分配完成但 host 锁释放失败，尝试重新加锁回滚: $uuid"
            if _mdev_host_lock_acquire; then
                if [[ -L "$MDEV_DEVICES_DIR/$uuid" ]] &&
                        ! _mdev_release_locked "$uuid"; then
                    mdev_err "host 锁异常后的 mdev 回滚失败: $uuid"
                elif [[ -L "$MDEV_DEVICES_DIR/$uuid" ]]; then
                    mdev_err "host 锁异常后的 mdev remove 返回成功但 UUID 仍存在: $uuid"
                fi
                _mdev_host_lock_release ||
                    mdev_err "mdev 回滚后 host 锁仍无法释放: $uuid"
            else
                mdev_err "无法重新取得 host 锁；由上层 recovery 守卫处理: $uuid"
            fi
        fi
    fi
    return "$rc"
}

_mdev_release_locked() {
    local uuid=$1
    local mdev_dir=$MDEV_DEVICES_DIR/$uuid
    [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
        mdev_err "非法 mdev UUID: $uuid"
        return 1
    }
    [[ -L "$mdev_dir" ]] || return 0
    if _mdev_is_production_sysfs && _mdev_admin_available; then
        _mdev_admin_run mdev-remove "$uuid"
    else
        _mdev_sudo_write 1 "$mdev_dir/remove"
    fi
}

mdev_release() {
    local rc
    _mdev_host_lock_acquire || return 1
    if _mdev_release_locked "$@"; then rc=0; else rc=$?; fi
    _mdev_host_lock_release || { ((rc != 0)) || rc=1; }
    return "$rc"
}

# Resolve the start-vm allocation handoff without guessing ownership.  The
# caller records pending-new/pending-existing before mdev_allocate and changes
# it to active only after the API succeeds.  During an EXIT trap the allocator
# may still own the host lock, so use the locked primitive only in that exact
# state; acquiring/releasing are deliberately left for recovery instead of
# risking an unsafe mutation or a self-deadlock.
mdev_cleanup_allocation_state() {
    local state=$1 uuid=$2 recovery_file=${3:-}
    local release_required=0 release_ok=0

    [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
        mdev_err "cleanup 收到非法 mdev UUID: $uuid"
        return 1
    }
    case "$state" in
        active)
            release_required=1
            ;;
        pending-new)
            [[ ! -L "$MDEV_DEVICES_DIR/$uuid" ]] || release_required=1
            ;;
        pending-existing)
            # The failed launch never owned this pre-existing object.
            return 0
            ;;
        *)
            mdev_err "未知 mdev cleanup 状态: $state"
            return 1
            ;;
    esac

    if ((release_required)); then
        case "${_MDEV_HOST_LOCK_STATE:-none}" in
            held)
                if _mdev_release_locked "$uuid"; then release_ok=1; fi
                ;;
            none)
                if mdev_release "$uuid"; then release_ok=1; fi
                ;;
            *)
                mdev_err "host 锁处于 ${_MDEV_HOST_LOCK_STATE:-unknown}，保留 recovery 记录: $uuid"
                ;;
        esac
        if ((release_ok)) && [[ ! -L "$MDEV_DEVICES_DIR/$uuid" ]]; then
            if [[ -n "$recovery_file" ]] && ! rm -f -- "$recovery_file"; then
                mdev_err "mdev 已回收但 recovery 记录无法删除: $recovery_file"
                return 1
            fi
            return 0
        fi
        if [[ -n "$recovery_file" ]]; then
            mdev_err "mdev 回收失败，保留 $recovery_file ($uuid)"
        else
            mdev_err "mdev 回收失败，UUID=$uuid（恢复记录尚未建立）"
        fi
        return 1
    fi

    # pending-new can fail before the kernel object appears.  Its prewritten
    # marker is then stale and safe to remove.
    if [[ -n "$recovery_file" ]] && ! rm -f -- "$recovery_file"; then
        mdev_err "未创建 mdev，但 recovery 记录无法删除: $recovery_file"
        return 1
    fi
}

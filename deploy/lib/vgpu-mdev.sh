# shellcheck shell=bash
# deploy/lib/vgpu-mdev.sh — vGPU mdev 分配/回收 helper
#
# 默认仍兼容本机 RTX 2080 魔改 16 GB / 2 GB-per-VM 环境，但
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
#                                   # 用 <uuid> 在 type 下创建 mdev。
#                                   # 第 4 参数写入/移除 per-VM 名称；可选
#                                   # 的成对第 5/6 参数写入 vgpu_unlock
#                                   # 内部 vdev_id/pdev_id。可选第 7 参数
#                                   # 写 per-mdev frl_enabled；无 PCI ID 时
#                                   # 第 5/6 参数传空。旧 1-6 参数兼容。
#   mdev_configure_console_interval <uuid> <microseconds>
#                                   # R535 console REGION copy 周期。
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
: "${MDEV_DEVICES_DIR:=/sys/bus/mdev/devices}"
: "${MDEV_PROC_DIR:=/proc}"
: "${NVIDIA_MODULE_VERSION_FILE:=/sys/module/nvidia/version}"
: "${VGPU_HOST_LOCK_FILE:=/opt/nvidia-modes/state/current}"
: "${VGPU_HOST_LOCK_WAIT_SECONDS:=30}"
: "${VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG_PATH:=${VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG:-/etc/vgpu_unlock/profile_override.toml}}"
: "${VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG:=$VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG_PATH}"
: "${VGPU_MDEV_IDENTITY_MODE:=auto}" # auto | required | off
_MDEV_MANAGED_IDENTITY_CONFIG=/etc/vgpu_unlock/profile_override.toml
_MDEV_TRUSTED_IDENTITY_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../host/update-vgpu-mdev-identity.py"
if [[ -z "${VGPU_MDEV_IDENTITY_HELPER:-}" ]]; then
    VGPU_MDEV_IDENTITY_HELPER=$_MDEV_TRUSTED_IDENTITY_HELPER
fi

mdev_err() { printf 'mdev: %s\n' "$*" >&2; }

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

    exec {MDEV_HOST_LOCK_FD}<"$VGPU_HOST_LOCK_FILE" || {
        mdev_err "无法打开 vGPU host 全局锁: $VGPU_HOST_LOCK_FILE"
        return 1
    }
    flock -x -w "$VGPU_HOST_LOCK_WAIT_SECONDS" "$MDEV_HOST_LOCK_FD" || {
        mdev_err "等待 vGPU host 全局锁超时: $VGPU_HOST_LOCK_FILE"
        exec {MDEV_HOST_LOCK_FD}<&-
        unset MDEV_HOST_LOCK_FD
        return 1
    }
}

_mdev_host_lock_release() {
    local rc=0
    [[ -n "${MDEV_HOST_LOCK_FD:-}" ]] || return 0
    flock -u "$MDEV_HOST_LOCK_FD" || rc=1
    exec {MDEV_HOST_LOCK_FD}<&- || rc=1
    unset MDEV_HOST_LOCK_FD
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
    local canonical_config canonical_helper trusted_helper
    local -a helper_identity_args=()
    local identity_pci_id="" identity_pci_device_id="" identity_frl_enabled=""

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
        *)
            mdev_err "per-mdev identity 参数必须是 name、name+FRL、name+PCI pair 或 name+PCI pair+FRL"
            return 1
            ;;
    esac
    if [[ -z "$identity_name" && $# -gt 2 ]]; then
        mdev_err "移除 per-mdev identity 时不能同时写 PCI/FRL override"
        return 1
    fi
    if [[ -n "$identity_frl_enabled" &&
          "$identity_frl_enabled" != 0 && "$identity_frl_enabled" != 1 ]]; then
        mdev_err "per-mdev frl_enabled 必须是 0 或 1: $identity_frl_enabled"
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
        canonical_config=$(readlink -f -- "$config") || {
            rm -f "$temporary"
            return 1
        }
        canonical_helper=$(readlink -f -- "$helper") || {
            rm -f "$temporary"
            return 1
        }
        trusted_helper=$(readlink -f -- "$_MDEV_TRUSTED_IDENTITY_HELPER") || {
            rm -f "$temporary"
            return 1
        }
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
}

# profile 名 → NVIDIA vGPU type name 的关键子串。
# 本机实际 name 长这样 (见 `cat .../mdev_supported_types/nvidia-NNN/name`):
#   nvidia-256 = GRID RTX6000-1Q  (1 GB)
#   nvidia-257 = GRID RTX6000-2Q  (2 GB)  ← 本项目主用 (每 VM 2 GB)
#   nvidia-258 = GRID RTX6000-3Q  (3 GB)
#   nvidia-259 = GRID RTX6000-4Q  (4 GB)
_profile_to_keyword() {
    case "$1" in
        gtx750ti_2gb|gtx1050_2gb|gt1030_2gb|nvidia-257|2Q|RTX6000-2Q) echo "RTX6000-2Q" ;;
        gt1030_4gb|nvidia-259|4Q|RTX6000-4Q)             echo "RTX6000-4Q" ;;
        1Q|RTX6000-1Q|nvidia-256)                        echo "RTX6000-1Q" ;;
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
        gtx750ti_2gb|gtx1050_2gb|gt1030_2gb|nvidia-257|2Q|RTX6000-2Q) echo nvidia-257 ;;
        gt1030_4gb|nvidia-259|4Q|RTX6000-4Q)                         echo nvidia-259 ;;
        1Q|RTX6000-1Q|nvidia-256)                                    echo nvidia-256 ;;
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

mdev_configure_console_interval() {
    local uuid=$1 interval_us=$2
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
    _mdev_sudo_write \
        "intervaltime=${interval_us},vgaintervaltime=${interval_us}" \
        "$params_path" || {
        mdev_err "设置 R535 console REGION 周期失败"
        return 1
    }
    mdev_err "R535 console REGION 周期=${interval_us}us（实验性内部参数）"
}

_mdev_allocate_locked() {
    local profile=$1 uuid=$2 requested_fb_mb=${3:-$VGPU_PER_VM_FB_MB}
    local identity_argument_present=0 identity_name=""
    local type_dir mdev_dir actual_fb_mb available fb_used existing_type
    local -a identity_field_args=()

    if (( $# == 5 || $# > 7 )); then
        mdev_err "mdev_allocate identity 参数必须是成对 PCI ID，可再带第 7 参数 FRL"
        return 1
    fi

    if (( $# >= 4 )); then
        identity_argument_present=1
        identity_name=$4
    fi
    if (( $# == 6 || $# == 7 )); then
        [[ -n "$identity_name" ]] || {
            mdev_err "mdev_allocate 写 PCI/FRL identity 时 guest_gpu_name 不能为空"
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

    if ! _mdev_sudo_write "$uuid" "$type_dir/create"; then
        mdev_err "写入 $type_dir/create 失败"
        return 1
    fi

    # mdev 创建后内核自动生成 /dev/vfio/<iommu_group>，默认仅 root:root 0600，
    # 当前用户 (ubuntu) 打不开；直接 chown 给调用者，免改 udev 规则。
    local group
    group=$(basename "$(readlink -f "$mdev_dir/iommu_group" 2>/dev/null)") || true
    if [[ -n "$group" && -c "/dev/vfio/$group" ]]; then
        if sudo -n true 2>/dev/null; then
            sudo chown "$(id -u):$(id -g)" "/dev/vfio/$group" 2>/dev/null
        elif [[ -n "${SUDO_PASSWORD:-}" ]]; then
            echo "$SUDO_PASSWORD" | sudo -S chown "$(id -u):$(id -g)" "/dev/vfio/$group" 2>/dev/null
        fi
    fi

    echo "$uuid"
}

mdev_allocate() {
    local rc
    _mdev_host_lock_acquire || return 1
    if _mdev_allocate_locked "$@"; then rc=0; else rc=$?; fi
    _mdev_host_lock_release || { ((rc != 0)) || rc=1; }
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
    _mdev_sudo_write 1 "$mdev_dir/remove"
}

mdev_release() {
    local rc
    _mdev_host_lock_acquire || return 1
    if _mdev_release_locked "$@"; then rc=0; else rc=$?; fi
    _mdev_host_lock_release || { ((rc != 0)) || rc=1; }
    return "$rc"
}

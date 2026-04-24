# shellcheck shell=bash
# deploy/lib/vgpu-mdev.sh — vGPU mdev 分配/回收 helper
#
# 约束 (来自本项目 memory):
#   * 宿主 RTX 2080 是魔改 16 GB 版本；多 VM 总显存按 16 GB 上限计算，
#     不信任 sysfs 里的 available_instances（nvidia 驱动会错报）。
#   * GPU passthrough **严禁**，永远走 mdev 拆分。
#
# API:
#   mdev_find_type <profile>        # 根据 profile 匹配 /sys 下的 type name
#   mdev_allocate <profile> <uuid>  # 用 <uuid> 在 type 下创建 mdev，
#                                   # 如果已存在直接复用。
#   mdev_release <uuid>             # VM 退出时拆除 mdev（通过 remove sysfs）
#   mdev_count_active               # 统计当前已分配的 mdev 数（用于 16 GB cap 检查）

: "${VGPU_MGPU:=0000:04:00.0}"      # 物理 GPU BDF，按环境覆盖 (本机 RTX 2080)
: "${VGPU_TYPES_DIR:=/sys/bus/pci/devices/${VGPU_MGPU}/mdev_supported_types}"
: "${VGPU_TOTAL_FB_GB:=16}"         # 物理卡真实可用显存 (RTX 2080 魔改)
: "${VGPU_PER_VM_FB_GB:=2}"         # 每个 VM 要 2 GB

mdev_err() { printf 'mdev: %s\n' "$*" >&2; }

# sudo wrapper：先试 -n；失败则用 SUDO_PASSWORD；都不行就报错。
_mdev_sudo_write() {
    local content=$1 path=$2
    if sudo -n true 2>/dev/null; then
        echo "$content" | sudo tee "$path" >/dev/null 2>&1
    elif [[ -n "${SUDO_PASSWORD:-}" ]]; then
        echo "$SUDO_PASSWORD" | sudo -S sh -c "echo '$content' > '$path'" 2>/dev/null
    else
        mdev_err "写 $path 需要 sudo；请先 sudo -v 或设 SUDO_PASSWORD"
        return 1
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
        gtx1050_2gb|gt1030_2gb|nvidia-257|2Q|RTX6000-2Q) echo "RTX6000-2Q" ;;
        gt1030_4gb|nvidia-259|4Q|RTX6000-4Q)             echo "RTX6000-4Q" ;;
        1Q|RTX6000-1Q|nvidia-256)                        echo "RTX6000-1Q" ;;
        3Q|RTX6000-3Q|nvidia-258)                        echo "RTX6000-3Q" ;;
        *)                                                echo "$1" ;;
    esac
}

mdev_find_type() {
    # Prefer exact nvidia-NNN id match when it's spelled out in the profile;
    # fall back to name-keyword matching. The name in /sys was historically
    # "GRID RTX6000-XQ" upstream; we rewrote vgpuConfig.xml to "NVIDIA
    # GeForce GT 1030" for stealth (hides the RTX6000 tag in 鲁大师/NVAPI),
    # which breaks pure-name matching — so the id path is load-bearing.
    local profile=$1 keyword type_dir
    case "$profile" in
        gtx1050_2gb|gt1030_2gb|nvidia-257|2Q|RTX6000-2Q) type_dir="$VGPU_TYPES_DIR/nvidia-257" ;;
        gt1030_4gb|nvidia-259|4Q|RTX6000-4Q)             type_dir="$VGPU_TYPES_DIR/nvidia-259" ;;
        1Q|RTX6000-1Q|nvidia-256)                        type_dir="$VGPU_TYPES_DIR/nvidia-256" ;;
        3Q|RTX6000-3Q|nvidia-258)                        type_dir="$VGPU_TYPES_DIR/nvidia-258" ;;
        *)                                                type_dir="" ;;
    esac
    if [[ -n "$type_dir" && -d "$type_dir" ]]; then
        echo "$type_dir"
        return 0
    fi

    # Fallback: keyword search by displayed name.
    keyword=$(_profile_to_keyword "$profile")
    for type_dir in "$VGPU_TYPES_DIR"/*/; do
        [[ -d "$type_dir" ]] || continue
        local name
        name=$(cat "$type_dir/name" 2>/dev/null || true)
        if [[ "$name" == *"$keyword"* ]]; then
            echo "${type_dir%/}"
            return 0
        fi
    done
    mdev_err "未找到 profile 对应的 type (profile=$profile keyword=$keyword)，查 $VGPU_TYPES_DIR"
    return 1
}

mdev_count_active() {
    local n=0
    [[ -d /sys/bus/mdev/devices ]] || { echo 0; return; }
    for d in /sys/bus/mdev/devices/*; do
        [[ -L "$d" ]] && n=$((n + 1))
    done
    echo "$n"
}

mdev_allocate() {
    local profile=$1 uuid=$2
    local type_dir mdev_dir
    type_dir=$(mdev_find_type "$profile") || return 1
    mdev_dir=/sys/bus/mdev/devices/$uuid

    if [[ -L "$mdev_dir" ]]; then
        mdev_err "UUID $uuid 已存在，复用"
        echo "$uuid"
        return 0
    fi

    # 16 GB 硬上限检查 (memory: 魔改 16 GB / 不信 available_instances)
    local active=$((`mdev_count_active`))
    local fb_used=$((active * VGPU_PER_VM_FB_GB))
    if (( fb_used + VGPU_PER_VM_FB_GB > VGPU_TOTAL_FB_GB )); then
        mdev_err "超出物理显存上限: 已用 ${fb_used} GB + 请求 ${VGPU_PER_VM_FB_GB} GB > ${VGPU_TOTAL_FB_GB} GB"
        return 1
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

mdev_release() {
    local uuid=$1
    local mdev_dir=/sys/bus/mdev/devices/$uuid
    [[ -L "$mdev_dir" ]] || return 0
    _mdev_sudo_write 1 "$mdev_dir/remove" || true
}

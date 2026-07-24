#!/usr/bin/env bash
# base 镜像生命周期使用的启动盘字段适配器。
#
# NVME_POOL 同时包含稳定 component ID、Guest 型号、固件、容量和 PCI 身份；
# base 容量护栏只读取前四列，但必须按当前目录布局准确解析。clone 则只认
# PLATFORM_BOOT_STORAGE 指向的 BOOT_STORAGE_*，不能把 SATA 平台的 data-only
# NVME_* 误当成系统盘。

if [[ "${_BASE_BOOT_STORAGE_LOADED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317 # source guard 兼容直接执行诊断。
    return 0 2>/dev/null || exit 0
fi
_BASE_BOOT_STORAGE_LOADED=1

_base_boot_storage_positive_size() {
    local size="${1:-}"
    [[ "$size" =~ ^[0-9]+$ ]] && (( size > 0 ))
}

# 解析当前 NVME_POOL 行：
# component_id|model|firmware|size_bytes|...
#
# 结果通过固定变量返回，避免调用方再次复制容易错位的 IFS read。允许尾部新增列，
# 但前四个稳定字段必须完整且容量必须是正整数。
base_boot_storage_parse_nvme_pool_row() {
    local row="${1:-}"
    local -a columns=()

    IFS='|' read -r -a columns <<<"$row"
    if (( ${#columns[@]} < 4 )); then
        echo "ERROR: NVME_POOL 行少于四列: $row" >&2
        return 1
    fi

    BASE_NVME_COMPONENT_ID="${columns[0]}"
    BASE_NVME_MODEL="${columns[1]}"
    BASE_NVME_FIRMWARE="${columns[2]}"
    BASE_NVME_SIZE_BYTES="${columns[3]}"

    if [[ -z "$BASE_NVME_COMPONENT_ID" ||
          -z "$BASE_NVME_MODEL" ||
          -z "$BASE_NVME_FIRMWARE" ]] ||
       ! _base_boot_storage_positive_size "$BASE_NVME_SIZE_BYTES"; then
        echo "ERROR: NVME_POOL 前四列不完整或容量非法: $row" >&2
        return 1
    fi
}

# 从当前 profile 构建唯一的“启动盘视图”。NVMe 平台和 SATA/AHCI 平台都使用
# 独立 BOOT_STORAGE_*；PLATFORM_BOOT_STORAGE 只负责声明实际启动总线。
base_boot_storage_load_profile_view() {
    BASE_BOOT_STORAGE_BUS_LABEL=
    BASE_BOOT_STORAGE_MODEL=
    BASE_BOOT_STORAGE_FIRMWARE=
    BASE_BOOT_STORAGE_SIZE_BYTES=

    case "${PLATFORM_BOOT_STORAGE:-}" in
        nvme)
            # shellcheck disable=SC2034 # 由 source 本 helper 的 clone 入口读取。
            BASE_BOOT_STORAGE_BUS_LABEL=NVMe
            ;;
        sata-ahci)
            # shellcheck disable=SC2034 # 由 source 本 helper 的 clone 入口读取。
            BASE_BOOT_STORAGE_BUS_LABEL=SATA/AHCI
            ;;
        *)
            echo "ERROR: profile 启动盘总线不受支持: ${PLATFORM_BOOT_STORAGE:-empty}" >&2
            return 1
            ;;
    esac

    BASE_BOOT_STORAGE_MODEL="${BOOT_STORAGE_MODEL:-}"
    BASE_BOOT_STORAGE_FIRMWARE="${BOOT_STORAGE_FIRMWARE:-}"
    BASE_BOOT_STORAGE_SIZE_BYTES="${BOOT_STORAGE_SIZE_BYTES:-}"

    if [[ -z "$BASE_BOOT_STORAGE_MODEL" ||
          -z "$BASE_BOOT_STORAGE_FIRMWARE" ]] ||
       ! _base_boot_storage_positive_size "$BASE_BOOT_STORAGE_SIZE_BYTES"; then
        echo "ERROR: profile 缺少合法 BOOT_STORAGE_* 启动盘身份" >&2
        return 1
    fi
}

# 先重建启动盘视图，再做字节级容量比较。返回 0 表示可安全复用 base，返回 1
# 表示应重抽 profile；调用完成后 BASE_BOOT_STORAGE_* 仍可用于诊断输出。
base_boot_storage_matches_size() {
    local expected_size="${1:-}"

    if ! _base_boot_storage_positive_size "$expected_size"; then
        echo "ERROR: base 启动盘比较容量非法: ${expected_size:-empty}" >&2
        return 1
    fi
    base_boot_storage_load_profile_view || return 1
    [[ "$BASE_BOOT_STORAGE_SIZE_BYTES" == "$expected_size" ]]
}

# 收集 component NVMe 池中与 base 字节容量精确相等的候选。NVME_POOL 必须来自
# 已校验 components.json 投影；这里复用上面的前四列解析，不复制目录结构。
base_boot_storage_collect_nvme_matches() {
    local expected_size="${1:-}" output_name="${2:-}"
    local row

    _base_boot_storage_positive_size "$expected_size" || {
        echo "ERROR: NVMe 启动池比较容量非法: ${expected_size:-empty}" >&2
        return 1
    }
    [[ "$output_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        echo "ERROR: NVMe 匹配结果数组名非法: ${output_name:-empty}" >&2
        return 1
    }
    local -n nvme_output_ref="$output_name"
    declare -p NVME_POOL >/dev/null 2>&1 || {
        echo "ERROR: component NVMe 池尚未加载" >&2
        return 1
    }

    nvme_output_ref=()
    for row in "${NVME_POOL[@]}"; do
        base_boot_storage_parse_nvme_pool_row "$row" || return 1
        if [[ "$BASE_NVME_SIZE_BYTES" == "$expected_size" ]]; then
            nvme_output_ref+=("$BASE_NVME_MODEL")
        fi
    done
}

# 通过现有 storage-compat.py Bash 包装器枚举 SATA compatibility 目录。每个条目
# 在子 shell 中加载，避免查询候选时覆盖已经严格载入的源 profile BOOT_STORAGE_*。
base_boot_storage_collect_sata_matches() {
    local expected_size="${1:-}" output_name="${2:-}"
    local ids_text id record model size

    _base_boot_storage_positive_size "$expected_size" || {
        echo "ERROR: SATA 启动池比较容量非法: ${expected_size:-empty}" >&2
        return 1
    }
    [[ "$output_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        echo "ERROR: SATA 匹配结果数组名非法: ${output_name:-empty}" >&2
        return 1
    }
    local -n sata_output_ref="$output_name"
    if ! declare -F stealth_storage_compat_ids >/dev/null 2>&1 ||
       ! declare -F stealth_storage_compat_load >/dev/null 2>&1; then
        echo "ERROR: SATA compatibility 目录加载器不可用" >&2
        return 1
    fi

    ids_text="$(stealth_storage_compat_ids)" || return 1
    sata_output_ref=()
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        record="$(
            stealth_storage_compat_load "$id" >/dev/null || exit 1
            printf '%s\t%s' "$BOOT_STORAGE_MODEL" "$BOOT_STORAGE_SIZE_BYTES"
        )" || {
            echo "ERROR: 无法读取 SATA compatibility 条目: $id" >&2
            return 1
        }
        IFS=$'\t' read -r model size <<<"$record"
        if [[ -z "$model" ]] || ! _base_boot_storage_positive_size "$size"; then
            echo "ERROR: SATA compatibility 条目容量非法: $id" >&2
            return 1
        fi
        if [[ "$size" == "$expected_size" ]]; then
            sata_output_ref+=("$model")
        fi
    done <<<"$ids_text"
}

# base 之后可能被正常 NVMe 平台或 E5 household SATA 平台复用，因此两个当前
# 启动池都必须各自存在同容量候选；任一为空都在 seal 前 fail closed。
base_boot_storage_require_all_pool_matches() {
    local expected_size="${1:-}"
    local -a nvme_matches=() sata_matches=()
    local failed=0

    base_boot_storage_collect_nvme_matches \
        "$expected_size" nvme_matches || return 1
    base_boot_storage_collect_sata_matches \
        "$expected_size" sata_matches || return 1

    if (( ${#nvme_matches[@]} == 0 )); then
        echo "ERROR: component NVMe 启动池没有 ${expected_size} bytes 候选" >&2
        failed=1
    fi
    if (( ${#sata_matches[@]} == 0 )); then
        echo "ERROR: samsung-sata-pro compatibility 启动池没有 ${expected_size} bytes 候选" >&2
        failed=1
    fi
    (( failed == 0 )) || return 1

    # shellcheck disable=SC2034 # seal-base 读取两个结果数组用于审计输出。
    BASE_BOOT_NVME_MATCHES=("${nvme_matches[@]}")
    # shellcheck disable=SC2034 # seal-base 读取两个结果数组用于审计输出。
    BASE_BOOT_SATA_MATCHES=("${sata_matches[@]}")
}

# clone 的 profile 复用/重抽事务。只有现有 profile 或新抽 profile 的实际启动盘
# 与 base 字节容量完全一致、且可选运行时校验回调成功时才返回；所有门禁都发生在
# 原子保存之前，失败时保留原文件，绝不落盘最后一次错配或无法 realize 的身份。
# 第五参数可声明 staging 来自 new 或 existing；默认 auto 保持普通调用方兼容。
# new 允许 mktemp 预占的空普通文件，但不会把它误作应严格加载的 legacy profile。
base_boot_storage_prepare_matching_profile() {
    local profile="${1:-}" expected_size="${2:-}" max_attempts="${3:-100}"
    local runtime_validator="${4:-}" profile_seed_state="${5:-auto}" attempt

    [[ -n "$profile" ]] || {
        echo "ERROR: clone 缺少 profile 路径" >&2
        return 1
    }
    _base_boot_storage_positive_size "$expected_size" || {
        echo "ERROR: clone base 容量非法: ${expected_size:-empty}" >&2
        return 1
    }
    if [[ ! "$max_attempts" =~ ^[0-9]+$ ]] || (( max_attempts <= 0 )); then
        echo "ERROR: profile 最大重抽次数非法: ${max_attempts:-empty}" >&2
        return 1
    fi
    if [[ -n "$runtime_validator" ]] &&
       { ! [[ "$runtime_validator" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
         ! declare -F "$runtime_validator" >/dev/null 2>&1; }; then
        echo "ERROR: profile 运行时校验回调不可用: $runtime_validator" >&2
        return 1
    fi
    if ! declare -F stealth_have_profile >/dev/null 2>&1 ||
       ! declare -F stealth_load_profile >/dev/null 2>&1 ||
       ! declare -F stealth_pick_profile >/dev/null 2>&1 ||
       ! declare -F stealth_save_profile >/dev/null 2>&1; then
        echo "ERROR: stealth profile 生命周期函数未加载" >&2
        return 1
    fi

    case "$profile_seed_state" in
        auto)
            if stealth_have_profile "$profile"; then
                profile_seed_state=existing
            else
                profile_seed_state=new
            fi
            ;;
        new)
            if stealth_have_profile "$profile" &&
               { [[ ! -f "$profile" || -L "$profile" || -s "$profile" ]]; }; then
                echo "ERROR: 新 profile staging 必须不存在或是空普通文件: $profile" >&2
                return 1
            fi
            ;;
        existing)
            if ! stealth_have_profile "$profile"; then
                echo "ERROR: 指定复用的已有 profile staging 不存在: $profile" >&2
                return 1
            fi
            ;;
        *)
            echo "ERROR: profile staging 来源状态非法: $profile_seed_state" >&2
            return 1
            ;;
    esac

    if [[ "$profile_seed_state" == existing ]]; then
        stealth_load_profile "$profile" || return 1
        if base_boot_storage_matches_size "$expected_size"; then
            if [[ -n "$runtime_validator" ]] && ! "$runtime_validator"; then
                echo "ERROR: 已有 profile 未通过创建期 CPU/KVM 实现预检" >&2
                return 1
            fi
            echo ">> 复用已有 profile: $profile"
            echo ">> profile 启动盘($BASE_BOOT_STORAGE_BUS_LABEL) = $BASE_BOOT_STORAGE_MODEL" \
                 "(size $BASE_BOOT_STORAGE_SIZE_BYTES) ✓ 匹配 base"
            return 0
        fi
        echo ">> WARN: 已有 profile.BOOT_STORAGE_SIZE_BYTES=$BASE_BOOT_STORAGE_SIZE_BYTES" \
             "与 base=$expected_size 不一致"
        echo "        将重抽容量匹配的 profile，避免 Windows 自动修复和硬盘指纹矛盾"
    fi

    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
        stealth_pick_profile || return 1
        if base_boot_storage_matches_size "$expected_size"; then
            if [[ -n "$runtime_validator" ]] && ! "$runtime_validator"; then
                echo "ERROR: 新抽 profile 未通过创建期 CPU/KVM 实现预检，拒绝保存" >&2
                return 1
            fi
            echo ">> profile 启动盘($BASE_BOOT_STORAGE_BUS_LABEL) = $BASE_BOOT_STORAGE_MODEL" \
                 "(size $BASE_BOOT_STORAGE_SIZE_BYTES) ✓ 匹配 base"
            stealth_save_profile "$profile" || return 1
            return 0
        fi
    done

    echo "ERROR: 启动盘池连续 ${max_attempts} 次未抽到 ${expected_size} bytes 候选" >&2
    echo "       已拒绝保存错配 profile；调用方目标文件保持不变。" >&2
    return 1
}

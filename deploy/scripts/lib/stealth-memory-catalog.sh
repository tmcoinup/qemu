#!/usr/bin/env bash
# 共享 DIMM 目录的 Linux 入口。
#
# JSON 是唯一物料事实源；本文件只提供稳定的行协议和旧 profile 查询 API。
# 选择器必须调用 stealth_memory_platform_candidate_rows，不能只按 socket 或
# 额定速率猜 DDR 代际。

_STEALTH_MEMORY_CATALOG_LIB_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)"
: "${STEALTH_MEMORY_CATALOG:=$_STEALTH_MEMORY_CATALOG_LIB_DIR/../../hardware/memory.json}"
: "${STEALTH_MEMORY_CATALOG_HELPER:=$_STEALTH_MEMORY_CATALOG_LIB_DIR/../memory_catalog.py}"

_stealth_memory_catalog_python() {
    local action="$1"
    shift

    command -v python3 >/dev/null 2>&1 || {
        echo "ERROR: 读取共享内存目录需要 python3" >&2
        return 1
    }
    [[ -r "$STEALTH_MEMORY_CATALOG" ]] || {
        echo "ERROR: 共享内存目录不可读: $STEALTH_MEMORY_CATALOG" >&2
        return 1
    }
    [[ -r "$STEALTH_MEMORY_CATALOG_HELPER" ]] || {
        echo "ERROR: 共享内存目录校验器不可读: $STEALTH_MEMORY_CATALOG_HELPER" >&2
        return 1
    }
    python3 "$STEALTH_MEMORY_CATALOG_HELPER" \
        "$STEALTH_MEMORY_CATALOG" "$action" "$@"
}

stealth_memory_catalog_validate() {
    _stealth_memory_catalog_python validate
}

# 九字段兼容投影：
# MFR|PART_2G|PART_4G|RATED_MTS|SOCKETS|
# RANK_2G|WIDTH_2G|RANK_4G|WIDTH_4G
stealth_memory_catalog_active_rows() {
    _stealth_memory_catalog_python active-legacy
}

stealth_memory_catalog_quarantine_rows() {
    _stealth_memory_catalog_python quarantine-legacy
}

# 候选投影同时验证 type/socket/channels/voltage/slots/total/module sizes/rates。
# 参数顺序：
# TYPE SOCKET CHANNELS VOLTAGE_MV DIMM_SLOTS TOTAL_MIB MODULE_MIB_CSV
# ALLOWED_MTS_CSV MAX_MTS
stealth_memory_platform_candidate_rows() {
    [[ "$#" == 9 ]] || {
        echo "ERROR: 内存平台候选查询需要 9 个参数" >&2
        return 2
    }
    _stealth_memory_catalog_python platform-candidates "$@"
}

# 实际模块投影不要求 family 同时具有 2GiB/4GiB 两个 SKU。协议为：
# FAMILY_ID|MODULE_ID|MFR|TYPE|PART|RATED|CONFIGURED|VOLTAGE|SOCKETS|
# RANK|DEVICE_WIDTH|MODULE_MIB|MODULE_COUNT|WEIGHT|SPD_EE1004
#
# 这是新 profile 与旧 profile 迁移的权威入口；上面的成对候选 API 仅保留给
# 旧九字段 ABI，不能再决定 Guest 实际安装的 DIMM。
stealth_memory_platform_module_plan_rows() {
    [[ "$#" == 9 ]] || {
        echo "ERROR: 内存实际模块查询需要 9 个参数" >&2
        return 2
    }
    _stealth_memory_catalog_python module-plans "$@"
}

_stealth_memory_catalog_resolve() {
    local status="$1"
    local manufacturer="$2"
    local part_2g="$3"
    local part_4g="$4"
    local rated_mts="$5"
    local expected_family="${6:-}"
    _stealth_memory_catalog_python "resolve-$status" \
        "$manufacturer" "$part_2g" "$part_4g" "$rated_mts" "$expected_family"
}

stealth_memory_catalog_family_id() {
    local resolved
    resolved="$(_stealth_memory_catalog_resolve active "$@" "")" || return 1
    printf '%s\n' "${resolved%%|*}"
}

stealth_memory_catalog_geometry() {
    local resolved
    resolved="$(_stealth_memory_catalog_resolve active "$@" "")" || return 1
    printf '%s\n' "${resolved#*|}"
}

stealth_memory_legacy_catalog_geometry() {
    local resolved
    resolved="$(_stealth_memory_catalog_resolve quarantine "$@" "")" || return 1
    printf '%s\n' "${resolved#*|}"
}

stealth_memory_catalog_contains() {
    local geometry
    geometry="$(stealth_memory_catalog_geometry "$1" "$2" "$3" "$4")" \
        || return 1
    [[ "$geometry" == "$5|$6|$7|$8" ]]
}

stealth_memory_profile_catalog_contains() {
    # 严格 profile 只接受 active；quarantine 仅供非严格旧档案诊断。
    stealth_memory_catalog_contains "$@"
}

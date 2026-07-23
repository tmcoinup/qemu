#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 已保存 Linux profile 的内存解析、目录绑定与窄范围历史迁移。
#
# 当前共享目录以“实际安装的 DIMM module ID”为权威。旧 profile 曾同时保存
# 2GiB/4GiB 两个候选料号；其中 Kingston KVR24N17S6/2 当前没有可核验的
# 官方资料，已从 active 目录移除，但实例实际曝光的一直是两条合法
# KVR24N17S8/4 4GiB。
# 本文件只对完整命中的历史输入做确定性规范化，不重新抽品牌、料号或序列号。
# ---------------------------------------------------------------------------

_STEALTH_MEMORY_PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F stealth_memory_platform_module_plan_rows >/dev/null; then
    # shellcheck disable=SC1091
    source "$_STEALTH_MEMORY_PROFILE_DIR/stealth-memory-catalog.sh"
fi

_stealth_memory_profile_error() {
    echo "ERROR: $*" >&2
    return 1
}

_stealth_memory_profile_legacy_kingston_alias() {
    local stable_key_count="$1"

    [[ "$stable_key_count" == 0 &&
       "$PLATFORM_SCHEMA_VERSION" == 1 &&
       "$PLATFORM_CATALOG_REVISION" == 2026-07-19.6 &&
       "$CPU_SOCKET" == LGA1151 &&
       "$BOARD_DIMM_SLOTS" == 2 &&
       "$MEM_MFR" == Kingston &&
       "$MEM_TYPE" == DDR4 &&
       "$MEM_PART_2G" == KVR24N17S6/2 &&
       "$MEM_PART_4G" == KVR24N17S8/4 &&
       "$MEM_RATED_MTS" == 2400 &&
       "$MEM_VOLTAGE_MV" == 1200 &&
       "$MEM_CHANNELS" == 2 &&
       "$MEM_TOTAL_MB" == 8192 &&
       "$MEM_RANK_2G" == 1 &&
       "$MEM_DEVICE_WIDTH_2G" == 16 &&
       "$MEM_RANK_4G" == 1 &&
       "$MEM_DEVICE_WIDTH_4G" == 8 ]]
}

_stealth_memory_profile_geometry_is_valid() {
    [[ "$MEM_RANK_2G" =~ ^[0-4]$ &&
       "$MEM_RANK_4G" =~ ^[0-4]$ ]] &&
        ! [[ "$MEM_RANK_2G" == 0 && "$MEM_RANK_4G" == 0 ]] &&
        ! [[ "$MEM_RANK_2G" == 0 && "$MEM_DEVICE_WIDTH_2G" != 0 ]] &&
        ! [[ "$MEM_RANK_2G" != 0 && "$MEM_DEVICE_WIDTH_2G" == 0 ]] &&
        ! [[ "$MEM_RANK_4G" == 0 && "$MEM_DEVICE_WIDTH_4G" != 0 ]] &&
        ! [[ "$MEM_RANK_4G" != 0 && "$MEM_DEVICE_WIDTH_4G" == 0 ]] &&
        [[ "$MEM_DEVICE_WIDTH_2G" == 0 ||
           "$MEM_DEVICE_WIDTH_2G" == 4 ||
           "$MEM_DEVICE_WIDTH_2G" == 8 ||
           "$MEM_DEVICE_WIDTH_2G" == 16 ||
           "$MEM_DEVICE_WIDTH_2G" == 32 ]] &&
        [[ "$MEM_DEVICE_WIDTH_4G" == 0 ||
           "$MEM_DEVICE_WIDTH_4G" == 4 ||
           "$MEM_DEVICE_WIDTH_4G" == 8 ||
           "$MEM_DEVICE_WIDTH_4G" == 16 ||
           "$MEM_DEVICE_WIDTH_4G" == 32 ]]
}

_stealth_memory_profile_selected_slot_matches() {
    local expected_part="$1"
    local expected_rank="$2"
    local expected_width="$3"
    local expected_module_mib="$4"

    case "$expected_module_mib" in
        2048)
            [[ "$MEM_PART_2G" == "$expected_part" &&
               "$MEM_RANK_2G" == "$expected_rank" &&
               "$MEM_DEVICE_WIDTH_2G" == "$expected_width" ]]
            ;;
        4096)
            [[ "$MEM_PART_4G" == "$expected_part" &&
               "$MEM_RANK_4G" == "$expected_rank" &&
               "$MEM_DEVICE_WIDTH_4G" == "$expected_width" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

_stealth_memory_profile_singleton_slots_match() {
    local expected_module_mib="$1"

    case "$expected_module_mib" in
        2048)
            [[ -z "$MEM_PART_4G" &&
               "$MEM_RANK_4G" == 0 &&
               "$MEM_DEVICE_WIDTH_4G" == 0 ]]
            ;;
        4096)
            [[ -z "$MEM_PART_2G" &&
               "$MEM_RANK_2G" == 0 &&
               "$MEM_DEVICE_WIDTH_2G" == 0 ]]
            ;;
        *)
            return 1
            ;;
    esac
}

_stealth_memory_profile_resolve_schema1_plan() {
    local present_array_name="$1"
    local -n present_keys="$present_array_name"
    local stable_key stable_key_count=0
    local memory_socket="$CPU_SOCKET"
    local row selected_row=""
    local family_id module_id manufacturer memory_type part_number
    local rated_mts _configured_mts voltage_mv _sockets rank device_width
    local module_mib module_count _selection_weight spd_ee1004

    for stable_key in \
        MEM_FAMILY_ID MEM_MODULE_ID MEM_SELECTED_MODULE_MB \
        MEM_MODULE_COUNT MEM_SPD_EE1004; do
        [[ -n "${present_keys[$stable_key]:-}" ]] &&
            ((stable_key_count += 1))
    done
    if [[ "$stable_key_count" != 0 && "$stable_key_count" != 5 ]]; then
        _stealth_memory_profile_error \
            "schema-1 profile 的 DIMM 稳定绑定字段不完整"
        return 1
    fi

    [[ "${PLATFORM_CPU_SOURCE:-}" == host-passthrough ]] && memory_socket="*"
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        IFS='|' read -r family_id module_id manufacturer memory_type \
            part_number rated_mts _configured_mts voltage_mv _sockets rank \
            device_width module_mib module_count _selection_weight spd_ee1004 \
            <<<"$row"
        if (( stable_key_count == 5 )); then
            [[ "$module_id" == "$MEM_MODULE_ID" ]] || continue
        else
            [[ "$manufacturer" == "$MEM_MFR" ]] || continue
            _stealth_memory_profile_selected_slot_matches \
                "$part_number" "$rank" "$device_width" "$module_mib" || continue
        fi
        if [[ -n "$selected_row" ]]; then
            _stealth_memory_profile_error \
                "profile 的 DIMM 物料无法唯一解析"
            return 1
        fi
        selected_row="$row"
    done < <(stealth_memory_platform_module_plan_rows \
        "$MEM_TYPE" "$memory_socket" "$MEM_CHANNELS" "$MEM_VOLTAGE_MV" \
        "$BOARD_DIMM_SLOTS" "$MEM_TOTAL_MB" "$MEM_MODULE_MB" \
        "$MEM_ALLOWED_MTS" "$MEM_MAX_MTS")

    if [[ -z "$selected_row" ]]; then
        _stealth_memory_profile_error \
            "profile 的实际 DIMM 不适配当前平台拓扑"
        return 1
    fi
    IFS='|' read -r family_id module_id manufacturer memory_type \
        part_number rated_mts _configured_mts voltage_mv _sockets rank \
        device_width module_mib module_count _selection_weight spd_ee1004 \
        <<<"$selected_row"

    # 已保存 profile 可在目录额定值以下按平台允许档位训练；module-plans 的
    # configured 字段是“新选择时的最高档”，不能强迫旧实例升级工作频率。
    if [[ "$MEM_MFR|$MEM_TYPE|$MEM_RATED_MTS|$MEM_VOLTAGE_MV" != \
          "$manufacturer|$memory_type|$rated_mts|$voltage_mv" ]] ||
       ! _stealth_memory_profile_selected_slot_matches \
            "$part_number" "$rank" "$device_width" "$module_mib"; then
        _stealth_memory_profile_error \
            "profile 的 DIMM 品牌、料号、几何或速率与共享目录不一致"
        return 1
    fi

    if (( stable_key_count == 5 )) &&
       [[ "$MEM_FAMILY_ID|$MEM_MODULE_ID|$MEM_SELECTED_MODULE_MB|$MEM_MODULE_COUNT|$MEM_SPD_EE1004" != \
          "$family_id|$module_id|$module_mib|$module_count|$spd_ee1004" ]]; then
        _stealth_memory_profile_error \
            "profile 的 DIMM 稳定 ID、容量或数量与共享目录不一致"
        return 1
    fi

    if ! stealth_memory_profile_catalog_contains \
            "$MEM_MFR" "$MEM_PART_2G" "$MEM_PART_4G" "$MEM_RATED" \
            "$MEM_RANK_2G" "$MEM_DEVICE_WIDTH_2G" \
            "$MEM_RANK_4G" "$MEM_DEVICE_WIDTH_4G"; then
        if _stealth_memory_profile_legacy_kingston_alias \
                "$stable_key_count" &&
           [[ "$family_id" == kingston-kvr24n17-ddr4-2400 &&
              "$module_id" == kingston-kvr24n17s8-4-ddr4-4g &&
              "$module_mib" == 4096 && "$module_count" == 2 ]]; then
            # 只清理 Guest 从未使用的虚假 2GiB 候选；实际 4GiB Kingston
            # module、序列号、容量及所有其它整机身份保持原样。
            MEM_PART_2G=""
            MEM_RANK_2G=0
            MEM_DEVICE_WIDTH_2G=0
            _STEALTH_MEMORY_PROFILE_MIGRATION_KIND=legacy-kingston-4g
        elif ! _stealth_memory_profile_singleton_slots_match "$module_mib"; then
            _stealth_memory_profile_error \
                "profile 的内存料号/几何不在已核验硬件目录中"
            return 1
        fi
    fi

    if (( stable_key_count == 0 )); then
        [[ "$_STEALTH_MEMORY_PROFILE_MIGRATION_KIND" != none ]] ||
            _STEALTH_MEMORY_PROFILE_MIGRATION_KIND=stable-module-binding
    fi
    MEM_FAMILY_ID="$family_id"
    MEM_MODULE_ID="$module_id"
    MEM_SELECTED_MODULE_MB="$module_mib"
    MEM_MODULE_COUNT="$module_count"
    MEM_SPD_EE1004="$spd_ee1004"
}

stealth_resolve_loaded_memory_profile() {
    local present_array_name="$1"
    local -n present_keys="$present_array_name"
    local geometry geometry_key geometry_key_count=0

    _STEALTH_MEMORY_PROFILE_MIGRATION_KIND=none
    [[ -n "${present_keys[MEM_MFR]:-}" ]] || MEM_MFR=Crucial
    [[ -n "${present_keys[MEM_PART_2G]:-}" ]] || MEM_PART_2G=CT2G4DFS624A
    [[ -n "${present_keys[MEM_PART_4G]:-}" ]] || MEM_PART_4G=CT4G4DFS824A
    if [[ -z "${MEM_RATED:-}" ]]; then
        case "${MEM_PART_4G:-}${MEM_PART_2G:-}" in
            *-CRC*|*24N*|*DFS624*|*DFS824*) MEM_RATED=2400 ;;
            *26N*|*266*|*C16F*) MEM_RATED=2666 ;;
            *) MEM_RATED=2666 ;;
        esac
    fi
    case "$CPU_SOCKET" in
        AM3|AM3+|FM2+|LGA1155)
            : "${MEM_TYPE:=DDR3}"
            : "${MEM_VOLTAGE_MV:=1500}"
            ;;
        *)
            : "${MEM_TYPE:=DDR4}"
            : "${MEM_VOLTAGE_MV:=1200}"
            ;;
    esac
    : "${MEM_CHANNELS:=2}"
    : "${MEM_MAX_MTS:=$MEM_RATED}"
    : "${MEM_ALLOWED_MTS:=$MEM_MAX_MTS}"
    : "${MEM_RATED_MTS:=$MEM_RATED}"
    if [[ "$MEM_RATED" != "$MEM_RATED_MTS" ]]; then
        _stealth_memory_profile_error \
            "profile 的 MEM_RATED 与 MEM_RATED_MTS 自相矛盾"
        return 1
    fi
    if ! [[ "$MEM_RATED_MTS" =~ ^[0-9]+$ &&
            "$MEM_MAX_MTS" =~ ^[0-9]+$ ]] ||
       (( MEM_RATED_MTS <= 0 || MEM_MAX_MTS <= 0 )); then
        _stealth_memory_profile_error \
            "profile 的内存额定值或平台上限不是正整数"
        return 1
    fi
    if [[ -z "${MEM_CONFIGURED_MTS:-}" ]]; then
        if (( MEM_RATED_MTS < MEM_MAX_MTS )); then
            MEM_CONFIGURED_MTS="$MEM_RATED_MTS"
        else
            MEM_CONFIGURED_MTS="$MEM_MAX_MTS"
        fi
    fi
    if ! [[ "$MEM_CONFIGURED_MTS" =~ ^[0-9]+$ ]] ||
       (( MEM_CONFIGURED_MTS <= 0 ||
          MEM_CONFIGURED_MTS > MEM_RATED_MTS ||
          MEM_CONFIGURED_MTS > MEM_MAX_MTS )) ||
       [[ ",$MEM_ALLOWED_MTS," != *",$MEM_CONFIGURED_MTS,"* ]]; then
        _stealth_memory_profile_error \
            "profile 内存额定/配置速率不可能: rated=$MEM_RATED_MTS configured=$MEM_CONFIGURED_MTS max=$MEM_MAX_MTS allowed=$MEM_ALLOWED_MTS"
        return 1
    fi

    : "${MEM_RANK:=1}"
    for geometry_key in \
        MEM_RANK_2G MEM_DEVICE_WIDTH_2G MEM_RANK_4G MEM_DEVICE_WIDTH_4G; do
        [[ -n "${present_keys[$geometry_key]:-}" ]] &&
            ((geometry_key_count += 1))
    done
    if [[ "$PLATFORM_SCHEMA_VERSION" == 1 &&
          "$geometry_key_count" != 0 &&
          "$geometry_key_count" != 4 ]]; then
        _stealth_memory_profile_error \
            "schema-1 profile 的 DIMM 几何字段不完整"
        return 1
    fi
    if [[ "$geometry_key_count" == 0 ]]; then
        if geometry="$(stealth_memory_catalog_geometry \
                "$MEM_MFR" "$MEM_PART_2G" "$MEM_PART_4G" "$MEM_RATED")" ||
           { [[ "$PLATFORM_SCHEMA_VERSION" != 1 ]] &&
             geometry="$(stealth_memory_legacy_catalog_geometry \
                "$MEM_MFR" "$MEM_PART_2G" "$MEM_PART_4G" "$MEM_RATED")"; }; then
            IFS='|' read -r MEM_RANK_2G MEM_DEVICE_WIDTH_2G \
                MEM_RANK_4G MEM_DEVICE_WIDTH_4G <<<"$geometry"
        else
            MEM_RANK_2G="$MEM_RANK"
            MEM_DEVICE_WIDTH_2G=8
            MEM_RANK_4G="$MEM_RANK"
            MEM_DEVICE_WIDTH_4G=8
        fi
    fi
    _stealth_memory_profile_geometry_is_valid || {
        _stealth_memory_profile_error \
            "profile 的 DIMM rank/device-width 非法"
        return 1
    }

    : "${MEM_MODULE_MB:=2048,4096}"
    : "${MEM_ALLOWED_TOTAL_MB:=2048,4096,8192}"
    : "${MEM_MAX_CAPACITY_MB:=$(( BOARD_MAX_MEMORY_GIB * 1024 ))}"
    : "${MEM_TOTAL_MB:=}"
    if [[ "$PLATFORM_SCHEMA_VERSION" == 1 ]]; then
        if ! [[ "$MEM_TOTAL_MB" =~ ^[0-9]+$ ]] ||
           [[ ",$MEM_ALLOWED_TOTAL_MB," != *",$MEM_TOTAL_MB,"* ]]; then
            _stealth_memory_profile_error \
                "schema-1 profile 的内存总量不在平台允许集合中"
            return 1
        fi
        _stealth_memory_profile_resolve_schema1_plan \
            "$present_array_name" || return 1
    else
        MEM_FAMILY_ID=""
        MEM_MODULE_ID=""
        MEM_SELECTED_MODULE_MB=""
        MEM_MODULE_COUNT=""
        MEM_SPD_EE1004=""
    fi
}

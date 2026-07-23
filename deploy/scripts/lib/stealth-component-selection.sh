#!/usr/bin/env bash
# Linux profile 可更换部件的显式选择契约。
#
# 四个请求变量为空时保持各目录原有权重随机；非空时只能在“当前整机过滤后的
# 合法候选”中唯一命中。这里不产生新的硬件事实，所有稳定 ID 与字段仍来自
# components.json / memory.json 的已校验投影。

readonly _STEALTH_CURRENT_STORAGE_BYTES=512110190592

stealth_component_selection_init_requests() {
    : "${STEALTH_MEMORY_ID:=}" "${STEALTH_STORAGE_ID:=}" \
        "${STEALTH_GPU_ID:=}" "${STEALTH_MONITOR_ID:=}"
    export STEALTH_MEMORY_ID STEALTH_STORAGE_ID
    export STEALTH_GPU_ID STEALTH_MONITOR_ID
}

_stealth_selection_pick_weighted_id() {
    local requested="$1" rows_name="$2" label="$3"
    local -n selection_rows="$rows_name"
    local row stable_id matched="" count=0

    if [[ -z "$requested" ]]; then
        _pick_weighted_rows "$rows_name"
        return
    fi
    for row in "${selection_rows[@]}"; do
        stable_id="${row%%|*}"
        if [[ "$stable_id" == "$requested" ]]; then
            matched="$stable_id"
            ((count += 1))
        fi
    done
    if (( count != 1 )); then
        printf 'ERROR: 指定%s ID %q 未在当前合法候选中唯一命中（实际=%d）\n' \
            "$label" "$requested" "$count" >&2
        return 1
    fi
    printf '%s\n' "$matched"
}

stealth_select_gpu_component_row() {
    local selected_id
    selected_id="$(_stealth_selection_pick_weighted_id \
        "${STEALTH_GPU_ID:-}" GPU_WEIGHT_ROWS "GPU")" || return 1
    stealth_component_gpu_row "$selected_id"
}

stealth_select_storage_component_row() {
    local weight_row component_row stable_id size selected_id
    local -a legal_weights=()

    for weight_row in "${NVME_WEIGHT_ROWS[@]}"; do
        stable_id="${weight_row%%|*}"
        component_row="$(stealth_component_storage_row "$stable_id")" || return 1
        IFS='|' read -r _ _ _ size _ <<<"$component_row"
        if [[ "$size" == "$_STEALTH_CURRENT_STORAGE_BYTES" ]]; then
            legal_weights+=("$weight_row")
        fi
    done
    if (( ${#legal_weights[@]} == 0 )); then
        echo "ERROR: 当前部件目录没有精确 512110190592 bytes 的存储候选" >&2
        return 1
    fi
    selected_id="$(_stealth_selection_pick_weighted_id \
        "${STEALTH_STORAGE_ID:-}" legal_weights "存储")" || return 1
    stealth_component_storage_row "$selected_id"
}

stealth_select_memory_module_row() {
    local candidates_name="$1"
    local -n memory_candidates_ref="$candidates_name"
    local row module_id weight selected_id matched="" count=0
    local -a columns=() legal_weights=()

    for row in "${memory_candidates_ref[@]}"; do
        IFS='|' read -r -a columns <<<"$row"
        module_id="${columns[1]:-}"
        weight="${columns[13]:-}"
        legal_weights+=("$module_id|$weight")
    done
    selected_id="$(_stealth_selection_pick_weighted_id \
        "${STEALTH_MEMORY_ID:-}" legal_weights "内存")" || return 1
    for row in "${memory_candidates_ref[@]}"; do
        IFS='|' read -r -a columns <<<"$row"
        module_id="${columns[1]:-}"
        if [[ "$module_id" == "$selected_id" ]]; then
            matched="$row"
            ((count += 1))
        fi
    done
    if (( count != 1 )); then
        printf 'ERROR: 内存 module ID %q 在完整平台候选中无法唯一解析（实际=%d）\n' \
            "$selected_id" "$count" >&2
        return 1
    fi
    printf '%s\n' "$matched"
}

stealth_select_monitor_component_row() {
    local selected_id
    selected_id="$(_stealth_selection_pick_weighted_id \
        "${STEALTH_MONITOR_ID:-}" MONITOR_WEIGHT_ROWS "显示器")" || return 1
    stealth_component_monitor_row "$selected_id"
}

_stealth_selection_assert_same_id() {
    local requested="$1" actual="$2" label="$3"

    [[ -z "$requested" ]] && return 0
    if [[ "$requested" != "$actual" ]]; then
        printf 'ERROR: 已有 profile 的%s ID 为 %q，与指定 ID %q 不一致\n' \
            "$label" "${actual:-<empty>}" "$requested" >&2
        return 1
    fi
}

stealth_assert_requested_component_profile() {
    local requested_gpu="${STEALTH_GPU_ID:-}"
    local gpu_row actual_gpu storage_row storage_size

    _stealth_selection_assert_same_id \
        "${STEALTH_MEMORY_ID:-}" "${MEM_MODULE_ID:-}" "内存" || return 1
    _stealth_selection_assert_same_id \
        "${STEALTH_MONITOR_ID:-}" "${EDID_COMPONENT_ID:-}" "显示器" || return 1

    if [[ -n "${STEALTH_STORAGE_ID:-}" ]]; then
        if ! storage_row="$(
            stealth_component_storage_row "$STEALTH_STORAGE_ID" 2>/dev/null
        )"; then
            printf 'ERROR: 指定存储 ID %q 不是当前统一 512G 候选\n' \
                "$STEALTH_STORAGE_ID" >&2
            return 1
        fi
        IFS='|' read -r _ _ _ storage_size _ <<<"$storage_row"
        if [[ "$storage_size" != "$_STEALTH_CURRENT_STORAGE_BYTES" ]]; then
            printf 'ERROR: 指定存储 ID %q 不是当前统一 512G 候选\n' \
                "$STEALTH_STORAGE_ID" >&2
            return 1
        fi
        _stealth_selection_assert_same_id \
            "$STEALTH_STORAGE_ID" "${NVME_COMPONENT_ID:-}" "存储" || return 1
    fi

    if [[ -n "$requested_gpu" ]]; then
        gpu_row="$(stealth_component_gpu_row "$requested_gpu")" || return 1
        actual_gpu="$(stealth_current_gpu_profile_row)"
        if [[ "$gpu_row" != "$actual_gpu" ]]; then
            printf 'ERROR: 已有 profile 的 GPU bundle 与指定 ID %q 不一致\n' \
                "$requested_gpu" >&2
            return 1
        fi
    fi
}

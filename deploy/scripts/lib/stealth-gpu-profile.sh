#!/usr/bin/env bash
# AIB 显卡 profile 的行投影、旧 generic profile 回查与导出辅助层。

stealth_gpu_legacy_profile_row() {
    local wanted_ven="$1" wanted_dev="$2" row row_ven row_dev matched="" count=0
    for row in "${LEGACY_GPU_POOL[@]}"; do
        IFS='|' read -r _ _ row_ven row_dev _ <<<"$row"
        if [[ "${row_ven,,}" == "${wanted_ven,,}" &&
              "${row_dev,,}" == "${wanted_dev,,}" ]]; then
            matched="$row"
            ((count += 1))
        fi
    done
    if (( count != 1 )); then
        printf 'ERROR: 旧 GPU label 的 PCI 键必须唯一命中 %s:%s，实际=%d\n' \
            "$wanted_ven" "$wanted_dev" "$count" >&2
        return 1
    fi
    printf '%s\n' "$matched"
}

stealth_gpu_legacy_component_id() {
    local wanted_ven="$1" wanted_dev="$2" row stable_id row_ven row_dev
    local matched="" count=0
    for row in "${LEGACY_GPU_INDEX[@]}"; do
        IFS='|' read -r stable_id _ _ row_ven row_dev _ <<<"$row"
        if [[ "${row_ven,,}" == "${wanted_ven,,}" &&
              "${row_dev,,}" == "${wanted_dev,,}" ]]; then
            matched="$stable_id"
            ((count += 1))
        fi
    done
    (( count == 1 )) || return 1
    printf '%s\n' "$matched"
}

stealth_assign_gpu_profile_row() {
    local row="$1"
    IFS='|' read -r GPU_COMPONENT_ID GPU_VENDOR GPU_NAME GPU_PCI_VEN \
        GPU_PCI_DEV GPU_RAM_MB GPU_BIOS GPU_REV GPU_MEMORY_TYPE \
        GPU_MEMORY_BUS_WIDTH_BITS GPU_BASE_CLOCK_KHZ GPU_BOOST_CLOCK_KHZ \
        GPU_MEMORY_CLOCK_KHZ GPU_SLI_SUPPORTED GPU_BOARD_PARTNER \
        GPU_PART_NUMBER GPU_SUBSYS_VEN GPU_SUBSYS_DEV GPU_CARRIER_VEN \
        GPU_CARRIER_DEV GPU_IDENTITY_FIDELITY <<<"$row"
}

stealth_current_gpu_profile_row() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$GPU_COMPONENT_ID" "$GPU_VENDOR" "$GPU_NAME" "$GPU_PCI_VEN" \
        "$GPU_PCI_DEV" "$GPU_RAM_MB" "$GPU_BIOS" "$GPU_REV" \
        "$GPU_MEMORY_TYPE" "$GPU_MEMORY_BUS_WIDTH_BITS" "$GPU_BASE_CLOCK_KHZ" \
        "$GPU_BOOST_CLOCK_KHZ" "$GPU_MEMORY_CLOCK_KHZ" "$GPU_SLI_SUPPORTED" \
        "$GPU_BOARD_PARTNER" "$GPU_PART_NUMBER" "$GPU_SUBSYS_VEN" \
        "$GPU_SUBSYS_DEV" "$GPU_CARRIER_VEN" "$GPU_CARRIER_DEV" \
        "$GPU_IDENTITY_FIDELITY"
}

stealth_export_gpu_profile() {
    export GPU_COMPONENT_ID GPU_VENDOR GPU_NAME GPU_PCI_VEN GPU_PCI_DEV
    export GPU_RAM_MB GPU_BIOS GPU_REV GPU_MEMORY_TYPE GPU_MEMORY_BUS_WIDTH_BITS
    export GPU_BASE_CLOCK_KHZ GPU_BOOST_CLOCK_KHZ GPU_MEMORY_CLOCK_KHZ
    export GPU_SLI_SUPPORTED GPU_BOARD_PARTNER GPU_PART_NUMBER
    export GPU_SUBSYS_VEN GPU_SUBSYS_DEV GPU_CARRIER_VEN GPU_CARRIER_DEV
    export GPU_IDENTITY_FIDELITY
}

stealth_fill_legacy_gpu_spec_defaults() {
    local row legacy_id
    local vendor name ven dev ram bios rev memory_type bus_width
    local base_clock boost_clock memory_clock sli_supported

    # 新 AIB profile 已按稳定 ID 持久化；这里只补非严格诊断路径中的缺失元数据。
    if [[ -n "${GPU_COMPONENT_ID:-}" ]] &&
       row="$(stealth_component_gpu_row "$GPU_COMPONENT_ID" 2>/dev/null)"; then
        local -a columns=()
        IFS='|' read -r -a columns <<<"$row"
        : "${GPU_BOARD_PARTNER:=${columns[14]}}"
        : "${GPU_PART_NUMBER:=${columns[15]}}"
        : "${GPU_SUBSYS_VEN:=${columns[16]}}"
        : "${GPU_SUBSYS_DEV:=${columns[17]}}"
        : "${GPU_CARRIER_VEN:=${columns[18]}}"
        : "${GPU_CARRIER_DEV:=${columns[19]}}"
        : "${GPU_IDENTITY_FIDELITY:=${columns[20]}}"
        return 0
    fi

    legacy_id="${GPU_COMPONENT_ID:-}"
    if [[ -z "$legacy_id" ]]; then
        legacy_id="$(stealth_gpu_legacy_component_id \
            "${GPU_PCI_VEN:-}" "${GPU_PCI_DEV:-}")" || return 1
    fi
    row="$(stealth_component_legacy_gpu_row "$legacy_id")" || return 1
    IFS='|' read -r vendor name ven dev ram bios rev memory_type bus_width \
        base_clock boost_clock memory_clock sli_supported <<<"$row"
    : "${GPU_COMPONENT_ID:=$legacy_id}"
    : "${GPU_MEMORY_TYPE:=$memory_type}"
    : "${GPU_MEMORY_BUS_WIDTH_BITS:=$bus_width}"
    : "${GPU_BASE_CLOCK_KHZ:=$base_clock}"
    : "${GPU_BOOST_CLOCK_KHZ:=$boost_clock}"
    : "${GPU_MEMORY_CLOCK_KHZ:=$memory_clock}"
    : "${GPU_SLI_SUPPORTED:=$sli_supported}"
    : "${GPU_BOARD_PARTNER:=reference-label}"
    : "${GPU_PART_NUMBER:=not-exposed}"
    : "${GPU_SUBSYS_VEN:=${GPU_PCI_VEN:-$ven}}"
    : "${GPU_SUBSYS_DEV:=${GPU_PCI_DEV:-$dev}}"
    : "${GPU_CARRIER_VEN:=${GPU_PCI_VEN:-$ven}}"
    : "${GPU_CARRIER_DEV:=${GPU_PCI_DEV:-$dev}}"
    : "${GPU_IDENTITY_FIDELITY:=label_only_out_of_scope}"
}

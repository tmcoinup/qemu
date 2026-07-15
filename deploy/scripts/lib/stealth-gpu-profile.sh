#!/usr/bin/env bash
# GPU 型号池与旧 profile 兼容读取的小型辅助层。
#
# 新 profile 会由 stealth_pick_profile 一次性生成全部 GPU 字段；本文件
# 只为旧 profile 的非严格诊断路径提供稳定默认。严格路径仍会通过
# `_stealth_present_keys` 要求新字段真实存在于磁盘 profile，不会把这些
# 运行时补值冒充为已完成迁移。

stealth_gpu_profile_row() {
    # PCI VEN/DEV 是 GPU_POOL 中的稳定主键。必须恰好命中一行；
    # 重复 ID 会使 guest SUBSYS 反查产生歧义，因此也按错误处理。
    local wanted_ven="$1" wanted_dev="$2" row row_ven row_dev matched='' count=0
    for row in "${GPU_POOL[@]}"; do
        IFS='|' read -r _ _ row_ven row_dev _ <<<"$row"
        if [[ "${row_ven,,}" == "${wanted_ven,,}" && \
              "${row_dev,,}" == "${wanted_dev,,}" ]]; then
            matched="$row"
            ((count += 1))
        fi
    done
    if (( count != 1 )); then
        echo "ERROR: GPU_POOL 必须唯一命中 $wanted_ven:$wanted_dev，实际=$count" >&2
        return 1
    fi
    printf '%s\n' "$matched"
}

stealth_fill_legacy_gpu_spec_defaults() {
    # 只填缺失的新字段，不覆盖已有值。这样严格校验仍能看到
    # 人工篡改；旧版 AMD/NVIDIA profile 在显式非严格诊断时也不会
    # 全部错用 GTX 1050 的时钟。
    local row _vendor _name _ven _dev _ram _bios _rev memory_type bus_width
    local base_clock boost_clock memory_clock sli_supported
    row="$(stealth_gpu_profile_row "${GPU_PCI_VEN:-}" "${GPU_PCI_DEV:-}")" || return 1
    IFS='|' read -r _vendor _name _ven _dev _ram _bios _rev memory_type bus_width \
        base_clock boost_clock memory_clock sli_supported <<<"$row"
    : "${GPU_MEMORY_TYPE:=$memory_type}"
    : "${GPU_MEMORY_BUS_WIDTH_BITS:=$bus_width}"
    : "${GPU_BASE_CLOCK_KHZ:=$base_clock}"
    : "${GPU_BOOST_CLOCK_KHZ:=$boost_clock}"
    : "${GPU_MEMORY_CLOCK_KHZ:=$memory_clock}"
    : "${GPU_SLI_SUPPORTED:=$sli_supported}"
}

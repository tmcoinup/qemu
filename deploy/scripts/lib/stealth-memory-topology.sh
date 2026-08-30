# ---------------------------------------------------------------------------
# 根据 platform manifest 解析物理 DIMM 拓扑。
#
# 输入：RAM、MEM_ALLOWED_TOTAL_MB、MEM_MODULE_MB、MEM_CHANNELS、
#       BOARD_DIMM_SLOTS、MEM_MAX_CAPACITY_MB。
# 输出：NUM_DIMMS、PER_DIMM_MB、T16_NUM_DEVICES、T16_MAX_CAPACITY。
# ---------------------------------------------------------------------------

_stealth_mem_csv_contains() {
    local csv="$1" wanted="$2"
    [[ ",$csv," == *",$wanted,"* ]]
}

stealth_resolve_memory_topology() {
    local allowed_totals="${MEM_ALLOWED_TOTAL_MB:-2048,4096,8192}"
    local module_sizes="${MEM_MODULE_MB:-2048,4096}"
    local channels="${MEM_CHANNELS:-2}"
    local slots="${BOARD_DIMM_SLOTS:-2}"
    local max_populated count each preferred_chunk fallback_count=0 fallback_each=0

    if ! [[ "${RAM:-}" =~ ^[0-9]+$ ]] || \
       ! _stealth_mem_csv_contains "$allowed_totals" "$RAM"; then
        echo "ERROR: RAM=${RAM:-unset}MiB 不属于当前 platform 允许值: $allowed_totals" >&2
        return 2
    fi
    if ! [[ "$channels" =~ ^[0-9]+$ && "$slots" =~ ^[0-9]+$ ]] || \
       (( channels < 1 || slots < 1 )); then
        echo "ERROR: manifest 内存通道/槽位字段非法" >&2
        return 2
    fi
    if (( (RAM == 12288 || RAM == 16384) && slots < 4 )); then
        echo "ERROR: RAM=${RAM}MiB 仅允许用于至少四个 DIMM 插槽的主板" >&2
        return 2
    fi

    NUM_DIMMS=0
    PER_DIMM_MB=0
    max_populated=$channels
    (( slots < max_populated )) && max_populated=$slots
    # QEMU 当前按 4GiB chunk 生成 SMBIOS Type17/SPD；优先选择同样大小的物理条，
    # 避免 4GiB 总内存声称 2x2GiB、底层却只生成一条 4GiB 记录。
    preferred_chunk="${SMBIOS_DIMM_DEVICE_MB:-4096}"
    for (( count=1; count<=max_populated; count++ )); do
        (( RAM % count == 0 )) || continue
        each=$(( RAM / count ))
        if _stealth_mem_csv_contains "$module_sizes" "$each"; then
            (( fallback_count == 0 )) && { fallback_count=$count; fallback_each=$each; }
            if (( each == preferred_chunk )); then
                NUM_DIMMS=$count
                PER_DIMM_MB=$each
                break
            fi
        fi
    done
    if (( NUM_DIMMS == 0 && fallback_count > 0 )); then
        NUM_DIMMS=$fallback_count
        PER_DIMM_MB=$fallback_each
    fi
    if (( NUM_DIMMS == 0 )); then
        echo "ERROR: RAM=${RAM}MiB 无法由 ${slots}槽/${channels}通道和模块 ${module_sizes}MiB 组成" >&2
        return 2
    fi

    MEM_PER_DIMM_MB=$PER_DIMM_MB
    T16_NUM_DEVICES=$slots
    T16_MAX_CAPACITY_MB="${MEM_MAX_CAPACITY_MB:-$(( slots * PER_DIMM_MB ))}"
    if ! [[ "$T16_MAX_CAPACITY_MB" =~ ^[0-9]+$ ]] || (( T16_MAX_CAPACITY_MB < RAM )); then
        echo "ERROR: MEM_MAX_CAPACITY_MB 小于已安装 RAM 或格式非法" >&2
        return 2
    fi
    T16_MAX_CAPACITY="${T16_MAX_CAPACITY_MB}M"
    export NUM_DIMMS PER_DIMM_MB MEM_PER_DIMM_MB
    export T16_NUM_DEVICES T16_MAX_CAPACITY_MB T16_MAX_CAPACITY
}

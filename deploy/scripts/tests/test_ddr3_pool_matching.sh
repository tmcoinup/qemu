#!/usr/bin/env bash
# DDR3 物料仍用于读取历史 profile，但当前 Q35 平台层不能可信表达 AM3/AM3+、
# FM2+ 或 LGA1155 整机。因此本测试确保 DDR3 不会重新泄漏到新 VM 随机池。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"

is_known_memory_product_pair() {
    local key="$1|$2|$3|$4"
    case "$key" in
        "Crucial|CT2G4DFS6266|CT4G4DFS8266|2666" \
        |"Samsung|M378A5644EB0-CRC|M378A5244CB0-CRC|2400" \
        |"Kingston|KVR24N17S6/2|KVR24N17S8/4|2400" \
        |"Crucial|CT2G4DFS624A|CT4G4DFS824A|2400" \
        |"SK hynix|HMA425U6AFR6N-UH|HMA851U6AFR6N-UH|2400" \
        |"Kingston|KVR16N11S6/2|KVR16N11S8/4|1600" \
        |"Crucial|CT25664BA160B|CT51264BA160B|1600" \
        |"SK hynix|HMT325U6CFR8C-PB|HMT351U6CFR8C-PB|1600" \
        |"Kingston|KVR13N9S6/2|KVR13N9S8/4|1333")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# CPU_POOL/BOARD_POOL 是 manifest 的 enabled 兼容视图；旧 socket 出现在这里就
# 代表随机器又能生成行为上不成立的 DDR3 整机，必须阻断。
for row in "${CPU_POOL[@]}"; do
    IFS='|' read -r _ _ _ _ _ _ _ socket <<<"$row"
    case "$socket" in
        AM3|AM3+|FM2+|LGA1155)
            fail "DDR3 CPU 泄漏到新 VM 随机池: $row" ;;
    esac
done
for row in "${BOARD_POOL[@]}"; do
    socket="${row%%|*}"
    case "$socket" in
        AM3|AM3+|FM2+|LGA1155)
            fail "DDR3 主板泄漏到新 VM 随机池: $row" ;;
    esac
done

# 历史 profile 仍可能引用这些真实 DIMM part，因此物料目录不能在迁移期间被删掉，
# 同时也不能混入未经核验的自造容量。
ddr3_material_count=0
for row in "${MEM_POOL[@]}"; do
    fields="$(awk -F'|' '{print NF}' <<<"$row")"
    (( fields == 5 )) || fail "MEM_POOL 必须是 5 字段: $row"
    IFS='|' read -r mfr part_2g part_4g rated sockets <<<"$row"
    [[ "$rated" =~ ^[0-9]+$ && -n "$sockets" ]] || fail "内存速率/socket 无效: $row"
    is_known_memory_product_pair "$mfr" "$part_2g" "$part_4g" "$rated" \
        || fail "MEM_POOL 包含未核验型号: $row"
    if [[ ",$sockets," == *",AM3,"* || ",$sockets," == *",AM3+,"* \
        || ",$sockets," == *",FM2+,"* || ",$sockets," == *",LGA1155,"* ]]; then
        ddr3_material_count=$((ddr3_material_count + 1))
    fi
done
(( ddr3_material_count >= 4 )) || fail "历史 DDR3 物料被意外删除"

# 当前所有可随机 bundle 都必须明确报告 DDR4；compatibility AMD 条目也使用 DDR4，
# 但因为 enabled=false 不进入 CPU_POOL。
for row in "${PLATFORM_POOL[@]}"; do
    IFS='|' read -r platform_id enabled _ _ _ _ <<<"$row"
    [[ "$enabled" == true ]] || continue
    stealth_platform_load "$platform_id"
    [[ "$MEM_TYPE" == DDR4 && "$MEM_VOLTAGE_MV" == 1200 ]] \
        || fail "enabled 平台不是 DDR4 1.2V: $platform_id"
done

echo "OK: DDR3 legacy materials are isolated from enabled platforms"

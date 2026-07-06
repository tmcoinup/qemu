#!/usr/bin/env bash
# 验证 DDR3 家用平台硬件池：CPU / 主板 / 内存必须按 socket 成套出现。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"

socket_has_board() {
    local socket="$1" row
    for row in "${BOARD_POOL[@]}"; do
        [[ "${row%%|*}" == "$socket" ]] && return 0
    done
    return 1
}

cpu_memory_limit() {
    local name="$1"
    CPU_NAME="$name" CPU_MODEL="" _cpu_max_mem
}

socket_has_memory_under_limit() {
    local socket="$1" limit="$2" row rated sockets
    for row in "${MEM_POOL[@]}"; do
        IFS='|' read -r _ _ _ rated sockets <<<"$row"
        [[ "$rated" =~ ^[0-9]+$ ]] || continue
        [[ ",$sockets," == *",$socket,"* ]] && (( rated <= limit )) && return 0
    done
    return 1
}

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

is_known_no_igpu_consumer_ddr3_cpu() {
    local name="$1"
    case "$name" in
        "AMD Athlon(tm) II X2 250 Processor" \
        |"AMD Athlon(tm) II X4 640 Processor" \
        |"AMD Phenom(tm) II X4 955 Processor" \
        |"AMD FX(tm)-4100 Quad-Core Processor" \
        |"AMD FX(tm)-4300 Quad-Core Processor" \
        |"AMD Athlon(tm) X4 860K Quad Core Processor" \
        |"Intel(R) Core(TM) i5-2380P CPU @ 3.10GHz" \
        |"Intel(R) Core(TM) i5-2550K CPU @ 3.40GHz" \
        |"Intel(R) Core(TM) i5-3350P CPU @ 3.10GHz")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

for row in "${CPU_POOL[@]}"; do
    [[ "$row" != *"Xeon"* ]] || fail "DDR3 家用池不得引入 Xeon/E 系列 CPU: $row"
    [[ "$row" != *" E3-"* ]] || fail "DDR3 家用池不得引入 E3 CPU: $row"
done

ddr3_cpu_count=0
for row in "${CPU_POOL[@]}"; do
    IFS='|' read -r _ _ name _ _ _ _ socket <<<"$row"
    case "$socket" in
        AM3|AM3+|FM2+|LGA1155)
            ddr3_cpu_count=$((ddr3_cpu_count + 1))
            is_known_no_igpu_consumer_ddr3_cpu "$name" \
                || fail "DDR3 CPU 不在无核显家用白名单: $name"
            limit="$(cpu_memory_limit "$name")"
            socket_has_board "$socket" || fail "CPU $name 的 socket=$socket 缺少主板"
            socket_has_memory_under_limit "$socket" "$limit" \
                || fail "CPU $name 的 socket=$socket 缺少 <=${limit}MT/s 的 DDR3 内存"
            ;;
    esac
done
(( ddr3_cpu_count >= 4 )) || fail "DDR3 CPU 数量过少: $ddr3_cpu_count"

for row in "${MEM_POOL[@]}"; do
    fields="$(awk -F'|' '{print NF}' <<<"$row")"
    (( fields == 5 )) || fail "MEM_POOL 必须是 5 字段: $row"
    IFS='|' read -r mfr part_2g part_4g rated sockets <<<"$row"
    [[ "$rated" =~ ^[0-9]+$ ]] || fail "MEM_POOL 速率不是整数: $row"
    [[ -n "$sockets" ]] || fail "MEM_POOL 缺 socket 列: $row"
    is_known_memory_product_pair "$mfr" "$part_2g" "$part_4g" "$rated" \
        || fail "MEM_POOL 包含未核验的内存型号组合: $row"
done

for row in "${CPU_POOL[@]}"; do
    IFS='|' read -r _ _ name _ _ _ _ socket <<<"$row"
    limit="$(cpu_memory_limit "$name")"
    socket_has_memory_under_limit "$socket" "$limit" \
        || fail "CPU $name 的 socket=$socket 缺少 <=${limit}MT/s 的内存"
done

echo "OK: DDR3 consumer pool matching checks passed"

#!/usr/bin/env bash
# DDR3 物料供显式 household compatibility 整机使用；默认 enabled 平台仍必须
# 保持 DDR4。测试同时阻止 DDR3 跨 socket 泄漏到 LGA1151/AM4。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"

is_known_active_memory_product_pair() {
    local key="$1|$2|$3|$4"
    case "$key" in
        "Samsung|M378A5644EB0-CRC|M378A5244CB0-CRC|2400" \
        |"Crucial|CT2G4DFS624A|CT4G4DFS824A|2400" \
        |"Kingston|KVR16N11S6/2|KVR16N11S8/4|1600" \
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

# 旧双料号视图只允许五组有型号级依据的 DDR4/DDR3。Kingston DDR4 仅有
# 官方可证的 4GB 单品，由新 module API 选择，不伪造 2GB 料号来拼旧 ABI。
# DDR3 只绑定老家用 socket，
# 不会被默认 LGA1151/AM4 bundle 抽到。
active_count=0
for row in "${MEM_POOL[@]}"; do
    fields="$(awk -F'|' '{print NF}' <<<"$row")"
    (( fields == 9 )) || fail "MEM_POOL 必须是 9 字段: $row"
    IFS='|' read -r mfr part_2g part_4g rated sockets \
        rank_2g width_2g rank_4g width_4g <<<"$row"
    [[ "$rated" =~ ^[0-9]+$ && -n "$sockets" ]] || fail "内存速率/socket 无效: $row"
    [[ "$rank_2g" =~ ^[1-4]$ && "$rank_4g" =~ ^[1-4]$ ]] \
        || fail "内存 rank 无效: $row"
    [[ "$width_2g" =~ ^(4|8|16)$ && "$width_4g" =~ ^(4|8|16)$ ]] \
        || fail "内存 device-width 无效: $row"
    is_known_active_memory_product_pair "$mfr" "$part_2g" "$part_4g" "$rated" \
        || fail "MEM_POOL 包含未核验型号: $row"
    if (( rated <= 1600 )); then
        [[ ",$sockets," != *",AM4,"* && ",$sockets," != *",LGA1151,"* &&
           ",$sockets," != *",LGA1200,"* ]] \
            || fail "DDR3 物料错误绑定到 DDR4 socket: $row"
    fi
    active_count=$((active_count + 1))
done
(( active_count == 5 )) || fail "旧双料号池应为两组 DDR4 + 三组 DDR3"

# 三组已核验 DDR3 已因家用 compatibility bundle 转为活动物料。
(( ${#MEM_DORMANT_POOL[@]} == 0 )) || fail "DDR3 不应继续留在 dormant 目录"

# 两组证据不足项必须明确隔离，不能被 geometry/strict contains 当成活动目录。
(( ${#MEM_QUARANTINED_POOL[@]} == 2 )) || fail "quarantine 目录数量错误"
for row in "${MEM_QUARANTINED_POOL[@]}"; do
    IFS='|' read -r mfr part_2g part_4g rated _ \
        rank_2g width_2g rank_4g width_4g <<<"$row"
    if stealth_memory_catalog_contains "$mfr" "$part_2g" "$part_4g" "$rated" \
        "$rank_2g" "$width_2g" "$rank_4g" "$width_4g"; then
        fail "quarantine 内存被活动目录接受: $row"
    fi
done

# 当前所有可随机 bundle 都必须明确报告 DDR4；compatibility AMD 条目也使用 DDR4，
# 但因为 enabled=false 不进入 CPU_POOL。
for row in "${PLATFORM_POOL[@]}"; do
    IFS='|' read -r platform_id enabled _ _ _ _ <<<"$row"
    [[ "$enabled" == true ]] || continue
    stealth_platform_load "$platform_id"
    [[ "$MEM_TYPE" == DDR4 && "$MEM_VOLTAGE_MV" == 1200 ]] \
        || fail "enabled 平台不是 DDR4 1.2V: $platform_id"
done

echo "OK: DDR3 household materials remain isolated from default enabled platforms"

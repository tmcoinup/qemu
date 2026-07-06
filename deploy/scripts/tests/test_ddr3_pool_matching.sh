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

socket_has_memory() {
    local socket="$1" row sockets
    for row in "${MEM_POOL[@]}"; do
        IFS='|' read -r _ _ _ _ sockets <<<"$row"
        [[ ",$sockets," == *",$socket,"* ]] && return 0
    done
    return 1
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
            socket_has_board "$socket" || fail "CPU $name 的 socket=$socket 缺少主板"
            socket_has_memory "$socket" || fail "CPU $name 的 socket=$socket 缺少 DDR3 内存"
            ;;
    esac
done
(( ddr3_cpu_count >= 4 )) || fail "DDR3 CPU 数量过少: $ddr3_cpu_count"

for row in "${MEM_POOL[@]}"; do
    fields="$(awk -F'|' '{print NF}' <<<"$row")"
    (( fields == 5 )) || fail "MEM_POOL 必须是 5 字段: $row"
    IFS='|' read -r _ _ _ rated sockets <<<"$row"
    [[ "$rated" =~ ^[0-9]+$ ]] || fail "MEM_POOL 速率不是整数: $row"
    [[ -n "$sockets" ]] || fail "MEM_POOL 缺 socket 列: $row"
done

echo "OK: DDR3 consumer pool matching checks passed"

#!/bin/bash
# ---------------------------------------------------------------------------
# 宿主物理上联的只读拓扑探测
#
# 调用方负责提供严格的物理接口校验函数。本文件只按固定优先级收集候选，并且
# 只有候选唯一时才返回：默认路由物理口 -> 已接入 bridge 的物理口 ->
# 唯一 carrier-up 物理口。整个过程不修改 NetworkManager 或内核网络状态。
# ---------------------------------------------------------------------------

uplink_detect_from_topology() {
    local candidate_check="$1"
    local bridge_name="$2"
    local sys_class_net="${3:-/sys/class/net}"
    local candidate line path
    local -a candidates=()

    # 同时支持 IPv4-only 与 IPv6-only 宿主；同一接口上的多个默认路由先去重。
    while IFS= read -r candidate; do
        "$candidate_check" "$candidate" "$bridge_name" \
            && candidates+=("$candidate")
    done < <(
        {
            ip -4 route show default 2>/dev/null || true
            ip -6 route show default 2>/dev/null || true
        } | awk '{
            for (i = 1; i < NF; i++)
                if ($i == "dev")
                    print $(i + 1)
        }' | sort -u
    )
    if (( ${#candidates[@]} == 1 )); then
        printf '%s\n' "${candidates[0]}"
        return 0
    elif (( ${#candidates[@]} > 1 )); then
        return 1
    fi

    candidates=()
    while IFS= read -r line; do
        candidate="${line#*: }"
        candidate="${candidate%%:*}"
        candidate="${candidate%%@*}"
        "$candidate_check" "$candidate" "$bridge_name" \
            && candidates+=("$candidate")
    done < <(ip -o link show master "$bridge_name" 2>/dev/null || true)
    if (( ${#candidates[@]} == 1 )); then
        printf '%s\n' "${candidates[0]}"
        return 0
    elif (( ${#candidates[@]} > 1 )); then
        return 1
    fi

    candidates=()
    for path in "$sys_class_net"/*/device; do
        [[ -e "$path" ]] || continue
        candidate="${path%/device}"
        candidate="${candidate##*/}"
        [[ "$(cat -- "$sys_class_net/$candidate/carrier" 2>/dev/null || true)" == "1" ]] \
            && "$candidate_check" "$candidate" "$bridge_name" \
            && candidates+=("$candidate")
    done
    (( ${#candidates[@]} == 1 )) || return 1
    printf '%s\n' "${candidates[0]}"
}


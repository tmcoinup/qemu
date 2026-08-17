#!/bin/bash
# ---------------------------------------------------------------------------
# VLAN 网络共享校验库
#
# 本文件同时被普通用户运行的 VM 启动器和 root 运行的宿主建桥脚本 source。
# 因此这里只放无副作用的纯函数：不修改网卡、不调用 sudo，也不改变调用方的
# `set -euo pipefail` 状态。所有函数均通过 stdout 返回结果，失败时返回非零值。
# ---------------------------------------------------------------------------

# Linux 的 IFNAMSIZ 为 16，其中最后一个字节留给字符串结尾，所以可见接口名
# 最长 15 字符。额外限制到常用安全字符，避免接口名在 QEMU `-netdev` 的逗号
# 分隔字符串中被解释成新参数，也避免换行等字符污染 bridge.conf。
vlan_validate_ifname() {
    local name="${1:-}"

    [[ -n "$name" && ${#name} -le 15 ]] || return 1
    [[ "$name" =~ ^[[:alnum:]_.-]+$ ]] || return 1
    [[ "$name" != "." && "$name" != ".." ]] || return 1
}

# 校验并规范化 802.1Q VLAN ID。
# 0 只用于 priority tag，4095 是保留值；可分配 VLAN 的合法范围为 1..4094。
# 输入最多四位，既允许 `0011` 这类显式十进制写法，又避免 Bash 算术溢出。
vlan_validate_id() {
    local raw="${1:-}"
    local normalized

    [[ "$raw" =~ ^[0-9]{1,4}$ ]] || return 1
    normalized=$((10#$raw))
    (( normalized >= 1 && normalized <= 4094 )) || return 1
    printf '%d\n' "$normalized"
}

# 校验 setup 写入 root 配置的 VLAN 白名单。格式为逗号分隔的单个 VID 或闭区间，
# 例如 `11,20,30-39`；不允许空项、空白、降序区间或保留 VID。
vlan_validate_allowlist() {
    local allowlist="${1:-}"
    local item first last
    local -a items=()

    [[ -n "$allowlist" && ${#allowlist} -le 4096 ]] || return 1
    [[ "$allowlist" =~ ^[0-9]{1,4}(-[0-9]{1,4})?(,[0-9]{1,4}(-[0-9]{1,4})?)*$ ]] \
        || return 1
    IFS=',' read -r -a items <<<"$allowlist"
    for item in "${items[@]}"; do
        if [[ "$item" == *-* ]]; then
            first="$(vlan_validate_id "${item%%-*}")" || return 1
            last="$(vlan_validate_id "${item#*-}")" || return 1
            (( first <= last )) || return 1
        else
            vlan_validate_id "$item" >/dev/null || return 1
        fi
    done
}

# 成功表示请求 VID 位于白名单某个单值/区间内；失败不输出任何内容。
vlan_id_is_allowed() {
    local requested allowlist item first last
    local -a items=()

    requested="$(vlan_validate_id "${1:-}")" || return 1
    allowlist="${2:-}"
    vlan_validate_allowlist "$allowlist" || return 1
    IFS=',' read -r -a items <<<"$allowlist"
    for item in "${items[@]}"; do
        if [[ "$item" == *-* ]]; then
            first="$(vlan_validate_id "${item%%-*}")" || return 1
            last="$(vlan_validate_id "${item#*-}")" || return 1
            (( requested >= first && requested <= last )) && return 0
        else
            first="$(vlan_validate_id "$item")" || return 1
            (( requested == first )) && return 0
        fi
    done
    return 1
}

# 每个实例使用确定性 persistent TAP。`g11t` 占 4 字符，Linux 接口名最多
# 15 字符，因此 VLAN 模式把实例号限制为最多 10 位。无 VLAN 路径仍接受原有
# 实例范围，不受该限制影响。
vlan_tap_name() {
    local instance="${1:-}"
    local tap

    [[ "$instance" =~ ^[0-9]{1,10}$ ]] || return 1
    (( 10#$instance >= 1 )) || return 1
    tap="g11t${instance}"
    vlan_validate_ifname "$tap" || return 1
    printf '%s\n' "$tap"
}

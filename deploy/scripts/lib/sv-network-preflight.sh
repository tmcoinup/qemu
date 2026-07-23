#!/bin/bash
# ---------------------------------------------------------------------------
# 普通 bridge 网络的只读宿主健康预检
#
# 显式 VLAN 已由 sv-vlan-preflight.sh 和 root helper 做完整拓扑核验。本文件只补
# 普通 `-netdev bridge` 路径的缺口：仅当 root-owned stealth-vlan.conf 能把当前
# bridge 精确绑定到一个物理上联时，才要求 bridge/上联在创建 QEMU TAP 前健康。
# 没有可信配置、显式 isolated bridge、user-mode NAT 与 DRY_RUN 均保持历史语义。
# ---------------------------------------------------------------------------

# Linux IFNAMSIZ 为 16；同时限制安全字符，避免配置字段进入 ip 参数或诊断文本时
# 被解释为选项、空白或换行。
sv_bridge_preflight_ifname_is_safe() {
    local name="${1:-}"

    [[ -n "$name" && ${#name} -le 15 ]] || return 1
    [[ "$name" =~ ^[[:alnum:]_][[:alnum:]_.-]*$ ]] || return 1
    [[ "$name" != "." && "$name" != ".." ]]
}

# 配置及父目录都必须由 root 控制，且组/其他用户不可写。调用方只把该文件作为
# “是否启用严格预检”的可信事实来源；不 source，也不执行其中任何内容。
sv_bridge_preflight_path_is_trusted() {
    local path="$1" kind="$2"
    local owner mode

    case "$kind" in
        file) [[ -f "$path" && ! -L "$path" ]] || return 1 ;;
        dir)  [[ -d "$path" && ! -L "$path" ]] || return 1 ;;
        *) return 1 ;;
    esac
    owner="$(stat -c '%u' -- "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 1
    [[ "$owner" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#022) == 0 ))
}

# 严格解析 setup-bridge.sh 生成的五字段配置。返回非零表示“没有可采信的上联”，
# 上层会保持历史 bridge/NAT/isolated 行为，而不是根据不可信文件猜测物理接口。
sv_bridge_preflight_load_uplink() {
    local selected_bridge="$1" config="$2"
    local config_dir line key value configured_bridge="" uplink=""
    local -A seen=()

    config_dir="$(dirname -- "$config")" || return 1
    sv_bridge_preflight_path_is_trusted "$config_dir" dir || return 1
    sv_bridge_preflight_path_is_trusted "$config" file || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" =~ ^([A-Z_]+)=([^[:space:]]+)$ ]] || return 1
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        [[ -z "${seen[$key]:-}" ]] || return 1
        seen["$key"]=1
        case "$key" in
            VERSION)     [[ "$value" == "1" ]] || return 1 ;;
            BRIDGE)      configured_bridge="$value" ;;
            UPLINK)      uplink="$value" ;;
            ALLOWED_UID|ALLOWED_GID) [[ "$value" =~ ^[0-9]+$ ]] || return 1 ;;
            *) return 1 ;;
        esac
    done <"$config"

    [[ "${seen[VERSION]:-}" == "1" && "${seen[BRIDGE]:-}" == "1" \
        && "${seen[UPLINK]:-}" == "1" && "${seen[ALLOWED_UID]:-}" == "1" \
        && "${seen[ALLOWED_GID]:-}" == "1" ]] || return 1
    sv_bridge_preflight_ifname_is_safe "$selected_bridge" || return 1
    sv_bridge_preflight_ifname_is_safe "$configured_bridge" || return 1
    sv_bridge_preflight_ifname_is_safe "$uplink" || return 1
    [[ "$configured_bridge" == "br0" && "$selected_bridge" == "$configured_bridge" \
        && "$uplink" != "$configured_bridge" && "$uplink" != "lo" \
        && "$uplink" != svtap* && "$uplink" != tap* && "$uplink" != vnet* ]] \
        || return 1

    printf '%s\n' "$uplink"
}

# `ip -o link` 的首个尖括号字段是内核接口 flags。转成逗号包围的字符串后做精确
# token 匹配，避免把 LOWER_UP 误认为 UP，或受接口后续详情中的单词干扰。
sv_bridge_preflight_link_has_flag() {
    local details="$1" expected="$2" flags

    [[ "$details" == *"<"*">"* ]] || return 1
    flags="${details#*<}"
    flags="${flags%%>*}"
    [[ ",$flags," == *",$expected,"* ]]
}

sv_bridge_preflight_error() {
    echo "ERROR: bridge 上联健康预检失败: $*" >&2
    echo "       请先修复宿主 br0；本次拒绝创建会落入空 bridge 的 QEMU TAP。" >&2
}

# 只读核验当前运行态，不要求宿主 IPv4、默认路由或 DHCP 成功。L2 bridge 可以在
# 没有宿主三层地址时正常转发；这里真正需要保证的是 QEMU 首包能够到达物理上联。
sv_bridge_uplink_preflight() {
    local bridge_name="$1" config="$2" sys_class_net="$3"
    local uplink bridge_details uplink_details link_type carrier

    # 返回 0 代表此配置不适用：只有可信的 br0 配置才扩大 fail-closed 范围。
    if ! uplink="$(sv_bridge_preflight_load_uplink "$bridge_name" "$config")"; then
        return 0
    fi

    if ! bridge_details="$(ip -d -o link show dev "$bridge_name" 2>/dev/null)"; then
        sv_bridge_preflight_error "bridge '$bridge_name' 不存在"
        return 1
    fi
    if [[ ! "$bridge_details" =~ [[:space:]]bridge[[:space:]]+forward_delay[[:space:]] ]]; then
        sv_bridge_preflight_error "接口 '$bridge_name' 不是 Linux bridge"
        return 1
    fi
    if ! sv_bridge_preflight_link_has_flag "$bridge_details" UP; then
        sv_bridge_preflight_error "bridge '$bridge_name' 未处于 UP 状态"
        return 1
    fi

    if [[ ! -e "$sys_class_net/$uplink/device" \
        || -d "$sys_class_net/$uplink/wireless" ]]; then
        sv_bridge_preflight_error "配置上联 '$uplink' 不是可验证的有线物理设备"
        return 1
    fi
    IFS= read -r link_type <"$sys_class_net/$uplink/type" || link_type=""
    if [[ "$link_type" != "1" ]]; then
        sv_bridge_preflight_error "配置上联 '$uplink' 不是 Ethernet 接口"
        return 1
    fi

    if ! uplink_details="$(ip -d -o link show dev "$uplink" 2>/dev/null)"; then
        sv_bridge_preflight_error "配置上联 '$uplink' 不存在"
        return 1
    fi
    if [[ " $uplink_details " != *" master $bridge_name "* ]]; then
        sv_bridge_preflight_error "上联 '$uplink' 未连接到 '$bridge_name'"
        return 1
    fi
    if ! sv_bridge_preflight_link_has_flag "$uplink_details" UP; then
        sv_bridge_preflight_error "上联 '$uplink' 未处于 UP 状态"
        return 1
    fi
    if ! sv_bridge_preflight_link_has_flag "$uplink_details" LOWER_UP; then
        sv_bridge_preflight_error "上联 '$uplink' 没有 LOWER_UP/carrier"
        return 1
    fi
    IFS= read -r carrier <"$sys_class_net/$uplink/carrier" || carrier=""
    if [[ "$carrier" != "1" ]]; then
        sv_bridge_preflight_error "上联 '$uplink' carrier 不可用"
        return 1
    fi
}

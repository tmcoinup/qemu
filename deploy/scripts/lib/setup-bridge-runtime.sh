#!/bin/bash
# ---------------------------------------------------------------------------
# setup-bridge.sh 的 bridge VLAN 运行态只读校验
#
# 单独拆出文本解析，避免宿主安装主流程超过单文件上限。函数只读取 bridge VLAN
# 表，不写接口；调用方确认安全后才设置 VID 1 native/PVID。
# ---------------------------------------------------------------------------

# shellcheck disable=SC1091  # 运行时按当前库目录加载共享只读探测函数。
_SETUP_BRIDGE_RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SETUP_BRIDGE_RUNTIME_DIR/uplink-detect.sh"
unset _SETUP_BRIDGE_RUNTIME_DIR

# setup-bridge.sh 的错误输出统一走 stderr，便于启动器复检时保留 stdout 契约。
setup_error() {
    echo "ERROR: $*" >&2
}

# Linux IFNAMSIZ 为 16，接口可见名称最多 15 字符。额外限制字符集合，防止名称
# 进入 nmcli、iproute2 或 bridge.conf 时被解释成参数或注入换行。
setup_validate_ifname() {
    local name="${1:-}"

    [[ -n "$name" && ${#name} -le 15 ]] || return 1
    [[ "$name" =~ ^[[:alnum:]_.-]+$ ]] || return 1
    [[ "$name" != "." && "$name" != ".." ]]
}

# 自动模式绝不按 enp*/eth* 名称猜测。候选必须是可验证的有线物理设备，
# 且不能已被 br0 以外的 controller 接管；Wi-Fi 和虚拟 link kind 均需显式处理。
setup_uplink_candidate_is_physical() {
    local candidate="$1"
    local bridge_name="${2:-${BR:-br0}}"
    local sys_class_net="${3:-/sys/class/net}"
    local details

    setup_validate_ifname "$candidate" || return 1
    [[ "$candidate" != "$bridge_name" && "$candidate" != "lo" \
        && "$candidate" != svtap* && "$candidate" != tap* \
        && "$candidate" != vnet* ]] || return 1
    [[ -e "$sys_class_net/$candidate/device" \
        && ! -d "$sys_class_net/$candidate/wireless" ]] || return 1
    # 只自动接管 carrier-up 的 ARPHRD_ETHER(1)。物理口的 stale linkdown
    # default route、InfiniBand/WWAN 等非 Ethernet 设备必须由管理员显式处理。
    [[ "$(cat -- "$sys_class_net/$candidate/type" 2>/dev/null || true)" == "1" \
        && "$(cat -- "$sys_class_net/$candidate/carrier" 2>/dev/null || true)" == "1" ]] \
        || return 1
    details="$(ip -d -o link show dev "$candidate" 2>/dev/null)" || return 1
    if [[ "$details" =~ [[:space:]]master[[:space:]]+([^[:space:]]+) \
        && "${BASH_REMATCH[1]}" != "$bridge_name" ]]; then
        return 1
    fi
    [[ ! "$details" =~ [[:space:]]vlan[[:space:]]+protocol[[:space:]] \
        && ! "$details" =~ [[:space:]]macvlan[[:space:]] \
        && ! "$details" =~ [[:space:]]macvtap[[:space:]] ]]
}

# 所有用户输入必须在 root 检查、flock、文件安装和网络修改之前完成校验。这样旧
# 参数或拼写错误只返回退出码 2，不会留下半套宿主配置。
setup_validate_inputs() {
    local uplink_detected=0

    if [[ -v VLAN_ID || -v VLAN_IF ]]; then
        setup_error "VLAN_ID/VLAN_IF 已废弃；setup 默认启用 trunk，请在启动 VM 时传 --vlan-id=N。"
        return 2
    fi

    VLAN_TRUNK="${VLAN_TRUNK:-1}"
    VLAN_SETUP_AUTO="${VLAN_SETUP_AUTO:-0}"
    UPLINK_AUTO="${UPLINK_AUTO:-0}"
    UPLINK="${UPLINK:-}"
    HOST_IP="${HOST_IP:-192.168.76.1/24}"
    BR="${BR:-br0}"

    [[ "$VLAN_TRUNK" == "0" || "$VLAN_TRUNK" == "1" ]] || {
        setup_error "VLAN_TRUNK 必须为 0 或 1（实际: '$VLAN_TRUNK'）。"
        return 2
    }
    [[ "$VLAN_SETUP_AUTO" == "0" || "$VLAN_SETUP_AUTO" == "1" ]] || {
        setup_error "VLAN_SETUP_AUTO 必须为 0 或 1（实际: '$VLAN_SETUP_AUTO'）。"
        return 2
    }
    [[ "$UPLINK_AUTO" == "0" || "$UPLINK_AUTO" == "1" ]] || {
        setup_error "UPLINK_AUTO 必须为 0 或 1（实际: '$UPLINK_AUTO'）。"
        return 2
    }
    setup_validate_ifname "$BR" || {
        setup_error "bridge 名 '$BR' 非法（最多 15 个安全字符）。"
        return 2
    }
    if [[ -n "$UPLINK" ]]; then
        setup_validate_ifname "$UPLINK" || {
            setup_error "上联接口名 '$UPLINK' 非法。"
            return 2
        }
        [[ "$UPLINK" != "$BR" ]] || {
            setup_error "BR 与 UPLINK 不能使用同一接口 '$BR'。"
            return 2
        }
    fi

    if [[ "$VLAN_TRUNK" == "1" ]]; then
        [[ "$BR" == "br0" ]] || {
            setup_error "VLAN_TRUNK=1 固定使用单一 br0，不能设置 BR='$BR'。"
            return 2
        }
    fi

    # trunk 沿用缺省自动探测；普通 bridge 只有管理员显式 UPLINK_AUTO=1 才会
    # 接管物理口。两者都要求拓扑中恰好一个安全候选，歧义或无候选一律失败闭合。
    if [[ -z "$UPLINK" \
        && ( "$VLAN_TRUNK" == "1" || "$UPLINK_AUTO" == "1" ) ]]; then
        if ! UPLINK="$(uplink_detect_from_topology \
            setup_uplink_candidate_is_physical "$BR")"; then
            setup_error "无法唯一识别安全的物理上联；请显式设置 UPLINK=<网卡>。"
            return 2
        fi
        uplink_detected=1
    fi

    # 普通 bridge 的自动修复必须由 NetworkManager 完成 DHCP/profile 迁移。旧
    # iproute2 fallback 只迁移接口地址，不掌管 DHCP lease 与默认路由；启动时
    # 自动进入该分支可能让宿主立即断网。管理员显式给出 UPLINK 时仍保留历史
    # fallback，isolated bridge 与 trunk 行为也不受影响。
    if [[ "$VLAN_TRUNK" == "0" && "$UPLINK_AUTO" == "1" \
        && "$uplink_detected" == "1" ]] && ! setup_nm_is_active; then
        setup_error "普通 bridge 自动上联需要正在运行的 NetworkManager；拒绝使用非持久 iproute2 fallback。"
        return 2
    fi
    (( uplink_detected == 0 )) || echo ">> auto-detected uplink: $UPLINK"
}

# 自动启动器会在 sudo 前完成一次人工确认，但不同实例仍可能同时确认。下面的
# 只读契约检查在 root 全局锁内执行，让后获得锁的进程识别“前一个已经完成”，
# 从而不再 down/up NetworkManager bridge。普通管理员手动重跑仍保留原修复语义。
setup_root_file_is_trusted() {
    local path="$1" expected_mode="${2:-}" owner mode

    [[ -f "$path" && ! -L "$path" ]] || return 1
    owner="$(stat -c '%u' -- "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 1
    [[ "$owner" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#022) == 0 )) || return 1
    [[ -z "$expected_mode" || "$mode" == "$expected_mode" ]]
}

setup_root_directory_is_trusted() {
    local path="$1" owner mode

    [[ -d "$path" && ! -L "$path" ]] || return 1
    owner="$(stat -c '%u' -- "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 1
    [[ "$owner" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#022) == 0 ))
}

setup_vlan_expected_config() {
    printf 'VERSION=1\nBRIDGE=br0\nUPLINK=%s\nALLOWED_UID=%s\nALLOWED_GID=%s\n' \
        "$UPLINK" "$ALLOWED_UID_VALUE" "$ALLOWED_GID_VALUE"
}

setup_vlan_expected_sudoers() {
    printf '# 仅允许 setup 时的调用用户执行严格校验过的 root-owned TAP helper。\n'
    printf '#%s ALL=(root) NOPASSWD:NOSETENV: %s\n' \
        "$ALLOWED_UID_VALUE" "$VLAN_TAP_INSTALLED"
}

# 配置存在但不属于当前 VM 用户时，自动模式必须拒绝覆盖。该判定也覆盖符号链接、
# 非 root owner、可写权限、未知字段和重复字段，因为生成文件必须逐字匹配固定格式。
setup_vlan_config_matches_request() {
    local actual expected

    setup_root_directory_is_trusted "$(dirname "$VLAN_CONFIG")" || return 1
    setup_root_file_is_trusted "$VLAN_CONFIG" 644 || return 1
    actual="$(<"$VLAN_CONFIG")"
    expected="$(setup_vlan_expected_config)"
    [[ "$actual" == "$expected" ]]
}

setup_vlan_config_path_exists() {
    [[ -e "$VLAN_CONFIG" || -L "$VLAN_CONFIG" ]]
}

setup_vlan_runtime_contract_matches() {
    local actual expected

    setup_root_directory_is_trusted "$(dirname "$VLAN_TAP_INSTALLED")" || return 1
    setup_root_directory_is_trusted "$(dirname "$VLAN_SUDOERS")" || return 1
    setup_root_file_is_trusted "$VLAN_TAP_INSTALLED" 755 \
        && [[ -x "$VLAN_TAP_INSTALLED" ]] || return 1
    setup_root_file_is_trusted "$VLAN_DOWN_INSTALLED" 755 \
        && [[ -x "$VLAN_DOWN_INSTALLED" ]] || return 1
    cmp -s -- "$VLAN_TAP_SOURCE" "$VLAN_TAP_INSTALLED" || return 1
    cmp -s -- "$VLAN_DOWN_SOURCE" "$VLAN_DOWN_INSTALLED" || return 1
    setup_vlan_config_matches_request || return 1
    setup_root_file_is_trusted "$VLAN_SUDOERS" 440 || return 1
    actual="$(<"$VLAN_SUDOERS")"
    expected="$(setup_vlan_expected_sudoers)"
    [[ "$actual" == "$expected" ]] || return 1
    visudo -cf "$VLAN_SUDOERS" >/dev/null 2>&1
}

# bridge 输出使用“首行端口名、后续行缩进”的格式。只有唯一 VID 1 同时具备
# PVID/Egress/Untagged 才算 native LAN 完整，其他 VID 只能是纯 tagged。
setup_uplink_vid1_is_native() {
    local uplink="$1"

    bridge vlan show dev "$uplink" 2>/dev/null | awk -v dev="$uplink" '
        NR == 1 || NF == 0 { next }
        {
            if ($1 == dev && $2 ~ /^[0-9]+$/) { token = $2; start = 3 }
            else { token = $1; start = 2 }
            native = 0
            for (i = start; i <= NF; i++)
                if ($i == "PVID" || $i == "Egress" || $i == "Untagged") native++
            if (token == "1" && native == 3) good++
            else if (native > 0) bad = 1
        }
        END { exit(good == 1 && !bad ? 0 : 1) }
    '
}

setup_vlan_topology_is_ready() {
    local bridge_info uplink_info

    bridge_info="$(ip -d -o link show dev br0 2>/dev/null)" || return 1
    [[ "$bridge_info" =~ [[:space:]]bridge[[:space:]]+forward_delay[[:space:]] \
        && "$bridge_info" =~ [[:space:]]vlan_filtering[[:space:]]+1([[:space:]]|$) \
        && "$bridge_info" =~ [,\<]UP[,\>] ]] || return 1
    uplink_info="$(ip -o link show dev "$UPLINK" 2>/dev/null)" || return 1
    [[ "$uplink_info" =~ [[:space:]]master[[:space:]]+br0([[:space:]]|$) \
        && "$uplink_info" =~ [,\<]UP[,\>] ]] || return 1
    setup_uplink_vid1_is_native "$UPLINK"
}

# NetworkManager 的 controller 与 port 有两套独立的自动激活开关。安装事务中
# 临时由 controller 带起 port；持久状态则让物理口在 carrier 晚到时自行加入
# 已经 active 的 bridge，避免空 br0 等到 DHCP 超时后才重建。
setup_nm_is_active() {
    command -v nmcli >/dev/null 2>&1 \
        && command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet NetworkManager 2>/dev/null
}

setup_nm_value_is_true() {
    case "${1:-}" in
        1|yes|true) return 0 ;;
        *) return 1 ;;
    esac
}

setup_nm_value_is_false() {
    case "${1:-}" in
        0|no|false) return 0 ;;
        *) return 1 ;;
    esac
}

setup_nm_profiles_match_boot_contract() {
    local bridge_name="${1:-${BR:-br0}}"
    local uplink="${2:-${UPLINK:-}}"
    local slave bridge_auto port_auto auto_ports profile_names

    [[ -n "$uplink" ]] || return 0
    slave="$bridge_name-slave-$uplink"
    profile_names="$(nmcli -t -f NAME connection show 2>/dev/null)" || return 1
    grep -Fx -- "$bridge_name" <<<"$profile_names" >/dev/null || return 1
    grep -Fx -- "$slave" <<<"$profile_names" >/dev/null || return 1
    bridge_auto="$(nmcli -g connection.autoconnect \
        connection show "$bridge_name" 2>/dev/null)" || return 1
    port_auto="$(nmcli -g connection.autoconnect \
        connection show "$slave" 2>/dev/null)" || return 1
    auto_ports="$(nmcli -g connection.autoconnect-slaves \
        connection show "$bridge_name" 2>/dev/null)" || return 1
    setup_nm_value_is_true "$bridge_auto" \
        && setup_nm_value_is_true "$port_auto" \
        && setup_nm_value_is_false "$auto_ports"
}

setup_nm_boot_contract_is_ready() {
    # iproute2 fallback 没有 NM profile 契约；运行态拓扑校验仍然必须通过。
    setup_nm_is_active || return 0
    setup_nm_profiles_match_boot_contract "$@"
}

setup_nm_persist_boot_contract() {
    local bridge_name="$1" uplink="$2"
    local slave="$bridge_name-slave-$uplink"
    local old_bridge_auto old_port_auto old_auto_ports

    old_bridge_auto="$(nmcli -g connection.autoconnect \
        connection show "$bridge_name" 2>/dev/null)" || return 1
    old_port_auto="$(nmcli -g connection.autoconnect \
        connection show "$slave" 2>/dev/null)" || return 1
    old_auto_ports="$(nmcli -g connection.autoconnect-slaves \
        connection show "$bridge_name" 2>/dev/null)" || return 1

    # 先允许 late-carrier port 自启动，再关闭 controller 的批量拉起行为；属性
    # 修改不会 down 当前连接，也不会拆除正在使用的 QEMU TAP。
    nmcli connection modify "$slave" connection.autoconnect yes || return 1
    if nmcli connection modify "$bridge_name" \
        connection.autoconnect yes connection.autoconnect-slaves 0 \
        && setup_nm_profiles_match_boot_contract "$bridge_name" "$uplink"; then
        return 0
    fi

    # profile 写入或复核失败时恢复精确旧值；只改持久属性，不触碰 active bridge。
    nmcli connection modify "$bridge_name" \
        connection.autoconnect "$old_bridge_auto" \
        connection.autoconnect-slaves "$old_auto_ports" >/dev/null 2>&1 || true
    nmcli connection modify "$slave" \
        connection.autoconnect "$old_port_auto" >/dev/null 2>&1 || true
    return 1
}

setup_vlan_auto_is_fully_ready() {
    [[ "$VLAN_TRUNK" == "1" && "$VLAN_SETUP_AUTO" == "1" ]] || return 1
    setup_vlan_runtime_contract_matches \
        && setup_vlan_topology_is_ready \
        && setup_nm_boot_contract_is_ready "$BR" "$UPLINK"
}

setup_uplink_native_is_safe() {
    local uplink="$1"

    bridge vlan show dev "$uplink" 2>/dev/null | awk -v dev="$uplink" '
        NR > 1 {
            token = ($1 == dev && $2 ~ /^[0-9]+(-[0-9]+)?$/) ? $2 : $1
            for (i = 2; i <= NF; i++) {
                if (token != "1" && ($i == "PVID" || $i == "Egress" || $i == "Untagged"))
                    bad = 1
            }
        }
        END { exit(bad ? 1 : 0) }
    '
}

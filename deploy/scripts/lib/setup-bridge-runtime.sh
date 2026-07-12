#!/bin/bash
# ---------------------------------------------------------------------------
# setup-bridge.sh 的 bridge VLAN 运行态只读校验
#
# 单独拆出文本解析，避免宿主安装主流程超过单文件上限。函数只读取 bridge VLAN
# 表，不写接口；调用方确认安全后才设置 VID 1 native/PVID。
# ---------------------------------------------------------------------------

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

# 所有用户输入必须在 root 检查、flock、文件安装和网络修改之前完成校验。这样旧
# 参数或拼写错误只返回退出码 2，不会留下半套宿主配置。
setup_validate_inputs() {
    if [[ -v VLAN_ID || -v VLAN_IF ]]; then
        setup_error "VLAN_ID/VLAN_IF 已废弃；请改用 VLAN_TRUNK=1，并在启动 VM 时传 --vlan-id=N。"
        return 2
    fi

    VLAN_TRUNK="${VLAN_TRUNK:-0}"
    VLAN_SETUP_AUTO="${VLAN_SETUP_AUTO:-0}"
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
        [[ -n "$UPLINK" ]] || {
            setup_error "VLAN_TRUNK=1 必须提供 UPLINK=<物理网卡>。"
            return 2
        }
    fi
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

setup_vlan_auto_is_fully_ready() {
    [[ "$VLAN_TRUNK" == "1" && "$VLAN_SETUP_AUTO" == "1" ]] || return 1
    setup_vlan_runtime_contract_matches && setup_vlan_topology_is_ready
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

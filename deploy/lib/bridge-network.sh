#!/usr/bin/env bash
# Read-only G-11 bridge/uplink health gate used before QEMU creates a TAP.

g11_bridge_ifname_is_safe() {
    local name="${1:-}"

    [[ -n "$name" && ${#name} -le 15 ]] || return 1
    [[ "$name" =~ ^[[:alnum:]_][[:alnum:]_.-]*$ ]] || return 1
    [[ "$name" != "." && "$name" != ".." ]]
}

g11_bridge_path_is_trusted() {
    local path="$1" kind="$2" owner mode

    case "$kind" in
        file) [[ -f "$path" && ! -L "$path" ]] || return 1 ;;
        dir) [[ -d "$path" && ! -L "$path" ]] || return 1 ;;
        *) return 1 ;;
    esac
    owner="$(stat -c '%u' -- "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 1
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#022) == 0 ))
}

g11_bridge_load_facts() {
    local selected_bridge="$1" config="$2"
    local config_dir line key value bridge="" uplink="" mode="" mac=""
    local -A seen=()

    [[ -e "$config" || -L "$config" ]] || return 2
    config_dir="$(dirname -- "$config")" || return 1
    g11_bridge_path_is_trusted "$config_dir" dir || return 1
    g11_bridge_path_is_trusted "$config" file || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" =~ ^([A-Z_]+)=([^[:space:]]+)$ ]] || return 1
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        [[ -z "${seen[$key]:-}" ]] || return 1
        seen[$key]=1
        case "$key" in
            VERSION) [[ "$value" == 1 ]] || return 1 ;;
            BRIDGE) bridge="$value" ;;
            UPLINK) uplink="$value" ;;
            MODE) mode="$value" ;;
            UPLINK_MAC) mac="${value,,}" ;;
            *) return 1 ;;
        esac
    done <"$config"
    [[ "${seen[VERSION]:-}" == 1 && "${seen[BRIDGE]:-}" == 1 \
        && "${seen[UPLINK]:-}" == 1 && "${seen[MODE]:-}" == 1 \
        && "${seen[UPLINK_MAC]:-}" == 1 ]] || return 1
    g11_bridge_ifname_is_safe "$bridge" || return 1
    g11_bridge_ifname_is_safe "$uplink" || return 1
    [[ "$bridge" == "$selected_bridge" \
        && ( "$mode" == access || "$mode" == vlan-aware ) \
        && "$uplink" != "$bridge" && "$uplink" != lo \
        && "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || return 1
    printf '%s %s\n' "$uplink" "$mode"
}

g11_bridge_physical_candidate() {
    local candidate="$1" bridge_name="$2" sys_class_net="$3"
    local type details

    g11_bridge_ifname_is_safe "$candidate" || return 1
    [[ "$candidate" != lo && "$candidate" != "$bridge_name" \
        && "$candidate" != tap* && "$candidate" != vnet* \
        && "$candidate" != g11t* && "$candidate" != svtap* ]] || return 1
    [[ -e "$sys_class_net/$candidate/device" \
        && ! -d "$sys_class_net/$candidate/wireless" ]] || return 1
    IFS= read -r type <"$sys_class_net/$candidate/type" || return 1
    [[ "$type" == 1 ]] || return 1
    details="$(ip -d -o link show dev "$candidate" 2>/dev/null)" || return 1
    [[ " $details " == *" master $bridge_name "* ]]
}

g11_bridge_detect_uplink() {
    local bridge_name="$1" sys_class_net="$2" line candidate
    local -a candidates=()

    while IFS= read -r line; do
        candidate="${line#*: }"
        candidate="${candidate%%:*}"
        candidate="${candidate%%@*}"
        if g11_bridge_physical_candidate \
            "$candidate" "$bridge_name" "$sys_class_net"; then
            candidates+=("$candidate")
        fi
    done < <(ip -o link show master "$bridge_name" 2>/dev/null || true)
    (( ${#candidates[@]} == 1 )) || return 1
    printf '%s\n' "${candidates[0]}"
}

g11_bridge_link_has_flag() {
    local details="$1" expected="$2" flags

    [[ "$details" == *"<"*">"* ]] || return 1
    flags="${details#*<}"
    flags="${flags%%>*}"
    [[ ",$flags," == *",$expected,"* ]]
}

g11_bridge_preflight_error() {
    printf '[start-vm] bridge 网络预检失败: %s\n' "$*" >&2
    printf '[start-vm] VM 未启动；一键修复: ./deploy/scripts/setup-bridge.sh\n' >&2
}

g11_bridge_helper_is_ready() {
    local helper="$1" mode capabilities

    g11_bridge_path_is_trusted "$(dirname -- "$helper")" dir || return 1
    g11_bridge_path_is_trusted "$helper" file || return 1
    [[ -x "$helper" ]] || return 1
    mode="$(stat -c '%a' -- "$helper" 2>/dev/null)" || return 1
    (( (8#$mode & 8#0777) == 8#0750 )) || return 1
    if (( (8#$mode & 8#4000) != 0 )); then
        (( (8#$mode & 8#7000) == 8#4000 ))
        return
    fi
    command -v getcap >/dev/null 2>&1 || return 1
    capabilities="$(getcap -- "$helper" 2>/dev/null)" || return 1
    [[ "${capabilities#* }" == cap_net_admin=ep ]]
}

g11_bridge_acl_is_ready() {
    local bridge_name="$1" acl="$2" line rule="" count=0

    g11_bridge_path_is_trusted "$(dirname -- "$acl")" dir || return 1
    g11_bridge_path_is_trusted "$acl" file || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        rule=$line
        ((count += 1))
    done <"$acl"
    [[ "$count" == 1 && "$rule" == "allow $bridge_name" ]]
}

g11_network_maintenance_lock_shared() {
    local lock="${1:-/run/qemu-g11-network.lock}" before after

    g11_bridge_path_is_trusted "$(dirname -- "$lock")" dir || return 1
    g11_bridge_path_is_trusted "$lock" file || {
        g11_bridge_preflight_error "宿主网络维护锁尚未初始化: $lock"
        return 1
    }
    before="$(stat -c '%d:%i' -- "$lock")" || return 1
    exec {G11_NETWORK_LOCK_FD}<"$lock" || return 1
    after="$(stat -Lc '%d:%i' -- "/proc/self/fd/$G11_NETWORK_LOCK_FD")" || return 1
    [[ "$before" == "$after" ]] || {
        g11_bridge_preflight_error "宿主网络维护锁在打开时被替换"
        return 1
    }
    flock -s "$G11_NETWORK_LOCK_FD"
}

g11_bridge_uplink_preflight() {
    local bridge_name="$1"
    local config="${2:-/etc/qemu/g11-bridge.conf}"
    local sys_class_net="${3:-/sys/class/net}"
    local helper="${4:-/usr/local/libexec/qemu-g11-bridge-helper}"
    local acl="${5:-${G11_BRIDGE_ACL:-/etc/qemu/bridge.conf}}"
    local check_mode="${BRIDGE_UPLINK_CHECK:-required}"
    local uplink facts facts_rc contract_mode=access
    local bridge_details uplink_details type carrier

    g11_bridge_ifname_is_safe "$bridge_name" || {
        g11_bridge_preflight_error "bridge 名称不安全: '$bridge_name'"
        return 1
    }
    g11_network_maintenance_lock_shared \
        "${G11_NETWORK_LOCK:-/run/qemu-g11-network.lock}" || {
        g11_bridge_preflight_error "无法取得宿主网络维护共享锁"
        return 1
    }
    g11_bridge_helper_is_ready "$helper" || {
        g11_bridge_preflight_error "固定 bridge helper 缺失、权限不安全或没有 cap_net_admin: $helper"
        return 1
    }
    g11_bridge_acl_is_ready "$bridge_name" "$acl" || {
        g11_bridge_preflight_error "bridge helper ACL 不可信或不是精确的 'allow $bridge_name': $acl"
        return 1
    }
    case "$check_mode" in
        required) ;;
        off)
            printf '[start-vm] WARN: BRIDGE_UPLINK_CHECK=off，跳过物理上联检查（仅适合明确的隔离 bridge）。\n' >&2
            return 0
            ;;
        *)
            g11_bridge_preflight_error "BRIDGE_UPLINK_CHECK 必须是 required 或 off"
            return 2
            ;;
    esac

    facts_rc=0
    facts="$(g11_bridge_load_facts "$bridge_name" "$config")" || facts_rc=$?
    case "$facts_rc" in
        0)
            read -r uplink contract_mode <<<"$facts"
            ;;
        2)
            uplink="$(g11_bridge_detect_uplink "$bridge_name" "$sys_class_net")" || {
                g11_bridge_preflight_error "'$bridge_name' 没有唯一可验证的物理上联"
                return 1
            }
            ;;
        *)
            g11_bridge_preflight_error "bridge 契约不可信或格式损坏: $config"
            return 1
            ;;
    esac

    bridge_details="$(ip -d -o link show dev "$bridge_name" 2>/dev/null)" || {
        g11_bridge_preflight_error "bridge '$bridge_name' 不存在"
        return 1
    }
    [[ "$bridge_details" =~ [[:space:]]bridge[[:space:]]+forward_delay[[:space:]] ]] || {
        g11_bridge_preflight_error "'$bridge_name' 不是 Linux bridge"
        return 1
    }
    g11_bridge_link_has_flag "$bridge_details" UP || {
        g11_bridge_preflight_error "bridge '$bridge_name' 未处于 UP 状态"
        return 1
    }
    g11_bridge_link_has_flag "$bridge_details" LOWER_UP || {
        g11_bridge_preflight_error "bridge '$bridge_name' 没有 LOWER_UP/carrier"
        return 1
    }

    [[ -e "$sys_class_net/$uplink/device" \
        && ! -d "$sys_class_net/$uplink/wireless" ]] || {
        g11_bridge_preflight_error "上联 '$uplink' 不是有线物理设备"
        return 1
    }
    IFS= read -r type <"$sys_class_net/$uplink/type" || type=""
    [[ "$type" == 1 ]] || {
        g11_bridge_preflight_error "上联 '$uplink' 不是 Ethernet"
        return 1
    }
    uplink_details="$(ip -d -o link show dev "$uplink" 2>/dev/null)" || {
        g11_bridge_preflight_error "上联 '$uplink' 不存在"
        return 1
    }
    [[ " $uplink_details " == *" master $bridge_name "* ]] || {
        g11_bridge_preflight_error "上联 '$uplink' 未加入 '$bridge_name'"
        return 1
    }
    g11_bridge_link_has_flag "$uplink_details" UP || {
        g11_bridge_preflight_error "上联 '$uplink' 未处于 UP 状态"
        return 1
    }
    g11_bridge_link_has_flag "$uplink_details" LOWER_UP || {
        g11_bridge_preflight_error "上联 '$uplink' 没有 LOWER_UP"
        return 1
    }
    IFS= read -r carrier <"$sys_class_net/$uplink/carrier" || carrier=""
    [[ "$carrier" == 1 ]] || {
        g11_bridge_preflight_error "上联 '$uplink' carrier 不可用"
        return 1
    }
    if [[ "$contract_mode" == vlan-aware ]]; then
        [[ "$bridge_details" =~ [[:space:]]vlan_filtering[[:space:]]+1([[:space:]]|$) ]] || {
            g11_bridge_preflight_error "bridge '$bridge_name' 的 vlan_filtering 未启用"
            return 1
        }
        bridge vlan show dev "$uplink" 2>/dev/null \
            | grep -Eq '(^|[[:space:]])1[[:space:]].*PVID.*Untagged' || {
                g11_bridge_preflight_error "上联 '$uplink' 缺少 native VID 1"
                return 1
            }
    fi
    printf '[start-vm] bridge 网络预检通过: %s -> %s\n' \
        "$uplink" "$bridge_name"
}

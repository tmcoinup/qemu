#!/usr/bin/env bash
# G-11 bridge setup shared checks.
#
# This is the G-11 adaptation of V-11's setup runtime.  It intentionally keeps
# discovery and verification read-only; only setup-bridge.sh's explicit
# `apply` action may mutate the host network.

_G11_SETUP_RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=uplink-detect.sh
source "$_G11_SETUP_RUNTIME_DIR/uplink-detect.sh"
unset _G11_SETUP_RUNTIME_DIR

SETUP_SYS_CLASS_NET="${SETUP_SYS_CLASS_NET:-/sys/class/net}"

setup_error() {
    printf 'ERROR: %s\n' "$*" >&2
}

setup_warn() {
    printf 'WARN: %s\n' "$*" >&2
}

setup_ifname_is_safe() {
    local name="${1:-}"

    [[ -n "$name" && ${#name} -le 15 ]] || return 1
    [[ "$name" =~ ^[[:alnum:]_][[:alnum:]_.-]*$ ]] || return 1
    [[ "$name" != "." && "$name" != ".." ]]
}

setup_link_has_flag() {
    local details="$1" expected="$2" flags

    [[ "$details" == *"<"*">"* ]] || return 1
    flags="${details#*<}"
    flags="${flags%%>*}"
    [[ ",$flags," == *",$expected,"* ]]
}

setup_candidate_is_physical() {
    local candidate="$1" bridge_name="${2:-br0}" details link_type

    setup_ifname_is_safe "$candidate" || return 1
    [[ "$candidate" != lo && "$candidate" != "$bridge_name" ]] || return 1
    [[ "$candidate" != tap* && "$candidate" != vnet* \
        && "$candidate" != g11t* && "$candidate" != svtap* ]] || return 1
    [[ -e "$SETUP_SYS_CLASS_NET/$candidate/device" \
        && ! -d "$SETUP_SYS_CLASS_NET/$candidate/wireless" ]] || return 1
    IFS= read -r link_type <"$SETUP_SYS_CLASS_NET/$candidate/type" || return 1
    [[ "$link_type" == 1 ]] || return 1
    details="$(ip -d -o link show dev "$candidate" 2>/dev/null)" || return 1
    [[ ! "$details" =~ [[:space:]]vlan[[:space:]]+protocol[[:space:]] \
        && ! "$details" =~ [[:space:]]macvlan[[:space:]] \
        && ! "$details" =~ [[:space:]]macvtap[[:space:]] ]] || return 1
    if [[ "$details" =~ [[:space:]]master[[:space:]]+([^[:space:]]+) \
        && "${BASH_REMATCH[1]}" != "$bridge_name" ]]; then
        return 1
    fi
}

setup_resolve_uplink() {
    local requested="${1:-}" bridge_name="${2:-br0}" detected

    if [[ -n "$requested" ]]; then
        setup_candidate_is_physical "$requested" "$bridge_name" || {
            setup_error "上联 '$requested' 不是可安全接管的有线物理接口。"
            return 1
        }
        printf '%s\n' "$requested"
        return 0
    fi
    if ! detected="$(uplink_detect_from_topology \
        setup_candidate_is_physical "$bridge_name" "$SETUP_SYS_CLASS_NET")"; then
        setup_error "无法唯一识别物理上联；请显式指定 --uplink <接口>。"
        return 1
    fi
    printf '%s\n' "$detected"
}

setup_bridge_details() {
    local bridge_name="$1" details

    details="$(ip -d -o link show dev "$bridge_name" 2>/dev/null)" || return 1
    [[ "$details" =~ [[:space:]]bridge[[:space:]]+forward_delay[[:space:]] ]] \
        || return 1
    printf '%s\n' "$details"
}

setup_bridge_verify_l2() {
    local bridge_name="$1" uplink="$2"
    local bridge_details uplink_details carrier

    if ! bridge_details="$(setup_bridge_details "$bridge_name")"; then
        setup_error "'$bridge_name' 不存在或不是 Linux bridge。"
        return 1
    fi
    setup_link_has_flag "$bridge_details" UP || {
        setup_error "bridge '$bridge_name' 未处于 UP 状态。"
        return 1
    }
    setup_link_has_flag "$bridge_details" LOWER_UP || {
        setup_error "bridge '$bridge_name' 没有 LOWER_UP/carrier。"
        return 1
    }
    setup_candidate_is_physical "$uplink" "$bridge_name" || {
        setup_error "'$uplink' 不是可验证的有线物理上联。"
        return 1
    }
    uplink_details="$(ip -d -o link show dev "$uplink" 2>/dev/null)" || {
        setup_error "上联 '$uplink' 不存在。"
        return 1
    }
    [[ " $uplink_details " == *" master $bridge_name "* ]] || {
        setup_error "上联 '$uplink' 没有加入 '$bridge_name'。"
        return 1
    }
    setup_link_has_flag "$uplink_details" UP || {
        setup_error "上联 '$uplink' 未处于 UP 状态。"
        return 1
    }
    setup_link_has_flag "$uplink_details" LOWER_UP || {
        setup_error "上联 '$uplink' 没有 LOWER_UP。"
        return 1
    }
    IFS= read -r carrier <"$SETUP_SYS_CLASS_NET/$uplink/carrier" || carrier=""
    [[ "$carrier" == 1 ]] || {
        setup_error "上联 '$uplink' 没有物理 carrier。"
        return 1
    }
}

setup_bridge_verify_host_l3() {
    local bridge_name="$1" uplink="$2" gateway="${3:-}"

    setup_bridge_verify_l2 "$bridge_name" "$uplink" || return 1
    ip -4 -o address show dev "$bridge_name" scope global 2>/dev/null \
        | grep -q . || {
            setup_error "宿主 IPv4 尚未迁移到 '$bridge_name'。"
            return 1
        }
    if ip -4 -o address show dev "$uplink" scope global 2>/dev/null \
        | grep -q .; then
        setup_error "物理口 '$uplink' 仍持有 IPv4；L3 应只在 '$bridge_name'。"
        return 1
    fi
    ip -4 route show default 2>/dev/null \
        | awk -v dev="$bridge_name" '
            { for (i=1; i<NF; i++) if ($i=="dev" && $(i+1)==dev) found=1 }
            END { exit(found ? 0 : 1) }
        ' || {
            setup_error "默认 IPv4 路由尚未迁移到 '$bridge_name'。"
            return 1
        }
    if [[ -n "$gateway" ]] && command -v ping >/dev/null 2>&1; then
        ping -n -c 1 -W 2 -I "$bridge_name" "$gateway" >/dev/null 2>&1 || {
            setup_error "无法通过 '$bridge_name' 到达迁移前网关 '$gateway'。"
            return 1
        }
    fi
}

setup_uplink_mac() {
    local uplink="$1" mac

    IFS= read -r mac <"$SETUP_SYS_CLASS_NET/$uplink/address" || return 1
    mac="${mac,,}"
    [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ \
        && "$mac" != 00:00:00:00:00:00 ]] || return 1
    printf '%s\n' "$mac"
}

setup_uplink_gateway() {
    local uplink="$1"

    ip -4 route show default dev "$uplink" 2>/dev/null \
        | awk '{ for (i=1; i<NF; i++) if ($i=="via") { print $(i+1); exit } }'
}

setup_uplink_ipv4_method() {
    setup_device_ip_method "$1" ipv4
}

setup_device_ip_method() {
    local interface="$1" family="$2" connection

    command -v nmcli >/dev/null 2>&1 || return 1
    [[ "$family" == ipv4 || "$family" == ipv6 ]] || return 1
    connection="$(nmcli -g GENERAL.CONNECTION device show "$interface" 2>/dev/null \
        | head -n 1)" || return 1
    [[ -n "$connection" && "$connection" != -- ]] || return 1
    nmcli -g "$family.method" connection show "$connection" 2>/dev/null \
        | head -n 1
}

# The generated G-11 Netplan intentionally represents one narrow, predictable
# contract: DHCPv4 on the current L3 owner and no managed IPv6.  Refuse to
# silently translate static addressing, policy routing, DNS, or dual-stack
# state into that contract.  This helper is read-only so auto mode can run it
# before asking the operator to stop any VM.
setup_validate_supported_ip_contract() {
    local bridge_name="$1" uplink="$2" owner ipv4_method ipv6_method

    owner=$uplink
    if setup_bridge_verify_host_l3 "$bridge_name" "$uplink" "" \
            >/dev/null 2>&1; then
        owner=$bridge_name
    fi
    ipv4_method="$(setup_device_ip_method "$owner" ipv4 || true)"
    ipv6_method="$(setup_device_ip_method "$owner" ipv6 || true)"
    [[ "$ipv4_method" == auto ]] || {
        setup_error "只支持无损迁移 DHCPv4；'$owner' IPv4 method=${ipv4_method:-unknown}。"
        setup_error "静态地址/路由/DNS 必须显式迁移，不能由一键封装猜测。"
        return 1
    }
    [[ "$ipv6_method" == ignore || "$ipv6_method" == disabled ]] || {
        setup_error "'$owner' IPv6 method=${ipv6_method:-unknown}；一键封装拒绝覆盖双栈配置。"
        return 1
    }
}

# Build an exact offline copy of Netplan's three input trees.  A symlinked
# directory or YAML file is rejected instead of silently omitted: otherwise
# `netplan generate --root-dir` would validate a different aggregate from the
# one that the real host applies.  source_root is only an explicit test hook;
# production callers leave it empty and therefore inspect /lib, /etc and /run.
setup_copy_netplan_sources() {
    local root="$1" source_root="${2:-}" config source_dir source_path

    install -d -m 0700 \
        "$root/lib/netplan" "$root/etc/netplan" "$root/run/netplan"
    for source_dir in /lib/netplan /etc/netplan /run/netplan; do
        source_path="$source_root$source_dir"
        if [[ ! -e "$source_path" && ! -L "$source_path" ]]; then
            continue
        fi
        [[ -d "$source_path" && ! -L "$source_path" ]] || {
            setup_error "Netplan 输入目录类型不安全: $source_path"
            return 1
        }
        for config in "$source_path"/*.yaml "$source_path"/*.yml; do
            if [[ ! -e "$config" && ! -L "$config" ]]; then
                continue
            fi
            [[ -f "$config" && ! -L "$config" ]] || {
                setup_error "Netplan YAML 必须是非符号链接普通文件: $config"
                return 1
            }
            install -m 0600 "$config" "$root$source_dir/${config##*/}"
        done
    done
}

setup_networkmanager_is_active() {
    command -v nmcli >/dev/null 2>&1 || return 1
    nmcli -t -f RUNNING general 2>/dev/null | grep -Fqx running
}

setup_print_active_qemu() {
    local proc pid exe cmdline name

    for proc in /proc/[0-9]*/exe; do
        [[ -r "$proc" || -L "$proc" ]] || continue
        pid="${proc#/proc/}"
        pid="${pid%/exe}"
        exe="$(readlink -f -- "$proc" 2>/dev/null || true)"
        [[ "${exe##*/}" == qemu-system-* ]] || continue
        cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
        name="$(sed -n 's/.*-name[[:space:]]\+\([^,[:space:]]\+\).*/\1/p' \
            <<<"$cmdline")"
        printf '%s:%s\n' "$pid" "${name:-qemu}"
    done
}

setup_network_is_busy() {
    local active tap path vlan_state_dir=/run/qemu-g11-vlan

    active="$(setup_print_active_qemu)"
    if [[ -n "$active" ]]; then
        setup_error "仍有 QEMU 正在运行，拒绝迁移宿主网络：${active//$'\n'/, }"
        return 0
    fi
    for path in "$SETUP_SYS_CLASS_NET"/tap[0-9]* \
        "$SETUP_SYS_CLASS_NET"/vnet[0-9]* \
        "$SETUP_SYS_CLASS_NET"/g11t[0-9]* \
        "$SETUP_SYS_CLASS_NET"/svtap[0-9]*; do
        [[ -e "$path" || -L "$path" ]] || continue
        tap="${path##*/}"
        setup_error "仍有 guest TAP '$tap'，拒绝迁移宿主网络。"
        return 0
    done
    if [[ -e "$vlan_state_dir" || -L "$vlan_state_dir" ]]; then
        [[ -d "$vlan_state_dir" && ! -L "$vlan_state_dir" ]] || {
            setup_error "VLAN runtime 状态目录类型异常，拒绝迁移宿主网络。"
            return 0
        }
        for path in "$vlan_state_dir"/* \
                "$vlan_state_dir"/.[!.]* "$vlan_state_dir"/..?*; do
            [[ -e "$path" || -L "$path" ]] || continue
            setup_error "仍有 VLAN intent state/runtime '${path##*/}'，拒绝迁移宿主网络。"
            return 0
        done
    fi
    return 1
}

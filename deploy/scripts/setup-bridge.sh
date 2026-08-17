#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# G-11 host bridge setup
#
# Adapted from origin/V-11's deploy/scripts/setup-bridge.sh, with three G-11
# safety changes:
#   * no-argument use is the one-click VLAN-aware path requested for G-11;
#   * Netplan remains the single persistent source of truth on Ubuntu hosts;
#   * an out-of-process root watchdog restores the previous managed override
#     unless the operator explicitly confirms the new network.
#
# Access-mode quick path:
#   ./deploy/scripts/setup-bridge.sh plan --uplink enp7s0
#   sudo ./deploy/scripts/setup-bridge.sh apply --uplink enp7s0
#   ./deploy/scripts/setup-bridge.sh verify --uplink enp7s0
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/setup-bridge-runtime.sh
source "$HERE/lib/setup-bridge-runtime.sh"
# shellcheck source=lib/vlan-network.sh
source "$HERE/lib/vlan-network.sh"

readonly MANAGED_NETPLAN_EARLY=/etc/netplan/00-qemu-g11-uplink.yaml
readonly MANAGED_NETPLAN=/etc/netplan/99-qemu-g11-br0.yaml
readonly BRIDGE_FACTS=/etc/qemu/g11-bridge.conf
readonly VLAN_CONFIG=/etc/qemu/g11-vlan.conf
readonly VLAN_TAP_SOURCE="$HERE/host-vlan-tap.sh"
readonly VLAN_DOWN_SOURCE="$HERE/host-vlan-down.sh"
readonly VLAN_BRIDGE_SOURCE="$HERE/host-vlan-bridge.sh"
readonly VLAN_DISPATCHER_SOURCE="$HERE/host-vlan-dispatcher.sh"
readonly VLAN_SERVICE_SOURCE="$HERE/qemu-g11-vlan-bridge.service"
readonly VLAN_TAP_INSTALLED=/usr/local/libexec/qemu-g11-vlan-tap
readonly VLAN_DOWN_INSTALLED=/usr/local/libexec/qemu-g11-vlan-down
readonly VLAN_BRIDGE_INSTALLED=/usr/local/libexec/qemu-g11-vlan-bridge
readonly VLAN_DISPATCHER_INSTALLED=/etc/NetworkManager/dispatcher.d/90-qemu-g11-vlan-bridge
readonly VLAN_SERVICE_INSTALLED=/etc/systemd/system/qemu-g11-vlan-bridge.service
readonly VLAN_SUDOERS=/etc/sudoers.d/qemu-g11-vlan
readonly BRIDGE_HELPER_INSTALLED=/usr/local/libexec/qemu-g11-bridge-helper
readonly ROLLBACK_SOURCE="$HERE/host-bridge-rollback.sh"
readonly ROLLBACK_INSTALLED=/usr/local/libexec/qemu-g11-bridge-rollback
readonly STATE_ROOT=/var/lib/qemu-g11-network
readonly NETWORK_LOCK=/run/qemu-g11-network.lock
readonly NETWORK_TMPFILES_CONFIG=/etc/tmpfiles.d/qemu-g11-network.conf
readonly NETPLAN_GENERATOR=/usr/libexec/netplan/generate
readonly AUTO_VERIFY_REPAIR_RC=42

ACTION=auto
ACTION_SET=0
BRIDGE="${BR:-${BR0:-br0}}"
UPLINK_REQUESTED="${UPLINK:-}"
MODE="${G11_NETWORK_MODE:-}"
ALLOWED_VLANS="${G11_ALLOWED_VLANS:-}"
ALLOWED_VLANS_EXPLICIT=0
[[ -z "${G11_ALLOWED_VLANS:-}" ]] || ALLOWED_VLANS_EXPLICIT=1
CONFIRM_TIMEOUT="${G11_NETWORK_CONFIRM_TIMEOUT:-120}"
TRANSACTION_ARMED=0
TRANSACTION_ID=""
TRANSACTION_UNIT=""
ROLLBACK_COMMIT_LOCK_HELD=0
NETWORK_MAINTENANCE_LOCK_HELD=0

usage() {
    cat <<'EOF'
usage: deploy/scripts/setup-bridge.sh [inspect|plan|apply|verify] [options]

  no arguments            one-click: self-sudo, auto-detect uplink, create a
                          VLAN-aware br0, native VID 1 and all-VID allowlist
  inspect                 read-only summary
  plan                    print the candidate Netplan override; no writes
  apply                   guarded host migration; root + local TTY required
  verify                  read-only L2/L3/installed-contract verification;
                          self-sudo only to inspect root-readable files

  --uplink IFACE          physical wired uplink (auto-detect only if unique)
  --bridge BRIDGE         bridge name (default br0)
  --mode access           ordinary untagged LAN bridge
  --mode vlan-aware       single br0 + dynamic access TAP (default)
  --allowed-vlans LIST    allowed guest VLANs (default 1-4094), e.g. 11,20,30-39
  --timeout SECONDS       rollback confirmation timeout, 30..600 (default 120)
  -h, --help              show this help

Compatibility environment variables: BR/BR0, UPLINK, VLAN_TRUNK=0|1,
G11_ALLOWED_VLANS and G11_NETWORK_CONFIRM_TIMEOUT.  No password is read from
the repository or command line; invoke apply through sudo's normal channel.
EOF
}

set_action() {
    (( ACTION_SET == 0 )) || {
        setup_error "只能指定一个动作。"
        exit 2
    }
    ACTION=$1
    ACTION_SET=1
}

while (($#)); do
    case "$1" in
        auto|inspect|plan|apply|verify|verify-auto-ready)
            set_action "$1"
            shift
            ;;
        --uplink)
            (($# >= 2)) || { setup_error "--uplink 需要一个参数。"; exit 2; }
            UPLINK_REQUESTED=$2
            shift 2
            ;;
        --uplink=*)
            UPLINK_REQUESTED=${1#*=}
            shift
            ;;
        --bridge)
            (($# >= 2)) || { setup_error "--bridge 需要一个参数。"; exit 2; }
            BRIDGE=$2
            shift 2
            ;;
        --bridge=*)
            BRIDGE=${1#*=}
            shift
            ;;
        --mode)
            (($# >= 2)) || { setup_error "--mode 需要一个参数。"; exit 2; }
            MODE=$2
            shift 2
            ;;
        --mode=*)
            MODE=${1#*=}
            shift
            ;;
        --allowed-vlans)
            (($# >= 2)) || { setup_error "--allowed-vlans 需要一个参数。"; exit 2; }
            ALLOWED_VLANS=$2
            ALLOWED_VLANS_EXPLICIT=1
            shift 2
            ;;
        --allowed-vlans=*)
            ALLOWED_VLANS=${1#*=}
            ALLOWED_VLANS_EXPLICIT=1
            shift
            ;;
        --timeout)
            (($# >= 2)) || { setup_error "--timeout 需要一个参数。"; exit 2; }
            CONFIRM_TIMEOUT=$2
            shift 2
            ;;
        --timeout=*)
            CONFIRM_TIMEOUT=${1#*=}
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            setup_error "未知参数: $1"
            usage >&2
            exit 2
            ;;
    esac
done

read_existing_vlan_contract() {
    local line key value owner mode config_dir dir_owner dir_mode
    local version="" bridge="" uplink="" uid="" gid="" allowlist=""
    local -A seen=()

    config_dir="${VLAN_CONFIG%/*}"
    [[ -d "$config_dir" && ! -L "$config_dir" ]] || return 1
    dir_owner="$(stat -c '%u' -- "$config_dir" 2>/dev/null)" || return 1
    dir_mode="$(stat -c '%a' -- "$config_dir" 2>/dev/null)" || return 1
    [[ "$dir_owner" == 0 && "$dir_mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$dir_mode & 8#022) == 0 )) || return 1
    [[ -f "$VLAN_CONFIG" && ! -L "$VLAN_CONFIG" ]] || return 1
    owner="$(stat -c '%u' -- "$VLAN_CONFIG" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$VLAN_CONFIG" 2>/dev/null)" || return 1
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#022) == 0 )) || return 1
    [[ "$(stat -c '%s' -- "$VLAN_CONFIG")" -le 8192 ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" =~ ^([A-Z_]+)=([^[:space:]]+)$ ]] || return 1
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        [[ -z "${seen[$key]:-}" ]] || return 1
        seen[$key]=1
        case "$key" in
            VERSION) version=$value ;;
            BRIDGE) bridge=$value ;;
            UPLINK) uplink=$value ;;
            ALLOWED_UID) uid=$value ;;
            ALLOWED_GID) gid=$value ;;
            ALLOWED_VLANS) allowlist=$value ;;
            *) return 1 ;;
        esac
    done <"$VLAN_CONFIG"
    [[ "$version" == 1 && "$bridge" == br0 ]] || return 1
    setup_ifname_is_safe "$uplink" || return 1
    [[ "$uplink" != br0 && "$uplink" != lo \
        && "$uplink" != tap* && "$uplink" != vnet* \
        && "$uplink" != g11t* && "$uplink" != svtap* ]] || return 1
    [[ "$uid" =~ ^(0|[1-9][0-9]{0,9})$ \
        && "$gid" =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 1
    (( 10#$uid <= 2147483647 && 10#$gid <= 2147483647 )) || return 1
    vlan_validate_allowlist "$allowlist" || return 1
    printf '%s %s %s %s\n' "$allowlist" "$uid" "$gid" "$uplink"
}

EXISTING_VLAN_CONFIG=0
EXISTING_ALLOWED_VLANS=""
EXISTING_ALLOWED_UID=""
EXISTING_ALLOWED_GID=""
EXISTING_VLAN_UPLINK=""
if [[ -e "$VLAN_CONFIG" || -L "$VLAN_CONFIG" ]]; then
    if ! read -r EXISTING_ALLOWED_VLANS EXISTING_ALLOWED_UID \
            EXISTING_ALLOWED_GID EXISTING_VLAN_UPLINK \
            < <(read_existing_vlan_contract); then
        setup_error "已有 $VLAN_CONFIG 不可信或格式损坏；拒绝静默放宽/覆盖 VLAN 授权。"
        exit 1
    fi
    EXISTING_VLAN_CONFIG=1
fi

read_existing_vlan_allowlist() {
    (( EXISTING_VLAN_CONFIG == 1 )) || return 1
    printf '%s\n' "$EXISTING_ALLOWED_VLANS"
}

if [[ -z "$MODE" ]]; then
    case "${VLAN_TRUNK:-1}" in
        0) MODE=access ;;
        1) MODE=vlan-aware ;;
        *) setup_error "VLAN_TRUNK 必须是 0 或 1。"; exit 2 ;;
    esac
fi

setup_ifname_is_safe "$BRIDGE" || {
    setup_error "bridge 名称不安全: '$BRIDGE'"
    exit 2
}
[[ "$CONFIRM_TIMEOUT" =~ ^[0-9]+$ \
    && "$CONFIRM_TIMEOUT" -ge 30 \
    && "$CONFIRM_TIMEOUT" -le 600 ]] || {
    setup_error "--timeout 必须是 30..600 秒。"
    exit 2
}
case "$MODE" in
    access) ;;
    vlan-aware)
        if (( ALLOWED_VLANS_EXPLICIT == 1 )); then
            [[ -n "$ALLOWED_VLANS" ]] || {
                setup_error "--allowed-vlans 不能是空值。"
                exit 2
            }
        elif [[ -z "$ALLOWED_VLANS" ]]; then
            ALLOWED_VLANS="$(read_existing_vlan_allowlist 2>/dev/null || true)"
            : "${ALLOWED_VLANS:=1-4094}"
        fi
        vlan_validate_allowlist "$ALLOWED_VLANS" || {
            setup_error "--allowed-vlans 必须是合法 VID/范围，如 11,20,30-39。"
            exit 2
        }
        [[ "$BRIDGE" == br0 ]] || {
            setup_error "vlan-aware 模式固定使用单 bridge br0。"
            exit 2
        }
        ;;
    *)
        setup_error "--mode 只接受 access 或 vlan-aware。"
        exit 2
        ;;
esac

render_netplan() {
    local bridge_name="$1" uplink="$2" mac="$3" mode="$4"

    cat <<EOF
# Managed by qemu G-11 deploy/scripts/setup-bridge.sh.
# User Netplan files are not edited; this late override moves host L3 to bridge.
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    $uplink:
      dhcp4: false
      dhcp6: false
  bridges:
    $bridge_name:
      interfaces:
        - $uplink
      macaddress: $mac
      dhcp4: true
      dhcp6: false
      parameters:
        stp: false
        forward-delay: 0
EOF
    if [[ "$mode" == vlan-aware ]]; then
        cat <<'EOF'
      networkmanager:
        passthrough:
          bridge.vlan-filtering: "true"
          bridge.vlan-default-pvid: "1"
EOF
    fi
}

render_netplan_early() {
    local uplink="$1"

    cat <<EOF
# Managed by qemu G-11.  This early declaration lets older split Netplan
# files reference the physical port before later cloud-init fragments load.
network:
  version: 2
  ethernets:
    $uplink: {}
EOF
}

render_bridge_facts() {
    local bridge_name="$1" uplink="$2" mac="$3" mode="$4"

    printf 'VERSION=1\nBRIDGE=%s\nUPLINK=%s\nMODE=%s\nUPLINK_MAC=%s\n' \
        "$bridge_name" "$uplink" "$mode" "$mac"
}

render_network_tmpfiles_config() {
    printf '# G-11 VM/network maintenance serialization.\n'
    printf 'f %s 0644 root root - -\n' "$NETWORK_LOCK"
}

resolve_inputs() {
    UPLINK_EFFECTIVE="$(setup_resolve_uplink "$UPLINK_REQUESTED" "$BRIDGE")"
    UPLINK_MAC="$(setup_uplink_mac "$UPLINK_EFFECTIVE")" || {
        setup_error "无法读取 '$UPLINK_EFFECTIVE' 的稳定 MAC。"
        return 1
    }
    UPLINK_GATEWAY="$(setup_uplink_gateway "$UPLINK_EFFECTIVE")"
}

inspect_host() {
    local active="" uplink="" bridge_state=missing uplink_state=unknown
    local status=needs-apply

    if setup_bridge_details "$BRIDGE" >/dev/null 2>&1; then
        bridge_state=present
    elif ip link show dev "$BRIDGE" >/dev/null 2>&1; then
        bridge_state=not-a-bridge
    fi
    if uplink="$(setup_resolve_uplink "$UPLINK_REQUESTED" "$BRIDGE" 2>/dev/null)"; then
        uplink_state=detected
    fi
    active="$(setup_print_active_qemu)"
    printf 'mode=%s\nbridge=%s (%s)\nuplink=%s (%s)\n' \
        "$MODE" "$BRIDGE" "$bridge_state" "${uplink:-<ambiguous>}" "$uplink_state"
    if [[ -n "$uplink" ]]; then
        ip -4 -o address show dev "$uplink" 2>/dev/null \
            | sed 's/^/uplink-ip: /' || true
    fi
    ip -4 -o address show dev "$BRIDGE" 2>/dev/null \
        | sed 's/^/bridge-ip: /' || true
    ip -4 route show default 2>/dev/null | sed 's/^/default-route: /' || true
    if [[ -n "$active" ]]; then
        printf 'active-qemu=%s\n' "${active//$'\n'/,}"
    else
        printf 'active-qemu=none\n'
    fi
    UPLINK_EFFECTIVE=${uplink:-}
    if [[ -n "$UPLINK_EFFECTIVE" ]]; then
        UPLINK_MAC="$(setup_uplink_mac "$UPLINK_EFFECTIVE" 2>/dev/null || true)"
    fi
    if [[ -n "$uplink" ]] \
        && setup_bridge_verify_host_l3 "$BRIDGE" "$uplink" "" >/dev/null 2>&1 \
        && setup_validate_supported_ip_contract "$BRIDGE" "$uplink" \
            >/dev/null 2>&1 \
        && verify_vlan_runtime >/dev/null 2>&1; then
        if (( EUID != 0 )) && [[ "$MODE" == vlan-aware ]]; then
            # The runtime can be inspected publicly, but the exact sudoers
            # rule is intentionally 0440.  Do not mislabel that permission
            # boundary as a broken installation; `verify` performs the
            # remaining checks read-only through sudo.
            status=privileged-verify-required
        elif resolve_allowed_identity >/dev/null 2>&1 \
            && vlan_runtime_assets_ready >/dev/null 2>&1 \
            && bridge_helper_ready >/dev/null 2>&1; then
            status=ready
        fi
    fi
    printf 'status=%s\n' "$status"
}

plan_host() {
    resolve_inputs
    printf '# action: plan (read-only)\n'
    printf '# mode: %s\n# targets: %s, %s\n# uplink: %s\n# preserved-mac: %s\n' \
        "$MODE" "$MANAGED_NETPLAN_EARLY" "$MANAGED_NETPLAN" \
        "$UPLINK_EFFECTIVE" "$UPLINK_MAC"
    if [[ -n "$UPLINK_GATEWAY" ]]; then
        printf '# current-gateway: %s\n' "$UPLINK_GATEWAY"
    fi
    if [[ "$MODE" == vlan-aware ]]; then
        printf '# allowed-vlans: %s\n' "$ALLOWED_VLANS"
        printf '# native LAN: VID 1 PVID/untagged; requested guest VIDs are access TAPs.\n'
    fi
    printf '### BEGIN %s\n' "$MANAGED_NETPLAN_EARLY"
    render_netplan_early "$UPLINK_EFFECTIVE"
    printf '### END %s\n' "$MANAGED_NETPLAN_EARLY"
    printf '### BEGIN %s\n' "$MANAGED_NETPLAN"
    render_netplan "$BRIDGE" "$UPLINK_EFFECTIVE" "$UPLINK_MAC" "$MODE"
    printf '### END %s\n' "$MANAGED_NETPLAN"
}

verify_host() {
    resolve_inputs || return
    setup_validate_supported_ip_contract \
        "$BRIDGE" "$UPLINK_EFFECTIVE" || return
    setup_bridge_verify_host_l3 \
        "$BRIDGE" "$UPLINK_EFFECTIVE" \
        "${G11_NETWORK_VERIFY_GATEWAY:-}" || return
    verify_vlan_runtime || return
    resolve_allowed_identity || return
    vlan_runtime_assets_ready || {
        setup_error "VLAN runtime/helper/sudoers/service 契约未完整安装。"
        return 1
    }
    bridge_helper_ready || {
        setup_error "G-11 bridge helper 未安装或权限/capability 不正确。"
        return 1
    }
    printf 'OK: %s -> %s，宿主 DHCP/默认路由位于 bridge。\n' \
        "$UPLINK_EFFECTIVE" "$BRIDGE" || true
    return 0
}

build_privileged_network_command() {
    local action="$1"
    local -n result="$2"

    case "$action" in
        apply|verify|verify-auto-ready) ;;
        *)
            setup_error "内部错误：不支持的提权网络动作 '$action'。"
            return 2
            ;;
    esac
    [[ -x /usr/bin/sudo ]] || {
        setup_error "缺少 sudo，无法读取 root-only 的宿主网络契约。"
        return 1
    }
    result=(/usr/bin/sudo -H -u root -- "$HERE/setup-bridge.sh" "$action"
        --bridge "$BRIDGE" --mode "$MODE" --timeout "$CONFIRM_TIMEOUT")
    [[ -z "$UPLINK_REQUESTED" ]] \
        || result+=(--uplink "$UPLINK_REQUESTED")
    [[ "$MODE" != vlan-aware ]] \
        || result+=(--allowed-vlans "$ALLOWED_VLANS")
}

verify_host_privileged() {
    local -a command

    if (( EUID == 0 )); then
        verify_host
        return
    fi
    build_privileged_network_command verify command
    exec "${command[@]}"
}

verify_host_for_auto() {
    (( EUID == 0 )) || {
        setup_error "内部只读校验必须由 root 执行。"
        return 125
    }
    if verify_host; then
        return 0
    fi
    # This dedicated status proves that sudo successfully launched the root
    # verifier and that the installed/runtime contract itself needs repair.
    # The parent must not confuse sudo denial, cancellation or a signal with
    # this result.
    return "$AUTO_VERIFY_REPAIR_RC"
}

find_qemu_bridge_helper() {
    local candidate owner mode

    for candidate in \
        /usr/local/libexec/qemu-bridge-helper \
        /usr/lib/qemu/qemu-bridge-helper \
        /usr/libexec/qemu-bridge-helper; do
        setup_trusted_directory "${candidate%/*}" || continue
        [[ -x "$candidate" && -f "$candidate" && ! -L "$candidate" ]] || continue
        owner="$(stat -c '%u' -- "$candidate" 2>/dev/null)" || continue
        mode="$(stat -c '%a' -- "$candidate" 2>/dev/null)" || continue
        [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || continue
        (( (8#$mode & 8#022) == 0 )) || continue
        printf '%s\n' "$candidate"
        return 0
    done
    setup_error "找不到可信的发行版 qemu-bridge-helper；请先安装 qemu-system-common。"
    return 1
}

quarantine_installed_bridge_helper() {
    # If an administrator broadened bridge.conf after an earlier setup, do not
    # leave G-11's dedicated privileged copy executable by the VM user while we
    # refuse to overwrite that policy.  Only a trusted, fixed-path regular file
    # is touched; an unsafe path is left alone and reported by the caller.
    setup_trusted_file "$BRIDGE_HELPER_INSTALLED" 0 || return 0
    setcap -r "$BRIDGE_HELPER_INSTALLED" >/dev/null 2>&1 || true
    chown root:root "$BRIDGE_HELPER_INSTALLED"
    chmod 0700 "$BRIDGE_HELPER_INSTALLED"
}

install_bridge_contract() {
    local bridge_name="$1" uplink="$2" mac="$3"
    local helper bridge_tmp facts_tmp tmpfiles_tmp

    helper="$(find_qemu_bridge_helper)"
    resolve_allowed_identity
    install -d -o root -g root -m 0755 \
        /etc/qemu /usr/local/libexec /etc/tmpfiles.d

    bridge_tmp="$(mktemp /etc/qemu/.bridge.conf.XXXXXX)"
    if [[ -e /etc/qemu/bridge.conf || -L /etc/qemu/bridge.conf ]]; then
        setup_trusted_file /etc/qemu/bridge.conf 0 || {
            rm -f -- "$bridge_tmp"
            quarantine_installed_bridge_helper
            setup_error "/etc/qemu/bridge.conf 不是可信的 root 普通文件，拒绝覆盖。"
            return 1
        }
        while IFS= read -r bridge_rule || [[ -n "$bridge_rule" ]]; do
            [[ -z "$bridge_rule" || "$bridge_rule" == \#* \
                || "$bridge_rule" == "allow $bridge_name" ]] || {
                rm -f -- "$bridge_tmp"
                quarantine_installed_bridge_helper
                setup_error "/etc/qemu/bridge.conf 含非 G-11 ACL，拒绝把宽泛规则暴露给特权 helper。"
                return 1
            }
        done </etc/qemu/bridge.conf
    fi
    printf 'allow %s\n' "$bridge_name" >"$bridge_tmp"
    install -o root -g root -m 0644 "$bridge_tmp" /etc/qemu/bridge.conf
    rm -f -- "$bridge_tmp"

    tmpfiles_tmp="$(mktemp /etc/tmpfiles.d/.qemu-g11-network.XXXXXX)"
    render_network_tmpfiles_config >"$tmpfiles_tmp"
    install -o root -g root -m 0644 \
        "$tmpfiles_tmp" "$NETWORK_TMPFILES_CONFIG"
    rm -f -- "$tmpfiles_tmp"
    systemd-tmpfiles --create "$NETWORK_TMPFILES_CONFIG"

    # The ACL is exact and root-controlled before the helper gains privilege.
    install -o root -g "$ALLOWED_GID_VALUE" -m 0750 \
        "$helper" "$BRIDGE_HELPER_INSTALLED"
    if command -v setcap >/dev/null 2>&1 \
        && setcap cap_net_admin+ep "$BRIDGE_HELPER_INSTALLED"; then
        :
    else
        chown root:"$ALLOWED_GID_VALUE" "$BRIDGE_HELPER_INSTALLED"
        chmod u+s "$BRIDGE_HELPER_INSTALLED"
    fi

    facts_tmp="$(mktemp /etc/qemu/.g11-bridge.conf.XXXXXX)"
    render_bridge_facts "$bridge_name" "$uplink" "$mac" "$MODE" >"$facts_tmp"
    install -o root -g root -m 0644 "$facts_tmp" "$BRIDGE_FACTS"
    rm -f -- "$facts_tmp"
}

resolve_allowed_identity() {
    local requested_user="${VM_USER:-}" requested_uid requested_gid

    if (( EXISTING_VLAN_CONFIG == 1 )); then
        ALLOWED_UID_VALUE=$EXISTING_ALLOWED_UID
        ALLOWED_GID_VALUE=$EXISTING_ALLOWED_GID
        if [[ -n "$requested_user" ]]; then
            [[ "$requested_user" =~ ^[[:alnum:]_.-]+\$?$ ]] || {
                setup_error "VM_USER 用户名不安全: $requested_user"
                return 1
            }
            requested_uid="$(id -u -- "$requested_user")" || return 1
            requested_gid="$(id -g -- "$requested_user")" || return 1
            [[ "$requested_uid" == "$ALLOWED_UID_VALUE" \
                && "$requested_gid" == "$ALLOWED_GID_VALUE" ]] || {
                setup_error "已有 VLAN runtime 绑定 UID:GID=${ALLOWED_UID_VALUE}:${ALLOWED_GID_VALUE}；拒绝无迁移地改绑。"
                return 1
            }
        fi
    elif [[ -n "$requested_user" ]]; then
        [[ "$requested_user" =~ ^[[:alnum:]_.-]+\$?$ ]] || {
            setup_error "VM_USER 用户名不安全: $requested_user"
            return 1
        }
        ALLOWED_UID_VALUE="$(id -u -- "$requested_user")" || return 1
        ALLOWED_GID_VALUE="$(id -g -- "$requested_user")" || return 1
    elif [[ "${SUDO_UID:-}" =~ ^[0-9]+$ \
        && "${SUDO_GID:-}" =~ ^[0-9]+$ \
        && "${SUDO_UID:-0}" != 0 ]]; then
        ALLOWED_UID_VALUE=$SUDO_UID
        ALLOWED_GID_VALUE=$SUDO_GID
    elif (( EUID != 0 )); then
        ALLOWED_UID_VALUE=$EUID
        ALLOWED_GID_VALUE=$(id -g)
    else
        setup_error "无法确定普通 VM 用户；直接 root 运行请设置 VM_USER=<用户名>。"
        return 1
    fi
    [[ "$ALLOWED_UID_VALUE" =~ ^[0-9]+$ \
        && "$ALLOWED_GID_VALUE" =~ ^[0-9]+$ ]] || return 1
}

install_vlan_runtime() {
    local config_tmp sudoers_tmp asset mod

    [[ "$MODE" == vlan-aware ]] || return 0
    for asset in "$VLAN_TAP_SOURCE" "$VLAN_DOWN_SOURCE" \
        "$VLAN_BRIDGE_SOURCE" "$VLAN_DISPATCHER_SOURCE" "$VLAN_SERVICE_SOURCE"; do
        [[ -f "$asset" && ! -L "$asset" ]] || {
            setup_error "缺少 VLAN runtime 资产: $asset"
            return 1
        }
    done
    resolve_allowed_identity
    install -d -o root -g root -m 0755 \
        /usr/local/libexec /etc/qemu /etc/sudoers.d \
        /etc/NetworkManager/dispatcher.d /etc/systemd/system /etc/modules-load.d
    install -o root -g root -m 0755 "$VLAN_TAP_SOURCE" "$VLAN_TAP_INSTALLED"
    install -o root -g root -m 0755 "$VLAN_DOWN_SOURCE" "$VLAN_DOWN_INSTALLED"
    install -o root -g root -m 0755 "$VLAN_BRIDGE_SOURCE" "$VLAN_BRIDGE_INSTALLED"
    install -o root -g root -m 0755 \
        "$VLAN_DISPATCHER_SOURCE" "$VLAN_DISPATCHER_INSTALLED"
    install -o root -g root -m 0644 "$VLAN_SERVICE_SOURCE" "$VLAN_SERVICE_INSTALLED"

    config_tmp="$(mktemp /etc/qemu/.g11-vlan.conf.XXXXXX)"
    printf 'VERSION=1\nBRIDGE=br0\nUPLINK=%s\nALLOWED_UID=%s\nALLOWED_GID=%s\nALLOWED_VLANS=%s\n' \
        "$UPLINK_EFFECTIVE" "$ALLOWED_UID_VALUE" "$ALLOWED_GID_VALUE" \
        "$ALLOWED_VLANS" >"$config_tmp"
    install -o root -g root -m 0644 "$config_tmp" "$VLAN_CONFIG"
    rm -f -- "$config_tmp"

    sudoers_tmp="$(mktemp /etc/sudoers.d/.qemu-g11-vlan.XXXXXX)"
    {
        printf '# G-11: only the setup caller may invoke the fixed VLAN TAP helper.\n'
        printf '#%s ALL=(root) NOPASSWD:NOSETENV: %s\n' \
            "$ALLOWED_UID_VALUE" "$VLAN_TAP_INSTALLED"
    } >"$sudoers_tmp"
    chmod 0440 "$sudoers_tmp"
    visudo -cf "$sudoers_tmp" >/dev/null
    chown root:root "$sudoers_tmp"
    mv -f -- "$sudoers_tmp" "$VLAN_SUDOERS"

    for mod in tun bridge 8021q; do
        modprobe "$mod" 2>/dev/null || setup_warn "modprobe $mod 失败"
    done
    printf 'tun\nbridge\n8021q\n' >/etc/modules-load.d/qemu-g11-vlan.conf
    chown root:root /etc/modules-load.d/qemu-g11-vlan.conf
    chmod 0644 /etc/modules-load.d/qemu-g11-vlan.conf
    systemctl daemon-reload
    systemctl enable qemu-g11-vlan-bridge.service >/dev/null
}

disable_vlan_runtime() {
    [[ "$MODE" == access ]] || return 0
    systemctl disable --now qemu-g11-vlan-bridge.service >/dev/null 2>&1 || true
    rm -f -- "$VLAN_DISPATCHER_INSTALLED" "$VLAN_SERVICE_INSTALLED" \
        "$VLAN_CONFIG" "$VLAN_SUDOERS"
    # setup_network_is_busy already refused any intent state; only remove the
    # root runtime directory if it is in fact empty.
    rmdir -- /run/qemu-g11-vlan 2>/dev/null || true
    systemctl daemon-reload
}

verify_vlan_runtime() {
    [[ "$MODE" == vlan-aware ]] || return 0
    local details
    details="$(ip -d -o link show dev "$BRIDGE" 2>/dev/null)" || return 1
    [[ "$details" =~ [[:space:]]vlan_filtering[[:space:]]+1([[:space:]]|$) ]] \
        || { setup_error "$BRIDGE 尚未启用 vlan_filtering"; return 1; }
    bridge vlan show dev "$UPLINK_EFFECTIVE" 2>/dev/null \
        | grep -Eq '(^|[[:space:]])1[[:space:]].*PVID.*Untagged' || {
            setup_error "$UPLINK_EFFECTIVE 缺少 native/PVID/untagged VID 1"
            return 1
        }
    bridge vlan show dev "$BRIDGE" 2>/dev/null \
        | grep -Eq '(^|[[:space:]])1[[:space:]].*PVID.*Untagged' || {
            setup_error "$BRIDGE self 缺少 native/PVID/untagged VID 1"
            return 1
        }
}

setup_vlan_native_status() {
    local dev="$1"

    bridge vlan show dev "$dev" 2>/dev/null | awk -v dev="$dev" '
        NR == 1 { next }
        NF == 0 { next }
        {
            if ($1 == dev) { token=$2; start=3 } else { token=$1; start=2 }
            pvid=untagged=0
            for (i=start; i<=NF; i++) {
                if ($i == "PVID") pvid=1
                if ($i == "Untagged") untagged=1
            }
            if (token == "1") {
                count++
                if (pvid && untagged) native++
            } else if (pvid || untagged) conflict=1
        }
        END {
            if (conflict || count > 1 || (count == 1 && native != 1)) print "unsafe"
            else if (count == 0) print "missing"
            else print "native"
        }
    '
}

ensure_provisional_vlan_topology() {
    local lock=/run/qemu-g11-vlan.lock status owner mode

    if [[ ! -e "$lock" ]]; then
        ( set -o noclobber; umask 077; : >"$lock" ) 2>/dev/null || true
    fi
    [[ -f "$lock" && ! -L "$lock" ]] || {
        setup_error "VLAN 全局锁类型不安全: $lock"
        return 1
    }
    owner="$(stat -c '%u' -- "$lock")"
    mode="$(stat -c '%a' -- "$lock")"
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ \
        && $((8#$mode & 8#022)) == 0 ]] || {
        setup_error "VLAN 全局锁权限不安全: $lock"
        return 1
    }
    exec 8>>"$lock"
    flock -x -w 10 8 || {
        setup_error "等待 VLAN 全局锁超时"
        return 1
    }
    ip link set dev "$BRIDGE" type bridge \
        vlan_filtering 1 vlan_default_pvid 1 vlan_protocol 802.1Q
    status="$(setup_vlan_native_status "$UPLINK_EFFECTIVE")"
    case "$status" in
        native) ;;
        missing) bridge vlan add dev "$UPLINK_EFFECTIVE" vid 1 pvid untagged ;;
        *)
            setup_error "$UPLINK_EFFECTIVE 存在不安全的 native VLAN flags"
            flock -u 8
            exec 8>&-
            return 1
            ;;
    esac
    status="$(setup_vlan_native_status "$BRIDGE")"
    case "$status" in
        native) ;;
        missing) bridge vlan add dev "$BRIDGE" vid 1 pvid untagged self ;;
        *)
            setup_error "$BRIDGE self 存在不安全的 native VLAN flags"
            flock -u 8
            exec 8>&-
            return 1
            ;;
    esac
    if verify_vlan_runtime; then
        flock -u 8
        exec 8>&-
        return 0
    fi
    flock -u 8
    exec 8>&-
    return 1
}

setup_trusted_file() {
    local path="$1" executable="${2:-0}" owner mode

    [[ -f "$path" && ! -L "$path" ]] || return 1
    owner="$(stat -c '%u' -- "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 1
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#022) == 0 )) || return 1
    [[ "$executable" == 0 || -x "$path" ]]
}

setup_trusted_directory() {
    local path="$1" owner mode

    [[ -d "$path" && ! -L "$path" ]] || return 1
    owner="$(stat -c '%u' -- "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 1
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#022) == 0 ))
}

bridge_helper_ready() {
    local mode gid capabilities source_helper expected_facts actual_facts
    local expected_tmpfiles actual_tmpfiles

    setup_trusted_directory /etc/qemu || return 1
    setup_trusted_directory "${BRIDGE_HELPER_INSTALLED%/*}" || return 1
    setup_trusted_directory "${NETWORK_TMPFILES_CONFIG%/*}" || return 1
    setup_trusted_file /etc/qemu/bridge.conf 0 || return 1
    setup_trusted_file "$NETWORK_TMPFILES_CONFIG" 0 || return 1
    setup_trusted_file "$NETWORK_LOCK" 0 || return 1
    [[ "$(stat -c '%a' -- "$NETWORK_TMPFILES_CONFIG")" == 644 \
        && "$(stat -c '%a' -- "$NETWORK_LOCK")" == 644 ]] || return 1
    setup_trusted_file "$BRIDGE_HELPER_INSTALLED" 1 || return 1
    mode="$(stat -c '%a' -- "$BRIDGE_HELPER_INSTALLED")" || return 1
    gid="$(stat -c '%g' -- "$BRIDGE_HELPER_INSTALLED")" || return 1
    [[ "$gid" == "$ALLOWED_GID_VALUE" ]] || return 1
    (( (8#$mode & 8#0777) == 8#0750 )) || return 1
    if (( (8#$mode & 8#4000) == 0 )); then
        command -v getcap >/dev/null 2>&1 || return 1
        capabilities="$(getcap -- "$BRIDGE_HELPER_INSTALLED" 2>/dev/null)" || return 1
        [[ "${capabilities#* }" == cap_net_admin=ep ]] || return 1
    else
        (( (8#$mode & 8#7000) == 8#4000 )) || return 1
    fi
    expected_tmpfiles="$(render_network_tmpfiles_config)"
    actual_tmpfiles="$(<"$NETWORK_TMPFILES_CONFIG")"
    [[ "$actual_tmpfiles" == "$expected_tmpfiles" ]] || return 1
    setup_trusted_file "$BRIDGE_FACTS" 0 || return 1
    expected_facts="$(render_bridge_facts \
        "$BRIDGE" "$UPLINK_EFFECTIVE" "$UPLINK_MAC" "$MODE")"
    actual_facts="$(<"$BRIDGE_FACTS")"
    [[ "$actual_facts" == "$expected_facts" ]] || return 1
    [[ "$(sed -E '/^[[:space:]]*(#|$)/d' /etc/qemu/bridge.conf 2>/dev/null)" \
        == "allow $BRIDGE" ]] || return 1
    source_helper="$(find_qemu_bridge_helper 2>/dev/null)" || return 1
    cmp -s -- "$source_helper" "$BRIDGE_HELPER_INSTALLED"
}

vlan_runtime_assets_ready() {
    local existing expected_sudo unexpected_sudo stateful

    if [[ "$MODE" == access ]]; then
        for stateful in "$VLAN_CONFIG" "$VLAN_SUDOERS" \
                "$VLAN_DISPATCHER_INSTALLED" "$VLAN_SERVICE_INSTALLED"; do
            [[ ! -e "$stateful" && ! -L "$stateful" ]] || return 1
        done
        ! systemctl is-enabled --quiet qemu-g11-vlan-bridge.service \
            >/dev/null 2>&1 || return 1
        ! systemctl is-active --quiet qemu-g11-vlan-bridge.service \
            >/dev/null 2>&1 || return 1
        return 0
    fi
    existing="$(read_existing_vlan_allowlist 2>/dev/null)" || return 1
    [[ "$existing" == "$ALLOWED_VLANS" ]] || return 1
    [[ "$EXISTING_VLAN_UPLINK" == "$UPLINK_EFFECTIVE" \
        && "$EXISTING_ALLOWED_UID" == "$ALLOWED_UID_VALUE" \
        && "$EXISTING_ALLOWED_GID" == "$ALLOWED_GID_VALUE" ]] || return 1
    setup_trusted_directory /etc/qemu \
        && setup_trusted_directory /usr/local/libexec \
        && setup_trusted_directory /etc/sudoers.d \
        && setup_trusted_directory /etc/NetworkManager/dispatcher.d \
        && setup_trusted_directory /etc/systemd/system || return 1
    setup_trusted_file "$VLAN_TAP_INSTALLED" 1 \
        && setup_trusted_file "$VLAN_DOWN_INSTALLED" 1 \
        && setup_trusted_file "$VLAN_BRIDGE_INSTALLED" 1 \
        && setup_trusted_file "$VLAN_DISPATCHER_INSTALLED" 1 \
        && setup_trusted_file "$VLAN_SERVICE_INSTALLED" 0 \
        && setup_trusted_file "$VLAN_SUDOERS" 0 || return 1
    [[ "$(stat -c '%a' -- "$VLAN_TAP_INSTALLED")" == 755 \
        && "$(stat -c '%a' -- "$VLAN_DOWN_INSTALLED")" == 755 \
        && "$(stat -c '%a' -- "$VLAN_BRIDGE_INSTALLED")" == 755 \
        && "$(stat -c '%a' -- "$VLAN_DISPATCHER_INSTALLED")" == 755 \
        && "$(stat -c '%a' -- "$VLAN_SERVICE_INSTALLED")" == 644 \
        && "$(stat -c '%a' -- "$VLAN_SUDOERS")" == 440 ]] || return 1
    cmp -s -- "$VLAN_TAP_SOURCE" "$VLAN_TAP_INSTALLED" \
        && cmp -s -- "$VLAN_DOWN_SOURCE" "$VLAN_DOWN_INSTALLED" \
        && cmp -s -- "$VLAN_BRIDGE_SOURCE" "$VLAN_BRIDGE_INSTALLED" \
        && cmp -s -- "$VLAN_DISPATCHER_SOURCE" "$VLAN_DISPATCHER_INSTALLED" \
        && cmp -s -- "$VLAN_SERVICE_SOURCE" "$VLAN_SERVICE_INSTALLED" \
        || return 1
    expected_sudo="#${ALLOWED_UID_VALUE} ALL=(root) NOPASSWD:NOSETENV: ${VLAN_TAP_INSTALLED}"
    grep -Fqx -- "$expected_sudo" "$VLAN_SUDOERS" || return 1
    unexpected_sudo="$(awk '
        !/^(# G-11:|#[0-9]+ ALL=|[[:space:]]*$)/ { bad++ }
        END { print bad + 0 }
    ' "$VLAN_SUDOERS")"
    [[ "$unexpected_sudo" == 0 ]] || return 1
    systemctl is-enabled --quiet qemu-g11-vlan-bridge.service || return 1
    systemctl is-active --quiet qemu-g11-vlan-bridge.service || return 1
}

auto_host_is_ready() {
    resolve_inputs || return 1
    resolve_allowed_identity || return 1
    setup_validate_supported_ip_contract "$BRIDGE" "$UPLINK_EFFECTIVE" \
        >/dev/null 2>&1 || return 1
    setup_bridge_verify_host_l3 "$BRIDGE" "$UPLINK_EFFECTIVE" "" \
        >/dev/null 2>&1 || return 1
    verify_vlan_runtime >/dev/null 2>&1 || return 1
    vlan_runtime_assets_ready || return 1
    bridge_helper_ready || return 1
    printf 'OK: %s -> %s 已完整就绪；配置未改变，活动 VM 不受影响。\n' \
        "$UPLINK_EFFECTIVE" "$BRIDGE"
}

auto_readonly_dependency_preflight() {
    local command asset

    [[ -z "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" \
        || "${G11_NETWORK_ALLOW_SSH:-0}" == 1 ]] || {
        setup_error "SSH 会话默认拒绝迁网；请在宿主本地控制台执行。"
        return 1
    }
    setup_networkmanager_is_active || {
        setup_error "NetworkManager 未运行；VM 保持运行，宿主网络未修改。"
        return 1
    }
    for command in netplan systemd-run systemctl systemd-tmpfiles nmcli ip \
            bridge flock stat install mktemp visudo; do
        command -v "$command" >/dev/null 2>&1 || {
            setup_error "缺少依赖 $command；VM 保持运行，宿主网络未修改。"
            return 1
        }
    done
    [[ -x "$NETPLAN_GENERATOR" ]] || {
        setup_error "缺少 Netplan generator: $NETPLAN_GENERATOR"
        return 1
    }
    find_qemu_bridge_helper >/dev/null || return 1
    for asset in "$ROLLBACK_SOURCE" "$VLAN_TAP_SOURCE" "$VLAN_DOWN_SOURCE" \
            "$VLAN_BRIDGE_SOURCE" "$VLAN_DISPATCHER_SOURCE" \
            "$VLAN_SERVICE_SOURCE"; do
        [[ -f "$asset" && ! -L "$asset" ]] || {
            setup_error "缺少或不安全的部署资产: $asset"
            return 1
        }
    done
    # Everything below is still read-only and intentionally precedes the VM
    # shutdown prompt.  In particular, static IPv4 or active IPv6 must be
    # rejected while guests are still running.
    resolve_inputs
    resolve_allowed_identity
    setup_validate_supported_ip_contract "$BRIDGE" "$UPLINK_EFFECTIVE"
}

offline_validate_candidate() {
    local candidate_early="$1" candidate="$2" work="$3" root

    root="$work/candidate-root"
    setup_copy_netplan_sources "$root"
    install -m 0600 "$candidate_early" \
        "$root/etc/netplan/${MANAGED_NETPLAN_EARLY##*/}"
    install -m 0600 "$candidate" "$root/etc/netplan/${MANAGED_NETPLAN##*/}"
    [[ -x "$NETPLAN_GENERATOR" ]] || {
        setup_error "缺少 Netplan generator: $NETPLAN_GENERATOR"
        return 1
    }
    "$NETPLAN_GENERATOR" --root-dir "$root"
}

offline_select_rollback_recovery() {
    local candidate_early="$1" work="$2" root

    root="$work/rollback-root"
    setup_copy_netplan_sources "$root"
    if "$NETPLAN_GENERATOR" --root-dir "$root" \
            >"$work/rollback-generate.out" 2>"$work/rollback-generate.err"; then
        printf '0\n'
        return 0
    fi
    root="$work/recovery-root"
    setup_copy_netplan_sources "$root"
    install -m 0600 "$candidate_early" \
        "$root/etc/netplan/${MANAGED_NETPLAN_EARLY##*/}"
    if "$NETPLAN_GENERATOR" --root-dir "$root" \
            >"$work/recovery-generate.out" 2>"$work/recovery-generate.err"; then
        printf '1\n'
        return 0
    fi
    setup_error "当前 Netplan 与仅添加安全 uplink 声明的恢复配置都无法生成；拒绝迁网。"
    sed 's/^/  /' "$work/recovery-generate.err" >&2 || true
    return 1
}

stop_rollback_timer() {
    [[ -n "$TRANSACTION_UNIT" ]] || return 0
    systemctl stop "$TRANSACTION_UNIT.timer" >/dev/null 2>&1 || true
    systemctl reset-failed "$TRANSACTION_UNIT.service" \
        "$TRANSACTION_UNIT.timer" >/dev/null 2>&1 || true
}

rollback_transaction() {
    local rc=0

    (( TRANSACTION_ARMED == 1 )) || return 0
    if (( ROLLBACK_COMMIT_LOCK_HELD == 1 )); then
        flock -u 6 || true
        exec 6>&-
        ROLLBACK_COMMIT_LOCK_HELD=0
    fi
    if "$ROLLBACK_INSTALLED" "$TRANSACTION_ID"; then
        TRANSACTION_ARMED=0
        stop_rollback_timer
        return 0
    fi
    rc=$?
    setup_warn "立即回滚未完成；独立 watchdog 保持启用并会重试。"
    return "$rc"
}

transaction_exit_guard() {
    local rc=$?

    if (( TRANSACTION_ARMED == 1 )); then
        setup_warn "配置尚未确认，立即恢复迁移前网络。"
        rollback_transaction || true
    fi
    return "$rc"
}

acquire_network_maintenance_lock() {
    local owner mode before after

    if [[ ! -e "$NETWORK_LOCK" ]]; then
        ( set -o noclobber; umask 022; : >"$NETWORK_LOCK" ) 2>/dev/null || true
    fi
    [[ -f "$NETWORK_LOCK" && ! -L "$NETWORK_LOCK" ]] || {
        setup_error "宿主网络维护锁类型不安全: $NETWORK_LOCK"
        return 1
    }
    owner="$(stat -c '%u' -- "$NETWORK_LOCK")"
    mode="$(stat -c '%a' -- "$NETWORK_LOCK")"
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ \
        && $((8#$mode & 8#022)) == 0 ]] || {
        setup_error "宿主网络维护锁权限不安全: $NETWORK_LOCK"
        return 1
    }
    before="$(stat -c '%d:%i' -- "$NETWORK_LOCK")"
    exec 9>>"$NETWORK_LOCK"
    after="$(stat -Lc '%d:%i' -- /proc/self/fd/9)"
    [[ "$before" == "$after" ]] || {
        setup_error "宿主网络维护锁在打开时被替换"
        return 1
    }
    flock -x -w 5 9 || {
        setup_error "有 VM 正在启动或运行；宿主网络未修改，请先正常关机。"
        return 1
    }
    NETWORK_MAINTENANCE_LOCK_HELD=1
}

release_network_maintenance_lock() {
    (( NETWORK_MAINTENANCE_LOCK_HELD == 1 )) || return 0
    flock -u 9
    exec 9>&-
    NETWORK_MAINTENANCE_LOCK_HELD=0
}

apply_host() {
    local candidate candidate_early work txn_dir
    local rollback_recovery_early=0
    local had_early=0 had_target=0
    local deadline remaining answer="" verify_deadline verified=0

    [[ "$(id -u)" == 0 ]] || {
        setup_error "apply 必须通过 sudo 以 root 运行。"
        return 1
    }
    # Mutating mode never trusts a caller-controlled PATH or fake sysfs root.
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    export PATH
    SETUP_SYS_CLASS_NET=/sys/class/net
    [[ -z "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" \
        || "${G11_NETWORK_ALLOW_SSH:-0}" == 1 ]] || {
        setup_error "SSH 会话默认拒绝迁网；请在宿主本地控制台执行。"
        return 1
    }
    exec 7<>/dev/tty || {
        setup_error "apply 需要本地交互 TTY，以便在超时前确认网络。"
        return 1
    }

    acquire_network_maintenance_lock
    setup_network_is_busy && {
        setup_error "请先正常关闭所有 VM，并清理残留 TAP，再重试。"
        return 1
    }
    setup_networkmanager_is_active || {
        setup_error "当前封装要求 active NetworkManager；不会混用 NM profile 与 netplan。"
        return 1
    }
    command -v netplan >/dev/null 2>&1 || {
        setup_error "缺少 netplan。"
        return 1
    }
    command -v systemd-run >/dev/null 2>&1 || {
        setup_error "缺少 systemd-run，无法建立断线后仍有效的回滚 watchdog。"
        return 1
    }
    for runtime_override in \
        "/run/netplan/${MANAGED_NETPLAN_EARLY##*/}" \
        "/run/netplan/${MANAGED_NETPLAN##*/}"; do
        [[ ! -e "$runtime_override" && ! -L "$runtime_override" ]] || {
            setup_error "发现会遮蔽持久配置的 runtime Netplan: $runtime_override"
            return 1
        }
    done
    [[ -f "$ROLLBACK_SOURCE" && ! -L "$ROLLBACK_SOURCE" ]] || {
        setup_error "缺少回滚 helper 源文件: $ROLLBACK_SOURCE"
        return 1
    }

    resolve_inputs
    if setup_bridge_verify_host_l3 "$BRIDGE" "$UPLINK_EFFECTIVE" "" \
            >/dev/null 2>&1; then
        echo ">> 当前 bridge 已健康；只刷新持久配置和 helper 契约。"
    fi
    setup_validate_supported_ip_contract "$BRIDGE" "$UPLINK_EFFECTIVE"
    find_qemu_bridge_helper >/dev/null

    work="$(mktemp -d /run/qemu-g11-network.XXXXXX)"
    chmod 0700 "$work"
    candidate_early="$work/${MANAGED_NETPLAN_EARLY##*/}"
    candidate="$work/${MANAGED_NETPLAN##*/}"
    render_netplan_early "$UPLINK_EFFECTIVE" >"$candidate_early"
    render_netplan "$BRIDGE" "$UPLINK_EFFECTIVE" "$UPLINK_MAC" "$MODE" >"$candidate"
    chmod 0600 "$candidate_early" "$candidate"
    rollback_recovery_early="$(offline_select_rollback_recovery \
        "$candidate_early" "$work")" || return 1
    if [[ "$rollback_recovery_early" == 1 ]]; then
        if [[ -e "$MANAGED_NETPLAN_EARLY" \
            || -L "$MANAGED_NETPLAN_EARLY" ]]; then
            setup_error "现有 $MANAGED_NETPLAN_EARLY 无法参与有效回滚；拒绝迁网。"
            setup_error "请先修复当前 Netplan，使原始配置可独立 generate。"
            return 1
        fi
        setup_warn "原始 split Netplan 无法独立生成；回滚时会保留 G-11 的只读 uplink 声明以确保可恢复。"
    fi
    echo ">> 离线校验合并后的 Netplan..."
    offline_validate_candidate "$candidate_early" "$candidate" "$work"
    TRANSACTION_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    txn_dir="$STATE_ROOT/transactions/$TRANSACTION_ID"
    install -d -o root -g root -m 0700 \
        "$STATE_ROOT" "$STATE_ROOT/transactions" "$txn_dir"
    if [[ -e "$MANAGED_NETPLAN_EARLY" ]]; then
        [[ -f "$MANAGED_NETPLAN_EARLY" && ! -L "$MANAGED_NETPLAN_EARLY" ]] || {
            setup_error "$MANAGED_NETPLAN_EARLY 类型异常，拒绝覆盖。"
            return 1
        }
        install -o root -g root -m 0600 \
            "$MANAGED_NETPLAN_EARLY" "$txn_dir/previous-early.yaml"
        had_early=1
    fi
    if [[ -e "$MANAGED_NETPLAN" ]]; then
        [[ -f "$MANAGED_NETPLAN" && ! -L "$MANAGED_NETPLAN" ]] || {
            setup_error "$MANAGED_NETPLAN 类型异常，拒绝覆盖。"
            return 1
        }
        install -o root -g root -m 0600 \
            "$MANAGED_NETPLAN" "$txn_dir/previous.yaml"
        had_target=1
    fi
    if [[ "$rollback_recovery_early" == 1 ]]; then
        install -o root -g root -m 0600 \
            "$candidate_early" "$txn_dir/recovery-early.yaml"
    fi
    printf 'VERSION=1\nHAD_EARLY=%s\nHAD_TARGET=%s\nRECOVERY_EARLY=%s\n' \
        "$had_early" "$had_target" "$rollback_recovery_early" \
        >"$txn_dir/manifest"
    chmod 0600 "$txn_dir/manifest"
    install -o root -g root -m 0755 "$ROLLBACK_SOURCE" "$ROLLBACK_INSTALLED"

    TRANSACTION_UNIT="qemu-g11-network-rollback-$TRANSACTION_ID"
    systemd-run --quiet --unit="$TRANSACTION_UNIT" \
        --on-active="${CONFIRM_TIMEOUT}s" --property=Type=oneshot \
        --property=Restart=on-failure --property=RestartSec=5s \
        "$ROLLBACK_INSTALLED" "$TRANSACTION_ID"
    TRANSACTION_ARMED=1
    trap transaction_exit_guard EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    deadline=$((SECONDS + CONFIRM_TIMEOUT))
    install -o root -g root -m 0600 "$candidate_early" "$MANAGED_NETPLAN_EARLY"
    install -o root -g root -m 0600 "$candidate" "$MANAGED_NETPLAN"

    echo ">> 应用候选配置；未确认会由独立 watchdog 自动回滚。"
    netplan apply
    verify_deadline=$((SECONDS + 45))
    while (( SECONDS < verify_deadline && SECONDS < deadline )); do
        if setup_bridge_verify_host_l3 \
            "$BRIDGE" "$UPLINK_EFFECTIVE" "$UPLINK_GATEWAY" \
            >/dev/null 2>&1; then
            verified=1
            break
        fi
        sleep 1
    done
    if (( verified == 0 )); then
        setup_error "45 秒内未通过 bridge/DHCP/网关验证，执行回滚。"
        rollback_transaction
        trap - EXIT INT TERM
        return 1
    fi
    if [[ "$MODE" == vlan-aware ]] \
        && ! ensure_provisional_vlan_topology; then
        setup_error "无法启用 VID 1 native 的 VLAN-aware br0，执行回滚。"
        rollback_transaction
        trap - EXIT INT TERM
        return 1
    fi
    if ! verify_vlan_runtime \
        || ! setup_bridge_verify_host_l3 \
            "$BRIDGE" "$UPLINK_EFFECTIVE" "$UPLINK_GATEWAY"; then
        setup_error "VLAN-aware bridge 拓扑未通过检查，执行回滚。"
        rollback_transaction
        trap - EXIT INT TERM
        return 1
    fi

    remaining=$((deadline - SECONDS))
    (( remaining > 0 )) || {
        setup_error "确认窗口已耗尽，执行回滚。"
        rollback_transaction
        trap - EXIT INT TERM
        return 1
    }
    printf '\n网络已自动验证。请输入 KEEP %s 并回车确认（%s 秒内）: ' \
        "$UPLINK_EFFECTIVE" "$remaining" >&7
    IFS= read -r -t "$remaining" answer <&7 || true
    if [[ "$answer" != "KEEP $UPLINK_EFFECTIVE" ]]; then
        setup_error "未收到精确确认，执行回滚。"
        rollback_transaction
        trap - EXIT INT TERM
        return 1
    fi

    # Do not hold this lock while waiting for operator input: an independent
    # watchdog must still be able to recover if this process is frozen or loses
    # its TTY.  After an exact answer, serialize the commit and reject every
    # transaction for which rollback has started or the deadline has elapsed.
    exec 6>>/run/qemu-g11-network-rollback.lock
    flock -x 6
    ROLLBACK_COMMIT_LOCK_HELD=1
    if (( SECONDS >= deadline )) \
        || [[ -e "$txn_dir/rollback-started" \
            || -L "$txn_dir/rollback-started" \
            || -e "$txn_dir/rollback-failed" \
            || -L "$txn_dir/rollback-failed" \
            || -e "$txn_dir/rolled-back" \
            || -L "$txn_dir/rolled-back" ]]; then
        setup_error "确认已过期或 watchdog 已开始回滚；拒绝提交该事务。"
        rollback_transaction
        trap - EXIT INT TERM
        return 1
    fi
    if [[ -e "$txn_dir/committed" || -L "$txn_dir/committed" ]]; then
        setup_error "事务出现意外的 committed 标记，拒绝继续。"
        rollback_transaction
        trap - EXIT INT TERM
        return 1
    fi

    # Once committed under the same lock used by the detached helper, the
    # helper will observe the marker and exit without touching Netplan.
    touch "$txn_dir/committed"
    TRANSACTION_ARMED=0
    stop_rollback_timer
    flock -u 6
    exec 6>&-
    ROLLBACK_COMMIT_LOCK_HELD=0
    trap - EXIT INT TERM
    install_bridge_contract "$BRIDGE" "$UPLINK_EFFECTIVE" "$UPLINK_MAC"
    if [[ "$MODE" == vlan-aware ]]; then
        install_vlan_runtime
        # The persistence helper deliberately takes this maintenance lock in
        # shared mode.  Starting it while setup still owns the exclusive lock
        # makes systemd wait ten seconds and fail even though the topology is
        # already healthy.  All host/config mutations are complete here, so
        # release the setup lock before the synchronous service restart.
        release_network_maintenance_lock
        systemctl restart qemu-g11-vlan-bridge.service
    else
        disable_vlan_runtime
        release_network_maintenance_lock
    fi
    rm -rf -- "$work"
    echo ">> 已确认并持久保存: $MANAGED_NETPLAN_EARLY, $MANAGED_NETPLAN"
    echo ">> G-11 bridge 契约: $BRIDGE_FACTS"
    verify_host
}

auto_stop_active_vms() {
    local active line pid name id labels="" answer="" arg
    local g11_marker g11_qmp
    local -a ids=()
    local -a argv=()

    active="$(setup_print_active_qemu)"
    [[ -n "$active" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        pid=${line%%:*}
        name=${line#*:}
        if [[ ! "$name" =~ ^vm([1-9][0-9]{0,9})$ ]]; then
            setup_error "发现无法安全映射到 G-11 VM ID 的 QEMU: $line"
            return 1
        fi
        id=${BASH_REMATCH[1]}
        [[ -r "/proc/$pid/cmdline" ]] || continue
        argv=()
        mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null || {
            setup_error "无法读取活动 QEMU $pid 的不可变参数；拒绝自动关机。"
            return 1
        }
        g11_marker=0
        g11_qmp=0
        for arg in "${argv[@]}"; do
            [[ "$arg" == type=11,value=G11_VGPU_PROFILE_V1\|* ]] \
                && g11_marker=1
            if [[ "$arg" == unix:*"/$id/run/qmp"* \
                && "$arg" == *,server,* ]]; then
                g11_qmp=1
            fi
        done
        if (( g11_marker != 1 || g11_qmp != 1 )); then
            setup_error "QEMU $pid ($name) 无法证明属于当前 G-11 生命周期；拒绝误停 V-11/其它实例。"
            return 1
        fi
        ids+=("$id")
        labels+="${labels:+,}vm$id"
    done <<<"$active"
    exec 7<>/dev/tty || {
        setup_error "检测到活动 VM，但没有交互 TTY 可确认安全关机。"
        return 1
    }
    printf '检测到活动 %s。输入 STOP %s 让本命令先正常关机再建桥: ' \
        "$labels" "$labels" >&7
    IFS= read -r answer <&7 || true
    [[ "$answer" == "STOP $labels" ]] || {
        setup_error "未确认 VM 关机，网络未修改。"
        return 1
    }
    for id in "${ids[@]}"; do
        "$HERE/stop-vm.sh" "$id" --graceful-only || {
            setup_error "vm$id 未能优雅关机；未强杀、网络未修改，请处理后重跑。"
            return 1
        }
    done
}

auto_host() {
    local verify_rc
    local -a command

    # A complete VLAN readiness check must inspect the 0440 sudoers fragment.
    # On an already provisioned host, do that read-only check through sudo so
    # an ordinary caller neither gets a false negative nor needlessly reapplies
    # Netplan.  If the installed contract is incomplete, continue into the
    # existing guarded repair path below.
    if (( EUID != 0 && EXISTING_VLAN_CONFIG == 1 )); then
        build_privileged_network_command verify-auto-ready command
        if "${command[@]}"; then
            return 0
        else
            verify_rc=$?
        fi
        if (( verify_rc != AUTO_VERIFY_REPAIR_RC )); then
            setup_error "只读提权校验未执行完成（rc=$verify_rc）；网络和 VM 均未修改。"
            return "$verify_rc"
        fi
        setup_warn "现有 VLAN 契约未通过完整校验；进入受保护的修复流程。"
    else
        auto_host_is_ready && return 0
    fi
    auto_readonly_dependency_preflight
    auto_stop_active_vms
    if (( EUID != 0 )); then
        build_privileged_network_command apply command
        exec "${command[@]}"
    fi
    apply_host
}

case "$ACTION" in
    auto) auto_host ;;
    inspect) inspect_host ;;
    plan) plan_host ;;
    verify) verify_host_privileged ;;
    verify-auto-ready) verify_host_for_auto ;;
    apply) apply_host ;;
esac

#!/usr/bin/env bash
# Root-only persistence helper for the G-11 single-br0 VLAN-aware topology.
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

readonly CONFIG=/etc/qemu/g11-vlan.conf
readonly LOCK=/run/qemu-g11-vlan.lock
readonly MAINTENANCE_LOCK=/run/qemu-g11-network.lock

fail() {
    printf 'qemu-g11-vlan-bridge: %s\n' "$*" >&2
    exit 1
}

trusted_path() {
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

safe_ifname() {
    local name="$1"
    [[ -n "$name" && ${#name} -le 15 \
        && "$name" =~ ^[[:alnum:]_][[:alnum:]_.-]*$ \
        && "$name" != . && "$name" != .. ]]
}

load_config() {
    local line key value config_dir
    local -A seen=()

    config_dir="$(dirname -- "$CONFIG")"
    trusted_path "$config_dir" dir || fail "untrusted config directory"
    trusted_path "$CONFIG" file || fail "untrusted config"
    BRIDGE=""
    UPLINK=""
    ALLOWED_VLANS=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" =~ ^([A-Z_]+)=([^[:space:]]+)$ ]] \
            || fail "malformed config line"
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        [[ -z "${seen[$key]:-}" ]] || fail "duplicate config key $key"
        seen[$key]=1
        case "$key" in
            VERSION) [[ "$value" == 1 ]] || fail "unsupported config version" ;;
            BRIDGE) BRIDGE="$value" ;;
            UPLINK) UPLINK="$value" ;;
            ALLOWED_UID|ALLOWED_GID)
                [[ "$value" =~ ^[0-9]+$ ]] || fail "invalid $key"
                ;;
            ALLOWED_VLANS)
                [[ "$value" =~ ^[0-9,-]+$ ]] || fail "invalid VLAN allowlist"
                ALLOWED_VLANS="$value"
                ;;
            *) fail "unknown config key $key" ;;
        esac
    done <"$CONFIG"
    for key in VERSION BRIDGE UPLINK ALLOWED_UID ALLOWED_GID ALLOWED_VLANS; do
        [[ "${seen[$key]:-}" == 1 ]] || fail "missing config key $key"
    done
    [[ "$BRIDGE" == br0 ]] || fail "VLAN-aware bridge must be br0"
    safe_ifname "$BRIDGE" && safe_ifname "$UPLINK" \
        || fail "unsafe bridge/uplink name"
    [[ "$UPLINK" != "$BRIDGE" && "$UPLINK" != lo \
        && "$UPLINK" != tap* && "$UPLINK" != vnet* \
        && "$UPLINK" != g11t* && "$UPLINK" != svtap* ]] \
        || fail "invalid physical uplink"
}

bridge_and_uplink_exist() {
    local bridge_details uplink_details

    bridge_details="$(ip -d -o link show dev "$BRIDGE" 2>/dev/null)" || return 1
    [[ "$bridge_details" =~ [[:space:]]bridge[[:space:]]+forward_delay[[:space:]] ]] \
        || return 1
    uplink_details="$(ip -d -o link show dev "$UPLINK" 2>/dev/null)" || return 1
    [[ " $uplink_details " == *" master $BRIDGE "* ]]
}

port_has_native_vid1() {
    local dev="$1"

    bridge vlan show dev "$dev" 2>/dev/null | awk -v dev="$dev" '
        NR == 1 { next }
        {
            if ($1 == dev) { vid=$2; start=3 } else { vid=$1; start=2 }
            if (vid != "1") next
            pvid=untagged=0
            for (i=start; i<=NF; i++) {
                if ($i == "PVID") pvid=1
                if ($i == "Untagged") untagged=1
            }
            if (pvid && untagged) ok=1
        }
        END { exit(ok ? 0 : 1) }
    '
}

port_has_vid1() {
    local dev="$1"

    bridge vlan show dev "$dev" 2>/dev/null | awk -v dev="$dev" '
        NR == 1 { next }
        {
            if ($1 == dev) vid=$2; else vid=$1
            if (vid == "1") found=1
        }
        END { exit(found ? 0 : 1) }
    '
}

uplink_has_native_conflict() {
    bridge vlan show dev "$UPLINK" 2>/dev/null | awk -v dev="$UPLINK" '
        NR == 1 { next }
        {
            if ($1 == dev) { vid=$2; start=3 } else { vid=$1; start=2 }
            if (vid == "1") next
            for (i=start; i<=NF; i++)
                if ($i == "PVID" || $i == "Untagged") bad=1
        }
        END { exit(bad ? 0 : 1) }
    '
}

check_topology() {
    local details

    bridge_and_uplink_exist || fail "$UPLINK is not a port of $BRIDGE"
    details="$(ip -d -o link show dev "$BRIDGE")"
    [[ "$details" =~ [[:space:]]vlan_filtering[[:space:]]+1([[:space:]]|$) ]] \
        || fail "$BRIDGE vlan_filtering is disabled"
    port_has_native_vid1 "$UPLINK" || fail "$UPLINK lacks native VID 1"
    port_has_native_vid1 "$BRIDGE" || fail "$BRIDGE self lacks native VID 1"
}

ensure_topology() {
    bridge_and_uplink_exist || fail "$UPLINK is not a port of $BRIDGE"
    uplink_has_native_conflict \
        && fail "$UPLINK has a non-VID1 native/PVID conflict"
    ip link set dev "$BRIDGE" type bridge \
        vlan_filtering 1 vlan_default_pvid 1 vlan_protocol 802.1Q
    if ! port_has_native_vid1 "$UPLINK"; then
        ! port_has_vid1 "$UPLINK" \
            || fail "$UPLINK has VID 1 with unsafe flags"
        bridge vlan add dev "$UPLINK" vid 1 pvid untagged
    fi
    if ! port_has_native_vid1 "$BRIDGE"; then
        ! port_has_vid1 "$BRIDGE" \
            || fail "$BRIDGE self has VID 1 with unsafe flags"
        bridge vlan add dev "$BRIDGE" vid 1 pvid untagged self
    fi
    check_topology
}

acquire_lock() {
    local parent before after

    parent=${LOCK%/*}
    trusted_path "$parent" dir || fail "untrusted lock directory"
    if [[ ! -e "$LOCK" ]]; then
        ( set -o noclobber; umask 077; : >"$LOCK" ) 2>/dev/null || true
    fi
    trusted_path "$LOCK" file || fail "untrusted VLAN lock"
    before="$(stat -c '%d:%i' -- "$LOCK")"
    exec 9>>"$LOCK"
    after="$(stat -Lc '%d:%i' -- /proc/self/fd/9)"
    [[ "$before" == "$after" ]] || fail "VLAN lock changed while opening"
    flock -x -w 10 9 || fail "timed out waiting for VLAN lock"
}

acquire_maintenance_lock() {
    local parent before after

    parent=${MAINTENANCE_LOCK%/*}
    trusted_path "$parent" dir || fail "untrusted maintenance lock directory"
    trusted_path "$MAINTENANCE_LOCK" file \
        || fail "maintenance lock missing; rerun setup-bridge.sh"
    before="$(stat -c '%d:%i' -- "$MAINTENANCE_LOCK")"
    exec 8<"$MAINTENANCE_LOCK"
    after="$(stat -Lc '%d:%i' -- /proc/self/fd/8)"
    [[ "$before" == "$after" ]] || fail "maintenance lock changed while opening"
    flock -s -w 10 8 || fail "host network maintenance is active"
}

[[ "$(id -u)" == 0 ]] || fail "must run as root"
[[ $# == 1 ]] || fail "usage: $0 ensure|check"
acquire_maintenance_lock
acquire_lock
load_config
case "$1" in
    ensure) ensure_topology ;;
    check) check_topology ;;
    *) fail "usage: $0 ensure|check" ;;
esac

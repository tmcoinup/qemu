#!/usr/bin/env bash
# Isolated integration test for the privileged G-11 access-VLAN TAP helper.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER_SOURCE="$REPO_ROOT/deploy/scripts/host-vlan-tap.sh"
DOWN_SOURCE="$REPO_ROOT/deploy/scripts/host-vlan-down.sh"
RUNTIME_SOURCE="$REPO_ROOT/deploy/lib/vlan-runtime.sh"

[[ -x "$HELPER_SOURCE" && -x "$DOWN_SOURCE" ]] || {
    echo "FAIL: G-11 VLAN helper assets are missing" >&2
    exit 1
}
instance_fields="$(awk '
    /^write_state\(\)/ { in_function=1 }
    in_function && /"INSTANCE=\$instance"/ { count++ }
    in_function && /^}/ { print count + 0; exit }
' "$HELPER_SOURCE")"
[[ "$instance_fields" == 1 ]] || {
    echo "FAIL: VLAN state writer does not emit exactly one INSTANCE field" >&2
    exit 1
}
grep -Fq '/run/qemu-g11-vlan' "$RUNTIME_SOURCE" || {
    echo "FAIL: runtime cleanup has no state-only crash hint" >&2
    exit 1
}
if ! command -v unshare >/dev/null 2>&1 || ! unshare -Urnm true 2>/dev/null; then
    echo "SKIP: unprivileged user/network/mount namespaces are unavailable"
    exit 0
fi

# shellcheck disable=SC2016
unshare -Urnm bash -euo pipefail -c '
    helper_source=$1
    down_source=$2
    helper=/usr/local/libexec/qemu-g11-vlan-tap
    down=/usr/local/libexec/qemu-g11-vlan-down

    fail() { echo "FAIL: $*" >&2; exit 1; }
    assert_access() {
        local dev=$1 vid=$2 output
        output="$(bridge vlan show dev "$dev")"
        grep -Eq "(^|[[:space:]])${vid}[[:space:]]+PVID[[:space:]]+Egress[[:space:]]+Untagged" \
            <<<"$output" || fail "$dev is not access VLAN $vid"
        [[ "$(awk -v dev="$dev" '"'"'
            NR > 1 {
                token = ($1 == dev) ? $2 : $1
                if (token ~ /^[0-9]+(-[0-9]+)?$/) count++
            }
            END { print count + 0 }
        '"'"' <<<"$output")" == 1 ]] || fail "$dev has extra VLAN membership"
    }
    assert_tagged() {
        local dev=$1 vid=$2 line
        line="$(bridge vlan show dev "$dev" | awk -v wanted="$vid" '"'"'
            NR > 1 {
                token = ($1 ~ /^[0-9]/) ? $1 : $2
                if (token == wanted) print
            }
        '"'"')"
        [[ -n "$line" ]] || fail "$dev lacks tagged VLAN $vid"
        ! grep -Eq "PVID|Egress|Untagged" <<<"$line" \
            || fail "$dev business VLAN $vid has native flags"
    }

    mount --make-rprivate /
    mount -t sysfs sysfs /sys
    mount -t tmpfs -o mode=0755 tmpfs /etc/qemu
    mount -t tmpfs -o mode=0755 tmpfs /usr/local/libexec
    mount -t tmpfs -o mode=0755 tmpfs /run
    install -o root -g root -m 0644 /dev/null /run/qemu-g11-network.lock
    install -o root -g root -m 0755 "$helper_source" "$helper"
    install -o root -g root -m 0755 "$down_source" "$down"
    printf "%s\n" \
        VERSION=1 BRIDGE=br0 UPLINK=enp5s0 \
        ALLOWED_UID=0 ALLOWED_GID=0 ALLOWED_VLANS=1,11,20,70 \
        >/etc/qemu/g11-vlan.conf
    chmod 0644 /etc/qemu/g11-vlan.conf

    ip link add enp5s0 type dummy
    ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 1
    ip link set enp5s0 master br0
    ip link set enp5s0 up
    ip link set br0 up

    [[ "$("$helper" check 1 11)" == g11t1 ]] || fail "check output mismatch"
    [[ ! -e /run/qemu-g11-vlan.lock && ! -e /run/qemu-g11-vlan ]] \
        || fail "read-only check created runtime state"
    if "$helper" check 1 12 >/dev/null 2>&1; then
        fail "VID outside ALLOWED_VLANS was accepted"
    fi

    [[ "$("$helper" prepare 1 11)" == g11t1 ]] || fail "prepare VLAN 11 failed"
    [[ "$("$helper" prepare 2 20)" == g11t2 ]] || fail "prepare VLAN 20 failed"
    assert_access g11t1 11
    assert_access g11t2 20
    assert_tagged enp5s0 11
    assert_tagged enp5s0 20
    [[ "$("$helper" prepare 1 11)" == g11t1 ]] || fail "prepare is not idempotent"
    if "$helper" prepare 1 20 >/dev/null 2>&1; then
        fail "same instance changed VLAN without cleanup"
    fi

    # State-only crash recovery must reconstruct and later clean the instance.
    [[ "$("$helper" prepare 7 70)" == g11t7 ]] || fail "prepare VLAN 70 failed"
    ip tuntap del dev g11t7 mode tap
    [[ "$("$helper" prepare 7 70)" == g11t7 ]] \
        || fail "state-only recovery failed"

    # Tightening policy or preserving a historical owner must never strand a
    # valid root-owned state during cleanup.
    sed -i "s/^ALLOWED_UID=.*/ALLOWED_UID=1/; s/^ALLOWED_GID=.*/ALLOWED_GID=1/; s/^ALLOWED_VLANS=.*/ALLOWED_VLANS=1,11/" \
        /etc/qemu/g11-vlan.conf
    "$helper" cleanup-instance 7
    ! ip link show g11t7 >/dev/null 2>&1 || fail "owner/policy change stranded g11t7"
    "$helper" cleanup-instance 2
    ! ip link show g11t2 >/dev/null 2>&1 || fail "allowlist tightening blocked cleanup"

    "$down" g11t1
    ! ip link show g11t1 >/dev/null 2>&1 || fail "downscript did not clean g11t1"
    [[ ! -e /run/qemu-g11-vlan ]] || fail "empty VLAN state directory was retained"
    if "$down" tap0 >/dev/null 2>&1; then
        fail "downscript accepted an unrelated interface"
    fi
' bash "$HELPER_SOURCE" "$DOWN_SOURCE"

echo "PASS: G-11 VLAN helper access/tagged topology, allowlist and crash cleanup"

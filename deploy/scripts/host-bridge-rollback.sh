#!/usr/bin/env bash
# Root-owned rollback helper installed by setup-bridge.sh.
# It only restores G-11's single managed netplan override; user netplan files
# are never rewritten or removed.
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

STATE_ROOT=/var/lib/qemu-g11-network/transactions
EARLY_TARGET=/etc/netplan/00-qemu-g11-uplink.yaml
TARGET=/etc/netplan/99-qemu-g11-br0.yaml
LOCK=/run/qemu-g11-network-rollback.lock

fail() {
    printf 'qemu-g11-network-rollback: %s\n' "$*" >&2
    exit 1
}

[[ "$(id -u)" == 0 ]] || fail "must run as root"
exec 9>"$LOCK"
flock -x 9
[[ $# == 1 ]] || fail "expected one transaction id"
txn=$1
[[ "$txn" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || fail "invalid transaction id"
state_dir="$STATE_ROOT/$txn"
[[ -d "$state_dir" && ! -L "$state_dir" ]] || fail "invalid transaction directory"
[[ "$(stat -c '%u' -- "$state_dir")" == 0 ]] || fail "transaction is not root-owned"
mode="$(stat -c '%a' -- "$state_dir")"
[[ "$mode" =~ ^[0-7]{3,4}$ ]] || fail "invalid transaction mode"
(( (8#$mode & 8#077) == 0 )) || fail "transaction permissions are too broad"

[[ ! -e "$state_dir/committed" ]] || exit 0
[[ ! -e "$state_dir/rolled-back" ]] || exit 0

# This marker is written while holding the same lock used by setup's commit.
# From this point onward the transaction can never be committed, even if a
# later validation or `netplan apply` step fails and systemd retries us.
touch "$state_dir/rollback-started"
rollback_exit_guard() {
    local rc=$?

    trap - EXIT
    if (( rc != 0 )); then
        touch "$state_dir/rollback-failed" 2>/dev/null || true
        logger -t qemu-g11-network \
            "rollback attempt failed for bridge transaction $txn" \
            2>/dev/null || true
    fi
    exit "$rc"
}
trap rollback_exit_guard EXIT

version="$(sed -n 's/^VERSION=//p' "$state_dir/manifest" 2>/dev/null || true)"
had_early="$(sed -n 's/^HAD_EARLY=//p' "$state_dir/manifest" 2>/dev/null || true)"
had_target="$(sed -n 's/^HAD_TARGET=//p' "$state_dir/manifest" 2>/dev/null || true)"
recovery_early="$(sed -n 's/^RECOVERY_EARLY=//p' "$state_dir/manifest" 2>/dev/null || true)"
: "${recovery_early:=0}"
[[ "$version" == 1 ]] || fail "invalid transaction version"
[[ "$had_early" == 0 || "$had_early" == 1 ]] \
    || fail "invalid early transaction manifest"
[[ "$had_target" == 0 || "$had_target" == 1 ]] \
    || fail "invalid transaction manifest"
[[ "$recovery_early" == 0 || "$recovery_early" == 1 ]] \
    || fail "invalid recovery transaction manifest"
case "$had_early" in
    0)
        if [[ "$recovery_early" == 1 ]]; then
            [[ -f "$state_dir/recovery-early.yaml" \
                && ! -L "$state_dir/recovery-early.yaml" ]] \
                || fail "missing recovery early config"
            install -o root -g root -m 0600 \
                "$state_dir/recovery-early.yaml" "$EARLY_TARGET"
        else
            rm -f -- "$EARLY_TARGET"
        fi
        ;;
    1)
        [[ "$recovery_early" == 0 ]] \
            || fail "recovery early conflicts with a previous managed file"
        [[ -f "$state_dir/previous-early.yaml" \
            && ! -L "$state_dir/previous-early.yaml" ]] \
            || fail "missing previous early config"
        install -o root -g root -m 0600 \
            "$state_dir/previous-early.yaml" "$EARLY_TARGET"
        ;;
    *)
        fail "invalid early transaction manifest"
        ;;
esac
case "$had_target" in
    0)
        rm -f -- "$TARGET"
        ;;
    1)
        [[ -f "$state_dir/previous.yaml" && ! -L "$state_dir/previous.yaml" ]] \
            || fail "missing previous managed config"
        install -o root -g root -m 0600 \
            "$state_dir/previous.yaml" "$TARGET"
        ;;
    *)
        fail "invalid transaction manifest"
        ;;
esac

netplan generate
netplan apply
touch "$state_dir/rolled-back"
rm -f -- "$state_dir/rollback-failed"
trap - EXIT
logger -t qemu-g11-network \
    "rolled back unconfirmed bridge transaction $txn" 2>/dev/null || true

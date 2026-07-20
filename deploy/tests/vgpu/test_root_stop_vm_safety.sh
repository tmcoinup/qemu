#!/usr/bin/env bash
# Exercise the vGPU stop implementation and stale-state cleanup without touching
# a real VM or any mdev sysfs device.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
STOP_VM="$REPO_ROOT/deploy/stop-vm.sh"
TMP_DIR="$(mktemp -d)"
VM_ID=$((980000000 + $$ % 10000000))

cleanup() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect_invalid_id() {
    local value=$1

    if VM_ROOT="$TMP_DIR" "$STOP_VM" "$value" --force \
            >"$TMP_DIR/invalid.out" 2>&1; then
        fail "invalid VM id was accepted: $value"
    fi
    grep -Fq 'VM_ID 必须是正整数' "$TMP_DIR/invalid.out" \
        || fail "invalid VM id did not get the validation error: $value"
}

[[ -x "$STOP_VM" ]] || fail "stop-vm.sh is missing or not executable"
mkdir -p "$TMP_DIR/run"

# These values used to pass the shell glob parser and could expand the pgrep /
# pkill regex or runtime paths beyond one VM.
expect_invalid_id '1.*'
expect_invalid_id '1/../../tmp/x'
expect_invalid_id 0

# A non-running high VM with ordinary stale runtime state is safe to clean.  Its
# UUID does not exist in sysfs, so this path never invokes sudo or writes sysfs.
printf '%s\n' '00000000-0000-0000-0000-999999999999' \
    >"$TMP_DIR/run/vm${VM_ID}.mdev"
touch "$TMP_DIR/run/vm${VM_ID}.pid" "$TMP_DIR/run/vm${VM_ID}.qmp" \
    "$TMP_DIR/run/vm${VM_ID}.mon"
VM_ROOT="$TMP_DIR" VM_RUN_DIR="$TMP_DIR/run" \
    VM_STORAGE_COMPAT_FALLBACK=1 \
    "$STOP_VM" "$VM_ID" >"$TMP_DIR/cleanup.out"
grep -Fq "no qemu-system for vm${VM_ID}" "$TMP_DIR/cleanup.out" \
    || fail "non-running VM did not take the stale cleanup path"
[[ ! -e "$TMP_DIR/run/vm${VM_ID}.mdev" ]] \
    || fail "stale per-VM mdev record was not removed"
[[ ! -e "$TMP_DIR/run/vm${VM_ID}.pid" &&
   ! -e "$TMP_DIR/run/vm${VM_ID}.qmp" &&
   ! -e "$TMP_DIR/run/vm${VM_ID}.mon" ]] \
    || fail "stale runtime files were not removed"

# New instance bundles use generic runtime names inside the VM directory.
CANONICAL_ID=$((VM_ID + 1))
mkdir -p "$TMP_DIR/vm${CANONICAL_ID}/run" \
    "$TMP_DIR/vm${CANONICAL_ID}/tpm/state"
printf '%s\n' '00000000-0000-0000-0000-999999999998' \
    >"$TMP_DIR/vm${CANONICAL_ID}/run/mdev.uuid"
touch "$TMP_DIR/vm${CANONICAL_ID}/run/qemu.pid" \
    "$TMP_DIR/vm${CANONICAL_ID}/run/qmp.sock" \
    "$TMP_DIR/vm${CANONICAL_ID}/run/monitor.sock"
printf '%s\n' 999999999 >"$TMP_DIR/vm${CANONICAL_ID}/run/swtpm.pid"
touch "$TMP_DIR/vm${CANONICAL_ID}/tpm/state/tpm2-00.permall"
python3 - "$TMP_DIR/vm${CANONICAL_ID}/run/swtpm.sock" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(sys.argv[1])
sock.close()
PY
VM_ROOT="$TMP_DIR" "$STOP_VM" "$CANONICAL_ID" >"$TMP_DIR/canonical-cleanup.out"
[[ -z "$(find "$TMP_DIR/vm${CANONICAL_ID}/run" -mindepth 1 -print -quit)" ]] \
    || fail "canonical per-VM runtime files were not removed"
[[ -e "$TMP_DIR/vm${CANONICAL_ID}/tpm/state/tpm2-00.permall" ]] \
    || fail "persistent TPM state was removed during stale runtime cleanup"

# Guard the central invariant statically: cleanup must never enumerate every
# host mdev and remove them as a group.
if grep -Eq 'for .*\/sys\/bus\/mdev\/devices\/\*' "$STOP_VM"; then
    fail "stop-vm.sh still contains an all-mdev cleanup loop"
fi
grep -Fq 'mdev_release "$MDEV_UUID"' "$STOP_VM" \
    || fail "stop-vm.sh bypasses the shared vGPU host lock during mdev release"
if grep -Eq "echo[[:space:]]+1[[:space:]]*>.*mdev_dir/remove" "$STOP_VM"; then
    fail "stop-vm.sh still writes mdev/remove directly"
fi

echo "PASS: root stop-vm validates VM ids and scopes stale cleanup per VM"

#!/usr/bin/env bash
# G-11 disk-space guard regression test.  It only reads the test filesystem.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# shellcheck source=../../lib/disk-headroom.sh
source "$REPO_ROOT/deploy/lib/disk-headroom.sh"

fixed=$(disk_headroom_required_free_bytes $((100 * 1024 * 1024 * 1024)) 16 5)
[[ "$fixed" == $((16 * 1024 * 1024 * 1024)) ]] ||
    fail "fixed 16 GiB threshold was not selected"
percent=$(disk_headroom_required_free_bytes $((1000 * 1024 * 1024 * 1024)) 16 5)
[[ "$percent" == $((50 * 1024 * 1024 * 1024)) ]] ||
    fail "5 percent threshold was not selected"

DISK_GUARD=1
DISK_FORCE=0
DISK_MIN_FREE_GIB=1
DISK_MIN_FREE_PERCENT=100
DISK_WARN_FREE_PERCENT=100
if disk_headroom_guard "$TMP_DIR/disk.qcow2" >"$TMP_DIR/reject.out" 2>&1; then
    fail "100 percent free-space threshold did not reject"
fi
grep -Fq 'qcow2 所在文件系统空间不足' "$TMP_DIR/reject.out" ||
    fail "rejection did not explain the ENOSPC risk"

DISK_FORCE=1
disk_headroom_guard "$TMP_DIR/disk.qcow2" >"$TMP_DIR/force.out" 2>&1 ||
    fail "DISK_FORCE=1 did not bypass the guard"
grep -Fq '显式越过满盘/ENOSPC 风险' "$TMP_DIR/force.out" ||
    fail "forced bypass did not print a warning"

grep -Fq 'source "$here/lib/disk-headroom.sh"' \
    "$REPO_ROOT/deploy/scripts/start-vm.sh" || fail "launcher does not load disk guard"
grep -Fq 'disk_headroom_guard "$DISK_PATH"' \
    "$REPO_ROOT/deploy/scripts/start-vm.sh" || fail "launcher does not enforce disk guard"
grep -Fq 'disk_headroom_guard "$TARGET"' \
    "$REPO_ROOT/deploy/scripts/create-disk.sh" || fail "disk creator does not enforce guard"
grep -Fq 'discard=unmap,detect-zeroes=unmap' \
    "$REPO_ROOT/deploy/scripts/start-vm.sh" || fail "zero detection is not enabled"

echo "PASS: disk headroom guard and zero-discard integration"

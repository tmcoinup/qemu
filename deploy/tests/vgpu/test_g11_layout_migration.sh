#!/usr/bin/env bash
# Verify the one-time G-11 namespace migration entirely below a temporary
# IMAGE_ROOT.  In particular, V-11 numeric directories must remain untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MIGRATE="$REPO_ROOT/deploy/migrate-g11-layout.sh"
QEMU_IMG="$REPO_ROOT/build/qemu-img"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img || true)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_migrate() {
    local image_root=$1 vm_root=$2
    shift 2
    IMAGE_ROOT="$image_root" VM_ROOT="$vm_root" QEMU_IMG="$QEMU_IMG" \
        "$MIGRATE" "$@"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
[[ -n "$QEMU_IMG" && -x "$QEMU_IMG" ]] || fail "qemu-img is required"
command -v lsof >/dev/null 2>&1 || fail "lsof is required"

IMAGE_ROOT="$TMP_DIR/images"
OLD_ROOT="$IMAGE_ROOT/vms"
NEW_ROOT="$OLD_ROOT/G-11"
OLD_VM="$OLD_ROOT/instances/vm1"
V11_DIR="$OLD_ROOT/2"

mkdir -p "$OLD_VM/run" "$OLD_VM/log" "$OLD_VM/tpm/state" \
    "$OLD_VM/backups/disks" "$OLD_ROOT/bases" "$OLD_ROOT/assets" \
    "$OLD_ROOT/run" "$V11_DIR"
printf 'vm-config\n' >"$OLD_VM/vm.conf"
printf 'vars\n' >"$OLD_VM/nvram.fd"
printf 'v11-sentinel\n' >"$V11_DIR/profile"
printf 'asset\n' >"$OLD_ROOT/assets/README"
printf 'history\n' >"$OLD_ROOT/run/storage-migration-test.tsv"
touch "$OLD_ROOT/run/.storage.lock" "$OLD_ROOT/run/vm1.start.lock" \
    "$OLD_ROOT/run/vm1.disk.lock"
"$QEMU_IMG" create -q -f qcow2 "$OLD_VM/disk.qcow2" 1M
"$QEMU_IMG" create -q -f qcow2 "$OLD_ROOT/bases/win10-base.qcow2" 1M
disk_inode=$(stat -c %i "$OLD_VM/disk.qcow2")
base_inode=$(stat -c %i "$OLD_ROOT/bases/win10-base.qcow2")

run_migrate "$IMAGE_ROOT" "$NEW_ROOT" --check \
    >"$TMP_DIR/check.out" 2>"$TMP_DIR/check.err"
grep -Fq 'CHECK OK: no files changed' "$TMP_DIR/check.out" \
    || fail "--check did not report read-only success"
grep -Fq "$V11_DIR" "$TMP_DIR/check.out" \
    || fail "--check did not identify the V-11 numeric directory"
[[ -f "$OLD_VM/disk.qcow2" && ! -e "$NEW_ROOT/vm1" ]] \
    || fail "--check changed the G-11 tree"

run_migrate "$IMAGE_ROOT" "$NEW_ROOT" --apply \
    >"$TMP_DIR/apply.out" 2>"$TMP_DIR/apply.err"
grep -Fq 'APPLY OK' "$TMP_DIR/apply.out" \
    || fail "--apply did not report success"
[[ "$(stat -c %i "$NEW_ROOT/vm1/disk.qcow2")" == "$disk_inode" ]] \
    || fail "VM directory rename did not preserve the disk inode"
[[ "$(stat -c %i "$NEW_ROOT/shared/bases/win10-base.qcow2")" == "$base_inode" ]] \
    || fail "base directory rename did not preserve the image inode"
[[ -f "$NEW_ROOT/shared/assets/README" ]] \
    || fail "shared assets were not moved"
[[ -f "$NEW_ROOT/control/history/pre-g11-namespace/storage-migration-test.tsv" ]] \
    || fail "old migration history was not preserved"
[[ -f "$V11_DIR/profile" ]] && grep -Fxq 'v11-sentinel' "$V11_DIR/profile" \
    || fail "V-11 numeric directory was changed"
[[ ! -e "$OLD_ROOT/instances" && ! -e "$OLD_ROOT/bases" &&
   ! -e "$OLD_ROOT/assets" && ! -e "$OLD_ROOT/run" ]] \
    || fail "empty pre-namespace G-11 directories were left behind"

# Re-applying after the atomic rename must be harmless.
run_migrate "$IMAGE_ROOT" "$NEW_ROOT" --apply \
    >"$TMP_DIR/idempotent.out" 2>"$TMP_DIR/idempotent.err"
grep -Fq 'APPLY OK' "$TMP_DIR/idempotent.out" \
    || fail "second apply was not idempotent"
[[ -f "$V11_DIR/profile" && -f "$NEW_ROOT/vm1/disk.qcow2" ]] \
    || fail "second apply changed migrated or V-11 data"

# A V-11 overlay that records an old G-11 absolute backing path must block the
# rename.  Merely excluding the numeric directory from the move set is not
# enough to preserve that chain.
DEPEND_IMAGE_ROOT="$TMP_DIR/dependent/images"
DEPEND_OLD_ROOT="$DEPEND_IMAGE_ROOT/vms"
DEPEND_NEW_ROOT="$DEPEND_OLD_ROOT/G-11"
mkdir -p "$DEPEND_OLD_ROOT/bases" "$DEPEND_OLD_ROOT/2"
"$QEMU_IMG" create -q -f qcow2 \
    "$DEPEND_OLD_ROOT/bases/win10-base.qcow2" 1M
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$DEPEND_OLD_ROOT/bases/win10-base.qcow2" \
    "$DEPEND_OLD_ROOT/2/disk.qcow2"
if run_migrate "$DEPEND_IMAGE_ROOT" "$DEPEND_NEW_ROOT" --check \
        >"$TMP_DIR/dependent.out" 2>"$TMP_DIR/dependent.err"; then
    fail "migration accepted a V-11 overlay depending on a moved G-11 base"
fi
grep -Fq 'outside qcow2 chain depends on a planned file' \
    "$TMP_DIR/dependent.err" \
    || fail "dependent V-11 overlay refusal was not clear"
[[ -f "$DEPEND_OLD_ROOT/bases/win10-base.qcow2" &&
   -f "$DEPEND_OLD_ROOT/2/disk.qcow2" &&
   ! -e "$DEPEND_NEW_ROOT/shared/bases" ]] \
    || fail "blocked dependency check changed data"

echo "PASS: G-11 namespace migration is atomic, idempotent and V-11-safe"

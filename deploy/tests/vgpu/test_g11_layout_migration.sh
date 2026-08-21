#!/usr/bin/env bash
# Verify the one-time migration from both historical G-11 layouts into numeric
# VM directories below a temporary VMS root.  Existing V-11 data must never be
# overwritten or merged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MIGRATE="$REPO_ROOT/deploy/scripts/migrate-g11-layout.sh"
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
TARGET_ROOT="$IMAGE_ROOT/vms"
NAMESPACED_ROOT="$TARGET_ROOT/G-11"
CURRENT_VM="$NAMESPACED_ROOT/vm1"
LEGACY_VM="$TARGET_ROOT/instances/vm3"
V11_DIR="$TARGET_ROOT/2"

mkdir -p "$CURRENT_VM/run" "$CURRENT_VM/log" "$CURRENT_VM/tpm/state" \
    "$LEGACY_VM/run" "$LEGACY_VM/log" \
    "$NAMESPACED_ROOT/shared/bases" "$NAMESPACED_ROOT/shared/assets" \
    "$NAMESPACED_ROOT/control" "$TARGET_ROOT/run" "$V11_DIR"
printf 'current-config\n' >"$CURRENT_VM/vm.conf"
printf 'legacy-config\n' >"$LEGACY_VM/vm.conf"
printf 'vars\n' >"$CURRENT_VM/nvram.fd"
printf 'v11-sentinel\n' >"$V11_DIR/profile"
printf 'asset\n' >"$NAMESPACED_ROOT/shared/assets/README"
printf 'history\n' >"$TARGET_ROOT/run/storage-migration-test.tsv"
touch "$NAMESPACED_ROOT/control/.storage.lock" \
    "$NAMESPACED_ROOT/control/vm1.start.lock" \
    "$NAMESPACED_ROOT/control/vm1.disk.lock" \
    "$NAMESPACED_ROOT/control/vm1.tpm.lock" \
    "$TARGET_ROOT/run/.storage.lock" "$TARGET_ROOT/run/vm3.start.lock"
"$QEMU_IMG" create -q -f qcow2 "$CURRENT_VM/disk.qcow2" 1M
"$QEMU_IMG" create -q -f qcow2 "$LEGACY_VM/disk.qcow2" 1M
"$QEMU_IMG" create -q -f qcow2 \
    "$NAMESPACED_ROOT/shared/bases/win10-base.qcow2" 1M
current_inode=$(stat -c %i "$CURRENT_VM/disk.qcow2")
legacy_inode=$(stat -c %i "$LEGACY_VM/disk.qcow2")
base_inode=$(stat -c %i \
    "$NAMESPACED_ROOT/shared/bases/win10-base.qcow2")

if ! run_migrate "$IMAGE_ROOT" "$TARGET_ROOT" --check \
        >"$TMP_DIR/check.out" 2>"$TMP_DIR/check.err"; then
    sed -n '1,200p' "$TMP_DIR/check.err" >&2
    fail "--check unexpectedly failed"
fi
grep -Fq 'CHECK OK: no files changed' "$TMP_DIR/check.out" \
    || fail "--check did not report read-only success"
grep -Fq "$V11_DIR" "$TMP_DIR/check.out" \
    || fail "--check did not inventory the existing numeric directory"
[[ -f "$CURRENT_VM/disk.qcow2" && -f "$LEGACY_VM/disk.qcow2" &&
   ! -e "$TARGET_ROOT/1" && ! -e "$TARGET_ROOT/3" ]] \
    || fail "--check changed the G-11 trees"

if ! run_migrate "$IMAGE_ROOT" "$TARGET_ROOT" --apply \
        >"$TMP_DIR/apply.out" 2>"$TMP_DIR/apply.err"; then
    sed -n '1,200p' "$TMP_DIR/apply.err" >&2
    fail "--apply unexpectedly failed"
fi
grep -Fq 'APPLY OK' "$TMP_DIR/apply.out" \
    || fail "--apply did not report success"
[[ "$(stat -c %i "$TARGET_ROOT/1/disk.qcow2")" == "$current_inode" ]] \
    || fail "namespaced VM rename did not preserve the disk inode"
[[ "$(stat -c %i "$TARGET_ROOT/3/disk.qcow2")" == "$legacy_inode" ]] \
    || fail "pre-namespace VM rename did not preserve the disk inode"
[[ "$(stat -c %i "$TARGET_ROOT/_base/win10-base.qcow2")" == \
   "$base_inode" ]] || fail "base rename did not preserve the image inode"
[[ -f "$TARGET_ROOT/shared/assets/README" ]] \
    || fail "shared assets were not moved"
[[ -f "$TARGET_ROOT/control/history/pre-g11-layout/storage-migration-test.tsv" ]] \
    || fail "old migration history was not preserved"
[[ -f "$V11_DIR/profile" ]] && grep -Fxq 'v11-sentinel' "$V11_DIR/profile" \
    || fail "existing V-11 numeric directory was changed"
[[ ! -e "$NAMESPACED_ROOT" && ! -e "$TARGET_ROOT/instances" &&
   ! -e "$TARGET_ROOT/run" ]] \
    || fail "historical G-11 directories were left behind"
for stale_lock in \
    "$TARGET_ROOT/control/vm1.start.lock" \
    "$TARGET_ROOT/control/vm1.disk.lock" \
    "$TARGET_ROOT/control/vm1.tpm.lock" \
    "$TARGET_ROOT/1/run/start.lock" \
    "$TARGET_ROOT/1/run/disk.lock" \
    "$TARGET_ROOT/1/run/tpm.lock"; do
    [[ ! -e "$stale_lock" ]] || fail "migration retained a stale lock: $stale_lock"
done

# Re-applying after the atomic renames must be harmless.
run_migrate "$IMAGE_ROOT" "$TARGET_ROOT" --apply \
    >"$TMP_DIR/idempotent.out" 2>"$TMP_DIR/idempotent.err"
grep -Fq 'APPLY OK' "$TMP_DIR/idempotent.out" \
    || fail "second apply was not idempotent"
[[ -f "$V11_DIR/profile" && -f "$TARGET_ROOT/1/disk.qcow2" &&
   -f "$TARGET_ROOT/3/disk.qcow2" ]] \
    || fail "second apply changed migrated or V-11 data"

# If one historical generation only contains empty shared directory skeletons,
# the real populated generation wins without a false merge or data deletion.
EMPTY_IMAGE_ROOT="$TMP_DIR/empty-shared/images"
EMPTY_TARGET="$EMPTY_IMAGE_ROOT/vms"
EMPTY_NAMESPACE="$EMPTY_TARGET/G-11"
mkdir -p "$EMPTY_NAMESPACE/shared/bases/archive" \
    "$EMPTY_NAMESPACE/shared/assets" "$EMPTY_TARGET/bases/archive" \
    "$EMPTY_TARGET/assets"
"$QEMU_IMG" create -q -f qcow2 \
    "$EMPTY_TARGET/bases/win10-base.qcow2" 1M
printf 'real asset\n' >"$EMPTY_TARGET/assets/aero_arrow.cur"
empty_base_inode=$(stat -c %i "$EMPTY_TARGET/bases/win10-base.qcow2")
run_migrate "$EMPTY_IMAGE_ROOT" "$EMPTY_TARGET" --check \
    >"$TMP_DIR/empty-shared-check.out" 2>"$TMP_DIR/empty-shared-check.err" \
    || fail "empty shared skeleton caused a false migration conflict"
grep -Fq 'verified empty shared skeletons' \
    "$TMP_DIR/empty-shared-check.out" \
    || fail "empty shared skeleton was not reported"
run_migrate "$EMPTY_IMAGE_ROOT" "$EMPTY_TARGET" --apply \
    >"$TMP_DIR/empty-shared-apply.out" 2>"$TMP_DIR/empty-shared-apply.err" \
    || fail "populated pre-namespace shared data did not migrate"
[[ "$(stat -c %i "$EMPTY_TARGET/_base/win10-base.qcow2")" == \
   "$empty_base_inode" &&
   -f "$EMPTY_TARGET/shared/assets/aero_arrow.cur" &&
   ! -e "$EMPTY_NAMESPACE" && ! -e "$EMPTY_TARGET/bases" &&
   ! -e "$EMPTY_TARGET/assets" ]] \
    || fail "empty shared skeleton migration changed or left shared data"

# An outside numeric overlay that records an old absolute backing path blocks
# the rename; merely moving the source directory would break that chain.
DEPEND_IMAGE_ROOT="$TMP_DIR/dependent/images"
DEPEND_TARGET="$DEPEND_IMAGE_ROOT/vms"
DEPEND_NAMESPACE="$DEPEND_TARGET/G-11"
mkdir -p "$DEPEND_NAMESPACE/shared/bases" "$DEPEND_TARGET/2"
"$QEMU_IMG" create -q -f qcow2 \
    "$DEPEND_NAMESPACE/shared/bases/win10-base.qcow2" 1M
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$DEPEND_NAMESPACE/shared/bases/win10-base.qcow2" \
    "$DEPEND_TARGET/2/disk.qcow2"
if run_migrate "$DEPEND_IMAGE_ROOT" "$DEPEND_TARGET" --check \
        >"$TMP_DIR/dependent.out" 2>"$TMP_DIR/dependent.err"; then
    fail "migration accepted an outside overlay depending on a moved base"
fi
grep -Fq 'outside qcow2 chain depends on a planned file' \
    "$TMP_DIR/dependent.err" \
    || fail "dependent outside overlay refusal was not clear"
[[ -f "$DEPEND_NAMESPACE/shared/bases/win10-base.qcow2" &&
   -f "$DEPEND_TARGET/2/disk.qcow2" &&
   ! -e "$DEPEND_TARGET/_base" ]] \
    || fail "blocked dependency check changed data"

# A pre-existing numeric destination (for example V-11) is a hard conflict.
COLLISION_IMAGE_ROOT="$TMP_DIR/collision/images"
COLLISION_TARGET="$COLLISION_IMAGE_ROOT/vms"
COLLISION_SOURCE="$COLLISION_TARGET/G-11/vm4"
mkdir -p "$COLLISION_SOURCE" "$COLLISION_TARGET/4"
printf 'g11\n' >"$COLLISION_SOURCE/vm.conf"
printf 'v11\n' >"$COLLISION_TARGET/4/profile"
if run_migrate "$COLLISION_IMAGE_ROOT" "$COLLISION_TARGET" --check \
        >"$TMP_DIR/collision.out" 2>"$TMP_DIR/collision.err"; then
    fail "migration merged an existing numeric destination"
fi
grep -Fq 'destination already exists' "$TMP_DIR/collision.err" \
    || fail "numeric collision refusal was not clear"
[[ -f "$COLLISION_SOURCE/vm.conf" && -f "$COLLISION_TARGET/4/profile" ]] \
    || fail "blocked numeric collision changed source or destination"

echo "PASS: G-11 layouts migrate atomically to numeric bundles without V-11 merges"

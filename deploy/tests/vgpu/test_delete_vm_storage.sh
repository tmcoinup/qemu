#!/usr/bin/env bash
# Ensure delete-vm removes only one production vGPU instance across both path
# generations and never touches bases or the numeric compatibility workflow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DELETE_VM="$REPO_ROOT/deploy/delete-vm.sh"
QEMU_IMG="$REPO_ROOT/build/qemu-img"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img || true)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
IMAGE_ROOT="$TMP_DIR"
VM_ROOT="$IMAGE_ROOT/vms"
export IMAGE_ROOT VM_ROOT
export QEMU_IMG
# This test deliberately keeps legacy categorized files and flat runtime
# records alongside the canonical bundle.
export VM_STORAGE_COMPAT_FALLBACK=1
VM_ID=$((700000000 + $$ % 10000000))
OTHER_ID=$((VM_ID + 1))
[[ -n "$QEMU_IMG" && -x "$QEMU_IMG" ]] || fail "qemu-img is required"

mkdir -p \
    "$VM_ROOT/legacy/configs" "$VM_ROOT/legacy/disks/archive" \
    "$VM_ROOT/shared/bases" "$VM_ROOT/legacy/nvram/backups" \
    "$VM_ROOT/control" "$VM_ROOT/legacy/log" \
    "$VM_ROOT/vm${VM_ID}/backups/disks" \
    "$VM_ROOT/vm${VM_ID}/backups/nvram" \
    "$VM_ROOT/vm${VM_ID}/log" \
    "$VM_ROOT/vm${VM_ID}/run" "$VM_ROOT/$VM_ID"
touch \
    "$VM_ROOT/vm${VM_ID}/vm.conf" \
    "$VM_ROOT/vm${VM_ID}/nvram.fd" \
    "$VM_ROOT/vm${VM_ID}/backups/nvram/nvram.fd.bak-test" \
    "$VM_ROOT/vm${VM_ID}/log/qemu.log" \
    "$VM_ROOT/vm${VM_ID}/run/monitor-edid.sha256" \
    "$VM_ROOT/legacy/configs/vm${VM_ID}.conf" \
    "$VM_ROOT/legacy/nvram/vm${VM_ID}_VARS.fd" \
    "$VM_ROOT/legacy/nvram/backups/vm${VM_ID}_VARS.fd.bak-test" \
    "$VM_ROOT/vm${VM_ID}_VARS.fd" \
    "$VM_ROOT/legacy/log/vm${VM_ID}.log" \
    "$VM_ROOT/control/vm${VM_ID}.monitor-edid"
for image in \
    "$VM_ROOT/vm${VM_ID}/disk.qcow2" \
    "$VM_ROOT/vm${VM_ID}/backups/disks/disk-old.qcow2" \
    "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" \
    "$VM_ROOT/legacy/disks/archive/win10-vm${VM_ID}.qcow2.bak-test" \
    "$VM_ROOT/win10-vm${VM_ID}.qcow2" \
    "$VM_ROOT/legacy/disks/win10-vm${OTHER_ID}.qcow2" \
    "$VM_ROOT/shared/bases/win10-base.qcow2" \
    "$VM_ROOT/$VM_ID/disk.qcow2"; do
    "$QEMU_IMG" create -q -f qcow2 "$image" 1M
done
printf '00000000-0000-0000-0000-%012d\n' "$VM_ID" \
    >"$VM_ROOT/control/vm${VM_ID}.mdev"

exec {DISK_HOLDER_FD}>"$VM_ROOT/control/vm${VM_ID}.disk.lock"
flock -x "$DISK_HOLDER_FD"
if "$DELETE_VM" "$VM_ID" -y \
    >"$TMP_DIR/locked.out" 2>"$TMP_DIR/locked.err"; then
    fail "delete-vm ignored the per-VM disk lifecycle lock"
fi
exec {DISK_HOLDER_FD}>&-
grep -Fq '磁盘正在创建' "$TMP_DIR/locked.err" \
    || fail "disk-lock refusal was not clear"
[[ -f "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" ]] \
    || fail "disk-lock refusal deleted the VM disk"

rm -f "$VM_ROOT/$VM_ID/disk.qcow2"
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" \
    "$VM_ROOT/$VM_ID/disk.qcow2"
if "$DELETE_VM" "$VM_ID" -y \
    >"$TMP_DIR/dependent.out" 2>"$TMP_DIR/dependent.err"; then
    fail "delete-vm removed a disk used as another overlay's backing"
fi
grep -Fq '依赖待删除磁盘' "$TMP_DIR/dependent.err" \
    || fail "dependent-overlay refusal was not clear"
[[ -f "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" ]] \
    || fail "dependent-overlay refusal deleted the backing disk"
rm -f "$VM_ROOT/$VM_ID/disk.qcow2"
"$QEMU_IMG" create -q -f qcow2 "$VM_ROOT/$VM_ID/disk.qcow2" 1M

SYMLINK_OUTSIDE="$TMP_DIR/symlink-outside"
mkdir -p "$SYMLINK_OUTSIDE"
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" \
    "$SYMLINK_OUTSIDE/dependent.qcow2"
ln -s "$SYMLINK_OUTSIDE/dependent.qcow2" \
    "$VM_ROOT/legacy/disks/dependent-link.qcow2"
if "$DELETE_VM" "$VM_ID" -y \
    >"$TMP_DIR/symlink.out" 2>"$TMP_DIR/symlink.err"; then
    fail "delete-vm ignored a dependent qcow2 file symlink"
fi
grep -Fq '依赖待删除磁盘' "$TMP_DIR/symlink.err" \
    || fail "symlink dependent refusal was not clear"
[[ -f "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" ]] \
    || fail "symlink dependency refusal deleted the backing disk"
rm -f "$VM_ROOT/legacy/disks/dependent-link.qcow2" "$SYMLINK_OUTSIDE/dependent.qcow2"

DIR_LINK_OUTSIDE="$TMP_DIR/dir-link-outside/vm10"
mkdir -p "$DIR_LINK_OUTSIDE"
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" \
    "$DIR_LINK_OUTSIDE/disk.qcow2"
ln -s "$DIR_LINK_OUTSIDE" "$VM_ROOT/10"
if "$DELETE_VM" "$VM_ID" -y \
    >"$TMP_DIR/dir-link.out" 2>"$TMP_DIR/dir-link.err"; then
    fail "delete-vm ignored a dependent below a directory symlink"
fi
grep -Fq '依赖待删除磁盘' "$TMP_DIR/dir-link.err" \
    || fail "directory-symlink dependent refusal was not clear"
[[ -f "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" ]] \
    || fail "directory-symlink refusal deleted the backing disk"
rm -f "$VM_ROOT/10" "$DIR_LINK_OUTSIDE/disk.qcow2"

rm -f "$VM_ROOT/$VM_ID/disk.qcow2"
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "file:$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" \
    "$VM_ROOT/$VM_ID/disk.qcow2"
if "$DELETE_VM" "$VM_ID" -y \
    >"$TMP_DIR/protocol.out" 2>"$TMP_DIR/protocol.err"; then
    fail "delete-vm accepted an unsupported protocol backing reference"
fi
grep -Fq 'unsupported backing reference' "$TMP_DIR/protocol.err" \
    || fail "protocol-backing refusal was not clear"
[[ -f "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" ]] \
    || fail "protocol-backing refusal deleted the backing disk"
rm -f "$VM_ROOT/$VM_ID/disk.qcow2"
"$QEMU_IMG" create -q -f qcow2 "$VM_ROOT/$VM_ID/disk.qcow2" 1M

CHAIN_OUTSIDE="$TMP_DIR/recursive-chain-outside"
mkdir -p "$CHAIN_OUTSIDE"
rm -f "$VM_ROOT/$VM_ID/disk.qcow2"
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" \
    "$CHAIN_OUTSIDE/middle.qcow2"
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$CHAIN_OUTSIDE/middle.qcow2" "$VM_ROOT/$VM_ID/disk.qcow2"
if "$DELETE_VM" "$VM_ID" -y \
    >"$TMP_DIR/recursive.out" 2>"$TMP_DIR/recursive.err"; then
    fail "delete-vm missed a target behind an external middle layer"
fi
grep -Fq 'overlay chain 依赖待删除磁盘' "$TMP_DIR/recursive.err" \
    || fail "recursive-chain refusal was not clear"
[[ -f "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" ]] \
    || fail "recursive-chain refusal deleted the backing disk"
rm -f "$VM_ROOT/$VM_ID/disk.qcow2" "$CHAIN_OUTSIDE/middle.qcow2"
"$QEMU_IMG" create -q -f qcow2 "$VM_ROOT/$VM_ID/disk.qcow2" 1M

"$DELETE_VM" "$VM_ID" -y >"$TMP_DIR/delete.out"

for path in \
    "$VM_ROOT/vm${VM_ID}/vm.conf" \
    "$VM_ROOT/vm${VM_ID}/disk.qcow2" \
    "$VM_ROOT/vm${VM_ID}/backups/disks/disk-old.qcow2" \
    "$VM_ROOT/vm${VM_ID}/nvram.fd" \
    "$VM_ROOT/vm${VM_ID}/backups/nvram/nvram.fd.bak-test" \
    "$VM_ROOT/vm${VM_ID}/log/qemu.log" \
    "$VM_ROOT/vm${VM_ID}/run/monitor-edid.sha256" \
    "$VM_ROOT/legacy/configs/vm${VM_ID}.conf" \
    "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" \
    "$VM_ROOT/legacy/disks/archive/win10-vm${VM_ID}.qcow2.bak-test" \
    "$VM_ROOT/win10-vm${VM_ID}.qcow2" \
    "$VM_ROOT/legacy/nvram/vm${VM_ID}_VARS.fd" \
    "$VM_ROOT/legacy/nvram/backups/vm${VM_ID}_VARS.fd.bak-test" \
    "$VM_ROOT/vm${VM_ID}_VARS.fd" \
    "$VM_ROOT/legacy/log/vm${VM_ID}.log" \
    "$VM_ROOT/control/vm${VM_ID}.monitor-edid" \
    "$VM_ROOT/control/vm${VM_ID}.mdev"; do
    [[ ! -e "$path" ]] || fail "delete left target path: $path"
done
[[ -f "$VM_ROOT/legacy/disks/win10-vm${OTHER_ID}.qcow2" ]] \
    || fail "delete touched another VM"
[[ -f "$VM_ROOT/shared/bases/win10-base.qcow2" ]] || fail "delete touched the base"
[[ -f "$VM_ROOT/$VM_ID/disk.qcow2" ]] \
    || fail "delete touched the numeric compatibility workflow"

UNSAFE_ROOT="$TMP_DIR/unsafe-delete/vms"
UNSAFE_ID=$((OTHER_ID + 1))
UNSAFE_OUTSIDE="$TMP_DIR/unsafe-delete-outside"
mkdir -p "$UNSAFE_ROOT" "$UNSAFE_ROOT/control" "$UNSAFE_OUTSIDE/log"
"$QEMU_IMG" create -q -f qcow2 "$UNSAFE_OUTSIDE/disk.qcow2" 1M
touch "$UNSAFE_OUTSIDE/vm.conf" "$UNSAFE_OUTSIDE/nvram.fd" \
    "$UNSAFE_OUTSIDE/log/qemu.log"
ln -s "$UNSAFE_OUTSIDE" "$UNSAFE_ROOT/vm${UNSAFE_ID}"
if VM_ROOT="$UNSAFE_ROOT" "$DELETE_VM" "$UNSAFE_ID" -y \
        >"$TMP_DIR/unsafe-delete.out" 2>"$TMP_DIR/unsafe-delete.err"; then
    fail "delete-vm followed an instance directory symlink"
fi
grep -Fq '拒绝沿路径删除' "$TMP_DIR/unsafe-delete.err" \
    || fail "unsafe instance delete refusal was not clear"
[[ -f "$UNSAFE_OUTSIDE/disk.qcow2" && -f "$UNSAFE_OUTSIDE/vm.conf" ]] \
    || fail "unsafe instance delete touched external files"

if "$DELETE_VM" '1oops' -y >/dev/null 2>&1; then
    fail "delete-vm accepted an invalid VM id"
fi
if grep -Fq 'for e in /sys/bus/mdev/devices/*' "$DELETE_VM"; then
    fail "delete-vm still contains the all-mdev release loop"
fi

[[ ! -e "$VM_ROOT/vm${VM_ID}" ]] \
    || fail "delete left an empty instance directory"

echo "PASS: delete-vm instance/categorized/legacy scope and mdev isolation"

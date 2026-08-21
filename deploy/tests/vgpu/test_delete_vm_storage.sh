#!/usr/bin/env bash
# Ensure delete-vm removes one complete numeric vGPU bundle, including locks
# and TPM/unknown per-VM files, without touching another VM or shared bases.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DELETE_VM="$REPO_ROOT/deploy/scripts/delete-vm.sh"
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
INSTANCE="$VM_ROOT/$VM_ID"
OTHER_INSTANCE="$VM_ROOT/$OTHER_ID"
[[ -n "$QEMU_IMG" && -x "$QEMU_IMG" ]] || fail "qemu-img is required"

mkdir -p \
    "$VM_ROOT/legacy/configs" "$VM_ROOT/legacy/disks/archive" \
    "$VM_ROOT/_base" "$VM_ROOT/legacy/nvram/backups" \
    "$VM_ROOT/control" "$VM_ROOT/legacy/log" \
    "$INSTANCE/backups/disks" \
    "$INSTANCE/backups/nvram" \
    "$INSTANCE/log" "$INSTANCE/run" "$INSTANCE/tpm/state" \
    "$INSTANCE/packages/SystemNvapiProjection/vm${VM_ID}-fixture" \
    "$OTHER_INSTANCE"
touch \
    "$INSTANCE/vm.conf" \
    "$INSTANCE/nvram.fd" \
    "$INSTANCE/backups/nvram/nvram.fd.bak-test" \
    "$INSTANCE/log/qemu.log" \
    "$INSTANCE/run/monitor-edid.sha256" \
    "$INSTANCE/tpm/state/tpm2-00.permall" \
    "$INSTANCE/custom-per-vm-note" \
    "$INSTANCE/packages/SystemNvapiProjection/vm${VM_ID}-fixture.iso" \
    "$INSTANCE/packages/SystemNvapiProjection/vm${VM_ID}-fixture/Run-As-Administrator.cmd" \
    "$VM_ROOT/legacy/configs/vm${VM_ID}.conf" \
    "$VM_ROOT/legacy/nvram/vm${VM_ID}_VARS.fd" \
    "$VM_ROOT/legacy/nvram/backups/vm${VM_ID}_VARS.fd.bak-test" \
    "$VM_ROOT/vm${VM_ID}_VARS.fd" \
    "$VM_ROOT/legacy/log/vm${VM_ID}.log" \
    "$VM_ROOT/control/vm${VM_ID}.monitor-edid"
for image in \
    "$INSTANCE/disk.qcow2" \
    "$INSTANCE/backups/disks/disk-old.qcow2" \
    "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" \
    "$VM_ROOT/legacy/disks/archive/win10-vm${VM_ID}.qcow2.bak-test" \
    "$VM_ROOT/win10-vm${VM_ID}.qcow2" \
    "$VM_ROOT/legacy/disks/win10-vm${OTHER_ID}.qcow2" \
    "$VM_ROOT/_base/win10-base.qcow2" \
    "$OTHER_INSTANCE/disk.qcow2"; do
    "$QEMU_IMG" create -q -f qcow2 "$image" 1M
done
printf '{"schemaVersion":7}\n' \
    >"$VM_ROOT/_base/win10-base.qcow2.vgpu-portable.json"
printf '{"schema_version":1}\n' \
    >"$VM_ROOT/_base/.win10-base.qcow2.vmate.json"
printf '{"note":"per-VM metadata, not an image"}\n' \
    >"$INSTANCE/disk.qcow2.vgpu-portable.json"
printf '00000000-0000-0000-0000-%012d\n' "$VM_ID" \
    >"$VM_ROOT/control/vm${VM_ID}.mdev"

exec {DISK_HOLDER_FD}>"$INSTANCE/run/disk.lock"
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

exec {TPM_HOLDER_FD}>"$INSTANCE/run/tpm.lock"
flock -x "$TPM_HOLDER_FD"
if "$DELETE_VM" "$VM_ID" -y \
    >"$TMP_DIR/tpm-locked.out" 2>"$TMP_DIR/tpm-locked.err"; then
    fail "delete-vm ignored the per-VM TPM lifecycle lock"
fi
exec {TPM_HOLDER_FD}>&-
grep -Fq 'TPM 生命周期操作仍在进行' "$TMP_DIR/tpm-locked.err" \
    || fail "TPM-lock refusal was not clear"
[[ -f "$INSTANCE/tpm/state/tpm2-00.permall" ]] \
    || fail "TPM-lock refusal deleted persistent TPM state"

rm -f "$OTHER_INSTANCE/disk.qcow2"
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" \
    "$OTHER_INSTANCE/disk.qcow2"
if "$DELETE_VM" "$VM_ID" -y \
    >"$TMP_DIR/dependent.out" 2>"$TMP_DIR/dependent.err"; then
    fail "delete-vm removed a disk used as another overlay's backing"
fi
grep -Fq '依赖待删除磁盘' "$TMP_DIR/dependent.err" \
    || fail "dependent-overlay refusal was not clear"
[[ -f "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" ]] \
    || fail "dependent-overlay refusal deleted the backing disk"
rm -f "$OTHER_INSTANCE/disk.qcow2"
"$QEMU_IMG" create -q -f qcow2 "$OTHER_INSTANCE/disk.qcow2" 1M

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

rm -f "$OTHER_INSTANCE/disk.qcow2"
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "file:$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" \
    "$OTHER_INSTANCE/disk.qcow2"
if "$DELETE_VM" "$VM_ID" -y \
    >"$TMP_DIR/protocol.out" 2>"$TMP_DIR/protocol.err"; then
    fail "delete-vm accepted an unsupported protocol backing reference"
fi
grep -Fq 'unsupported backing reference' "$TMP_DIR/protocol.err" \
    || fail "protocol-backing refusal was not clear"
[[ -f "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" ]] \
    || fail "protocol-backing refusal deleted the backing disk"
rm -f "$OTHER_INSTANCE/disk.qcow2"
"$QEMU_IMG" create -q -f qcow2 "$OTHER_INSTANCE/disk.qcow2" 1M

CHAIN_OUTSIDE="$TMP_DIR/recursive-chain-outside"
mkdir -p "$CHAIN_OUTSIDE"
rm -f "$INSTANCE/disk.qcow2"
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" \
    "$CHAIN_OUTSIDE/middle.qcow2"
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$CHAIN_OUTSIDE/middle.qcow2" "$INSTANCE/disk.qcow2"
if "$DELETE_VM" "$VM_ID" -y \
    >"$TMP_DIR/recursive.out" 2>"$TMP_DIR/recursive.err"; then
    fail "delete-vm missed a target behind an external middle layer"
fi
grep -Fq 'overlay chain 依赖待删除磁盘' "$TMP_DIR/recursive.err" \
    || fail "recursive-chain refusal was not clear"
[[ -f "$VM_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" ]] \
    || fail "recursive-chain refusal deleted the backing disk"
rm -f "$INSTANCE/disk.qcow2" "$CHAIN_OUTSIDE/middle.qcow2"
"$QEMU_IMG" create -q -f qcow2 "$INSTANCE/disk.qcow2" 1M

"$DELETE_VM" "$VM_ID" -y >"$TMP_DIR/delete.out"

for path in \
    "$INSTANCE" \
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
[[ -f "$VM_ROOT/_base/win10-base.qcow2" ]] || fail "delete touched the base"
[[ -f "$VM_ROOT/_base/win10-base.qcow2.vgpu-portable.json" ]] \
    || fail "delete touched the base portable attestation"
[[ -f "$VM_ROOT/_base/.win10-base.qcow2.vmate.json" ]] \
    || fail "delete touched the base type manifest"
[[ -f "$OTHER_INSTANCE/disk.qcow2" ]] \
    || fail "delete touched another numeric VM bundle"

UNSAFE_ROOT="$TMP_DIR/unsafe-delete/vms"
UNSAFE_ID=$((OTHER_ID + 1))
UNSAFE_OUTSIDE="$TMP_DIR/unsafe-delete-outside"
mkdir -p "$UNSAFE_ROOT" "$UNSAFE_ROOT/control" "$UNSAFE_OUTSIDE/log"
"$QEMU_IMG" create -q -f qcow2 "$UNSAFE_OUTSIDE/disk.qcow2" 1M
touch "$UNSAFE_OUTSIDE/vm.conf" "$UNSAFE_OUTSIDE/nvram.fd" \
    "$UNSAFE_OUTSIDE/log/qemu.log"
ln -s "$UNSAFE_OUTSIDE" "$UNSAFE_ROOT/${UNSAFE_ID}"
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

[[ ! -e "$INSTANCE" ]] \
    || fail "delete left an empty instance directory"

echo "PASS: delete-vm instance/categorized/legacy scope and mdev isolation"

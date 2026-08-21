#!/usr/bin/env bash
# Exercise check/apply/idempotence/collision/holder behavior in temporary trees.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MIGRATE="$REPO_ROOT/deploy/migrate-vm-storage.sh"
QEMU_IMG="$REPO_ROOT/build/qemu-img"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img || true)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
[[ -n "$QEMU_IMG" && -x "$QEMU_IMG" ]] || fail "qemu-img is required"
IMAGE_ROOT="$TMP_DIR/images"
VM_ROOT="$IMAGE_ROOT/vms"
export IMAGE_ROOT VM_ROOT
mkdir -p "$VM_ROOT/legacy/configs" "$VM_ROOT/legacy/disks" \
    "$VM_ROOT/legacy/nvram" "$VM_ROOT/legacy/log" \
    "$VM_ROOT/control" "$VM_ROOT/_base"

"$QEMU_IMG" create -q -f qcow2 "$VM_ROOT/win10-vm1.qcow2" 1M
"$QEMU_IMG" create -q -f qcow2 "$VM_ROOT/win10-base.qcow2" 1M
"$QEMU_IMG" create -q -f qcow2 "$VM_ROOT/win10-base.qcow2.old" 1M
printf 'vars\n' >"$VM_ROOT/vm1_VARS.fd"
printf 'vars-backup\n' >"$VM_ROOT/vm1_VARS.fd.bak-display-test"
printf 'vm1-config\n' >"$VM_ROOT/legacy/configs/vm1.conf"
printf 'vm1-log\n' >"$VM_ROOT/legacy/log/vm1.log"
"$QEMU_IMG" create -q -f qcow2 "$VM_ROOT/legacy/disks/win10-vm2.qcow2" 1M
printf 'vm2-vars\n' >"$VM_ROOT/legacy/nvram/vm2_VARS.fd"
printf 'vm2-config\n' >"$VM_ROOT/legacy/configs/vm2.conf"
printf 'vm2-log\n' >"$VM_ROOT/legacy/log/vm2.log"
printf 'iso\n' >"$IMAGE_ROOT/win10-ltsc.iso"
"$QEMU_IMG" create -q -f qcow2 "$VM_ROOT/_base/compat.qcow2" 1M
disk_inode=$(stat -c %i "$VM_ROOT/win10-vm1.qcow2")
categorized_inode=$(stat -c %i "$VM_ROOT/legacy/disks/win10-vm2.qcow2")
compat_base_inode=$(stat -c %i "$VM_ROOT/_base/compat.qcow2")

"$MIGRATE" --check >"$TMP_DIR/check.out"
[[ -f "$VM_ROOT/win10-vm1.qcow2" ]] || fail "--check moved a disk"
grep -Fq 'CHECK ONLY: no files moved' "$TMP_DIR/check.out" \
    || fail "--check did not identify itself as non-mutating"

"$MIGRATE" --apply >"$TMP_DIR/apply.out"
[[ ! -e "$VM_ROOT/win10-vm1.qcow2" ]] || fail "legacy disk remains after apply"
[[ -f "$VM_ROOT/1/disk.qcow2" ]] || fail "instance disk missing"
[[ "$(stat -c %i "$VM_ROOT/1/disk.qcow2")" == "$disk_inode" ]] \
    || fail "same-filesystem migration did not preserve the disk inode"
[[ "$(stat -c %i "$VM_ROOT/2/disk.qcow2")" == "$categorized_inode" ]] \
    || fail "categorized disk was not migrated into vm2"
[[ -f "$VM_ROOT/_base/win10-base.qcow2" ]] || fail "categorized base missing"
[[ -f "$VM_ROOT/_base/archive/win10-base.qcow2.old" ]] \
    || fail "old base was not archived"
[[ -f "$VM_ROOT/1/vm.conf" ]] || fail "instance config missing"
[[ -f "$VM_ROOT/1/nvram.fd" ]] || fail "instance NVRAM missing"
[[ -f "$VM_ROOT/1/log/qemu.log" ]] || fail "instance log missing"
[[ -f "$VM_ROOT/1/backups/nvram/vm1_VARS.fd.bak-display-test" ]] \
    || fail "NVRAM backup was not moved into the instance"
[[ -f "$VM_ROOT/2/vm.conf" &&
   -f "$VM_ROOT/2/nvram.fd" &&
   -f "$VM_ROOT/2/log/qemu.log" ]] \
    || fail "categorized-only vm2 payload was not bundled"
[[ -d "$VM_ROOT/1/run" &&
   -d "$VM_ROOT/1/backups/disks" ]] \
    || fail "migration did not complete the instance directory skeleton"
[[ ! -e "$VM_ROOT/legacy/configs" && ! -e "$VM_ROOT/legacy/disks" &&
   ! -e "$VM_ROOT/legacy/nvram" && ! -e "$VM_ROOT/legacy/log" ]] \
    || fail "migration left empty deprecated classification directories"
[[ -f "$IMAGE_ROOT/iso/win10-ltsc.iso" ]] || fail "ISO was not classified"
[[ "$(stat -c %i "$VM_ROOT/_base/compat.qcow2")" == "$compat_base_inode" ]] \
    || fail "compatibility _base was modified"
find "$VM_ROOT/control" -name 'storage-migration-*.tsv' -type f | grep -q . \
    || fail "migration manifest was not written"

"$MIGRATE" --apply >"$TMP_DIR/idempotent.out"
grep -Fq 'instance layout is current' "$TMP_DIR/idempotent.out" \
    || fail "second migration was not idempotent"

# A destination collision must fail before moving the legacy source.
COLLISION_ROOT="$TMP_DIR/collision/vms"
mkdir -p "$COLLISION_ROOT/2"
"$QEMU_IMG" create -q -f qcow2 "$COLLISION_ROOT/win10-vm2.qcow2" 1M
"$QEMU_IMG" create -q -f qcow2 "$COLLISION_ROOT/2/disk.qcow2" 2M
if IMAGE_ROOT="$TMP_DIR/collision" VM_ROOT="$COLLISION_ROOT" \
    "$MIGRATE" --apply >"$TMP_DIR/collision.out" 2>"$TMP_DIR/collision.err"; then
    fail "migration accepted conflicting disk paths"
fi
grep -Fq 'destination already exists' "$TMP_DIR/collision.err" \
    || fail "collision refusal was not clear"
[[ -f "$COLLISION_ROOT/win10-vm2.qcow2" ]] \
    || fail "collision path moved the source"

# An arbitrary open descriptor must also block apply.
HOLDER_ROOT="$TMP_DIR/holder/vms"
mkdir -p "$HOLDER_ROOT/control"
"$QEMU_IMG" create -q -f qcow2 "$HOLDER_ROOT/win10-vm3.qcow2" 1M
exec {HELD_FD}<"$HOLDER_ROOT/win10-vm3.qcow2"
if IMAGE_ROOT="$TMP_DIR/holder" VM_ROOT="$HOLDER_ROOT" \
    "$MIGRATE" --apply >"$TMP_DIR/holder.out" 2>"$TMP_DIR/holder.err"; then
    fail "migration accepted an open source file"
fi
exec {HELD_FD}>&-
grep -Fq 'open file' "$TMP_DIR/holder.err" \
    || fail "open-file refusal was not clear"
[[ -f "$HOLDER_ROOT/win10-vm3.qcow2" ]] || fail "held source was moved"

# If a base is being moved, unreadable/corrupt qcow2 metadata must fail closed.
BAD_ROOT="$TMP_DIR/bad-metadata/vms"
mkdir -p "$BAD_ROOT/control"
"$QEMU_IMG" create -q -f qcow2 "$BAD_ROOT/win10-base.qcow2" 1M
printf '\x51\x46\x49\xfb\x00' >"$BAD_ROOT/bad.qcow2"
if IMAGE_ROOT="$TMP_DIR/bad-metadata" VM_ROOT="$BAD_ROOT" \
    "$MIGRATE" --apply >"$TMP_DIR/bad.out" 2>"$TMP_DIR/bad.err"; then
    fail "migration ignored invalid qcow2 backing metadata"
fi
grep -Fq 'cannot prove qcow2 backing safety' "$TMP_DIR/bad.err" \
    || fail "invalid-metadata refusal was not clear"
[[ -f "$BAD_ROOT/win10-base.qcow2" ]] \
    || fail "base moved after backing metadata inspection failed"

# A relative backing filename would resolve from a different directory after
# moving the overlay, so migration must refuse it instead of breaking the chain.
REL_ROOT="$TMP_DIR/relative/vms"
mkdir -p "$REL_ROOT/_base" "$REL_ROOT/control"
"$QEMU_IMG" create -q -f qcow2 "$REL_ROOT/_base/win10-base.qcow2" 1M
(
    cd "$REL_ROOT"
    "$QEMU_IMG" create -q -f qcow2 -F qcow2 \
        -b _base/win10-base.qcow2 win10-vm4.qcow2
)
if IMAGE_ROOT="$TMP_DIR/relative" VM_ROOT="$REL_ROOT" \
    "$MIGRATE" --check >"$TMP_DIR/relative.out" 2>"$TMP_DIR/relative.err"; then
    fail "migration accepted a planned overlay with relative backing"
fi
grep -Fq 'planned qcow2 has a backing file' "$TMP_DIR/relative.err" \
    || fail "relative-backing refusal was not clear"
[[ -f "$REL_ROOT/win10-vm4.qcow2" ]] \
    || fail "relative-backing overlay moved"

# An excluded compatibility overlay may still depend on a production file;
# moving that backing file must be refused even though the overlay stays put.
DEPEND_ROOT="$TMP_DIR/dependent/vms"
mkdir -p "$DEPEND_ROOT/9" "$DEPEND_ROOT/control"
"$QEMU_IMG" create -q -f qcow2 "$DEPEND_ROOT/win10-base.qcow2" 1M
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$DEPEND_ROOT/win10-base.qcow2" "$DEPEND_ROOT/9/disk.qcow2"
if IMAGE_ROOT="$TMP_DIR/dependent" VM_ROOT="$DEPEND_ROOT" \
    "$MIGRATE" --check >"$TMP_DIR/dependent.out" 2>"$TMP_DIR/dependent.err"; then
    fail "migration accepted a moved backing file with a dependent overlay"
fi
grep -Fq 'depends on a planned file that would move' "$TMP_DIR/dependent.err" \
    || fail "dependent-overlay refusal was not clear"
[[ -f "$DEPEND_ROOT/win10-base.qcow2" ]] \
    || fail "dependent backing file moved"

# Managed disk/base directories may be explicitly placed outside IMAGE_ROOT;
# dependency scans must include them rather than assuming one directory tree.
EXTERNAL_IMAGE_ROOT="$TMP_DIR/external-scan/images"
EXTERNAL_VM_ROOT="$EXTERNAL_IMAGE_ROOT/vms"
EXTERNAL_DISKS="$TMP_DIR/external-scan-disks"
mkdir -p "$EXTERNAL_VM_ROOT/control" "$EXTERNAL_DISKS"
"$QEMU_IMG" create -q -f qcow2 "$EXTERNAL_VM_ROOT/win10-base.qcow2" 1M
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$EXTERNAL_VM_ROOT/win10-base.qcow2" \
    "$EXTERNAL_DISKS/dependent.qcow2"
if IMAGE_ROOT="$EXTERNAL_IMAGE_ROOT" VM_ROOT="$EXTERNAL_VM_ROOT" \
    VM_DISK_DIR="$EXTERNAL_DISKS" VM_BASE_DIR="$EXTERNAL_VM_ROOT/_base" \
    "$MIGRATE" --check >"$TMP_DIR/external.out" 2>"$TMP_DIR/external.err"; then
    fail "migration ignored a dependent in an external managed disk dir"
fi
grep -Fq 'depends on a planned file that would move' "$TMP_DIR/external.err" \
    || fail "external dependent refusal was not clear"

# A qcow2 file symlink inside a managed root may point to an overlay elsewhere;
# it is still a dependent and must not be skipped by find -type f.
SYMLINK_IMAGE_ROOT="$TMP_DIR/symlink-scan/images"
SYMLINK_VM_ROOT="$SYMLINK_IMAGE_ROOT/vms"
SYMLINK_OUTSIDE="$TMP_DIR/symlink-scan-outside"
mkdir -p "$SYMLINK_VM_ROOT/control" "$SYMLINK_OUTSIDE"
"$QEMU_IMG" create -q -f qcow2 "$SYMLINK_VM_ROOT/win10-base.qcow2" 1M
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$SYMLINK_VM_ROOT/win10-base.qcow2" \
    "$SYMLINK_OUTSIDE/dependent.qcow2"
ln -s "$SYMLINK_OUTSIDE/dependent.qcow2" \
    "$SYMLINK_VM_ROOT/dependent-link.qcow2"
if IMAGE_ROOT="$SYMLINK_IMAGE_ROOT" VM_ROOT="$SYMLINK_VM_ROOT" \
    "$MIGRATE" --check >"$TMP_DIR/symlink.out" 2>"$TMP_DIR/symlink.err"; then
    fail "migration ignored a dependent qcow2 file symlink"
fi
grep -Fq 'depends on a planned file that would move' "$TMP_DIR/symlink.err" \
    || fail "symlink dependent refusal was not clear"

# QEMU protocol backing strings (file:/..., json:{...}, nbd:...) are not plain
# POSIX paths.  Lifecycle tools must fail closed unless they can prove safety.
PROTOCOL_IMAGE_ROOT="$TMP_DIR/protocol-scan/images"
PROTOCOL_VM_ROOT="$PROTOCOL_IMAGE_ROOT/vms"
mkdir -p "$PROTOCOL_VM_ROOT/9" "$PROTOCOL_VM_ROOT/control"
"$QEMU_IMG" create -q -f qcow2 "$PROTOCOL_VM_ROOT/win10-base.qcow2" 1M
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "file:$PROTOCOL_VM_ROOT/win10-base.qcow2" \
    "$PROTOCOL_VM_ROOT/9/disk.qcow2"
if IMAGE_ROOT="$PROTOCOL_IMAGE_ROOT" VM_ROOT="$PROTOCOL_VM_ROOT" \
    "$MIGRATE" --check >"$TMP_DIR/protocol.out" 2>"$TMP_DIR/protocol.err"; then
    fail "migration accepted an unsupported protocol backing reference"
fi
grep -Fq 'unsupported backing reference' "$TMP_DIR/protocol.err" \
    || fail "protocol-backing refusal was not clear"

# External qcow2 data files are another dependency mechanism.  A relative
# data_file would break when the qcow2 moves to disks/, so apply must refuse.
DATA_IMAGE_ROOT="$TMP_DIR/data-file/images"
DATA_VM_ROOT="$DATA_IMAGE_ROOT/vms"
mkdir -p "$DATA_VM_ROOT/control"
(
    cd "$DATA_VM_ROOT"
    "$QEMU_IMG" create -q -f qcow2 -o data_file=payload.raw \
        win10-vm7.qcow2 1M
)
if IMAGE_ROOT="$DATA_IMAGE_ROOT" VM_ROOT="$DATA_VM_ROOT" \
    "$MIGRATE" --apply >"$TMP_DIR/data-file.out" 2>"$TMP_DIR/data-file.err"; then
    fail "migration moved a qcow2 with an external data-file"
fi
grep -Fq 'planned qcow2 has an external data-file' "$TMP_DIR/data-file.err" \
    || fail "external-data-file refusal was not clear"
[[ -f "$DATA_VM_ROOT/win10-vm7.qcow2" &&
   ! -e "$DATA_VM_ROOT/7/disk.qcow2" ]] \
    || fail "external-data-file refusal moved the qcow2"

# Relative ISO/NVRAM symlinks also change meaning after a directory move, so
# migration rejects every source symlink rather than trying to rewrite links.
SOURCE_LINK_IMAGE_ROOT="$TMP_DIR/source-links/images"
SOURCE_LINK_VM_ROOT="$SOURCE_LINK_IMAGE_ROOT/vms"
mkdir -p "$SOURCE_LINK_VM_ROOT/templates" "$SOURCE_LINK_VM_ROOT/control"
printf 'iso-target\n' >"$SOURCE_LINK_IMAGE_ROOT/install-target.bin"
printf 'vars-target\n' >"$SOURCE_LINK_VM_ROOT/templates/vars.fd"
ln -s install-target.bin "$SOURCE_LINK_IMAGE_ROOT/win10-test.iso"
ln -s templates/vars.fd "$SOURCE_LINK_VM_ROOT/vm1_VARS.fd"
if IMAGE_ROOT="$SOURCE_LINK_IMAGE_ROOT" VM_ROOT="$SOURCE_LINK_VM_ROOT" \
    "$MIGRATE" --apply >"$TMP_DIR/source-links.out" \
    2>"$TMP_DIR/source-links.err"; then
    fail "migration moved relative ISO/NVRAM source symlinks"
fi
grep -Fq 'source symlink move is not supported' "$TMP_DIR/source-links.err" \
    || fail "source-symlink refusal was not clear"
[[ -e "$SOURCE_LINK_IMAGE_ROOT/win10-test.iso" &&
   -e "$SOURCE_LINK_VM_ROOT/vm1_VARS.fd" ]] \
    || fail "source-symlink refusal changed or broke a link"

# A qcow2 backing layer may be raw and named *.iso.  Compare chains against
# every planned source, not only planned qcow2 files.
RAW_IMAGE_ROOT="$TMP_DIR/raw-iso/images"
RAW_VM_ROOT="$RAW_IMAGE_ROOT/vms"
mkdir -p "$RAW_VM_ROOT/9" "$RAW_VM_ROOT/control"
"$QEMU_IMG" create -q -f raw "$RAW_IMAGE_ROOT/payload.iso" 1M
"$QEMU_IMG" create -q -f qcow2 -F raw \
    -b "$RAW_IMAGE_ROOT/payload.iso" "$RAW_VM_ROOT/9/disk.qcow2"
if IMAGE_ROOT="$RAW_IMAGE_ROOT" VM_ROOT="$RAW_VM_ROOT" \
    "$MIGRATE" --apply >"$TMP_DIR/raw-iso.out" 2>"$TMP_DIR/raw-iso.err"; then
    fail "migration moved a raw ISO used as a qcow2 backing layer"
fi
grep -Fq 'depends on a planned file that would move' "$TMP_DIR/raw-iso.err" \
    || fail "raw-ISO backing refusal was not clear"
[[ -f "$RAW_IMAGE_ROOT/payload.iso" &&
   ! -e "$RAW_IMAGE_ROOT/iso/payload.iso" ]] \
    || fail "raw-ISO backing refusal moved the source"

# Follow managed directory symlinks too: numeric compatibility directories are
# allowed to live on external storage and may contain a dependent overlay.
DIR_LINK_IMAGE_ROOT="$TMP_DIR/dir-link/images"
DIR_LINK_VM_ROOT="$DIR_LINK_IMAGE_ROOT/vms"
DIR_LINK_OUTSIDE="$TMP_DIR/dir-link-outside/vm9"
mkdir -p "$DIR_LINK_VM_ROOT/control" "$DIR_LINK_OUTSIDE"
"$QEMU_IMG" create -q -f qcow2 "$DIR_LINK_VM_ROOT/win10-base.qcow2" 1M
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$DIR_LINK_VM_ROOT/win10-base.qcow2" \
    "$DIR_LINK_OUTSIDE/disk.qcow2"
ln -s "$DIR_LINK_OUTSIDE" "$DIR_LINK_VM_ROOT/9"
if IMAGE_ROOT="$DIR_LINK_IMAGE_ROOT" VM_ROOT="$DIR_LINK_VM_ROOT" \
    "$MIGRATE" --check >"$TMP_DIR/dir-link.out" 2>"$TMP_DIR/dir-link.err"; then
    fail "migration ignored a dependent below a managed directory symlink"
fi
grep -Fq 'depends on a planned file that would move' "$TMP_DIR/dir-link.err" \
    || fail "directory-symlink dependent refusal was not clear"

# Inspect every layer, not only the direct backing: managed top -> external
# middle -> legacy base must still block moving the chain tail.
CHAIN_IMAGE_ROOT="$TMP_DIR/recursive-chain/images"
CHAIN_VM_ROOT="$CHAIN_IMAGE_ROOT/vms"
CHAIN_OUTSIDE="$TMP_DIR/recursive-chain-outside"
mkdir -p "$CHAIN_VM_ROOT/9" "$CHAIN_VM_ROOT/control" "$CHAIN_OUTSIDE"
"$QEMU_IMG" create -q -f qcow2 "$CHAIN_VM_ROOT/win10-base.qcow2" 1M
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$CHAIN_VM_ROOT/win10-base.qcow2" "$CHAIN_OUTSIDE/middle.qcow2"
"$QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$CHAIN_OUTSIDE/middle.qcow2" "$CHAIN_VM_ROOT/9/disk.qcow2"
if IMAGE_ROOT="$CHAIN_IMAGE_ROOT" VM_ROOT="$CHAIN_VM_ROOT" \
    "$MIGRATE" --check >"$TMP_DIR/recursive.out" 2>"$TMP_DIR/recursive.err"; then
    fail "migration missed a moved dependency behind an external middle layer"
fi
grep -Fq 'depends on a planned file that would move' "$TMP_DIR/recursive.err" \
    || fail "recursive-chain refusal was not clear"

# Runtime PID/socket/mdev state is never renamed into an instance.  Even stale
# state must be cleaned explicitly before moving persistent VM files.
RUNTIME_ROOT="$TMP_DIR/runtime-state/vms"
mkdir -p "$RUNTIME_ROOT/control"
"$QEMU_IMG" create -q -f qcow2 "$RUNTIME_ROOT/win10-vm5.qcow2" 1M
touch "$RUNTIME_ROOT/control/vm5.pid"
if IMAGE_ROOT="$TMP_DIR/runtime-state" VM_ROOT="$RUNTIME_ROOT" \
    "$MIGRATE" --check >"$TMP_DIR/runtime-state.out" \
    2>"$TMP_DIR/runtime-state.err"; then
    fail "migration accepted stale VM runtime state"
fi
grep -Fq 'runtime state must be cleaned' "$TMP_DIR/runtime-state.err" \
    || fail "runtime-state refusal was not clear"
[[ -f "$RUNTIME_ROOT/win10-vm5.qcow2" ]] \
    || fail "runtime-state refusal moved the source"

# The canonical instance path and its children must be real directories, not
# symlinks that redirect a migration outside the managed tree.
UNSAFE_ROOT="$TMP_DIR/unsafe-instance/vms"
mkdir -p "$UNSAFE_ROOT" "$TMP_DIR/unsafe-instance-outside"
"$QEMU_IMG" create -q -f qcow2 "$UNSAFE_ROOT/win10-vm5.qcow2" 1M
ln -s "$TMP_DIR/unsafe-instance-outside" "$UNSAFE_ROOT/5"
if IMAGE_ROOT="$TMP_DIR/unsafe-instance" VM_ROOT="$UNSAFE_ROOT" \
    "$MIGRATE" --check >"$TMP_DIR/unsafe-instance.out" \
    2>"$TMP_DIR/unsafe-instance.err"; then
    fail "migration followed an instance directory symlink"
fi
grep -Fq 'instance path must be a real directory' \
    "$TMP_DIR/unsafe-instance.err" \
    || fail "unsafe-instance refusal was not clear"

# Apply takes the exclusive storage lock before it inventories or validates
# destinations, closing the plan-to-publication race with cooperating tools.
LOCK_ROOT="$TMP_DIR/locked-apply/vms"
mkdir -p "$LOCK_ROOT/control"
"$QEMU_IMG" create -q -f qcow2 "$LOCK_ROOT/win10-vm6.qcow2" 1M
exec {STORAGE_HOLDER_FD}>"$LOCK_ROOT/control/.storage.lock"
flock -s "$STORAGE_HOLDER_FD"
if IMAGE_ROOT="$TMP_DIR/locked-apply" VM_ROOT="$LOCK_ROOT" \
    "$MIGRATE" --apply >"$TMP_DIR/locked-apply.out" \
    2>"$TMP_DIR/locked-apply.err"; then
    fail "migration generated an apply plan without the exclusive storage lock"
fi
exec {STORAGE_HOLDER_FD}>&-
grep -Fq 'another VM/storage operation holds' "$TMP_DIR/locked-apply.err" \
    || fail "early storage-lock refusal was not clear"
[[ -f "$LOCK_ROOT/win10-vm6.qcow2" ]] \
    || fail "locked apply moved the source disk"

# Per-VM disk mutation locks are also a final apply gate.
DISK_LOCK_ROOT="$TMP_DIR/disk-locked-apply/vms"
mkdir -p "$DISK_LOCK_ROOT/control"
"$QEMU_IMG" create -q -f qcow2 "$DISK_LOCK_ROOT/win10-vm8.qcow2" 1M
exec {DISK_LOCK_HOLDER_FD}>"$DISK_LOCK_ROOT/control/vm8.disk.lock"
flock -x "$DISK_LOCK_HOLDER_FD"
if IMAGE_ROOT="$TMP_DIR/disk-locked-apply" VM_ROOT="$DISK_LOCK_ROOT" \
    "$MIGRATE" --apply >"$TMP_DIR/disk-locked.out" \
    2>"$TMP_DIR/disk-locked.err"; then
    fail "migration ignored a busy per-VM disk lock"
fi
exec {DISK_LOCK_HOLDER_FD}>&-
grep -Fq 'disk lock is busy' "$TMP_DIR/disk-locked.err" \
    || fail "disk-lock refusal was not clear"
[[ -f "$DISK_LOCK_ROOT/win10-vm8.qcow2" ]] \
    || fail "disk-lock refusal moved the source"

echo "PASS: storage migration check/apply/idempotence and safety gates"

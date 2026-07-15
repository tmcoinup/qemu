#!/usr/bin/env bash
# Verify categorized base publication and failure-safe replacement with a fake
# qemu-img. No real qcow2 is opened.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROMOTE="$REPO_ROOT/deploy/promote-base.sh"
REAL_QEMU_IMG="$REPO_ROOT/build/qemu-img"
[[ -x "$REAL_QEMU_IMG" ]] || REAL_QEMU_IMG=$(command -v qemu-img || true)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
[[ -n "$REAL_QEMU_IMG" && -x "$REAL_QEMU_IMG" ]] || fail "qemu-img is required"
VM_ROOT="$TMP_DIR/vms"
QEMU_IMG="$TMP_DIR/qemu-img"
export VM_ROOT QEMU_IMG
mkdir -p "$VM_ROOT/disks" "$VM_ROOT/bases" "$VM_ROOT/run"
printf 'new-base-content\n' >"$VM_ROOT/disks/win10-vm8.qcow2"
printf 'old-base-content\n' >"$VM_ROOT/bases/win10-base.qcow2"

cat >"$QEMU_IMG" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    info)
        image=${@: -1}
        [[ -f "$image" ]]
        backing=""
        if grep -q '^BACKING=' "$image"; then
            backing=$(sed -n 's/^BACKING=//p' "$image" | head -1)
        fi
        data_file=""
        if grep -q '^DATA_FILE=' "$image"; then
            data_file=$(sed -n 's/^DATA_FILE=//p' "$image" | head -1)
        fi
        if [[ " $* " == *' --backing-chain '* ]]; then
            if [[ -n "$backing" ]]; then
                printf '[{"filename":"%s","format":"qcow2","backing-filename":"%s","full-backing-filename":"%s","format-specific":{"data":{"data-file":"%s"}}},{"filename":"%s","format":"qcow2","format-specific":{"data":{}}}]\n' \
                    "$image" "$backing" "$backing" "$data_file" "$backing"
            else
                printf '[{"filename":"%s","format":"qcow2","format-specific":{"data":{"data-file":"%s"}}}]\n' \
                    "$image" "$data_file"
            fi
        else
            printf '{"format":"qcow2","virtual-size":1048576,"backing-filename":"%s","format-specific":{"data":{"data-file":"%s"}}}\n' \
                "$backing" "$data_file"
        fi
        ;;
    convert)
        src=${@: -2:1}
        dst=${@: -1}
        cp -- "$src" "$dst"
        ;;
    check)
        [[ -f "${@: -1}" ]]
        ;;
    *)
        echo "unexpected fake qemu-img command: $*" >&2
        exit 99
        ;;
esac
EOF
chmod +x "$QEMU_IMG"

exec {STORAGE_HOLDER_FD}>"$VM_ROOT/run/.storage.lock"
flock -s "$STORAGE_HOLDER_FD"
if "$PROMOTE" 8 -y >"$TMP_DIR/locked.out" 2>"$TMP_DIR/locked.err"; then
    fail "promote-base ignored a running/shared storage holder"
fi
exec {STORAGE_HOLDER_FD}>&-
grep -Fq '其它 VM 正在运行' "$TMP_DIR/locked.err" \
    || fail "exclusive-storage refusal was not clear"

printf 'BACKING=parent.qcow2\n' >"$VM_ROOT/bases/win10-base.qcow2"
if "$PROMOTE" 8 -y >"$TMP_DIR/nonstandalone.out" \
    2>"$TMP_DIR/nonstandalone.err"; then
    fail "promote-base archived a non-standalone existing base"
fi
grep -Fq '现有 base 不是 standalone' "$TMP_DIR/nonstandalone.err" \
    || fail "non-standalone existing-base refusal was not clear"
printf 'old-base-content\n' >"$VM_ROOT/bases/win10-base.qcow2"

"$PROMOTE" 8 -y >"$TMP_DIR/success.out"
grep -Fq 'new-base-content' "$VM_ROOT/bases/win10-base.qcow2" \
    || fail "new base was not published"
archive=$(find "$VM_ROOT/bases/archive" -type f -name 'win10-base-*.qcow2' -print -quit)
[[ -n "$archive" ]] || fail "old base was not archived"
grep -Fq 'old-base-content' "$archive" || fail "archive content changed"

# Replacing a base that any existing overlay depends on must be refused.
printf 'stable-dependent-base\n' >"$VM_ROOT/bases/win10-base.qcow2"
printf 'BACKING=%s\n' "$VM_ROOT/bases/win10-base.qcow2" \
    >"$VM_ROOT/disks/win10-vm9.qcow2"
if "$PROMOTE" 8 -y >"$TMP_DIR/dependent.out" 2>"$TMP_DIR/dependent.err"; then
    fail "promote-base replaced a base with an existing dependent overlay"
fi
grep -Fq 'overlay 依赖目标 base 路径' "$TMP_DIR/dependent.err" \
    || fail "dependent-overlay refusal was not clear"
grep -Fq 'stable-dependent-base' "$VM_ROOT/bases/win10-base.qcow2" \
    || fail "dependent-overlay refusal changed the base"
rm -f "$VM_ROOT/disks/win10-vm9.qcow2"

SYMLINK_OUTSIDE="$TMP_DIR/symlink-outside"
mkdir -p "$SYMLINK_OUTSIDE"
printf 'BACKING=%s\n' "$VM_ROOT/bases/win10-base.qcow2" \
    >"$SYMLINK_OUTSIDE/dependent.qcow2"
ln -s "$SYMLINK_OUTSIDE/dependent.qcow2" \
    "$VM_ROOT/disks/dependent-link.qcow2"
if "$PROMOTE" 8 -y >"$TMP_DIR/symlink.out" 2>"$TMP_DIR/symlink.err"; then
    fail "promote-base ignored a dependent qcow2 file symlink"
fi
grep -Fq 'overlay 依赖目标 base 路径' "$TMP_DIR/symlink.err" \
    || fail "symlink dependent refusal was not clear"
rm -f "$VM_ROOT/disks/dependent-link.qcow2" "$SYMLINK_OUTSIDE/dependent.qcow2"

DIR_LINK_OUTSIDE="$TMP_DIR/dir-link-outside/vm10"
mkdir -p "$DIR_LINK_OUTSIDE"
printf 'BACKING=%s\n' "$VM_ROOT/bases/win10-base.qcow2" \
    >"$DIR_LINK_OUTSIDE/disk.qcow2"
ln -s "$DIR_LINK_OUTSIDE" "$VM_ROOT/10"
if "$PROMOTE" 8 -y >"$TMP_DIR/dir-link.out" 2>"$TMP_DIR/dir-link.err"; then
    fail "promote-base ignored a dependent below a directory symlink"
fi
grep -Fq 'overlay 依赖目标 base 路径' "$TMP_DIR/dir-link.err" \
    || fail "directory-symlink dependent refusal was not clear"
rm -f "$VM_ROOT/10" "$DIR_LINK_OUTSIDE/disk.qcow2"

# Even when the target base pathname is currently missing, publishing a new
# unrelated file there must not silently reconnect a broken overlay.
mv "$VM_ROOT/bases/win10-base.qcow2" "$VM_ROOT/bases/win10-base.qcow2.saved"
printf 'BACKING=%s\n' "$VM_ROOT/bases/win10-base.qcow2" \
    >"$VM_ROOT/disks/win10-vm9.qcow2"
if "$PROMOTE" 8 -y >"$TMP_DIR/missing.out" 2>"$TMP_DIR/missing.err"; then
    fail "promote-base published into a missing path recorded by an overlay"
fi
grep -Fq 'overlay 依赖目标 base 路径' "$TMP_DIR/missing.err" \
    || fail "missing-base dependency refusal was not clear"
[[ ! -e "$VM_ROOT/bases/win10-base.qcow2" ]] \
    || fail "missing-base dependency check published a new base"
rm -f "$VM_ROOT/disks/win10-vm9.qcow2"
mv "$VM_ROOT/bases/win10-base.qcow2.saved" "$VM_ROOT/bases/win10-base.qcow2"

# Explicit managed disk directories outside IMAGE_ROOT must be scanned too.
EXTERNAL_DISKS="$TMP_DIR/external-disks"
mkdir -p "$EXTERNAL_DISKS"
cp "$VM_ROOT/disks/win10-vm8.qcow2" \
    "$EXTERNAL_DISKS/win10-vm8.qcow2"
printf 'BACKING=%s\n' "$VM_ROOT/bases/win10-base.qcow2" \
    >"$EXTERNAL_DISKS/dependent.qcow2"
if VM_DISK_DIR="$EXTERNAL_DISKS" VM_BASE_DIR="$VM_ROOT/bases" \
    "$PROMOTE" 8 -y >"$TMP_DIR/external.out" 2>"$TMP_DIR/external.err"; then
    fail "promote-base ignored a dependent in an external managed disk dir"
fi
grep -Fq 'overlay 依赖目标 base 路径' "$TMP_DIR/external.err" \
    || fail "external dependent refusal was not clear"
rm -rf "$EXTERNAL_DISKS"

# Even if convert/check return success, a published base must not retain a
# qcow2 external data-file dependency.
printf 'stable-before-data-output\n' >"$VM_ROOT/bases/win10-base.qcow2"
printf 'DATA_FILE=shared.raw\n' >"$VM_ROOT/disks/win10-vm8.qcow2"
if "$PROMOTE" 8 -y >"$TMP_DIR/data-output.out" 2>"$TMP_DIR/data-output.err"; then
    fail "promote-base published a qcow2 with an external data-file"
fi
grep -Fq 'convert 结果不是有效 standalone qcow2' "$TMP_DIR/data-output.err" \
    || fail "external-data-file output refusal was not clear"
grep -Fq 'stable-before-data-output' "$VM_ROOT/bases/win10-base.qcow2" \
    || fail "external-data-file output refusal changed the base"
printf 'new-base-content\n' >"$VM_ROOT/disks/win10-vm8.qcow2"

# Real qcow2 protocol backing (file:/...) is deliberately fail-closed; it must
# not be misparsed as a relative host pathname and silently missed.
PROTOCOL_VM_ROOT="$TMP_DIR/protocol/vms"
mkdir -p "$PROTOCOL_VM_ROOT/disks" "$PROTOCOL_VM_ROOT/bases" \
    "$PROTOCOL_VM_ROOT/9" "$PROTOCOL_VM_ROOT/run"
"$REAL_QEMU_IMG" create -q -f qcow2 \
    "$PROTOCOL_VM_ROOT/disks/win10-vm8.qcow2" 1M
"$REAL_QEMU_IMG" create -q -f qcow2 \
    "$PROTOCOL_VM_ROOT/bases/win10-base.qcow2" 1M
"$REAL_QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "file:$PROTOCOL_VM_ROOT/bases/win10-base.qcow2" \
    "$PROTOCOL_VM_ROOT/9/disk.qcow2"
protocol_base_inode=$(stat -c %i "$PROTOCOL_VM_ROOT/bases/win10-base.qcow2")
if VM_ROOT="$PROTOCOL_VM_ROOT" QEMU_IMG="$REAL_QEMU_IMG" \
    "$PROMOTE" 8 -y >"$TMP_DIR/protocol.out" 2>"$TMP_DIR/protocol.err"; then
    fail "promote-base accepted an unsupported protocol backing reference"
fi
grep -Fq 'unsupported backing reference' "$TMP_DIR/protocol.err" \
    || fail "protocol-backing refusal was not clear"
[[ "$(stat -c %i "$PROTOCOL_VM_ROOT/bases/win10-base.qcow2")" == \
   "$protocol_base_inode" ]] || fail "protocol refusal replaced the base"

# Complete-chain inspection must catch managed top -> external middle -> base.
CHAIN_VM_ROOT="$TMP_DIR/recursive/vms"
CHAIN_OUTSIDE="$TMP_DIR/recursive-outside"
mkdir -p "$CHAIN_VM_ROOT/disks" "$CHAIN_VM_ROOT/bases" \
    "$CHAIN_VM_ROOT/9" "$CHAIN_VM_ROOT/run" "$CHAIN_OUTSIDE"
"$REAL_QEMU_IMG" create -q -f qcow2 \
    "$CHAIN_VM_ROOT/disks/win10-vm8.qcow2" 1M
"$REAL_QEMU_IMG" create -q -f qcow2 \
    "$CHAIN_VM_ROOT/bases/win10-base.qcow2" 1M
"$REAL_QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$CHAIN_VM_ROOT/bases/win10-base.qcow2" \
    "$CHAIN_OUTSIDE/middle.qcow2"
"$REAL_QEMU_IMG" create -q -f qcow2 -F qcow2 \
    -b "$CHAIN_OUTSIDE/middle.qcow2" "$CHAIN_VM_ROOT/9/disk.qcow2"
chain_base_inode=$(stat -c %i "$CHAIN_VM_ROOT/bases/win10-base.qcow2")
if VM_ROOT="$CHAIN_VM_ROOT" QEMU_IMG="$REAL_QEMU_IMG" \
    "$PROMOTE" 8 -y >"$TMP_DIR/recursive.out" 2>"$TMP_DIR/recursive.err"; then
    fail "promote-base missed a base behind an external middle layer"
fi
grep -Fq 'overlay 依赖目标 base 路径' "$TMP_DIR/recursive.err" \
    || fail "recursive-chain refusal was not clear"
[[ "$(stat -c %i "$CHAIN_VM_ROOT/bases/win10-base.qcow2")" == \
   "$chain_base_inode" ]] || fail "recursive-chain refusal replaced the base"

# A failed convert must leave the current valid base untouched and publish no
# partial final image.
printf 'stable-base\n' >"$VM_ROOT/bases/win10-base.qcow2"
cat >"$QEMU_IMG" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    info)
        image=${@: -1}
        if [[ " $* " == *' --backing-chain '* ]]; then
            printf '[{"filename":"%s","format":"qcow2","format-specific":{"data":{}}}]\n' "$image"
        else
            printf '{"format":"qcow2","virtual-size":1048576,"backing-filename":"","format-specific":{"data":{}}}\n'
        fi
        ;;
    check)
        [[ -f "${@: -1}" ]]
        ;;
    convert)
        exit 42
        ;;
    *)
        exit 99
        ;;
esac
EOF
chmod +x "$QEMU_IMG"
if "$PROMOTE" 8 -y >"$TMP_DIR/fail.out" 2>"$TMP_DIR/fail.err"; then
    fail "promote-base accepted a failed conversion"
fi
grep -Fq 'stable-base' "$VM_ROOT/bases/win10-base.qcow2" \
    || fail "failed conversion damaged the existing base"
if find "$VM_ROOT/bases" -maxdepth 1 -name '*.partial.*' -print | grep -q .; then
    fail "failed conversion left a partial image"
fi

echo "PASS: promote-base categorized archive and failure-safe publication"

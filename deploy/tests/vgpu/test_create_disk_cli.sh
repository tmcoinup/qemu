#!/usr/bin/env bash
# Regression coverage for create-disk.sh argument parsing. Everything stays in
# a temporary directory; no real VM image or qemu process is touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CREATE_DISK="$REPO_ROOT/deploy/create-disk.sh"
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
IMAGE_ROOT="$TMP_DIR"
TRACE="$TMP_DIR/qemu-img.trace"
export IMAGE_ROOT VM_ROOT QEMU_IMG="$TMP_DIR/qemu-img" TRACE

cat >"$QEMU_IMG" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    create)
        target=${@: -2:1}
        size=${@: -1}
        mkdir -p "$(dirname "$target")"
        printf 'VIRTUAL_SIZE=%s\n' "$size" >"$target"
        printf 'create|%s|%s\n' "$target" "$size" >>"$TRACE"
        ;;
    info)
        image=${@: -1}
        [[ -f "$image" ]]
        backing=""
        virtual_size=${FAKE_VIRTUAL_SIZE:-512000000000}
        if grep -q '^BACKING=' "$image"; then
            backing=$(sed -n 's/^BACKING=//p' "$image" | head -1)
        fi
        if grep -q '^VIRTUAL_SIZE=' "$image"; then
            virtual_size=$(sed -n 's/^VIRTUAL_SIZE=//p' "$image" | tail -1)
        fi
        if [[ " $* " == *' --output=json '* ]]; then
            printf '{"format":"qcow2","virtual-size":%s,"backing-filename":"%s"}\n' \
                "$virtual_size" "$backing"
        else
            printf 'image: %s\nfile format: qcow2\nvirtual size: %s bytes\n' \
                "$image" "$virtual_size"
        fi
        printf 'info|%s\n' "$image" >>"$TRACE"
        ;;
    check)
        image=${@: -1}
        [[ -f "$image" ]]
        [[ "${FAIL_CHECK:-0}" != 1 ]]
        printf 'check|%s\n' "$image" >>"$TRACE"
        ;;
    resize)
        target=${@: -2:1}
        size=${@: -1}
        [[ -f "$target" ]]
        printf 'VIRTUAL_SIZE=%s\n' "$size" >>"$target"
        printf 'resize|%s|%s\n' "$target" "$size" >>"$TRACE"
        ;;
    *)
        echo "unexpected fake qemu-img command: $*" >&2
        exit 99
        ;;
esac
EOF
chmod +x "$QEMU_IMG"

# The old parser rejected one-digit IDs; this is the primary regression case.
SIZE_BYTES=12345 "$CREATE_DISK" 4 --blank >"$TMP_DIR/vm4.out"
[[ -f "$VM_ROOT/vm4/disk.qcow2" ]] || fail "single-digit VM ID was not created"
grep -Fq "$TMP_DIR/iso/win10.iso" "$TMP_DIR/vm4.out" || \
    fail "blank-disk next-step hint does not match start-vm's canonical ISO"
if grep -Fq 'win10-ltsc.iso' "$TMP_DIR/vm4.out"; then
    fail "blank-disk next-step hint still advertises the stale ISO basename"
fi
grep -Eq "^create\\|$VM_ROOT/vm4/\\.disk\\.qcow2\\.partial\\.[^|]+\\|12345$" "$TRACE" \
    || fail "single-digit VM did not use the requested byte size"

# With a qualified base and no --blank, creation must clone instead of calling
# qemu-img create.
mkdir -p "$VM_ROOT/shared/bases"
printf 'qualified-base-fixture\n' >"$VM_ROOT/shared/bases/win10-base.qcow2"
chmod 0444 "$VM_ROOT/shared/bases/win10-base.qcow2"
"$CREATE_DISK" 10 >"$TMP_DIR/vm10.out"
cmp "$VM_ROOT/shared/bases/win10-base.qcow2" "$VM_ROOT/vm10/disk.qcow2" \
    || fail "base clone content differs"
clone_mode=$(stat -c %a "$VM_ROOT/vm10/disk.qcow2")
(( (8#$clone_mode & 0200) != 0 )) \
    || fail "clone inherited a read-only baseline mode"
[[ "$(grep -c '^create|' "$TRACE")" -eq 1 ]] \
    || fail "base clone unexpectedly created a blank image"
chmod 0644 "$VM_ROOT/shared/bases/win10-base.qcow2"

# A profile larger than the baseline is safe: clone first, then grow only the
# private copy.  The shared baseline must stay at its original virtual size.
printf 'VIRTUAL_SIZE=500107862016\n' >"$VM_ROOT/shared/bases/win10-base.qcow2"
mkdir -p "$VM_ROOT/vm20"
printf 'SSD_SIZE_BYTES=512110190592\n' \
    >"$VM_ROOT/vm20/vm.conf"
"$CREATE_DISK" 20 --from-base >"$TMP_DIR/grow-base.out"
[[ -f "$VM_ROOT/vm20/disk.qcow2" ]] \
    || fail "larger profile did not publish the grown base clone"
grep -Eq "^resize\|$VM_ROOT/vm20/\\.disk\\.qcow2\\.partial\\.[^|]+\\|512110190592$" \
    "$TRACE" || fail "larger profile did not resize its private partial clone"
grep -Fxq 'VIRTUAL_SIZE=512110190592' \
    "$VM_ROOT/vm20/disk.qcow2" \
    || fail "grown clone does not report the profile capacity"
grep -Fxq 'VIRTUAL_SIZE=500107862016' \
    "$VM_ROOT/shared/bases/win10-base.qcow2" \
    || fail "growing a clone mutated the shared baseline"

# Shrinking a baseline is deliberately unsupported.  A 500 GB profile cannot
# clone a 512 GB baseline and must fail before publishing or calling resize.
printf 'VIRTUAL_SIZE=512110190592\n' >"$VM_ROOT/shared/bases/win10-base.qcow2"
mkdir -p "$VM_ROOT/vm21"
printf 'SSD_SIZE_BYTES=500107862016\n' \
    >"$VM_ROOT/vm21/vm.conf"
resize_count_before=$(grep -c '^resize|' "$TRACE" || true)
if "$CREATE_DISK" 21 --from-base \
        >"$TMP_DIR/shrink-base.out" 2>"$TMP_DIR/shrink-base.err"; then
    fail "smaller profile accepted an unsafe baseline shrink"
fi
grep -Fq '小于 baseline' "$TMP_DIR/shrink-base.err" \
    || fail "baseline shrink refusal was not clear"
[[ ! -e "$VM_ROOT/vm21/disk.qcow2" ]] \
    || fail "baseline shrink refusal published a disk"
[[ "$(grep -c '^resize|' "$TRACE" || true)" -eq "$resize_count_before" ]] \
    || fail "baseline shrink refusal still invoked qemu-img resize"

# Forced blank creation also consumes the exact capacity in vm.conf when no
# SIZE_BYTES/positional override is supplied.
mkdir -p "$VM_ROOT/vm22"
printf 'SSD_SIZE_BYTES=500107862016\n' \
    >"$VM_ROOT/vm22/vm.conf"
"$CREATE_DISK" 22 --blank >"$TMP_DIR/profile-blank.out"
grep -Eq "^create\|$VM_ROOT/vm22/\\.disk\\.qcow2\\.partial\\.[^|]+\\|500107862016$" \
    "$TRACE" || fail "blank disk ignored vm.conf SSD_SIZE_BYTES"

REQUIRED_VM_ROOT="$TMP_DIR/required-vms"
if VM_ROOT="$REQUIRED_VM_ROOT" "$CREATE_DISK" 18 --from-base \
        >"$TMP_DIR/required.out" 2>"$TMP_DIR/required.err"; then
    fail "--from-base silently fell back to a blank disk"
fi
grep -Fq '要求从公共 base 创建，但文件不存在' "$TMP_DIR/required.err" || \
    fail "missing required base refusal was not clear"
[[ ! -e "$REQUIRED_VM_ROOT/vm18/disk.qcow2" ]] || \
    fail "--from-base missing-base refusal published a disk"

# A base with any backing file is not portable to disks/ and must be rejected.
printf 'BACKING=parent.qcow2\n' >"$VM_ROOT/shared/bases/win10-base.qcow2"
if "$CREATE_DISK" 11 >"$TMP_DIR/backing.out" 2>"$TMP_DIR/backing.err"; then
    fail "base clone accepted a non-standalone base"
fi
grep -Fq 'base 必须是 standalone qcow2' "$TMP_DIR/backing.err" \
    || fail "non-standalone base refusal was not clear"
[[ ! -e "$VM_ROOT/vm11/disk.qcow2" ]] \
    || fail "non-standalone base published a VM disk"

# An explicitly requested blank install disk must not depend on the health of
# an unrelated public-base symlink. Normal clone mode still rejects it.
DANGLING_VM_ROOT="$TMP_DIR/dangling-vms"
mkdir -p "$DANGLING_VM_ROOT/shared/bases"
ln -s missing-base.qcow2 "$DANGLING_VM_ROOT/shared/bases/win10-base.qcow2"
VM_ROOT="$DANGLING_VM_ROOT" SIZE_BYTES=23456 "$CREATE_DISK" 16 --blank \
    >"$TMP_DIR/dangling-blank.out"
[[ -f "$DANGLING_VM_ROOT/vm16/disk.qcow2" ]] || \
    fail "blank creation was blocked by an unrelated dangling base symlink"
if VM_ROOT="$DANGLING_VM_ROOT" "$CREATE_DISK" 17 \
        >"$TMP_DIR/dangling-clone.out" 2>"$TMP_DIR/dangling-clone.err"; then
    fail "clone mode accepted a dangling public-base symlink"
fi
grep -Fq 'base 是失效符号链接' "$TMP_DIR/dangling-clone.err" || \
    fail "dangling base refusal was not clear"

# A qcow2 external data_file is not standalone even when backing-filename is
# empty; cloning it would make multiple VM images share one writable payload.
DATA_VM_ROOT="$TMP_DIR/data-vms"
mkdir -p "$DATA_VM_ROOT/shared/bases"
(
    cd "$DATA_VM_ROOT/shared/bases"
    "$REAL_QEMU_IMG" create -q -f qcow2 -o data_file=base.data \
        win10-base.qcow2 1M
)
if VM_ROOT="$DATA_VM_ROOT" QEMU_IMG="$REAL_QEMU_IMG" \
    "$CREATE_DISK" 15 >"$TMP_DIR/data.out" 2>"$TMP_DIR/data.err"; then
    fail "base clone accepted a qcow2 external data-file"
fi
grep -Fq '不能有 backing/data-file' "$TMP_DIR/data.err" \
    || fail "external-data-file base refusal was not clear"
[[ ! -e "$DATA_VM_ROOT/vm15/disk.qcow2" ]] \
    || fail "external-data-file base published a VM disk"

# qemu-img/check failure must clean the partial and never publish the target.
if FAIL_CHECK=1 "$CREATE_DISK" 12 --blank \
    >"$TMP_DIR/check-fail.out" 2>"$TMP_DIR/check-fail.err"; then
    fail "blank creation accepted a failed qemu-img check"
fi
[[ ! -e "$VM_ROOT/vm12/disk.qcow2" ]] \
    || fail "failed validation published a VM disk"
if find "$VM_ROOT/vm12" -maxdepth 1 -name '*.partial.*' -print | grep -q .; then
    fail "failed validation left a partial disk"
fi

exec {DISK_HOLDER_FD}>"$VM_ROOT/control/vm14.disk.lock"
flock -x "$DISK_HOLDER_FD"
if "$CREATE_DISK" 14 --blank \
    >"$TMP_DIR/locked.out" 2>"$TMP_DIR/locked.err"; then
    fail "create-disk ignored the per-VM lifecycle lock"
fi
exec {DISK_HOLDER_FD}>&-
grep -Fq '磁盘正在被创建或删除' "$TMP_DIR/locked.err" \
    || fail "create-disk lock refusal was not clear"
[[ ! -e "$VM_ROOT/vm14/disk.qcow2" ]] \
    || fail "locked create-disk published a disk"

for args in '0 --blank' 'abc --blank' '11 0 --blank' '12 20 30 --blank' \
        '19 --blank --from-base'; do
    # shellcheck disable=SC2086
    if "$CREATE_DISK" $args >"$TMP_DIR/invalid.out" 2>"$TMP_DIR/invalid.err"; then
        fail "invalid arguments were accepted: $args"
    fi
done

if SIZE_BYTES=not-a-number "$CREATE_DISK" 13 --blank \
    >"$TMP_DIR/invalid-bytes.out" 2>"$TMP_DIR/invalid-bytes.err"; then
    fail "invalid SIZE_BYTES was accepted"
fi

echo "PASS: create-disk single-digit, blank/base, and validation paths"

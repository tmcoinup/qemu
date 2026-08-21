#!/usr/bin/env bash
# Regression coverage for create-disk.sh argument parsing. Everything stays in
# a temporary directory; no real VM image or qemu process is touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CREATE_DISK="$REPO_ROOT/deploy/scripts/create-disk.sh"
REAL_QEMU_IMG="$REPO_ROOT/build/qemu-img"
[[ -x "$REAL_QEMU_IMG" ]] || REAL_QEMU_IMG=$(command -v qemu-img || true)
REAL_JQ=$(command -v jq || true)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
[[ -n "$REAL_QEMU_IMG" && -x "$REAL_QEMU_IMG" ]] || fail "qemu-img is required"
[[ -n "$REAL_JQ" && -x "$REAL_JQ" ]] || fail "jq is required"
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
[[ -f "$VM_ROOT/4/disk.qcow2" ]] || fail "single-digit VM ID was not created"
grep -Fq "$TMP_DIR/iso/win10.iso" "$TMP_DIR/vm4.out" || \
    fail "blank-disk next-step hint does not match start-vm's canonical ISO"
if grep -Fq 'win10-ltsc.iso' "$TMP_DIR/vm4.out"; then
    fail "blank-disk next-step hint still advertises the stale ISO basename"
fi
grep -Eq "^create\\|$VM_ROOT/4/\\.disk\\.qcow2\\.partial\\.[^|]+\\|12345$" "$TRACE" \
    || fail "single-digit VM did not use the requested byte size"

# With a qualified base and no --blank, creation must clone instead of calling
# qemu-img create.
mkdir -p "$VM_ROOT/_base"
printf 'qualified-base-fixture\n' >"$VM_ROOT/_base/win10-base.qcow2"
chmod 0444 "$VM_ROOT/_base/win10-base.qcow2"
"$CREATE_DISK" 10 >"$TMP_DIR/vm10.out"
cmp "$VM_ROOT/_base/win10-base.qcow2" "$VM_ROOT/10/disk.qcow2" \
    || fail "base clone content differs"
clone_mode=$(stat -c %a "$VM_ROOT/10/disk.qcow2")
(( (8#$clone_mode & 0200) != 0 )) \
    || fail "clone inherited a read-only baseline mode"
[[ "$(grep -c '^create|' "$TRACE")" -eq 1 ]] \
    || fail "base clone unexpectedly created a blank image"
chmod 0644 "$VM_ROOT/_base/win10-base.qcow2"

# An explicit name must select that exact managed base, leaving the historical
# default and every sibling base untouched.
printf 'named-base-fixture\n' \
    >"$VM_ROOT/_base/win11-vgpu-v2.qcow2"
chmod 0444 "$VM_ROOT/_base/win11-vgpu-v2.qcow2"
"$CREATE_DISK" 23 --from-base --base-name win11-vgpu-v2 \
    >"$TMP_DIR/vm23.out"
cmp "$VM_ROOT/_base/win11-vgpu-v2.qcow2" \
    "$VM_ROOT/23/disk.qcow2" || fail "named base clone content differs"
grep -Fq "baseline 'win11-vgpu-v2'" "$TMP_DIR/vm23.out" \
    || fail "named base selection was not visible"
if "$CREATE_DISK" 24 --from-base --base-name '../escape' \
        >"$TMP_DIR/unsafe-name.out" 2>"$TMP_DIR/unsafe-name.err"; then
    fail "create-disk accepted an unsafe base name"
fi
[[ ! -e "$VM_ROOT/24/disk.qcow2" ]] \
    || fail "unsafe base name published a disk"

# The V-11-compatible exact path selects the same delivery/local image without
# copying it into VM_BASE_DIR first.
mkdir -p "$TMP_DIR/delivery"
EXACT_BASE="$TMP_DIR/delivery/win10-base.qcow2"
printf 'VIRTUAL_SIZE=512000000000\nexact-path-base\n' >"$EXACT_BASE"
chmod 0444 "$EXACT_BASE"
"$CREATE_DISK" 25 --from-base --base "$EXACT_BASE" \
    >"$TMP_DIR/vm25.out"
cmp "$EXACT_BASE" "$VM_ROOT/25/disk.qcow2" ||
    fail "exact-path base clone content differs"
grep -Fq "baseline 'win10-base'" "$TMP_DIR/vm25.out" ||
    fail "exact-path base selection was not visible"
if "$CREATE_DISK" 26 --from-base --base "$EXACT_BASE" \
        --base-name win10-base >/dev/null 2>&1; then
    fail "create-disk accepted both --base and --base-name"
fi

# V-11-style linked mode pins the exact base inode inside the instance and
# publishes a tiny overlay with a fixed relative backing name. Replacing the
# managed base path later must not retarget an existing VM.
LINKED_VM_ROOT="$TMP_DIR/linked-vms"
mkdir -p "$LINKED_VM_ROOT/_base" "$LINKED_VM_ROOT/27"
LINKED_BASE="$LINKED_VM_ROOT/_base/win10-base.qcow2"
"$REAL_QEMU_IMG" create -q -f qcow2 "$LINKED_BASE" 64M
printf '%s\n' 'SSD_SIZE_BYTES=67108864' >"$LINKED_VM_ROOT/27/vm.conf"
VM_ROOT="$LINKED_VM_ROOT" QEMU_IMG="$REAL_QEMU_IMG" DISK_GUARD=0 \
    "$CREATE_DISK" 27 --from-base --linked >"$TMP_DIR/linked.out"
LINKED_DISK="$LINKED_VM_ROOT/27/disk.qcow2"
LINKED_PIN="$LINKED_VM_ROOT/27/.base.qcow2"
[[ -f "$LINKED_DISK" && -f "$LINKED_PIN" && ! -L "$LINKED_PIN" &&
   "$LINKED_BASE" -ef "$LINKED_PIN" ]] ||
    fail "linked clone did not publish an instance-local hard-link pin"
"$REAL_JQ" -e \
    --arg fullBacking "$LINKED_PIN" '
    .format == "qcow2" and ."virtual-size" == 67108864 and
    ."backing-filename" == ".base.qcow2" and
    ."full-backing-filename" == $fullBacking and
    ."actual-size" < 4194304
' < <("$REAL_QEMU_IMG" info --output=json -- "$LINKED_DISK") >/dev/null ||
    fail "linked clone metadata is not a small relative overlay"
linked_pin_inode=$(stat -c %i -- "$LINKED_PIN")
LINKED_REPLACEMENT="$LINKED_VM_ROOT/_base/.win10-base.new.qcow2"
"$REAL_QEMU_IMG" create -q -f qcow2 "$LINKED_REPLACEMENT" 64M
mv -T -- "$LINKED_REPLACEMENT" "$LINKED_BASE"
[[ "$(stat -c %i -- "$LINKED_PIN")" == "$linked_pin_inode" &&
   ! "$LINKED_BASE" -ef "$LINKED_PIN" ]] ||
    fail "base replacement retargeted an existing linked clone"
"$REAL_QEMU_IMG" check -q "$LINKED_DISK" ||
    fail "linked clone broke after atomic managed-base replacement"
grep -Fq 'V-11 式增量盘' "$TMP_DIR/linked.out" ||
    fail "linked creation did not explain its disk mode"

if VM_ROOT="$LINKED_VM_ROOT" "$CREATE_DISK" 28 --from-base \
        --linked --full-copy >/dev/null 2>&1; then
    fail "create-disk accepted both linked and full-copy modes"
fi
if VM_ROOT="$LINKED_VM_ROOT" SIZE_BYTES=67108864 "$CREATE_DISK" 29 \
        --blank --linked >/dev/null 2>&1; then
    fail "create-disk accepted linked mode for a blank disk"
fi

# A profile larger than the baseline is safe: clone first, then grow only the
# private copy.  The shared baseline must stay at its original virtual size.
printf 'VIRTUAL_SIZE=500107862016\n' >"$VM_ROOT/_base/win10-base.qcow2"
mkdir -p "$VM_ROOT/20"
printf 'SSD_SIZE_BYTES=512110190592\n' \
    >"$VM_ROOT/20/vm.conf"
"$CREATE_DISK" 20 --from-base >"$TMP_DIR/grow-base.out"
[[ -f "$VM_ROOT/20/disk.qcow2" ]] \
    || fail "larger profile did not publish the grown base clone"
grep -Eq "^resize\|$VM_ROOT/20/\\.disk\\.qcow2\\.partial\\.[^|]+\\|512110190592$" \
    "$TRACE" || fail "larger profile did not resize its private partial clone"
grep -Fxq 'VIRTUAL_SIZE=512110190592' \
    "$VM_ROOT/20/disk.qcow2" \
    || fail "grown clone does not report the profile capacity"
grep -Fxq 'VIRTUAL_SIZE=500107862016' \
    "$VM_ROOT/_base/win10-base.qcow2" \
    || fail "growing a clone mutated the shared baseline"

# Shrinking a baseline is deliberately unsupported.  A 500 GB profile cannot
# clone a 512 GB baseline and must fail before publishing or calling resize.
printf 'VIRTUAL_SIZE=512110190592\n' >"$VM_ROOT/_base/win10-base.qcow2"
mkdir -p "$VM_ROOT/21"
printf 'SSD_SIZE_BYTES=500107862016\n' \
    >"$VM_ROOT/21/vm.conf"
resize_count_before=$(grep -c '^resize|' "$TRACE" || true)
if "$CREATE_DISK" 21 --from-base \
        >"$TMP_DIR/shrink-base.out" 2>"$TMP_DIR/shrink-base.err"; then
    fail "smaller profile accepted an unsafe baseline shrink"
fi
grep -Fq '小于 baseline' "$TMP_DIR/shrink-base.err" \
    || fail "baseline shrink refusal was not clear"
[[ ! -e "$VM_ROOT/21/disk.qcow2" ]] \
    || fail "baseline shrink refusal published a disk"
[[ "$(grep -c '^resize|' "$TRACE" || true)" -eq "$resize_count_before" ]] \
    || fail "baseline shrink refusal still invoked qemu-img resize"

# Forced blank creation also consumes the exact capacity in vm.conf when no
# SIZE_BYTES/positional override is supplied.
mkdir -p "$VM_ROOT/22"
printf 'SSD_SIZE_BYTES=500107862016\n' \
    >"$VM_ROOT/22/vm.conf"
"$CREATE_DISK" 22 --blank >"$TMP_DIR/profile-blank.out"
grep -Eq "^create\|$VM_ROOT/22/\\.disk\\.qcow2\\.partial\\.[^|]+\\|500107862016$" \
    "$TRACE" || fail "blank disk ignored vm.conf SSD_SIZE_BYTES"

REQUIRED_VM_ROOT="$TMP_DIR/required-vms"
if VM_ROOT="$REQUIRED_VM_ROOT" "$CREATE_DISK" 18 --from-base \
        >"$TMP_DIR/required.out" 2>"$TMP_DIR/required.err"; then
    fail "--from-base silently fell back to a blank disk"
fi
grep -Fq '要求从公共 base 创建，但文件不存在' "$TMP_DIR/required.err" || \
    fail "missing required base refusal was not clear"
[[ ! -e "$REQUIRED_VM_ROOT/18/disk.qcow2" ]] || \
    fail "--from-base missing-base refusal published a disk"

# A base with any backing file is not portable to disks/ and must be rejected.
printf 'BACKING=parent.qcow2\n' >"$VM_ROOT/_base/win10-base.qcow2"
if "$CREATE_DISK" 11 >"$TMP_DIR/backing.out" 2>"$TMP_DIR/backing.err"; then
    fail "base clone accepted a non-standalone base"
fi
grep -Fq 'base 必须是 standalone qcow2' "$TMP_DIR/backing.err" \
    || fail "non-standalone base refusal was not clear"
[[ ! -e "$VM_ROOT/11/disk.qcow2" ]] \
    || fail "non-standalone base published a VM disk"

# An explicitly requested blank install disk must not depend on the health of
# an unrelated public-base symlink. Normal clone mode still rejects it.
DANGLING_VM_ROOT="$TMP_DIR/dangling-vms"
mkdir -p "$DANGLING_VM_ROOT/_base"
ln -s missing-base.qcow2 "$DANGLING_VM_ROOT/_base/win10-base.qcow2"
VM_ROOT="$DANGLING_VM_ROOT" SIZE_BYTES=23456 "$CREATE_DISK" 16 --blank \
    >"$TMP_DIR/dangling-blank.out"
[[ -f "$DANGLING_VM_ROOT/16/disk.qcow2" ]] || \
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
mkdir -p "$DATA_VM_ROOT/_base"
(
    cd "$DATA_VM_ROOT/_base"
    "$REAL_QEMU_IMG" create -q -f qcow2 -o data_file=base.data \
        win10-base.qcow2 1M
)
if VM_ROOT="$DATA_VM_ROOT" QEMU_IMG="$REAL_QEMU_IMG" \
    "$CREATE_DISK" 15 >"$TMP_DIR/data.out" 2>"$TMP_DIR/data.err"; then
    fail "base clone accepted a qcow2 external data-file"
fi
grep -Fq '不能有 backing/data-file' "$TMP_DIR/data.err" \
    || fail "external-data-file base refusal was not clear"
[[ ! -e "$DATA_VM_ROOT/15/disk.qcow2" ]] \
    || fail "external-data-file base published a VM disk"

# qemu-img/check failure must clean the partial and never publish the target.
if FAIL_CHECK=1 "$CREATE_DISK" 12 --blank \
    >"$TMP_DIR/check-fail.out" 2>"$TMP_DIR/check-fail.err"; then
    fail "blank creation accepted a failed qemu-img check"
fi
[[ ! -e "$VM_ROOT/12/disk.qcow2" ]] \
    || fail "failed validation published a VM disk"
if find "$VM_ROOT/12" -maxdepth 1 -name '*.partial.*' -print | grep -q .; then
    fail "failed validation left a partial disk"
fi

mkdir -p "$VM_ROOT/14/run"
exec {DISK_HOLDER_FD}>"$VM_ROOT/14/run/disk.lock"
flock -x "$DISK_HOLDER_FD"
if "$CREATE_DISK" 14 --blank \
    >"$TMP_DIR/locked.out" 2>"$TMP_DIR/locked.err"; then
    fail "create-disk ignored the per-VM lifecycle lock"
fi
exec {DISK_HOLDER_FD}>&-
grep -Fq '磁盘正在被创建或删除' "$TMP_DIR/locked.err" \
    || fail "create-disk lock refusal was not clear"
[[ ! -e "$VM_ROOT/14/disk.qcow2" ]] \
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

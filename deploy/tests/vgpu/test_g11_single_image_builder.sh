#!/usr/bin/env bash
# Verify the one-command wrapper's V-11-style paths without touching a VM,
# licensed payload, NBD device, or Windows filesystem.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SOURCE="$ROOT/deploy/build-g11-private-base.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
TMP_DIR=$(mktemp -d /tmp/g11-single-builder-test.XXXXXXXX)
trap 'rm -rf -- "$TMP_DIR"' EXIT
HARNESS="$TMP_DIR/repo"
TRACE="$TMP_DIR/trace"
mkdir -p "$HARNESS/deploy/scripts" "$HARNESS/deploy/lib" "$HARNESS/bin"
cp -- "$SOURCE" "$HARNESS/deploy/build-g11-private-base.sh"
cp -- "$ROOT/deploy/lib/vm-storage.sh" "$HARNESS/deploy/lib/vm-storage.sh"
chmod +x "$HARNESS/deploy/build-g11-private-base.sh"

cat >"$HARNESS/deploy/scripts/seal-base.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'seal|root=%s|base=%s|archive=%s' "$VM_ROOT" "$VM_BASE_DIR" "$VM_BASE_ARCHIVE_DIR" >>"$TRACE"
printf '|%s' "$@" >>"$TRACE"
printf '\n' >>"$TRACE"
mkdir -p "$VM_BASE_DIR"
[[ ! -e "$VM_BASE_DIR/$2.qcow2" ]] || exit 73
printf 'fixture\n' >"$VM_BASE_DIR/$2.qcow2"
EOF

cat >"$HARNESS/deploy/package-vgpu-one-click.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'package' >>"$TRACE"
printf '|%s' "$@" >>"$TRACE"
printf '\n' >>"$TRACE"
EOF

cat >"$HARNESS/deploy/install-vgpu-portable-to-base.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'install' >>"$TRACE"
printf '|%s' "$@" >>"$TRACE"
printf '\n' >>"$TRACE"
EOF

cat >"$HARNESS/deploy/scripts/export-vgpu-base.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'export' >>"$TRACE"
printf '|%s' "$@" >>"$TRACE"
printf '\n' >>"$TRACE"
[[ "$1" == --in-place ]]
printf '{}\n' >"$3/$2.g11base"
mkdir -p "$VM_BASE_ARCHIVE_DIR"
EOF
chmod +x "$HARNESS/deploy/scripts/"*.sh \
    "$HARNESS/deploy/package-vgpu-one-click.sh" \
    "$HARNESS/deploy/install-vgpu-portable-to-base.sh"

cat >"$HARNESS/bin/qemu-img" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command_name=${1:-}
image=${*: -1}
case "$command_name" in
    info)
        virtual_size=512188612608
        backing=null
        [[ "$image" != */13/disk.qcow2 ]] || virtual_size=536870912000
        [[ "$image" != */backed-base.qcow2 ]] || backing='"../unexpected.qcow2"'
        printf '{"format":"qcow2","virtual-size":%s,"backing-filename":%s,"full-backing-filename":%s,"format-specific":{"data":{"data-file":null}}}\n' \
            "$virtual_size" "$backing" "$backing"
        ;;
    check)
        [[ "$image" != */corrupt-base.qcow2 ]]
        ;;
    compare)
        [[ "$image" != */different-base.qcow2 ]]
        ;;
    *)
        echo "unexpected fake qemu-img command: $*" >&2
        exit 2
        ;;
esac
EOF
cat >"$HARNESS/bin/lsof" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$HARNESS/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$HARNESS/bin/"*

VMS_DIR="$TMP_DIR/vms"
BASE_DIR="$VMS_DIR/_base"
mkdir -p "$VMS_DIR/8"
TRACE="$TRACE" "$HARNESS/deploy/build-g11-private-base.sh" 8 win10-base \
    --vms-dir="$VMS_DIR" --no-progress \
    >"$TMP_DIR/out"

grep -Fq "seal|root=$VMS_DIR|base=$BASE_DIR|archive=$BASE_DIR/archive|8|win10-base|--yes|--single-image" "$TRACE" ||
    fail "builder did not pass the selected V-11-style storage and seal mode"
grep -Fq 'package|--with-license-token' "$TRACE" ||
    fail "builder did not rebuild the licensed EXE from the current checkout"
grep -Fq 'install|--base-name|win10-base|--site-private|--sysprep-generalized|--single-image|--yes' "$TRACE" ||
    fail "builder did not request ephemeral installer rollback"
package_line=$(grep -nF 'package|--with-license-token' "$TRACE" | head -1 | cut -d: -f1)
install_line=$(grep -nF 'install|--base-name|win10-base' "$TRACE" | head -1 | cut -d: -f1)
[[ "$package_line" -lt "$install_line" ]] ||
    fail "builder did not package current source before offline injection"
grep -Fq "export|--in-place|win10-base|$BASE_DIR" "$TRACE" ||
    fail "builder did not create an in-place transfer manifest"
[[ -f "$BASE_DIR/win10-base.qcow2" && -f "$BASE_DIR/win10-base.g11base" ]] ||
    fail "builder did not retain the direct V-11-style filenames"
[[ ! -d "$BASE_DIR/archive" ]] ||
    fail "builder retained an empty archive directory"
grep -Fq -- "--vms-dir=$VMS_DIR --start" "$TMP_DIR/out" ||
    fail "builder did not print a directly usable local clone command"
if grep -Fq -- '--base-dir=' "$TMP_DIR/out"; then
    fail "default builder command unnecessarily printed a base-dir override"
fi

DEFAULT_IMAGE_ROOT="$TMP_DIR/default-images"
DEFAULT_VMS_DIR="$DEFAULT_IMAGE_ROOT/vms"
mkdir -p "$DEFAULT_VMS_DIR/9"
IMAGE_ROOT="$DEFAULT_IMAGE_ROOT" TRACE="$TRACE" \
    "$HARNESS/deploy/build-g11-private-base.sh" 9 default-base --no-progress \
    >"$TMP_DIR/default.out"
[[ -f "$DEFAULT_VMS_DIR/_base/default-base.qcow2" ]] ||
    fail "builder did not use IMAGE_ROOT/vms/_base by default"
grep -Fq -- \
    './deploy/scripts/clone-from-base.sh default-base NEW_VM_ID --start' \
    "$TMP_DIR/default.out" ||
    fail "default builder did not print the flag-free V-11-style clone command"
if grep -Fq -- '--vms-dir=' "$TMP_DIR/default.out" ||
        grep -Fq -- '--base-dir=' "$TMP_DIR/default.out"; then
    fail "default builder printed redundant storage overrides"
fi

prepare_resume_fixture() {
    local id=$1 base_name=$2 root=$3
    mkdir -p "$root/$id/run" "$root/_base"
    printf 'source-fixture\n' >"$root/$id/disk.qcow2"
    printf 'sealed-fixture\n' >"$root/_base/$base_name.qcow2"
}

# The only resumable checkpoint is the exact package-only failure state:
# standalone base present, no installer attestation/manifest/remnants, and a
# stopped source VM.  The seal command must not be called in this explicit mode.
RESUME_VMS="$TMP_DIR/resume-vms"
RESUME_TRACE="$TMP_DIR/resume.trace"
prepare_resume_fixture 10 resume-base "$RESUME_VMS"
: >"$RESUME_TRACE"
PATH="$HARNESS/bin:$PATH" QEMU_IMG="$HARNESS/bin/qemu-img" TRACE="$RESUME_TRACE" \
    "$HARNESS/deploy/build-g11-private-base.sh" 10 resume-base \
    --vms-dir="$RESUME_VMS" --resume-sealed \
    --token-file /private/outside-repository/token.tok --replace-licensed \
    >"$TMP_DIR/resume.out"
if grep -Fq 'seal|' "$RESUME_TRACE"; then
    fail "explicit sealed checkpoint resume unexpectedly reran seal-base"
fi
grep -Fq 'package|--token-file|/private/outside-repository/token.tok|--replace-licensed' \
    "$RESUME_TRACE" || fail "resume did not forward private package arguments"
grep -Fq 'install|--base-name|resume-base|--site-private|--sysprep-generalized|--single-image|--yes' \
    "$RESUME_TRACE" || fail "resume did not continue with private injection"
grep -Eq 'install\|.*--expect-base-state-sha256\|[0-9A-F]{64}' \
    "$RESUME_TRACE" || fail "resume did not carry the sealed base state into locked injection"
grep -Fq "export|--in-place|resume-base|$RESUME_VMS/_base" "$RESUME_TRACE" ||
    fail "resume did not finish the in-place export"
grep -Fq 'seal-base will be skipped only because --resume-sealed was explicit' \
    "$TMP_DIR/resume.out" || fail "resume did not disclose its seal skip"

# Without the explicit flag an existing base still reaches seal-base, which
# refuses it.  The wrapper must never infer or silently enter resume mode.
prepare_resume_fixture 11 existing-base "$RESUME_VMS"
: >"$RESUME_TRACE"
if TRACE="$RESUME_TRACE" \
        "$HARNESS/deploy/build-g11-private-base.sh" 11 existing-base \
        --vms-dir="$RESUME_VMS" --no-progress \
        >"$TMP_DIR/existing.out" 2>"$TMP_DIR/existing.err"; then
    fail "builder silently skipped seal for an existing base"
fi
grep -Fq 'seal|' "$RESUME_TRACE" ||
    fail "normal mode did not preserve the mandatory seal step"
if grep -Fq 'package|' "$RESUME_TRACE"; then
    fail "normal mode continued after seal-base refused the existing base"
fi

assert_resume_rejected() {
    local id=$1 base_name=$2 expected=$3
    : >"$RESUME_TRACE"
    if PATH="$HARNESS/bin:$PATH" QEMU_IMG="$HARNESS/bin/qemu-img" \
            TRACE="$RESUME_TRACE" \
            "$HARNESS/deploy/build-g11-private-base.sh" "$id" "$base_name" \
            --vms-dir="$RESUME_VMS" --resume-sealed \
            >"$TMP_DIR/reject-$id.out" 2>"$TMP_DIR/reject-$id.err"; then
        fail "resume accepted unsafe checkpoint vm$id/$base_name"
    fi
    grep -Fq "$expected" "$TMP_DIR/reject-$id.err" ||
        fail "resume rejection for vm$id did not explain: $expected"
    [[ ! -s "$RESUME_TRACE" ]] ||
        fail "resume invoked a mutating stage after rejecting vm$id"
}

prepare_resume_fixture 12 completed-base "$RESUME_VMS"
printf '{}\n' >"$RESUME_VMS/_base/completed-base.g11base"
assert_resume_rejected 12 completed-base 'requires a sealed-only checkpoint'

prepare_resume_fixture 13 mismatched-base "$RESUME_VMS"
assert_resume_rejected 13 mismatched-base 'virtual sizes differ'

prepare_resume_fixture 14 backed-base "$RESUME_VMS"
assert_resume_rejected 14 backed-base 'is not standalone'

prepare_resume_fixture 15 remnant-base "$RESUME_VMS"
printf 'preserved transaction\n' \
    >"$RESUME_VMS/_base/.remnant-base.qcow2.vgpu-portable.123.456"
assert_resume_rejected 15 remnant-base 'unfinished installer/export files exist'

prepare_resume_fixture 16 running-base "$RESUME_VMS"
LOCK_READY="$TMP_DIR/lock.ready"
(
    trap 'exit 0' TERM
    exec 9>"$RESUME_VMS/16/run/start.lock"
    flock -x 9
    : >"$LOCK_READY"
    while :; do
        read -r -t 0.1 _ || true
    done
) &
LOCK_HOLDER=$!
for _ in {1..100}; do
    [[ -e "$LOCK_READY" ]] && break
    sleep 0.01
done
[[ -e "$LOCK_READY" ]] || fail "test could not acquire the source VM start lock"
assert_resume_rejected 16 running-base 'is starting or running'
kill "$LOCK_HOLDER" 2>/dev/null || true
wait "$LOCK_HOLDER" 2>/dev/null || true

prepare_resume_fixture 17 tuned-base "$RESUME_VMS"
: >"$RESUME_TRACE"
if PATH="$HARNESS/bin:$PATH" QEMU_IMG="$HARNESS/bin/qemu-img" \
        TRACE="$RESUME_TRACE" \
        "$HARNESS/deploy/build-g11-private-base.sh" 17 tuned-base \
        --vms-dir="$RESUME_VMS" --resume-sealed --compression-type zlib \
        >"$TMP_DIR/tuned.out" 2>"$TMP_DIR/tuned.err"; then
    fail "resume accepted meaningless seal compression options"
fi
grep -Fq 'cannot be combined with compression/progress options' \
    "$TMP_DIR/tuned.err" || fail "resume did not explain rejected seal options"
[[ ! -s "$RESUME_TRACE" ]] || fail "rejected resume invoked a mutating stage"

prepare_resume_fixture 18 different-base "$RESUME_VMS"
assert_resume_rejected 18 different-base 'logical contents differ'

for unsafe_base_dir in '///' '/tmp/..'; do
    : >"$RESUME_TRACE"
    if TRACE="$RESUME_TRACE" \
            "$HARNESS/deploy/build-g11-private-base.sh" 19 unsafe-base \
            --vms-dir="$RESUME_VMS" --base-dir="$unsafe_base_dir" \
            >"$TMP_DIR/unsafe-base-dir.out" \
            2>"$TMP_DIR/unsafe-base-dir.err"; then
        fail "builder accepted a base directory that normalizes to root: $unsafe_base_dir"
    fi
    grep -Fq 'must remain non-root after normalization' \
        "$TMP_DIR/unsafe-base-dir.err" ||
        fail "root-normalizing base directory rejection was not explicit"
    [[ ! -s "$RESUME_TRACE" ]] ||
        fail "root-normalizing base directory reached a build stage"
done

echo "PASS: G-11 builder publishes one qcow2 and fail-closed resumes only a sealed checkpoint"

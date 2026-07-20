#!/usr/bin/env bash
# Fixture regression for clone-vgpu-base.sh.  The harness substitutes tiny
# create/start scripts and a text "base"; no real VM, qcow2 image, or NBD is
# opened.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CLONE_SOURCE="$REPO_ROOT/deploy/clone-vgpu-base.sh"
REAL_JQ=$(command -v jq || true)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -x "$CLONE_SOURCE" ]] || fail "clone script is missing or not executable"
[[ -n "$REAL_JQ" && -x "$REAL_JQ" ]] || fail "jq is required"
bash -n "$CLONE_SOURCE" || fail "clone script has invalid Bash syntax"

TMP_DIR=$(mktemp -d)
children=()
cleanup() {
    local pid
    for pid in "${children[@]}"; do
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
    done
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

HARNESS="$TMP_DIR/harness"
mkdir -p "$HARNESS/deploy/lib" "$HARNESS/bin"
cp -- "$CLONE_SOURCE" "$HARNESS/deploy/clone-vgpu-base.sh"
cp -- "$REPO_ROOT/deploy/lib/vm-storage.sh" "$HARNESS/deploy/lib/vm-storage.sh"
cp -- "$REPO_ROOT/deploy/lib/vgpu-profiles.sh" \
    "$HARNESS/deploy/lib/vgpu-profiles.sh"
chmod +x "$HARNESS/deploy/clone-vgpu-base.sh"

# jq wrapper gives the lock test an observable marker after sidecar parsing.
cat >"$HARNESS/bin/jq" <<EOF
#!/usr/bin/env bash
set -euo pipefail
"$REAL_JQ" "\$@"
rc=\$?
[[ -z "\${JQ_MARKER:-}" ]] || : >"\$JQ_MARKER"
exit "\$rc"
EOF
chmod +x "$HARNESS/bin/jq"

cat >"$HARNESS/deploy/create-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'create-vm'
    printf '|%s' "$@"
    printf '\n'
    printf 'create-vm-start-lock|%s\n' "${VM_START_LOCK_HELD:-<unset>}"
} >>"$TRACE"
id=$1
shift
profile=""
while (($#)); do
    case "$1" in
        --gpu-profile)
            profile=$2
            shift 2
            ;;
        --platform|--ssd-profile|--monitor-profile)
            shift 2
            ;;
        *)
            echo "unexpected create-vm fixture argument: $1" >&2
            exit 90
            ;;
    esac
done
[[ -n "$profile" ]]
instance="$VM_INSTANCES_DIR/vm$id"
mkdir -p "$instance"
spoof_mode=B
[[ "${STUB_BAD_CONF:-0}" != 1 ]] || spoof_mode=A
cat >"$instance/vm.conf" <<CONF
SPOOF_MODE='$spoof_mode'
GPU_PROFILE='$profile'
VM_UUID='00112233-4455-4677-8899-AABBCCDDEEFF'
CONF
EOF
chmod +x "$HARNESS/deploy/create-vm.sh"

cat >"$HARNESS/deploy/create-disk.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'create-disk'
    printf '|%s' "$@"
    printf '\n'
} >>"$TRACE"
[[ $# -eq 2 && "$2" == --from-base ]]
[[ "${STUB_DISK_FAIL:-0}" != 1 ]] || exit 91
[[ "${STUB_DISK_NO_PUBLISH:-0}" != 1 ]] || exit 0
mkdir -p "$VM_INSTANCES_DIR/vm$1"
printf 'standalone clone fixture\n' >"$VM_INSTANCES_DIR/vm$1/disk.qcow2"
[[ "${STUB_DISK_PUBLISH_FAIL:-0}" != 1 ]] || exit 92
EOF
chmod +x "$HARNESS/deploy/create-disk.sh"

cat >"$HARNESS/deploy/start-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
id=$1
exec {STORAGE_TEST_FD}>"$VM_RUN_DIR/.storage.lock"
flock -n -s "$STORAGE_TEST_FD"
exec {START_TEST_FD}>"$VM_RUN_DIR/vm${id}.start.lock"
flock -n -x "$START_TEST_FD"
{
    printf 'start-vm'
    printf '|%s' "$@"
    printf '\n'
} >>"$TRACE"
EOF
chmod +x "$HARNESS/deploy/start-vm.sh"

IMAGE_ROOT="$TMP_DIR/images"
VM_ROOT="$IMAGE_ROOT/vms"
VM_INSTANCES_DIR="$VM_ROOT/instances"
VM_BASE_DIR="$VM_ROOT/bases"
VM_RUN_DIR="$VM_ROOT/run"
TRACE="$TMP_DIR/trace"
BASE="$VM_BASE_DIR/win10-base.qcow2"
ATTESTATION="${BASE}.vgpu-portable.json"
export IMAGE_ROOT VM_ROOT VM_INSTANCES_DIR VM_BASE_DIR VM_RUN_DIR TRACE
export PATH="$HARNESS/bin:$PATH"
mkdir -p "$VM_BASE_DIR" "$VM_RUN_DIR"
printf 'portable-enabled standalone base fixture\n' >"$BASE"
chmod 0444 "$BASE"

# shellcheck source=../../../lib/vgpu-profiles.sh
source "$HARNESS/deploy/lib/vgpu-profiles.sh"
CATALOG_SHA256=$(vgpu_profile_catalog_sha256)

write_attestation() {
    local catalog=${1:-$CATALOG_SHA256}
    local extra_json=${2:-'{}'}
    local bytes device inode mtime ctime
    bytes=$(stat -c %s -- "$BASE")
    device=$(stat -c %D -- "$BASE")
    inode=$(stat -c %i -- "$BASE")
    mtime=$(stat -c %y -- "$BASE")
    ctime=$(stat -c %z -- "$BASE")
    rm -f -- "$ATTESTATION"
    "$REAL_JQ" -n \
        --arg basePath "$BASE" \
        --argjson baseFileBytes "$bytes" \
        --arg baseDeviceId "$device" \
        --arg baseInode "$inode" \
        --arg baseMtimeNs "$mtime" \
        --arg baseCtimeNs "$ctime" \
        --arg catalogSha256 "$catalog" \
        --argjson extra "$extra_json" '
        {
            schemaVersion: 2,
            bindingMode: "portable-auto",
            basePath: $basePath,
            baseFileBytes: $baseFileBytes,
            baseDeviceId: $baseDeviceId,
            baseInode: $baseInode,
            baseMtimeNs: $baseMtimeNs,
            baseCtimeNs: $baseCtimeNs,
            guestPath: "C:\\Users\\Public\\Desktop\\VgpuPortable.exe",
            exeSha256:
                "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
            exeBytes: 12270080,
            catalogSha256: $catalogSha256,
            installedUtc: "2026-07-20T10:00:00Z"
        } + $extra
    ' >"$ATTESTATION"
    chmod 0444 "$ATTESTATION"
}
write_attestation

run_clone() {
    "$HARNESS/deploy/clone-vgpu-base.sh" "$@"
}

# VM IDs are not tied to VM1/2/3.  All audited profiles and forwarded hardware
# selectors must reach the canonical create-vm/create-disk entry points.
run_clone 456 --gpu-profile gtx750ti_2gb >"$TMP_DIR/456.out"
grep -Fxq 'create-vm|456|--gpu-profile|gtx750ti_2gb' "$TRACE" ||
    fail "VM456 create-vm arguments are incorrect"
grep -Fxq 'create-vm-start-lock|1' "$TRACE" ||
    fail "clone did not tell create-vm that it owns the VM start lock"
grep -Fxq 'create-disk|456|--from-base' "$TRACE" ||
    fail "VM456 did not require the prepared base"

run_clone 987654 --gpu-profile gt1030_2gb \
    --platform office-intel \
    --ssd-profile samsung-970-pro-512gb \
    --monitor-profile lenovo-d24-20 >"$TMP_DIR/987654.out"
grep -Fxq \
    'create-vm|987654|--gpu-profile|gt1030_2gb|--platform|office-intel|--ssd-profile|samsung-970-pro-512gb|--monitor-profile|lenovo-d24-20' \
    "$TRACE" || fail "forwarded create-vm selectors are incorrect"
grep -Fxq 'create-disk|987654|--from-base' "$TRACE" ||
    fail "VM987654 did not clone from base"

run_clone 2147483647 --gpu-profile gtx1050_2gb --start \
    >"$TMP_DIR/max-id.out"
grep -Fxq 'create-vm|2147483647|--gpu-profile|gtx1050_2gb' "$TRACE" ||
    fail "maximum supported VM ID was not forwarded"
grep -Fxq 'create-disk|2147483647|--from-base' "$TRACE" ||
    fail "maximum supported VM ID disk was not cloned"
grep -Fxq 'start-vm|2147483647' "$TRACE" ||
    fail "--start did not release its locks and invoke start-vm"
grep -Fq 'C:\Users\Public\Desktop\VgpuPortable.exe' "$TMP_DIR/max-id.out" ||
    fail "clone handoff omitted the offline guest EXE path"

# Invalid IDs/profiles and duplicate IDs fail before any helper is invoked.
for args in \
        '0' \
        '0003' \
        '2147483648' \
        'abc' \
        '41 42' \
        '41 --gpu-profile definitely-not-a-profile'; do
    before=$(wc -l <"$TRACE")
    # This deliberate word split feeds the individual fixture arguments.
    # shellcheck disable=SC2086
    if run_clone $args >"$TMP_DIR/reject.out" 2>"$TMP_DIR/reject.err"; then
        fail "clone accepted invalid arguments: $args"
    fi
    [[ "$(wc -l <"$TRACE")" -eq "$before" ]] ||
        fail "invalid arguments invoked a helper: $args"
done

# Existing identity or disk state is never overwritten.
mkdir -p "$VM_INSTANCES_DIR/vm600"
printf 'SPOOF_MODE=B\n' >"$VM_INSTANCES_DIR/vm600/vm.conf"
before=$(wc -l <"$TRACE")
if run_clone 600 >"$TMP_DIR/existing-conf.out" 2>"$TMP_DIR/existing-conf.err"; then
    fail "clone accepted an existing VM configuration"
fi
[[ "$(wc -l <"$TRACE")" -eq "$before" ]] ||
    fail "existing VM configuration invoked a helper"

mkdir -p "$VM_INSTANCES_DIR/vm601"
printf 'existing disk\n' >"$VM_INSTANCES_DIR/vm601/disk.qcow2"
if run_clone 601 >"$TMP_DIR/existing-disk.out" 2>"$TMP_DIR/existing-disk.err"; then
    fail "clone accepted an existing VM disk"
fi
[[ "$(wc -l <"$TRACE")" -eq "$before" ]] ||
    fail "existing VM disk invoked a helper"

# Sidecar schema/path/generation/catalog mismatches all fail before create-vm.
write_attestation "$CATALOG_SHA256" '{"unexpected":true}'
if run_clone 610 >"$TMP_DIR/extra.out" 2>"$TMP_DIR/extra.err"; then
    fail "clone accepted an attestation with extra keys"
fi
write_attestation \
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
if run_clone 611 >"$TMP_DIR/catalog.out" 2>"$TMP_DIR/catalog.err"; then
    fail "clone accepted a base built from a different GPU catalog"
fi

write_attestation
chmod u+w "$BASE"
printf 'changed\n' >>"$BASE"
chmod 0444 "$BASE"
if run_clone 612 >"$TMP_DIR/size.out" 2>"$TMP_DIR/size.err"; then
    fail "clone accepted a base whose size changed after installation"
fi

chmod u+w "$BASE"
printf 'portable-enabled standalone base fixture\n' >"$BASE"
chmod 0444 "$BASE"
write_attestation
recorded_mtime=$(stat -c %Y -- "$BASE")
touch -m -d "@$((recorded_mtime + 5))" "$BASE"
if run_clone 613 >"$TMP_DIR/mtime.out" 2>"$TMP_DIR/mtime.err"; then
    fail "clone accepted a base whose mtime changed after installation"
fi

touch -m -d "@$recorded_mtime" "$BASE"
write_attestation
mv -- "$ATTESTATION" "$ATTESTATION.real"
ln -s -- "$(basename "$ATTESTATION.real")" "$ATTESTATION"
if run_clone 614 >"$TMP_DIR/link.out" 2>"$TMP_DIR/link.err"; then
    fail "clone accepted a symlink attestation"
fi
rm -- "$ATTESTATION"
mv -- "$ATTESTATION.real" "$ATTESTATION"

# Failures after this wrapper creates vm.conf roll it back only when no disk
# was published.  A published disk keeps its matching identity configuration
# so recovery never leaves an anonymous/orphan guest disk.
export STUB_BAD_CONF=1
if run_clone 620 >"$TMP_DIR/bad-conf.out" 2>"$TMP_DIR/bad-conf.err"; then
    fail "clone accepted a non-B configuration from create-vm"
fi
unset STUB_BAD_CONF
[[ ! -e "$VM_INSTANCES_DIR/vm620/vm.conf" ]] ||
    fail "invalid newly-created configuration was not rolled back"
[[ ! -e "$VM_INSTANCES_DIR/vm620/disk.qcow2" ]] ||
    fail "invalid configuration still reached disk creation"

export STUB_DISK_FAIL=1
if run_clone 621 >"$TMP_DIR/disk-fail.out" 2>"$TMP_DIR/disk-fail.err"; then
    fail "clone accepted a create-disk failure"
fi
unset STUB_DISK_FAIL
[[ ! -e "$VM_INSTANCES_DIR/vm621/vm.conf" ]] ||
    fail "configuration was not rolled back after pre-publication disk failure"
[[ ! -e "$VM_INSTANCES_DIR/vm621/disk.qcow2" ]] ||
    fail "pre-publication failure unexpectedly left a disk"

export STUB_DISK_NO_PUBLISH=1
if run_clone 622 >"$TMP_DIR/no-disk.out" 2>"$TMP_DIR/no-disk.err"; then
    fail "clone accepted create-disk success without a published disk"
fi
unset STUB_DISK_NO_PUBLISH
[[ ! -e "$VM_INSTANCES_DIR/vm622/vm.conf" ]] ||
    fail "configuration was not rolled back when create-disk published nothing"

export STUB_DISK_PUBLISH_FAIL=1
if run_clone 623 >"$TMP_DIR/published-fail.out" \
        2>"$TMP_DIR/published-fail.err"; then
    fail "clone accepted create-disk failure after disk publication"
fi
unset STUB_DISK_PUBLISH_FAIL
[[ -f "$VM_INSTANCES_DIR/vm623/vm.conf" &&
   -f "$VM_INSTANCES_DIR/vm623/disk.qcow2" ]] ||
    fail "published disk did not retain its matching recovery configuration"

# Hold the same exclusive lock used by the base installer.  Clone must acquire
# its shared lock before parsing the sidecar, then retain it through both child
# operations.  The jq marker makes a missing/late lock deterministic.
JQ_MARKER="$TMP_DIR/jq-after-lock"
export JQ_MARKER
rm -f -- "$JQ_MARKER"
exec {LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -x "$LOCK_FD"
run_clone 700 >"$TMP_DIR/locked.out" 2>"$TMP_DIR/locked.err" &
locked_pid=$!
children+=("$locked_pid")
for _ in {1..100}; do
    [[ ! -e "$JQ_MARKER" ]] ||
        fail "clone parsed the sidecar before acquiring the storage lock"
    kill -0 "$locked_pid" >/dev/null 2>&1 ||
        fail "clone did not wait for the base installer's exclusive lock"
    sleep 0.01
done
flock -u "$LOCK_FD"
wait "$locked_pid" || fail "clone failed after the storage lock was released"
children=()
grep -Fxq 'create-vm|700|--gpu-profile|gtx1050_2gb' "$TRACE" ||
    fail "lock-delayed clone did not create its VM"
grep -Fxq 'create-disk|700|--from-base' "$TRACE" ||
    fail "lock-delayed clone did not create its disk"

# A busy per-VM lifecycle lock must fail before sidecar parsing or helper
# invocation, preventing start/delete/concurrent-clone races between config and
# disk publication.
before=$(wc -l <"$TRACE")
rm -f -- "$JQ_MARKER"
exec {VM_LOCK_FD}>"$VM_RUN_DIR/vm701.start.lock"
flock -x "$VM_LOCK_FD"
if run_clone 701 >"$TMP_DIR/vm-lock.out" 2>"$TMP_DIR/vm-lock.err"; then
    fail "clone ignored a busy per-VM start lock"
fi
flock -u "$VM_LOCK_FD"
[[ ! -e "$JQ_MARKER" ]] ||
    fail "busy per-VM lock was checked after sidecar parsing"
[[ "$(wc -l <"$TRACE")" -eq "$before" ]] ||
    fail "busy per-VM lock still invoked a helper"
grep -Fq 'starting, running, or being modified' "$TMP_DIR/vm-lock.err" ||
    fail "busy per-VM lock refusal was not clear"

echo "PASS: portable base clone is VM-unbound, profile-aware, attested and lifecycle-lock safe"

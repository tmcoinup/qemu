#!/usr/bin/env bash
# Fixture regression for the canonical clone-from-base.sh.  The harness substitutes tiny
# create/start scripts and a text "base"; no real VM, qcow2 image, or NBD is
# opened.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CLONE_SOURCE="$REPO_ROOT/deploy/scripts/clone-from-base.sh"
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
mkdir -p "$HARNESS/deploy/lib" "$HARNESS/deploy/scripts" "$HARNESS/bin"
cp -- "$CLONE_SOURCE" "$HARNESS/deploy/scripts/clone-from-base.sh"
cp -- "$REPO_ROOT/deploy/lib/vm-storage.sh" "$HARNESS/deploy/lib/vm-storage.sh"
cp -- "$REPO_ROOT/deploy/lib/vgpu-profiles.sh" \
    "$HARNESS/deploy/lib/vgpu-profiles.sh"
cp -- "$REPO_ROOT/deploy/lib/gpuz-assets.sh" \
    "$HARNESS/deploy/lib/gpuz-assets.sh"
chmod +x "$HARNESS/deploy/scripts/clone-from-base.sh"

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

cat >"$HARNESS/deploy/scripts/create-vm.sh" <<'EOF'
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
vram=""
while (($#)); do
    case "$1" in
        --gpu-profile)
            profile=$2
            shift 2
            ;;
        --gpu-vram)
            vram=$2
            shift 2
            ;;
        --platform|--cpu-profile|--board-profile|--memory-profile|--memory-size|--ssd-profile|--monitor-profile)
            shift 2
            ;;
        --allow-fallback-platform)
            shift
            ;;
        *)
            echo "unexpected create-vm fixture argument: $1" >&2
            exit 90
            ;;
    esac
done
if [[ "$vram" == 1024 ]]; then
    profile=gtx750_asus_1gb
elif [[ "$vram" == 2048 ]]; then
    profile=gtx1050_colorful_2gb
fi
[[ -n "$profile" ]] || profile=gtx1050_colorful_2gb
instance="$VM_INSTANCES_DIR/$id"
mkdir -p "$instance"
spoof_mode=B
[[ "${STUB_BAD_CONF:-0}" != 1 ]] || spoof_mode=A
cat >"$instance/vm.conf" <<CONF
VM_ID='$id'
SPOOF_MODE='$spoof_mode'
GPU_PROFILE='$profile'
MONITOR_PROFILE='dell-p2419h'
VM_UUID='00112233-4455-4677-8899-AABBCCDDEEFF'
CONF
EOF
chmod +x "$HARNESS/deploy/scripts/create-vm.sh"

cat >"$HARNESS/deploy/package-system-nvapi-projection.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
requested_id=$1
conf="$VM_INSTANCES_DIR/$requested_id/vm.conf"
config_sha=$(sha256sum -- "$conf" | awk '{print toupper($1)}')
unset VM_ID VM_UUID GPU_PROFILE MONITOR_PROFILE
# shellcheck source=/dev/null
source "$conf"
[[ "$VM_ID" == "$requested_id" ]]
uuid=${VM_UUID,,}
root="$VM_INSTANCES_DIR/$requested_id/packages/SystemNvapiProjection"
temporary="$root/.contract.json"
jq -n \
    --argjson vmId "$requested_id" \
    --arg vmUuid "$uuid" \
    --arg profile "$GPU_PROFILE" \
    --arg monitor "$MONITOR_PROFILE" \
    --arg configSha "$config_sha" '
    {
        schemaVersion: 4,
        purpose: "g11-system-nvapi-projection",
        contractId: "",
        vmId: $vmId,
        vmUuid: $vmUuid,
        identityCatalogSha256: ("E" * 64),
        sourceConfigSha256: $configSha,
        profile: {key: $profile},
        monitor: {key: $monitor},
        transport: {
            targetPnpId: "PCI\\VEN_10DE&DEV_1E30",
            driverVersion: "31.0.15.3833"
        },
        payload: {
            shimX86Sha256: ("A" * 64),
            shimX64Sha256: ("B" * 64)
        }
    }' >"$temporary"
contract_id=$(jq -cS 'del(.contractId)' "$temporary" |
    sha256sum | awk '{print toupper($1)}')
stem="vm${requested_id}-${uuid}-${contract_id:0:16}"
payload="$root/$stem"
mkdir -m 0700 -- "$payload"
jq --arg contractId "$contract_id" '.contractId = $contractId' \
    "$temporary" >"$payload/system-nvapi-contract.json"
rm -f -- "$temporary"
jq -n --arg contractId "$contract_id" '
    {
        schemaVersion: 1,
        purpose: "g11-system-nvapi-projection",
        contractId: $contractId,
        files: [range(0; 12) | {
            path: ("fixture" + (tostring)), bytes: 1, sha256: ("F" * 64)
        }]
    }' >"$payload/system-nvapi-manifest.json"
printf 'read-only per-VM ISO fixture\n' >"$root/$stem.iso"
chmod 0600 "$root/$stem.iso"
printf 'system-nvapi-package|%s|%s\n' "$requested_id" "$contract_id" >>"$TRACE"
EOF
chmod +x "$HARNESS/deploy/package-system-nvapi-projection.sh"

cat >"$HARNESS/deploy/scripts/create-disk.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'create-disk'
    printf '|%s' "$@"
    printf '\n'
} >>"$TRACE"
[[ $# -eq 5 && "$2" == --from-base ]]
case "$3" in
    --base-name) [[ "$4" =~ ^[A-Za-z0-9_-]+$ ]] ;;
    --base) [[ "$4" == /* && "$4" == *.qcow2 && -f "$4" ]] ;;
    *) exit 89 ;;
esac
[[ "$5" == --linked || "$5" == --full-copy ]]
[[ "${STUB_DISK_FAIL:-0}" != 1 ]] || exit 91
[[ "${STUB_DISK_NO_PUBLISH:-0}" != 1 ]] || exit 0
mkdir -p "$VM_INSTANCES_DIR/$1"
if [[ "$5" == --linked ]]; then
    if [[ "$3" == --base-name ]]; then
        selected_base="$VM_BASE_DIR/$4.qcow2"
    else
        selected_base=$4
    fi
    ln -- "$selected_base" "$VM_INSTANCES_DIR/$1/.base.qcow2"
    printf 'linked clone fixture\n' >"$VM_INSTANCES_DIR/$1/disk.qcow2"
else
    printf 'standalone clone fixture\n' >"$VM_INSTANCES_DIR/$1/disk.qcow2"
fi
[[ "${STUB_DISK_PUBLISH_FAIL:-0}" != 1 ]] || exit 92
EOF
chmod +x "$HARNESS/deploy/scripts/create-disk.sh"

cat >"$HARNESS/deploy/scripts/sync-monitor-profile.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'monitor-sync'
    printf '|%s' "$@"
    printf '|start-lock=%s\n' "${VM_START_LOCK_HELD:-<unset>}"
} >>"$TRACE"
exit "${STUB_MONITOR_SYNC_RC:-0}"
EOF
chmod +x "$HARNESS/deploy/scripts/sync-monitor-profile.sh"

cat >"$HARNESS/deploy/scripts/start-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
id=$1
exec {STORAGE_TEST_FD}>"$VM_RUN_DIR/.storage.lock"
flock -n -s "$STORAGE_TEST_FD"
exec {START_TEST_FD}>"$VM_INSTANCES_DIR/${id}/run/start.lock"
flock -n -x "$START_TEST_FD"
{
    printf 'start-vm'
    printf '|%s' "$@"
    printf '\n'
} >>"$TRACE"
EOF
chmod +x "$HARNESS/deploy/scripts/start-vm.sh"

IMAGE_ROOT="$TMP_DIR/images"
VM_ROOT="$IMAGE_ROOT/vms"
VM_INSTANCES_DIR="$VM_ROOT/instances"
VM_BASE_DIR="$VM_ROOT/bases"
VM_RUN_DIR="$VM_ROOT/run"
TRACE="$TMP_DIR/trace"
BASE_NAME=win10-base
BASE="$VM_BASE_DIR/${BASE_NAME}.qcow2"
ATTESTATION="${BASE}.vgpu-portable.json"
export IMAGE_ROOT VM_ROOT VM_INSTANCES_DIR VM_BASE_DIR VM_RUN_DIR TRACE
export PATH="$HARNESS/bin:$PATH"
mkdir -p "$VM_BASE_DIR" "$VM_RUN_DIR"
printf 'portable-enabled standalone base fixture\n' >"$BASE"
chmod 0444 "$BASE"

# shellcheck source=../../../lib/vgpu-profiles.sh
source "$HARNESS/deploy/lib/vgpu-profiles.sh"
# shellcheck source=../../../lib/gpuz-assets.sh
source "$HARNESS/deploy/lib/gpuz-assets.sh"
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
            schemaVersion: 5,
            bindingMode: "portable-auto",
            basePath: $basePath,
            baseFileBytes: $baseFileBytes,
            baseDeviceId: $baseDeviceId,
            baseInode: $baseInode,
            baseMtimeNs: $baseMtimeNs,
            baseCtimeNs: $baseCtimeNs,
            portableGuestPath:
                "C:\\Users\\Public\\Desktop\\VgpuPortable.exe",
            portableSha256:
                "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
            portableBytes: 1048576,
            gpuZDelivery: "optional-explicit-sibling",
            gpuZIncluded: false,
            gpuZGuestPath: null,
            gpuZSha256: null,
            gpuZBytes: null,
            guestPerformance: "embedded-recommended-native-v1",
            catalogSha256: $catalogSha256,
            installedUtc: "2026-07-20T10:00:00Z"
        } + $extra
    ' >"$ATTESTATION"
    chmod 0444 "$ATTESTATION"
}

write_private_attestation() {
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
        --arg catalogSha256 "$CATALOG_SHA256" '
        {
            schemaVersion: 7,
            bindingMode: "portable-auto",
            deploymentMode: "site-private-licensed-firstboot-v2",
            basePath: $basePath,
            baseFileBytes: $baseFileBytes,
            baseDeviceId: $baseDeviceId,
            baseInode: $baseInode,
            baseMtimeNs: $baseMtimeNs,
            baseCtimeNs: $baseCtimeNs,
            portableGuestPath: "C:\\ProgramData\\VMate\\G11\\VgpuPortable.exe",
            portableSha256: ("A" * 64),
            portableBytes: 1048576,
            firstBootScriptGuestPath: "C:\\ProgramData\\VMate\\G11\\Finalize-Clone.ps1",
            firstBootScriptSha256: ("B" * 64),
            retryGuestPath: "C:\\ProgramData\\VMate\\G11\\Retry-Clone-Initialization.cmd",
            retrySha256: ("C" * 64),
            sysprepAnswerGuestPath: "C:\\Windows\\Panther\\unattend.xml",
            sysprepAnswerSha256: ("D" * 64),
            windowsGeneralized: true,
            oobeMode: "unattended-auto-finalize",
            licenseDelivery: "embedded-private-shared-token",
            firstBootWorkflow: "licensed-portable-system-nvapi-two-boot-v1",
            systemNvapiDelivery: "per-vm-read-only-iso",
            systemNvapiRequired: true,
            dlsHost: "dls.gvmates.com",
            dlsPort: 443,
            guestPerformance: "embedded-recommended-native-v1",
            catalogSha256: $catalogSha256,
            installedUtc: "2026-08-19T00:00:00Z"
        }
    ' >"$ATTESTATION"
    chmod 0400 "$ATTESTATION"
}

write_legacy_attestation() {
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
        --arg catalogSha256 "$CATALOG_SHA256" '
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
        }
    ' >"$ATTESTATION"
    chmod 0444 "$ATTESTATION"
}
write_attestation

run_clone() {
    "$HARNESS/deploy/scripts/clone-from-base.sh" "$BASE_NAME" "$@"
}

if "$HARNESS/deploy/scripts/clone-from-base.sh" 453 \
        >"$TMP_DIR/missing-base-name.out" 2>"$TMP_DIR/missing-base-name.err"; then
    fail "canonical clone guessed a base name"
fi
grep -Fq 'BASE_NAME_OR_QCOW2 NEW_VM_ID' "$TMP_DIR/missing-base-name.err" ||
    fail "missing clone base selector usage error was not clear"

# Every managed name selects its own qcow2 and its own attestation.  A second
# generation must be cloneable without renaming or replacing win10-base.
FIRST_BASE_NAME=$BASE_NAME
FIRST_BASE=$BASE
FIRST_ATTESTATION=$ATTESTATION
BASE_NAME=win11-vgpu-v2
BASE="$VM_BASE_DIR/${BASE_NAME}.qcow2"
ATTESTATION="${BASE}.vgpu-portable.json"
printf 'second portable-enabled standalone base fixture\n' >"$BASE"
chmod 0444 "$BASE"
write_attestation
run_clone 455 --no-monitor-sync >"$TMP_DIR/named-base.out"
grep -Fxq 'create-disk|455|--from-base|--base-name|win11-vgpu-v2|--linked' "$TRACE" ||
    fail "second named base was not forwarded to create-disk"
grep -Fq 'base name:   win11-vgpu-v2' "$TMP_DIR/named-base.out" ||
    fail "clone handoff omitted the selected named base"

BASE_NAME=$FIRST_BASE_NAME
BASE=$FIRST_BASE
ATTESTATION=$FIRST_ATTESTATION
mapfile -t listed_bases < <(run_clone --list-bases)
[[ "${listed_bases[*]}" == 'win10-base win11-vgpu-v2' ]] ||
    fail "--list-bases did not expose both managed generations"
mapfile -t cli_dir_bases < <(
    "$HARNESS/deploy/scripts/clone-from-base.sh" \
        --base-dir="$VM_BASE_DIR" --list-bases
)
[[ "${cli_dir_bases[*]}" == 'win10-base win11-vgpu-v2' ]] ||
    fail "V-11-style --base-dir did not select the requested base directory"
if "$HARNESS/deploy/scripts/clone-from-base.sh" 'bad.name' 454 \
        >"$TMP_DIR/unsafe-base.out" 2>"$TMP_DIR/unsafe-base.err"; then
    fail "clone accepted an unsafe base name"
fi
grep -Fq 'invalid base name' "$TMP_DIR/unsafe-base.err" ||
    fail "unsafe clone base-name refusal was not clear"

run_clone --list-gpu-profiles >"$TMP_DIR/profiles.out"
[[ "$(tail -n +2 "$TMP_DIR/profiles.out" | wc -l)" -eq 25 ]] ||
    fail "clone did not expose all 25 atomic model/AIB/VRAM-maker rows"
[[ "${#VGPU_DEFAULT_PROFILE_KEYS[@]}" -eq 12 &&
   "${#VGPU_TIER_1024_PROFILE_KEYS[@]}" -eq 4 &&
   "${#VGPU_EXPLICIT_PROFILE_KEYS[@]}" -eq 1 &&
   "${#VGPU_LEGACY_PROFILE_KEYS[@]}" -eq 8 ]] ||
    fail "clone catalog lost the 12 default / 4 tier / 1 explicit / 8 legacy policy"

# Like V-11, the same local/delivery qcow2 can be selected by exact path.
"$HARNESS/deploy/scripts/clone-from-base.sh" "$BASE" 452 --no-monitor-sync \
    >"$TMP_DIR/path-base.out"
grep -Fxq "create-disk|452|--from-base|--base|$BASE|--linked" "$TRACE" ||
    fail "exact qcow2 path was not forwarded without making another base copy"
grep -Fq "base image:  $BASE" "$TMP_DIR/path-base.out" ||
    fail "exact-path clone handoff omitted the selected image"
grep -Fq 'disk mode:   linked (incremental / V-11-style)' \
    "$TMP_DIR/path-base.out" ||
    fail "default clone did not report V-11-style incremental disk mode"

# A full standalone copy remains an explicit escape hatch, never the default.
run_clone 451 --full-copy --no-monitor-sync >"$TMP_DIR/full-copy.out"
grep -Fxq 'create-disk|451|--from-base|--base-name|win10-base|--full-copy' \
    "$TRACE" || fail "explicit full-copy mode was not forwarded"
grep -Fq 'disk mode:   copy (standalone full copy)' \
    "$TMP_DIR/full-copy.out" || fail "full-copy mode was not visible"

# VM IDs are not tied to VM1/2/3.  All audited profiles and forwarded hardware
# selectors must reach the canonical create-vm/create-disk entry points.
run_clone 456 --gpu-profile gtx750ti_2gb >"$TMP_DIR/456.out"
grep -Fxq 'create-vm|456|--gpu-profile|gtx750ti_2gb' "$TRACE" ||
    fail "VM456 create-vm arguments are incorrect"
grep -Fxq 'create-vm-start-lock|1' "$TRACE" ||
    fail "clone did not tell create-vm that it owns the VM start lock"
grep -Fxq 'create-disk|456|--from-base|--base-name|win10-base|--linked' "$TRACE" ||
    fail "VM456 did not require the prepared base"
grep -Fxq 'monitor-sync|456|start-lock=1' "$TRACE" ||
    fail "VM456 did not automatically apply its generated monitor profile"
grep -Fq 'automatic sync=complete' "$TMP_DIR/456.out" ||
    fail "clone handoff did not report completed automatic monitor sync"

run_clone 987654 --gpu-profile gt1030_2gb \
    --platform office-intel \
    --ssd-profile samsung-970-pro-512gb \
    --monitor-profile lenovo-d24-20 >"$TMP_DIR/987654.out"
grep -Fxq \
    'create-vm|987654|--gpu-profile|gt1030_2gb|--platform|office-intel|--ssd-profile|samsung-970-pro-512gb|--monitor-profile|lenovo-d24-20' \
    "$TRACE" || fail "forwarded create-vm selectors are incorrect"
grep -Fxq 'create-disk|987654|--from-base|--base-name|win10-base|--linked' "$TRACE" ||
    fail "VM987654 did not clone from base"
grep -Fxq 'monitor-sync|987654|start-lock=1' "$TRACE" ||
    fail "explicit monitor profile was not automatically synchronized"

run_clone 987655 --gpu-vram 1024 --memory-size 6G \
    --allow-fallback-platform --no-monitor-sync >"$TMP_DIR/987655.out"
grep -Fxq \
    'create-vm|987655|--gpu-vram|1024|--memory-size|6G|--allow-fallback-platform' \
    "$TRACE" || fail "capacity/fallback selectors were not forwarded"

# Every catalog row, including non-reference AIB and VRAM-maker variants, is
# accepted by the same VM-unbound clone path without repackaging.
profile_vm=800
while IFS= read -r profile; do
    run_clone "$profile_vm" --gpu-profile "$profile" --no-monitor-sync \
        >"$TMP_DIR/profile-${profile}.out"
    grep -Fxq "create-vm|${profile_vm}|--gpu-profile|${profile}" "$TRACE" ||
        fail "clone did not forward atomic profile $profile"
    profile_vm=$((profile_vm + 1))
done < <(vgpu_profile_keys)

# A base may include GPU-Z only by explicit opt-in; the true state must bind
# all exact fields and remains a valid clone source.
write_attestation "$CATALOG_SHA256" \
    '{"gpuZIncluded":true,"gpuZGuestPath":"C:\\Users\\Public\\Desktop\\GPU-Z.exe","gpuZSha256":"6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29","gpuZBytes":11642144}'
run_clone 830 --no-monitor-sync >"$TMP_DIR/gpuz-included.out"
grep -Fxq 'create-vm|830' "$TRACE" ||
    fail "default clone pinned a fixed GPU instead of delegating random selection"
grep -Fq 'GPU profile: gtx1050_colorful_2gb' \
    "$TMP_DIR/gpuz-included.out" ||
    fail "default clone did not report the GPU selected by create-vm"
grep -Fq 'GPU-Z:       included by explicit base opt-in' \
    "$TMP_DIR/gpuz-included.out" ||
    fail "clone did not report the attested explicit GPU-Z opt-in"
write_attestation

run_clone 2147483647 --gpu-profile gtx1050_2gb --start \
    >"$TMP_DIR/max-id.out"
grep -Fxq 'create-vm|2147483647|--gpu-profile|gtx1050_2gb' "$TRACE" ||
    fail "maximum supported VM ID was not forwarded"
grep -Fxq 'create-disk|2147483647|--from-base|--base-name|win10-base|--linked' "$TRACE" ||
    fail "maximum supported VM ID disk was not cloned"
grep -Fxq 'start-vm|2147483647' "$TRACE" ||
    fail "--start did not release its locks and invoke start-vm"
grep -Fq 'C:\Users\Public\Desktop\VgpuPortable.exe' "$TMP_DIR/max-id.out" ||
    fail "clone handoff omitted the offline guest EXE path"
grep -Fq 'GPU-Z:       not included (default)' "$TMP_DIR/max-id.out" ||
    fail "clone handoff did not report the default no-GPU-Z state"
grep -Fq 'performance: embedded recommended-native-v1' "$TMP_DIR/max-id.out" ||
    fail "clone handoff omitted the attested guest performance profile"

# Monitor handling is automatic even without --start.  A pristine base may
# need one guest enumeration; that is a successful deferred state, while the
# next normal start remains responsible for retrying it.
export STUB_MONITOR_SYNC_RC=10
run_clone 457 >"$TMP_DIR/monitor-deferred.out"
unset STUB_MONITOR_SYNC_RC
grep -Fxq 'monitor-sync|457|start-lock=1' "$TRACE" ||
    fail "first-enumeration clone did not invoke automatic monitor sync"
grep -Fq 'automatic sync=first-enumeration-deferred' \
    "$TMP_DIR/monitor-deferred.out" ||
    fail "first-enumeration deferral was not explained in the clone handoff"

# Rescue/debug opt-out must be explicit and is forwarded to an immediate
# start so clone and start do not silently disagree about operator intent.
before_monitor=$(grep -c '^monitor-sync|' "$TRACE" || true)
run_clone 458 --no-monitor-sync >"$TMP_DIR/monitor-disabled.out"
after_monitor=$(grep -c '^monitor-sync|' "$TRACE" || true)
[[ "$after_monitor" -eq "$before_monitor" ]] ||
    fail "--no-monitor-sync still invoked the monitor helper"
grep -Fq 'automatic sync=disabled' "$TMP_DIR/monitor-disabled.out" ||
    fail "monitor opt-out was not visible in the clone handoff"

run_clone 459 --no-monitor-sync --start >"$TMP_DIR/monitor-disabled-start.out"
grep -Fxq 'start-vm|459|--no-monitor-sync' "$TRACE" ||
    fail "monitor opt-out was not forwarded to --start"

# A private generalized base publishes its host gate before the disk commit,
# defers monitor mutation until one-click initialization, and may start only
# the intended guest first-boot pass. Pre-publication failures roll the gate
# back; a disk already published retains it and therefore remains fail-closed.
write_private_attestation
"$REAL_JQ" '
    .schemaVersion = 6 |
    .deploymentMode = "site-private-licensed-firstboot-v1" |
    del(.firstBootWorkflow, .systemNvapiDelivery, .systemNvapiRequired)
' "$ATTESTATION" >"$ATTESTATION.old"
mv -f -- "$ATTESTATION.old" "$ATTESTATION"
chmod 0400 "$ATTESTATION"
if run_clone 833 >"$TMP_DIR/private-old.out" 2>"$TMP_DIR/private-old.err"; then
    fail "private clone accepted obsolete schema-6 first-boot semantics"
fi
grep -Fq 'schema-6 base lacks automatic system NVAPI projection' \
    "$TMP_DIR/private-old.err" ||
    fail "obsolete private base refusal did not explain the required rebuild"
write_private_attestation
before_monitor=$(grep -c '^monitor-sync|' "$TRACE" || true)
run_clone 834 --gpu-profile gtx750_asus_1gb --start >"$TMP_DIR/private.out"
after_monitor=$(grep -c '^monitor-sync|' "$TRACE" || true)
[[ "$after_monitor" -eq "$before_monitor" ]] ||
    fail "private clone modified the monitor cache before guest validation"
[[ -f "$VM_INSTANCES_DIR/834/.g11-init-required" ]] ||
    fail "private clone did not publish its initialization gate"
"$REAL_JQ" -e \
    '.schemaVersion == 2 and .state == "guest-firstboot-required" and
     .baseName == "win10-base" and
     .vmUuid == "00112233-4455-4677-8899-aabbccddeeff" and
     .gpuProfile == "gtx750_asus_1gb" and .monitorProfile == "dell-p2419h" and
     (.catalogSha256 | test("^[0-9A-F]{64}$")) and
     (.sourceConfigSha256 | test("^[0-9A-F]{64}$")) and
     (.systemNvapiContractId | test("^[0-9A-F]{64}$")) and
     (.systemNvapiIsoSha256 | test("^[0-9A-F]{64}$")) and
     .systemNvapiIsoFile ==
       ("vm834-00112233-4455-4677-8899-aabbccddeeff-" +
        (.systemNvapiContractId[0:16]) + ".iso")' \
    "$VM_INSTANCES_DIR/834/.g11-init-required" >/dev/null ||
    fail "private clone initialization gate is invalid"
[[ -f "$VM_INSTANCES_DIR/834/packages/SystemNvapiProjection/$(
        "$REAL_JQ" -r '.systemNvapiIsoFile' \
            "$VM_INSTANCES_DIR/834/.g11-init-required")" ]] ||
    fail "private clone did not retain its read-only per-VM system NVAPI ISO"
grep -Fq 'system-nvapi-package|834|' "$TRACE" ||
    fail "private clone did not invoke the per-VM system NVAPI packager"
grep -Fxq 'start-vm|834' "$TRACE" ||
    fail "private --start did not launch the intended first-boot pass"
grep -Fq 'deferred-to-one-click-initialization' "$TMP_DIR/private.out" ||
    fail "private clone did not explain deferred monitor initialization"

export STUB_DISK_FAIL=1
if run_clone 835 >"$TMP_DIR/private-disk-fail.out" \
        2>"$TMP_DIR/private-disk-fail.err"; then
    fail "private clone accepted a pre-publication disk failure"
fi
unset STUB_DISK_FAIL
[[ ! -e "$VM_INSTANCES_DIR/835/.g11-init-required" &&
   ! -e "$VM_INSTANCES_DIR/835/packages/SystemNvapiProjection" &&
   ! -e "$VM_INSTANCES_DIR/835/vm.conf" &&
   ! -e "$VM_INSTANCES_DIR/835/disk.qcow2" ]] ||
    fail "private pre-publication failure was not rolled back"

export STUB_DISK_PUBLISH_FAIL=1
if run_clone 836 >"$TMP_DIR/private-published-fail.out" \
        2>"$TMP_DIR/private-published-fail.err"; then
    fail "private clone accepted a post-publication disk failure"
fi
unset STUB_DISK_PUBLISH_FAIL
[[ -f "$VM_INSTANCES_DIR/836/.g11-init-required" &&
   -d "$VM_INSTANCES_DIR/836/packages/SystemNvapiProjection" &&
   -f "$VM_INSTANCES_DIR/836/vm.conf" &&
   -f "$VM_INSTANCES_DIR/836/disk.qcow2" ]] ||
    fail "private published disk did not retain its fail-closed gate"
write_attestation

# Once a disk is published, an unexpected sync error keeps the clone for
# recovery but fails closed and never launches it.
export STUB_MONITOR_SYNC_RC=12
if run_clone 460 --start >"$TMP_DIR/monitor-fail.out" \
        2>"$TMP_DIR/monitor-fail.err"; then
    fail "clone accepted an unexpected automatic monitor-sync failure"
else
    monitor_fail_rc=$?
fi
unset STUB_MONITOR_SYNC_RC
[[ "$monitor_fail_rc" -eq 12 ]] ||
    fail "automatic monitor-sync failure status was not preserved"
[[ -f "$VM_INSTANCES_DIR/460/vm.conf" &&
   -f "$VM_INSTANCES_DIR/460/disk.qcow2" ]] ||
    fail "published clone was lost after monitor-sync recovery failure"
! grep -Fq 'start-vm|460' "$TRACE" ||
    fail "clone started after an unexpected monitor-sync failure"
grep -Fq '克隆已保留' "$TMP_DIR/monitor-fail.err" ||
    fail "monitor-sync failure did not explain clone recovery state"

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
mkdir -p "$VM_INSTANCES_DIR/600"
printf 'SPOOF_MODE=B\n' >"$VM_INSTANCES_DIR/600/vm.conf"
before=$(wc -l <"$TRACE")
if run_clone 600 >"$TMP_DIR/existing-conf.out" 2>"$TMP_DIR/existing-conf.err"; then
    fail "clone accepted an existing VM configuration"
fi
[[ "$(wc -l <"$TRACE")" -eq "$before" ]] ||
    fail "existing VM configuration invoked a helper"

mkdir -p "$VM_INSTANCES_DIR/601"
printf 'existing disk\n' >"$VM_INSTANCES_DIR/601/disk.qcow2"
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
write_attestation "$CATALOG_SHA256" '{"gpuZDelivery":"embedded"}'
if run_clone 615 >"$TMP_DIR/delivery.out" 2>"$TMP_DIR/delivery.err"; then
    fail "clone accepted a non-optional GPU-Z delivery attestation"
fi
write_attestation "$CATALOG_SHA256" \
    '{"guestPerformance":"not-embedded"}'
if run_clone 614 >"$TMP_DIR/performance.out" \
        2>"$TMP_DIR/performance.err"; then
    fail "clone accepted a base without the unified guest performance profile"
fi
write_attestation "$CATALOG_SHA256" \
    '{"gpuZSha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}'
if run_clone 616 >"$TMP_DIR/gpuz-hash.out" 2>"$TMP_DIR/gpuz-hash.err"; then
    fail "clone accepted a different external GPU-Z hash"
fi
write_attestation "$CATALOG_SHA256" \
    '{"gpuZGuestPath":"C:\\Users\\Public\\Desktop\\Other.exe"}'
if run_clone 617 >"$TMP_DIR/gpuz-path.out" 2>"$TMP_DIR/gpuz-path.err"; then
    fail "clone accepted a different external GPU-Z guest path"
fi
write_attestation "$CATALOG_SHA256" '{"gpuZBytes":11642143}'
if run_clone 680 >"$TMP_DIR/gpuz-bytes.out" 2>"$TMP_DIR/gpuz-bytes.err"; then
    fail "clone accepted a different external GPU-Z byte length"
fi
write_attestation "$CATALOG_SHA256" \
    '{"portableGuestPath":"C:\\Users\\Public\\Desktop\\OtherPortable.exe"}'
if run_clone 681 >"$TMP_DIR/portable-path.out" \
        2>"$TMP_DIR/portable-path.err"; then
    fail "clone accepted a different portable guest path"
fi
write_attestation "$CATALOG_SHA256" '{"portableSha256":"not-a-sha"}'
if run_clone 682 >"$TMP_DIR/portable-hash.out" \
        2>"$TMP_DIR/portable-hash.err"; then
    fail "clone accepted a malformed portable hash"
fi
write_attestation "$CATALOG_SHA256" '{"portableBytes":0}'
if run_clone 683 >"$TMP_DIR/portable-bytes.out" \
        2>"$TMP_DIR/portable-bytes.err"; then
    fail "clone accepted a non-positive portable byte length"
fi

# Legacy schema 2 proves only one guest file and must not authorize a new
# external-sibling clone.
write_legacy_attestation
if run_clone 618 >"$TMP_DIR/legacy.out" 2>"$TMP_DIR/legacy.err"; then
    fail "clone accepted a legacy single-file base attestation"
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
[[ ! -e "$VM_INSTANCES_DIR/620/vm.conf" ]] ||
    fail "invalid newly-created configuration was not rolled back"
[[ ! -e "$VM_INSTANCES_DIR/620/disk.qcow2" ]] ||
    fail "invalid configuration still reached disk creation"

export STUB_DISK_FAIL=1
if run_clone 621 >"$TMP_DIR/disk-fail.out" 2>"$TMP_DIR/disk-fail.err"; then
    fail "clone accepted a create-disk failure"
fi
unset STUB_DISK_FAIL
[[ ! -e "$VM_INSTANCES_DIR/621/vm.conf" ]] ||
    fail "configuration was not rolled back after pre-publication disk failure"
[[ ! -e "$VM_INSTANCES_DIR/621/disk.qcow2" ]] ||
    fail "pre-publication failure unexpectedly left a disk"

export STUB_DISK_NO_PUBLISH=1
if run_clone 622 >"$TMP_DIR/no-disk.out" 2>"$TMP_DIR/no-disk.err"; then
    fail "clone accepted create-disk success without a published disk"
fi
unset STUB_DISK_NO_PUBLISH
[[ ! -e "$VM_INSTANCES_DIR/622/vm.conf" ]] ||
    fail "configuration was not rolled back when create-disk published nothing"

export STUB_DISK_PUBLISH_FAIL=1
if run_clone 623 >"$TMP_DIR/published-fail.out" \
        2>"$TMP_DIR/published-fail.err"; then
    fail "clone accepted create-disk failure after disk publication"
fi
unset STUB_DISK_PUBLISH_FAIL
[[ -f "$VM_INSTANCES_DIR/623/vm.conf" &&
   -f "$VM_INSTANCES_DIR/623/disk.qcow2" ]] ||
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
grep -Fxq 'create-vm|700' "$TRACE" ||
    fail "lock-delayed clone did not create its VM"
grep -Fxq 'create-disk|700|--from-base|--base-name|win10-base|--linked' "$TRACE" ||
    fail "lock-delayed clone did not create its disk"

# A busy per-VM lifecycle lock must fail before sidecar parsing or helper
# invocation, preventing start/delete/concurrent-clone races between config and
# disk publication.
before=$(wc -l <"$TRACE")
rm -f -- "$JQ_MARKER"
mkdir -p "$VM_INSTANCES_DIR/701/run"
exec {VM_LOCK_FD}>"$VM_INSTANCES_DIR/701/run/start.lock"
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

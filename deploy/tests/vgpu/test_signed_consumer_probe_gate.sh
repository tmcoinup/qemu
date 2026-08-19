#!/usr/bin/env bash
# Host-only integration test for the one-shot signed-consumer probe.  Every
# accepted launch is --dry-run; no mdev, QEMU process or guest disk is opened.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CREATE_VM="$REPO_ROOT/deploy/scripts/create-vm.sh"
PROBE="$REPO_ROOT/deploy/probe-signed-consumer-vgpu.sh"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
CATALOG="$REPO_ROOT/deploy/lib/signed-consumer-catalog.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local text=$1 file=$2 label=${3:-$1}
    grep -F -- "$text" "$file" >/dev/null \
        || fail "$label missing from $(basename "$file")"
}

reject_text() {
    local text=$1 file=$2 label=${3:-$1}
    if grep -F -- "$text" "$file" >/dev/null; then
        fail "$label unexpectedly present in $(basename "$file")"
    fi
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT
IMAGE_ROOT="$TMP_DIR/image"
VM_ROOT="$IMAGE_ROOT/vms"
VM_ID=73
EMPTY_VGPU_CONFIG="$TMP_DIR/vgpu-host.conf"
mkdir -p "$IMAGE_ROOT" "$VM_ROOT"
touch "$EMPTY_VGPU_CONFIG" "$TMP_DIR/OVMF_CODE.fd" "$TMP_DIR/OVMF_VARS.fd"

# Every expected identity fact comes from the audited catalogs. The test VM
# number is deliberately unrelated to any historical proof/source VM.
# shellcheck source=../../lib/signed-consumer-catalog.sh
source "$CATALOG"
signed_consumer_catalog_validate || fail 'catalog validation failed'
signed_consumer_driver_load nvidia-53758-dch-whql-gtx1050-dell
signed_consumer_profile_load_canonical "$SC_GPU_PROFILE"
PROFILE_SHA=$(signed_consumer_profile_sha256 "$SC_GPU_PROFILE")
printf -v EXPECTED_PCI_VID '0x%04X' "$((SC_CANONICAL_PCI_VID))"
printf -v EXPECTED_PCI_DID '0x%04X' "$((SC_CANONICAL_PCI_DID))"
printf -v EXPECTED_SUB_VID '0x%04X' "$((SC_CANONICAL_SUB_VID))"
printf -v EXPECTED_SUB_DID '0x%04X' "$((SC_CANONICAL_SUB_DID))"
printf -v EXPECTED_INTERNAL_PCI '0x%04X%04X' \
    "$((SC_CANONICAL_PCI_DID))" "$((SC_CANONICAL_SUB_DID))"
printf -v EXPECTED_INTERNAL_PDEV '0x%04X' "$((SC_CANONICAL_PCI_DID))"

cat >"$TMP_DIR/qemu-system-x86_64" <<'EOF'
#!/bin/sh
if [ "$#" -eq 2 ] && [ "$1" = -display ] && [ "$2" = help ]; then
    printf '%s\n' gtk sdl
    exit 0
fi
if [ "$#" -eq 2 ] && [ "$1" = -device ] &&
        [ "$2" = vfio-pci-nohotplug,help ]; then
    printf '  ramfb=<bool>\n'
    exit 0
fi
if [ "$#" -eq 2 ] && [ "$1" = -device ] &&
        [ "$2" = pcie-root-port,help ]; then
    printf '%s\n' \
        '  x-speed=<PCIELinkSpeed>' \
        '  x-width=<PCIELinkWidth>' \
        '  x-pci-vendor-id=<uint32>' \
        '  x-pci-device-id=<uint32>' \
        '  x-pci-revision=<uint32>'
    exit 0
fi
if [ "$#" -eq 2 ] && [ "$1" = -object ] && [ "$2" = fb-shm,help ]; then
    printf 'fb-shm options:\n  path=<string>\n  rate=<uint32>\n'
    exit 0
fi
echo "unexpected fake QEMU invocation: $*" >&2
exit 99
EOF
chmod +x "$TMP_DIR/qemu-system-x86_64"

env -i \
    HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
    IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
    "$CREATE_VM" "$VM_ID" \
        --platform i5-4590-h81m-s1-8g \
        --ssd-profile samsung-850-pro-512gb \
        --gpu-profile "$SC_GPU_PROFILE" \
        --monitor-profile dell-se2416h >"$TMP_DIR/create.out"

CONF="$VM_ROOT/$VM_ID/vm.conf"
DISK="$VM_ROOT/$VM_ID/disk.qcow2"
truncate -s 1048576 "$DISK"
CONFIG_SHA=$(sha256sum "$CONF" | awk '{print toupper($1)}')
VM_UUID=$(sed -n 's/^VM_UUID=//p' "$CONF")

write_attestation() {
    local stage=$1 issued_at=${2:-} marker_dir marker disk_token nonce
    marker_dir="$VM_ROOT/$VM_ID/probe"
    marker="$marker_dir/signed-consumer-${stage}.json"
    mkdir -p "$marker_dir"
    chmod 0700 "$marker_dir"
    disk_token=$(stat -Lc '%d:%i:%s:%Y:%Z' "$DISK")
    nonce=$(tr -d '-' </proc/sys/kernel/random/uuid | tr '[:lower:]' '[:upper:]')
    issued_at=${issued_at:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
    jq -n \
        --argjson vmId "$VM_ID" \
        --arg vmUuid "$VM_UUID" \
        --arg stage "$stage" \
        --arg configSha "$CONFIG_SHA" \
        --arg diskPath "$DISK" \
        --arg diskToken "$disk_token" \
        --argjson issuedByUid "$(id -u)" \
        --arg issuedAtUtc "$issued_at" \
        --arg nonce "$nonce" \
        --arg profile "$SC_CANONICAL_GPU_PROFILE" --arg profileSha "$PROFILE_SHA" \
        --arg gpuName "$SC_CANONICAL_GPU_NAME" \
        --arg pciVid "$EXPECTED_PCI_VID" --arg pciDid "$EXPECTED_PCI_DID" \
        --arg subVid "$EXPECTED_SUB_VID" --arg subDid "$EXPECTED_SUB_DID" \
        --arg internalPci "$EXPECTED_INTERNAL_PCI" \
        --arg internalPdev "$EXPECTED_INTERNAL_PDEV" \
        --arg resourceProfile "$SC_CANONICAL_MDEV_PROFILE" \
        --argjson framebufferMb "$SC_CANONICAL_FB_MB" \
        --arg driverKey "$SC_DRIVER_KEY" --arg driverVersion "$SC_DRIVER_VERSION" \
        --arg infName "$SC_INF_NAME" --arg infSha "$SC_INF_SHA256" \
        --arg catalogName "$SC_CATALOG_NAME" --arg catSha "$SC_CATALOG_SHA256" \
        --arg packageSha "$SC_INSTALLER_SHA256" '
        {
          schemaVersion: 2,
          purpose: "g11-signed-consumer-disposable-clone",
          disposableClone: true,
          vmId: $vmId,
          vmUuid: $vmUuid,
          stage: $stage,
          configSha256: $configSha,
          diskPath: $diskPath,
          diskStatToken: $diskToken,
          issuedByUid: $issuedByUid,
          issuedAtUtc: $issuedAtUtc,
          nonce: $nonce,
          gpu: {
            profile: $profile, profileSha256: $profileSha, name: $gpuName,
            pciVid: $pciVid, pciDid: $pciDid,
            subVid: $subVid, subDid: $subDid,
            internalPciId: $internalPci, internalPdevId: $internalPdev,
            resourceProfile: $resourceProfile, framebufferMb: $framebufferMb
          },
          driverEvidence: {
            driverKey: $driverKey, driverVersion: $driverVersion, inf: $infName,
            infSha256: $infSha, catalog: $catalogName,
            catalogSha256: $catSha, packageSha256: $packageSha,
            status:
              "production-signed-pnp-match-host-audited-mdev-unproven"
          }
        }
    ' >"$marker"
    chmod 0600 "$marker"
}

run_probe() {
    local stage=$1 output=$2 error=$3 report_failure=${4:-1} marker
    if ! env -i \
        HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin DISPLAY=:99 \
        IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
        QEMU_BIN="$TMP_DIR/qemu-system-x86_64" \
        OVMF_CODE="$TMP_DIR/OVMF_CODE.fd" \
        OVMF_VARS="$TMP_DIR/OVMF_VARS.fd" \
        VGPU_HOST_CONFIG="$EMPTY_VGPU_CONFIG" \
        REPAIR_DISPLAY_VARS=off \
        "$PROBE" "$VM_ID" --stage "$stage" --vms-dir "$VM_ROOT" \
            --dry-run --no-tpm --no-cpu-isolate \
            >"$output" 2>"$error"; then
        if (( report_failure )); then
            sed -n '1,240p' "$error" >&2
            marker="$VM_ROOT/$VM_ID/probe/signed-consumer-${stage}.json"
            [[ ! -f "$marker" ]] || jq -S . "$marker" >&2
        fi
        return 1
    fi
}

# Ordinary strict-A remains closed and a private probe flag without the
# wrapper-consumed FD cannot create authorization.
if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
        IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
        "$START_VM" "$VM_ID" --dry-run --spoof \
        >"$TMP_DIR/ordinary-a.out" 2>"$TMP_DIR/ordinary-a.err"; then
    fail "ordinary strict-A launch was accepted"
fi
require_text "strict-A startup is disabled" "$TMP_DIR/ordinary-a.err"

if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
        IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
        "$START_VM" "$VM_ID" --dry-run \
            --signed-consumer-probe outer-only \
        >"$TMP_DIR/no-fd.out" 2>"$TMP_DIR/no-fd.err"; then
    fail "probe without consumed attestation FD was accepted"
fi
require_text "authorization must arrive on the wrapper-owned one-shot FD" \
    "$TMP_DIR/no-fd.err"

write_attestation outer-only "$(date -u -d '11 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
if run_probe outer-only "$TMP_DIR/expired.out" "$TMP_DIR/expired.err" 0; then
    fail "expired probe attestation was accepted"
fi
require_text "有效期 10 分钟" "$TMP_DIR/expired.err" "attestation TTL"

if VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG="$TMP_DIR/redirected.toml" \
        "$PROBE" "$VM_ID" --stage outer-only --vms-dir "$VM_ROOT" \
        --dry-run >"$TMP_DIR/redirect.out" 2>"$TMP_DIR/redirect.err"; then
    fail "redirected host identity backend was accepted"
fi
require_text "环境覆盖被禁止" "$TMP_DIR/redirect.err" \
    "canonical host identity backend"

write_attestation outer-only
run_probe outer-only "$TMP_DIR/outer.out" "$TMP_DIR/outer.err"
require_text "signed-consumer-probe authorized for this invocation only" \
    "$TMP_DIR/outer.out"
require_text "GPU probe: one-shot outer-only" "$TMP_DIR/outer.out"
require_text "vGPU internal PCI identity: native（outer-only stage）" \
    "$TMP_DIR/outer.out"
require_text "x-pci-vendor-id=${EXPECTED_PCI_VID}\\,x-pci-device-id=${EXPECTED_PCI_DID}" \
    "$TMP_DIR/outer.out" "outer consumer PCI tuple"
[[ ! -e "$VM_ROOT/$VM_ID/probe/signed-consumer-outer-only.json" ]] \
    || fail "outer-only attestation was reusable by path"

write_attestation outer+internal
run_probe outer+internal "$TMP_DIR/internal.out" "$TMP_DIR/internal.err"
require_text "GPU probe: one-shot outer+internal" "$TMP_DIR/internal.out"
require_text \
    "vGPU internal PCI identity: one-shot pci_id=${EXPECTED_INTERNAL_PCI} / pdev=${EXPECTED_INTERNAL_PDEV}" \
    "$TMP_DIR/internal.out"
require_text "x-pci-vendor-id=${EXPECTED_PCI_VID}\\,x-pci-device-id=${EXPECTED_PCI_DID}" \
    "$TMP_DIR/internal.out" "internal-stage outer PCI tuple"
[[ ! -e "$VM_ROOT/$VM_ID/probe/signed-consumer-outer+internal.json" ]] \
    || fail "outer+internal attestation was reusable by path"

[[ "$(sha256sum "$CONF" | awk '{print toupper($1)}')" == "$CONFIG_SHA" ]] \
    || fail "probe persisted a vm.conf change"
grep -Fxq 'SPOOF_MODE=B' "$CONF" || fail "probe did not leave B persisted"
grep -Fxq 'VGPU_IDENTITY_TARGET=name-only' "$CONF" \
    || fail "probe did not leave name-only persisted"

# The exact same catalog/attestation/start path also accepts the maximum legal
# VM number. This catches regressions that quietly reintroduce sample-VM gates.
VM_ID=2147483647
env -i \
    HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
    IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
    "$CREATE_VM" "$VM_ID" \
        --platform i5-4590-h81m-s1-8g \
        --ssd-profile samsung-850-pro-512gb \
        --gpu-profile "$SC_GPU_PROFILE" \
        --monitor-profile dell-se2416h >"$TMP_DIR/create-max.out"
CONF="$VM_ROOT/$VM_ID/vm.conf"
DISK="$VM_ROOT/$VM_ID/disk.qcow2"
truncate -s 1048576 "$DISK"
CONFIG_SHA=$(sha256sum "$CONF" | awk '{print toupper($1)}')
VM_UUID=$(sed -n 's/^VM_UUID=//p' "$CONF")
write_attestation outer-only
run_probe outer-only "$TMP_DIR/max.out" "$TMP_DIR/max.err"
require_text "signed-consumer-probe authorized for this invocation only: vm${VM_ID}" \
    "$TMP_DIR/max.out" "maximum VM ID authorization"

# A canonical profile is not automatically production-qualified. Until that
# profile has its own untouched WHQL row and validator, the wrapper fails
# before creating or consuming an attestation.
UNQUALIFIED_VM_ID=88
env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
    IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
    "$CREATE_VM" "$UNQUALIFIED_VM_ID" \
        --platform i5-4590-h81m-s1-8g \
        --ssd-profile samsung-850-pro-512gb \
        --gpu-profile gt1030_2gb \
        --monitor-profile dell-se2416h >"$TMP_DIR/create-unqualified.out"
truncate -s 1048576 "$VM_ROOT/$UNQUALIFIED_VM_ID/disk.qcow2"
if env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
        IMAGE_ROOT="$IMAGE_ROOT" VM_ROOT="$VM_ROOT" \
        "$PROBE" "$UNQUALIFIED_VM_ID" --stage outer-only \
            --vms-dir "$VM_ROOT" --dry-run \
            >"$TMP_DIR/unqualified.out" 2>"$TMP_DIR/unqualified.err"; then
    fail 'unqualified canonical GPU profile was accepted'
fi
require_text '尚无可资格化的原版 WHQL driver 条目' \
    "$TMP_DIR/unqualified.err" "unqualified profile fail-closed"

# Static safety boundary: wrapper never calls a guest installer, BCD tool or
# patched-driver path, and the only launcher exception is stage/FD bound.
for forbidden in testsigning nointegritychecks bcdedit pnputil \
        install-patched-driver stage-patched-vgpu-driver; do
    reject_text "$forbidden" "$PROBE" "forbidden probe operation $forbidden"
done
reject_text 'REQUESTED_VM_ID" != 3' "$START_VM" "VM3 special case"
reject_text 'REQUESTED_VM_ID" != 9' "$START_VM" "VM9 special case"
require_text 'vm_storage_id_is_supported "$VM_ID"' "$PROBE" "generic VM ID gate"
require_text '"$SIGNED_CONSUMER_PROBE_AUTHORIZED" == 1' \
    "$START_VM" "late signed-probe authorization"
require_text 'VGPU_MDEV_INTERNAL_PCI_IDENTITY=1' \
    "$START_VM" "internal-stage transient selector"
require_text 'elif [[ "$SPOOF_MODE" == A ]]; then' \
    "$START_VM" "ordinary strict-A late guard"
require_text 'age_seconds <= 600' "$PROBE" "wrapper 10-minute TTL"
require_text 'age_seconds <= 600' "$START_VM" "launcher 10-minute TTL"
require_text '环境覆盖被禁止' "$PROBE" "wrapper env redirect refusal"
require_text '! _mdev_release_locked "$uuid"' \
    "$REPO_ROOT/deploy/lib/vgpu-mdev.sh" "stale mdev release before B reset"

# Behavioral rollback ordering: an unused stale mdev must be removed before
# B/name-only TOML is rewritten, never reused with its old live identity.
(
    MDEV_DEVICES_DIR="$TMP_DIR/mock-mdev"
    mkdir -p "$MDEV_DEVICES_DIR/target"
    # shellcheck source=../../lib/vgpu-mdev.sh
    source "$REPO_ROOT/deploy/lib/vgpu-mdev.sh"
    mock_uuid=11111111-2222-3333-4444-555555555555
    ln -s "$MDEV_DEVICES_DIR/target" "$MDEV_DEVICES_DIR/$mock_uuid"
    events=""
    _mdev_host_lock_acquire() { :; }
    _mdev_host_lock_release() { :; }
    mdev_uuid_in_use() { return 1; }
    _mdev_release_locked() {
        events+="release "
        unlink "$MDEV_DEVICES_DIR/$1"
    }
    _mdev_sync_identity_override_locked() {
        [[ ! -L "$MDEV_DEVICES_DIR/$1" ]] || return 1
        events+="sync"
    }
    mdev_set_identity_override "$mock_uuid" "$SC_CANONICAL_GPU_NAME"
    [[ "$events" == "release sync" ]] \
        || fail "stale mdev rollback order was '$events'"
)

echo "PASS: signed-consumer probe is disposable-clone/tuple/FD/stage bound, emits both dry-run stages, consumes authorization and preserves B"

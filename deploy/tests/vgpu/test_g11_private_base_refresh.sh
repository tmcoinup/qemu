#!/usr/bin/env bash
# Credential-free check-mode regression for the one-command private base
# payload refresh wrapper. No qcow2/NBD device is opened.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REFRESH="$ROOT/deploy/scripts/refresh-g11-private-base.sh"
TMP_DIR=$(mktemp -d /tmp/g11-private-base-refresh-test.XXXXXXXX)
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
sha256_upper() { sha256sum -- "$1" | awk '{print toupper($1)}'; }

bash -n "$REFRESH" || fail "refresh wrapper has invalid Bash syntax"
VM_ROOT="$TMP_DIR/vms"
VM_BASE_DIR="$VM_ROOT/_base"
BASE_NAME=fixture-private
BASE="$VM_BASE_DIR/$BASE_NAME.qcow2"
ATTESTATION="${BASE}.vgpu-portable.json"
mkdir -p "$VM_BASE_DIR"
printf 'credential-free private base fixture\n' >"$BASE"
BASE_SHA_BEFORE=$(sha256_upper "$BASE")
BASE_BYTES=$(stat -c %s -- "$BASE")
BASE_DEVICE=$(stat -c %D -- "$BASE")
BASE_INODE=$(stat -c %i -- "$BASE")
BASE_MTIME=$(stat -c %y -- "$BASE")
BASE_CTIME=$(stat -c %z -- "$BASE")
# shellcheck source=../../lib/vgpu-profiles.sh
source "$ROOT/deploy/lib/vgpu-profiles.sh"
vgpu_profile_validate_catalog
CATALOG_SHA=$(vgpu_profile_catalog_sha256)

FINALIZER_SHA=$(sha256_upper "$ROOT/deploy/guest/finalize-g11-clone.ps1")
RETRY_SHA=$(sha256_upper "$ROOT/deploy/guest/Retry-Clone-Initialization.cmd")
SYSPREP_SHA=$(sha256_upper "$ROOT/deploy/autounattend/g11-sysprep-clone.xml")
jq -n \
    --arg basePath "$BASE" \
    --argjson baseFileBytes "$BASE_BYTES" \
    --arg baseDeviceId "$BASE_DEVICE" \
    --arg baseInode "$BASE_INODE" \
    --arg baseMtimeNs "$BASE_MTIME" \
    --arg baseCtimeNs "$BASE_CTIME" \
    --arg catalogSha "$CATALOG_SHA" \
    --arg finalizerSha "$FINALIZER_SHA" \
    --arg retrySha "$RETRY_SHA" \
    --arg sysprepSha "$SYSPREP_SHA" '
    {
        schemaVersion: 8,
        bindingMode: "portable-auto",
        deploymentMode: "site-private-licensed-firstboot-v3",
        basePath: $basePath,
        baseFileBytes: $baseFileBytes,
        baseDeviceId: $baseDeviceId,
        baseInode: $baseInode,
        baseMtimeNs: $baseMtimeNs,
        baseCtimeNs: $baseCtimeNs,
        portableGuestPath: "C:\\ProgramData\\VMate\\G11\\VgpuPortable.exe",
        portableSha256: ("A" * 64),
        portableBytes: 123,
        portableReceiptSchema: 8,
        portableLauncherFormat: "QEMU_VGPU_PORTABLE_LICENSED_BRANCH_V8",
        driverBranch: "R535",
        driverVersion: "31.0.15.3833",
        catalogSha256: $catalogSha,
        firstBootScriptGuestPath: "C:\\ProgramData\\VMate\\G11\\Finalize-Clone.ps1",
        firstBootScriptSha256: $finalizerSha,
        retryGuestPath: "C:\\ProgramData\\VMate\\G11\\Retry-Clone-Initialization.cmd",
        retrySha256: $retrySha,
        sysprepAnswerGuestPath: "C:\\Windows\\Panther\\unattend.xml",
        sysprepAnswerSha256: $sysprepSha,
        windowsGeneralized: true,
        oobeMode: "unattended-auto-finalize",
        licenseDelivery: "embedded-private-shared-token",
        firstBootWorkflow: "licensed-portable-system-nvapi-two-boot-v1",
        systemNvapiDelivery: "per-vm-read-only-iso",
        systemNvapiRequired: true,
        dlsHost: "dls.gvmates.com",
        dlsPort: 443,
        guestPerformance: "embedded-recommended-native-v1",
        installedUtc: "2026-01-01T00:00:00Z"
    }
' >"$ATTESTATION"

IMAGE_ROOT="$TMP_DIR/images" VM_ROOT="$VM_ROOT" VMS_DIR="$VM_ROOT" \
VM_INSTANCES_DIR="$VM_ROOT" VM_BASE_DIR="$VM_BASE_DIR" \
    "$REFRESH" "$BASE_NAME" --check >"$TMP_DIR/current.out"
grep -Fq 'already embeds marker schema 4 / Guest Lite 2.6.7' \
    "$TMP_DIR/current.out" || fail "current private base was not recognized"

jq '.firstBootScriptSha256 = ("0" * 64)' "$ATTESTATION" \
    >"$ATTESTATION.stale"
mv -f -- "$ATTESTATION.stale" "$ATTESTATION"
if IMAGE_ROOT="$TMP_DIR/images" VM_ROOT="$VM_ROOT" VMS_DIR="$VM_ROOT" \
        VM_INSTANCES_DIR="$VM_ROOT" VM_BASE_DIR="$VM_BASE_DIR" \
        "$REFRESH" "$BASE_NAME" --check >"$TMP_DIR/stale.out" \
        2>"$TMP_DIR/stale.err"; then
    fail "obsolete private base passed refresh --check"
fi
grep -Fq 'must be refreshed before another clone' "$TMP_DIR/stale.err" ||
    fail "stale check did not explain the required refresh"
[[ "$(sha256_upper "$BASE")" == "$BASE_SHA_BEFORE" ]] ||
    fail "--check modified the base image"

echo "PASS: private base refresh check rejects obsolete clone payloads without touching the image"

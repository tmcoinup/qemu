#!/usr/bin/env bash
# Functional export/import test with a tiny credential-free qcow2 fixture.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXPORT="$ROOT/deploy/scripts/export-vgpu-base.sh"
IMPORT="$ROOT/deploy/scripts/import-vgpu-base.sh"
command -v qemu-img >/dev/null 2>&1 || {
    echo "SKIP: qemu-img is unavailable"
    exit 0
}
command -v jq >/dev/null 2>&1 || {
    echo "SKIP: jq is unavailable"
    exit 0
}

TMP_DIR=$(mktemp -d /tmp/g11-private-transfer-test.XXXXXXXX)
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
SOURCE_ROOT="$TMP_DIR/source-vms"
IMPORT_ROOT="$TMP_DIR/import-vms"
OUTPUT_ROOT="$TMP_DIR/output"
BASE_NAME=test-g11-private
mkdir -p "$SOURCE_ROOT/_base" "$OUTPUT_ROOT"
BASE="$SOURCE_ROOT/_base/$BASE_NAME.qcow2"
EXPECTED_COMPRESSION=zstd
if ! qemu-img create -q -f qcow2 -o compression_type=zstd "$BASE" 1M; then
    rm -f -- "$BASE"
    qemu-img create -q -f qcow2 "$BASE" 1M
    EXPECTED_COMPRESSION=zlib
fi

# shellcheck source=../../lib/vgpu-profiles.sh
source "$ROOT/deploy/lib/vgpu-profiles.sh"
vgpu_profile_validate_catalog
CATALOG_SHA256=$(vgpu_profile_catalog_sha256)
BYTES=$(stat -c %s "$BASE")
DEVICE=$(stat -c %D "$BASE")
INODE=$(stat -c %i "$BASE")
MTIME=$(stat -c %y "$BASE")
CTIME=$(stat -c %z "$BASE")
SIDE="${BASE}.vgpu-portable.json"
jq -n \
    --arg basePath "$BASE" --argjson baseFileBytes "$BYTES" \
    --arg baseDeviceId "$DEVICE" --arg baseInode "$INODE" \
    --arg baseMtimeNs "$MTIME" --arg baseCtimeNs "$CTIME" \
    --arg catalogSha256 "$CATALOG_SHA256" '
    {
        schemaVersion: 7, bindingMode: "portable-auto",
        deploymentMode: "site-private-licensed-firstboot-v2",
        basePath: $basePath, baseFileBytes: $baseFileBytes,
        baseDeviceId: $baseDeviceId, baseInode: $baseInode,
        baseMtimeNs: $baseMtimeNs, baseCtimeNs: $baseCtimeNs,
        portableGuestPath: "C:\\ProgramData\\VMate\\G11\\VgpuPortable.exe",
        portableSha256: ("A" * 64), portableBytes: 123,
        firstBootScriptGuestPath: "C:\\ProgramData\\VMate\\G11\\Finalize-Clone.ps1",
        firstBootScriptSha256: ("B" * 64),
        retryGuestPath: "C:\\ProgramData\\VMate\\G11\\Retry-Clone-Initialization.cmd",
        retrySha256: ("C" * 64),
        sysprepAnswerGuestPath: "C:\\Windows\\Panther\\unattend.xml",
        sysprepAnswerSha256: ("D" * 64), windowsGeneralized: true,
        oobeMode: "unattended-auto-finalize",
        licenseDelivery: "embedded-private-shared-token",
        firstBootWorkflow: "licensed-portable-system-nvapi-two-boot-v1",
        systemNvapiDelivery: "per-vm-read-only-iso",
        systemNvapiRequired: true,
        dlsHost: "dls.gvmates.com", dlsPort: 443,
        guestPerformance: "embedded-recommended-native-v1",
        catalogSha256: $catalogSha256, installedUtc: "2026-01-01T00:00:00Z"
    }' >"$SIDE"
chmod 0600 "$SIDE"

# A V-11-style instance pin changes inode ctime without changing base bytes.
# Export must remain valid after linked clones exist.
mkdir -p "$SOURCE_ROOT/999"
ln -- "$BASE" "$SOURCE_ROOT/999/.base.qcow2"
[[ "$BASE" -ef "$SOURCE_ROOT/999/.base.qcow2" &&
   "$(stat -c %y -- "$BASE")" == "$MTIME" ]] || {
    echo "FAIL: linked-clone fixture did not preserve base content identity" >&2
    exit 1
}

IMAGE_ROOT="$TMP_DIR/source-images" VM_ROOT="$SOURCE_ROOT" VMS_DIR="$SOURCE_ROOT" \
VM_INSTANCES_DIR="$SOURCE_ROOT" QEMU_IMG="$(command -v qemu-img)" \
    "$EXPORT" "$BASE_NAME" "$OUTPUT_ROOT" >"$TMP_DIR/export.out"
BUNDLE="$OUTPUT_ROOT/${BASE_NAME}-g11-private"
MANIFEST="$BUNDLE/$BASE_NAME.g11base"
EXPORTED_IMAGE="$BUNDLE/$BASE_NAME.qcow2"
[[ -f "$MANIFEST" && -f "$EXPORTED_IMAGE" ]] || {
    echo "FAIL: export did not publish both bundle files" >&2
    exit 1
}
grep -Fq '[g11-base-export] PASS' "$TMP_DIR/export.out"
if grep -Fq 'licenseTokenSha256' "$MANIFEST"; then
    echo "FAIL: transfer manifest leaked token fingerprint" >&2
    exit 1
fi

# The one-command builder uses in-place mode: one qcow2 remains both locally
# cloneable and transferable, with the .g11base manifest beside it.
SOURCE_BASE_INODE=$(stat -c %i -- "$BASE")
IMAGE_ROOT="$TMP_DIR/source-images" VM_ROOT="$SOURCE_ROOT" VMS_DIR="$SOURCE_ROOT" \
VM_INSTANCES_DIR="$SOURCE_ROOT" VM_BASE_DIR="$(dirname -- "$BASE")" \
QEMU_IMG="$(command -v qemu-img)" \
    "$EXPORT" --in-place "$BASE_NAME" "$(dirname -- "$BASE")" \
    >"$TMP_DIR/export-in-place.out"
IN_PLACE_MANIFEST="$(dirname -- "$BASE")/$BASE_NAME.g11base"
[[ -f "$IN_PLACE_MANIFEST" && -f "$SIDE" &&
   "$(stat -c %i -- "$BASE")" == "$SOURCE_BASE_INODE" ]] || {
    echo "FAIL: in-place export copied/replaced the local base" >&2
    exit 1
}
[[ "$(find "$(dirname -- "$BASE")" -maxdepth 1 -type f -name '*.qcow2' | wc -l)" == 1 ]] || {
    echo "FAIL: in-place export retained more than one qcow2" >&2
    exit 1
}
grep -Fq 'one qcow2 / local + delivery' "$TMP_DIR/export-in-place.out" || {
    echo "FAIL: in-place export did not report its single-image layout" >&2
    exit 1
}

# Refreshing an already published local base replaces only its exact managed
# manifest.  This is the normal update path after a newer first-boot finalizer
# is injected; it must not create another qcow2 or archive generation.
IMAGE_ROOT="$TMP_DIR/source-images" VM_ROOT="$SOURCE_ROOT" VMS_DIR="$SOURCE_ROOT" \
VM_INSTANCES_DIR="$SOURCE_ROOT" VM_BASE_DIR="$(dirname -- "$BASE")" \
QEMU_IMG="$(command -v qemu-img)" \
    "$EXPORT" --in-place "$BASE_NAME" "$(dirname -- "$BASE")" \
    >"$TMP_DIR/export-in-place-refresh.out"
[[ -f "$IN_PLACE_MANIFEST" && "$(stat -c %i -- "$BASE")" == "$SOURCE_BASE_INODE" ]] || {
    echo "FAIL: in-place manifest refresh copied/replaced the local base" >&2
    exit 1
}
[[ "$(find "$(dirname -- "$BASE")" -maxdepth 1 -type f -name '*.qcow2' | wc -l)" == 1 ]] || {
    echo "FAIL: in-place manifest refresh retained more than one qcow2" >&2
    exit 1
}
grep -Fq '[g11-base-export] PASS' "$TMP_DIR/export-in-place-refresh.out"

# The installer may run in a UTC container while export runs in the host's
# local timezone. Equivalent stat timestamps must compare by instant rather
# than by their rendered offset.
ATTESTED_MTIME=$(jq -r '.baseMtimeNs' "$SIDE")
UTC_MTIME=$(date -u -d "$ATTESTED_MTIME" '+%Y-%m-%d %H:%M:%S.%N +0000')
jq --arg mtime "$UTC_MTIME" '.baseMtimeNs = $mtime' "$SIDE" >"$SIDE.utc"
mv -f -- "$SIDE.utc" "$SIDE"
chmod 0600 "$SIDE"
IMAGE_ROOT="$TMP_DIR/source-images" VM_ROOT="$SOURCE_ROOT" VMS_DIR="$SOURCE_ROOT" \
VM_INSTANCES_DIR="$SOURCE_ROOT" VM_BASE_DIR="$(dirname -- "$BASE")" \
QEMU_IMG="$(command -v qemu-img)" TZ=America/Los_Angeles \
    "$EXPORT" --in-place "$BASE_NAME" "$(dirname -- "$BASE")" \
    >"$TMP_DIR/export-cross-timezone.out"
grep -Fq '[g11-base-export] PASS' "$TMP_DIR/export-cross-timezone.out"

ln -s -- "$(basename "$MANIFEST")" "$BUNDLE/symlink.g11base"
if IMAGE_ROOT="$TMP_DIR/link-images" VM_ROOT="$TMP_DIR/link-vms" \
        VMS_DIR="$TMP_DIR/link-vms" VM_INSTANCES_DIR="$TMP_DIR/link-vms" \
        QEMU_IMG="$(command -v qemu-img)" \
        "$IMPORT" "$BUNDLE/symlink.g11base" >/dev/null 2>&1; then
    echo "FAIL: import accepted a symbolic-link manifest" >&2
    exit 1
fi
rm -- "$BUNDLE/symlink.g11base"

mv -- "$EXPORTED_IMAGE" "$EXPORTED_IMAGE.real"
ln -s -- "$(basename "$EXPORTED_IMAGE.real")" "$EXPORTED_IMAGE"
if IMAGE_ROOT="$TMP_DIR/link-images" VM_ROOT="$TMP_DIR/link-vms" \
        VMS_DIR="$TMP_DIR/link-vms" VM_INSTANCES_DIR="$TMP_DIR/link-vms" \
        QEMU_IMG="$(command -v qemu-img)" \
        "$IMPORT" "$MANIFEST" >/dev/null 2>&1; then
    echo "FAIL: import accepted a symbolic-link bundle image" >&2
    exit 1
fi
rm -- "$EXPORTED_IMAGE"
mv -- "$EXPORTED_IMAGE.real" "$EXPORTED_IMAGE"

IMAGE_ROOT="$TMP_DIR/import-images" VM_ROOT="$IMPORT_ROOT" VMS_DIR="$IMPORT_ROOT" \
VM_INSTANCES_DIR="$IMPORT_ROOT" QEMU_IMG="$(command -v qemu-img)" \
    "$IMPORT" "$MANIFEST" >"$TMP_DIR/import.out"
IMPORTED="$IMPORT_ROOT/_base/$BASE_NAME.qcow2"
IMPORTED_SIDE="${IMPORTED}.vgpu-portable.json"
[[ -f "$IMPORTED" && -f "$IMPORTED_SIDE" && -f "$MANIFEST" && -f "$EXPORTED_IMAGE" ]] || {
    echo "FAIL: import did not retain source and publish local files" >&2
    exit 1
}
[[ "$(stat -c %a "$IMPORTED")" == 444 ]] || {
    echo "FAIL: imported base is not sealed mode 0444" >&2
    exit 1
}
jq -e \
    --arg path "$IMPORTED" \
    --argjson bytes "$(stat -c %s "$IMPORTED")" \
    --arg device "$(stat -c %D "$IMPORTED")" \
    --arg inode "$(stat -c %i "$IMPORTED")" \
    --arg mtime "$(stat -c %y "$IMPORTED")" \
    --arg ctime "$(stat -c %z "$IMPORTED")" '
    .schemaVersion == 7 and .basePath == $path and .baseFileBytes == $bytes and
    .baseDeviceId == $device and .baseInode == $inode and
    .baseMtimeNs == $mtime and .baseCtimeNs == $ctime and
    .windowsGeneralized == true and
    .firstBootWorkflow == "licensed-portable-system-nvapi-two-boot-v1" and
    .systemNvapiDelivery == "per-vm-read-only-iso" and
    .systemNvapiRequired == true and
    .dlsHost == "dls.gvmates.com" and .dlsPort == 443
' "$IMPORTED_SIDE" >/dev/null || {
    echo "FAIL: imported attestation was not rebound to the target computer" >&2
    exit 1
}
grep -Fq '[g11-base-import] PASS' "$TMP_DIR/import.out"
grep -Fq "qcow2 compression: $EXPECTED_COMPRESSION (supported)" \
    "$TMP_DIR/import.out" || {
    echo "FAIL: import did not report verified qcow2 compression support" >&2
    exit 1
}

echo "PASS: private G-11 base supports one-image local/delivery use and copy import"

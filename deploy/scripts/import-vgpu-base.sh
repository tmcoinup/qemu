#!/usr/bin/env bash
# Import a portable private G-11 base bundle and regenerate the local
# path/inode/time-bound attestation. Source bundle is never removed.
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=../lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
# shellcheck source=../lib/vgpu-driver-assets.sh
source "$here/lib/vgpu-driver-assets.sh"
vm_storage_init

die() { echo "[g11-base-import] ERROR: $*" >&2; exit 1; }
usage() { echo "usage: $0 /absolute/path/BASE_NAME.g11base" >&2; }
sha256_upper() { sha256sum -- "$1" | awk '{print toupper($1)}'; }

(($# == 1)) || { usage; exit 2; }
MANIFEST_ARG=$1
[[ "$MANIFEST_ARG" == /* && "${MANIFEST_ARG,,}" == *.g11base ]] ||
    die "select an absolute .g11base manifest path"
for dependency in jq sha256sum stat realpath flock cp chmod mv date; do
    command -v "$dependency" >/dev/null 2>&1 || die "missing dependency: $dependency"
done
: "${QEMU_IMG:=$(command -v qemu-img)}"
[[ -x "$QEMU_IMG" ]] || die "qemu-img is missing; set QEMU_IMG explicitly"
[[ -f "$MANIFEST_ARG" && ! -L "$MANIFEST_ARG" ]] ||
    die "manifest must be a real file, not a symbolic link"
MANIFEST=$(realpath -e -- "$MANIFEST_ARG") || die "manifest does not exist"
[[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || die "manifest must be a real file"

vgpu_profile_validate_catalog || die "GPU profile catalog validation failed"
CATALOG_SHA256=$(vgpu_profile_catalog_sha256)
vgpu_select_driver_stack || die "could not select the reviewed host/guest driver pair"
[[ "$VGPU_SELECTED_DRIVER_BRANCH" == R535 &&
   "$VGPU_SELECTED_DRIVER_VERSION" == 31.0.15.3833 ]] ||
    die "private G-11 base import is reviewed only for R535/GRID 538.33 (31.0.15.3833)"
DRIVER_BRANCH=$VGPU_SELECTED_DRIVER_BRANCH
DRIVER_VERSION=$VGPU_SELECTED_DRIVER_VERSION
MANIFEST_SHA256_BEFORE=$(sha256_upper "$MANIFEST")
MANIFEST_SCHEMA=$(jq -er '.schemaVersion | numbers' "$MANIFEST") ||
    die "private G-11 bundle manifest has no numeric schema"
if [[ "$MANIFEST_SCHEMA" == 3 ]]; then
    jq -e --arg catalogSha256 "$CATALOG_SHA256" \
            --arg driverBranch "$DRIVER_BRANCH" \
            --arg driverVersion "$DRIVER_VERSION" '
    (keys | sort) == [
        "baseName", "bindingMode", "bundleType", "catalogSha256",
        "deploymentMode", "dlsHost", "dlsPort", "driverBranch",
        "driverVersion", "exportedUtc",
        "firstBootScriptGuestPath", "firstBootScriptSha256", "firstBootWorkflow",
        "guestPerformance", "imageBytes", "imageFile", "imageSha256",
        "licenseDelivery", "oobeMode", "portableBytes",
        "portableGuestPath", "portableLauncherFormat",
        "portableReceiptSchema", "portableSha256", "retryGuestPath",
        "retrySha256", "schemaVersion",
        "sysprepAnswerGuestPath", "sysprepAnswerSha256",
        "systemNvapiDelivery", "systemNvapiRequired", "windowsGeneralized"
    ] and
    .schemaVersion == 3 and .bundleType == "vmate-g11-private-base-v3" and
    (.baseName | test("^[A-Za-z0-9_-]{1,128}$")) and
    .imageFile == (.baseName + ".qcow2") and
    (.imageSha256 | test("^[0-9A-F]{64}$")) and
    (.imageBytes | type) == "number" and
    (.imageBytes | floor) == .imageBytes and .imageBytes > 0 and
    .bindingMode == "portable-auto" and
    .deploymentMode == "site-private-licensed-firstboot-v3" and
    .portableGuestPath == "C:\\ProgramData\\VMate\\G11\\VgpuPortable.exe" and
    .portableReceiptSchema == 8 and
    .portableLauncherFormat == "QEMU_VGPU_PORTABLE_LICENSED_BRANCH_V8" and
    .driverBranch == $driverBranch and .driverVersion == $driverVersion and
    (.portableSha256 | test("^[0-9A-F]{64}$")) and
    (.portableBytes | type) == "number" and
    (.portableBytes | floor) == .portableBytes and .portableBytes > 0 and
    .firstBootScriptGuestPath == "C:\\ProgramData\\VMate\\G11\\Finalize-Clone.ps1" and
    (.firstBootScriptSha256 | test("^[0-9A-F]{64}$")) and
    .retryGuestPath == "C:\\ProgramData\\VMate\\G11\\Retry-Clone-Initialization.cmd" and
    (.retrySha256 | test("^[0-9A-F]{64}$")) and
    .sysprepAnswerGuestPath == "C:\\Windows\\Panther\\unattend.xml" and
    (.sysprepAnswerSha256 | test("^[0-9A-F]{64}$")) and
    .windowsGeneralized == true and .oobeMode == "unattended-auto-finalize" and
    .licenseDelivery == "embedded-private-shared-token" and
    .firstBootWorkflow == "licensed-portable-system-nvapi-two-boot-v1" and
    .systemNvapiDelivery == "per-vm-read-only-iso" and
    .systemNvapiRequired == true and
    .dlsHost == "dls.gvmates.com" and .dlsPort == 443 and
    .guestPerformance == "embedded-recommended-native-v1" and
    .catalogSha256 == $catalogSha256 and (.exportedUtc | type) == "string"
' "$MANIFEST" >/dev/null ||
        die "private G-11 driver-bound bundle manifest is invalid or obsolete"
    IMPORT_ATTESTATION_SCHEMA=8
    IMPORT_DEPLOYMENT_MODE=site-private-licensed-firstboot-v3
    PORTABLE_RECEIPT_SCHEMA=8
    PORTABLE_LAUNCHER_FORMAT=QEMU_VGPU_PORTABLE_LICENSED_BRANCH_V8
elif [[ "$MANIFEST_SCHEMA" == 2 ]]; then
    jq -e --arg catalogSha256 "$CATALOG_SHA256" '
        (keys | sort) == [
            "baseName", "bindingMode", "bundleType", "catalogSha256",
            "deploymentMode", "dlsHost", "dlsPort", "exportedUtc",
            "firstBootScriptGuestPath", "firstBootScriptSha256",
            "firstBootWorkflow", "guestPerformance", "imageBytes",
            "imageFile", "imageSha256", "licenseDelivery", "oobeMode",
            "portableBytes", "portableGuestPath", "portableSha256",
            "retryGuestPath", "retrySha256", "schemaVersion",
            "sysprepAnswerGuestPath", "sysprepAnswerSha256",
            "systemNvapiDelivery", "systemNvapiRequired",
            "windowsGeneralized"
        ] and
        .schemaVersion == 2 and
        .bundleType == "vmate-g11-private-base-v2" and
        (.baseName | test("^[A-Za-z0-9_-]{1,128}$")) and
        .imageFile == (.baseName + ".qcow2") and
        (.imageSha256 | test("^[0-9A-F]{64}$")) and
        (.imageBytes | type) == "number" and
        (.imageBytes | floor) == .imageBytes and .imageBytes > 0 and
        .bindingMode == "portable-auto" and
        .deploymentMode == "site-private-licensed-firstboot-v2" and
        .portableGuestPath == "C:\\ProgramData\\VMate\\G11\\VgpuPortable.exe" and
        (.portableSha256 | test("^[0-9A-F]{64}$")) and
        (.portableBytes | type) == "number" and
        (.portableBytes | floor) == .portableBytes and .portableBytes > 0 and
        .firstBootScriptGuestPath == "C:\\ProgramData\\VMate\\G11\\Finalize-Clone.ps1" and
        (.firstBootScriptSha256 | test("^[0-9A-F]{64}$")) and
        .retryGuestPath == "C:\\ProgramData\\VMate\\G11\\Retry-Clone-Initialization.cmd" and
        (.retrySha256 | test("^[0-9A-F]{64}$")) and
        .sysprepAnswerGuestPath == "C:\\Windows\\Panther\\unattend.xml" and
        (.sysprepAnswerSha256 | test("^[0-9A-F]{64}$")) and
        .windowsGeneralized == true and .oobeMode == "unattended-auto-finalize" and
        .licenseDelivery == "embedded-private-shared-token" and
        .firstBootWorkflow == "licensed-portable-system-nvapi-two-boot-v1" and
        .systemNvapiDelivery == "per-vm-read-only-iso" and
        .systemNvapiRequired == true and
        .dlsHost == "dls.gvmates.com" and .dlsPort == 443 and
        .guestPerformance == "embedded-recommended-native-v1" and
        .catalogSha256 == $catalogSha256 and (.exportedUtc | type) == "string"
    ' "$MANIFEST" >/dev/null ||
        die "legacy private G-11 bundle manifest is invalid or obsolete"
    echo "[g11-base-import] accepting historical manifest schema 2 only for R535/31.0.15.3833"
    IMPORT_ATTESTATION_SCHEMA=7
    IMPORT_DEPLOYMENT_MODE=site-private-licensed-firstboot-v2
    PORTABLE_RECEIPT_SCHEMA=7
    PORTABLE_LAUNCHER_FORMAT=QEMU_VGPU_PORTABLE_LICENSED_UNIFIED_V7
else
    die "unsupported private G-11 bundle manifest schema: $MANIFEST_SCHEMA"
fi

mapfile -t MANIFEST_FIELDS < <(jq -r '
    .baseName, .imageFile, (.imageBytes | tostring), .imageSha256,
    .portableSha256, (.portableBytes | tostring),
    .firstBootScriptSha256, .retrySha256, .sysprepAnswerSha256
' "$MANIFEST")
((${#MANIFEST_FIELDS[@]} == 9)) || die "could not snapshot the private manifest"
[[ "$(sha256_upper "$MANIFEST")" == "$MANIFEST_SHA256_BEFORE" ]] ||
    die "private manifest changed while it was being validated"
BASE_NAME=${MANIFEST_FIELDS[0]}
IMAGE_FILE=${MANIFEST_FIELDS[1]}
EXPECTED_BYTES=${MANIFEST_FIELDS[2]}
EXPECTED_SHA256=${MANIFEST_FIELDS[3]}
PORTABLE_SHA256=${MANIFEST_FIELDS[4]}
PORTABLE_BYTES=${MANIFEST_FIELDS[5]}
FIRST_BOOT_SCRIPT_SHA256=${MANIFEST_FIELDS[6]}
RETRY_SHA256=${MANIFEST_FIELDS[7]}
SYSPREP_ANSWER_SHA256=${MANIFEST_FIELDS[8]}
vm_storage_validate_base_name "$BASE_NAME" || exit 2
MANIFEST_DIR=$(dirname -- "$MANIFEST")
IMAGE_ARGUMENT="$MANIFEST_DIR/$IMAGE_FILE"
[[ -f "$IMAGE_ARGUMENT" && ! -L "$IMAGE_ARGUMENT" ]] ||
    die "bundle image must be a real file, not a symbolic link"
IMAGE_SOURCE=$(realpath -e -- "$IMAGE_ARGUMENT") ||
    die "bundle image is missing beside the manifest"
[[ "$(dirname -- "$IMAGE_SOURCE")" == "$(realpath -e -- "$MANIFEST_DIR")" ]] ||
    die "bundle image may not escape the manifest directory"
[[ -f "$IMAGE_SOURCE" && ! -L "$IMAGE_SOURCE" ]] ||
    die "bundle image must be a real file"
[[ "$(stat -c %s -- "$IMAGE_SOURCE")" == "$EXPECTED_BYTES" ]] ||
    die "bundle image size does not match the manifest"
echo "[g11-base-import] verifying private image sha256; this can take several minutes"
[[ "$(sha256_upper "$IMAGE_SOURCE")" == "$EXPECTED_SHA256" ]] ||
    die "bundle image sha256 does not match the manifest"
if ! IMAGE_INFO_JSON=$("$QEMU_IMG" info --output=json -- "$IMAGE_SOURCE" 2>/dev/null); then
    die "target qemu-img cannot read this qcow2 compression format; install the current VMate/QEMU build"
fi
IMAGE_COMPRESSION_TYPE=$(jq -er '
    select(.format == "qcow2") |
    ."format-specific".data."compression-type" // "zlib"
' <<<"$IMAGE_INFO_JSON") ||
    die "bundle image does not report a supported qcow2 compression format"
[[ "$IMAGE_COMPRESSION_TYPE" == zstd || "$IMAGE_COMPRESSION_TYPE" == zlib ]] ||
    die "unsupported qcow2 compression type: $IMAGE_COMPRESSION_TYPE"
echo "[g11-base-import] qcow2 compression: $IMAGE_COMPRESSION_TYPE (supported)"
vm_storage_read_qcow2_metadata "$QEMU_IMG" "$IMAGE_SOURCE" ||
    die "bundle image is not a verifiable qcow2"
[[ -z "$VM_STORAGE_QCOW2_BACKING" && -z "$VM_STORAGE_QCOW2_DATA_FILE" ]] ||
    die "bundle image must be standalone (no backing/data file)"
"$QEMU_IMG" check -q "$IMAGE_SOURCE"

vm_storage_prepare
exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -x "$STORAGE_LOCK_FD"
TARGET=$(vm_storage_base_path "$BASE_NAME")
ATTESTATION="${TARGET}.vgpu-portable.json"
[[ ! -e "$TARGET" && ! -L "$TARGET" && ! -e "$ATTESTATION" && ! -L "$ATTESTATION" ]] ||
    die "managed base already exists; choose a new base name at the publishing computer: $BASE_NAME"
TARGET_DIR=$(dirname -- "$TARGET")
TARGET_TMP="$TARGET_DIR/.${BASE_NAME}.import.$$.$RANDOM.qcow2"
ATTESTATION_TMP="${ATTESTATION}.new.$$.$RANDOM"
PUBLISHED=0
cleanup() {
    rm -f -- "$TARGET_TMP" "$ATTESTATION_TMP"
    if (( ! PUBLISHED )); then
        rm -f -- "$TARGET" "$ATTESTATION"
    fi
}
trap cleanup EXIT

cp --reflink=auto --sparse=always -- "$IMAGE_SOURCE" "$TARGET_TMP"
chmod 0444 "$TARGET_TMP"
[[ "$(stat -c %s -- "$TARGET_TMP")" == "$EXPECTED_BYTES" &&
   "$(sha256_upper "$TARGET_TMP")" == "$EXPECTED_SHA256" ]] ||
    die "local imported copy changed during transfer"
"$QEMU_IMG" check -q "$TARGET_TMP"
mv -T -- "$TARGET_TMP" "$TARGET"

BASE_FILE_BYTES=$(stat -c %s -- "$TARGET")
BASE_DEVICE_ID=$(stat -c %D -- "$TARGET")
BASE_INODE=$(stat -c %i -- "$TARGET")
BASE_MTIME_NS=$(stat -c %y -- "$TARGET")
BASE_CTIME_NS=$(stat -c %z -- "$TARGET")
jq -n \
    --argjson schemaVersion "$IMPORT_ATTESTATION_SCHEMA" \
    --arg deploymentMode "$IMPORT_DEPLOYMENT_MODE" \
    --arg basePath "$TARGET" \
    --argjson baseFileBytes "$BASE_FILE_BYTES" \
    --arg baseDeviceId "$BASE_DEVICE_ID" \
    --arg baseInode "$BASE_INODE" \
    --arg baseMtimeNs "$BASE_MTIME_NS" \
    --arg baseCtimeNs "$BASE_CTIME_NS" \
    --arg portableSha256 "$PORTABLE_SHA256" \
    --argjson portableBytes "$PORTABLE_BYTES" \
    --arg firstBootScriptSha256 "$FIRST_BOOT_SCRIPT_SHA256" \
    --arg retrySha256 "$RETRY_SHA256" \
    --arg sysprepAnswerSha256 "$SYSPREP_ANSWER_SHA256" \
    --argjson portableReceiptSchema "$PORTABLE_RECEIPT_SCHEMA" \
    --arg portableLauncherFormat "$PORTABLE_LAUNCHER_FORMAT" \
    --arg driverBranch "$DRIVER_BRANCH" \
    --arg driverVersion "$DRIVER_VERSION" \
    --arg catalogSha256 "$CATALOG_SHA256" \
    --arg installedUtc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {
        schemaVersion: $schemaVersion,
        bindingMode: "portable-auto",
        deploymentMode: $deploymentMode,
        basePath: $basePath,
        baseFileBytes: $baseFileBytes,
        baseDeviceId: $baseDeviceId,
        baseInode: $baseInode,
        baseMtimeNs: $baseMtimeNs,
        baseCtimeNs: $baseCtimeNs,
        portableGuestPath: "C:\\ProgramData\\VMate\\G11\\VgpuPortable.exe",
        portableSha256: $portableSha256,
        portableBytes: $portableBytes,
        firstBootScriptGuestPath: "C:\\ProgramData\\VMate\\G11\\Finalize-Clone.ps1",
        firstBootScriptSha256: $firstBootScriptSha256,
        retryGuestPath: "C:\\ProgramData\\VMate\\G11\\Retry-Clone-Initialization.cmd",
        retrySha256: $retrySha256,
        sysprepAnswerGuestPath: "C:\\Windows\\Panther\\unattend.xml",
        sysprepAnswerSha256: $sysprepAnswerSha256,
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
        installedUtc: $installedUtc
    } + (if $schemaVersion == 8 then {
        portableReceiptSchema: $portableReceiptSchema,
        portableLauncherFormat: $portableLauncherFormat,
        driverBranch: $driverBranch,
        driverVersion: $driverVersion
    } else {} end)' >"$ATTESTATION_TMP"
chmod 0600 "$ATTESTATION_TMP"
mv -T -- "$ATTESTATION_TMP" "$ATTESTATION"
PUBLISHED=1
trap - EXIT

cat <<EOF
[g11-base-import] PASS
  base name: $BASE_NAME
  image:     $TARGET
  driver:    $DRIVER_BRANCH / $DRIVER_VERSION
  source:    retained at $MANIFEST_DIR
G11_IMPORTED_BASE_NAME=$BASE_NAME
G11_IMPORTED_PATH=$TARGET
EOF

#!/usr/bin/env bash
# Export one locally bound private G-11 Sysprep base. Normal mode makes a
# copy-only bundle; --in-place writes the transfer manifest beside the same
# locally cloneable qcow2 and therefore retains exactly one image.
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

die() { echo "[g11-base-export] ERROR: $*" >&2; exit 1; }
usage() {
    echo "usage: $0 [--in-place] BASE_NAME OUTPUT_DIRECTORY" >&2
}
sha256_upper() { sha256sum -- "$1" | awk '{print toupper($1)}'; }

IN_PLACE=0
declare -a POSITIONAL=()
while (($#)); do
    case "$1" in
        --in-place) IN_PLACE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --*) die "unknown option: $1" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
((${#POSITIONAL[@]} == 2)) || { usage; exit 2; }
BASE_NAME=${POSITIONAL[0]}
OUTPUT_PARENT=${POSITIONAL[1]}
vm_storage_validate_base_name "$BASE_NAME" || exit 2
[[ "$OUTPUT_PARENT" == /* && "$OUTPUT_PARENT" != / ]] ||
    die "OUTPUT_DIRECTORY must be a non-root absolute path"
for dependency in jq sha256sum stat realpath flock cp mkdir chmod mv date; do
    command -v "$dependency" >/dev/null 2>&1 || die "missing dependency: $dependency"
done
: "${QEMU_IMG:=$(command -v qemu-img || true)}"
[[ -x "$QEMU_IMG" ]] || die "qemu-img is missing; set QEMU_IMG explicitly"

vgpu_profile_validate_catalog || die "GPU profile catalog validation failed"
CATALOG_SHA256=$(vgpu_profile_catalog_sha256)
vgpu_select_driver_stack || die "could not select the reviewed host/guest driver pair"
[[ "$VGPU_SELECTED_DRIVER_BRANCH" == R535 &&
   "$VGPU_SELECTED_DRIVER_VERSION" == 31.0.15.3833 ]] ||
    die "private G-11 base export is reviewed only for R535/GRID 538.33 (31.0.15.3833)"
DRIVER_BRANCH=$VGPU_SELECTED_DRIVER_BRANCH
DRIVER_VERSION=$VGPU_SELECTED_DRIVER_VERSION
vm_storage_prepare
BASE=$(vm_storage_base_path "$BASE_NAME")
ATTESTATION="${BASE}.vgpu-portable.json"
[[ -f "$BASE" && ! -L "$BASE" ]] || die "managed base is missing: $BASE"
[[ -f "$ATTESTATION" && ! -L "$ATTESTATION" ]] ||
    die "private base attestation is missing: $ATTESTATION"

exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -s "$STORAGE_LOCK_FD"
BASE_FILE_BYTES=$(stat -c %s -- "$BASE")
BASE_DEVICE_ID=$(stat -c %D -- "$BASE")
BASE_INODE=$(stat -c %i -- "$BASE")
OBSERVED_BASE_MTIME_NS=$(TZ=UTC stat -c %y -- "$BASE")
BASE_CTIME_NS=$(TZ=UTC stat -c %z -- "$BASE")
BASE_MTIME_NS=$(jq -er '.baseMtimeNs | strings' "$ATTESTATION") ||
    die "private base attestation has no string mtime"
OBSERVED_BASE_MTIME_INSTANT=$(date -u -d "$OBSERVED_BASE_MTIME_NS" '+%s.%N') ||
    die "could not normalize the base image mtime"
ATTESTED_BASE_MTIME_INSTANT=$(date -u -d "$BASE_MTIME_NS" '+%s.%N') ||
    die "private base attestation has an invalid mtime"
[[ "$OBSERVED_BASE_MTIME_INSTANT" == "$ATTESTED_BASE_MTIME_INSTANT" ]] ||
    die "base image mtime changed after portable-package installation"
# Instance-local hard-link pins change only inode ctime. Keep ctime as an audit
# field, while content eligibility remains bound to inode/size/mtime and the
# exported transfer manifest receives a fresh full-image SHA-256 below.
ATTESTATION_SCHEMA=$(jq -er '.schemaVersion | numbers' "$ATTESTATION") ||
    die "private base attestation has no numeric schema"
if [[ "$ATTESTATION_SCHEMA" == 8 ]]; then
    jq -e \
    --arg basePath "$BASE" \
    --argjson baseFileBytes "$BASE_FILE_BYTES" \
    --arg baseDeviceId "$BASE_DEVICE_ID" \
    --arg baseInode "$BASE_INODE" \
    --arg baseMtimeNs "$BASE_MTIME_NS" \
    --arg baseCtimeNs "$BASE_CTIME_NS" \
    --arg catalogSha256 "$CATALOG_SHA256" \
    --arg driverBranch "$DRIVER_BRANCH" \
    --arg driverVersion "$DRIVER_VERSION" '
    (keys | sort) == [
        "baseCtimeNs", "baseDeviceId", "baseFileBytes", "baseInode",
        "baseMtimeNs", "basePath", "bindingMode", "catalogSha256",
        "deploymentMode", "dlsHost", "dlsPort", "driverBranch",
        "driverVersion",
        "firstBootScriptGuestPath", "firstBootScriptSha256", "firstBootWorkflow",
        "guestPerformance", "installedUtc", "licenseDelivery", "oobeMode",
        "portableBytes", "portableGuestPath", "portableLauncherFormat",
        "portableReceiptSchema", "portableSha256",
        "retryGuestPath", "retrySha256", "schemaVersion",
        "sysprepAnswerGuestPath", "sysprepAnswerSha256",
        "systemNvapiDelivery", "systemNvapiRequired", "windowsGeneralized"
    ] and
    .schemaVersion == 8 and .bindingMode == "portable-auto" and
    .deploymentMode == "site-private-licensed-firstboot-v3" and
    .basePath == $basePath and .baseFileBytes == $baseFileBytes and
    .baseDeviceId == $baseDeviceId and .baseInode == $baseInode and
    .baseMtimeNs == $baseMtimeNs and
    (.baseCtimeNs | type) == "string" and
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
    .catalogSha256 == $catalogSha256 and (.installedUtc | type) == "string"
' "$ATTESTATION" >/dev/null ||
        die "the base is not a current driver-bound private Sysprep generation"
    EXPORT_MANIFEST_SCHEMA=3
    EXPORT_BUNDLE_TYPE=vmate-g11-private-base-v3
    EXPORT_DEPLOYMENT_MODE=site-private-licensed-firstboot-v3
    PORTABLE_RECEIPT_SCHEMA=8
    PORTABLE_LAUNCHER_FORMAT=QEMU_VGPU_PORTABLE_LICENSED_BRANCH_V8
elif [[ "$ATTESTATION_SCHEMA" == 7 ]]; then
    jq -e \
        --arg basePath "$BASE" \
        --argjson baseFileBytes "$BASE_FILE_BYTES" \
        --arg baseDeviceId "$BASE_DEVICE_ID" \
        --arg baseInode "$BASE_INODE" \
        --arg baseMtimeNs "$BASE_MTIME_NS" \
        --arg catalogSha256 "$CATALOG_SHA256" '
        (keys | sort) == [
            "baseCtimeNs", "baseDeviceId", "baseFileBytes", "baseInode",
            "baseMtimeNs", "basePath", "bindingMode", "catalogSha256",
            "deploymentMode", "dlsHost", "dlsPort",
            "firstBootScriptGuestPath", "firstBootScriptSha256",
            "firstBootWorkflow", "guestPerformance", "installedUtc",
            "licenseDelivery", "oobeMode", "portableBytes",
            "portableGuestPath", "portableSha256", "retryGuestPath",
            "retrySha256", "schemaVersion", "sysprepAnswerGuestPath",
            "sysprepAnswerSha256", "systemNvapiDelivery",
            "systemNvapiRequired", "windowsGeneralized"
        ] and
        .schemaVersion == 7 and .bindingMode == "portable-auto" and
        .deploymentMode == "site-private-licensed-firstboot-v2" and
        .basePath == $basePath and .baseFileBytes == $baseFileBytes and
        .baseDeviceId == $baseDeviceId and .baseInode == $baseInode and
        .baseMtimeNs == $baseMtimeNs and
        (.baseCtimeNs | type) == "string" and
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
        .catalogSha256 == $catalogSha256 and (.installedUtc | type) == "string"
    ' "$ATTESTATION" >/dev/null ||
        die "legacy private base attestation is invalid"
    echo "[g11-base-export] accepting historical schema-7 base only for R535/31.0.15.3833"
    EXPORT_MANIFEST_SCHEMA=2
    EXPORT_BUNDLE_TYPE=vmate-g11-private-base-v2
    EXPORT_DEPLOYMENT_MODE=site-private-licensed-firstboot-v2
    PORTABLE_RECEIPT_SCHEMA=7
    PORTABLE_LAUNCHER_FORMAT=QEMU_VGPU_PORTABLE_LICENSED_UNIFIED_V7
else
    die "unsupported private base attestation schema: $ATTESTATION_SCHEMA"
fi

vm_storage_read_qcow2_metadata "$QEMU_IMG" "$BASE" ||
    die "base is not a verifiable qcow2 image"
[[ -z "$VM_STORAGE_QCOW2_BACKING" && -z "$VM_STORAGE_QCOW2_DATA_FILE" ]] ||
    die "base must be standalone (no backing/data file)"
"$QEMU_IMG" check -q "$BASE"

mkdir -p -- "$OUTPUT_PARENT"
OUTPUT_PARENT=$(realpath -e -- "$OUTPUT_PARENT") || die "cannot resolve output directory"
[[ -d "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] ||
    die "output must be a real directory"
CREATED_BUNDLE=0
if ((IN_PLACE)); then
    BASE_PARENT=$(realpath -e -- "$(dirname -- "$BASE")") ||
        die "cannot resolve the managed base directory"
    [[ "$OUTPUT_PARENT" == "$BASE_PARENT" ]] ||
        die "--in-place output must equal VM_BASE_DIR: $BASE_PARENT"
    BUNDLE_DIR=$OUTPUT_PARENT
else
    BUNDLE_DIR="$OUTPUT_PARENT/${BASE_NAME}-g11-private"
    [[ ! -e "$BUNDLE_DIR" && ! -L "$BUNDLE_DIR" ]] ||
        die "output bundle already exists: $BUNDLE_DIR"
    mkdir -m 0700 -- "$BUNDLE_DIR"
    CREATED_BUNDLE=1
fi
COMPLETE=0
MANIFEST_TMP=""
cleanup() {
    if (( ! COMPLETE )); then
        rm -f -- "${MANIFEST_TMP:-}"
        if ((CREATED_BUNDLE)); then
            rm -rf -- "$BUNDLE_DIR"
        fi
    fi
}
trap cleanup EXIT

IMAGE_FILE="${BASE_NAME}.qcow2"
MANIFEST_FILE="${BASE_NAME}.g11base"
IMAGE_OUT="$BUNDLE_DIR/$IMAGE_FILE"
MANIFEST_OUT="$BUNDLE_DIR/$MANIFEST_FILE"
REPLACE_MANIFEST=0
MANIFEST_UID=""
MANIFEST_GID=""
if [[ -e "$MANIFEST_OUT" || -L "$MANIFEST_OUT" ]]; then
    ((IN_PLACE)) || die "output manifest already exists: $MANIFEST_OUT"
    [[ -f "$MANIFEST_OUT" && ! -L "$MANIFEST_OUT" ]] ||
        die "existing in-place manifest is not a regular non-symlink file: $MANIFEST_OUT"
    jq -e --arg baseName "$BASE_NAME" --arg imageFile "$IMAGE_FILE" \
            --arg driverBranch "$DRIVER_BRANCH" \
            --arg driverVersion "$DRIVER_VERSION" '
        (
            ((keys | sort) == [
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
             .deploymentMode == "site-private-licensed-firstboot-v2")
            or
            ((keys | sort) == [
                "baseName", "bindingMode", "bundleType", "catalogSha256",
                "deploymentMode", "dlsHost", "dlsPort", "driverBranch",
                "driverVersion", "exportedUtc", "firstBootScriptGuestPath",
                "firstBootScriptSha256", "firstBootWorkflow",
                "guestPerformance", "imageBytes", "imageFile",
                "imageSha256", "licenseDelivery", "oobeMode",
                "portableBytes", "portableGuestPath",
                "portableLauncherFormat", "portableReceiptSchema",
                "portableSha256", "retryGuestPath", "retrySha256",
                "schemaVersion", "sysprepAnswerGuestPath",
                "sysprepAnswerSha256", "systemNvapiDelivery",
                "systemNvapiRequired", "windowsGeneralized"
            ] and
             .schemaVersion == 3 and
             .bundleType == "vmate-g11-private-base-v3" and
             .deploymentMode == "site-private-licensed-firstboot-v3" and
             .portableReceiptSchema == 8 and
             .portableLauncherFormat ==
                "QEMU_VGPU_PORTABLE_LICENSED_BRANCH_V8" and
             .driverBranch == $driverBranch and
             .driverVersion == $driverVersion)
        ) and
        .baseName == $baseName and .imageFile == $imageFile and
        .bindingMode == "portable-auto" and
        (.imageSha256 | test("^[0-9A-F]{64}$")) and
        (.imageBytes | type) == "number" and .imageBytes > 0 and
        .portableGuestPath == "C:\\ProgramData\\VMate\\G11\\VgpuPortable.exe" and
        (.portableSha256 | test("^[0-9A-F]{64}$")) and
        (.portableBytes | type) == "number" and .portableBytes > 0 and
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
        (.catalogSha256 | test("^[0-9A-F]{64}$")) and
        (.exportedUtc | type) == "string"
    ' "$MANIFEST_OUT" >/dev/null ||
        die "existing in-place manifest is not a valid managed G-11 manifest"
    REPLACE_MANIFEST=1
    MANIFEST_UID=$(stat -c %u -- "$MANIFEST_OUT")
    MANIFEST_GID=$(stat -c %g -- "$MANIFEST_OUT")
fi
if ((IN_PLACE)); then
    IMAGE_OUT=$BASE
    echo "[g11-base-export] hashing the single local/delivery qcow2; no image copy is made"
else
    echo "[g11-base-export] copying private qcow2; this can take several minutes"
    cp --reflink=auto --sparse=always -- "$BASE" "$IMAGE_OUT"
    chmod 0600 "$IMAGE_OUT"
    "$QEMU_IMG" check -q "$IMAGE_OUT"
fi
IMAGE_BYTES=$(stat -c %s -- "$IMAGE_OUT")
[[ "$IMAGE_BYTES" == "$BASE_FILE_BYTES" ]] || die "exported image size changed"
IMAGE_SHA256=$(sha256_upper "$IMAGE_OUT")

MANIFEST_TMP="$BUNDLE_DIR/.${MANIFEST_FILE}.new.$$.$RANDOM"
jq -n \
    --argjson schemaVersion "$EXPORT_MANIFEST_SCHEMA" \
    --arg bundleType "$EXPORT_BUNDLE_TYPE" \
    --arg deploymentMode "$EXPORT_DEPLOYMENT_MODE" \
    --arg baseName "$BASE_NAME" \
    --arg imageFile "$IMAGE_FILE" \
    --arg imageSha256 "$IMAGE_SHA256" \
    --argjson imageBytes "$IMAGE_BYTES" \
    --arg catalogSha256 "$CATALOG_SHA256" \
    --arg portableSha256 "$(jq -r '.portableSha256' "$ATTESTATION")" \
    --argjson portableBytes "$(jq -r '.portableBytes' "$ATTESTATION")" \
    --arg firstBootScriptSha256 "$(jq -r '.firstBootScriptSha256' "$ATTESTATION")" \
    --arg retrySha256 "$(jq -r '.retrySha256' "$ATTESTATION")" \
    --arg sysprepAnswerSha256 "$(jq -r '.sysprepAnswerSha256' "$ATTESTATION")" \
    --argjson portableReceiptSchema "$PORTABLE_RECEIPT_SCHEMA" \
    --arg portableLauncherFormat "$PORTABLE_LAUNCHER_FORMAT" \
    --arg driverBranch "$DRIVER_BRANCH" \
    --arg driverVersion "$DRIVER_VERSION" \
    --arg exportedUtc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {
        schemaVersion: $schemaVersion,
        bundleType: $bundleType,
        baseName: $baseName,
        imageFile: $imageFile,
        imageSha256: $imageSha256,
        imageBytes: $imageBytes,
        bindingMode: "portable-auto",
        deploymentMode: $deploymentMode,
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
        exportedUtc: $exportedUtc
    } + (if $schemaVersion == 3 then {
        portableReceiptSchema: $portableReceiptSchema,
        portableLauncherFormat: $portableLauncherFormat,
        driverBranch: $driverBranch,
        driverVersion: $driverVersion
    } else {} end)' >"$MANIFEST_TMP"
chmod 0600 "$MANIFEST_TMP"
if ((REPLACE_MANIFEST)); then
    chown "$MANIFEST_UID:$MANIFEST_GID" "$MANIFEST_TMP"
fi
mv -T -- "$MANIFEST_TMP" "$MANIFEST_OUT"
MANIFEST_TMP=""
COMPLETE=1
trap - EXIT

cat <<EOF
[g11-base-export] PASS
  manifest: $MANIFEST_OUT
  image:    $IMAGE_OUT
  sha256:   $IMAGE_SHA256
  driver:   $DRIVER_BRANCH / $DRIVER_VERSION
  layout:   $([[ "$IN_PLACE" == 1 ]] && echo 'one qcow2 / local + delivery' || echo 'copy-only bundle')

这是私有授权镜像包。复制时必须同时保留上面两个文件；目标电脑在 VMate 中选择
${MANIFEST_FILE} 导入。本机可直接用同一个 qcow2 克隆；不要上传到公开仓库或公共网盘。
EOF

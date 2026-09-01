#!/usr/bin/env bash
# Refresh one already-generalized private G-11 base with the clone payload in
# this checkout. Existing linked clones keep their instance-local hard-link
# pin; only clones created after this transaction use the refreshed base.
set -euo pipefail
umask 077
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=../lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
# shellcheck source=../lib/vgpu-driver-assets.sh
source "$here/lib/vgpu-driver-assets.sh"

die() { echo "[g11-base-refresh] ERROR: $*" >&2; exit 1; }
usage() {
    cat <<'EOF' >&2
usage: ./deploy/scripts/refresh-g11-private-base.sh BASE_NAME [options]

Options:
  --check                 Read-only current/stale check
  --vms-dir DIRECTORY     G-11 VM root
  --base-dir DIRECTORY    Managed base directory (default: VMS_DIR/_base)
  --exe FILE.exe          Explicit repository-external licensed portable EXE
  --token-file FILE.tok   Rebuild the licensed EXE from this secure token path
  --replace-licensed      Allow intentional licensed EXE/token replacement
  -h, --help              Show this help

Without --token-file, the command reuses the authenticated licensed EXE under
$STAGE_DIR/VgpuPortableLicensed. No credential is copied into the repository.
The base must already be a private Sysprep-generalized managed image.
EOF
}
sha256_upper() { sha256sum -- "$1" | awk '{print toupper($1)}'; }

CHECK_ONLY=0
CLI_VMS_DIR=""
CLI_BASE_DIR=""
PORTABLE_EXE=""
TOKEN_FILE=""
REPLACE_LICENSED=0
declare -a POSITIONAL=()
while (($#)); do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --vms-dir)
            (($# >= 2)) || die "--vms-dir requires a directory"
            [[ -z "$CLI_VMS_DIR" ]] || die "--vms-dir may be specified once"
            CLI_VMS_DIR=$2
            shift 2
            ;;
        --vms-dir=*)
            [[ -z "$CLI_VMS_DIR" ]] || die "--vms-dir may be specified once"
            CLI_VMS_DIR=${1#*=}
            shift
            ;;
        --base-dir)
            (($# >= 2)) || die "--base-dir requires a directory"
            [[ -z "$CLI_BASE_DIR" ]] || die "--base-dir may be specified once"
            CLI_BASE_DIR=$2
            shift 2
            ;;
        --base-dir=*)
            [[ -z "$CLI_BASE_DIR" ]] || die "--base-dir may be specified once"
            CLI_BASE_DIR=${1#*=}
            shift
            ;;
        --exe)
            (($# >= 2)) || die "--exe requires FILE.exe"
            [[ -z "$PORTABLE_EXE" ]] || die "--exe may be specified once"
            PORTABLE_EXE=$2
            shift 2
            ;;
        --token-file)
            (($# >= 2)) || die "--token-file requires FILE.tok"
            [[ -z "$TOKEN_FILE" ]] || die "--token-file may be specified once"
            TOKEN_FILE=$2
            shift 2
            ;;
        --replace-licensed) REPLACE_LICENSED=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --*) die "unknown option: $1" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
((${#POSITIONAL[@]} == 1)) || { usage; exit 2; }
BASE_NAME=${POSITIONAL[0]}
[[ -z "$TOKEN_FILE" || -z "$PORTABLE_EXE" ]] ||
    die "--token-file and --exe cannot be combined"
((CHECK_ONLY == 0 || REPLACE_LICENSED == 0)) ||
    die "--check cannot be combined with --replace-licensed"
[[ $CHECK_ONLY == 0 || -z "$TOKEN_FILE" ]] ||
    die "--check cannot be combined with --token-file"
[[ $CHECK_ONLY == 0 || -z "$PORTABLE_EXE" ]] ||
    die "--check cannot be combined with --exe"

if [[ -n "$CLI_VMS_DIR" ]]; then
    vm_storage_select_root "$CLI_VMS_DIR" || exit $?
fi
vm_storage_init
if [[ -n "$CLI_BASE_DIR" ]]; then
    vm_storage_validate_root_path "$CLI_BASE_DIR" "base directory" || exit $?
    export VM_BASE_DIR=${CLI_BASE_DIR%/}
    export VM_BASE_ARCHIVE_DIR="$VM_BASE_DIR/archive"
fi
vm_storage_validate_base_name "$BASE_NAME" || exit 2

for dependency in jq sha256sum awk sed stat date grep realpath; do
    command -v "$dependency" >/dev/null 2>&1 ||
        die "missing dependency: $dependency"
done
BASE=$(vm_storage_base_path "$BASE_NAME")
ATTESTATION="${BASE}.vgpu-portable.json"
[[ -f "$BASE" && ! -L "$BASE" ]] ||
    die "managed base is missing or unsafe: $BASE"
[[ -f "$ATTESTATION" && ! -L "$ATTESTATION" ]] ||
    die "private base attestation is missing or unsafe: $ATTESTATION"

FINALIZER="$here/guest/finalize-g11-clone.ps1"
RETRY="$here/guest/Retry-Clone-Initialization.cmd"
SYSPREP_ANSWER="$here/autounattend/g11-sysprep-clone.xml"
GUEST_LITE_MANIFEST="$here/guest/guest-lite/clone-manifest.json"
STORAGE_PORTABILITY="$here/guest/Prepare-G11-Storage-Portability.ps1"
for payload in "$FINALIZER" "$RETRY" "$SYSPREP_ANSWER" \
        "$GUEST_LITE_MANIFEST" "$STORAGE_PORTABILITY"; do
    [[ -f "$payload" && ! -L "$payload" && -s "$payload" ]] ||
        die "current private clone payload is missing or unsafe: $payload"
done
FINALIZER_SHA256=$(sha256_upper "$FINALIZER")
RETRY_SHA256=$(sha256_upper "$RETRY")
SYSPREP_ANSWER_SHA256=$(sha256_upper "$SYSPREP_ANSWER")
GUEST_LITE_MANIFEST_SHA256=$(sha256_upper "$GUEST_LITE_MANIFEST")
STORAGE_PORTABILITY_SHA256=$(sha256_upper "$STORAGE_PORTABILITY")
PINNED_MANIFEST_SHA256=$(sed -n \
    "s/^\\\$ExpectedGuestLiteManifestSha256 = '\\([0-9A-F]\\{64\\}\\)'$/\\1/p" \
    "$FINALIZER")
[[ "$PINNED_MANIFEST_SHA256" == "$GUEST_LITE_MANIFEST_SHA256" ]] ||
    die "current finalizer does not pin the current Guest Lite manifest"
PINNED_STORAGE_SHA256=$(sed -n \
    "s/^\\\$ExpectedStoragePortabilitySha256 = '\([0-9A-F]\{64\}\)'$/\1/p" \
    "$FINALIZER")
[[ "$PINNED_STORAGE_SHA256" == "$STORAGE_PORTABILITY_SHA256" ]] ||
    die "current finalizer does not pin the storage portability helper"
jq -e '
    (keys | sort) == ["files", "profileVersion", "schemaVersion"] and
    .schemaVersion == 1 and .profileVersion == "2.6.7"
' "$GUEST_LITE_MANIFEST" >/dev/null ||
    die "current Guest Lite manifest is not the supported 2.6.7 contract"
grep -Fq 'schemaVersion = 4' "$FINALIZER" ||
    die "current finalizer does not publish clone marker schema 4"

vgpu_profile_validate_catalog || die "GPU profile catalog validation failed"
CATALOG_SHA256=$(vgpu_profile_catalog_sha256)
vgpu_select_driver_stack || die "could not select the reviewed host/guest driver pair"
[[ "$VGPU_SELECTED_DRIVER_BRANCH" == R535 &&
   "$VGPU_SELECTED_DRIVER_VERSION" == 31.0.15.3833 ]] ||
    die "private G-11 base refresh is reviewed only for R535/GRID 538.33 (31.0.15.3833)"
DRIVER_BRANCH=$VGPU_SELECTED_DRIVER_BRANCH
DRIVER_VERSION=$VGPU_SELECTED_DRIVER_VERSION
BASE_FILE_BYTES=$(stat -c %s -- "$BASE")
BASE_DEVICE_ID=$(stat -c %D -- "$BASE")
BASE_INODE=$(stat -c %i -- "$BASE")
OBSERVED_BASE_MTIME_NS=$(TZ=UTC stat -c %y -- "$BASE")
ATTESTED_BASE_MTIME_NS=$(jq -er '.baseMtimeNs | strings' "$ATTESTATION" 2>/dev/null || true)
MTIME_MATCHES=0
if [[ -n "$ATTESTED_BASE_MTIME_NS" ]]; then
    OBSERVED_BASE_MTIME_INSTANT=$(date -u -d "$OBSERVED_BASE_MTIME_NS" '+%s.%N' 2>/dev/null || true)
    ATTESTED_BASE_MTIME_INSTANT=$(date -u -d "$ATTESTED_BASE_MTIME_NS" '+%s.%N' 2>/dev/null || true)
    [[ -z "$OBSERVED_BASE_MTIME_INSTANT" ||
       "$OBSERVED_BASE_MTIME_INSTANT" != "$ATTESTED_BASE_MTIME_INSTANT" ]] ||
        MTIME_MATCHES=1
fi

CURRENT=0
if ((MTIME_MATCHES)) && jq -e \
        --arg basePath "$BASE" \
        --argjson baseFileBytes "$BASE_FILE_BYTES" \
        --arg baseDeviceId "$BASE_DEVICE_ID" \
        --arg baseInode "$BASE_INODE" \
        --arg catalogSha256 "$CATALOG_SHA256" \
        --arg finalizerSha256 "$FINALIZER_SHA256" \
        --arg retrySha256 "$RETRY_SHA256" \
        --arg sysprepAnswerSha256 "$SYSPREP_ANSWER_SHA256" \
        --arg driverBranch "$DRIVER_BRANCH" \
        --arg driverVersion "$DRIVER_VERSION" '
    (
        ((keys | sort) == [
            "baseCtimeNs", "baseDeviceId", "baseFileBytes", "baseInode",
            "baseMtimeNs", "basePath", "bindingMode", "catalogSha256",
            "deploymentMode", "dlsHost", "dlsPort", "driverBranch",
            "driverVersion", "firstBootScriptGuestPath",
            "firstBootScriptSha256", "firstBootWorkflow",
            "guestPerformance", "installedUtc", "licenseDelivery",
            "oobeMode", "portableBytes", "portableGuestPath",
            "portableLauncherFormat", "portableReceiptSchema",
            "portableSha256", "retryGuestPath", "retrySha256",
            "schemaVersion", "sysprepAnswerGuestPath",
            "sysprepAnswerSha256", "systemNvapiDelivery",
            "systemNvapiRequired", "windowsGeneralized"
        ] and
         .schemaVersion == 8 and
         .deploymentMode == "site-private-licensed-firstboot-v3" and
         .portableReceiptSchema == 8 and
         .portableLauncherFormat ==
            "QEMU_VGPU_PORTABLE_LICENSED_BRANCH_V8" and
         .driverBranch == $driverBranch and
         .driverVersion == $driverVersion)
        or
        ((keys | sort) == [
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
         .schemaVersion == 7 and
         .deploymentMode == "site-private-licensed-firstboot-v2")
    ) and
    .basePath == $basePath and
    .baseFileBytes == $baseFileBytes and
    .baseDeviceId == $baseDeviceId and .baseInode == $baseInode and
    .catalogSha256 == $catalogSha256 and
    .firstBootScriptSha256 == $finalizerSha256 and
    .retrySha256 == $retrySha256 and
    .sysprepAnswerSha256 == $sysprepAnswerSha256 and
    .windowsGeneralized == true and
    .firstBootWorkflow == "licensed-portable-system-nvapi-two-boot-v1"
' "$ATTESTATION" >/dev/null; then
    CURRENT=1
fi

if ((CHECK_ONLY)); then
    if ((CURRENT)); then
        echo "[g11-base-refresh] PASS: $BASE_NAME already embeds marker schema 4 / Guest Lite 2.6.7 / SATA+NVMe helper"
        exit 0
    fi
    echo "[g11-base-refresh] STALE: $BASE_NAME must be refreshed before another clone" >&2
    exit 1
fi

if ((CURRENT)) && [[ -z "$TOKEN_FILE" && -z "$PORTABLE_EXE" ]] &&
        ((REPLACE_LICENSED == 0)); then
    echo "[g11-base-refresh] $BASE_NAME payload is current; refreshing its in-place transfer manifest"
    "$here/scripts/export-vgpu-base.sh" --in-place "$BASE_NAME" "$VM_BASE_DIR"
    echo "[g11-base-refresh] PASS: $BASE_NAME is current; no image was rewritten"
    exit 0
fi

if [[ -n "$TOKEN_FILE" ]]; then
    PACKAGE_ARGS=(--token-file "$TOKEN_FILE")
    ((REPLACE_LICENSED == 0)) || PACKAGE_ARGS+=(--replace-licensed)
    "$here/package-vgpu-one-click.sh" "${PACKAGE_ARGS[@]}"
elif ((REPLACE_LICENSED)); then
    "$here/package-vgpu-one-click.sh" --with-license-token --replace-licensed
fi

INSTALL_ARGS=(
    --base-name "$BASE_NAME"
    --site-private
    --sysprep-generalized
    --single-image
    --yes
)
[[ -z "$PORTABLE_EXE" ]] || INSTALL_ARGS+=(--exe "$PORTABLE_EXE")

echo "[g11-base-refresh] atomically refreshing $BASE_NAME; existing clone pins are unchanged"
"$here/install-vgpu-portable-to-base.sh" "${INSTALL_ARGS[@]}"
"$here/scripts/export-vgpu-base.sh" --in-place "$BASE_NAME" "$VM_BASE_DIR"

cat <<EOF
[g11-base-refresh] PASS: $BASE_NAME now embeds marker schema 4 / Guest Lite 2.6.7 / SATA+NVMe helper

后续克隆直接运行：
  ./deploy/scripts/clone-from-base.sh $BASE_NAME NEW_VM_ID --start

旧克隆不会被本次母盘换代覆盖；失败旧克隆使用：
  sudo ./deploy/scripts/repair-clone-init.sh OLD_VM_ID
EOF

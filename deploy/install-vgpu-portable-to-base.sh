#!/usr/bin/env bash
# Atomically place either the public portable tool or the private licensed
# Sysprep first-boot finalizer into a standalone Windows clone base.  The live
# base is never mounted or edited.
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
ORIGINAL_ARGS=("$@")

# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
# shellcheck source=lib/gpuz-assets.sh
source "$here/lib/gpuz-assets.sh"
# shellcheck source=lib/vgpu-driver-assets.sh
source "$here/lib/vgpu-driver-assets.sh"
vm_storage_init

usage() {
    cat <<'EOF'
usage: ./deploy/install-vgpu-portable-to-base.sh [options]

Options:
  --base-name NAME   Managed base created by seal-base.sh (recommended)
                     Example: win10-ltsc-v1; omit .qcow2
  --base IMAGE       Explicit Windows standalone qcow2 path (advanced)
                     Cannot be combined with --base-name
  --exe FILE.exe     Portable guest EXE
                     (public default: $STAGE_DIR/VgpuPortable/VgpuPortable.exe;
                     private default:
                     $STAGE_DIR/VgpuPortableLicensed/VgpuPortable.exe)
  --site-private     Inject the driver-bound licensed V8 EXE and automatic Sysprep
                     clone finalizer into C:\ProgramData\VMate\G11
  --sysprep-generalized
                     Required acknowledgement for --site-private: the input
                     Windows image was shut down by Sysprep /generalize
                     /oobe /shutdown
  --with-gpuz        Also place the audited GPU-Z.exe beside the EXE (optional)
  --gpuz-source FILE Audited external TechPowerUp GPU-Z 2.70 executable
                     (implies --with-gpuz; default source when selected:
                     $IMAGE_ROOT/candidates/gpuz-2.70-audit/GPU-Z.2.70.0.exe)
  --yes, -y          Skip the final replacement confirmation
  --single-image     V-11 style transaction for the private one-command build:
                     keep rollback only while editing, then delete it on PASS
  --expect-base-state-sha256 SHA256
                     Internal resume guard: after taking the storage lock,
                     require the exact pre-package base inode/size/mtime state
  -h, --help         Show this help

Public mode writes the generic VgpuPortable.exe to the Public Desktop. Private
mode writes one licensed EXE plus the unattended one-shot clone finalizer; a
clone runs that EXE exactly once, verifies Licensed/Code-0/GRID 538.33, then
fully shuts down. GPU-Z is not required. Hibernated/dirty NTFS is refused.
EOF
}

die() {
    echo "[vgpu-base] ERROR: $*" >&2
    exit 1
}

log() {
    echo "[vgpu-base] $*"
}

sha256_upper() {
    sha256sum -- "$1" | awk '{print toupper($1)}'
}

BASE=""
BASE_NAME=""
BASE_PATH_SET=0
PORTABLE_EXE=""
GPUZ_SOURCE=""
WITH_GPUZ=0
ASSUME_YES=0
SITE_PRIVATE=0
SYSPREP_GENERALIZED=0
SINGLE_IMAGE=0
EXPECTED_BASE_STATE_SHA256=""
while (($#)); do
    case "$1" in
        --base)
            (($# >= 2)) || die "--base requires an image"
            ((BASE_PATH_SET == 0)) || die "--base may be specified once"
            BASE=$2
            BASE_PATH_SET=1
            shift 2
            ;;
        --base-name)
            (($# >= 2)) || die "--base-name requires a name"
            [[ -z "$BASE_NAME" ]] || die "--base-name may be specified once"
            BASE_NAME=$2
            shift 2
            ;;
        --exe)
            (($# >= 2)) || die "--exe requires a Windows executable"
            PORTABLE_EXE=$2
            shift 2
            ;;
        --gpuz-source)
            (($# >= 2)) || die "--gpuz-source requires a host file"
            GPUZ_SOURCE=$2
            WITH_GPUZ=1
            shift 2
            ;;
        --with-gpuz)
            WITH_GPUZ=1
            shift
            ;;
        --site-private)
            SITE_PRIVATE=1
            shift
            ;;
        --sysprep-generalized)
            SYSPREP_GENERALIZED=1
            shift
            ;;
        --single-image)
            SINGLE_IMAGE=1
            shift
            ;;
        --expect-base-state-sha256)
            (($# >= 2)) || die "--expect-base-state-sha256 requires SHA256"
            [[ -z "$EXPECTED_BASE_STATE_SHA256" ]] ||
                die "--expect-base-state-sha256 may be specified once"
            EXPECTED_BASE_STATE_SHA256=$2
            shift 2
            ;;
        -y|--yes)
            ASSUME_YES=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ -z "$BASE_NAME" || $BASE_PATH_SET -eq 0 ]] ||
    die "--base-name and --base cannot be combined"
if ((SITE_PRIVATE)); then
    ((SYSPREP_GENERALIZED)) ||
        die "--site-private requires --sysprep-generalized after Sysprep /generalize /oobe /shutdown"
    ((WITH_GPUZ == 0)) ||
        die "--site-private does not copy GPU-Z; install it later only when explicitly needed"
elif ((SYSPREP_GENERALIZED)); then
    die "--sysprep-generalized is valid only with --site-private"
fi
((SINGLE_IMAGE == 0 || SITE_PRIVATE == 1)) ||
    die "--single-image is valid only with --site-private"
if [[ -n "$EXPECTED_BASE_STATE_SHA256" ]]; then
    [[ "$EXPECTED_BASE_STATE_SHA256" =~ ^[0-9A-F]{64}$ ]] ||
        die "--expect-base-state-sha256 must be 64 uppercase hexadecimal characters"
    ((SITE_PRIVATE && SINGLE_IMAGE)) ||
        die "--expect-base-state-sha256 is valid only with --site-private --single-image"
fi
if [[ -n "$BASE_NAME" ]]; then
    vm_storage_validate_base_name "$BASE_NAME" || exit 2
fi

# Offline qcow2/NBD mounting needs root.  Parse help/options first, then
# re-exec once and let sudo use its normal password prompt; no credential is
# stored in this script.
if ((EUID != 0)); then
    exec sudo --preserve-env=IMAGE_ROOT,VM_ROOT,VM_INSTANCES_DIR,VM_BASE_DIR,STAGE_DIR,QEMU_IMG \
        -- "$0" "${ORIGINAL_ARGS[@]}"
fi

if [[ -n "$BASE_NAME" ]]; then
    BASE=$(vm_storage_base_path "$BASE_NAME")
elif ((BASE_PATH_SET == 0)); then
    # Retain the historical default only for compatibility.  New tutorials
    # always name the base explicitly so multiple generations cannot mix.
    BASE_NAME=win10-base
    BASE=$(vm_storage_base_path "$BASE_NAME")
fi
if [[ -z "$PORTABLE_EXE" ]]; then
    if ((SITE_PRIVATE)); then
        PORTABLE_EXE="$STAGE_DIR/VgpuPortableLicensed/VgpuPortable.exe"
    else
        PORTABLE_EXE="$STAGE_DIR/VgpuPortable/VgpuPortable.exe"
    fi
fi
if ((WITH_GPUZ)) && [[ -z "$GPUZ_SOURCE" ]]; then
    GPUZ_SOURCE=$(gpuz_asset_default_source) ||
        die "could not derive the canonical GPU-Z source"
fi
[[ "$BASE" == /* && "$BASE" != / ]] ||
    die "--base must be a non-root absolute path"
[[ "$PORTABLE_EXE" == /* && "${PORTABLE_EXE,,}" == *.exe ]] ||
    die "--exe must be an absolute .exe path"
BASE=$(realpath -e -- "$BASE") || die "base image does not exist"
PORTABLE_EXE=$(realpath -e -- "$PORTABLE_EXE") ||
    die "portable EXE does not exist; run ./deploy/package-vgpu-one-click.sh first"
if ((WITH_GPUZ)); then
    GPUZ_SOURCE=$(gpuz_asset_resolve_source "$GPUZ_SOURCE") ||
        die "invalid --gpuz-source"
fi
[[ -f "$BASE" && ! -L "$BASE" ]] ||
    die "base must be a regular non-symlink image"
[[ -f "$PORTABLE_EXE" && ! -L "$PORTABLE_EXE" ]] ||
    die "portable EXE must be a regular non-symlink file"

for dependency in qemu-nbd qemu-img jq sha256sum awk stat realpath \
        flock lsof lsblk blkid partprobe udevadm mount umount findmnt \
        cp mv sync chmod chown ln mktemp mkdir sed; do
    command -v "$dependency" >/dev/null 2>&1 ||
        die "missing dependency: $dependency"
done
: "${QEMU_IMG:=$(command -v qemu-img)}"
QEMU_NBD=$(command -v qemu-nbd)
vgpu_profile_validate_catalog ||
    die "GPU profile catalog validation failed"
vgpu_select_driver_stack ||
    die "could not select the reviewed host/guest driver pair"
case "$VGPU_SELECTED_DRIVER_BRANCH" in
    R535|R570) ;;
    *)
        die "$VGPU_SELECTED_DRIVER_BRANCH does not have a validated B/native portable identity contract"
        ;;
esac
EXPECTED_DRIVER_BRANCH=$VGPU_SELECTED_DRIVER_BRANCH
EXPECTED_DRIVER_VERSION=$VGPU_SELECTED_DRIVER_VERSION
if ((SITE_PRIVATE)) && [[ "$EXPECTED_DRIVER_BRANCH" != R535 ||
                         "$EXPECTED_DRIVER_VERSION" != 31.0.15.3833 ]]; then
    die "private clone finalizer is reviewed only for R535/GRID 538.33 (31.0.15.3833); selected stack is $EXPECTED_DRIVER_BRANCH/$EXPECTED_DRIVER_VERSION"
fi
EXPECTED_CATALOG_SHA256=$(vgpu_profile_catalog_sha256)
[[ "$EXPECTED_CATALOG_SHA256" =~ ^[0-9A-F]{64}$ ]] ||
    die "could not calculate the current GPU profile catalog hash"

PORTABLE_SHA256=$(sha256_upper "$PORTABLE_EXE")
PORTABLE_BYTES=$(stat -c %s -- "$PORTABLE_EXE")
GPUZ_SHA256=""
GPUZ_BYTES=0
if ((WITH_GPUZ)); then
    GPUZ_SHA256=$(sha256_upper "$GPUZ_SOURCE")
    GPUZ_BYTES=$(stat -c %s -- "$GPUZ_SOURCE")
    [[ "$GPUZ_BYTES" == "$GPUZ_ASSET_BYTES" &&
       "$GPUZ_SHA256" == "$GPUZ_ASSET_SHA256" ]] ||
        die "GPU-Z source is not the locked ${GPUZ_ASSET_PRODUCT_VERSION} image (${GPUZ_ASSET_BYTES} bytes / ${GPUZ_ASSET_SHA256})"
fi
PORTABLE_PARENT=$(dirname -- "$PORTABLE_EXE")
PORTABLE_RECEIPT="$PORTABLE_PARENT/.$(basename -- "$PORTABLE_EXE").receipts/${PORTABLE_SHA256}.json"
[[ -f "$PORTABLE_RECEIPT" && ! -L "$PORTABLE_RECEIPT" ]] ||
    die "portable EXE has no host content receipt"
if ((SITE_PRIVATE)); then
    RECEIPT_METADATA=""
    if RECEIPT_METADATA=$(jq -er \
        --arg exeSha256 "$PORTABLE_SHA256" \
        --argjson exeBytes "$PORTABLE_BYTES" \
        --arg driverBranch "$EXPECTED_DRIVER_BRANCH" \
        --arg driverVersion "$EXPECTED_DRIVER_VERSION" '
        select(
            (keys | sort) == [
                "bindingMode", "bundleManifestSha256", "catalogSha256",
                "driverBranch", "driverVersion", "exeBytes", "exeSha256",
                "gpuZDelivery", "guestPerformance", "launcherFormat",
                "licenseTokenBytes", "licenseTokenDelivery",
                "licenseTokenSha256", "schemaVersion"
            ] and
            .schemaVersion == 8 and .bindingMode == "portable-auto" and
            .gpuZDelivery == "optional-explicit-sibling" and
            .guestPerformance == "embedded-recommended-native-v1" and
            .launcherFormat == "QEMU_VGPU_PORTABLE_LICENSED_BRANCH_V8" and
            .driverBranch == $driverBranch and
            .driverVersion == $driverVersion and
            .licenseTokenDelivery == "embedded-private" and
            (.licenseTokenSha256 | test("^[0-9A-F]{64}$")) and
            (.licenseTokenBytes | type) == "number" and
            .licenseTokenBytes > 0 and
            .exeSha256 == $exeSha256 and .exeBytes == $exeBytes and
            (.catalogSha256 | test("^[0-9A-F]{64}$")) and
            (.bundleManifestSha256 | test("^[0-9A-F]{64}$"))
        ) | [.catalogSha256, (.schemaVersion | tostring), .launcherFormat,
             .driverBranch, .driverVersion] | @tsv
    ' "$PORTABLE_RECEIPT"); then
        :
    elif [[ "$EXPECTED_DRIVER_BRANCH" == R535 &&
            "$EXPECTED_DRIVER_VERSION" == 31.0.15.3833 ]] &&
            RECEIPT_METADATA=$(jq -er \
                --arg exeSha256 "$PORTABLE_SHA256" \
                --argjson exeBytes "$PORTABLE_BYTES" '
            select(
                (keys | sort) == [
                    "bindingMode", "bundleManifestSha256", "catalogSha256",
                    "exeBytes", "exeSha256", "gpuZDelivery",
                    "guestPerformance", "launcherFormat",
                    "licenseTokenBytes", "licenseTokenDelivery",
                    "licenseTokenSha256", "schemaVersion"
                ] and
                .schemaVersion == 7 and .bindingMode == "portable-auto" and
                .gpuZDelivery == "optional-explicit-sibling" and
                .guestPerformance == "embedded-recommended-native-v1" and
                .launcherFormat ==
                    "QEMU_VGPU_PORTABLE_LICENSED_UNIFIED_V7" and
                .licenseTokenDelivery == "embedded-private" and
                (.licenseTokenSha256 | test("^[0-9A-F]{64}$")) and
                (.licenseTokenBytes | type) == "number" and
                .licenseTokenBytes > 0 and
                .exeSha256 == $exeSha256 and .exeBytes == $exeBytes and
                (.catalogSha256 | test("^[0-9A-F]{64}$")) and
                (.bundleManifestSha256 | test("^[0-9A-F]{64}$"))
            ) | [.catalogSha256, (.schemaVersion | tostring), .launcherFormat,
                 "R535", "31.0.15.3833"] | @tsv
        ' "$PORTABLE_RECEIPT"); then
        log "accepting historical licensed V7 receipt only for the reviewed R535/31.0.15.3833 stack"
    else
        die "licensed private EXE host receipt is invalid for $EXPECTED_DRIVER_BRANCH/$EXPECTED_DRIVER_VERSION"
    fi
    IFS=$'\t' read -r CATALOG_SHA256 PORTABLE_RECEIPT_SCHEMA \
        PORTABLE_LAUNCHER_FORMAT PORTABLE_DRIVER_BRANCH \
        PORTABLE_DRIVER_VERSION <<<"$RECEIPT_METADATA"
else
    RECEIPT_METADATA=""
    if RECEIPT_METADATA=$(jq -er \
        --arg exeSha256 "$PORTABLE_SHA256" \
        --argjson exeBytes "$PORTABLE_BYTES" \
        --arg driverBranch "$EXPECTED_DRIVER_BRANCH" \
        --arg driverVersion "$EXPECTED_DRIVER_VERSION" '
        select(
            (keys | sort) == [
                "bindingMode", "bundleManifestSha256", "catalogSha256",
                "driverBranch", "driverVersion", "exeBytes", "exeSha256",
                "gpuZDelivery", "guestPerformance", "launcherFormat",
                "schemaVersion"
            ] and
            .schemaVersion == 7 and .bindingMode == "portable-auto" and
            .gpuZDelivery == "optional-explicit-sibling" and
            .guestPerformance == "embedded-recommended-native-v1" and
            .launcherFormat == "QEMU_VGPU_PORTABLE_BRANCH_V7" and
            .driverBranch == $driverBranch and
            .driverVersion == $driverVersion and
            .exeSha256 == $exeSha256 and .exeBytes == $exeBytes and
            (.catalogSha256 | test("^[0-9A-F]{64}$")) and
            (.bundleManifestSha256 | test("^[0-9A-F]{64}$"))
        ) | [.catalogSha256, (.schemaVersion | tostring), .launcherFormat,
             .driverBranch, .driverVersion] | @tsv
    ' "$PORTABLE_RECEIPT"); then
        :
    elif [[ "$EXPECTED_DRIVER_BRANCH" == R535 &&
            "$EXPECTED_DRIVER_VERSION" == 31.0.15.3833 ]] &&
            RECEIPT_METADATA=$(jq -er \
                --arg exeSha256 "$PORTABLE_SHA256" \
                --argjson exeBytes "$PORTABLE_BYTES" '
            select(
                (keys | sort) == [
                    "bindingMode", "bundleManifestSha256", "catalogSha256",
                    "exeBytes", "exeSha256", "gpuZDelivery",
                    "guestPerformance", "launcherFormat", "schemaVersion"
                ] and
                .schemaVersion == 6 and .bindingMode == "portable-auto" and
                .gpuZDelivery == "optional-explicit-sibling" and
                .guestPerformance == "embedded-recommended-native-v1" and
                .launcherFormat == "QEMU_VGPU_PORTABLE_UNIFIED_V6" and
                .exeSha256 == $exeSha256 and .exeBytes == $exeBytes and
                (.catalogSha256 | test("^[0-9A-F]{64}$")) and
                (.bundleManifestSha256 | test("^[0-9A-F]{64}$"))
            ) | [.catalogSha256, (.schemaVersion | tostring), .launcherFormat,
                 "R535", "31.0.15.3833"] | @tsv
        ' "$PORTABLE_RECEIPT"); then
        log "accepting historical public V6 receipt only for the reviewed R535/31.0.15.3833 stack"
    else
        die "portable EXE host receipt is invalid for $EXPECTED_DRIVER_BRANCH/$EXPECTED_DRIVER_VERSION"
    fi
    IFS=$'\t' read -r CATALOG_SHA256 PORTABLE_RECEIPT_SCHEMA \
        PORTABLE_LAUNCHER_FORMAT PORTABLE_DRIVER_BRANCH \
        PORTABLE_DRIVER_VERSION <<<"$RECEIPT_METADATA"
fi
[[ "$CATALOG_SHA256" == "$EXPECTED_CATALOG_SHA256" ]] ||
    die "portable EXE uses an obsolete GPU profile catalog; rebuild it before installing the base"

FIRST_BOOT_SOURCE="$here/guest/finalize-g11-clone.ps1"
RETRY_SOURCE="$here/guest/Retry-Clone-Initialization.cmd"
SYSPREP_ANSWER_SOURCE="$here/autounattend/g11-sysprep-clone.xml"
GUEST_LITE_SOURCE_ROOT="$here/guest/guest-lite"
GUEST_LITE_MANIFEST_SOURCE="$GUEST_LITE_SOURCE_ROOT/clone-manifest.json"
GUEST_LITE_ASSETS=(
    G11-Guest-Lite.ps1
    01-OneClick-Apply.cmd
    02-Audit.cmd
    03-Rollback.cmd
    README.txt
)
FIRST_BOOT_SHA256=""
RETRY_SHA256=""
SYSPREP_ANSWER_SHA256=""
GUEST_LITE_MANIFEST_SHA256=""
if ((SITE_PRIVATE)); then
    for private_asset in "$FIRST_BOOT_SOURCE" "$RETRY_SOURCE" "$SYSPREP_ANSWER_SOURCE"; do
        [[ -f "$private_asset" && ! -L "$private_asset" && -s "$private_asset" ]] ||
            die "private Sysprep asset is missing or unsafe: $private_asset"
    done
    [[ -f "$GUEST_LITE_MANIFEST_SOURCE" &&
       ! -L "$GUEST_LITE_MANIFEST_SOURCE" &&
       -s "$GUEST_LITE_MANIFEST_SOURCE" ]] ||
        die "Guest Lite clone manifest is missing or unsafe: $GUEST_LITE_MANIFEST_SOURCE"
    for guest_lite_asset in "${GUEST_LITE_ASSETS[@]}"; do
        [[ -f "$GUEST_LITE_SOURCE_ROOT/$guest_lite_asset" &&
           ! -L "$GUEST_LITE_SOURCE_ROOT/$guest_lite_asset" &&
           -s "$GUEST_LITE_SOURCE_ROOT/$guest_lite_asset" ]] ||
            die "Guest Lite clone asset is missing or unsafe: $guest_lite_asset"
    done
    FIRST_BOOT_SHA256=$(sha256_upper "$FIRST_BOOT_SOURCE")
    RETRY_SHA256=$(sha256_upper "$RETRY_SOURCE")
    SYSPREP_ANSWER_SHA256=$(sha256_upper "$SYSPREP_ANSWER_SOURCE")
    GUEST_LITE_MANIFEST_SHA256=$(sha256_upper "$GUEST_LITE_MANIFEST_SOURCE")
    FINALIZER_GUEST_LITE_MANIFEST_SHA256=$(sed -n \
        "s/^\\\$ExpectedGuestLiteManifestSha256 = '\\([0-9A-F]\\{64\\}\\)'$/\\1/p" \
        "$FIRST_BOOT_SOURCE")
    [[ "$FINALIZER_GUEST_LITE_MANIFEST_SHA256" == \
       "$GUEST_LITE_MANIFEST_SHA256" ]] ||
        die 'Guest Lite manifest is not pinned by the clone finalizer'
fi

storage_uid=$(stat -c %u -- "$BASE")
storage_gid=$(stat -c %g -- "$BASE")
ensure_storage_directory() {
    local path=$1
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -d "$path" && ! -L "$path" ]] ||
            die "storage directory is not a regular non-symlink directory: $path"
    else
        mkdir -m 0750 -p -- "$path"
        chown "$storage_uid:$storage_gid" "$path"
    fi
}
ensure_storage_directory "$VM_RUN_DIR"
((SINGLE_IMAGE)) || ensure_storage_directory "$VM_BASE_ARCHIVE_DIR"

STORAGE_LOCK_PATH="$VM_RUN_DIR/.storage.lock"
if [[ ! -e "$STORAGE_LOCK_PATH" && ! -L "$STORAGE_LOCK_PATH" ]]; then
    storage_lock_tmp=$(mktemp -- "$VM_RUN_DIR/.storage.lock.new.XXXXXXXX")
    chmod 0600 "$storage_lock_tmp"
    chown "$storage_uid:$storage_gid" "$storage_lock_tmp"
    if ! ln -T -- "$storage_lock_tmp" "$STORAGE_LOCK_PATH" 2>/dev/null; then
        [[ -e "$STORAGE_LOCK_PATH" || -L "$STORAGE_LOCK_PATH" ]] || {
            rm -f -- "$storage_lock_tmp"
            die "could not create the global storage lock"
        }
    fi
    rm -f -- "$storage_lock_tmp"
fi
[[ -f "$STORAGE_LOCK_PATH" && ! -L "$STORAGE_LOCK_PATH" &&
   "$(stat -c %s -- "$STORAGE_LOCK_PATH")" == 0 &&
   "$(stat -c %h -- "$STORAGE_LOCK_PATH")" == 1 ]] ||
    die "global storage lock is not a safe empty regular file"
lock_uid=$(stat -c %u -- "$STORAGE_LOCK_PATH")
[[ "$lock_uid" == "$storage_uid" || "$lock_uid" == 0 ]] ||
    die "global storage lock owner does not match the base-image owner"

exec {STORAGE_LOCK_FD}<>"$STORAGE_LOCK_PATH"
if ! flock -n -x "$STORAGE_LOCK_FD"; then
    die "another VM is running or a storage operation is active; stop all VMs first"
fi
[[ "$(stat -Lc '%d:%i' -- "/proc/self/fd/$STORAGE_LOCK_FD")" == \
   "$(stat -Lc '%d:%i' -- "$STORAGE_LOCK_PATH")" ]] ||
    die "global storage lock changed while it was being acquired"
if [[ "$lock_uid" == 0 && "$storage_uid" != 0 ]]; then
    chown "$storage_uid:$storage_gid" "/proc/self/fd/$STORAGE_LOCK_FD"
    chmod 0600 "/proc/self/fd/$STORAGE_LOCK_FD"
fi
if [[ -n "$EXPECTED_BASE_STATE_SHA256" ]]; then
    OBSERVED_BASE_STATE_SHA256=$(
        TZ=UTC stat -c '%D|%i|%s|%y' -- "$BASE" |
            sha256sum | awk '{print toupper($1)}'
    ) || die "could not fingerprint base after taking the storage lock"
    [[ "$OBSERVED_BASE_STATE_SHA256" == "$EXPECTED_BASE_STATE_SHA256" ]] ||
        die "base state changed before locked injection; refusing resume"
fi
storage_dirs=("$VM_RUN_DIR")
((SINGLE_IMAGE)) || storage_dirs+=("$VM_BASE_ARCHIVE_DIR")
for storage_dir in "${storage_dirs[@]}"; do
    if [[ "$(stat -c %u -- "$storage_dir")" == 0 && "$storage_uid" != 0 ]]; then
        chown "$storage_uid:$storage_gid" "$storage_dir"
        chmod u+rwx "$storage_dir"
    fi
done
holders=$(lsof -t -- "$BASE" 2>/dev/null | paste -sd, - || true)
[[ -z "$holders" ]] ||
    die "base image is open by process(es): $holders"

if ! vm_storage_read_qcow2_metadata "$QEMU_IMG" "$BASE"; then
    die "base is not a verifiable qcow2 image"
fi
[[ -z "$VM_STORAGE_QCOW2_BACKING" &&
   -z "$VM_STORAGE_QCOW2_DATA_FILE" ]] ||
    die "base must be standalone (no backing/data-file)"
"$QEMU_IMG" check -q "$BASE"

# Do not replace a pathname used as a backing/data file by any managed image.
base_key=$(readlink -m -- "$BASE")
base_real=$(readlink -f -- "$BASE")
exec {QCOW2_FIND_FD}< <(
    while IFS= read -r -d '' scan_root; do
        find -L "$scan_root" \( -type f -o -type l \) \
            \( -name '*.qcow2' -o -name '*.qcow2.*' \) \
            ! -name '*.vgpu-portable.json' -print0 || exit 1
    done < <(vm_storage_qcow2_scan_roots)
)
QCOW2_FIND_PID=$!
while IFS= read -r -d '' image <&"$QCOW2_FIND_FD"; do
    [[ "$image" -ef "$BASE" ]] && continue
    vm_storage_read_qcow2_chain_metadata "$QEMU_IMG" "$image" ||
        die "cannot prove qcow2 chain safety for $image"
    for dependency in "${VM_STORAGE_QCOW2_CHAIN_FILES[@]:1}" \
            "${VM_STORAGE_QCOW2_CHAIN_DATA_FILES[@]}"; do
        [[ -n "$dependency" ]] || continue
        dependency_real=$(readlink -f -- "$dependency" 2>/dev/null || true)
        if [[ "$dependency" == "$base_key" ||
              "$dependency_real" == "$base_real" ]]; then
            die "managed image depends on the base pathname: $image"
        fi
    done
done
exec {QCOW2_FIND_FD}<&-
wait "$QCOW2_FIND_PID" ||
    die "managed qcow2 enumeration failed"

base_dir=$(dirname -- "$BASE")
base_leaf=$(basename -- "$BASE")
base_mode=$(stat -c %a -- "$BASE")
base_uid=$(stat -c %u -- "$BASE")
base_gid=$(stat -c %g -- "$BASE")
ORIGINAL_BASE_FILE_BYTES=$(stat -c %s -- "$BASE")
ORIGINAL_BASE_DEVICE_ID=$(stat -c %D -- "$BASE")
ORIGINAL_BASE_INODE=$(stat -c %i -- "$BASE")
ORIGINAL_BASE_MTIME_NS=$(stat -c %y -- "$BASE")
ATTESTATION="${BASE}.vgpu-portable.json"
if [[ -e "$ATTESTATION" || -L "$ATTESTATION" ]]; then
    [[ -f "$ATTESTATION" && ! -L "$ATTESTATION" ]] ||
        die "existing base attestation is not a regular non-symlink file"
fi
WORK_ROOT=$(mktemp -d "$base_dir/.vgpu-base-work.XXXXXXXX")
BASE_TMP="$base_dir/.${base_leaf}.vgpu-portable.$$.$RANDOM"
MOUNT_DIR="$WORK_ROOT/mnt"
mkdir -m 0700 -- "$MOUNT_DIR"
GUEST_LITE_STAGE=""
verify_guest_lite_dir() {
    local asset_dir=$1 row name expected_sha expected_bytes asset_path
    [[ "$(sha256_upper "$asset_dir/clone-manifest.json")" == \
       "$GUEST_LITE_MANIFEST_SHA256" ]] || return 1
    jq -e '
        (keys | sort) == ["files", "profileVersion", "schemaVersion"] and
        .schemaVersion == 1 and .profileVersion == "2.6.7" and
        (.files | type) == "array" and (.files | length) == 5 and
        ([.files[].name] | sort) == [
            "01-OneClick-Apply.cmd", "02-Audit.cmd", "03-Rollback.cmd",
            "G11-Guest-Lite.ps1", "README.txt"
        ] and
        ([.files[].name] | unique | length) == 5 and
        all(.files[];
            (.name | type) == "string" and
            (.sha256 | test("^[0-9A-F]{64}$")) and
            (.bytes | type) == "number" and .bytes > 0 and
            (.bytes | floor) == .bytes)
    ' "$asset_dir/clone-manifest.json" >/dev/null || return 1
    while IFS=$'\t' read -r name expected_sha expected_bytes; do
        asset_path="$asset_dir/$name"
        [[ -f "$asset_path" && ! -L "$asset_path" &&
           "$(sha256_upper "$asset_path")" == "$expected_sha" &&
           "$(stat -c %s -- "$asset_path")" == "$expected_bytes" ]] ||
            return 1
    done < <(jq -r '.files[] | [.name, .sha256, (.bytes | tostring)] | @tsv' \
        "$asset_dir/clone-manifest.json")
}
if ((SITE_PRIVATE)); then
    GUEST_LITE_STAGE="$WORK_ROOT/GuestLite"
    mkdir -m 0700 -- "$GUEST_LITE_STAGE"
    for guest_lite_asset in "${GUEST_LITE_ASSETS[@]}"; do
        cp --reflink=never -- "$GUEST_LITE_SOURCE_ROOT/$guest_lite_asset" \
            "$GUEST_LITE_STAGE/$guest_lite_asset"
    done
    # Match the standalone package's Windows-safe launchers while retaining
    # LF-only reviewed source in git.
    for guest_lite_launcher in "$GUEST_LITE_STAGE"/*.cmd; do
        sed -i 's/$/\r/' "$guest_lite_launcher"
    done
    cp --reflink=never -- "$GUEST_LITE_MANIFEST_SOURCE" \
        "$GUEST_LITE_STAGE/clone-manifest.json"
    verify_guest_lite_dir "$GUEST_LITE_STAGE" ||
        die 'Guest Lite staged clone payload differs from its pinned manifest'
fi
NBD=""
NBD_CONNECTED=0
MOUNTED=0
BASE_BACKUP=""
BASE_BACKUP_ATTESTATION=""
ATTESTATION_TMP=""
ATTESTATION_MOVED=0
PUBLICATION_STARTED=0
BASE_PUBLISHED=0
PUBLICATION_COMPLETE=0
refresh_restored_attestation_ctime() {
    local refresh_tmp attestation_mode attestation_uid attestation_gid
    local restored_bytes restored_device restored_inode restored_mtime restored_ctime
    [[ -f "$BASE" && ! -L "$BASE" &&
       -f "$ATTESTATION" && ! -L "$ATTESTATION" ]] || return 1
    restored_bytes=$(stat -c %s -- "$BASE") || return 1
    restored_device=$(stat -c %D -- "$BASE") || return 1
    restored_inode=$(stat -c %i -- "$BASE") || return 1
    restored_mtime=$(stat -c %y -- "$BASE") || return 1
    restored_ctime=$(stat -c %z -- "$BASE") || return 1
    [[ "$restored_bytes" == "$ORIGINAL_BASE_FILE_BYTES" &&
       "$restored_device" == "$ORIGINAL_BASE_DEVICE_ID" &&
       "$restored_inode" == "$ORIGINAL_BASE_INODE" &&
       "$restored_mtime" == "$ORIGINAL_BASE_MTIME_NS" ]] || return 1

    refresh_tmp=$(mktemp -- "${ATTESTATION}.rollback.XXXXXXXX") || return 1
    if ! jq -e \
            --arg basePath "$BASE" \
            --argjson baseFileBytes "$restored_bytes" \
            --arg baseDeviceId "$restored_device" \
            --arg baseInode "$restored_inode" \
            --arg baseMtimeNs "$restored_mtime" \
            --arg baseCtimeNs "$restored_ctime" \
            --arg gpuZSha256 "$GPUZ_ASSET_SHA256" \
            --argjson gpuZBytes "$GPUZ_ASSET_BYTES" '
        if (
            .basePath == $basePath and .baseFileBytes == $baseFileBytes and
            .baseDeviceId == $baseDeviceId and .baseInode == $baseInode and
            .baseMtimeNs == $baseMtimeNs and
            (.baseCtimeNs | type) == "string" and
            .bindingMode == "portable-auto" and
            (.catalogSha256 | test("^[0-9A-F]{64}$")) and
            (.installedUtc | type) == "string" and
            (
                ((keys | sort) == [
                    "baseCtimeNs", "baseDeviceId", "baseFileBytes",
                    "baseInode", "baseMtimeNs", "basePath", "bindingMode",
                    "catalogSha256", "exeBytes", "exeSha256", "guestPath",
                    "installedUtc", "schemaVersion"
                ] and
                 .schemaVersion == 2 and
                 .guestPath == "C:\\Users\\Public\\Desktop\\VgpuPortable.exe" and
                 (.exeSha256 | test("^[0-9A-F]{64}$")) and
                 (.exeBytes | type) == "number" and .exeBytes > 0)
                or
                ((keys | sort) == [
                    "baseCtimeNs", "baseDeviceId", "baseFileBytes",
                    "baseInode", "baseMtimeNs", "basePath", "bindingMode",
                    "catalogSha256", "gpuZBytes", "gpuZDelivery",
                    "gpuZGuestPath", "gpuZSha256", "installedUtc",
                    "portableBytes", "portableGuestPath", "portableSha256",
                    "schemaVersion"
                ] and
                 .schemaVersion == 3 and
                 .gpuZDelivery == "external-sibling" and
                 .portableGuestPath == "C:\\Users\\Public\\Desktop\\VgpuPortable.exe" and
                 (.portableSha256 | test("^[0-9A-F]{64}$")) and
                 (.portableBytes | type) == "number" and
                 .portableBytes > 0 and
                 .gpuZGuestPath == "C:\\Users\\Public\\Desktop\\GPU-Z.exe" and
                 .gpuZSha256 == $gpuZSha256 and .gpuZBytes == $gpuZBytes)
                or
                ((keys | sort) == [
                    "baseCtimeNs", "baseDeviceId", "baseFileBytes",
                    "baseInode", "baseMtimeNs", "basePath", "bindingMode",
                    "catalogSha256", "gpuZBytes", "gpuZDelivery",
                    "gpuZGuestPath", "gpuZIncluded", "gpuZSha256",
                    "installedUtc", "portableBytes", "portableGuestPath",
                    "portableSha256", "schemaVersion"
                ] and
                 .schemaVersion == 4 and
                 .gpuZDelivery == "optional-explicit-sibling" and
                 .portableGuestPath == "C:\\Users\\Public\\Desktop\\VgpuPortable.exe" and
                 (.portableSha256 | test("^[0-9A-F]{64}$")) and
                 (.portableBytes | type) == "number" and
                 .portableBytes > 0 and
                 (.gpuZIncluded | type) == "boolean" and
                 (if .gpuZIncluded then
                    .gpuZGuestPath == "C:\\Users\\Public\\Desktop\\GPU-Z.exe" and
                    .gpuZSha256 == $gpuZSha256 and .gpuZBytes == $gpuZBytes
                 else
                    .gpuZGuestPath == null and .gpuZSha256 == null and
                    .gpuZBytes == null
                  end))
                or
                ((keys | sort) == [
                    "baseCtimeNs", "baseDeviceId", "baseFileBytes",
                    "baseInode", "baseMtimeNs", "basePath", "bindingMode",
                    "catalogSha256", "gpuZBytes", "gpuZDelivery",
                    "gpuZGuestPath", "gpuZIncluded", "gpuZSha256",
                    "guestPerformance", "installedUtc", "portableBytes",
                    "portableGuestPath", "portableSha256", "schemaVersion"
                ] and
                 .schemaVersion == 5 and
                 .gpuZDelivery == "optional-explicit-sibling" and
                 .guestPerformance == "embedded-recommended-native-v1" and
                 .portableGuestPath == "C:\\Users\\Public\\Desktop\\VgpuPortable.exe" and
                 (.portableSha256 | test("^[0-9A-F]{64}$")) and
                 (.portableBytes | type) == "number" and
                 .portableBytes > 0 and
                 (.gpuZIncluded | type) == "boolean" and
                 (if .gpuZIncluded then
                    .gpuZGuestPath == "C:\\Users\\Public\\Desktop\\GPU-Z.exe" and
                    .gpuZSha256 == $gpuZSha256 and .gpuZBytes == $gpuZBytes
                  else
                    .gpuZGuestPath == null and .gpuZSha256 == null and
                    .gpuZBytes == null
                  end))
                or
                ((keys | sort) == [
                    "baseCtimeNs", "baseDeviceId", "baseFileBytes",
                    "baseInode", "baseMtimeNs", "basePath", "bindingMode",
                    "catalogSha256", "deploymentMode", "dlsHost", "dlsPort",
                    "firstBootScriptGuestPath", "firstBootScriptSha256",
                    "guestPerformance", "installedUtc", "licenseDelivery",
                    "oobeMode", "portableBytes", "portableGuestPath",
                    "portableSha256", "retryGuestPath", "retrySha256",
                    "schemaVersion", "sysprepAnswerGuestPath",
                    "sysprepAnswerSha256", "windowsGeneralized"
                ] and
                 .schemaVersion == 6 and
                 .deploymentMode == "site-private-licensed-firstboot-v1" and
                 .portableGuestPath == "C:\\ProgramData\\VMate\\G11\\VgpuPortable.exe" and
                 (.portableSha256 | test("^[0-9A-F]{64}$")) and
                 (.portableBytes | type) == "number" and
                 (.portableBytes | floor) == .portableBytes and .portableBytes > 0 and
                 .firstBootScriptGuestPath ==
                    "C:\\ProgramData\\VMate\\G11\\Finalize-Clone.ps1" and
                 (.firstBootScriptSha256 | test("^[0-9A-F]{64}$")) and
                 .retryGuestPath ==
                    "C:\\ProgramData\\VMate\\G11\\Retry-Clone-Initialization.cmd" and
                 (.retrySha256 | test("^[0-9A-F]{64}$")) and
                 .sysprepAnswerGuestPath == "C:\\Windows\\Panther\\unattend.xml" and
                 (.sysprepAnswerSha256 | test("^[0-9A-F]{64}$")) and
                 .windowsGeneralized == true and
                 .oobeMode == "unattended-auto-finalize" and
                 .licenseDelivery == "embedded-private-shared-token" and
                 .dlsHost == "dls.gvmates.com" and .dlsPort == 443 and
                 .guestPerformance == "embedded-recommended-native-v1")
                or
                ((keys | sort) == [
                    "baseCtimeNs", "baseDeviceId", "baseFileBytes",
                    "baseInode", "baseMtimeNs", "basePath", "bindingMode",
                    "catalogSha256", "deploymentMode", "dlsHost", "dlsPort",
                    "firstBootScriptGuestPath", "firstBootScriptSha256",
                    "firstBootWorkflow", "guestPerformance", "installedUtc",
                    "licenseDelivery", "oobeMode", "portableBytes",
                    "portableGuestPath", "portableSha256", "retryGuestPath",
                    "retrySha256", "schemaVersion", "sysprepAnswerGuestPath",
                    "sysprepAnswerSha256", "systemNvapiDelivery",
                    "systemNvapiRequired", "windowsGeneralized"
                ] and
                 .schemaVersion == 7 and
                 .deploymentMode == "site-private-licensed-firstboot-v2" and
                 .portableGuestPath == "C:\\ProgramData\\VMate\\G11\\VgpuPortable.exe" and
                 (.portableSha256 | test("^[0-9A-F]{64}$")) and
                 (.portableBytes | type) == "number" and
                 (.portableBytes | floor) == .portableBytes and .portableBytes > 0 and
                 .firstBootScriptGuestPath ==
                    "C:\\ProgramData\\VMate\\G11\\Finalize-Clone.ps1" and
                 (.firstBootScriptSha256 | test("^[0-9A-F]{64}$")) and
                 .retryGuestPath ==
                    "C:\\ProgramData\\VMate\\G11\\Retry-Clone-Initialization.cmd" and
                 (.retrySha256 | test("^[0-9A-F]{64}$")) and
                 .sysprepAnswerGuestPath == "C:\\Windows\\Panther\\unattend.xml" and
                 (.sysprepAnswerSha256 | test("^[0-9A-F]{64}$")) and
                 .windowsGeneralized == true and
                 .oobeMode == "unattended-auto-finalize" and
                 .licenseDelivery == "embedded-private-shared-token" and
                 .firstBootWorkflow ==
                    "licensed-portable-system-nvapi-two-boot-v1" and
                 .systemNvapiDelivery == "per-vm-read-only-iso" and
                 .systemNvapiRequired == true and
                 .dlsHost == "dls.gvmates.com" and .dlsPort == 443 and
                 .guestPerformance == "embedded-recommended-native-v1")
                or
                ((keys | sort) == [
                    "baseCtimeNs", "baseDeviceId", "baseFileBytes",
                    "baseInode", "baseMtimeNs", "basePath", "bindingMode",
                    "catalogSha256", "deploymentMode", "dlsHost", "dlsPort",
                    "driverBranch", "driverVersion", "firstBootScriptGuestPath",
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
                 .driverBranch == "R535" and
                 .driverVersion == "31.0.15.3833" and
                 .portableGuestPath == "C:\\ProgramData\\VMate\\G11\\VgpuPortable.exe" and
                 (.portableSha256 | test("^[0-9A-F]{64}$")) and
                 (.portableBytes | type) == "number" and
                 (.portableBytes | floor) == .portableBytes and .portableBytes > 0 and
                 .firstBootScriptGuestPath ==
                    "C:\\ProgramData\\VMate\\G11\\Finalize-Clone.ps1" and
                 (.firstBootScriptSha256 | test("^[0-9A-F]{64}$")) and
                 .retryGuestPath ==
                    "C:\\ProgramData\\VMate\\G11\\Retry-Clone-Initialization.cmd" and
                 (.retrySha256 | test("^[0-9A-F]{64}$")) and
                 .sysprepAnswerGuestPath == "C:\\Windows\\Panther\\unattend.xml" and
                 (.sysprepAnswerSha256 | test("^[0-9A-F]{64}$")) and
                 .windowsGeneralized == true and
                 .oobeMode == "unattended-auto-finalize" and
                 .licenseDelivery == "embedded-private-shared-token" and
                 .firstBootWorkflow ==
                    "licensed-portable-system-nvapi-two-boot-v1" and
                 .systemNvapiDelivery == "per-vm-read-only-iso" and
                 .systemNvapiRequired == true and
                 .dlsHost == "dls.gvmates.com" and .dlsPort == 443 and
                 .guestPerformance == "embedded-recommended-native-v1")
            )
        ) then
            .baseCtimeNs = $baseCtimeNs
        else
            error("restored attestation is not a valid schema-2..5 public or schema-6..8 private generation")
        end
    ' "$ATTESTATION" >"$refresh_tmp"; then
        rm -f -- "$refresh_tmp"
        return 1
    fi
    attestation_mode=$(stat -c %a -- "$ATTESTATION") || {
        rm -f -- "$refresh_tmp"
        return 1
    }
    attestation_uid=$(stat -c %u -- "$ATTESTATION") || {
        rm -f -- "$refresh_tmp"
        return 1
    }
    attestation_gid=$(stat -c %g -- "$ATTESTATION") || {
        rm -f -- "$refresh_tmp"
        return 1
    }
    if chmod "$attestation_mode" "$refresh_tmp" &&
            chown "$attestation_uid:$attestation_gid" "$refresh_tmp" &&
            mv -fT -- "$refresh_tmp" "$ATTESTATION"; then
        return 0
    fi
    rm -f -- "$refresh_tmp"
    return 1
}
cleanup() {
    local cleanup_safe=1 restored_original=0
    if ((MOUNTED)); then
        sync || true
        if umount -- "$MOUNT_DIR"; then
            MOUNTED=0
        else
            echo "[vgpu-base] CLEANUP ERROR: could not unmount $MOUNT_DIR" >&2
            cleanup_safe=0
        fi
    fi
    if findmnt -rn -M "$MOUNT_DIR" >/dev/null 2>&1; then
        echo "[vgpu-base] CLEANUP ERROR: $MOUNT_DIR is still a mount point" >&2
        cleanup_safe=0
    fi
    if ((cleanup_safe && NBD_CONNECTED)); then
        if "$QEMU_NBD" --disconnect "$NBD" >/dev/null 2>&1; then
            NBD_CONNECTED=0
            udevadm settle >/dev/null 2>&1 || true
        else
            echo "[vgpu-base] CLEANUP ERROR: could not disconnect $NBD" >&2
            cleanup_safe=0
        fi
    fi
    if ((cleanup_safe && ! PUBLICATION_COMPLETE)); then
        rm -f -- "${ATTESTATION_TMP:-}"
        if ((PUBLICATION_STARTED)); then
            rm -f -- "$ATTESTATION"
            if ((BASE_PUBLISHED)) && [[ -e "$BASE" && -n "$BASE_TMP" &&
                    ! -e "$BASE_TMP" ]]; then
                mv -T -- "$BASE" "$BASE_TMP" || true
            fi
            if [[ ! -e "$BASE" && -n "$BASE_BACKUP" &&
                  -e "$BASE_BACKUP" ]]; then
                mv -T -- "$BASE_BACKUP" "$BASE" || true
            fi
        fi
        if [[ -f "$BASE" && ! -L "$BASE" &&
              "$(stat -c %s -- "$BASE")" == "$ORIGINAL_BASE_FILE_BYTES" &&
              "$(stat -c %D -- "$BASE")" == "$ORIGINAL_BASE_DEVICE_ID" &&
              "$(stat -c %i -- "$BASE")" == "$ORIGINAL_BASE_INODE" &&
              "$(stat -c %y -- "$BASE")" == "$ORIGINAL_BASE_MTIME_NS" ]]; then
            restored_original=1
        fi
        if ((ATTESTATION_MOVED && restored_original)) &&
                [[ -n "$BASE_BACKUP_ATTESTATION" &&
                   -e "$BASE_BACKUP_ATTESTATION" && ! -e "$ATTESTATION" ]]; then
            if mv -T -- "$BASE_BACKUP_ATTESTATION" "$ATTESTATION"; then
                if ! refresh_restored_attestation_ctime; then
                    echo "[vgpu-base] rollback restored the old sidecar, but its generation could not be refreshed" >&2
                fi
            fi
        elif ((ATTESTATION_MOVED && ! restored_original)); then
            echo "[vgpu-base] rollback could not prove the original base was restored; its sidecar remains archived at $BASE_BACKUP_ATTESTATION" >&2
        fi
    fi
    if ((cleanup_safe)); then
        rm -rf -- "${WORK_ROOT:-}"
        rm -f -- "${BASE_TMP:-}"
    else
        echo "[vgpu-base] cleanup stopped safely; private work files were preserved:" >&2
        echo "  work: ${WORK_ROOT:-<none>}" >&2
        echo "  image: ${BASE_TMP:-<none>}" >&2
    fi
}
trap cleanup EXIT

log "copying standalone base to a private editable image"
cp --reflink=auto -- "$BASE" "$BASE_TMP"
chmod u+rw -- "$BASE_TMP"
"$QEMU_IMG" check -q "$BASE_TMP"

for candidate in /dev/nbd{0..31}; do
    [[ -b "$candidate" ]] || continue
    sys_name=${candidate##*/}
    nbd_pid=$(cat "/sys/block/$sys_name/pid" 2>/dev/null || true)
    [[ -z "$nbd_pid" ]] || continue
    if findmnt -rn -S "$candidate" >/dev/null 2>&1; then
        continue
    fi
    NBD=$candidate
    break
done
[[ -n "$NBD" ]] || die "no free /dev/nbd device is available"
"$QEMU_NBD" --connect="$NBD" --format=qcow2 --cache=none "$BASE_TMP"
NBD_CONNECTED=1
partprobe "$NBD"
udevadm settle

mapfile -t partitions < <(
    lsblk -lnpo NAME,TYPE "$NBD" |
        awk '$2 == "part" {print $1}'
)
((${#partitions[@]} > 0)) ||
    die "base image has no visible partitions"
WINDOWS_PARTITION=""
for partition in "${partitions[@]}"; do
    fs_type=$(blkid -o value -s TYPE -- "$partition" 2>/dev/null || true)
    [[ "$fs_type" == ntfs ]] || continue
    if mount -t ntfs-3g -o ro -- "$partition" "$MOUNT_DIR"; then
        MOUNTED=1
        if [[ -d "$MOUNT_DIR/Windows/System32" &&
              -d "$MOUNT_DIR/Users/Public" ]]; then
            WINDOWS_PARTITION=$partition
        fi
        umount -- "$MOUNT_DIR"
        MOUNTED=0
        [[ -z "$WINDOWS_PARTITION" ]] || break
    fi
done
[[ -n "$WINDOWS_PARTITION" ]] ||
    die "could not find one clean Windows NTFS partition"

# A hibernated or dirty NTFS volume is intentionally not forced writable.
mount -t ntfs-3g -o big_writes,windows_names \
    -- "$WINDOWS_PARTITION" "$MOUNT_DIR" ||
    die "Windows NTFS is dirty/hibernated or cannot be mounted safely"
MOUNTED=1
if ((SITE_PRIVATE)); then
    DEST_DIR="$MOUNT_DIR/ProgramData/VMate/G11"
else
    DEST_DIR="$MOUNT_DIR/Users/Public/Desktop"
fi
mkdir -p -- "$DEST_DIR"
if ((SITE_PRIVATE)); then
    # Seal-G11-Template.cmd must roll back live experimental state before
    # Sysprep.  Offline deletion cannot restore registry/services from an
    # active baseline, so fail closed instead of producing a contaminated base.
    for active_clone_state in \
            "$MOUNT_DIR/ProgramData/G11GuestPerformance/state.json" \
            "$MOUNT_DIR/ProgramData/G11GuestLite/state.json" \
            "$MOUNT_DIR/ProgramData/QemuGpuZProfile/last-result.json"; do
        [[ ! -e "$active_clone_state" && ! -L "$active_clone_state" ]] ||
            die "generalized template retained active clone state: ${active_clone_state#"$MOUNT_DIR"/}"
    done
    PROJECTION_STATE="$MOUNT_DIR/ProgramData/G11/SystemNvapiProjection"
    [[ ! -e "$PROJECTION_STATE" && ! -L "$PROJECTION_STATE" ]] ||
        die "generalized template retained per-VM system NVAPI projection state"

    # A private Sysprep generation has exactly one executable route. Remove
    # generic/previous-run state even when the maker reused an older template.
    rm -f -- \
        "$MOUNT_DIR/Users/Public/Desktop/VgpuPortable.exe" \
        "$DEST_DIR/clone-initialization.json" \
        "$DEST_DIR/clone-initialization-error.txt"
    # Rolled-back reports/archives and prior executable output are not active
    # baselines, but remain identity-bound. Remove their exact plain roots so
    # a new clone can create its own state from scratch.
    for stale_clone_root in \
            "$MOUNT_DIR/ProgramData/QemuGpuZProfile" \
            "$MOUNT_DIR/ProgramData/G11GuestPerformance" \
            "$MOUNT_DIR/ProgramData/G11GuestLite" \
            "$DEST_DIR/logs"; do
        [[ ! -L "$stale_clone_root" ]] ||
            die "clone-state cleanup target is a symlink/reparse path: ${stale_clone_root#"$MOUNT_DIR"/}"
        rm -rf -- "$stale_clone_root"
    done
fi
PORTABLE_DEST_TMP="$DEST_DIR/.VgpuPortable.exe.new.$$"
cp --reflink=never -- "$PORTABLE_EXE" "$PORTABLE_DEST_TMP"
sync -- "$PORTABLE_DEST_TMP"
[[ "$(sha256_upper "$PORTABLE_DEST_TMP")" == "$PORTABLE_SHA256" &&
   "$(stat -c %s -- "$PORTABLE_DEST_TMP")" == "$PORTABLE_BYTES" ]] ||
    die "portable EXE verification failed inside the base image"
mv -fT -- "$PORTABLE_DEST_TMP" "$DEST_DIR/VgpuPortable.exe"
if ((SITE_PRIVATE)); then
    FIRST_BOOT_DEST_TMP="$DEST_DIR/.Finalize-Clone.ps1.new.$$"
    RETRY_DEST_TMP="$DEST_DIR/.Retry-Clone-Initialization.cmd.new.$$"
    cp --reflink=never -- "$FIRST_BOOT_SOURCE" "$FIRST_BOOT_DEST_TMP"
    cp --reflink=never -- "$RETRY_SOURCE" "$RETRY_DEST_TMP"
    sync -- "$FIRST_BOOT_DEST_TMP" "$RETRY_DEST_TMP"
    [[ "$(sha256_upper "$FIRST_BOOT_DEST_TMP")" == "$FIRST_BOOT_SHA256" &&
       "$(sha256_upper "$RETRY_DEST_TMP")" == "$RETRY_SHA256" ]] ||
        die "private first-boot asset verification failed inside the base image"
    mv -fT -- "$FIRST_BOOT_DEST_TMP" "$DEST_DIR/Finalize-Clone.ps1"
    mv -fT -- "$RETRY_DEST_TMP" "$DEST_DIR/Retry-Clone-Initialization.cmd"

    GUEST_LITE_DEST="$DEST_DIR/GuestLite"
    rm -rf -- "$GUEST_LITE_DEST"
    mkdir -m 0700 -- "$GUEST_LITE_DEST"
    cp --reflink=never -- "$GUEST_LITE_STAGE"/* "$GUEST_LITE_DEST/"
    sync -- "$GUEST_LITE_DEST"/*
    verify_guest_lite_dir "$GUEST_LITE_DEST" ||
        die 'Guest Lite clone payload verification failed inside the base image'

    PANTHER_DIR="$MOUNT_DIR/Windows/Panther"
    mkdir -p -- "$PANTHER_DIR"
    SYSPREP_DEST_TMP="$PANTHER_DIR/.unattend.xml.new.$$"
    cp --reflink=never -- "$SYSPREP_ANSWER_SOURCE" "$SYSPREP_DEST_TMP"
    sync -- "$SYSPREP_DEST_TMP"
    [[ "$(sha256_upper "$SYSPREP_DEST_TMP")" == "$SYSPREP_ANSWER_SHA256" ]] ||
        die "Sysprep answer verification failed inside the base image"
    mv -fT -- "$SYSPREP_DEST_TMP" "$PANTHER_DIR/unattend.xml"

    PUBLIC_DESKTOP="$MOUNT_DIR/Users/Public/Desktop"
    mkdir -p -- "$PUBLIC_DESKTOP"
    cp --reflink=never -- "$RETRY_SOURCE" \
        "$PUBLIC_DESKTOP/Retry-Clone-Initialization.cmd"
elif ((WITH_GPUZ)); then
    GPUZ_DEST_TMP="$DEST_DIR/.GPU-Z.exe.new.$$"
    cp --reflink=never -- "$GPUZ_SOURCE" "$GPUZ_DEST_TMP"
    sync -- "$GPUZ_DEST_TMP"
    [[ "$(sha256_upper "$GPUZ_DEST_TMP")" == "$GPUZ_SHA256" &&
       "$(stat -c %s -- "$GPUZ_DEST_TMP")" == "$GPUZ_BYTES" ]] ||
        die "optional GPU-Z verification failed inside the base image"
    mv -fT -- "$GPUZ_DEST_TMP" "$DEST_DIR/GPU-Z.exe"
fi
sync
[[ "$(sha256_upper "$DEST_DIR/VgpuPortable.exe")" == "$PORTABLE_SHA256" &&
   "$(stat -c %s -- "$DEST_DIR/VgpuPortable.exe")" == "$PORTABLE_BYTES" ]] ||
    die "published base-image portable EXE is incorrect"
if ((SITE_PRIVATE)); then
    [[ "$(sha256_upper "$DEST_DIR/Finalize-Clone.ps1")" == "$FIRST_BOOT_SHA256" &&
       "$(sha256_upper "$DEST_DIR/Retry-Clone-Initialization.cmd")" == "$RETRY_SHA256" &&
       "$(sha256_upper "$MOUNT_DIR/Windows/Panther/unattend.xml")" == "$SYSPREP_ANSWER_SHA256" ]] ||
        die "published private Sysprep assets are incorrect"
    verify_guest_lite_dir "$DEST_DIR/GuestLite" ||
        die 'published private Guest Lite payload is incorrect'
    [[ ! -e "$MOUNT_DIR/Users/Public/Desktop/VgpuPortable.exe" &&
       ! -e "$DEST_DIR/clone-initialization.json" &&
       ! -e "$DEST_DIR/clone-initialization-error.txt" &&
       ! -e "$MOUNT_DIR/ProgramData/QemuGpuZProfile" &&
       ! -e "$MOUNT_DIR/ProgramData/G11GuestPerformance" &&
       ! -e "$MOUNT_DIR/ProgramData/G11GuestLite" &&
       ! -e "$MOUNT_DIR/ProgramData/G11/SystemNvapiProjection" &&
       ! -e "$DEST_DIR/logs" ]] ||
        die "private base retained a generic EXE or previous clone result"
    log "installed one driver-bound licensed receipt schema $PORTABLE_RECEIPT_SCHEMA EXE, pinned Guest Lite 2.6.7, and the unattended clone finalizer in C:\\ProgramData\\VMate\\G11"
elif ((WITH_GPUZ)); then
    [[ "$(sha256_upper "$DEST_DIR/GPU-Z.exe")" == "$GPUZ_SHA256" &&
       "$(stat -c %s -- "$DEST_DIR/GPU-Z.exe")" == "$GPUZ_BYTES" ]] ||
        die "published base-image optional GPU-Z is incorrect"
    log "installed unified identity/performance EXE plus explicitly selected GPU-Z on C:\\Users\\Public\\Desktop"
else
    log "installed unified identity/performance EXE only; GPU-Z was not selected or copied"
fi

umount -- "$MOUNT_DIR"
MOUNTED=0
"$QEMU_NBD" --disconnect "$NBD"
NBD_CONNECTED=0
udevadm settle
"$QEMU_IMG" check -q "$BASE_TMP"
vm_storage_read_qcow2_metadata "$QEMU_IMG" "$BASE_TMP" ||
    die "edited base qcow2 metadata is invalid"
[[ -z "$VM_STORAGE_QCOW2_BACKING" &&
   -z "$VM_STORAGE_QCOW2_DATA_FILE" ]] ||
    die "edited base unexpectedly gained a backing/data file"

chown "$base_uid:$base_gid" "$BASE_TMP"
chmod "$base_mode" "$BASE_TMP"
if (( ! ASSUME_YES )); then
    read -rp "Replace $BASE with the validated portable-enabled copy? (y/N) " answer
    [[ "$answer" =~ ^[Yy]$ ]] || {
        log "cancelled; original base was not changed"
        exit 0
    }
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
if ((SINGLE_IMAGE)); then
    BASE_BACKUP="$base_dir/.${base_leaf}.pre-vgpu-portable-rollback-${timestamp}-$$-$RANDOM"
else
    BASE_BACKUP="$VM_BASE_ARCHIVE_DIR/${base_leaf%.qcow2}-pre-vgpu-portable-${timestamp}-$$.qcow2"
fi
BASE_BACKUP_ATTESTATION="${BASE_BACKUP}.vgpu-portable.json"
if (( ! SINGLE_IMAGE )); then
    [[ "$(stat -c %d -- "$base_dir")" == \
       "$(stat -c %d -- "$VM_BASE_ARCHIVE_DIR")" ]] ||
        die "base and archive directory must be on the same filesystem"
fi
if [[ -e "$ATTESTATION" ]]; then
    mv -T -- "$ATTESTATION" "$BASE_BACKUP_ATTESTATION"
    ATTESTATION_MOVED=1
fi
PUBLICATION_STARTED=1
mv -T -- "$BASE" "$BASE_BACKUP"
if ! mv -T -- "$BASE_TMP" "$BASE"; then
    mv -T -- "$BASE_BACKUP" "$BASE" || true
    die "atomic base publication failed"
fi
BASE_PUBLISHED=1

BASE_FILE_BYTES=$(stat -c %s -- "$BASE")
BASE_DEVICE_ID=$(stat -c %D -- "$BASE")
BASE_INODE=$(stat -c %i -- "$BASE")
BASE_MTIME_NS=$(stat -c %y -- "$BASE")
BASE_CTIME_NS=$(stat -c %z -- "$BASE")
ATTESTATION_TMP="${ATTESTATION}.new.$$.$RANDOM"
GPUZ_INCLUDED_JSON=false
if ((WITH_GPUZ)); then
    GPUZ_INCLUDED_JSON=true
fi
if ((SITE_PRIVATE)); then
    PRIVATE_DEPLOYMENT_MODE=site-private-licensed-firstboot-v2
    if [[ "$PORTABLE_RECEIPT_SCHEMA" == 8 ]]; then
        PRIVATE_DEPLOYMENT_MODE=site-private-licensed-firstboot-v3
    fi
    jq -n \
        --argjson schemaVersion "$PORTABLE_RECEIPT_SCHEMA" \
        --arg deploymentMode "$PRIVATE_DEPLOYMENT_MODE" \
        --arg basePath "$BASE" \
        --argjson baseFileBytes "$BASE_FILE_BYTES" \
        --arg baseDeviceId "$BASE_DEVICE_ID" \
        --arg baseInode "$BASE_INODE" \
        --arg baseMtimeNs "$BASE_MTIME_NS" \
        --arg baseCtimeNs "$BASE_CTIME_NS" \
        --arg portableSha256 "$PORTABLE_SHA256" \
        --argjson portableBytes "$PORTABLE_BYTES" \
        --arg firstBootScriptSha256 "$FIRST_BOOT_SHA256" \
        --arg retrySha256 "$RETRY_SHA256" \
        --arg sysprepAnswerSha256 "$SYSPREP_ANSWER_SHA256" \
        --arg portableLauncherFormat "$PORTABLE_LAUNCHER_FORMAT" \
        --arg driverBranch "$PORTABLE_DRIVER_BRANCH" \
        --arg driverVersion "$PORTABLE_DRIVER_VERSION" \
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
            portableReceiptSchema: 8,
            portableLauncherFormat: $portableLauncherFormat,
            driverBranch: $driverBranch,
            driverVersion: $driverVersion
        } else {} end)' >"$ATTESTATION_TMP"
    chmod 0600 "$ATTESTATION_TMP"
else
    jq -n \
        --argjson schemaVersion 5 \
        --arg basePath "$BASE" \
        --argjson baseFileBytes "$BASE_FILE_BYTES" \
        --arg baseDeviceId "$BASE_DEVICE_ID" \
        --arg baseInode "$BASE_INODE" \
        --arg baseMtimeNs "$BASE_MTIME_NS" \
        --arg baseCtimeNs "$BASE_CTIME_NS" \
        --arg portableGuestPath 'C:\Users\Public\Desktop\VgpuPortable.exe' \
        --arg portableSha256 "$PORTABLE_SHA256" \
        --argjson portableBytes "$PORTABLE_BYTES" \
        --arg gpuZDelivery optional-explicit-sibling \
        --argjson gpuZIncluded "$GPUZ_INCLUDED_JSON" \
        --arg gpuZGuestPath 'C:\Users\Public\Desktop\GPU-Z.exe' \
        --arg gpuZSha256 "$GPUZ_SHA256" \
        --argjson gpuZBytes "$GPUZ_BYTES" \
        --arg guestPerformance embedded-recommended-native-v1 \
        --arg catalogSha256 "$CATALOG_SHA256" \
        --arg installedUtc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        {
            schemaVersion: $schemaVersion,
            bindingMode: "portable-auto",
            basePath: $basePath,
            baseFileBytes: $baseFileBytes,
            baseDeviceId: $baseDeviceId,
            baseInode: $baseInode,
            baseMtimeNs: $baseMtimeNs,
            baseCtimeNs: $baseCtimeNs,
            portableGuestPath: $portableGuestPath,
            portableSha256: $portableSha256,
            portableBytes: $portableBytes,
            gpuZDelivery: $gpuZDelivery,
            gpuZIncluded: $gpuZIncluded,
            gpuZGuestPath: (if $gpuZIncluded then $gpuZGuestPath else null end),
            gpuZSha256: (if $gpuZIncluded then $gpuZSha256 else null end),
            gpuZBytes: (if $gpuZIncluded then $gpuZBytes else null end),
            guestPerformance: $guestPerformance,
            catalogSha256: $catalogSha256,
            installedUtc: $installedUtc
        }' >"$ATTESTATION_TMP"
    chmod 0644 "$ATTESTATION_TMP"
fi
chown "$base_uid:$base_gid" "$ATTESTATION_TMP"
mv -fT -- "$ATTESTATION_TMP" "$ATTESTATION"
ATTESTATION_TMP=""
if ((SITE_PRIVATE)); then
    jq -e \
        --arg basePath "$BASE" \
        --argjson baseFileBytes "$BASE_FILE_BYTES" \
        --arg baseDeviceId "$BASE_DEVICE_ID" \
        --arg baseInode "$BASE_INODE" \
        --arg baseMtimeNs "$BASE_MTIME_NS" \
        --arg baseCtimeNs "$BASE_CTIME_NS" \
        --arg catalogSha256 "$CATALOG_SHA256" \
        --arg portableSha256 "$PORTABLE_SHA256" \
        --argjson portableBytes "$PORTABLE_BYTES" \
        --arg firstBootScriptSha256 "$FIRST_BOOT_SHA256" \
        --arg retrySha256 "$RETRY_SHA256" \
        --arg sysprepAnswerSha256 "$SYSPREP_ANSWER_SHA256" \
        --argjson receiptSchema "$PORTABLE_RECEIPT_SCHEMA" \
        --arg launcherFormat "$PORTABLE_LAUNCHER_FORMAT" \
        --arg driverBranch "$PORTABLE_DRIVER_BRANCH" \
        --arg driverVersion "$PORTABLE_DRIVER_VERSION" '
        (
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
             .schemaVersion == 7 and $receiptSchema == 7 and
             .deploymentMode == "site-private-licensed-firstboot-v2")
            or
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
             .schemaVersion == 8 and $receiptSchema == 8 and
             .deploymentMode == "site-private-licensed-firstboot-v3" and
             .portableReceiptSchema == 8 and
             .portableLauncherFormat == $launcherFormat and
             .driverBranch == $driverBranch and
             .driverVersion == $driverVersion)
        ) and
        .bindingMode == "portable-auto" and
        .basePath == $basePath and .baseFileBytes == $baseFileBytes and
        .baseDeviceId == $baseDeviceId and .baseInode == $baseInode and
        .baseMtimeNs == $baseMtimeNs and .baseCtimeNs == $baseCtimeNs and
        .portableGuestPath == "C:\\ProgramData\\VMate\\G11\\VgpuPortable.exe" and
        .portableSha256 == $portableSha256 and .portableBytes == $portableBytes and
        .firstBootScriptGuestPath == "C:\\ProgramData\\VMate\\G11\\Finalize-Clone.ps1" and
        .firstBootScriptSha256 == $firstBootScriptSha256 and
        .retryGuestPath == "C:\\ProgramData\\VMate\\G11\\Retry-Clone-Initialization.cmd" and
        .retrySha256 == $retrySha256 and
        .sysprepAnswerGuestPath == "C:\\Windows\\Panther\\unattend.xml" and
        .sysprepAnswerSha256 == $sysprepAnswerSha256 and
        .windowsGeneralized == true and .oobeMode == "unattended-auto-finalize" and
        .licenseDelivery == "embedded-private-shared-token" and
        .firstBootWorkflow == "licensed-portable-system-nvapi-two-boot-v1" and
        .systemNvapiDelivery == "per-vm-read-only-iso" and
        .systemNvapiRequired == true and
        .dlsHost == "dls.gvmates.com" and .dlsPort == 443 and
        .guestPerformance == "embedded-recommended-native-v1" and
        .catalogSha256 == $catalogSha256 and (.installedUtc | type) == "string"
    ' "$ATTESTATION" >/dev/null ||
        die "published private base attestation failed verification"
else
    jq -e \
    --arg basePath "$BASE" \
    --argjson baseFileBytes "$BASE_FILE_BYTES" \
    --arg baseDeviceId "$BASE_DEVICE_ID" \
    --arg baseInode "$BASE_INODE" \
    --arg baseMtimeNs "$BASE_MTIME_NS" \
    --arg baseCtimeNs "$BASE_CTIME_NS" \
    --arg catalogSha256 "$CATALOG_SHA256" \
    --arg portableSha256 "$PORTABLE_SHA256" \
    --argjson portableBytes "$PORTABLE_BYTES" \
    --argjson gpuZIncluded "$GPUZ_INCLUDED_JSON" \
    --arg gpuZSha256 "$GPUZ_SHA256" \
    --argjson gpuZBytes "$GPUZ_BYTES" '
    (keys | sort) == [
        "baseCtimeNs", "baseDeviceId", "baseFileBytes", "baseInode",
        "baseMtimeNs", "basePath", "bindingMode", "catalogSha256",
        "gpuZBytes", "gpuZDelivery", "gpuZGuestPath", "gpuZIncluded",
        "gpuZSha256", "guestPerformance",
        "installedUtc", "portableBytes", "portableGuestPath",
        "portableSha256", "schemaVersion"
    ] and
    .schemaVersion == 5 and .bindingMode == "portable-auto" and
    .basePath == $basePath and .baseFileBytes == $baseFileBytes and
    .baseDeviceId == $baseDeviceId and .baseInode == $baseInode and
    .baseMtimeNs == $baseMtimeNs and .baseCtimeNs == $baseCtimeNs and
    .portableGuestPath == "C:\\Users\\Public\\Desktop\\VgpuPortable.exe" and
    .portableSha256 == $portableSha256 and
    .portableBytes == $portableBytes and
    .gpuZDelivery == "optional-explicit-sibling" and
    .guestPerformance == "embedded-recommended-native-v1" and
    .gpuZIncluded == $gpuZIncluded and
    (if $gpuZIncluded then
        .gpuZGuestPath == "C:\\Users\\Public\\Desktop\\GPU-Z.exe" and
        .gpuZSha256 == $gpuZSha256 and .gpuZBytes == $gpuZBytes
     else
        .gpuZGuestPath == null and .gpuZSha256 == null and .gpuZBytes == null
     end) and
    .catalogSha256 == $catalogSha256 and
    (.installedUtc | type) == "string"
' "$ATTESTATION" >/dev/null ||
        die "published base attestation failed verification"
fi
BACKUP_RESULT=$BASE_BACKUP
if ((SINGLE_IMAGE)); then
    [[ -f "$BASE_BACKUP" && ! -L "$BASE_BACKUP" &&
       "$(stat -c %s -- "$BASE_BACKUP")" == "$ORIGINAL_BASE_FILE_BYTES" &&
       "$(stat -c %D -- "$BASE_BACKUP")" == "$ORIGINAL_BASE_DEVICE_ID" &&
       "$(stat -c %i -- "$BASE_BACKUP")" == "$ORIGINAL_BASE_INODE" &&
       "$(stat -c %y -- "$BASE_BACKUP")" == "$ORIGINAL_BASE_MTIME_NS" ]] ||
        die "temporary rollback generation changed; refusing to discard it"
    if ((ATTESTATION_MOVED)); then
        [[ -f "$BASE_BACKUP_ATTESTATION" && ! -L "$BASE_BACKUP_ATTESTATION" ]] ||
            die "temporary rollback attestation changed; refusing silent cleanup"
    fi
    # The new base and sidecar are already fully verified.  Commit before
    # unlinking rollback data so an unlikely unlink error can never make EXIT
    # cleanup remove the valid new base after the old generation is gone.
    PUBLICATION_COMPLETE=1
    rm -- "$BASE_BACKUP"
    ((ATTESTATION_MOVED == 0)) || rm -- "$BASE_BACKUP_ATTESTATION"
    BACKUP_RESULT='none (temporary rollback deleted after full verification)'
else
    PUBLICATION_COMPLETE=1
fi
BASE_TMP=""

trap - EXIT
rm -rf -- "$WORK_ROOT"
GPUZ_RESULT='not included (default; install later from the official audited file)'
if ((WITH_GPUZ)); then
    GPUZ_RESULT="C:\\Users\\Public\\Desktop\\GPU-Z.exe / sha256=$GPUZ_SHA256 / bytes=$GPUZ_BYTES"
fi
CLONE_HINT="  ./deploy/scripts/clone-from-base.sh $BASE NEW_VM_ID --gpu-profile gtx1050_2gb"
if ((SITE_PRIVATE)); then
    cat <<EOF
[vgpu-base] PASS / private Sysprep clone base
  base:       $BASE
  archive:    $BACKUP_RESULT
  portable:   C:\ProgramData\VMate\G11\VgpuPortable.exe
              sha256=$PORTABLE_SHA256
  first boot: automatic licensed receipt schema $PORTABLE_RECEIPT_SCHEMA finalizer; one execution only
  Guest Lite: automatic pinned 2.6.7 profile in the same verified first-boot flow
  OOBE:       unattended; each clone still receives a generalized Windows identity
  DLS:        dls.gvmates.com:443
  performance: embedded recommended-native-v1
  driver:     $PORTABLE_DRIVER_BRANCH / $PORTABLE_DRIVER_VERSION
  catalog:    $CATALOG_SHA256

下一步只需导出私有基础镜像包：
  ./deploy/scripts/export-vgpu-base.sh ${BASE_NAME:-BASE_NAME} OUTPUT_DIRECTORY
EOF
else
    cat <<EOF
[vgpu-base] PASS
  base:       $BASE
  archive:    $BACKUP_RESULT
  portable:   C:\\Users\\Public\\Desktop\\VgpuPortable.exe
              sha256=$PORTABLE_SHA256
  performance: embedded recommended-native-v1
  GPU-Z:      $GPUZ_RESULT
  catalog:    $CATALOG_SHA256

后续 clone 不需要再打包，也不需要 HTTP：
$CLONE_HINT
EOF
fi

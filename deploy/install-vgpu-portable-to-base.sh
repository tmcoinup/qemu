#!/usr/bin/env bash
# Atomically place the VM-unbound offline identity/performance EXE on the
# Windows public desktop of the standalone clone base.  GPU-Z is omitted by default and may
# be included only through an explicit option.  The live base is never mounted
# or edited.
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
                     (default: $STAGE_DIR/VgpuPortable/VgpuPortable.exe)
  --with-gpuz        Also place the audited GPU-Z.exe beside the EXE (optional)
  --gpuz-source FILE Audited external TechPowerUp GPU-Z 2.70 executable
                     (implies --with-gpuz; default source when selected:
                     $IMAGE_ROOT/candidates/gpuz-2.70-audit/GPU-Z.2.70.0.exe)
  --yes, -y          Skip the final replacement confirmation
  -h, --help         Show this help

The script clones the base to a private temporary qcow2, mounts only that
copy, writes the unified VgpuPortable.exe to the Public Desktop, validates it, then
atomically archives/replaces the base.  GPU-Z is not required or copied unless
--with-gpuz/--gpuz-source is explicit.  Hibernated/dirty NTFS is refused.
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
[[ -n "$PORTABLE_EXE" ]] ||
    PORTABLE_EXE="$STAGE_DIR/VgpuPortable/VgpuPortable.exe"
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
        cp mv sync chmod chown ln mktemp mkdir; do
    command -v "$dependency" >/dev/null 2>&1 ||
        die "missing dependency: $dependency"
done
: "${QEMU_IMG:=$(command -v qemu-img)}"
QEMU_NBD=$(command -v qemu-nbd)
vgpu_profile_validate_catalog ||
    die "GPU profile catalog validation failed"
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
CATALOG_SHA256=$(jq -er \
    --arg exeSha256 "$PORTABLE_SHA256" \
    --argjson exeBytes "$PORTABLE_BYTES" '
    select(
        (keys | sort) == [
            "bindingMode", "bundleManifestSha256", "catalogSha256",
            "exeBytes", "exeSha256", "gpuZDelivery", "guestPerformance",
            "launcherFormat", "schemaVersion"
        ] and
        .schemaVersion == 6 and .bindingMode == "portable-auto" and
        .gpuZDelivery == "optional-explicit-sibling" and
        .guestPerformance == "embedded-recommended-native-v1" and
        .launcherFormat == "QEMU_VGPU_PORTABLE_UNIFIED_V6" and
        .exeSha256 == $exeSha256 and .exeBytes == $exeBytes and
        (.catalogSha256 | test("^[0-9A-F]{64}$")) and
        (.bundleManifestSha256 | test("^[0-9A-F]{64}$"))
    ) | .catalogSha256
' "$PORTABLE_RECEIPT") ||
    die "portable EXE host receipt is invalid"
[[ "$CATALOG_SHA256" == "$EXPECTED_CATALOG_SHA256" ]] ||
    die "portable EXE uses an obsolete GPU profile catalog; rebuild it before installing the base"

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
ensure_storage_directory "$VM_BASE_ARCHIVE_DIR"

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
for storage_dir in "$VM_RUN_DIR" "$VM_BASE_ARCHIVE_DIR"; do
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
            )
        ) then
            .baseCtimeNs = $baseCtimeNs
        else
            error("restored attestation is not a valid schema-2/schema-3/schema-4/schema-5 generation")
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
DEST_DIR="$MOUNT_DIR/Users/Public/Desktop"
mkdir -p -- "$DEST_DIR"
PORTABLE_DEST_TMP="$DEST_DIR/.VgpuPortable.exe.new.$$"
cp --reflink=never -- "$PORTABLE_EXE" "$PORTABLE_DEST_TMP"
sync -- "$PORTABLE_DEST_TMP"
[[ "$(sha256_upper "$PORTABLE_DEST_TMP")" == "$PORTABLE_SHA256" &&
   "$(stat -c %s -- "$PORTABLE_DEST_TMP")" == "$PORTABLE_BYTES" ]] ||
    die "portable EXE verification failed inside the base image"
mv -fT -- "$PORTABLE_DEST_TMP" "$DEST_DIR/VgpuPortable.exe"
if ((WITH_GPUZ)); then
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
if ((WITH_GPUZ)); then
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
BASE_BACKUP="$VM_BASE_ARCHIVE_DIR/${base_leaf%.qcow2}-pre-vgpu-portable-${timestamp}-$$.qcow2"
BASE_BACKUP_ATTESTATION="${BASE_BACKUP}.vgpu-portable.json"
[[ "$(stat -c %d -- "$base_dir")" == \
   "$(stat -c %d -- "$VM_BASE_ARCHIVE_DIR")" ]] ||
    die "base and archive directory must be on the same filesystem"
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
chown "$base_uid:$base_gid" "$ATTESTATION_TMP"
mv -fT -- "$ATTESTATION_TMP" "$ATTESTATION"
ATTESTATION_TMP=""
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
PUBLICATION_COMPLETE=1
BASE_TMP=""

trap - EXIT
rm -rf -- "$WORK_ROOT"
GPUZ_RESULT='not included (default; install later from the official audited file)'
if ((WITH_GPUZ)); then
    GPUZ_RESULT="C:\\Users\\Public\\Desktop\\GPU-Z.exe / sha256=$GPUZ_SHA256 / bytes=$GPUZ_BYTES"
fi
if [[ -n "$BASE_NAME" ]]; then
    CLONE_HINT="  ./deploy/scripts/clone-from-base.sh $BASE_NAME NEW_VM_ID --gpu-profile gtx1050_2gb"
else
    CLONE_HINT="  自定义 --base 路径不是托管名称；请先放入 VM_BASE_DIR 并按名称调用 clone-from-base.sh。"
fi
cat <<EOF
[vgpu-base] PASS
  base:       $BASE
  archive:    $BASE_BACKUP
  portable:   C:\\Users\\Public\\Desktop\\VgpuPortable.exe
              sha256=$PORTABLE_SHA256
  performance: embedded recommended-native-v1
  GPU-Z:      $GPUZ_RESULT
  catalog:    $CATALOG_SHA256

后续 clone 不需要再打包，也不需要 HTTP：
$CLONE_HINT
EOF

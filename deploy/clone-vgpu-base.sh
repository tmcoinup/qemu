#!/usr/bin/env bash
# Create a new B/native VM configuration and a standalone disk copy from the
# portable-enabled Windows base.  No per-VM guest package is generated.
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
vm_storage_init

usage() {
    cat <<'EOF'
usage: ./deploy/clone-vgpu-base.sh VM_ID [options]

Options:
  --gpu-profile PROFILE      gtx750ti_2gb, gt1030_2gb or gtx1050_2gb
                             (default: gtx1050_2gb)
  --platform PROFILE         Forward to create-vm.sh
  --ssd-profile PROFILE      Forward to create-vm.sh
  --monitor-profile PROFILE  Forward to create-vm.sh
  --start                    Start the new VM after cloning
  -h, --help                 Show this help

The public base must first be prepared once:
  ./deploy/package-vgpu-one-click.sh
  ./deploy/install-vgpu-portable-to-base.sh

The cloned guest already contains VgpuPortable.exe on the Public Desktop.
Double-click it inside Windows; B/native clones need no host commit afterward.
EOF
}

die() {
    echo "[vgpu-clone] ERROR: $*" >&2
    exit 1
}

VM_ID=""
GPU_PROFILE_REQUEST=gtx1050_2gb
START_AFTER=0
declare -a CREATE_ARGS=()
while (($#)); do
    case "$1" in
        --gpu-profile)
            (($# >= 2)) || die "--gpu-profile requires a value"
            GPU_PROFILE_REQUEST=$2
            shift 2
            ;;
        --platform|--ssd-profile|--monitor-profile)
            (($# >= 2)) || die "$1 requires a value"
            CREATE_ARGS+=("$1" "$2")
            shift 2
            ;;
        --start)
            START_AFTER=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if vm_storage_id_is_supported "$1" && [[ -z "$VM_ID" ]]; then
                VM_ID=$1
                shift
            else
                die "unknown argument or duplicate/unsupported VM_ID: $1"
            fi
            ;;
    esac
done
[[ -n "$VM_ID" ]] || {
    usage >&2
    exit 2
}
vgpu_profile_validate_catalog ||
    die "GPU profile catalog validation failed"
vgpu_profile_load "$GPU_PROFILE_REQUEST" ||
    die "unsupported --gpu-profile: $GPU_PROFILE_REQUEST"
EXPECTED_CATALOG_SHA256=$(vgpu_profile_catalog_sha256)
[[ "$EXPECTED_CATALOG_SHA256" =~ ^[0-9A-F]{64}$ ]] ||
    die "could not calculate the current GPU profile catalog hash"

for dependency in jq stat flock; do
    command -v "$dependency" >/dev/null 2>&1 ||
        die "missing dependency: $dependency"
done
vm_storage_prepare
exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -s "$STORAGE_LOCK_FD"
START_LOCK=$(vm_storage_run_path "$VM_ID" start.lock)
exec {START_LOCK_FD}>"$START_LOCK"
if ! flock -n -x "$START_LOCK_FD"; then
    die "vm${VM_ID} is starting, running, or being modified"
fi
BASE=$(vm_storage_base_path)
ATTESTATION="${BASE}.vgpu-portable.json"
[[ -f "$BASE" && ! -L "$BASE" ]] ||
    die "standalone Windows base is missing: $BASE"
[[ -f "$ATTESTATION" && ! -L "$ATTESTATION" ]] ||
    die "base has no portable-package attestation; run install-vgpu-portable-to-base.sh"
BASE_FILE_BYTES=$(stat -c %s -- "$BASE")
BASE_DEVICE_ID=$(stat -c %D -- "$BASE")
BASE_INODE=$(stat -c %i -- "$BASE")
BASE_MTIME_NS=$(stat -c %y -- "$BASE")
BASE_CTIME_NS=$(stat -c %z -- "$BASE")
jq -e \
    --arg basePath "$BASE" \
    --argjson baseFileBytes "$BASE_FILE_BYTES" \
    --arg baseDeviceId "$BASE_DEVICE_ID" \
    --arg baseInode "$BASE_INODE" \
    --arg baseMtimeNs "$BASE_MTIME_NS" \
    --arg baseCtimeNs "$BASE_CTIME_NS" \
    --arg catalogSha256 "$EXPECTED_CATALOG_SHA256" '
    (keys | sort) == [
        "baseCtimeNs", "baseDeviceId", "baseFileBytes", "baseInode",
        "baseMtimeNs", "basePath", "bindingMode", "catalogSha256",
        "exeBytes", "exeSha256", "guestPath", "installedUtc",
        "schemaVersion"
    ] and
    .schemaVersion == 2 and .bindingMode == "portable-auto" and
    .basePath == $basePath and .baseFileBytes == $baseFileBytes and
    .baseDeviceId == $baseDeviceId and .baseInode == $baseInode and
    .baseMtimeNs == $baseMtimeNs and .baseCtimeNs == $baseCtimeNs and
    .guestPath == "C:\\Users\\Public\\Desktop\\VgpuPortable.exe" and
    (.exeSha256 | test("^[0-9A-F]{64}$")) and
    .catalogSha256 == $catalogSha256
' "$ATTESTATION" >/dev/null ||
    die "base/catalog changed after portable installation; re-run install-vgpu-portable-to-base.sh"

INSTANCE_DIR=$(vm_storage_instance_dir "$VM_ID")
EXISTING_CONF=$(vm_storage_config_path "$VM_ID") ||
    die "vm${VM_ID} configuration paths are ambiguous"
if [[ -e "$EXISTING_CONF" || -L "$EXISTING_CONF" ]]; then
    die "vm${VM_ID} configuration already exists"
fi
DISK=$(vm_storage_disk_path "$VM_ID")
[[ ! -e "$DISK" && ! -L "$DISK" ]] ||
    die "vm${VM_ID} disk already exists: $DISK"

CREATED_CONF=""
CREATED_CONF_ID=""
CLONE_COMMITTED=0
cleanup_clone() {
    if (( ! CLONE_COMMITTED )) && [[ -n "$CREATED_CONF" &&
            -f "$CREATED_CONF" && ! -L "$CREATED_CONF" &&
            ! -e "$DISK" && ! -L "$DISK" &&
            "$(stat -Lc '%d:%i' -- "$CREATED_CONF")" == "$CREATED_CONF_ID" ]]; then
        rm -f -- "$CREATED_CONF" || true
        echo "[vgpu-clone] rolled back the newly created VM configuration" >&2
    fi
}
trap cleanup_clone EXIT

echo "[vgpu-clone] creating vm${VM_ID} / ${GPU_PROFILE_REQUEST}"
VM_START_LOCK_HELD=1 "$here/create-vm.sh" "$VM_ID" \
    --gpu-profile "$GPU_PROFILE_REQUEST" "${CREATE_ARGS[@]}"
CONF=$(vm_storage_config_path "$VM_ID") ||
    die "new VM configuration was not published"
[[ -f "$CONF" && ! -L "$CONF" ]] ||
    die "new VM configuration is not a regular non-symlink file"
CREATED_CONF=$CONF
CREATED_CONF_ID=$(stat -Lc '%d:%i' -- "$CONF")
if ! (
    unset SPOOF_MODE GPU_PROFILE VM_UUID
    # shellcheck source=/dev/null
    source "$CONF"
    [[ "$SPOOF_MODE" == B &&
       "$GPU_PROFILE" == "$GPU_PROFILE_REQUEST" &&
       "$VM_UUID" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]]
); then
    die "new VM configuration failed the B/native identity check"
fi

if ! "$here/create-disk.sh" "$VM_ID" --from-base; then
    die "base cloning failed; the new configuration will be rolled back when no disk was published"
fi
[[ -f "$DISK" && ! -L "$DISK" ]] ||
    die "base cloning returned success without a regular VM disk"
CLONE_COMMITTED=1
trap - EXIT

cat <<EOF
[vgpu-clone] PASS
  VM:          vm${VM_ID}
  GPU profile: ${GPU_PROFILE_REQUEST}
  config:      ${CONF}
  disk:        ${DISK}
  guest EXE:   C:\\Users\\Public\\Desktop\\VgpuPortable.exe

Windows 启动后双击桌面的 VgpuPortable.exe。它会读取本次启动的只读
profile/UUID 声明并自动选择型号；整个过程离线，不需要 HTTP，也不需要
关机后再执行 host commit。
EOF

if ((START_AFTER)); then
    flock -u "$START_LOCK_FD"
    exec {START_LOCK_FD}>&-
    flock -u "$STORAGE_LOCK_FD"
    exec {STORAGE_LOCK_FD}>&-
    exec "$here/start-vm.sh" "$VM_ID"
fi

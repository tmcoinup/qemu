#!/usr/bin/env bash
# Upgrade one stopped, failed G-11 clone to the current first-boot contract.
# The VM-bound system-NVAPI package and the small guest finalizer/Guest Lite
# payload are refreshed together. The licensed EXE/result and private base are
# retained; no BCD, driver, or code-integrity setting is changed.
set -euo pipefail
umask 077
export LC_ALL=C

ORIGINAL_ARGS=("$@")

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=../lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
vm_storage_init

die() { echo "[g11-init-repair] ERROR: $*" >&2; exit 1; }
usage() { echo "usage: $0 VM_ID" >&2; }
sha256_upper() { sha256sum -- "$1" | awk '{print toupper($1)}'; }

(($# == 1)) || { usage; exit 2; }
VM_ID=$1
vm_storage_validate_id "$VM_ID" || exit 2
if ((EUID != 0)); then
    exec sudo --preserve-env=IMAGE_ROOT,VM_ROOT,VMS_DIR,VM_INSTANCES_DIR,VM_BASE_DIR,STAGE_DIR,QEMU_IMG,NBD \
        -- "$0" "${ORIGINAL_ARGS[@]}"
fi
for dependency in jq sha256sum awk stat realpath flock pgrep grep find mktemp \
        mv chmod chown rm cp sync sed qemu-nbd qemu-img mount umount \
        ntfs-3g ntfs-3g.probe blkid lsblk modprobe partprobe udevadm rmdir; do
    command -v "$dependency" >/dev/null 2>&1 || die "missing dependency: $dependency"
done
: "${QEMU_IMG:=$(command -v qemu-img)}"
[[ -x "$QEMU_IMG" ]] || die "qemu-img is missing; set QEMU_IMG explicitly"

vm_storage_require_namespace_ready "$VM_ID"
vm_storage_prepare
vm_storage_validate_instance_tree "$VM_ID" || die "VM instance tree is unsafe"
INSTANCE_DIR=$(vm_storage_instance_dir "$VM_ID")
CONF=$(vm_storage_config_path "$VM_ID")
DISK=$(vm_storage_disk_path "$VM_ID")
REQUIRED_MARKER="$INSTANCE_DIR/.g11-init-required"
DONE_MARKER="$INSTANCE_DIR/.g11-initialized"
PACKAGE_PARENT=$(vm_storage_instance_package_dir "$VM_ID") ||
    die "could not resolve VM package directory"
CURRENT_ROOT="$PACKAGE_PARENT/SystemNvapiProjection"
PACKAGER="$here/package-system-nvapi-projection.sh"
FIRST_BOOT_SOURCE="$here/guest/finalize-g11-clone.ps1"
RETRY_SOURCE="$here/guest/Retry-Clone-Initialization.cmd"
GUEST_LITE_SOURCE_ROOT="$here/guest/guest-lite"
GUEST_LITE_MANIFEST_SOURCE="$GUEST_LITE_SOURCE_ROOT/clone-manifest.json"
GUEST_LITE_ASSETS=(
    G11-Guest-Lite.ps1
    01-OneClick-Apply.cmd
    02-Audit.cmd
    03-Rollback.cmd
    README.txt
)

[[ -f "$CONF" && ! -L "$CONF" && -f "$DISK" && ! -L "$DISK" ]] ||
    die "vm${VM_ID} lacks a safe config or disk"
[[ -f "$REQUIRED_MARKER" && ! -L "$REQUIRED_MARKER" ]] ||
    die "vm${VM_ID} is not waiting for G-11 clone initialization"
[[ ! -e "$DONE_MARKER" && ! -L "$DONE_MARKER" ]] ||
    die "vm${VM_ID} is already initialized"
[[ -d "$CURRENT_ROOT" && ! -L "$CURRENT_ROOT" ]] ||
    die "current per-VM initialization package is missing or unsafe"
[[ -x "$PACKAGER" && ! -L "$PACKAGER" ]] ||
    die "system NVAPI packager is missing or unsafe: $PACKAGER"
for payload_source in "$FIRST_BOOT_SOURCE" "$RETRY_SOURCE" \
        "$GUEST_LITE_MANIFEST_SOURCE"; do
    [[ -f "$payload_source" && ! -L "$payload_source" && -s "$payload_source" ]] ||
        die "current clone payload is missing or unsafe: $payload_source"
done
for guest_lite_asset in "${GUEST_LITE_ASSETS[@]}"; do
    [[ -f "$GUEST_LITE_SOURCE_ROOT/$guest_lite_asset" &&
       ! -L "$GUEST_LITE_SOURCE_ROOT/$guest_lite_asset" &&
       -s "$GUEST_LITE_SOURCE_ROOT/$guest_lite_asset" ]] ||
        die "Guest Lite clone asset is missing or unsafe: $guest_lite_asset"
done
FIRST_BOOT_SHA256=$(sha256_upper "$FIRST_BOOT_SOURCE")
RETRY_SHA256=$(sha256_upper "$RETRY_SOURCE")
GUEST_LITE_MANIFEST_SHA256=$(sha256_upper "$GUEST_LITE_MANIFEST_SOURCE")
FINALIZER_GUEST_LITE_MANIFEST_SHA256=$(sed -n \
    "s/^\\\$ExpectedGuestLiteManifestSha256 = '\\([0-9A-F]\\{64\\}\\)'$/\\1/p" \
    "$FIRST_BOOT_SOURCE")
[[ "$FINALIZER_GUEST_LITE_MANIFEST_SHA256" == \
   "$GUEST_LITE_MANIFEST_SHA256" ]] ||
    die "current finalizer does not pin the current Guest Lite manifest"
jq -e '
    (keys | sort) == ["files", "profileVersion", "schemaVersion"] and
    .schemaVersion == 1 and .profileVersion == "2.6.4" and
    (.files | type) == "array" and (.files | length) == 5 and
    ([.files[].name] | sort) == [
        "01-OneClick-Apply.cmd", "02-Audit.cmd", "03-Rollback.cmd",
        "G11-Guest-Lite.ps1", "README.txt"
    ] and
    ([.files[].name] | unique | length) == 5 and
    all(.files[];
        (.sha256 | test("^[0-9A-F]{64}$")) and
        (.bytes | type) == "number" and .bytes > 0 and
        (.bytes | floor) == .bytes)
' "$GUEST_LITE_MANIFEST_SOURCE" >/dev/null ||
    die "current Guest Lite manifest is invalid"
grep -Fq 'schemaVersion = 4' "$FIRST_BOOT_SOURCE" ||
    die "current finalizer does not publish clone marker schema 4"

verify_guest_lite_dir() {
    local asset_dir=$1 name expected_sha expected_bytes asset_path
    [[ -d "$asset_dir" && ! -L "$asset_dir" &&
       "$(sha256_upper "$asset_dir/clone-manifest.json")" == "$GUEST_LITE_MANIFEST_SHA256" ]] ||
        return 1
    while IFS=$'\t' read -r name expected_sha expected_bytes; do
        asset_path="$asset_dir/$name"
        [[ -f "$asset_path" && ! -L "$asset_path" &&
           "$(sha256_upper "$asset_path")" == "$expected_sha" &&
           "$(stat -c %s -- "$asset_path")" == "$expected_bytes" ]] ||
            return 1
    done < <(jq -r '.files[] | [.name, .sha256, (.bytes | tostring)] | @tsv' \
        "$asset_dir/clone-manifest.json")
}

exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -x "$STORAGE_LOCK_FD"
START_LOCK=$(vm_storage_run_path "$VM_ID" start.lock)
exec {START_LOCK_FD}>"$START_LOCK"
flock -n -x "$START_LOCK_FD" || die "vm${VM_ID} is starting or running"
if pgrep -af qemu-system-x86_64 2>/dev/null | grep -F -- "$DISK" >/dev/null; then
    die "vm${VM_ID} is still running; shut it down before refreshing first boot"
fi
vm_storage_read_qcow2_metadata "$QEMU_IMG" "$DISK" ||
    die "vm${VM_ID} disk is not a verifiable qcow2"
[[ -z "$VM_STORAGE_QCOW2_DATA_FILE" ]] ||
    die "vm${VM_ID} disk cannot use an external data file"
"$QEMU_IMG" check -q "$DISK"

vgpu_profile_validate_catalog || die "GPU profile catalog validation failed"
CATALOG_SHA256=$(vgpu_profile_catalog_sha256)
jq -e --arg catalogSha256 "$CATALOG_SHA256" '
    (keys | sort) == [
        "baseName", "catalogSha256", "createdUtc", "gpuProfile",
        "monitorProfile", "schemaVersion", "sourceConfigSha256", "state",
        "systemNvapiContractId", "systemNvapiIsoFile",
        "systemNvapiIsoSha256", "vmUuid"
    ] and
    .schemaVersion == 2 and .state == "guest-firstboot-required" and
    (.baseName | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
    .catalogSha256 == $catalogSha256 and
    (.vmUuid | test("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")) and
    (.gpuProfile | test("^[a-z0-9_]+$")) and
    (.monitorProfile | test("^[a-z0-9][a-z0-9-]{0,47}$")) and
    (.sourceConfigSha256 | test("^[0-9A-F]{64}$")) and
    (.systemNvapiContractId | test("^[0-9A-F]{64}$")) and
    (.systemNvapiIsoFile | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,191}\\.iso$")) and
    (.systemNvapiIsoSha256 | test("^[0-9A-F]{64}$")) and
    (.createdUtc | type) == "string"
' "$REQUIRED_MARKER" >/dev/null || die "existing initialization marker is invalid"
BASE_NAME=$(jq -er '.baseName' "$REQUIRED_MARKER")

NEW_ROOT=$(mktemp -d "$PACKAGE_PARENT/.SystemNvapiProjection.new.XXXXXXXX")
OLD_ROOT="$PACKAGE_PARENT/.SystemNvapiProjection.old.$$.$RANDOM"
MARKER_TMP=$(mktemp "$INSTANCE_DIR/.g11-init-required.new.XXXXXXXX")
PAYLOAD_STAGE=$(mktemp -d "$INSTANCE_DIR/.g11-clone-payload.new.XXXXXXXX")
MOUNT_DIR=$(mktemp -d /tmp/g11-init-repair.XXXXXXXX)
if [[ -n "${NBD:-}" ]]; then
    [[ "$NBD" =~ ^/dev/nbd([0-9]|[12][0-9]|3[01])$ ]] ||
        die "NBD must be /dev/nbd0 through /dev/nbd31"
    _NBD_PINNED=1
else
    NBD=/dev/nbd0
    _NBD_PINNED=""
fi
ROOT_SWAPPED=0
MOUNTED=0
COMPLETE=0
cleanup() {
    local status=$?
    local cleanup_status=$status
    trap - EXIT HUP INT TERM
    if ((MOUNTED)); then
        if umount -- "$MOUNT_DIR" >/dev/null 2>&1; then
            MOUNTED=0
        else
            echo "[g11-init-repair] ERROR: cleanup could not unmount $MOUNT_DIR" >&2
            cleanup_status=70
        fi
    fi
    if [[ "${_NBD_CONNECTED:-0}" == 1 && -n "${_NBD_DEV:-}" ]]; then
        if qemu-nbd --disconnect "$_NBD_DEV" >/dev/null 2>&1; then
            _NBD_CONNECTED=0
        else
            echo "[g11-init-repair] ERROR: cleanup could not disconnect $_NBD_DEV" >&2
            cleanup_status=70
        fi
    fi
    if (( ! COMPLETE )); then
        [[ -z "$MARKER_TMP" ]] || rm -f -- "$MARKER_TMP"
        if (( ROOT_SWAPPED )); then
            rm -rf -- "$CURRENT_ROOT"
            mv -T -- "$OLD_ROOT" "$CURRENT_ROOT" >/dev/null 2>&1 || true
        fi
        [[ -z "$NEW_ROOT" ]] || rm -rf -- "$NEW_ROOT"
    fi
    [[ -z "$PAYLOAD_STAGE" ]] || rm -rf -- "$PAYLOAD_STAGE"
    rmdir -- "$MOUNT_DIR" >/dev/null 2>&1 || true
    exit "$cleanup_status"
}
trap cleanup EXIT HUP INT TERM
# shellcheck source=../lib/nbd-lock.sh
source "$here/lib/nbd-lock.sh"

for guest_lite_asset in "${GUEST_LITE_ASSETS[@]}"; do
    cp --reflink=never -- "$GUEST_LITE_SOURCE_ROOT/$guest_lite_asset" \
        "$PAYLOAD_STAGE/$guest_lite_asset"
done
for guest_lite_launcher in "$PAYLOAD_STAGE"/*.cmd; do
    sed -i 's/$/\r/' "$guest_lite_launcher"
done
cp --reflink=never -- "$GUEST_LITE_MANIFEST_SOURCE" \
    "$PAYLOAD_STAGE/clone-manifest.json"
verify_guest_lite_dir "$PAYLOAD_STAGE" ||
    die "staged Guest Lite payload differs from its pinned manifest"

echo "[g11-init-repair] generating a fresh VM-bound initialization package for vm${VM_ID}"
"$PACKAGER" "$VM_ID" --output-root "$NEW_ROOT"
mapfile -d '' -t NEW_ISOS < <(
    find -P "$NEW_ROOT" -mindepth 1 -maxdepth 1 -type f \
        -name "vm${VM_ID}-*.iso" -print0
)
mapfile -d '' -t NEW_DIRS < <(
    find -P "$NEW_ROOT" -mindepth 1 -maxdepth 1 -type d \
        -name "vm${VM_ID}-*" -print0
)
((${#NEW_ISOS[@]} == 1 && ${#NEW_DIRS[@]} == 1)) ||
    die "packager did not publish exactly one ISO/payload pair"
NEW_ISO=${NEW_ISOS[0]}
NEW_DIR=${NEW_DIRS[0]}
NEW_CONTRACT="$NEW_DIR/system-nvapi-contract.json"
[[ -f "$NEW_CONTRACT" && ! -L "$NEW_CONTRACT" ]] ||
    die "new package lacks a safe contract"
CONTRACT_ID=$(jq -er '.contractId' "$NEW_CONTRACT")
CONFIG_SHA256=$(sha256_upper "$CONF")
jq -e \
    --argjson vmId "$VM_ID" \
    --arg sourceConfigSha256 "$CONFIG_SHA256" \
    --arg contractId "$CONTRACT_ID" '
    .schemaVersion == 4 and .purpose == "g11-system-nvapi-projection" and
    .vmId == $vmId and .contractId == $contractId and
    .sourceConfigSha256 == $sourceConfigSha256 and
    (.vmUuid | test("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")) and
    (.profile.key | test("^[a-z0-9_]+$")) and
    (.monitor.key | test("^[a-z0-9][a-z0-9-]{0,47}$"))
' "$NEW_CONTRACT" >/dev/null || die "new package contract does not match vm.conf"
CALCULATED_CONTRACT_ID=$(jq -cS 'del(.contractId)' "$NEW_CONTRACT" |
    sha256sum | awk '{print toupper($1)}')
[[ "$CONTRACT_ID" == "$CALCULATED_CONTRACT_ID" ]] ||
    die "new package contract content hash is invalid"

VM_UUID=$(jq -er '.vmUuid' "$NEW_CONTRACT")
GPU_PROFILE=$(jq -er '.profile.key' "$NEW_CONTRACT")
MONITOR_PROFILE=$(jq -er '.monitor.key' "$NEW_CONTRACT")
ISO_FILE=$(basename -- "$NEW_ISO")
[[ "$ISO_FILE" == "vm${VM_ID}-${VM_UUID}-${CONTRACT_ID:0:16}.iso" ]] ||
    die "new initialization ISO name is not content-bound"
ISO_SHA256=$(sha256_upper "$NEW_ISO")
jq -n \
    --argjson schemaVersion 2 \
    --arg state guest-firstboot-required \
    --arg baseName "$BASE_NAME" \
    --arg catalogSha256 "$CATALOG_SHA256" \
    --arg createdUtc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg vmUuid "$VM_UUID" \
    --arg gpuProfile "$GPU_PROFILE" \
    --arg monitorProfile "$MONITOR_PROFILE" \
    --arg sourceConfigSha256 "$CONFIG_SHA256" \
    --arg systemNvapiContractId "$CONTRACT_ID" \
    --arg systemNvapiIsoFile "$ISO_FILE" \
    --arg systemNvapiIsoSha256 "$ISO_SHA256" '
    {
        schemaVersion: $schemaVersion,
        state: $state,
        baseName: $baseName,
        catalogSha256: $catalogSha256,
        createdUtc: $createdUtc,
        vmUuid: $vmUuid,
        gpuProfile: $gpuProfile,
        monitorProfile: $monitorProfile,
        sourceConfigSha256: $sourceConfigSha256,
        systemNvapiContractId: $systemNvapiContractId,
        systemNvapiIsoFile: $systemNvapiIsoFile,
        systemNvapiIsoSha256: $systemNvapiIsoSha256
    }
' >"$MARKER_TMP"
chmod 0600 "$MARKER_TMP"
chown "$(stat -c %u -- "$REQUIRED_MARKER"):$(stat -c %g -- "$REQUIRED_MARKER")" \
    "$MARKER_TMP"
chmod 0700 "$NEW_ROOT"
chown -R "$(stat -c %u -- "$CURRENT_ROOT"):$(stat -c %g -- "$CURRENT_ROOT")" \
    "$NEW_ROOT"

publish_guest_file() {
    local source_file=$1 destination_file=$2 expected_sha256=$3
    local temporary_file="${destination_file}.new.$$.$RANDOM"
    if [[ -e "$destination_file" || -L "$destination_file" ]]; then
        [[ -f "$destination_file" && ! -L "$destination_file" ]] ||
            die "guest payload destination is unsafe: $destination_file"
    fi
    [[ ! -e "$temporary_file" && ! -L "$temporary_file" ]] ||
        die "guest payload temporary path already exists: $temporary_file"
    cp --reflink=never -- "$source_file" "$temporary_file"
    sync -- "$temporary_file"
    [[ "$(sha256_upper "$temporary_file")" == "$expected_sha256" ]] ||
        die "guest payload copy verification failed: $destination_file"
    mv -fT -- "$temporary_file" "$destination_file"
}

echo "[g11-init-repair] safely updating the stopped guest to marker schema 4 / Guest Lite 2.6.4"
modprobe nbd max_part=32 >/dev/null 2>&1 || true
nbd_connect NBD "$DISK" read-write
partprobe "$NBD"
udevadm settle
mapfile -t PARTITIONS < <(
    lsblk -lnpo NAME,TYPE "$NBD" | awk '$2 == "part" {print $1}'
)
((${#PARTITIONS[@]} > 0)) || die "disk has no visible partitions"
WINDOWS_PARTITION=""
for partition in "${PARTITIONS[@]}"; do
    [[ "$(blkid -o value -s TYPE -- "$partition" 2>/dev/null || true)" == ntfs ]] ||
        continue
    if mount -t ntfs-3g -o ro,norecover -- "$partition" "$MOUNT_DIR" \
            >/dev/null 2>&1; then
        MOUNTED=1
        if [[ -d "$MOUNT_DIR/Windows/System32" &&
              -d "$MOUNT_DIR/ProgramData" &&
              -d "$MOUNT_DIR/Users/Public" ]]; then
            WINDOWS_PARTITION=$partition
        fi
        umount -- "$MOUNT_DIR" || die "could not unmount Windows partition probe"
        MOUNTED=0
        [[ -z "$WINDOWS_PARTITION" ]] || break
    fi
done
[[ -n "$WINDOWS_PARTITION" ]] || die "could not find a clean Windows NTFS partition"

probe_rc=0
ntfs-3g.probe --readwrite "$WINDOWS_PARTITION" || probe_rc=$?
case "$probe_rc" in
    0) ;;
    14) die "Windows is hibernated/Fast Startup is active; boot it and perform a full shutdown" ;;
    15) die "Windows volume is dirty; boot it and perform a clean full shutdown" ;;
    *) die "NTFS write-safety probe failed (rc=$probe_rc)" ;;
esac
mount -t ntfs-3g -o rw,norecover,big_writes,windows_names \
    -- "$WINDOWS_PARTITION" "$MOUNT_DIR" ||
    die "clean Windows NTFS could not be mounted safely for payload refresh"
MOUNTED=1

GUEST_ROOT="$MOUNT_DIR/ProgramData/VMate/G11"
PUBLIC_DESKTOP="$MOUNT_DIR/Users/Public/Desktop"
[[ -d "$GUEST_ROOT" && ! -L "$GUEST_ROOT" ]] ||
    die "guest VMate G-11 directory is missing or unsafe"
if [[ -e "$PUBLIC_DESKTOP" || -L "$PUBLIC_DESKTOP" ]]; then
    [[ -d "$PUBLIC_DESKTOP" && ! -L "$PUBLIC_DESKTOP" ]] ||
        die "guest Public Desktop is unsafe"
else
    mkdir -p -- "$PUBLIC_DESKTOP"
fi

publish_guest_file "$FIRST_BOOT_SOURCE" \
    "$GUEST_ROOT/Finalize-Clone.ps1" "$FIRST_BOOT_SHA256"
publish_guest_file "$RETRY_SOURCE" \
    "$GUEST_ROOT/Retry-Clone-Initialization.cmd" "$RETRY_SHA256"
publish_guest_file "$RETRY_SOURCE" \
    "$PUBLIC_DESKTOP/Retry-Clone-Initialization.cmd" "$RETRY_SHA256"

GUEST_LITE_DEST="$GUEST_ROOT/GuestLite"
GUEST_LITE_NEW="$GUEST_ROOT/.GuestLite.new.$$.$RANDOM"
GUEST_LITE_OLD="$GUEST_ROOT/.GuestLite.old.$$.$RANDOM"
[[ ! -e "$GUEST_LITE_NEW" && ! -L "$GUEST_LITE_NEW" &&
   ! -e "$GUEST_LITE_OLD" && ! -L "$GUEST_LITE_OLD" ]] ||
    die "guest Guest Lite transaction path already exists"
mkdir -- "$GUEST_LITE_NEW"
cp --reflink=never -- "$PAYLOAD_STAGE"/* "$GUEST_LITE_NEW/"
sync -- "$GUEST_LITE_NEW"/*
verify_guest_lite_dir "$GUEST_LITE_NEW" ||
    die "Guest Lite verification failed after copying into Windows"
GUEST_LITE_HAD_OLD=0
if [[ -e "$GUEST_LITE_DEST" || -L "$GUEST_LITE_DEST" ]]; then
    [[ -d "$GUEST_LITE_DEST" && ! -L "$GUEST_LITE_DEST" ]] ||
        die "existing guest Guest Lite directory is unsafe"
    mv -T -- "$GUEST_LITE_DEST" "$GUEST_LITE_OLD"
    GUEST_LITE_HAD_OLD=1
fi
if ! mv -T -- "$GUEST_LITE_NEW" "$GUEST_LITE_DEST"; then
    ((GUEST_LITE_HAD_OLD == 0)) ||
        mv -T -- "$GUEST_LITE_OLD" "$GUEST_LITE_DEST" >/dev/null 2>&1 || true
    die "could not publish the current Guest Lite payload"
fi
if ! verify_guest_lite_dir "$GUEST_LITE_DEST"; then
    rm -rf -- "$GUEST_LITE_DEST"
    ((GUEST_LITE_HAD_OLD == 0)) ||
        mv -T -- "$GUEST_LITE_OLD" "$GUEST_LITE_DEST" >/dev/null 2>&1 || true
    die "published Guest Lite payload failed verification"
fi
if ((GUEST_LITE_HAD_OLD)); then
    rm -rf -- "$GUEST_LITE_OLD"
fi

for stale_guest_result in \
        "$GUEST_ROOT/clone-initialization.json" \
        "$GUEST_ROOT/clone-initialization-error.txt"; do
    if [[ -e "$stale_guest_result" || -L "$stale_guest_result" ]]; then
        [[ -f "$stale_guest_result" && ! -L "$stale_guest_result" ]] ||
            die "stale guest initialization result is unsafe: $stale_guest_result"
        rm -f -- "$stale_guest_result"
    fi
done
sync
umount -- "$MOUNT_DIR" || die "could not unmount the updated Windows partition"
MOUNTED=0
qemu-nbd --disconnect "$NBD" || die "could not disconnect the updated guest disk"
_NBD_CONNECTED=0
udevadm settle
"$QEMU_IMG" check -q "$DISK"

mv -T -- "$CURRENT_ROOT" "$OLD_ROOT"
ROOT_SWAPPED=1
mv -T -- "$NEW_ROOT" "$CURRENT_ROOT"
NEW_ROOT=""
mv -T -- "$MARKER_TMP" "$REQUIRED_MARKER"
MARKER_TMP=""
COMPLETE=1
rm -rf -- "$OLD_ROOT"
[[ ! -e "$OLD_ROOT" && ! -L "$OLD_ROOT" ]] ||
    die "obsolete package could not be removed: $OLD_ROOT"

cat <<EOF
[g11-init-repair] PASS vm${VM_ID}
  contract: $CONTRACT_ID
  ISO:      $CURRENT_ROOT/$ISO_FILE
  guest:    marker schema 4 / Guest Lite 2.6.4 payload refreshed
  old package: removed (no archive); private base and licensed result retained

下一步只需：
  1. ./deploy/scripts/start-vm.sh ${VM_ID}
  2. 登录 Windows，右键桌面的 Retry-Clone-Initialization.cmd，选择“以管理员身份运行”
  3. 等待内部重启一次并最终完整关机
  4. sudo ./deploy/scripts/initialize-clone.sh ${VM_ID}

本次只替换了来宾用户态初始化脚本/Guest Lite 文件及 VM 绑定 ISO；没有修改 BCD、
驱动、testsigning/nointegritychecks，也没有把任何宿主凭据写入仓库或来宾。
EOF

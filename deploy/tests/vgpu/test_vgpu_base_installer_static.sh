#!/usr/bin/env bash
# Static safety contract for the offline portable-EXE base-image installer.
# This test never invokes qemu-nbd, mounts a filesystem, or opens a real image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INSTALLER="$REPO_ROOT/deploy/install-vgpu-portable-to-base.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle=$1 label=${2:-$1}
    grep -F -- "$needle" "$INSTALLER" >/dev/null ||
        fail "$label is missing"
}

reject_regex() {
    local pattern=$1 label=$2
    if grep -E -- "$pattern" "$INSTALLER" >/dev/null; then
        fail "$label is present"
    fi
}

first_line() {
    local needle=$1
    grep -nF -- "$needle" "$INSTALLER" | head -1 | cut -d: -f1
}

assert_before() {
    local earlier=$1 later=$2 label=$3 earlier_line later_line
    earlier_line=$(first_line "$earlier")
    later_line=$(first_line "$later")
    [[ -n "$earlier_line" && -n "$later_line" ]] ||
        fail "$label cannot be checked because a marker is absent"
    ((earlier_line < later_line)) ||
        fail "$label has unsafe ordering ($earlier_line >= $later_line)"
}

[[ -x "$INSTALLER" ]] || fail "base installer is missing or not executable"
bash -n "$INSTALLER" || fail "base installer has invalid Bash syntax"

# --help is intentionally available without sudo and must not perform storage
# work.  Redirect all roots to an empty fixture as an additional guard.
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
IMAGE_ROOT="$TMP_DIR/images" \
VM_ROOT="$TMP_DIR/images/vms" \
VM_BASE_DIR="$TMP_DIR/images/vms/bases" \
STAGE_DIR="$TMP_DIR/images/staging" \
    "$INSTALLER" --help >"$TMP_DIR/help.out"
grep -Fq -- '--base IMAGE' "$TMP_DIR/help.out" ||
    fail "--help did not describe the base selector"
grep -Fq -- '--base-name NAME' "$TMP_DIR/help.out" ||
    fail "--help did not describe the managed named-base selector"
grep -Fq -- '--gpuz-source FILE' "$TMP_DIR/help.out" ||
    fail "--help did not describe the external GPU-Z source"
grep -Fq -- '--with-gpuz' "$TMP_DIR/help.out" ||
    fail "--help did not describe explicit GPU-Z opt-in"
grep -Fq -- '--single-image' "$TMP_DIR/help.out" ||
    fail "--help did not describe V-11-style single-image publication"
[[ ! -e "$TMP_DIR/images" ]] ||
    fail "--help unexpectedly created storage"
if "$INSTALLER" --base-name '../escape' \
        >"$TMP_DIR/unsafe-name.out" 2>"$TMP_DIR/unsafe-name.err"; then
    fail "installer accepted an unsafe managed base name"
fi
grep -Fq 'invalid base name' "$TMP_DIR/unsafe-name.err" ||
    fail "unsafe managed base-name refusal was not clear"
if "$INSTALLER" --base-name win10-ltsc-v1 --base /tmp/custom.qcow2 \
        >"$TMP_DIR/conflicting-base.out" 2>"$TMP_DIR/conflicting-base.err"; then
    fail "installer accepted both --base-name and --base"
fi
grep -Fq 'cannot be combined' "$TMP_DIR/conflicting-base.err" ||
    fail "conflicting base selectors were not explained"

# The installer is offline and must not alter Windows code-integrity policy.
reject_regex \
    '(^|[^[:alnum:]_])(curl|wget|Invoke-WebRequest|Start-BitsTransfer)([^[:alnum:]_]|$)|https?://' \
    "network download primitive"
reject_regex \
    'testsigning|nointegritychecks|bcdedit|remove_hiberfile|ntfsfix|[,-]force([,[:space:]]|$)' \
    "forbidden BCD/test-signing/forced-NTFS primitive"

# Inputs and the package receipt are fail-closed before any image operation.
require_text '[[ "$BASE" == /* && "$BASE" != / ]]' \
    "absolute non-root base-path gate"
require_text '[[ "$PORTABLE_EXE" == /* && "${PORTABLE_EXE,,}" == *.exe ]]' \
    "absolute EXE-path gate"
require_text '[[ -f "$BASE" && ! -L "$BASE" ]]' \
    "regular non-symlink base gate"
require_text '[[ -f "$PORTABLE_EXE" && ! -L "$PORTABLE_EXE" ]]' \
    "regular non-symlink EXE gate"
require_text 'GPUZ_SOURCE=$(gpuz_asset_resolve_source "$GPUZ_SOURCE")' \
    "regular non-symlink external GPU-Z gate"
require_text '"$GPUZ_BYTES" == "$GPUZ_ASSET_BYTES"' \
    "locked external GPU-Z byte-length gate"
require_text '"$GPUZ_SHA256" == "$GPUZ_ASSET_SHA256"' \
    "locked external GPU-Z hash gate"
require_text 'die "portable EXE has no host content receipt"' \
    "authenticated package-receipt gate"
require_text '.bindingMode == "portable-auto"' \
    "portable-auto receipt binding"
require_text '.schemaVersion == 6 and .bindingMode == "portable-auto"' \
    "unified portable receipt schema"
require_text '.gpuZDelivery == "optional-explicit-sibling"' \
    "optional GPU-Z delivery receipt binding"
require_text '.guestPerformance == "embedded-recommended-native-v1"' \
    "embedded guest performance receipt binding"
require_text '.launcherFormat == "QEMU_VGPU_PORTABLE_UNIFIED_V6"' \
    "unified launcher format binding"
require_text 'GUEST_LITE_MANIFEST_SOURCE="$GUEST_LITE_SOURCE_ROOT/clone-manifest.json"' \
    "Guest Lite clone-manifest source"
require_text 'die '\''Guest Lite manifest is not pinned by the clone finalizer'\''' \
    "Guest Lite finalizer hash pin"
require_text 'verify_guest_lite_dir()' \
    "Guest Lite payload verifier"
reject_regex 'QEMU_GPUZ_PORTABLE_EXE_V1' \
    "legacy embedded portable launcher acceptance"
assert_before \
    '"$GPUZ_SHA256" == "$GPUZ_ASSET_SHA256"' \
    'cp --reflink=auto -- "$BASE" "$BASE_TMP"' \
    "external GPU-Z validation before private base copy"
assert_before \
    '.launcherFormat == "QEMU_VGPU_PORTABLE_UNIFIED_V6"' \
    'cp --reflink=auto -- "$BASE" "$BASE_TMP"' \
    "portable receipt validation before private base copy"
assert_before \
    'Guest Lite manifest is not pinned by the clone finalizer' \
    'cp --reflink=auto -- "$BASE" "$BASE_TMP"' \
    "Guest Lite authentication before private base copy"

# An exclusive global storage lock must be held before inspection/copy.  Every
# normal start/create path holds this inode shared, so a running VM is refused.
require_text 'STORAGE_LOCK_PATH="$VM_RUN_DIR/.storage.lock"' \
    "global storage lock inode"
require_text 'exec {STORAGE_LOCK_FD}<>"$STORAGE_LOCK_PATH"' \
    "global storage lock open"
require_text 'flock -n -x "$STORAGE_LOCK_FD"' \
    "nonblocking exclusive storage lock"
require_text 'global storage lock owner does not match the base-image owner' \
    "storage-owner fail-closed gate"
require_text 'chown "$storage_uid:$storage_gid" "/proc/self/fd/$STORAGE_LOCK_FD"' \
    "root-created lock ownership repair"
require_text 'storage_dirs=("$VM_RUN_DIR")' \
    "single-image-aware storage-directory ownership repair"
require_text '((SINGLE_IMAGE)) || storage_dirs+=("$VM_BASE_ARCHIVE_DIR")' \
    "archive directory is lazy in single-image mode"
require_text 'lsof -t -- "$BASE"' "open-holder check"
assert_before \
    'flock -n -x "$STORAGE_LOCK_FD"' \
    'vm_storage_read_qcow2_metadata "$QEMU_IMG" "$BASE"' \
    "storage lock before qcow2 inspection"
assert_before \
    'flock -n -x "$STORAGE_LOCK_FD"' \
    'cp --reflink=auto -- "$BASE" "$BASE_TMP"' \
    "storage lock before private-copy creation"

# Both the source and edited copy must remain standalone qcow2 images.  The
# managed-tree scan prevents replacing a pathname used by another chain.
require_text 'die "base must be standalone (no backing/data-file)"' \
    "source standalone qcow2 gate"
require_text 'vm_storage_read_qcow2_chain_metadata "$QEMU_IMG" "$image"' \
    "managed backing-chain validation"
require_text 'die "managed image depends on the base pathname: $image"' \
    "managed base dependency refusal"
require_text "! -name '*.vgpu-portable.json' -print0" \
    "owned sidecar exclusion from qcow2 scan"
require_text '"$QEMU_IMG" check -q "$BASE"' "source qemu-img check"
require_text '"$QEMU_IMG" check -q "$BASE_TMP"' "edited-copy qemu-img check"
require_text 'die "edited base unexpectedly gained a backing/data file"' \
    "edited-copy standalone qcow2 gate"

# Only the private copy is attached.  Discovery is read-only; the eventual
# write mount deliberately omits force/remove_hiberfile recovery options.
require_text 'cp --reflink=auto -- "$BASE" "$BASE_TMP"' \
    "private editable base copy"
require_text \
    '"$QEMU_NBD" --connect="$NBD" --format=qcow2 --cache=none "$BASE_TMP"' \
    "explicit-format private-copy NBD attachment"
if grep -E 'qemu-nbd.*(^|[[:space:]"])[$][{]?BASE[}]?("|[[:space:]]|$)' \
        "$INSTALLER" >/dev/null; then
    fail "installer can attach the live base directly"
fi
require_text 'cat "/sys/block/$sys_name/pid"' "kernel NBD occupancy check"
require_text 'findmnt -rn -S "$candidate"' "mounted NBD refusal"
require_text 'mount -t ntfs-3g -o ro -- "$partition" "$MOUNT_DIR"' \
    "read-only Windows partition discovery"
require_text '-d "$MOUNT_DIR/Windows/System32"' \
    "Windows System32 partition marker"
require_text '-d "$MOUNT_DIR/Users/Public"' \
    "Windows Public-profile partition marker"
require_text 'mount -t ntfs-3g -o big_writes,windows_names' \
    "safe Windows NTFS write mount"

# The identity EXE is always verified before/after publication.  GPU-Z uses
# the same gates only inside the explicit WITH_GPUZ branch.
require_text 'sync -- "$PORTABLE_DEST_TMP"' "guest EXE data sync"
require_text 'sync -- "$GPUZ_DEST_TMP"' "external GPU-Z data sync"
require_text '"$(sha256_upper "$PORTABLE_DEST_TMP")" == "$PORTABLE_SHA256"' \
    "pre-publication guest EXE hash check"
require_text '"$(sha256_upper "$GPUZ_DEST_TMP")" == "$GPUZ_SHA256"' \
    "pre-publication external GPU-Z hash check"
require_text 'mv -fT -- "$PORTABLE_DEST_TMP" "$DEST_DIR/VgpuPortable.exe"' \
    "atomic guest EXE publication"
require_text 'mv -fT -- "$GPUZ_DEST_TMP" "$DEST_DIR/GPU-Z.exe"' \
    "atomic external GPU-Z publication"
require_text "sed -i 's/\$/\\r/' \"\$guest_lite_launcher\"" \
    "Windows-safe Guest Lite launcher conversion"
require_text 'for stale_clone_root in \' \
    "fixed stale clone-state cleanup loop"
require_text '"$MOUNT_DIR/ProgramData/G11GuestLite" \' \
    "stale clone-bound Guest Lite cleanup target"
require_text '[[ ! -L "$stale_clone_root" ]]' \
    "stale clone-state symlink rejection"
require_text 'rm -rf -- "$stale_clone_root"' \
    "stale clone-bound state removal"
require_text 'cp --reflink=never -- "$GUEST_LITE_STAGE"/* "$GUEST_LITE_DEST/"' \
    "Guest Lite payload publication"
require_text 'verify_guest_lite_dir "$GUEST_LITE_DEST"' \
    "published Guest Lite payload verification"
require_text '"$(sha256_upper "$DEST_DIR/VgpuPortable.exe")" == "$PORTABLE_SHA256"' \
    "post-publication guest EXE hash check"
require_text '"$(sha256_upper "$DEST_DIR/GPU-Z.exe")" == "$GPUZ_SHA256"' \
    "post-publication external GPU-Z hash check"

# Cleanup has to unmount/disconnect and restore the archived original if the
# base pathname is absent.  Final publication uses same-filesystem renames.
require_text '"$QEMU_NBD" --disconnect "$NBD"' "NBD disconnect"
require_text 'rm -f -- "${BASE_TMP:-}"' "private-copy cleanup"
require_text 'local cleanup_safe=1' "fail-closed cleanup state"
require_text 'if umount -- "$MOUNT_DIR"; then' \
    "checked cleanup unmount"
require_text 'findmnt -rn -M "$MOUNT_DIR"' \
    "post-unmount mountpoint verification"
require_text 'if ((cleanup_safe && NBD_CONNECTED)); then' \
    "NBD disconnect gated by safe unmount"
require_text 'if ((cleanup_safe)); then' \
    "work-file deletion gated by safe cleanup"
require_text 'cleanup stopped safely; private work files were preserved' \
    "unsafe-cleanup preservation notice"
assert_before \
    'findmnt -rn -M "$MOUNT_DIR"' \
    'rm -rf -- "${WORK_ROOT:-}"' \
    "mountpoint verification before recursive cleanup"
require_text 'if ((cleanup_safe && ! PUBLICATION_COMPLETE)); then' \
    "incomplete-publication rollback gate"
require_text 'mv -T -- "$BASE_BACKUP" "$BASE" || true' \
    "archived-base rollback"
require_text 'BASE_BACKUP_ATTESTATION="${BASE_BACKUP}.vgpu-portable.json"' \
    "archived sidecar path"
require_text 'mv -T -- "$ATTESTATION" "$BASE_BACKUP_ATTESTATION"' \
    "old-sidecar archival rename"
require_text 'if mv -T -- "$BASE_BACKUP_ATTESTATION" "$ATTESTATION"; then' \
    "old-sidecar rollback"
require_text 'base and archive directory must be on the same filesystem' \
    "same-filesystem publication gate"
require_text 'mv -T -- "$BASE" "$BASE_BACKUP"' "original-base archival rename"
require_text 'mv -T -- "$BASE_TMP" "$BASE"' "new-base atomic rename"
require_text 'atomic base publication failed' "base publication rollback error"

# Clone-side attestation binds the identity EXE, the optional inclusion state,
# the catalog, and a concrete base generation.  The fixture test covers both
# false/null and explicit true/exact GPU-Z states.
for key in schemaVersion bindingMode basePath baseFileBytes baseDeviceId \
        baseInode baseMtimeNs baseCtimeNs portableGuestPath portableSha256 \
        portableBytes gpuZDelivery gpuZIncluded gpuZGuestPath gpuZSha256 gpuZBytes \
        guestPerformance \
        catalogSha256 installedUtc; do
    require_text "$key" "sidecar field $key"
done
require_text '[[ "$CATALOG_SHA256" == "$EXPECTED_CATALOG_SHA256" ]]' \
    "current-catalog package gate"
require_text '.schemaVersion == 5' "generation-bound unified sidecar schema"
require_text 'mv -fT -- "$ATTESTATION_TMP" "$ATTESTATION"' \
    "atomic sidecar publication"
require_text 'die "published base attestation failed verification"' \
    "published-sidecar verification"
require_text 'PUBLICATION_COMPLETE=1' \
    "base-and-sidecar transaction commit marker"
require_text 'temporary rollback deleted after full verification' \
    "single-image successful rollback disposal"
require_text 'temporary rollback generation changed; refusing to discard it' \
    "single-image rollback generation proof"
assert_before \
    'PUBLICATION_COMPLETE=1' \
    'rm -- "$BASE_BACKUP"' \
    "valid new generation commit before old rollback unlink"

# A successful prior installation leaves sidecars whose names also match the
# broad *.qcow2.* backup pattern.  Prove the intentionally narrow exclusion
# still scans real qcow2/backup names while allowing installer re-runs.
SCAN_FIXTURE="$TMP_DIR/scan"
mkdir -p "$SCAN_FIXTURE"
touch "$SCAN_FIXTURE/base.qcow2" \
    "$SCAN_FIXTURE/base.qcow2.pre-update" \
    "$SCAN_FIXTURE/base.qcow2.vgpu-portable.json"
mapfile -d '' -t scan_results < <(
    find -L "$SCAN_FIXTURE" \( -type f -o -type l \) \
        \( -name '*.qcow2' -o -name '*.qcow2.*' \) \
        ! -name '*.vgpu-portable.json' -print0
)
[[ ${#scan_results[@]} -eq 2 ]] ||
    fail "owned sidecar exclusion did not leave exactly two qcow2 candidates"
for candidate in "${scan_results[@]}"; do
    [[ "$candidate" != *.vgpu-portable.json ]] ||
        fail "owned portable sidecar leaked into qcow2 scan"
done

# Renaming the original base to/from the archive changes ctime.  Rollback may
# refresh that one field only after proving the restored inode/generation via
# device, inode, size and mtime; otherwise the old sidecar stays archived.
for field in ORIGINAL_BASE_FILE_BYTES ORIGINAL_BASE_DEVICE_ID \
        ORIGINAL_BASE_INODE ORIGINAL_BASE_MTIME_NS; do
    require_text "$field" "original generation proof field $field"
done
require_text 'refresh_restored_attestation_ctime()' \
    "rollback ctime refresh helper"
require_text '.baseCtimeNs = $baseCtimeNs' \
    "rollback ctime rewrite"
require_text 'valid schema-2..5 public or schema-6/7 private generation' \
    "legacy/new rollback attestation compatibility"
require_text '.schemaVersion == 7 and' \
    "current private Sysprep attestation schema"
require_text '.systemNvapiRequired == true' \
    "current private base requires per-VM system NVAPI"
require_text 'mv -fT -- "$refresh_tmp" "$ATTESTATION"' \
    "atomic refreshed-sidecar publication"
require_text 'if ((ATTESTATION_MOVED && restored_original))' \
    "old-sidecar restore generation proof"
require_text \
    'rollback could not prove the original base was restored; its sidecar remains archived' \
    "unproven rollback fail-closed notice"

echo "PASS: portable base installer has offline, lock, qcow2/NBD/NTFS, rollback and attestation gates"

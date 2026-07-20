#!/usr/bin/env bash
# Verify the production-driver staged receipt from a stopped Windows disk, then
# and only then atomically migrate vm.conf from legacy A to B/native DEV_1E30.
#
# This script never starts/stops a VM and never writes the Windows disk or BCD.
set -euo pipefail
umask 077
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"

usage() {
    cat >&2 <<'EOF'
usage: sudo ./deploy/commit-vgpu-production-migration.sh VM_ID [options]

Options:
  --output-root DIR   Package root used by the builder
  --receipt-file FILE Verify an explicitly copied staged receipt
                      (--check-only recovery/testing only; cannot commit)
  --check-only        Verify all gates without changing vm.conf
  -h, --help          Show this help

Default operation mounts the stopped qcow2 read-only, verifies the protected
ProgramData staged receipt, unmounts/disconnects it, and only then changes the
host config.  No Windows/BCD bytes are written.
EOF
}

die() { echo "[vgpu-production-commit] ERROR: $*" >&2; exit 1; }
log() { echo "[vgpu-production-commit] $*"; }
sha256_upper() { sha256sum -- "$1" | awk '{print toupper($1)}'; }

VM_ID=""
OUTPUT_ROOT=""
RECEIPT_FILE=""
CHECK_ONLY=0
while (($#)); do
    case "$1" in
        --output-root) OUTPUT_ROOT=${2:-}; shift 2 ;;
        --receipt-file) RECEIPT_FILE=${2:-}; shift 2 ;;
        --check-only) CHECK_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            if vm_storage_id_is_supported "$1" && [[ -z "$VM_ID" ]]; then
                VM_ID=$1
                shift
            else
                die "unknown argument or invalid VM ID: $1"
            fi
            ;;
    esac
done
[[ -n "$VM_ID" ]] || { usage; exit 2; }
if [[ -n "$RECEIPT_FILE" && "$CHECK_ONLY" != 1 ]]; then
    die "--receipt-file is check-only; a real commit must read the stopped disk"
fi
for dependency in jq sha256sum stat realpath awk install flock pgrep grep; do
    command -v "$dependency" >/dev/null 2>&1 \
        || die "missing dependency: $dependency"
done

vm_storage_init
CONF=$(vm_storage_config_path "$VM_ID")
DISK=$(vm_storage_disk_path "$VM_ID")
INSTANCE_DIR=$(vm_storage_instance_dir "$VM_ID")
[[ -f "$CONF" && ! -L "$CONF" && -r "$CONF" ]] \
    || die "VM config is not a readable regular file"
[[ -f "$DISK" && ! -L "$DISK" ]] \
    || die "VM disk is missing or unsafe"

# Hold the same cooperative lifecycle locks as start-vm/create-vm for the
# entire stopped-disk proof and config commit.  This closes the gap in which a
# VM could otherwise start after the process check or another tool could touch
# its qcow2 while it is attached read-only through NBD.
[[ ! -L "$VM_RUN_DIR" &&
   ( ! -e "$VM_RUN_DIR" || -d "$VM_RUN_DIR" ) ]] \
    || die "VM runtime root is unsafe"
mkdir -p -- "$VM_RUN_DIR"
exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -s "$STORAGE_LOCK_FD"
START_LOCK=$(vm_storage_run_path "$VM_ID" start.lock)
DISK_LOCK=$(vm_storage_run_path "$VM_ID" disk.lock)
exec {START_LOCK_FD}>"$START_LOCK"
flock -n "$START_LOCK_FD" \
    || die "vm${VM_ID} start lock is busy; perform a full stop first"
exec {DISK_LOCK_FD}>"$DISK_LOCK"
flock -n -x "$DISK_LOCK_FD" \
    || die "vm${VM_ID} disk lifecycle lock is busy"

OUTPUT_ROOT=${OUTPUT_ROOT:-"$STAGE_DIR/VgpuProductionMigration"}
OUTPUT_ROOT=$(realpath -m -- "$OUTPUT_ROOT")

REQUESTED_VM_ID=$VM_ID
unset VM_ID VM_UUID GPU_PROFILE GPU_NAME SPOOF_MODE
# shellcheck source=/dev/null
source "$CONF"
CONFIG_VM_ID=${VM_ID:-}
VM_ID=$REQUESTED_VM_ID
[[ "$CONFIG_VM_ID" == "$VM_ID" ]] || die "vm.conf VM_ID mismatch"
[[ "${VM_UUID:-}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || die "vm.conf VM_UUID is invalid"
[[ -n "${GPU_PROFILE:-}" && -n "${GPU_NAME:-}" ]] \
    || die "vm.conf GPU profile/name is incomplete"
[[ "${SPOOF_MODE:-}" == A ]] \
    || die "vm.conf is not the legacy A source captured by this migration"
UUID_LOWER=${VM_UUID,,}
PACKAGE_DIR="$OUTPUT_ROOT/vm${VM_ID}-${UUID_LOWER}"
STATE="$PACKAGE_DIR/host-state.json"
CONTRACT="$PACKAGE_DIR/migration-contract.json"
EXE="$PACKAGE_DIR/VgpuProductionMigration.exe"
for file in "$STATE" "$CONTRACT" "$EXE"; do
    [[ -f "$file" && ! -L "$file" ]] \
        || die "package state is missing or unsafe: $file"
done

jq -e \
    --argjson vmId "$VM_ID" \
    --arg vmUuid "$UUID_LOWER" \
    --arg gpuProfile "$GPU_PROFILE" \
    --arg gpuName "$GPU_NAME" '
    (keys | sort) == [
        "archiveSha256", "exeBytes", "exeSha256", "gpuName", "gpuProfile",
        "guestContractSha256", "migrationId", "requiredHostModeAfterReceipt",
        "schemaVersion", "sourceCatalogSha256", "sourceConfigSha256",
        "sourceHostMode", "sourceInfSha256", "vmId", "vmUuid"
    ] and
    .schemaVersion == 1 and .vmId == $vmId and
    .vmUuid == $vmUuid and .gpuProfile == $gpuProfile and
    .gpuName == $gpuName and .sourceHostMode == "A" and
    .requiredHostModeAfterReceipt == "B" and
    (.migrationId | test("^[0-9A-F]{32}$")) and
    (.sourceConfigSha256 | test("^[0-9A-F]{64}$")) and
    (.guestContractSha256 | test("^[0-9A-F]{64}$")) and
    (.exeSha256 | test("^[0-9A-F]{64}$")) and
    (.exeBytes | type == "number" and . > 268435456) and
    .archiveSha256 ==
      "A3D7AD8B8082D6AC6214565B4766B5190A819BC9B7574765B14897E0DB809690" and
    .sourceInfSha256 ==
      "67A240E1D464CF97DABFEC1A7CECF000EAA9DDFD702F32BA2C8771F17905DC2B" and
    .sourceCatalogSha256 ==
      "56B07BD93280BBDA761CB5C9A3A13262C3605320D7286953989E2A5B16D5EC6F"
' "$STATE" >/dev/null || die "host package state is invalid"
MIGRATION_ID=$(jq -er .migrationId "$STATE")
EXPECTED_CONFIG_SHA=$(jq -er .sourceConfigSha256 "$STATE")
CONTRACT_SHA=$(jq -er .guestContractSha256 "$STATE")
EXE_SHA=$(jq -er .exeSha256 "$STATE")
EXE_BYTES=$(jq -er .exeBytes "$STATE")
[[ "$(sha256_upper "$CONF")" == "$EXPECTED_CONFIG_SHA" ]] \
    || die "vm.conf changed after the migration EXE was built; rebuild first"
[[ "$(sha256_upper "$CONTRACT")" == "$CONTRACT_SHA" ]] \
    || die "guest contract hash does not match host state"
[[ "$(sha256_upper "$EXE")" == "$EXE_SHA" &&
   "$(stat -c %s -- "$EXE")" == "$EXE_BYTES" ]] \
    || die "migration EXE does not match host state"

VM_PATTERN="qemu-system-x86_64.*-name[[:space:]]+vm${VM_ID}([,[:space:]]|$)"
if pgrep -f "$VM_PATTERN" >/dev/null 2>&1 ||
   pgrep -af qemu-system-x86_64 2>/dev/null |
       grep -F -- "$DISK" >/dev/null; then
    die "vm${VM_ID} is running; receipt consumption requires a full stop"
fi

receipt_snapshot=$(mktemp)
cleanup_receipt() { rm -f -- "$receipt_snapshot"; }
trap cleanup_receipt EXIT

if [[ -n "$RECEIPT_FILE" ]]; then
    RECEIPT_FILE=$(realpath -e -- "$RECEIPT_FILE") \
        || die "receipt file does not exist"
    [[ -f "$RECEIPT_FILE" && ! -L "$RECEIPT_FILE" ]] \
        || die "receipt file is unsafe"
    install -m 0600 -- "$RECEIPT_FILE" "$receipt_snapshot"
    log "using explicitly copied receipt (offline-disk verification was bypassed)"
else
    [[ $EUID -eq 0 ]] \
        || die "default stopped-disk receipt verification requires root"
    for dependency in qemu-nbd ntfs-3g.probe mount umount blkid modprobe \
            udevadm; do
        command -v "$dependency" >/dev/null 2>&1 \
            || die "missing stopped-disk dependency: $dependency"
    done
    # shellcheck source=lib/nbd-lock.sh
    source "$here/lib/nbd-lock.sh"
    _NBD_PINNED="${NBD:+1}"
    NBD="${NBD:-/dev/nbd0}"
    modprobe nbd max_part=16 2>/dev/null || true
    mount_point=$(mktemp -d "/tmp/vgpu-production-vm${VM_ID}.XXXXXXXX")
    mounted=0
    cleanup_disk() {
        local rc=$?
        if ((mounted)); then
            umount "$mount_point" 2>/dev/null || rc=70
            mounted=0
        fi
        nbd_disconnect_if_owned
        rmdir "$mount_point" 2>/dev/null || true
        return "$rc"
    }
    trap 'cleanup_disk; cleanup_receipt' EXIT
    # qemu-nbd's temporary external snapshot absorbs even hypothetical probe
    # writes.  The Windows qcow2 is therefore never exported writable.
    nbd_connect NBD "$DISK" snapshot
    udevadm settle --timeout=10
    windows_partition=""
    for partition in "${NBD}p3" "${NBD}p4" "${NBD}p2" \
            "${NBD}p1" "${NBD}p5"; do
        [[ -b "$partition" ]] || continue
        [[ "$(blkid -o value -s TYPE "$partition" 2>/dev/null)" == ntfs ]] \
            || continue
        if mount -t ntfs-3g -o ro,norecover "$partition" \
                "$mount_point" 2>/dev/null; then
            mounted=1
            if [[ -f "$mount_point/Windows/System32/config/SYSTEM" ]]; then
                windows_partition=$partition
                umount "$mount_point" \
                    || die "could not unmount Windows partition probe"
                mounted=0
                break
            fi
            umount "$mount_point" || die "could not unmount NTFS probe"
            mounted=0
        fi
    done
    [[ -n "$windows_partition" ]] \
        || die "Windows system partition was not found"
    probe_rc=0
    ntfs-3g.probe --readwrite "$windows_partition" || probe_rc=$?
    case "$probe_rc" in
        0) ;;
        14) die "Windows is hibernated/Fast Startup is active; perform a full shutdown" ;;
        15) die "Windows volume is dirty; boot and perform a clean full shutdown" ;;
        *) die "NTFS clean-shutdown probe failed (rc=$probe_rc)" ;;
    esac
    mount -t ntfs-3g -o ro,norecover "$windows_partition" "$mount_point" \
        || die "could not mount the clean Windows partition read-only"
    mounted=1
    guest_receipt="$mount_point/ProgramData/QemuVgpuProductionMigration/receipts/vm${VM_ID}-${MIGRATION_ID}-staged.json"
    [[ -f "$guest_receipt" && ! -L "$guest_receipt" ]] \
        || die "protected staged receipt is missing from the stopped guest"
    install -m 0600 -- "$guest_receipt" "$receipt_snapshot"
    umount "$mount_point" || die "could not unmount stopped guest disk"
    mounted=0
    nbd_disconnect_if_owned
    log "copied staged receipt from the stopped disk; disk stayed read-only"
fi

jq -e \
    --arg migrationId "$MIGRATION_ID" \
    --argjson vmId "$VM_ID" \
    --arg vmUuid "$UUID_LOWER" \
    --arg gpuProfile "$GPU_PROFILE" \
    --arg gpuName "$GPU_NAME" '
    (keys | sort) == [
        "activeDriverChanged", "activeInfAfter", "activeInfBefore",
        "archiveBytes", "archiveSha256", "bcdAfterSha256",
        "bcdBeforeSha256", "bcdChanged", "catalogSigner",
        "catalogSignerThumbprint", "completedUtc", "displayInstanceBefore",
        "driverStoreCatalogSha256",
        "driverStoreInfSha256", "driverVersion", "gpuName", "gpuProfile",
        "migrationId", "nativePnpId", "nextHostMode", "nointegritychecks",
        "phase", "publishedInf", "schemaVersion", "sourceCatalogSha256",
        "sourceInfSha256", "testsigning", "vmId", "vmUuid"
    ] and
    .schemaVersion == 1 and .phase == "staged" and
    .migrationId == $migrationId and .vmId == $vmId and
    .vmUuid == $vmUuid and .gpuProfile == $gpuProfile and
    .gpuName == $gpuName and .nextHostMode == "B" and
    .nativePnpId == "PCI\\VEN_10DE&DEV_1E30" and
    .driverVersion == "31.0.15.3833" and
    .archiveBytes == 860703853 and
    .archiveSha256 ==
      "A3D7AD8B8082D6AC6214565B4766B5190A819BC9B7574765B14897E0DB809690" and
    .sourceInfSha256 ==
      "67A240E1D464CF97DABFEC1A7CECF000EAA9DDFD702F32BA2C8771F17905DC2B" and
    .sourceCatalogSha256 ==
      "56B07BD93280BBDA761CB5C9A3A13262C3605320D7286953989E2A5B16D5EC6F" and
    .driverStoreInfSha256 == .sourceInfSha256 and
    .driverStoreCatalogSha256 == .sourceCatalogSha256 and
    (.publishedInf | test("^oem[0-9]+\\.inf$")) and
    (.catalogSigner | test("^CN=(NVIDIA( Corporation)?|Microsoft Windows Hardware Compatibility Publisher)(,|$)")) and
    (.catalogSignerThumbprint | test("^[0-9A-F]{40,64}$")) and
    (.activeInfBefore | test("^oem[0-9]+\\.inf$")) and
    .activeInfAfter == .activeInfBefore and
    (.bcdBeforeSha256 | test("^[0-9A-F]{64}$")) and
    .bcdAfterSha256 == .bcdBeforeSha256 and
    .testsigning == false and .nointegritychecks == false and
    .activeDriverChanged == false and .bcdChanged == false
' "$receipt_snapshot" >/dev/null \
    || die "staged receipt does not satisfy the production-only contract"
PUBLISHED_INF=$(jq -er .publishedInf "$receipt_snapshot")
log "receipt PASS: $PUBLISHED_INF is exact original INF/CAT; BCD off/unchanged"

[[ "$(sha256_upper "$CONF")" == "$EXPECTED_CONFIG_SHA" ]] \
    || die "vm.conf changed while the receipt was being verified"
if ((CHECK_ONLY)); then
    log "check-only PASS; vm.conf was not changed"
    exit 0
fi

target_config_valid() {
    local file=$1 expected_line
    [[ -f "$file" && ! -L "$file" ]] || return 1
    for expected_line in \
            'SPOOF_MODE=B' \
            'VGPU_IDENTITY_TARGET=name-only' \
            "VGPU_PRODUCTION_MIGRATION_ID=${MIGRATION_ID}" \
            'VGPU_PRODUCTION_DRIVER_VERSION=31.0.15.3833' \
            'VGPU_PRODUCTION_DRIVER_INF_SHA256=67A240E1D464CF97DABFEC1A7CECF000EAA9DDFD702F32BA2C8771F17905DC2B' \
            'VGPU_PRODUCTION_DRIVER_CATALOG_SHA256=56B07BD93280BBDA761CB5C9A3A13262C3605320D7286953989E2A5B16D5EC6F'; do
        grep -Fxq "$expected_line" "$file" || return 1
    done
    ! grep -Eq \
        '^[[:space:]]*(export[[:space:]]+)?(SPOOF=|SPOOF_MODE=A|VGPU_MDEV_INTERNAL_PCI_IDENTITY=1|VGPU_MDEV_FRL_ENABLED=|VGPU_PATCHED_DRIVER_(INF|VERSION|REQUIRED_VERSION)=)' \
        "$file"
}

backup_dir="$INSTANCE_DIR/backups/production-migration"
mkdir -p "$backup_dir"
chmod 0700 "$backup_dir"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
config_backup="$backup_dir/vm.conf.before-B-${timestamp}-${MIGRATION_ID}"
receipt_backup="$backup_dir/staged-${MIGRATION_ID}.json"
config_mode=$(stat -c %a -- "$CONF")
config_uid=$(stat -c %u -- "$CONF")
config_gid=$(stat -c %g -- "$CONF")
install -m 0400 -- "$CONF" "$config_backup"
install -m 0400 -- "$receipt_snapshot" "$receipt_backup"
config_tmp="$(dirname -- "$CONF")/.$(basename -- "$CONF").production.$$.$RANDOM"
restore_tmp="$(dirname -- "$CONF")/.$(basename -- "$CONF").restore.$$.$RANDOM"
cleanup_config() { rm -f -- "$config_tmp" "$restore_tmp"; }
trap 'cleanup_config; cleanup_receipt' EXIT
awk '
    !/^[[:space:]]*(export[[:space:]]+)?(SPOOF|SPOOF_MODE|VGPU_IDENTITY_TARGET|VGPU_MDEV_INTERNAL_PCI_IDENTITY|VGPU_MDEV_FRL_ENABLED|VGPU_PATCHED_DRIVER_INF|VGPU_PATCHED_DRIVER_VERSION|VGPU_PATCHED_DRIVER_REQUIRED_VERSION|VGPU_PRODUCTION_MIGRATION_ID|VGPU_PRODUCTION_DRIVER_VERSION|VGPU_PRODUCTION_DRIVER_INF_SHA256|VGPU_PRODUCTION_DRIVER_CATALOG_SHA256)=/
' "$CONF" >"$config_tmp"
cat >>"$config_tmp" <<EOF

# Production migration ${MIGRATION_ID}; staged guest receipt verified offline.
SPOOF_MODE=B
VGPU_IDENTITY_TARGET=name-only
VGPU_PRODUCTION_MIGRATION_ID=${MIGRATION_ID}
VGPU_PRODUCTION_DRIVER_VERSION=31.0.15.3833
VGPU_PRODUCTION_DRIVER_INF_SHA256=67A240E1D464CF97DABFEC1A7CECF000EAA9DDFD702F32BA2C8771F17905DC2B
VGPU_PRODUCTION_DRIVER_CATALOG_SHA256=56B07BD93280BBDA761CB5C9A3A13262C3605320D7286953989E2A5B16D5EC6F
EOF
chmod --reference="$CONF" "$config_tmp"
chown --reference="$CONF" "$config_tmp" 2>/dev/null || true
target_config_valid "$config_tmp" \
    || die "refusing to commit an invalid generated B config"
mv -T -- "$config_tmp" "$CONF"
if ! target_config_valid "$CONF"; then
    if install -m "$config_mode" -- "$config_backup" "$restore_tmp" &&
       chown "$config_uid:$config_gid" "$restore_tmp" &&
       mv -T -- "$restore_tmp" "$CONF" &&
       [[ "$(sha256_upper "$CONF")" == "$EXPECTED_CONFIG_SHA" ]]; then
        die "post-commit assertion failed; original vm.conf was atomically restored"
    fi
    die "CRITICAL: B config assertion and automatic vm.conf restore both failed"
fi
trap cleanup_receipt EXIT

log "COMMIT PASS: vm${VM_ID} is now B/native DEV_1E30"
log "config backup: $config_backup"
log "receipt backup: $receipt_backup"
log "next: start vm${VM_ID} normally; the installed guest continuation binds and verifies the exact official package"

#!/usr/bin/env bash
# Build one VM-bound, single-file guest migration from a legacy consumer-ID
# vGPU to B/native DEV_1E30 plus the exact original GRID 538.33 package.
#
# This is build-only.  It never starts/stops a VM, edits vm.conf, mounts a
# guest disk, changes BCD, or installs a driver.
set -euo pipefail
umask 077
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
# shellcheck source=lib/vgpu-driver-assets.sh
source "$here/lib/vgpu-driver-assets.sh"
# shellcheck source=lib/gpuz-assets.sh
source "$here/lib/gpuz-assets.sh"

usage() {
    cat >&2 <<'EOF'
usage: ./deploy/package-vgpu-production-migration.sh VM_ID [options]

Options:
  --driver-zip FILE.zip  Original GRID 538.33 Display.Driver archive
                         (default: $STAGE_DIR/553.24-display-driver.zip)
  --output-root DIR      Private output root
                         (default: $STAGE_DIR/VgpuProductionMigration)
  --gpuz-source FILE     Host GPU-Z 2.70.0 executable embedded in the nested
                         profile package (default: $IMAGE_ROOT/candidates/
                         gpuz-2.70-audit/GPU-Z.2.70.0.exe)
  --replace              Replace an existing package only if its EXE has
                         never been run in the guest
  -h, --help             Show this help

Output:
  DIR/vmN-UUID/VgpuProductionMigration.exe

The EXE is large because it embeds the locked 821 MiB original vendor archive
without modifying or recompressing it.  Copy that one EXE to its matching VM
and run it once as Administrator.
EOF
}

die() { echo "[vgpu-production-package] ERROR: $*" >&2; exit 1; }
log() { echo "[vgpu-production-package] $*"; }
sha256_upper() { sha256sum -- "$1" | awk '{print toupper($1)}'; }

VM_ID=""
DRIVER_ZIP=""
OUTPUT_ROOT=""
GPUZ_SOURCE=""
REPLACE=0
while (($#)); do
    case "$1" in
        --driver-zip)
            (($# >= 2)) || die "--driver-zip requires a host ZIP file"
            DRIVER_ZIP=$2
            shift 2
            ;;
        --output-root)
            (($# >= 2)) || die "--output-root requires a path"
            OUTPUT_ROOT=$2
            shift 2
            ;;
        --gpuz-source)
            (($# >= 2)) || die "--gpuz-source requires a host file"
            GPUZ_SOURCE=$2
            shift 2
            ;;
        --replace) REPLACE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            if vm_storage_id_is_supported "$1" && [[ -z "$VM_ID" ]]; then
                VM_ID=$1
                shift
            else
                die "unknown argument or unsupported VM_ID (expected 1..2147483647): $1"
            fi
            ;;
    esac
done
[[ -n "$VM_ID" ]] || { usage; exit 2; }
for dependency in jq sha256sum stat realpath mktemp install awk od tr \
        unzip flock python3 x86_64-w64-mingw32-gcc \
        x86_64-w64-mingw32-windres; do
    command -v "$dependency" >/dev/null 2>&1 \
        || die "missing dependency: $dependency"
done
vm_storage_init
vm_storage_require_namespace_ready "$VM_ID" \
    || die "VM storage still uses an old/conflicting layout"
if [[ -z "$GPUZ_SOURCE" ]]; then
    GPUZ_SOURCE=$(gpuz_asset_default_source) \
        || die "could not derive the canonical GPU-Z source"
fi
GPUZ_SOURCE=$(gpuz_asset_resolve_source "$GPUZ_SOURCE") \
    || die "invalid --gpuz-source"
CONF=$(vm_storage_config_path "$VM_ID")
DISK=$(vm_storage_disk_path "$VM_ID")
[[ -f "$CONF" && ! -L "$CONF" && -r "$CONF" ]] \
    || die "VM config is not a readable regular file: $CONF"
[[ -f "$DISK" && ! -L "$DISK" ]] \
    || die "VM disk is missing or unsafe: $DISK"
CONFIG_SHA256=$(sha256_upper "$CONF")

DRIVER_ZIP=${DRIVER_ZIP:-"$STAGE_DIR/$VGPU_DRIVER_ZIP_NAME"}
DRIVER_ZIP=$(realpath -e -- "$DRIVER_ZIP") \
    || die "driver ZIP does not exist"
[[ -f "$DRIVER_ZIP" && ! -L "$DRIVER_ZIP" ]] \
    || die "driver ZIP is not a regular file"
vgpu_verify_driver_asset "$DRIVER_ZIP" "$VGPU_DRIVER_ZIP_SHA256" \
    || die "refusing a non-locked driver archive"
[[ "$(stat -c %s -- "$DRIVER_ZIP")" == 860703853 ]] \
    || die "locked driver archive byte count changed"
SOURCE_INF_SHA=$(
    unzip -p "$DRIVER_ZIP" Display.Driver/nvgridsw.inf |
        sha256sum | awk '{print toupper($1)}'
)
SOURCE_CAT_SHA=$(
    unzip -p "$DRIVER_ZIP" Display.Driver/nvgridsw.cat |
        sha256sum | awk '{print toupper($1)}'
)
[[ "$SOURCE_INF_SHA" == \
   67A240E1D464CF97DABFEC1A7CECF000EAA9DDFD702F32BA2C8771F17905DC2B &&
   "$SOURCE_CAT_SHA" == \
   56B07BD93280BBDA761CB5C9A3A13262C3605320D7286953989E2A5B16D5EC6F ]] \
    || die "locked archive no longer contains the reviewed original INF/catalog"

REQUESTED_VM_ID=$VM_ID
unset VM_ID VM_UUID GPU_PROFILE GPU_NAME GPU_PCI_VID GPU_PCI_DID \
    GPU_SUB_VID GPU_SUB_DID VGPU_MDEV_PROFILE SPOOF_MODE \
    GPUZ_PACKAGE_ENABLED
# shellcheck source=/dev/null
source "$CONF"
CONFIG_VM_ID=${VM_ID:-}
VM_ID=$REQUESTED_VM_ID
[[ "$CONFIG_VM_ID" == "$VM_ID" ]] \
    || die "VM_ID in config does not match requested vm${VM_ID}"
[[ "${VM_UUID:-}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || die "VM_UUID is missing or invalid"
[[ -n "${GPU_PROFILE:-}" ]] || die "GPU_PROFILE is missing"
configured_profile=$GPU_PROFILE
configured_name=${GPU_NAME:-}
configured_vid=${GPU_PCI_VID:-}
configured_did=${GPU_PCI_DID:-}
configured_subvid=${GPU_SUB_VID:-}
configured_subdid=${GPU_SUB_DID:-}
configured_mdev=${VGPU_MDEV_PROFILE:-}
configured_mode=${SPOOF_MODE:-B}

if [[ -n "${VGPU_PACKAGE_DISPATCH_CONFIG_SHA256:-}" ||
      -n "${VGPU_PACKAGE_DISPATCH_SPOOF_MODE:-}" ]]; then
    [[ "${VGPU_PACKAGE_DISPATCH_CONFIG_SHA256:-}" =~ ^[0-9A-F]{64}$ &&
       "${VGPU_PACKAGE_DISPATCH_SPOOF_MODE:-}" =~ ^(A|B)$ ]] \
        || die "invalid one-click dispatch constraint"
    [[ "$CONFIG_SHA256" == "$VGPU_PACKAGE_DISPATCH_CONFIG_SHA256" &&
       "$configured_mode" == "$VGPU_PACKAGE_DISPATCH_SPOOF_MODE" ]] \
        || die "VM config changed after one-click mode selection; rerun the one-click packager"
fi
unset VGPU_PACKAGE_DISPATCH_CONFIG_SHA256 \
    VGPU_PACKAGE_DISPATCH_SPOOF_MODE

vgpu_profile_validate_catalog || die "GPU profile catalog is invalid"
vgpu_profile_load "$configured_profile" \
    || die "unsupported GPU profile: $configured_profile"
[[ -z "$configured_name" || "$configured_name" == "$GPU_NAME" ]] \
    || die "configured GPU_NAME conflicts with catalog"
[[ -z "$configured_mdev" || "$configured_mdev" == "$VGPU_MDEV_PROFILE" ]] \
    || die "configured VGPU_MDEV_PROFILE conflicts with catalog"
for tuple in \
        "$configured_vid|$GPU_PCI_VID|GPU_PCI_VID" \
        "$configured_did|$GPU_PCI_DID|GPU_PCI_DID" \
        "$configured_subvid|$GPU_SUB_VID|GPU_SUB_VID" \
        "$configured_subdid|$GPU_SUB_DID|GPU_SUB_DID"; do
    IFS='|' read -r actual expected label <<<"$tuple"
    [[ -z "$actual" || "$actual" == "$expected" ]] \
        || die "$label conflicts with catalog profile $configured_profile"
done
case "$configured_mode" in
    A|B|off) ;;
    *) die "SPOOF_MODE must be A, B or off" ;;
esac
[[ "$configured_mode" == A ]] \
    || die "this stopped-receipt migrator requires a legacy A source VM"

did_hex=${GPU_PCI_DID#0x}
subvid_hex=${GPU_SUB_VID#0x}
subdid_hex=${GPU_SUB_DID#0x}
LEGACY_PNP="PCI\\VEN_10DE&DEV_${did_hex^^}&SUBSYS_${subdid_hex^^}${subvid_hex^^}"
UUID_LOWER=${VM_UUID,,}
UUID_UPPER=${VM_UUID^^}
MIGRATION_ID=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | tr a-f A-F)
[[ "$MIGRATION_ID" =~ ^[0-9A-F]{32}$ ]] \
    || die "could not generate migration ID"

OUTPUT_ROOT=${OUTPUT_ROOT:-"$STAGE_DIR/VgpuProductionMigration"}
[[ "$OUTPUT_ROOT" == /* && "$OUTPUT_ROOT" != / ]] \
    || die "--output-root must be a non-root absolute path"
OUTPUT_ROOT=$(realpath -m -- "$OUTPUT_ROOT")
OUTPUT_DIR="$OUTPUT_ROOT/vm${VM_ID}-${UUID_LOWER}"
[[ ! -L "$OUTPUT_DIR" ]] || die "output directory must not be a symlink"
mkdir -p -- "$OUTPUT_ROOT"
OUTPUT_ROOT=$(realpath -e -- "$OUTPUT_ROOT")
[[ "$(dirname -- "$OUTPUT_DIR")" == "$OUTPUT_ROOT" ]] \
    || die "output directory escaped --output-root"

assert_trusted_output_ancestry() {
    local path=$OUTPUT_ROOT owner mode gid

    path_has_posix_acl() {
        python3 -I -S - "$1" <<'PY'
import os
import sys

try:
    attributes = os.listxattr(sys.argv[1], follow_symlinks=False)
except OSError:
    sys.exit(0)
if any(name in ("system.posix_acl_access", "system.posix_acl_default")
       for name in attributes):
    sys.exit(0)
sys.exit(1)
PY
    }

    group_has_untrusted_member() {
        python3 -I -S - "$1" "$EUID" <<'PY'
import grp
import pwd
import sys

gid = int(sys.argv[1])
euid = int(sys.argv[2])
try:
    group = grp.getgrgid(gid)
except KeyError:
    sys.exit(0)
names = set(group.gr_mem)
for account in pwd.getpwall():
    if account.pw_gid == gid:
        names.add(account.pw_name)
for name in names:
    try:
        uid = pwd.getpwnam(name).pw_uid
    except KeyError:
        sys.exit(0)
    if uid not in (0, euid):
        sys.exit(0)
sys.exit(1)
PY
    }

    while :; do
        [[ -d "$path" && ! -L "$path" ]] \
            || die "output ancestry contains a non-directory/symlink: $path"
        ! path_has_posix_acl "$path" \
            || die "output ancestry has an extended/default POSIX ACL at $path"
        owner=$(stat -c %u -- "$path")
        [[ "$owner" == "$EUID" || "$owner" == 0 ]] \
            || die "output ancestry has an untrusted owner at $path"
        mode=$(stat -c %a -- "$path")
        if (( (8#$mode & 002) != 0 )); then
            (( (8#$mode & 01000) != 0 )) \
                || die "output ancestry is writable without sticky protection at $path"
        fi
        if (( (8#$mode & 020) != 0 &&
              (8#$mode & 01000) == 0 )); then
            gid=$(stat -c %g -- "$path")
            ! group_has_untrusted_member "$gid" \
                || die "output ancestry has an untrusted writable group at $path"
        fi
        [[ "$path" == / ]] && break
        path=$(dirname -- "$path")
    done
    [[ "$(stat -c %u -- "$OUTPUT_ROOT")" == "$EUID" ]] \
        || die "output root must be owned by the packager user"
    mode=$(stat -c %a -- "$OUTPUT_ROOT")
    (( (8#$mode & 002) == 0 )) \
        || die "output root must not be other-writable"
    if (( (8#$mode & 020) != 0 )); then
        gid=$(stat -c %g -- "$OUTPUT_ROOT")
        ! group_has_untrusted_member "$gid" \
            || die "output root group contains another writable user"
    fi
}
assert_trusted_output_ancestry

# Lock the already-canonical private directory inode.  A pathname lock file
# could itself be replaced by a lower-privilege host user.
exec {LOCK_FD}<"$OUTPUT_ROOT" \
    || die "could not open the output root for locking"
LOCK_FD_PATH="/proc/self/fd/$LOCK_FD"
[[ -d "$LOCK_FD_PATH" &&
   "$(stat -Lc '%d:%i' -- "$LOCK_FD_PATH")" == \
       "$(stat -Lc '%d:%i' -- "$OUTPUT_ROOT")" ]] \
    || die "output root changed before locking"
flock -x "$LOCK_FD"
[[ "$(stat -Lc '%d:%i' -- "$LOCK_FD_PATH")" == \
   "$(stat -Lc '%d:%i' -- "$OUTPUT_ROOT")" ]] \
    || die "output root changed while waiting for the package lock"
assert_trusted_output_ancestry

validate_existing_package() {
    local directory=$1 state contract exe
    local state_contract_sha state_exe_sha state_exe_bytes mode file

    [[ -d "$directory" && ! -L "$directory" &&
       "$(stat -c %u -- "$directory")" == "$EUID" ]] \
        || die "existing output is not a private packager-owned directory"
    mode=$(stat -c %a -- "$directory")
    (( (8#$mode & 077) == 0 )) \
        || die "existing output directory is accessible by other users"

    python3 -I -S - "$directory" <<'PY' \
        || die "existing output contains missing, extra or unrelated entries"
import os
import sys

expected = {
    "VgpuProductionMigration.exe",
    "host-state.json",
    "migration-contract.json",
}
try:
    actual = set(os.listdir(sys.argv[1]))
except OSError:
    raise SystemExit(1)
raise SystemExit(0 if actual == expected else 1)
PY

    state="$directory/host-state.json"
    contract="$directory/migration-contract.json"
    exe="$directory/VgpuProductionMigration.exe"
    for file in "$state" "$contract" "$exe"; do
        [[ -f "$file" && ! -L "$file" &&
           "$(stat -c %u -- "$file")" == "$EUID" &&
           "$(stat -c %a -- "$file")" == 600 ]] \
            || die "existing package asset is unsafe: $file"
    done

    jq -e \
        --argjson vmId "$VM_ID" \
        --arg vmUuid "$UUID_LOWER" \
        --arg gpuProfile "$GPU_PROFILE" \
        --arg gpuName "$GPU_NAME" '
        (keys | sort) == [
            "archiveSha256", "exeBytes", "exeSha256", "gpuName",
            "gpuProfile", "guestContractSha256", "migrationId",
            "requiredHostModeAfterReceipt", "schemaVersion",
            "sourceCatalogSha256", "sourceConfigSha256", "sourceHostMode",
            "sourceInfSha256", "vmId", "vmUuid"
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
    ' "$state" >/dev/null \
        || die "existing host-state metadata is incomplete or mismatched"

    state_contract_sha=$(jq -er .guestContractSha256 "$state")
    state_exe_sha=$(jq -er .exeSha256 "$state")
    state_exe_bytes=$(jq -er .exeBytes "$state")
    [[ "$(sha256_upper "$contract")" == "$state_contract_sha" ]] \
        || die "existing contract does not match its host-state metadata"
    [[ "$(sha256_upper "$exe")" == "$state_exe_sha" &&
       "$(stat -c %s -- "$exe")" == "$state_exe_bytes" ]] \
        || die "existing migration EXE does not match its host-state metadata"
}

EXISTING_OUTPUT=0
if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]]; then
    ((REPLACE)) || die \
        "existing migration package retained; use --replace only before its EXE has ever run"
    validate_existing_package "$OUTPUT_DIR"
    EXISTING_OUTPUT=1
fi

log "building vm${VM_ID} / ${GPU_PROFILE} / ${GPU_NAME}: legacy A -> B/native"
log "embedding the locked driver archive and GPU-Z package; this can take several minutes"

work=$(mktemp -d "$OUTPUT_ROOT/.vm${VM_ID}-production.XXXXXXXX")
cleanup() { rm -rf -- "${work:-}"; }
trap cleanup EXIT

# Build the existing, independently hash-manifested B/native GPU-Z profile
# against an isolated config copy.  The live vm.conf and disk are never edited.
fake_image="$work/image"
fake_vm_root="$fake_image/vms"
fake_instance="$fake_vm_root/${VM_ID}"
mkdir -p "$fake_instance"
awk '
    !/^[[:space:]]*(export[[:space:]]+)?(SPOOF|SPOOF_MODE|VGPU_IDENTITY_TARGET|VGPU_MDEV_INTERNAL_PCI_IDENTITY|VGPU_MDEV_FRL_ENABLED|VGPU_PATCHED_DRIVER_INF|VGPU_PATCHED_DRIVER_VERSION|VGPU_PATCHED_DRIVER_REQUIRED_VERSION|GPUZ_PACKAGE_ENABLED)=/
' "$CONF" >"$fake_instance/vm.conf"
printf '\nSPOOF_MODE=B\nVGPU_IDENTITY_TARGET=name-only\nGPUZ_PACKAGE_ENABLED=1\n' \
    >>"$fake_instance/vm.conf"
install -m 0600 /dev/null "$fake_instance/disk.qcow2"
fake_gpuz_root="$work/gpuz"
env -u VMS_DIR -u VM_INSTANCE_DIR -u VM_INSTANCE_ID \
    -u VM_DISK_ARCHIVE_DIR -u VM_BASE_ARCHIVE_DIR \
    -u VM_NVRAM_BACKUP_DIR -u ISO_DIR \
IMAGE_ROOT="$fake_image" \
VM_ROOT="$fake_vm_root" \
VM_INSTANCES_DIR="$fake_vm_root" \
VM_SHARED_DIR="$fake_vm_root/shared" \
VM_CONFIG_DIR="$fake_vm_root/legacy/configs" \
VM_DISK_DIR="$fake_vm_root/legacy/disks" \
VM_BASE_DIR="$fake_vm_root/shared/bases" \
VM_NVRAM_DIR="$fake_vm_root/legacy/nvram" \
VM_CONTROL_DIR="$fake_vm_root/control" \
VM_RUN_DIR="$fake_vm_root/control" \
VM_LOG_DIR="$fake_vm_root/legacy/log" \
VM_ASSET_DIR="$fake_vm_root/shared/assets" \
VM_STORAGE_COMPAT_FALLBACK=0 \
STAGE_DIR="$fake_image/staging" \
    "$here/package-gpuz-profile.sh" "$VM_ID" \
        --output-root "$fake_gpuz_root" \
        --gpuz-source "$GPUZ_SOURCE" >/dev/null
NESTED_GPUZ="$fake_gpuz_root/vm${VM_ID}-${UUID_LOWER}/GpuZProfile.exe"
[[ -f "$NESTED_GPUZ" && ! -L "$NESTED_GPUZ" ]] \
    || die "B/native GPU-Z package was not produced"
GPUZ_SHA=$(sha256_upper "$NESTED_GPUZ")

CONTRACT="$work/migration-contract.json"
jq -n \
    --argjson schemaVersion 1 \
    --arg migrationId "$MIGRATION_ID" \
    --argjson vmId "$VM_ID" \
    --arg vmUuid "$UUID_UPPER" \
    --arg gpuProfile "$GPU_PROFILE" \
    --arg gpuName "$GPU_NAME" \
    --arg legacyPnpId "$LEGACY_PNP" \
    --arg nativePnpId 'PCI\VEN_10DE&DEV_1E30' \
    --argjson archiveBytes 860703853 \
    --arg archiveSha256 "${VGPU_DRIVER_ZIP_SHA256^^}" \
    --arg infSha256 "$SOURCE_INF_SHA" \
    --arg catalogSha256 "$SOURCE_CAT_SHA" \
    --arg driverVersion "$VGPU_DRIVER_VERSION" \
    --arg gpuzSha256 "$GPUZ_SHA" \
    '{
        schemaVersion: $schemaVersion,
        migrationId: $migrationId,
        vmId: $vmId,
        vmUuid: $vmUuid,
        gpuProfile: $gpuProfile,
        gpuName: $gpuName,
        legacyPnpId: $legacyPnpId,
        nativePnpId: $nativePnpId,
        driver: {
            archiveName: "538.33-display-driver.zip",
            archiveBytes: $archiveBytes,
            archiveSha256: $archiveSha256,
            infRelativePath: "Display.Driver/nvgridsw.inf",
            infSha256: $infSha256,
            catalogRelativePath: "Display.Driver/nvgridsw.cat",
            catalogSha256: $catalogSha256,
            driverVersion: $driverVersion
        },
        gpuz: {
            name: "GpuZProfile.exe",
            sha256: $gpuzSha256
        }
    }' >"$CONTRACT"
chmod 0600 "$CONTRACT"
CONTRACT_SHA=$(sha256_upper "$CONTRACT")

OUTPUT_EXE="$work/VgpuProductionMigration.exe"
"$here/guest/vgpu-production-migration/build.sh" \
    --contract "$CONTRACT" \
    --script "$here/guest/migrate-vgpu-production-driver.ps1" \
    --driver-zip "$DRIVER_ZIP" \
    --gpuz-exe "$NESTED_GPUZ" \
    --output "$OUTPUT_EXE" >/dev/null
EXE_SHA=$(sha256_upper "$OUTPUT_EXE")
EXE_BYTES=$(stat -c %s -- "$OUTPUT_EXE")

HOST_STATE="$work/host-state.json"
jq -n \
    --argjson schemaVersion 1 \
    --arg migrationId "$MIGRATION_ID" \
    --argjson vmId "$VM_ID" \
    --arg vmUuid "$UUID_LOWER" \
    --arg gpuProfile "$GPU_PROFILE" \
    --arg gpuName "$GPU_NAME" \
    --arg sourceHostMode "$configured_mode" \
    --arg sourceConfigSha256 "$CONFIG_SHA256" \
    --arg guestContractSha256 "$CONTRACT_SHA" \
    --arg exeSha256 "$EXE_SHA" \
    --argjson exeBytes "$EXE_BYTES" \
    --arg archiveSha256 "${VGPU_DRIVER_ZIP_SHA256^^}" \
    --arg sourceInfSha256 "$SOURCE_INF_SHA" \
    --arg sourceCatalogSha256 "$SOURCE_CAT_SHA" \
    '{
        schemaVersion: $schemaVersion,
        migrationId: $migrationId,
        vmId: $vmId,
        vmUuid: $vmUuid,
        gpuProfile: $gpuProfile,
        gpuName: $gpuName,
        sourceHostMode: $sourceHostMode,
        sourceConfigSha256: $sourceConfigSha256,
        guestContractSha256: $guestContractSha256,
        exeSha256: $exeSha256,
        exeBytes: $exeBytes,
        archiveSha256: $archiveSha256,
        sourceInfSha256: $sourceInfSha256,
        sourceCatalogSha256: $sourceCatalogSha256,
        requiredHostModeAfterReceipt: "B"
    }' >"$HOST_STATE"
chmod 0600 "$HOST_STATE"

published="$work/published"
mkdir -m 0700 "$published"
install -m 0600 "$OUTPUT_EXE" "$published/VgpuProductionMigration.exe"
install -m 0600 "$CONTRACT" "$published/migration-contract.json"
install -m 0600 "$HOST_STATE" "$published/host-state.json"

# The build includes two independently generated executables and the locked
# vendor archive, so the live config and publication pathname must be checked
# again at the final commit point instead of trusting their state at startup.
[[ "$(sha256_upper "$CONF")" == "$CONFIG_SHA256" ]] \
    || die "VM configuration changed while the package was being built; rebuild first"
if ((EXISTING_OUTPUT)); then
    validate_existing_package "$OUTPUT_DIR"
    old="$OUTPUT_ROOT/.old-vm${VM_ID}-$$-$RANDOM"
    [[ ! -e "$old" && ! -L "$old" ]] \
        || die "could not reserve a private replacement path"
    mv -T -- "$OUTPUT_DIR" "$old"
else
    [[ ! -e "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] \
        || die "an output directory appeared during packaging; refusing to replace it without --replace"
    old=""
fi
if ! mv -T -- "$published" "$OUTPUT_DIR"; then
    [[ -z "$old" ]] || mv -T -- "$old" "$OUTPUT_DIR"
    die "could not publish migration package"
fi
[[ -z "$old" ]] || rm -rf -- "$old"
trap - EXIT
rm -rf -- "$work"
work=""

printf -v OUTPUT_ROOT_SHELL '%q' "$OUTPUT_ROOT"
cat <<EOF
[vgpu-production-package] PASS
  VM:          vm${VM_ID} / ${GPU_PROFILE} / ${GPU_NAME}
  migration:   ${MIGRATION_ID}
  source mode: ${configured_mode}
  target mode: B / native DEV_1E30
  launcher:    1.1.0.0
  EXE:         ${OUTPUT_DIR}/VgpuProductionMigration.exe
  EXE bytes:   ${EXE_BYTES}
  EXE SHA256:  ${EXE_SHA}

Windows 内只复制并双击 VgpuProductionMigration.exe 一次（UAC 点“是”）。
它约 821 MiB + GPU-Z 子包，因为原始 NVIDIA archive 完整内嵌且不重打包。
第一阶段只 add-only 暂存官方包、写回执并关机；不会绑定当前 A 设备。
关机后必须运行宿主 commit 脚本验证磁盘回执，脚本才允许把 vm.conf 切到 B。

VM 完全关机后，在宿主机直接运行：
  sudo ./deploy/commit-vgpu-production-migration.sh ${VM_ID} --output-root ${OUTPUT_ROOT_SHELL}
EOF

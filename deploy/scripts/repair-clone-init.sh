#!/usr/bin/env bash
# Refresh the VM-bound first-boot ISO for one stopped, failed G-11 clone.
# The Windows disk and private base are not modified.  The obsolete package is
# removed after the new content-bound package and marker are committed.
set -euo pipefail
umask 077
export LC_ALL=C

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
for dependency in jq sha256sum stat realpath flock pgrep grep find mktemp \
        mv chmod chown rm; do
    command -v "$dependency" >/dev/null 2>&1 || die "missing dependency: $dependency"
done

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

exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -x "$STORAGE_LOCK_FD"
START_LOCK=$(vm_storage_run_path "$VM_ID" start.lock)
exec {START_LOCK_FD}>"$START_LOCK"
flock -n -x "$START_LOCK_FD" || die "vm${VM_ID} is starting or running"
if pgrep -af qemu-system-x86_64 2>/dev/null | grep -F -- "$DISK" >/dev/null; then
    die "vm${VM_ID} is still running; shut it down before refreshing first boot"
fi

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
ROOT_SWAPPED=0
COMPLETE=0
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if (( ! COMPLETE )); then
        rm -f -- "$MARKER_TMP"
        if (( ROOT_SWAPPED )); then
            rm -rf -- "$CURRENT_ROOT"
            mv -T -- "$OLD_ROOT" "$CURRENT_ROOT" >/dev/null 2>&1 || true
        fi
        rm -rf -- "$NEW_ROOT"
    fi
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

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

mv -T -- "$CURRENT_ROOT" "$OLD_ROOT"
ROOT_SWAPPED=1
mv -T -- "$NEW_ROOT" "$CURRENT_ROOT"
NEW_ROOT=""
mv -T -- "$MARKER_TMP" "$REQUIRED_MARKER"
MARKER_TMP=""
COMPLETE=1
trap - EXIT HUP INT TERM
rm -rf -- "$OLD_ROOT"
[[ ! -e "$OLD_ROOT" && ! -L "$OLD_ROOT" ]] ||
    die "obsolete package could not be removed: $OLD_ROOT"

cat <<EOF
[g11-init-repair] PASS vm${VM_ID}
  contract: $CONTRACT_ID
  ISO:      $CURRENT_ROOT/$ISO_FILE
  old package: removed (no archive)

启动该 VM，登录后右键管理员运行桌面的 Retry-Clone-Initialization.cmd。
母盘和 Windows 磁盘均未修改；成功后仍会内部重启一次并最终完整关机。
EOF

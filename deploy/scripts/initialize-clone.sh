#!/usr/bin/env bash
# One stopped-state host action after the private Sysprep clone shuts down:
# verify the guest receipt, refresh its monitor cache, then clear the gate.
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=../lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
vm_storage_init

die() { echo "[g11-initial] ERROR: $*" >&2; exit 1; }
usage() { echo "usage: $0 VM_ID" >&2; }

(($# == 1)) || { usage; exit 2; }
VM_ID=$1
vm_storage_validate_id "$VM_ID" || exit 2
((EUID == 0)) || die "需要管理员权限；请从 VMate 点击‘初始’，或使用 sudo 运行"
for dependency in jq flock stat mv date pgrep grep chmod chown rm dirname mktemp sed find; do
    command -v "$dependency" >/dev/null 2>&1 || die "missing dependency: $dependency"
done
: "${QEMU_IMG:=$(command -v qemu-img || true)}"
[[ -x "$QEMU_IMG" ]] || die "qemu-img is missing; set QEMU_IMG explicitly"

vm_storage_require_namespace_ready "$VM_ID"
vm_storage_prepare
vm_storage_prepare_instance "$VM_ID"
INSTANCE_DIR=$(vm_storage_instance_dir "$VM_ID")
DISK=$(vm_storage_disk_path "$VM_ID")
REQUIRED_MARKER="$INSTANCE_DIR/.g11-init-required"
DONE_MARKER="$INSTANCE_DIR/.g11-initialized"
NATIVE_STORAGE_MARKER="$INSTANCE_DIR/.g11-repair-native-storage"
if [[ ! -e "$REQUIRED_MARKER" && -f "$DONE_MARKER" && ! -L "$DONE_MARKER" ]]; then
    echo "[g11-initial] vm${VM_ID} already initialized"
    exit 0
fi
[[ -f "$REQUIRED_MARKER" && ! -L "$REQUIRED_MARKER" ]] ||
    die "this VM is not waiting for private G-11 initialization"
if [[ -e "$NATIVE_STORAGE_MARKER" || -L "$NATIVE_STORAGE_MARKER" ]]; then
    [[ -f "$NATIVE_STORAGE_MARKER" && ! -L "$NATIVE_STORAGE_MARKER" &&
       "$(stat -c '%a:%u:%h' -- "$NATIVE_STORAGE_MARKER")" == "600:$(stat -c %u -- "$REQUIRED_MARKER"):1" ]] ||
        die "old-clone native-storage marker is unsafe"
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
' "$REQUIRED_MARKER" >/dev/null || die "private clone initialization marker is invalid"

exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -s "$STORAGE_LOCK_FD"
exec {IDENTITY_LOCK_FD}>"$VM_RUN_DIR/.g11-identity.lock"
flock -x "$IDENTITY_LOCK_FD"
START_LOCK=$(vm_storage_run_path "$VM_ID" start.lock)
exec {START_LOCK_FD}>"$START_LOCK"
flock -n -x "$START_LOCK_FD" || die "vm${VM_ID} is starting or running"
if pgrep -af qemu-system-x86_64 2>/dev/null | grep -F -- "$DISK" >/dev/null; then
    die "vm${VM_ID} is still running; wait for its automatic full shutdown"
fi

VERIFY_OUTPUT=$(VM_START_LOCK_HELD=1 QEMU_IMG="$QEMU_IMG" \
    "$here/host/verify-g11-clone-ready.sh" "$VM_ID")
printf '%s\n' "$VERIFY_OUTPUT"
mapfile -t IDENTITY_LINES < <(
    printf '%s\n' "$VERIFY_OUTPUT" | sed -n 's/^G11_SAFE_IDENTITY_JSON=//p'
)
((${#IDENTITY_LINES[@]} == 1)) || die "guest verifier returned no unique OS identity"
IDENTITY_JSON=${IDENTITY_LINES[0]}
jq -e '
    (keys | sort) == [
        "computerName", "gpuProfile", "machineGuid", "machineSid",
        "observedVmUuid", "systemNvapiContractId"
    ] and
    (.computerName | test("^[A-Z0-9][A-Z0-9-]{0,14}$")) and
    (.machineGuid | test("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")) and
    (.machineSid | test("^S-1-5-21-[0-9]+-[0-9]+-[0-9]+$")) and
    (.observedVmUuid | test("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")) and
    (.gpuProfile | test("^[a-z0-9_]+$")) and
    (.systemNvapiContractId | test("^[0-9A-F]{64}$"))
' <<<"$IDENTITY_JSON" >/dev/null || die "guest verifier returned an invalid OS identity"

COMPUTER_NAME=$(jq -r '.computerName' <<<"$IDENTITY_JSON")
MACHINE_GUID=$(jq -r '.machineGuid' <<<"$IDENTITY_JSON")
MACHINE_SID=$(jq -r '.machineSid' <<<"$IDENTITY_JSON")
OBSERVED_VM_UUID=$(jq -r '.observedVmUuid' <<<"$IDENTITY_JSON")
EXPECTED_COMPUTER_NAME="DESKTOP-${OBSERVED_VM_UUID//-/}"
EXPECTED_COMPUTER_NAME=${EXPECTED_COMPUTER_NAME:0:15}
EXPECTED_COMPUTER_NAME=${EXPECTED_COMPUTER_NAME^^}
[[ "$COMPUTER_NAME" == "$EXPECTED_COMPUTER_NAME" ]] ||
    die "guest computer name is not the V-11-style value: $COMPUTER_NAME != $EXPECTED_COMPUTER_NAME"
GPU_PROFILE=$(jq -r '.gpuProfile' <<<"$IDENTITY_JSON")
SYSTEM_NVAPI_CONTRACT_ID=$(jq -r '.systemNvapiContractId' <<<"$IDENTITY_JSON")
while IFS= read -r -d '' existing_marker; do
    [[ "$existing_marker" != "$DONE_MARKER" ]] || continue
    jq -e '
        (((keys | sort) == [
              "completedUtc", "computerName", "gpuProfile", "guestVerified",
              "machineGuid", "machineSid", "monitorSynchronized",
              "observedVmUuid", "schemaVersion", "state"
          ] and .schemaVersion == 2)
         or
         ((keys | sort) == [
              "completedUtc", "computerName", "gpuProfile", "guestVerified",
              "machineGuid", "machineSid", "monitorSynchronized",
              "observedVmUuid", "schemaVersion", "state",
              "systemNvapiContractId", "systemNvapiVerified"
          ] and .schemaVersion == 3 and .systemNvapiVerified == true and
          (.systemNvapiContractId | test("^[0-9A-F]{64}$")))) and
        .state == "ready" and
        .guestVerified == true and .monitorSynchronized == true and
        (.completedUtc | type) == "string" and
        (.computerName | test("^[A-Z0-9][A-Z0-9-]{0,14}$")) and
        (.machineGuid | test("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")) and
        (.machineSid | test("^S-1-5-21-[0-9]+-[0-9]+-[0-9]+$")) and
        (.observedVmUuid | test("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")) and
        (.gpuProfile | test("^[a-z0-9_]+$"))
    ' "$existing_marker" >/dev/null ||
        die "existing G-11 identity marker is invalid: $existing_marker"
    if jq -e \
            --arg computerName "$COMPUTER_NAME" \
            --arg machineGuid "$MACHINE_GUID" \
            --arg machineSid "$MACHINE_SID" \
            --arg observedVmUuid "$OBSERVED_VM_UUID" '
            .computerName == $computerName or .machineGuid == $machineGuid or
            .machineSid == $machineSid or .observedVmUuid == $observedVmUuid
        ' "$existing_marker" >/dev/null; then
        die "Windows OS identity duplicates another initialized G-11 VM: $existing_marker"
    fi
done < <(find "$VM_INSTANCES_DIR" -mindepth 2 -maxdepth 2 -type f \
    -name .g11-initialized -print0)

if [[ -z "${QEMU_EDID:-}" ]]; then
    for candidate in \
        "$(dirname -- "$QEMU_IMG")/qemu-edid.g11" \
        /opt/vmate/qemu-edid.g11 \
        "$here/../build/qemu-edid"; do
        if [[ -x "$candidate" ]]; then
            QEMU_EDID=$candidate
            break
        fi
    done
fi
[[ -n "${QEMU_EDID:-}" && -x "$QEMU_EDID" ]] ||
    die "qemu-edid.g11 is missing; reinstall the VMate deb or set QEMU_EDID"
VM_START_LOCK_HELD=1 QEMU_IMG="$QEMU_IMG" QEMU_EDID="$QEMU_EDID" \
    "$here/scripts/sync-monitor-profile.sh" "$VM_ID" --force

marker_uid=$(stat -c %u -- "$REQUIRED_MARKER")
marker_gid=$(stat -c %g -- "$REQUIRED_MARKER")
DONE_TMP=$(mktemp "$INSTANCE_DIR/.g11-initialized.new.XXXXXXXX")
DONE_PUBLISHED=0
cleanup_done_marker() {
    ((DONE_PUBLISHED)) || rm -f -- "$DONE_TMP"
}
trap cleanup_done_marker EXIT
jq -n \
    --argjson schemaVersion 3 \
    --arg state ready \
    --arg completedUtc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg computerName "$COMPUTER_NAME" \
    --arg machineGuid "$MACHINE_GUID" \
    --arg machineSid "$MACHINE_SID" \
    --arg observedVmUuid "$OBSERVED_VM_UUID" \
    --arg gpuProfile "$GPU_PROFILE" \
    --arg systemNvapiContractId "$SYSTEM_NVAPI_CONTRACT_ID" '
    {
        schemaVersion: $schemaVersion,
        state: $state,
        completedUtc: $completedUtc,
        computerName: $computerName,
        machineGuid: $machineGuid,
        machineSid: $machineSid,
        observedVmUuid: $observedVmUuid,
        gpuProfile: $gpuProfile,
        guestVerified: true,
        monitorSynchronized: true,
        systemNvapiVerified: true,
        systemNvapiContractId: $systemNvapiContractId
    }' >"$DONE_TMP"
chmod 0600 "$DONE_TMP"
chown "$marker_uid:$marker_gid" "$DONE_TMP"
mv -T -- "$DONE_TMP" "$DONE_MARKER"
DONE_PUBLISHED=1
rm -f -- "$REQUIRED_MARKER" "$NATIVE_STORAGE_MARKER"
trap - EXIT

echo "[g11-initial] PASS: vm${VM_ID} 来宾身份/授权、x86+x64 系统 NVAPI 已验证，显示器缓存已刷新，可以启动"

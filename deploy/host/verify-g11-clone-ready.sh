#!/usr/bin/env bash
# Read-only verification of the licensed guest first-boot result. No guest
# registry or file is modified and no credential/hash is printed.
set -euo pipefail
umask 077

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/vm-storage.sh
source "$DEPLOY_ROOT/lib/vm-storage.sh"
# shellcheck source=../lib/vgpu-profiles.sh
source "$DEPLOY_ROOT/lib/vgpu-profiles.sh"
vm_storage_init

die() { echo "[g11-clone-verify] ERROR: $*" >&2; exit 1; }
usage() { echo "usage: $0 VM_ID" >&2; }

(($# == 1)) || { usage; exit 2; }
VM_ID=$1
vm_storage_validate_id "$VM_ID" || exit 2
readonly REQUESTED_VM_ID=$VM_ID
((EUID == 0)) || die "root is required for read-only qemu-nbd verification"
for dependency in qemu-nbd jq mount umount ntfs-3g blkid lsblk modprobe partprobe \
        udevadm flock lsof realpath stat awk mktemp rmdir pgrep grep sha256sum \
        head tr; do
    command -v "$dependency" >/dev/null 2>&1 || die "missing dependency: $dependency"
done
: "${QEMU_IMG:=$(command -v qemu-img || true)}"
[[ -x "$QEMU_IMG" ]] || die "qemu-img is missing; set QEMU_IMG explicitly"

vm_storage_require_namespace_ready "$VM_ID"
vm_storage_prepare
vm_storage_prepare_instance "$VM_ID"
if [[ "${VM_START_LOCK_HELD:-0}" != 1 ]]; then
    START_LOCK=$(vm_storage_run_path "$VM_ID" start.lock)
    exec {START_LOCK_FD}>"$START_LOCK"
    flock -n -x "$START_LOCK_FD" || die "vm${VM_ID} is starting or running"
fi
CONF=$(vm_storage_config_path "$VM_ID")
DISK=$(vm_storage_disk_path "$VM_ID")
[[ -f "$CONF" && ! -L "$CONF" ]] || die "VM configuration is missing: $CONF"
[[ -f "$DISK" && ! -L "$DISK" ]] || die "VM disk is missing: $DISK"
if pgrep -af qemu-system-x86_64 2>/dev/null | grep -F -- "$DISK" >/dev/null; then
    die "vm${VM_ID} is still running"
fi

unset VM_UUID GPU_PROFILE MONITOR_PROFILE SPOOF_MODE
# shellcheck source=/dev/null
source "$CONF"
[[ "$VM_ID" == "$REQUESTED_VM_ID" ]] ||
    die "vm.conf VM_ID does not match the instance path"
VM_ID=$REQUESTED_VM_ID
[[ "${SPOOF_MODE:-}" == B ]] || die "vm${VM_ID} is not the G-11 B/native mode"
[[ "${VM_UUID:-}" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]] ||
    die "vm.conf has an invalid VM_UUID"
vgpu_profile_load "${GPU_PROFILE:-}" || die "vm.conf has an unknown GPU_PROFILE"
EXPECTED_UUID=${VM_UUID,,}
EXPECTED_COMPUTER_NAME="DESKTOP-${EXPECTED_UUID//-/}"
EXPECTED_COMPUTER_NAME=${EXPECTED_COMPUTER_NAME:0:15}
EXPECTED_COMPUTER_NAME=${EXPECTED_COMPUTER_NAME^^}
EXPECTED_PROFILE=$GPU_PROFILE
EXPECTED_MONITOR_PROFILE=${MONITOR_PROFILE:-}
[[ "$EXPECTED_MONITOR_PROFILE" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] ||
    die "vm.conf has an invalid MONITOR_PROFILE"
EXPECTED_CONFIG_SHA256=$(sha256sum -- "$CONF" | awk '{print toupper($1)}')

vm_storage_read_qcow2_metadata "$QEMU_IMG" "$DISK" || die "disk is not qcow2"
[[ -z "$VM_STORAGE_QCOW2_DATA_FILE" ]] ||
    die "clone disk cannot use an external data file"
DISK_MODE=standalone
if [[ -n "$VM_STORAGE_QCOW2_BACKING" ]]; then
    EXPECTED_BASE_PIN=$(vm_storage_instance_base_pin_path "$VM_ID") ||
        die "could not resolve the instance base pin"
    [[ "$VM_STORAGE_QCOW2_BACKING" == "$(basename "$EXPECTED_BASE_PIN")" ]] ||
        die "linked clone must use the fixed relative .base.qcow2 pin"
    RESOLVED_BASE_PIN=$(vm_storage_resolved_backing_path "$DISK") ||
        die "linked clone backing path is unsafe"
    [[ "$RESOLVED_BASE_PIN" == "$EXPECTED_BASE_PIN" &&
       -f "$EXPECTED_BASE_PIN" && ! -L "$EXPECTED_BASE_PIN" &&
       ! "$DISK" -ef "$EXPECTED_BASE_PIN" ]] ||
        die "linked clone backing is not the regular instance-local base pin"
    vm_storage_read_qcow2_metadata "$QEMU_IMG" "$EXPECTED_BASE_PIN" ||
        die "instance base pin is not qcow2"
    [[ -z "$VM_STORAGE_QCOW2_BACKING" &&
       -z "$VM_STORAGE_QCOW2_DATA_FILE" ]] ||
        die "instance base pin must be a standalone image"
    DISK_MODE=linked
fi
"$QEMU_IMG" check -q "$DISK"

NBD=/dev/nbd0
_NBD_PINNED=""
# shellcheck source=../lib/nbd-lock.sh
source "$DEPLOY_ROOT/lib/nbd-lock.sh"
MOUNT_DIR=$(mktemp -d /tmp/g11-clone-verify.XXXXXXXX)
MOUNTED=0
COMPLETED=0
cleanup() {
    local status=$?
    local cleanup_status=$status
    trap - EXIT HUP INT TERM
    if ((MOUNTED)); then
        umount -- "$MOUNT_DIR" >/dev/null 2>&1 || cleanup_status=70
        MOUNTED=0
    fi
    if [[ "${_NBD_CONNECTED:-0}" == 1 && -n "${_NBD_DEV:-}" ]]; then
        qemu-nbd --disconnect "$_NBD_DEV" >/dev/null 2>&1 || cleanup_status=70
        _NBD_CONNECTED=0
    fi
    rmdir -- "$MOUNT_DIR" >/dev/null 2>&1 || true
    if ((status == 0 && ! COMPLETED)); then cleanup_status=70; fi
    exit "$cleanup_status"
}
trap cleanup EXIT HUP INT TERM

modprobe nbd max_part=32 >/dev/null 2>&1 || true
nbd_connect NBD "$DISK" read-only
partprobe "$NBD"
udevadm settle
mapfile -t PARTITIONS < <(lsblk -lnpo NAME,TYPE "$NBD" | awk '$2 == "part" {print $1}')
((${#PARTITIONS[@]} > 0)) || die "disk has no visible partitions"
WINDOWS_PARTITION=""
for partition in "${PARTITIONS[@]}"; do
    [[ "$(blkid -o value -s TYPE -- "$partition" 2>/dev/null || true)" == ntfs ]] || continue
    if mount -t ntfs-3g -o ro,norecover -- "$partition" "$MOUNT_DIR" >/dev/null 2>&1; then
        MOUNTED=1
        if [[ -d "$MOUNT_DIR/Windows/System32" && -d "$MOUNT_DIR/ProgramData" ]]; then
            WINDOWS_PARTITION=$partition
        fi
        umount -- "$MOUNT_DIR" || die "could not unmount Windows probe"
        MOUNTED=0
        [[ -z "$WINDOWS_PARTITION" ]] || break
    fi
done
[[ -n "$WINDOWS_PARTITION" ]] || die "could not find a clean Windows NTFS partition"
mount -t ntfs-3g -o ro,norecover -- "$WINDOWS_PARTITION" "$MOUNT_DIR" ||
    die "Windows did not complete a clean full shutdown"
MOUNTED=1

GUEST_MARKER="$MOUNT_DIR/ProgramData/VMate/G11/clone-initialization.json"
GUEST_ERROR="$MOUNT_DIR/ProgramData/VMate/G11/clone-initialization-error.txt"
PORTABLE_RESULT="$MOUNT_DIR/ProgramData/QemuGpuZProfile/last-result.json"
if [[ ! -f "$GUEST_MARKER" || -L "$GUEST_MARKER" ]]; then
    if [[ -f "$GUEST_ERROR" && ! -L "$GUEST_ERROR" ]]; then
        echo "[g11-clone-verify] guest initialization failure:" >&2
        # The guest file is untrusted terminal input. Bound its size and strip
        # control bytes (including ANSI escape) while preserving UTF-8 bytes.
        head -c 32768 -- "$GUEST_ERROR" |
            LC_ALL=C tr -cd '\11\12\15\40-\176\200-\377' >&2
        echo >&2
    fi
    die "guest initialization marker is missing; guest error remains at C:\\ProgramData\\VMate\\G11\\clone-initialization-error.txt"
fi
[[ -f "$PORTABLE_RESULT" && ! -L "$PORTABLE_RESULT" ]] ||
    die "licensed VgpuPortable final result is missing"

describe_guest_marker_mismatch() {
    echo "[g11-clone-verify] guest marker diagnostics:" >&2
    jq -r \
        --argjson vmId "$VM_ID" \
        --arg uuid "$EXPECTED_UUID" \
        --arg computerName "$EXPECTED_COMPUTER_NAME" \
        --arg profile "$EXPECTED_PROFILE" \
        --arg monitorProfile "$EXPECTED_MONITOR_PROFILE" '
        def shown:
            if type == "number" or type == "boolean" or type == "null" then
                tostring
            else
                (tostring | .[0:80] | @json)
            end;
        def lower_string: if type == "string" then ascii_downcase else "" end;
        def upper_string: if type == "string" then ascii_upcase else "" end;
        "  actual schemaVersion=\(.schemaVersion | shown) guestLite.profileVersion=\(.guestLite.profileVersion | shown)",
        ([
            (if ((keys | sort) == [
                "completedUtc", "computerName", "driverVersion", "gpuProfile",
                "guestLite", "licenseStatus", "machineGuid", "machineSid",
                "nointegritychecks", "observedVmUuid", "pnpDeviceId",
                "schemaVersion", "state", "systemNvapiProjection", "testsigning"
            ] and .schemaVersion == 4 and
            .state == "ready-for-host-initialization") then empty
             else "top-level-schema-or-fields" end),
            (if ((.observedVmUuid | lower_string) == $uuid and
                 .gpuProfile == $profile and .computerName == $computerName)
             then empty else "vm-config-or-windows-identity" end),
            (if (((.pnpDeviceId | upper_string) |
                    startswith("PCI\\VEN_10DE&DEV_1E30")) and
                 .driverVersion == "31.0.15.3833" and
                 .licenseStatus == "Licensed" and
                 .testsigning == false and .nointegritychecks == false)
             then empty else "driver-license-or-code-integrity" end),
            (if ((.guestLite | type) == "object" and
                 .guestLite.state == "validated" and
                 .guestLite.profileVersion == "2.6.4")
             then empty else "guest-lite-schema-or-version" end),
            (if (.guestLite.firewallService == "MpsSvc" and
                 .guestLite.firewallStartMode == "Auto" and
                 .guestLite.firewallState == "Running" and
                 .guestLite.firewallProcessId > 0 and
                 .guestLite.baseFilteringEngine == "preserved-running" and
                 .guestLite.enforcementLastResult == 0)
             then empty else "guest-lite-system-enforcement" end),
            (if (.guestLite.audio == "muted" and
                 .guestLite.notifications == "disabled" and
                 .guestLite.taskbarSearch == "hidden" and
                 .guestLite.gameMode == "enabled" and
                 .guestLite.gameDvr == "disabled" and
                 .guestLite.nvidiaPowerMode == "prefer-maximum-performance" and
                 .guestLite.dnfPriority == "high-on-launch" and
                 .guestLite.temporaryCleanup == "stale-files-over-24h-completed" and
                 .guestLite.backgroundProcesses == "reviewed-stopped" and
                 .guestLite.defaultInputMethod == "0409:00000409" and
                 .guestLite.inputOrder == "en-US/US,zh-CN/Microsoft-Pinyin")
             then empty else "guest-lite-policy-receipt" end),
            (if ((.systemNvapiProjection | type) == "object" and
                 .systemNvapiProjection.state == "validated" and
                 .systemNvapiProjection.vmId == $vmId and
                 (.systemNvapiProjection.vmUuid | lower_string) == $uuid and
                 .systemNvapiProjection.gpuProfile == $profile and
                 .systemNvapiProjection.monitorProfile == $monitorProfile and
                 .systemNvapiProjection.driverSigned == true and
                 .systemNvapiProjection.testsigning == false and
                 .systemNvapiProjection.nointegritychecks == false)
             then empty else "system-nvapi-projection" end)
        ] | "  failed checks: " + (if length == 0 then "strict-shape/detail"
                                    else join(", ") end))
    ' "$GUEST_MARKER" 2>/dev/null |
        head -c 4096 |
        LC_ALL=C tr -cd '\11\12\15\40-\176\200-\377' >&2 ||
        echo "  marker is not valid JSON" >&2
    echo >&2
}

if ! jq -e \
    --argjson vmId "$VM_ID" \
    --arg uuid "$EXPECTED_UUID" \
    --arg computerName "$EXPECTED_COMPUTER_NAME" \
    --arg profile "$EXPECTED_PROFILE" \
    --arg monitorProfile "$EXPECTED_MONITOR_PROFILE" '
    (keys | sort) == [
        "completedUtc", "computerName", "driverVersion", "gpuProfile",
        "guestLite", "licenseStatus", "machineGuid", "machineSid", "nointegritychecks",
        "observedVmUuid", "pnpDeviceId", "schemaVersion", "state",
        "systemNvapiProjection", "testsigning"
    ] and
    .schemaVersion == 4 and .state == "ready-for-host-initialization" and
    (.observedVmUuid | ascii_downcase) == $uuid and .gpuProfile == $profile and
    (.pnpDeviceId | ascii_upcase | startswith("PCI\\VEN_10DE&DEV_1E30")) and
    .driverVersion == "31.0.15.3833" and .licenseStatus == "Licensed" and
    (.machineGuid | ascii_downcase | test("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")) and
    (.machineSid | test("^S-1-5-21-[0-9]+-[0-9]+-[0-9]+$")) and
    .computerName == $computerName and
    .testsigning == false and .nointegritychecks == false and
    (.completedUtc | type) == "string" and
    (.guestLite | keys | sort) == [
        "appearance", "audio", "backgroundProcesses", "baseFilteringEngine",
        "defaultInputMethod", "dnfPriority",
        "enforcementLastResult",
        "enforcementLastRun", "enforcementTask",
        "firewallProcessId", "firewallService", "firewallStartMode",
        "firewallState", "gameDvr", "gameMode", "inputOrder",
        "notifications", "nvidiaPowerMode", "profileVersion",
        "rollbackBaseline", "state", "taskbarSearch", "temporaryCleanup",
        "userSid"
    ] and
    .guestLite.state == "validated" and
    .guestLite.profileVersion == "2.6.4" and
    .guestLite.userSid == (.machineSid + "-500") and
    .guestLite.rollbackBaseline == "C:\\ProgramData\\G11GuestLite\\state.json" and
    .guestLite.enforcementTask == "\\G11GuestLite-EnforceProfile" and
    .guestLite.enforcementLastResult == 0 and
    (.guestLite.enforcementLastRun | type) == "string" and
    (.guestLite.enforcementLastRun | length) > 0 and
    .guestLite.firewallService == "MpsSvc" and
    .guestLite.firewallStartMode == "Auto" and
    .guestLite.firewallState == "Running" and
    .guestLite.firewallProcessId > 0 and
    .guestLite.baseFilteringEngine == "preserved-running" and
    .guestLite.appearance == "background-and-font-preserved" and
    .guestLite.audio == "muted" and
    .guestLite.backgroundProcesses == "reviewed-stopped" and
    .guestLite.gameMode == "enabled" and
    .guestLite.gameDvr == "disabled" and
    .guestLite.nvidiaPowerMode == "prefer-maximum-performance" and
    .guestLite.dnfPriority == "high-on-launch" and
    .guestLite.temporaryCleanup == "stale-files-over-24h-completed" and
    .guestLite.notifications == "disabled" and
    .guestLite.taskbarSearch == "hidden" and
    .guestLite.defaultInputMethod == "0409:00000409" and
    .guestLite.inputOrder == "en-US/US,zh-CN/Microsoft-Pinyin" and
    (.systemNvapiProjection | keys | sort) == [
        "contractId", "driverSigned", "driverVersion", "gpuProfile",
        "monitorProfile", "nointegritychecks", "state", "testsigning",
        "vmId", "vmUuid"
    ] and
    .systemNvapiProjection.state == "validated" and
    (.systemNvapiProjection.contractId | test("^[0-9A-F]{64}$")) and
    .systemNvapiProjection.vmId == $vmId and
    (.systemNvapiProjection.vmUuid | ascii_downcase) == $uuid and
    .systemNvapiProjection.gpuProfile == $profile and
    .systemNvapiProjection.monitorProfile == $monitorProfile and
    .systemNvapiProjection.driverVersion == "31.0.15.3833" and
    .systemNvapiProjection.driverSigned == true and
    .systemNvapiProjection.testsigning == false and
    .systemNvapiProjection.nointegritychecks == false
' "$GUEST_MARKER" >/dev/null; then
    describe_guest_marker_mismatch
    die "guest initialization marker does not match the current vm.conf/clone contract"
fi

jq -e --arg uuid "$EXPECTED_UUID" --arg profile "$EXPECTED_PROFILE" '
    .receiptType == "vgpu-identity-portable-final" and
    .schemaVersion == 4 and .bindingMode == "portable-auto" and
    .privateLicensedFinalizer == true and
    (.observedVmUuid | ascii_downcase) == $uuid and .gpuProfile == $profile and
    (.pnpDeviceId | ascii_upcase | startswith("PCI\\VEN_10DE&DEV_1E30")) and
    .driverVersion == "31.0.15.3833" and
    .license.licenseStatus == "Licensed" and
    .testsigning == false and .nointegritychecks == false and
    .systemNvapiChanged == false and .hostCommitEligible == false
' "$PORTABLE_RESULT" >/dev/null ||
    die "licensed VgpuPortable result does not match this VM or production policy"

SYSTEM_CONTRACT_ID=$(jq -er '.systemNvapiProjection.contractId' "$GUEST_MARKER")
SYSTEM_PAYLOAD_ROOT="$MOUNT_DIR/ProgramData/G11/SystemNvapiProjection/$SYSTEM_CONTRACT_ID"
SYSTEM_CONTRACT="$SYSTEM_PAYLOAD_ROOT/system-nvapi-contract.json"
SYSTEM_MANIFEST="$SYSTEM_PAYLOAD_ROOT/system-nvapi-manifest.json"
SYSTEM_RECEIPT="$MOUNT_DIR/ProgramData/G11/SystemNvapiProjection/receipts/${SYSTEM_CONTRACT_ID}-validated.json"
for required_file in "$SYSTEM_CONTRACT" "$SYSTEM_MANIFEST" "$SYSTEM_RECEIPT"; do
    [[ -f "$required_file" && ! -L "$required_file" ]] ||
        die "validated system NVAPI evidence is missing or unsafe: $required_file"
done

CALCULATED_CONTRACT_ID=$(jq -cS 'del(.contractId)' "$SYSTEM_CONTRACT" |
    sha256sum | awk '{print toupper($1)}')
[[ "$CALCULATED_CONTRACT_ID" == "$SYSTEM_CONTRACT_ID" ]] ||
    die "system NVAPI contract content hash is invalid"
jq -e \
    --argjson vmId "$VM_ID" \
    --arg uuid "$EXPECTED_UUID" \
    --arg profile "$EXPECTED_PROFILE" \
    --arg monitorProfile "$EXPECTED_MONITOR_PROFILE" \
    --arg sourceConfigSha256 "$EXPECTED_CONFIG_SHA256" \
    --arg contractId "$SYSTEM_CONTRACT_ID" '
    (keys | sort) == [
        "contractId", "identityCatalogSha256", "monitor", "payload",
        "profile", "purpose", "schemaVersion", "sourceConfigSha256",
        "transport", "vmId", "vmUuid"
    ] and
    .schemaVersion == 4 and .purpose == "g11-system-nvapi-projection" and
    .contractId == $contractId and .vmId == $vmId and
    (.vmUuid | ascii_downcase) == $uuid and .profile.key == $profile and
    .monitor.key == $monitorProfile and
    .sourceConfigSha256 == $sourceConfigSha256 and
    .transport.targetPnpId == "PCI\\VEN_10DE&DEV_1E30" and
    .transport.driverVersion == "31.0.15.3833" and
    (.payload.shimX86Sha256 | test("^[0-9A-F]{64}$")) and
    (.payload.shimX64Sha256 | test("^[0-9A-F]{64}$"))
' "$SYSTEM_CONTRACT" >/dev/null ||
    die "system NVAPI contract does not match this VM/config"

jq -e --arg contractId "$SYSTEM_CONTRACT_ID" '
    (keys | sort) == ["contractId", "files", "purpose", "schemaVersion"] and
    .schemaVersion == 1 and .purpose == "g11-system-nvapi-projection" and
    .contractId == $contractId and (.files | length) == 12 and
    ([.files[].path] | unique | length) == 12 and
    ([.files[].path] | sort) == [
        "D3D12CapabilityProbe32.exe", "D3D12CapabilityProbe64.exe",
        "SystemNvapiProbe32.exe", "SystemNvapiProbe64.exe",
        "install-nvapi-shim.ps1", "install-system-nvapi-projection.ps1",
        "monitor-edid.bin", "nvapi.dll", "nvapi64.dll",
        "patch-grid-strings.ps1", "system-nvapi-contract.json",
        "vgpu-profile-catalog.json"
    ] and
    all(.files[];
        (.path | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
        (.bytes | type) == "number" and .bytes > 0 and
        (.sha256 | test("^[0-9A-F]{64}$")))
' "$SYSTEM_MANIFEST" >/dev/null || die "system NVAPI durable manifest is invalid"

while IFS=$'\t' read -r payload_name payload_bytes payload_sha256; do
    payload_file="$SYSTEM_PAYLOAD_ROOT/$payload_name"
    [[ -f "$payload_file" && ! -L "$payload_file" &&
       "$(stat -c %s -- "$payload_file")" == "$payload_bytes" ]] ||
        die "system NVAPI durable payload file is missing/changed: $payload_name"
    [[ "$(sha256sum -- "$payload_file" | awk '{print toupper($1)}')" == \
       "$payload_sha256" ]] ||
        die "system NVAPI durable payload digest mismatch: $payload_name"
done < <(jq -r '.files[] | [.path, (.bytes | tostring), .sha256] | @tsv' \
    "$SYSTEM_MANIFEST")

jq -e \
    --argjson vmId "$VM_ID" \
    --arg uuid "$EXPECTED_UUID" \
    --arg profile "$EXPECTED_PROFILE" \
    --arg monitorProfile "$EXPECTED_MONITOR_PROFILE" \
    --arg contractId "$SYSTEM_CONTRACT_ID" \
    --arg shimX86 "$(jq -r '.payload.shimX86Sha256' "$SYSTEM_CONTRACT")" \
    --arg shimX64 "$(jq -r '.payload.shimX64Sha256' "$SYSTEM_CONTRACT")" '
    (keys | sort) == [
        "bcdSha256", "boardBrand", "completedUtc", "contractId",
        "displayInstanceId", "driverSigned", "driverVersion", "gpuName",
        "gpuProfile", "memoryMaker", "memoryMakerNvapi", "memoryType",
        "monitorInstanceId", "monitorName", "monitorPnpId", "monitorProfile",
        "nointegritychecks", "purpose", "schemaVersion", "shimX64Sha256",
        "shimX86Sha256", "state", "testsigning", "vmId", "vmUuid"
    ] and
    .schemaVersion == 2 and .purpose == "g11-system-nvapi-projection" and
    .state == "validated" and .contractId == $contractId and .vmId == $vmId and
    (.vmUuid | ascii_downcase) == $uuid and .gpuProfile == $profile and
    .monitorProfile == $monitorProfile and
    (.displayInstanceId | ascii_upcase | startswith("PCI\\VEN_10DE&DEV_1E30")) and
    (.monitorInstanceId | ascii_upcase | startswith("DISPLAY\\")) and
    .driverVersion == "31.0.15.3833" and .driverSigned == true and
    .shimX86Sha256 == $shimX86 and .shimX64Sha256 == $shimX64 and
    .testsigning == false and .nointegritychecks == false and
    (.bcdSha256 | test("^[0-9A-F]{64}$")) and (.completedUtc | type) == "string"
' "$SYSTEM_RECEIPT" >/dev/null ||
    die "system NVAPI validated receipt does not match this VM or production policy"

SAFE_IDENTITY_JSON=$(jq -c '
    {
        computerName: .computerName,
        machineGuid: (.machineGuid | ascii_downcase),
        machineSid: .machineSid,
        observedVmUuid: (.observedVmUuid | ascii_downcase),
        gpuProfile: .gpuProfile,
        systemNvapiContractId: .systemNvapiProjection.contractId
    }
' "$GUEST_MARKER")

umount -- "$MOUNT_DIR"
MOUNTED=0
qemu-nbd --disconnect "$_NBD_DEV" >/dev/null
_NBD_CONNECTED=0
COMPLETED=1
trap - EXIT HUP INT TERM
rmdir -- "$MOUNT_DIR"
printf 'G11_SAFE_IDENTITY_JSON=%s\n' "$SAFE_IDENTITY_JSON"
echo "[g11-clone-verify] PASS: vm${VM_ID} / independent Windows OS identity / Guest Lite 2.6.4 fast path + Game Mode + Game DVR off + NVIDIA maximum performance + DNF High-on-launch + stale Temp cleaned + reviewed background processes stopped + audio muted + notifications off + taskbar search hidden + en-US/US first + Microsoft Pinyin second + MpsSvc Automatic/Running / GRID 538.33 / Code 0 / Licensed / x86+x64 system NVAPI + monitor identity validated"

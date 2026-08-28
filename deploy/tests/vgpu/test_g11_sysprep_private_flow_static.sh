#!/usr/bin/env bash
# Static contract for the portable private Sysprep clone workflow. No image is
# mounted and no licensed payload is required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
XML="$ROOT/deploy/autounattend/g11-sysprep-clone.xml"
FINALIZER="$ROOT/deploy/guest/finalize-g11-clone.ps1"
RETRY="$ROOT/deploy/guest/Retry-Clone-Initialization.cmd"
SEAL="$ROOT/deploy/guest/Seal-G11-Template.cmd"
SYSPREP_DIAGNOSTIC="$ROOT/deploy/guest/Collect-Sysprep-Diagnostics.ps1"
TEMPLATE_READINESS="$ROOT/deploy/guest/Assert-G11-Template-Ready.ps1"
TEMPLATE_RESET="$ROOT/deploy/guest/Reset-G11-Template-State.ps1"
GUEST_PERFORMANCE="$ROOT/deploy/guest/guest-performance/Optimize-Guest.ps1"
GUEST_LITE_ROOT="$ROOT/deploy/guest/guest-lite"
GUEST_LITE_MANIFEST="$GUEST_LITE_ROOT/clone-manifest.json"
INSTALLER="$ROOT/deploy/install-vgpu-portable-to-base.sh"
CLONE="$ROOT/deploy/scripts/clone-from-base.sh"
CREATE_DISK="$ROOT/deploy/scripts/create-disk.sh"
EXPORT="$ROOT/deploy/scripts/export-vgpu-base.sh"
IMPORT="$ROOT/deploy/scripts/import-vgpu-base.sh"
INITIAL="$ROOT/deploy/scripts/initialize-clone.sh"
REPAIR="$ROOT/deploy/scripts/repair-clone-init.sh"
REFRESH_BASE="$ROOT/deploy/scripts/refresh-g11-private-base.sh"
VERIFY="$ROOT/deploy/host/verify-g11-clone-ready.sh"
BUILD_BASE="$ROOT/deploy/build-g11-private-base.sh"
KIT="$ROOT/deploy/package-g11-sysprep-kit.sh"
START="$ROOT/deploy/scripts/start-vm.sh"
PACKAGER="$ROOT/deploy/package-system-nvapi-projection.sh"
COORDINATOR="$ROOT/deploy/guest/install-system-nvapi-projection.ps1"
INIT_MEDIA_WATCHER="$ROOT/deploy/host/watch-g11-init-media.py"
GUEST_LITE_ASSETS=(
    "$GUEST_LITE_ROOT/G11-Guest-Lite.ps1"
    "$GUEST_LITE_ROOT/01-OneClick-Apply.cmd"
    "$GUEST_LITE_ROOT/02-Audit.cmd"
    "$GUEST_LITE_ROOT/03-Rollback.cmd"
    "$GUEST_LITE_ROOT/README.txt"
)

fail() { echo "FAIL: $*" >&2; exit 1; }
for file in "$XML" "$FINALIZER" "$RETRY" "$SEAL" "$SYSPREP_DIAGNOSTIC" \
        "$TEMPLATE_READINESS" "$TEMPLATE_RESET" "$GUEST_PERFORMANCE" \
        "$INSTALLER" "$CLONE" "$CREATE_DISK" "$EXPORT" \
        "$IMPORT" "$INITIAL" "$REPAIR" "$REFRESH_BASE" "$VERIFY" \
        "$BUILD_BASE" "$KIT" "$START" \
        "$PACKAGER" "$COORDINATOR" "$INIT_MEDIA_WATCHER" \
        "$GUEST_LITE_MANIFEST" "${GUEST_LITE_ASSETS[@]}"; do
    [[ -s "$file" && ! -L "$file" ]] || fail "missing/unsafe asset: $file"
done
bash -n "$INSTALLER" "$CLONE" "$CREATE_DISK" "$EXPORT" "$IMPORT" "$INITIAL" \
    "$REPAIR" "$REFRESH_BASE" "$VERIFY" "$BUILD_BASE" "$KIT" "$START" "$PACKAGER"

python3 - "$XML" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
ns = {"u": "urn:schemas-microsoft-com:unattend"}
settings = {node.attrib["pass"]: node for node in root.findall("u:settings", ns)}
assert set(settings) == {"generalize", "specialize", "oobeSystem"}
persist = settings["generalize"].find(".//u:PersistAllDeviceInstalls", ns)
assert persist is not None and persist.text == "false"
name = settings["specialize"].find(".//u:ComputerName", ns)
assert name is None
expected_input = (
    "0409:00000409;"
    "0804:{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}"
    "{FA550B04-5AD7-411F-A5AC-CA038EC515D7}"
)
for pass_name in ("specialize", "oobeSystem"):
    input_locale = settings[pass_name].find(
        ".//u:component[@name='Microsoft-Windows-International-Core']"
        "/u:InputLocale",
        ns,
    )
    assert input_locale is not None and input_locale.text == expected_input
oobe = settings["oobeSystem"].find(".//u:OOBE", ns)
for key in (
    "HideEULAPage", "HideOEMRegistrationScreen", "HideOnlineAccountScreens",
    "HideLocalAccountScreen", "HideWirelessSetupInOOBE",
):
    value = oobe.find(f"u:{key}", ns)
    assert value is not None and value.text == "true"
command = settings["oobeSystem"].find(".//u:FirstLogonCommands/u:SynchronousCommand/u:CommandLine", ns)
assert command is not None
assert command.text == r"cmd.exe /d /c C:\ProgramData\VMate\G11\Retry-Clone-Initialization.cmd"
requires_input = settings["oobeSystem"].find(
    ".//u:FirstLogonCommands/u:SynchronousCommand/u:RequiresUserInput", ns
)
assert requires_input is not None and requires_input.text == "true"
specialize_paths = [
    node.text for node in settings["specialize"].findall(
        ".//u:RunSynchronousCommand/u:Path", ns
    )
]
assert any("LimitBlankPasswordUse" in path and "/d 1 /f" in path for path in specialize_paths)
PY

jq -e '
    (keys | sort) == ["files", "profileVersion", "schemaVersion"] and
    .schemaVersion == 1 and .profileVersion == "2.6.4" and
    ([.files[].name] | sort) == [
        "01-OneClick-Apply.cmd", "02-Audit.cmd", "03-Rollback.cmd",
        "G11-Guest-Lite.ps1", "README.txt"
    ]
' "$GUEST_LITE_MANIFEST" >/dev/null || fail "Guest Lite clone manifest is invalid"
guest_lite_manifest_sha=$(sha256sum "$GUEST_LITE_MANIFEST" | awk \
    '{print toupper($1)}')
grep -Fq "\$ExpectedGuestLiteManifestSha256 = '$guest_lite_manifest_sha'" \
    "$FINALIZER" || fail "clone finalizer does not pin the Guest Lite manifest"

grep -Fq -- '--site-private' "$INSTALLER" || fail "private installer option missing"
grep -Fq -- '--sysprep-generalized' "$INSTALLER" || fail "generalize acknowledgement missing"
grep -Fq 'QEMU_VGPU_PORTABLE_LICENSED_UNIFIED_V7' "$INSTALLER" ||
    fail "licensed V7 receipt validation missing"
grep -Fq 'site-private-licensed-firstboot-v2' "$INSTALLER" ||
    fail "private base deployment mode missing"
grep -Fq 'licensed-portable-system-nvapi-two-boot-v1' "$INSTALLER" ||
    fail "private two-stage first-boot workflow missing"
grep -Fq 'C:\\ProgramData\\VMate\\G11\\VgpuPortable.exe' "$INSTALLER" ||
    fail "fixed private guest path missing"
grep -Fq 'Users/Public/Desktop/VgpuPortable.exe' "$INSTALLER" ||
    fail "private base does not remove a stale generic portable EXE"
grep -Fq 'QemuGpuZProfile/last-result.json' "$INSTALLER" ||
    fail "private base does not reject an active portable result"
grep -Fq 'GUEST_LITE_STAGE="$WORK_ROOT/GuestLite"' "$INSTALLER" ||
    fail "private base does not stage Guest Lite"
grep -Fq 'verify_guest_lite_dir "$GUEST_LITE_DEST"' "$INSTALLER" ||
    fail "private base does not verify the published Guest Lite payload"
grep -Fq 'generalized template retained active clone state' "$INSTALLER" ||
    fail "private base does not reject an active clone rollback baseline"
for clone_state_root in QemuGpuZProfile G11GuestPerformance G11GuestLite; do
    grep -Fq "\"\$MOUNT_DIR/ProgramData/$clone_state_root\"" "$INSTALLER" ||
        fail "private base can leak clone state: $clone_state_root"
done
grep -Fq 'generalized template retained per-VM system NVAPI projection state' \
    "$INSTALLER" ||
    fail "private base does not reject per-VM system NVAPI projection state"
grep -Fq 'dls.gvmates.com' "$FINALIZER" || fail "fixed DLS host missing"
grep -Fq "'Licensed'" "$FINALIZER" || fail "Licensed validation missing"
grep -Fq "'31.0.15.3833'" "$FINALIZER" || fail "GRID 538.33 validation missing"
grep -Fq "'PCI\VEN_10DE&DEV_1E30'" "$FINALIZER" || fail "native PnP validation missing"
grep -Fq 'Get-WindowsOsIdentity' "$FINALIZER" || fail "Windows OS identity capture missing"
grep -Fq 'machineSid = $osIdentity.MachineSid' "$FINALIZER" ||
    fail "Windows machine SID receipt missing"
grep -Fq 'machineGuid = $osIdentity.MachineGuid' "$FINALIZER" ||
    fail "Windows MachineGuid receipt missing"
grep -Fq 'Disable-OneShotAutoLogon' "$FINALIZER" ||
    fail "one-shot Administrator auto-logon cleanup missing"
grep -Fq 'Finalize-BootstrapAdministrator' "$FINALIZER" ||
    fail "built-in Administrator lockout guard is missing"
grep -Fq 'if errorlevel 1 pause' "$ROOT/deploy/guest/Retry-Clone-Initialization.cmd" ||
    fail "automatic first-boot errors do not remain visible"
grep -Fq 'Get-CimAssociatedInstance' "$FINALIZER" ||
    fail "alternate local administrator validation is missing"
grep -Fq "\$activeSwitch = '/active:yes'" "$FINALIZER" ||
    fail "sole local Administrator is not kept available"
grep -Fq "\$activeSwitch = '/active:no'" "$FINALIZER" ||
    fail "bootstrap Administrator is not disabled when another administrator exists"
grep -Fq 'if (-not $readyForHost)' "$FINALIZER" ||
    fail "failed bootstrap can leave a stale host-ready marker"
grep -Fq "'/no-launch'" "$FINALIZER" || fail "single noninteractive EXE call missing"
[[ "$(grep -Fc 'Start-Process -FilePath $Portable' "$FINALIZER")" == 1 ]] ||
    fail "licensed VgpuPortable must have exactly one invocation site"
grep -Fq 'Register-CloneContinuationTask' "$FINALIZER" ||
    fail "post-reboot clone continuation is missing"
grep -Fq "[ValidateSet('Auto', 'Complete', 'Notice')]" "$FINALIZER" ||
    fail "interactive post-reboot notice phase is missing"
grep -Fq "\$ContinuationNoticeTaskName = 'VMate-G11-Clone-Notice'" \
    "$FINALIZER" || fail "post-reboot notice task has no stable identity"
notice_task=$(sed -n \
    '/^function Register-CloneContinuationNoticeTask {/,/^function Register-CloneContinuationTask {/p' \
    "$FINALIZER")
grep -Fq 'New-ScheduledTaskTrigger -AtLogOn -User $UserSid' \
    <<<"$notice_task" || fail "post-reboot notice is not tied to the clone user logon"
grep -Fq -- '-LogonType Interactive -RunLevel Limited' <<<"$notice_task" ||
    fail "post-reboot notice cannot enter the interactive user session"
grep -Fq 'Resolve-ScheduledTaskUserSid' "$FINALIZER" ||
    fail "post-reboot notice does not normalize Task Scheduler identities to SID"
if grep -Fq '[string]$task.Principal.UserId -cne $UserSid' <<<"$notice_task"; then
    fail "post-reboot notice still compares equivalent SID/account strings directly"
fi
grep -Fq -- '-Phase Notice' <<<"$notice_task" ||
    fail "post-reboot notice task does not launch the read-only notice phase"
grep -Fq '[System.Windows.Forms.ProgressBarStyle]::Marquee' "$FINALIZER" ||
    fail "post-reboot notice lacks an indeterminate progress indicator"
grep -Fq '$form.ControlBox = $false' "$FINALIZER" ||
    fail "running clone notice can be mistaken for a dismissible completion message"
grep -Fq 'Test-Path -LiteralPath $ErrorFile -PathType Leaf' "$FINALIZER" ||
    fail "post-reboot notice cannot surface a continuation failure"
grep -Fq 'Test-Path -LiteralPath $Marker -PathType Leaf' "$FINALIZER" ||
    fail "post-reboot notice cannot distinguish actual completion"
python3 - "$FINALIZER" <<'PY'
import base64
import re
import sys

source = open(sys.argv[1], encoding="ascii").read()
decoded = "\n".join(
    base64.b64decode(value).decode("utf-8")
    for value in re.findall(
        r"ConvertFrom-Utf8Base64\s+(?:`\s*)?'([A-Za-z0-9+/]{8,}={0,2})'",
        source,
    )
)
for required in (
    "这是第一次克隆后的自动重启。进入桌面不代表初始化已经完成。",
    "请勿关机、重启或注销。完成后虚拟机会自动关机。",
    "初始化失败，请勿强制关机。",
    "Retry-Clone-Initialization.cmd",
):
    assert required in decoded, f"post-reboot notice omits: {required}"
PY
grep -Fq -- '-Action Install' "$FINALIZER" ||
    fail "system NVAPI install stage is missing"
grep -Fq 'Read-And-ValidateProjectionReceipt' "$FINALIZER" ||
    fail "system NVAPI validated receipt gate is missing"
grep -Fq 'systemNvapiProjection = [ordered]@{' "$FINALIZER" ||
    fail "host-ready marker lacks system NVAPI evidence"
grep -Fq 'Read-And-ValidateGuestLitePayload' "$FINALIZER" ||
    fail "clone finalizer does not authenticate Guest Lite"
grep -Fq -- '-Mode CloneApply' "$FINALIZER" ||
    fail "clone finalizer does not apply Guest Lite unattended"
grep -Fq 'foreach ($candidate in @($standardError, $standardOutput))' "$FINALIZER" ||
    fail "clone finalizer does not surface redirected Guest Lite stdout failures"
grep -Fq 'Read-And-ValidateGuestLiteState -RequireFirewallReady' "$FINALIZER" ||
    fail "clone finalizer does not require MpsSvc after reboot"
guest_lite_state_reader=$(sed -n \
    '/^function Read-And-ValidateGuestLiteState {/,/^function Invoke-And-WaitGuestLiteEnforcement {/p' \
    "$FINALIZER")
grep -Fq '$stateMachineGuid -cne [string]$osIdentity.MachineGuid' \
    <<<"$guest_lite_state_reader" ||
    fail "clone finalizer does not bind Guest Lite state to the stable MachineGuid"
grep -Fq "Name = 'ToastEnabled'; Value = 0; Type = 'DWord'" \
    <<<"$guest_lite_state_reader" ||
    fail "clone finalizer does not verify the notification master switch"
grep -Fq "Name = 'SearchboxTaskbarMode'; Value = 0; Type = 'DWord'" \
    <<<"$guest_lite_state_reader" ||
    fail "clone finalizer does not verify hidden taskbar search"
grep -Fq "Name = 'HistoricalCaptureEnabled'; Value = 0; Type = 'DWord'" \
    <<<"$guest_lite_state_reader" ||
    fail "clone finalizer does not verify disabled Game DVR background recording"
grep -Fq "Name = 'AutoGameModeEnabled'; Value = 1; Type = 'DWord'" \
    <<<"$guest_lite_state_reader" ||
    fail "clone finalizer does not verify enabled Game Mode"
grep -Fq 'Image File Execution Options\DNF.exe\PerfOptions' \
    <<<"$guest_lite_state_reader" ||
    fail "clone finalizer does not verify persistent DNF High priority"
grep -Fq "Name = 'InputMethodOverride'; Value = '0409:00000409'; Type = 'String'" \
    <<<"$guest_lite_state_reader" ||
    fail "clone finalizer does not verify the en-US default input method"
grep -Fq '[int]$state.SchemaVersion -ne 6' \
    <<<"$guest_lite_state_reader" ||
    fail "clone finalizer does not require the audio/language/NVIDIA/DNF rollback schema"
grep -Fq '$GuestLiteEnglishInputTip' <<<"$guest_lite_state_reader" ||
    fail "clone finalizer does not verify en-US/US as the first input"
grep -Fq '$GuestLitePinyinInputTip' <<<"$guest_lite_state_reader" ||
    fail "clone finalizer does not verify Microsoft Pinyin as the second input"
grep -Fq "@('zh-CN', 'zh-Hans-CN')" "$FINALIZER" ||
    fail "clone finalizer does not accept the Windows 10 canonical Simplified Chinese tag"
grep -Fq 'Open-GuestLiteUserHive -UserSid ([string]$state.UserSid)' \
    <<<"$guest_lite_state_reader" ||
    fail "clone finalizer does not bind per-user checks to the saved SID hive"
grep -Fq "Registry::HKEY_USERS\\\$UserSid" "$FINALIZER" ||
    fail "clone finalizer does not address the target user hive under SYSTEM"
grep -Fq "'Languages', [string[]]@()" <<<"$guest_lite_state_reader" ||
    fail "clone finalizer does not verify language order from the target SID hive"
if grep -Fq '$state.ComputerName' <<<"$guest_lite_state_reader"; then
    fail "clone finalizer still binds Guest Lite state to the mutable computer name"
fi
grep -Fq '$resumeVerifiedProjection = $null -ne $projectionReceipt' \
    "$FINALIZER" ||
    fail "Auto retry does not detect an already validated projection reboot"
grep -Fq 'interactive Auto retry safely' "$FINALIZER" ||
    fail "Auto retry does not document the baseline-preserving profile upgrade"
grep -Fq -- '-RedirectStandardOutput $standardOutput' "$FINALIZER" ||
    fail "clone Guest Lite output is not redirected away from the rendered console"
grep -Fq -- '-RedirectStandardOutput $portableOutput' "$FINALIZER" ||
    fail "clone portable stdout is not persisted for retry diagnosis"
grep -Fq -- '-RedirectStandardError $portableError' "$FINALIZER" ||
    fail "clone portable stderr is not persisted for retry diagnosis"
grep -Fq -- "-Tail 24 -ErrorAction SilentlyContinue" "$FINALIZER" ||
    fail "clone portable failure does not include a bounded output tail"
grep -Fq "Clone log root must be a regular, non-reparse directory" "$FINALIZER" ||
    fail "clone portable log directory is not protected against reparse paths"
grep -Fq 'Invoke-And-WaitGuestLiteEnforcement' "$FINALIZER" ||
    fail "clone finalizer does not require a measured SYSTEM enforcement run"
enforcement_waiter=$(sed -n \
    '/^function Invoke-And-WaitGuestLiteEnforcement {/,/^function Invoke-GuestLiteCloneProfile {/p' \
    "$FINALIZER")
grep -Fq '$info.LastRunTime -gt $lastBootTime' <<<"$enforcement_waiter" ||
    fail "clone finalizer cannot reuse a clean enforcement run from this boot"
grep -Fq '$info.LastRunTime -gt $previousRunTime' "$FINALIZER" ||
    fail "Guest Lite task completion is still coupled to a wall-clock tolerance"
[[ "$(grep -Fc 'Start-ScheduledTask -TaskPath $taskPath' <<<"$enforcement_waiter")" == 1 ]] ||
    fail "clone finalizer has more than one fallback enforcement launch site"
grep -Fq -- '-MinimumGeneratedTime $lastBootTime' <<<"$enforcement_waiter" ||
    fail "clone finalizer accepts a stale pre-boot Guest Lite receipt"
grep -Fq -- '-ExpectedUserSid ([string]$guestLiteState.UserSid)' "$FINALIZER" ||
    fail "clone finalizer does not bind enforcement reuse to the saved user SID"
grep -Fq 'Guest Lite enforcement receipt does not match this clone identity.' \
    "$FINALIZER" ||
    fail "clone finalizer does not bind enforcement reuse to clone identity"
grep -Fq 'result=pass failures=0' "$FINALIZER" ||
    fail "clone finalizer does not validate the Guest Lite enforcement receipt"
grep -Fq 'firewallService=automatic-running' "$FINALIZER" ||
    fail "clone finalizer does not require a measured MpsSvc receipt"
grep -Fq 'audio=default-render-muted' "$FINALIZER" ||
    fail "clone finalizer does not require a measured default-audio mute receipt"
grep -Fq 'nvidiaPowerMode=prefer-maximum-performance' "$FINALIZER" ||
    fail "clone finalizer does not require measured NVIDIA maximum performance"
grep -Fq 'dnfPriority=high-if-running' "$FINALIZER" ||
    fail "clone finalizer does not require measured DNF priority enforcement"
grep -Fq 'processes=reviewed-stopped' "$FINALIZER" ||
    fail "clone finalizer does not require reviewed background processes to stop"
grep -Fq 'enforcementLastResult = [int64]$guestLiteEnforcement.LastTaskResult' \
    "$FINALIZER" || fail "clone marker lacks the Guest Lite task result"
grep -Fq 'schemaVersion = 4' "$FINALIZER" ||
    fail "clone-ready marker schema does not include Guest Lite evidence"
grep -Fq 'guestLite = [ordered]@{' "$FINALIZER" ||
    fail "clone-ready marker lacks Guest Lite evidence"
grep -Fq '.schemaVersion == 4' "$VERIFY" ||
    fail "host verifier does not require the Guest Lite-aware marker schema"
grep -Fq '.guestLite.firewallStartMode == "Auto"' "$VERIFY" ||
    fail "host verifier does not enforce Automatic MpsSvc startup"
grep -Fq '.guestLite.firewallState == "Running"' "$VERIFY" ||
    fail "host verifier does not enforce running MpsSvc state"
grep -Fq '.guestLite.firewallProcessId > 0' "$VERIFY" ||
    fail "host verifier does not require a live MpsSvc process"
grep -Fq '.guestLite.baseFilteringEngine == "preserved-running"' "$VERIFY" ||
    fail "host verifier does not enforce BFE preservation"
grep -Fq '.guestLite.enforcementLastResult == 0' "$VERIFY" ||
    fail "host verifier does not require a clean Guest Lite SYSTEM run"
grep -Fq '.guestLite.notifications == "disabled"' "$VERIFY" ||
    fail "host verifier does not require notifications to be disabled"
grep -Fq '.guestLite.taskbarSearch == "hidden"' "$VERIFY" ||
    fail "host verifier does not require taskbar search to be hidden"
grep -Fq '.guestLite.defaultInputMethod == "0409:00000409"' "$VERIFY" ||
    fail "host verifier does not require the en-US default input method"
grep -Fq '.guestLite.inputOrder == "en-US/US,zh-CN/Microsoft-Pinyin"' "$VERIFY" ||
    fail "host verifier does not require en-US first and Microsoft Pinyin second"
grep -Fq '.guestLite.audio == "muted"' "$VERIFY" ||
    fail "host verifier does not require default audio to be muted"
grep -Fq '.guestLite.gameMode == "enabled"' "$VERIFY" ||
    fail "host verifier does not require enabled Game Mode"
grep -Fq '.guestLite.gameDvr == "disabled"' "$VERIFY" ||
    fail "host verifier does not require disabled Game DVR"
grep -Fq '.guestLite.nvidiaPowerMode == "prefer-maximum-performance"' "$VERIFY" ||
    fail "host verifier does not require NVIDIA maximum performance"
grep -Fq '.guestLite.dnfPriority == "high-on-launch"' "$VERIFY" ||
    fail "host verifier does not require persistent DNF High priority"
grep -Fq '.guestLite.temporaryCleanup == "stale-files-over-24h-completed"' "$VERIFY" ||
    fail "host verifier does not require the temporary-cleanup receipt"
grep -Fq '.guestLite.backgroundProcesses == "reviewed-stopped"' "$VERIFY" ||
    fail "host verifier does not require reviewed background processes to stop"
safe_identity_block=$(sed -n \
    '/^SAFE_IDENTITY_JSON=/,/^umount -- /p' "$VERIFY")
if grep -Fq 'guestLiteProfile:' <<<"$safe_identity_block"; then
    fail "host verifier leaks non-identity Guest Lite data into its strict identity contract"
fi
if grep -Eiq 'bcdedit([.]exe)?[[:space:]]+/(set|deletevalue)|testsigning[[:space:]]+(on|yes|true|1)|nointegritychecks[[:space:]]+(on|yes|true|1)' \
        "$XML" "$FINALIZER" "$INSTALLER" "$CLONE" "$EXPORT" "$IMPORT" \
        "$INITIAL" "$REPAIR" "$REFRESH_BASE" "$VERIFY" "$PACKAGER" \
        "$SYSPREP_DIAGNOSTIC" "$TEMPLATE_READINESS" "$TEMPLATE_RESET" \
        "$COORDINATOR"; then
    fail "forbidden BCD/code-integrity mutation found"
fi

grep -Fq '.g11-init-required' "$CLONE" || fail "clone initialization gate missing"
grep -Fq 'ATTESTED_FINALIZER_SHA256' "$CLONE" ||
    fail "private clone does not bind the base to the current finalizer"
grep -Fq 'refresh-g11-private-base.sh' "$CLONE" ||
    fail "obsolete private base refusal lacks a packaged remediation"
grep -Fq 'package-system-nvapi-projection.sh' "$CLONE" ||
    fail "private clone does not build its per-VM system NVAPI package"
grep -Fq 'G11_INIT_REQUIRED="$SELECTED_VM_DIR/.g11-init-required"' "$START" ||
    fail "first boot does not recognize the private initialization gate"
grep -Fq 'media=cdrom,readonly=on' "$START" ||
    fail "first boot does not attach the per-VM package read-only"
grep -Fq 'g11-init-odd-usb' "$START" ||
    fail "first boot lacks the dedicated non-boot initialization optical device"
grep -Fq 'usb-bot,id=g11-init-odd-usb' "$START" ||
    fail "first boot initialization media does not use the reviewed USB-BOT stack"
grep -Fq 'scsi-cd,id=g11-init-odd' "$START" ||
    fail "first boot initialization media lacks a true optical model"
grep -Fq 'x-no-serial=on' "$START" ||
    fail "first boot optical transport invents a USB serial"
if grep -Fq 'g11-init-odd-usb,bus=xhci.0,port=3,attached=on' "$START"; then
    fail "command-line usb-bot incorrectly presets its runtime attached property"
fi
grep -Fq 'watch-g11-init-media.py' "$START" ||
    fail "first boot lacks automatic temporary optical hot-remove"
grep -Fq 'blockdev-open-tray' "$INIT_MEDIA_WATCHER" &&
    fail "host watcher can open/eject guest media instead of only observing it"
grep -Fq 'device_del' "$INIT_MEDIA_WATCHER" ||
    fail "host watcher cannot remove the temporary optical frontends"
grep -Fq 'IOCTL_STORAGE_EJECT_MEDIA' "$COORDINATOR" ||
    fail "guest coordinator does not signal durable payload completion by eject"
grep -Fq 'Prepare-V11CloneComputerName $payload' "$COORDINATOR" ||
    fail "current private bases cannot normalize ADMINS-* to V-11 DESKTOP-*"
grep -Fq 'EXPECTED_COMPUTER_NAME="DESKTOP-${EXPECTED_UUID//-/}"' "$VERIFY" ||
    fail "host verifier does not enforce the V-11-style clone name"
grep -Fq 'EXPECTED_COMPUTER_NAME=${EXPECTED_COMPUTER_NAME^^}' "$VERIFY" ||
    fail "host verifier does not normalize the V-11-style clone name to uppercase"
grep -Fq 'EXPECTED_COMPUTER_NAME=${EXPECTED_COMPUTER_NAME^^}' "$INITIAL" ||
    fail "one-click initializer does not normalize the V-11-style clone name to uppercase"
if grep -Fq 'local status=$? cleanup_status=$status' "$VERIFY"; then
    fail "host verifier cleanup reads an unbound local under set -u"
fi
grep -Fq 'MONITOR_SYNC=0' "$START" ||
    fail "first boot does not defer monitor refresh to one-click initialization"
grep -Fq -- '--vms-dir' "$BUILD_BASE" || fail "VMate/custom G-11 root selection missing"
grep -Fq -- '--base-dir' "$BUILD_BASE" || fail "V-11-style base directory selection missing"
grep -Fq '${IMAGE_ROOT:-/home/ubuntu/images}/vms' "$BUILD_BASE" ||
    fail "V-11-style default VM root missing"
if grep -Fq 'g11-vms' "$BUILD_BASE"; then
    fail "private base builder retains the obsolete G-11 default root"
fi
grep -Fq 'COMPRESSION_TYPE=zstd' "$BUILD_BASE" ||
    fail "G-11 private base does not default to fast zstd compression"
grep -Fq -- '--compression-parallel' "$BUILD_BASE" ||
    fail "G-11 private base compression parallelism is not configurable"
grep -Fq 'SEAL_ARGS+=(--progress)' "$BUILD_BASE" ||
    fail "G-11 private base compression progress is not enabled"
grep -Fq '"$SOURCE_VM_ID" "$BASE_NAME" --yes --single-image' "$BUILD_BASE" ||
    fail "one-command builder does not request V-11-style single-image sealing"
grep -Fq 'chmod 0600 -- "$SEALED_BASE"' "$BUILD_BASE" ||
    fail "private base is not made owner-only before credential injection"
grep -Fq -- '--single-image --yes' "$BUILD_BASE" ||
    fail "one-command builder retains the portable installer rollback archive"
grep -Fq 'export-vgpu-base.sh" --in-place' "$BUILD_BASE" ||
    fail "one-command builder still copies a second delivery qcow2"
grep -Fq 'one qcow2 / local + delivery' "$EXPORT" ||
    fail "in-place export does not identify the shared local/delivery image"
grep -Fq 'BASE_NAME_OR_QCOW2 NEW_VM_ID' "$CLONE" ||
    fail "clone command does not match V-11 name-or-path selection"
grep -Fq -- '--base-dir' "$CLONE" ||
    fail "clone command lacks V-11-style --base-dir"
grep -Fq 'CLONE_DISK_MODE=linked' "$CLONE" ||
    fail "G-11 clone does not default to a V-11-style incremental disk"
grep -Fq 'DISK_BASE_ARGS+=(--linked)' "$CLONE" ||
    fail "clone does not forward the linked-disk contract"
grep -Fq -- '--full-copy' "$CLONE" ||
    fail "clone lacks the explicit standalone-copy escape hatch"
grep -Fq 'vm_storage_instance_base_pin_path' "$CREATE_DISK" ||
    fail "disk creator lacks the instance-local base inode pin"
grep -Fq -- '-b "$(basename "$BASE_PIN")"' "$CREATE_DISK" ||
    fail "disk creator lacks a relative qcow2 backing file"
grep -Fq 'linked clone must use the fixed relative .base.qcow2 pin' "$VERIFY" ||
    fail "host verifier accepts an arbitrary linked-clone backing path"
grep -Fq '实例盘: V-11 式增量盘 / backing=.base.qcow2' "$START" ||
    fail "normal start does not validate/report the incremental disk"
grep -Fq 'verify-g11-clone-ready.sh' "$INITIAL" || fail "host guest-result verifier missing"
grep -Fq 'guest initialization failure:' "$VERIFY" ||
    fail "host verifier does not surface the persisted guest failure"
grep -Fq 'tr -cd' "$VERIFY" ||
    fail "host verifier prints untrusted guest errors without control-byte filtering"
grep -Fq 'guest marker diagnostics:' "$VERIFY" ||
    fail "host verifier does not explain marker contract failures"
grep -Fq 'guest-lite-schema-or-version' "$VERIFY" ||
    fail "host verifier diagnostics do not identify obsolete Guest Lite markers"
grep -Fq 'nbd_connect NBD "$DISK" read-write' "$REPAIR" ||
    fail "repair-init does not refresh the stopped guest payload"
grep -Fq 'Finalize-Clone.ps1' "$REPAIR" ||
    fail "repair-init does not publish the current clone finalizer"
grep -Fq 'verify_guest_lite_dir "$GUEST_LITE_DEST"' "$REPAIR" ||
    fail "repair-init does not verify Guest Lite after offline publication"
grep -Fq 'clone-initialization.json' "$REPAIR" ||
    fail "repair-init does not clear an obsolete guest completion marker"
grep -Fq 'ntfs-3g.probe --readwrite' "$REPAIR" ||
    fail "repair-init can write a dirty or hibernated Windows volume"
if grep -Fq 'QemuGpuZProfile/last-result.json' "$REPAIR"; then
    fail "repair-init removes the reusable licensed VgpuPortable result"
fi
if grep -Eiq 'pnputil|dism([.]exe)?[[:space:]].*/add-driver|DriverStore.*(rm|remove)|[.]sys([^A-Za-z]|$)' \
        "$REPAIR"; then
    fail "repair-init contains a kernel-driver installation/removal path"
fi
grep -Fq -- '--site-private' "$REFRESH_BASE" ||
    fail "private base refresh does not use the reviewed private installer"
grep -Fq 'export-vgpu-base.sh" --in-place' "$REFRESH_BASE" ||
    fail "private base refresh does not update the one-image transfer manifest"
grep -Fq 'Windows OS identity duplicates another initialized G-11 VM' "$INITIAL" ||
    fail "host Windows OS identity uniqueness gate missing"
grep -Fq 'sync-monitor-profile.sh" "$VM_ID" --force' "$INITIAL" ||
    fail "one-click forced monitor refresh missing"
grep -Fq 'rm -f -- "$REQUIRED_MARKER"' "$INITIAL" ||
    fail "initialization gate is not cleared after success"
grep -Fq 'systemNvapiVerified: true' "$INITIAL" ||
    fail "one-click final state does not record system NVAPI verification"
grep -Fq 'vmate-g11-private-base-v2' "$EXPORT" || fail "portable export manifest missing"
grep -Fq 'vmate-g11-private-base-v2' "$IMPORT" || fail "portable import validation missing"
grep -Fq 'source:    retained' "$IMPORT" || fail "copy-only import result missing"
grep -Fq 'target qemu-img cannot read this qcow2 compression format' "$IMPORT" ||
    fail "target-side qcow2 compression compatibility gate missing"
if grep -Eq '^for dependency in .*qemu-img' "$IMPORT"; then
    fail "portable import must accept packaged QEMU_IMG without system qemu-img"
fi
if grep -Fq 'licenseTokenSha256' "$EXPORT" "$IMPORT"; then
    fail "token fingerprint leaked into portable manifest scripts"
fi

KIT_TMP=$(mktemp -d)
trap 'rm -rf -- "$KIT_TMP"' EXIT
"$KIT" "$KIT_TMP/G11SysprepKit" >/dev/null
"$KIT" "$KIT_TMP/G11SysprepKit" --replace >/dev/null
cmp -- "$XML" "$KIT_TMP/G11SysprepKit/g11-sysprep-clone.xml" ||
    fail "refreshed Sysprep kit does not contain the current answer file"
cmp -- "$FINALIZER" "$KIT_TMP/G11SysprepKit/Payload/Finalize-Clone.ps1" ||
    fail "complete Sysprep kit does not contain the current finalizer"
cmp -- "$GUEST_LITE_MANIFEST" \
    "$KIT_TMP/G11SysprepKit/Payload/GuestLite/clone-manifest.json" ||
    fail "complete Sysprep kit does not contain the pinned Guest Lite manifest"
[[ -s "$KIT_TMP/G11SysprepKit/Standalone-GuestLite/G11GuestLite.exe" ]] ||
    fail "complete Sysprep kit does not contain the compiled Guest Lite EXE"
expected_kit_files=$(cat <<'EOF'
Assert-G11-Template-Ready.ps1
Collect-Sysprep-Diagnostics.ps1
G11-Sysprep-README.txt
Payload/Finalize-Clone.ps1
Payload/GuestLite/01-OneClick-Apply.cmd
Payload/GuestLite/02-Audit.cmd
Payload/GuestLite/03-Rollback.cmd
Payload/GuestLite/G11-Guest-Lite.ps1
Payload/GuestLite/README.txt
Payload/GuestLite/clone-manifest.json
Payload/Retry-Clone-Initialization.cmd
Reset-G11-Template-State.ps1
Seal-G11-Template.cmd
Standalone-GuestLite/G11GuestLite.exe
Template-Reset/GuestLite/G11-Guest-Lite.ps1
Template-Reset/GuestPerformance/Optimize-Guest.ps1
g11-sysprep-clone.xml
EOF
)
actual_kit_files=$(find "$KIT_TMP/G11SysprepKit" -type f -printf '%P\n' | LC_ALL=C sort)
[[ "$actual_kit_files" == "$expected_kit_files" ]] ||
    fail "complete Sysprep kit file set differs from the reviewed contract"
grep -Fq 'set "PAYLOAD=%~dp0Payload"' "$SEAL" ||
    fail "Seal entry point does not locate the collected public payload"
grep -Fq 'move /y "%GUESTLITE_NEW%" "%DEST%\GuestLite"' "$SEAL" ||
    fail "Seal entry point does not stage Guest Lite into ProgramData"
grep -Fq 'Standalone-GuestLite\G11GuestLite.exe' "$SEAL" ||
    fail "Seal entry point does not reject an incomplete compiled kit"
grep -Fq 'G11SysprepKit cannot be stored in or below' "$SEAL" ||
    fail "Seal entry point does not reject ProgramData source placement"
grep -Fq 'Collect-Sysprep-Diagnostics.ps1' "$SEAL" ||
    fail "Seal entry point does not collect Sysprep failure diagnostics"
grep -Fq 'Get-MpComputerStatus' "$TEMPLATE_READINESS" ||
    fail "template readiness gate does not query supported Defender status"
grep -Fq "PSObject.Properties['IsTamperProtected']" "$TEMPLATE_READINESS" ||
    fail "template readiness gate does not require explicit Tamper status"
grep -Fq 'turn Tamper Protection OFF manually' "$TEMPLATE_READINESS" ||
    fail "template readiness gate does not preserve the manual Windows Security boundary"
grep -Fq 'Per-VM system NVAPI projection state' "$TEMPLATE_READINESS" ||
    fail "template readiness gate can seal VM-bound system projection state"
if grep -Eiq 'Set-MpPreference|Set-ItemProperty|New-ItemProperty|Remove-Item(Property)?|reg([.]exe)?[[:space:]]+(add|delete)|takeown|icacls' \
        "$TEMPLATE_READINESS"; then
    fail "read-only template readiness gate contains a security/state mutation"
fi
grep -Fq "Invoke-SavedRollbackIfPresent \$GuestLiteRoot" "$TEMPLATE_RESET" ||
    fail "template reset does not roll back Guest Lite"
grep -Fq "Invoke-SavedRollbackIfPresent \$PerformanceRoot" "$TEMPLATE_RESET" ||
    fail "template reset does not roll back guest performance"
grep -Fq 'contains a reparse point; refusing recursive removal' "$TEMPLATE_RESET" ||
    fail "template reset recursively removes unchecked reparse paths"
grep -Fq "'licensed portable clone result'" "$TEMPLATE_RESET" ||
    fail "template reset does not remove portable clone output"
grep -Fq 'Windows SID and MachineGuid were not edited' "$TEMPLATE_RESET" ||
    fail "template reset does not document the Sysprep identity boundary"
cmp -- "$GUEST_LITE_ROOT/G11-Guest-Lite.ps1" \
    "$KIT_TMP/G11SysprepKit/Template-Reset/GuestLite/G11-Guest-Lite.ps1" ||
    fail "Sysprep kit reset helper is not the reviewed Guest Lite script"
cmp -- "$GUEST_PERFORMANCE" \
    "$KIT_TMP/G11SysprepKit/Template-Reset/GuestPerformance/Optimize-Guest.ps1" ||
    fail "Sysprep kit reset helper is not the reviewed performance script"
grep -Fq '0x800F0975' "$SYSPREP_DIAGNOSTIC" ||
    fail "Sysprep diagnostics do not identify the reserved-storage blocker"
grep -Fq '0x80073cf2' "$SYSPREP_DIAGNOSTIC" ||
    fail "Sysprep diagnostics do not identify Appx provisioning mismatch"
if grep -Eiq 'Remove-AppxPackage|Remove-AppxProvisionedPackage|Set-ReservedStorageState|ReserveManager.*(Set|New-ItemProperty)|bcdedit' \
        "$SYSPREP_DIAGNOSTIC"; then
    fail "Sysprep diagnostic collector contains an automatic destructive repair"
fi
seal_sysprep_line=$(grep -n 'Sysprep.exe.* /generalize /oobe /shutdown ' "$SEAL" |
    cut -d: -f1)
seal_readiness_line=$(grep -n 'ExecutionPolicy Bypass -File "%READINESS%"' "$SEAL" |
    cut -d: -f1)
seal_reset_line=$(grep -n 'ExecutionPolicy Bypass -File "%RESET%"' "$SEAL" |
    cut -d: -f1)
seal_stage_line=$(grep -n '^set "GUESTLITE_NEW=' "$SEAL" | cut -d: -f1)
seal_success_exit_line=$(grep -n '^exit /b 0$' "$SEAL" | cut -d: -f1)
seal_stage_error_line=$(grep -n '^:stage_error$' "$SEAL" | cut -d: -f1)
[[ "$seal_sysprep_line" =~ ^[0-9]+$ &&
   "$seal_readiness_line" =~ ^[0-9]+$ &&
   "$seal_reset_line" =~ ^[0-9]+$ &&
   "$seal_stage_line" =~ ^[0-9]+$ &&
   "$seal_success_exit_line" =~ ^[0-9]+$ &&
   "$seal_stage_error_line" =~ ^[0-9]+$ &&
   "$seal_readiness_line" -lt "$seal_reset_line" &&
   "$seal_reset_line" -lt "$seal_stage_line" &&
   "$seal_stage_line" -lt "$seal_sysprep_line" &&
   "$seal_sysprep_line" -lt "$seal_success_exit_line" &&
   "$seal_success_exit_line" -lt "$seal_stage_error_line" ]] ||
    fail "Seal entry point can exit or enter its error label before Sysprep"

mkdir "$KIT_TMP/LegacyKit"
cp -- "$ROOT/deploy/guest/G11-Sysprep-README.txt" \
    "$ROOT/deploy/guest/Seal-G11-Template.cmd" \
    "$XML" "$KIT_TMP/LegacyKit/"
"$KIT" "$KIT_TMP/LegacyKit" --replace >/dev/null
[[ -s "$KIT_TMP/LegacyKit/Standalone-GuestLite/G11GuestLite.exe" ]] ||
    fail "--replace did not safely upgrade a recognized legacy three-file kit"
cp -a -- "$KIT_TMP/G11SysprepKit" "$KIT_TMP/PreviousCompleteKit"
rm -rf -- "$KIT_TMP/PreviousCompleteKit/Template-Reset"
rm -- "$KIT_TMP/PreviousCompleteKit/Assert-G11-Template-Ready.ps1" \
    "$KIT_TMP/PreviousCompleteKit/Reset-G11-Template-State.ps1" \
    "$KIT_TMP/PreviousCompleteKit/Collect-Sysprep-Diagnostics.ps1"
"$KIT" "$KIT_TMP/PreviousCompleteKit" --replace >/dev/null
[[ -s "$KIT_TMP/PreviousCompleteKit/Collect-Sysprep-Diagnostics.ps1" ]] ||
    fail "--replace did not safely upgrade the previous complete kit"
cp -a -- "$KIT_TMP/G11SysprepKit" "$KIT_TMP/DiagnosticCompleteKit"
rm -rf -- "$KIT_TMP/DiagnosticCompleteKit/Template-Reset"
rm -- "$KIT_TMP/DiagnosticCompleteKit/Assert-G11-Template-Ready.ps1" \
    "$KIT_TMP/DiagnosticCompleteKit/Reset-G11-Template-State.ps1"
"$KIT" "$KIT_TMP/DiagnosticCompleteKit" --replace >/dev/null
[[ -s "$KIT_TMP/DiagnosticCompleteKit/Assert-G11-Template-Ready.ps1" &&
   -s "$KIT_TMP/DiagnosticCompleteKit/Template-Reset/GuestPerformance/Optimize-Guest.ps1" ]] ||
    fail "--replace did not safely upgrade the diagnostic complete kit"
touch "$KIT_TMP/G11SysprepKit/operator-file.txt"
if "$KIT" "$KIT_TMP/G11SysprepKit" --replace >/dev/null 2>&1; then
    fail "Sysprep kit replacement deleted an unknown operator file"
fi

echo "PASS: private Sysprep/OOBE-skip/single-portable-call/per-VM-system-NVAPI/portable-import/one-click-init contract"

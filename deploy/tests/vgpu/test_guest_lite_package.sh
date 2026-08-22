#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
packager="$root/deploy/package-guest-lite.sh"
wrapper="$root/deploy/scripts/guest-lite.sh"
guest="$root/deploy/guest/guest-lite/G11-Guest-Lite.ps1"
clone_manifest="$root/deploy/guest/guest-lite/clone-manifest.json"
finalizer="$root/deploy/guest/finalize-g11-clone.ps1"
exe_builder="$root/deploy/guest/guest-lite/exe/build.sh"
exe_source="$root/deploy/guest/guest-lite/exe/guest_lite_launcher.c"
exe_manifest="$root/deploy/guest/guest-lite/exe/guest_lite_launcher.manifest"

fail() { echo "FAIL: $*" >&2; exit 1; }
for dependency in xorriso mktemp rg strings cmp jq sha256sum stat \
        x86_64-w64-mingw32-gcc x86_64-w64-mingw32-windres \
        x86_64-w64-mingw32-objdump; do
    command -v "$dependency" >/dev/null 2>&1 \
        || fail "missing dependency: $dependency"
done

bash -n "$packager"
bash -n "$wrapper"
bash -n "$exe_builder"
[[ -x "$exe_builder" ]] || fail 'EXE builder is not executable'
[[ -s "$clone_manifest" && ! -L "$clone_manifest" ]] \
    || fail 'clone manifest is missing or unsafe'

tmp=$(mktemp -d)
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT INT TERM
output="$tmp/output"
iso=$("$packager" --output-root "$output" --print-path)
[[ "$iso" == "$output/G11GuestLite/G11GuestLite.iso" &&
   -s "$iso" && ! -L "$iso" ]] \
    || fail 'packager did not publish the fixed-name ISO'
[[ "$("$packager" --output-root "$output" --print-path)" == "$iso" ]] \
    || fail 'rebuild changed the fixed ISO path'
package_dir=$("$packager" --output-root "$output" --print-dir-path)
[[ "$package_dir" == "$output/G11GuestLite" &&
   -d "$package_dir" && ! -L "$package_dir" ]] \
    || fail 'packager did not publish the fixed USB directory'
exe=$("$packager" --output-root "$output" --print-exe-path)
[[ "$exe" == "$package_dir/G11GuestLite.exe" && -s "$exe" && ! -L "$exe" ]] \
    || fail 'packager did not publish a safe standalone EXE'

fake_vms="$tmp/vms"
fake_id=919904
mkdir -p "$fake_vms/$fake_id"
touch "$fake_vms/$fake_id/vm.conf"
"$wrapper" "$fake_id" prepare --vms-dir "$fake_vms" >/dev/null
[[ -d "$fake_vms/shared/usb/G11GuestLite" &&
   -f "$fake_vms/shared/usb/G11GuestLite/G11GuestLite.exe" &&
   -f "$fake_vms/shared/usb/G11GuestLite/G11GuestLite.iso" ]] \
    || fail 'guest-lite wrapper did not use its fixed public USB child directory'

"$exe_builder" --output "$tmp/direct-a.exe" >/dev/null
"$exe_builder" --output "$tmp/direct-b.exe" >/dev/null
cmp -s "$tmp/direct-a.exe" "$tmp/direct-b.exe" \
    || fail 'standalone EXE build is not reproducible'
cmp -s "$exe" "$tmp/direct-a.exe" \
    || fail 'published EXE differs from the reviewed direct build'

listing=$(xorriso -indev "$iso" -find / -type f -exec echo 2>/dev/null)
for expected in G11GuestLite.exe G11-Guest-Lite.ps1 \
        01-OneClick-Apply.cmd 02-Audit.cmd \
        03-Rollback.cmd README.txt; do
    rg -Fq "/$expected" <<<"$listing" || fail "ISO omitted $expected"
done
if rg -q '/(SHA256SUMS|ISO-SHA256)\.txt' <<<"$listing"; then
    fail 'ISO still contains a content-hash manifest'
fi

extracted="$tmp/extracted"
mkdir -p "$extracted"
xorriso -osirrox on -indev "$iso" -extract / "$extracted" \
    >/dev/null 2>&1

for launcher in "$extracted"/*.cmd; do
    LC_ALL=C rg -q $'\r$' "$launcher" \
        || fail "launcher is not CRLF: $launcher"
done

jq -e '
    (keys | sort) == ["files", "profileVersion", "schemaVersion"] and
    .schemaVersion == 1 and .profileVersion == "2.5.2" and
    (.files | length) == 5 and
    ([.files[].name] | sort) == [
        "01-OneClick-Apply.cmd", "02-Audit.cmd", "03-Rollback.cmd",
        "G11-Guest-Lite.ps1", "README.txt"
    ] and
    ([.files[].name] | unique | length) == 5 and
    all(.files[];
        (.sha256 | test("^[0-9A-F]{64}$")) and
        (.bytes | type) == "number" and .bytes > 0 and
        (.bytes | floor) == .bytes)
' "$clone_manifest" >/dev/null || fail 'clone manifest schema is invalid'
while IFS=$'\t' read -r name expected_sha expected_bytes; do
    actual_sha=$(sha256sum "$extracted/$name" | awk '{print toupper($1)}')
    [[ "$actual_sha" == "$expected_sha" &&
       "$(stat -c %s -- "$extracted/$name")" == "$expected_bytes" ]] \
        || fail "clone manifest does not pin packaged asset: $name"
done < <(jq -r '.files[] | [.name, .sha256, (.bytes | tostring)] | @tsv' \
    "$clone_manifest")

pe_header=$(x86_64-w64-mingw32-objdump -f "$exe")
rg -q 'file format pei-x86-64' <<<"$pe_header" \
    || fail 'standalone launcher is not a 64-bit Windows PE'
pe_imports=$(x86_64-w64-mingw32-objdump -p "$exe")
for dll in ADVAPI32.dll bcrypt.dll KERNEL32.dll SHELL32.dll USER32.dll; do
    rg -Fq "DLL Name: $dll" <<<"$pe_imports" \
        || fail "standalone launcher omitted expected system import: $dll"
done
while IFS= read -r dll; do
    case "${dll,,}" in
        advapi32.dll|bcrypt.dll|kernel32.dll|msvcrt.dll|shell32.dll|user32.dll) ;;
        *) fail "standalone launcher has a non-inbox/unreviewed DLL import: $dll" ;;
    esac
done < <(sed -n 's/^[[:space:]]*DLL Name: //p' <<<"$pe_imports")
exe_ascii=$(strings -a "$exe")
for token in requireAdministrator G11-Guest-Lite.ps1 \
        DisableAntiSpyware Invoke-Rollback; do
    rg -Fq "$token" <<<"$exe_ascii" \
        || fail "standalone launcher omitted embedded token: $token"
done
exe_wide=$(strings -a -el "$exe")
for token in 'G11GuestLite.exe /apply' 'G11GuestLite.exe /audit' \
        'G11GuestLite.exe /rollback' \
        'WindowsPowerShell\v1.0\powershell.exe' \
        'G-11 Windows 10 Guest Lite 2.5.2'; do
    rg -Fq "$token" <<<"$exe_wide" \
        || fail "standalone launcher omitted fixed entry point: $token"
done
rg -Fq 'DRIVE_CDROM' "$exe_source" \
    || fail 'standalone launcher cannot safely install itself from the ISO'
rg -Fq 'DRIVE_REMOVABLE' "$exe_source" \
    || fail 'standalone launcher cannot install itself from the managed USB disk'
rg -Fq 'Some Windows' "$exe_source" \
    || fail 'standalone launcher omitted the FAT package-media compatibility path'
rg -Fq 'level="requireAdministrator"' "$exe_manifest" \
    || fail 'standalone launcher omitted its UAC manifest'
rg -Fq 'assemblyIdentity version="2.5.2.0"' "$exe_manifest" \
    || fail 'standalone launcher manifest version is stale'
if rg -n 'bundle_id|G11GuestLite-\$|G11GuestLite-\*|sha256sum|SHA256SUMS|ISO-SHA256' \
        "$packager"; then
    fail 'guest-lite packager still contains content-addressed output logic'
fi
for action in usb-mount usb-status usb-eject; do
    rg -Fq "$action" "$wrapper" \
        || fail "guest-lite wrapper omitted USB action: $action"
done

for required in \
        'IsTamperProtected' \
        'Tamper Protection state cannot be verified while the Defender engine is active' \
        'Defender engine is already inactive; continuing without a bypass' \
        "[string]\$defender.WinDefendState -notin @('Running', 'StartPending')" \
        '-not [bool]$defender.MsMpEngProcessRunning' \
        'Get-OptionalRegistryValue' \
        'Ensure-RegistryKey' \
        'if (-not (Test-Path -LiteralPath $Path))' \
        'OnboardingState' \
        'Set-MpPreference' \
        'DisableRealtimeMonitoring' \
        'DisableAntiSpyware' \
        'Stop-CurrentDefenderScan' \
        'ScanAvgCPULoadFactor' \
        'MsMpEngProcessRunning' \
        'AMServiceEnabled' \
        'DefenderPreferences' \
        'Restore-DefenderPreferenceSnapshots' \
        'Set-NetFirewallProfile' \
        'FirewallProfiles' \
        "FirewallServiceName = 'MpsSvc'" \
        'Disable-FirewallService' \
        'Start-ScheduledTask' \
        'BFE and other core networking services' \
        'DisableFileSyncNGSC' \
        'ShellFeedsTaskbarViewMode' \
        'LetAppsRunInBackground' \
        "Name = 'SearchboxTaskbarMode'; Type = 'DWord'; Value = 0; Group = 'Taskbar'" \
        "Name = 'ToastEnabled'; Type = 'DWord'; Value = 0; Group = 'Notifications'" \
        "Name = 'NoToastApplicationNotification'; Type = 'DWord'; Value = 1; Group = 'Notifications'" \
        "Name = 'NoToastApplicationNotificationOnLockScreen'; Type = 'DWord'; Value = 1; Group = 'Notifications'" \
        "Name = 'DisableNotificationCenter'; Type = 'DWord'; Value = 1; Group = 'Notifications'" \
        "Name = 'DisableNotifications'; Type = 'DWord'; Value = 1; Group = 'Notifications'" \
        "Name = 'InputMethodOverride'; Type = 'String'; Value = '0409:00000409'; Group = 'Input'" \
        "EnglishLanguageTag = 'en-US'" \
        "EnglishInputTip = '0409:00000409'" \
        "PinyinLanguageTag = 'zh-CN'" \
        "PinyinCanonicalLanguageTag = 'zh-Hans-CN'" \
        '0804:{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}{FA550B04-5AD7-411F-A5AC-CA038EC515D7}' \
        'Get-UserLanguageListSnapshot' \
        'Set-PreferredUserLanguageList' \
        'Restore-UserLanguageListSnapshot' \
        '$liveLanguages = Get-WinUserLanguageList -ErrorAction Stop' \
        '$languageIndex -lt $liveLanguages.Count' \
        '$desired.Add($PinyinLanguageTag)' \
        'Initialize-AudioEndpointInterop' \
        'IAudioEndpointVolume' \
        'Get-AudioEndpointSnapshot' \
        'Set-DefaultAudioMuted' \
        'Restore-AudioEndpointSnapshot' \
        'AudioEndpoint' \
        'UserLanguageList' \
        'MicrosoftEdgeUpdate' \
        'Office Automatic Updates 2.0' \
        'GoogleUpdater' \
        'ComponentUpdatesEnabled' \
        'DisableAppUpdate' \
        'bUpdater' \
        'OneDrive (?:Standalone Update' \
        'SysMain' \
        'WSearch' \
        'PowerThrottlingOff' \
        'RetiredRegistryPlan' \
        'preserved appearance restored' \
        'SCHEME_MIN' \
        'Registry.pol' \
        'MS-GPREG 2.2.1' \
        '($key + [char]0)' \
        '(([string]$entry.Name) + [char]0)' \
        'Write-ManagedPolicyFiles' \
        'gpt.ini' \
        'Write-ManagedPolicyMetadata' \
        'gPCMachineExtensionNames/gPCUserExtensionNames are Active Directory GPO' \
        'PolicyMetadataPath' \
        'Restore-PolicyFileSnapshots' \
        'Refresh-LocalPolicy' \
        'G11GuestLite-EnforceProfile' \
        'Register-EnforcementTask' \
        'Get-CurrentMachineGuid' \
        'MachineGuid' \
        'LastTaskResult' \
        'New-ScheduledTaskTrigger -AtLogOn -User ([string]$State.UserSid)' \
        'services=reviewed-disabled' \
        'tasks=reviewed-disabled' \
        "'Enforce' { Invoke-Enforce }" \
        "-UserId 'SYSTEM'" \
        'S-1-5-18' \
        'Ensure-CurrentBaseline' \
        'SchemaVersion = 5' \
        "'CloneApply' { Invoke-Apply -UnattendedClone }" \
        'Avoid two duplicate' \
        'Save-AuditReportLines' \
        'cpuSampleSkipped=True' \
        'NoAutoUpdate' \
        'DoNotConnectToWindowsUpdateInternetLocations' \
        'DODownloadMode' \
        'RemoveWindowsStore' \
        'Microsoft.BingNews' \
        'Microsoft.BingWeather' \
        'Microsoft.OneDriveSync' \
        'Microsoft.OutlookForWindows' \
        'Microsoft.WindowsStore' \
        'Remove-AppxPackage' \
        'G11GuestLite' \
        'Invoke-Rollback'; do
    rg -Fq -- "$required" "$guest" || fail "guest script omitted: $required"
done

if grep -Fq '@(Get-WinUserLanguageList' "$guest"; then
    fail 'guest-lite must explicitly index the Windows PowerShell 5.1 LanguageList collection'
fi
if grep -Fq '@(Get-WinUserLanguageList' "$finalizer"; then
    fail 'clone finalizer must explicitly index the Windows PowerShell 5.1 LanguageList collection'
fi

if rg -Fq '$desired.Add($pinyin[0])' "$guest" ||
        rg -Fq '$restored.Add($single[0])' "$guest"; then
    fail 'language list appends a WinUserLanguage object instead of a tag on PowerShell 5.1'
fi

enforce_body=$(sed -n '/^function Invoke-Enforce {/,/^function Invoke-Rollback {/p' \
    "$guest")
for required_call in Disable-PlannedServices Disable-PlannedTasks \
        Stop-PlannedProcesses Set-DefaultAudioMuted Set-PerformancePowerPlan; do
    rg -Fq "$required_call" <<<"$enforce_body" \
        || fail "SYSTEM enforcement omitted self-healing call: $required_call"
done
enforcement_reader=$(sed -n \
    '/^function Read-EnforcementState {/,/^function Get-DefenderPreferenceSnapshots {/p' \
    "$guest")
if rg -Fq '$state.ComputerName' <<<"$enforcement_reader"; then
    fail 'SYSTEM enforcement is still coupled to the mutable computer name'
fi
rg -Fq 'Test-StateMachineGuid $state' <<<"$enforcement_reader" \
    || fail 'SYSTEM enforcement does not bind rollback state to MachineGuid'

if rg -n -F 'New-Item -Path $Entry.Path -Force' "$guest"; then
    fail 'guest-lite can recreate an existing registry leaf and erase sibling values'
fi

if rg -n -F '$RegistryPolicyExtensionPair' "$guest"; then
    fail 'guest-lite still writes Active Directory extension metadata into local gpt.ini'
fi

if rg -n \
        '^[[:space:]]*(\$[[:alnum:]_]+[[:space:]]*=[[:space:]]*)?Get-ItemPropertyValue([[:space:]`]|$)' \
        "$guest"; then
    fail 'guest-lite uses the Windows PowerShell 5.1-unsafe optional registry value reader'
fi

if rg -n \
        'return[[:space:]]+@\(\$(failures|issues|result|rows)\)' \
        "$guest"; then
    fail 'guest-lite directly wraps a generic list in a Windows PowerShell 5.1 array subexpression'
fi
for safe_list in failures issues result rows; do
    rg -Fq "return \$$safe_list.ToArray()" "$guest" \
        || fail "guest-lite omitted the safe generic-list conversion: \$$safe_list"
done

if rg -n '\.InvocationInfo\.MyCommand\.Name|\$invocation\.MyCommand\.Name' \
        "$guest"; then
    fail 'guest-lite directly reads the optional PowerShell 5.1 command Name property'
fi
rg -Fq "PSObject.Properties['Name']" "$guest" \
    || fail 'guest-lite omitted strict-safe exception command-name inspection'

for protected in \
        'BITS' \
        'CryptSvc' \
        'NVIDIA/vGPU'; do
    rg -Fq "$protected" "$guest" || fail "protected component is undocumented: $protected"
done

if rg -n -i \
        'bcdedit\.exe|pnputil\.exe|takeown\.exe|nointegritychecks[[:space:]]+on|testsigning[[:space:]]+on|sc\.exe[[:space:]]+delete|Remove-AppxProvisionedPackage|Disable-PnpDevice|Remove-WindowsFeature|dism\.exe.+Remove-Package' \
        "$guest"; then
    fail 'guest-lite contains a prohibited destructive/signing operation'
fi
for firewall_profile in Domain Private Public; do
    rg -Fq "$firewall_profile" "$guest" \
        || fail "guest-lite omitted firewall profile: $firewall_profile"
done
rg -Fq '编译器支持已静态链接' \
    "$root/deploy/guest/guest-lite/README.txt" \
    || fail 'guest-lite does not document its no-third-party-runtime contract'
if rg -n -i \
        'ShellExecute|WinExec|system[[:space:]]*\(|CreateService|DeviceIoControl|bcdedit|testsigning|nointegritychecks' \
        "$exe_source" "$exe_manifest"; then
    fail 'standalone launcher contains an unreviewed process/driver/BCD path'
fi
if rg -n -i \
        'Set-Service.+WinDefend|Stop-Service.+WinDefend|Set-Service.+BITS|Stop-Service.+BITS|Set-Service.+NVDisplay|Stop-Service.+NVDisplay' \
        "$guest"; then
    fail 'guest-lite attempts to modify a protected service'
fi
if rg -n -F "Name = 'BFE'" "$guest"; then
    fail 'guest-lite attempts to disable the Base Filtering Engine'
fi
if rg -n -F "Name = 'Audiosrv'" "$guest"; then
    fail 'guest-lite attempts to disable the Windows Audio service'
fi
if rg -n -i \
        'password|passwd|credential|private[_ -]?key|BEGIN (RSA |OPENSSH )?PRIVATE KEY' \
        "$root/deploy/guest/guest-lite"; then
    fail 'guest package appears to contain a credential field'
fi

echo 'PASS: G-11 Windows 10 guest-lite package'

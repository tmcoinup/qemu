#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
packager="$root/deploy/package-guest-lite.sh"
wrapper="$root/deploy/scripts/guest-lite.sh"
guest="$root/deploy/guest/guest-lite/G11-Guest-Lite.ps1"
exe_builder="$root/deploy/guest/guest-lite/exe/build.sh"
exe_source="$root/deploy/guest/guest-lite/exe/guest_lite_launcher.c"
exe_manifest="$root/deploy/guest/guest-lite/exe/guest_lite_launcher.manifest"

fail() { echo "FAIL: $*" >&2; exit 1; }
for dependency in xorriso mktemp rg strings cmp \
        x86_64-w64-mingw32-gcc x86_64-w64-mingw32-windres \
        x86_64-w64-mingw32-objdump; do
    command -v "$dependency" >/dev/null 2>&1 \
        || fail "missing dependency: $dependency"
done

bash -n "$packager"
bash -n "$wrapper"
bash -n "$exe_builder"
[[ -x "$exe_builder" ]] || fail 'EXE builder is not executable'

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

pe_header=$(x86_64-w64-mingw32-objdump -f "$exe")
rg -q 'file format pei-x86-64' <<<"$pe_header" \
    || fail 'standalone launcher is not a 64-bit Windows PE'
pe_imports=$(x86_64-w64-mingw32-objdump -p "$exe")
for dll in ADVAPI32.dll bcrypt.dll KERNEL32.dll SHELL32.dll USER32.dll; do
    rg -Fq "DLL Name: $dll" <<<"$pe_imports" \
        || fail "standalone launcher omitted expected system import: $dll"
done
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
        'G-11 Windows 10 Guest Lite 1.5'; do
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
        'Get-OptionalRegistryValue' \
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
        'NoAutoUpdate' \
        'DoNotConnectToWindowsUpdateInternetLocations' \
        'RemoveWindowsStore' \
        'Microsoft.BingNews' \
        'Microsoft.WindowsStore' \
        'Remove-AppxPackage' \
        'G11GuestLite' \
        'Invoke-Rollback'; do
    rg -Fq "$required" "$guest" || fail "guest script omitted: $required"
done

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

for protected in \
        'Windows Firewall' \
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
if rg -n -i \
        'ShellExecute|WinExec|system[[:space:]]*\(|CreateService|DeviceIoControl|bcdedit|testsigning|nointegritychecks' \
        "$exe_source" "$exe_manifest"; then
    fail 'standalone launcher contains an unreviewed process/driver/BCD path'
fi
if rg -n -i \
        'Set-Service.+WinDefend|Stop-Service.+WinDefend|Set-Service.+MpsSvc|Stop-Service.+MpsSvc|Set-Service.+BITS|Stop-Service.+BITS|Set-Service.+NVDisplay|Stop-Service.+NVDisplay' \
        "$guest"; then
    fail 'guest-lite attempts to modify a protected service'
fi
if rg -n -i \
        'password|passwd|credential|private[_ -]?key|BEGIN (RSA |OPENSSH )?PRIVATE KEY' \
        "$root/deploy/guest/guest-lite"; then
    fail 'guest package appears to contain a credential field'
fi

echo 'PASS: G-11 Windows 10 guest-lite package'

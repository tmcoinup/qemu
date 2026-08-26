#!/usr/bin/env bash
# P-11 Monitor：只清理旧伪设备，并对真实 active EDID 做 fail-closed 验收。
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd -- "$script_dir/../../.." && pwd)
gpup="$repo/deploy/windows/gpup"
cleanup="$gpup/VMate.GpuP.GuestMonitor.ps1"
validation="$gpup/VMate.GpuP.GuestMonitorValidation.ps1"
reality="$gpup/VMate.GpuP.GuestDeviceReality.ps1"
guest="$gpup/VMate.GpuP.GuestValidation.ps1"
driver_store="$gpup/VMate.GpuP.DriverStore.ps1"
nsis="$repo/scripts/nsis.py"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

contains() {
    grep -F -- "$1" "$2" >/dev/null || fail "missing '$1' in $2"
}

rejects() {
    if grep -E -- "$1" "$2" >/dev/null; then
        fail "unexpected '$1' in $2"
    fi
}

test_sources_are_bounded_ps51_modules() {
    local file signature lines
    for file in "$cleanup" "$validation" "$reality"; do
        [[ -f "$file" ]] || fail "missing PowerShell module: $file"
        signature=$(od -An -tx1 -N3 "$file" | tr -d ' \n')
        [[ "$signature" == efbbbf ]] || fail "UTF-8 BOM missing: $file"
        lines=$(wc -l <"$file")
        (( lines <= 500 )) || fail "$file exceeds 500 lines: $lines"
        contains '#Requires -Version 5.1' "$file"
    done
}

test_legacy_cleanup_is_offline_and_fail_closed() {
    contains 'Remove-VMateGpuPLegacyGuestMonitorArtifacts' "$cleanup"
    contains '[IO.Directory]::GetParent($windows).FullName' "$cleanup"
    contains 'VMateP11GuestProvisioner' "$cleanup"
    contains 'Enum\Root\VMATEP11MONITOR' "$cleanup"
    contains 'VMateGuestMonitorProvisioner.exe' "$cleanup"
    contains 'Invoke-VMateGpuPOfflineSystemHive' "$cleanup"
    contains '& $reg load $nativeName $SystemHivePath' "$cleanup"
    contains '& $reg unload $nativeName' "$cleanup"
    contains 'Remove-Item -LiteralPath $target -Recurse -Force' "$cleanup"
    contains 'CreatesMonitorDevice = $false' "$cleanup"
    contains 'GuestTestSigningRequired = $false' "$cleanup"
    contains 'GuestKernelDriverInstalled = $false' "$cleanup"
    contains 'Remove-VMateGpuPLegacyGuestMonitorArtifacts' "$driver_store"

    rejects 'SetupDiCreateDeviceInfo|DIF_REGISTERDEVICE|New-Service|'\
'CreateService|Add-WindowsDriver|pnputil|devcon|bcdedit' "$cleanup"
    rejects 'native/bin/VMateGuestMonitorProvisioner\.exe' "$nsis"
}

test_validation_requires_one_signed_real_monitor() {
    contains 'function Assert-VMateGpuPGuestMonitor' "$validation"
    contains 'WmiMonitorID' "$validation"
    contains "@('MSH062E', 'DEFAULT_MONITOR')" "$validation"
    contains 'ROOT\\VMATEP11MONITOR' "$validation"
    contains 'DriverProvider -notmatch' "$validation"
    contains 'Assert-VMateGpuPGuestMonitor' "$guest"
    contains 'OfficialVendorPnpDriver' "$reality"
    contains 'ExactlyOneDisplayAdapter' "$reality"
    contains 'NoVMateNamedDevices' "$reality"

    local shell_bin
    shell_bin=$(command -v pwsh || command -v powershell || true)
    [[ -n "$shell_bin" ]] || return 0
    VMATE_MONITOR_VALIDATION="$validation" "$shell_bin" -NoLogo -NoProfile \
        -NonInteractive -Command '
        $ErrorActionPreference = "Stop"
        . $env:VMATE_MONITOR_VALIDATION
        $script:monitor = [pscustomobject]@{
            Name = "Samsung S24F350"; InstanceId = "DISPLAY\SAM0D20\4&1"
            HardwareIds = @("MONITOR\SAM0D20"); Status = "OK"
            Present = $true; ProblemCode = 0; Service = "monitor"
            DriverProvider = "Microsoft"; DriverVersion = "10.0.19041.1"
            InfName = "monitor.inf"; IsSigned = $true
            Signer = "Microsoft Windows"
        }
        $script:edid = [pscustomobject]@{
            InstanceName = "DISPLAY\SAM0D20\4&1_0"; Manufacturer = "SAM"
            ProductCode = "0D20"; SerialNumber = "H4ZMC48327"
            FriendlyName = "Samsung S24F350"; WeekOfManufacture = 12
            YearOfManufacture = 2022
        }
        function Get-VMateGpuPGuestMonitorInventory { @($script:monitor) }
        function Get-VMateGpuPGuestActiveMonitorIdentity { @($script:edid) }
        $result = Assert-VMateGpuPGuestMonitor -ExpectedPnpCode SAM0D20 `
            -ExpectedFriendlyName "Samsung S24F350"
        if (-not $result.Passed -or $result.PnpCode -cne "SAM0D20") {
            throw "real monitor was rejected"
        }
        $script:monitor.InstanceId = "DISPLAY\MSH062E\4&1"
        $script:monitor.HardwareIds = @("MONITOR\MSH062E")
        $script:monitor.Name = "Generic PnP Monitor"
        try {
            [void](Assert-VMateGpuPGuestMonitor)
            throw "Hyper-V default monitor was accepted"
        } catch {
            if ($_.Exception.Message -eq "Hyper-V default monitor was accepted") {
                throw
            }
        }
        $script:monitor.InstanceId = "ROOT\VMATEP11MONITOR\0000"
        $script:monitor.Name = "VMate P-11 Virtual Console Monitor"
        try {
            [void](Assert-VMateGpuPGuestMonitor)
            throw "legacy VMate monitor was accepted"
        } catch {
            if ($_.Exception.Message -eq "legacy VMate monitor was accepted") {
                throw
            }
        }
        exit 0
        '
}

test_sources_are_bounded_ps51_modules
test_legacy_cleanup_is_offline_and_fail_closed
test_validation_requires_one_signed_real_monitor

echo 'OK: Windows GPU-P real Monitor and legacy cleanup checks passed'

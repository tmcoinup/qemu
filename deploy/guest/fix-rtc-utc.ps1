<#
.SYNOPSIS
  Deprecated, read-only RTC diagnostics for the vGPU guest.

.DESCRIPTION
  This legacy filename is kept for operators who already know it. The script
  does not change the Windows timezone, registry, wall clock, or time service.

  The supported RTC contract is owned by the host launcher:
    TZ=Asia/Shanghai
    -rtc base=localtime,clock=vm,driftfix=slew

  Windows must use China Standard Time. RealTimeIsUniversal must be absent or
  DWORD 0 so Windows interprets the emulated RTC as local time.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedTimeZone = 'China Standard Time'
$timeZonePath = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
$tzutil = Join-Path $env:SystemRoot 'System32\tzutil.exe'

$configuredZone = (& $tzutil /g | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "tzutil failed to read the Windows timezone (exit $LASTEXITCODE)"
}

$timeConfiguration = Get-ItemProperty -LiteralPath $timeZonePath -ErrorAction Stop
$rtcProperty = $timeConfiguration.PSObject.Properties['RealTimeIsUniversal']
$rtcValue = if ($null -eq $rtcProperty) { '<missing>' } else { [string][int]$rtcProperty.Value }

Write-Warning 'deploy/guest/fix-rtc-utc.ps1 is deprecated and performs read-only diagnostics'
Write-Host '[time] host-required: TZ=Asia/Shanghai' -ForegroundColor Cyan
Write-Host '[time] qemu-required: -rtc base=localtime,clock=vm,driftfix=slew' -ForegroundColor Cyan
Write-Host "[time] windows-timezone=$configuredZone"
Write-Host "[time] RealTimeIsUniversal=$rtcValue"
Write-Host "[time] current-local=$((Get-Date).ToString('o'))"
Write-Host "[time] current-utc=$([DateTime]::UtcNow.ToString('o'))"

$problems = @()
if ($configuredZone -ne $expectedTimeZone) {
    $problems += "Windows timezone must be '$expectedTimeZone'"
}
if ($null -ne $rtcProperty -and [int]$rtcProperty.Value -ne 0) {
    $problems += 'RealTimeIsUniversal must be absent or DWORD 0'
}

if ($problems.Count -ne 0) {
    throw ('RTC contract check failed: ' + ($problems -join '; ') +
        '. This diagnostic does not make changes; correct the host launcher or Windows settings, then fully shut down Windows.')
}

Write-Host '[time] PASS: local RTC contract is consistent (no changes made)' -ForegroundColor Green

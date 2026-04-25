<#
.SYNOPSIS
  Tell Windows to treat motherboard RTC as UTC, paired with QEMU -rtc base=utc.
  After this, guest's China timezone (CST +8) converts from UTC correctly to
  real Beijing time.

.NOTES
  Must match deploy/start-vm.sh setting -rtc base=utc. If host side still uses
  base=localtime, this registry flip will make things worse. Flip both or neither.
#>
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' `
    -Name RealTimeIsUniversal -Value 1 -Type DWord -Force
Write-Host 'RealTimeIsUniversal = 1 (RTC treated as UTC)' -Fore Green
Write-Host 'Next boot: guest time = host UTC + TZ offset = correct Beijing time' -Fore Cyan

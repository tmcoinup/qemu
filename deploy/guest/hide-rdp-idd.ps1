<#
.SYNOPSIS
  Disable the "Microsoft Remote Display Adapter" (RdpIdd indirect display driver)
  so Device Manager / WMI enumerate only the NVIDIA GPU.

.NOTES
  RdpIdd is the RDP virtual display driver. Turning it off means the RDP session
  still connects, but the fancy hardware-accelerated virtual monitor layer is
  gone — the desktop in an RDP session is served by whatever real display
  adapter is present (our vGPU). Some UI features may degrade (multi-monitor,
  arbitrary resolutions). Local console / VNC unaffected.

  This is reversible: run with -Restore to re-enable.
#>
[CmdletBinding()]
param(
    [switch]$Restore
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

$svc = 'HKLM:\SYSTEM\CurrentControlSet\Services\RdpIdd'

if ($Restore) {
    Write-Host 'Restoring RdpIdd service (Start=3 Demand)' -Fore Cyan
    Set-ItemProperty -Path $svc -Name Start -Value 3 -Type DWord -Force
    Write-Host 'Re-enabling any disabled RDP display adapters' -Fore Cyan
    Get-PnpDevice | Where-Object { $_.FriendlyName -match 'Remote Display' -and $_.Status -eq 'Disabled' } |
        Enable-PnpDevice -Confirm:$false
    Write-Host 'Done. Reboot to take effect.' -Fore Green
    return
}

Write-Host '[1/2] Disable running Remote Display Adapter instance(s)' -Fore Cyan
$idds = Get-PnpDevice | Where-Object {
    $_.FriendlyName -match 'Remote Display' -or
    $_.InstanceId -match 'ROOT\\BasicRender|RDPIDD|DISPLAY\\RDPIDD'
}
if ($idds) {
    foreach ($d in $idds) {
        Write-Host "  disable $($d.InstanceId)"
        Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    }
} else {
    Write-Host '  no present IDD — good'
}

Write-Host '[2/2] RdpIdd service Start=4 (disabled)' -Fore Cyan
if (Test-Path $svc) {
    Set-ItemProperty -Path $svc -Name Start -Value 4 -Type DWord -Force
    Write-Host "  Start set to 4 (disabled)"
} else {
    Write-Host '  Service key missing (not on this build) — skip'
}

Write-Host ''
Write-Host 'Done. Reboot to apply. Next RDP connect will not spawn IDD adapter.' -Fore Green
Write-Host 'To restore: \\tsclient\nv\hide-rdp-idd.ps1 -Restore' -Fore Yellow

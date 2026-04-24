<#
.SYNOPSIS
  Uninstall current NVIDIA driver (553.74) and stage 553.24 for next-boot install.
  Then shut down the VM so the host can flip to --rdp mode with vGPU attached.

.NOTES
  Run as administrator in the guest.
  Prerequisite: Set-ExecutionPolicy bypass for this session or RemoteSigned for user.
#>
[CmdletBinding()]
param()

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

Write-Host '[1/4] Uninstall every NVIDIA driver oem package' -Fore Cyan
$all = pnputil /enum-drivers
$matches = [regex]::Matches($all,
    'Published name\s*:\s*(oem\d+\.inf)[\s\S]*?Provider\s*:\s*NVIDIA')
foreach ($m in $matches) {
    $oem = $m.Groups[1].Value
    Write-Host "  pnputil /delete-driver $oem /uninstall /force"
    pnputil /delete-driver $oem /uninstall /force | Out-Null
}
Write-Host "  done ($($matches.Count) packages removed)" -Fore Green

Write-Host '[2/4] Remove phantom NVIDIA PCI devices' -Fore Cyan
$env:DEVMGR_SHOW_NONPRESENT_DEVICES = '1'
Get-PnpDevice | Where-Object { $_.InstanceId -like 'PCI\VEN_10DE*' } |
    ForEach-Object {
        Write-Host "  removing $($_.InstanceId)"
        pnputil /remove-device $_.InstanceId /force 2>&1 | Out-Null
    }

Write-Host '[3/4] Uninstall NVIDIA user-space packages' -Fore Cyan
Get-Package | Where-Object { $_.Name -like '*NVIDIA*' } |
    ForEach-Object {
        Write-Host "  uninstalling $($_.Name)"
        $_ | Uninstall-Package -Force -ErrorAction SilentlyContinue | Out-Null
    }

Write-Host '[4/4] Stage 553.24 installer locally for next boot' -Fore Cyan
New-Item -ItemType Directory -Force C:\nv | Out-Null
Copy-Item '\\tsclient\nv\553.24.exe' C:\nv\ -Force
if (Test-Path C:\nv\553.24.exe) {
    Write-Host "  C:\nv\553.24.exe staged ($((Get-Item C:\nv\553.24.exe).Length) bytes)" -Fore Green
} else {
    Write-Warning 'Copy failed — check \\tsclient\nv\ share is mapped'
}

Write-Host ''
Write-Host 'All done. Shutting down in 5 seconds...' -Fore Yellow
Write-Host 'After shutdown, host will flip to --rdp mode and re-attach vGPU.'
shutdown /s /t 5

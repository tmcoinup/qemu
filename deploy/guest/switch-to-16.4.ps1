<#
.SYNOPSIS
  Prepare guest for 16.4 (538.33) driver installation:
    1) Uninstall any existing NVIDIA oem INF packages
    2) Delete NVIDIA runtime DLL/SYS residues in System32/SysWOW64 that the
       vGPU 17.x/18.x driver left behind
    3) Remove phantom NVIDIA PCI records (driver-store rollbacks otherwise
       try to re-bind the wrong version)
    4) Stage C:\nv\538.33.exe and launch its GUI installer
#>
[CmdletBinding()]
param()

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

Write-Host '[1/4] Uninstall NVIDIA oem INF packages' -Fore Cyan
$all = pnputil /enum-drivers
$nvInfs = [regex]::Matches($all, 'Published name\s*:\s*(oem\d+\.inf)[\s\S]*?Provider\s*:\s*NVIDIA') |
    ForEach-Object { $_.Groups[1].Value }
foreach ($oem in $nvInfs) {
    Write-Host "  pnputil /delete-driver $oem /uninstall /force"
    pnputil /delete-driver $oem /uninstall /force | Out-Null
}
Write-Host "  removed $($nvInfs.Count) packages" -Fore Green

Write-Host '[2/4] Delete NVIDIA runtime residues in System32/SysWOW64' -Fore Cyan
$patterns = @(
    'C:\Windows\System32\drivers\nv*.sys',
    'C:\Windows\System32\drivers\nvidia*.sys',
    'C:\Windows\System32\nvwgf*.dll',
    'C:\Windows\System32\nvapi*.dll',
    'C:\Windows\System32\nvcuda*.dll',
    'C:\Windows\System32\nvml*.dll',
    'C:\Windows\System32\nvvm*.dll',
    'C:\Windows\SysWOW64\nvwgf*.dll',
    'C:\Windows\SysWOW64\nvapi*.dll',
    'C:\Windows\SysWOW64\nvcuda*.dll'
)
foreach ($pat in $patterns) {
    $files = Get-ChildItem -Path $pat -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        Write-Host "  rm $($f.Name)"
        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '[3/4] Remove phantom NVIDIA PCI records' -Fore Cyan
$env:DEVMGR_SHOW_NONPRESENT_DEVICES = '1'
Get-PnpDevice | Where-Object {
    $_.InstanceId -like 'PCI\VEN_10DE*' -or $_.FriendlyName -like 'NVIDIA*'
} | ForEach-Object {
    Write-Host "  remove $($_.InstanceId)"
    pnputil /remove-device $_.InstanceId /force 2>&1 | Out-Null
}

Write-Host '[4/4] Stage 538.33.exe and launch installer' -Fore Cyan
New-Item -ItemType Directory -Force C:\nv | Out-Null
Copy-Item '\\tsclient\nv\538.33.exe' 'C:\nv\538.33.exe' -Force
Write-Host "  $((Get-Item C:\nv\538.33.exe).Length) bytes staged"
Write-Host ''
Write-Host 'Launching installer GUI - pick Express when it asks.' -Fore Yellow
Write-Host 'RDP will disconnect when the driver swaps WDDM adapter. That is' -Fore Yellow
Write-Host 'normal - xfreerdp3 auto-reconnects once Windows finishes.' -Fore Yellow
Start-Process 'C:\nv\538.33.exe'

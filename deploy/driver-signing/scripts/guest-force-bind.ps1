$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== Before: which service is bound ==='
$p = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI\VEN_10DE&DEV_1C81&SUBSYS_1C8110DE&REV_A1\3&11583659&0&30'
if (Test-Path $p) { (Get-ItemProperty $p -Name Service -EA 0).Service }

Write-Host ''
Write-Host '=== pnputil /add-driver /install (forces binding to matching devices) ==='
& pnputil /add-driver 'C:\stealth\nv-driver\viogpudo-nvidia.inf' /install
Write-Host ''
Write-Host '=== pnputil /scan-devices ==='
& pnputil /scan-devices
Start-Sleep -Seconds 3

Write-Host ''
Write-Host '=== After binding attempt ==='
Get-CimInstance Win32_VideoController | Select-Object Name,Status,ConfigManagerErrorCode,DriverVersion,PNPDeviceID | Format-List

Write-Host '=== Enum\PCI service ==='
if (Test-Path $p) {
    $d = Get-ItemProperty $p
    Write-Host ("  Service      = " + $d.Service)
    Write-Host ("  DeviceDesc   = " + $d.DeviceDesc)
    Write-Host ("  Driver       = " + $d.Driver)
    Write-Host ("  Problem      = " + $d.ConfigFlags)
}

Write-Host '=== Setupapi.dev.log tail — errors around latest install ==='
$log = 'C:\Windows\INF\setupapi.dev.log'
Get-Content $log -Tail 200 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'Error|!!!|failed|viogpudo|VEN_10DE|signer|catalog' } | Select-Object -Last 20

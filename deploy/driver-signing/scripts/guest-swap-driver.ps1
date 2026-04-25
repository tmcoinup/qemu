$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== removing oem3.inf (old, non-backdated) ==='
& pnputil /delete-driver oem3.inf /uninstall /force

Write-Host ''
Write-Host '=== rescanning PnP so oem7.inf gets bound ==='
& pnputil /scan-devices
Start-Sleep -Seconds 3

Write-Host ''
Write-Host '=== post-swap state ==='
Get-CimInstance Win32_VideoController | Select-Object Name,Status,PNPDeviceID,ConfigManagerErrorCode,DriverVersion | Format-List

Write-Host ''
Write-Host '=== surviving viogpudo INFs ==='
pnputil /enum-drivers | Select-String -Pattern 'viogpudo' -Context 0,4 | ForEach-Object { $_.ToString() }

Write-Host ''
Write-Host '=== Class\0002 current state ==='
$p = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0002'
if (Test-Path $p) {
    Get-ItemProperty $p | Select-Object DriverDesc,DriverVersion,DriverDate,InfPath,InfSection,ProviderName,MatchingDeviceId | Format-List
}

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== removing current oem7.inf (to force re-copy with new files) ==='
& pnputil /delete-driver oem7.inf /uninstall /force
Start-Sleep -Seconds 2

Write-Host '=== re-adding oem7 with TSA-countersigned files ==='
& pnputil /add-driver C:\stealth\nv-driver\viogpudo-nvidia.inf

Write-Host '=== scanning for hardware changes ==='
& pnputil /scan-devices
Start-Sleep -Seconds 4

Write-Host ''
Write-Host '=== post state ==='
Get-CimInstance Win32_VideoController | Select-Object Name,Status,PNPDeviceID,ConfigManagerErrorCode,DriverVersion | Format-List

Write-Host ''
Write-Host '=== signtool verify /kp sys ==='
$st = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe'
& $st verify /v /kp 'C:\Windows\System32\drivers\viogpudo.sys'

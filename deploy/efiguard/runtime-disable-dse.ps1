$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== before: Win32_VideoController ==='
Get-CimInstance Win32_VideoController | Select-Object Name,Status,ConfigManagerErrorCode | Format-List

Write-Host '=== running EfiDSEFix.exe -d (disable DSE via EfiGuardDxe SetVariable hook) ==='
& 'C:\stealth\efiguard\EfiDSEFix.exe' -d 2>&1
Write-Host ('exit=' + $LASTEXITCODE)

Write-Host ''
Write-Host '=== forcing PnP re-bind on the NVIDIA device ==='
& pnputil /scan-devices
Start-Sleep -Seconds 3
& pnputil /add-driver 'C:\stealth\nv-driver\viogpudo-nvidia.inf' /install
Start-Sleep -Seconds 3

Write-Host ''
Write-Host '=== after: Win32_VideoController ==='
Get-CimInstance Win32_VideoController | Select-Object Name,Status,ConfigManagerErrorCode,DriverVersion | Format-List

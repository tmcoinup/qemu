$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host '=== EfiDSEFix /c (config dump) ==='
& 'C:\stealth\efiguard\EfiDSEFix.exe' /c
Write-Host ''
Write-Host '=== EfiDSEFix /i (info) ==='
& 'C:\stealth\efiguard\EfiDSEFix.exe' /i 2>&1
Write-Host ''
Write-Host '=== EfiGuardDxe variable check via UEFI ==='
& bcdedit /enum firmware | Select-String -Pattern 'identifier|description|path' | Select-Object -First 30

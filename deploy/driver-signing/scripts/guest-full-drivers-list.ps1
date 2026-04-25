$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host '=== all oem*.inf in DriverStore ==='
pnputil /enum-drivers | Select-String -Pattern 'Published Name|Original Name|Driver Version|Signer Name|Class Name' | ForEach-Object { $_.ToString() }

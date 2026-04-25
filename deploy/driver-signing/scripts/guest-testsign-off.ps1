$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host '=== disabling testsigning ==='
& bcdedit /set testsigning off
& bcdedit /enum | Select-String -Pattern 'testsigning|nointegritychecks'

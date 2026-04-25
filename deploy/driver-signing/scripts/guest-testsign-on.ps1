$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host '=== enabling testsigning ==='
& bcdedit /set testsigning on
& bcdedit /enum | Select-String -Pattern 'testsigning|nointegritychecks'

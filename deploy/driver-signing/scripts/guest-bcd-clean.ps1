$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host '=== setting testsigning + nointegritychecks to No ==='
& bcdedit /set '{current}' testsigning No
& bcdedit /set '{current}' nointegritychecks No
& bcdedit /enum '{current}' | Select-String -Pattern 'testsigning|nointegritychecks'

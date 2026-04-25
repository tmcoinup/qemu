$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== disabling fast startup + hibernate ==='
& powercfg /hibernate off
& powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0
# Fast startup in Win10: registry setting
$path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
Set-ItemProperty -Path $path -Name HiberbootEnabled -Value 0 -Type DWord -Force
Write-Host ('HiberbootEnabled = ' + (Get-ItemProperty $path -Name HiberbootEnabled).HiberbootEnabled)

Write-Host ''
Write-Host '=== setting testsigning Yes ==='
& bcdedit /set '{current}' testsigning Yes
& bcdedit /set '{current}' nointegritychecks Yes
& bcdedit /enum '{current}' | Select-String -Pattern 'testsigning|nointegritychecks'

Write-Host ''
Write-Host '=== rebooting with shutdown /r /t 0 (full reboot, bypassing fast startup) ==='

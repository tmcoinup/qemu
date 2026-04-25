$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Disable hibernation + fast startup (sticky; survives Windows updates)
& powercfg /hibernate off
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord -Force
Write-Host ('HiberbootEnabled = ' + (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled).HiberbootEnabled)

# Set BCD testsigning Yes
& bcdedit /set '{current}' testsigning Yes
& bcdedit /set '{current}' nointegritychecks No
& bcdedit /enum '{current}' | Select-String -Pattern 'testsigning|nointegritychecks'

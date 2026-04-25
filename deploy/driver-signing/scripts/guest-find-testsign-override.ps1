$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== scheduled tasks that might flip BCD ==='
Get-ScheduledTask | Where-Object { $_.TaskName -match 'cih|sign|testsign|stealth|gpu|refresh|bcd' } |
    Select-Object TaskName,State,@{L='Cmd';E={ ($_.Actions[0].Execute + ' ' + $_.Actions[0].Arguments) }} | Format-Table -AutoSize -Wrap

Write-Host ''
Write-Host '=== startup programs (Run key) ==='
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue |
    ForEach-Object { $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | Format-Table Name,Value -AutoSize }

Write-Host '=== kernel drivers with cihider in name ==='
Get-ChildItem 'C:\Windows\System32\drivers' -Filter '*cihider*' -ErrorAction SilentlyContinue | Format-Table Name,Length,LastWriteTime -AutoSize
Get-ChildItem 'C:\Windows\System32\drivers' -Filter 'cih*' -ErrorAction SilentlyContinue | Format-Table Name,Length,LastWriteTime -AutoSize

Write-Host '=== CiHider service registry ==='
$svc = 'HKLM:\SYSTEM\CurrentControlSet\Services\CiHider'
if (Test-Path $svc) { Get-ItemProperty $svc | Select-Object ImagePath,Start,Type,DisplayName | Format-List }

Write-Host '=== services referencing cihider ==='
Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -match 'cihider|CihSigner|CiHider|cih' } | Select-Object Name,State,StartMode,PathName | Format-Table -AutoSize

Write-Host '=== sys drivers list (filtered) ==='
Get-CimInstance Win32_SystemDriver | Where-Object { $_.PathName -match 'viogpudo|cihider' } | Select-Object Name,State,StartMode,PathName | Format-Table -AutoSize

Write-Host '=== OS version / install date ==='
Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,InstallDate,LastBootUpTime | Format-List

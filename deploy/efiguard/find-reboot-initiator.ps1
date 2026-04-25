$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== Event 1074 (planned shutdown initiator) last 24h ==='
Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddHours(-24);Id=1074} -EA 0 |
    Sort-Object TimeCreated |
    ForEach-Object {
        Write-Host ('-- ' + $_.TimeCreated)
        Write-Host ('   ' + ($_.Message -replace "`r`n", ' | '))
    }

Write-Host ''
Write-Host '=== Event 1076 (reason for unexpected shutdown if user provided) ==='
Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddHours(-24);Id=1076} -EA 0 |
    ForEach-Object { Write-Host ('-- ' + $_.TimeCreated + ' ' + ($_.Message -split "`r?`n")[0]) }

Write-Host ''
Write-Host '=== ACE / Tencent / GameSafe related events last 4h ==='
$cutoff = (Get-Date).AddHours(-4)
Get-WinEvent -FilterHashtable @{LogName='System';StartTime=$cutoff} -EA 0 |
    Where-Object { $_.Message -match 'ACE|TenSafe|TGP|Tencent|wegame|GameSafe|tcls|TenProtect|tp_pro|sguard' -or $_.ProviderName -match 'ACE|TenSafe|Tencent' } |
    ForEach-Object { Write-Host ('-- ' + $_.TimeCreated + ' ' + $_.ProviderName + ' Id=' + $_.Id); Write-Host ('   ' + (($_.Message -split "`r?`n")[0])) }
Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$cutoff} -EA 0 |
    Where-Object { $_.Message -match 'ACE|TenSafe|TGP|Tencent|wegame|GameSafe|tcls|TenProtect|tp_pro|sguard' -or $_.ProviderName -match 'ACE|TenSafe|Tencent' } |
    Select-Object -First 15 |
    ForEach-Object { Write-Host ('-- ' + $_.TimeCreated + ' ' + $_.ProviderName + ' Id=' + $_.Id); Write-Host ('   ' + (($_.Message -split "`r?`n")[0])) }

Write-Host ''
Write-Host '=== ACE service status ==='
Get-Service -ErrorAction SilentlyContinue 'ACE-*','TenSafe*','SGuard*','TenProtect*','TGProtector*' | Format-Table Name,Status,StartType -AutoSize
Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -match 'ACE|TenSafe|SGuard|TenProtect|TGP' } | Select Name,State,StartMode,PathName | Format-Table -AutoSize

Write-Host ''
Write-Host '=== last 30 Kernel-General + Wininit + UserMode-Power-Diagnostic events ==='
Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddHours(-1)} -EA 0 |
    Where-Object { $_.ProviderName -in @('Microsoft-Windows-Kernel-General','Microsoft-Windows-Wininit','Microsoft-Windows-Power-Troubleshooter','Microsoft-Windows-Eventlog','USER32','Application Popup') } |
    Select-Object -First 25 |
    ForEach-Object { Write-Host ('-- ' + $_.TimeCreated.ToString('HH:mm:ss') + ' ' + $_.ProviderName + ' Id=' + $_.Id + ' ' + (($_.Message -split "`r?`n")[0])) }

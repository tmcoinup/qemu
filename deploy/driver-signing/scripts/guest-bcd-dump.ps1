$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host '=== bcdedit /v ==='
bcdedit /v
Write-Host ''
Write-Host '=== cihider status ==='
Get-Service -Name *Cih*,*cihider* -ErrorAction SilentlyContinue | Format-Table Name,Status,StartType -AutoSize
Write-Host '=== cihider driver state ==='
Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -match 'cihider' -or $_.Name -match 'CiHider' } | Select-Object Name,State,StartMode,PathName | Format-Table -AutoSize
Write-Host '=== Testsigning-related events ==='
Get-WinEvent -LogName System -MaxEvents 400 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'testsigning|integrity|code.integrity|viogpudo|VioGpu' } | Select-Object -First 5 TimeCreated,ProviderName,Id,LevelDisplayName,Message | Format-List

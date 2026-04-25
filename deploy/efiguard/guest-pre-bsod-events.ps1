$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== last 50 System events around 22:40 (just before crash) ==='
$cutoff = [datetime]'2026-04-24 22:30:00'
$end    = [datetime]'2026-04-24 22:42:00'
Get-WinEvent -FilterHashtable @{LogName='System';StartTime=$cutoff;EndTime=$end} -EA 0 |
    Sort-Object TimeCreated |
    ForEach-Object {
        $msg = ($_.Message -split "`n")[0]
        if ($msg.Length -gt 200) { $msg = $msg.Substring(0,200) + '...' }
        Write-Host ('{0} | {1,-50} | Id={2,-5} | {3} | {4}' -f $_.TimeCreated.ToString('HH:mm:ss'), $_.ProviderName, $_.Id, $_.LevelDisplayName, $msg)
    } | Out-String -Stream | Select-Object -Last 60

Write-Host ''
Write-Host '=== last 50 Application events around 22:40 ==='
Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$cutoff;EndTime=$end} -EA 0 |
    Sort-Object TimeCreated |
    ForEach-Object {
        $msg = ($_.Message -split "`n")[0]
        if ($msg.Length -gt 200) { $msg = $msg.Substring(0,200) + '...' }
        Write-Host ('{0} | {1,-50} | Id={2,-5} | {3} | {4}' -f $_.TimeCreated.ToString('HH:mm:ss'), $_.ProviderName, $_.Id, $_.LevelDisplayName, $msg)
    } | Out-String -Stream | Select-Object -Last 30

Write-Host ''
Write-Host '=== uptime + last boot time ==='
Get-CimInstance Win32_OperatingSystem | Select-Object LastBootUpTime,LocalDateTime | Format-List

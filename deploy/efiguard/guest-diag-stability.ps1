$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== auto-restart on BSOD policy (we want it OFF for diag) ==='
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' |
    Select-Object AutoReboot,CrashDumpEnabled,DumpFile,MinidumpDir | Format-List

Write-Host '=== minidumps (last 10) ==='
Get-ChildItem 'C:\Windows\Minidump' -Filter '*.dmp' -EA 0 |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 10 Name,Length,LastWriteTime |
    Format-Table -AutoSize

Write-Host ''
Write-Host '=== System event log: BSOD / unexpected shutdowns (last 24h) ==='
$cutoff = (Get-Date).AddDays(-1)
Get-WinEvent -FilterHashtable @{LogName='System';StartTime=$cutoff;Id=6008,41,1001,1003} -EA 0 |
    Select-Object -First 20 |
    ForEach-Object {
        Write-Host ('-- ' + $_.TimeCreated + ' Provider=' + $_.ProviderName + ' Id=' + $_.Id + ' Level=' + $_.LevelDisplayName)
        Write-Host ('   ' + ($_.Message -replace "`r`n",' | ' -replace '\s+',' ').Substring(0, [Math]::Min(400,$_.Message.Length)))
    }

Write-Host ''
Write-Host '=== Kernel-PnP errors (driver crashing/restarting) last hour ==='
Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddHours(-1)} -EA 0 |
    Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Kernel-PnP' -and $_.LevelDisplayName -in 'Error','Warning' } |
    Select-Object -First 20 |
    ForEach-Object { Write-Host ('-- ' + $_.TimeCreated + ' Id=' + $_.Id + ' ' + ($_.Message -split "`n")[0]) }

Write-Host ''
Write-Host '=== display.framework crash signatures ==='
Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddHours(-2)} -EA 0 |
    Where-Object { $_.Message -match 'viogpudo|VioGpu|nvlddmkm|TDR|display driver|stopped responding' } |
    Select-Object -First 10 |
    ForEach-Object { Write-Host ('-- ' + $_.TimeCreated + ' ' + $_.ProviderName + ' Id=' + $_.Id); Write-Host ('   ' + ($_.Message -split "`n")[0]) }

Write-Host ''
Write-Host '=== WHEA / hardware errors ==='
Get-WinEvent -LogName 'Microsoft-Windows-Kernel-WHEA/Errors' -EA 0 -MaxEvents 5 |
    ForEach-Object { Write-Host ('-- ' + $_.TimeCreated + ' Id=' + $_.Id); Write-Host ('   ' + ($_.Message -split "`n")[0]) }

Write-Host ''
Write-Host '=== reliability records (system stability summary) ==='
Get-CimInstance Win32_ReliabilityRecords -EA 0 |
    Where-Object { $_.SourceName -match 'Microsoft-Windows-WindowsUpdateClient|Kernel-Power|Kernel-General|EventLog|Application Error|Windows Error Reporting' } |
    Sort-Object TimeGenerated -Descending |
    Select-Object -First 15 TimeGenerated,SourceName,EventIdentifier,@{L='Msg';E={ ($_.Message -split "`n")[0] }} |
    Format-Table -AutoSize -Wrap

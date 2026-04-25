$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== existing memory.dmp / minidump on disk ==='
Get-ChildItem 'C:\Windows\MEMORY.DMP' -EA 0 | Format-List Name,Length,LastWriteTime
Get-ChildItem 'C:\Windows\Minidump' -Recurse -EA 0 | Format-Table Name,Length,LastWriteTime -AutoSize
Get-ChildItem 'C:\Windows\LiveKernelReports' -Recurse -EA 0 | Format-Table FullName,Length -AutoSize

Write-Host '=== bug check codes from System log (Id 1001) ==='
Get-WinEvent -LogName 'System' -EA 0 -MaxEvents 2000 |
    Where-Object { $_.Id -eq 1001 -and $_.ProviderName -eq 'Microsoft-Windows-WER-SystemErrorReporting' } |
    Select-Object TimeCreated,Message |
    Format-List

Write-Host '=== earlier reliability records from BSOD providers ==='
Get-CimInstance Win32_ReliabilityRecords -EA 0 |
    Where-Object { $_.SourceName -match 'WER|BugCheck|Kernel-Power|EventLog' -and $_.EventIdentifier -in @(41,1001,1003,1018) } |
    Sort-Object TimeGenerated -Descending |
    Select-Object -First 20 TimeGenerated,SourceName,EventIdentifier,@{L='Msg';E={ ($_.Message -split "`r?`n")[0] }} |
    Format-Table -AutoSize -Wrap

Write-Host '=== virtio / GL / display events last 4h (any error/warning) ==='
Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddHours(-4);Level=1,2,3} -EA 0 |
    Where-Object { $_.Message -match 'virtio|virgl|GL|D3D|DXG|Display|Adapter|TDR|nvlddmkm|viogpudo|hyperv|ACPI|machine.check' } |
    Select-Object -First 25 |
    ForEach-Object {
        Write-Host ('-- ' + $_.TimeCreated + ' ' + $_.ProviderName + ' Id=' + $_.Id + ' ' + $_.LevelDisplayName)
        Write-Host ('   ' + (($_.Message -split "`r?`n")[0]))
    }

Write-Host ''
Write-Host '=== pagefile size (need >= memory dump for kernel dump) ==='
Get-CimInstance Win32_PageFileSetting | Format-List Name,InitialSize,MaximumSize
Get-CimInstance Win32_PageFileUsage | Format-List Name,AllocatedBaseSize,CurrentUsage,PeakUsage
Get-CimInstance Win32_OperatingSystem | Select-Object TotalVisibleMemorySize,FreePhysicalMemory | Format-List

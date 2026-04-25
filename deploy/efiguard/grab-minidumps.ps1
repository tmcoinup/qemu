$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Run on guest; lists minidumps with bug check codes. Use after BSOD.
# Pull the .dmp back to host with scp + run host-side analyze-minidump.sh

Write-Host '=== minidumps in C:\Windows\Minidump ==='
$dumps = Get-ChildItem 'C:\Windows\Minidump' -Filter '*.dmp' -EA 0 |
    Sort-Object LastWriteTime -Descending
$dumps | Format-Table Name,Length,LastWriteTime -AutoSize

Write-Host ''
Write-Host '=== last 10 BSOD bug check codes (Event 1001 from System log) ==='
Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-WER-SystemErrorReporting'} -MaxEvents 10 -EA 0 |
    Sort-Object TimeCreated |
    ForEach-Object {
        # Message format: "The computer has rebooted from a bugcheck.
        #                  The bugcheck was: 0x000000XX (0xYYY,...)..."
        $msg = $_.Message
        $code = if ($msg -match '0x[0-9A-Fa-f]{8}') { $matches[0] } else { '???' }
        Write-Host ('-- ' + $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss') + ' Bug check: ' + $code)
        Write-Host ('   ' + (($msg -split "`r?`n")[0]))
    }

Write-Host ''
Write-Host '=== last 10 LiveKernelReports (sub-fatal driver crash dumps) ==='
Get-ChildItem 'C:\Windows\LiveKernelReports' -Recurse -Filter '*.dmp' -EA 0 |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 10 FullName,Length,LastWriteTime |
    Format-Table -AutoSize -Wrap

Write-Host ''
Write-Host 'Pull from host with:'
Write-Host '  sshpass -p ''123456'' scp -P 22 Administrator@<guest-ip>:''C:/Windows/Minidump/*.dmp'' /tmp/'
Write-Host 'Then analyze on host with deploy/efiguard/analyze-minidump.sh'

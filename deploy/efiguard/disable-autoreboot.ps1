$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Disable auto-restart on BSOD so the bug check screen stays visible
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name AutoReboot -Value 0 -Type DWord

# Force kernel memory dump (smaller, faster) instead of full memory dump
# CrashDumpEnabled: 0=none, 1=full, 2=kernel, 3=auto, 7=active memory
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name CrashDumpEnabled -Value 2 -Type DWord

# Make sure minidump dir is set + create it
New-Item -Path 'C:\Windows\Minidump' -ItemType Directory -Force | Out-Null
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name MinidumpDir -Value 'C:\Windows\Minidump' -Type String -EA 0
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name MinidumpsCount -Value 50 -Type DWord -EA 0

Write-Host '=== CrashControl now ==='
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' |
    Select-Object AutoReboot,CrashDumpEnabled,DumpFile,MinidumpDir,MinidumpsCount | Format-List

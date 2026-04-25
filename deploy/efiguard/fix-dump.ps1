$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Small (mini) dump: 256KB only, always fits.
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name CrashDumpEnabled -Value 3 -Type DWord

# Disable auto-restart so BSOD screen stays
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name AutoReboot -Value 0 -Type DWord
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name MinidumpsCount -Value 50 -Type DWord -EA 0
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name AlwaysKeepMemoryDump -Value 1 -Type DWord -EA 0

# Bump pagefile to 4 GB system-managed for next boot (helps if user later wants kernel dump)
$pf = Get-CimInstance Win32_ComputerSystem
if ($pf.AutomaticManagedPagefile) {
    Write-Host '(pagefile is automatic-managed; explicit set requires registry-level config — skipping for now)'
}

Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' |
    Select-Object AutoReboot,CrashDumpEnabled,DumpFile,MinidumpDir,MinidumpsCount,AlwaysKeepMemoryDump | Format-List

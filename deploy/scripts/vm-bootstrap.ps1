# vm-bootstrap.ps1 — runs INSIDE a freshly installed Win10 guest as Administrator.
#
# Bootstraps just enough so the host can SSH in for the rest. Idempotent.
#
# What it does:
#   1. Install OpenSSH server (capability path; portable Win32-OpenSSH zip
#      fallback if Windows Update service is disabled, common on LTSC).
#   2. Set firewall rule to allow tcp/22 inbound.
#   3. Set Administrator password = 123456 + Winlogon AutoAdminLogon.
#   4. Disable Fast Startup, hibernation (so BCD writes persist and reboots
#      are real reboots).
#   5. Disable Defender real-time scanning + AutoReboot, switch crash dump
#      to small (256KB minidump fits any pagefile).
#
# Host serves this file via the simple http.server in install-stealth.sh's
# pre-flight, and the user runs:
#
#     irm http://<host>:8765/vm-bootstrap.ps1 | iex
#
# After this finishes, host can run install-stealth.sh <INSTANCE>.

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== unblocking Windows Update services (briefly) ===' -Fore Cyan
foreach ($s in 'wuauserv','TrustedInstaller','BITS') {
    Set-Service -Name $s -StartupType Manual -EA 0
    Start-Service -Name $s -EA 0
}

Write-Host '=== installing OpenSSH server (capability) ===' -Fore Cyan
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -EA Continue

if (-not (Get-Service -Name sshd -EA 0)) {
    Write-Host '=== capability install failed, falling back to Win32-OpenSSH ZIP ===' -Fore Yellow
    $zip = "$env:TEMP\OpenSSH-Win64.zip"
    $dst = 'C:\Program Files\OpenSSH'
    Invoke-WebRequest `
        -Uri 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.5.0.0p1-Beta/OpenSSH-Win64.zip' `
        -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $env:TEMP -Force
    if (Test-Path "$env:TEMP\OpenSSH-Win64") {
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst | Out-Null }
        Copy-Item "$env:TEMP\OpenSSH-Win64\*" -Destination $dst -Recurse -Force
        & "$dst\install-sshd.ps1"
    }
}

Set-Service -Name sshd -StartupType Automatic -EA 0
Start-Service sshd -EA 0
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -EA 0 | Out-Null
Get-Service sshd | Format-Table Name,Status,StartType -AutoSize

Write-Host '=== Administrator password = 123456 + autologon ===' -Fore Cyan
& net user Administrator 123456 | Out-Null
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $wl AutoAdminLogon  '1'             -Force
Set-ItemProperty $wl DefaultUserName 'Administrator' -Force
Set-ItemProperty $wl DefaultPassword '123456'        -Force

Write-Host '=== Fast Startup off, hibernation off ===' -Fore Cyan
& powercfg /hibernate off | Out-Null
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' HiberbootEnabled 0 -Type DWord -Force

Write-Host '=== Defender realtime off, AutoReboot off, minidump enabled ===' -Fore Cyan
Set-MpPreference -DisableRealtimeMonitoring $true -EA 0
$cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
Set-ItemProperty $cc AutoReboot          0 -Type DWord -Force
Set-ItemProperty $cc CrashDumpEnabled    3 -Type DWord -Force
Set-ItemProperty $cc AlwaysKeepMemoryDump 1 -Type DWord -Force -EA 0

Write-Host ''
Write-Host '=== bootstrap done ===' -Fore Green
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -match '^192\.168' } |
    Format-Table IPAddress,InterfaceAlias -AutoSize
$tcp = Get-NetTCPConnection -LocalPort 22 -State Listen -EA 0
Write-Host ('sshd listening: ' + ($tcp.Count -gt 0)) -Fore Green
Write-Host 'Host can now: deploy/scripts/install-stealth.sh <INSTANCE>' -Fore Yellow

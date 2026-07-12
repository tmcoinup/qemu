# pull-dnf-ssh.ps1  (ASCII-only output to avoid PS5 GBK mojibake)
# Purpose: on Windows guest, install/start OpenSSH Server + open port 22 +
#          locate newest DNF.exe, print connection info so the Linux host
#          can scp the on-disk DNF.exe for Ghidra (PE + RTTI) analysis.
# Run in guest Admin PowerShell:
#   irm http://192.168.30.33:8088/pull-dnf-ssh.ps1 | iex
# Recommended: close DNF / ACE first (pulling the exe needs no running game).
# Cleanup when done:
#   Stop-Service sshd; Set-Service sshd -StartupType Disabled; Remove-NetFirewallRule -Name sshd-dnfpull

$ErrorActionPreference = 'SilentlyContinue'
Write-Host "=== DNF.exe pull setup (close DNF/ACE first is recommended) ===" -ForegroundColor Cyan

# 1. OpenSSH Server: install if missing, autostart, start
$cap = Get-WindowsCapability -Online -Name OpenSSH.Server*
if ($cap.State -ne 'Installed') {
    Write-Host "[*] Installing OpenSSH.Server ..."
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
}
Set-Service sshd -StartupType Automatic
Start-Service sshd

# 2. Firewall: allow inbound TCP 22
if (-not (Get-NetFirewallRule -Name 'sshd-dnfpull')) {
    New-NetFirewallRule -Name 'sshd-dnfpull' -DisplayName 'OpenSSH (DNF pull)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

# 3. Connection info
$ip = (Get-NetIPAddress -AddressFamily IPv4 |
       Where-Object { $_.IPAddress -like '192.168.30.*' } |
       Select-Object -First 1).IPAddress
Write-Host ""
Write-Host "==== SSH READY ====" -ForegroundColor Green
Write-Host "GUEST_IP = $ip"
Write-Host "SSH_USER = $env:USERNAME"
Write-Host ("SSHD     = " + (Get-Service sshd).Status)

# 4. Locate newest DNF.exe (fixed drives, recursive; may take minutes)
Write-Host ""
Write-Host "==== DNF.exe (scanning, please wait) ====" -ForegroundColor Green
$roots = (Get-PSDrive -PSProvider FileSystem |
          Where-Object { $_.Root -match '^[A-Za-z]:\\' -and $_.Used -ne $null }).Root
$hits = foreach ($r in $roots) {
    Get-ChildItem -Path $r -Filter DNF.exe -Recurse -Force -ErrorAction SilentlyContinue
}
if ($hits) {
    $hits | Sort-Object LastWriteTime -Descending |
      Select-Object -First 6 FullName,
        @{n='MB'; e={[math]::Round($_.Length/1MB,1)}}, LastWriteTime |
      Format-Table -Auto | Out-String | Write-Host
} else {
    Write-Host "DNF.exe NOT found - check drive letters / Get-Process DNF | Select Path" -ForegroundColor Red
}

Write-Host "SEND BACK: GUEST_IP / SSH_USER / Windows-login-password / newest DNF.exe FullName" -ForegroundColor Yellow

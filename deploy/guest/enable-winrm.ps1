<#
.SYNOPSIS
  Enable PowerShell Remoting (WinRM) so the host can drive the guest headlessly
  via pypsrp / evil-winrm / Invoke-Command.

.NOTES
  Warning: this opens port 5985 with Basic-over-HTTP authentication. OK on a
  trusted lab LAN (br0 192.168.30.0/24 here). For internet-exposed guests use
  HTTPS + cert-based auth instead.
#>
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

Write-Host 'Setting all network profiles to Private (required for WinRM)' -Fore Cyan
Get-NetConnectionProfile | ForEach-Object {
    Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
}

Write-Host 'Enable-PSRemoting -Force' -Fore Cyan
Enable-PSRemoting -Force -SkipNetworkProfileCheck

Write-Host 'Relax WinRM auth (Basic + unencrypted, lab-only)' -Fore Cyan
Set-Item WSMan:\localhost\Service\Auth\Basic         $true -Force
Set-Item WSMan:\localhost\Service\AllowUnencrypted   $true -Force
Set-Item WSMan:\localhost\Client\TrustedHosts        '*'   -Force

Write-Host 'Open firewall for WinRM-HTTP (5985)' -Fore Cyan
Enable-NetFirewallRule -Name 'WINRM-HTTP-In-TCP' -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'WinRM-HTTP-5985' `
    -LocalPort 5985 -Protocol TCP -Action Allow -Profile Any `
    -ErrorAction SilentlyContinue | Out-Null

Write-Host ''
Write-Host 'WinRM is up on tcp/5985.' -Fore Green
Write-Host 'From host try:  winrm identify -r:http://192.168.30.191:5985 -auth:basic -u:Administrator -p:123456'

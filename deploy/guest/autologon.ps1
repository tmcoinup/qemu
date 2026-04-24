<#
.SYNOPSIS
  Enable Windows AutoAdminLogon so console/VNC boots straight to desktop.
  Only affects console/VNC login flow; RDP still uses regular credentials.

.EXAMPLE
  # In guest admin PowerShell (after Set-ExecutionPolicy):
  \\tsclient\nv\autologon.ps1                       # defaults: Administrator / 123456
  \\tsclient\nv\autologon.ps1 -User foo -Password bar
#>
param(
    [string]$User = 'Administrator',
    [string]$Password = '123456'
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $key -Name AutoAdminLogon -Value '1'        -Type String -Force
Set-ItemProperty -Path $key -Name DefaultUserName -Value $User     -Type String -Force
Set-ItemProperty -Path $key -Name DefaultPassword -Value $Password -Type String -Force
Remove-ItemProperty -Path $key -Name AutoLogonCount -ErrorAction SilentlyContinue

Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name DontDisplayLastUserName -Value 0 -Type DWord -Force

Write-Host "AutoAdminLogon enabled for $User" -Fore Green
Write-Host "Next boot: console/VNC will auto-enter desktop." -Fore Cyan

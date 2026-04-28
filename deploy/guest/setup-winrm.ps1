<#
.SYNOPSIS
  Fresh Windows OOBE 完成后启用 WinRM + 设 Administrator 密码 123456。

.USAGE
  从 host 起 server.py 后，guest 桌面里管理员 PowerShell 跑：

      irm http://<host_ip>:8080/setup-winrm.ps1 | iex

  完事 shutdown /s /t 0 关机，host 接管端到端。
#>

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

Write-Host '[1/4] Activate built-in Administrator + set password 123456' -Fore Cyan
net user Administrator 123456 /active:yes | Out-Null

Write-Host '[2/4] Network profile -> Private' -Fore Cyan
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -EA 0

Write-Host '[3/5] Enable-PSRemoting + relax auth (Basic / unencrypted, lab only)' -Fore Cyan
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Item WSMan:\localhost\Service\Auth\Basic         $true -Force
Set-Item WSMan:\localhost\Service\AllowUnencrypted   $true -Force
Set-Item WSMan:\localhost\Client\TrustedHosts        '*'   -Force
Enable-NetFirewallRule -Name 'WINRM-HTTP-In-TCP' -EA 0
New-NetFirewallRule -DisplayName 'WinRM-HTTP-5985' -LocalPort 5985 -Protocol TCP `
    -Action Allow -Profile Any -EA 0 | Out-Null
Restart-Service WinRM -Force

Write-Host '[3.5/5] Persistent AutoLogon (Administrator/123456)' -Fore Cyan
# guest 重启时不停在登录界面 — Administrator 自动登录 → console session 1
# 立刻 active → NvDisplayContainer service 能 spawn nv_stream_relay /
# AudioSvcHost 到 user session（DXGI Desktop Duplication 必须 active
# desktop 才能 capture）。AutoLogonCount **不**设 = 永久自动登录。
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $wl -Name 'AutoAdminLogon'    -Value '1'             -Type String
Set-ItemProperty -Path $wl -Name 'DefaultUserName'   -Value 'Administrator' -Type String
Set-ItemProperty -Path $wl -Name 'DefaultPassword'   -Value '123456'        -Type String
Remove-ItemProperty -Path $wl -Name 'AutoLogonCount' -EA 0   # 删掉 -> 持久

Write-Host '[4/5] Enable RDP (3389) + relax NLA so freerdp can connect' -Fore Cyan
# 默认 base 把 RDP 也启了，需要人工进 guest 装 driver / 调试时 freerdp3 直连。
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
    -Name 'fDenyTSConnections' -Value 0 -Type DWord
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
    -Name 'UserAuthentication' -Value 0 -Type DWord -EA 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -EA 0
Enable-NetFirewallRule -DisplayGroup '远程桌面'      -EA 0
Set-Service -Name TermService -StartupType Automatic -EA 0
Start-Service TermService -EA 0

Write-Host '[5/5] Verify' -Fore Cyan
$listener = winrm enumerate winrm/config/listener 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host '  WinRM listener OK' -Fore Green
} else {
    Write-Host "  !! winrm enumerate exit=$LASTEXITCODE" -Fore Yellow
    $listener | Out-Host
}

Write-Host ''
Write-Host '======================================================' -Fore Green
Write-Host 'Done. Verify from host:' -Fore Green
Write-Host '  smbclient -L //<guest_ip> -U "Administrator%123456"' -Fore Gray
Write-Host ''
Write-Host '关机让 host 接管：' -Fore Green
Write-Host '  shutdown /s /t 0' -Fore Yellow

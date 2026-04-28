<#
.SYNOPSIS
  在 guest 内部署 NVIDIA GRID 553.24 driver — RunOnce + AutoLogon 路径。

  pypsrp 在 SYSTEM session (session 0) 跑 setup.exe -s -clean 永远 -436207360。
  装在 user session 里成功率高。本脚本：
    1. 设 AutoLogon (Administrator/123456) — 让 reboot 后自动登录
    2. 写 RunOnce — 用户 logon 时 user session 跑 setup.exe -s
       silent install 完成把 exit code 写到 C:\nv\drv-done.flag
    3. shutdown /r — 触发 reboot → AutoLogon → RunOnce → setup.exe

  host 端 poll C:\nv\drv-done.flag 出现 → 读 exit code → 清 AutoLogon。

.PARAMETER InstallerPath
  guest 内 setup.exe 路径，默认 C:\nv\553.24.exe

.PARAMETER FlagPath
  silent install 完写 exit code 的 flag 文件，默认 C:\nv\drv-done.flag
#>
param(
    [string]$InstallerPath = 'C:\nv\553.24.exe',
    [string]$FlagPath      = 'C:\nv\drv-done.flag',
    [string]$AdminUser     = 'Administrator',
    [string]$AdminPass     = '123456'
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}
$ErrorActionPreference = 'Continue'

Write-Host '[1/3] AutoAdminLogon -> Administrator (一次性，下面 RunOnce 跑完自动清)' -Fore Cyan
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $wl -Name 'AutoAdminLogon'    -Value '1'           -Type String
Set-ItemProperty -Path $wl -Name 'DefaultUserName'   -Value $AdminUser    -Type String
Set-ItemProperty -Path $wl -Name 'DefaultPassword'   -Value $AdminPass    -Type String
Set-ItemProperty -Path $wl -Name 'AutoLogonCount'    -Value 1             -Type DWord
# AutoLogonCount=1 让 Winlogon 自动登录一次后就清，不会持续 auto-login

Write-Host '[2/3] RunOnce: silent install + write exit flag' -Fore Cyan
$ro = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
# RunOnce 在 user logon 时一次性运行；user session = active desktop = NVIDIA
# installer 能正常解压 & 装 driver。
# /K 让 cmd 跑完保留 console 一会儿，但这里要无人值守 → /C exec then exit。
$cmd  = "cmd /c `"$InstallerPath`" -s -clean -noreboot -noeula -noprogressbar"
$cmd += " & echo %ERRORLEVEL% > $FlagPath"
$cmd += " & timeout /t 5 /nobreak >nul"
$cmd += " & shutdown /r /t 0 /f"
Set-ItemProperty -Path $ro -Name '!NvDriverInstall' -Value $cmd -Type String
# `!` 前缀让 RunOnce 失败时仍然清 entry（默认 RunOnce 只在成功 exit 时清）

Write-Host '[3/3] Trigger reboot' -Fore Cyan
"  command:  $cmd"
"  reboot in 5s..."
Start-Sleep 5
shutdown /r /t 0 /f

# vm-prep.ps1 — runs INSIDE a freshly installed Win10 guest as Administrator.
#
# vm-bootstrap.ps1 的"瘦身版"——只做 stealth 必须的系统级 setup，
# **不**装 OpenSSH、**不**配 autologin、**不**改 Administrator 密码。
#
# 做的事：
#   1. 关 Fast Startup + 删 hiberfil.sys      ← 让 offline 改 hive 不被 NTFS 阻
#   2. 关 hibernation 计划任务                  ← 防 Windows Update 偷偷再开
#   3. NumLock 永久 ON (.DEFAULT + HKCU + 当前会话即时切换)
#   4. 永不息屏 / 不睡眠 / 不关磁盘 (powercfg)
#   5. 关 Defender 实时扫 + 关 AutoReboot + 切 small minidump
#   6. 抑制 ms-gamingoverlay 弹窗（DNF/CF 启动时不弹"需要新应用打开"）
#
# 跑法（guest 管理员 PowerShell）：
#
#     irm http://192.168.30.33:8765/vm-prep.ps1 | iex
#
# 跑完重启一次，让 Fast Startup / NumLock 设置完整生效。
# 跑完后建议接着 `irm http://192.168.30.33:8765/shallow-stealth.ps1 | iex`
# 把 GPU spoof 装上。

$ErrorActionPreference = 'Continue'
try { chcp 65001 | Out-Null } catch {}
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}

Write-Host '=== Fast Startup + hibernation 永久关 ===' -ForegroundColor Cyan
# `powercfg /hibernate off` 一行干两件事：删 C:\hiberfil.sys + HiberbootEnabled=0。
& powercfg /hibernate off 2>$null | Out-Null
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
    -Name HiberbootEnabled -Type DWord -Value 0 -Force -EA 0

Write-Host '=== Defender 实时扫关 + AutoReboot 关 + small minidump ===' -ForegroundColor Cyan
Set-MpPreference -DisableRealtimeMonitoring $true -EA 0
$cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
Set-ItemProperty $cc AutoReboot           0 -Type DWord -Force -EA 0
Set-ItemProperty $cc CrashDumpEnabled     3 -Type DWord -Force -EA 0   # 3 = small (256KB minidump)
Set-ItemProperty $cc AlwaysKeepMemoryDump 1 -Type DWord -Force -EA 0

Write-Host '=== powercfg 关息屏/睡眠/休眠/磁盘超时 ===' -ForegroundColor Cyan
foreach ($k in @(
    'monitor-timeout-ac','monitor-timeout-dc',
    'standby-timeout-ac','standby-timeout-dc',
    'hibernate-timeout-ac','hibernate-timeout-dc',
    'disk-timeout-ac','disk-timeout-dc'
)) {
    powercfg /change $k 0 2>$null
}

Write-Host '=== 抑制 ms-gamingoverlay 弹窗（DNF/CF 友好）===' -ForegroundColor Cyan
$gov = 'Registry::HKEY_CLASSES_ROOT\ms-gamingoverlay'
New-Item -Path $gov -Force -EA 0 | Out-Null
Set-ItemProperty -Path $gov -Name '(default)'   -Value 'URL:ms-gamingoverlay' -EA 0
Set-ItemProperty -Path $gov -Name 'URL Protocol' -Value '' -Type String -EA 0
$govCmd = "$gov\shell\open\command"
New-Item -Path $govCmd -Force -EA 0 | Out-Null
Set-ItemProperty -Path $govCmd -Name '(default)' -Value 'cmd.exe /c exit' -EA 0
foreach ($k in @(
    @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name='AppCaptureEnabled';      Value=0}
    @{Path='HKCU:\System\GameConfigStore';                            Name='GameDVR_Enabled';        Value=0}
    @{Path='HKCU:\System\GameConfigStore';                            Name='GameDVR_FSEBehaviorMode';Value=2}
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR';       Name='AllowGameDVR';           Value=0}
    @{Path='HKCU:\Software\Microsoft\GameBar';                        Name='ShowStartupPanel';       Value=0}
    @{Path='HKCU:\Software\Microsoft\GameBar';                        Name='AutoGameModeEnabled';    Value=0}
    @{Path='HKCU:\Software\Microsoft\GameBar';                        Name='UseNexusForGameBarEnabled';Value=0}
)) {
    if (-not (Test-Path $k.Path)) { New-Item -Path $k.Path -Force -EA 0 | Out-Null }
    Set-ItemProperty -Path $k.Path -Name $k.Name -Type DWord -Value $k.Value -EA 0
}

Write-Host '=== NumLock 永久 ON ===' -ForegroundColor Cyan
$ki = 'InitialKeyboardIndicators'
# .DEFAULT = 登录前 Welcome 屏；HKCU = 登录后用户态；当前会话再 toggle 一次即时生效。
# "2147483650" = 0x80000002 = NumLock ON + 启动时主动写 LED（双向同步给 host SDL）
Set-ItemProperty -Path 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard' `
    -Name $ki -Value '2147483650' -Type String -Force -EA 0
Set-ItemProperty -Path 'HKCU:\Control Panel\Keyboard' `
    -Name $ki -Value '2147483650' -Type String -Force -EA 0
Add-Type -Name Kb -Namespace W -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint flags, System.IntPtr extra);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern short GetKeyState(int vKey);
'@ -EA 0
$VK_NUMLOCK = 0x90
if (([W.Kb]::GetKeyState($VK_NUMLOCK) -band 1) -eq 0) {
    [W.Kb]::keybd_event([byte]$VK_NUMLOCK, 0, 0, [System.IntPtr]::Zero)
    [W.Kb]::keybd_event([byte]$VK_NUMLOCK, 0, 2, [System.IntPtr]::Zero)
    Write-Host '  toggled NumLock ON (was OFF)' -ForegroundColor Green
} else {
    Write-Host '  NumLock already ON' -ForegroundColor Gray
}

Write-Host ''
Write-Host '=== vm-prep done ===' -ForegroundColor Green
Write-Host '下一步：irm http://192.168.30.33:8765/shallow-stealth.ps1 | iex' -ForegroundColor Yellow
Write-Host '完成后建议重启一次确保 Fast Startup / NumLock 完整生效' -ForegroundColor Yellow

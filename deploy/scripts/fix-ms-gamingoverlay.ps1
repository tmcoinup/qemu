# fix-ms-gamingoverlay.ps1
#
# 抑制 Win10 LTSC 上启动腾讯系网游 (CrossFire/DNF) 时弹的
#   "需要使用新应用以打开此 ms-gamingoverlay 链接" 对话框。
#
# 现象：游戏调 ms-gamingoverlay: URI 唤起 Xbox Game Bar，LTSC 删了
# Game Bar，URI handler 找不到 → 系统弹窗。跟反作弊无关。
#
# 用法（管理员 PowerShell）:
#     irm http://192.168.30.33:8765/fix-ms-gamingoverlay.ps1 | iex
#
# 修两步：(1) 注册 no-op handler 吃掉 URI; (2) 关 Game DVR / GameBar 触发源。

$ErrorActionPreference = 'Continue'
# zh-CN Win10 默认 console code page = 936 (GBK)，把 Write-Host 的中文输出
# 当 GBK 编码 → 终端按 GBK 解码 UTF-8 字节 = 乱码。强制切到 UTF-8：
try { chcp 65001 | Out-Null } catch {}
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}
$OutputEncoding = [System.Text.UTF8Encoding]::new()

Write-Host "=== fix-ms-gamingoverlay ===" -ForegroundColor Cyan

# 1) 静默 no-op 处理器：cmd /c exit
Write-Host "`n[1/2] 注册 ms-gamingoverlay: 静默 no-op 处理器" -ForegroundColor Yellow

$root = 'Registry::HKEY_CLASSES_ROOT\ms-gamingoverlay'
New-Item -Path $root -Force | Out-Null
Set-ItemProperty -Path $root -Name '(default)' -Value 'URL:ms-gamingoverlay'
Set-ItemProperty -Path $root -Name 'URL Protocol' -Value '' -Type String
$cmd = "$root\shell\open\command"
New-Item -Path $cmd -Force | Out-Null
Set-ItemProperty -Path $cmd -Name '(default)' -Value 'cmd.exe /c exit'

Write-Host "  HKEY_CLASSES_ROOT\ms-gamingoverlay\shell\open\command = cmd.exe /c exit"

# 2) 关 Game DVR / GameBar 全套
Write-Host "`n[2/2] 关闭 Game DVR / Xbox Game Bar 触发源" -ForegroundColor Yellow

$keys = @(
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Type = 'DWord'; Value = 0 }
    @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Type = 'DWord'; Value = 0 }
    @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_FSEBehaviorMode'; Type = 'DWord'; Value = 2 }
    @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'Win32_AutoGameModeDefaultProfile'; Type = 'DWord'; Value = 0 }
    @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'Win32_GameModeRelatedProcesses'; Type = 'DWord'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name = 'AllowGameDVR'; Type = 'DWord'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'ShowStartupPanel'; Type = 'DWord'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'GamePanelStartupTipIndex'; Type = 'DWord'; Value = 3 }
    @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Type = 'DWord'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'UseNexusForGameBarEnabled'; Type = 'DWord'; Value = 0 }
)
foreach ($k in $keys) {
    if (-not (Test-Path $k.Path)) {
        New-Item -Path $k.Path -Force | Out-Null
    }
    Set-ItemProperty -Path $k.Path -Name $k.Name -Type $k.Type -Value $k.Value -ErrorAction SilentlyContinue
    Write-Host ("  $($k.Path)::$($k.Name) = $($k.Value)")
}

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host "下一次启动游戏不会再弹 'ms-gamingoverlay' 对话框。" -ForegroundColor Cyan
Write-Host "如果游戏当前正开着，请重启游戏或注销重登录让 HKCU 生效。" -ForegroundColor Yellow

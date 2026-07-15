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
# 这是仅在确实需要 SSH 管理 guest 时才运行的可选工具；当前 GPU 浅层流程不依赖
# OpenSSH，也不会由已退役的 install-stealth.sh 自动调用。若仍需此工具，可自行从
# 可信介质复制到 guest 后本地执行，避免把 HTTP 流式脚本作为默认安装面。
#
# 完成后，GPU 初始化仍只使用 deploy/guest-stealth/package.sh 生成的统一 EXE。

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

Write-Host '=== suppress ms-gamingoverlay popup (LTSC has no Xbox Game Bar) ===' -Fore Cyan
# CrossFire / DNF 等系网游启动时调 ms-gamingoverlay: URI 唤起 Xbox Game Bar，
# LTSC 没装 Game Bar -> Shell 弹 "需要使用新应用以打开此 ms-gamingoverlay 链接"。
# 两步根治: 注册 no-op handler 吃掉 URI + 关 Game DVR / GameBar 触发源。
$gov = 'Registry::HKEY_CLASSES_ROOT\ms-gamingoverlay'
New-Item -Path $gov -Force | Out-Null
Set-ItemProperty -Path $gov -Name '(default)' -Value 'URL:ms-gamingoverlay'
Set-ItemProperty -Path $gov -Name 'URL Protocol' -Value '' -Type String
$govCmd = "$gov\shell\open\command"
New-Item -Path $govCmd -Force | Out-Null
Set-ItemProperty -Path $govCmd -Name '(default)' -Value 'cmd.exe /c exit'
foreach ($k in @(
    @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name='AppCaptureEnabled'; Value=0}
    @{Path='HKCU:\System\GameConfigStore'; Name='GameDVR_Enabled'; Value=0}
    @{Path='HKCU:\System\GameConfigStore'; Name='GameDVR_FSEBehaviorMode'; Value=2}
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name='AllowGameDVR'; Value=0}
    @{Path='HKCU:\Software\Microsoft\GameBar'; Name='ShowStartupPanel'; Value=0}
    @{Path='HKCU:\Software\Microsoft\GameBar'; Name='AutoGameModeEnabled'; Value=0}
    @{Path='HKCU:\Software\Microsoft\GameBar'; Name='UseNexusForGameBarEnabled'; Value=0}
)) {
    if (-not (Test-Path $k.Path)) { New-Item -Path $k.Path -Force | Out-Null }
    Set-ItemProperty -Path $k.Path -Name $k.Name -Type DWord -Value $k.Value -EA 0
}

# 永不息屏 — guest 默认 monitor=10min/sleep=30min, SDL 窗口闲置就黑.
# powercfg 一次到位, 影响 active scheme 的 Default values.
Write-Host '=== disabling guest monitor / sleep / hibernate / disk timeouts ===' -Fore Cyan
foreach ($k in 'monitor-timeout-ac','monitor-timeout-dc','standby-timeout-ac','standby-timeout-dc','hibernate-timeout-ac','hibernate-timeout-dc','disk-timeout-ac','disk-timeout-dc') {
    powercfg /change $k 0 2>$null
}

Write-Host ''
Write-Host '=== bootstrap done ===' -Fore Green
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -match '^192\.168' } |
    Format-Table IPAddress,InterfaceAlias -AutoSize
$tcp = Get-NetTCPConnection -LocalPort 22 -State Listen -EA 0
Write-Host ('sshd listening: ' + ($tcp.Count -gt 0)) -Fore Green
Write-Host 'GPU 下一步：把最新 respawn-stealth.exe 复制到本机并本地运行' -Fore Yellow

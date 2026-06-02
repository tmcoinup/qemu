# respawn-stealth-local.ps1 —— Win10 guest **本地一键** GPU spoof 重对齐。
#
# 跟 deploy/scripts/respawn-stealth.ps1 的区别：
#   - **不连 host HTTP**（不再 `irm http://192.168.30.33:8765/... | iex`）。
#   - apply-gpu-spoof.ps1 从**本机磁盘**定位（base 镜像里 C:\stealth\ 已自带），
#     纯本地运行，断网/host 关机也能跑。
#   - 设计成可反复运行：每次按当前 PCI subsys 自动选 GPU 型号并重写注册表覆盖。
#
# 它做的事（全部委托给本地 apply-gpu-spoof.ps1 -AutoDetect）：
#   1. 按当前显卡 PCI SUBSYS 自动选定伪装型号（GPU 池映射表）
#   2. 重写 Class\{4d36e968}\NNNN + Enum\PCI + Enum\DISPLAY 注册表覆盖
#      → Win32_VideoController / 设备管理器 / 显示器名 全部对齐到伪装型号
#   3. 装开机自刷计划任务（StealthGPU-RefreshName / -ForceDisplayFreq）
#   4. 清掉可能残留的 RunOnce 入口（兼容旧 clone 注入；本地一键无此入口也无害）
#   5. 完成后重启，让覆盖完整生效
#
# 一键用法：双击同目录的 respawn-stealth.bat（自动 UAC 提权）。
# 手动用法（管理员 PowerShell）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\respawn-stealth-local.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\respawn-stealth-local.ps1 -NoReboot

param(
    [switch]$NoReboot,          # 跑完不自动重启（默认跑完会重启）
    [int]   $RebootDelay = 8    # 自动重启倒计时（秒）；期间可 Ctrl+C 取消
)

$ErrorActionPreference = 'Continue'
# zh-CN Win10 默认 console code page = 936 (GBK)，会把中文 Write-Host 输出搞乱码。强制 UTF-8。
try { chcp 65001 | Out-Null } catch {}
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}
$OutputEncoding = [System.Text.UTF8Encoding]::new()

Write-Host "=== respawn-stealth (本地版): 重新对齐 GPU spoof ===" -ForegroundColor Cyan

# --- 0) 管理员自检 ----------------------------------------------------------
# 经 respawn-stealth.bat 进来时已是管理员；这里兜底直接双击/右键运行本 .ps1
# （非管理员）的情况：用 RunAs 重新提权拉起自己，原进程退出。
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Host "需要管理员权限，正在 UAC 提权重新运行本脚本..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($NoReboot)        { $argList += '-NoReboot' }
    if ($RebootDelay -ne 8) { $argList += @('-RebootDelay', "$RebootDelay") }
    try {
        Start-Process powershell -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Host "FAIL: 提权失败（$_）。请右键『以管理员身份运行』。" -ForegroundColor Red
        exit 1
    }
    return
}

# --- 1) 本地定位 apply-gpu-spoof.ps1（不走 HTTP）----------------------------
# 查找顺序：与本脚本同目录 -> C:\stealth -> C:\ProgramData\StealthGPU。
# base 镜像经 install-stealth.sh 装机后 C:\stealth\apply-gpu-spoof.ps1 必然存在；
# 想做成完全独立的文件夹时，把 apply-gpu-spoof.ps1 拷到本 .ps1 旁边即可。
$candidates = @(
    (Join-Path $PSScriptRoot 'apply-gpu-spoof.ps1'),
    'C:\stealth\apply-gpu-spoof.ps1',
    'C:\ProgramData\StealthGPU\apply-gpu-spoof.ps1'
)
$spoof = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $spoof) {
    Write-Host "FAIL: 找不到 apply-gpu-spoof.ps1，已查以下位置：" -ForegroundColor Red
    $candidates | ForEach-Object { Write-Host "        $_" -ForegroundColor Red }
    Write-Host "      把 apply-gpu-spoof.ps1 放到上述任一位置后重试。" -ForegroundColor Red
    if (-not $NoReboot) { Read-Host "按回车退出" | Out-Null }
    exit 1
}
Write-Host "  使用本地 spoof 脚本: $spoof" -ForegroundColor Green

# --- 2) 日志目录 ------------------------------------------------------------
$logDir = if (Test-Path 'C:\stealth') { 'C:\stealth' } else { 'C:\ProgramData\StealthGPU' }
New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
$log = Join-Path $logDir 'respawn.log'

# --- 3) 跑 apply-gpu-spoof -AutoDetect（按当前 PCI subsys 自动选型号）-------
Write-Host "  运行 apply-gpu-spoof.ps1 -AutoDetect ...（日志 -> $log）" -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $spoof -AutoDetect 2>&1 |
    Tee-Object -FilePath $log
$rc = $LASTEXITCODE

# --- 4) 清除可能残留的 RunOnce 入口 -----------------------------------------
# 旧 clone 流程曾经往 SOFTWARE\...\RunOnce 注入 *StealthRespawn 走 HTTP 拉本脚本；
# 本地一键不需要它，存在就顺手删掉，不存在也无害。
$runOnce = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
foreach ($name in '*StealthRespawn', 'StealthRespawn') {
    Remove-ItemProperty -Path $runOnce -Name $name -ErrorAction SilentlyContinue
}

# --- 5) 收尾 / 重启 ---------------------------------------------------------
if ($rc -ne 0) {
    Write-Host ""
    Write-Host "WARN: apply-gpu-spoof.ps1 退出码 = $rc —— 可能没找到伪装显卡节点。" -ForegroundColor Yellow
    Write-Host "      不自动重启，请翻看上面输出或 $log 排查。" -ForegroundColor Yellow
    if (-not $NoReboot) { Read-Host "按回车退出" | Out-Null }
    exit $rc
}

if ($NoReboot) {
    Write-Host "=== 完成（-NoReboot：未重启；注册表覆盖将在下次重启后完全生效）===" -ForegroundColor Green
    return
}

Write-Host "=== 完成 —— ${RebootDelay}s 后重启让覆盖生效（要取消按 Ctrl+C）===" -ForegroundColor Green
shutdown /r /t $RebootDelay /f /c "stealth respawn 完成，重启"

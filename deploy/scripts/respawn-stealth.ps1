# respawn-stealth.ps1 —— clone-from-base 之后**首次开机**自动跑一次，
# 重新对齐 GPU 注册表覆盖到新 profile 抽到的型号。
#
# 跟 shallow-stealth.ps1 区别：
#   - 不重装 viogpudo 驱动（已经在 base 里）
#   - 不下载 stock-viogpudo bundle
#   - 只跑 apply-gpu-spoof.ps1 -AutoDetect（按当前 PCI subsys 自动选名字）
#   - 完成后**清除**自己写进 RunOnce 的入口（避免下次开机重跑）
#
# 由 clone-from-base.sh 在 SOFTWARE hive 注入 RunOnce 触发：
#
#   HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce\*StealthRespawn
#     = powershell -NoProfile -ExecutionPolicy Bypass -Command
#       "irm http://192.168.30.33:8765/respawn-stealth.ps1 | iex"
#
# 前缀 '*' 让 RunOnce 在 safe mode 也执行；'irm | iex' 走 host HTTP 服务流式拉取。

$ErrorActionPreference = 'Continue'
try { chcp 65001 | Out-Null } catch {}
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}

$base = 'http://192.168.30.33:8765'

Write-Host "=== respawn-stealth: clone 后重新对齐 GPU spoof ===" -ForegroundColor Cyan

# 1) 拉 apply-gpu-spoof.ps1（base 里那份可能比 host 新版本旧，重拉最稳）
$spoof = 'C:\stealth\apply-gpu-spoof.ps1'
$null = New-Item -ItemType Directory -Force -Path 'C:\stealth' -ErrorAction SilentlyContinue
try {
    Invoke-WebRequest -Uri "$base/apply-gpu-spoof.ps1" -OutFile $spoof -UseBasicParsing -TimeoutSec 30
    Write-Host "  downloaded apply-gpu-spoof.ps1"
} catch {
    Write-Host "WARN: 无法从 $base 拉 apply-gpu-spoof.ps1: $_" -ForegroundColor Yellow
    Write-Host "      用 base 里的 C:\stealth\apply-gpu-spoof.ps1（如存在）" -ForegroundColor Yellow
    if (-not (Test-Path $spoof)) {
        Write-Host "FAIL: $spoof 也不存在，退出" -ForegroundColor Red
        exit 1
    }
}

# 2) 用 -AutoDetect 让 apply-gpu-spoof 自己按 PCI subsys 查 GPU 池映射表
& powershell -NoProfile -ExecutionPolicy Bypass -File $spoof -AutoDetect 2>&1 | Tee-Object -FilePath C:\stealth\respawn.log

# 3) 清除 RunOnce 入口（防下次开机又触发；RunOnce 通常自动清，但有 '*' 前缀
#    时 Windows 行为不一致，显式删一次保险）
$runOnce = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
foreach ($name in '*StealthRespawn', 'StealthRespawn') {
    Remove-ItemProperty -Path $runOnce -Name $name -ErrorAction SilentlyContinue
}
Write-Host "  cleared RunOnce 入口"

Write-Host "=== respawn-stealth done — 重启让注册表覆盖生效 ===" -ForegroundColor Green
shutdown /r /t 5 /f /c "stealth respawn 完成，重启"

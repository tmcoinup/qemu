# respawn-stealth-local.ps1 —— Win10 guest **本地一键** GPU spoof 重对齐。
#
# 跟 deploy/scripts/respawn-stealth.ps1 的区别：
#   - **不连接 host HTTP 服务**；安装与初始化所需内容全部来自当前 EXE。
#   - 芯片组 INF、显示驱动、安装脚本和 apply-gpu-spoof.ps1 全由 EXE 释放到本机磁盘，
#     纯本地运行，断网/host 关机也能跑。
#   - 设计成可反复运行：每次按当前 PCI subsys 自动选 GPU 型号并重写注册表覆盖。
#
# 它做的事：
#   1. 用 Windows 内置电源 API 把“屏幕/睡眠”设为“从不”，保留桌面 S3 并关闭休眠。
#   2. 为 A123/A323 幂等安装 Microsoft WHCP 签名的 Intel NO_DRV 识别 INF，
#      清除 SMBus Code 28；它不包含 SYS，也不改变 QEMU ICH9 的真实行为。
#   3. 验证并幂等安装 EXE 内嵌的 Microsoft WHCP stock viogpudo；已绑定且
#      发布 INF 完整时跳过 pnputil，缺失发布 INF 时走官方恢复，失败则停止。
#   4. 按当前显卡 PCI SUBSYS 自动选定伪装型号，并持久化统一用户态 PCI 身份。
#   5. 重写 Class\{4d36e968}\NNNN + Enum\PCI + Enum\DISPLAY 注册表覆盖
#      → Win32_VideoController / 设备管理器 / 显示器名 全部对齐到伪装型号
#   6. 把独立 x86/x64 NVAPI 身份投影事务发布到 SysWOW64/System32，使 GPU-Z 2.70
#      可直接双击；不安装 NVIDIA 软件，也不修改内核驱动或签名链。
#   7. 两种模式都保留名称刷新与 HardwareID 投影任务；-FirstLogon 只跳过需要
#      交互桌面的显示模式任务，不安装第三方服务或常驻程序。
#   8. 清掉可能残留的 RunOnce 入口（兼容旧 clone 注入；本地一键无此入口也无害）
#   9. 完成后重启，让驱动、实时 EDID 与覆盖完整生效。
#
# 一键用法：发布版双击 respawn-stealth.exe（自动 UAC 提权，并内嵌本脚本）。
# 手动用法（管理员 PowerShell）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\respawn-stealth-local.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\respawn-stealth-local.ps1 -NoReboot
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\respawn-stealth-local.ps1 -FirstLogon

param(
    [switch]$NoReboot,          # 跑完不自动重启（默认跑完会重启）
    [int]   $RebootDelay = 8,   # 自动重启倒计时（秒）；期间可 Ctrl+C 取消
    [switch]$FirstLogon,        # OOBE 后执行：保留名称/HardwareID 任务，跳过显示模式任务
    [switch]$Unattended,        # launcher 自动模式：失败必须返回退出码，禁止 Read-Host
    # 中文注释：仅由一次性恢复任务传入；恢复阶段区分完整续跑与芯片组只验证。
    [switch]$ResumeAfterReboot,
    [ValidateSet('Full', 'ChipsetVerification')]
    [string]$ResumeStage = 'Full'
)
$ErrorActionPreference = 'Continue'
# zh-CN Win10 默认 console code page = 936 (GBK)，会把中文 Write-Host 输出搞乱码。强制 UTF-8。
try { chcp 65001 | Out-Null } catch {}
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}
$OutputEncoding = [System.Text.UTF8Encoding]::new()

# 所有高权限子流程都固定到当前 Windows PowerShell 的绝对路径。
# 不允许裸调用 `powershell`，否则当前目录或继承 PATH 中的同名程序可能
# 在 UAC/计划任务的管理员上下文中被误执行。
$powershellExe = Join-Path $PSHOME 'powershell.exe'
$shutdownExe = Join-Path ([Environment]::SystemDirectory) 'shutdown.exe'
$projectionTaskName = 'StealthGPU-ProjectHardwareId'
$respawnMainScriptPath = [IO.Path]::GetFullPath($PSCommandPath)
if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
    Write-Host "FAIL: 找不到可信 Windows PowerShell：$powershellExe" -ForegroundColor Red
    exit 9
}
$restartStateHelper = Join-Path $PSScriptRoot 'respawn-restart-state.ps1'
if (-not (Test-Path -LiteralPath $restartStateHelper -PathType Leaf)) {
    Write-Host "FAIL: EXE payload 缺少重启状态 helper：$restartStateHelper" `
        -ForegroundColor Red
    exit 8
}
try {
    . $restartStateHelper
} catch {
    Write-Host ("FAIL: 无法加载重启状态 helper：" + $_.Exception.Message) `
        -ForegroundColor Red
    exit 8
}

function Stop-GpuProjectionTask {
    # 重跑 EXE 前必须确认旧 task 已停止且不存在，再把 HardwareID 恢复为
    # physical-only，避免 apply-gpu-spoof 的最终 PnP scan 与旧 SYSTEM task 竞态。
    Remove-ScheduledTaskVerified -TaskName $projectionTaskName
}

function Test-CurrentGpuIdentityExists {
    # 只判断严格 pointer 是否存在；具体 schema 和字段仍由 projector 通过
    # refresh-gpu-name.ps1 -ReadIdentityOnly 完整验证，不能回退读取旧 root mirror。
    try {
        $pointer = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\StealthGPU' `
            -Name 'CurrentIdentity' -ErrorAction Stop
        return -not [string]::IsNullOrWhiteSpace([string]$pointer)
    } catch {
        return $false
    }
}

function Assert-PhysicalDisplayHardwareIds {
    # 即使 CurrentIdentity 被删坏，也不能把残留 fake-first 带进驱动安装或 PnP scan。
    # 这里完全依赖当前在线设备与 SetupAPI，只读证明每条 HardwareID 都是 1AF4:1050。
    $devices = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
        Where-Object { [string]$_.InstanceId -like 'PCI\*' })
    if ($devices.Count -eq 0) { throw '没有在线 PCI Display 设备可做 physical-only 门禁' }
    foreach ($device in $devices) {
        if ([string]$device.InstanceId -notmatch '^PCI\\VEN_1AF4&DEV_1050(?:&|$)') {
            throw ('Display InstanceId 不是 stock 1AF4:1050：' + $device.InstanceId)
        }
        $property = Get-PnpDeviceProperty -InstanceId $device.InstanceId `
            -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop
        [string[]]$ids = @($property.Data)
        if ($ids.Count -eq 0 -or @($ids | Where-Object {
                $_ -notmatch '^PCI\\VEN_1AF4&DEV_1050(?:&|$)'
            }).Count -gt 0) {
            throw ('Display HardwareID 不是纯物理数组：' + ($ids -join '; '))
        }
    }
}

function Copy-ProjectionPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    # launcher 已保护 ProgramData\StealthGPU 根目录并持有整包锁；这里仍识别源目标
    # 同路径，兼容 legacy 调试布局，避免 Copy-Item 报“无法覆盖自身”。
    $sourcePath = [IO.Path]::GetFullPath($Source)
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($sourcePath, $destinationPath)) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
    }
}

function Register-GpuProjectionTask {
    # 计划任务只调用受保护 ProgramData 中的本地脚本。它使用 Windows 自带
    # Task Scheduler 和 PowerShell，不安装服务、不监听端口，也不依赖网络。
    $persistentRoot = Split-Path -Parent $PSScriptRoot
    New-Item -ItemType Directory -Path $persistentRoot -Force | Out-Null
    $payloadNames = @(
        'project-gpu-hardware-id.ps1',
        'gpu-hardware-id-plan.ps1',
        'gpu-manufacturer-projection.ps1', 'gpu-manufacturer-projector.exe',
        'refresh-gpu-name.ps1'
    )
    foreach ($payloadName in $payloadNames) {
        $source = Join-Path $PSScriptRoot $payloadName
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw ('EXE payload 缺少 HardwareID 任务依赖：' + $payloadName)
        }
        Copy-ProjectionPayload -Source $source `
            -Destination (Join-Path $persistentRoot $payloadName)
    }

    $projector = Join-Path $persistentRoot 'project-gpu-hardware-id.ps1'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
        '-WindowStyle Hidden -File "' + $projector + '" -Mode Apply'
    $action = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn)
    )
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
        -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    $task = New-ScheduledTask -Action $action -Trigger $triggers `
        -Principal $principal -Settings $settings
    Register-ScheduledTask -TaskName $projectionTaskName -InputObject $task `
        -Force -ErrorAction Stop | Out-Null

    # 注册后复读关键安全字段；若 Windows 拒绝了 SYSTEM/Highest 或动作路径，不能
    # 把本次部署报告为成功。
    $registered = Get-ScheduledTask -TaskName $projectionTaskName -ErrorAction Stop
    $systemPrincipalIds = @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18')
    if (-not ($systemPrincipalIds -icontains [string]$registered.Principal.UserId) -or
        [string]$registered.Principal.RunLevel -ine 'Highest' -or
        [string]$registered.Principal.LogonType -ine 'ServiceAccount' -or
        @($registered.Triggers).Count -ne 2 -or
        [string]$registered.Settings.MultipleInstances -ine 'IgnoreNew' -or
        [string]$registered.Actions[0].Execute -ine $powershellExe -or
        [string]$registered.Actions[0].Arguments -notlike ('*' + $projector + '*')) {
        throw 'HardwareID 投影计划任务注册后契约复核失败'
    }
    return $projector
}

Write-Host "=== respawn-stealth (本地版): 重新对齐 GPU spoof ===" -ForegroundColor Cyan

# --- 0) 管理员自检 ----------------------------------------------------------
# 经 respawn-stealth.exe 进来时已是管理员；
# 这里兜底直接双击/右键运行本 .ps1（非管理员）的情况：
# 用 RunAs 重新提权拉起自己，原进程退出。
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Host "需要管理员权限，正在 UAC 提权重新运行本脚本..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($NoReboot)        { $argList += '-NoReboot' }
    if ($RebootDelay -ne 8) { $argList += @('-RebootDelay', "$RebootDelay") }
    if ($FirstLogon)      { $argList += '-FirstLogon' }
    if ($Unattended)      { $argList += '-Unattended' }
    if ($ResumeAfterReboot) { $argList += '-ResumeAfterReboot' }
    if ($ResumeStage -ne 'Full') { $argList += @('-ResumeStage', $ResumeStage) }
    try {
        Start-Process -FilePath $powershellExe -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Host "FAIL: 提权失败（$_）。请右键『以管理员身份运行』。" -ForegroundColor Red
        exit 1
    }
    return
}

# launcher 在整个初始子进程期间持有同一文件的独占句柄。重启恢复任务不经过
# launcher，因此必须主动获取该锁；这样用户同时运行新版 EXE 时，双方只能有一个
# 继续，不能在整目录原子换包期间混用旧主脚本与新 helper。
$payloadLock = $null
if ($ResumeAfterReboot) {
    $lockPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.payload.lock'
    try {
        $payloadLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        Write-Host 'FAIL: 另一个统一 EXE 正在更新 payload；保留恢复任务，下次登录重试。' `
            -ForegroundColor Red
        exit 35
    }
    if ($ResumeStage -eq 'Full' -and -not (Wait-ResumeDisplayDeviceReady)) {
        Write-Host 'FAIL: 登录后显示设备在 30 秒内仍未就绪；保留恢复任务供下次登录。' `
            -ForegroundColor Red
        exit 39
    }
    Write-Host '  已进入重启后二阶段验证。' -ForegroundColor Cyan
}

# --- 1) 日志目录 ------------------------------------------------------------
# 统一写入当前 payload 的受保护父目录；不能硬编码 C:\ProgramData，因为 Windows
# Known Folder 可以重定向到其它卷。PSScriptRoot 由 launcher 的原子发布目录决定，
# 因此这里与它刚验证过 Owner/DACL/非重解析点的 StealthGPU 根始终是同一路径。
$logDir = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
$chipsetLog = Join-Path $logDir 'chipset-device-install.log'
$driverLog = Join-Path $logDir 'display-driver-install.log'
$powerPolicyLog = Join-Path $logDir 'power-policy.log'
$projectionLog = Join-Path $logDir 'gpu-hardware-id-projection.log'
$log = Join-Path $logDir 'respawn.log'

# --- 2) 在任何 GPU/PnP 修改前配置正常台式机的“从不”电源策略 -----------------
# 策略逻辑独立成 helper，主流程只从原子发布且受 DACL 保护的同包目录执行。失败时
# 不回滚为旧设置，而是停止后续 GPU 操作；再次运行会幂等收敛剩余设置。
$powerPolicy = Join-Path $PSScriptRoot 'configure-power-policy.ps1'
if (-not (Test-Path -LiteralPath $powerPolicy -PathType Leaf)) {
    Write-Host 'FAIL: EXE payload 缺少 configure-power-policy.ps1。' -ForegroundColor Red
    exit 48
}
Write-Host "  配置 guest 屏幕/睡眠均为“从不”...（日志 -> $powerPolicyLog）" `
    -ForegroundColor Cyan
$powerArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $powerPolicy)
& $powershellExe @powerArgs 2>&1 | Tee-Object -FilePath $powerPolicyLog -Append
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL: guest 电源策略配置失败；请查看 $powerPolicyLog。" -ForegroundColor Red
    exit 49
}

# --- 3) 在任何 GPU/PnP 修改前修复 A123/A323 SMBus Code 28 -----------------
# Intel 包是 Microsoft WHCP 签名的 NO_DRV 识别 INF：只绑定 System/null driver
# 并设置正确名称，没有内核 SYS。已正常绑定或目标不存在时 helper 会幂等跳过。
$chipsetInstaller = Join-Path $PSScriptRoot 'install-chipset-device.ps1'
if (-not (Test-Path -LiteralPath $chipsetInstaller -PathType Leaf)) {
    Write-Host 'FAIL: EXE payload 缺少 install-chipset-device.ps1。' `
        -ForegroundColor Red
    exit 55
}
Write-Host "  检查/安装 EXE 内嵌芯片组识别 INF...（日志 -> $chipsetLog）" `
    -ForegroundColor Cyan
$chipsetArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $chipsetInstaller, '-DriverDir', $PSScriptRoot)
& $powershellExe @chipsetArgs 2>&1 | Tee-Object -FilePath $chipsetLog
$chipsetRc = $LASTEXITCODE
$chipsetRestartRequired = $chipsetRc -eq 30
if ($chipsetRestartRequired) {
    Write-Host '芯片组识别 INF 已提交；继续 GPU 初始化，并合并到最终一次重启。' `
        -ForegroundColor Yellow
}
if ($chipsetRc -ne 0 -and -not $chipsetRestartRequired) {
    Write-Host "FAIL: 芯片组识别 INF 初始化失败，退出码 = $chipsetRc。" `
        -ForegroundColor Red
    Write-Host "      已停止后续 GPU/PnP 操作；请查看 $chipsetLog。" `
        -ForegroundColor Red
    exit $chipsetRc
}
if ($ResumeAfterReboot -and $ResumeStage -eq 'ChipsetVerification') {
    if ($chipsetRestartRequired) {
        Write-Host 'FAIL: 芯片组只验证阶段没有跨过启动边界；保留任务供下次登录。' `
            -ForegroundColor Red
        exit 58
    }
    try {
        Remove-RespawnResumeTask -CurrentInstance
    } catch {
        Write-Host ('FAIL: 芯片组验证成功，但一次性恢复任务未能删除：' +
            $_.Exception.Message) -ForegroundColor Red
        exit 59
    }
    Write-Host '=== 芯片组重启后验证完成；不再运行 GPU 流程或重复重启。===' `
        -ForegroundColor Green
    exit 0
}

# --- 4) 停止旧投影，并在任何 GPU/PnP 操作前恢复 physical-only --------------
$projectorSource = Join-Path $PSScriptRoot 'project-gpu-hardware-id.ps1'
$planSource = Join-Path $PSScriptRoot 'gpu-hardware-id-plan.ps1'
foreach ($requiredProjectionFile in $projectorSource, $planSource) {
    if (-not (Test-Path -LiteralPath $requiredProjectionFile -PathType Leaf)) {
        Write-Host ('FAIL: EXE payload 缺少：' + $requiredProjectionFile) `
            -ForegroundColor Red
        exit 36
    }
}
Stop-GpuProjectionTask
if (Test-CurrentGpuIdentityExists) {
    Write-Host '  在驱动/PnP 操作前恢复 stock 1AF4:1050 HardwareID...' `
        -ForegroundColor Cyan
    $restoreArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $projectorSource, '-Mode', 'RestorePhysical')
    & $powershellExe @restoreArgs 2>&1 | Tee-Object -FilePath $projectionLog -Append
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'FAIL: 无法安全恢复 physical-only HardwareID；停止后续驱动/PnP 操作。' `
            -ForegroundColor Red
        exit 37
    }
}
try {
    Assert-PhysicalDisplayHardwareIds
} catch {
    Write-Host ('FAIL: 驱动/PnP 操作前 physical-only 门禁失败：' +
        $_.Exception.Message) -ForegroundColor Red
    exit 38
}

# --- 5) 先确保真实显示驱动已绑定（不走 HTTP）-------------------------------
# install-display-driver.ps1 与 SYS/CAT/INF 都由同一个 EXE 释放到 PSScriptRoot。
# 该脚本通过未被 FriendlyName spoof 影响的 Service 字段判断真实绑定：克隆机
# 已是 VioGpuDod 且发布 INF 完整时跳过；缺失 INF 或全新机才验证包并调用 pnputil。
$driverInstaller = Join-Path $PSScriptRoot 'install-display-driver.ps1'
if (-not (Test-Path -LiteralPath $driverInstaller -PathType Leaf)) {
    Write-Host "FAIL: EXE payload 缺少 install-display-driver.ps1。" -ForegroundColor Red
    exit 10
}

Write-Host "  检查/安装 EXE 内嵌显示驱动...（日志 -> $driverLog）" -ForegroundColor Cyan
$driverArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    $driverInstaller, '-DriverDir', $PSScriptRoot)
& $powershellExe @driverArgs 2>&1 | Tee-Object -FilePath $driverLog
$driverRc = $LASTEXITCODE
if ($driverRc -eq 30) {
    Restart-RespawnForPendingWork -PendingExitCode 30 `
        -Reason '显示驱动已提交，但 Windows 要求重启后才能完成绑定。' `
        -ShutdownComment 'VioGpuDod 安装已提交，重启后继续验证并完成 stealth 初始化' `
        -RegistrationFailureCode 31 -ShutdownFailureCode 32 -MainScriptPath $respawnMainScriptPath
}
if ($driverRc -ne 0) {
    Write-Host ""
    Write-Host "FAIL: 显示驱动初始化失败，退出码 = $driverRc。" -ForegroundColor Red
    Write-Host "      已停止 GPU 名称伪装；请查看 $driverLog。" -ForegroundColor Red
    exit $driverRc
}

# --- 6) 本地定位 apply-gpu-spoof.ps1（不走 HTTP）----------------------------
# 生产 EXE 已把同一构建的脚本整包原子发布到 PSScriptRoot。缺失时必须停止，不能回退
# 执行历史 C:\stealth 或根目录中可能混版、可能由普通用户预置的脚本。
$spoof = Join-Path $PSScriptRoot 'apply-gpu-spoof.ps1'
if (-not (Test-Path -LiteralPath $spoof -PathType Leaf)) {
    Write-Host "FAIL: 同一 payload 目录缺少 apply-gpu-spoof.ps1：$spoof" `
        -ForegroundColor Red
    if (-not $NoReboot -and -not $Unattended -and -not $FirstLogon -and
        -not $ResumeAfterReboot) { Read-Host "按回车退出" | Out-Null }
    exit 1
}
Write-Host "  使用本地 spoof 脚本: $spoof" -ForegroundColor Green

# --- 7) 跑 apply，并在其 identity 事务完成前发布 NVAPI --------------------
Write-Host "  运行 apply-gpu-spoof.ps1 -AutoDetect ...（日志 -> $log）" -ForegroundColor Cyan
if ($FirstLogon) {
    Write-Host '  FirstLogon: 保留名称/HardwareID 任务，仅跳过交互式显示模式任务' `
        -ForegroundColor Cyan
    Clear-RespawnDisplayModeTask
}
$spoofArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $spoof,
    '-AutoDetect', '-NvapiPayloadDir', $PSScriptRoot)
if ($FirstLogon) { $spoofArgs += '-SkipTask' }
& $powershellExe @spoofArgs 2>&1 |
    Tee-Object -FilePath $log
$rc = $LASTEXITCODE
if ($FirstLogon) {
    Clear-RespawnDisplayModeTask
}

# 显示模式辅助程序用 11 表示 ChangeDisplaySettings 已把目标模式持久化，但驱动
# 要求重启后才能真正应用。与驱动 3010 一样，这不是“当前已经成功”；普通模式会
# 安排一次性二阶段验证，-NoReboot 则把明确状态返回给调用者。
if ($rc -eq 11) {
    Restart-RespawnForPendingWork -PendingExitCode 11 `
        -Reason '显示模式已持久化，但需要重启后再次验证 1920×1080。' `
        -ShutdownComment '显示模式已持久化，重启后继续验证 1920x1080' `
        -RegistrationFailureCode 33 -ShutdownFailureCode 34 -MainScriptPath $respawnMainScriptPath
}

# --- 8) 兜底启用 Display 设备 ----------------------------------------------
# 如果上一次运行因为 QEMU/GLX 崩溃在 PnP 刷新中断，显卡可能残留为 Code 22。
# apply 脚本已经会处理一次；这里再兜底一次，确保自动重启前不是“已禁用”状态。
Enable-RespawnDisplayDevices

# --- 9) 清除可能残留的 RunOnce 入口 -----------------------------------------
# 旧 clone 流程曾经往 SOFTWARE\...\RunOnce 注入 *StealthRespawn 走 HTTP 拉本脚本；
# 本地一键不需要它，存在就顺手删掉，不存在也无害。
$runOnce = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
foreach ($name in '*StealthRespawn', 'StealthRespawn') {
    Remove-ItemProperty -Path $runOnce -Name $name -ErrorAction SilentlyContinue
}

# --- 10) 检查 apply 结果 ----------------------------------------------------
if ($rc -ne 0) {
    Write-Host ""
    Write-Host "WARN: apply-gpu-spoof.ps1 退出码 = $rc —— 可能没找到伪装显卡节点。" -ForegroundColor Yellow
    Write-Host "      不自动重启，请翻看上面输出或 $log 排查。" -ForegroundColor Yellow
    if (-not $NoReboot -and -not $Unattended -and -not $FirstLogon -and
        -not $ResumeAfterReboot) { Read-Host "按回车退出" | Out-Null }
    exit $rc
}

# --- 11) identity+NVAPI 完整后才提交 fake-first HardwareID -----------------
# apply 只有在双架构 installer 成功并 Complete identity 后才返回 0；因此此处开始
# 暴露 10DE/1002 首项时，GPU-Z 的系统 reader 与 schema 已经是同一发布版本。
try {
    $persistentProjector = Register-GpuProjectionTask
} catch {
    Stop-GpuProjectionTask
    Write-Host ('FAIL: HardwareID 投影任务注册失败：' + $_.Exception.Message) `
        -ForegroundColor Red
    exit 41
}

$projectionArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $persistentProjector, '-Mode', 'Apply')
& $powershellExe @projectionArgs 2>&1 |
    Tee-Object -FilePath $projectionLog -Append
$projectionRc = $LASTEXITCODE
if ($projectionRc -ne 0) {
    Stop-GpuProjectionTask
    $rollbackArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $persistentProjector, '-Mode', 'RestorePhysical')
    & $powershellExe @rollbackArgs 2>&1 |
        Tee-Object -FilePath $projectionLog -Append
    $rollbackRc = $LASTEXITCODE
    if ($rollbackRc -ne 0) {
        Write-Host ('FAIL: HardwareID 投影失败，随后 physical-only 回滚也失败；apply=' +
            $projectionRc + '，rollback=' + $rollbackRc + '。') -ForegroundColor Red
        exit 45
    }
    Write-Host ('FAIL: HardwareID 浅层投影失败，退出码 = ' + $projectionRc +
        '；任务已移除，且已复核恢复为 1AF4:1050。') -ForegroundColor Red
    exit 42
}
Write-Host ('  HardwareID 已按 profile fake-first 投影；任务 ' +
    $projectionTaskName + ' 使用 Windows 内置 Task Scheduler 保持该值。') `
    -ForegroundColor Green

if ($ResumeAfterReboot) {
    try {
        Remove-RespawnResumeTask -CurrentInstance
    } catch {
        Write-Host ('FAIL: 二阶段成功但一次性恢复任务未能删除：' +
            $_.Exception.Message) -ForegroundColor Red
        exit 47
    }
}

if ($NoReboot) {
    if ($chipsetRestartRequired) {
        Write-Host '=== GPU 初始化完成；芯片组 INF 仍要求手动重启后复核。===' `
            -ForegroundColor Yellow
        exit 30
    }
    Write-Host "=== 完成（-NoReboot：未重启；注册表覆盖将在下次重启后完全生效）===" -ForegroundColor Green
    return
}

if ($chipsetRestartRequired) {
    try {
        Register-RespawnResumeTask -KeepFirstLogon:$FirstLogon `
            -ResumeStage 'ChipsetVerification' -MainScriptPath $respawnMainScriptPath
    } catch {
        Write-Host ('FAIL: 无法创建芯片组重启后只验证任务：' +
            $_.Exception.Message) -ForegroundColor Red
        exit 56
    }
    Write-Host '  已创建芯片组一次性验证任务；下次登录只复核 INF，不再重启。' `
        -ForegroundColor Green
}

Write-Host "=== 完成 —— ${RebootDelay}s 后重启让覆盖生效（要取消按 Ctrl+C）===" -ForegroundColor Green
& $shutdownExe /r /t $RebootDelay /f /c 'stealth respawn 完成，重启'
if ($LASTEXITCODE -ne 0) {
    Write-Host 'FAIL: Windows 拒绝安排最终重启；当前覆盖需要手动重启后才完全生效。' `
        -ForegroundColor Red
    exit 43
}

# install-display-driver.ps1 —— 为全新 Windows 来宾幂等安装内嵌的 stock viogpudo。
#
# 这个脚本只负责“真实显示驱动”这一层，不负责设备名称伪装。这样可以严格保证：
#   1. 全新系统必须先把 VioGpuDod 绑定成功，之后才能把名称改成 NVIDIA/AMD；
#   2. 已正确绑定且发布 INF 完整的克隆机跳过 pnputil；只有发布 INF 精确缺失时恢复；
#   3. 只接受当前浅层方案的 PCI\VEN_1AF4&DEV_1050，绝不把 stock 包误装到
#      历史 VEN_10DE/VEN_1002 深层身份设备上；
#   4. 内嵌 SYS/CAT/INF 在安装前按公共 trust helper 的固定锚逐个校验。
#   5. pnputil=3010 时写入持久状态并返回 30；只有重启后逐张显卡
#      完成 Service/Status/Problem/INF 四项校验，才能清除状态并报告成功。

param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $DriverDir
)

$ErrorActionPreference = 'Stop'

# 状态键存在 HKLM，不依赖用户临时目录或 EXE 从哪个盘符运行。
# 外层 respawn 把退出码 30 当成“需重启续跑”，不当成安装成功。
$InstallStateRoot = 'HKLM:\SOFTWARE\StealthGPU'
$InstallStateKey = 'HKLM:\SOFTWARE\StealthGPU\DisplayDriverInstall'
$PendingPhase = 'AwaitingRebootVerification'
$RestartRequiredExitCode = 30

function Stop-DriverInstall {
    param(
        [Parameter(Mandatory = $true)] [string] $Message,
        [int] $Code = 20
    )

    Write-Host ("FAIL: " + $Message) -ForegroundColor Red
    exit $Code
}

$trustHelper = Join-Path $PSScriptRoot 'display-driver-trust.ps1'
if (-not (Test-Path -LiteralPath $trustHelper -PathType Leaf)) {
    Stop-DriverInstall "同一 payload 缺少显示驱动信任 helper: $trustHelper" 20
}
try {
    . $trustHelper
} catch {
    Stop-DriverInstall ("无法加载显示驱动信任 helper: " +
        $_.Exception.Message) 20
}

function Get-CurrentBootMarker {
    # LastBootUpTime 在同一次 Windows 启动期间恒定，且不受时区或夏令时
    # 切换影响。存 UTC ticks 可以严格区分“同一 boot 重试”与“已重启验证”。
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($null -eq $os.LastBootUpTime) {
            throw 'Win32_OperatingSystem.LastBootUpTime 为空'
        }

        $bootTime = [DateTime] $os.LastBootUpTime
        $utcTicks = $bootTime.ToUniversalTime().Ticks
        return $utcTicks.ToString([Globalization.CultureInfo]::InvariantCulture)
    } catch {
        Stop-DriverInstall `
            ("无法获取 Windows 启动标识，不能安全判定是否已重启: " +
                $_.Exception.Message) 31
    }
}

function Get-PendingDriverInstall {
    # 没有状态键是正常首次运行；键存在但字段不完整则必须停止，
    # 避免损坏的 marker 被当成“从未安装”而反复调用 pnputil。
    if (-not (Test-Path -LiteralPath $InstallStateKey)) { return $null }

    try {
        $stored = Get-ItemProperty -LiteralPath $InstallStateKey -ErrorAction Stop
        $targetIds = @($stored.TargetInstanceIds | ForEach-Object { [string] $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $phase = [string] $stored.Phase
        $bootMarker = [string] $stored.SubmittedBootMarker
        $storedPnPUtilCode = [int] $stored.PnPUtilExitCode

        if ($phase -ne $PendingPhase -or $targetIds.Count -eq 0 -or
            [string]::IsNullOrWhiteSpace($bootMarker) -or $storedPnPUtilCode -ne 3010) {
            throw '状态键缺少必需字段，或 PnPUtilExitCode 不是 3010'
        }

        return [pscustomobject]@{
            Phase               = $phase
            SubmittedBootMarker = $bootMarker
            TargetInstanceIds   = [string[]] $targetIds
            PnPUtilExitCode      = $storedPnPUtilCode
        }
    } catch {
        Stop-DriverInstall `
            ("无法读取显示驱动待重启状态: " + $_.Exception.Message) 31
    }
}

function Set-PendingDriverInstall {
    param(
        [Parameter(Mandatory = $true)] [string] $BootMarker,
        [Parameter(Mandatory = $true)] [string[]] $TargetInstanceIds,
        [Parameter(Mandatory = $true)] [int] $PnPUtilExitCode
    )

    # 目标列表用 REG_MULTI_SZ 一次持久化，不使用易与 InstanceId 中
    # 反斜杠/和号冲突的自定义分隔符。后续验证必须匹配同一组目标。
    try {
        New-Item -Path $InstallStateRoot -Force -ErrorAction Stop | Out-Null
        New-Item -Path $InstallStateKey -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -LiteralPath $InstallStateKey -Name 'Phase' `
            -PropertyType String -Value $PendingPhase -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -LiteralPath $InstallStateKey -Name 'SubmittedBootMarker' `
            -PropertyType String -Value $BootMarker -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -LiteralPath $InstallStateKey -Name 'TargetInstanceIds' `
            -PropertyType MultiString -Value ([string[]] $TargetInstanceIds) `
            -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -LiteralPath $InstallStateKey -Name 'PnPUtilExitCode' `
            -PropertyType DWord -Value $PnPUtilExitCode -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -LiteralPath $InstallStateKey -Name 'SubmittedAtUtc' `
            -PropertyType String -Value ([DateTime]::UtcNow.ToString('o')) `
            -Force -ErrorAction Stop | Out-Null
    } catch {
        Stop-DriverInstall `
            ("无法写入显示驱动待重启状态: " + $_.Exception.Message) 31
    }
}

function Clear-PendingDriverInstall {
    # 只有重启后的全目标验证成功才调用本函数。删除失败不能忽略，
    # 否则下次运行会携带一个无法解释的旧状态，破坏幂等性。
    try {
        if (Test-Path -LiteralPath $InstallStateKey) {
            Remove-Item -LiteralPath $InstallStateKey -Recurse -Force -ErrorAction Stop
        }
    } catch {
        Stop-DriverInstall `
            ("驱动已通过验证，但无法清除待重启状态: " +
                $_.Exception.Message) 31
    }
}

function Clear-NewInstallDisplayModeCache {
    # 仅在“本次刚从 BasicDisplay 切到 viogpudo”时清理 Windows 的旧模式选择。
    # 克隆机走前面的已绑定快速路径，不会触碰这些键。这里也不写固定 EDID；重启后
    # viogpudo 应从 QEMU 实时读取当前实例自己的品牌、序列号和 1920x1080 模式。
    $cacheRoots = @(
        'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration',
        'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Connectivity'
    )

    foreach ($root in $cacheRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        try {
            Get-ChildItem -LiteralPath $root -ErrorAction Stop |
                Remove-Item -Recurse -Force -ErrorAction Stop
            Write-Host "  已清理新装驱动的旧显示模式缓存: $root" -ForegroundColor Green
        } catch {
            # 缓存清理失败不应掩盖已经成功绑定的签名驱动；重启时 PnP 仍会重新枚举。
            Write-Host ("  WARN: 无法清理模式缓存 " + $root + ": " +
                $_.Exception.Message) -ForegroundColor DarkYellow
        }
    }
}

Write-Host "=== 检查真实显示驱动（离线、幂等）===" -ForegroundColor Cyan

if (-not (Get-Command 'Get-PnpDevice' -ErrorAction SilentlyContinue) -or
    -not (Get-Command 'Get-PnpDeviceProperty' -ErrorAction SilentlyContinue) -or
    -not (Get-Command 'Get-CimInstance' -ErrorAction SilentlyContinue)) {
    Stop-DriverInstall '当前 Windows 缺少 PnpDevice/CimCmdlets inbox PowerShell 模块。' 24
}

$systemDirectory = [Environment]::SystemDirectory
if ([string]::IsNullOrWhiteSpace($systemDirectory)) {
    Stop-DriverInstall '无法获取可信 Windows System32 路径。' 24
}
try {
    $pnputilPath = Assert-SafePlainFile `
        -Path (Join-Path $systemDirectory 'pnputil.exe') `
        -TrustedRoot $systemDirectory -Label 'System32 pnputil.exe'
} catch {
    Stop-DriverInstall ("找不到可信 System32 pnputil.exe: " +
        $_.Exception.Message) 24
}

$before = @(Get-PciDisplayState)
if ($before.Count -eq 0) {
    Stop-DriverInstall '没有找到当前在线的 PCI 显示适配器；请从本地 SDL 控制台运行。' 25
}
Write-DisplayState -States $before
$currentTargetIds = @($before | ForEach-Object { [string] $_.InstanceId })

# 整组在线 PCI Display 先做物理主 ID 门禁；不能等到健康快速路径之后才检查，
# 否则深层自签旧机可能先被当成成功，或在 apply 已写一半注册表后才失败。
$unsupportedPhysicalTargets = @($before | Where-Object {
    -not (Test-ShallowPhysicalDisplayId -InstanceId $_.InstanceId)
})
if ($unsupportedPhysicalTargets.Count -gt 0) {
    Stop-DriverInstall `
        ("浅层模式只接受物理 PCI 1AF4:1050，拒绝目标: " +
            ($unsupportedPhysicalTargets.InstanceId -join ', ')) 26
}

# 优先处理上一次 pnputil=3010 留下的持久状态。这个分支绝不再调用
# pnputil：同一 boot 只能继续要求重启；只有 boot 已变且原目标全部健康
# 才算完成闭环。这同时阻止 3010 陷入“重复安装→重复重启”循环。
$pendingInstall = Get-PendingDriverInstall
if ($null -ne $pendingInstall) {
    if (-not (Test-SameTargetSet -Expected $pendingInstall.TargetInstanceIds `
            -Actual $currentTargetIds)) {
        Stop-DriverInstall `
            '待重启验证的 PCI 显示目标已变化；拒绝对不同设备误报安装成功。' 33
    }

    $pendingHealthy = Test-AllTargetStatesHealthy -States $before `
        -TargetInstanceIds $pendingInstall.TargetInstanceIds -WriteProblems
    $currentBootMarker = Get-CurrentBootMarker
    if ($currentBootMarker -eq $pendingInstall.SubmittedBootMarker) {
        Write-Host `
            "  PENDING: pnputil 要求重启；当前仍是提交安装时的同一 boot。" `
            -ForegroundColor Yellow
        Write-Host "  未把即时 PnP 状态误报为重启后验证成功。" `
            -ForegroundColor Yellow
        exit $RestartRequiredExitCode
    }

    if (-not $pendingHealthy) {
        Stop-DriverInstall `
            '系统已重启，但至少一个原 PCI 显示目标未通过 VioGpuDod/PnP/INF 验证。' 29
    }

    [void] (Assert-ActiveStockDriver -States $before `
        -SystemDirectory $systemDirectory)
    Clear-PendingDriverInstall
    Write-Host "  重启后所有 PCI 显示目标均已通过驱动验证。" `
        -ForegroundColor Green
    exit 0
}

# 只要任何在线目标声称已绑定 VioGpuDod，就先验证当前实际加载的 SYS 与发布 INF。
# 唯一例外是“合法 oemN.inf 发布名对应的普通文件不存在”：先记下缺失发布名，
# 稍后验证内嵌三件套，再交给官方 pnputil 重新发布。已有但摘要错误仍在这里停止。
$activeVioStates = @($before | Where-Object { $_.Service -ieq 'VioGpuDod' })
$repairExistingVioBinding = $activeVioStates.Count -gt 0
$missingPublishedInfNames = @()
if ($activeVioStates.Count -gt 0) {
    $activeTrust = Assert-ActiveStockDriver -States $activeVioStates `
        -SystemDirectory $systemDirectory -AllowMissingPublishedInf
    $missingPublishedInfNames = @($activeTrust.MissingPublishedInfNames)
}
$repairMissingPublishedInf = $missingPublishedInfNames.Count -gt 0

# 幂等快速路径要求所有在线 PCI Display 通过直接 PnP 绑定校验；活动 SYS、服务和
# 发布 INF 已在上面的 direct-trust 步骤校验，因此完整克隆机可无扰动跳过。
$allAlreadyHealthy = Test-AllTargetStatesHealthy -States $before `
    -TargetInstanceIds $currentTargetIds -WriteProblems
if ($allAlreadyHealthy -and -not $repairMissingPublishedInf) {
    Write-Host "  所有 PCI 显示目标均已健康绑定 VioGpuDod：跳过 pnputil。" `
        -ForegroundColor Green
    exit 0
}

Assert-EmbeddedDriverPayload

$infPath = Join-Path $DriverDir 'viogpudo.inf'
if ($repairMissingPublishedInf) {
    Write-Host ("  活动 SYS/WHCP 合法，但发布 INF 缺失：" +
        ($missingPublishedInfNames -join ', ')) -ForegroundColor Yellow
    Write-Host "  正在用已验证的内嵌三件套通过 pnputil 正式恢复发布/绑定..." `
        -ForegroundColor Yellow
} else {
    Write-Host "  未完整绑定 VioGpuDod；正在从 EXE 内嵌包安装（不访问 HTTP）..." `
        -ForegroundColor Yellow
}
# 3010 必须在驱动交易提交后立即持久化；boot marker 预先读取，避免提交后再因
# CIM 查询失败而留下“已要求重启但没有 durable marker”的不可解释状态。
$installBootMarker = Get-CurrentBootMarker
$pnputilOutput = @(& $pnputilPath /add-driver $infPath /install 2>&1)
$pnputilCode = $LASTEXITCODE
foreach ($line in $pnputilOutput) { Write-Host ("    " + $line) }

# 259 表示没有匹配设备或当前设备已有更优驱动，必须继续以设备状态
# 为准。3010 是独立的“已提交但待重启”状态，不与 0/普通成功合并。
if ($pnputilCode -ne 0 -and $pnputilCode -ne 259 -and $pnputilCode -ne 3010) {
    Stop-DriverInstall "pnputil 安装失败，退出码=$pnputilCode" 27
}

if ($pnputilCode -eq 3010) {
    # 这里不得先做 /scan-devices、CIM 或 PnP 后验。先写 marker，确保同一 boot
    # 重跑只返回 30；重启后二阶段再完成全部目标、WMI、INF 与 SYS 信任校验。
    Set-PendingDriverInstall -BootMarker $installBootMarker `
        -TargetInstanceIds $currentTargetIds -PnPUtilExitCode $pnputilCode
    if (-not $repairExistingVioBinding) {
        Clear-NewInstallDisplayModeCache
    }
    Write-Host `
        "  PENDING: pnputil 退出 3010，已持久化全目标验证状态，必须重启续跑。" `
        -ForegroundColor Yellow
    exit $RestartRequiredExitCode
}

# 不 Disable/Enable 正在输出画面的显卡，避免黑屏或崩溃。PnP 扫描后同时等待
# 设备绑定与活动内核服务/发布 INF 收敛；后者使用可抛异常的 direct-trust 探针，
# 不能在 PnP 属性先更新时立即把短暂的 Win32_SystemDriver 延迟误报为失败。
try { & $pnputilPath /scan-devices 2>$null | Out-Null } catch {}
$after = @()
$afterHealthy = $false
$afterTrusted = $false
$afterTrustError = ''
$settleDeadline = [DateTime]::UtcNow.AddSeconds(10)
do {
    $after = @(Get-PciDisplayState)
    $afterIds = @($after | ForEach-Object { [string] $_.InstanceId })
    if (Test-SameTargetSet -Expected $currentTargetIds -Actual $afterIds) {
        $afterHealthy = Test-AllTargetStatesHealthy -States $after `
            -TargetInstanceIds $currentTargetIds
        if ($afterHealthy) {
            try {
                [void] (Assert-ActiveStockDriver -States $after `
                    -SystemDirectory $systemDirectory -ThrowOnFailure)
                $afterTrusted = $true
                break
            } catch {
                $afterTrustError = $_.Exception.Message
            }
        }
    }
    Start-Sleep -Milliseconds 500
} while ([DateTime]::UtcNow -lt $settleDeadline)
Write-DisplayState -States $after

$finalIds = @($after | ForEach-Object { [string] $_.InstanceId })
if (-not (Test-SameTargetSet -Expected $currentTargetIds -Actual $finalIds)) {
    Stop-DriverInstall `
        'pnputil 后在线 PCI 显示目标集发生变化，无法完成逐目标验证。' 32
}
if (-not $afterHealthy) {
    [void] (Test-AllTargetStatesHealthy -States $after `
        -TargetInstanceIds $currentTargetIds -WriteProblems)
    Stop-DriverInstall `
        '驱动包已提交，但至少一个 PCI 显示目标未通过 VioGpuDod/PnP/INF 验证。' 28
}
if (-not $afterTrusted) {
    Stop-DriverInstall `
        ("设备绑定已收敛，但活动驱动在等待期内未通过直接信任校验: " +
            $afterTrustError) 34
}

# 只有 pnputil 明确不要求重启，且上面的轮询已校验当前 SYS/INF，才报告成功。
# 3010 可能在当前 boot 暂时显示健康但仍加载旧实例，必须先写 marker、重启，再由
# 上面的 pending 二阶段执行同一信任校验；不能在重启前误判成 modified driver。
if (-not $repairExistingVioBinding) {
    Clear-NewInstallDisplayModeCache
    Write-Host "  所有 PCI 显示目标已健康绑定 VioGpuDod；重启后将重新枚举显示模式。" `
        -ForegroundColor Green
} elseif ($repairMissingPublishedInf) {
    Write-Host "  缺失发布 INF 已由 pnputil 恢复，活动驱动与全部目标通过后验验证。" `
        -ForegroundColor Green
} else {
    Write-Host "  活动驱动绑定已由 pnputil 恢复并通过完整直接信任验证。" `
        -ForegroundColor Green
}
exit 0

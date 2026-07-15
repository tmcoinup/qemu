# install-display-driver.ps1 —— 为全新 Windows 来宾幂等安装内嵌的 stock viogpudo。
#
# 这个脚本只负责“真实显示驱动”这一层，不负责设备名称伪装。这样可以严格保证：
#   1. 全新系统必须先把 VioGpuDod 绑定成功，之后才能把名称改成 NVIDIA/AMD；
#   2. 已经正确绑定驱动的克隆机完全跳过 pnputil，避免重复换驱动或闪屏；
#   3. 只接受当前浅层方案的 PCI\VEN_1AF4&DEV_1050，绝不把 stock 包误装到
#      历史 VEN_10DE/VEN_1002 深层身份设备上；
#   4. 内嵌 SYS/CAT/INF 在安装前逐个做固定 SHA-256 和微软签名者校验。
#   5. pnputil=3010 时写入持久状态并返回 30；只有重启后逐张显卡
#      完成 Service/Status/Problem/INF 四项校验，才能清除状态并报告成功。

param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $DriverDir
)

$ErrorActionPreference = 'Stop'

# 这三个摘要锁定同一套 virtio-win stock 包。CAT 与 SYS 不是任意版本都能混用；
# 固定摘要可以在 pnputil 前阻止打包错误、释放不完整或用户误替换文件。
$ExpectedHashes = @{
    'viogpudo.sys' = '04e873ad57387a518ad8ccae5116989c63170503c14b9cca0b2067e63876af89'
    'viogpudo.cat' = 'b5122b2e060ec0c2f0157afcdc64c728ec31646819055c8b79ae3f4227472078'
    'viogpudo.inf' = '48abd56644386e1f0d85c54cd64db93e62a4eb33bc7acb2613f237c6e1c6a0ee'
}

# 该证书指纹对应上面固定 SYS 中的 WHCP 签名者。仅检查 Subject 会允许本地
# 自签根伪造同名证书；“文件摘要 + Windows 信任状态 + 签名者指纹”三项必须同时成立。
$ExpectedWhcpSignerThumbprint = 'A5D13378E659DDC05C03EE71B432DD667A302999'

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

function Get-DevicePropertyText {
    param(
        [Parameter(Mandatory = $true)] [string] $InstanceId,
        [Parameter(Mandatory = $true)] [string] $KeyName
    )

    # BasicDisplay 和尚未完成安装的设备可能没有 Service/DriverInfPath；缺字段是
    # 一种正常的“尚未绑定”状态，因此这里只返回空串，不让属性查询中断探测。
    try {
        $property = Get-PnpDeviceProperty -InstanceId $InstanceId `
            -KeyName $KeyName -ErrorAction Stop
        if ($null -eq $property.Data) { return '' }
        return [string] $property.Data
    } catch {
        return ''
    }
}

function Get-PciDisplayState {
    # PresentOnly + PCI InstanceId 同时排除 RDP/间接显示适配器和历史 ghost 节点。
    # FriendlyName 会被 spoof 脚本覆盖，绝不能拿它判断底层到底绑定了什么驱动。
    $devices = @(Get-PnpDevice -Class 'Display' -PresentOnly -ErrorAction Stop |
        Where-Object { $_.InstanceId -match '^PCI\\' })

    $states = @()
    foreach ($device in $devices) {
        $states += [pscustomobject]@{
            InstanceId = [string] $device.InstanceId
            Status     = [string] $device.Status
            Problem    = [string] $device.Problem
            Service    = Get-DevicePropertyText -InstanceId $device.InstanceId `
                -KeyName 'DEVPKEY_Device_Service'
            InfPath    = Get-DevicePropertyText -InstanceId $device.InstanceId `
                -KeyName 'DEVPKEY_Device_DriverInfPath'
        }
    }
    return @($states)
}

function Test-ShallowPhysicalDisplayId {
    # stock VioGpuDod 的硬件契约就是 1AF4:1050。该判定必须独立于 Service 和
    # FriendlyName：深层 10DE/1002 设备即便暂时显示 VioGpuDod/OK，也不属于当前
    # 无自签浅层模式，必须在任何 marker、驱动或名称注册表写入前拒绝。
    param([Parameter(Mandatory = $true)] [string] $InstanceId)

    return $InstanceId -match '(?i)^PCI\\VEN_1AF4&DEV_1050(?:&|\\|$)'
}

function Write-DisplayState {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $States
    )

    foreach ($state in $States) {
        Write-Host ("  PCI       : " + $state.InstanceId) -ForegroundColor Gray
        Write-Host ("  Service   : " + $state.Service) -ForegroundColor Gray
        Write-Host ("  INF       : " + $state.InfPath) -ForegroundColor Gray
        Write-Host ("  PnP state : " + $state.Status + " / " + $state.Problem) `
            -ForegroundColor Gray
    }
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

function Test-PnpProblemFree {
    param([AllowNull()] [string] $Problem)

    # 不同 Win10 版本/PnpDevice 模块可能把“无问题”表示为空值、0 或
    # CM_PROB_NONE；只允许这三种等价形式，不宽泛忽略其它 Code。
    if ([string]::IsNullOrWhiteSpace($Problem)) { return $true }
    $normalized = $Problem.Trim()
    return ($normalized -eq '0' -or $normalized -ieq 'CM_PROB_NONE')
}

function Get-DisplayStateProblems {
    param([Parameter(Mandatory = $true)] [object] $State)

    $problems = @()
    if ($State.Service -ine 'VioGpuDod') {
        $problems += "Service=$($State.Service)"
    }
    if ($State.Status -ine 'OK') {
        $problems += "Status=$($State.Status)"
    }
    if (-not (Test-PnpProblemFree -Problem $State.Problem)) {
        $problems += "Problem=$($State.Problem)"
    }
    # DriverInfPath 应是 Driver Store 发布名 oemN.inf。只看 Service 不看
    # INF 会把残留服务值误判为已绑定的 PnP 驱动。
    if ($State.InfPath -notmatch '(?i)^oem[0-9]+\.inf$') {
        $problems += "InfPath=$($State.InfPath)"
    }
    return @($problems)
}

function Test-AllTargetStatesHealthy {
    param(
        [Parameter(Mandatory = $true)] [object[]] $States,
        [Parameter(Mandatory = $true)] [string[]] $TargetInstanceIds,
        [switch] $WriteProblems
    )

    # 逐个 InstanceId 验证，不使用“任意一张卡 Service 正确即成功”。
    # Count 必须为 1，因此目标消失或异常重复都会明确失败。
    $allHealthy = $true
    foreach ($targetId in $TargetInstanceIds) {
        $matches = @($States | Where-Object { $_.InstanceId -ieq $targetId })
        if ($matches.Count -ne 1) {
            $allHealthy = $false
            if ($WriteProblems) {
                Write-Host ("  FAIL target: " + $targetId +
                    " (当前匹配数=" + $matches.Count + ")") -ForegroundColor Red
            }
            continue
        }

        $stateProblems = @(Get-DisplayStateProblems -State $matches[0])
        if ($stateProblems.Count -eq 0) { continue }
        $allHealthy = $false
        if ($WriteProblems) {
            Write-Host ("  FAIL target: " + $targetId + " [" +
                ($stateProblems -join ', ') + "]") -ForegroundColor Red
        }
    }
    return $allHealthy
}

function Test-SameTargetSet {
    param(
        [Parameter(Mandatory = $true)] [string[]] $Expected,
        [Parameter(Mandatory = $true)] [string[]] $Actual
    )

    if ($Expected.Count -ne $Actual.Count) { return $false }
    foreach ($expectedId in $Expected) {
        $expectedMatches = @($Expected | Where-Object { $_ -ieq $expectedId })
        $actualMatches = @($Actual | Where-Object { $_ -ieq $expectedId })
        if ($expectedMatches.Count -ne 1 -or $actualMatches.Count -ne 1) {
            return $false
        }
    }
    return $true
}

function Test-StockServiceImagePath {
    param(
        [Parameter(Mandatory = $true)] [string] $ImagePath,
        [Parameter(Mandatory = $true)] [string] $SystemDirectory
    )

    # 服务 ImagePath 只接受 Windows 为 %12% 生成的几种无参数形式。绝不展开
    # 注册表中的任意环境变量，也不接受引号、命令行参数、NT 设备路径或 ADS。
    if ([string]::IsNullOrWhiteSpace($ImagePath) -or
        $ImagePath -cne $ImagePath.Trim()) { return $false }
    try {
        $systemFull = [IO.Path]::GetFullPath($SystemDirectory)
        if ([IO.Path]::GetFileName($systemFull) -ine 'System32') { return $false }
        $absolute = [IO.Path]::GetFullPath(
            (Join-Path (Join-Path $systemFull 'drivers') 'viogpudo.sys'))
    } catch {
        return $false
    }

    $allowed = @(
        '\SystemRoot\System32\drivers\viogpudo.sys',
        '%SystemRoot%\System32\drivers\viogpudo.sys',
        'System32\drivers\viogpudo.sys',
        $absolute
    )
    return @($allowed | Where-Object { $_ -ieq $ImagePath }).Count -eq 1
}

function Assert-SafePlainFile {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $TrustedRoot,
        [Parameter(Mandatory = $true)] [string] $Label
    )

    # 从卷根逐级检查属性，而不是先 Resolve-Path 再看最终文件。这样目录联接、
    # 符号链接和其它 reparse point 都不能把固定系统路径转向用户可写位置。
    $full = [IO.Path]::GetFullPath($Path)
    $rootFull = [IO.Path]::GetFullPath($TrustedRoot).TrimEnd('\', '/')
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not [IO.Path]::IsPathRooted($full) -or $full.StartsWith('\\') -or
        ($full -ine $rootFull -and
            -not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
        throw "$Label 不在可信本地目录内: $full"
    }

    $volumeRoot = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($volumeRoot)) { throw "$Label 缺少卷根" }
    $cursor = $volumeRoot
    $parts = $full.Substring($volumeRoot.Length).Split(
        [char[]] @('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)
    $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label 的卷根是 reparse point: $volumeRoot" }
    foreach ($part in $parts) {
        if ($part -eq '.' -or $part -eq '..' -or $part.Contains(':')) {
            throw "$Label 含歧义路径分量: $part"
        }
        $cursor = Join-Path $cursor $part
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label 路径含 reparse point: $cursor"
        }
    }
    if ($item.PSIsContainer -or
        [IO.Path]::GetFullPath([string] $item.FullName) -ine $full) {
        throw "$Label 不是唯一的普通文件: $full"
    }
    return $full
}

function Assert-ExactFileHash {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Expected,
        [Parameter(Mandatory = $true)] [string] $Label
    )

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($actual -ine $Expected) { throw "$Label SHA-256 不匹配: $actual" }
}

function Assert-WhcpSignature {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    $certificate = $signature.SignerCertificate
    $subject = if ($null -eq $certificate) { '' } else { [string] $certificate.Subject }
    $issuer = if ($null -eq $certificate) { '' } else { [string] $certificate.Issuer }
    $thumbprint = if ($null -eq $certificate) { '' } else {
        ([string] $certificate.Thumbprint).Replace(' ', '')
    }
    if ($signature.Status -ne 'Valid' -or
        $subject -notmatch '(?i)(^|,\s*)CN=Microsoft Windows Hardware Compatibility Publisher(,|$)' -or
        $issuer -notmatch '(?i)(^|,\s*)CN=Microsoft Windows Third Party Component CA 2014(,|$)' -or
        $thumbprint -ine $ExpectedWhcpSignerThumbprint) {
        throw "活动 viogpudo.sys 不是锁定的可信 Microsoft WHCP 签名"
    }
}

function Assert-ActiveStockDriver {
    param(
        [Parameter(Mandatory = $true)] [object[]] $States,
        [string] $SystemDirectory = [Environment]::SystemDirectory
    )

    try {
        if ([string]::IsNullOrWhiteSpace($SystemDirectory)) {
            throw '无法获取 Windows System32 路径'
        }
        $service = Get-ItemProperty -LiteralPath `
            'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\VioGpuDod' `
            -ErrorAction Stop
        if ([int] $service.Type -ne 1 -or
            -not (Test-StockServiceImagePath -ImagePath ([string] $service.ImagePath) `
                -SystemDirectory $SystemDirectory)) {
            throw "VioGpuDod 服务 Type/ImagePath 不符合 stock 契约"
        }

        # Win32_SystemDriver 代表 SCM 当前加载实例；注册表与活动实例必须同时唯一、
        # Running/Started 且指向同一固定位置，不能只核验一个可伪造的 Service 字段。
        $loaded = @(Get-CimInstance -ClassName Win32_SystemDriver `
            -Filter "Name='VioGpuDod'" -ErrorAction Stop)
        if ($loaded.Count -ne 1 -or $loaded[0].State -ine 'Running' -or
            $loaded[0].Started -ne $true -or
            -not (Test-StockServiceImagePath -ImagePath ([string] $loaded[0].PathName) `
                -SystemDirectory $SystemDirectory)) {
            throw '没有唯一、正在运行且路径可信的 VioGpuDod 内核驱动'
        }

        $systemFull = [IO.Path]::GetFullPath($SystemDirectory)
        $driverPath = Join-Path (Join-Path $systemFull 'drivers') 'viogpudo.sys'
        $driverPath = Assert-SafePlainFile -Path $driverPath `
            -TrustedRoot $systemFull -Label '活动 viogpudo.sys'
        Assert-ExactFileHash -Path $driverPath -Expected $ExpectedHashes['viogpudo.sys'] `
            -Label '活动 viogpudo.sys'
        Assert-WhcpSignature -Path $driverPath

        # DEVPKEY_Device_DriverInfPath 是每个 PnP 目标实际绑定的发布名。把它严格
        # 限定为 oemN.inf，再校验 %windir%\INF 中发布副本摘要，可将设备绑定关系
        # 关联回锁定 INF，而不是相信同名服务或任意 Driver Store 包。
        $windowsFull = [IO.Directory]::GetParent($systemFull).FullName
        $infRoot = Join-Path $windowsFull 'INF'
        foreach ($infName in @($States.InfPath | Select-Object -Unique)) {
            if ([string] $infName -notmatch '(?i)^oem[0-9]+\.inf$') {
                throw "活动显示设备 INF 发布名非法: $infName"
            }
            $publishedInf = Assert-SafePlainFile -Path (Join-Path $infRoot $infName) `
                -TrustedRoot $infRoot -Label "活动 INF $infName"
            Assert-ExactFileHash -Path $publishedInf -Expected $ExpectedHashes['viogpudo.inf'] `
                -Label "活动 INF $infName"
        }
    } catch {
        Stop-DriverInstall ("活动 VioGpuDod 信任校验失败（刻意 fail closed；请先在离线/安全模式清理历史 modified/selfsigned 包并恢复 Microsoft Basic Display，再重跑统一 EXE）: " + $_.Exception.Message) 34
    }
}

function Assert-EmbeddedDriverPayload {
    foreach ($fileName in $ExpectedHashes.Keys) {
        $path = Join-Path $DriverDir $fileName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Stop-DriverInstall "内嵌驱动释放不完整，缺少 $path" 21
        }

        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $expected = $ExpectedHashes[$fileName]
        if ($actual -ne $expected) {
            Stop-DriverInstall "内嵌驱动摘要不匹配: $fileName ($actual)" 22
        }
    }

    # SYS 自身带 Microsoft WHCP Authenticode 签名，同时还被同目录 CAT 收录。
    # Windows 的 pnputil 会再次验证 CAT；这里提前检查签名者，避免把深层自签版
    # 或错误二进制送进 Driver Store。
    $sysPath = Join-Path $DriverDir 'viogpudo.sys'
    $signature = Get-AuthenticodeSignature -LiteralPath $sysPath
    $subject = ''
    if ($null -ne $signature.SignerCertificate) {
        $subject = [string] $signature.SignerCertificate.Subject
    }
    if ($signature.Status -ne 'Valid' -or
        $subject -notmatch 'Microsoft Windows Hardware Compatibility Publisher') {
        Stop-DriverInstall `
            "viogpudo.sys 微软 WHCP 签名无效（Status=$($signature.Status), Subject=$subject）" 23
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

    Assert-ActiveStockDriver -States $before
    Clear-PendingDriverInstall
    Write-Host "  重启后所有 PCI 显示目标均已通过驱动验证。" `
        -ForegroundColor Green
    exit 0
}

# 只要任何在线目标声称已绑定 VioGpuDod，就必须先验证当前实际加载的 SYS 与
# 该目标发布 INF。这样 modified/selfsigned 同名服务在 healthy 快速路径之前
# 就会 fail closed；未绑定的 BasicDisplay 首装机仍可继续安装 stock 包。
$activeVioStates = @($before | Where-Object { $_.Service -ieq 'VioGpuDod' })
if ($activeVioStates.Count -gt 0) {
    Assert-ActiveStockDriver -States $activeVioStates
}

# 幂等快速路径要求“所有已经通过 1AF4:1050 物理门禁的在线 PCI Display”
# 均通过四项校验；因此克隆机可以无扰动跳过，深层自签旧机不会进入此分支。
$allAlreadyHealthy = Test-AllTargetStatesHealthy -States $before `
    -TargetInstanceIds $currentTargetIds -WriteProblems
if ($allAlreadyHealthy) {
    Write-Host "  所有 PCI 显示目标均已健康绑定 VioGpuDod：跳过 pnputil。" `
        -ForegroundColor Green
    exit 0
}

Assert-EmbeddedDriverPayload

$infPath = Join-Path $DriverDir 'viogpudo.inf'
Write-Host "  未绑定 VioGpuDod；正在从 EXE 内嵌包安装（不访问 HTTP）..." `
    -ForegroundColor Yellow
$pnputilOutput = @(& pnputil.exe /add-driver $infPath /install 2>&1)
$pnputilCode = $LASTEXITCODE
foreach ($line in $pnputilOutput) { Write-Host ("    " + $line) }

# 259 表示没有匹配设备或当前设备已有更优驱动，必须继续以设备状态
# 为准。3010 是独立的“已提交但待重启”状态，不与 0/普通成功合并。
if ($pnputilCode -ne 0 -and $pnputilCode -ne 259 -and $pnputilCode -ne 3010) {
    Stop-DriverInstall "pnputil 安装失败，退出码=$pnputilCode" 27
}

# 不 Disable/Enable 正在输出画面的显卡，避免黑屏或崩溃。PnP 扫描后用
# 有界短轮询取代固定 3 秒空等：驱动已即时绑定时可立即继续，慢机器
# 仍有最多约 3 秒的 PnP 收敛时间。
try { & pnputil.exe /scan-devices 2>$null | Out-Null } catch {}
$after = @()
$afterHealthy = $false
for ($attempt = 0; $attempt -lt 7; $attempt++) {
    $after = @(Get-PciDisplayState)
    $afterIds = @($after | ForEach-Object { [string] $_.InstanceId })
    if (Test-SameTargetSet -Expected $currentTargetIds -Actual $afterIds) {
        $afterHealthy = Test-AllTargetStatesHealthy -States $after `
            -TargetInstanceIds $currentTargetIds
        if ($afterHealthy) { break }
    }
    if ($attempt -lt 6) { Start-Sleep -Milliseconds 500 }
}
Write-DisplayState -States $after

if ($pnputilCode -eq 3010) {
    # 即使所有字段已在当前 boot 短暂显示正常，3010 仍明确表示 Windows
    # 还有需要重启完成的驱动交易。先清理模式缓存并记住本 boot/全目标，
    # 然后以 30 让外层安排重启续跑，绝不在本次运行中报成功。
    Clear-NewInstallDisplayModeCache
    $submittedBootMarker = Get-CurrentBootMarker
    Set-PendingDriverInstall -BootMarker $submittedBootMarker `
        -TargetInstanceIds $currentTargetIds -PnPUtilExitCode $pnputilCode
    Write-Host `
        "  PENDING: pnputil 退出 3010，已持久化全目标验证状态，必须重启续跑。" `
        -ForegroundColor Yellow
    exit $RestartRequiredExitCode
}

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

# 只有 pnputil 明确不要求重启时，才校验当前正在运行的 SYS/INF 并报告成功。
# 3010 可能在当前 boot 暂时显示健康但仍加载旧实例，必须先写 marker、重启，再由
# 上面的 pending 二阶段执行同一信任校验；不能在重启前误判成 modified driver。
Assert-ActiveStockDriver -States $after
Clear-NewInstallDisplayModeCache
Write-Host "  所有 PCI 显示目标已健康绑定 VioGpuDod；重启后将重新枚举显示模式。" `
    -ForegroundColor Green
exit 0

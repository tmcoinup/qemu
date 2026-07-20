# display-driver-trust.ps1 —— VioGpuDod 活动驱动与内嵌包信任校验。
#
# 本文件只定义函数，由 install-display-driver.ps1 从同一受保护 payload 目录加载。
# “发布 INF 不存在”是唯一可恢复的活动驱动异常；任何已有文件摘要错误、reparse
# 路径、服务/SYS 异常或签名者不符都继续 fail closed。

function Get-DevicePropertyText {
    param(
        [Parameter(Mandatory = $true)] [string] $InstanceId,
        [Parameter(Mandatory = $true)] [string] $KeyName
    )

    # BasicDisplay 和尚未完成安装的设备可能没有 Service/DriverInfPath；缺字段是
    # 正常的“尚未绑定”状态，因此这里只返回空串，不让属性查询中断整个探测。
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
    # FriendlyName、DeviceDesc 和 Manufacturer 属于 UI 投影，可显示 NVIDIA/AMD；
    # 底层签名关联只由 Win32_PnPSignedDriver 与可信 INF/SYS 证明。
    $devices = @(Get-PnpDevice -Class 'Display' -PresentOnly -ErrorAction Stop |
        Where-Object { $_.InstanceId -match '^PCI\\' })
    $signedDrivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver `
        -ErrorAction Stop)

    $states = @()
    foreach ($device in $devices) {
        $signedMatches = @($signedDrivers | Where-Object {
            [string] $_.DeviceID -ieq [string] $device.InstanceId
        })
        $signedDriver = if ($signedMatches.Count -eq 1) {
            $signedMatches[0]
        } else {
            $null
        }
        $states += [pscustomobject]@{
            InstanceId      = [string] $device.InstanceId
            Status          = [string] $device.Status
            Problem         = [string] $device.Problem
            Service         = Get-DevicePropertyText -InstanceId $device.InstanceId `
                -KeyName 'DEVPKEY_Device_Service'
            InfPath         = Get-DevicePropertyText -InstanceId $device.InstanceId `
                -KeyName 'DEVPKEY_Device_DriverInfPath'
            SignedMatchCount = $signedMatches.Count
            SignedInfPath   = $(if ($null -eq $signedDriver) {
                ''
            } else {
                [string] $signedDriver.InfName
            })
            SignedProvider  = $(if ($null -eq $signedDriver) {
                ''
            } else {
                [string] $signedDriver.DriverProviderName
            })
            IsSigned        = $(if ($null -eq $signedDriver) {
                $false
            } else {
                [bool] $signedDriver.IsSigned
            })
            Signer          = $(if ($null -eq $signedDriver) {
                ''
            } else {
                [string] $signedDriver.Signer
            })
        }
    }
    return @($states)
}

function Test-ShallowPhysicalDisplayId {
    # stock VioGpuDod 的硬件契约就是 1AF4:1050。该判定独立于 Service 和
    # FriendlyName，深层 10DE/1002 设备不得进入当前无自签浅层模式。
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
        Write-Host ("  包 Provider: " + $state.SignedProvider) -ForegroundColor Gray
        Write-Host ("  包 Signer : " + $state.Signer) -ForegroundColor Gray
        Write-Host ("  PnP state : " + $state.Status + " / " + $state.Problem) `
            -ForegroundColor Gray
    }
}

function Test-PnpProblemFree {
    param([AllowNull()] [string] $Problem)

    # 不同 Win10/PnpDevice 版本可能把“无问题”表示为空、0 或 CM_PROB_NONE。
    if ([string]::IsNullOrWhiteSpace($Problem)) { return $true }
    $normalized = $Problem.Trim()
    return ($normalized -eq '0' -or $normalized -ieq 'CM_PROB_NONE')
}

function Get-DisplayStateProblems {
    param([Parameter(Mandatory = $true)] [object] $State)

    $problems = @()
    if ($State.Service -ine 'VioGpuDod') { $problems += "Service=$($State.Service)" }
    if ($State.Status -ine 'OK') { $problems += "Status=$($State.Status)" }
    if (-not (Test-PnpProblemFree -Problem $State.Problem)) {
        $problems += "Problem=$($State.Problem)"
    }
    if ($State.InfPath -notmatch '(?i)^oem[0-9]+\.inf$') {
        $problems += "InfPath=$($State.InfPath)"
    }

    # UI DevProp 可按 profile 投影；真实包 Provider/Signer 必须继续来自 WHCP 包。
    if ([int] $State.SignedMatchCount -ne 1) {
        $problems += "SignedMatchCount=$($State.SignedMatchCount)"
    } else {
        if ($State.SignedInfPath -ine $State.InfPath) {
            $problems += "SignedInfPath=$($State.SignedInfPath)"
        }
        if ($State.SignedProvider -ine 'Red Hat, Inc.') {
            $problems += "SignedProvider=$($State.SignedProvider)"
        }
        if ($State.IsSigned -ne $true) { $problems += "IsSigned=$($State.IsSigned)" }
        if ($State.Signer -ine 'Microsoft Windows Hardware Compatibility Publisher') {
            $problems += "Signer=$($State.Signer)"
        }
    }
    return @($problems)
}

function Test-AllTargetStatesHealthy {
    param(
        [Parameter(Mandatory = $true)] [object[]] $States,
        [Parameter(Mandatory = $true)] [string[]] $TargetInstanceIds,
        [switch] $WriteProblems
    )

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

function Assert-SafeLocalPath {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $TrustedRoot,
        [Parameter(Mandatory = $true)] [string] $Label,
        [Parameter(Mandatory = $true)]
        [ValidateSet('File', 'Directory')]
        [string] $ExpectedKind
    )

    # 从卷根逐级检查属性，而不是先 Resolve-Path 再看最终对象。这样目录联接、
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
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label 的卷根是 reparse point: $volumeRoot"
    }
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
    if ([IO.Path]::GetFullPath([string] $item.FullName) -ine $full) {
        throw "$Label 解析结果不唯一: $full"
    }
    if ($ExpectedKind -eq 'File' -and $item.PSIsContainer) {
        throw "$Label 不是普通文件: $full"
    }
    if ($ExpectedKind -eq 'Directory' -and -not $item.PSIsContainer) {
        throw "$Label 不是目录: $full"
    }
    return $full
}

function Assert-SafePlainFile {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $TrustedRoot,
        [Parameter(Mandatory = $true)] [string] $Label
    )

    return Assert-SafeLocalPath -Path $Path -TrustedRoot $TrustedRoot `
        -Label $Label -ExpectedKind 'File'
}

function Assert-SafeDirectory {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $TrustedRoot,
        [Parameter(Mandatory = $true)] [string] $Label
    )

    return Assert-SafeLocalPath -Path $Path -TrustedRoot $TrustedRoot `
        -Label $Label -ExpectedKind 'Directory'
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

function Get-PublishedInfTrustState {
    param(
        [Parameter(Mandatory = $true)] [string] $InfName,
        [Parameter(Mandatory = $true)] [string] $InfRoot,
        [switch] $AllowMissing
    )

    if ($InfName -notmatch '(?i)^oem[0-9]+\.inf$') {
        throw "活动显示设备 INF 发布名非法: $InfName"
    }
    $safeInfRoot = Assert-SafeDirectory -Path $InfRoot -TrustedRoot $InfRoot `
        -Label 'Windows INF 目录'
    $publishedPath = Join-Path $safeInfRoot $InfName
    try {
        [void] (Get-Item -LiteralPath $publishedPath -Force -ErrorAction Stop)
    } catch [System.Management.Automation.ItemNotFoundException] {
        # 只有父目录可信、且目录枚举也确认没有同名对象时，才把异常归类为
        # “普通缺失”。访问被拒绝、目录冒充和悬空 reparse point 都不能进入恢复路径。
        $sameNameEntries = @(Get-ChildItem -LiteralPath $safeInfRoot -Force `
            -ErrorAction Stop | Where-Object { $_.Name -ieq $InfName })
        if ($sameNameEntries.Count -ne 0) {
            throw "活动 INF $InfName 无法按普通文件解析"
        }
        if (-not $AllowMissing) { throw "活动 INF $InfName 缺失" }
        return [pscustomobject]@{
            InfName = $InfName
            Path    = $publishedPath
            Status  = 'Missing'
        }
    }

    $publishedInf = Assert-SafePlainFile -Path $publishedPath `
        -TrustedRoot $safeInfRoot -Label "活动 INF $InfName"
    Assert-ExactFileHash -Path $publishedInf -Expected $ExpectedHashes['viogpudo.inf'] `
        -Label "活动 INF $InfName"
    return [pscustomobject]@{
        InfName = $InfName
        Path    = $publishedInf
        Status  = 'Trusted'
    }
}

function Assert-ActiveStockDriver {
    param(
        [Parameter(Mandatory = $true)] [object[]] $States,
        [string] $SystemDirectory = [Environment]::SystemDirectory,
        [switch] $AllowMissingPublishedInf
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

        # 每个 PnP 目标的 DriverInfPath 都必须关联回锁定发布 INF。恢复模式只把
        # “发布名合法但普通文件不存在”返回给调用方；已有错文件仍在这里拒绝。
        $windowsFull = [IO.Directory]::GetParent($systemFull).FullName
        $infRoot = Join-Path $windowsFull 'INF'
        $missingInfNames = @()
        foreach ($infName in @($States.InfPath | Select-Object -Unique)) {
            $trustState = Get-PublishedInfTrustState -InfName ([string] $infName) `
                -InfRoot $infRoot -AllowMissing:$AllowMissingPublishedInf
            if ($trustState.Status -eq 'Missing') {
                $missingInfNames += [string] $trustState.InfName
            }
        }
        return [pscustomobject]@{
            MissingPublishedInfNames = [string[]] $missingInfNames
        }
    } catch {
        Stop-DriverInstall ("活动 VioGpuDod 信任校验失败（刻意 fail closed；" +
            "只有普通缺失的 oemN.inf 可由官方 pnputil 恢复）: " +
            $_.Exception.Message) 34
    }
}

function Assert-EmbeddedDriverPayload {
    foreach ($fileName in $ExpectedHashes.Keys) {
        $path = Join-Path $DriverDir $fileName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Stop-DriverInstall "内嵌驱动释放不完整，缺少 $path" 21
        }
        try {
            $safePath = Assert-SafePlainFile -Path $path -TrustedRoot $DriverDir `
                -Label "内嵌驱动 $fileName"
            Assert-ExactFileHash -Path $safePath -Expected $ExpectedHashes[$fileName] `
                -Label "内嵌驱动 $fileName"
        } catch {
            Stop-DriverInstall ("内嵌驱动校验失败: $fileName (" +
                $_.Exception.Message + ")") 22
        }
    }

    # 固定三件套摘要保证 CAT/INF/SYS 来自同一已审计包；SYS 再校验 Windows
    # 信任状态、WHCP 主体/颁发者和证书指纹，随后 pnputil 会正式验证 CAT。
    try {
        Assert-WhcpSignature -Path (Join-Path $DriverDir 'viogpudo.sys')
    } catch {
        Stop-DriverInstall ("viogpudo.sys 微软 WHCP 签名无效: " +
            $_.Exception.Message) 23
    }
}

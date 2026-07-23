param(
    [switch]$ReadIdentityOnly,
    [switch]$AllowMissing,
    [ValidatePattern('^[0-9A-F]{32}$')]
    [string]$StagedIdentityId
)
$ErrorActionPreference = 'Stop'
$stockDriverDescription = 'Red Hat VirtIO GPU DOD controller'
$stockDriverProvider = 'Red Hat, Inc.'
$gpuBoardIdentityContractPath = Join-Path $PSScriptRoot `
    'gpu-board-identity-contract.ps1'
if (-not (Test-Path -LiteralPath $gpuBoardIdentityContractPath -PathType Leaf)) {
    throw ('缺少 refresh GPU board identity contract：' +
        $gpuBoardIdentityContractPath)
}
. $gpuBoardIdentityContractPath

function Get-ExactRegistryValue {
    # RegistryKey.GetValue 会把缺失值和空值都变成 null，也可能透明展开字符串。
    # 身份协议必须精确验证名称、类型和非空内容，因此先查 kind，再以禁止展开方式读。
    param(
        [Parameter(Mandatory = $true)]$Key,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Microsoft.Win32.RegistryValueKind]$Kind
    )
    if (-not (@($Key.GetValueNames()) -ccontains $Name)) {
        throw ('身份快照缺少注册表值：' + $Name)
    }
    if ($Key.GetValueKind($Name) -ne $Kind) {
        throw ('身份快照注册表类型错误：' + $Name)
    }
    $value = $Key.GetValue($Name, $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($Kind -eq [Microsoft.Win32.RegistryValueKind]::String) {
        $text = [string]$value
        if ([string]::IsNullOrWhiteSpace($text) -or $text.IndexOf([char]0) -ge 0) {
            throw ('身份快照字符串为空或含 NUL：' + $Name)
        }
        return $text
    }
    # DWord 由 RegistryKey 本身返回 Int32；Binary/QWord 必须保留 byte[]/Int64，
    # 否则 4 GiB 显存 QWord 会溢出且 Binary 无法转换成 Int32。
    return $value
}

function Get-CurrentGpuIdentity {
    # 与 NVAPI DLL 使用同一线性化读取：pointer -> 不可变 GUID 子键 -> 重读
    # pointer/schema。旧 root-only profile 只在 apply 的首次升级探测中可视为“没有
    # previous identity”；任何已存在但损坏/变化的 pointer 都必须抛错而非回落默认值。
    param([switch]$MissingIsAllowed, [string]$StagedId, $BaseKeyOverride)
    $baseKey = if ($null -ne $BaseKeyOverride) { $BaseKeyOverride } else {
        [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64)
    }
    $rootKey = $null
    $versionKey = $null
    $transactionKey = $null
    try {
        $stringKind = [Microsoft.Win32.RegistryValueKind]::String
        $dwordKind = [Microsoft.Win32.RegistryValueKind]::DWord
        $rootKey = $baseKey.OpenSubKey('SOFTWARE\StealthGPU', $false)
        if ($null -eq $rootKey) {
            if ($MissingIsAllowed) { return $null }
            throw '缺少 StealthGPU 身份根键'
        }
        if (-not [string]::IsNullOrWhiteSpace($StagedId)) {
            if ($StagedId -cnotmatch '^[0-9A-F]{32}$') {
                throw ('暂存身份 ID 非法：' + $StagedId)
            }
            $initialPointer = Get-ExactRegistryValue -Key $rootKey `
                -Name 'PendingIdentity' -Kind $stringKind
            if ($initialPointer -cne $StagedId) {
                throw 'StagedIdentityId 与 PendingIdentity 不一致'
            }
            $transactionKey = $rootKey.OpenSubKey(('Transactions\' + $StagedId), $false)
            if ($null -eq $transactionKey) { throw ('暂存事务不存在：' + $StagedId) }
            $transactionSchema = Get-ExactRegistryValue -Key $transactionKey `
                -Name 'TransactionSchemaVersion' -Kind $dwordKind
            # schema-1 只保留给 transaction helper 的 Recover/Rollback 兼容路径。
            # Commit 严禁按旧投影契约首写 Enum/Class，否则会再次破坏签名关联。
            if ($transactionSchema -ne 2) {
                throw ('暂存提交只接受 transaction schema-2：' + $transactionSchema)
            }
            $transactionState = Get-ExactRegistryValue -Key $transactionKey `
                -Name 'State' -Kind $stringKind
            $stagedClassSubkey = Get-ExactRegistryValue -Key $transactionKey `
                -Name 'ClassSubkey' -Kind $stringKind
            $stagedDriverInfPath = Get-ExactRegistryValue -Key $transactionKey `
                -Name 'DriverInfPath' -Kind $stringKind
            if ($transactionState -cne 'Prepared' -or
                $stagedClassSubkey -cnotmatch '^\d{4}$' -or
                $stagedDriverInfPath -cnotmatch '^oem[0-9]+\.inf$') {
                throw ('暂存事务不是完整 Prepared 状态：' + $transactionSchema + '/' +
                    $transactionState)
            }
        } elseif (-not (@($rootKey.GetValueNames()) -ccontains 'CurrentIdentity')) {
            if (-not $MissingIsAllowed) {
                throw '缺少 CurrentIdentity；旧 root-only profile 不作为 refresh 身份'
            }
            # 仅 apply 在升级旧 EXE 状态时使用此分支，而且只取“上一名称”作为
            # Class target needle，不读取 Vendor/BIOS/RAM/显存及时钟字段。旧协议以 root schema
            # last 提交；名称/schema 双读及 pointer 再确认可拒绝恰逢新协议提交的竞态。
            if (-not (@($rootKey.GetValueNames()) -ccontains 'SpoofName') -or
                -not (@($rootKey.GetValueNames()) -ccontains 'IdentitySchemaVersion')) {
                return $null
            }
            $legacySchemaBefore = Get-ExactRegistryValue -Key $rootKey `
                -Name 'IdentitySchemaVersion' -Kind $dwordKind
            $legacyNameBefore = Get-ExactRegistryValue -Key $rootKey `
                -Name 'SpoofName' -Kind $stringKind
            $legacyNameAfter = Get-ExactRegistryValue -Key $rootKey `
                -Name 'SpoofName' -Kind $stringKind
            $legacySchemaAfter = Get-ExactRegistryValue -Key $rootKey `
                -Name 'IdentitySchemaVersion' -Kind $dwordKind
            if (@($rootKey.GetValueNames()) -ccontains 'CurrentIdentity' -or
                $legacySchemaBefore -ne 1 -or $legacySchemaAfter -ne 1 -or
                $legacyNameBefore -cne $legacyNameAfter) {
                throw '旧 root-only 身份读取期间发生变化，拒绝用作迁移名称'
            }
            return [pscustomobject]@{
                SpoofName = $legacyNameBefore
                IsLegacyMigrationHint = $true
            }
        }
        else {
            $initialPointer = Get-ExactRegistryValue -Key $rootKey `
                -Name 'CurrentIdentity' -Kind $stringKind
        }
        if ($initialPointer -cnotmatch '^[0-9A-F]{32}$') {
            throw ('CurrentIdentity 不是 32 位大写十六进制 GUID-N：' + $initialPointer)
        }
        # pointer 已经过严格白名单；只允许拼接固定 Identities\ 前缀，拒绝任意路径。
        $versionPath = 'Identities\' + $initialPointer
        $versionKey = $rootKey.OpenSubKey($versionPath, $false)
        if ($null -eq $versionKey) { throw ('身份版本子键不存在：' + $versionPath) }
        $schemaBefore = Get-ExactRegistryValue -Key $versionKey `
            -Name 'IdentitySchemaVersion' -Kind $dwordKind
        if ($schemaBefore -eq 1) {
            throw 'schema-1 versioned GPU 身份已停止兼容；请用当前硬件池重建实例'
        }
        if ($schemaBefore -ne 2) { throw ('不支持的身份 schema：' + $schemaBefore) }
        $snapshot = [ordered]@{
            IdentityId = Get-ExactRegistryValue -Key $versionKey -Name 'IdentityId' -Kind $stringKind
            SpoofName = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofName' -Kind $stringKind
            SpoofVendor = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofVendor' -Kind $stringKind
            SpoofBios = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofBios' -Kind $stringKind
            SpoofPciVendorId = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofPciVendorId' -Kind $dwordKind
            SpoofPciDeviceId = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofPciDeviceId' -Kind $dwordKind
            SpoofSubsystemVendorId = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofSubsystemVendorId' -Kind $dwordKind
            SpoofSubsystemDeviceId = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofSubsystemDeviceId' -Kind $dwordKind
            SpoofRevisionId = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofRevisionId' -Kind $dwordKind
            SpoofPciBusId = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofPciBusId' -Kind $dwordKind
            SpoofPciSlotId = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofPciSlotId' -Kind $dwordKind
            SpoofPciFunctionId = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofPciFunctionId' -Kind $dwordKind
            SpoofRamMb = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofRamMb' -Kind $dwordKind
            SpoofMemoryType = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofMemoryType' -Kind $stringKind
            SpoofMemoryBusWidthBits = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofMemoryBusWidthBits' -Kind $dwordKind
            SpoofBaseClockKHz = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofBaseClockKHz' -Kind $dwordKind
            SpoofBoostClockKHz = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofBoostClockKHz' -Kind $dwordKind
            SpoofMemoryClockKHz = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofMemoryClockKHz' -Kind $dwordKind
            SpoofSliSupported = Get-ExactRegistryValue -Key $versionKey -Name 'SpoofSliSupported' -Kind $dwordKind
            SourceInstanceId = Get-ExactRegistryValue -Key $versionKey -Name 'SourceInstanceId' -Kind $stringKind
            IdentityMode = Get-ExactRegistryValue -Key $versionKey -Name 'IdentityMode' -Kind $stringKind
        }
        if (-not [string]::IsNullOrWhiteSpace($StagedId)) {
            $snapshot['StagedClassSubkey'] = $stagedClassSubkey
            $snapshot['StagedDriverInfPath'] = $stagedDriverInfPath
        }
        $finalPointerName = if ([string]::IsNullOrWhiteSpace($StagedId)) {
            'CurrentIdentity'
        } else { 'PendingIdentity' }
        $finalPointer = Get-ExactRegistryValue -Key $rootKey `
            -Name $finalPointerName -Kind $stringKind
        $schemaAfter = Get-ExactRegistryValue -Key $versionKey `
            -Name 'IdentitySchemaVersion' -Kind $dwordKind
        if ($finalPointer -cne $initialPointer -or $schemaAfter -ne $schemaBefore) {
            throw '读取期间 CurrentIdentity 或 schema 已变化，拒绝混合身份'
        }
        $expectedVendorId = switch -CaseSensitive ($snapshot.SpoofVendor) {
            'NVIDIA' { 0x10DE; break }
            'AMD' { 0x1002; break }
            default { throw ('不支持的身份厂商：' + $snapshot.SpoofVendor) }
        }
        Assert-GpuIdentityStrings -Name $snapshot.SpoofName `
            -Vendor $snapshot.SpoofVendor -Bios $snapshot.SpoofBios
        $sourceIdentity = [regex]::Match($snapshot.SourceInstanceId,
            '^PCI\\VEN_1AF4&DEV_1050&SUBSYS_([0-9A-F]{4})([0-9A-F]{4})&REV_([0-9A-F]{2})(?:&|\\)')
        if ($snapshot.IdentityId -cne $initialPointer -or
            $snapshot.IdentityMode -cne 'shallow-user-projection' -or
            -not $sourceIdentity.Success -or
            $snapshot.SpoofPciVendorId -ne $expectedVendorId -or
            $snapshot.SpoofPciDeviceId -lt 1 -or $snapshot.SpoofPciDeviceId -gt 0xFFFF -or
            -not (Test-GpuLogicalBinding $snapshot $sourceIdentity) -or
            $snapshot.SpoofRevisionId -lt 0 -or $snapshot.SpoofRevisionId -gt 0xFF -or
            $snapshot.SpoofPciBusId -lt 0 -or $snapshot.SpoofPciBusId -gt 0xFF -or
            $snapshot.SpoofPciSlotId -lt 0 -or $snapshot.SpoofPciSlotId -gt 0x1F -or
            $snapshot.SpoofPciFunctionId -lt 0 -or $snapshot.SpoofPciFunctionId -gt 7 -or
            $snapshot.SpoofRamMb -lt 1 -or $snapshot.SpoofRamMb -gt 1048576 -or
            $snapshot.SpoofMemoryType -cne 'GDDR5' -or
            $snapshot.SpoofMemoryBusWidthBits -lt 32 -or
            $snapshot.SpoofMemoryBusWidthBits -gt 1024 -or
            ($snapshot.SpoofMemoryBusWidthBits -band
                ($snapshot.SpoofMemoryBusWidthBits - 1)) -ne 0 -or
            $snapshot.SpoofBaseClockKHz -lt 100000 -or $snapshot.SpoofBaseClockKHz -gt 5000000 -or
            $snapshot.SpoofBoostClockKHz -lt $snapshot.SpoofBaseClockKHz -or
            $snapshot.SpoofBoostClockKHz -gt 5000000 -or
            $snapshot.SpoofMemoryClockKHz -lt 100000 -or $snapshot.SpoofMemoryClockKHz -gt 10000000 -or
            $snapshot.SpoofSliSupported -ne 0) {
            throw '身份版本字段不满足浅层 PCI 一致性约束'
        }
        return [pscustomobject]$snapshot
    } finally {
        if ($null -ne $transactionKey) { $transactionKey.Dispose() }
        if ($null -ne $versionKey) { $versionKey.Dispose() }
        if ($null -ne $rootKey) { $rootKey.Dispose() }
        $baseKey.Dispose()
    }
}
function Get-StockDriverMatchingDeviceId {
    # MatchingDeviceId 是 Windows 写入的驱动安装状态，不是品牌展示字段。它必须
    # 保持为 stock viogpudo.inf 实际用于安装设备的模型 ID；写成 NVIDIA/AMD
    # 的逻辑 ID 会让 SetupAPI 无法把活动节点关联回 Microsoft 签名的 INF/CAT，
    # 设备管理器随即把 Digital Signer 显示为“未经数字签名”。
    param([Parameter(Mandatory = $true)][string]$SourceInstanceId)
    if ($SourceInstanceId -cnotmatch
            '^PCI\\VEN_1AF4&DEV_1050&SUBSYS_[0-9A-F]{8}&REV_[0-9A-F]{2}(?:&|\\)') {
        throw ('无法从非 stock VioGpuDod 设备恢复 MatchingDeviceId：' +
            $SourceInstanceId)
    }
    return 'PCI\VEN_1AF4&DEV_1050'
}
function Assert-GpuIdentityStrings {
    # 与 schema writer 和 NVAPI C reader 使用同一字节契约，防止损坏注册表被
    # PowerShell 接受、GPU-Z/NVAPI 却拒绝整份身份。
    param([string]$Name, [string]$Vendor, [string]$Bios)
    if (-not (@('NVIDIA', 'AMD') -ccontains $Vendor) -or
        $Name -cnotmatch '\A[\x20-\x7E]{1,63}\z' -or
        -not $Name.StartsWith(($Vendor + ' '), [System.StringComparison]::Ordinal) -or
        $Name -match '(?i)\b(?:Red Hat|VirtIO)\b') {
        throw 'GPU 名称或 canonical 厂商不满足 schema-2 字符串约束'
    }
    if ($Vendor -ceq 'NVIDIA') {
        if ($Bios -cnotmatch '\AVersion [0-9A-F]{2}(?:\.[0-9A-F]{2}){4}\z') {
            throw 'NVIDIA VBIOS 不满足 Version XX.XX.XX.XX.YY 约束'
        }
    } elseif ($Bios -cnotmatch '\A[0-9]{3}(?:\.[0-9]{3}){3}\.[0-9]{6}\z') {
        throw 'AMD VBIOS 不满足 DDD.DDD.DDD.DDD.DDDDDD 约束'
    }
}
function Set-VerifiedRegistryValue {
    # 关键 Enum/Class 值必须使用 64 位 RegistryKey 直接写入，并立即回读名称、
    # 类型和内容。任何 non-terminating provider error 都不能再伪装成 refresh 成功。
    param($Key, [string]$Name, $Value,
        [Microsoft.Win32.RegistryValueKind]$Kind)
    $Key.SetValue($Name, $Value, $Kind)
    $actual = Get-ExactRegistryValue -Key $Key -Name $Name -Kind $Kind
    $expectedValues = @($Value); $actualValues = @($actual)
    if ($expectedValues.Count -ne $actualValues.Count) {
        throw ('关键注册表值回读长度不一致：' + $Name)
    }
    for ($i = 0; $i -lt $expectedValues.Count; $i++) {
        if ($Kind -eq [Microsoft.Win32.RegistryValueKind]::String) {
            if ([string]$actualValues[$i] -cne [string]$expectedValues[$i]) {
                throw ('关键注册表字符串回读不一致：' + $Name)
            }
        } elseif ($actualValues[$i] -ne $expectedValues[$i]) {
            throw ('关键注册表值回读不一致：' + $Name)
        }
    }
}
function Invoke-WithProjectionLock {
    # 与 Stage/Commit/Rollback 共用同一全局锁；计划任务因此不能在 journal
    # 恢复一半时按另一 pointer 插入写入。
    param([scriptblock]$Body)
    $mutex = New-Object System.Threading.Mutex($false, 'Global\StealthGPU-IdentityWriter')
    $held = $false
    try {
        try { $held = $mutex.WaitOne(30000) }
        catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw '等待 StealthGPU 投影锁超时（30 秒）' }
        & $Body
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
function Set-ActiveGpuProjection {
    param($Config)
    $present = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
        Where-Object {
            [System.StringComparer]::OrdinalIgnoreCase.Equals(
                [string]$_.InstanceId, [string]$Config.SourceInstanceId)
        })
    if ($present.Count -ne 1) {
        throw ('SourceInstanceId 对应的在线 Display 数量不是 1：' + $present.Count)
    }
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    $enumKey = $null; $classKey = $null
    try {
            $enumPath = 'SYSTEM\CurrentControlSet\Enum\' + $Config.SourceInstanceId
            $enumKey = $baseKey.OpenSubKey($enumPath, $true)
            if ($null -eq $enumKey) { throw ('active Enum 节点不可写：' + $enumPath) }
            $string = [Microsoft.Win32.RegistryValueKind]::String
            $service = [string](Get-ExactRegistryValue $enumKey 'Service' $string)
            $driver = [string](Get-ExactRegistryValue $enumKey 'Driver' $string)
            $driverMatch = [regex]::Match($driver,
                '^\{4d36e968-e325-11ce-bfc1-08002be10318\}\\([0-9]{4})$',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($service -ine 'VioGpuDod' -or -not $driverMatch.Success) {
                throw ('active Enum 未绑定 stock VioGpuDod Display Class：' + $service + '/' + $driver)
            }
            if ($null -ne $Config.PSObject.Properties['StagedClassSubkey'] -and
                $driverMatch.Groups[1].Value -cne $Config.StagedClassSubkey) {
                throw 'Prepared transaction 的 journal Class 与 active Driver 已发生变化'
            }
            $classPath = 'SYSTEM\CurrentControlSet\Control\Class\' +
                '{4d36e968-e325-11ce-bfc1-08002be10318}\' + $driverMatch.Groups[1].Value
            $classKey = $baseKey.OpenSubKey($classPath, $true)
            if ($null -eq $classKey) { throw ('active Class 子键不可写：' + $classPath) }
            $infPath = [string](Get-ExactRegistryValue $classKey 'InfPath' $string)
            $infSection = [string](Get-ExactRegistryValue $classKey 'InfSection' $string)
            if ($infPath -cnotmatch '^oem[0-9]+\.inf$' -or
                $infSection -cne 'VioGpuDod_Inst') {
                throw ('active Class 不是受支持的 VioGpuDod INF：' +
                    $infPath + '/' + $infSection)
            }
            if ($null -ne $Config.PSObject.Properties['StagedDriverInfPath'] -and
                $infPath -cne $Config.StagedDriverInfPath) {
                throw 'Prepared transaction 的 INF 与 active Class 已发生变化'
            }
            $stockEnumDescription = '@' + $infPath +
                ',%viogpudod.devicedesc%;' + $stockDriverDescription
            $stockEnumProvider = '@' + $infPath +
                ',%vendor%;' + $stockDriverProvider
            $chipType = $Config.SpoofName -replace '^(NVIDIA|AMD)\s+', ''
            $memoryBytes = [BitConverter]::GetBytes([UInt64]$Config.SpoofRamMb * 1MB)
            $legacyMemory = [byte[]]$memoryBytes[0..3]
            $driverMatchingId = Get-StockDriverMatchingDeviceId `
                $Config.SourceInstanceId
            Set-VerifiedRegistryValue $enumKey 'FriendlyName' $Config.SpoofName $string
            # DeviceDesc/Mfg 与 Class DriverDesc/ProviderName 是 SetupAPI 用来
            # 回找当前 INF driver node 的安装状态。品牌仅投影到 FriendlyName
            # 和 HardwareInformation；否则有效的 WHQL 包会在设备管理器里误报未签名。
            Set-VerifiedRegistryValue $enumKey 'DeviceDesc' $stockEnumDescription $string
            Set-VerifiedRegistryValue $enumKey 'Mfg' $stockEnumProvider $string
            Set-VerifiedRegistryValue $classKey 'DriverDesc' $stockDriverDescription $string
            Set-VerifiedRegistryValue $classKey 'ProviderName' $stockDriverProvider $string
            Set-VerifiedRegistryValue $classKey 'MatchingDeviceId' `
                $driverMatchingId $string
            Set-VerifiedRegistryValue $classKey 'HardwareInformation.AdapterString' $Config.SpoofName $string
            Set-VerifiedRegistryValue $classKey 'HardwareInformation.ChipType' $chipType $string
            Set-VerifiedRegistryValue $classKey 'HardwareInformation.DacType' 'Integrated RAMDAC' $string
            Set-VerifiedRegistryValue $classKey 'HardwareInformation.BiosString' $Config.SpoofBios $string
            Set-VerifiedRegistryValue $classKey 'HardwareInformation.MemorySize' $legacyMemory `
                ([Microsoft.Win32.RegistryValueKind]::Binary)
            Set-VerifiedRegistryValue $classKey 'HardwareInformation.qwMemorySize' `
                ([UInt64]$Config.SpoofRamMb * 1MB) ([Microsoft.Win32.RegistryValueKind]::QWord)
            $enumKey.Flush(); $classKey.Flush()
    } finally {
        if ($null -ne $classKey) { $classKey.Dispose() }
        if ($null -ne $enumKey) { $enumKey.Dispose() }
        $baseKey.Dispose()
    }
}
if ($AllowMissing -and -not $ReadIdentityOnly) {
    throw '-AllowMissing 只能与 -ReadIdentityOnly 一起使用'
}
if ($AllowMissing -and -not [string]::IsNullOrWhiteSpace($StagedIdentityId)) {
    throw '-AllowMissing 不能与 -StagedIdentityId 一起使用'
}
if ($ReadIdentityOnly) {
    return Get-CurrentGpuIdentity -MissingIsAllowed:$AllowMissing -StagedId $StagedIdentityId
}
$cfg = Invoke-WithProjectionLock {
    $lockedConfig = Get-CurrentGpuIdentity -StagedId $StagedIdentityId
    Set-ActiveGpuProjection -Config $lockedConfig
    return $lockedConfig
}
if (-not [string]::IsNullOrWhiteSpace($StagedIdentityId)) { return }
& (Join-Path $PSScriptRoot 'gpu-manufacturer-projection.ps1') -Vendor $cfg.SpoofVendor -InstanceId $cfg.SourceInstanceId
# 显示器身份只能来自 Host profile 注入的 QEMU EDID。这里不得再改写
# Enum\DISPLAY、Monitor Class、HardwareID 或厂商名称，否则启动/登录任务会把
# AOC、Xiaomi、Lenovo 等已选组件重新污染成某个固定品牌。

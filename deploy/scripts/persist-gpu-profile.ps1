[CmdletBinding(DefaultParameterSetName = 'Stage')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Stage')]
    [string]$SpoofName,
    [Parameter(Mandatory = $true, ParameterSetName = 'Stage')]
    [string]$SpoofVendor,
    [Parameter(Mandatory = $true, ParameterSetName = 'Stage')]
    [string]$SpoofBios,
    [Parameter(Mandatory = $true, ParameterSetName = 'Stage')]
    [ValidateRange(1, 1048576)]
    [int]$SpoofRamMb,
    [Parameter(Mandatory = $true, ParameterSetName = 'Stage')]
    [ValidateSet('GDDR5')]
    [string]$SpoofMemoryType,
    [Parameter(Mandatory = $true, ParameterSetName = 'Stage')]
    [ValidateRange(32, 1024)]
    [ValidateScript({ ($_ -band ($_ - 1)) -eq 0 })]
    [int]$SpoofMemoryBusWidthBits,
    [Parameter(Mandatory = $true, ParameterSetName = 'Stage')]
    [ValidateRange(100000, 5000000)]
    [int]$SpoofBaseClockKHz,
    [Parameter(Mandatory = $true, ParameterSetName = 'Stage')]
    [ValidateRange(100000, 5000000)]
    [int]$SpoofBoostClockKHz,
    [Parameter(Mandatory = $true, ParameterSetName = 'Stage')]
    [ValidateRange(100000, 10000000)]
    [int]$SpoofMemoryClockKHz,
    [Parameter(Mandatory = $true, ParameterSetName = 'Stage')]
    [ValidateSet(0)]
    [int]$SpoofSliSupported,
    [Parameter(Mandatory = $true, ParameterSetName = 'Stage')]
    [switch]$Stage,
    [Parameter(Mandatory = $true, ParameterSetName = 'Commit')]
    [string]$CommitIdentity,
    [Parameter(Mandatory = $true, ParameterSetName = 'Rollback')]
    [string]$RollbackIdentity,
    [Parameter(Mandatory = $true, ParameterSetName = 'Inspect')]
    [string]$InspectIdentity,
    [Parameter(Mandatory = $true, ParameterSetName = 'Complete')]
    [string]$CompleteIdentity,
    [Parameter(Mandatory = $true, ParameterSetName = 'Recover')]
    [switch]$RecoverPending
)

$ErrorActionPreference = 'Stop'

# 本 helper 只负责把“浅层用户态身份”写入统一配置，不修改 PCI 配置空间、驱动
# 二进制或签名链。硬件层继续保留 stock VioGpuDod 要求的 1AF4:1050；NVAPI
# shim 从这里读取逻辑 10DE:1C82 等身份，避免 GPU 名称、PCI ID 与显存各自硬编码。

function Get-HexWord {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    if ($Text -notmatch '^[0-9A-Fa-f]{4}$') {
        throw ("非法的 " + $FieldName + "：" + $Text)
    }
    return [Convert]::ToInt32($Text, 16)
}

function Get-HexByte {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    if ($Text -notmatch '^[0-9A-Fa-f]{2}$') {
        throw ("非法的 " + $FieldName + "：" + $Text)
    }
    return [Convert]::ToInt32($Text, 16)
}

function Get-ShallowPciIdentity {
    # 将 PnP InstanceId 转成 NVAPI 要使用的逻辑身份。函数不访问注册表和设备，
    # 因而可在 Linux 上用 PowerShell AST 单独提取并覆盖成功/拒绝路径。
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$Vendor
    )

    $normalized = $InstanceId.ToUpperInvariant()
    $identityMatch = [regex]::Match($normalized,
        '^PCI\\VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})&SUBSYS_([0-9A-F]{4})([0-9A-F]{4})&REV_([0-9A-F]{2})(?:&|\\)')
    if (-not $identityMatch.Success) {
        throw ("显示设备 InstanceId 缺少完整 VEN/DEV/SUBSYS/REV：" + $normalized)
    }

    $physicalVendorId = Get-HexWord -Text $identityMatch.Groups[1].Value -FieldName '物理 Vendor ID'
    $physicalDeviceId = Get-HexWord -Text $identityMatch.Groups[2].Value -FieldName '物理 Device ID'
    $subsystemDeviceId = Get-HexWord -Text $identityMatch.Groups[3].Value -FieldName 'Subsystem Device ID'
    $subsystemVendorId = Get-HexWord -Text $identityMatch.Groups[4].Value -FieldName 'Subsystem Vendor ID'
    $revisionId = Get-HexByte -Text $identityMatch.Groups[5].Value -FieldName 'Revision ID'

    # 旧版浅层方案的关键约束：stock 驱动看到的物理 ID 必须仍为 virtio-gpu；
    # 用户态逻辑主 ID则使用 profile 的 subsystem VEN/DEV。若这里接受其他物理 ID，
    # 就可能把已经进入 Code 43 的深层设备误标为“配置成功”。
    if ($physicalVendorId -ne 0x1AF4 -or $physicalDeviceId -ne 0x1050) {
        throw ('浅层模式要求物理 PCI ID 为 1AF4:1050，实际为 {0:X4}:{1:X4}' -f
            $physicalVendorId, $physicalDeviceId)
    }

    $expectedVendorId = switch -CaseSensitive ($Vendor) {
        'NVIDIA' { 0x10DE; break }
        'AMD' { 0x1002; break }
        default { throw ("不支持的 GPU 厂商：" + $Vendor) }
    }
    if ($subsystemDeviceId -eq 0) {
        throw '逻辑/SUBSYS Device ID 不能为 0000'
    }
    if ($subsystemVendorId -ne $expectedVendorId) {
        throw ('profile 厂商与 PCI SUBSYS 不一致：期望 {0:X4}，实际 {1:X4}' -f
            $expectedVendorId, $subsystemVendorId)
    }

    return [pscustomobject]@{
        InstanceId = $normalized
        PciVendorId = $subsystemVendorId
        PciDeviceId = $subsystemDeviceId
        SubsystemVendorId = $subsystemVendorId
        SubsystemDeviceId = $subsystemDeviceId
        RevisionId = $revisionId
    }
}

function Get-PciLocation {
    # Windows 的 DEVPKEY_Device_Address 对 PCI 设备使用“高 16 位设备号、低
    # 16 位功能号”。这里转换为 NVAPI 的 BusId/BusSlotId；FunctionId 只留作
    # 诊断，避免把 PnP InstanceId 尾部的非标准编码误当成真实 BDF。
    param(
        [Parameter(Mandatory = $true)][long]$BusNumber,
        [Parameter(Mandatory = $true)][long]$Address
    )

    if ($BusNumber -lt 0 -or $BusNumber -gt 0xFF -or
        $Address -lt 0 -or $Address -gt 0x001F0007) {
        throw ('PCI bus/address 越界：bus={0}, address=0x{1:X8}' -f
            $BusNumber, $Address)
    }

    $slot = ($Address -shr 16) -band 0xFFFF
    $function = $Address -band 0xFFFF
    if ($slot -gt 0x1F -or $function -gt 7) {
        throw ('PCI device/function 越界：device={0}, function={1}' -f
            $slot, $function)
    }

    return [pscustomobject]@{
        BusId = [int]$BusNumber
        SlotId = [int]$slot
        FunctionId = [int]$function
    }
}

function Assert-GpuRuntimeProfile {
    # 注册表快照是 NVAPI 的唯一数据源，因此不能只依赖上层 map
    # 正确。本门禁在打开 PnP/注册表之前再次校验类型、位宽、时钟顺序
    # 和 SLI 布尔值；任一项异常都不会发布部分 schema-2 身份。
    param(
        [Parameter(Mandatory = $true)][string]$MemoryType,
        [Parameter(Mandatory = $true)][int]$MemoryBusWidthBits,
        [Parameter(Mandatory = $true)][int]$BaseClockKHz,
        [Parameter(Mandatory = $true)][int]$BoostClockKHz,
        [Parameter(Mandatory = $true)][int]$MemoryClockKHz,
        [Parameter(Mandatory = $true)][int]$SliSupported
    )

    if ($MemoryType -cne 'GDDR5') { throw ('不支持的显存类型：' + $MemoryType) }
    if ($MemoryBusWidthBits -lt 32 -or $MemoryBusWidthBits -gt 1024 -or
        ($MemoryBusWidthBits -band ($MemoryBusWidthBits - 1)) -ne 0) {
        throw ('显存总线位宽必须为 32..1024 范围内的 2 次幂：' + $MemoryBusWidthBits)
    }
    if ($BaseClockKHz -lt 100000 -or $BaseClockKHz -gt 5000000 -or
        $BoostClockKHz -lt $BaseClockKHz -or $BoostClockKHz -gt 5000000) {
        throw ('GPU base/boost clock 越界或顺序错误：' +
            $BaseClockKHz + '/' + $BoostClockKHz + ' kHz')
    }
    if ($MemoryClockKHz -lt 100000 -or $MemoryClockKHz -gt 10000000) {
        throw ('NVAPI memory clock 越界：' + $MemoryClockKHz + ' kHz')
    }
    if ($SliSupported -ne 0) {
        throw ('单 GPU 浅层身份不支持 SLI，SpoofSliSupported 必须为 0，实际：' +
            $SliSupported)
    }
}

function Assert-GpuIdentityStrings {
    # 名称/VBIOS 最终会进入固定大小的 C 缓冲区，因此写者必须先执行与 shim
    # 完全相同的字节级门禁。只允许 canonical 厂商，避免 writer 容忍空白或大小写、
    # strict reader 却拒绝同一份已发布快照。
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Vendor,
        [Parameter(Mandatory = $true)][string]$Bios
    )

    if (-not (@('NVIDIA', 'AMD') -ccontains $Vendor)) {
        throw ('GPU 厂商必须精确为 NVIDIA 或 AMD，实际：' + $Vendor)
    }
    if ($Name -cnotmatch '\A[\x20-\x7E]{1,63}\z' -or
        -not $Name.StartsWith(($Vendor + ' '), [System.StringComparison]::Ordinal) -or
        $Name -match '(?i)\b(?:Red Hat|VirtIO)\b') {
        throw 'GPU 名称必须以 canonical 厂商开头，且不得包含 Red Hat/VirtIO 品牌'
    }
    if ($Vendor -ceq 'NVIDIA') {
        if ($Bios -cnotmatch '\AVersion [0-9A-F]{2}(?:\.[0-9A-F]{2}){4}\z') {
            throw ('NVIDIA VBIOS 必须精确为 Version XX.XX.XX.XX.YY：' + $Bios)
        }
    } elseif ($Bios -cnotmatch '\A[0-9]{3}(?:\.[0-9]{3}){3}\.[0-9]{6}\z') {
        throw ('AMD VBIOS 必须精确为 DDD.DDD.DDD.DDD.DDDDDD：' + $Bios)
    }
}

$transactionHelperPath = Join-Path $PSScriptRoot 'gpu-profile-transaction.ps1'
if (-not (Test-Path -LiteralPath $transactionHelperPath -PathType Leaf)) {
    throw ('缺少同目录 durable transaction helper：' + $transactionHelperPath)
}
. $transactionHelperPath

if ($PSCmdlet.ParameterSetName -eq 'Inspect') {
    # Complete 抛错后只读裁决 durable State；这里绝不清 Pending、恢复投影或切 pointer，
    # 让 apply 能在 Committed 分支严格先回滚 DLL，再调用有写入的 RollbackIdentity。
    Invoke-WithIdentityWriterLock {
        $baseKey = Open-StealthBaseKey; $configKey = $null
        try {
            $configKey = $baseKey.OpenSubKey('SOFTWARE\StealthGPU', $false)
            if ($null -eq $configKey) { throw '缺少 StealthGPU 身份根键' }
            $receipt = Read-TransactionReceipt $configKey $InspectIdentity
            return [pscustomobject]@{
                IdentityId=$receipt.NewIdentityId; State=$receipt.State
            }
        } finally {
            if ($null -ne $configKey) { $configKey.Dispose() }
            $baseKey.Dispose()
        }
    }
    return
}

if ($PSCmdlet.ParameterSetName -eq 'Recover') {
    Invoke-RecoverOrRollback -Recover
    return
}
if ($PSCmdlet.ParameterSetName -eq 'Rollback') {
    Invoke-RecoverOrRollback -RequestedIdentity $RollbackIdentity
    return
}

if ($PSCmdlet.ParameterSetName -eq 'Commit') {
    Invoke-WithIdentityWriterLock {
        $baseKey = Open-StealthBaseKey; $configKey = $null
        try {
            $configKey = $baseKey.OpenSubKey('SOFTWARE\StealthGPU', $true)
            if ($null -eq $configKey) { throw '缺少 StealthGPU 身份根键' }
            $pending = Get-OptionalStringState $configKey 'PendingIdentity'
            if (-not $pending.Present -or $pending.Value -cne $CommitIdentity) {
                throw 'CommitIdentity 与 PendingIdentity 不一致'
            }
            $receipt = Read-TransactionReceipt $configKey $CommitIdentity
            if ($receipt.State -cne 'Prepared') { throw ('不能提交事务状态：' + $receipt.State) }
            $expected = [pscustomobject]@{ Present=$receipt.PreviousPointerPresent; Value=$receipt.PreviousIdentityId }
            $current = Get-OptionalStringState $configKey 'CurrentIdentity'
            if ($current.Present -ne $expected.Present -or
                ($current.Present -and $current.Value -cne $expected.Value)) {
                throw 'Commit 投影前 CurrentIdentity 已偏离事务基线'
            }
            # 关键投影与 CurrentIdentity CAS 必须处在同一个全局 mutex 临界区。
            # refresh 由当前 PowerShell 线程同步调用；Windows named Mutex 可重入，
            # 内层写后回读完成并释放一次后，外层锁仍保持到 pointer 提交结束。
            $refreshPath = Join-Path $PSScriptRoot 'refresh-gpu-name.ps1'
            if (-not (Test-Path -LiteralPath $refreshPath -PathType Leaf)) {
                throw ('Commit 缺少 strict projection helper：' + $refreshPath)
            }
            & $refreshPath -StagedIdentityId $CommitIdentity
            Set-CurrentIdentityPointer $configKey $expected $true $receipt.NewIdentityId
            $configKey.SetValue('SpoofName', $receipt.NewSpoofName,
                [Microsoft.Win32.RegistryValueKind]::String); $configKey.Flush()
            Assert-RegistryState $configKey 'SpoofName' $true $receipt.NewSpoofName `
                ([Microsoft.Win32.RegistryValueKind]::String)
            Set-TransactionState $configKey $CommitIdentity 'Prepared' 'Committed'
        } finally {
            if ($null -ne $configKey) { $configKey.Dispose() }
            $baseKey.Dispose()
        }
    }
    return
}

if ($PSCmdlet.ParameterSetName -eq 'Complete') {
    Invoke-WithIdentityWriterLock {
        $baseKey = Open-StealthBaseKey; $configKey = $null
        try {
            $configKey = $baseKey.OpenSubKey('SOFTWARE\StealthGPU', $true)
            if ($null -eq $configKey) { throw '缺少 StealthGPU 身份根键' }
            $pending = Get-OptionalStringState $configKey 'PendingIdentity'
            if (-not $pending.Present -or $pending.Value -cne $CompleteIdentity) {
                throw 'CompleteIdentity 与 PendingIdentity 不一致'
            }
            $receipt = Read-TransactionReceipt $configKey $CompleteIdentity
            $current = Get-OptionalStringState $configKey 'CurrentIdentity'
            if ($receipt.State -cne 'Committed' -or -not $current.Present -or
                $current.Value -cne $CompleteIdentity) { throw '只有已提交且仍为 current 的事务才能完成' }
            Set-TransactionState $configKey $CompleteIdentity 'Committed' 'Completed'
            Clear-PendingIdentity $configKey $CompleteIdentity
        } finally {
            if ($null -ne $configKey) { $configKey.Dispose() }
            $baseKey.Dispose()
        }
    }
    return
}

Assert-GpuIdentityStrings -Name $SpoofName -Vendor $SpoofVendor -Bios $SpoofBios
Assert-GpuRuntimeProfile -MemoryType $SpoofMemoryType `
    -MemoryBusWidthBits $SpoofMemoryBusWidthBits -BaseClockKHz $SpoofBaseClockKHz `
    -BoostClockKHz $SpoofBoostClockKHz -MemoryClockKHz $SpoofMemoryClockKHz `
    -SliSupported $SpoofSliSupported
Invoke-LegacyGpuTaskBarrier

$baseKey = Open-StealthBaseKey
try {
    $matched = @()
    foreach ($device in @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop)) {
        if ([string]::IsNullOrWhiteSpace([string]$device.InstanceId)) { continue }
        $enumPath = 'SYSTEM\CurrentControlSet\Enum\' + [string]$device.InstanceId
        $enumKey = $baseKey.OpenSubKey($enumPath, $false)
        if ($null -eq $enumKey) { continue }
        try {
            $service = [string](Get-ExactRegistryValue $enumKey 'Service' `
                ([Microsoft.Win32.RegistryValueKind]::String))
        } catch { continue } finally { $enumKey.Dispose() }
        if ($service -ieq 'VioGpuDod') { $matched += $device }
    }
    if ($matched.Count -ne 1) {
        throw ('应当恰好找到一个由 VioGpuDod 驱动的在线显示设备，实际数量=' + $matched.Count)
    }
    $identity = Get-ShallowPciIdentity ([string]$matched[0].InstanceId) $SpoofVendor
    $busProperty = Get-PnpDeviceProperty -InstanceId $matched[0].InstanceId `
        -KeyName 'DEVPKEY_Device_BusNumber' -ErrorAction Stop
    $addressProperty = Get-PnpDeviceProperty -InstanceId $matched[0].InstanceId `
        -KeyName 'DEVPKEY_Device_Address' -ErrorAction Stop
    $location = Get-PciLocation ([long]$busProperty.Data) ([long]$addressProperty.Data)
    $enumPath = 'SYSTEM\CurrentControlSet\Enum\' + $identity.InstanceId
    $enumKey = $baseKey.OpenSubKey($enumPath, $false)
    if ($null -eq $enumKey) { throw ('active Enum 节点不存在：' + $enumPath) }
    try {
        $driver = [string](Get-ExactRegistryValue $enumKey 'Driver' `
            ([Microsoft.Win32.RegistryValueKind]::String))
        $driverMatch = [regex]::Match($driver,
            '^\{4d36e968-e325-11ce-bfc1-08002be10318\}\\([0-9]{4})$',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $driverMatch.Success) { throw ('active Enum Driver 非 Display Class：' + $driver) }
        $classSubkey = $driverMatch.Groups[1].Value
        $classPath = 'SYSTEM\CurrentControlSet\Control\Class\' + $classGuid + '\' + $classSubkey
        $classKey = $baseKey.OpenSubKey($classPath, $false)
        if ($null -eq $classKey) { throw ('active Class 子键不存在：' + $classPath) }
        try {
            $stageResult = Invoke-WithIdentityWriterLock {
                $configKey = $baseKey.CreateSubKey('SOFTWARE\StealthGPU', $true)
                $identitiesKey = $null; $transactionsKey = $null
                $versionKey = $null; $transactionKey = $null
                try {
                    if ($null -eq $configKey) { throw '无法创建 HKLM\SOFTWARE\StealthGPU' }
                    if ((Get-OptionalStringState $configKey 'PendingIdentity').Present) {
                        throw '已有 PendingIdentity；必须先执行 -RecoverPending'
                    }
                    $oldPointer = Get-OptionalStringState $configKey 'CurrentIdentity'
                    $oldIdentitySchema = $null
                    if ($oldPointer.Present) {
                        Assert-IdentityToken $oldPointer.Value 'CurrentIdentity'
                        # 在发布 PendingIdentity 前确认旧 pointer 至少是已知 schema-1
                        # migration snapshot 或完整 schema-2。这样未知/半写旧状态不会
                        # 先生成一个连 rollback receipt 都无法读取的持久事务。
                        $oldIdentity = Get-PreviousIdentitySnapshot $configKey $oldPointer.Value
                        $oldIdentitySchema = [int]$oldIdentity.IdentitySchemaVersion
                    }
                    $oldMirror = Get-OptionalStringState $configKey 'SpoofName'
                    $versionId = [Guid]::NewGuid().ToString('N').ToUpperInvariant()
                    Assert-IdentityToken $versionId
                    $identitiesKey = $configKey.CreateSubKey('Identities', $true)
                    $transactionsKey = $configKey.CreateSubKey('Transactions', $true)
                    if (@($identitiesKey.GetSubKeyNames()) -ccontains $versionId -or
                        @($transactionsKey.GetSubKeyNames()) -ccontains $versionId) {
                        throw ('拒绝复用身份/事务 GUID：' + $versionId)
                    }
                    $versionKey = $identitiesKey.CreateSubKey($versionId, $true)
                    $transactionKey = $transactionsKey.CreateSubKey($versionId, $true)
                    $dword = [Microsoft.Win32.RegistryValueKind]::DWord
                    $string = [Microsoft.Win32.RegistryValueKind]::String
                    $versionKey.SetValue('IdentitySchemaVersion', 0, $dword)
                    $versionKey.SetValue('IdentityId', $versionId, $string)
                    $versionKey.SetValue('SpoofName', $SpoofName, $string)
                    $versionKey.SetValue('SpoofVendor', $SpoofVendor, $string)
                    $versionKey.SetValue('SpoofBios', $SpoofBios, $string)
                    $versionKey.SetValue('SpoofPciVendorId', [int]$identity.PciVendorId, $dword)
                    $versionKey.SetValue('SpoofPciDeviceId', [int]$identity.PciDeviceId, $dword)
                    $versionKey.SetValue('SpoofSubsystemVendorId', [int]$identity.SubsystemVendorId, $dword)
                    $versionKey.SetValue('SpoofSubsystemDeviceId', [int]$identity.SubsystemDeviceId, $dword)
                    $versionKey.SetValue('SpoofRevisionId', [int]$identity.RevisionId, $dword)
                    $versionKey.SetValue('SpoofPciBusId', [int]$location.BusId, $dword)
                    $versionKey.SetValue('SpoofPciSlotId', [int]$location.SlotId, $dword)
                    $versionKey.SetValue('SpoofPciFunctionId', [int]$location.FunctionId, $dword)
                    $versionKey.SetValue('SpoofRamMb', [int]$SpoofRamMb, $dword)
                    $versionKey.SetValue('SpoofMemoryType', $SpoofMemoryType, $string)
                    $versionKey.SetValue('SpoofMemoryBusWidthBits', [int]$SpoofMemoryBusWidthBits, $dword)
                    $versionKey.SetValue('SpoofBaseClockKHz', [int]$SpoofBaseClockKHz, $dword)
                    $versionKey.SetValue('SpoofBoostClockKHz', [int]$SpoofBoostClockKHz, $dword)
                    $versionKey.SetValue('SpoofMemoryClockKHz', [int]$SpoofMemoryClockKHz, $dword)
                    $versionKey.SetValue('SpoofSliSupported', [int]$SpoofSliSupported, $dword)
                    $versionKey.SetValue('SourceInstanceId', $identity.InstanceId, $string)
                    $versionKey.SetValue('IdentityMode', 'shallow-user-projection', $string)
                    $versionKey.SetValue('IdentitySchemaVersion', 2, $dword); $versionKey.Flush()
                    $transactionKey.SetValue('TransactionSchemaVersion', 0, $dword)
                    $transactionKey.SetValue('TransactionId', $versionId, $string)
                    $transactionKey.SetValue('State', 'Prepared', $string)
                    $transactionKey.SetValue('PreviousPointerPresent', [int]$oldPointer.Present, $dword)
                    if ($oldPointer.Present) {
                        $transactionKey.SetValue('PreviousIdentityId', $oldPointer.Value, $string)
                        $transactionKey.SetValue('PreviousIdentitySchemaVersion', $oldIdentitySchema, $dword)
                    }
                    $transactionKey.SetValue('PreviousSpoofNamePresent', [int]$oldMirror.Present, $dword)
                    if ($oldMirror.Present) { $transactionKey.SetValue('PreviousSpoofName', $oldMirror.Value, $string) }
                    $transactionKey.SetValue('ClassSubkey', $classSubkey, $string)
                    Write-ProjectionJournal $transactionKey 'Enum' $enumKey $enumPath $enumJournalNames
                    Write-ProjectionJournal $transactionKey 'Class' $classKey $classPath $classJournalNames
                    $transactionKey.SetValue('TransactionSchemaVersion', 1, $dword); $transactionKey.Flush()
                    $configKey.SetValue('PendingIdentity', $versionId, $string); $configKey.Flush()
                    Assert-RegistryState $configKey 'PendingIdentity' $true $versionId $string
                    return [pscustomobject]@{ NewIdentityId=$versionId; PreviousPointerPresent=$oldPointer.Present; PreviousIdentityId=$oldPointer.Value }
                } finally {
                    foreach ($key in @($transactionKey,$versionKey,$transactionsKey,$identitiesKey,$configKey)) {
                        if ($null -ne $key) { $key.Dispose() }
                    }
                }
            }
            Write-Host ('浅层 GPU 身份已暂存：物理 1AF4:1050 -> 用户态 {0:X4}:{1:X4}，等待严格投影后提交' -f
                $identity.PciVendorId, $identity.PciDeviceId) -ForegroundColor Green
            return $stageResult
        } finally { $classKey.Dispose() }
    } finally { $enumKey.Dispose() }
} finally { $baseKey.Dispose() }

# GPU 身份 durable transaction 的公共实现。
#
# 本文件只定义无副作用的事务函数与 journal 字段常量；由同目录的
# persist-gpu-profile.ps1 严格检查后 dot-source。保持独立文件可避免身份解析、
# 快照构建和 durable rollback 全部挤在一个超长脚本内，同时不改变事务语义。

function Assert-IdentityToken {
    param([Parameter(Mandatory = $true)][string]$Value, [string]$Field = 'IdentityId')
    if ($Value -cnotmatch '^[0-9A-F]{32}$') {
        throw ($Field + ' 必须是 32 位大写十六进制 GUID-N：' + $Value)
    }
}

function Get-ExactRegistryValue {
    param($Key, [string]$Name, [Microsoft.Win32.RegistryValueKind]$Kind)
    if (-not (@($Key.GetValueNames()) -ccontains $Name)) { throw ('缺少注册表值：' + $Name) }
    if ($Key.GetValueKind($Name) -ne $Kind) { throw ('注册表值类型错误：' + $Name) }
    return $Key.GetValue($Name, $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Get-OptionalStringState {
    param($Key, [string]$Name)
    if (-not (@($Key.GetValueNames()) -ccontains $Name)) {
        return [pscustomobject]@{ Present = $false; Value = $null }
    }
    $value = [string](Get-ExactRegistryValue -Key $Key -Name $Name `
        -Kind ([Microsoft.Win32.RegistryValueKind]::String))
    if ([string]::IsNullOrWhiteSpace($value) -or $value.IndexOf([char]0) -ge 0) {
        throw ('注册表字符串为空或含 NUL：' + $Name)
    }
    return [pscustomobject]@{ Present = $true; Value = $value }
}

function Test-RegistryDataEqual {
    param($Left, $Right)
    if ($Left -is [array] -or $Right -is [array]) {
        $a = @($Left); $b = @($Right)
        if ($a.Count -ne $b.Count) { return $false }
        for ($i = 0; $i -lt $a.Count; $i++) {
            if ([string]$a[$i] -cne [string]$b[$i]) { return $false }
        }
        return $true
    }
    if ($Left -is [string] -or $Right -is [string]) {
        return ([string]$Left -ceq [string]$Right)
    }
    return ($Left -eq $Right)
}

function Assert-RegistryState {
    param($Key, [string]$Name, [bool]$Present, $Value,
        [Microsoft.Win32.RegistryValueKind]$Kind)
    $names = @($Key.GetValueNames())
    if (-not $Present) {
        if ($names -ccontains $Name) { throw ('回读发现本应不存在的值：' + $Name) }
        return
    }
    $actual = Get-ExactRegistryValue -Key $Key -Name $Name -Kind $Kind
    if (-not (Test-RegistryDataEqual -Left $actual -Right $Value)) {
        throw ('注册表写后回读不一致：' + $Name)
    }
}

function Set-CurrentIdentityPointer {
    # 所有 CurrentIdentity 修改都经过同一个 compare-before-write 门。命名 mutex
    # 串行化仓库内写者，精确 expected state 则拒绝覆盖外部或并发修改。
    param($ConfigKey, $Expected, [bool]$NewPresent, [string]$NewValue)
    $actual = Get-OptionalStringState -Key $ConfigKey -Name 'CurrentIdentity'
    if ($actual.Present -ne $Expected.Present -or
        ($actual.Present -and $actual.Value -cne $Expected.Value)) {
        throw 'CurrentIdentity 已被并发修改，CAS 拒绝覆盖'
    }
    if ($NewPresent) {
        Assert-IdentityToken -Value $NewValue -Field '新 CurrentIdentity'
        $ConfigKey.SetValue('CurrentIdentity', $NewValue,
            [Microsoft.Win32.RegistryValueKind]::String)
    } else {
        $ConfigKey.DeleteValue('CurrentIdentity', $false)
    }
    $ConfigKey.Flush()
    Assert-RegistryState -Key $ConfigKey -Name 'CurrentIdentity' -Present $NewPresent `
        -Value $NewValue -Kind ([Microsoft.Win32.RegistryValueKind]::String)
}

function Write-ProjectionJournal {
    param($TransactionKey, [string]$JournalName, $TargetKey,
        [string]$TargetPath, [string[]]$ValueNames)
    $journal = $TransactionKey.CreateSubKey(('Journal\' + $JournalName), $true)
    if ($null -eq $journal) { throw ('无法创建投影 journal：' + $JournalName) }
    try {
        $journal.SetValue('TargetPath', $TargetPath,
            [Microsoft.Win32.RegistryValueKind]::String)
        $mask = 0
        for ($i = 0; $i -lt $ValueNames.Count; $i++) {
            $name = $ValueNames[$i]
            if (@($TargetKey.GetValueNames()) -ccontains $name) {
                $mask = $mask -bor (1 -shl $i)
                $kind = $TargetKey.GetValueKind($name)
                $value = $TargetKey.GetValue($name, $null,
                    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $journal.SetValue(('Original.' + $name), $value, $kind)
            }
        }
        $journal.SetValue('PresentMask', $mask,
            [Microsoft.Win32.RegistryValueKind]::DWord)
        $journal.Flush()
    } finally { $journal.Dispose() }
}

function Read-ProjectionJournal {
    param($TransactionKey, [string]$JournalName, [string]$ExpectedPath,
        [string[]]$ValueNames)
    $journal = $TransactionKey.OpenSubKey(('Journal\' + $JournalName), $false)
    if ($null -eq $journal) { throw ('缺少投影 journal：' + $JournalName) }
    try {
        $path = [string](Get-ExactRegistryValue -Key $journal -Name 'TargetPath' `
            -Kind ([Microsoft.Win32.RegistryValueKind]::String))
        $mask = [int](Get-ExactRegistryValue -Key $journal -Name 'PresentMask' `
            -Kind ([Microsoft.Win32.RegistryValueKind]::DWord))
        if ($path -cne $ExpectedPath -or $mask -lt 0 -or
            $mask -gt ((1 -shl $ValueNames.Count) - 1)) {
            throw ('投影 journal 目标或 mask 非法：' + $JournalName)
        }
        $entries = @()
        for ($i = 0; $i -lt $ValueNames.Count; $i++) {
            $name = $ValueNames[$i]; $present = (($mask -band (1 -shl $i)) -ne 0)
            $storedName = 'Original.' + $name
            if ($present) {
                if (-not (@($journal.GetValueNames()) -ccontains $storedName)) {
                    throw ('journal 缺少原值：' + $storedName)
                }
                $kind = $journal.GetValueKind($storedName)
                $value = $journal.GetValue($storedName, $null,
                    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            } else {
                if (@($journal.GetValueNames()) -ccontains $storedName) {
                    throw ('journal 为 absent 字段保存了多余原值：' + $storedName)
                }
                $kind = [Microsoft.Win32.RegistryValueKind]::Unknown; $value = $null
            }
            $entries += [pscustomobject]@{ Name=$name; Present=$present; Kind=$kind; Value=$value }
        }
        return [pscustomobject]@{ TargetPath=$path; Entries=$entries }
    } finally { $journal.Dispose() }
}

function Test-RegistryStateMatches {
    param($Key, [string]$Name, [bool]$Present, $Value,
        [Microsoft.Win32.RegistryValueKind]$Kind)
    $actualPresent = @($Key.GetValueNames()) -ccontains $Name
    if ($actualPresent -ne $Present) { return $false }
    if (-not $Present) { return $true }
    if ($Key.GetValueKind($Name) -ne $Kind) { return $false }
    $actual = $Key.GetValue($Name, $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return (Test-RegistryDataEqual $actual $Value)
}

function Assert-ProjectionJournalCanRestore {
    param($BaseKey, $Journal, [hashtable]$ProjectedValues)
    $target = $BaseKey.OpenSubKey($Journal.TargetPath, $true)
    if ($null -eq $target) { throw ('无法打开 journal 目标：' + $Journal.TargetPath) }
    try {
        # 先完整 CAS 预检再写第一个值：每项只能仍是 journal 原值或本事务的
        # projected 值。第三方修改会在恢复任何字段之前被拒绝，避免覆盖外部状态。
        foreach ($entry in $Journal.Entries) {
            $projected = $ProjectedValues[$entry.Name]
            if ($null -eq $projected) { throw ('缺少 projected CAS 值：' + $entry.Name) }
            $isOriginal = Test-RegistryStateMatches $target $entry.Name $entry.Present `
                $entry.Value $entry.Kind
            $isProjected = Test-RegistryStateMatches $target $entry.Name $true `
                $projected.Value $projected.Kind
            if (-not $isOriginal -and -not $isProjected) {
                throw ('journal CAS 拒绝覆盖第三方注册表值：' + $entry.Name)
            }
        }
    } finally { $target.Dispose() }
}

function Restore-ProjectionJournal {
    param($BaseKey, $Journal, [hashtable]$ProjectedValues,
        [switch]$PreflightComplete)
    if (-not $PreflightComplete) {
        Assert-ProjectionJournalCanRestore $BaseKey $Journal $ProjectedValues
    }
    $target = $BaseKey.OpenSubKey($Journal.TargetPath, $true)
    if ($null -eq $target) { throw ('无法打开 journal 目标：' + $Journal.TargetPath) }
    try {
        foreach ($entry in $Journal.Entries) {
            if ($entry.Present) { $target.SetValue($entry.Name, $entry.Value, $entry.Kind) }
            else { $target.DeleteValue($entry.Name, $false) }
        }
        $target.Flush()
        foreach ($entry in $Journal.Entries) {
            Assert-RegistryState -Key $target -Name $entry.Name -Present $entry.Present `
                -Value $entry.Value -Kind $entry.Kind
        }
    } finally { $target.Dispose() }
}

$enumJournalNames = @('FriendlyName', 'DeviceDesc', 'Mfg')
$classJournalNames = @('DriverDesc', 'ProviderName', 'MatchingDeviceId',
    'HardwareInformation.AdapterString', 'HardwareInformation.ChipType',
    'HardwareInformation.DacType', 'HardwareInformation.BiosString',
    'HardwareInformation.MemorySize', 'HardwareInformation.qwMemorySize')
$classGuid = '{4d36e968-e325-11ce-bfc1-08002be10318}'

function Read-ValidatedIdentitySnapshot {
    # schema-1 是上一版完整快照，schema-2 只在其上增加显存类型/位宽、时钟和
    # SLI 字段。迁移可以把 schema-1 当 rollback 基线，但两版都必须通过相同的
    # 名称、PCI 拓扑、物理 SourceInstanceId 与 schema-last 一致性门禁。
    param($IdentityKey, [string]$ExpectedId, [int[]]$AllowedSchemas)
    Assert-IdentityToken $ExpectedId '身份快照 ID'
    $dword = [Microsoft.Win32.RegistryValueKind]::DWord; $string = [Microsoft.Win32.RegistryValueKind]::String
    $schemaBefore = [int](Get-ExactRegistryValue $IdentityKey 'IdentitySchemaVersion' $dword)
    if (-not ($AllowedSchemas -ccontains $schemaBefore)) {
        throw ('身份快照 schema 不受支持：' + $schemaBefore)
    }
    $snapshot = [ordered]@{
        IdentitySchemaVersion=$schemaBefore
        IdentityId=[string](Get-ExactRegistryValue $IdentityKey 'IdentityId' $string)
        SpoofName=[string](Get-ExactRegistryValue $IdentityKey 'SpoofName' $string)
        SpoofVendor=[string](Get-ExactRegistryValue $IdentityKey 'SpoofVendor' $string)
        SpoofBios=[string](Get-ExactRegistryValue $IdentityKey 'SpoofBios' $string)
        SpoofPciVendorId=[int](Get-ExactRegistryValue $IdentityKey 'SpoofPciVendorId' $dword)
        SpoofPciDeviceId=[int](Get-ExactRegistryValue $IdentityKey 'SpoofPciDeviceId' $dword)
        SpoofSubsystemVendorId=[int](Get-ExactRegistryValue $IdentityKey 'SpoofSubsystemVendorId' $dword)
        SpoofSubsystemDeviceId=[int](Get-ExactRegistryValue $IdentityKey 'SpoofSubsystemDeviceId' $dword)
        SpoofRevisionId=[int](Get-ExactRegistryValue $IdentityKey 'SpoofRevisionId' $dword)
        SpoofPciBusId=[int](Get-ExactRegistryValue $IdentityKey 'SpoofPciBusId' $dword)
        SpoofPciSlotId=[int](Get-ExactRegistryValue $IdentityKey 'SpoofPciSlotId' $dword)
        SpoofPciFunctionId=[int](Get-ExactRegistryValue $IdentityKey 'SpoofPciFunctionId' $dword)
        SpoofRamMb=[int](Get-ExactRegistryValue $IdentityKey 'SpoofRamMb' $dword)
        SourceInstanceId=[string](Get-ExactRegistryValue $IdentityKey 'SourceInstanceId' $string)
        IdentityMode=[string](Get-ExactRegistryValue $IdentityKey 'IdentityMode' $string)
    }
    if ($schemaBefore -eq 2) {
        $snapshot.SpoofMemoryType=[string](Get-ExactRegistryValue $IdentityKey 'SpoofMemoryType' $string)
        $snapshot.SpoofMemoryBusWidthBits=[int](Get-ExactRegistryValue $IdentityKey 'SpoofMemoryBusWidthBits' $dword)
        $snapshot.SpoofBaseClockKHz=[int](Get-ExactRegistryValue $IdentityKey 'SpoofBaseClockKHz' $dword)
        $snapshot.SpoofBoostClockKHz=[int](Get-ExactRegistryValue $IdentityKey 'SpoofBoostClockKHz' $dword)
        $snapshot.SpoofMemoryClockKHz=[int](Get-ExactRegistryValue $IdentityKey 'SpoofMemoryClockKHz' $dword)
        $snapshot.SpoofSliSupported=[int](Get-ExactRegistryValue $IdentityKey 'SpoofSliSupported' $dword)
    }
    $schemaAfter = [int](Get-ExactRegistryValue $IdentityKey 'IdentitySchemaVersion' $dword)
    $source = [regex]::Match($snapshot.SourceInstanceId,
        '^PCI\\VEN_1AF4&DEV_1050&SUBSYS_([0-9A-F]{4})([0-9A-F]{4})&REV_([0-9A-F]{2})(?:&|\\)')
    $vendorId = switch -CaseSensitive ($snapshot.SpoofVendor) {
        'NVIDIA' { 0x10DE; break }; 'AMD' { 0x1002; break }; default { -1 }
    }
    $validName = $snapshot.SpoofName -cmatch '\A[\x20-\x7E]{1,63}\z' -and $snapshot.SpoofName.StartsWith(($snapshot.SpoofVendor + ' '), [System.StringComparison]::Ordinal) -and $snapshot.SpoofName -cnotmatch '(?i)\b(?:Red Hat|VirtIO)\b'
    $validBios = if ($snapshot.SpoofVendor -ceq 'NVIDIA') {
        $snapshot.SpoofBios -cmatch '\AVersion [0-9A-F]{2}(?:\.[0-9A-F]{2}){4}\z'
    } else { $snapshot.SpoofBios -cmatch '\A[0-9]{3}(?:\.[0-9]{3}){3}\.[0-9]{6}\z' }
    if ($schemaAfter -ne $schemaBefore -or $snapshot.IdentityId -cne $ExpectedId -or
        $snapshot.IdentityMode -cne 'shallow-user-projection' -or -not $validName -or $vendorId -lt 0 -or
        -not $validBios -or -not $source.Success -or
        $snapshot.SpoofPciVendorId -ne $vendorId -or
        $snapshot.SpoofPciDeviceId -lt 1 -or $snapshot.SpoofPciDeviceId -gt 0xFFFF -or
        $snapshot.SpoofSubsystemVendorId -ne $snapshot.SpoofPciVendorId -or
        $snapshot.SpoofSubsystemDeviceId -ne $snapshot.SpoofPciDeviceId -or
        [Convert]::ToInt32($source.Groups[1].Value,16) -ne $snapshot.SpoofPciDeviceId -or
        [Convert]::ToInt32($source.Groups[2].Value,16) -ne $snapshot.SpoofPciVendorId -or
        [Convert]::ToInt32($source.Groups[3].Value,16) -ne $snapshot.SpoofRevisionId -or
        $snapshot.SpoofRevisionId -lt 0 -or $snapshot.SpoofRevisionId -gt 0xFF -or
        $snapshot.SpoofPciBusId -lt 0 -or $snapshot.SpoofPciBusId -gt 0xFF -or
        $snapshot.SpoofPciSlotId -lt 0 -or $snapshot.SpoofPciSlotId -gt 0x1F -or
        $snapshot.SpoofPciFunctionId -lt 0 -or $snapshot.SpoofPciFunctionId -gt 7 -or
        $snapshot.SpoofRamMb -lt 1 -or $snapshot.SpoofRamMb -gt 1048576) {
        throw ('身份快照公共字段非法：' + $ExpectedId)
    }
    if ($schemaBefore -eq 2 -and ($snapshot.SpoofMemoryType -cne 'GDDR5' -or
        $snapshot.SpoofMemoryBusWidthBits -lt 32 -or $snapshot.SpoofMemoryBusWidthBits -gt 1024 -or
        ($snapshot.SpoofMemoryBusWidthBits -band ($snapshot.SpoofMemoryBusWidthBits - 1)) -ne 0 -or
        $snapshot.SpoofBaseClockKHz -lt 100000 -or $snapshot.SpoofBaseClockKHz -gt 5000000 -or
        $snapshot.SpoofBoostClockKHz -lt $snapshot.SpoofBaseClockKHz -or
        $snapshot.SpoofBoostClockKHz -gt 5000000 -or $snapshot.SpoofMemoryClockKHz -lt 100000 -or
        $snapshot.SpoofMemoryClockKHz -gt 10000000 -or $snapshot.SpoofSliSupported -ne 0)) {
        throw ('身份快照 schema-2 扩展字段非法：' + $ExpectedId)
    }
    return [pscustomobject]$snapshot
}

function Get-PreviousIdentitySnapshot {
    param($ConfigKey, [string]$IdentityId)
    Assert-IdentityToken $IdentityId 'PreviousIdentityId'
    $identityKey = $ConfigKey.OpenSubKey(('Identities\' + $IdentityId), $false)
    if ($null -eq $identityKey) { throw 'PreviousIdentityId 子键不存在' }
    try { return Read-ValidatedIdentitySnapshot $identityKey $IdentityId @(1,2) }
    finally { $identityKey.Dispose() }
}

function Read-TransactionReceipt {
    param($ConfigKey, [string]$IdentityId)
    Assert-IdentityToken -Value $IdentityId
    $transactionKey = $ConfigKey.OpenSubKey(('Transactions\' + $IdentityId), $false)
    $identityKey = $ConfigKey.OpenSubKey(('Identities\' + $IdentityId), $false)
    if ($null -eq $transactionKey -or $null -eq $identityKey) {
        if ($null -ne $transactionKey) { $transactionKey.Dispose() }
        if ($null -ne $identityKey) { $identityKey.Dispose() }
        throw ('事务或身份子键不存在：' + $IdentityId)
    }
    try {
        $string = [Microsoft.Win32.RegistryValueKind]::String
        $dword = [Microsoft.Win32.RegistryValueKind]::DWord
        $schema = [int](Get-ExactRegistryValue $transactionKey 'TransactionSchemaVersion' $dword)
        $txnId = [string](Get-ExactRegistryValue $transactionKey 'TransactionId' $string)
        $state = [string](Get-ExactRegistryValue $transactionKey 'State' $string)
        $oldPresent = [int](Get-ExactRegistryValue $transactionKey 'PreviousPointerPresent' $dword)
        $mirrorPresent = [int](Get-ExactRegistryValue $transactionKey 'PreviousSpoofNamePresent' $dword)
        $classSubkey = [string](Get-ExactRegistryValue $transactionKey 'ClassSubkey' $string)
        $newIdentity = Read-ValidatedIdentitySnapshot $identityKey $IdentityId @(2)
        $source = $newIdentity.SourceInstanceId
        $newName = $newIdentity.SpoofName; $newVendor = $newIdentity.SpoofVendor
        $newBios = $newIdentity.SpoofBios; $newDeviceId = $newIdentity.SpoofPciDeviceId
        $newVendorId = $newIdentity.SpoofPciVendorId; $newRamMb = $newIdentity.SpoofRamMb
        if ($schema -ne 1 -or $txnId -cne $IdentityId -or
            -not (@('Prepared','Committed','Completed','RolledBack') -ccontains $state) -or
            ($oldPresent -ne 0 -and $oldPresent -ne 1) -or
            ($mirrorPresent -ne 0 -and $mirrorPresent -ne 1) -or $classSubkey -cnotmatch '^\d{4}$' -or
            [string]::IsNullOrWhiteSpace($source)) {
            throw ('事务凭据字段非法：' + $IdentityId)
        }
        $oldIdState = Get-OptionalStringState $transactionKey 'PreviousIdentityId'
        $oldMirrorState = Get-OptionalStringState $transactionKey 'PreviousSpoofName'
        if ($oldIdState.Present -ne [bool]$oldPresent -or
            $oldMirrorState.Present -ne [bool]$mirrorPresent) {
            throw '事务凭据 presence flag 与字段不一致'
        }
        $markerPresent = @($transactionKey.GetValueNames()) -ccontains 'PreviousIdentitySchemaVersion'
        $oldIdentitySchema = $null
        if ($oldIdState.Present) {
            $oldIdentity = Get-PreviousIdentitySnapshot $ConfigKey $oldIdState.Value
            $oldIdentitySchema = [int]$oldIdentity.IdentitySchemaVersion
            if ($markerPresent -and [int](Get-ExactRegistryValue $transactionKey `
                    'PreviousIdentitySchemaVersion' $dword) -ne $oldIdentitySchema) {
                throw 'PreviousIdentitySchemaVersion 与旧快照不一致'
            }
        } elseif ($markerPresent) {
            throw '无 PreviousIdentityId 却存在 PreviousIdentitySchemaVersion'
        }
        $enumPath = 'SYSTEM\CurrentControlSet\Enum\' + $source
        $classPath = 'SYSTEM\CurrentControlSet\Control\Class\' + $classGuid + '\' + $classSubkey
        $enumJournal = Read-ProjectionJournal $transactionKey 'Enum' $enumPath $enumJournalNames
        $classJournal = Read-ProjectionJournal $transactionKey 'Class' $classPath $classJournalNames
        $chipType = $newName -replace '^(NVIDIA|AMD)\s+', ''
        $memoryBytes = [BitConverter]::GetBytes([UInt64]$newRamMb * 1MB)
        $projectedEnum = @{}
        foreach ($name in $enumJournalNames) {
            $value = if ($name -ceq 'Mfg') { $newVendor } else { $newName }
            $projectedEnum[$name] = [pscustomobject]@{ Value=$value; Kind=$string }
        }
        $projectedClass = @{
            DriverDesc=[pscustomobject]@{ Value=$newName; Kind=$string }
            ProviderName=[pscustomobject]@{ Value=$newVendor; Kind=$string }
            MatchingDeviceId=[pscustomobject]@{ Value=('PCI\VEN_{0:X4}&DEV_{1:X4}' -f $newVendorId,$newDeviceId); Kind=$string }
            'HardwareInformation.AdapterString'=[pscustomobject]@{ Value=$newName; Kind=$string }
            'HardwareInformation.ChipType'=[pscustomobject]@{ Value=$chipType; Kind=$string }
            'HardwareInformation.DacType'=[pscustomobject]@{ Value='Integrated RAMDAC'; Kind=$string }
            'HardwareInformation.BiosString'=[pscustomobject]@{ Value=$newBios; Kind=$string }
            'HardwareInformation.MemorySize'=[pscustomobject]@{ Value=[byte[]]$memoryBytes[0..3]; Kind=[Microsoft.Win32.RegistryValueKind]::Binary }
            'HardwareInformation.qwMemorySize'=[pscustomobject]@{ Value=([UInt64]$newRamMb * 1MB); Kind=[Microsoft.Win32.RegistryValueKind]::QWord }
        }
        return [pscustomobject]@{
            NewIdentityId=$IdentityId; State=$state
            PreviousPointerPresent=[bool]$oldPresent; PreviousIdentityId=$oldIdState.Value
            PreviousIdentitySchemaVersion=$oldIdentitySchema
            PreviousSpoofNamePresent=[bool]$mirrorPresent; PreviousSpoofName=$oldMirrorState.Value
            NewSpoofName=$newName; EnumJournal=$enumJournal; ClassJournal=$classJournal
            ProjectedEnum=$projectedEnum; ProjectedClass=$projectedClass
        }
    } finally { $identityKey.Dispose(); $transactionKey.Dispose() }
}

function Set-TransactionState {
    param($ConfigKey, [string]$IdentityId, [string]$Expected, [string]$NewState)
    $key = $ConfigKey.OpenSubKey(('Transactions\' + $IdentityId), $true)
    if ($null -eq $key) { throw ('事务子键不存在：' + $IdentityId) }
    try {
        $kind = [Microsoft.Win32.RegistryValueKind]::String
        $actual = [string](Get-ExactRegistryValue $key 'State' $kind)
        if ($actual -cne $Expected) { throw ('事务状态竞态：' + $actual + ' != ' + $Expected) }
        $key.SetValue('State', $NewState, $kind); $key.Flush()
        Assert-RegistryState $key 'State' $true $NewState $kind
    } finally { $key.Dispose() }
}

function Clear-PendingIdentity {
    param($ConfigKey, [string]$IdentityId)
    $pending = Get-OptionalStringState $ConfigKey 'PendingIdentity'
    if (-not $pending.Present -or $pending.Value -cne $IdentityId) {
        throw 'PendingIdentity 与事务不一致，拒绝清除'
    }
    $ConfigKey.DeleteValue('PendingIdentity', $false); $ConfigKey.Flush()
    Assert-RegistryState $ConfigKey 'PendingIdentity' $false $null `
        ([Microsoft.Win32.RegistryValueKind]::String)
}

function Invoke-TransactionRollback {
    param($BaseKey, $ConfigKey, $Receipt)
    $current = Get-OptionalStringState $ConfigKey 'CurrentIdentity'
    $isNew = $current.Present -and $current.Value -ceq $Receipt.NewIdentityId
    $isOld = $current.Present -eq $Receipt.PreviousPointerPresent -and
        (-not $current.Present -or $current.Value -ceq $Receipt.PreviousIdentityId)
    if (-not $isNew -and -not $isOld) { throw '回滚发现并发 CurrentIdentity，拒绝覆盖' }
    $mirror = Get-OptionalStringState $ConfigKey 'SpoofName'
    $mirrorIsOld = $mirror.Present -eq $Receipt.PreviousSpoofNamePresent -and
        (-not $mirror.Present -or $mirror.Value -ceq $Receipt.PreviousSpoofName)
    $mirrorIsNew = $mirror.Present -and $mirror.Value -ceq $Receipt.NewSpoofName
    if (-not $mirrorIsOld -and -not $mirrorIsNew) {
        throw '回滚发现第三方 SpoofName mirror，拒绝覆盖'
    }
    # 两个 journal 必须全部通过值级 CAS 后才允许首写，避免 Class 第三方修改
    # 导致 Enum 已回滚、Class 却拒绝的跨 journal 半恢复。
    Assert-ProjectionJournalCanRestore $BaseKey $Receipt.EnumJournal $Receipt.ProjectedEnum
    Assert-ProjectionJournalCanRestore $BaseKey $Receipt.ClassJournal $Receipt.ProjectedClass
    Restore-ProjectionJournal $BaseKey $Receipt.EnumJournal $Receipt.ProjectedEnum -PreflightComplete
    Restore-ProjectionJournal $BaseKey $Receipt.ClassJournal $Receipt.ProjectedClass -PreflightComplete
    if ($Receipt.PreviousSpoofNamePresent) {
        $ConfigKey.SetValue('SpoofName', $Receipt.PreviousSpoofName,
            [Microsoft.Win32.RegistryValueKind]::String)
    } else { $ConfigKey.DeleteValue('SpoofName', $false) }
    $ConfigKey.Flush()
    Assert-RegistryState $ConfigKey 'SpoofName' $Receipt.PreviousSpoofNamePresent `
        $Receipt.PreviousSpoofName ([Microsoft.Win32.RegistryValueKind]::String)
    if ($isNew) {
        Set-CurrentIdentityPointer $ConfigKey $current `
            $Receipt.PreviousPointerPresent $Receipt.PreviousIdentityId
    }
    if ($Receipt.State -cne 'RolledBack') {
        Set-TransactionState $ConfigKey $Receipt.NewIdentityId $Receipt.State 'RolledBack'
    }
    Clear-PendingIdentity $ConfigKey $Receipt.NewIdentityId
}

function Invoke-WithIdentityWriterLock {
    param([scriptblock]$Body)
    $mutex = New-Object System.Threading.Mutex($false, 'Global\StealthGPU-IdentityWriter')
    $held = $false
    try {
        try { $held = $mutex.WaitOne(30000) }
        catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw '等待 StealthGPU 身份写锁超时（30 秒）' }
        return & $Body
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Open-StealthBaseKey {
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
}

function Get-RootScheduledTaskExact {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    # 完整枚举失败必须硬抛；不能用 SilentlyContinue 把 CIM/Task Scheduler 故障
    # 误判成“不存在”。只有一次成功枚举中确实没有根目录同名项才返回 null。
    $matches = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
            [string]$_.TaskPath -ieq '\' -and [string]$_.TaskName -ieq $TaskName
        })
    if ($matches.Count -gt 1) { throw ('根目录存在多个同名计划任务：' + $TaskName) }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Invoke-LegacyGpuTaskBarrier {
    # 旧版 SYSTEM refresh 不认识当前身份 mutex；若它在 rollback journal 恢复中途
    # 写 Class/Enum，下一次 Stage 会把混合状态记录成“原值”。Recover 因此必须先
    # 阻止新触发、停止活动实例、确认退出，再删除定义并复读不存在。
    foreach ($taskName in 'StealthGPU-RefreshName', 'StealthGPU-ForceDisplayFreq') {
        $task = Get-RootScheduledTaskExact -TaskName $taskName
        if ($null -eq $task) { continue }

        Disable-ScheduledTask -TaskName $taskName -TaskPath '\' `
            -ErrorAction Stop | Out-Null
        Stop-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 100
            $task = Get-RootScheduledTaskExact -TaskName $taskName
        } while ($null -ne $task -and [string]$task.State -imatch '^(Running|Queued)$' -and
            [DateTime]::UtcNow -lt $deadline)
        if ($null -ne $task -and [string]$task.State -imatch '^(Running|Queued)$') {
            throw ('旧 GPU 任务停止超时：' + $taskName + '（当前=' +
                [string]$task.State + '）')
        }
        if ($null -ne $task -and [bool]$task.Settings.Enabled) {
            throw ('旧 GPU 任务停止后仍可触发：' + $taskName)
        }
        if ($null -ne $task) {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' `
                -Confirm:$false -ErrorAction Stop
        }
        if ($null -ne (Get-RootScheduledTaskExact -TaskName $taskName)) {
            throw ('旧 GPU 任务删除后仍可见：' + $taskName)
        }
    }
}

function Invoke-RecoverOrRollback {
    param([string]$RequestedIdentity, [switch]$Recover)
    if ($Recover) { Invoke-LegacyGpuTaskBarrier }
    return Invoke-WithIdentityWriterLock {
        $baseKey = Open-StealthBaseKey; $configKey = $null
        try {
            $configKey = $baseKey.OpenSubKey('SOFTWARE\StealthGPU', $true)
            if ($null -eq $configKey) {
                if ($Recover) { return $null }
                throw '缺少 StealthGPU 身份根键'
            }
            $pending = Get-OptionalStringState $configKey 'PendingIdentity'
            if (-not $pending.Present) {
                if ($Recover) { return $null }
                $done = Read-TransactionReceipt $configKey $RequestedIdentity
                if (@('Completed','RolledBack') -ccontains $done.State) { return $done }
                throw '事务仍未完成但 PendingIdentity 缺失'
            }
            Assert-IdentityToken $pending.Value 'PendingIdentity'
            if (-not $Recover -and $pending.Value -cne $RequestedIdentity) {
                throw '请求回滚的身份与 PendingIdentity 不一致'
            }
            $receipt = Read-TransactionReceipt $configKey $pending.Value
            if ($receipt.State -ceq 'Completed') {
                $current = Get-OptionalStringState $configKey 'CurrentIdentity'
                if (-not $current.Present -or $current.Value -cne $receipt.NewIdentityId) {
                    throw 'Completed 事务的 CurrentIdentity 不一致'
                }
                Clear-PendingIdentity $configKey $receipt.NewIdentityId
                return [pscustomobject]@{ Action='Completed'; IdentityId=$receipt.NewIdentityId }
            }
            Invoke-TransactionRollback $baseKey $configKey $receipt
            return [pscustomobject]@{ Action='RolledBack'; IdentityId=$receipt.NewIdentityId }
        } finally {
            if ($null -ne $configKey) { $configKey.Dispose() }
            $baseKey.Dispose()
        }
    }
}

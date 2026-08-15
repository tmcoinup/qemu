#Requires -Version 5.1

<#
.SYNOPSIS
    生成并事务应用 Hyper-V 虚拟机固件身份。

.DESCRIPTION
    本模块只处理 Msvm_VirtualSystemSettingData 官方公开的五个固件字段。身份的
    长期持久化由上层 identity.json 的 HardwareIdentity 嵌套对象负责；本文件
    不拥有清单，也不修改注册表或客机文件。写入只允许在 VM Off 状态执行，
    并在失败时回滚原值。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:VMateHyperVFirmwareNamespace = 'root\virtualization\v2'
$script:VMateHyperVFirmwareFields = @(
    'BIOSGUID',
    'BIOSSerialNumber',
    'BaseBoardSerialNumber',
    'ChassisSerialNumber',
    'ChassisAssetTag'
)

function New-VMateHyperVFirmwareRandomBytes {
    param([ValidateRange(1, 128)][int]$ByteCount)

    $bytes = New-Object byte[] $ByteCount
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    return ,$bytes
}

function ConvertTo-VMateHyperVFirmwareHex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    return ([BitConverter]::ToString($Bytes)).Replace('-', '')
}

function New-VMateHyperVFirmwareGuid {
    [CmdletBinding()]
    param()

    [byte[]]$bytes = New-VMateHyperVFirmwareRandomBytes -ByteCount 16
    # 按 RFC 4122 设置 version 4 和 variant 位；其余 122 位都来自 CSPRNG。
    $bytes[6] = [byte](($bytes[6] -band 0x0f) -bor 0x40)
    $bytes[8] = [byte](($bytes[8] -band 0x3f) -bor 0x80)
    $hex = ConvertTo-VMateHyperVFirmwareHex -Bytes $bytes
    $text = '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8),
        $hex.Substring(8, 4), $hex.Substring(12, 4),
        $hex.Substring(16, 4), $hex.Substring(20, 12)
    $guid = [Guid]::Parse($text)
    return '{' + $guid.ToString('D').ToUpperInvariant() + '}'
}

function New-VMateHyperVFirmwareSerial {
    [CmdletBinding()]
    param()

    # 128-bit 随机值仍远低于 SMBIOS 64 字符上限，并降低大规模清单碰撞概率。
    $bytes = New-VMateHyperVFirmwareRandomBytes -ByteCount 16
    return ConvertTo-VMateHyperVFirmwareHex -Bytes $bytes
}

function New-VMateHyperVFirmwareIdentityFragment {
    [CmdletBinding()]
    param()

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        IdentityKind = 'HyperVFirmwareVssd'
        BIOSGUID = New-VMateHyperVFirmwareGuid
        BIOSSerialNumber = New-VMateHyperVFirmwareSerial
        BaseBoardSerialNumber = New-VMateHyperVFirmwareSerial
        ChassisSerialNumber = New-VMateHyperVFirmwareSerial
        ChassisAssetTag = New-VMateHyperVFirmwareSerial
    }
}

function Get-VMateHyperVFirmwareProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Label = '固件身份对象'
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "$Label 缺少 $Name 属性。"
    }
    return $property.Value
}

function ConvertTo-VMateHyperVFirmwareIdentityFragment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Identity)

    $schema = Get-VMateHyperVFirmwareProperty $Identity 'SchemaVersion'
    $kind = [string](Get-VMateHyperVFirmwareProperty $Identity 'IdentityKind')
    if ([int]$schema -ne 1 -or $kind -cne 'HyperVFirmwareVssd') {
        throw 'Hyper-V 固件身份 fragment 的 schema 或类型不受支持。'
    }

    $guidText = [string](Get-VMateHyperVFirmwareProperty $Identity 'BIOSGUID')
    $biosGuid = [Guid]::Empty
    if (-not [Guid]::TryParse($guidText, [ref]$biosGuid) -or
        $biosGuid -eq [Guid]::Empty) {
        throw 'Hyper-V 固件身份 BIOSGUID 无效。'
    }

    $serials = [ordered]@{}
    foreach ($name in $script:VMateHyperVFirmwareFields[1..4]) {
        $value = [string](Get-VMateHyperVFirmwareProperty $Identity $name)
        if ($value -notmatch '^[0-9a-fA-F]{32}$') {
            throw "Hyper-V 固件身份 $name 必须是 32 位十六进制字符串。"
        }
        $serials[$name] = $value.ToUpperInvariant()
    }
    if (@($serials.Values | Select-Object -Unique).Count -ne 4) {
        throw 'Hyper-V 固件身份的四个序列字段不能重复。'
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        IdentityKind = 'HyperVFirmwareVssd'
        BIOSGUID = '{' + $biosGuid.ToString('D').ToUpperInvariant() + '}'
        BIOSSerialNumber = $serials.BIOSSerialNumber
        BaseBoardSerialNumber = $serials.BaseBoardSerialNumber
        ChassisSerialNumber = $serials.ChassisSerialNumber
        ChassisAssetTag = $serials.ChassisAssetTag
    }
}

function Get-VMateHyperVFirmwareIdentitySnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Vssd)

    $snapshot = [ordered]@{}
    foreach ($name in $script:VMateHyperVFirmwareFields) {
        $snapshot[$name] = [string](
            Get-VMateHyperVFirmwareProperty $Vssd $name 'Hyper-V 当前 VSSD')
    }
    return [pscustomobject]$snapshot
}

function Test-VMateHyperVFirmwareIdentityMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][object]$Expected
    )

    foreach ($name in $script:VMateHyperVFirmwareFields) {
        $actualValue = [string](Get-VMateHyperVFirmwareProperty $Actual $name)
        $expectedValue = [string](Get-VMateHyperVFirmwareProperty $Expected $name)
        if ($name -ceq 'BIOSGUID') {
            $actualGuid = [Guid]::Empty
            $expectedGuid = [Guid]::Empty
            if (-not [Guid]::TryParse($actualValue, [ref]$actualGuid) -or
                -not [Guid]::TryParse($expectedValue, [ref]$expectedGuid) -or
                $actualGuid -ne $expectedGuid) {
                return $false
            }
        }
        elseif ($actualValue -cne $expectedValue) {
            return $false
        }
    }
    return $true
}

function Test-VMateHyperVFirmwareIdentityExactMatch {
    param(
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][object]$Expected
    )

    foreach ($name in $script:VMateHyperVFirmwareFields) {
        $actualValue = [string](Get-VMateHyperVFirmwareProperty $Actual $name)
        $expectedValue = [string](Get-VMateHyperVFirmwareProperty $Expected $name)
        if ($actualValue -cne $expectedValue) { return $false }
    }
    return $true
}

function Set-VMateHyperVFirmwareVssdIdentityValues {
    param(
        [Parameter(Mandatory = $true)][object]$Vssd,
        [Parameter(Mandatory = $true)][object]$Identity
    )

    foreach ($name in $script:VMateHyperVFirmwareFields) {
        [void](Get-VMateHyperVFirmwareProperty $Vssd $name 'Hyper-V 当前 VSSD')
        $Vssd.$name = [string](Get-VMateHyperVFirmwareProperty $Identity $name)
    }
    return $Vssd
}

function Get-VMateHyperVFirmwareComputerSystem {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Guid]$VMId)

    $systems = @(Get-WmiObject -Namespace $script:VMateHyperVFirmwareNamespace `
            -Class Msvm_ComputerSystem `
            -Filter "Name='$($VMId.ToString('D'))'" -ErrorAction Stop)
    if ($systems.Count -ne 1) {
        throw "无法唯一解析 VMId $VMId 的 Msvm_ComputerSystem。"
    }
    return $systems[0]
}

function Assert-VMateHyperVFirmwareVmOff {
    param([Parameter(Mandatory = $true)][object]$ComputerSystem)

    $state = [uint16](Get-VMateHyperVFirmwareProperty $ComputerSystem `
            'EnabledState' 'Msvm_ComputerSystem')
    if ($state -ne 3) {
        throw "固件身份只能在 VM Off 状态应用；EnabledState=$state。"
    }
}

function Get-VMateHyperVFirmwareVssd {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Guid]$VMId)

    $system = Get-VMateHyperVFirmwareComputerSystem -VMId $VMId
    $relativePath = [string](Get-VMateHyperVFirmwareProperty $system `
            '__RELPATH' 'Msvm_ComputerSystem')
    $query = 'ASSOCIATORS OF {' + $relativePath + '} WHERE ' +
        'AssocClass=Msvm_SettingsDefineState ' +
        'ResultClass=Msvm_VirtualSystemSettingData'
    $allSettings = @(Get-WmiObject `
            -Namespace $script:VMateHyperVFirmwareNamespace `
            -Query $query -ErrorAction Stop)
    $current = @($allSettings | Where-Object {
            [string]$_.VirtualSystemType -ceq
                'Microsoft:Hyper-V:System:Realized'
        })
    if ($current.Count -ne 1) {
        throw "无法唯一解析 VMId $VMId 的当前 realized VSSD。"
    }
    return $current[0]
}

function ConvertTo-VMateHyperVFirmwareJobPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $index = $Path.IndexOf(
        'Msvm_ConcreteJob.', [StringComparison]::OrdinalIgnoreCase)
    if ($index -ge 0) {
        return $Path.Substring($index).ToLowerInvariant()
    }
    return $Path.Trim().ToLowerInvariant()
}

function Get-VMateHyperVFirmwareWmiJob {
    param([Parameter(Mandatory = $true)][string]$JobReference)

    $expected = ConvertTo-VMateHyperVFirmwareJobPath $JobReference
    foreach ($job in @(Get-WmiObject `
            -Namespace $script:VMateHyperVFirmwareNamespace `
            -Class Msvm_ConcreteJob -ErrorAction Stop)) {
        foreach ($propertyName in @('__PATH', '__RELPATH')) {
            $property = $job.PSObject.Properties[$propertyName]
            if ($null -ne $property -and
                (ConvertTo-VMateHyperVFirmwareJobPath `
                    ([string]$property.Value)) -ceq $expected) {
                return $job
            }
        }
    }
    return $null
}

function Wait-VMateHyperVFirmwareWmiJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobReference,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 60
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $job = Get-VMateHyperVFirmwareWmiJob -JobReference $JobReference
        if ($null -ne $job) {
            $state = [uint16](Get-VMateHyperVFirmwareProperty $job `
                    'JobState' 'Msvm_ConcreteJob')
            if ($state -eq 7) {
                $errorCodeProperty = $job.PSObject.Properties['ErrorCode']
                $errorCode = if ($null -eq $errorCodeProperty -or
                    $null -eq $errorCodeProperty.Value) { 0 } else {
                    [uint32]$errorCodeProperty.Value
                }
                if ($errorCode -ne 0) {
                    throw "Hyper-V 异步 Job 完成但 ErrorCode=$errorCode。"
                }
                return $job
            }
            if ($state -in @(8, 9, 10)) {
                $descriptionProperty =
                    $job.PSObject.Properties['ErrorDescription']
                $description = if ($null -eq $descriptionProperty) {
                    ''
                } else { [string]$descriptionProperty.Value }
                throw "Hyper-V 异步 Job 失败；JobState=$state；$description"
            }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "等待 Hyper-V 异步 Job 超过 ${TimeoutSeconds}s：$JobReference"
}

function Complete-VMateHyperVFirmwareWmiOperation {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [ValidateRange(1, 300)][int]$JobTimeoutSeconds = 60
    )

    $returnValue = [uint32](Get-VMateHyperVFirmwareProperty $Result `
            'ReturnValue' 'ModifySystemSettings 返回值')
    if ($returnValue -eq 0) {
        return
    }
    if ($returnValue -eq 4096) {
        $jobReference = [string](Get-VMateHyperVFirmwareProperty $Result `
                'Job' 'ModifySystemSettings 返回值')
        if ([String]::IsNullOrWhiteSpace($jobReference)) {
            throw 'ModifySystemSettings 返回异步状态但没有 Job 引用。'
        }
        Wait-VMateHyperVFirmwareWmiJob -JobReference $jobReference `
            -TimeoutSeconds $JobTimeoutSeconds | Out-Null
        return
    }
    throw "Hyper-V ModifySystemSettings 失败；ReturnValue=$returnValue。"
}

function Invoke-VMateHyperVFirmwareWmiModify {
    param(
        [Parameter(Mandatory = $true)][object]$Vssd,
        [ValidateRange(1, 300)][int]$JobTimeoutSeconds = 60
    )

    $services = @(Get-WmiObject `
            -Namespace $script:VMateHyperVFirmwareNamespace `
            -Class Msvm_VirtualSystemManagementService -ErrorAction Stop)
    if ($services.Count -ne 1) {
        throw '无法唯一解析 Msvm_VirtualSystemManagementService。'
    }
    $payload = $Vssd.GetText(1)
    $result = $services[0].ModifySystemSettings($payload)
    Complete-VMateHyperVFirmwareWmiOperation -Result $result `
        -JobTimeoutSeconds $JobTimeoutSeconds
}

function Enter-VMateHyperVFirmwareIdentityLock {
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )

    $name = 'Global\VMate.HyperV.FirmwareIdentity.' + $VMId.ToString('N')
    $mutex = [Threading.Mutex]::new($false, $name)
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            throw "等待 Hyper-V 固件身份锁超过 ${TimeoutSeconds}s。"
        }
        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-VMateHyperVFirmwareIdentityLock {
    param([Parameter(Mandatory = $true)][Threading.Mutex]$Mutex)

    try { $Mutex.ReleaseMutex() }
    finally { $Mutex.Dispose() }
}

function Restore-VMateHyperVFirmwareIdentitySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [ValidateRange(1, 300)][int]$JobTimeoutSeconds = 60
    )

    # 快照可能来自 Hyper-V 默认值，不应套用新 fragment 的 32-hex 格式约束。
    $desired = Get-VMateHyperVFirmwareIdentitySnapshot -Vssd $Snapshot
    $mutex = Enter-VMateHyperVFirmwareIdentityLock -VMId $VMId
    try {
        $system = Get-VMateHyperVFirmwareComputerSystem -VMId $VMId
        Assert-VMateHyperVFirmwareVmOff -ComputerSystem $system
        $before = Get-VMateHyperVFirmwareIdentitySnapshot `
            (Get-VMateHyperVFirmwareVssd -VMId $VMId)
        if (Test-VMateHyperVFirmwareIdentityExactMatch $before $desired) {
            return [pscustomobject][ordered]@{
                Status = 'Unchanged'; VMId = $VMId.ToString('D')
                Requested = $desired; Previous = $before; Observed = $before
            }
        }

        $target = Get-VMateHyperVFirmwareVssd -VMId $VMId
        Set-VMateHyperVFirmwareVssdIdentityValues $target $desired | Out-Null
        Invoke-VMateHyperVFirmwareWmiModify -Vssd $target `
            -JobTimeoutSeconds $JobTimeoutSeconds
        $observed = Get-VMateHyperVFirmwareIdentitySnapshot `
            (Get-VMateHyperVFirmwareVssd -VMId $VMId)
        if (-not (Test-VMateHyperVFirmwareIdentityExactMatch `
                $observed $desired)) {
            throw '恢复后固件身份快照回读不一致。'
        }
        return [pscustomobject][ordered]@{
            Status = 'Restored'; VMId = $VMId.ToString('D')
            Requested = $desired; Previous = $before; Observed = $observed
        }
    }
    finally {
        Exit-VMateHyperVFirmwareIdentityLock -Mutex $mutex
    }
}

function Invoke-VMateHyperVFirmwareIdentityTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [Parameter(Mandatory = $true)][object]$Identity,
        [ValidateRange(1, 300)][int]$JobTimeoutSeconds = 60,
        [ValidateRange(1, 120)][int]$LockTimeoutSeconds = 30
    )

    $requested = ConvertTo-VMateHyperVFirmwareIdentityFragment $Identity
    $mutex = Enter-VMateHyperVFirmwareIdentityLock -VMId $VMId `
        -TimeoutSeconds $LockTimeoutSeconds
    try {
        $system = Get-VMateHyperVFirmwareComputerSystem -VMId $VMId
        Assert-VMateHyperVFirmwareVmOff -ComputerSystem $system
        $before = Get-VMateHyperVFirmwareIdentitySnapshot `
            (Get-VMateHyperVFirmwareVssd -VMId $VMId)
        if (Test-VMateHyperVFirmwareIdentityMatch $before $requested) {
            return [pscustomobject][ordered]@{
                Status = 'Unchanged'; VMId = $VMId.ToString('D')
                Requested = $requested; Previous = $before; Observed = $before
            }
        }

        $mutationStarted = $false
        try {
            $target = Get-VMateHyperVFirmwareVssd -VMId $VMId
            Set-VMateHyperVFirmwareVssdIdentityValues $target $requested |
                Out-Null
            $mutationStarted = $true
            Invoke-VMateHyperVFirmwareWmiModify -Vssd $target `
                -JobTimeoutSeconds $JobTimeoutSeconds
            $observed = Get-VMateHyperVFirmwareIdentitySnapshot `
                (Get-VMateHyperVFirmwareVssd -VMId $VMId)
            if (-not (Test-VMateHyperVFirmwareIdentityMatch `
                    $observed $requested)) {
                throw 'ModifySystemSettings 后固件身份回读不一致。'
            }
            return [pscustomobject][ordered]@{
                Status = 'Applied'; VMId = $VMId.ToString('D')
                Requested = $requested; Previous = $before
                Observed = $observed
            }
        }
        catch {
            $applyError = $_.Exception.Message
            if (-not $mutationStarted) { throw }
            try {
                Restore-VMateHyperVFirmwareIdentitySnapshot -VMId $VMId `
                    -Snapshot $before -JobTimeoutSeconds $JobTimeoutSeconds |
                    Out-Null
            }
            catch {
                throw "固件身份应用失败且回滚失败；应用错误：$applyError；" +
                    "回滚错误：$($_.Exception.Message)"
            }
            throw "固件身份应用失败，已回滚原值：$applyError"
        }
    }
    finally {
        Exit-VMateHyperVFirmwareIdentityLock -Mutex $mutex
    }
}

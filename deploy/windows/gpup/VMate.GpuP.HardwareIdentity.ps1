#Requires -Version 5.1

<#
.SYNOPSIS
    持久化并应用 P-11 Hyper-V 官方支持的每 VM 硬件身份。

.DESCRIPTION
    本模块把固件五字段和静态 MAC 作为 identity.json 的 HardwareIdentity
    子记录保存。可在首次创建时显式提供值，未提供的字段使用 CSPRNG；重试、
    重启和 GPU 驱动更新都复用同一记录。GPU/CPU 品牌及 DIMM/控制器身份只读。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.GpuP.Identity.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.FirmwareIdentity.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.NetworkIdentity.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.GuestIdentity.ps1')

$script:VMateGpuPHardwareSerialFields = @(
    'BIOSSerialNumber',
    'BaseBoardSerialNumber',
    'ChassisSerialNumber',
    'ChassisAssetTag'
)

function Resolve-VMateGpuPFirmwareIdentity {
    param([AllowNull()][object]$Overrides)

    $fragment = New-VMateHyperVFirmwareIdentityFragment
    if ($null -ne $Overrides) {
        foreach ($name in $script:VMateHyperVFirmwareFields) {
            $property = $Overrides.PSObject.Properties[$name]
            if ($null -ne $property -and
                -not [String]::IsNullOrWhiteSpace([string]$property.Value)) {
                $fragment.$name = [string]$property.Value
            }
        }
    }
    return ConvertTo-VMateHyperVFirmwareIdentityFragment $fragment
}

function Get-VMateGpuPHardwareProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Label = 'HardwareIdentity'
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Label 缺少 $Name 属性。" }
    return $property.Value
}

function ConvertTo-VMateGpuPHardwareNetworkFragment {
    param([Parameter(Mandatory = $true)][object]$HardwareIdentity)

    $fragment = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Status = [string](Get-VMateGpuPHardwareProperty `
                $HardwareIdentity 'NetworkStatus')
        NetworkAdapters = @((Get-VMateGpuPHardwareProperty `
                    $HardwareIdentity 'NetworkAdapters'))
    }
    Assert-VMateHyperVNetworkIdentityFragment $fragment
    return $fragment
}

function ConvertTo-VMateGpuPHardwareIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$HardwareIdentity)

    if ([int](Get-VMateGpuPHardwareProperty `
            $HardwareIdentity 'SchemaVersion') -ne 1) {
        throw 'HardwareIdentity schema 不受支持。'
    }
    if ([string](Get-VMateGpuPHardwareProperty `
            $HardwareIdentity 'PersistencePolicy') -cne
        'generate-once-no-reroll') {
        throw 'HardwareIdentity 持久化策略无效。'
    }
    $state = [string](Get-VMateGpuPHardwareProperty $HardwareIdentity 'State')
    if ($state -notin @('Prepared', 'Applied')) {
        throw "HardwareIdentity 状态无效：$state"
    }
    $firmware = ConvertTo-VMateHyperVFirmwareIdentityFragment `
        (Get-VMateGpuPHardwareProperty $HardwareIdentity 'Firmware')
    $network = ConvertTo-VMateGpuPHardwareNetworkFragment $HardwareIdentity
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        PersistencePolicy = 'generate-once-no-reroll'
        State = $state
        Firmware = $firmware
        NetworkStatus = [string]$network.Status
        NetworkAdapters = @($network.NetworkAdapters)
        HostObserved = Get-VMateGpuPHardwareProperty `
            $HardwareIdentity 'HostObserved'
        GuestObserved = Get-VMateGpuPHardwareProperty `
            $HardwareIdentity 'GuestObserved'
        CreatedAtUtc = [string](Get-VMateGpuPHardwareProperty `
                $HardwareIdentity 'CreatedAtUtc')
        AppliedAtUtc = [string](Get-VMateGpuPHardwareProperty `
                $HardwareIdentity 'AppliedAtUtc')
    }
}

function Get-VMateGpuPHardwareIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [string]$StateRoot = ''
    )

    $identity = Get-VMateGpuPIdentity -VMId $VMId -StateRoot $StateRoot
    if ($null -eq $identity) { return $null }
    $property = $identity.PSObject.Properties['HardwareIdentity']
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    return ConvertTo-VMateGpuPHardwareIdentity $property.Value
}

function Get-VMateGpuPHardwareRecords {
    param([string]$StateRoot = '')

    if ([String]::IsNullOrWhiteSpace($StateRoot)) {
        $StateRoot = Get-VMateGpuPDefaultStateRoot
    }
    if (-not (Test-Path -LiteralPath $StateRoot -PathType Container)) {
        return @()
    }
    $records = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $StateRoot `
            -Filter identity.json -File -Recurse -ErrorAction Stop)) {
        $identity = Read-VMateGpuPIdentityManifest -Path $file.FullName
        $property = $identity.PSObject.Properties['HardwareIdentity']
        if ($null -eq $property) { continue }
        if ($null -eq $property.Value) {
            throw "HardwareIdentity 为空：$($file.FullName)"
        }
        [void]$records.Add([pscustomobject][ordered]@{
                VMId = [string]$identity.VMId
                HardwareIdentity = ConvertTo-VMateGpuPHardwareIdentity `
                    $property.Value
                SourcePath = $file.FullName
            })
    }
    return @($records)
}

function Assert-VMateGpuPHardwareIdentityAvailable {
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [Parameter(Mandatory = $true)][object]$HardwareIdentity,
        [string]$StateRoot = ''
    )

    $candidate = ConvertTo-VMateGpuPHardwareIdentity $HardwareIdentity
    foreach ($record in @(Get-VMateGpuPHardwareRecords $StateRoot)) {
        if ([string]$record.VMId -ieq $VMId.ToString('D')) { continue }
        if ([string]$record.HardwareIdentity.Firmware.BIOSGUID -ieq
            [string]$candidate.Firmware.BIOSGUID) {
            throw "BIOSGUID 已被另一台 P-11 VM 占用。"
        }
        $existingSerials = @($script:VMateGpuPHardwareSerialFields |
            ForEach-Object { [string]$record.HardwareIdentity.Firmware.$_ })
        foreach ($field in $script:VMateGpuPHardwareSerialFields) {
            if ([string]$candidate.Firmware.$field -iin $existingSerials) {
                throw "$field 已被另一台 P-11 VM 占用。"
            }
        }
    }
}

function Initialize-VMateGpuPHardwareIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [string]$StateRoot = '',
        [AllowNull()][object]$FirmwareIdentity = $null,
        [string]$StaticMacAddress = ''
    )

    if ([string]$VM.State -cne 'Off') {
        throw 'VM 必须为 Off 才能初始化持久硬件身份。'
    }
    $vmId = [Guid]$VM.Id
    # 与 MAC 分配器使用同一全局锁，保证“扫描全部清单 -> 生成 -> 发布”
    # 是一个原子分配区间；per-VM 锁只保护单份 identity.json 的 RMW。
    $allocator = Enter-VMateHyperVNetworkIdentityAllocator
    try {
        $identityLock = Enter-VMateGpuPIdentityLock -VMId $vmId
        try {
            $path = Get-VMateGpuPIdentityPath -VMId $vmId `
                -StateRoot $StateRoot
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "GPU-P 身份清单不存在：$path"
            }
            $identity = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            Assert-VMateGpuPIdentityRecord $identity $vmId | Out-Null
            $existing = $identity.PSObject.Properties['HardwareIdentity']
            if ($null -ne $existing -and $null -ne $existing.Value) {
                $current = ConvertTo-VMateGpuPHardwareIdentity $existing.Value
                if ($null -ne $FirmwareIdentity) {
                    $merged = $current.Firmware | Select-Object *
                    foreach ($name in $script:VMateHyperVFirmwareFields) {
                        $property = $FirmwareIdentity.PSObject.Properties[$name]
                        if ($null -ne $property -and -not
                            [String]::IsNullOrWhiteSpace(
                                [string]$property.Value)) {
                            $merged.$name = [string]$property.Value
                        }
                    }
                    $requested = Resolve-VMateGpuPFirmwareIdentity $merged
                    if (-not (Test-VMateHyperVFirmwareIdentityMatch `
                            $current.Firmware $requested)) {
                        throw 'VM 已有不同的持久固件身份，拒绝重新抽取或覆盖。'
                    }
                }
                if (-not [String]::IsNullOrWhiteSpace($StaticMacAddress)) {
                    $requestedMac = Assert-VMateHyperVLocalUnicastMacAddress `
                        $StaticMacAddress
                    if (@($current.NetworkAdapters).Count -ne 1 -or
                        [string]$current.NetworkAdapters[0].StaticMacAddress `
                            -cne $requestedMac) {
                        throw 'VM 已有不同的持久静态 MAC，拒绝覆盖。'
                    }
                }
                Assert-VMateGpuPHardwareIdentityAvailable $vmId $current `
                    $StateRoot
                return $current
            }

            $network = New-VMateHyperVNetworkIdentityFragment -VM $VM `
                -StateRoot $StateRoot
            if (-not [String]::IsNullOrWhiteSpace($StaticMacAddress)) {
                if (@($network.NetworkAdapters).Count -ne 1) {
                    throw '显式 StaticMacAddress 要求 VM 恰好有一张虚拟网卡。'
                }
                $network.NetworkAdapters[0].StaticMacAddress =
                    Assert-VMateHyperVLocalUnicastMacAddress $StaticMacAddress
            }
            $record = [pscustomobject][ordered]@{
                SchemaVersion = 1
                PersistencePolicy = 'generate-once-no-reroll'
                State = 'Prepared'
                Firmware = Resolve-VMateGpuPFirmwareIdentity $FirmwareIdentity
                NetworkStatus = [string]$network.Status
                NetworkAdapters = @($network.NetworkAdapters)
                HostObserved = $null
                GuestObserved = $null
                CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
                AppliedAtUtc = ''
            }
            Assert-VMateGpuPHardwareIdentityAvailable $vmId $record $StateRoot
            $identity | Add-Member -NotePropertyName HardwareIdentity `
                -NotePropertyValue $record
            $identity.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
            Write-VMateGpuPAtomicJson $identity $path | Out-Null
            return ConvertTo-VMateGpuPHardwareIdentity $record
        }
        finally { Exit-VMateGpuPIdentityLock -Mutex $identityLock }
    }
    finally { Exit-VMateHyperVNetworkIdentityAllocator -Mutex $allocator }
}

function Complete-VMateGpuPHardwareIdentity {
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [Parameter(Mandatory = $true)][object]$HostObserved,
        [string]$StateRoot = ''
    )

    $identityLock = Enter-VMateGpuPIdentityLock -VMId $VMId
    try {
        $path = Get-VMateGpuPIdentityPath $VMId $StateRoot
        $identity = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        Assert-VMateGpuPIdentityRecord $identity $VMId | Out-Null
        $hardwareProperty = $identity.PSObject.Properties['HardwareIdentity']
        if ($null -eq $hardwareProperty -or $null -eq $hardwareProperty.Value) {
            throw 'HardwareIdentity 在应用期间消失。'
        }
        $hardware = ConvertTo-VMateGpuPHardwareIdentity $hardwareProperty.Value
        $hardware.State = 'Applied'
        $hardware.HostObserved = $HostObserved
        $hardware.AppliedAtUtc = [DateTime]::UtcNow.ToString('o')
        $hardwareProperty.Value = $hardware
        $identity.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
        Write-VMateGpuPAtomicJson $identity $path | Out-Null
        return $hardware
    }
    finally { Exit-VMateGpuPIdentityLock -Mutex $identityLock }
}

function Set-VMateGpuPGuestObservedHardwareIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [Parameter(Mandatory = $true)][object]$GuestObserved,
        [string]$StateRoot = ''
    )

    $identityLock = Enter-VMateGpuPIdentityLock -VMId $VMId
    try {
        $path = Get-VMateGpuPIdentityPath $VMId $StateRoot
        $identity = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        Assert-VMateGpuPIdentityRecord $identity $VMId | Out-Null
        $hardwareProperty = $identity.PSObject.Properties['HardwareIdentity']
        if ($null -eq $hardwareProperty -or $null -eq $hardwareProperty.Value) {
            throw 'HardwareIdentity 在 guest 回读期间消失。'
        }
        $hardware = ConvertTo-VMateGpuPHardwareIdentity $hardwareProperty.Value
        if ([string]$hardware.State -cne 'Applied') {
            throw '只有 Applied 硬件身份可以保存 GuestObserved。'
        }
        $verified = Test-VMateGpuPGuestHardwareIdentityMatch `
            -Expected $hardware -Observed $GuestObserved
        if (-not [bool]$verified.Match) {
            throw ('guest 硬件身份回读不一致：' +
                (@($verified.Mismatches) -join ', '))
        }
        $hardware.GuestObserved = $verified
        $hardwareProperty.Value = $hardware
        $identity.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
        Write-VMateGpuPAtomicJson $identity $path | Out-Null
        return $hardware
    }
    finally { Exit-VMateGpuPIdentityLock -Mutex $identityLock }
}

function Ensure-VMateGpuPHardwareIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [string]$StateRoot = '',
        [AllowNull()][object]$FirmwareIdentity = $null,
        [string]$StaticMacAddress = '',
        [ValidateRange(1, 300)][int]$JobTimeoutSeconds = 60
    )

    if ([string]$VM.State -cne 'Off') {
        throw 'VM 必须为 Off 才能应用持久硬件身份。'
    }
    $hardware = Initialize-VMateGpuPHardwareIdentity -VM $VM `
        -StateRoot $StateRoot -FirmwareIdentity $FirmwareIdentity `
        -StaticMacAddress $StaticMacAddress
    $network = ConvertTo-VMateGpuPHardwareNetworkFragment $hardware
    # 先提交可重复修改、内部可回滚的 MAC，最后才写 Win10 上可能一次性的
    # BIOSGUID。任一失败都保留已经持久化的 Prepared 期望值；同参重试只会
    # 收敛到该记录，绝不重新抽取身份或尝试把 BIOSGUID 改回旧值。
    $networkResult = Set-VMateHyperVNetworkIdentity -VM $VM `
        -NetworkIdentity $network -StateRoot $StateRoot
    $firmwareResult = Invoke-VMateHyperVFirmwareIdentityTransaction `
        -VMId ([Guid]$VM.Id) -Identity $hardware.Firmware `
        -JobTimeoutSeconds $JobTimeoutSeconds
    $networkObserved = if ($null -ne $networkResult.PSObject.Properties[
            'Observed']) { $networkResult.Observed } else {
        Get-VMateHyperVNetworkIdentityObserved $VM $network
    }
    $observed = [pscustomobject][ordered]@{
        Firmware = $firmwareResult.Observed
        Network = $networkObserved
        Match = (Test-VMateHyperVFirmwareIdentityMatch `
                $firmwareResult.Observed $hardware.Firmware) -and
            [bool]$networkObserved.Match
    }
    if (-not $observed.Match) {
        throw 'Hyper-V 硬件身份最终回读不一致。'
    }
    $completed = Complete-VMateGpuPHardwareIdentity `
        -VMId ([Guid]$VM.Id) -HostObserved $observed -StateRoot $StateRoot
    return [pscustomobject][ordered]@{
        Status = [string]$completed.State
        VMId = ([Guid]$VM.Id).ToString('D')
        PersistencePolicy = [string]$completed.PersistencePolicy
        Desired = $completed
        HostObserved = $observed
    }
}

function Get-VMateGpuPHardwareIdentityStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [string]$StateRoot = ''
    )

    $hardware = Get-VMateGpuPHardwareIdentity `
        -VMId ([Guid]$VM.Id) -StateRoot $StateRoot
    if ($null -eq $hardware) {
        return [pscustomobject]@{ Status = 'Missing'; Match = $false }
    }
    $firmwareObserved = Get-VMateHyperVFirmwareIdentitySnapshot `
        (Get-VMateHyperVFirmwareVssd -VMId ([Guid]$VM.Id))
    $network = ConvertTo-VMateGpuPHardwareNetworkFragment $hardware
    $networkObserved = Get-VMateHyperVNetworkIdentityObserved $VM $network
    $match = (Test-VMateHyperVFirmwareIdentityMatch `
            $firmwareObserved $hardware.Firmware) -and $networkObserved.Match
    return [pscustomobject][ordered]@{
        Status = [string]$hardware.State
        Desired = $hardware
        HostObserved = [pscustomobject][ordered]@{
            Firmware = $firmwareObserved; Network = $networkObserved
        }
        Match = $match
    }
}

function Test-VMateGpuPHardwareIdentityUniqueness {
    [CmdletBinding()]
    param([string]$StateRoot = '')

    $records = @(Get-VMateGpuPHardwareRecords $StateRoot)
    $values = [Collections.Generic.List[object]]::new()
    foreach ($record in $records) {
        [void]$values.Add([pscustomobject]@{
                Field = 'BIOSGUID'; Value = $record.HardwareIdentity.Firmware.BIOSGUID
                VMId = $record.VMId })
        foreach ($field in $script:VMateGpuPHardwareSerialFields) {
            [void]$values.Add([pscustomobject]@{
                    Field = 'FirmwareSerial'; Value = $record.HardwareIdentity.Firmware.$field
                    VMId = $record.VMId })
        }
        foreach ($adapter in @($record.HardwareIdentity.NetworkAdapters)) {
            [void]$values.Add([pscustomobject]@{
                    Field = 'StaticMacAddress'; Value = $adapter.StaticMacAddress
                    VMId = $record.VMId })
        }
    }
    $collisions = @($values | Group-Object Field, Value |
        Where-Object Count -gt 1 | ForEach-Object {
            [pscustomobject]@{ Key = [string]$_.Name; Count = [int]$_.Count }
        })
    return [pscustomobject][ordered]@{
        IsUnique = $collisions.Count -eq 0
        Records = $records.Count
        Collisions = $collisions
    }
}

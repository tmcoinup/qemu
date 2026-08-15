#Requires -Version 5.1

<#
.SYNOPSIS
    持久化并应用 P-11 Hyper-V 官方支持的每 VM 硬件身份。

.DESCRIPTION
    本模块把固件五字段和静态 MAC 作为 identity.json 的 HardwareIdentity
    子记录保存。随机值只在首次创建时生成；重试、重启和 GPU 驱动更新都复用
    同一记录。GPU/CPU/DIMM/控制器身份不在本模块的可写范围内。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.GpuP.Identity.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.FirmwareIdentity.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.NetworkIdentity.ps1')

$script:VMateGpuPHardwareSerialFields = @(
    'BIOSSerialNumber',
    'BaseBoardSerialNumber',
    'ChassisSerialNumber',
    'ChassisAssetTag'
)

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
        [string]$StateRoot = ''
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
                Assert-VMateGpuPHardwareIdentityAvailable $vmId $current `
                    $StateRoot
                return $current
            }

            $network = New-VMateHyperVNetworkIdentityFragment -VM $VM `
                -StateRoot $StateRoot
            $record = [pscustomobject][ordered]@{
                SchemaVersion = 1
                PersistencePolicy = 'generate-once-no-reroll'
                State = 'Prepared'
                Firmware = New-VMateHyperVFirmwareIdentityFragment
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

function Ensure-VMateGpuPHardwareIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [string]$StateRoot = '',
        [ValidateRange(1, 300)][int]$JobTimeoutSeconds = 60
    )

    if ([string]$VM.State -cne 'Off') {
        throw 'VM 必须为 Off 才能应用持久硬件身份。'
    }
    $hardware = Initialize-VMateGpuPHardwareIdentity -VM $VM `
        -StateRoot $StateRoot
    $network = ConvertTo-VMateGpuPHardwareNetworkFragment $hardware
    $firmwareResult = Invoke-VMateHyperVFirmwareIdentityTransaction `
        -VMId ([Guid]$VM.Id) -Identity $hardware.Firmware `
        -JobTimeoutSeconds $JobTimeoutSeconds
    try {
        $networkResult = Set-VMateHyperVNetworkIdentity -VM $VM `
            -NetworkIdentity $network -StateRoot $StateRoot
    }
    catch {
        $networkFailure = $_.Exception.Message
        if ([string]$firmwareResult.Status -ceq 'Applied') {
            try {
                Restore-VMateHyperVFirmwareIdentitySnapshot `
                    -VMId ([Guid]$VM.Id) -Snapshot $firmwareResult.Previous `
                    -JobTimeoutSeconds $JobTimeoutSeconds | Out-Null
            }
            catch {
                throw "网络身份失败且固件补偿失败；网络：$networkFailure；" +
                    "固件：$($_.Exception.Message)"
            }
        }
        throw $networkFailure
    }
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

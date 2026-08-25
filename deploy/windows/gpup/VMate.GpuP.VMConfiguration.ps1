#Requires -Version 5.1

<#
.SYNOPSIS
    可靠读取并核验 GPU-P VM 的 cache/MMIO/checkpoint 配置。

.DESCRIPTION
    Win10 Hyper-V 在 VM 配置写入后可能让同一 PowerShell 进程中的
    Get-VM.LowMemoryMappedIoSpace 暂时返回 null；实际 VSSD 已正确写入。
    本模块只在 cmdlet 值为 null 时用 Msvm_VirtualSystemSettingData 的 MiB
    字段补充回读，仍逐字节严格比较，不把未知值当作成功。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VMateGpuPVMConfigurationProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-VMateGpuPVMConfigurationVssd {
    param([Parameter(Mandatory = $true)][object]$VM)

    $vmId = ([Guid]$VM.Id).ToString('D')
    $rows = @(Get-CimInstance -Namespace 'root\virtualization\v2' `
            -ClassName Msvm_VirtualSystemSettingData `
            -Filter "VirtualSystemIdentifier = '$vmId'" -ErrorAction Stop |
        Where-Object {
            [string]$_.VirtualSystemIdentifier -ieq $vmId -and
            [string]$_.VirtualSystemType -ceq
                'Microsoft:Hyper-V:System:Realized'
        })
    if ($rows.Count -ne 1) {
        throw "Hyper-V VM [$($VM.Name)] 的 realized VSSD 必须恰好一条，实际 $($rows.Count)。"
    }
    return $rows[0]
}

function ConvertFrom-VMateGpuPMmioMiB {
    param(
        [Parameter(Mandatory = $true)][object]$Vssd,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $value = Get-VMateGpuPVMConfigurationProperty $Vssd $Name
    if ($null -eq $value) { throw "Hyper-V VSSD 缺少 $Name 回读值。" }
    $bytes = [decimal]$value * [decimal]1MB
    if ($bytes -lt 0 -or $bytes -gt [decimal][uint64]::MaxValue -or
        [decimal]::Truncate($bytes) -ne $bytes) {
        throw "Hyper-V VSSD $Name 无法安全换算为字节：$value"
    }
    return [uint64]$bytes
}

function Get-VMateGpuPVMConfigurationSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$VM)

    $cache = Get-VMateGpuPVMConfigurationProperty $VM `
        'GuestControlledCacheTypes'
    $low = Get-VMateGpuPVMConfigurationProperty $VM `
        'LowMemoryMappedIoSpace'
    $high = Get-VMateGpuPVMConfigurationProperty $VM `
        'HighMemoryMappedIoSpace'
    $checkpoint = Get-VMateGpuPVMConfigurationProperty $VM 'CheckpointType'
    $source = 'HyperVCmdlet'
    if ($null -eq $low -or $null -eq $high) {
        $vssd = Get-VMateGpuPVMConfigurationVssd $VM
        if ($null -eq $low) {
            $low = ConvertFrom-VMateGpuPMmioMiB $vssd 'LowMmioGapSize'
        }
        if ($null -eq $high) {
            $high = ConvertFrom-VMateGpuPMmioMiB $vssd 'HighMmioGapSize'
        }
        $source = 'HyperVCmdlet+VSSD'
    }
    if ($null -eq $cache -or $null -eq $checkpoint) {
        throw "Hyper-V VM [$($VM.Name)] 的 cache/checkpoint 回读为空。"
    }
    return [pscustomobject][ordered]@{
        GuestControlledCacheTypes = [bool]$cache
        LowMemoryMappedIoSpace = [uint64]$low
        HighMemoryMappedIoSpace = [uint64]$high
        CheckpointType = [string]$checkpoint
        ReadbackSource = $source
    }
}

function Test-VMateGpuPVMConfigurationMatch {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][object]$Plan
    )

    return [bool]$Snapshot.GuestControlledCacheTypes -and
        [uint64]$Snapshot.LowMemoryMappedIoSpace -eq
            [uint64]$Plan.LowMemoryMappedIoSpace -and
        [uint64]$Snapshot.HighMemoryMappedIoSpace -eq
            [uint64]$Plan.HighMemoryMappedIoSpace -and
        [string]$Snapshot.CheckpointType -ceq 'Disabled'
}

function Assert-VMateGpuPAppliedState {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $vm = Get-VMateGpuPVirtualMachine $Plan.VMName
    $snapshot = Get-VMateGpuPVMConfigurationSnapshot $vm
    if (-not (Test-VMateGpuPVMConfigurationMatch $snapshot $Plan)) {
        throw ('GPU-P VM cache/MMIO/checkpoint 配置回读不一致：' +
            "Cache=$($snapshot.GuestControlledCacheTypes), " +
            "Low=$($snapshot.LowMemoryMappedIoSpace), " +
            "High=$($snapshot.HighMemoryMappedIoSpace), " +
            "Checkpoint=$($snapshot.CheckpointType), " +
            "Source=$($snapshot.ReadbackSource)。")
    }
    $adapters = @(Get-VMateGpuPAdaptersForVm $vm)
    $adapter = Resolve-VMateGpuPExistingAdapter $adapters `
        $Plan.InstancePath $Plan.SupportedGpuCount
    $expected = Get-VMateGpuPAdapterSettings $Plan.ResourcePlan
    $actual = Get-VMateGpuPAdapterSettings $adapter
    foreach ($name in $expected.Keys) {
        if ([uint64]$actual[$name] -ne [uint64]$expected[$name]) {
            throw "GPU-P adapter 回读不一致：$name"
        }
    }
}

#Requires -Version 5.1

<#
.SYNOPSIS
    事务配置 Hyper-V 官方公开的每 VM CPU 资源与拓扑字段。

.DESCRIPTION
    这些字段改变 vCPU 数量、调度配额、SMT 呈现和嵌套虚拟化；它们不会改变
    CPU 厂商、品牌字符串、ProcessorId 或 CPUID。配置只允许在 VM Off 时执行。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-VMateHyperVComputeProfile {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 256)][int]$ProcessorCount = 4,
        [ValidateRange(1, 100)][int]$CpuMaximumPercent = 100,
        [ValidateRange(0, 100)][int]$CpuReservePercent = 0,
        [ValidateRange(1, 10000)][int]$CpuRelativeWeight = 100,
        [ValidateRange(1, 64)][int]$HwThreadCountPerCore = 1,
        [bool]$ExposeVirtualizationExtensions = $false
    )

    if ($CpuReservePercent -gt $CpuMaximumPercent) {
        throw 'CPU Reserve 不能大于 Maximum。'
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        ProfileKind = 'HyperVComputeSupportedFields'
        ProcessorCount = $ProcessorCount
        CpuMaximumPercent = $CpuMaximumPercent
        CpuReservePercent = $CpuReservePercent
        CpuRelativeWeight = $CpuRelativeWeight
        HwThreadCountPerCore = $HwThreadCountPerCore
        ExposeVirtualizationExtensions = $ExposeVirtualizationExtensions
        CpuIdentityPolicy = 'host-managed-read-only'
    }
}

function Get-VMateHyperVComputeProfileProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "CPU profile 缺少 $Name 属性。" }
    return $property.Value
}

function ConvertTo-VMateHyperVComputeProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Profile)

    if ([int](Get-VMateHyperVComputeProfileProperty `
            $Profile 'SchemaVersion') -ne 1 -or
        [string](Get-VMateHyperVComputeProfileProperty `
            $Profile 'ProfileKind') -cne 'HyperVComputeSupportedFields') {
        throw 'CPU profile schema 或类型不受支持。'
    }
    $parameters = @{
        ProcessorCount = [int](Get-VMateHyperVComputeProfileProperty `
                $Profile 'ProcessorCount')
        CpuMaximumPercent = [int](Get-VMateHyperVComputeProfileProperty `
                $Profile 'CpuMaximumPercent')
        CpuReservePercent = [int](Get-VMateHyperVComputeProfileProperty `
                $Profile 'CpuReservePercent')
        CpuRelativeWeight = [int](Get-VMateHyperVComputeProfileProperty `
                $Profile 'CpuRelativeWeight')
        HwThreadCountPerCore = [int](Get-VMateHyperVComputeProfileProperty `
                $Profile 'HwThreadCountPerCore')
        ExposeVirtualizationExtensions = [bool](`
            Get-VMateHyperVComputeProfileProperty `
                $Profile 'ExposeVirtualizationExtensions')
    }
    return New-VMateHyperVComputeProfile @parameters
}

function Get-VMateHyperVComputeSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$VM)

    $processor = Get-VMProcessor -VM $VM -ErrorAction Stop
    return [pscustomobject][ordered]@{
        ProcessorCount = [int]$processor.Count
        CpuMaximumPercent = [int]$processor.Maximum
        CpuReservePercent = [int]$processor.Reserve
        CpuRelativeWeight = [int]$processor.RelativeWeight
        HwThreadCountPerCore = [int]$processor.HwThreadCountPerCore
        ExposeVirtualizationExtensions =
            [bool]$processor.ExposeVirtualizationExtensions
    }
}

function Test-VMateHyperVComputeProfileMatch {
    param(
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][object]$Expected
    )

    foreach ($name in @('ProcessorCount', 'CpuMaximumPercent',
            'CpuReservePercent', 'CpuRelativeWeight',
            'HwThreadCountPerCore', 'ExposeVirtualizationExtensions')) {
        if ([string]$Actual.$name -cne [string]$Expected.$name) {
            return $false
        }
    }
    return $true
}

function Assert-VMateHyperVComputeEnvironment {
    if ($env:OS -cne 'Windows_NT') {
        throw 'Hyper-V CPU profile 只能在 Windows 宿主配置。'
    }
    foreach ($name in @('Get-VMProcessor', 'Set-VMProcessor')) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            throw "缺少 Hyper-V PowerShell cmdlet：$name"
        }
    }
    $setter = Get-Command Set-VMProcessor -ErrorAction Stop
    foreach ($name in @('Count', 'Maximum', 'Reserve', 'RelativeWeight',
            'HwThreadCountPerCore', 'ExposeVirtualizationExtensions')) {
        if (-not $setter.Parameters.ContainsKey($name)) {
            throw "Set-VMProcessor 缺少 CPU profile 参数：$name"
        }
    }
}

function Set-VMateHyperVComputeProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$Profile,
        [switch]$DryRun
    )

    Assert-VMateHyperVComputeEnvironment
    if ([string]$VM.State -cne 'Off') {
        throw 'VM 必须为 Off 才能配置 CPU profile。'
    }
    $desired = ConvertTo-VMateHyperVComputeProfile $Profile
    $before = Get-VMateHyperVComputeSnapshot $VM
    if (Test-VMateHyperVComputeProfileMatch $before $desired) {
        return [pscustomobject][ordered]@{
            Status = 'Unchanged'; Desired = $desired; Observed = $before
        }
    }
    if ($DryRun.IsPresent) {
        return [pscustomobject][ordered]@{
            Status = 'DryRun'; Desired = $desired; Previous = $before
        }
    }

    try {
        Set-VMProcessor -VM $VM -Count $desired.ProcessorCount `
            -Maximum $desired.CpuMaximumPercent `
            -Reserve $desired.CpuReservePercent `
            -RelativeWeight $desired.CpuRelativeWeight `
            -HwThreadCountPerCore $desired.HwThreadCountPerCore `
            -ExposeVirtualizationExtensions `
                $desired.ExposeVirtualizationExtensions `
            -Confirm:$false -ErrorAction Stop
        $observed = Get-VMateHyperVComputeSnapshot $VM
        if (-not (Test-VMateHyperVComputeProfileMatch $observed $desired)) {
            throw 'CPU profile 写入后的回读不一致。'
        }
    }
    catch {
        $failure = $_.Exception.Message
        try {
            Set-VMProcessor -VM $VM -Count $before.ProcessorCount `
                -Maximum $before.CpuMaximumPercent `
                -Reserve $before.CpuReservePercent `
                -RelativeWeight $before.CpuRelativeWeight `
                -HwThreadCountPerCore $before.HwThreadCountPerCore `
                -ExposeVirtualizationExtensions `
                    $before.ExposeVirtualizationExtensions `
                -Confirm:$false -ErrorAction Stop
            $restored = Get-VMateHyperVComputeSnapshot $VM
            if (-not (Test-VMateHyperVComputeProfileMatch $restored $before)) {
                throw 'CPU profile 回滚回读不一致。'
            }
        }
        catch {
            throw "CPU profile 应用失败：$failure；回滚失败：$($_.Exception.Message)"
        }
        throw "CPU profile 应用失败：$failure；已回滚原值。"
    }
    return [pscustomobject][ordered]@{
        Status = 'Applied'; Desired = $desired; Previous = $before
        Observed = $observed
    }
}

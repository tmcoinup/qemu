#Requires -Version 5.1

<#
.SYNOPSIS
    解析 GPU-P 配额模式，并复现经授权 Win10 样例的“100%”编码语义。

.DESCRIPTION
    普通百分比和完整宿主配额继续由 VMate.GpuP.Common.ps1 计算。本模块只增加
    Win10Reference100：VRAM/Decode/Compute 使用宿主报告的 100%，而当 Encode
    使用 UInt64.MaxValue 哨兵时，精确写入 2^63。能力形状不匹配时失败关闭。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-VMateGpuPQuotaCompatibilityRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Percentages,
        [AllowEmptyCollection()][string[]]$ExplicitNames = @(),
        [switch]$FullSharedGpuQuota,
        [switch]$Win10ReferenceGpuQuota,
        [switch]$AllowOvercommit
    )

    if ($FullSharedGpuQuota -and $Win10ReferenceGpuQuota) {
        throw '-FullSharedGpuQuota 与 -Win10ReferenceGpuQuota 冲突，不能同时使用。'
    }
    if (-not $Win10ReferenceGpuQuota) {
        return Resolve-VMateGpuPQuotaRequest -Percentages $Percentages `
            -ExplicitNames $ExplicitNames `
            -FullSharedGpuQuota:$FullSharedGpuQuota.IsPresent `
            -AllowOvercommit:$AllowOvercommit.IsPresent
    }

    $required = @('VramPercentage', 'EncodePercentage',
        'DecodePercentage', 'ComputePercentage')
    $resolved = [ordered]@{}
    foreach ($name in $required) {
        if (-not $Percentages.ContainsKey($name)) {
            throw "GPU-P 配额请求缺少 $name。"
        }
        $value = [int]$Percentages[$name]
        [void](Assert-VMateGpuPPercentage -Percentage $value -Label $name)
        if ($ExplicitNames -contains $name -and $value -ne 100) {
            throw "-Win10ReferenceGpuQuota 与显式 -$name $value 冲突；只允许 100。"
        }
        $resolved[$name] = 100
    }
    return [pscustomobject][ordered]@{
        Percentages = [pscustomobject]$resolved
        EffectiveAllowOvercommit = $true
        QuotaMode = 'Win10Reference100'
    }
}

function Get-VMateGpuPResourcePlanForRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$HostGpu,
        [Parameter(Mandatory = $true)][object]$QuotaRequest
    )

    $percentages = $QuotaRequest.Percentages
    $plan = Get-VMateGpuPResourcePlan -HostGpu $HostGpu `
        -VramPercentage ([int]$percentages.VramPercentage) `
        -EncodePercentage ([int]$percentages.EncodePercentage) `
        -DecodePercentage ([int]$percentages.DecodePercentage) `
        -ComputePercentage ([int]$percentages.ComputePercentage)
    if ([string]$QuotaRequest.QuotaMode -cne 'Win10Reference100') {
        return $plan
    }

    $total = Get-VMateGpuPObjectUInt64 $HostGpu 'TotalEncode' '宿主 GPU'
    $minimum = Get-VMateGpuPObjectUInt64 $HostGpu `
        'MinPartitionEncode' '宿主 GPU'
    $maximum = Get-VMateGpuPObjectUInt64 $HostGpu `
        'MaxPartitionEncode' '宿主 GPU'
    if ($total -ne [uint64]::MaxValue -or
        $maximum -ne [uint64]::MaxValue -or $minimum -ne 0) {
        throw ('Win10Reference100 只支持 Encode Total/Max=UInt64.MaxValue、' +
            'Min=0 的已校准能力形状。')
    }
    $referenceEncode = [uint64][decimal]::Floor(
        (([decimal]$total + [decimal]1) / [decimal]2))
    foreach ($name in @('MinPartitionEncode', 'MaxPartitionEncode',
            'OptimalPartitionEncode')) {
        $plan.$name = $referenceEncode
    }
    return $plan
}

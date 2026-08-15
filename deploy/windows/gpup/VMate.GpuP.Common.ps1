#Requires -Version 5.1

<#
.SYNOPSIS
    GPU-P 配额计算与校验的无副作用公共函数。

.DESCRIPTION
    本文件不调用 Hyper-V cmdlet，也不修改宿主或虚拟机。百分比计算先提升到
    Decimal，避免 UInt64 与百分比相乘溢出；最终值严格夹在厂商驱动报告的
    MinPartition/MaxPartition 边界内，可直接供 DryRun 和事务预检复用。
#>

function Assert-VMateGpuPPercentage {
    param(
        [int]$Percentage,
        [string]$Label = 'GPU-P 配额百分比'
    )

    if ($Percentage -lt 1 -or $Percentage -gt 100) {
        throw "$Label 必须是 1..100 的整数，实际：$Percentage"
    }
    return $Percentage
}

function ConvertTo-VMateGpuPUInt64 {
    param(
        [AllowNull()][object]$Value,
        [string]$Label
    )

    # 不能直接强制转换：PowerShell 会把部分浮点值四舍五入，也可能把空值变成
    # 零。使用 invariant 的严格整数解析，让损坏的驱动属性在预检阶段失败。
    if ($null -eq $Value) {
        throw "$Label 缺失。"
    }
    $text = [System.Convert]::ToString(
        $Value, [System.Globalization.CultureInfo]::InvariantCulture)
    $parsed = [uint64]0
    $style = [System.Globalization.NumberStyles]::None
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [uint64]::TryParse($text, $style, $culture, [ref]$parsed)) {
        throw "$Label 不是合法的 UInt64：$text"
    }
    return $parsed
}

function Get-VMateGpuPObjectUInt64 {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [string]$ObjectLabel = 'GPU-P 对象'
    )

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        throw "$ObjectLabel 缺少 $PropertyName 属性。"
    }
    return ConvertTo-VMateGpuPUInt64 -Value $property.Value `
        -Label "$ObjectLabel.$PropertyName"
}

function Get-VMateGpuPVendorInfo {
    param([Parameter(Mandatory = $true)][string]$InstancePath)

    # Hyper-V 的 Name/InstancePath 来自 PnP device instance path。这里只读取
    # PCI vendor ID，不依赖本地化设备名称，且明确拒绝未纳入方案的厂商。
    $match = [regex]::Match(
        $InstancePath, 'VEN_(10DE|1002)(?=&|#|\\|$)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw "GPU InstancePath 不属于受支持的 NVIDIA/AMD PCI 设备：$InstancePath"
    }
    $vendorId = $match.Groups[1].Value.ToUpperInvariant()
    if ($vendorId -ceq '10DE') {
        $vendor = 'NVIDIA'
    } else {
        $vendor = 'AMD'
    }
    return [pscustomobject][ordered]@{
        Vendor = $vendor
        VendorId = $vendorId
        InstancePath = $InstancePath
    }
}

function ConvertTo-VMateGpuPPartitionIdentitySeed {
    param([Parameter(Mandatory = $true)][string]$Value)

    # seed 由 Identity 模块首次创建并持久化；核心模块只验证、规范化和透传，
    # 不把它写入 GPU 驱动，也不把 Hyper-V 生成的 PartitionId 当成板卡序列号。
    if ($Value -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'PartitionIdentitySeed 必须是 64 位十六进制字符串。'
    }
    return $Value.ToLowerInvariant()
}

function Get-VMateGpuPScaledValue {
    param(
        [Parameter(Mandatory = $true)][object]$Total,
        [Parameter(Mandatory = $true)][object]$Minimum,
        [Parameter(Mandatory = $true)][object]$Maximum,
        [Parameter(Mandatory = $true)][int]$Percentage,
        [string]$ResourceName = 'GPU-P 资源'
    )

    [void](Assert-VMateGpuPPercentage -Percentage $Percentage `
        -Label "$ResourceName 百分比")
    $totalValue = ConvertTo-VMateGpuPUInt64 $Total "$ResourceName.Total"
    $minimumValue = ConvertTo-VMateGpuPUInt64 $Minimum "$ResourceName.Min"
    $maximumValue = ConvertTo-VMateGpuPUInt64 $Maximum "$ResourceName.Max"
    if ($minimumValue -gt $maximumValue) {
        throw "$ResourceName 的厂商下限大于上限：$minimumValue > $maximumValue"
    }
    if ($maximumValue -gt $totalValue) {
        throw "$ResourceName 的厂商上限超过总量：$maximumValue > $totalValue"
    }

    # UInt64.MaxValue * 100 会溢出 UInt64。Decimal 可精确保存这里最多 22 位的
    # 中间整数，再向下取整，确保不同 PowerShell/.NET 版本得到一致结果。
    $scaled = [decimal]::Floor(
        ([decimal]$totalValue * [decimal]$Percentage) / [decimal]100)
    if ($scaled -lt [decimal]$minimumValue) {
        return $minimumValue
    }
    if ($scaled -gt [decimal]$maximumValue) {
        return $maximumValue
    }
    return [uint64]$scaled
}

function Get-VMateGpuPResourcePlan {
    param(
        [Parameter(Mandatory = $true)][object]$HostGpu,
        [int]$VramPercentage = 100,
        [int]$EncodePercentage = 100,
        [int]$DecodePercentage = 100,
        [int]$ComputePercentage = 100
    )

    $percentages = [ordered]@{
        VRAM = Assert-VMateGpuPPercentage $VramPercentage 'VRAM 百分比'
        Encode = Assert-VMateGpuPPercentage $EncodePercentage 'Encode 百分比'
        Decode = Assert-VMateGpuPPercentage $DecodePercentage 'Decode 百分比'
        Compute = Assert-VMateGpuPPercentage $ComputePercentage 'Compute 百分比'
    }
    $values = [ordered]@{}
    foreach ($resource in @('VRAM', 'Encode', 'Decode', 'Compute')) {
        $total = Get-VMateGpuPObjectUInt64 $HostGpu "Total$resource" '宿主 GPU'
        $minimum = Get-VMateGpuPObjectUInt64 $HostGpu `
            "MinPartition$resource" '宿主 GPU'
        $maximum = Get-VMateGpuPObjectUInt64 $HostGpu `
            "MaxPartition$resource" '宿主 GPU'
        $values[$resource] = Get-VMateGpuPScaledValue $total $minimum `
            $maximum $percentages[$resource] $resource
    }

    # Min/Max/Optimal 使用同一夹紧后的目标值，防止调度器在一个宽范围内把单台
    # VM 扩张到高于用户百分比的额度，也让多 VM 的最大配额求和具有确定含义。
    return [pscustomobject][ordered]@{
        VramPercentage = $percentages.VRAM
        EncodePercentage = $percentages.Encode
        DecodePercentage = $percentages.Decode
        ComputePercentage = $percentages.Compute
        MinPartitionVRAM = [uint64]$values.VRAM
        MaxPartitionVRAM = [uint64]$values.VRAM
        OptimalPartitionVRAM = [uint64]$values.VRAM
        MinPartitionEncode = [uint64]$values.Encode
        MaxPartitionEncode = [uint64]$values.Encode
        OptimalPartitionEncode = [uint64]$values.Encode
        MinPartitionDecode = [uint64]$values.Decode
        MaxPartitionDecode = [uint64]$values.Decode
        OptimalPartitionDecode = [uint64]$values.Decode
        MinPartitionCompute = [uint64]$values.Compute
        MaxPartitionCompute = [uint64]$values.Compute
        OptimalPartitionCompute = [uint64]$values.Compute
    }
}

function Get-VMateGpuPCapabilitySnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$HostGpu,
        [Parameter(Mandatory = $true)][object]$VendorInfo
    )

    $resources = [ordered]@{}
    foreach ($resource in @('VRAM', 'Encode', 'Decode', 'Compute')) {
        $row = [ordered]@{}
        foreach ($prefix in @('Total', 'Available', 'MinPartition',
                'MaxPartition', 'OptimalPartition')) {
            $propertyName = "${prefix}$resource"
            $row[$prefix] = Get-VMateGpuPObjectUInt64 `
                $HostGpu $propertyName '宿主 GPU'
        }
        $resources[$resource] = [pscustomobject]$row
    }
    $validCountsProperty = $HostGpu.PSObject.Properties['ValidPartitionCounts']
    if ($null -eq $validCountsProperty) {
        throw '宿主 GPU 缺少 ValidPartitionCounts 属性。'
    }
    $validCounts = @($validCountsProperty.Value | ForEach-Object {
            ConvertTo-VMateGpuPUInt64 $_ '宿主 GPU.ValidPartitionCounts'
        })
    return [pscustomobject][ordered]@{
        InstancePath = [string]$VendorInfo.InstancePath
        Vendor = [string]$VendorInfo.Vendor
        VendorId = [string]$VendorInfo.VendorId
        PartitionCount = Get-VMateGpuPObjectUInt64 `
            $HostGpu 'PartitionCount' '宿主 GPU'
        ValidPartitionCounts = $validCounts
        Resources = [pscustomobject]$resources
    }
}

function Get-VMateGpuPQuotaSummary {
    param(
        [Parameter(Mandatory = $true)][object]$HostGpu,
        [Parameter(Mandatory = $true)][object]$RequestedPlan,
        [AllowEmptyCollection()][object[]]$ExistingAdapters = @()
    )

    $resources = [ordered]@{}
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($resource in @('VRAM', 'Encode', 'Decode', 'Compute')) {
        $total = Get-VMateGpuPObjectUInt64 $HostGpu "Total$resource" '宿主 GPU'
        $requested = Get-VMateGpuPObjectUInt64 $RequestedPlan `
            "MaxPartition$resource" '请求计划'
        $existing = [decimal]0
        foreach ($adapter in @($ExistingAdapters)) {
            $allocation = Get-VMateGpuPObjectUInt64 $adapter `
                "MaxPartition$resource" '既有 GPU-P adapter'
            $existing += [decimal]$allocation
        }
        $projected = $existing + [decimal]$requested
        $exceeded = $projected -gt [decimal]$total
        if ($exceeded) {
            [void]$problems.Add(
                "$resource 最大配额将超过宿主总量：$projected > $total")
        }
        $resources[$resource] = [pscustomobject][ordered]@{
            Total = $total
            Existing = $existing
            Requested = $requested
            Projected = $projected
            Exceeded = $exceeded
        }
    }

    return [pscustomobject][ordered]@{
        ExistingAdapterCount = @($ExistingAdapters).Count
        Resources = [pscustomobject]$resources
        Overcommitted = $problems.Count -gt 0
        Problems = @($problems)
    }
}

function Enter-VMateGpuPConfigurationLock {
    param([ValidateRange(1, 300)][int]$TimeoutSeconds = 60)

    # 配额校验与 adapter 写入必须跨进程串行，否则两次并发 Enable 都可能在
    # 读取到旧配额后通过预检。Global mutex 只保护很短的宿主配置事务。
    $mutex = [System.Threading.Mutex]::new(
        $false, 'Global\VMate.GpuP.HostConfiguration.v1')
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(
                [TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "等待 GPU-P 宿主配置锁超过 ${TimeoutSeconds}s。"
        }
        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-VMateGpuPConfigurationLock {
    param([Parameter(Mandatory = $true)][System.Threading.Mutex]$Mutex)

    try {
        $Mutex.ReleaseMutex()
    }
    finally {
        $Mutex.Dispose()
    }
}

function Get-VMateGpuPCmdletCompatibility {
    param(
        [Parameter(Mandatory = $true)][object]$AddCommand,
        [Parameter(Mandatory = $true)][object]$SetCommand,
        [Parameter(Mandatory = $true)][string[]]$QuotaNames,
        [int]$RawGpuCount,
        [int]$NamedGpuCount,
        [int]$UniqueNamedGpuCount
    )

    $supportsPath = $AddCommand.Parameters.ContainsKey('InstancePath')
    if (-not $supportsPath -and ($RawGpuCount -ne 1 -or
            $NamedGpuCount -ne 1 -or $UniqueNamedGpuCount -ne 1)) {
        throw ('当前 Hyper-V 模块不支持 Add-VMGpuPartitionAdapter ' +
            '-InstancePath，只有恰好一张、名称非空且唯一的 GPU 时才能安全配置。')
    }
    if ($AddCommand.Parameters.ContainsKey('VM')) {
        $target = 'VM'
    }
    elseif ($AddCommand.Parameters.ContainsKey('VMName')) {
        $target = 'VMName'
    }
    else {
        throw 'Add-VMGpuPartitionAdapter 不支持 VM 或 VMName 目标参数。'
    }
    if (-not $AddCommand.Parameters.ContainsKey('Passthru')) {
        throw 'Add-VMGpuPartitionAdapter 缺少事务回滚必需的 Passthru。'
    }
    if (-not $SetCommand.Parameters.ContainsKey('VMGpuPartitionAdapter')) {
        throw 'Set-VMGpuPartitionAdapter 缺少 VMGpuPartitionAdapter 参数。'
    }
    foreach ($name in $QuotaNames) {
        if (-not $SetCommand.Parameters.ContainsKey($name)) {
            throw "Set-VMGpuPartitionAdapter 缺少必需配额参数：$name"
        }
    }
    return [pscustomobject]@{
        SupportsInstancePath = $supportsPath
        AddTargetParameter = $target
        AddQuotaParameters = @($QuotaNames | Where-Object {
                $AddCommand.Parameters.ContainsKey($_) })
    }
}

function Get-VMateGpuPAdapterOwnership {
    param(
        [Parameter(Mandatory = $true)][object]$Adapter,
        [Parameter(Mandatory = $true)][string]$SelectedInstancePath,
        [AllowEmptyCollection()][AllowNull()][string[]]$HostGpuNames
    )

    $pathProperty = $Adapter.PSObject.Properties['InstancePath']
    $adapterPath = if ($null -eq $pathProperty) {
        ''
    }
    else { [string]$pathProperty.Value }
    if ([String]::IsNullOrWhiteSpace($adapterPath)) {
        return [pscustomobject]@{ Ownership = 'Unknown'; InstancePath = '' }
    }
    $matches = @($HostGpuNames | Where-Object {
            -not [String]::IsNullOrWhiteSpace([string]$_) -and
            [string]::Equals([string]$_, $adapterPath,
                [StringComparison]::OrdinalIgnoreCase)
        })
    if ($matches.Count -ne 1) {
        return [pscustomobject]@{
            Ownership = 'Unknown'
            InstancePath = $adapterPath
        }
    }
    $ownership = if ([string]::Equals($adapterPath,
            $SelectedInstancePath,
            [StringComparison]::OrdinalIgnoreCase)) {
        'SelectedGpu'
    }
    else { 'OtherGpu' }
    return [pscustomobject]@{
        Ownership = $ownership
        InstancePath = $adapterPath
    }
}

function Resolve-VMateGpuPQuotaRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Percentages,
        [AllowEmptyCollection()][string[]]$ExplicitNames = @(),
        [switch]$FullSharedGpuQuota,
        [switch]$AllowOvercommit
    )

    $required = @('VramPercentage', 'EncodePercentage',
        'DecodePercentage', 'ComputePercentage')
    $resolved = [ordered]@{}
    foreach ($name in $required) {
        if (-not $Percentages.ContainsKey($name)) {
            throw "GPU-P 配额请求缺少 $name。"
        }
        $value = [int]$Percentages[$name]
        [void](Assert-VMateGpuPPercentage -Percentage $value -Label $name)
        if ($FullSharedGpuQuota -and $ExplicitNames -contains $name -and
            $value -ne 100) {
            throw "-FullSharedGpuQuota 与显式 -$name $value 冲突；只允许 100。"
        }
        $resolved[$name] = if ($FullSharedGpuQuota) { 100 } else { $value }
    }
    return [pscustomobject][ordered]@{
        Percentages = [pscustomobject]$resolved
        EffectiveAllowOvercommit = ($AllowOvercommit.IsPresent -or
            $FullSharedGpuQuota.IsPresent)
        QuotaMode = if ($FullSharedGpuQuota) {
            'FullHostReportedGpuPQuota'
        } else { 'Percentage' }
    }
}

function Assert-VMateGpuPFullHostVramQuota {
    param(
        [Parameter(Mandatory = $true)][object]$ResourcePlan,
        [Parameter(Mandatory = $true)][object]$CapabilitySnapshot,
        [string]$FailureMessage = '宿主报告的 GPU-P 总显存配额无法完整分配。'
    )

    $maximum = Get-VMateGpuPObjectUInt64 $ResourcePlan `
        'MaxPartitionVRAM' 'GPU-P 资源计划'
    if ($null -eq $CapabilitySnapshot.PSObject.Properties['Resources'] -or
        $null -eq $CapabilitySnapshot.Resources.PSObject.Properties['VRAM']) {
        throw 'GPU-P 能力快照缺少 Resources.VRAM。'
    }
    $total = Get-VMateGpuPObjectUInt64 $CapabilitySnapshot.Resources.VRAM `
        'Total' 'GPU-P 能力快照.VRAM'
    if ($maximum -ne $total) {
        throw $FailureMessage
    }
    return $true
}

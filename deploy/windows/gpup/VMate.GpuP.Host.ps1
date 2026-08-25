#Requires -Version 5.1
<#
.SYNOPSIS
    Hyper-V GPU-P 宿主预检与可回滚 VM 配置事务。
.DESCRIPTION
    只使用公开 Hyper-V PowerShell API：选择 partitionable GPU、核对 VM 与多 VM
    配额、配置 MMIO/checkpoint/cache 和 Add/Set GPU partition adapter。本模块不
    启动 VM、不复制驱动、不安装 IDD；-DryRun 完成同等读取和校验但不写宿主。
#>
$gpuPCommon = Join-Path $PSScriptRoot 'VMate.GpuP.Common.ps1'
if (-not (Get-Command -Name Get-VMateGpuPResourcePlan `
        -CommandType Function -ErrorAction SilentlyContinue)) {
    . $gpuPCommon
}
. (Join-Path $PSScriptRoot 'VMate.GpuP.VMConfiguration.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.QuotaProfile.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.ConsoleProfile.ps1')
function Assert-VMateGpuPHostEnvironment {
    if ($env:OS -ne 'Windows_NT') {
        throw 'GPU-P 配置只能在 Windows Hyper-V 宿主运行。'
    }
    $nativeArchitecture = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else { $env:PROCESSOR_ARCHITECTURE }
    if (-not [Environment]::Is64BitOperatingSystem -or
        $nativeArchitecture -ine 'AMD64') {
        throw 'P-11 GPU-P 宿主必须是 x64 Windows。'
    }
    [void](Resolve-VMateGpuPHostPartitionCommand -Operation Get)
    $required = @('Get-VM', 'Set-VM',
        'Get-VMGpuPartitionAdapter', 'Add-VMGpuPartitionAdapter',
        'Set-VMGpuPartitionAdapter', 'Remove-VMGpuPartitionAdapter'
    )
    foreach ($command in $required) {
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
            throw "缺少 Hyper-V PowerShell cmdlet：$command"
        }
    }
    # GPU-P 读取和配置均要求提升权限，必须在事务前失败。
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator
        if (-not $principal.IsInRole($adminRole)) {
            throw 'GPU-P 配置需要管理员 PowerShell。'
        }
    } finally {
        $identity.Dispose()
    }
}
function Resolve-VMateGpuPHostGpu {
    param(
        [AllowEmptyCollection()][object[]]$Gpus,
        [string]$InstancePath = '',
        [ValidateSet('Auto', 'NVIDIA', 'AMD')][string]$Vendor = 'Auto',
        [string]$PartitionIdentitySeed = ''
    )
    $supported = [System.Collections.Generic.List[object]]::new()
    foreach ($gpu in @($Gpus)) {
        $nameProperty = $gpu.PSObject.Properties['Name']
        if ($null -eq $nameProperty -or
            [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
            continue
        }
        try {
            $vendorInfo = Get-VMateGpuPVendorInfo ([string]$nameProperty.Value)
        } catch {
            continue
        }
        if ($Vendor -eq 'Auto' -or $vendorInfo.Vendor -eq $Vendor) {
            [void]$supported.Add([pscustomobject]@{
                    Gpu = $gpu
                    VendorInfo = $vendorInfo
                })
        }
    }
    if ($InstancePath) {
        $matches = @($supported | Where-Object {
                [string]::Equals(
                    [string]$_.VendorInfo.InstancePath, $InstancePath,
                    [System.StringComparison]::OrdinalIgnoreCase)
            })
        if ($matches.Count -ne 1) {
            throw "指定 InstancePath 无法唯一解析为 $Vendor partitionable GPU：$InstancePath"
        }
        return $matches[0]
    }
    if ($supported.Count -ne 1) {
        if ($supported.Count -eq 0) {
            throw "没有找到 $Vendor NVIDIA/AMD partitionable GPU。"
        }
        if ($Vendor -ne 'Auto') {
            throw "发现 $($supported.Count) 个 $Vendor partitionable GPU；请显式指定 InstancePath。"
        }
        if (-not $PartitionIdentitySeed) {
            throw 'Auto 发现多个 partitionable GPU；必须提供持久化 PartitionIdentitySeed。'
        }
        $seed = ConvertTo-VMateGpuPPartitionIdentitySeed $PartitionIdentitySeed
        $ordered = @($supported | Sort-Object {
                ([string]$_.VendorInfo.InstancePath).ToUpperInvariant()
            })
        # 以持久化随机 seed 映射稳定排序后的真实物理卡。
        $selector = [convert]::ToUInt32($seed.Substring(0, 8), 16)
        return $ordered[$selector % [uint32]$ordered.Count]
    }
    return $supported[0]
}
function Get-VMateGpuPVirtualMachine {
    param([Parameter(Mandatory = $true)][string]$VMName)
    $escapedName = [System.Management.Automation.WildcardPattern]::Escape($VMName)
    try {
        $matches = @(Get-VM -Name $escapedName -ErrorAction Stop |
            Where-Object {
                [string]::Equals([string]$_.Name, $VMName,
                    [System.StringComparison]::OrdinalIgnoreCase)
            })
    } catch {
        throw "无法读取 Hyper-V VM [$VMName]：$($_.Exception.Message)"
    }
    if ($matches.Count -ne 1) {
        throw "Hyper-V VM 名称无法唯一解析：$VMName"
    }
    return $matches[0]
}
function Assert-VMateGpuPVirtualMachine {
    param([Parameter(Mandatory = $true)][object]$VM)
    if ([string]$VM.State -cne 'Off') {
        throw "GPU-P 配置要求 VM 完全关机，当前状态：$($VM.State)"
    }
    if ([int]$VM.Generation -ne 2) {
        throw "GPU-P 只支持 Generation 2 VM，当前代数：$($VM.Generation)"
    }
}
function Get-VMateGpuPAdaptersForVm {
    param([Parameter(Mandatory = $true)][object]$VM)
    try {
        return @(Get-VMGpuPartitionAdapter -VM $VM -ErrorAction Stop)
    } catch {
        throw "无法读取 VM [$($VM.Name)] 的 GPU-P adapter：$($_.Exception.Message)"
    }
}
function Test-VMateGpuPAdapterForGpu {
    param(
        [Parameter(Mandatory = $true)][object]$Adapter,
        [Parameter(Mandatory = $true)][string]$InstancePath,
        [int]$SupportedGpuCount
    )
    $property = $Adapter.PSObject.Properties['InstancePath']
    $adapterPath = if ($null -eq $property) { '' } else { [string]$property.Value }
    if ([string]::IsNullOrWhiteSpace($adapterPath)) {
        if ($SupportedGpuCount -ne 1) {
            throw '既有 GPU-P adapter 没有 InstancePath，无法在多 GPU 宿主安全归属。'
        }
        return $true
    }
    return [string]::Equals(
        $adapterPath, $InstancePath,
        [System.StringComparison]::OrdinalIgnoreCase)
}
function Resolve-VMateGpuPExistingAdapter {
    param(
        [AllowEmptyCollection()][object[]]$Adapters,
        [Parameter(Mandatory = $true)][string]$InstancePath,
        [int]$SupportedGpuCount
    )
    if (@($Adapters).Count -gt 1) {
        throw '目标 VM 已有多个 GPU-P adapter；本方案每台 VM 只管理一个。'
    }
    if (@($Adapters).Count -eq 0) {
        return $null
    }
    if (-not (Test-VMateGpuPAdapterForGpu $Adapters[0] $InstancePath `
            $SupportedGpuCount)) {
        throw '目标 VM 的既有 GPU-P adapter 属于另一块物理 GPU。'
    }
    return $Adapters[0]
}
function Get-VMateGpuPOtherAllocations {
    param(
        [Parameter(Mandatory = $true)][object]$TargetVM,
        [Parameter(Mandatory = $true)][string]$InstancePath,
        [AllowEmptyCollection()][string[]]$HostGpuNames
    )
    $allocations = [System.Collections.Generic.List[object]]::new()
    try {
        $allVms = @(Get-VM -ErrorAction Stop)
    } catch {
        throw "无法枚举 Hyper-V VM 以核对 GPU-P 配额：$($_.Exception.Message)"
    }
    foreach ($vm in $allVms) {
        $sameVm = if ($null -ne $TargetVM.PSObject.Properties['Id'] -and
            $null -ne $vm.PSObject.Properties['Id']) {
            [string]$vm.Id -ceq [string]$TargetVM.Id
        } else {
            [string]::Equals([string]$vm.Name, [string]$TargetVM.Name,
                [System.StringComparison]::OrdinalIgnoreCase)
        }
        if ($sameVm) {
            continue
        }
        foreach ($adapter in @(Get-VMateGpuPAdaptersForVm $vm)) {
            $ownership = Get-VMateGpuPAdapterOwnership $adapter `
                $InstancePath $HostGpuNames
            if ($ownership.Ownership -ceq 'Unknown') {
                throw "VM [$($vm.Name)] 的 GPU-P adapter 路径为空、过期或重复，无法安全核算配额。"
            }
            if ($ownership.Ownership -ceq 'SelectedGpu') {
                [void]$allocations.Add($adapter)
            }
        }
    }
    return @($allocations)
}
function Get-VMateGpuPAdapterSettings {
    param([Parameter(Mandatory = $true)][object]$Source)
    $settings = [ordered]@{}
    foreach ($resource in @('VRAM', 'Encode', 'Decode', 'Compute')) {
        foreach ($bound in @('Min', 'Max', 'Optimal')) {
            $name = "${bound}Partition$resource"
            $settings[$name] = Get-VMateGpuPObjectUInt64 $Source $name 'GPU-P 配置'
        }
    }
    return $settings
}
function Get-VMateGpuPConfigurationPlan {
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [string]$InstancePath = '',
        [ValidateSet('Auto', 'NVIDIA', 'AMD')][string]$Vendor = 'Auto',
        [int]$VramPercentage = 100,
        [int]$EncodePercentage = 100,
        [int]$DecodePercentage = 100,
        [int]$ComputePercentage = 100,
        [switch]$AllowOvercommit,
        [AllowNull()][object]$QuotaRequest = $null,
        [AllowNull()][object]$ConsoleProfile = $null,
        [string]$PartitionIdentitySeed = '',
        [uint64]$LowMemoryMappedIoSpace = 1GB,
        [uint64]$HighMemoryMappedIoSpace = 32GB
    )
    Assert-VMateGpuPHostEnvironment
    if ($LowMemoryMappedIoSpace -eq 0 -or $HighMemoryMappedIoSpace -eq 0) {
        throw 'GPU-P 的 LowMMIO/HighMMIO 必须大于零。'
    }
    $allGpus = @(Get-VMateGpuPHostPartitionableGpu)
    $namedGpus = @($allGpus | Where-Object {
            $null -ne $_.PSObject.Properties['Name'] -and
            -not [String]::IsNullOrWhiteSpace([string]$_.Name)
        })
    $partitionableGpuCount = $allGpus.Count
    $uniqueNamedGpuCount = @($namedGpus | ForEach-Object {
            ([string]$_.Name).Trim().ToUpperInvariant()
        } | Sort-Object -Unique).Count
    $supportedCount = @($allGpus | Where-Object {
            try { [void](Get-VMateGpuPVendorInfo ([string]$_.Name)); $true }
            catch { $false }
        }).Count
    $addCommand = Get-Command -Name Add-VMGpuPartitionAdapter -ErrorAction Stop
    $vm = Get-VMateGpuPVirtualMachine $VMName
    Assert-VMateGpuPVirtualMachine $vm
    $currentAdapters = @(Get-VMateGpuPAdaptersForVm $vm)
    if ($currentAdapters.Count -gt 1) {
        throw '目标 VM 已有多个 GPU-P adapter；本方案每台 VM 只管理一个。'
    }
    # 重跑优先使用已绑定路径；首次配置才由显式路径或稳定 seed 选择。
    $effectivePath = $InstancePath
    if (-not $effectivePath -and $currentAdapters.Count -eq 1 -and
        $null -ne $currentAdapters[0].PSObject.Properties['InstancePath']) {
        $effectivePath = [string]$currentAdapters[0].InstancePath
    }
    $selected = Resolve-VMateGpuPHostGpu $allGpus $effectivePath $Vendor `
        $PartitionIdentitySeed
    $selectedPathCount = @($namedGpus | Where-Object {
            [string]::Equals([string]$_.Name,
                [string]$selected.VendorInfo.InstancePath,
                [StringComparison]::OrdinalIgnoreCase)
        }).Count
    if ($selectedPathCount -ne 1) {
        throw '所选 partitionable GPU 的 InstancePath 在当前宿主不唯一。'
    }
    $current = Resolve-VMateGpuPExistingAdapter $currentAdapters `
        $selected.VendorInfo.InstancePath $partitionableGpuCount
    $capabilitySnapshot = Get-VMateGpuPCapabilitySnapshot `
        $selected.Gpu $selected.VendorInfo
    if ($null -eq $QuotaRequest) {
        $QuotaRequest = Resolve-VMateGpuPQuotaCompatibilityRequest `
            -Percentages @{ VramPercentage = $VramPercentage
                EncodePercentage = $EncodePercentage
                DecodePercentage = $DecodePercentage
                ComputePercentage = $ComputePercentage } `
            -AllowOvercommit:$AllowOvercommit.IsPresent
    }
    $resourcePlan = Get-VMateGpuPResourcePlanForRequest $selected.Gpu $QuotaRequest
    $quotaNames = @((Get-VMateGpuPAdapterSettings $resourcePlan).Keys)
    $setCommand = Get-Command -Name Set-VMGpuPartitionAdapter -ErrorAction Stop
    $compat = Get-VMateGpuPCmdletCompatibility $addCommand $setCommand `
        $quotaNames $partitionableGpuCount $namedGpus.Count $uniqueNamedGpuCount
    $hostGpuNames = @($allGpus | ForEach-Object { [string]$_.Name })
    $others = @(Get-VMateGpuPOtherAllocations $vm `
        $selected.VendorInfo.InstancePath $hostGpuNames)
    $quota = Get-VMateGpuPQuotaSummary $selected.Gpu $resourcePlan $others
    if ($quota.Overcommitted -and -not $AllowOvercommit.IsPresent) {
        throw "GPU-P 多 VM 配额超出宿主总量；仅可显式使用 -AllowOvercommit：$($quota.Problems -join '；')"
    }
    $partitionCount = Get-VMateGpuPObjectUInt64 `
        $selected.Gpu 'PartitionCount' '宿主 GPU'
    if ([decimal]$others.Count + [decimal]1 -gt [decimal]$partitionCount) {
        throw "GPU-P partition 数量不足：需要 $($others.Count + 1)，总数 $partitionCount"
    }
    $identitySeed = if ($PartitionIdentitySeed) {
        ConvertTo-VMateGpuPPartitionIdentitySeed $PartitionIdentitySeed
    } else { '' }
    return [pscustomobject][ordered]@{
        VM = $vm
        VMName = [string]$vm.Name
        HostGpu = $selected.Gpu
        InstancePath = [string]$selected.VendorInfo.InstancePath
        Vendor = [string]$selected.VendorInfo.Vendor
        VendorId = [string]$selected.VendorInfo.VendorId
        CapabilitySnapshot = $capabilitySnapshot
        PartitionIdentitySeed = $identitySeed
        Action = if ($null -eq $current) { 'Add' } else { 'Set' }
        ExistingAdapter = $current
        ResourcePlan = $resourcePlan
        Quota = $quota
        SupportedGpuCount = $partitionableGpuCount
        SupportedVendorGpuCount = $supportedCount
        SupportsInstancePath = $compat.SupportsInstancePath
        AddTargetParameter = $compat.AddTargetParameter
        AddQuotaParameters = @($compat.AddQuotaParameters)
        AllowOvercommit = $AllowOvercommit.IsPresent
        ConsoleProfile = if ($null -eq $ConsoleProfile) { $null } else {
            New-VMateHyperVConsoleProfile `
                -ResolutionType ([string]$ConsoleProfile.ResolutionType) `
                -HorizontalResolution ([int]$ConsoleProfile.HorizontalResolution) `
                -VerticalResolution ([int]$ConsoleProfile.VerticalResolution)
        }
        LowMemoryMappedIoSpace = $LowMemoryMappedIoSpace
        HighMemoryMappedIoSpace = $HighMemoryMappedIoSpace
    }
}
function Invoke-VMateGpuPConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [string]$InstancePath = '',
        [ValidateSet('Auto', 'NVIDIA', 'AMD')][string]$Vendor = 'Auto',
        [ValidateRange(1, 100)][int]$VramPercentage = 100,
        [ValidateRange(1, 100)][int]$EncodePercentage = 100,
        [ValidateRange(1, 100)][int]$DecodePercentage = 100,
        [ValidateRange(1, 100)][int]$ComputePercentage = 100,
        [switch]$AllowOvercommit,
        [AllowNull()][object]$QuotaRequest = $null,
        [AllowNull()][object]$ConsoleProfile = $null,
        [string]$PartitionIdentitySeed = '',
        [switch]$DryRun,
        [uint64]$LowMemoryMappedIoSpace = 1GB,
        [uint64]$HighMemoryMappedIoSpace = 32GB
    )
    $configurationLock = Enter-VMateGpuPConfigurationLock
    try {
    $planParameters = @{}
    foreach ($name in $PSBoundParameters.Keys) {
        $planParameters[$name] = $PSBoundParameters[$name]
    }
    [void]$planParameters.Remove('DryRun')
    $plan = Get-VMateGpuPConfigurationPlan @planParameters
    if ($DryRun.IsPresent) {
        return $plan
    }
    $vmSnapshot = Get-VMateGpuPVMConfigurationSnapshot $plan.VM
    $oldAdapterSettings = if ($null -ne $plan.ExistingAdapter) {
        Get-VMateGpuPAdapterSettings $plan.ExistingAdapter
    } else { $null }
    $vmAttempted = $false
    $adapterAttempted = $false
    $createdAdapters = @()
    try {
        if (-not (Test-VMateGpuPVMConfigurationMatch $vmSnapshot $plan)) {
            $vmAttempted = $true
            Set-VM -VM $plan.VM -GuestControlledCacheTypes $true `
                -LowMemoryMappedIoSpace $plan.LowMemoryMappedIoSpace `
                -HighMemoryMappedIoSpace $plan.HighMemoryMappedIoSpace `
                -CheckpointType Disabled -Confirm:$false -ErrorAction Stop
        }
        $settings = Get-VMateGpuPAdapterSettings $plan.ResourcePlan
        $adapterAttempted = $true
        if ($plan.Action -ceq 'Add') {
            $parameters = @{ Confirm = $false; ErrorAction = 'Stop'; Passthru = $true }
            $parameters[$plan.AddTargetParameter] = if (
                $plan.AddTargetParameter -ceq 'VM') { $plan.VM } else { $plan.VMName }
            foreach ($name in $plan.AddQuotaParameters) {
                $parameters[$name] = $settings[$name]
            }
            # Win10 无 -InstancePath 时只允许已预检的唯一单 GPU。
            if ($plan.SupportsInstancePath) {
                $parameters['InstancePath'] = $plan.InstancePath
            }
            $createdAdapters = @(Add-VMGpuPartitionAdapter @parameters)
            if ($createdAdapters.Count -ne 1) {
                $createdAdapters = @(Get-VMateGpuPAdaptersForVm $plan.VM)
            }
            $created = Resolve-VMateGpuPExistingAdapter $createdAdapters `
                $plan.InstancePath $plan.SupportedGpuCount
            if ($plan.AddQuotaParameters.Count -ne $settings.Count) {
                $setParameters = @{
                    VMGpuPartitionAdapter = $created
                    Confirm = $false
                    ErrorAction = 'Stop'
                }
                foreach ($name in $settings.Keys) {
                    $setParameters[$name] = $settings[$name]
                }
                [void](Set-VMGpuPartitionAdapter @setParameters)
            }
        } else {
            $settings['VMGpuPartitionAdapter'] = $plan.ExistingAdapter
            $settings['Confirm'] = $false
            $settings['ErrorAction'] = 'Stop'
            [void](Set-VMGpuPartitionAdapter @settings)
        }
        Assert-VMateGpuPAppliedState $plan
        $consoleResult = if ($null -eq $plan.ConsoleProfile) { $null } else {
            Set-VMateHyperVConsoleProfile -VM $plan.VM `
                -Profile $plan.ConsoleProfile
        }
    } catch {
        $original = $_.Exception.Message
        $rollback = [System.Collections.Generic.List[string]]::new()
        if ($adapterAttempted) {
            try {
                if ($plan.Action -ceq 'Add') {
                    # Passthru 对象可精确删除本事务新增项。若 Add 在返回前抛错，
                    # 才回读 VM 并只移除匹配物理路径的 adapter。
                    $removeTargets = $createdAdapters
                    if ($removeTargets.Count -eq 0) {
                        $removeTargets = @(Get-VMateGpuPAdaptersForVm $plan.VM |
                            Where-Object {
                                Test-VMateGpuPAdapterForGpu $_ `
                                    $plan.InstancePath $plan.SupportedGpuCount
                            })
                    }
                    foreach ($adapter in $removeTargets) {
                        Remove-VMGpuPartitionAdapter `
                            -VMGpuPartitionAdapter $adapter -Confirm:$false `
                            -ErrorAction Stop
                    }
                } else {
                    $restore = @{}
                    foreach ($name in $oldAdapterSettings.Keys) {
                        $restore[$name] = $oldAdapterSettings[$name]
                    }
                    $restore['VMGpuPartitionAdapter'] = $plan.ExistingAdapter
                    $restore['Confirm'] = $false
                    $restore['ErrorAction'] = 'Stop'
                    [void](Set-VMGpuPartitionAdapter @restore)
                }
            } catch {
                [void]$rollback.Add("adapter 回滚失败：$($_.Exception.Message)")
            }
        }
        if ($vmAttempted) {
            try {
                Set-VM -VM $plan.VM `
                    -GuestControlledCacheTypes $vmSnapshot.GuestControlledCacheTypes `
                    -LowMemoryMappedIoSpace $vmSnapshot.LowMemoryMappedIoSpace `
                    -HighMemoryMappedIoSpace $vmSnapshot.HighMemoryMappedIoSpace `
                    -CheckpointType $vmSnapshot.CheckpointType -Confirm:$false `
                    -ErrorAction Stop
            } catch {
                [void]$rollback.Add("VM 配置回滚失败：$($_.Exception.Message)")
            }
        }
        $suffix = if ($rollback.Count -eq 0) {
            '已按事务记录完成回滚。'
        } else {
            "回滚不完整：$($rollback -join '；')"
        }
        throw "GPU-P 配置失败：$original；$suffix"
    }
    return [pscustomobject][ordered]@{
        Succeeded = $true
        DryRun = $false
        Action = $plan.Action
        VMName = $plan.VMName
        InstancePath = $plan.InstancePath
        Vendor = $plan.Vendor
        VendorId = $plan.VendorId
        CapabilitySnapshot = $plan.CapabilitySnapshot
        PartitionIdentitySeed = $plan.PartitionIdentitySeed
        ResourcePlan = $plan.ResourcePlan
        Quota = $plan.Quota
        ConsoleProfile = $consoleResult
        VMSettingsChanged = $vmAttempted
    }
    }
    finally {
        Exit-VMateGpuPConfigurationLock -Mutex $configurationLock
    }
}

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$VMName,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$VhdPath,
    [ValidateSet('Auto', 'NVIDIA', 'AMD')][string]$Vendor = 'Auto',
    [string]$InstancePath = '',
    [ValidateRange(1, 256)][int]$ProcessorCount = 4,
    [ValidateRange(1, 100)][int]$CpuMaximumPercent = 100,
    [ValidateRange(0, 100)][int]$CpuReservePercent = 0,
    [ValidateRange(1, 10000)][int]$CpuRelativeWeight = 100,
    [ValidateRange(1, 64)][int]$HwThreadCountPerCore = 1,
    [bool]$ExposeVirtualizationExtensions = $false,
    [string]$HardwareProfileId = 'host-native',
    [string]$HardwareProfileCatalogPath = '',
    [switch]$RequireFullHardwareIdentity,
    [string]$BIOSGUID = '',
    [string]$BIOSSerialNumber = '',
    [string]$BaseBoardSerialNumber = '',
    [string]$ChassisSerialNumber = '',
    [string]$ChassisAssetTag = '',
    [string]$StaticMacAddress = '',
    [ValidateRange(1073741824, 1099511627776)][UInt64]$MemoryStartupBytes = 8GB,
    [string]$SwitchName = '',
    [switch]$CreateVhd,
    [ValidateRange(21474836480, 70368744177664)][UInt64]$VhdSizeBytes = 127GB,
    [string]$IsoPath = '',
    [string]$BaseImagePath = '',
    [ValidateRange(1, 100)][int]$GpuPercentage = 50,
    [UInt64]$LowMemoryMappedIoSpace = 1GB,
    [UInt64]$HighMemoryMappedIoSpace = 32GB,
    [ValidateSet('Default', 'Maximum', 'Single')]
    [string]$ConsoleResolutionType = 'Default',
    [ValidateRange(640, 8192)][int]$ConsoleHorizontalResolution = 1920,
    [ValidateRange(480, 8192)][int]$ConsoleVerticalResolution = 1200,
    [string]$ConfigurationVersion = '',
    [switch]$AllowOvercommit,
    [switch]$FullSharedGpuQuota,
    [switch]$Win10ReferenceGpuQuota,
    [switch]$SkipDriverSync,
    [switch]$StartVM,
    [switch]$ValidateGuest,
    [PSCredential]$GuestCredential,
    [bool]$StrictGuestDisplay = $true,
    [switch]$DisableHyperVVideo,
    [switch]$RequireNvidiaSmi,
    [ValidateRange(10, 300)][int]$GuestValidationTimeoutSeconds = 90,
    [string]$StateRoot = '',
    [string]$PartitionIdentitySeed = '',
    [ValidateRange(0, 65535)][int]$GuestCapacity = 2,
    [ValidateRange(1, 300)][int]$HostLockTimeoutSeconds = 120,
    [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VMate.GpuP.Host.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.Lifecycle.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.Partition.ps1')
$hardwareProfile = Resolve-VMateGpuPHardwareProfile `
    -ProfileId $HardwareProfileId `
    -CatalogPath $HardwareProfileCatalogPath `
    -RequireFullIdentity:$RequireFullHardwareIdentity.IsPresent
[void](Assert-VMateGpuPHardwareProfileOverrides $hardwareProfile $PSBoundParameters)
if (-not $PSBoundParameters.ContainsKey('ProcessorCount')) {
    $ProcessorCount = [int]$hardwareProfile.Processor.Count
}
if (-not $PSBoundParameters.ContainsKey('CpuMaximumPercent')) {
    $CpuMaximumPercent = [int]$hardwareProfile.Processor.MaximumPercent
}
if (-not $PSBoundParameters.ContainsKey('CpuReservePercent')) {
    $CpuReservePercent = [int]$hardwareProfile.Processor.ReservePercent
}
if (-not $PSBoundParameters.ContainsKey('CpuRelativeWeight')) {
    $CpuRelativeWeight = [int]$hardwareProfile.Processor.RelativeWeight
}
if (-not $PSBoundParameters.ContainsKey('HwThreadCountPerCore')) {
    $HwThreadCountPerCore = [int]$hardwareProfile.Processor.HwThreadsPerCore
}
if (-not $PSBoundParameters.ContainsKey('ExposeVirtualizationExtensions')) {
    $ExposeVirtualizationExtensions = [bool](
        $hardwareProfile.Processor.ExposeVirtualizationExtensions)
}
if (-not $PSBoundParameters.ContainsKey('MemoryStartupBytes')) {
    $MemoryStartupBytes = [uint64]$hardwareProfile.Memory.startup_bytes
}
$profileGpu = $hardwareProfile.Gpu
if (-not $PSBoundParameters.ContainsKey('LowMemoryMappedIoSpace')) {
    $LowMemoryMappedIoSpace = [uint64]$profileGpu.low_mmio_bytes
}
if (-not $PSBoundParameters.ContainsKey('HighMemoryMappedIoSpace')) {
    $HighMemoryMappedIoSpace = [uint64]$profileGpu.high_mmio_bytes
}
if (-not $PSBoundParameters.ContainsKey('ConsoleResolutionType')) {
    $ConsoleResolutionType = [string]$profileGpu.console_resolution_type
}
if (-not $PSBoundParameters.ContainsKey('ConsoleHorizontalResolution')) {
    $ConsoleHorizontalResolution = [int]$profileGpu.console_horizontal_resolution
}
if (-not $PSBoundParameters.ContainsKey('ConsoleVerticalResolution')) {
    $ConsoleVerticalResolution = [int]$profileGpu.console_vertical_resolution
}
if (-not $PSBoundParameters.ContainsKey('ConfigurationVersion')) {
    $ConfigurationVersion = [string]$profileGpu.vm_configuration_version
}
if (-not $PSBoundParameters.ContainsKey('GpuPercentage') -and
    -not $PSBoundParameters.ContainsKey('FullSharedGpuQuota') -and
    -not $PSBoundParameters.ContainsKey('Win10ReferenceGpuQuota')) {
    if ([string]$profileGpu.quota_profile -ceq 'win10-reference-100') {
        $Win10ReferenceGpuQuota = [Management.Automation.SwitchParameter]$true
    } elseif ([string]$profileGpu.quota_profile -ceq
        'full-all-shared-resources') {
        $FullSharedGpuQuota = [Management.Automation.SwitchParameter]$true
    }
}
$consoleProfile = New-VMateHyperVConsoleProfile $ConsoleResolutionType `
    $ConsoleHorizontalResolution $ConsoleVerticalResolution
if ($CreateVhd -and $ValidateGuest) {
    throw '空 VHDX 尚未安装系统；完成 Windows 安装并关机后再执行 guest 验证。'
}
if ($ValidateGuest -and -not $StartVM) {
    throw '-ValidateGuest 要求同时使用 -StartVM。'
}
if (-not $ValidateGuest -and ($DisableHyperVVideo -or $RequireNvidiaSmi -or
        $null -ne $GuestCredential)) {
    throw 'GuestCredential/DisableHyperVVideo/RequireNvidiaSmi 只可与 -ValidateGuest 一起使用。'
}
$requiresCredential = $ValidateGuest -and $null -eq $GuestCredential
if ($requiresCredential) {
    throw '-ValidateGuest 要求显式传入 -GuestCredential。'
}
if (-not [String]::IsNullOrWhiteSpace($PartitionIdentitySeed) -and
    $PartitionIdentitySeed -notmatch '^[0-9a-fA-F]{64}$') {
    throw 'PartitionIdentitySeed 必须是 64 位十六进制字符串。'
}
$explicitQuotaNames = if ($PSBoundParameters.ContainsKey('GpuPercentage')) {
    @('VramPercentage', 'EncodePercentage',
        'DecodePercentage', 'ComputePercentage')
} else { @() }
$quotaRequest = Resolve-VMateGpuPQuotaCompatibilityRequest -Percentages @{
    VramPercentage = $GpuPercentage
    EncodePercentage = $GpuPercentage
    DecodePercentage = $GpuPercentage
    ComputePercentage = $GpuPercentage
} -ExplicitNames $explicitQuotaNames `
    -FullSharedGpuQuota:$FullSharedGpuQuota.IsPresent `
    -Win10ReferenceGpuQuota:$Win10ReferenceGpuQuota.IsPresent `
    -AllowOvercommit:$AllowOvercommit.IsPresent
$GpuPercentage = [int]$quotaRequest.Percentages.VramPercentage
$effectiveAllowOvercommit = [bool]$quotaRequest.EffectiveAllowOvercommit
$firmwareValues = @($BIOSGUID, $BIOSSerialNumber,
    $BaseBoardSerialNumber, $ChassisSerialNumber, $ChassisAssetTag)
$firmwareIdentity = if (@($firmwareValues | Where-Object {
            -not [String]::IsNullOrWhiteSpace([string]$_)
        }).Count -eq 0) { $null } else {
    [pscustomobject][ordered]@{
        BIOSGUID = $BIOSGUID
        BIOSSerialNumber = $BIOSSerialNumber
        BaseBoardSerialNumber = $BaseBoardSerialNumber
        ChassisSerialNumber = $ChassisSerialNumber
        ChassisAssetTag = $ChassisAssetTag
    }
}
Assert-VMateGpuPHostEnvironment
$seed = if ([String]::IsNullOrWhiteSpace($PartitionIdentitySeed)) {
    New-VMateGpuPRandomHex -ByteCount 32
} else { $PartitionIdentitySeed.Trim().ToLowerInvariant() }
$hostGpus = @(Get-VMateGpuPHostPartitionableGpu)
$selected = Resolve-VMateGpuPHostGpu -Gpus $hostGpus `
    -InstancePath $InstancePath -Vendor $Vendor `
    -PartitionIdentitySeed $seed
if ([string]$selected.VendorInfo.Vendor -ieq 'AMD' -and
    $RequireNvidiaSmi) {
    throw 'Auto 选择到 AMD GPU，不能要求 nvidia-smi。'
}
# 在 New-VM 前完成 cmdlet、GPU 能力和分区容量预检。
$resourcePreview = Get-VMateGpuPResourcePlanForRequest $selected.Gpu $quotaRequest
$capabilityPreview = Get-VMateGpuPCapabilitySnapshot `
    $selected.Gpu $selected.VendorInfo
$fullHostVramQuotaPreview = (
    [uint64]$resourcePreview.MaxPartitionVRAM -eq
    [uint64]$capabilityPreview.Resources.VRAM.Total)
if ($FullSharedGpuQuota) {
    [void](Assert-VMateGpuPFullHostVramQuota $resourcePreview `
            $capabilityPreview `
            '所选 GPU 不能提供宿主报告的全部 VRAM 配额；未创建 VM。')
}
$quotaNames = @((Get-VMateGpuPAdapterSettings $resourcePreview).Keys)
$namedGpus = @($hostGpus | Where-Object {
        $null -ne $_.PSObject.Properties['Name'] -and
        -not [String]::IsNullOrWhiteSpace([string]$_.Name)
    })
$uniqueNamedGpuCount = @($namedGpus | ForEach-Object {
        ([string]$_.Name).Trim().ToUpperInvariant()
    } | Sort-Object -Unique).Count
[void](Get-VMateGpuPCmdletCompatibility `
        (Get-Command Add-VMGpuPartitionAdapter -ErrorAction Stop) `
        (Get-Command Set-VMGpuPartitionAdapter -ErrorAction Stop) `
        $quotaNames $hostGpus.Count $namedGpus.Count $uniqueNamedGpuCount)
$partitionCapacityPlan = $null
if ($GuestCapacity -gt 0) {
    $partitionCapacityPlan = Get-VMateGpuPPartitionCountPlan `
        -HostGpu $selected.Gpu -GuestCapacity $GuestCapacity
    if ($partitionCapacityPlan.ChangeRequired) {
        if (-not (Test-VMateGpuPHostPartitionSetter)) {
            throw ('当前 Hyper-V 模块缺少可用的 GPU-P PartitionCount setter；' +
                '现有 PartitionCount 不足，未创建 VM。')
        }
        $assigned = @(Get-VMateGpuPAssignedAdapterSnapshot `
                -InstancePath ([string]$selected.VendorInfo.InstancePath))
        if ($assigned.Count -ne 0) {
            throw ('所选 GPU 已有或存在归属不明的 GPU-P adapter，' +
                '无法安全扩容 PartitionCount；未创建 VM。')
        }
    }
}
$creationParameters = @{
    VMName = $VMName
    VhdPath = $VhdPath
    ProcessorCount = $ProcessorCount
    CpuMaximumPercent = $CpuMaximumPercent
    CpuReservePercent = $CpuReservePercent
    CpuRelativeWeight = $CpuRelativeWeight
    HwThreadCountPerCore = $HwThreadCountPerCore
    ExposeVirtualizationExtensions = $ExposeVirtualizationExtensions
    HardwareProfileId = $HardwareProfileId
    HardwareProfileCatalogPath = $HardwareProfileCatalogPath
    RequireFullHardwareIdentity = $RequireFullHardwareIdentity
    FirmwareIdentity = $firmwareIdentity
    StaticMacAddress = $StaticMacAddress
    ConfigurationVersion = $ConfigurationVersion
    ConsoleProfile = $consoleProfile
    MemoryStartupBytes = $MemoryStartupBytes
    Vendor = [string]$selected.VendorInfo.Vendor
    PartitionIdentitySeed = $seed
    SwitchName = $SwitchName
    IsoPath = $IsoPath
    BaseImagePath = $BaseImagePath
    CreateVhd = $CreateVhd
    VhdSizeBytes = $VhdSizeBytes
    StateRoot = $StateRoot
    DryRun = $DryRun
}
if ($DryRun) {
    $creationPlanParameters = @{} + $creationParameters
    [void]$creationPlanParameters.Remove('StateRoot')
    [void]$creationPlanParameters.Remove('DryRun')
    $creationPlan = Get-VMateGpuPVirtualMachinePlan @creationPlanParameters
    return [pscustomobject][ordered]@{
        Status = 'DryRun'
        Backend = 'Hyper-V GPU-P'
        Creation = $creationPlan
        SelectedVendor = [string]$selected.VendorInfo.Vendor
        SelectedVendorId = [string]$selected.VendorInfo.VendorId
        SelectedInstancePath = [string]$selected.VendorInfo.InstancePath
        PartitionIdentitySeed = $seed
        GpuPercentage = $GpuPercentage
        CapabilitySnapshot = $capabilityPreview
        QuotaMode = [string]$quotaRequest.QuotaMode
        EffectiveAllowOvercommit = $effectiveAllowOvercommit
        FullHostVramQuota = $fullHostVramQuotaPreview
        HostPartitionCapacityPlan = $partitionCapacityPlan
        PhysicalGpuSerialPolicy = 'vendor-managed-read-only'
        HardwareIdentityPolicy = 'custom-or-random-once-persisted-on-create'
        HardwareProfile = $creationPlan.HardwareProfile
        IdentityBoot = $creationPlan.IdentityBoot; HostIdentityExtension = $creationPlan.HostIdentityExtension
        WillDeferGpuProvisioning = $CreateVhd.IsPresent
        WillCloneBaseImage = -not [String]::IsNullOrWhiteSpace($BaseImagePath)
        WillStartVM = $StartVM.IsPresent
        WillValidateGuest = $ValidateGuest.IsPresent
    }
}
$created = New-VMateGpuPVirtualMachine @creationParameters
$operation = '固定物理 GPU 身份'
try {
    $createdIdentity = Set-VMateGpuPIdentityBinding -VMId $created.VM.Id `
        -Vendor ([string]$selected.VendorInfo.Vendor) `
        -GpuInstancePath ([string]$selected.VendorInfo.InstancePath) `
        -StateRoot $StateRoot
    if ($CreateVhd) {
        $operation = '启动 Windows 安装阶段 VM'
        if ($StartVM) {
            Start-VM -VM $created.VM -ErrorAction Stop | Out-Null
        }
        return [pscustomobject][ordered]@{
            Status = if ($StartVM) { 'InstallingWindows' } else { 'CreatedForInstallation' }
            Backend = 'Hyper-V GPU-P'
            VMName = $VMName
            VMId = [string]$created.VM.Id
            VhdPath = [string]$created.Plan.VhdPath
            VhdBlockSizeBytes = [uint64]$created.Plan.VhdBlockSizeBytes
            Vendor = [string]$selected.VendorInfo.Vendor
            InstancePath = [string]$selected.VendorInfo.InstancePath
            PartitionIdentitySeed = [string]$createdIdentity.PartitionIdentitySeed
            HostPartitionCapacityPlan = $partitionCapacityPlan
            CapabilitySnapshot = $capabilityPreview
            QuotaMode = [string]$quotaRequest.QuotaMode
            EffectiveAllowOvercommit = $effectiveAllowOvercommit
            FullHostVramQuota = $fullHostVramQuotaPreview
            HardwareIdentity = $created.HardwareIdentity
            HardwareProfile = $created.HardwareProfile
            IdentityBoot = $created.IdentityBoot; HostIdentityExtension = $created.HostIdentityExtension
            ComputeProfile = $created.ComputeProfile
            ResumeArguments = [pscustomobject][ordered]@{
                VMName = $VMName
                Vendor = [string]$selected.VendorInfo.Vendor
                InstancePath = [string]$selected.VendorInfo.InstancePath
                VhdPath = [string]$created.Plan.VhdPath
                VramPercentage = $GpuPercentage
                EncodePercentage = $GpuPercentage
                DecodePercentage = $GpuPercentage
                ComputePercentage = $GpuPercentage
                FullSharedGpuQuota = $FullSharedGpuQuota.IsPresent
                Win10ReferenceGpuQuota = $Win10ReferenceGpuQuota.IsPresent
                LowMemoryMappedIoSpace = $LowMemoryMappedIoSpace
                HighMemoryMappedIoSpace = $HighMemoryMappedIoSpace
                ConsoleResolutionType = $consoleProfile.ResolutionType
                ConsoleHorizontalResolution = $consoleProfile.HorizontalResolution
                ConsoleVerticalResolution = $consoleProfile.VerticalResolution
                GuestCapacity = $GuestCapacity
                HostLockTimeoutSeconds = $HostLockTimeoutSeconds
                PartitionIdentitySeed = [string]$createdIdentity.PartitionIdentitySeed
            }
            NextAction = if ($FullSharedGpuQuota) {
                "安装 Windows 并完全关机后运行 Enable-VMateGpuP.ps1 -FullSharedGpuQuota -GuestCapacity $GuestCapacity。"
            }
            else {
                "安装 Windows 并完全关机后使用 ResumeArguments 运行 Enable-VMateGpuP.ps1。"
            }
        }
    }
    $operation = '同步驱动并启用 GPU-P'
    $enableScript = Join-Path $PSScriptRoot 'Enable-VMateGpuP.ps1'
    $enableParameters = @{
        VMName = $VMName
        Vendor = [string]$selected.VendorInfo.Vendor
        InstancePath = [string]$selected.VendorInfo.InstancePath
        VhdPath = [string]$created.Plan.VhdPath
        VramPercentage = $GpuPercentage
        EncodePercentage = $GpuPercentage
        DecodePercentage = $GpuPercentage
        ComputePercentage = $GpuPercentage
        LowMemoryMappedIoSpace = $LowMemoryMappedIoSpace
        HighMemoryMappedIoSpace = $HighMemoryMappedIoSpace
        AllowOvercommit = $effectiveAllowOvercommit
        FullSharedGpuQuota = $FullSharedGpuQuota
        Win10ReferenceGpuQuota = $Win10ReferenceGpuQuota
        ConsoleResolutionType = $consoleProfile.ResolutionType
        ConsoleHorizontalResolution = $consoleProfile.HorizontalResolution
        ConsoleVerticalResolution = $consoleProfile.VerticalResolution
        SkipDriverSync = $SkipDriverSync
        StartVM = $StartVM
        ValidateGuest = $ValidateGuest
        GuestCredential = $GuestCredential
        StrictGuestDisplay = $StrictGuestDisplay
        DisableHyperVVideo = $DisableHyperVVideo
        RequireNvidiaSmi = $RequireNvidiaSmi
        GuestValidationTimeoutSeconds = $GuestValidationTimeoutSeconds
        StateRoot = $StateRoot
        PartitionIdentitySeed = $seed
        GuestCapacity = $GuestCapacity
        HostLockTimeoutSeconds = $HostLockTimeoutSeconds
    }
    $gpuResult = & $enableScript @enableParameters
    return [pscustomobject][ordered]@{
        Status = [string]$gpuResult.Status
        Backend = 'Hyper-V GPU-P'
        VMName = $VMName
        VMId = [string]$created.VM.Id
        VhdPath = [string]$created.Plan.VhdPath
        Vendor = [string]$gpuResult.Vendor
        DeviceName = [string]$gpuResult.DeviceName
        InstancePath = [string]$gpuResult.InstancePath
        DriverVersion = [string]$gpuResult.DriverVersion
        PartitionId = $gpuResult.PartitionId
        PartitionVfLuid = $gpuResult.PartitionVfLuid
        PartitionIdentitySeed = $seed
        PhysicalGpuSerialPolicy = [string]$gpuResult.PhysicalGpuSerialPolicy
        ResourcePlan = $gpuResult.ResourcePlan
        CapabilitySnapshot = $gpuResult.CapabilitySnapshot
        Quota = $gpuResult.Quota
        QuotaMode = [string]$gpuResult.QuotaMode
        EffectiveAllowOvercommit = [bool]$gpuResult.EffectiveAllowOvercommit
        FullHostVramQuota = [bool]$gpuResult.FullHostVramQuota
        HostPartitionCapacity = $gpuResult.HostPartitionCapacity
        HardwareIdentity = $gpuResult.HardwareIdentity
        HardwareProfile = $created.HardwareProfile
        IdentityBoot = $gpuResult.IdentityBoot; HostIdentityExtension = $gpuResult.HostIdentityExtension
        ComputeProfile = $created.ComputeProfile
        ConsoleProfile = $gpuResult.ConsoleProfile
        GuestValidation = $gpuResult.GuestValidation
    }
}
catch {
    $primaryError = $_.Exception.Message
    $rollbackErrors = [System.Collections.Generic.List[string]]::new()
    $liveVm = $null
    $inventoryReadable = $true
    try {
        $matches = @(Get-VM -ErrorAction Stop | Where-Object {
                [string]$_.Id -ceq [string]$created.VM.Id
            })
        if ($matches.Count -gt 1) {
            throw '同一 VMId 回读到多个 Hyper-V VM。'
        }
        if ($matches.Count -eq 1) { $liveVm = $matches[0] }
    }
    catch {
        $inventoryReadable = $false
        [void]$rollbackErrors.Add("无法回读 VM 注册状态：$($_.Exception.Message)")
    }
    $adapterCount = -1
    if ($null -ne $liveVm) {
        try {
            $adapterCount = @(Get-VMGpuPartitionAdapter -VM $liveVm `
                    -ErrorAction Stop).Count
        }
        catch {
            [void]$rollbackErrors.Add(
                "无法回读 GPU-P adapter：$($_.Exception.Message)")
        }
    }
    $vmUnregistered = $inventoryReadable -and $null -eq $liveVm
    if ($null -ne $liveVm -and [string]$liveVm.State -ceq 'Off' -and
        $adapterCount -eq 0) {
        $safeToUnregister = $true
        if ($null -ne $created.IdentityBoot -and
            [string]$created.IdentityBoot.Status -in @('Installed', 'Reinstalled')) {
            try {
                [void](Uninstall-VMateHyperVIdentityBoot -VM $liveVm)
            }
            catch {
                $safeToUnregister = $false
                [void]$rollbackErrors.Add(
                    "回滚本次 identity boot 失败：$($_.Exception.Message)")
            }
        }
        if ($safeToUnregister) {
            try {
                Remove-VM -VM $liveVm -Force -Confirm:$false -ErrorAction Stop
                $remaining = @(Get-VM -ErrorAction Stop | Where-Object {
                        [string]$_.Id -ceq [string]$created.VM.Id
                    })
                if ($remaining.Count -ne 0) {
                    throw '回读发现 VM 仍在 Hyper-V 注册。'
                }
                $vmUnregistered = $true
            }
            catch {
                [void]$rollbackErrors.Add(
                    "注销本次 VM 失败：$($_.Exception.Message)")
            }
        }
        else {
            [void]$rollbackErrors.Add(
                'identity boot 未安全回滚；保留 VM、身份清单和 VHD。')
        }
    }
    elseif ($null -ne $liveVm) {
        [void]$rollbackErrors.Add(
            "VM 状态=$($liveVm.State)，adapter 数=$adapterCount；保留诊断状态。")
    }
    if ($vmUnregistered) {
        try {
            if (Test-Path -LiteralPath $created.IdentityPath -PathType Leaf) {
                Remove-Item -LiteralPath $created.IdentityPath -Force `
                    -ErrorAction Stop
            }
        }
        catch {
            [void]$rollbackErrors.Add(
                "删除本次身份清单失败：$($_.Exception.Message)")
        }
        if ($created.Plan.CreateVhd) {
            try {
                if (Test-Path -LiteralPath $created.Plan.VhdPath -PathType Leaf) {
                    Remove-Item -LiteralPath $created.Plan.VhdPath -Force `
                        -ErrorAction Stop
                }
            }
            catch {
                [void]$rollbackErrors.Add(
                    "删除本次空 VHD 失败：$($_.Exception.Message)")
            }
        }
    }
    else {
        [void]$rollbackErrors.Add(
            '未确认 VM 已注销；身份清单和 VHD 均保留。')
    }
    $rollbackSummary = if ($rollbackErrors.Count -eq 0) {
        if ($created.Plan.CreateVhd) {
            '已回滚 VM、身份和本次空 VHD。'
        }
        else { '已回滚 VM 与身份；用户 VHD 保留。' }
    }
    else { $rollbackErrors -join '；' }
    throw "新 VM 在${operation}时失败：$primaryError；$rollbackSummary"
}

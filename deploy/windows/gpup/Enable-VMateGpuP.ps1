#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [ValidateSet('Auto', 'NVIDIA', 'AMD')]
    [string]$Vendor = 'Auto',

    [string]$InstancePath = '',

    [string]$VhdPath = '',

    [ValidateRange(1, 100)]
    [int]$VramPercentage = 50,

    [ValidateRange(1, 100)]
    [int]$EncodePercentage = 50,

    [ValidateRange(1, 100)]
    [int]$DecodePercentage = 50,

    [ValidateRange(1, 100)]
    [int]$ComputePercentage = 50,

    [UInt64]$LowMemoryMappedIoSpace = 1GB,

    [UInt64]$HighMemoryMappedIoSpace = 32GB,

    [switch]$AllowOvercommit,

    [switch]$FullSharedGpuQuota,

    [switch]$Win10ReferenceGpuQuota,

    [ValidateSet('Unchanged', 'Default', 'Maximum', 'Single')]
    [string]$ConsoleResolutionType = 'Unchanged',

    [ValidateRange(640, 8192)][int]$ConsoleHorizontalResolution = 1920,

    [ValidateRange(480, 8192)][int]$ConsoleVerticalResolution = 1200,

    [switch]$SkipDriverSync,
    [switch]$StartVM,
    [switch]$RequireFullHardwareIdentity,
    [switch]$ValidateGuest,
    [PSCredential]$GuestCredential,
    [bool]$StrictGuestDisplay = $true,
    [switch]$DisableHyperVVideo,
    [switch]$RequireNvidiaSmi,

    [ValidateRange(10, 300)]
    [int]$GuestValidationTimeoutSeconds = 90,

    [string]$StateRoot = '',
    [string]$ArtifactManifestPath = '',
    [string]$PartitionIdentitySeed = '',

    [ValidateRange(0, 65535)]
    [int]$GuestCapacity = 2,

    [ValidateRange(1, 300)]
    [int]$HostLockTimeoutSeconds = 120,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.GpuP.Host.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.DriverStore.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.Identity.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.HardwareIdentity.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.HardwareProfile.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.Guest.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.Partition.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.IdentityBoot.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.HostIdentityExtension.ps1')

if ($ValidateGuest -and -not $StartVM) {
    throw '-ValidateGuest 要求同时使用 -StartVM。'
}
if (-not $ValidateGuest -and ($DisableHyperVVideo -or $RequireNvidiaSmi -or
        $null -ne $GuestCredential)) {
    throw 'GuestCredential/DisableHyperVVideo/RequireNvidiaSmi 只可与 -ValidateGuest 一起使用。'
}
if ($ValidateGuest -and $null -eq $GuestCredential) {
    throw '-ValidateGuest 要求显式传入 -GuestCredential；凭据不会写入状态清单。'
}
if ($Vendor -ieq 'AMD' -and $RequireNvidiaSmi) {
    throw 'AMD GPU-P 不能要求 nvidia-smi。'
}
if (-not [String]::IsNullOrWhiteSpace($PartitionIdentitySeed) -and
    $PartitionIdentitySeed -notmatch '^[0-9a-fA-F]{64}$') {
    throw 'PartitionIdentitySeed 必须是 64 位十六进制字符串。'
}
$percentageNames = @('VramPercentage', 'EncodePercentage',
    'DecodePercentage', 'ComputePercentage')
$quotaRequest = Resolve-VMateGpuPQuotaCompatibilityRequest -Percentages @{
    VramPercentage = $VramPercentage
    EncodePercentage = $EncodePercentage
    DecodePercentage = $DecodePercentage
    ComputePercentage = $ComputePercentage
} -ExplicitNames @($percentageNames | Where-Object {
        $PSBoundParameters.ContainsKey($_)
    }) -FullSharedGpuQuota:$FullSharedGpuQuota.IsPresent `
    -Win10ReferenceGpuQuota:$Win10ReferenceGpuQuota.IsPresent `
    -AllowOvercommit:$AllowOvercommit.IsPresent
$VramPercentage = [int]$quotaRequest.Percentages.VramPercentage
$EncodePercentage = [int]$quotaRequest.Percentages.EncodePercentage
$DecodePercentage = [int]$quotaRequest.Percentages.DecodePercentage
$ComputePercentage = [int]$quotaRequest.Percentages.ComputePercentage
$effectiveAllowOvercommit = [bool]$quotaRequest.EffectiveAllowOvercommit
$consoleProfile = if ($ConsoleResolutionType -ceq 'Unchanged') { $null } else {
    New-VMateHyperVConsoleProfile $ConsoleResolutionType `
        $ConsoleHorizontalResolution $ConsoleVerticalResolution
}

Assert-VMateGpuPHostEnvironment
$vm = Get-VMateGpuPVirtualMachine -VMName $VMName
Assert-VMateGpuPVirtualMachine -VM $vm
$identity = Get-VMateGpuPIdentity -VMId $vm.Id -StateRoot $StateRoot
$hardwareProfile = Get-VMateGpuPHardwareProfileBinding `
    -VMId $vm.Id -StateRoot $StateRoot
$requiresProfileStart = $null -ne $hardwareProfile -and
    [bool]$hardwareProfile.RequiresHostExtension
if (-not [String]::IsNullOrWhiteSpace($ArtifactManifestPath)) {
    throw ('-ArtifactManifestPath 对应的 paused-CPUID 路径已停用；' +
        'P-11 安全启动不加载该清单。')
}
if ($StartVM -and $RequireFullHardwareIdentity -and
    $requiresProfileStart) {
    throw ('当前安全后端尚未实现启动期 direct CPUID；' +
        '已在驱动同步和 GPU-P 配置前阻断。')
}

$effectivePath = $InstancePath
$effectiveVendor = $Vendor
$seed = $PartitionIdentitySeed.Trim().ToLowerInvariant()
if ($null -ne $identity) {
    if ($Vendor -ne 'Auto' -and [string]$identity.Vendor -ne $Vendor) {
        throw "VM 已固定为 $($identity.Vendor)，不能用 -Vendor $Vendor 重新解释。"
    }
    if ($Vendor -ieq 'Auto') {
        $effectiveVendor = [string]$identity.Vendor
    }
    if ($seed -and $seed -ine [string]$identity.PartitionIdentitySeed) {
        throw '显式 PartitionIdentitySeed 与该 VM 的持久化身份不一致。'
    }
    $seed = [string]$identity.PartitionIdentitySeed
    $boundPath = [string]$identity.GpuInstancePath
    if (-not [String]::IsNullOrWhiteSpace($boundPath)) {
        if (-not [String]::IsNullOrWhiteSpace($effectivePath) -and
            -not $effectivePath.Equals($boundPath,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw '显式 InstancePath 与该 VM 的持久化 GPU 绑定不一致。'
        }
        $effectivePath = $boundPath
    }
}
elseif (-not $seed) {
    $seed = New-VMateGpuPRandomHex -ByteCount 32
}

$configurationParameters = @{
    VMName = $VMName
    InstancePath = $effectivePath
    Vendor = $effectiveVendor
    VramPercentage = $VramPercentage
    EncodePercentage = $EncodePercentage
    DecodePercentage = $DecodePercentage
    ComputePercentage = $ComputePercentage
    AllowOvercommit = $effectiveAllowOvercommit
    QuotaRequest = $quotaRequest
    ConsoleProfile = $consoleProfile
    PartitionIdentitySeed = $seed
    LowMemoryMappedIoSpace = $LowMemoryMappedIoSpace
    HighMemoryMappedIoSpace = $HighMemoryMappedIoSpace
}
$plan = Get-VMateGpuPConfigurationPlan @configurationParameters
if ($plan.Vendor -ieq 'AMD' -and $RequireNvidiaSmi) {
    throw 'Auto 选择到 AMD GPU，不能要求 nvidia-smi。'
}
if ($FullSharedGpuQuota) {
    [void](Assert-VMateGpuPFullHostVramQuota $plan.ResourcePlan `
            $plan.CapabilitySnapshot `
            '所选 GPU 不能提供宿主报告的全部 VRAM 配额；拒绝伪造 FullSharedGpuQuota。')
}
# 首次计划只负责选卡。立即固定真实路径和厂商，避免驱动同步期间
# partitionable GPU 候选集变化后，锁内重新计划静默换到另一张卡。
$configurationParameters.InstancePath = [string]$plan.InstancePath
$configurationParameters.Vendor = [string]$plan.Vendor

if ($null -eq $identity -and -not $DryRun) {
    $identity = Initialize-VMateGpuPIdentity -VMId $vm.Id `
        -Vendor $plan.Vendor -PartitionIdentitySeed $seed -StateRoot $StateRoot
}

$hardwareIdentity = $null
$hostIdentityExtension = $null
$identityBoot = if ($null -eq $hardwareProfile) {
    [pscustomobject][ordered]@{
        Status = 'Unbound'
        Required = $false
        Capability = 'guest-boot-smbios-only'
        FullIdentitySupported = $false
    }
}
elseif (-not [bool]$hardwareProfile.RequiresHostExtension) {
    [pscustomobject][ordered]@{
        Status = 'NotRequired'
        Required = $false
        Capability = 'guest-boot-smbios-only'
        FullIdentitySupported = [bool]$hardwareProfile.FullIdentitySupported
    }
}
else {
    [pscustomobject][ordered]@{
        Status = 'WouldInstallOrUpdate'
        Required = $true
        Capability = 'guest-boot-smbios-only'
        FullIdentitySupported = $false
    }
}
if (-not $DryRun) {
    $preflightUniqueness = Test-VMateGpuPIdentityUniqueness -StateRoot $StateRoot
    if (-not $preflightUniqueness.IsUnique) {
        throw 'GPU-P VM 身份预检发现碰撞；尚未修改硬件身份、同步驱动或修改 adapter。'
    }
    $hardwareIdentity = Ensure-VMateGpuPHardwareIdentity -VM $vm `
        -StateRoot $StateRoot
    $hardwareUniqueness = Test-VMateGpuPHardwareIdentityUniqueness `
        -StateRoot $StateRoot
    if (-not $hardwareUniqueness.IsUnique) {
        throw 'Hyper-V 硬件身份预检发现碰撞；尚未修改 GPU-P adapter。'
    }
    if ($null -ne $hardwareProfile -and
        [bool]$hardwareProfile.RequiresHostExtension) {
        $identityBoot = Install-VMateHyperVIdentityBoot -VM $vm `
            -Profile $hardwareProfile `
            -HardwareIdentity $hardwareIdentity.Desired `
            -AllowDisableSecureBoot
        $identityBoot | Add-Member -NotePropertyName Required `
            -NotePropertyValue $true
        $identityBoot | Add-Member -NotePropertyName FullIdentitySupported `
            -NotePropertyValue $false
        $hostIdentityExtension =
            Publish-VMateHyperVHostIdentityDesiredManifest `
                -VM $vm -Profile $hardwareProfile `
                -HardwareIdentity $hardwareIdentity.Desired `
                -StateRoot $StateRoot
    }
}

$partitionCapacity = $null
$configurationLock = Enter-VMateGpuPConfigurationLock `
    -TimeoutSeconds $HostLockTimeoutSeconds
try {
    # 整个容量更新、重新选卡、驱动同步与 adapter 配置共用同一
    # 宿主锁。Partition 公共入口在同线程递归取得此锁后再取 per-GPU 锁，
    # 固定锁序避免两个 guest 同时通过旧配额快照。
    if ($GuestCapacity -gt 0) {
        $partitionCapacity = Set-VMateGpuPHostPartitionCount `
            -InstancePath ([string]$plan.InstancePath) `
            -GuestCapacity $GuestCapacity -DryRun:$DryRun `
            -LockTimeoutSeconds $HostLockTimeoutSeconds
    }

    $lockedPlan = Get-VMateGpuPConfigurationPlan @configurationParameters
    if (-not [string]::Equals([string]$lockedPlan.InstancePath,
            [string]$plan.InstancePath,
            [StringComparison]::OrdinalIgnoreCase) -or
        [string]$lockedPlan.Vendor -ine [string]$plan.Vendor) {
        throw '锁内重新计划的物理 GPU 与已固定选择不一致。'
    }
    if ([string]$lockedPlan.VM.Id -cne [string]$vm.Id) {
        throw '等待宿主锁期间 VM 已被删除或同名重建。'
    }
    if ($FullSharedGpuQuota) {
        [void](Assert-VMateGpuPFullHostVramQuota `
                $lockedPlan.ResourcePlan $lockedPlan.CapabilitySnapshot `
                '锁内能力回读不再满足宿主总显存配额；未写入 adapter。')
    }

    $pnpInstanceId = ConvertTo-VMateGpuPInstanceId `
        -PartitionableName $lockedPlan.InstancePath
    $driverSelection = Get-VMateGpuPDriverSelection `
        -GpuInstanceId $pnpInstanceId
    if ([string]$driverSelection.Vendor.Vendor -ine
        [string]$lockedPlan.Vendor) {
        throw 'GPU-P 计划与官方驱动包的厂商不一致。'
    }

    $driverResult = $null
    if (-not $SkipDriverSync) {
        $driverResult = Sync-VMateGpuPDriverStore -VMName $VMName `
            -VhdPath $VhdPath -GpuInstanceId $pnpInstanceId -DryRun:$DryRun
    }

    $configurationResult = $null
    $lockedVm = $lockedPlan.VM
    $partitionId = $null
    $partitionVfLuid = $null
    $startResult = $null
    if (-not $DryRun) {
        $identity = Set-VMateGpuPIdentityBinding -VMId $vm.Id `
            -Vendor $lockedPlan.Vendor `
            -GpuInstancePath $lockedPlan.InstancePath `
            -HostGpuName ([string]$driverSelection.Pnp.Name) `
            -DriverVersion ([string]$driverSelection.SignedDriver.DriverVersion) `
            -DriverInf ([string]$driverSelection.SignedDriver.InfName) `
            -StateRoot $StateRoot
        $configurationResult = Invoke-VMateGpuPConfiguration `
            @configurationParameters
        if ($StartVM) {
            if ($requiresProfileStart) {
                $startScript = Join-Path $PSScriptRoot `
                    'Start-VMateGpuPVM.ps1'
                $startResult = & $startScript -VMName $VMName `
                    -StateRoot $StateRoot `
                    -RequireFullHardwareIdentity:$RequireFullHardwareIdentity
            }
            else {
                Start-VM -VM $lockedVm -ErrorAction Stop | Out-Null
                $startResult = [pscustomobject][ordered]@{
                    Action = 'StandardHyperVColdBoot'
                    ProfileId = if ($null -eq $hardwareProfile) {
                        'unbound'
                    } else { [string]$hardwareProfile.ProfileId }
                    RuntimeModelSwitch = $false
                }
            }
            $lockedVm = Get-VMateGpuPVirtualMachine -VMName $VMName
        }
        $adapters = @(Get-VMGpuPartitionAdapter -VM $lockedVm `
                -ErrorAction Stop)
        if ($adapters.Count -ne 1) {
            throw "GPU-P 配置后 adapter 数量异常：$($adapters.Count)"
        }
        $partitionId = if ($null -ne
            $adapters[0].PSObject.Properties['PartitionId']) {
            $adapters[0].PartitionId
        }
        else { $null }
        $partitionVfLuid = if ($null -ne
            $adapters[0].PSObject.Properties['PartitionVfLuid']) {
            $adapters[0].PartitionVfLuid
        }
        else { $null }
        $identity = Update-VMateGpuPObservedIdentity -VMId $lockedVm.Id `
            -PartitionId $partitionId -PartitionVfLuid $partitionVfLuid `
            -StateRoot $StateRoot
    }
    $lockedResult = [pscustomobject]@{
        Plan = $lockedPlan
        PnpInstanceId = $pnpInstanceId
        DriverSelection = $driverSelection
        DriverSync = $driverResult
        ConsoleProfile = $plan.ConsoleProfile
        Configuration = $configurationResult
        PartitionCapacity = $partitionCapacity
        VM = $lockedVm
        Identity = $identity
        PartitionId = $partitionId
        PartitionVfLuid = $partitionVfLuid
        Start = $startResult
    }
}
catch {
    $primaryError = $_.Exception.Message
    if ($null -ne $partitionCapacity -and
        $partitionCapacity.ChangeApplied -eq $true) {
        $partitionRollbackError = ''
        try {
            [void](Restore-VMateGpuPHostPartitionCount `
                    -InstancePath ([string]$partitionCapacity.InstancePath) `
                    -ExpectedPartitionCount ([int]$partitionCapacity.PartitionCount) `
                    -PreviousPartitionCount ([int]$partitionCapacity.PreviousPartitionCount) `
                    -LockTimeoutSeconds $HostLockTimeoutSeconds)
        }
        catch {
            $partitionRollbackError = $_.Exception.Message
        }
        if ($partitionRollbackError) {
            throw ("GPU-P Enable 失败：$primaryError；" +
                "PartitionCount 回滚失败：$partitionRollbackError")
        }
        throw "GPU-P Enable 失败：$primaryError；已回滚本次 PartitionCount 扩容。"
    }
    throw
}
finally {
    Exit-VMateGpuPConfigurationLock -Mutex $configurationLock
}

$plan = $lockedResult.Plan
$pnpInstanceId = [string]$lockedResult.PnpInstanceId
$driverSelection = $lockedResult.DriverSelection
$driverResult = $lockedResult.DriverSync
$configurationResult = $lockedResult.Configuration
$partitionCapacity = $lockedResult.PartitionCapacity
$vm = $lockedResult.VM
$identity = $lockedResult.Identity
$partitionId = $lockedResult.PartitionId
$partitionVfLuid = $lockedResult.PartitionVfLuid

if ($DryRun) {
    return [pscustomobject][ordered]@{
        Status = 'DryRun'
        VMName = $VMName
        VMId = [string]$vm.Id
        Vendor = $plan.Vendor
        DeviceName = [string]$driverSelection.Pnp.Name
        InstancePath = $plan.InstancePath
        PnpInstanceId = $pnpInstanceId
        DriverVersion = [string]$driverSelection.SignedDriver.DriverVersion
        DriverInf = [string]$driverSelection.SignedDriver.InfName
        PartitionIdentitySeed = $seed
        PhysicalGpuSerialPolicy = 'vendor-managed-read-only'
        ResourcePlan = $plan.ResourcePlan
        CapabilitySnapshot = $plan.CapabilitySnapshot
        Quota = $plan.Quota
        QuotaMode = [string]$quotaRequest.QuotaMode
        EffectiveAllowOvercommit = $effectiveAllowOvercommit
        FullHostVramQuota = ([uint64]$plan.ResourcePlan.MaxPartitionVRAM -eq
            [uint64]$plan.CapabilitySnapshot.Resources.VRAM.Total)
        HostPartitionCapacity = $partitionCapacity
        DriverSync = $driverResult
        HardwareIdentityPolicy = 'random-once-persisted-on-create'
        HardwareProfile = $hardwareProfile
        IdentityBoot = $identityBoot
        HostIdentityExtension = $hostIdentityExtension
        WillStartVM = $StartVM.IsPresent
        WillValidateGuest = $ValidateGuest.IsPresent
        StartMode = if (-not $StartVM) { 'NotRequested' }
            elseif ($requiresProfileStart) { 'P11SafePartialIdentityColdBoot' }
            else { 'StandardHyperVColdBoot' }
    }
}

$guestResult = $null
if ($ValidateGuest) {
    $guestResult = Invoke-VMateGpuPGuestValidation -VMName $VMName `
        -Credential $GuestCredential -Vendor $plan.Vendor `
        -GpuName ([string]$driverSelection.Pnp.Name) `
        -DriverVersion ([string]$driverSelection.SignedDriver.DriverVersion) `
        -ExpectedHardwareIdentity $hardwareIdentity.Desired `
        -StrictDisplay $StrictGuestDisplay `
        -DisableHyperVVideo:$DisableHyperVVideo.IsPresent `
        -RequireNvidiaSmi:$RequireNvidiaSmi.IsPresent `
        -TimeoutSeconds $GuestValidationTimeoutSeconds
    $hardwareIdentity.Desired = Set-VMateGpuPGuestObservedHardwareIdentity `
        -VMId ([Guid]$vm.Id) -GuestObserved $guestResult.HardwareIdentity `
        -StateRoot $StateRoot
    $vendorGpuUuid = [string]$guestResult.VendorGpuUuid
    if (-not [String]::IsNullOrWhiteSpace($vendorGpuUuid)) {
        $identity = Update-VMateGpuPObservedIdentity -VMId $vm.Id `
            -PartitionId $partitionId -PartitionVfLuid $partitionVfLuid `
            -VendorGpuUuid $vendorGpuUuid -StateRoot $StateRoot
    }
}
$uniqueness = Test-VMateGpuPIdentityUniqueness -StateRoot $StateRoot
if (-not $uniqueness.IsUnique) {
    throw 'GPU-P VM 身份出现碰撞；请检查状态清单后停止相关 VM。'
}

[pscustomobject][ordered]@{
    Status = if ($StartVM) { 'Running' } else { 'Configured' }
    VMName = $VMName
    VMId = [string]$vm.Id
    Vendor = $plan.Vendor
    DeviceName = [string]$driverSelection.Pnp.Name
    InstancePath = $plan.InstancePath
    DriverVersion = [string]$driverSelection.SignedDriver.DriverVersion
    DriverInf = [string]$driverSelection.SignedDriver.InfName
    PartitionId = $partitionId
    PartitionVfLuid = $partitionVfLuid
    PhysicalGpuSerialPolicy = [string]$identity.PhysicalGpuSerialPolicy
    ResourcePlan = $configurationResult.ResourcePlan
    CapabilitySnapshot = $configurationResult.CapabilitySnapshot
    Quota = $configurationResult.Quota
    QuotaMode = [string]$quotaRequest.QuotaMode
    EffectiveAllowOvercommit = $effectiveAllowOvercommit
    FullHostVramQuota = ([uint64]$configurationResult.ResourcePlan.MaxPartitionVRAM -eq
        [uint64]$configurationResult.CapabilitySnapshot.Resources.VRAM.Total)
    HostPartitionCapacity = $partitionCapacity
    DriverSync = $driverResult
    ConsoleProfile = $configurationResult.ConsoleProfile
    HardwareIdentity = $hardwareIdentity
    HardwareProfile = $hardwareProfile
    IdentityBoot = $identityBoot
    HostIdentityExtension = $hostIdentityExtension
    Start = $lockedResult.Start
    GuestValidation = $guestResult
}

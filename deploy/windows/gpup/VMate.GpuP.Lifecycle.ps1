#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$identityModule = Join-Path $PSScriptRoot 'VMate.GpuP.Identity.ps1'
. $identityModule
. (Join-Path $PSScriptRoot 'VMate.GpuP.HardwareIdentity.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.HardwareProfile.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.BaseImage.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.ComputeProfile.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.ConsoleProfile.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.IdentityBoot.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.HostIdentityExtension.ps1')
function Assert-VMateHyperVAdministrator {
    [CmdletBinding()]
    param()
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'P-11 GPU-P 后端只能在 Windows Hyper-V 宿主运行。'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $administrator = [Security.Principal.WindowsBuiltInRole]::Administrator
        if (-not $principal.IsInRole($administrator)) {
            throw '请使用管理员 PowerShell 运行 P-11 GPU-P 命令。'
        }
    }
    finally {
        $identity.Dispose()
    }
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        throw '未安装 Hyper-V PowerShell 模块。请先启用完整 Hyper-V 角色，而不是仅启用 WHPX。'
    }
}
function Get-VMateGpuPVirtualMachinePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$VMName,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$VhdPath,
        [ValidateRange(1, 256)]
        [int]$ProcessorCount = 4,
        [ValidateRange(1, 100)][int]$CpuMaximumPercent = 100,
        [ValidateRange(0, 100)][int]$CpuReservePercent = 0,
        [ValidateRange(1, 10000)][int]$CpuRelativeWeight = 100,
        [ValidateRange(1, 64)][int]$HwThreadCountPerCore = 1,
        [bool]$ExposeVirtualizationExtensions = $false,
        [string]$HardwareProfileId = 'host-native',
        [string]$HardwareProfileCatalogPath = '',
        [switch]$RequireFullHardwareIdentity,
        [AllowNull()][object]$FirmwareIdentity = $null,
        [string]$StaticMacAddress = '',
        [string]$ConfigurationVersion = '',
        [AllowNull()][object]$ConsoleProfile = $null,
        [ValidateRange(1073741824, 1099511627776)]
        [UInt64]$MemoryStartupBytes = 8GB,
        [ValidateSet('NVIDIA', 'AMD')]
        [string]$Vendor,
        [string]$PartitionIdentitySeed = '',
        [string]$SwitchName = '',
        [string]$IsoPath = '',
        [string]$BaseImagePath = '',
        [switch]$CreateVhd,
        [ValidateRange(21474836480, 70368744177664)]
        [UInt64]$VhdSizeBytes = 127GB
    )
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
    $resolvedVhd = [IO.Path]::GetFullPath($VhdPath)
    if ([String]::IsNullOrWhiteSpace($VMName)) {
        throw 'VMName 不能只包含空白。'
    }
    if (-not [String]::IsNullOrWhiteSpace($PartitionIdentitySeed) -and
        $PartitionIdentitySeed -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'PartitionIdentitySeed 必须是 64 位十六进制字符串。'
    }
    if ([IO.Path]::GetExtension($resolvedVhd) -notin @('.vhd', '.vhdx')) {
        throw 'Hyper-V GPU-P 后端只接受 .vhd 或 .vhdx，不能直接使用 qcow2。'
    }
    if ($CreateVhd -and
        [IO.Path]::GetExtension($resolvedVhd) -ine '.vhdx') {
        throw 'P-11 新建系统盘必须使用 .vhdx，才能固定 1 MiB 动态块大小。'
    }
    $baseImagePlan = Resolve-VMateGpuPBaseImagePlan `
        -BaseImagePath $BaseImagePath -DestinationVhdPath $resolvedVhd
    if ($CreateVhd -and $null -ne $baseImagePlan) {
        throw '-CreateVhd 与 -BaseImagePath 互斥。'
    }
    if ($null -ne $baseImagePlan -and
        -not [String]::IsNullOrWhiteSpace($IsoPath)) {
        throw '-BaseImagePath 与 -IsoPath 互斥。'
    }
    if (($CreateVhd -or ($null -ne $baseImagePlan)) -and
        (Test-Path -LiteralPath $resolvedVhd)) {
        throw "创建目标不会覆盖已有磁盘：$resolvedVhd"
    }
    if (-not $CreateVhd -and $null -eq $baseImagePlan -and
        -not (Test-Path -LiteralPath $resolvedVhd -PathType Leaf)) {
        throw "找不到现有 Windows 系统盘：$resolvedVhd"
    }
    if ($null -eq $baseImagePlan -and -not $CreateVhd) {
        $vhd = Get-VHD -Path $resolvedVhd -ErrorAction Stop
        if ($vhd.Attached) {
            throw "现有 VHD 已挂载，拒绝复用：$resolvedVhd"
        }
        $owners = [System.Collections.Generic.List[string]]::new()
        foreach ($existingVm in @(Get-VM -ErrorAction Stop)) {
            foreach ($drive in @(Get-VMHardDiskDrive -VM $existingVm `
                        -ErrorAction Stop)) {
                if (-not [String]::IsNullOrWhiteSpace([string]$drive.Path) -and
                    [IO.Path]::GetFullPath([string]$drive.Path).Equals(
                        $resolvedVhd, [StringComparison]::OrdinalIgnoreCase)) {
                    [void]$owners.Add([string]$existingVm.Name)
                }
            }
        }
        if ($owners.Count -ne 0) {
            throw "现有 VHD 已属于 VM [$($owners -join ', ')]，拒绝重复挂载。"
        }
    }
    $resolvedIso = ''
    if (-not [String]::IsNullOrWhiteSpace($IsoPath)) {
        $resolvedIso = [IO.Path]::GetFullPath($IsoPath)
        if (-not (Test-Path -LiteralPath $resolvedIso -PathType Leaf)) {
            throw "找不到安装 ISO：$resolvedIso"
        }
    }
    if ($CreateVhd -and [String]::IsNullOrWhiteSpace($resolvedIso)) {
        throw '创建空 VHDX 时必须提供 -IsoPath；系统安装完成后再执行 GPU-P 驱动同步。'
    }
    $configurationVersion = $ConfigurationVersion.Trim()
    if ($configurationVersion -and
        $configurationVersion -notmatch '^\d{1,2}\.\d{1,2}$') {
        throw "Hyper-V VM 配置版本格式无效：$configurationVersion"
    }
    if ($configurationVersion) {
        $supportedVersions = @(Get-VMHostSupportedVersion -ErrorAction Stop |
            ForEach-Object { [string]$_.Version })
        if ($supportedVersions -notcontains $configurationVersion) {
            throw "当前宿主不支持 Hyper-V VM 配置版本 $configurationVersion。"
        }
    }
    if (-not [String]::IsNullOrWhiteSpace($SwitchName)) {
        $null = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
    }
    $computeProfile = New-VMateHyperVComputeProfile `
        -ProcessorCount $ProcessorCount `
        -CpuMaximumPercent $CpuMaximumPercent `
        -CpuReservePercent $CpuReservePercent `
        -CpuRelativeWeight $CpuRelativeWeight `
        -HwThreadCountPerCore $HwThreadCountPerCore `
        -ExposeVirtualizationExtensions $ExposeVirtualizationExtensions
    $firmwareProfile = if ($null -eq $FirmwareIdentity) { $null } else {
        Resolve-VMateGpuPFirmwareIdentity $FirmwareIdentity
    }
    $staticMac = if ([String]::IsNullOrWhiteSpace($StaticMacAddress)) { '' } else {
        Assert-VMateHyperVLocalUnicastMacAddress $StaticMacAddress
    }
    $console = if ($null -eq $ConsoleProfile) { $null } else {
        New-VMateHyperVConsoleProfile `
            -ResolutionType ([string]$ConsoleProfile.ResolutionType) `
            -HorizontalResolution ([int]$ConsoleProfile.HorizontalResolution) `
            -VerticalResolution ([int]$ConsoleProfile.VerticalResolution)
    }
    return [pscustomobject][ordered]@{
        Action = 'CreateHyperVGeneration2VM'
        VMName = $VMName
        VhdPath = $resolvedVhd
        CreateVhd = [bool]$CreateVhd
        CloneBaseImage = $null -ne $baseImagePlan
        BaseImagePath = if ($null -eq $baseImagePlan) { '' } else {
            [string]$baseImagePlan.SourcePath
        }
        BaseImagePlan = $baseImagePlan
        VhdSizeBytes = $VhdSizeBytes
        VhdBlockSizeBytes = [uint64]1MB
        StorageProfile = 'interactive-dynamic-vhdx-1mib'
        IsoPath = $resolvedIso
        ProcessorCount = $ProcessorCount
        ComputeProfile = $computeProfile
        HardwareProfile = Get-VMateGpuPHardwareProfilePlan $hardwareProfile
        FirmwareIdentity = $firmwareProfile
        StaticMacAddress = $staticMac
        ConfigurationVersion = $configurationVersion
        ConsoleProfile = $console
        MemoryStartupBytes = $MemoryStartupBytes
        SwitchName = $SwitchName
        Vendor = $Vendor
        PartitionIdentitySeed = $PartitionIdentitySeed
        AutomaticCheckpoints = $false
        SecureBootTemplate = 'MicrosoftWindows'
        IdentityBoot = [pscustomobject][ordered]@{
            Required = [bool]$hardwareProfile.RequiresHostExtension
            Status = if (-not $hardwareProfile.RequiresHostExtension) {
                'NotRequired'
            } elseif ($CreateVhd) { 'DeferredUntilWindowsInstalled' }
            else { 'InstallBeforeFirstBoot' }
            Capability = 'guest-boot-smbios-plus-host-extension-contract'
            FullIdentitySupported = [bool]$hardwareProfile.FullIdentitySupported
        }
        HostIdentityExtension = [pscustomobject][ordered]@{
            Required = [bool]$hardwareProfile.RequiresHostExtension
            ApplyPolicy = 'vm-off-publish-next-cold-boot-only'
            RuntimeModelSwitch = 'forbidden'
            FullIdentitySupported = $false
        }
        HardwareIdentityPolicy = 'custom-or-random-once-persisted-on-create'
        PhysicalGpuSerialPolicy = 'vendor-managed-read-only'
    }
}
function New-VMateGpuPVirtualMachine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        [Parameter(Mandatory = $true)]
        [string]$VhdPath,
        [ValidateRange(1, 256)]
        [int]$ProcessorCount = 4,
        [ValidateRange(1, 100)][int]$CpuMaximumPercent = 100,
        [ValidateRange(0, 100)][int]$CpuReservePercent = 0,
        [ValidateRange(1, 10000)][int]$CpuRelativeWeight = 100,
        [ValidateRange(1, 64)][int]$HwThreadCountPerCore = 1,
        [bool]$ExposeVirtualizationExtensions = $false,
        [string]$HardwareProfileId = 'host-native',
        [string]$HardwareProfileCatalogPath = '',
        [switch]$RequireFullHardwareIdentity,
        [AllowNull()][object]$FirmwareIdentity = $null,
        [string]$StaticMacAddress = '',
        [string]$ConfigurationVersion = '',
        [AllowNull()][object]$ConsoleProfile = $null,
        [ValidateRange(1073741824, 1099511627776)]
        [UInt64]$MemoryStartupBytes = 8GB,
        [Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD')]
        [string]$Vendor,
        [string]$PartitionIdentitySeed = '',
        [string]$SwitchName = '',
        [string]$IsoPath = '',
        [string]$BaseImagePath = '',
        [switch]$CreateVhd,
        [ValidateRange(21474836480, 70368744177664)]
        [UInt64]$VhdSizeBytes = 127GB,
        [string]$StateRoot = '',
        [switch]$DryRun
    )
    Assert-VMateHyperVAdministrator
    Import-Module Hyper-V -ErrorAction Stop
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        throw "Hyper-V VM 已存在：$VMName"
    }
    $planParameters = @{
        VMName = $VMName
        VhdPath = $VhdPath
        HardwareProfileId = $HardwareProfileId
        HardwareProfileCatalogPath = $HardwareProfileCatalogPath
        RequireFullHardwareIdentity = $RequireFullHardwareIdentity
        FirmwareIdentity = $FirmwareIdentity
        StaticMacAddress = $StaticMacAddress
        ConfigurationVersion = $ConfigurationVersion
        ConsoleProfile = $ConsoleProfile
        Vendor = $Vendor
        PartitionIdentitySeed = $PartitionIdentitySeed
        SwitchName = $SwitchName
        IsoPath = $IsoPath
        BaseImagePath = $BaseImagePath
        CreateVhd = $CreateVhd
        VhdSizeBytes = $VhdSizeBytes
    }
    foreach ($name in @('ProcessorCount', 'CpuMaximumPercent',
            'CpuReservePercent', 'CpuRelativeWeight', 'HwThreadCountPerCore',
            'ExposeVirtualizationExtensions', 'MemoryStartupBytes')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $planParameters[$name] = $PSBoundParameters[$name]
        }
    }
    $plan = Get-VMateGpuPVirtualMachinePlan @planParameters
    if ($DryRun) {
        return $plan
    }
    $createdVhd = $false
    $createdVm = $null
    $identityPath = $null
    $identityBoot = $null
    try {
        if ($plan.CreateVhd) {
            $parent = [IO.Path]::GetDirectoryName($plan.VhdPath)
            [IO.Directory]::CreateDirectory($parent) | Out-Null
            New-VHD -Path $plan.VhdPath -Dynamic `
                -SizeBytes $plan.VhdSizeBytes `
                -BlockSizeBytes $plan.VhdBlockSizeBytes `
                -ErrorAction Stop | Out-Null
            $createdVhd = $true
        }
        elseif ($plan.CloneBaseImage) {
            [void](Copy-VMateGpuPBaseImage -Plan $plan.BaseImagePlan)
            $createdVhd = $true
        }
        $newVmParameters = @{
            Name = $plan.VMName
            Generation = 2
            MemoryStartupBytes = $plan.MemoryStartupBytes
            VHDPath = $plan.VhdPath
            ErrorAction = 'Stop'
        }
        if (-not [String]::IsNullOrWhiteSpace($plan.SwitchName)) {
            $newVmParameters['SwitchName'] = $plan.SwitchName
        }
        if ($plan.ConfigurationVersion) {
            $newVmParameters['Version'] = $plan.ConfigurationVersion
        }
        $createdVm = New-VM @newVmParameters
        $computeResult = Set-VMateHyperVComputeProfile -VM $createdVm `
            -Profile $plan.ComputeProfile
        Set-VMMemory -VM $createdVm -DynamicMemoryEnabled $false -ErrorAction Stop
        Set-VM -VM $createdVm -AutomaticCheckpointsEnabled $false `
            -CheckpointType Disabled -AutomaticStartAction Nothing `
            -AutomaticStopAction ShutDown -ErrorAction Stop
        Set-VMFirmware -VM $createdVm -EnableSecureBoot On `
            -SecureBootTemplate MicrosoftWindows -ErrorAction Stop
        $consoleResult = if ($null -eq $plan.ConsoleProfile) { $null } else {
            Set-VMateHyperVConsoleProfile -VM $createdVm `
                -Profile $plan.ConsoleProfile
        }
        if (-not [String]::IsNullOrWhiteSpace($plan.IsoPath)) {
            $dvd = Add-VMDvdDrive -VM $createdVm -Path $plan.IsoPath -Passthru -ErrorAction Stop
            Set-VMFirmware -VM $createdVm -FirstBootDevice $dvd -ErrorAction Stop
        }
        $identityPath = Get-VMateGpuPIdentityPath -VMId $createdVm.Id `
            -StateRoot $StateRoot
        $identity = Initialize-VMateGpuPIdentity -VMId $createdVm.Id `
            -Vendor $plan.Vendor `
            -PartitionIdentitySeed $plan.PartitionIdentitySeed `
            -StateRoot $StateRoot
        $hardwareIdentity = Ensure-VMateGpuPHardwareIdentity -VM $createdVm `
            -StateRoot $StateRoot -FirmwareIdentity $plan.FirmwareIdentity `
            -StaticMacAddress $plan.StaticMacAddress
        $profile = Resolve-VMateGpuPHardwareProfile `
            -ProfileId ([string]$plan.HardwareProfile.ProfileId) `
            -CatalogPath $HardwareProfileCatalogPath `
            -RequireFullIdentity:$RequireFullHardwareIdentity.IsPresent
        $hardwareProfileBinding = Set-VMateGpuPHardwareProfileBinding `
            -VMId $createdVm.Id -Profile $profile -StateRoot $StateRoot
        $identityBoot = if (-not $profile.RequiresHostExtension) {
            [pscustomobject][ordered]@{
                Status = 'NotRequired'
                Required = $false
                Capability = 'guest-boot-smbios-only'
                FullIdentitySupported = [bool]$profile.FullIdentitySupported
            }
        }
        elseif ($plan.CreateVhd) {
            [pscustomobject][ordered]@{
                Status = 'DeferredUntilWindowsInstalled'
                Required = $true
                Capability = 'guest-boot-smbios-only'
                FullIdentitySupported = $false
            }
        }
        else {
            $installed = Install-VMateHyperVIdentityBoot -VM $createdVm `
                -Profile $profile -HardwareIdentity $hardwareIdentity.Desired `
                -AllowDisableSecureBoot
            $installed | Add-Member -NotePropertyName Required `
                -NotePropertyValue $true
            $installed | Add-Member -NotePropertyName FullIdentitySupported `
                -NotePropertyValue $false
            $installed
        }
        $hostIdentityExtension = if (-not $profile.RequiresHostExtension) {
            [pscustomobject][ordered]@{
                Status = 'NotRequired'
                FullIdentitySupported = $true
            }
        } else {
            Publish-VMateHyperVHostIdentityDesiredManifest `
                -VM $createdVm -Profile $profile `
                -HardwareIdentity $hardwareIdentity.Desired `
                -StateRoot $StateRoot
        }
        return [pscustomobject][ordered]@{
            VM = $createdVm
            Plan = $plan
            Identity = $identity
            IdentityPath = $identityPath
            HardwareIdentity = $hardwareIdentity
            HardwareProfile = $hardwareProfileBinding
            IdentityBoot = $identityBoot
            HostIdentityExtension = $hostIdentityExtension
            ComputeProfile = $computeResult
            ConsoleProfile = $consoleResult
        }
    }
    catch {
        $failure = $_.Exception.Message
        $rollbackErrors = [System.Collections.Generic.List[string]]::new()
        $vmUnregistered = $null -eq $createdVm
        if ($null -ne $createdVm) {
            $safeToUnregister = $true
            if ($null -ne $identityBoot -and
                [string]$identityBoot.Status -in @('Installed', 'Reinstalled')) {
                try {
                    [void](Uninstall-VMateHyperVIdentityBoot -VM $createdVm)
                }
                catch {
                    $safeToUnregister = $false
                    [void]$rollbackErrors.Add(
                        "回滚本次 identity boot 失败：$($_.Exception.Message)")
                }
            }
            if ($safeToUnregister) {
                try {
                    Remove-VM -VM $createdVm -Force -Confirm:$false `
                        -ErrorAction Stop
                    $remaining = Get-VM -Id $createdVm.Id `
                        -ErrorAction SilentlyContinue
                    if ($null -ne $remaining) {
                        [void]$rollbackErrors.Add(
                            '回读发现本次 VM 仍在 Hyper-V 注册。')
                    }
                    else { $vmUnregistered = $true }
                }
                catch {
                    [void]$rollbackErrors.Add(
                        "注销本次 VM 失败：$($_.Exception.Message)")
                }
            }
            else {
                [void]$rollbackErrors.Add(
                    'identity boot 未安全回滚；保留 VM 与恢复材料。')
            }
        }
        # VM 未确认注销时，VHD 与身份清单都是恢复/诊断材料，
        # 绝不继续删除。只有回读确认 VM 已消失才清理本事务产物。
        if ($vmUnregistered) {
            if (-not [String]::IsNullOrWhiteSpace([string]$identityPath) -and
                (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
                try {
                    Remove-Item -LiteralPath $identityPath -Force `
                        -ErrorAction Stop
                }
                catch {
                    [void]$rollbackErrors.Add(
                        "删除本次身份清单失败：$($_.Exception.Message)")
                }
            }
            if ($createdVhd -and
                (Test-Path -LiteralPath $plan.VhdPath -PathType Leaf)) {
                try {
                    Remove-Item -LiteralPath $plan.VhdPath -Force `
                        -ErrorAction Stop
                }
                catch {
                    [void]$rollbackErrors.Add(
                        "删除本次 VHD 失败：$($_.Exception.Message)")
                }
            }
        }
        else {
            [void]$rollbackErrors.Add(
                '已保留身份清单与 VHD，避免破坏仍注册 VM 的恢复材料。')
        }
        $rollback = if ($rollbackErrors.Count -eq 0) {
            '已完整回滚本次创建。'
        }
        else { $rollbackErrors -join '；' }
        throw "创建 GPU-P VM 失败：$failure；$rollback"
    }
}

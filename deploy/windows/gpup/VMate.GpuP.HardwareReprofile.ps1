#Requires -Version 5.1

<#
.SYNOPSIS
    事务化执行 P-11 显式关机态硬件换型。

.DESCRIPTION
    普通启动仍遵循 select-once-no-reroll。本模块只在 VM 完全 Off、调用者显式
    传入 AllowReprofile 时替换 CPU 拓扑、固定内存、控制台、guest SMBIOS
    identity boot、宿主身份扩展期望清单和 profile binding。GPU-P adapter 与
    现有 100% 配额只读快照，任何变化都会触发回滚。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.GpuP.HardwareIdentity.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.HardwareProfile.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.ComputeProfile.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.ConsoleProfile.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.IdentityBoot.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.HostIdentityExtension.ps1')

function New-VMateGpuPHardwareComputeProfile {
    param([Parameter(Mandatory = $true)][object]$HardwareProfile)

    return New-VMateHyperVComputeProfile `
        -ProcessorCount ([int]$HardwareProfile.Processor.Count) `
        -CpuMaximumPercent ([int]$HardwareProfile.Processor.MaximumPercent) `
        -CpuReservePercent ([int]$HardwareProfile.Processor.ReservePercent) `
        -CpuRelativeWeight ([int]$HardwareProfile.Processor.RelativeWeight) `
        -HwThreadCountPerCore ([int]$HardwareProfile.Processor.HwThreadsPerCore) `
        -ExposeVirtualizationExtensions `
            ([bool]$HardwareProfile.Processor.ExposeVirtualizationExtensions)
}

function New-VMateGpuPHardwareConsoleProfile {
    param([Parameter(Mandatory = $true)][object]$HardwareProfile)

    return New-VMateHyperVConsoleProfile `
        -ResolutionType ([string]$HardwareProfile.Gpu.console_resolution_type) `
        -HorizontalResolution `
            ([int]$HardwareProfile.Gpu.console_horizontal_resolution) `
        -VerticalResolution `
            ([int]$HardwareProfile.Gpu.console_vertical_resolution)
}

function Get-VMateGpuPHardwareMemorySnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$VM)

    $memory = Get-VMMemory -VM $VM -ErrorAction Stop
    return [pscustomobject][ordered]@{
        DynamicMemoryEnabled = [bool]$memory.DynamicMemoryEnabled
        StartupBytes = [uint64]$memory.Startup
        MinimumBytes = [uint64]$memory.Minimum
        MaximumBytes = [uint64]$memory.Maximum
        Buffer = [int]$memory.Buffer
        Priority = [int]$memory.Priority
    }
}

function Test-VMateGpuPHardwareMemoryMatch {
    param(
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][object]$Expected
    )

    foreach ($name in @('DynamicMemoryEnabled', 'StartupBytes')) {
        if ([string]$Actual.$name -cne [string]$Expected.$name) {
            return $false
        }
    }
    if ([bool]$Expected.DynamicMemoryEnabled) {
        foreach ($name in @('MinimumBytes', 'MaximumBytes', 'Buffer',
                'Priority')) {
            if ([string]$Actual.$name -cne [string]$Expected.$name) {
                return $false
            }
        }
    }
    return $true
}

function Set-VMateGpuPHardwareMemorySnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$Snapshot
    )

    $parameters = @{
        VM = $VM
        DynamicMemoryEnabled = [bool]$Snapshot.DynamicMemoryEnabled
        StartupBytes = [uint64]$Snapshot.StartupBytes
        Confirm = $false
        ErrorAction = 'Stop'
    }
    if ([bool]$Snapshot.DynamicMemoryEnabled) {
        $parameters.MinimumBytes = [uint64]$Snapshot.MinimumBytes
        $parameters.MaximumBytes = [uint64]$Snapshot.MaximumBytes
        $parameters.Buffer = [int]$Snapshot.Buffer
        $parameters.Priority = [int]$Snapshot.Priority
    }
    Set-VMMemory @parameters
    $observed = Get-VMateGpuPHardwareMemorySnapshot $VM
    if (-not (Test-VMateGpuPHardwareMemoryMatch $observed $Snapshot)) {
        throw 'Hyper-V 内存配置写入后的回读不一致。'
    }
    return $observed
}

function Set-VMateGpuPHardwareMemoryProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$HardwareProfile,
        [switch]$DryRun
    )

    if ([string]$VM.State -cne 'Off') {
        throw 'VM 必须为 Off 才能配置硬件 profile 内存。'
    }
    $before = Get-VMateGpuPHardwareMemorySnapshot $VM
    $desired = [pscustomobject][ordered]@{
        DynamicMemoryEnabled = [bool]$HardwareProfile.Memory.dynamic
        StartupBytes = [uint64]$HardwareProfile.Memory.startup_bytes
        MinimumBytes = [uint64]$before.MinimumBytes
        MaximumBytes = [uint64]$before.MaximumBytes
        Buffer = [int]$before.Buffer
        Priority = [int]$before.Priority
    }
    if (Test-VMateGpuPHardwareMemoryMatch $before $desired) {
        return [pscustomobject]@{
            Status = 'Unchanged'; Previous = $before; Observed = $before
        }
    }
    if ($DryRun) {
        return [pscustomobject]@{
            Status = 'DryRun'; Previous = $before; Desired = $desired
        }
    }
    try {
        $observed = Set-VMateGpuPHardwareMemorySnapshot $VM $desired
    }
    catch {
        $failure = $_.Exception.Message
        try { [void](Set-VMateGpuPHardwareMemorySnapshot $VM $before) }
        catch {
            throw "内存 profile 应用失败：$failure；回滚失败：$($_.Exception.Message)"
        }
        throw "内存 profile 应用失败：$failure；已恢复原配置。"
    }
    return [pscustomobject]@{
        Status = 'Applied'; Previous = $before; Desired = $desired
        Observed = $observed
    }
}

function Get-VMateGpuPHardwareGpuAdapterSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$VM)

    $names = @(
        'InstancePath', 'PartitionId', 'PartitionVfLuid',
        'MinPartitionVRAM', 'MaxPartitionVRAM', 'OptimalPartitionVRAM',
        'MinPartitionEncode', 'MaxPartitionEncode', 'OptimalPartitionEncode',
        'MinPartitionDecode', 'MaxPartitionDecode', 'OptimalPartitionDecode',
        'MinPartitionCompute', 'MaxPartitionCompute', 'OptimalPartitionCompute'
    )
    $result = [Collections.Generic.List[object]]::new()
    foreach ($adapter in @(Get-VMGpuPartitionAdapter -VM $VM `
            -ErrorAction Stop)) {
        $record = [ordered]@{}
        foreach ($name in $names) {
            $property = $adapter.PSObject.Properties[$name]
            $record[$name] = if ($null -ne $property) {
                [string]$property.Value
            } else { '' }
        }
        [void]$result.Add([pscustomobject]$record)
    }
    return @($result)
}

function Get-VMateGpuPHardwareSnapshotSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Value)

    $json = @($Value) | ConvertTo-Json -Depth 5 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash(
                    [Text.Encoding]::UTF8.GetBytes($json)))).Replace('-', '')
    }
    finally { $sha.Dispose() }
}

function Restore-VMateGpuPIdentityManifestBytes {
    param(
        [Parameter(Mandatory = $true)][Guid]$VMId,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [string]$StateRoot = ''
    )

    $path = Get-VMateGpuPIdentityPath $VMId $StateRoot
    $directory = [IO.Path]::GetDirectoryName($path)
    $temporary = [IO.Path]::Combine($directory,
        ('identity.' + [Guid]::NewGuid().ToString('N') + '.rollback.tmp'))
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        $backup = "$path.rollback.bak"
        [IO.File]::Replace($temporary, $path, $backup)
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        [void](Read-VMateGpuPIdentityManifest $path)
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Get-VMateGpuPHardwareReprofilePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][string]$HardwareProfileId,
        [string]$HardwareProfileCatalogPath = '',
        [string]$StateRoot = '',
        [switch]$AllowReprofile,
        [string]$ReprofileReason = ''
    )

    if ([string]$VM.State -cne 'Off') {
        throw "P-11 硬件换型要求 VM 完全关机，当前状态：$($VM.State)"
    }
    $target = Resolve-VMateGpuPHardwareProfile `
        -ProfileId $HardwareProfileId -CatalogPath $HardwareProfileCatalogPath
    $current = Get-VMateGpuPHardwareProfileBinding `
        -VMId ([Guid]$VM.Id) -StateRoot $StateRoot
    $replacement = $null -ne $current -and
        ([string]$current.ProfileId -cne [string]$target.Id -or
        [string]$current.CatalogRevision -cne [string]$target.CatalogRevision)
    if ($replacement -and -not $AllowReprofile) {
        throw '换到不同 hardware profile 必须显式传入 -AllowReprofile。'
    }
    if ($replacement -and [String]::IsNullOrWhiteSpace($ReprofileReason)) {
        throw '显式换型必须提供 ReprofileReason。'
    }
    $hardwareIdentity = Get-VMateGpuPHardwareIdentity `
        -VMId ([Guid]$VM.Id) -StateRoot $StateRoot
    if ($null -eq $hardwareIdentity -or
        [string]$hardwareIdentity.State -cne 'Applied') {
        throw 'P-11 硬件换型要求已有 Applied 持久硬件身份。'
    }
    $gpuBefore = @(Get-VMateGpuPHardwareGpuAdapterSnapshot $VM)
    return [pscustomobject][ordered]@{
        Action = if ($replacement) {
            'ExplicitOfflineHardwareReprofile'
        } else { 'ConvergeHardwareProfile' }
        VMId = ([Guid]$VM.Id).ToString('D')
        VMName = [string]$VM.Name
        Current = $current
        Target = $target
        Replacement = [bool]$replacement
        ReprofileReason = $ReprofileReason.Trim()
        Compute = New-VMateGpuPHardwareComputeProfile $target
        Memory = [pscustomobject]@{
            DynamicMemoryEnabled = [bool]$target.Memory.dynamic
            StartupBytes = [uint64]$target.Memory.startup_bytes
        }
        Console = New-VMateGpuPHardwareConsoleProfile $target
        HardwareIdentity = $hardwareIdentity
        GpuPartitionAdapters = $gpuBefore
        GpuPartitionSnapshotSha256 =
            Get-VMateGpuPHardwareSnapshotSha256 $gpuBefore
        HostIdentityExtension = if ([bool]$target.RequiresHostExtension) {
            New-VMateHyperVHostIdentityDesiredManifest `
                -VM $VM -Profile $target -HardwareIdentity $hardwareIdentity
        } else { $null }
        RuntimeModelSwitch = 'forbidden'
        FullIdentitySupportedBeforeColdBoot = $false
    }
}

function Invoke-VMateGpuPHardwareReprofile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][string]$HardwareProfileId,
        [string]$HardwareProfileCatalogPath = '',
        [string]$StateRoot = '',
        [switch]$AllowReprofile,
        [string]$ReprofileReason = '',
        [switch]$AllowDisableSecureBoot,
        [switch]$DryRun
    )

    $plan = Get-VMateGpuPHardwareReprofilePlan `
        -VM $VM -HardwareProfileId $HardwareProfileId `
        -HardwareProfileCatalogPath $HardwareProfileCatalogPath `
        -StateRoot $StateRoot -AllowReprofile:$AllowReprofile `
        -ReprofileReason $ReprofileReason
    if ($DryRun) {
        return [pscustomobject][ordered]@{
            Status = 'DryRun'
            Plan = $plan
            FullIdentitySupported = $false
        }
    }

    $vmId = [Guid]$VM.Id
    $identityPath = Get-VMateGpuPIdentityPath $vmId $StateRoot
    $identityBytes = [IO.File]::ReadAllBytes($identityPath)
    $computeBefore = Get-VMateHyperVComputeSnapshot $VM
    $memoryBefore = Get-VMateGpuPHardwareMemorySnapshot $VM
    $consoleBefore = Get-VMateHyperVConsoleSnapshot $VM
    $gpuHashBefore = [string]$plan.GpuPartitionSnapshotSha256
    $target = $plan.Target
    $current = $plan.Current
    try {
        $compute = Set-VMateHyperVComputeProfile `
            -VM $VM -Profile $plan.Compute
        $memory = Set-VMateGpuPHardwareMemoryProfile `
            -VM $VM -HardwareProfile $target
        $console = Set-VMateHyperVConsoleProfile `
            -VM $VM -Profile $plan.Console
        if ([bool]$target.RequiresHostExtension) {
            $identityBoot = Install-VMateHyperVIdentityBoot `
                -VM $VM -Profile $target -HardwareIdentity $plan.HardwareIdentity `
                -AllowDisableSecureBoot:$AllowDisableSecureBoot `
                -AllowProfileReplacement:$plan.Replacement
            $hostIdentity = Publish-VMateHyperVHostIdentityDesiredManifest `
                -VM $VM -Profile $target `
                -HardwareIdentity $plan.HardwareIdentity -StateRoot $StateRoot
        }
        else {
            $identityBoot = Uninstall-VMateHyperVIdentityBoot -VM $VM
            $hostIdentity = [pscustomobject]@{
                Status = 'NotRequired'; FullIdentitySupported = $true
            }
        }
        $binding = Set-VMateGpuPHardwareProfileBinding `
            -VMId $vmId -Profile $target -StateRoot $StateRoot `
            -AllowReprofile:$plan.Replacement `
            -ReprofileReason $plan.ReprofileReason
        $gpuAfter = @(Get-VMateGpuPHardwareGpuAdapterSnapshot $VM)
        $gpuHashAfter = Get-VMateGpuPHardwareSnapshotSha256 $gpuAfter
        if ($gpuHashAfter -cne $gpuHashBefore) {
            throw '换型期间 GPU-P adapter 或 100% 配额发生了变化。'
        }
        $extensionStatus = if ([bool]$target.RequiresHostExtension) {
            Get-VMateHyperVHostIdentityExtensionStatus `
                -VMId $vmId -StateRoot $StateRoot
        } else {
            [pscustomobject]@{
                State = 'NotRequired'; FullIdentitySupported = $true
            }
        }
        return [pscustomobject][ordered]@{
            Status = if ($plan.Replacement) { 'Reprofiled' } else { 'Converged' }
            VMId = $vmId.ToString('D')
            ProfileId = [string]$binding.ProfileId
            BindingRevision = [int]$binding.BindingRevision
            Compute = $compute
            Memory = $memory
            Console = $console
            IdentityBoot = $identityBoot
            HostIdentityExtension = $hostIdentity
            HostIdentityStatus = $extensionStatus
            GpuPartitionPreserved = $true
            RequiresColdBoot = [bool]$target.RequiresHostExtension
            FullIdentitySupported =
                [bool]$extensionStatus.FullIdentitySupported
        }
    }
    catch {
        $failure = $_.Exception.Message
        $rollbackErrors = [Collections.Generic.List[string]]::new()
        try {
            if ($null -ne $current -and
                [bool]$current.RequiresHostExtension) {
                [void](Install-VMateHyperVIdentityBoot `
                    -VM $VM -Profile $current `
                    -HardwareIdentity $plan.HardwareIdentity `
                    -AllowDisableSecureBoot -AllowProfileReplacement)
            }
            else { [void](Uninstall-VMateHyperVIdentityBoot -VM $VM) }
        }
        catch {
            [void]$rollbackErrors.Add(
                "identity boot 回滚失败：$($_.Exception.Message)")
        }
        foreach ($rollback in @(
                [pscustomobject]@{
                    Name = '控制台'
                    Action = {
                        Set-VMateHyperVConsoleProfile `
                            -VM $VM -Profile $consoleBefore | Out-Null
                    }
                },
                [pscustomobject]@{
                    Name = '内存'
                    Action = {
                        Set-VMateGpuPHardwareMemorySnapshot `
                            -VM $VM -Snapshot $memoryBefore | Out-Null
                    }
                },
                [pscustomobject]@{
                    Name = 'CPU'
                    Action = {
                        $restoreCompute = New-VMateHyperVComputeProfile `
                            -ProcessorCount $computeBefore.ProcessorCount `
                            -CpuMaximumPercent $computeBefore.CpuMaximumPercent `
                            -CpuReservePercent $computeBefore.CpuReservePercent `
                            -CpuRelativeWeight $computeBefore.CpuRelativeWeight `
                            -HwThreadCountPerCore `
                                $computeBefore.HwThreadCountPerCore `
                            -ExposeVirtualizationExtensions `
                                $computeBefore.ExposeVirtualizationExtensions
                        Set-VMateHyperVComputeProfile `
                            -VM $VM -Profile $restoreCompute | Out-Null
                    }
                })) {
            try { & $rollback.Action }
            catch {
                [void]$rollbackErrors.Add(
                    "$($rollback.Name)回滚失败：$($_.Exception.Message)")
            }
        }
        try {
            Restore-VMateGpuPIdentityManifestBytes `
                -VMId $vmId -Bytes $identityBytes -StateRoot $StateRoot
        }
        catch {
            [void]$rollbackErrors.Add(
                "identity.json 回滚失败：$($_.Exception.Message)")
        }
        try {
            $restoredGpu = @(Get-VMateGpuPHardwareGpuAdapterSnapshot $VM)
            if ((Get-VMateGpuPHardwareSnapshotSha256 $restoredGpu) -cne
                $gpuHashBefore) {
                throw 'GPU-P adapter 回读不一致。'
            }
        }
        catch {
            [void]$rollbackErrors.Add(
                "GPU-P 配额回读失败：$($_.Exception.Message)")
        }
        $rollbackSummary = if ($rollbackErrors.Count -eq 0) {
            '已恢复原硬件 profile。'
        } else { @($rollbackErrors) -join '；' }
        throw "P-11 硬件换型失败：$failure；$rollbackSummary"
    }
}

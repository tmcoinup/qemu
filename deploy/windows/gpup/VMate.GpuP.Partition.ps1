#Requires -Version 5.1

<#
.SYNOPSIS
    Hyper-V GPU-P 宿主分区数量规划、事务更新与跨进程配置锁。

.DESCRIPTION
    分区数量完全取自所选物理 GPU 的 PartitionCount/ValidPartitionCounts，
    不包含型号或厂商常量。数量足够时保持宿主现状；不足时选择能够容纳目标
    guest 数的最小有效值，并在没有任何已分配 GPU-P adapter 时事务更新。

    公共更新入口固定先取得 Common 模块的全宿主配置锁，再取得由 InstancePath
    派生的 Global mutex。这样直接调用也会与 Host 模块的 adapter 配置串行，
    无需依赖调用方记住锁约定。
#>

$gpuPCommon = Join-Path $PSScriptRoot 'VMate.GpuP.Common.ps1'
if (-not (Get-Command -Name ConvertTo-VMateGpuPUInt64 `
        -CommandType Function -ErrorAction SilentlyContinue)) {
    . $gpuPCommon
}

function Get-VMateGpuPValidPartitionCounts {
    param([Parameter(Mandatory = $true)][object]$HostGpu)

    $property = $HostGpu.PSObject.Properties['ValidPartitionCounts']
    if ($null -eq $property) {
        throw '所选宿主 GPU 缺少 ValidPartitionCounts 属性。'
    }
    $values = [System.Collections.Generic.List[uint64]]::new()
    foreach ($item in @($property.Value)) {
        $value = ConvertTo-VMateGpuPUInt64 $item `
            '所选宿主 GPU.ValidPartitionCounts'
        if ($value -eq 0 -or $value -gt [uint16]::MaxValue) {
            throw "ValidPartitionCounts 包含 Set-VMHostPartitionableGpu 无法使用的值：$value"
        }
        if (-not $values.Contains($value)) {
            [void]$values.Add($value)
        }
    }
    if ($values.Count -eq 0) {
        throw '所选宿主 GPU 的 ValidPartitionCounts 为空。'
    }
    return @($values | Sort-Object)
}

function Get-VMateGpuPPartitionCountPlan {
    param(
        [Parameter(Mandatory = $true)][object]$HostGpu,
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)][int]$GuestCapacity
    )

    $current = Get-VMateGpuPObjectUInt64 $HostGpu `
        'PartitionCount' '所选宿主 GPU'
    $valid = @(Get-VMateGpuPValidPartitionCounts $HostGpu)
    if ($valid -notcontains $current) {
        throw "当前 PartitionCount 不在 ValidPartitionCounts 中：$current"
    }

    # 已有数量足够时绝不为了贴近 GuestCapacity 而降低宿主分区数。
    if ($current -ge [uint64]$GuestCapacity) {
        $desired = $current
        $changeRequired = $false
    } else {
        $eligible = @($valid | Where-Object {
                $_ -ge [uint64]$GuestCapacity
            } | Sort-Object)
        if ($eligible.Count -eq 0) {
            throw ("所选宿主 GPU 没有可容纳 $GuestCapacity 个 guest 的有效分区数；" +
                "可用值：$($valid -join ', ')")
        }
        $desired = [uint64]$eligible[0]
        $changeRequired = $true
    }

    return [pscustomobject][ordered]@{
        GuestCapacity = $GuestCapacity
        PreviousPartitionCount = $current
        DesiredPartitionCount = $desired
        ValidPartitionCounts = $valid
        ChangeRequired = $changeRequired
    }
}

function Assert-VMateGpuPPartitionReadEnvironment {
    if ($env:OS -ne 'Windows_NT') {
        throw 'GPU-P 宿主分区数量只能在 Windows Hyper-V 宿主读取或配置。'
    }
    if (-not (Get-Command -Name Get-VMHostPartitionableGpu `
            -ErrorAction SilentlyContinue)) {
        throw '缺少 Hyper-V PowerShell cmdlet：Get-VMHostPartitionableGpu'
    }
}

function Resolve-VMateGpuPPartitionableGpu {
    param([Parameter(Mandatory = $true)][string]$InstancePath)

    if ([string]::IsNullOrWhiteSpace($InstancePath)) {
        throw 'InstancePath 不能为空。'
    }
    try {
        $matches = @(Get-VMHostPartitionableGpu -ErrorAction Stop |
            Where-Object {
                $name = $_.PSObject.Properties['Name']
                $null -ne $name -and [string]::Equals(
                    [string]$name.Value, $InstancePath,
                    [System.StringComparison]::OrdinalIgnoreCase)
            })
    } catch {
        throw "无法读取宿主 partitionable GPU：$($_.Exception.Message)"
    }
    if ($matches.Count -ne 1) {
        throw "InstancePath 无法唯一解析为 partitionable GPU：$InstancePath"
    }
    return $matches[0]
}

function Get-VMateGpuPAssignedAdapterSnapshot {
    param([Parameter(Mandatory = $true)][string]$InstancePath)

    if ([string]::IsNullOrWhiteSpace($InstancePath)) {
        throw '检查 adapter 归属时 InstancePath 不能为空。'
    }
    $required = @(
        'Get-VM', 'Get-VMGpuPartitionAdapter', 'Get-VMHostPartitionableGpu')
    foreach ($command in $required) {
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
            throw "缺少 Hyper-V PowerShell cmdlet：$command"
        }
    }
    try {
        $vms = @(Get-VM -ErrorAction Stop)
    } catch {
        throw "无法枚举 Hyper-V VM 以检查 GPU-P adapter：$($_.Exception.Message)"
    }
    try {
        $hostGpus = @(Get-VMHostPartitionableGpu -ErrorAction Stop)
    } catch {
        throw "无法枚举 partitionable GPU 以核对 adapter 归属：$($_.Exception.Message)"
    }

    $assigned = [System.Collections.Generic.List[object]]::new()
    foreach ($vm in $vms) {
        try {
            $adapters = @(Get-VMGpuPartitionAdapter -VM $vm -ErrorAction Stop)
        } catch {
            throw "无法读取 VM [$($vm.Name)] 的 GPU-P adapter：$($_.Exception.Message)"
        }
        foreach ($adapter in $adapters) {
            $pathProperty = $adapter.PSObject.Properties['InstancePath']
            $adapterPath = if ($null -eq $pathProperty) {
                ''
            } else {
                [string]$pathProperty.Value
            }
            $ownership = 'Unknown'
            if (-not [string]::IsNullOrWhiteSpace($adapterPath)) {
                if ([string]::Equals($adapterPath, $InstancePath,
                        [System.StringComparison]::OrdinalIgnoreCase)) {
                    $ownership = 'SelectedGpu'
                } else {
                    # 非空 mismatch 也可能是陈旧/损坏路径。只有它唯一命中当前
                    # partitionable inventory 中另一张有效 Name 时才能安全忽略。
                    $otherMatches = @($hostGpus | Where-Object {
                            $name = $_.PSObject.Properties['Name']
                            $null -ne $name -and
                            -not [string]::IsNullOrWhiteSpace(
                                [string]$name.Value) -and
                            [string]::Equals(
                                [string]$name.Value, $adapterPath,
                                [System.StringComparison]::OrdinalIgnoreCase)
                        })
                    if ($otherMatches.Count -eq 1) {
                        continue
                    }
                }
            }
            [void]$assigned.Add([pscustomobject][ordered]@{
                    VMName = [string]$vm.Name
                    InstancePath = $adapterPath
                    Ownership = $ownership
                    Adapter = $adapter
                })
        }
    }
    return @($assigned)
}

function Invoke-VMateGpuPHostPartitionCountCore {
    param(
        [Parameter(Mandatory = $true)][string]$InstancePath,
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)][int]$GuestCapacity,
        [switch]$DryRun
    )

    Assert-VMateGpuPPartitionReadEnvironment
    $beforeGpu = Resolve-VMateGpuPPartitionableGpu $InstancePath
    $plan = Get-VMateGpuPPartitionCountPlan $beforeGpu $GuestCapacity
    if (-not $plan.ChangeRequired) {
        return [pscustomobject][ordered]@{
            Status = 'Unchanged'
            InstancePath = $InstancePath
            GuestCapacity = $GuestCapacity
            PreviousPartitionCount = $plan.PreviousPartitionCount
            PartitionCount = $plan.DesiredPartitionCount
            ValidPartitionCounts = $plan.ValidPartitionCounts
            ChangeRequired = $false
            ChangeApplied = $false
        }
    }

    # 旧版 Win10 可能只有读取 cmdlet。数量无需变化时上方已经成功返回；只有
    # 真正需要更新时，缺少 setter 才是明确且可诊断的阻塞条件。
    if (-not (Get-Command -Name Set-VMHostPartitionableGpu `
            -ErrorAction SilentlyContinue)) {
        throw ('当前 Hyper-V 模块缺少 Set-VMHostPartitionableGpu；' +
            '现有 PartitionCount 不足，无法满足目标 guest 数量。')
    }
    $assigned = @(Get-VMateGpuPAssignedAdapterSnapshot `
        -InstancePath $InstancePath)
    if ($assigned.Count -ne 0) {
        $owners = @($assigned | ForEach-Object { $_.VMName } |
            Sort-Object -Unique)
        throw ("所选 GPU 已有或存在归属不明的 $($assigned.Count) 个 GPU-P " +
            "adapter，涉及 VM [$($owners -join ', ')]；为避免破坏现有分配，" +
            '拒绝更改 PartitionCount。')
    }

    if ($DryRun.IsPresent) {
        return [pscustomobject][ordered]@{
            Status = 'DryRun'
            InstancePath = $InstancePath
            GuestCapacity = $GuestCapacity
            PreviousPartitionCount = $plan.PreviousPartitionCount
            PartitionCount = $plan.DesiredPartitionCount
            ValidPartitionCounts = $plan.ValidPartitionCounts
            ChangeRequired = $true
            ChangeApplied = $false
        }
    }

    $mutationAttempted = $false
    try {
        $mutationAttempted = $true
        Set-VMHostPartitionableGpu -Name $InstancePath `
            -PartitionCount ([uint16]$plan.DesiredPartitionCount) `
            -ErrorAction Stop
        $afterGpu = Resolve-VMateGpuPPartitionableGpu $InstancePath
        $actual = Get-VMateGpuPObjectUInt64 $afterGpu `
            'PartitionCount' '更新后的宿主 GPU'
        if ($actual -ne $plan.DesiredPartitionCount) {
            throw ("PartitionCount 回读不一致：期望 " +
                "$($plan.DesiredPartitionCount)，实际 $actual")
        }
    } catch {
        $primaryError = $_.Exception.Message
        $rollbackError = ''
        if ($mutationAttempted) {
            try {
                Set-VMHostPartitionableGpu -Name $InstancePath `
                    -PartitionCount ([uint16]$plan.PreviousPartitionCount) `
                    -ErrorAction Stop
                $rollbackGpu = Resolve-VMateGpuPPartitionableGpu $InstancePath
                $rolledBack = Get-VMateGpuPObjectUInt64 $rollbackGpu `
                    'PartitionCount' '回滚后的宿主 GPU'
                if ($rolledBack -ne $plan.PreviousPartitionCount) {
                    throw ("回读值 $rolledBack，不是原值 " +
                        "$($plan.PreviousPartitionCount)")
                }
            } catch {
                $rollbackError = "；回滚失败：$($_.Exception.Message)"
            }
        }
        if (-not $rollbackError) {
            $rollbackError = '；已回滚到原 PartitionCount。'
        }
        throw "更新宿主 GPU-P PartitionCount 失败：$primaryError$rollbackError"
    }

    return [pscustomobject][ordered]@{
        Status = 'Changed'
        InstancePath = $InstancePath
        GuestCapacity = $GuestCapacity
        PreviousPartitionCount = $plan.PreviousPartitionCount
        PartitionCount = $plan.DesiredPartitionCount
        ValidPartitionCounts = $plan.ValidPartitionCounts
        ChangeRequired = $true
        ChangeApplied = $true
    }
}

function Set-VMateGpuPHostPartitionCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstancePath,
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)][int]$GuestCapacity,
        [switch]$DryRun,
        [ValidateRange(1, 300)][int]$LockTimeoutSeconds = 120
    )

    # 固定顺序是全宿主锁 -> per-GPU 锁。Common/Host 的 adapter 事务使用同一个
    # 全宿主锁，因此直接调用本入口时，PartitionCount 与 Add/Set adapter 不会
    # 并发。两层 mutex 都支持同线程递归，便于上层持有全宿主锁覆盖更长事务。
    $configurationLock = Enter-VMateGpuPConfigurationLock `
        -TimeoutSeconds $LockTimeoutSeconds
    try {
        return Invoke-VMateGpuPWithHostLock -InstancePath $InstancePath `
            -TimeoutSeconds $LockTimeoutSeconds -ScriptBlock {
                Invoke-VMateGpuPHostPartitionCountCore `
                    -InstancePath $InstancePath `
                    -GuestCapacity $GuestCapacity -DryRun:$DryRun
            }
    } finally {
        Exit-VMateGpuPConfigurationLock -Mutex $configurationLock
    }
}

function Restore-VMateGpuPHostPartitionCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstancePath,
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)][int]$ExpectedPartitionCount,
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)][int]$PreviousPartitionCount,
        [ValidateRange(1, 300)][int]$LockTimeoutSeconds = 120
    )

    $configurationLock = Enter-VMateGpuPConfigurationLock `
        -TimeoutSeconds $LockTimeoutSeconds
    try {
        return Invoke-VMateGpuPWithHostLock -InstancePath $InstancePath `
            -TimeoutSeconds $LockTimeoutSeconds -ScriptBlock {
                Assert-VMateGpuPPartitionReadEnvironment
                if (-not (Get-Command Set-VMHostPartitionableGpu `
                        -ErrorAction SilentlyContinue)) {
                    throw '回滚 PartitionCount 时缺少 Set-VMHostPartitionableGpu。'
                }
                $gpu = Resolve-VMateGpuPPartitionableGpu $InstancePath
                $actual = Get-VMateGpuPObjectUInt64 $gpu `
                    'PartitionCount' '回滚前的宿主 GPU'
                if ($actual -ne [uint64]$ExpectedPartitionCount) {
                    throw ("回滚前 PartitionCount 已变化：" +
                        "$actual != $ExpectedPartitionCount")
                }
                $assigned = @(Get-VMateGpuPAssignedAdapterSnapshot `
                        -InstancePath $InstancePath)
                if ($assigned.Count -ne 0) {
                    throw '回滚 PartitionCount 时所选 GPU 已存在或存在归属不明的 adapter。'
                }
                Set-VMHostPartitionableGpu -Name $InstancePath `
                    -PartitionCount ([uint16]$PreviousPartitionCount) `
                    -ErrorAction Stop
                $restoredGpu = Resolve-VMateGpuPPartitionableGpu $InstancePath
                $restored = Get-VMateGpuPObjectUInt64 $restoredGpu `
                    'PartitionCount' '回滚后的宿主 GPU'
                if ($restored -ne [uint64]$PreviousPartitionCount) {
                    throw "PartitionCount 回滚回读不一致：$restored"
                }
                return [pscustomobject]@{
                    Status = 'Restored'
                    InstancePath = $InstancePath
                    PartitionCount = $restored
                }
            }
    }
    finally {
        Exit-VMateGpuPConfigurationLock -Mutex $configurationLock
    }
}

function Get-VMateGpuPHostLockName {
    param([Parameter(Mandatory = $true)][string]$InstancePath)

    if ([string]::IsNullOrWhiteSpace($InstancePath)) {
        throw 'GPU-P 宿主锁的 InstancePath 不能为空。'
    }
    $normalized = $InstancePath.Trim().ToUpperInvariant()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
        $digest = $sha256.ComputeHash($bytes)
    } finally {
        $sha256.Dispose()
    }
    $suffix = [System.BitConverter]::ToString($digest).Replace('-', '')
    return "Global\VMate.GpuP.$suffix"
}

function Invoke-VMateGpuPWithHostLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstancePath,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 120
    )

    $lockName = Get-VMateGpuPHostLockName $InstancePath
    try {
        $mutex = [System.Threading.Mutex]::new($false, $lockName)
    } catch {
        throw "无法创建 GPU-P 宿主全局锁 [$lockName]：$($_.Exception.Message)"
    }
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(
                [TimeSpan]::FromSeconds($TimeoutSeconds))
        } catch [System.Threading.AbandonedMutexException] {
            # 前一进程异常退出时 .NET 已把 abandoned mutex 授予当前线程。
            $acquired = $true
        }
        if (-not $acquired) {
            throw ("等待所选 GPU 的宿主配置锁超过 ${TimeoutSeconds}s；" +
                "InstancePath=$InstancePath")
        }
        return & $ScriptBlock
    } finally {
        if ($acquired) {
            try {
                $mutex.ReleaseMutex()
            } finally {
                $mutex.Dispose()
            }
        } else {
            $mutex.Dispose()
        }
    }
}

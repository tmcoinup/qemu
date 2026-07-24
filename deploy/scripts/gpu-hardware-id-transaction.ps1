#Requires -Version 5.1

<#
.SYNOPSIS
  HardwareID 逻辑首项的事务化 Apply/Verify 实现。

.DESCRIPTION
  本文件由 project-gpu-hardware-id.ps1 在同一作用域加载。入口脚本负责注册表
  读取、唯一写点、回滚与全局互斥；这里仅编排 durable journal、身份 CAS、
  写后复核和只读验收，使每个 PowerShell 文件保持在 500 行以内。
#>

function Assert-SameProjectionIdentity {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual
    )

    foreach ($name in 'IdentityId', 'SourceInstanceId', 'SpoofPciVendorId',
            'SpoofPciDeviceId', 'SpoofSubsystemVendorId',
            'SpoofSubsystemDeviceId', 'SpoofRevisionId') {
        if ([string]$Actual.$name -cne [string]$Expected.$name) {
            throw ('CurrentIdentity 在 HardwareID 事务期间切换了字段：' + $name)
        }
    }
}

function Assert-PresentProjectionTarget {
    param([Parameter(Mandatory = $true)][string]$InstanceId)

    $present = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
        Where-Object { [string]$_.InstanceId -ieq $InstanceId })
    if ($present.Count -ne 1 -or [string]$present[0].Status -ine 'OK') {
        throw ('目标显示设备未唯一在线或状态非 OK：' + $InstanceId)
    }
}

function Get-ExpectedProjectionIds {
    param(
        [Parameter(Mandatory = $true)][string[]]$OriginalIds,
        [Parameter(Mandatory = $true)]$Identity
    )

    return [string[]]@(Get-ProjectedHardwareIds -OriginalIds $OriginalIds `
        -VendorId ([int]$Identity.SpoofPciVendorId) `
        -DeviceId ([int]$Identity.SpoofPciDeviceId) `
        -SubsystemVendorId ([int]$Identity.SpoofSubsystemVendorId) `
        -SubsystemDeviceId ([int]$Identity.SpoofSubsystemDeviceId) `
        -RevisionId ([int]$Identity.SpoofRevisionId))
}

function Set-ProjectionBackupState {
    # 新键先完整落盘 immutable binding，再发布 schema=1；设备值随后才允许写入。
    param(
        [Parameter(Mandatory = $true)]$BaseKey,
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string[]]$OriginalIds,
        [Parameter(Mandatory = $true)][string[]]$AppliedIds,
        [AllowNull()][AllowEmptyCollection()][string[]]$PendingIds,
        [Parameter(Mandatory = $true)][string]$IdentityId,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Applying', 'Applied')][string]$State
    )

    $relativePath = Get-BackupRelativePath $Target.InstanceId
    $existing = Get-ProjectionBackup $BaseKey $Target.InstanceId
    $key = $BaseKey.CreateSubKey($relativePath, $true)
    if ($null -eq $key) { throw '不能创建 HardwareID 投影备份键' }
    try {
        if ($null -eq $existing) {
            $key.SetValue('SchemaVersion', 0, $dwordKind)
            $key.SetValue('InstanceId', $Target.InstanceId, $stringKind)
            $key.SetValue('OriginalHardwareIds', $OriginalIds, $multiStringKind)
            $key.SetValue('OriginalCompatibleIds', $Target.CompatibleIds,
                $multiStringKind)
            $key.SetValue('OriginalService', $Target.Service, $stringKind)
            $key.SetValue('OriginalDriver', $Target.Driver, $stringKind)
        } elseif (-not (Test-StringArrayEqual `
                $existing.OriginalHardwareIds $OriginalIds) -or
            -not (Test-StringArrayEqual `
                $existing.OriginalCompatibleIds $Target.CompatibleIds) -or
            $existing.OriginalService -cne $Target.Service -or
            $existing.OriginalDriver -cne $Target.Driver) {
            throw '拒绝改写既有投影备份的原始绑定契约'
        }
        # RollbackHardwareIds 是设备写入前的持久锚点。Applying 首次发布它并
        # 单独 Flush；Applied 收尾沿用既有值。这样即使后续 Applied/Pending/
        # State 任一写入中断，catch 恢复的 beforeIds 仍属于 journal 允许集合。
        [string[]]$rollbackIds = @($AppliedIds)
        if ($State -eq 'Applied' -and $null -ne $existing -and
            @($existing.RollbackHardwareIds).Count -gt 0) {
            $rollbackIds = [string[]]@($existing.RollbackHardwareIds)
        }
        $key.SetValue('RollbackHardwareIds', $rollbackIds, $multiStringKind)
        $key.Flush()
        $key.SetValue('AppliedHardwareIds', $AppliedIds, $multiStringKind)
        $key.SetValue('IdentityId', $IdentityId, $stringKind)
        if (@($PendingIds).Count -gt 0) {
            $key.SetValue('PendingHardwareIds', $PendingIds, $multiStringKind)
        } else {
            $key.DeleteValue('PendingHardwareIds', $false)
        }
        $key.SetValue('TransactionState', $State, $stringKind)
        $key.Flush()
        if ($null -eq $existing) {
            $key.SetValue('SchemaVersion', 1, $dwordKind)
            $key.Flush()
        }
    } finally {
        $key.Dispose()
    }
}

function Invoke-ProjectionApply {
    param([Parameter(Mandatory = $true)]$BaseKey)

    $identity = Get-StrictIdentity
    $instanceId = [string]$identity.SourceInstanceId
    Assert-PresentProjectionTarget $instanceId
    $target = Get-TargetRegistryState $BaseKey $instanceId
    Remove-IncompleteBackupIfRecoverable $BaseKey $target $identity
    $backup = Get-ProjectionBackup $BaseKey $instanceId

    [string[]]$originalIds = @()
    if ($null -eq $backup) {
        if ($target.HardwareIds[0] -match $physicalPattern) {
            $originalIds = [string[]]@($target.HardwareIds)
            Assert-PhysicalHardwareIds $originalIds
        } else {
            $originalIds = [string[]]@(Get-OriginalIdsFromExistingProjection `
                -CurrentIds $target.HardwareIds `
                -VendorId ([int]$identity.SpoofPciVendorId) `
                -DeviceId ([int]$identity.SpoofPciDeviceId) `
                -SubsystemVendorId ([int]$identity.SpoofSubsystemVendorId) `
                -SubsystemDeviceId ([int]$identity.SpoofSubsystemDeviceId) `
                -RevisionId ([int]$identity.SpoofRevisionId))
            if ($originalIds.Count -eq 0) {
                throw '当前 HardwareID 不是物理原值或当前 profile 的精确投影'
            }
        }
    } else {
        if ($backup.OriginalService -cne $target.Service -or
            $backup.OriginalDriver -cne $target.Driver -or
            -not (Test-StringArrayEqual `
                $backup.OriginalCompatibleIds $target.CompatibleIds) -or
            -not (Test-BackupAllowsCurrentIds $backup $target.HardwareIds)) {
            throw '投影备份、当前 HardwareID 或驱动绑定不一致'
        }
        $originalIds = [string[]]@($backup.OriginalHardwareIds)
    }
    if (-not $instanceId.StartsWith(($originalIds[0] + '\'),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'CurrentIdentity.SourceInstanceId 与物理首条 HardwareID 不一致'
    }
    [string[]]$expected = @(Get-ExpectedProjectionIds $originalIds $identity)
    Assert-SameProjectionIdentity $identity (Get-StrictIdentity)

    if (Test-StringArrayEqual $target.HardwareIds $expected) {
        if ($null -eq $backup -or $backup.TransactionState -ne 'Applied' -or
            $backup.IdentityId -cne [string]$identity.IdentityId) {
            Set-ProjectionBackupState $BaseKey $target $originalIds $expected `
                @() ([string]$identity.IdentityId) 'Applied'
        }
        Write-Host 'PnP HardwareID 已是当前 profile 的精确浅层投影。' `
            -ForegroundColor Green
        return
    }

    [string[]]$beforeIds = @($target.HardwareIds)
    Set-ProjectionBackupState $BaseKey $target $originalIds $beforeIds `
        $expected ([string]$identity.IdentityId) 'Applying'
    $beforeWrite = Get-TargetRegistryState $BaseKey $instanceId
    Assert-BindingUnchanged $target $beforeWrite
    if (-not (Test-StringArrayEqual $beforeWrite.HardwareIds $beforeIds)) {
        throw 'HardwareID 在提交前发生变化'
    }
    Assert-SameProjectionIdentity $identity (Get-StrictIdentity)

    $writeAttempted = $false
    try {
        $writeAttempted = $true
        Set-TargetHardwareIds $BaseKey $target $expected
        $verified = Get-TargetRegistryState $BaseKey $instanceId
        Assert-BindingUnchanged $target $verified
        if (-not (Test-StringArrayEqual $verified.HardwareIds $expected)) {
            throw 'HardwareID 写后复核不等于预期投影'
        }
        Assert-SameProjectionIdentity $identity (Get-StrictIdentity)
        Set-ProjectionBackupState $BaseKey $target $originalIds $expected `
            @() ([string]$identity.IdentityId) 'Applied'
    } catch {
        $failure = $_
        if ($writeAttempted) {
            try {
                Set-TargetHardwareIds $BaseKey $target $beforeIds
                $restored = Get-TargetRegistryState $BaseKey $instanceId
                Assert-BindingUnchanged $target $restored
                if (-not (Test-StringArrayEqual `
                        $restored.HardwareIds $beforeIds)) {
                    throw '恢复后的 HardwareID 与事务前值不同'
                }
            } catch {
                throw ('HardwareID 投影与自动回滚均失败：提交={0}；回滚={1}' -f `
                    $failure.Exception.Message, $_.Exception.Message)
            }
        }
        throw $failure
    }
    Write-Host ('PnP HardwareID 浅层投影已提交：{0:X4}:{1:X4}；' +
        '实际 VioGpuDod/InstanceId/BDF 均保持不变' -f `
        [int]$identity.SpoofPciVendorId, [int]$identity.SpoofPciDeviceId) `
        -ForegroundColor Green
}

function Invoke-ProjectionVerify {
    # 只读验收，不在诊断路径中顺手修复。
    param([Parameter(Mandatory = $true)]$BaseKey)

    $identity = Get-StrictIdentity
    $instanceId = [string]$identity.SourceInstanceId
    Assert-PresentProjectionTarget $instanceId
    $target = Get-TargetRegistryState $BaseKey $instanceId
    $backup = Get-ProjectionBackup $BaseKey $instanceId
    if ($null -ne $backup) {
        if ($backup.OriginalService -cne $target.Service -or
            $backup.OriginalDriver -cne $target.Driver -or
            -not (Test-StringArrayEqual `
                $backup.OriginalCompatibleIds $target.CompatibleIds)) {
            throw '投影备份与当前驱动绑定不一致'
        }
        [string[]]$originalIds = @($backup.OriginalHardwareIds)
    } else {
        [string[]]$originalIds = @(Get-OriginalIdsFromExistingProjection `
            -CurrentIds $target.HardwareIds `
            -VendorId ([int]$identity.SpoofPciVendorId) `
            -DeviceId ([int]$identity.SpoofPciDeviceId) `
            -SubsystemVendorId ([int]$identity.SpoofSubsystemVendorId) `
            -SubsystemDeviceId ([int]$identity.SpoofSubsystemDeviceId) `
            -RevisionId ([int]$identity.SpoofRevisionId))
        if ($originalIds.Count -eq 0) { throw '当前设备没有可验证的 profile 投影' }
    }
    [string[]]$expected = @(Get-ExpectedProjectionIds $originalIds $identity)
    if (-not (Test-StringArrayEqual $target.HardwareIds $expected)) {
        throw '当前 HardwareID 不等于 CurrentIdentity 的精确投影'
    }
    Assert-SameProjectionIdentity $identity (Get-StrictIdentity)
    Write-Host 'PnP HardwareID 浅层投影与驱动绑定只读验收通过。' `
        -ForegroundColor Green
}

#Requires -Version 5.1

<#
.SYNOPSIS
  在不重绑驱动的前提下，把 stock VioGpuDod 的首条 PnP HardwareID 投影为 profile PCI ID。

.DESCRIPTION
  QEMU PCI 配置空间、设备实例路径、Service、Driver 和 CompatibleIDs 始终保持真实的
  1AF4:1050。本脚本只把 Enum\PCI 实例的 HardwareID REG_MULTI_SZ 排列为：

      profile 逻辑首项 + 完整原始物理数组

  这与 VM2 上 GPU-Z 2.70 的实机验收路径完全一致，也能覆盖其他通过 SetupAPI 读取
  SPDRP_HARDWAREID 的普通硬件工具。它不是 PCI 配置空间伪装，也不会给 Windows guest
  增加 D3D/Vulkan 加速能力。

  脚本不调用 pnputil/devcon，不禁用或启用设备，不触发 PnP 扫描，不改 ACL。每个
  SourceInstanceId 使用独立事务备份；Apply 幂等，Rollback 只恢复本事务认识的值，
  遇到第三方修改时 fail-closed。
#>

[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Verify', 'RestorePhysical', 'Rollback')]
    [string]$Mode = 'Apply'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$physicalPattern = '^PCI\\VEN_1AF4&DEV_1050(?:&|$)'
$backupRoot = 'SOFTWARE\StealthGPU\HardwareIdProjections'
$identityReader = Join-Path $PSScriptRoot 'refresh-gpu-name.ps1'
$planHelper = Join-Path $PSScriptRoot 'gpu-hardware-id-plan.ps1'
$multiStringKind = [Microsoft.Win32.RegistryValueKind]::MultiString
$stringKind = [Microsoft.Win32.RegistryValueKind]::String
$dwordKind = [Microsoft.Win32.RegistryValueKind]::DWord

if (-not (Test-Path -LiteralPath $planHelper -PathType Leaf)) {
    throw ('缺少 HardwareID 规划 helper：' + $planHelper)
}
. $planHelper

function Get-BackupRelativePath {
    # InstanceId 含反斜杠，不能直接作为单个注册表子键名。使用其规范化文本 SHA-256
    # 隔离每台 clone/每个 PCI 实例，同时把原文保存在备份中供碰撞与串实例复核。
    param([Parameter(Mandatory = $true)][string]$InstanceId)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($InstanceId.ToUpperInvariant())
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    $name = [BitConverter]::ToString($hash).Replace('-', '')
    return $backupRoot + '\' + $name
}

function Get-ExactRegistryValue {
    param(
        [Parameter(Mandatory = $true)]$Key,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Microsoft.Win32.RegistryValueKind]$Kind
    )

    if (-not (@($Key.GetValueNames()) -ccontains $Name)) {
        throw ('注册表值不存在：' + $Name)
    }
    if ($Key.GetValueKind($Name) -ne $Kind) {
        throw ('注册表值类型错误：' + $Name)
    }
    return $Key.GetValue($Name, $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Get-TargetRegistryState {
    param(
        [Parameter(Mandatory = $true)]$BaseKey,
        [Parameter(Mandatory = $true)][string]$InstanceId
    )

    $relativePath = 'SYSTEM\CurrentControlSet\Enum\' + $InstanceId
    $key = $BaseKey.OpenSubKey($relativePath, $false)
    if ($null -eq $key) { throw ('找不到显示设备实例：' + $relativePath) }
    try {
        [string]$service = Get-ExactRegistryValue $key 'Service' $stringKind
        [string]$driver = Get-ExactRegistryValue $key 'Driver' $stringKind
        [string[]]$hardwareIds = @(Get-ExactRegistryValue $key 'HardwareID' $multiStringKind)
        [string[]]$compatibleIds = @(Get-ExactRegistryValue $key 'CompatibleIDs' $multiStringKind)
        Assert-HardwareIdArray $hardwareIds '当前 HardwareID'
        Assert-HardwareIdArray $compatibleIds '当前 CompatibleIDs'
        if ($service -ine 'VioGpuDod') { throw ('显示服务不是 VioGpuDod：' + $service) }
        if ($driver -notmatch '^\{4d36e968-e325-11ce-bfc1-08002be10318\}\\\d{4}$') {
            throw ('显示 Class 绑定异常：' + $driver)
        }
        return [pscustomobject]@{
            InstanceId = $InstanceId
            RelativePath = $relativePath
            Service = $service
            Driver = $driver
            HardwareIds = $hardwareIds
            CompatibleIds = $compatibleIds
        }
    } finally {
        $key.Dispose()
    }
}

function Assert-BindingUnchanged {
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After
    )

    if ($After.Service -cne $Before.Service -or $After.Driver -cne $Before.Driver -or
        -not (Test-StringArrayEqual $After.CompatibleIds $Before.CompatibleIds)) {
        throw 'CompatibleIDs、Service 或 Driver 在事务期间发生变化'
    }
}

function Get-StrictIdentity {
    if (-not (Test-Path -LiteralPath $identityReader -PathType Leaf)) {
        throw ('缺少严格身份读取 helper：' + $identityReader)
    }
    $identity = & $identityReader -ReadIdentityOnly
    foreach ($name in 'IdentityId', 'SourceInstanceId', 'SpoofPciVendorId',
            'SpoofPciDeviceId') {
        if ($null -eq $identity.PSObject.Properties[$name]) {
            throw ('严格身份缺少字段：' + $name)
        }
    }
    return $identity
}

function Assert-SameIdentity {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual
    )

    if ([string]$Actual.IdentityId -cne [string]$Expected.IdentityId -or
        [string]$Actual.SourceInstanceId -cne [string]$Expected.SourceInstanceId -or
        [int]$Actual.SpoofPciVendorId -ne [int]$Expected.SpoofPciVendorId -or
        [int]$Actual.SpoofPciDeviceId -ne [int]$Expected.SpoofPciDeviceId) {
        throw 'CurrentIdentity 在 HardwareID 事务期间发生切换'
    }
}

function Assert-PresentTarget {
    param([Parameter(Mandatory = $true)][string]$InstanceId)

    $present = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
        Where-Object { [string]$_.InstanceId -ieq $InstanceId })
    if ($present.Count -ne 1 -or [string]$present[0].Status -ine 'OK') {
        throw ('目标显示设备未唯一在线或状态非 OK：' + $InstanceId)
    }
}

function Get-ProjectionBackup {
    param(
        [Parameter(Mandatory = $true)]$BaseKey,
        [Parameter(Mandatory = $true)][string]$InstanceId
    )

    $relativePath = Get-BackupRelativePath $InstanceId
    $key = $BaseKey.OpenSubKey($relativePath, $false)
    if ($null -eq $key) { return $null }
    try {
        $schema = [int](Get-ExactRegistryValue $key 'SchemaVersion' $dwordKind)
        if ($schema -ne 1) { throw ('不支持的投影备份 schema：' + $schema) }
        $state = [string](Get-ExactRegistryValue $key 'TransactionState' $stringKind)
        if ($state -notin @('Applying', 'Applied')) {
            throw ('非法投影事务状态：' + $state)
        }
        $pending = [string[]]@()
        if (@($key.GetValueNames()) -ccontains 'PendingHardwareIds') {
            $pending = [string[]]@(Get-ExactRegistryValue $key `
                'PendingHardwareIds' $multiStringKind)
        }
        $result = [pscustomobject]@{
            RelativePath = $relativePath
            InstanceId = [string](Get-ExactRegistryValue $key 'InstanceId' $stringKind)
            OriginalHardwareIds = [string[]]@(Get-ExactRegistryValue $key `
                'OriginalHardwareIds' $multiStringKind)
            AppliedHardwareIds = [string[]]@(Get-ExactRegistryValue $key `
                'AppliedHardwareIds' $multiStringKind)
            PendingHardwareIds = $pending
            OriginalCompatibleIds = [string[]]@(Get-ExactRegistryValue $key `
                'OriginalCompatibleIds' $multiStringKind)
            OriginalService = [string](Get-ExactRegistryValue $key 'OriginalService' $stringKind)
            OriginalDriver = [string](Get-ExactRegistryValue $key 'OriginalDriver' $stringKind)
            IdentityId = [string](Get-ExactRegistryValue $key 'IdentityId' $stringKind)
            TransactionState = $state
        }
        if ($result.InstanceId -cne $InstanceId) {
            throw '投影备份散列命中其他设备实例，拒绝继续'
        }
        Assert-PhysicalHardwareIds $result.OriginalHardwareIds
        return $result
    } finally {
        $key.Dispose()
    }
}

function Remove-IncompleteBackupIfRecoverable {
    # 新备份以 schema=0 开始，并在 HardwareID 写入前发布为 schema=1。若进程恰好在
    # 这段窗口退出，当前设备只能仍是纯物理数组，或是首次接管前已存在的当前 profile
    # 精确投影；只有这两种可重建状态才删除半成品，其他布局继续 fail-closed。
    param(
        [Parameter(Mandatory = $true)]$BaseKey,
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)]$Identity
    )

    $relativePath = Get-BackupRelativePath $Target.InstanceId
    $key = $BaseKey.OpenSubKey($relativePath, $false)
    if ($null -eq $key) { return }
    try {
        $names = @($key.GetValueNames())
        if ($names -ccontains 'SchemaVersion') {
            if ($key.GetValueKind('SchemaVersion') -ne $dwordKind) {
                throw '未完成投影备份的 schema 类型错误'
            }
            $schema = [int]$key.GetValue('SchemaVersion')
            if ($schema -eq 1) { return }
            if ($schema -ne 0) { throw ('不支持的投影备份 schema：' + $schema) }
        }
    } finally {
        $key.Dispose()
    }

    $recoverable = $false
    try {
        Assert-PhysicalHardwareIds $Target.HardwareIds
        $recoverable = $true
    } catch {
        $original = @(Get-OriginalIdsFromExistingProjection $Target.HardwareIds `
            ([int]$Identity.SpoofPciVendorId) ([int]$Identity.SpoofPciDeviceId))
        $recoverable = $original.Count -gt 0
    }
    if (-not $recoverable) { throw '存在 schema=0 半成品，但当前 HardwareID 无法安全重建' }
    $BaseKey.DeleteSubKeyTree($relativePath, $false)
}

function Set-BackupState {
    # 备份键只记录事务元数据；设备实例本身唯一允许写入的值仍然只有 HardwareID。
    param(
        [Parameter(Mandatory = $true)]$BaseKey,
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string[]]$OriginalIds,
        [Parameter(Mandatory = $true)][string[]]$AppliedIds,
        [AllowNull()][AllowEmptyCollection()][string[]]$PendingIds,
        [Parameter(Mandatory = $true)][string]$IdentityId,
        [Parameter(Mandatory = $true)][ValidateSet('Applying', 'Applied')][string]$State
    )

    $relativePath = Get-BackupRelativePath $Target.InstanceId
    $existing = Get-ProjectionBackup $BaseKey $Target.InstanceId
    $key = $BaseKey.CreateSubKey($relativePath, $true)
    if ($null -eq $key) { throw '不能创建 HardwareID 投影备份键' }
    try {
        if ($null -eq $existing) {
            # 新键先以 schema=0 标记未提交，全部不可变字段落盘后才发布 schema=1。
            # 设备 HardwareID 的写入发生在本函数返回以后，所以 schema=0 残留时
            # 物理数组尚未被触碰，可以安全地由管理员清理后重试。
            $key.SetValue('SchemaVersion', 0, $dwordKind)
            $key.SetValue('InstanceId', $Target.InstanceId, $stringKind)
            $key.SetValue('OriginalHardwareIds', $OriginalIds, $multiStringKind)
            $key.SetValue('OriginalCompatibleIds', $Target.CompatibleIds, $multiStringKind)
            $key.SetValue('OriginalService', $Target.Service, $stringKind)
            $key.SetValue('OriginalDriver', $Target.Driver, $stringKind)
        } elseif (-not (Test-StringArrayEqual $existing.OriginalHardwareIds $OriginalIds) -or
            -not (Test-StringArrayEqual $existing.OriginalCompatibleIds $Target.CompatibleIds) -or
            $existing.OriginalService -cne $Target.Service -or
            $existing.OriginalDriver -cne $Target.Driver) {
            throw '拒绝改写既有投影备份的原始绑定契约'
        }
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

function Set-TargetHardwareIds {
    # 此函数是生产代码中唯一写 Enum\PCI HardwareID 的位置，便于 AST 测试审计。
    param(
        [Parameter(Mandatory = $true)]$BaseKey,
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string[]]$HardwareIds
    )

    $key = $BaseKey.OpenSubKey($Target.RelativePath, $true)
    if ($null -eq $key) { throw ('不能写显示设备实例：' + $Target.RelativePath) }
    try {
        $key.SetValue('HardwareID', $HardwareIds, $multiStringKind)
        $key.Flush()
    } finally {
        $key.Dispose()
    }
}

function Test-BackupAllowsCurrentIds {
    param(
        [Parameter(Mandatory = $true)]$Backup,
        [Parameter(Mandatory = $true)][string[]]$CurrentIds
    )

    if (Test-StringArrayEqual $CurrentIds $Backup.OriginalHardwareIds) { return $true }
    if (Test-StringArrayEqual $CurrentIds $Backup.AppliedHardwareIds) { return $true }
    return ($Backup.PendingHardwareIds.Count -gt 0 -and
        (Test-StringArrayEqual $CurrentIds $Backup.PendingHardwareIds))
}

function Invoke-ProjectionApply {
    param([Parameter(Mandatory = $true)]$BaseKey)

    $identityA = Get-StrictIdentity
    $instanceId = [string]$identityA.SourceInstanceId
    Assert-PresentTarget $instanceId
    $target = Get-TargetRegistryState $BaseKey $instanceId
    Remove-IncompleteBackupIfRecoverable $BaseKey $target $identityA
    $backup = Get-ProjectionBackup $BaseKey $instanceId

    [string[]]$originalIds = @()
    if ($null -eq $backup) {
        if ($target.HardwareIds[0] -match $physicalPattern) {
            $originalIds = [string[]]@($target.HardwareIds)
            Assert-PhysicalHardwareIds $originalIds
        } else {
            $originalIds = [string[]]@(Get-OriginalIdsFromExistingProjection `
                -CurrentIds $target.HardwareIds `
                -VendorId ([int]$identityA.SpoofPciVendorId) `
                -DeviceId ([int]$identityA.SpoofPciDeviceId))
            if ($originalIds.Count -eq 0) {
                throw '当前 HardwareID 不是物理原值或当前 profile 的精确既有投影'
            }
        }
    } else {
        if ($backup.OriginalService -cne $target.Service -or
            $backup.OriginalDriver -cne $target.Driver -or
            -not (Test-StringArrayEqual $backup.OriginalCompatibleIds `
                $target.CompatibleIds)) {
            throw 'HardwareID 投影备份与当前驱动绑定不一致'
        }
        if (-not (Test-BackupAllowsCurrentIds $backup $target.HardwareIds)) {
            throw '当前 HardwareID 已被第三方修改，拒绝覆盖'
        }
        $originalIds = [string[]]@($backup.OriginalHardwareIds)
    }

    if (-not $instanceId.StartsWith(($originalIds[0] + '\'),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'CurrentIdentity.SourceInstanceId 与物理首条 HardwareID 不一致'
    }
    [string[]]$expected = @(Get-ProjectedHardwareIds -OriginalIds $originalIds `
        -VendorId ([int]$identityA.SpoofPciVendorId) `
        -DeviceId ([int]$identityA.SpoofPciDeviceId))

    # 第一次接管 VM2 的已投影现场状态时只建立备份；后续计划任务命中当前状态时
    # 完全零写 Enum\PCI，避免每次登录都制造无意义的设备属性变更。
    $identityB = Get-StrictIdentity
    Assert-SameIdentity $identityA $identityB
    if (Test-StringArrayEqual $target.HardwareIds $expected) {
        if ($null -eq $backup -or $backup.TransactionState -ne 'Applied' -or
            $backup.IdentityId -cne [string]$identityA.IdentityId) {
            Set-BackupState $BaseKey $target $originalIds $expected @() `
                ([string]$identityA.IdentityId) 'Applied'
        }
        Write-Host ('PnP HardwareID 已是 profile 浅层投影：{0:X4}:{1:X4}' -f `
            [int]$identityA.SpoofPciVendorId, [int]$identityA.SpoofPciDeviceId) `
            -ForegroundColor Green
        return
    }

    [string[]]$beforeIds = @($target.HardwareIds)
    Set-BackupState $BaseKey $target $originalIds $beforeIds $expected `
        ([string]$identityA.IdentityId) 'Applying'

    # 备份落盘后再次复读设备和身份，堵住预检与设备写入之间的 TOCTOU 窗口。
    $beforeWrite = Get-TargetRegistryState $BaseKey $instanceId
    Assert-BindingUnchanged $target $beforeWrite
    if (-not (Test-StringArrayEqual $beforeWrite.HardwareIds $beforeIds)) {
        throw 'HardwareID 在提交前发生变化'
    }
    Assert-SameIdentity $identityA (Get-StrictIdentity)

    $hardwareWriteAttempted = $false
    try {
        # SetValue 成功而 Flush/Dispose 抛错时，调用方无法知道值是否已落盘。因此在
        # 进入唯一 writer 前就标记“结果不确定”，catch 必须按已写入处理并恢复。
        $hardwareWriteAttempted = $true
        Set-TargetHardwareIds $BaseKey $target $expected
        $verified = Get-TargetRegistryState $BaseKey $instanceId
        Assert-BindingUnchanged $target $verified
        if (-not (Test-StringArrayEqual $verified.HardwareIds $expected)) {
            throw 'HardwareID 写后复核不等于预期投影'
        }
        Assert-SameIdentity $identityA (Get-StrictIdentity)
        Set-BackupState $BaseKey $target $originalIds $expected @() `
            ([string]$identityA.IdentityId) 'Applied'
    } catch {
        $failure = $_
        if ($hardwareWriteAttempted) {
            try {
                Set-TargetHardwareIds $BaseKey $target $beforeIds
                $restored = Get-TargetRegistryState $BaseKey $instanceId
                Assert-BindingUnchanged $target $restored
                if (-not (Test-StringArrayEqual $restored.HardwareIds $beforeIds)) {
                    throw '恢复后的 HardwareID 与事务前值不同'
                }
            } catch {
                throw ('HardwareID 投影失败，且自动回滚也失败：提交错误={0}；回滚错误={1}' -f `
                    $failure.Exception.Message, $_.Exception.Message)
            }
        }
        throw $failure
    }

    Write-Host ('PnP HardwareID 浅层投影已提交：{0:X4}:{1:X4}；' +
        'VioGpuDod/CompatibleIDs/实例路径保持不变' -f `
        [int]$identityA.SpoofPciVendorId, [int]$identityA.SpoofPciDeviceId) `
        -ForegroundColor Green
}

function Invoke-ProjectionVerify {
    # Verify 是部署验收和计划任务诊断入口，严格只读，不“顺手修复”任何异常状态。
    param([Parameter(Mandatory = $true)]$BaseKey)

    $identity = Get-StrictIdentity; $instanceId = [string]$identity.SourceInstanceId
    Assert-PresentTarget $instanceId
    $target = Get-TargetRegistryState $BaseKey $instanceId
    $backup = Get-ProjectionBackup $BaseKey $instanceId
    if ($null -ne $backup) {
        if ($backup.OriginalService -cne $target.Service -or
            $backup.OriginalDriver -cne $target.Driver -or
            -not (Test-StringArrayEqual $backup.OriginalCompatibleIds `
                $target.CompatibleIds)) {
            throw '投影备份与当前驱动绑定不一致'
        }
        [string[]]$originalIds = @($backup.OriginalHardwareIds)
    } else {
        [string[]]$originalIds = @(Get-OriginalIdsFromExistingProjection `
            -CurrentIds $target.HardwareIds `
            -VendorId ([int]$identity.SpoofPciVendorId) `
            -DeviceId ([int]$identity.SpoofPciDeviceId))
        if ($originalIds.Count -eq 0) { throw '当前设备没有可验证的 profile 投影' }
    }
    [string[]]$expected = @(Get-ProjectedHardwareIds -OriginalIds $originalIds `
        -VendorId ([int]$identity.SpoofPciVendorId) `
        -DeviceId ([int]$identity.SpoofPciDeviceId))
    if (-not (Test-StringArrayEqual $target.HardwareIds $expected)) {
        throw '当前 HardwareID 不等于 CurrentIdentity 对应的精确投影'
    }
    Assert-SameIdentity $identity (Get-StrictIdentity)
    Write-Host 'PnP HardwareID 浅层投影只读验收通过。' -ForegroundColor Green
}

function Invoke-ProjectionRollback {
    param([Parameter(Mandatory = $true)]$BaseKey)

    $identity = Get-StrictIdentity; $instanceId = [string]$identity.SourceInstanceId
    $backup = Get-ProjectionBackup $BaseKey $instanceId
    if ($null -eq $backup) {
        Write-Host '当前设备实例没有 HardwareID 投影备份；无需回滚。' -ForegroundColor Cyan
        return
    }
    $target = Get-TargetRegistryState $BaseKey $instanceId
    if ($backup.OriginalService -cne $target.Service -or
        $backup.OriginalDriver -cne $target.Driver -or
        -not (Test-StringArrayEqual $backup.OriginalCompatibleIds $target.CompatibleIds) -or
        -not (Test-BackupAllowsCurrentIds $backup $target.HardwareIds)) {
        throw '设备或 HardwareID 已被第三方修改，拒绝用旧备份覆盖'
    }

    if (-not (Test-StringArrayEqual $target.HardwareIds $backup.OriginalHardwareIds)) {
        Set-TargetHardwareIds $BaseKey $target $backup.OriginalHardwareIds
        $verified = Get-TargetRegistryState $BaseKey $instanceId
        Assert-BindingUnchanged $target $verified
        if (-not (Test-StringArrayEqual $verified.HardwareIds `
                $backup.OriginalHardwareIds)) {
            throw 'HardwareID 回滚后验证失败；备份保留供人工恢复'
        }
    }
    $BaseKey.DeleteSubKeyTree($backup.RelativePath, $false)
    Write-Host 'PnP HardwareID 已恢复 stock 1AF4:1050；未触发 PnP 重扫。' `
        -ForegroundColor Green
}

function Invoke-RestorePhysical {
    # respawn 重跑前必须让 apply-gpu-spoof 的 PnP scan 只看到真实 1AF4:1050。
    # 正式备份存在时走严格 Rollback；首次接管 VM2 现场状态时，仅接受当前 profile
    # 能精确反推的单 fake-first 布局，不接受未知历史 fake。
    param([Parameter(Mandatory = $true)]$BaseKey)

    $identity = Get-StrictIdentity; $instanceId = [string]$identity.SourceInstanceId
    $target = Get-TargetRegistryState $BaseKey $instanceId
    Remove-IncompleteBackupIfRecoverable $BaseKey $target $identity
    $backup = Get-ProjectionBackup $BaseKey $instanceId
    if ($null -ne $backup) {
        Invoke-ProjectionRollback $BaseKey
        return
    }
    if ($target.HardwareIds[0] -match $physicalPattern) {
        Assert-PhysicalHardwareIds $target.HardwareIds
        Write-Host 'PnP HardwareID 已是 stock 1AF4:1050；无需预恢复。' `
            -ForegroundColor Cyan
        return
    }
    [string[]]$originalIds = @(Get-OriginalIdsFromExistingProjection `
        -CurrentIds $target.HardwareIds `
        -VendorId ([int]$identity.SpoofPciVendorId) `
        -DeviceId ([int]$identity.SpoofPciDeviceId))
    if ($originalIds.Count -eq 0) {
        throw '没有正式备份，且当前 HardwareID 不是当前 profile 的精确投影'
    }
    Set-TargetHardwareIds $BaseKey $target $originalIds
    $verified = Get-TargetRegistryState $BaseKey $instanceId
    Assert-BindingUnchanged $target $verified
    if (-not (Test-StringArrayEqual $verified.HardwareIds $originalIds)) {
        throw '预恢复 stock HardwareID 后复核失败'
    }
    Write-Host 'PnP HardwareID 已预恢复为 stock 1AF4:1050；未触发 PnP 重扫。' `
        -ForegroundColor Green
}

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'PnP HardwareID 投影需要管理员权限'
}

# HardwareID 的读取、备份、唯一写入与回读必须和 CurrentIdentity 的 Stage/Commit/
# Recover 使用同一把全局锁。否则独立计划任务可能在身份 pointer CAS 的同时仍按旧
# snapshot 写 HardwareID，留下“新 CurrentIdentity + 旧首项”的跨 writer 混合状态。
# 同名 Windows mutex 也继续串行化多个 projector 实例，不再需要第二把专用锁。
$mutex = New-Object Threading.Mutex($false, 'Global\StealthGPU-IdentityWriter')
$lockTaken = $false
try {
    try {
        $lockTaken = $mutex.WaitOne(30000)
    } catch [Threading.AbandonedMutexException] {
        # 前一个进程异常退出时 Windows 会把互斥体所有权交给当前进程；事务状态机
        # 仍会复核 Pending/Applied，所以可以继续而不是永久锁死 guest。
        $lockTaken = $true
    }
    if (-not $lockTaken) { throw '等待 GPU 身份与 HardwareID 共享写锁超时' }

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    try {
        switch ($Mode) {
            'Apply' { Invoke-ProjectionApply $baseKey }
            'Verify' { Invoke-ProjectionVerify $baseKey }
            'RestorePhysical' { Invoke-RestorePhysical $baseKey }
            'Rollback' { Invoke-ProjectionRollback $baseKey }
        }
    } finally {
        $baseKey.Dispose()
    }
} finally {
    if ($lockTaken) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

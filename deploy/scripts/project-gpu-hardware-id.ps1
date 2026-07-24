#Requires -Version 5.1

<#
.SYNOPSIS
  事务化维护 GPU profile 逻辑首项与 stock VioGpuDod 物理尾项。

.DESCRIPTION
  QEMU PCI 配置空间、设备实例路径、Service、Driver 和 CompatibleIDs 始终保持
  真实 1AF4:1050。本脚本只把 Enum\PCI 的 HardwareID 排列为：

      profile 逻辑首项 + 完整原始物理数组

  脚本不调用 pnputil/devcon，不禁用或启用设备，不触发 PnP 扫描，不改 ACL。每个
  SourceInstanceId 使用独立事务备份；Apply 幂等，Rollback 只恢复本事务认识的值。
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
$transactionHelper = Join-Path $PSScriptRoot 'gpu-hardware-id-transaction.ps1'
$multiStringKind = [Microsoft.Win32.RegistryValueKind]::MultiString
$stringKind = [Microsoft.Win32.RegistryValueKind]::String
$dwordKind = [Microsoft.Win32.RegistryValueKind]::DWord

if (-not (Test-Path -LiteralPath $planHelper -PathType Leaf)) {
    throw ('缺少 HardwareID 规划 helper：' + $planHelper)
}
. $planHelper
if (-not (Test-Path -LiteralPath $transactionHelper -PathType Leaf)) {
    throw ('缺少 HardwareID 事务 helper：' + $transactionHelper)
}

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
    foreach ($name in 'IdentityId', 'SourceInstanceId', 'SpoofPciVendorId', 'SpoofPciDeviceId',
            'SpoofSubsystemVendorId', 'SpoofSubsystemDeviceId', 'SpoofRevisionId') {
        if ($null -eq $identity.PSObject.Properties[$name]) {
            throw ('严格身份缺少字段：' + $name)
        }
    }
    return $identity
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
        $rollback = [string[]]@()
        if (@($key.GetValueNames()) -ccontains 'RollbackHardwareIds') {
            $rollback = [string[]]@(Get-ExactRegistryValue $key `
                'RollbackHardwareIds' $multiStringKind)
        }
        $result = [pscustomobject]@{
            RelativePath = $relativePath
            InstanceId = [string](Get-ExactRegistryValue $key 'InstanceId' $stringKind)
            OriginalHardwareIds = [string[]]@(Get-ExactRegistryValue $key `
                'OriginalHardwareIds' $multiStringKind)
            AppliedHardwareIds = [string[]]@(Get-ExactRegistryValue $key `
                'AppliedHardwareIds' $multiStringKind)
            PendingHardwareIds = $pending
            RollbackHardwareIds = $rollback
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
        if ($result.RollbackHardwareIds.Count -gt 0) {
            Assert-HardwareIdArray $result.RollbackHardwareIds `
                'HardwareID durable rollback anchor'
        }
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
        $original = @(Get-OriginalIdsFromExistingProjection -CurrentIds $Target.HardwareIds -VendorId ([int]$Identity.SpoofPciVendorId) `
            -DeviceId ([int]$Identity.SpoofPciDeviceId) `
            -SubsystemVendorId ([int]$Identity.SpoofSubsystemVendorId) -SubsystemDeviceId ([int]$Identity.SpoofSubsystemDeviceId) -RevisionId ([int]$Identity.SpoofRevisionId))
        $recoverable = $original.Count -gt 0
    }
    if (-not $recoverable) { throw '存在 schema=0 半成品，但当前 HardwareID 无法安全重建' }
    $BaseKey.DeleteSubKeyTree($relativePath, $false)
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
    if ($Backup.PendingHardwareIds.Count -gt 0 -and
        (Test-StringArrayEqual $CurrentIds $Backup.PendingHardwareIds)) {
        return $true
    }
    return ($null -ne $Backup.PSObject.Properties['RollbackHardwareIds'] -and
        $Backup.RollbackHardwareIds.Count -gt 0 -and
        (Test-StringArrayEqual $CurrentIds $Backup.RollbackHardwareIds))
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
        -CurrentIds $target.HardwareIds -VendorId ([int]$identity.SpoofPciVendorId) `
        -DeviceId ([int]$identity.SpoofPciDeviceId) -SubsystemVendorId ([int]$identity.SpoofSubsystemVendorId) `
        -SubsystemDeviceId ([int]$identity.SpoofSubsystemDeviceId) -RevisionId ([int]$identity.SpoofRevisionId))
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

. $transactionHelper

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'PnP HardwareID 投影需要管理员权限'
}

# HardwareID 的读取、备份、唯一写入与回读必须和 CurrentIdentity 的 Stage/Commit/
# Recover 使用同一把全局锁。这样迁移旧投影时不会与身份 pointer CAS 交错，留下
# “新 CurrentIdentity + 旧首项”的跨 writer 混合状态；多个恢复实例也由同名 mutex
# 串行化。
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

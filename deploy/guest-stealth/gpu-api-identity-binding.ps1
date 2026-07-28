#Requires -Version 5.1

<#
.SYNOPSIS
  为 GPU API coordinator 读取并校验 identity durable transaction。

.DESCRIPTION
  本 helper 不写注册表。Install 只接受仍由 PendingIdentity 拥有的 schema-6
  Prepared 事务，并从不可变 identity snapshot 读取 canonical Vendor。收口只接受
  Completed/current 或 RolledBack/previous 两种终态，拒绝提前及跨事务恢复。
#>

function Get-GpuApiExactRegistryValue {
    param(
        [Parameter(Mandatory = $true)]$Key,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Microsoft.Win32.RegistryValueKind]$Kind
    )
    if (-not (@($Key.GetValueNames()) -ccontains $Name) -or
        $Key.GetValueKind($Name) -ne $Kind) {
        throw ('GPU identity 注册表值缺失或类型非法：' + $Name)
    }
    $value = $Key.GetValue($Name, $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($Kind -eq [Microsoft.Win32.RegistryValueKind]::String -and
        ([string]::IsNullOrWhiteSpace([string]$value) -or
         ([string]$value).IndexOf([char]0) -ge 0)) {
        throw ('GPU identity 注册表字符串为空或含 NUL：' + $Name)
    }
    return $value
}

function Get-GpuApiOptionalIdentityPointer {
    param($Key, [Parameter(Mandatory = $true)][string]$Name)
    if (-not (@($Key.GetValueNames()) -ccontains $Name)) {
        return [pscustomobject]@{ Present=$false; Value='' }
    }
    $value = [string](Get-GpuApiExactRegistryValue $Key $Name `
        ([Microsoft.Win32.RegistryValueKind]::String))
    Assert-GpuApiTransactionId $value
    return [pscustomobject]@{ Present=$true; Value=$value }
}

function Get-GpuApiIdentityDurableState {
    param([Parameter(Mandatory = $true)][string]$TransactionId)
    Assert-GpuApiTransactionId $TransactionId
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    $key = $transactionKey = $identityKey = $null
    try {
        $key = $baseKey.OpenSubKey('SOFTWARE\StealthGPU', $false)
        if ($null -eq $key) { throw 'GPU identity 根注册表不存在' }
        $current = Get-GpuApiOptionalIdentityPointer $key 'CurrentIdentity'
        $pending = Get-GpuApiOptionalIdentityPointer $key 'PendingIdentity'
        $transactionKey = $key.OpenSubKey(('Transactions\' + $TransactionId), $false)
        $identityKey = $key.OpenSubKey(('Identities\' + $TransactionId), $false)
        if ($null -eq $transactionKey -or $null -eq $identityKey) {
            throw ('GPU identity durable transaction/snapshot 不存在：' + $TransactionId)
        }
        $string = [Microsoft.Win32.RegistryValueKind]::String
        $dword = [Microsoft.Win32.RegistryValueKind]::DWord
        $recordedId = [string](Get-GpuApiExactRegistryValue `
            $transactionKey 'TransactionId' $string)
        $schema = [int](Get-GpuApiExactRegistryValue `
            $transactionKey 'TransactionSchemaVersion' $dword)
        $state = [string](Get-GpuApiExactRegistryValue $transactionKey 'State' $string)
        $previousPresent = [int](Get-GpuApiExactRegistryValue `
            $transactionKey 'PreviousPointerPresent' $dword)
        if ($recordedId -cne $TransactionId -or
            -not (@(1, 2, 3, 4, 5, 6) -contains $schema) -or
            @('Prepared', 'Committed', 'Completed', 'RolledBack') -cnotcontains $state -or
            ($previousPresent -ne 0 -and $previousPresent -ne 1)) {
            throw ('GPU identity durable transaction 字段非法：' + $TransactionId)
        }
        $previous = Get-GpuApiOptionalIdentityPointer `
            $transactionKey 'PreviousIdentityId'
        if ($previous.Present -ne [bool]$previousPresent) {
            throw 'GPU identity previous pointer presence 不一致'
        }
        $identitySchema = [int](Get-GpuApiExactRegistryValue `
            $identityKey 'IdentitySchemaVersion' $dword)
        $identityId = [string](Get-GpuApiExactRegistryValue `
            $identityKey 'IdentityId' $string)
        $vendor = [string](Get-GpuApiExactRegistryValue `
            $identityKey 'SpoofVendor' $string)
        if ($identitySchema -ne 2 -or $identityId -cne $TransactionId -or
            @('NVIDIA', 'AMD') -cnotcontains $vendor) {
            throw ('GPU staged identity schema/id/vendor 非法：' + $TransactionId)
        }
        return [pscustomobject]@{
            CurrentIdentity=$current; PendingIdentity=$pending; PreviousIdentity=$previous
            TransactionSchema=$schema; State=$state; Vendor=$vendor
        }
    } finally {
        if ($null -ne $identityKey) { $identityKey.Dispose() }
        if ($null -ne $transactionKey) { $transactionKey.Dispose() }
        if ($null -ne $key) { $key.Dispose() }
        $baseKey.Dispose()
    }
}

function Assert-GpuApiInstallIdentityBinding {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD')][string]$RequestedVendor
    )
    $identity = Get-GpuApiIdentityDurableState -TransactionId $TransactionId
    $baselineMatches = $identity.CurrentIdentity.Present -eq
        $identity.PreviousIdentity.Present -and
        (-not $identity.CurrentIdentity.Present -or
         $identity.CurrentIdentity.Value -ceq $identity.PreviousIdentity.Value)
    if ($identity.TransactionSchema -ne 6 -or $identity.State -cne 'Prepared' -or
        -not $identity.PendingIdentity.Present -or
        $identity.PendingIdentity.Value -cne $TransactionId -or -not $baselineMatches) {
        throw ('GPU API Install 只接受 pointer 未提交的 schema-6 Prepared identity：' +
            $TransactionId)
    }
    if ($identity.Vendor -cne $RequestedVendor) {
        throw ('GPU API 请求 Vendor 与 staged identity 不一致：' +
            $RequestedVendor + '/' + $identity.Vendor)
    }
    return $identity.Vendor
}

function Get-GpuApiIdentitySettlementAction {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD', 'LegacyBothPresent')][string]$ExpectedVendor
    )
    $identity = Get-GpuApiIdentityDurableState -TransactionId $TransactionId
    if ($ExpectedVendor -cne 'LegacyBothPresent' -and
        $identity.Vendor -cne $ExpectedVendor) {
        throw ('GPU API reservation Vendor 与 durable identity 不一致：' +
            $ExpectedVendor + '/' + $identity.Vendor)
    }
    if ($identity.State -ceq 'Completed') {
        if (-not $identity.CurrentIdentity.Present -or
            $identity.CurrentIdentity.Value -cne $TransactionId) {
            throw 'Completed GPU identity 的 CurrentIdentity 不一致'
        }
        return 'Finalize'
    }
    if ($identity.State -ceq 'RolledBack') {
        if ($identity.CurrentIdentity.Present -ne $identity.PreviousIdentity.Present -or
            ($identity.CurrentIdentity.Present -and
             $identity.CurrentIdentity.Value -cne $identity.PreviousIdentity.Value)) {
            throw 'RolledBack GPU identity 未精确恢复 previous pointer'
        }
        return 'Rollback'
    }
    throw ('GPU API 必须等待 identity terminal state，当前 State=' + $identity.State)
}

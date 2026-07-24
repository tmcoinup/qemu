#Requires -Version 5.1

<#
.SYNOPSIS
  GPU HardwareID 浅层投影的无副作用规划函数。

.DESCRIPTION
  本文件只校验、规划字符串数组，不访问 PnP、注册表或文件系统。生产 projector 与
  Linux 上的 PowerShell 纯函数测试共同加载它，避免测试复制一份容易漂移的算法。
#>

function Test-StringArrayEqual {
    # 注册表契约比较必须逐项、区分大小写；这样连非目标字段的大小写变化也不会漏报。
    param(
        [AllowEmptyCollection()][string[]]$Left,
        [AllowEmptyCollection()][string[]]$Right
    )

    if ($null -eq $Left -or $null -eq $Right -or $Left.Count -ne $Right.Count) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if (-not [string]::Equals($Left[$index], $Right[$index],
                [StringComparison]::Ordinal)) {
            return $false
        }
    }
    return $true
}

function Assert-HardwareIdArray {
    param(
        [Parameter(Mandatory = $true)][string[]]$Ids,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Ids.Count -eq 0) { throw ($Label + ' 为空') }
    foreach ($id in $Ids) {
        if ([string]::IsNullOrWhiteSpace($id) -or $id.IndexOf([char]0) -ge 0) {
            throw ($Label + ' 含空项或 NUL')
        }
    }
}

function Assert-PhysicalHardwareIds {
    # stock viogpudo 的 HardwareID 各层匹配项都应以同一物理 VEN/DEV 开头。
    # 尾部混入未知 ID 时不能只取“看起来像物理”的部分，否则会静默丢失绑定信息。
    param([Parameter(Mandatory = $true)][string[]]$Ids)

    $stockPattern = '^PCI\\VEN_1AF4&DEV_1050(?:&|$)'
    Assert-HardwareIdArray -Ids $Ids -Label '物理 HardwareID'
    foreach ($id in $Ids) {
        if ($id -notmatch $stockPattern) {
            throw ('物理 HardwareID 数组含未知项：' + $id)
        }
    }
}

function Get-ProjectedHardwareIds {
    # 只新增一个完整逻辑首项。AIB 的 SUBSYS 编码顺序是“子设备、子厂商”，不能
    # 沿用 carrier 的 A10x:1AF4；其余原数组逐项、逐序保留给 stock INF 绑定。
    param(
        [Parameter(Mandatory = $true)][string[]]$OriginalIds,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$VendorId,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$DeviceId,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$SubsystemVendorId,
        [Parameter(Mandatory = $true)][ValidateRange(0, 65535)][int]$SubsystemDeviceId,
        [Parameter(Mandatory = $true)][ValidateRange(0, 255)][int]$RevisionId
    )

    Assert-PhysicalHardwareIds -Ids $OriginalIds
    if ($VendorId -eq 0x1AF4 -and $DeviceId -eq 0x1050) {
        throw '逻辑 PCI ID 与物理 1AF4:1050 相同，拒绝无意义投影'
    }
    $logicalPrimary = 'PCI\VEN_{0:X4}&DEV_{1:X4}&SUBSYS_{2:X4}{3:X4}&REV_{4:X2}' -f `
        $VendorId, $DeviceId, $SubsystemDeviceId, $SubsystemVendorId, $RevisionId
    return [string[]](@($logicalPrimary) + @($OriginalIds))
}

function Get-OriginalIdsFromExistingProjection {
    # 优先接受 canonical 首项。兼容旧版只替换主 VEN/DEV 的 A101..A112 首项，
    # 让现有 VM 原地迁移；候选尾部仍须是完整物理数组，任意第三方布局均拒绝。
    param(
        [Parameter(Mandatory = $true)][string[]]$CurrentIds,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$VendorId,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$DeviceId,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$SubsystemVendorId,
        [Parameter(Mandatory = $true)][ValidateRange(0, 65535)][int]$SubsystemDeviceId,
        [Parameter(Mandatory = $true)][ValidateRange(0, 255)][int]$RevisionId
    )

    Assert-HardwareIdArray -Ids $CurrentIds -Label '当前 HardwareID'
    if ($CurrentIds.Count -lt 2) { return [string[]]@() }
    [string[]]$candidate = @($CurrentIds[1..($CurrentIds.Count - 1)])
    try {
        [string[]]$expected = @(Get-ProjectedHardwareIds -OriginalIds $candidate `
            -VendorId $VendorId -DeviceId $DeviceId `
            -SubsystemVendorId $SubsystemVendorId -SubsystemDeviceId $SubsystemDeviceId `
            -RevisionId $RevisionId)
        if (Test-StringArrayEqual $CurrentIds $expected) { return $candidate }

        $legacyCarrier = '^PCI\\VEN_1AF4&DEV_1050&SUBSYS_A1(?:0[1-9A-F]|1[0-2])1AF4' +
            '&REV_[0-9A-F]{2}$'
        if ($candidate[0] -notmatch $legacyCarrier) { return [string[]]@() }
        $legacyPrefix = 'PCI\VEN_{0:X4}&DEV_{1:X4}' -f $VendorId, $DeviceId
        $legacyPrimary = $candidate[0] -replace `
            '^PCI\\VEN_1AF4&DEV_1050(?=&|$)', $legacyPrefix
        [string[]]$legacyExpected = @($legacyPrimary) + @($candidate)
        if (Test-StringArrayEqual $CurrentIds $legacyExpected) { return $candidate }
    } catch {
        return [string[]]@()
    }
    return [string[]]@()
}

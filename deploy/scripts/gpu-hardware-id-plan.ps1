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
    # 现场验证只替换最具体的第一项。其余原数组逐项、逐序保留，既让 GPU-Z 的
    # 10DE 厂商门禁通过，也不给 Windows INF 匹配制造额外逻辑 ID。
    param(
        [Parameter(Mandatory = $true)][string[]]$OriginalIds,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$VendorId,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$DeviceId
    )

    # 替换必须使用零宽边界；若把分隔符 `&` 一并匹配，-replace 会生成
    # `DEV_1C82SUBSYS_...` 这种损坏的 HardwareID。
    $stockPattern = '^PCI\\VEN_1AF4&DEV_1050(?=&|$)'
    Assert-PhysicalHardwareIds -Ids $OriginalIds
    $logicalPrefix = 'PCI\VEN_{0:X4}&DEV_{1:X4}' -f $VendorId, $DeviceId
    $logicalPrimary = $OriginalIds[0] -replace $stockPattern, $logicalPrefix
    if ([string]::Equals($logicalPrimary, $OriginalIds[0],
            [StringComparison]::OrdinalIgnoreCase)) {
        throw '逻辑 PCI ID 与物理 1AF4:1050 相同，拒绝无意义投影'
    }
    return [string[]](@($logicalPrimary) + @($OriginalIds))
}

function Get-OriginalIdsFromExistingProjection {
    # 只接受“当前 profile 的逻辑第一项 + 完整物理后缀”。没有正式备份时，不把任意
    # 第三方 VEN/DEV 猜成历史 profile；VM2 的现场状态则能按这一精确规则安全接管。
    param(
        [Parameter(Mandatory = $true)][string[]]$CurrentIds,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$VendorId,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$DeviceId
    )

    Assert-HardwareIdArray -Ids $CurrentIds -Label '当前 HardwareID'
    if ($CurrentIds.Count -lt 2) { return [string[]]@() }
    [string[]]$candidate = @($CurrentIds[1..($CurrentIds.Count - 1)])
    try {
        [string[]]$expected = @(Get-ProjectedHardwareIds -OriginalIds $candidate `
            -VendorId $VendorId -DeviceId $DeviceId)
        if (Test-StringArrayEqual $CurrentIds $expected) { return $candidate }
    } catch {
        return [string[]]@()
    }
    return [string[]]@()
}

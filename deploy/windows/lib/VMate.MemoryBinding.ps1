#Requires -Version 5.1

<#
.SYNOPSIS
    把所选 DIMM 物料作为稳定 profile 绑定校验。

.DESCRIPTION
    同时约束目录字段与厂商来源，并对会投影到 SMBIOS/SPD 的选中条目做摘要。
    摘要不含目录修订或选择权重，因此追加品牌不改变已有 VM，而原位改写
    rank、位宽或料号会 fail closed。
#>

function Assert-VMateMemoryModuleCatalogPolicy {
    param(
        [object]$Module,
        [string[]]$ExpectedFields
    )

    $actualFields = @($Module.PSObject.Properties.Name | Sort-Object)
    if (($actualFields -join "`n") -cne
        (@($ExpectedFields | Sort-Object) -join "`n")) {
        throw "DIMM '$($Module.id)' 字段集合不完整或含未知字段。"
    }
    $allowedHosts = switch ([string]$Module.manufacturer) {
        'Samsung' { @('download.semiconductor.samsung.com') }
        'Kingston' { @('www.kingston.com') }
        'Crucial' { @('www.intel.com', 'uk.crucial.com', 'www.crucial.com') }
        'SK hynix' { @('product.skhynix.com') }
        default { @() }
    }
    $sources = @($Module.source_refs)
    if ($Module.source_refs -isnot [System.Array] -or
        $sources.Count -lt 1 -or
        @($sources | Select-Object -Unique).Count -ne $sources.Count) {
        throw "DIMM '$($Module.id)' 的来源必须是非空无重复数组。"
    }
    foreach ($source in $sources) {
        $uri = $null
        if ($source -isnot [string] -or
            -not [Uri]::TryCreate([string]$source, [UriKind]::Absolute,
                [ref]$uri) -or $uri.Scheme -cne 'https' -or
            $uri.DnsSafeHost.ToLowerInvariant() -notin $allowedHosts) {
            throw "DIMM '$($Module.id)' 含非对应厂商的来源：$source"
        }
    }
}

function Get-VMateMemoryPlanDigest {
    param([object]$Plan)

    $identity = [ordered]@{
        module_id = [string]$Plan.ModuleId
        family_id = [string]$Plan.FamilyId
        manufacturer = [string]$Plan.Manufacturer
        type = [string]$Plan.Type
        module_mib = [int]$Plan.ModuleMiB
        part_number = [string]$Plan.PartNumber
        rated_mts = [int]$Plan.RatedMts
        rank = [int]$Plan.Rank
        device_width_bits = [int]$Plan.DeviceWidthBits
        spd_ee1004 = [bool]$Plan.SpdEe1004
    }
    return Get-VMatePlatformDigest -Platform $identity
}

function Assert-VMateMemoryProfileBinding {
    param(
        [object]$Profile,
        [object]$Platform
    )

    $memoryV2 = Test-VMateComponentProperty `
        $Profile.components 'binding_version'
    $hasModuleId = Test-VMateJsonProperty `
        $Profile.identity 'memory_module_id'
    $hasModuleDigest = Test-VMateJsonProperty `
        $Profile.identity 'memory_module_digest'
    if (-not $memoryV2) {
        if ($hasModuleId -or $hasModuleDigest) {
            throw '旧版部件绑定不能携带未受组件摘要保护的 DIMM V2 字段。'
        }
        return
    }
    if (-not $hasModuleId -or -not $hasModuleDigest -or
        $Profile.identity.memory_module_digest -isnot [string] -or
        [string]$Profile.identity.memory_module_digest -notmatch
            '^[0-9a-f]{64}$') {
        throw 'V2 硬件 profile 缺少 DIMM 稳定 ID 或条目摘要。'
    }
    $memoryPlan = Get-VMateMemoryModulePlan -Platform $Platform `
        -MemoryMiB ([int]$Profile.configuration.memory_mib) `
        -ModuleId ([string]$Profile.identity.memory_module_id)
    if ([string]$Profile.identity.memory_module_digest -cne
        (Get-VMateMemoryPlanDigest $memoryPlan)) {
        throw 'DIMM 条目事实已变化；请审核后显式 reroll profile。'
    }
}

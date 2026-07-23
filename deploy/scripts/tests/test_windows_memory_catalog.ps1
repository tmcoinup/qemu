#Requires -Version 5.1

param([string]$RepoRoot = '')

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
}
. (Join-Path $RepoRoot 'deploy/windows/lib/VMate.Components.ps1')
. (Join-Path $RepoRoot 'deploy/windows/lib/VMate.Profile.ps1')

function Assert-MemoryTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-MemoryThrows {
    param([scriptblock]$Action, [string]$Message)
    try {
        & $Action
    } catch {
        return
    }
    throw $Message
}

function New-TestMemoryPlatform {
    param(
        [string]$Type,
        [string]$Socket,
        [int]$VoltageMv,
        [int]$MaxMts,
        [int[]]$AllowedMts,
        [int]$DimmSlots = 2
    )
    return [pscustomobject]@{
        id = "test-$($Type.ToLowerInvariant())-$($Socket.ToLowerInvariant())"
        cpu = [pscustomobject]@{
            socket = $Socket
            cores = 4
            threads = 4
        }
        board = [pscustomobject]@{
            dimm_slots = $DimmSlots
            max_memory_gib = 32
        }
        memory = [pscustomobject]@{
            type = $Type
            channels = 2
            max_mts = $MaxMts
            allowed_mts = $AllowedMts
            voltage_mv = $VoltageMv
            module_mib = @(2048, 4096)
            allowed_total_mib = @(2048, 4096, 8192)
        }
    }
}

$catalog = Get-VMateMemoryCatalog
Assert-MemoryTest ([int]$catalog.schema_version -eq 1) `
    'Windows 未加载共享 memory catalog schema 1。'
$active = @(Get-VMateMemoryPartCatalog)
$quarantine = @(Get-VMateMemoryPartCatalog -IncludeQuarantine |
    Where-Object { $_.status -eq 'quarantine' })
Assert-MemoryTest ($active.Count -eq 11 -and $quarantine.Count -eq 4) `
    'Windows active/quarantine DIMM 数量错误。'
Assert-MemoryTest `
    ((@($active.manufacturer | Sort-Object -Unique) -join ',') -eq
        'Crucial,Kingston,Samsung,SK hynix') `
    'Windows 活动目录没有覆盖四个品牌。'
$moduleFields = @($active[0].PSObject.Properties.Name)
$badSource = $active[0] | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$badSource.source_refs = @('https://example.invalid/fake-dimm')
Assert-MemoryThrows {
    Assert-VMateMemoryModuleCatalogPolicy $badSource $moduleFields
} 'Windows DIMM 目录接受了非对应厂商的证据来源。'
$extraField = $active[0] | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$extraField | Add-Member -NotePropertyName typo -NotePropertyValue $true
Assert-MemoryThrows {
    Assert-VMateMemoryModuleCatalogPolicy $extraField $moduleFields
} 'Windows DIMM 目录接受了未知字段。'

$ddr4 = New-TestMemoryPlatform -Type DDR4 -Socket LGA1151 `
    -VoltageMv 1200 -MaxMts 2400 -AllowedMts @(2133, 2400)
$ddr4Plans = @(Get-VMateMemoryModulePlans -Platform $ddr4 -MemoryMiB 8192)
Assert-MemoryTest ($ddr4Plans.Count -eq 3) `
    'LGA1151 DDR4 没有得到三个活动品牌系列。'
$ddr4TwoGib = @(Get-VMateMemoryModulePlans -Platform $ddr4 -MemoryMiB 2048)
Assert-MemoryTest ($ddr4TwoGib.Count -eq 2 -and
    @($ddr4TwoGib.Manufacturer) -notcontains 'Kingston') `
    '2GiB 计划错误使用了仅有官方 4GB SKU 的 Kingston 系列。'
Assert-MemoryTest `
    ((@($ddr4Plans.Manufacturer | Sort-Object) -join ',') -eq
        'Crucial,Kingston,Samsung') `
    'LGA1151 DDR4 候选品牌集合错误。'
Assert-MemoryTest `
    ((@($ddr4Plans.SelectionWeight) -join ',') -eq '50,30,20') `
    '常用 DDR4 品牌的加权优先级错误。'
foreach ($plan in $ddr4Plans) {
    Assert-MemoryTest `
        ($plan.Type -eq 'DDR4' -and $plan.ModuleMiB -eq 4096 -and
         $plan.ModuleCount -eq 2 -and $plan.ConfiguredMts -eq 2400 -and
         $plan.SpdEe1004) `
        "DDR4 计划 '$($plan.ModuleId)' 的拓扑或 SPD 字段错误。"
}

# 用可控 ticket 覆盖三个权重区间；生产环境同名函数来自 VMate.Profile.ps1，
# 使用拒绝采样 CSPRNG，目录权重只决定区间大小。
function Get-VMateSecureIndex {
    param([int]$Count)
    Assert-MemoryTest ($script:memoryTicket -lt $Count) '测试 ticket 越界。'
    return $script:memoryTicket
}
$script:memoryTicket = 0
Assert-MemoryTest `
    ((Select-VMateMemoryModulePlan $ddr4Plans).Manufacturer -eq 'Samsung') `
    'Samsung 权重区间起点错误。'
$script:memoryTicket = 50
Assert-MemoryTest `
    ((Select-VMateMemoryModulePlan $ddr4Plans).Manufacturer -eq 'Kingston') `
    'Kingston 权重区间起点错误。'
$script:memoryTicket = 80
Assert-MemoryTest `
    ((Select-VMateMemoryModulePlan $ddr4Plans).Manufacturer -eq 'Crucial') `
    'Crucial 权重区间起点错误。'

$genericQ35 = $ddr4 | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$genericQ35.cpu.PSObject.Properties.Remove('socket')
$genericQ35 | Add-Member -NotePropertyName identity_scope `
    -NotePropertyValue 'generic_q35_host_passthrough_compatibility'
Assert-MemoryTest `
    (@(Get-VMateMemoryModulePlans -Platform $genericQ35 `
            -MemoryMiB 8192).Count -eq 3) `
    '通用 Q35 模板不能在不冒充物理 socket 时选择 DDR4。'

$illegalDdr3 = New-TestMemoryPlatform -Type DDR3 -Socket LGA1151 `
    -VoltageMv 1500 -MaxMts 1600 -AllowedMts @(1333, 1600)
Assert-MemoryTest `
    (@(Get-VMateMemoryModulePlans -Platform $illegalDdr3 `
            -MemoryMiB 8192).Count -eq 0) `
    '1.5V DDR3 跨代泄漏到 LGA1151 DDR4 平台。'

$ddr3 = New-TestMemoryPlatform -Type DDR3 -Socket LGA1155 `
    -VoltageMv 1500 -MaxMts 1600 -AllowedMts @(1333, 1600) -DimmSlots 4
$ddr3Plans = @(Get-VMateMemoryModulePlans -Platform $ddr3 -MemoryMiB 8192)
Assert-MemoryTest ($ddr3Plans.Count -eq 3) `
    'LGA1155 DDR3 没有得到三个活动系列。'
Assert-MemoryTest (@($ddr3Plans | Where-Object {
            $_.Type -ne 'DDR3' -or $_.SpdEe1004
        }).Count -eq 0) `
    'DDR3 计划混入 DDR4 或错误启用 EE1004。'

# 新 profile 持久化稳定 module ID；旧 schema-1 profile 没有这个新增字段时，
# 仍可由品牌+料号无歧义解析，避免升级后强制改变既有 VM 的内存身份。
$selected = $ddr4Plans[1]
$profile = [pscustomobject]@{
    components = [pscustomobject]@{ binding_version = 2 }
    configuration = [pscustomobject]@{
        memory_mib = 8192
        memory_configured_mts = $selected.ConfiguredMts
        memory_module_mib = $selected.ModuleMiB
        memory_module_count = $selected.ModuleCount
    }
    identity = [pscustomobject]@{
        memory_module_id = $selected.ModuleId
        memory_module_digest = Get-VMateMemoryPlanDigest $selected
        memory_manufacturer = $selected.Manufacturer
        memory_part = $selected.PartNumber
        memory_rated_mts = $selected.RatedMts
    }
}
Assert-VMateMemoryRateFacts -Profile $profile -Platform $ddr4
Assert-VMateMemoryProfileBinding -Profile $profile -Platform $ddr4
$badDigest = $profile | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$badDigest.identity.memory_module_digest = '0' * 64
Assert-MemoryThrows {
    Assert-VMateMemoryProfileBinding -Profile $badDigest -Platform $ddr4
} 'DIMM 条目摘要篡改通过了 Windows profile 绑定校验。'
$legacy = $profile | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$legacy.components.PSObject.Properties.Remove('binding_version')
$legacy.identity.PSObject.Properties.Remove('memory_module_id')
$legacy.identity.PSObject.Properties.Remove('memory_module_digest')
Assert-VMateMemoryRateFacts -Profile $legacy -Platform $ddr4
Assert-VMateMemoryProfileBinding -Profile $legacy -Platform $ddr4

$badBrand = $profile | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$badBrand.identity.memory_manufacturer = 'Samsung'
Assert-MemoryThrows {
    Assert-VMateMemoryRateFacts -Profile $badBrand -Platform $ddr4
} '跨品牌 module ID/料号组合通过了 Windows 严格校验。'

$badType = $ddr4 | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$badType.memory.type = 'DDR3'
$badType.memory.voltage_mv = 1500
$badType.memory.allowed_mts = @(1333, 1600)
$badType.memory.max_mts = 1600
Assert-MemoryThrows {
    [void](Get-VMateMemoryRateFacts -Platform $badType `
        -PartNumber $selected.PartNumber -Manufacturer $selected.Manufacturer `
        -ModuleId $selected.ModuleId)
} 'DDR4 料号在平台改成 DDR3 后仍被接受。'

Write-Output 'PASS: Windows shared multi-brand memory catalog'

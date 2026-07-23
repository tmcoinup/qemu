#Requires -Version 5.1

. (Join-Path $PSScriptRoot 'VMate.MemoryBinding.ps1')

<#
.SYNOPSIS
    从共享 memory.json 选择并验证 Windows DIMM 身份。

.DESCRIPTION
    目录同时服务 Linux/Windows。平台的 DDR 代际、socket、通道、供电、
    DIMM 容量、槽位和训练速率均参与候选过滤；quarantine 条目只保留审计
    记录，绝不会进入新 profile 或严格 profile。
#>

function Get-VMateMemoryCatalogPath {
    return [IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '..\..\hardware\memory.json'))
}

function Test-VMateMemoryProperty {
    param([object]$Value, [string]$Name)
    return $null -ne $Value -and
        $null -ne $Value.PSObject.Properties[$Name]
}

function Test-VMateMemoryInteger {
    param([object]$Value)
    return $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
}

function Assert-VMateMemoryInteger {
    param([object]$Value, [string]$Where, [int64]$Minimum = 1)
    if (-not (Test-VMateMemoryInteger $Value) -or
        [int64]$Value -lt $Minimum) {
        throw "$Where 必须是大于等于 $Minimum 的 JSON 整数。"
    }
}

function Get-VMateMemoryJep106Text {
    param([object]$Value, [string]$Where, [bool]$AllowNull = $false)
    if ($null -eq $Value -and $AllowNull) {
        return ''
    }
    $bytes = @($Value)
    if ($bytes.Count -ne 2 -or @($bytes | Where-Object {
                $_ -isnot [string] -or [string]$_ -notmatch '^0x[0-9A-F]{2}$'
            }).Count -ne 0) {
        throw "$Where 必须是两个大写十六进制 JEP106 字节。"
    }
    return $bytes -join ','
}

function Get-VMateMemoryCatalog {
    param([string]$Path = (Get-VMateMemoryCatalogPath))

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "共享内存目录不存在：$Path"
    }
    try {
        $catalog = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "共享内存目录不是有效 JSON：$Path；$($_.Exception.Message)"
    }
    foreach ($field in @('schema_version', 'catalog_revision', 'serial_policy',
            'manufacturers', 'modules')) {
        if (-not (Test-VMateMemoryProperty $catalog $field)) {
            throw "共享内存目录缺少字段 '$field'。"
        }
    }
    if (-not (Test-VMateMemoryInteger $catalog.schema_version) -or
        [int]$catalog.schema_version -ne 1 -or
        $catalog.catalog_revision -isnot [string] -or
        [string]$catalog.catalog_revision -notmatch
            '^\d{4}-\d{2}-\d{2}-memory-r[1-9][0-9]*$') {
        throw '共享内存目录 schema 或 catalog_revision 无效。'
    }
    $serial = $catalog.serial_policy
    if ([string]$serial.id -ne 'jedec-spd-module-serial-u32' -or
        -not (Test-VMateMemoryInteger $serial.field_bytes) -or
        [int]$serial.field_bytes -ne 4 -or
        [string]$serial.text_encoding -ne 'uppercase_hex_big_endian' -or
        [string]$serial.pattern -ne '^[0-9A-F]{8}$' -or
        [string]$serial.identity_fidelity -ne
            'synthetic_value_in_real_jedec_spd_field' -or
        (@($serial.reserved_values) -join ',') -ne
            '00000000,00000001,FFFFFFFF') {
        throw '共享内存目录的 SPD 序列号策略无效。'
    }

    # 中文注释：这些编码与 hw/i2c/smbus_eeprom_spd.c 同源。Kingston 模组
    # 可跨批次使用不同 DRAM 颗粒，因此只固定模组厂商码，不伪造 DRAM 厂商码。
    $expectedJep106 = [ordered]@{
        'Samsung' = @('0x80,0xCE', '0x80,0xCE')
        'Kingston' = @('0x01,0x98', '')
        'Crucial' = @('0x85,0x9B', '0x80,0x2C')
        'SK hynix' = @('0x80,0xAD', '0x80,0xAD')
    }
    $manufacturerNames = @($catalog.manufacturers.PSObject.Properties.Name)
    $actualManufacturerText =
        (@($manufacturerNames | Sort-Object) -join ',')
    $expectedManufacturerText =
        (@($expectedJep106.Keys | Sort-Object) -join ',')
    if ($actualManufacturerText -ne $expectedManufacturerText) {
        throw '共享内存目录必须恰好覆盖四个已实现 SPD 品牌。'
    }
    foreach ($name in $expectedJep106.Keys) {
        $manufacturer = $catalog.manufacturers.$name
        $moduleCode = Get-VMateMemoryJep106Text `
            -Value $manufacturer.module_jep106 `
            -Where "manufacturers.$name.module_jep106"
        $dramCode = Get-VMateMemoryJep106Text `
            -Value $manufacturer.dram_jep106 `
            -Where "manufacturers.$name.dram_jep106" -AllowNull $true
        if ($moduleCode -ne $expectedJep106[$name][0] -or
            $dramCode -ne $expectedJep106[$name][1]) {
            throw "品牌 '$name' 的 JEP106 编码与 C 层不一致。"
        }
    }

    $modules = @($catalog.modules)
    if ($modules.Count -lt 1) {
        throw '共享内存目录 modules 不能为空。'
    }
    $ids = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $parts = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $requiredModuleFields = @(
        'id', 'family_id', 'status', 'selection_weight', 'manufacturer',
        'part_number', 'type', 'module_mib', 'rated_mts', 'voltage_mv',
        'rank', 'device_width_bits', 'spd_ee1004', 'allowed_sockets',
        'allowed_platform_channel_counts', 'source_refs')
    foreach ($module in $modules) {
        foreach ($field in $requiredModuleFields) {
            if (-not (Test-VMateMemoryProperty $module $field)) {
                throw "DIMM 条目缺少字段 '$field'。"
            }
        }
        Assert-VMateMemoryModuleCatalogPolicy $module $requiredModuleFields
        if ($module.id -isnot [string] -or
            [string]$module.id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or
            -not $ids.Add([string]$module.id) -or
            $module.family_id -isnot [string] -or
            [string]$module.family_id -notmatch
                '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or
            [string]$module.status -notin @('active', 'quarantine') -or
            [string]$module.manufacturer -notin @($expectedJep106.Keys) -or
            $module.part_number -isnot [string] -or
            -not ([string]$module.part_number).Trim() -or
            -not $parts.Add([string]$module.part_number)) {
            throw 'DIMM 的稳定 ID、状态、品牌或料号无效/重复。'
        }
        Assert-VMateMemoryInteger $module.selection_weight `
            'DIMM.selection_weight' 0
        foreach ($field in @('module_mib', 'rated_mts', 'voltage_mv', 'rank',
                'device_width_bits')) {
            Assert-VMateMemoryInteger $module.$field "DIMM.$field"
        }
        if (([string]$module.status -eq 'active' -and
                [int]$module.selection_weight -eq 0) -or
            ([string]$module.status -eq 'quarantine' -and
                [int]$module.selection_weight -ne 0)) {
            throw "DIMM '$($module.id)' 的选择权重与状态不一致。"
        }
        $type = [string]$module.type
        $rate = [int]$module.rated_mts
        $voltage = [int]$module.voltage_mv
        if ($type -notin @('DDR3', 'DDR4') -or
            [int]$module.module_mib -notin @(2048, 4096) -or
            [int]$module.rank -notin @(1, 2, 3, 4) -or
            [int]$module.device_width_bits -notin @(4, 8, 16) -or
            ($type -eq 'DDR4' -and
                ($rate -lt 2133 -or $voltage -ne 1200 -or
                    $module.spd_ee1004 -ne $true)) -or
            ($type -eq 'DDR3' -and
                ($rate -gt 2133 -or $voltage -ne 1500 -or
                    $module.spd_ee1004 -ne $false))) {
            throw "DIMM '$($module.id)' 的代际、容量、速率、供电或 SPD 几何无效。"
        }
        $sockets = @($module.allowed_sockets)
        $channels = @($module.allowed_platform_channel_counts)
        if ($sockets.Count -lt 1 -or $channels.Count -lt 1 -or
            @($channels | Where-Object { [int]$_ -notin @(1, 2, 4) }).Count -gt 0 -or
            ($type -eq 'DDR4' -and
                @($sockets | Where-Object {
                    $_ -in @('AM3', 'AM3+', 'FM2+', 'LGA1150', 'LGA1155')
                }).Count -gt 0) -or
            ($type -eq 'DDR3' -and
                @($sockets | Where-Object {
                    $_ -in @('AM4', 'LGA1151', 'LGA1200')
                }).Count -gt 0)) {
            throw "DIMM '$($module.id)' 的 socket/通道约束无效。"
        }
    }

    foreach ($family in @($modules | Group-Object family_id)) {
        $familyModules = @($family.Group)
        $uniqueSizes = @($familyModules.module_mib | Sort-Object -Unique)
        if ($familyModules.Count -gt 2 -or
            $uniqueSizes.Count -ne $familyModules.Count) {
            throw "DIMM family '$($family.Name)' 包含重复容量。"
        }
        $first = $familyModules[0]
        foreach ($module in $familyModules[1..($familyModules.Count - 1)]) {
            foreach ($field in @('status', 'selection_weight', 'manufacturer',
                    'type', 'rated_mts', 'voltage_mv', 'spd_ee1004')) {
                if ($module.$field -ne $first.$field) {
                    throw "DIMM family '$($family.Name)' 的 $field 不一致。"
                }
            }
        }
    }
    return $catalog
}

function Get-VMateMemoryPartCatalog {
    param([switch]$IncludeQuarantine)
    $catalog = Get-VMateMemoryCatalog
    return @($catalog.modules | Where-Object {
            $IncludeQuarantine -or [string]$_.status -eq 'active'
        } | Sort-Object @{Expression = 'selection_weight'; Descending = $true},
            family_id, module_mib)
}

function Get-VMateMemoryPlatformSocket {
    param([object]$Platform)
    $socket = [string]$Platform.cpu.socket
    if (-not $socket -and
        (Test-VMateMemoryProperty $Platform 'identity_scope') -and
        [string]$Platform.identity_scope -eq
            'generic_q35_host_passthrough_compatibility') {
        return '*'
    }
    return $socket
}

function Get-VMateMemoryModulePlans {
    param([object]$Platform, [int]$MemoryMiB)

    $type = [string]$Platform.memory.type
    $socket = Get-VMateMemoryPlatformSocket $Platform
    $channels = [int]$Platform.memory.channels
    $voltage = [int]$Platform.memory.voltage_mv
    $slots = [int]$Platform.board.dimm_slots
    $maxMts = [int]$Platform.memory.max_mts
    if ($type -notin @('DDR3', 'DDR4') -or -not $socket -or
        $channels -lt 1 -or $slots -lt 1 -or $MemoryMiB -lt 1) {
        throw "平台 '$($Platform.id)' 的 DIMM 约束不完整。"
    }
    $allowedTotals = @($Platform.memory.allowed_total_mib |
        ForEach-Object { [int]$_ })
    $moduleSizes = @($Platform.memory.module_mib | ForEach-Object { [int]$_ })
    $allowedRates = @($Platform.memory.allowed_mts |
        ForEach-Object { [int]$_ })
    if ($allowedTotals -notcontains $MemoryMiB) {
        return @()
    }
    $catalog = Get-VMateMemoryCatalog
    $plans = [Collections.Generic.List[object]]::new()
    foreach ($family in @($catalog.modules | Where-Object {
                [string]$_.status -eq 'active'
            } | Group-Object family_id)) {
        $modules = @($family.Group | Sort-Object module_mib -Descending)
        $first = $modules[0]
        if ([string]$first.type -ne $type -or
            [int]$first.voltage_mv -ne $voltage -or
            ($socket -ne '*' -and
                @($first.allowed_sockets) -notcontains $socket) -or
            @($first.allowed_platform_channel_counts) -notcontains $channels) {
            continue
        }
        $selected = @($modules | Where-Object {
                $moduleSizes -contains [int]$_.module_mib -and
                $MemoryMiB % [int]$_.module_mib -eq 0 -and
                [int]($MemoryMiB / [int]$_.module_mib) -le $slots
            } | Select-Object -First 1)
        $compatible = @($allowedRates | Where-Object {
                $_ -le [int]$first.rated_mts -and $_ -le $maxMts
            })
        if ($selected.Count -ne 1 -or $compatible.Count -eq 0) {
            continue
        }
        $module = $selected[0]
        $plans.Add([pscustomobject]@{
                CatalogRevision = [string]$catalog.catalog_revision
                ModuleId = [string]$module.id
                FamilyId = [string]$module.family_id
                SelectionWeight = [int]$module.selection_weight
                Manufacturer = [string]$module.manufacturer
                Type = [string]$module.type
                ModuleMiB = [int]$module.module_mib
                ModuleCount = [int]($MemoryMiB / [int]$module.module_mib)
                PartNumber = [string]$module.part_number
                RatedMts = [int]$module.rated_mts
                ConfiguredMts = [int](($compatible |
                            Measure-Object -Maximum).Maximum)
                Rank = [int]$module.rank
                DeviceWidthBits = [int]$module.device_width_bits
                SpdEe1004 = [bool]$module.spd_ee1004
            })
    }
    return @($plans | Sort-Object `
            @{Expression = 'SelectionWeight'; Descending = $true}, FamilyId)
}

function Select-VMateMemoryModulePlan {
    param([object[]]$Plans)

    $plansArray = @($Plans)
    $totalWeight = [int64](($plansArray.SelectionWeight |
                Measure-Object -Sum).Sum)
    if ($plansArray.Count -lt 1 -or $totalWeight -lt 1 -or
        $totalWeight -gt [int]::MaxValue) {
        throw 'DIMM 加权选择没有合法候选或总权重越界。'
    }
    $ticket = Get-VMateSecureIndex -Count ([int]$totalWeight)
    foreach ($plan in $plansArray) {
        if ($ticket -lt [int]$plan.SelectionWeight) {
            return $plan
        }
        $ticket -= [int]$plan.SelectionWeight
    }
    throw 'DIMM 加权选择内部状态无效。'
}

function Get-VMateMemoryModulePlan {
    param(
        [object]$Platform,
        [int]$MemoryMiB,
        [string]$ModuleId = '',
        [string]$Manufacturer = '',
        [string]$PartNumber = ''
    )
    $plans = @(Get-VMateMemoryModulePlans -Platform $Platform `
            -MemoryMiB $MemoryMiB)
    if ($ModuleId) {
        $plans = @($plans | Where-Object { $_.ModuleId -ceq $ModuleId })
    } elseif ($Manufacturer -or $PartNumber) {
        $plans = @($plans | Where-Object {
                (-not $Manufacturer -or $_.Manufacturer -eq $Manufacturer) -and
                (-not $PartNumber -or $_.PartNumber -eq $PartNumber)
            })
    } else {
        $plans = @($plans | Select-Object -First 1)
    }
    if ($plans.Count -ne 1) {
        throw "MemoryMiB=$MemoryMiB 无法唯一解析到合法 DIMM 物料。"
    }
    return $plans[0]
}

function New-VMateMemorySerial {
    # JEDEC SPD 序列号字段固定为四字节；文本 profile 使用八位大写十六进制。
    do {
        $value = New-VMateRandomHex -Bytes 4
    } while ($value -in @('00000000', '00000001', 'FFFFFFFF'))
    return $value
}

function Get-VMateMemoryRateFacts {
    param(
        [object]$Platform,
        [string]$PartNumber,
        [string]$Manufacturer = '',
        [string]$ModuleId = ''
    )
    $catalog = Get-VMateMemoryCatalog
    $socket = Get-VMateMemoryPlatformSocket $Platform
    $matches = @($catalog.modules | Where-Object {
            [string]$_.status -eq 'active' -and
            [string]$_.type -eq [string]$Platform.memory.type -and
            [string]$_.part_number -eq $PartNumber -and
            (-not $Manufacturer -or [string]$_.manufacturer -eq $Manufacturer) -and
            (-not $ModuleId -or [string]$_.id -eq $ModuleId) -and
            (($socket -eq '*') -or
                @($_.allowed_sockets) -contains $socket) -and
            @($_.allowed_platform_channel_counts) -contains
                [int]$Platform.memory.channels -and
            [int]$_.voltage_mv -eq [int]$Platform.memory.voltage_mv -and
            @($Platform.memory.module_mib | ForEach-Object { [int]$_ }) -contains
                [int]$_.module_mib
        })
    if ($matches.Count -ne 1) {
        throw "未审计或与平台不匹配的 Windows DIMM 料号：$PartNumber"
    }
    $module = $matches[0]
    $compatible = @($Platform.memory.allowed_mts |
        ForEach-Object { [int]$_ } | Where-Object {
            $_ -le [int]$module.rated_mts -and
            $_ -le [int]$Platform.memory.max_mts
        })
    if ($compatible.Count -eq 0) {
        throw "平台 '$($Platform.id)' 没有与 $($module.type)-$($module.rated_mts) 兼容的速率。"
    }
    return [pscustomobject]@{
        ModuleId = [string]$module.id
        Manufacturer = [string]$module.manufacturer
        RatedMts = [int]$module.rated_mts
        ConfiguredMts = [int](($compatible | Measure-Object -Maximum).Maximum)
        ModuleMiB = [int]$module.module_mib
        Rank = [int]$module.rank
        DeviceWidthBits = [int]$module.device_width_bits
        SpdEe1004 = [bool]$module.spd_ee1004
    }
}

function Assert-VMateMemoryRateFacts {
    param([object]$Profile, [object]$Platform)

    if ($Profile.identity.memory_manufacturer -isnot [string] -or
        $Profile.identity.memory_part -isnot [string]) {
        throw 'Windows DIMM 制造商或料号类型无效。'
    }
    foreach ($value in @($Profile.identity.memory_rated_mts,
            $Profile.configuration.memory_configured_mts,
            $Profile.configuration.memory_module_mib,
            $Profile.configuration.memory_module_count)) {
        if (-not (Test-VMateIntegerValue $value)) {
            throw 'Windows DIMM 容量、数量或速率必须是 JSON 整数。'
        }
    }
    $moduleId = if (Test-VMateMemoryProperty `
            $Profile.identity 'memory_module_id') {
        [string]$Profile.identity.memory_module_id
    } else {
        ''
    }
    $facts = Get-VMateMemoryRateFacts -Platform $Platform `
        -PartNumber ([string]$Profile.identity.memory_part) `
        -Manufacturer ([string]$Profile.identity.memory_manufacturer) `
        -ModuleId $moduleId
    $planArguments = @{
        Platform = $Platform
        MemoryMiB = [int]$Profile.configuration.memory_mib
        Manufacturer = [string]$Profile.identity.memory_manufacturer
        PartNumber = [string]$Profile.identity.memory_part
    }
    if ($moduleId) {
        $planArguments.ModuleId = $moduleId
    }
    $plan = Get-VMateMemoryModulePlan @planArguments
    if ([int]$Profile.identity.memory_rated_mts -ne $facts.RatedMts -or
        [int]$Profile.configuration.memory_configured_mts -ne
            $facts.ConfiguredMts -or
        $facts.DeviceWidthBits -notin @(4, 8, 16) -or
        ($Platform.memory.type -eq 'DDR4' -and -not $facts.SpdEe1004) -or
        ($Platform.memory.type -eq 'DDR3' -and $facts.SpdEe1004) -or
        [int]$Profile.configuration.memory_module_mib -ne $plan.ModuleMiB -or
        [int]$Profile.configuration.memory_module_count -ne $plan.ModuleCount -or
        [string]$Profile.identity.memory_part -ne $plan.PartNumber -or
        [string]$Profile.identity.memory_manufacturer -ne $plan.Manufacturer -or
        ($moduleId -and $moduleId -ne $plan.ModuleId)) {
        throw '内存品牌、料号、SPD 几何或平台配置速率不一致；请显式 reroll profile。'
    }
}

function Assert-VMateRequestedTopology {
    param(
        [object]$Platform,
        [object]$HostCpu,
        [int]$MemoryMiB,
        [int]$Cpus
    )
    $allowedMemory = @($Platform.memory.allowed_total_mib |
        ForEach-Object { [int]$_ })
    if ($allowedMemory -notcontains $MemoryMiB) {
        throw "MemoryMiB=$MemoryMiB 不在平台允许组合中：$($allowedMemory -join ',')。"
    }
    $maximumMemoryMiB = [int64]$Platform.board.max_memory_gib * 1024
    if ([int64]$MemoryMiB -gt $maximumMemoryMiB) {
        throw "内存 ${MemoryMiB}MiB 超过平台上限 ${maximumMemoryMiB}MiB。"
    }
    if (@(Get-VMateMemoryModulePlans -Platform $Platform `
                -MemoryMiB $MemoryMiB).Count -lt 1) {
        throw "MemoryMiB=$MemoryMiB 没有符合平台代际/插槽/速率约束的 DIMM。"
    }
    $platformTopology = "$([int]$Platform.cpu.cores)C$([int]$Platform.cpu.threads)T"
    if ($platformTopology -notin @('2C2T', '2C4T', '4C4T')) {
        throw "平台 CPU 拓扑只允许 2C2T、2C4T 或 4C4T；当前 $platformTopology。"
    }
    if ($Cpus -ne [int]$Platform.cpu.threads) {
        throw "vCPU=$Cpus 与平台 $($Platform.id) 的完整线程数 $($Platform.cpu.threads) 不一致。"
    }
    if ($Cpus -gt [int]$HostCpu.logical_processors) {
        throw "vCPU=$Cpus 超过宿主可用逻辑处理器上限。"
    }
}

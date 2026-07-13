#Requires -Version 5.1

<#
.SYNOPSIS
    统一计算和验证 Windows 硬件 profile 的 DIMM 额定/配置速率。
#>

function Get-VMateMemoryPartCatalog {
    # 当前只允许可追溯的 Samsung DDR4-2400 UDIMM。容量、料号与额定速率
    # 是同一条物料事实，不能仅凭总内存大小临时猜测料号。
    return @(
        [pscustomobject]@{
            Type = 'DDR4'; ModuleMiB = 2048
            PartNumber = 'M378A5644EB0-CRC'; RatedMts = 2400
        },
        [pscustomobject]@{
            Type = 'DDR4'; ModuleMiB = 4096
            PartNumber = 'M378A5244CB0-CRC'; RatedMts = 2400
        }
    )
}

function Get-VMateMemoryModulePlan {
    param(
        [object]$Platform,
        [int]$MemoryMiB
    )

    if ([string]$Platform.memory.type -ne 'DDR4') {
        throw "Windows DIMM 物料池不支持内存类型：$($Platform.memory.type)"
    }
    $catalog = @(Get-VMateMemoryPartCatalog)
    $platformSizes = @($Platform.memory.module_mib | ForEach-Object { [int]$_ })
    foreach ($size in $platformSizes) {
        if (@($catalog | Where-Object { $_.ModuleMiB -eq $size }).Count -ne 1) {
            throw "平台 '$($Platform.id)' 包含未审计的 Windows DIMM 容量：${size}MiB。"
        }
    }

    # 优先使用容量最大的同型号 DIMM，得到唯一且可复现的物料/插槽方案。
    # 通道数约束由 manifest 校验负责；单条内存仍是合法的单通道降级拓扑。
    foreach ($part in @($catalog | Sort-Object ModuleMiB -Descending)) {
        if ($platformSizes -notcontains [int]$part.ModuleMiB -or
            $MemoryMiB % [int]$part.ModuleMiB -ne 0) {
            continue
        }
        $count = [int]($MemoryMiB / [int]$part.ModuleMiB)
        if ($count -ge 1 -and $count -le [int]$Platform.board.dimm_slots) {
            return [pscustomobject]@{
                Type = [string]$part.Type
                ModuleMiB = [int]$part.ModuleMiB
                ModuleCount = $count
                PartNumber = [string]$part.PartNumber
                RatedMts = [int]$part.RatedMts
            }
        }
    }
    throw "MemoryMiB=$MemoryMiB 无法由平台 DIMM 物料与槽位组成。"
}

function Get-VMateMemoryRateFacts {
    param(
        [object]$Platform,
        [string]$PartNumber
    )

    $matches = @(Get-VMateMemoryPartCatalog | Where-Object {
        $_.PartNumber -eq $PartNumber -and $_.Type -eq [string]$Platform.memory.type
    })
    if ($matches.Count -ne 1 -or
        @($Platform.memory.module_mib | ForEach-Object { [int]$_ }) -notcontains
            [int]$matches[0].ModuleMiB) {
        throw "未审计或与平台不匹配的 Windows DIMM 料号：$PartNumber"
    }
    $ratedMts = [int]$matches[0].RatedMts
    $compatible = @($Platform.memory.allowed_mts | ForEach-Object { [int]$_ } |
        Where-Object { $_ -le $ratedMts })
    if ($compatible.Count -eq 0) {
        throw "平台 '$($Platform.id)' 没有与 DDR4-$ratedMts 物料兼容的速率。"
    }
    return [pscustomobject]@{
        RatedMts = [int]$ratedMts
        ConfiguredMts = [int](($compatible | Measure-Object -Maximum).Maximum)
        ModuleMiB = [int]$matches[0].ModuleMiB
    }
}

function Assert-VMateMemoryRateFacts {
    param(
        [object]$Profile,
        [object]$Platform
    )

    if ($Profile.identity.memory_manufacturer -isnot [string] -or
        [string]$Profile.identity.memory_manufacturer -ne 'Samsung' -or
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
    $facts = Get-VMateMemoryRateFacts -Platform $Platform `
        -PartNumber ([string]$Profile.identity.memory_part)
    $ratedMts = [int]$Profile.identity.memory_rated_mts
    $configuredMts = [int]$Profile.configuration.memory_configured_mts
    # 中文注释：料号、额定值与平台训练值必须作为原子事实校验；任一字段被
    # 手改都 fail-closed，不能在参数层用默认值掩盖持久化身份漂移。
    $plan = Get-VMateMemoryModulePlan -Platform $Platform `
        -MemoryMiB ([int]$Profile.configuration.memory_mib)
    if ($ratedMts -ne $facts.RatedMts -or
        $configuredMts -ne $facts.ConfiguredMts -or
        $configuredMts -gt $ratedMts -or
        [int]$Profile.configuration.memory_module_mib -ne $plan.ModuleMiB -or
        [int]$Profile.configuration.memory_module_count -ne $plan.ModuleCount -or
        [string]$Profile.identity.memory_part -ne $plan.PartNumber) {
        throw '内存料号、额定速率与平台配置速率不一致；请显式 reroll profile。'
    }
}

function Assert-VMateRequestedTopology {
    param(
        [object]$Platform,
        [object]$HostCpu,
        [int]$MemoryMiB,
        [int]$Cpus
    )

    # 创建 profile 前先证明请求能由所选整机表达。若把这些检查留到落盘后，
    # 一次无效参数就会留下无法启动的持久身份，并迫使用户额外 reroll。
    $allowedMemory = @($Platform.memory.allowed_total_mib |
        ForEach-Object { [int]$_ })
    if ($allowedMemory -notcontains $MemoryMiB) {
        throw "MemoryMiB=$MemoryMiB 不在平台允许组合中：$($allowedMemory -join ',')。"
    }
    $maximumMemoryMiB = [int64]$Platform.board.max_memory_gib * 1024
    if ([int64]$MemoryMiB -gt $maximumMemoryMiB) {
        throw "内存 ${MemoryMiB}MiB 超过平台上限 ${maximumMemoryMiB}MiB。"
    }
    [void](Get-VMateMemoryModulePlan -Platform $Platform -MemoryMiB $MemoryMiB)
    if ($Cpus -ne [int]$Platform.cpu.threads) {
        throw "vCPU=$Cpus 与平台 $($Platform.id) 的完整线程数 $($Platform.cpu.threads) 不一致。"
    }
    if ($Cpus -gt [int]$HostCpu.logical_processors) {
        throw "vCPU=$Cpus 超过宿主可用逻辑处理器上限。"
    }
}

#Requires -Version 5.1

<#
.SYNOPSIS
    把共享整机与家庭硬件兼容矩阵转换为 P-11 原子 profile。

.DESCRIPTION
    本文件由 VMate.GpuP.HardwareProfile.ps1 在定义公共校验函数后加载。这里仅做
    数据转换；所有非 host-native 项仍固定为 host-extension-required。
#>

function New-VMateGpuPReferenceProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [Parameter(Mandatory = $true)][object]$Cpu,
        [Parameter(Mandatory = $true)][object]$Board,
        [Parameter(Mandatory = $true)][object]$Memory,
        [Parameter(Mandatory = $true)][object]$Bios,
        [Parameter(Mandatory = $true)][object]$System,
        [Parameter(Mandatory = $true)][object]$Nic,
        [Parameter(Mandatory = $true)][uint64]$MemoryBytes
    )

    $cores = [int](Get-VMateGpuPOptionalProfileProperty $Cpu 'cores' 0)
    $threads = [int](Get-VMateGpuPProfileProperty $Cpu 'threads' "$Id.cpu")
    return [pscustomobject][ordered]@{
        id = Assert-VMateGpuPProfileIdentifier $Id
        label = (([string]$Cpu.name) + ' / ' + ([string]$Board.product))
        enabled = $Enabled
        status = 'reference'
        source = $Source
        identity_fidelity = 'host-extension-required'
        processor = [pscustomobject][ordered]@{
            count = $threads
            maximum_percent = 100
            reserve_percent = 0
            relative_weight = 100
            hw_threads_per_core = if ($cores -gt 0) {
                [Math]::Max(1, [int]($threads / $cores))
            } else { 1 }
            expose_virtualization_extensions = $false
            manufacturer = [string]$Cpu.vendor_id
            name = [string]$Cpu.name
            qemu_arg = [string](Get-VMateGpuPOptionalProfileProperty `
                $Cpu 'qemu_arg' '')
            family = Get-VMateGpuPOptionalProfileProperty $Cpu 'family' $null
            model = Get-VMateGpuPOptionalProfileProperty $Cpu 'model' $null
            stepping = Get-VMateGpuPOptionalProfileProperty `
                $Cpu 'stepping' $null
            cpuid_leaf1_eax = Get-VMateGpuPOptionalProfileProperty `
                $Cpu 'cpuid_leaf1_eax' $null
            cpuid_evidence_source = [string](
                Get-VMateGpuPOptionalProfileProperty `
                    $Cpu 'cpuid_evidence_source' '')
            brand_policy = 'host-extension-required'
        }
        memory = [pscustomobject][ordered]@{
            startup_bytes = $MemoryBytes
            dynamic = $false
            type = [string]$Memory.type
            speed_mts = [int]$Memory.max_mts
            module_identity_policy = 'host-extension-required'
        }
        platform = [pscustomobject][ordered]@{
            manufacturer = [string]$Board.manufacturer
            product = [string]$Board.product
            system_product = [string]$System.product
            version = [string]$Board.version
            chassis_type = [string]$System.chassis_type
            identity_policy = 'host-extension-required'
        }
        bios = [pscustomobject][ordered]@{
            manufacturer = [string]$Bios.vendor
            version = [string]$Bios.version
            release_date = [string]$Bios.date
            identity_policy = 'host-extension-required'
        }
        storage = $null
        network = [pscustomobject][ordered]@{
            model = [string]$Nic.model
            mac_policy = 'vmate-local-unicast-generated-once'
            identity_policy = 'host-extension-required'
        }
        firmware = [pscustomobject][ordered]@{
            serial_policy = 'vmate-unique-generated-once'
        }
        gpu = [pscustomobject][ordered]@{
            quota_profile = 'win10-reference-100'
            observed_reference_quota_profile = 'win10-reference-100'
            low_mmio_bytes = [uint64]3GB
            high_mmio_bytes = [uint64]32GB
            console_resolution_type = 'Maximum'
            console_horizontal_resolution = 3840
            console_vertical_resolution = 2400
            vm_configuration_version = '9.2'
            physical_serial_policy = 'vendor-managed-read-only'
        }
    }
}

function ConvertTo-VMateGpuPSharedPlatformProfile {
    param(
        [Parameter(Mandatory = $true)][object]$Platform,
        [Parameter(Mandatory = $true)][object]$SharedCatalog,
        [Parameter(Mandatory = $true)][object]$P11Catalog
    )

    $platformId = [string](Get-VMateGpuPProfileProperty `
            $Platform 'id' 'shared platform')
    $devices = Get-VMateGpuPProfileProperty $Platform 'devices' $platformId
    return New-VMateGpuPReferenceProfile `
        -Id "shared:$platformId" `
        -Source "shared-platforms:$platformId@$($SharedCatalog.catalog_revision)" `
        -Enabled ([bool]$Platform.enabled) `
        -Cpu (Get-VMateGpuPProfileProperty $Platform 'cpu' $platformId) `
        -Board (Get-VMateGpuPProfileProperty $Platform 'board' $platformId) `
        -Memory (Get-VMateGpuPProfileProperty $Platform 'memory' $platformId) `
        -Bios (Get-VMateGpuPProfileProperty $Platform 'bios' $platformId) `
        -System (Get-VMateGpuPProfileProperty $Platform 'system' $platformId) `
        -Nic (Get-VMateGpuPProfileProperty $devices 'nic' "$platformId.devices") `
        -MemoryBytes ([uint64]$SharedCatalog.defaults.memory_total_mib * 1MB)
}

function Get-VMateGpuPHouseholdBundleKey {
    param(
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $true)][object]$Platform
    )

    $cpu = Get-VMateGpuPProfileProperty $Candidate 'cpu' 'household candidate'
    $board = Get-VMateGpuPProfileProperty $Platform 'board' 'household platform'
    $memory = Get-VMateGpuPProfileProperty $Platform 'memory' 'household platform'
    return (([string]$cpu.name).Trim().ToLowerInvariant() + '|' +
        ([string]$board.manufacturer).Trim().ToLowerInvariant() + '|' +
        ([string]$board.product).Trim().ToLowerInvariant() + '|' +
        ([string]$memory.type).Trim().ToLowerInvariant() + '|' +
        ([string]$memory.max_mts))
}

function ConvertTo-VMateGpuPHouseholdProfile {
    param(
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $true)][object]$Platform,
        [Parameter(Mandatory = $true)][object]$HouseholdCatalog
    )

    $candidateId = [string](Get-VMateGpuPProfileProperty `
            $Candidate 'id' 'household candidate')
    $platformId = [string](Get-VMateGpuPProfileProperty `
            $Platform 'id' 'household platform')
    $memory = Get-VMateGpuPProfileProperty $Platform 'memory' $platformId
    $totals = @((Get-VMateGpuPProfileProperty $memory `
                'allowed_total_mib' "$platformId.memory") |
        ForEach-Object { [int]$_ })
    if ($totals.Count -eq 0) {
        throw "household platform $platformId 没有 allowed_total_mib。"
    }
    $memoryMiB = [int](($totals | Measure-Object -Maximum).Maximum)
    $devices = Get-VMateGpuPProfileProperty $Platform 'devices' $platformId
    return New-VMateGpuPReferenceProfile `
        -Id "household:$candidateId" `
        -Source "household-compatibility:$candidateId@$($HouseholdCatalog.catalog_revision)" `
        -Enabled ([bool]$Candidate.enabled) `
        -Cpu (Get-VMateGpuPProfileProperty $Candidate 'cpu' $candidateId) `
        -Board (Get-VMateGpuPProfileProperty $Platform 'board' $platformId) `
        -Memory $memory `
        -Bios (Get-VMateGpuPProfileProperty $Platform 'bios' $platformId) `
        -System (Get-VMateGpuPProfileProperty $Platform 'system' $platformId) `
        -Nic (Get-VMateGpuPProfileProperty $devices 'nic' "$platformId.devices") `
        -MemoryBytes ([uint64]$memoryMiB * 1MB)
}

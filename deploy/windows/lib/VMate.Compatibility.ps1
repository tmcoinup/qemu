#Requires -Version 5.1

<#
.SYNOPSIS
    校验并解析 Windows/WHPX 使用的通用 Q35 宿主透传兼容模板。

.DESCRIPTION
    物理整机平台与通用兼容模板故意存放在两个清单中。严格模式只选择
    platforms.json 中 CPU/主板完全配对的 supported 条目；本模块只有在调用方
    显式授权后才把 host-compatibility.json 的 QEMU/Q35 虚拟平台与实际宿主
    CPU 绑定，避免把 Xeon 或 AMD CPU 伪装成不可能存在的 ASUS H310 组合。
#>

function Assert-VMateCompatibilityFields {
    param(
        [object]$Object,
        [string[]]$Expected,
        [string]$Where
    )

    if ($null -eq $Object) {
        throw "$Where 必须是 JSON 对象。"
    }
    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if (($actual -join '|') -cne ($wanted -join '|')) {
        throw "$Where 字段集合不完整或包含未知字段。"
    }
}

function Assert-VMateHostCompatibilityManifest {
    param([object]$Manifest)

    Assert-VMateCompatibilityFields $Manifest @(
        'schema_version', 'catalog_revision', 'identity_scope', 'machine_model',
        'defaults', 'selection_policy', 'smbios_policy', 'common', 'templates'
    ) 'host compatibility manifest'
    if (-not (Test-VMateIntegerValue $Manifest.schema_version) -or
        [int]$Manifest.schema_version -ne 1 -or
        $Manifest.catalog_revision -isnot [string] -or
        [string]$Manifest.catalog_revision -notmatch '^\d{4}-\d{2}-\d{2}\.\d+$' -or
        [string]$Manifest.identity_scope -ne
            'generic_q35_host_passthrough_compatibility' -or
        [string]$Manifest.machine_model -ne 'q35') {
        throw 'host compatibility manifest 的 schema、revision 或身份边界无效。'
    }

    Assert-VMateCompatibilityFields $Manifest.defaults `
        @('vcpus', 'memory_total_mib') 'host compatibility defaults'
    foreach ($field in @('vcpus', 'memory_total_mib')) {
        if (-not (Test-VMateIntegerValue $Manifest.defaults.$field) -or
            [int64]$Manifest.defaults.$field -lt 1) {
            throw "host compatibility defaults.$field 必须是正整数。"
        }
    }

    $selection = $Manifest.selection_policy
    Assert-VMateCompatibilityFields $selection @(
        'requires_explicit_allow', 'physical_platform_claim',
        'cpu_vendor_must_match_host', 'cpu_model_source', 'guest_cpu_class',
        'server_brand_policy', 'host_topology_policy', 'profile_binding',
        'tsc_policy', 'kvm_realize_required'
    ) 'host compatibility selection_policy'
    if ($selection.requires_explicit_allow -ne $true -or
        $selection.physical_platform_claim -ne $false -or
        $selection.cpu_vendor_must_match_host -ne $true -or
        [string]$selection.cpu_model_source -ne 'host_passthrough' -or
        [string]$selection.guest_cpu_class -ne 'household_only' -or
        [string]$selection.server_brand_policy -ne 'reject' -or
        [string]$selection.host_topology_policy -ne 'exact_up_to_4_threads' -or
        [string]$selection.profile_binding -ne
            'vendor_brand_family_model_stepping_phys_bits_tsc_topology' -or
        [string]$selection.tsc_policy -ne 'host_default_no_tsc_freq' -or
        $selection.kvm_realize_required -ne $true) {
        throw 'host compatibility selection_policy 不是受控的显式宿主透传策略。'
    }

    $smbios = $Manifest.smbios_policy
    Assert-VMateCompatibilityFields $smbios @(
        'type0', 'type1_to_type3', 'type4', 'unknown_physical_fields'
    ) 'host compatibility smbios_policy'
    if ((@($smbios.type0, $smbios.type1_to_type3, $smbios.type4,
                $smbios.unknown_physical_fields) -join '|') -cne
        'runtime_firmware_default|generic_virtual_platform|' +
        'host_name_vendor_and_guest_topology|omit') {
        throw 'host compatibility smbios_policy 不能诚实表达通用虚拟平台。'
    }

    $common = $Manifest.common
    Assert-VMateCompatibilityFields $common @(
        'status', 'release_year', 'board', 'memory', 'devices', 'bios',
        'system', 'tpm'
    ) 'host compatibility common'
    if ([string]$common.status -ne 'compatibility' -or
        -not (Test-VMateIntegerValue $common.release_year) -or
        [int]$common.release_year -ne 2009) {
        throw 'host compatibility common 必须明确标记 Q35 2009 compatibility。'
    }

    Assert-VMateCompatibilityFields $common.board @(
        'manufacturer', 'product', 'family', 'version', 'serial_fn',
        'subsystem_vendor', 'subsystem_device', 'pch', 'pcie_generation',
        'dimm_slots', 'max_memory_gib'
    ) 'host compatibility board'
    if ((@($common.board.manufacturer, $common.board.product,
                $common.board.family, $common.board.version,
                $common.board.serial_fn, $common.board.pch) -join '|') -cne
        'QEMU|Standard PC (Q35 + ICH9, 2009)|Q35 Virtual Platform|' +
        'pc-q35|_serial_qemu|QEMU Q35/ICH9') {
        throw 'host compatibility board 混入了物理主板身份。'
    }
    foreach ($field in @('pcie_generation', 'dimm_slots', 'max_memory_gib')) {
        if (-not (Test-VMateIntegerValue $common.board.$field) -or
            [int64]$common.board.$field -lt 1) {
            throw "host compatibility board.$field 必须是正整数。"
        }
    }
    foreach ($field in @('subsystem_vendor', 'subsystem_device')) {
        Assert-VMateHexValue $common.board.$field `
            "host compatibility board.$field"
    }
    if ((@($common.board.subsystem_vendor,
                $common.board.subsystem_device) -join '|').ToLowerInvariant() -ne
        '0x1b36|0x0001') {
        throw 'host compatibility board subsystem 不是受控的 QEMU 虚拟身份。'
    }

    Assert-VMateCompatibilityFields $common.system @(
        'manufacturer', 'product', 'family', 'version', 'chassis_type'
    ) 'host compatibility system'
    if ((@($common.system.manufacturer, $common.system.product,
                $common.system.family, $common.system.version,
                $common.system.chassis_type) -join '|') -cne
        'QEMU|Standard PC (Q35 + ICH9, 2009)|Q35 Virtual Platform|' +
        'pc-q35|0x03') {
        throw 'host compatibility system 不是受控的 QEMU/Q35 虚拟身份。'
    }
    Assert-VMateCompatibilityFields $common.bios @('mode') `
        'host compatibility bios'
    if ([string]$common.bios.mode -ne 'runtime_firmware_default') {
        throw '兼容模板必须保留运行时固件 Type 0，不能伪造 BIOS 版本。'
    }

    $memory = $common.memory
    Assert-VMateCompatibilityFields $memory @(
        'type', 'channels', 'max_mts', 'allowed_mts', 'voltage_mv', 'rank',
        'module_mib', 'allowed_total_mib'
    ) 'host compatibility memory'
    if ([string]$memory.type -ne 'DDR4') {
        throw 'Windows Q35 兼容模板当前只支持 DDR4。'
    }
    foreach ($field in @('channels', 'max_mts', 'voltage_mv', 'rank')) {
        if (-not (Test-VMateIntegerValue $memory.$field) -or
            [int64]$memory.$field -lt 1) {
            throw "host compatibility memory.$field 必须是正整数。"
        }
    }
    foreach ($field in @('allowed_mts', 'module_mib', 'allowed_total_mib')) {
        $values = @($memory.$field)
        if ($memory.$field -isnot [System.Array] -or $values.Count -eq 0 -or
            @($values | Where-Object {
                    -not (Test-VMateIntegerValue $_) -or [int64]$_ -lt 1
                }).Count -gt 0) {
            throw "host compatibility memory.$field 必须是非空正整数数组。"
        }
    }
    if (@($memory.allowed_total_mib | ForEach-Object { [int]$_ }) -notcontains
        [int]$Manifest.defaults.memory_total_mib) {
        throw '兼容模板无法组成默认内存容量。'
    }

    $devices = $common.devices
    Assert-VMateCompatibilityFields $devices @(
        'identity_scope', 'chipset', 'root_port', 'xhci', 'nvme', 'nic',
        'audio'
    ) 'host compatibility devices'
    if ([string]$devices.identity_scope -ne 'explicit_virtual_compatibility') {
        throw '兼容模板设备必须明确声明 virtual compatibility 身份边界。'
    }
    Assert-VMateCompatibilityFields $devices.chipset `
        @('mch', 'lpc', 'smbus', 'ahci') 'host compatibility devices.chipset'
    foreach ($name in @('mch', 'lpc', 'smbus', 'ahci')) {
        Assert-VMateHexTuple $devices.chipset.$name `
            "host compatibility devices.chipset.$name"
    }
    if ((@($devices.chipset.mch) + @($devices.chipset.lpc) +
            @($devices.chipset.smbus) + @($devices.chipset.ahci) -join
            '|').ToLowerInvariant() -ne
        '0x8086|0x29c0|0x02|0x8086|0x2918|0x02|' +
        '0x8086|0x2930|0x02|0x8086|0x2922|0x02') {
        throw '兼容模板 chipset 不是原生 Q35/ICH9 身份。'
    }
    foreach ($name in @('root_port', 'xhci')) {
        Assert-VMateCompatibilityFields $devices.$name `
            @('pci_vendor', 'pci_device', 'revision') `
            "host compatibility devices.$name"
        foreach ($field in @('pci_vendor', 'pci_device', 'revision')) {
            Assert-VMateHexValue $devices.$name.$field `
                "host compatibility devices.$name.$field" @(2, 4)
        }
    }
    if ((@($devices.root_port.pci_vendor, $devices.root_port.pci_device,
                $devices.root_port.revision, $devices.xhci.pci_vendor,
                $devices.xhci.pci_device, $devices.xhci.revision) -join '|').ToLowerInvariant() -ne
        '0x1b36|0x000c|0x00|0x1b36|0x000d|0x01') {
        throw '兼容模板 root-port/xHCI 不是 QEMU/Red Hat 通用身份。'
    }
    Assert-VMateCompatibilityFields $devices.nvme @(
        'max_pcie_generation', 'lanes', 'boot_supported', 'attachment'
    ) 'host compatibility devices.nvme'
    if ([string]$devices.nvme.attachment -ne 'pcie_root_port' -or
        $devices.nvme.boot_supported -ne $true -or
        -not (Test-VMateIntegerValue $devices.nvme.max_pcie_generation) -or
        [int]$devices.nvme.max_pcie_generation -ne 3 -or
        -not (Test-VMateIntegerValue $devices.nvme.lanes) -or
        [int]$devices.nvme.lanes -ne 4) {
        throw '兼容模板 NVMe 必须明确挂在虚拟 PCIe root port。'
    }
    Assert-VMateCompatibilityFields $devices.nic @(
        'vendor', 'model', 'pci_vendor', 'pci_device', 'subsystem_vendor',
        'subsystem_device', 'mac_oui', 'attachment', 'board_nic_state'
    ) 'host compatibility devices.nic'
    if ((@($devices.nic.vendor, $devices.nic.model, $devices.nic.pci_vendor,
                $devices.nic.pci_device, $devices.nic.subsystem_vendor,
                $devices.nic.subsystem_device, $devices.nic.mac_oui,
                $devices.nic.attachment,
                $devices.nic.board_nic_state) -join '|').ToLowerInvariant() -ne
        'intel|intel 82574l gigabit network connection|0x8086|0x10d3|' +
        '0x8086|0xa01f|3c:fd:fe|add_in|not_applicable') {
        throw '兼容模板 NIC 不是受控的独立 e1000e 设备。'
    }
    Assert-VMateCompatibilityFields $devices.audio @(
        'vendor', 'codec', 'codec_id', 'codec_revision', 'codec_subsystem_id',
        'identity_fidelity', 'controller_pci_vendor', 'controller_pci_device'
    ) 'host compatibility devices.audio'
    if ((@($devices.audio.vendor, $devices.audio.codec,
                $devices.audio.codec_id, $devices.audio.codec_revision,
                $devices.audio.codec_subsystem_id,
                $devices.audio.identity_fidelity,
                $devices.audio.controller_pci_vendor,
                $devices.audio.controller_pci_device) -join '|').ToLowerInvariant() -ne
        'qemu|generic hda codec|0x1af40022|0x00100101|0x1af40022|' +
        'generic_virtual_protocol|0x8086|0x293e') {
        throw '兼容模板音频必须使用 QEMU generic HDA/ICH9 身份。'
    }

    $tpm = $common.tpm
    Assert-VMateCompatibilityFields $tpm @(
        'capability', 'supported', 'implementation', 'version',
        'emulation_frontend', 'pcr_banks'
    ) 'host compatibility tpm'
    if ($tpm.supported -ne $false -or
        $tpm.pcr_banks -isnot [System.Array] -or
        (@($tpm.capability, $tpm.implementation, $tpm.version,
                $tpm.emulation_frontend, (@($tpm.pcr_banks) -join ',')) -join '|') -ne
        'none|none|none|none|') {
        throw 'Windows/WHPX 兼容模板必须保持无 TPM。'
    }

    $templates = @($Manifest.templates)
    if ($Manifest.templates -isnot [System.Array] -or $templates.Count -ne 2) {
        throw 'host compatibility manifest 必须含 Intel/AMD 两个模板。'
    }
    $seen = @{}
    foreach ($template in $templates) {
        Assert-VMateCompatibilityFields $template `
            @('id', 'vendor_id', 'cpu_policy') 'host compatibility template'
        Assert-VMateCompatibilityFields $template.cpu_policy `
            @('qemu_model', 'feature_policy', 'integrated_gpu_state') `
            "host compatibility template '$($template.id)'.cpu_policy"
        $expectedId = switch ([string]$template.vendor_id) {
            'GenuineIntel' { 'compat-host-intel-q35' }
            'AuthenticAMD' { 'compat-host-amd-q35' }
            default { throw "兼容模板 CPU vendor 无效：$($template.vendor_id)" }
        }
        if ([string]$template.id -ne $expectedId -or
            $seen.ContainsKey([string]$template.id) -or
            (@($template.cpu_policy.qemu_model,
                    $template.cpu_policy.feature_policy,
                    $template.cpu_policy.integrated_gpu_state) -join '|') -ne
            'host|host_default|not_exposed') {
            throw "兼容模板 '$($template.id)' 的 ID 或 host CPU 策略无效。"
        }
        $seen[[string]$template.id] = $true
    }
}

function Read-VMateHostCompatibilityManifest {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到宿主兼容模板清单：$Path"
    }
    try {
        $manifest = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "宿主兼容模板清单不是有效 JSON：$Path；$($_.Exception.Message)"
    }
    Assert-VMateHostCompatibilityManifest -Manifest $manifest
    return $manifest
}

function Test-VMateHostCpuPlatformPair {
    param(
        [object]$Platform,
        [object]$HostCpu
    )

    if (Test-VMateCompatibilityPlatform -Platform $Platform) {
        return $false
    }
    $platformName = (([string]$Platform.cpu.name) -replace '\s+', ' ').Trim()
    $hostName = (([string]$HostCpu.name) -replace '\s+', ' ').Trim()
    return ([string]$Platform.cpu.vendor_id -eq [string]$HostCpu.vendor_id -and
        $platformName -eq $hostName -and
        [int]$Platform.cpu.cores -eq [int]$HostCpu.cores -and
        [int]$Platform.cpu.threads -eq [int]$HostCpu.logical_processors)
}

function Test-VMateCompatibilityPlatform {
    param([object]$Platform)

    return (Test-VMateJsonProperty $Platform 'identity_scope') -and
        [string]$Platform.identity_scope -eq
            'generic_q35_host_passthrough_compatibility'
}

function Assert-VMateHouseholdHostCpu {
    param([object]$HostCpu)

    $name = (([string]$HostCpu.name) -replace '\s+', ' ').Trim()
    if (-not $name) {
        throw '宿主 CPU 名称为空，不能判断是否为家用型号。'
    }
    # WHPX 的 -cpu host 无法把服务器处理器重塑成家用 CPUID。即使用户显式
    # 允许 generic Q35，也不能把 Xeon/E5/EPYC/Opteron 品牌原样暴露给 Guest。
    if ($name -match '(?i)\b(?:xeon|epyc|opteron|threadripper)\b' -or
        $name -match '(?i)(?<![A-Za-z0-9])E[357][-\s]*\d{3,5}[A-Za-z0-9]*(?![A-Za-z0-9])' -or
        $name -match '(?i)(?<![A-Za-z0-9])E-\d{4,5}[A-Za-z0-9]*(?![A-Za-z0-9])') {
        throw "WHPX host-passthrough 兼容模板拒绝服务器 CPU '$name'；" +
            '该宿主必须改用能塑造家用 Guest CPU 的完整 compatibility bundle。'
    }
    $household = if ([string]$HostCpu.vendor_id -eq 'GenuineIntel') {
        $name -match '(?i)\b(?:core|pentium|celeron|atom)\b|Intel\(R\)\s+(?:Processor\s+)?[NU]\d{2,4}\b'
    } else {
        $name -match '(?i)\b(?:ryzen|athlon|phenom|sempron)\b|\b(?:FX|A(?:4|6|8|10|12))-\d'
    }
    if (-not $household) {
        throw "无法从宿主 CPU 品牌证明 '$name' 属于受控家用系列，拒绝 host-passthrough。"
    }
}

function Resolve-VMateHostCompatibilityPlatform {
    param(
        [object]$Manifest,
        [object]$Template,
        [object]$HostCpu,
        [int]$GuestCpus
    )

    if ([string]$Template.vendor_id -ne [string]$HostCpu.vendor_id) {
        throw "兼容模板 '$($Template.id)' 与宿主 CPU 厂商不匹配。"
    }
    Assert-VMateHouseholdHostCpu -HostCpu $HostCpu
    $hostCores = [int]$HostCpu.cores
    $hostThreads = [int]$HostCpu.logical_processors
    if ($GuestCpus -lt 1) {
        $GuestCpus = [int]$Manifest.defaults.vcpus
    }
    $hostTopology = "${hostCores}C${hostThreads}T"
    if ($hostTopology -notin @('2C2T', '2C4T', '4C4T') -or
        $GuestCpus -ne $hostThreads) {
        throw "WHPX host-passthrough 只允许 2C2T、2C4T 或 4C4T 家用宿主，且 Guest vCPU 必须等于宿主线程数；" +
            "宿主=${hostCores}C/${hostThreads}T，Guest=${GuestCpus} vCPU。"
    }
    $platform = $Manifest.common | ConvertTo-Json -Depth 64 |
        ConvertFrom-Json
    $platform | Add-Member -NotePropertyName id `
        -NotePropertyValue ([string]$Template.id)
    $platform | Add-Member -NotePropertyName enabled -NotePropertyValue $false
    $platform | Add-Member -NotePropertyName identity_scope `
        -NotePropertyValue ([string]$Manifest.identity_scope)
    $platform | Add-Member -NotePropertyName cpu -NotePropertyValue ([pscustomobject]@{
        qemu_arg = 'host'
        vendor_id = [string]$HostCpu.vendor_id
        name = [string]$HostCpu.name
        max_mhz = [int]$HostCpu.max_mhz
        current_mhz = [int]$HostCpu.max_mhz
        cores = $hostCores
        threads = $hostThreads
        policy = 'host_passthrough'
    })
    return $platform
}

function Select-VMatePlatform {
    param(
        [object]$Manifest,
        [object]$CompatibilityManifest = $null,
        [string]$PlatformId = '',
        [object]$HostCpu,
        [Alias('AllowHostCpuPlatformMismatch')]
        [bool]$AllowPlatformCompatibility = $false,
        [int]$GuestCpus = 0
    )

    $enabled = @($Manifest.platforms | Where-Object {
        $_.enabled -eq $true -and [string]$_.status -eq 'supported' -and
        [string]$_.devices.audio.controller_pci_vendor -eq '0x8086'
    })
    foreach ($platform in $enabled) {
        Assert-VMatePlatformShape -Platform $platform
    }
    $strictMatches = @($enabled | Where-Object {
        Test-VMateHostCpuPlatformPair -Platform $_ -HostCpu $HostCpu
    })

    if ($PlatformId) {
        $physical = @($enabled | Where-Object { [string]$_.id -eq $PlatformId })
        if ($physical.Count -eq 1) {
            Assert-VMateHouseholdHostCpu -HostCpu $HostCpu
            if (-not (Test-VMateHostCpuPlatformPair $physical[0] $HostCpu)) {
                throw "平台 CPU '$($physical[0].cpu.name)' 与宿主 '$($HostCpu.name)' 不匹配；" +
                    '物理平台不能通过 compatibility 开关强行混搭。'
            }
            return [pscustomobject]@{
                Platform = $physical[0]
                Catalog = $Manifest
                IsCompatibility = $false
            }
        }
        if ($null -eq $CompatibilityManifest) {
            if ($PlatformId -like 'compat-host-*-q35') {
                throw "平台 '$PlatformId' 需要显式 -AllowPlatformCompatibility。"
            }
            throw "平台 '$PlatformId' 不存在、已禁用或不是 Windows 候选。"
        }
        $templates = @($CompatibilityManifest.templates | Where-Object {
            [string]$_.id -eq $PlatformId
        })
        if ($templates.Count -ne 1 -or -not $AllowPlatformCompatibility) {
            throw "兼容模板 '$PlatformId' 不存在或未被显式授权。"
        }
        $resolved = Resolve-VMateHostCompatibilityPlatform `
            -Manifest $CompatibilityManifest -Template $templates[0] `
            -HostCpu $HostCpu -GuestCpus $GuestCpus
        return [pscustomobject]@{
            Platform = $resolved
            Catalog = $CompatibilityManifest
            IsCompatibility = $true
        }
    }

    if ($strictMatches.Count -gt 0) {
        $selected = $strictMatches[(Get-VMateSecureIndex -Count $strictMatches.Count)]
        Assert-VMateHouseholdHostCpu -HostCpu $HostCpu
        return [pscustomobject]@{
            Platform = $selected
            Catalog = $Manifest
            IsCompatibility = $false
        }
    }
    if (-not $AllowPlatformCompatibility) {
        throw "共享清单没有与 WHPX 宿主 CPU '$($HostCpu.name)' 精确匹配的启用平台；" +
            'Windows 启动器当前只开放精确物理平台。'
    }
    if ($null -eq $CompatibilityManifest) {
        throw '已允许平台兼容，但宿主兼容模板清单尚未加载。'
    }
    $templates = @($CompatibilityManifest.templates | Where-Object {
        [string]$_.vendor_id -eq [string]$HostCpu.vendor_id
    })
    if ($templates.Count -ne 1) {
        throw "没有且仅有一个适配宿主厂商 '$($HostCpu.vendor_id)' 的兼容模板。"
    }
    $resolved = Resolve-VMateHostCompatibilityPlatform `
        -Manifest $CompatibilityManifest -Template $templates[0] `
        -HostCpu $HostCpu -GuestCpus $GuestCpus
    return [pscustomobject]@{
        Platform = $resolved
        Catalog = $CompatibilityManifest
        IsCompatibility = $true
    }
}

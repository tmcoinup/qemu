#Requires -Version 5.1

<#
.SYNOPSIS
    校验共享整机清单中会进入 Windows profile/QEMU 参数的深层硬件事实。

.DESCRIPTION
    本模块集中校验 fidelity、JSON 类型、CPU/主板系列、PCI 元组、BIOS 日期
    及设备身份；主清单模块负责目录状态、TPM 和内存组合。拆分后每个
    PowerShell 文件保持在 500 行以内，同时与 Linux 校验器采用同一 fail-closed
    边界。
#>

function Assert-VMateManifestFidelity {
    param([object]$Manifest)

    if (-not (Test-VMateJsonProperty $Manifest 'fidelity')) {
        throw '共享硬件清单缺少 fidelity；不能判断 Q35 与目标 PCH 的真实性边界。'
    }
    $fidelity = $Manifest.fidelity
    $expectedText = [ordered]@{
        supported_semantics = 'launch_candidate_after_runtime_preflight'
        machine_model = 'q35'
        chipset_identity_scope = 'pci_configuration_identity_only'
        target_pch_behavior = 'not_emulated'
        serial_identity_scope = 'synthetic_format_only_no_device_capture'
        asset_tag_identity_scope = 'synthetic_format_only_no_device_capture'
        mac_identity_scope = 'vendor_oui_synthetic_suffix'
        pci_subsystem_evidence = 'catalog_reference_no_lspci_snapshot'
    }
    foreach ($entry in $expectedText.GetEnumerator()) {
        if (-not (Test-VMateJsonProperty $fidelity $entry.Key) -or
            [string]$fidelity.($entry.Key) -ne [string]$entry.Value) {
            throw "共享清单 fidelity.$($entry.Key) 不是受控值 '$($entry.Value)'。"
        }
    }
    if (-not (Test-VMateJsonProperty $fidelity 'target_pch_bdf_equivalent') -or
        $fidelity.target_pch_bdf_equivalent -isnot [bool] -or
        $fidelity.target_pch_bdf_equivalent -ne $false) {
        throw '共享清单不得宣称 Q35 BDF 与目标 PCH 等价。'
    }
    if (-not (Test-VMateJsonProperty $fidelity 'bdf_layout')) {
        throw '共享清单 fidelity 缺少经当前启动器验证的 bdf_layout。'
    }

    # 布局钉住 Linux/Windows 实际 Q35 枚举；不声称目标主板使用相同地址。
    $layout = $fidelity.bdf_layout
    $expectedLayout = [ordered]@{
        mch = '00:00.0'
        lpc = '00:1f.0'
        ahci = '00:1f.2'
        smbus = '00:1f.3'
        linux_root_ports = '00:01.0,00:02.0,00:03.0,00:04.0'
        linux_hda = '00:05.0'
        windows_root_ports = '00:01.0,00:02.0,00:03.0'
        windows_hda = '00:04.0'
    }
    $actualNames = @($layout.PSObject.Properties.Name)
    if ($actualNames.Count -ne $expectedLayout.Count) {
        throw '共享清单 bdf_layout 字段集合不完整或包含未知字段。'
    }
    foreach ($entry in $expectedLayout.GetEnumerator()) {
        if (-not (Test-VMateJsonProperty $layout $entry.Key)) {
            throw "共享清单 bdf_layout 缺少 '$($entry.Key)'。"
        }
        $actual = if ($entry.Key -like '*_root_ports') {
            @($layout.($entry.Key)) -join ','
        } else {
            [string]$layout.($entry.Key)
        }
        if ($actual -ne [string]$entry.Value) {
            throw "共享清单 bdf_layout.$($entry.Key) 与当前 Q35 启动器不一致。"
        }
    }
}

function Assert-VMateNonEmptyStringFields {
    param(
        [object]$Object,
        [string[]]$Fields,
        [string]$Where
    )

    foreach ($field in $Fields) {
        if (-not (Test-VMateJsonProperty $Object $field) -or
            $Object.$field -isnot [string] -or
            -not [string]$Object.$field) {
            throw "$Where.$field 必须是非空 JSON 字符串。"
        }
    }
}

function Assert-VMatePositiveIntegerFields {
    param(
        [object]$Object,
        [string[]]$Fields,
        [string]$Where
    )

    foreach ($field in $Fields) {
        if (-not (Test-VMateJsonProperty $Object $field) -or
            -not (Test-VMateIntegerValue $Object.$field) -or
            [int64]$Object.$field -lt 1) {
            throw "$Where.$field 必须是正的 JSON 整数。"
        }
    }
}

function Assert-VMateHexValue {
    param(
        [object]$Value,
        [string]$Where,
        [int[]]$Digits = @(2, 4)
    )

    $alternatives = @($Digits | ForEach-Object { "[0-9A-Fa-f]{$_}" }) -join '|'
    if ($Value -isnot [string] -or
        [string]$Value -notmatch "^0x(?:$alternatives)$") {
        throw "$Where 必须是 0x 前缀的受控十六进制值。"
    }
}

function Assert-VMateHexTuple {
    param(
        [object]$Value,
        [string]$Where
    )

    if ($Value -isnot [System.Array] -or @($Value).Count -ne 3) {
        throw "$Where 必须是 vendor/device/revision 三元组。"
    }
    for ($index = 0; $index -lt 3; $index++) {
        Assert-VMateHexValue $Value[$index] "$Where[$index]" @(2, 4)
    }
}

function Assert-VMateHouseholdGuestCpu {
    param(
        [object]$Cpu,
        [string]$PlatformId
    )

    # 正常清单与 compatibility 都必须正向证明家用类别；不能因为清单当前
    # 恰好没有服务器条目，就允许以后新增的 Xeon/E/EPYC 身份直接进入 Guest。
    $name = [string]$Cpu.name
    $identity = "$name|$([string]$Cpu.qemu_arg)"
    $qemuBase = ([string]$Cpu.qemu_arg).Split(',')[0].ToLowerInvariant()
    if ($qemuBase -notin @('skylake-client-ibrs', 'ryzen3-1200')) {
        throw "平台 '$PlatformId' 的 CPU 未使用已审计家用 QEMU named-model。"
    }
    $serverPattern = '(?i)\b(?:xeon|epyc|opteron|threadripper)\b|' +
        '(?<![A-Za-z0-9])E[357][-\s]*[0-9]{3,5}[A-Za-z0-9]*(?![A-Za-z0-9])|' +
        '(?<![A-Za-z0-9])E-[0-9]{4,5}[A-Za-z0-9]*(?![A-Za-z0-9])'
    if ($identity -match $serverPattern) {
        throw "平台 '$PlatformId' 的 CPU 包含服务器/E 系列身份，禁止进入 Guest。"
    }
    $household = switch ([string]$Cpu.vendor_id) {
        'GenuineIntel' {
            $name -match '(?i)\b(?:core|pentium|celeron|atom)\b|' +
                'Intel\(R\)\s+(?:Processor\s+)?[NU][0-9]{2,4}\b'
        }
        'AuthenticAMD' {
            $name -match '(?i)\b(?:ryzen|athlon|phenom|sempron)\b|' +
                '(?<![A-Za-z0-9])(?:FX|A(?:4|6|8|10|12))-[0-9]'
        }
        default { $false }
    }
    if (-not $household) {
        throw "平台 '$PlatformId' 的 CPU 无法证明属于受控家用系列。"
    }
}

function Assert-VMatePlatformFacts {
    param(
        [object]$Platform,
        [string]$PlatformId
    )

    if (-not (Test-VMateIntegerValue $Platform.release_year) -or
        [int]$Platform.release_year -lt 2005 -or
        [int]$Platform.release_year -gt [DateTime]::UtcNow.Year) {
        throw "平台 '$PlatformId' 的 release_year 不是合理的 JSON 整数。"
    }

    $cpu = $Platform.cpu
    Assert-VMateNonEmptyStringFields $cpu `
        @('qemu_arg', 'vendor_id', 'name', 'part', 'socket', 'features') `
        "平台 '$PlatformId'.cpu"
    Assert-VMatePositiveIntegerFields $cpu `
        @('max_mhz', 'current_mhz', 'tsc_mhz', 'cores', 'threads', 'phys_bits') `
        "平台 '$PlatformId'.cpu"
    $cpuTopology = "$([int64]$cpu.cores)C$([int64]$cpu.threads)T"
    if ($cpu.vendor_id -notin @('AuthenticAMD', 'GenuineIntel') -or
        [int64]$cpu.current_mhz -gt [int64]$cpu.max_mhz -or
        [int64]$cpu.tsc_mhz -gt [int64]$cpu.max_mhz -or
        $cpuTopology -notin @('2C2T', '2C4T', '4C4T') -or
        [int64]$cpu.phys_bits -lt 32 -or [int64]$cpu.phys_bits -gt 52) {
        throw "平台 '$PlatformId' 的 CPU 厂商、频率、拓扑或物理地址位无效。"
    }
    if (($cpu.vendor_id -eq 'GenuineIntel' -and
            [string]$cpu.features -like '*+topoext*') -or
        ($cpu.vendor_id -eq 'AuthenticAMD' -and
            [string]$cpu.features -notlike '*+topoext*')) {
        throw "平台 '$PlatformId' 的 CPU features 与厂商不一致。"
    }
    Assert-VMateHouseholdGuestCpu -Cpu $cpu -PlatformId $PlatformId

    $igpu = $cpu.integrated_gpu
    Assert-VMateNonEmptyStringFields $igpu @('profile_state', 'model') `
        "平台 '$PlatformId'.cpu.integrated_gpu"
    if ($igpu.present -isnot [bool] -or
        $igpu.profile_state -notin @('absent', 'fused_off', 'disabled_in_bios') -or
        ([bool]$igpu.present -ne ($igpu.profile_state -eq 'disabled_in_bios'))) {
        throw "平台 '$PlatformId' 的集成显卡状态自相矛盾。"
    }

    $smbios = $cpu.smbios
    foreach ($field in @('family', 'upgrade', 'characteristics')) {
        Assert-VMateHexValue $smbios.$field `
            "平台 '$PlatformId'.cpu.smbios.$field" @(2, 4)
    }
    Assert-VMatePositiveIntegerFields $smbios `
        @('voltage_mv', 'external_clock_mhz') "平台 '$PlatformId'.cpu.smbios"

    $board = $Platform.board
    Assert-VMateNonEmptyStringFields $board `
        @('manufacturer', 'product', 'family', 'version', 'serial_fn', 'pch') `
        "平台 '$PlatformId'.board"
    foreach ($field in @('subsystem_vendor', 'subsystem_device')) {
        Assert-VMateHexValue $board.$field "平台 '$PlatformId'.board.$field"
    }
    if ([string]$board.serial_fn -notmatch '^_serial_(asus|msi|giga|asr)$') {
        throw "平台 '$PlatformId' 的 board.serial_fn 不在生成器白名单。"
    }

    Assert-VMateNonEmptyStringFields $Platform.bios @('vendor', 'version', 'date') `
        "平台 '$PlatformId'.bios"
    $parsedDate = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
            [string]$Platform.bios.date, 'MM/dd/yyyy',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
        throw "平台 '$PlatformId' 的 bios.date 必须是 MM/DD/YYYY。"
    }
    Assert-VMateNonEmptyStringFields $Platform.system @('product', 'family') `
        "平台 '$PlatformId'.system"
    Assert-VMateHexValue $Platform.system.chassis_type `
        "平台 '$PlatformId'.system.chassis_type" @(2)
    if ([string]$Platform.system.chassis_type -ne '0x03') {
        throw "平台 '$PlatformId' 当前只允许 DMTF Desktop 0x03。"
    }

    $devices = $Platform.devices
    foreach ($name in @('mch', 'lpc', 'smbus', 'ahci')) {
        Assert-VMateHexTuple $devices.chipset.$name `
            "平台 '$PlatformId'.devices.chipset.$name"
    }
    foreach ($name in @('root_port', 'xhci')) {
        foreach ($field in @('pci_vendor', 'pci_device', 'revision')) {
            Assert-VMateHexValue $devices.$name.$field `
                "平台 '$PlatformId'.devices.$name.$field" @(2, 4)
        }
    }
    Assert-VMatePositiveIntegerFields $devices.nvme `
        @('max_pcie_generation', 'lanes') "平台 '$PlatformId'.devices.nvme"
    if ([int]$devices.nvme.max_pcie_generation -gt [int]$board.pcie_generation -or
        [int]$devices.nvme.lanes -notin @(1, 2, 4) -or
        $devices.nvme.boot_supported -isnot [bool] -or
        [string]$devices.nvme.attachment -ne 'm2_socket') {
        throw "平台 '$PlatformId' 的 NVMe 接口事实无效。"
    }

    $nic = $devices.nic
    Assert-VMateNonEmptyStringFields $nic `
        @('vendor', 'model', 'pci_vendor', 'pci_device', 'subsystem_vendor',
            'subsystem_device', 'mac_oui', 'attachment', 'board_nic_state') `
        "平台 '$PlatformId'.devices.nic"
    if ((@($nic.pci_vendor, $nic.pci_device, $nic.subsystem_vendor,
                $nic.subsystem_device, $nic.mac_oui) -join '|') -cne
        '0x8086|0x10D3|0x8086|0xA01F|3c:fd:fe' -or
        $nic.attachment -cne 'add_in' -or
        $nic.board_nic_state -cne 'disabled_in_bios') {
        throw "平台 '$PlatformId' 当前 NIC 行为层只能声明受控 Intel 82574L bundle。"
    }

    $audio = $devices.audio
    Assert-VMateNonEmptyStringFields $audio `
        @('vendor', 'codec', 'codec_id', 'codec_revision', 'codec_subsystem_id',
            'identity_fidelity', 'controller_pci_vendor',
            'controller_pci_device') "平台 '$PlatformId'.devices.audio"
    foreach ($field in @('codec_id', 'codec_revision', 'codec_subsystem_id')) {
        Assert-VMateHexValue $audio.$field `
            "平台 '$PlatformId'.devices.audio.$field" @(8)
    }
    foreach ($field in @('controller_pci_vendor', 'controller_pci_device')) {
        Assert-VMateHexValue $audio.$field `
            "平台 '$PlatformId'.devices.audio.$field"
    }
    $audioContracts = @{
        '0x1043' = 'ALC887|0x10ec0887|0x00100302|0x104386c7'
        '0x1462' = 'ALC887|0x10ec0887|0x00100302|0x1462c708'
        '0x1458' = 'ALC887|0x10ec0887|0x00100302|0x1458a182'
    }
    $expectedAudio = $audioContracts[[string]$board.subsystem_vendor]
    if ($null -eq $expectedAudio -or
        (@($audio.codec, $audio.codec_id, $audio.codec_revision,
                $audio.codec_subsystem_id) -join '|') -cne $expectedAudio -or
        $audio.identity_fidelity -cne 'protocol_identity_only') {
        throw "平台 '$PlatformId' 的 ALC887 协议身份不是已审计组合。"
    }

    if ([int]$Platform.memory.voltage_mv -notin @(1200, 1500) -or
        [int]$Platform.memory.rank -notin @(1, 2)) {
        throw "平台 '$PlatformId' 的内存电压或 rank 不受支持。"
    }
    Assert-VMateH310CpuPolicy -Platform $Platform -PlatformId $PlatformId
}

function Get-VMateExpectedPlatformId {
    param(
        [object]$Cpu,
        [object]$Board
    )

    $name = [string]$Cpu.name
    $vendorToken = ''
    $cpuToken = ''
    if ([string]$Cpu.vendor_id -eq 'AuthenticAMD' -and
        $name -match '\bRyzen\s+(\d+)\s+([0-9A-Za-z]+)\b') {
        $vendorToken = 'amd'
        $cpuToken = "r$($Matches[1])-$($Matches[2].ToLowerInvariant())"
    } elseif ([string]$Cpu.vendor_id -eq 'GenuineIntel' -and
        $name -match '\bCore\(TM\)\s+i(\d)-([0-9A-Za-z]+)\b') {
        $vendorToken = 'intel'
        $cpuToken = "i$($Matches[1])-$($Matches[2].ToLowerInvariant())"
    } elseif ([string]$Cpu.vendor_id -eq 'GenuineIntel' -and
        $name -match '\bCeleron\(R\)\s+([A-Z]\d+)\b') {
        $vendorToken = 'intel'
        $cpuToken = "celeron-$($Matches[1].ToLowerInvariant())"
    } elseif ([string]$Cpu.vendor_id -eq 'GenuineIntel' -and
        $name -match '\bPentium\(R\)\s+Gold\s+([A-Z]\d+)\b') {
        $vendorToken = 'intel'
        $cpuToken = "pentium-$($Matches[1].ToLowerInvariant())"
    } else {
        throw "无法从 CPU 名称生成平台系列 ID：$name"
    }
    $boardVendors = @{
        'ASUSTeK COMPUTER INC.' = @('asus', '0x1043')
        'Micro-Star International Co., Ltd.' = @('msi', '0x1462')
        'Gigabyte Technology Co., Ltd.' = @('gigabyte', '0x1458')
        'ASRock' = @('asrock', '0x1849')
    }
    $boardVendor = $boardVendors[[string]$Board.manufacturer]
    if ($null -eq $boardVendor -or
        [string]$Board.subsystem_vendor -cne $boardVendor[1]) {
        throw "主板厂商与 subsystem vendor 未注册：$($Board.manufacturer)"
    }
    $product = ([string]$Board.product -replace '\.0\b', '').Replace('.', '')
    $boardToken = ($product.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    return "$vendorToken-$(([string]$Cpu.socket).ToLowerInvariant())-" +
        "$cpuToken-$($boardVendor[0])-$boardToken"
}

function Assert-VMateH310CpuPolicy {
    param(
        [object]$Platform,
        [string]$PlatformId
    )

    if ([string]$Platform.board.product -cne 'PRIME H310M-A R2.0') {
        return
    }
    $expected = switch -CaseSensitive ($PlatformId) {
        'intel-lga1151-celeron-g4900-asus-prime-h310m-a-r2' {
            [pscustomobject]@{
                ReleaseYear = 2018
                Name = 'Intel(R) Celeron(R) G4900 CPU @ 3.10GHz'
                Part = 'BX80684G4900'
                Frequencies = '3100|3100|3100'
                Topology = '2|2'
                Family = '0x00C7'
                Characteristics = '0x00EC'
                Igpu = 'True|disabled_in_bios|Intel UHD Graphics 610'
                QemuArg = 'Skylake-Client-IBRS,family=6,model=158,stepping=11,adx=off,avx=off,avx2=off,bmi1=off,bmi2=off,f16c=off,fma=off,hle=off,rtm=off,model-id=Intel(R) Celeron(R) G4900 CPU @ 3.10GHz'
                CpuSource = 'https://www.intel.com/content/www/us/en/products/sku/129487/intel-celeron-g4900-processor-2m-cache-3-10-ghz/specifications.html'
            }
            break
        }
        'intel-lga1151-pentium-g5400-asus-prime-h310m-a-r2' {
            [pscustomobject]@{
                ReleaseYear = 2018
                Name = 'Intel(R) Pentium(R) Gold G5400 CPU @ 3.70GHz'
                Part = 'BX80684G5400'
                Frequencies = '3700|3700|3700'
                Topology = '2|4'
                Family = '0x000B'
                Characteristics = '0x00FC'
                Igpu = 'True|disabled_in_bios|Intel UHD Graphics 610'
                QemuArg = 'Skylake-Client-IBRS,family=6,model=158,stepping=11,adx=off,avx=off,avx2=off,bmi1=off,bmi2=off,f16c=off,fma=off,hle=off,rtm=off,model-id=Intel(R) Pentium(R) Gold G5400 CPU @ 3.70GHz'
                CpuSource = 'https://www.intel.com/content/www/us/en/products/sku/129951/intel-pentium-gold-g5400-processor-4m-cache-3-70-ghz/specifications.html'
            }
            break
        }
        'intel-lga1151-i3-9100f-asus-prime-h310m-a-r2' {
            [pscustomobject]@{
                ReleaseYear = 2019
                Name = 'Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz'
                Part = 'BX80684I39100F'
                Frequencies = '4200|3600|3600'
                Topology = '4|4'
                Family = '0x00CE'
                Characteristics = '0x00EC'
                Igpu = 'False|fused_off|none'
                QemuArg = 'Skylake-Client-IBRS,family=6,model=158,stepping=11,hle=off,rtm=off,model-id=Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz'
                CpuSource = 'https://www.intel.com/content/www/us/en/products/sku/190886/intel-core-i39100f-processor-6m-cache-up-to-4-20-ghz/specifications.html'
            }
            break
        }
        default {
            throw "平台 '$PlatformId' 的 H310 CPU 尚未进入严格审计表。"
        }
    }

    $cpu = $Platform.cpu
    $actualFrequencies = @(
        $cpu.max_mhz, $cpu.current_mhz, $cpu.tsc_mhz
    ) -join '|'
    $actualTopology = @($cpu.cores, $cpu.threads) -join '|'
    $actualIgpu = @(
        [string][bool]$cpu.integrated_gpu.present,
        [string]$cpu.integrated_gpu.profile_state,
        [string]$cpu.integrated_gpu.model
    ) -join '|'
    if ($Platform.enabled -ne $true -or $Platform.status -cne 'supported' -or
        [int]$Platform.release_year -ne $expected.ReleaseYear -or
        [string]$cpu.vendor_id -cne 'GenuineIntel' -or
        [string]$cpu.socket -cne 'LGA1151' -or [int]$cpu.phys_bits -ne 39 -or
        [string]$cpu.features -cne '+invtsc,+tsc-deadline' -or
        [string]$cpu.name -cne $expected.Name -or
        [string]$cpu.part -cne $expected.Part -or
        $actualFrequencies -cne $expected.Frequencies -or
        $actualTopology -cne $expected.Topology -or
        [string]$cpu.smbios.family -cne $expected.Family -or
        [string]$cpu.smbios.characteristics -cne $expected.Characteristics -or
        $actualIgpu -cne $expected.Igpu -or
        [string]$cpu.qemu_arg -cne $expected.QemuArg) {
        throw "平台 '$PlatformId' 偏离官方 H310/SKU 审计事实。"
    }
    if ([string]$Platform.memory.type -cne 'DDR4' -or
        [int]$Platform.memory.channels -ne 2 -or
        [int]$Platform.memory.max_mts -ne 2400 -or
        (@($Platform.memory.allowed_mts) -join ',') -cne '2133,2400' -or
        [int]$Platform.memory.voltage_mv -ne 1200) {
        throw "平台 '$PlatformId' 不是官方 DDR4-2400 组合。"
    }
    $requiredSources = @(
        $expected.CpuSource,
        'https://www.intel.com/content/www/us/en/support/topics/support-and-servicing-for-processors.html',
        'https://www.asus.com/supportonly/prime%20h310m-a%20r2.0/helpdesk_cpu/',
        'https://dlcdnets.asus.com/pub/ASUS/mb/LGA1151/PRIME_H310M-A_R2.0/E15471_PRIME_H310M-A_R2.0_UM_V2_WEB.pdf'
    )
    foreach ($source in $requiredSources) {
        if (@($Platform.source_refs) -cnotcontains [string]$source) {
            throw "平台 '$PlatformId' 缺少 Intel/ASUS 官方组合证据。"
        }
    }
}

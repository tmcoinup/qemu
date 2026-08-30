#Requires -Version 5.1

. (Join-Path $PSScriptRoot 'VMate.Manifest.Validation.ps1')

<#
.SYNOPSIS
    验证 Windows/WHPX 路线使用的共享整机硬件清单。

.DESCRIPTION
    Linux 与 Windows 必须对 supported、compatibility 和 Q35 拟真边界采用同一
    解释。本模块在选择平台前锁定这些目录语义，并拒绝状态、BDF 或来源字段被
    篡改的清单，避免 Windows 只看 enabled 后把兼容条目误当严格候选。
#>

function Test-VMateJsonProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Test-VMateIntegerValue {
    param([object]$Value)

    # JSON 数字在 Windows PowerShell 5.1 与 PowerShell 7 中可能分别落到
    # Int32/Int64；显式列出整数 CLR 类型，避免字符串 "4" 被强制转换后过关。
    return ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64])
}

function Assert-VMatePlatformTpm {
    param(
        [object]$Tpm,
        [string]$CpuVendor,
        [object]$Board,
        [string]$PlatformId
    )

    # TPM 是主板平台事实，而不是 Windows 启动器的运行时开关。即使 WHPX
    # 路线暂不接入 swtpm，也必须与 Linux 对共享目录采用同一套严格解释，
    # 防止被篡改的版本或前端组合进入持久 profile 摘要。
    $expectedFields = @(
        'capability',
        'supported',
        'implementation',
        'version',
        'emulation_frontend',
        'pcr_banks',
        'support_source_ref',
        'version_source_ref'
    )
    if ($null -eq $Tpm) {
        throw "平台 '$PlatformId' 的 tpm 不能为空。"
    }
    $actualFields = if ($Tpm -is [System.Collections.IDictionary]) {
        @($Tpm.Keys)
    } else {
        @($Tpm.PSObject.Properties.Name)
    }
    if ($actualFields.Count -ne $expectedFields.Count -or
        @($actualFields | Where-Object {
                $expectedFields -cnotcontains [string]$_
            }).Count -gt 0) {
        throw "平台 '$PlatformId' 的 tpm 字段集合不完整或包含未知字段。"
    }

    if ($Tpm.capability -isnot [string] -or
        @('none', 'firmware', 'discrete') -cnotcontains $Tpm.capability) {
        throw "平台 '$PlatformId' 的 tpm.capability 不在受控集合。"
    }
    if ($Tpm.supported -isnot [bool]) {
        throw "平台 '$PlatformId' 的 tpm.supported 必须是布尔值。"
    }
    if ($Tpm.implementation -isnot [string] -or
        @('none', 'intel-ptt', 'amd-ftpm', 'discrete-module') `
            -cnotcontains $Tpm.implementation) {
        throw "平台 '$PlatformId' 的 tpm.implementation 不在受控集合。"
    }
    if ($Tpm.version -isnot [string] -or
        @('none', '1.2', '2.0') -cnotcontains $Tpm.version) {
        throw "平台 '$PlatformId' 的 tpm.version 不在受控集合。"
    }
    if ($Tpm.emulation_frontend -isnot [string] -or
        @('none', 'tpm-tis', 'tpm-crb') `
            -cnotcontains $Tpm.emulation_frontend) {
        throw "平台 '$PlatformId' 的 tpm.emulation_frontend 不在受控集合。"
    }
    if ($Tpm.pcr_banks -isnot [System.Array]) {
        throw "平台 '$PlatformId' 的 tpm.pcr_banks 必须是 JSON 数组。"
    }
    $banks = @($Tpm.pcr_banks)
    $seenBanks = @{}
    foreach ($bank in $banks) {
        if ($bank -isnot [string] -or
            @('sha1', 'sha256') -cnotcontains $bank -or
            $seenBanks.ContainsKey([string]$bank)) {
            throw "平台 '$PlatformId' 的 tpm.pcr_banks 含无效或重复算法。"
        }
        $seenBanks[[string]$bank] = $true
    }
    $boardTpmHosts = switch ([string]$Board.subsystem_vendor) {
        '0x1043' { @('www.asus.com', 'dlcdnet.asus.com', 'dlcdnets.asus.com') }
        '0x1462' { @('www.msi.com', 'download-2.msi.com') }
        '0x1458' { @('www.gigabyte.com', 'download.gigabyte.com') }
        '0x1849' { @('www.asrock.com', 'download.asrock.com') }
        default { @() }
    }
    $cpuTpmHost = if ($CpuVendor -ceq 'AuthenticAMD') {
        'www.amd.com'
    } else {
        'www.intel.com'
    }
    foreach ($sourceField in @('support_source_ref', 'version_source_ref')) {
        $sourceValue = $Tpm.$sourceField
        $sourceUri = $null
        if ($sourceValue -isnot [string] -or
            -not [Uri]::TryCreate([string]$sourceValue,
                [UriKind]::Absolute, [ref]$sourceUri) -or
            $sourceUri.Scheme -cne 'https' -or
            $sourceUri.DnsSafeHost.ToLowerInvariant() -notin @(
                @($boardTpmHosts) + $cpuTpmHost)) {
            throw "平台 '$PlatformId' 的 tpm.$sourceField 必须是已注册厂商官方 HTTPS 来源。"
        }
    }
    if ($Tpm.support_source_ref -ceq $Tpm.version_source_ref) {
        throw "平台 '$PlatformId' 必须分别记录 TPM 支持与版本证据。"
    }

    if (-not $Tpm.supported) {
        if ($Tpm.capability -cne 'none' -or
            $Tpm.implementation -cne 'none' -or
            $Tpm.version -cne 'none' -or
            $Tpm.emulation_frontend -cne 'none' -or $banks.Count -ne 0) {
            throw "平台 '$PlatformId' 不支持 TPM 时必须使用完整的 none 组合。"
        }
        return
    }
    if (@($Tpm.capability, $Tpm.implementation, $Tpm.version,
            $Tpm.emulation_frontend) -ccontains 'none' -or
        $banks.Count -eq 0) {
        throw "平台 '$PlatformId' 支持 TPM 时版本、实现、前端和 PCR bank 必须完整。"
    }
    if ($Tpm.emulation_frontend -ceq 'tpm-crb' -and
        $Tpm.version -cne '2.0') {
        throw "平台 '$PlatformId' 的 tpm-crb 前端仅允许 TPM 2.0。"
    }
    if ($Tpm.version -ceq '1.2' -and
        ($banks.Count -ne 1 -or $banks[0] -cne 'sha1')) {
        throw "平台 '$PlatformId' 的 TPM 1.2 仅允许 sha1 PCR bank。"
    }

    $expectedFirmware = switch -CaseSensitive ($CpuVendor) {
        'AuthenticAMD' { 'amd-ftpm' }
        'GenuineIntel' { 'intel-ptt' }
        default { '' }
    }
    if ($Tpm.capability -ceq 'firmware' -and
        $Tpm.implementation -cne $expectedFirmware) {
        throw "平台 '$PlatformId' 的固件 TPM 实现与 CPU 厂商不一致。"
    }
    if ($Tpm.capability -ceq 'discrete' -and
        $Tpm.implementation -cne 'discrete-module') {
        throw "平台 '$PlatformId' 的独立 TPM 必须使用 discrete-module。"
    }
    if ($Tpm.implementation -ceq 'discrete-module' -and
        $Tpm.capability -cne 'discrete') {
        throw "平台 '$PlatformId' 的 discrete-module 只能对应独立 TPM。"
    }
}

function Assert-VMatePlatformShape {
    param([object]$Platform)

    foreach ($field in @('id', 'enabled', 'status', 'release_year', 'cpu', 'board',
            'memory', 'bios', 'system', 'devices', 'tpm', 'source_refs')) {
        if (-not (Test-VMateJsonProperty $Platform $field)) {
            throw "平台条目缺少字段 '$field'。"
        }
    }
    $platformId = [string]$Platform.id
    if ($platformId -notmatch '^[a-z0-9-]+$' -or $Platform.enabled -isnot [bool]) {
        throw "平台 ID 或 enabled 类型无效：'$platformId'。"
    }
    $status = [string]$Platform.status
    if ($status -notin @('supported', 'compatibility')) {
        throw "平台 '$platformId' 的 status 不在受控集合。"
    }
    if ($Platform.enabled -eq $true -and $status -ne 'supported') {
        throw "平台 '$platformId' 已启用但不是 supported，拒绝进入严格候选。"
    }
    Assert-VMatePlatformFacts -Platform $Platform -PlatformId $platformId
    $sources = @($Platform.source_refs)
    $allowedSourceHosts = @(
        'www.asus.com', 'dlcdnet.asus.com', 'dlcdnets.asus.com',
        'www.amd.com', 'www.intel.com', 'www.msi.com',
        'download-2.msi.com', 'www.gigabyte.com', 'download.gigabyte.com',
        'www.asrock.com', 'download.asrock.com'
    )
    $invalidSources = @($sources | Where-Object {
            $uri = $null
            $_ -isnot [string] -or
            -not [Uri]::TryCreate([string]$_, [UriKind]::Absolute,
                [ref]$uri) -or $uri.Scheme -cne 'https' -or
            $uri.DnsSafeHost.ToLowerInvariant() -notin $allowedSourceHosts
        })
    if ($sources.Count -lt 3 -or
        @($sources | Select-Object -Unique).Count -ne $sources.Count -or
        $invalidSources.Count -gt 0) {
        throw "平台 '$platformId' 缺少 CPU/主板厂商官方 HTTPS 来源。"
    }
    $cpuDomain = if ([string]$Platform.cpu.vendor_id -eq 'AuthenticAMD') {
        'amd.com'
    } else {
        'intel.com'
    }
    if (@($sources | Where-Object { [string]$_ -like "*$cpuDomain*" }).Count -eq 0) {
        throw "平台 '$platformId' 缺少 CPU 厂商型号规格。"
    }
    $boardDomain = switch ([string]$Platform.board.subsystem_vendor) {
        '0x1043' { 'asus.com' }
        '0x1462' { 'msi.com' }
        '0x1458' { 'gigabyte.com' }
        '0x1849' { 'asrock.com' }
        default { '' }
    }
    if (-not $boardDomain -or
        @($sources | Where-Object {
                [string]$_ -like "*$boardDomain*"
            }).Count -eq 0) {
        throw "平台 '$platformId' 缺少对应主板厂商规格来源。"
    }
    foreach ($field in @('qemu_arg', 'vendor_id', 'name', 'part', 'socket',
            'cores', 'threads', 'smbios')) {
        if (-not (Test-VMateJsonProperty $Platform.cpu $field)) {
            throw "平台 '$platformId' 的 cpu 缺少 '$field'。"
        }
    }
    foreach ($field in @('cores', 'threads')) {
        $value = $Platform.cpu.$field
        if (-not (Test-VMateIntegerValue $value) -or [int64]$value -lt 1) {
            throw "平台 '$platformId' 的 cpu.$field 必须是正整数。"
        }
    }
    if ([int64]$Platform.cpu.threads -lt [int64]$Platform.cpu.cores) {
        throw "平台 '$platformId' 的线程数不能少于核心数。"
    }
    Assert-VMatePlatformTpm -Tpm $Platform.tpm `
        -CpuVendor ([string]$Platform.cpu.vendor_id) -Board $Platform.board `
        -PlatformId $platformId
    foreach ($field in @('manufacturer', 'product', 'family', 'version',
            'subsystem_vendor', 'subsystem_device', 'pcie_generation',
            'dimm_slots', 'max_memory_gib')) {
        if (-not (Test-VMateJsonProperty $Platform.board $field)) {
            throw "平台 '$platformId' 的 board 缺少 '$field'。"
        }
    }
    $expectedPlatformId = Get-VMateExpectedPlatformId -Cpu $Platform.cpu `
        -Board $Platform.board
    if ($platformId -cne $expectedPlatformId) {
        throw "平台 '$platformId' 与 CPU/主板组合不一致，应为 '$expectedPlatformId'。"
    }
    foreach ($field in @('family', 'characteristics')) {
        if (-not (Test-VMateJsonProperty $Platform.cpu.smbios $field) -or
            [string]$Platform.cpu.smbios.$field -notmatch
                '^0x[0-9A-Fa-f]{2,4}$') {
            throw "平台 '$platformId' 的 cpu.smbios.$field 无效。"
        }
    }
    $characteristics = [Convert]::ToInt32(
        ([string]$Platform.cpu.smbios.characteristics).Substring(2), 16)
    $hasHardwareThreads = ($characteristics -band 0x0010) -ne 0
    if (([int64]$Platform.cpu.threads -gt [int64]$Platform.cpu.cores) -ne
        $hasHardwareThreads) {
        throw "平台 '$platformId' 的 SMBIOS Hardware Thread 位与核线程数矛盾。"
    }
    $expectedFamily = if ([string]$Platform.cpu.name -like '*Ryzen *') {
        0x006B
    } elseif ([string]$Platform.cpu.name -like '*Core(TM) i3-*') {
        0x00CE
    } elseif ([string]$Platform.cpu.name -like '*Core(TM) i5-*') {
        0x00CD
    } else {
        $null
    }
    if ($null -ne $expectedFamily -and
        [Convert]::ToInt32(
            ([string]$Platform.cpu.smbios.family).Substring(2), 16) -ne
            $expectedFamily) {
        throw "平台 '$platformId' 的 SMBIOS family 与 CPU 系列不一致。"
    }
    foreach ($field in @('type', 'channels', 'max_mts', 'allowed_mts',
            'voltage_mv', 'rank', 'module_mib', 'allowed_total_mib')) {
        if (-not (Test-VMateJsonProperty $Platform.memory $field)) {
            throw "平台 '$platformId' 的 memory 缺少 '$field'。"
        }
    }
    foreach ($field in @('pcie_generation', 'dimm_slots', 'max_memory_gib')) {
        $value = $Platform.board.$field
        if (-not (Test-VMateIntegerValue $value) -or [int64]$value -lt 1) {
            throw "平台 '$platformId' 的 board.$field 必须是正整数。"
        }
    }
    $memory = $Platform.memory
    if ($memory.type -isnot [string] -or
        [string]$memory.type -notin @('DDR3', 'DDR4')) {
        throw "平台 '$platformId' 的 memory.type 不受支持。"
    }
    foreach ($field in @('channels', 'max_mts', 'voltage_mv', 'rank')) {
        $value = $memory.$field
        if (-not (Test-VMateIntegerValue $value) -or [int64]$value -lt 1) {
            throw "平台 '$platformId' 的 memory.$field 必须是正整数。"
        }
    }
    $channels = [int]$memory.channels
    $dimmSlots = [int]$Platform.board.dimm_slots
    if ($channels -notin @(1, 2, 4) -or $channels -gt $dimmSlots) {
        throw "平台 '$platformId' 的内存通道数与 DIMM 槽位不一致。"
    }
    $allowedMts = @($memory.allowed_mts)
    if ($allowedMts.Count -eq 0) {
        throw "平台 '$platformId' 的 memory.allowed_mts 不能为空。"
    }
    foreach ($rate in $allowedMts) {
        if (-not (Test-VMateIntegerValue $rate) -or [int64]$rate -lt 1 -or
            [int64]$rate -gt [int64]$memory.max_mts) {
            throw "平台 '$platformId' 的允许内存速率无效。"
        }
    }
    $moduleSizes = @($memory.module_mib)
    $allowedTotals = @($memory.allowed_total_mib)
    if ($moduleSizes.Count -eq 0 -or $allowedTotals.Count -eq 0) {
        throw "平台 '$platformId' 的内存物料或总容量列表不能为空。"
    }
    $possibleTotals = @{}
    foreach ($moduleSize in $moduleSizes) {
        if (-not (Test-VMateIntegerValue $moduleSize) -or
            [int64]$moduleSize -lt 1) {
            throw "平台 '$platformId' 的 memory.module_mib 无效。"
        }
        for ($count = 1; $count -le $dimmSlots; $count++) {
            $possibleTotals[[string]([int64]$moduleSize * $count)] = $true
        }
    }
    $maximumMemoryMiB = [int64]$Platform.board.max_memory_gib * 1024
    foreach ($total in $allowedTotals) {
        if (-not (Test-VMateIntegerValue $total) -or [int64]$total -lt 1 -or
            -not $possibleTotals.ContainsKey([string][int64]$total) -or
            [int64]$total -gt $maximumMemoryMiB) {
            throw "平台 '$platformId' 的允许总容量无法由 DIMM 物料和槽位组成。"
        }
    }
    foreach ($field in @('product', 'family', 'chassis_type')) {
        if (-not (Test-VMateJsonProperty $Platform.system $field)) {
            throw "平台 '$platformId' 的 system 缺少 '$field'。"
        }
    }
    foreach ($device in @('chipset', 'root_port', 'xhci', 'nvme', 'nic', 'audio')) {
        if (-not (Test-VMateJsonProperty $Platform.devices $device)) {
            throw "平台 '$platformId' 的 devices 缺少 '$device'。"
        }
    }
    foreach ($field in @('codec_id', 'codec_revision', 'codec_subsystem_id',
            'identity_fidelity', 'controller_pci_vendor', 'controller_pci_device')) {
        if (-not (Test-VMateJsonProperty $Platform.devices.audio $field)) {
            throw "平台 '$platformId' 的 devices.audio 缺少 '$field'。"
        }
    }
    if ([string]$Platform.devices.audio.identity_fidelity -ne
        'protocol_identity_only') {
        throw "平台 '$platformId' 的音频身份边界不是 protocol_identity_only。"
    }
    foreach ($field in @('pci_vendor', 'pci_device', 'attachment',
            'board_nic_state', 'subsystem_vendor', 'subsystem_device', 'mac_oui')) {
        if (-not (Test-VMateJsonProperty $Platform.devices.nic $field)) {
            throw "平台 '$platformId' 的 devices.nic 缺少 '$field'。"
        }
    }
}

function Read-VMateHardwareManifest {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到共享硬件清单：$Path"
    }
    try {
        $manifest = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "共享硬件清单不是有效 JSON：$Path；$($_.Exception.Message)"
    }
    if (-not (Test-VMateJsonProperty $manifest 'schema_version') -or
        -not (Test-VMateIntegerValue $manifest.schema_version) -or
        [int]$manifest.schema_version -ne 1) {
        throw "不支持的硬件清单 schema_version，仅接受 1：$Path"
    }
    if (-not (Test-VMateJsonProperty $manifest 'catalog_revision') -or
        $manifest.catalog_revision -isnot [string] -or
        -not [string]$manifest.catalog_revision) {
        throw "共享硬件清单缺少 catalog_revision：$Path"
    }
    if (-not (Test-VMateJsonProperty $manifest 'platforms') -or
        @($manifest.platforms).Count -eq 0) {
        throw "共享硬件清单没有 platforms：$Path"
    }
    if (-not (Test-VMateJsonProperty $manifest 'defaults')) {
        throw "共享硬件清单缺少 defaults：$Path"
    }
    Assert-VMatePositiveIntegerFields $manifest.defaults `
        @('vcpus', 'memory_total_mib') '共享硬件清单.defaults'
    Assert-VMateManifestFidelity -Manifest $manifest
    $seen = @{}
    $enabledCount = 0
    foreach ($platform in @($manifest.platforms)) {
        Assert-VMatePlatformShape -Platform $platform
        $platformId = [string]$platform.id
        if ($seen.ContainsKey($platformId)) {
            throw "共享硬件清单含重复平台 ID：$platformId"
        }
        $seen[$platformId] = $true
        if ($platform.enabled -eq $true) {
            $enabledCount++
        }
    }
    if ($enabledCount -eq 0) {
        throw '共享硬件清单没有 enabled + supported 平台。'
    }
    return $manifest
}

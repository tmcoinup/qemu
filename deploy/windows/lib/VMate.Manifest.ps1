#Requires -Version 5.1

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

    # 布局同时钉住 Linux 与 Windows 实际 Q35 枚举结果。这里不是声称目标主板
    # 也使用这些地址，而是防止清单说明与当前启动器悄悄分叉。
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

function Assert-VMatePlatformShape {
    param([object]$Platform)

    foreach ($field in @('id', 'enabled', 'status', 'release_year', 'cpu', 'board',
            'memory', 'bios', 'system', 'devices', 'source_refs')) {
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
    $sources = @($Platform.source_refs)
    if ($sources.Count -eq 0 -or @($sources | Where-Object {
                [string]$_ -notmatch '^https://'
            }).Count -gt 0) {
        throw "平台 '$platformId' 缺少可审计的 HTTPS 来源。"
    }
    foreach ($field in @('qemu_arg', 'vendor_id', 'name', 'cores', 'threads')) {
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
    foreach ($field in @('manufacturer', 'product', 'family', 'version',
            'subsystem_vendor', 'subsystem_device', 'pcie_generation',
            'dimm_slots', 'max_memory_gib')) {
        if (-not (Test-VMateJsonProperty $Platform.board $field)) {
            throw "平台 '$platformId' 的 board 缺少 '$field'。"
        }
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
        [int]$manifest.schema_version -ne 1) {
        throw "不支持的硬件清单 schema_version，仅接受 1：$Path"
    }
    if (-not (Test-VMateJsonProperty $manifest 'catalog_revision') -or
        -not [string]$manifest.catalog_revision) {
        throw "共享硬件清单缺少 catalog_revision：$Path"
    }
    if (-not (Test-VMateJsonProperty $manifest 'platforms') -or
        @($manifest.platforms).Count -eq 0) {
        throw "共享硬件清单没有 platforms：$Path"
    }
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

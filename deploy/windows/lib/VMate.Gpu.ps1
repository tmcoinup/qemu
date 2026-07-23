#Requires -Version 5.1

<#
.SYNOPSIS
    校验共享 GPU 标签目录的稳定身份字段。

.DESCRIPTION
    当前 Windows/WHPX 路线没有实现物理 GPU 直通。旧通用标签只用于历史
    profile 回读；新建 profile 使用经过审计的 AIB 板卡原子身份。AIB 的真实
    subsystem 只进入受控用户态投影，virtio 物理载体使用独立保留编号。
#>

. (Join-Path $PSScriptRoot 'VMate.Gpu.Contracts.ps1')

function Get-VMateGpuLabel {
    param([object]$Gpu)

    if ($null -eq $Gpu) {
        throw 'GPU 标签条目不能为空。'
    }
    $manufacturer = ([string]$Gpu.manufacturer).Trim()
    $model = ([string]$Gpu.model).Trim()
    if ($model.StartsWith($manufacturer + ' ',
            [System.StringComparison]::OrdinalIgnoreCase)) {
        return $model
    }
    return ($manufacturer + ' ' + $model).Trim()
}

function Assert-VMateGpuComponent {
    param([object]$Gpu)

    $fields = @(
        'id', 'enabled', 'selection_weight', 'manufacturer', 'model',
        'pci_vendor', 'pci_device', 'ram_mb', 'bios', 'revision',
        'memory_type', 'memory_bus_width_bits', 'base_clock_khz',
        'boost_clock_khz', 'memory_clock_khz', 'sli_supported',
        'identity_fidelity'
    )
    Assert-VMatePolicyFields $Gpu $fields "GPU 标签 '$($Gpu.id)'"
    if ($Gpu.enabled -isnot [bool] -or
        -not (Test-VMatePolicyInteger $Gpu.selection_weight) -or
        [int64]$Gpu.selection_weight -lt 0 -or
        [int64]$Gpu.selection_weight -gt 100 -or
        ($Gpu.enabled -eq $true -and [int64]$Gpu.selection_weight -lt 1) -or
        [string]$Gpu.identity_fidelity -cne 'label_only_out_of_scope') {
        throw "GPU 标签 '$($Gpu.id)' 的启用状态、权重或证据边界无效。"
    }
    foreach ($field in @('manufacturer', 'model', 'bios', 'revision',
            'memory_type')) {
        if ($Gpu.$field -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$Gpu.$field)) {
            throw "GPU 标签 '$($Gpu.id)' 的 $field 必须是非空字符串。"
        }
    }
    foreach ($field in @('pci_vendor', 'pci_device')) {
        if ($Gpu.$field -isnot [string] -or
            [string]$Gpu.$field -cnotmatch '^0x[0-9A-Fa-f]{4}$') {
            throw "GPU 标签 '$($Gpu.id)' 的 $field 不是四位十六进制 PCI ID。"
        }
    }
    foreach ($field in @('ram_mb', 'memory_bus_width_bits',
            'base_clock_khz', 'boost_clock_khz', 'memory_clock_khz')) {
        if (-not (Test-VMatePolicyInteger $Gpu.$field) -or
            [int64]$Gpu.$field -lt 1) {
            throw "GPU 标签 '$($Gpu.id)' 的 $field 必须是正整数。"
        }
    }
    if (-not (Test-VMatePolicyInteger $Gpu.sli_supported) -or
        [int64]$Gpu.sli_supported -ne 0) {
        throw "GPU 标签 '$($Gpu.id)' 的 sli_supported 必须保持旧目录 ABI 整数 0。"
    }
    if ((Get-VMateGpuLabel $Gpu) -match '[,\r\n]') {
        throw "GPU 标签 '$($Gpu.id)' 含不允许的控制符或分隔符。"
    }
}

function Assert-VMateGpuBoardComponent {
    param([object]$Gpu)

    $fields = @(
        'id', 'enabled', 'selection_weight', 'release_year', 'manufacturer',
        'board_partner', 'model', 'part_number', 'pci_vendor', 'pci_device',
        'subsystem_vendor', 'subsystem_device', 'carrier_vendor',
        'carrier_device', 'ram_mb', 'bios', 'revision', 'memory_type',
        'memory_bus_width_bits', 'base_clock_khz', 'boost_clock_khz',
        'memory_clock_khz', 'sli_supported', 'verification_status',
        'identity_fidelity', 'serial_exposed', 'source_refs',
        'identity_source_refs'
    )
    Assert-VMatePolicyFields $Gpu $fields "AIB GPU '$($Gpu.id)'"
    $id = [string]$Gpu.id
    $contract = Get-VMateGpuBoardContract $id
    if ($null -eq $contract) {
        throw "AIB GPU '$id' 没有已审计板卡契约。"
    }
    if ($Gpu.enabled -isnot [bool] -or $Gpu.enabled -ne $true -or
        -not (Test-VMatePolicyInteger $Gpu.selection_weight) -or
        -not (Test-VMatePolicyInteger $Gpu.release_year) -or
        [int]$Gpu.selection_weight -ne [int]$contract.Meta[0] -or
        [int]$Gpu.release_year -ne [int]$contract.Meta[1] -or
        $Gpu.serial_exposed -ne $false -or
        [string]$Gpu.identity_fidelity -cne
            'audited_aib_bundle_shallow_user_projection_no_passthrough') {
        throw "AIB GPU '$id' 的状态、权重、年份或证据边界无效。"
    }
    $text = @([string]$Gpu.manufacturer, [string]$Gpu.board_partner,
        [string]$Gpu.model, [string]$Gpu.part_number, [string]$Gpu.bios,
        [string]$Gpu.revision, [string]$Gpu.memory_type,
        [string]$Gpu.verification_status)
    if (($text -join "`n") -cne (@($contract.Text) -join "`n")) {
        throw "AIB GPU '$id' 的品牌、型号、料号、VBIOS 或证据状态不匹配。"
    }
    $pci = @('pci_vendor', 'pci_device', 'subsystem_vendor',
        'subsystem_device', 'carrier_vendor', 'carrier_device') |
        ForEach-Object {
            if ($Gpu.$_ -isnot [string] -or
                [string]$Gpu.$_ -cnotmatch '^0x[0-9A-Fa-f]{4}$') {
                throw "AIB GPU '$id' 的 $_ 不是四位十六进制 PCI ID。"
            }
            ([string]$Gpu.$_).ToUpperInvariant()
        }
    if (($pci -join ':') -cne (@($contract.Pci) -join ':')) {
        throw "AIB GPU '$id' 的主设备、subsystem 或 virtio 载体被交叉拼接。"
    }
    $numeric = @('ram_mb', 'memory_bus_width_bits', 'base_clock_khz',
        'boost_clock_khz', 'memory_clock_khz', 'sli_supported') |
        ForEach-Object {
            if (-not (Test-VMatePolicyInteger $Gpu.$_)) {
                throw "AIB GPU '$id' 的 $_ 必须是 JSON 整数。"
            }
            [int64]$Gpu.$_
        }
    if (($numeric -join ':') -cne (@($contract.Numeric) -join ':')) {
        throw "AIB GPU '$id' 的显存或时钟规格与已审计板卡不一致。"
    }
    if ((Get-VMateGpuLabel $Gpu) -match '[,\r\n]') {
        throw "AIB GPU '$id' 的稳定标签含控制符或分隔符。"
    }
    Assert-VMatePolicySources $Gpu.source_refs $contract.SourceHosts `
        "AIB GPU '$id' 的型号来源" ([int]$contract.SourceMinimum)
    Assert-VMatePolicySources $Gpu.identity_source_refs `
        $contract.IdentityHosts "AIB GPU '$id' 的身份来源"
}

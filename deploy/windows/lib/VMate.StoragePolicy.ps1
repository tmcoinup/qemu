#Requires -Version 5.1

<#
.SYNOPSIS
    校验精确 512GB NVMe 目录并生成符合厂商形态的合成序列号。

.DESCRIPTION
    存储身份按型号作为原子契约校验。容量、料号、固件、PCI/OUI、链路和
    序列号形态不能跨厂商拼接；生成器只产生符合已观察格式的合成值，不复制
    任何真实设备序列号。
#>

function Get-VMateStorageContract {
    param([string]$Id)

    $knownIds = @(
        'samsung-970-pro-512gb',
        'intel-760p-512gb',
        'wd-pc-sn730-512gb',
        'kioxia-xg6-512gb'
    )
    if ($Id -cnotin $knownIds) {
        return $null
    }
    $contracts = @{
        'samsung-970-pro-512gb' = @{
            SelectionWeight = 6
            ReleaseYear = 2018
            Facts = @('Samsung', 'MZ-V7P512BW',
                'Samsung SSD 970 PRO 512GB', '1B2QEXP7', 512110190592L)
            Pci = @('0X144D', '0XA808', '0X144D', '0XA801')
            Nvme = @(3, 4, '00:25:38')
            Serial = @('samsung-970-pro',
                '^S[A-Z0-9]{3}N[A-Z0-9]{10}$', 15,
                'observed_multi_sample_shape_synthetic_value')
            SourceHosts = @('www.samsung.com', 'semiconductor.samsung.com')
            IdentityHosts = @('bbs.archlinux.org', 'raw.githubusercontent.com')
        }
        'intel-760p-512gb' = @{
            SelectionWeight = 5
            ReleaseYear = 2018
            Facts = @('Intel', 'SSDPEKKW512G8', 'INTEL SSDPEKKW512G8',
                '001C', 512110190592L)
            Pci = @('0X8086', '0XF1A6', '0X8086', '0X390B')
            Nvme = @(3, 4, '5C:D2:E4')
            Serial = @('intel-760p', '^BTHH[A-Z0-9]{8}512D$', 16,
                'observed_multi_sample_shape_synthetic_value')
            SourceHosts = @('www.intel.com', 'cdrdv2-public.intel.com')
            IdentityHosts = @('gist.github.com', 'bugs.debian.org')
        }
        'wd-pc-sn730-512gb' = @{
            SelectionWeight = 6
            ReleaseYear = 2019
            Facts = @('Western Digital', 'SDBPNTY-512G-1027',
                'WDC PC SN730 SDBPNTY-512G-1027', '11110000',
                512110190592L)
            Pci = @('0X15B7', '0X5006', '0X15B7', '0X5006')
            Nvme = @(3, 4, '00:1B:44')
            Serial = @('wd-pc-sn730', '^[A-Z0-9]{12}$', 12,
                'observed_vendor_variable_ascii_shape_synthetic_value')
            SourceHosts = @('documents.westerndigital.com')
            IdentityHosts = @('forum.manjaro.org', 'bbs.archlinux.org',
                'lists.debian.org')
        }
        'kioxia-xg6-512gb' = @{
            SelectionWeight = 4
            ReleaseYear = 2018
            Facts = @('KIOXIA', 'KXG60ZNV512G',
                'KXG60ZNV512G KIOXIA', 'AGHA4101', 512110190592L)
            Pci = @('0X1179', '0X011A', '0X1179', '0X0001')
            Nvme = @(3, 4, '8C:E3:8E')
            Serial = @('kioxia-xg6', '^[A-Z0-9]{12}$', 12,
                'observed_multi_sample_shape_synthetic_value')
            SourceHosts = @('www.kioxia.com', 'europe.kioxia.com')
            IdentityHosts = @('www.reddit.com', 'bugs.debian.org',
                'mis.sapuraindustrial.com.my')
        }
    }
    return $contracts[$Id]
}

function Assert-VMateStorageComponent {
    param([object]$Storage)

    $fields = @('id', 'enabled', 'selection_weight', 'release_year',
        'manufacturer', 'part_number', 'identity_profile', 'model', 'firmware',
        'raw_bytes', 'verification_status', 'identity_fidelity',
        'serial_policy', 'pci', 'nvme', 'source_refs', 'identity_source_refs')
    Assert-VMatePolicyFields $Storage $fields "SSD 部件 '$($Storage.id)'"
    $id = [string]$Storage.id
    $contract = Get-VMateStorageContract $id
    if ($null -eq $contract) {
        throw "SSD 部件 '$id' 没有对应的 QEMU identity profile。"
    }
    if ($Storage.enabled -isnot [bool] -or $Storage.enabled -ne $true -or
        -not (Test-VMatePolicyInteger $Storage.selection_weight) -or
        [int]$Storage.selection_weight -ne
            [int]$contract.SelectionWeight -or
        -not (Test-VMatePolicyInteger $Storage.release_year) -or
        [int]$Storage.release_year -ne [int]$contract.ReleaseYear -or
        -not (Test-VMatePolicyInteger $Storage.raw_bytes) -or
        [int64]$Storage.raw_bytes -ne 512110190592L -or
        [string]$Storage.identity_profile -cne $id -or
        [string]$Storage.verification_status -cne
            'vendor_document_and_observed_identity_reference' -or
        [string]$Storage.identity_fidelity -cne
            'audited_register_bundle_synthetic_serial') {
        throw "SSD 部件 '$id' 的状态、权重、年份、容量或证据边界无效。"
    }
    $facts = @([string]$Storage.manufacturer, [string]$Storage.part_number,
        [string]$Storage.model, [string]$Storage.firmware,
        [int64]$Storage.raw_bytes)
    if (($facts -join "`n") -cne (@($contract.Facts) -join "`n")) {
        throw "SSD 部件 '$id' 的厂商、料号、型号或固件不匹配。"
    }

    Assert-VMatePolicyFields $Storage.pci @('vendor', 'device',
        'subsystem_vendor', 'subsystem_device') "SSD '$id' 的 pci"
    $pci = @('vendor', 'device', 'subsystem_vendor', 'subsystem_device') |
        ForEach-Object { ([string]$Storage.pci.$_).ToUpperInvariant() }
    if (($pci -join ':') -cne (@($contract.Pci) -join ':')) {
        throw "SSD 部件 '$id' 的 PCI 身份与 QEMU identity profile 不一致。"
    }

    Assert-VMatePolicyFields $Storage.nvme @('pcie_generation', 'lanes',
        'ieee_oui', 'subnqn_template', 'nqn_fidelity') "SSD '$id' 的 nvme"
    if (-not (Test-VMatePolicyInteger $Storage.nvme.pcie_generation) -or
        -not (Test-VMatePolicyInteger $Storage.nvme.lanes) -or
        [int]$Storage.nvme.pcie_generation -ne [int]$contract.Nvme[0] -or
        [int]$Storage.nvme.lanes -ne [int]$contract.Nvme[1] -or
        [string]$Storage.nvme.ieee_oui -cne [string]$contract.Nvme[2] -or
        [string]$Storage.nvme.subnqn_template -cne
            'nqn.2014-08.org.nvmexpress:uuid:{uuid}' -or
        [string]$Storage.nvme.nqn_fidelity -cne
            'standards_compliant_synthetic_uuid') {
        throw "SSD 部件 '$id' 的链路、OUI 或 NQN 组合无效。"
    }

    Assert-VMatePolicyFields $Storage.serial_policy @('kind', 'pattern',
        'length', 'format_fidelity') "SSD '$id' 的 serial_policy"
    $serial = @([string]$Storage.serial_policy.kind,
        [string]$Storage.serial_policy.pattern,
        [int]$Storage.serial_policy.length,
        [string]$Storage.serial_policy.format_fidelity)
    if (-not (Test-VMatePolicyInteger $Storage.serial_policy.length) -or
        ($serial -join "`n") -cne (@($contract.Serial) -join "`n")) {
        throw "SSD 部件 '$id' 的序列号策略与 QEMU 校验器不一致。"
    }
    try {
        [void][Regex]::new([string]$Storage.serial_policy.pattern)
    } catch {
        throw "SSD 部件 '$id' 的序列号正则无效。"
    }
    Assert-VMatePolicySources $Storage.source_refs $contract.SourceHosts `
        "SSD '$id' 的官方来源"
    Assert-VMatePolicySources $Storage.identity_source_refs `
        $contract.IdentityHosts "SSD '$id' 的身份来源"
}

function Assert-VMateComponentSerial {
    param(
        [object]$Component,
        [string]$Serial,
        [string]$Kind
    )

    $policy = $Component.serial_policy
    if ($Serial -isnot [string] -or
        $Serial.Length -ne [int]$policy.length -or
        $Serial -cnotmatch [string]$policy.pattern) {
        throw "$Kind '$($Component.id)' 的序列号不符合目录策略。"
    }
    $payload = switch ([string]$policy.kind) {
        # index 4 的 N 是 Samsung 固定格式位，只检查两侧可变负载。
        'samsung-970-pro' {
            $Serial.Substring(1, 3) + $Serial.Substring(5, 10)
        }
        'intel-760p' { $Serial.Substring(4, 8) }
        default { $Serial }
    }
    if ($payload -cmatch '^(?:0+|F+|N+)$') {
        throw "$Kind '$($Component.id)' 的序列号不能使用占位值。"
    }
}

function New-VMateStorageSerial {
    param([object]$Storage)

    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $serial = switch ([string]$Storage.serial_policy.kind) {
        'samsung-970-pro' {
            'S' + (New-VMatePolicyRandomText 3 $alphabet) + 'N' +
                (New-VMatePolicyRandomText 10 $alphabet)
        }
        'intel-760p' {
            'BTHH' + (New-VMatePolicyRandomText 8 $alphabet) + '512D'
        }
        'wd-pc-sn730' {
            New-VMatePolicyRandomText 12 $alphabet
        }
        'kioxia-xg6' {
            New-VMatePolicyRandomText 12 $alphabet
        }
        default { throw "未知 SSD 序列号策略：$($Storage.serial_policy.kind)" }
    }
    Assert-VMateComponentSerial $Storage $serial 'SSD'
    return $serial
}

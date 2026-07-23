#Requires -Version 5.1

<#
.SYNOPSIS
    保存 Windows 共享 AIB GPU 目录的固定身份契约。

.DESCRIPTION
    契约数据与字段校验实现分离，便于按芯片扩展多个真实板卡品牌。集合校验会
    拒绝缺失/额外 ID、重复料号、重复完整 subsystem 或重复 virtio carrier，
    并验证每个 PCI 主芯片的不同板卡品牌数量。
#>

function Get-VMateGpuBoardContracts {
    return @{
        'asus-ph-gtx1050ti-4g' = @{
            Meta = @(6, 2016)
            Text = @('NVIDIA', 'ASUS',
                'NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)',
                'PH-GTX1050TI-4G', 'Version 86.07.42.00.96', '0xA1',
                'GDDR5', 'official_model_and_observed_vbios_identity')
            Pci = @('0X10DE', '0X1C82', '0X1043', '0X8613',
                '0X1AF4', '0XA101')
            Numeric = @(4096, 128, 1291000, 1392000, 3504000, 0)
            SourceHosts = @('www.asus.com')
            SourceMinimum = 2
            IdentityHosts = @('www.techpowerup.com', 'forum.ubuntuusers.de')
        }
        'colorful-igame-gtx1050ti-u-4gd5' = @{
            Meta = @(5, 2016)
            Text = @('NVIDIA', 'Colorful',
                'NVIDIA GeForce GTX 1050 Ti (Colorful iGame U)',
                'iGame GTX1050Ti U-4GD5', 'Version 86.07.39.40.12', '0xA1',
                'GDDR5', 'official_model_and_observed_unverified_rom')
            Pci = @('0X10DE', '0X1C82', '0X7377', '0X0000',
                '0X1AF4', '0XA102')
            Numeric = @(4096, 128, 1380000, 1493000, 3504000, 0)
            SourceHosts = @('www.colorful.cn')
            SourceMinimum = 1
            IdentityHosts = @('modbios.io', 'www.techpowerup.com')
        }
        'galax-gt1030-exoc-white' = @{
            Meta = @(5, 2017)
            Text = @('NVIDIA', 'GALAX',
                'NVIDIA GeForce GT 1030 (GALAX EXOC White)',
                '30NPH4HVQ5EW', 'Version 86.08.0C.00.2B', '0xA1',
                'GDDR5',
                'official_model_and_observed_reference_subsystem_rom')
            Pci = @('0X10DE', '0X1D01', '0X10DE', '0X11C7',
                '0X1AF4', '0XA103')
            Numeric = @(2048, 64, 1253000, 1506000, 3004000, 0)
            SourceHosts = @('www.galax.com')
            SourceMinimum = 2
            IdentityHosts = @('www.techpowerup.com', 'eshop.macsales.com')
        }
        'asus-gt1030-sl-2g-brk' = @{
            Meta = @(6, 2017)
            Text = @('NVIDIA', 'ASUS',
                'NVIDIA GeForce GT 1030 (ASUS Silent)', 'GT1030-SL-2G-BRK',
                'Version 86.08.0C.00.1A', '0xA1', 'GDDR5',
                'official_model_and_observed_vbios_identity')
            Pci = @('0X10DE', '0X1D01', '0X1043', '0X85F4',
                '0X1AF4', '0XA104')
            Numeric = @(2048, 64, 1228000, 1468000, 3004000, 0)
            SourceHosts = @('www.asus.com'); SourceMinimum = 1
            IdentityHosts = @('modbios.io', 'forum.archlinux.de')
        }
        'msi-gt1030-2g-lp-ocv1' = @{
            Meta = @(6, 2017)
            Text = @('NVIDIA', 'MSI',
                'NVIDIA GeForce GT 1030 (MSI LP OCV1)',
                'GeForce GT 1030 2G LP OCV1', 'Version 86.08.0C.00.18',
                '0xA1', 'GDDR5',
                'official_model_and_observed_vbios_identity')
            Pci = @('0X10DE', '0X1D01', '0X1462', '0X8C98',
                '0X1AF4', '0XA105')
            Numeric = @(2048, 64, 1266000, 1519000, 3004000, 0)
            SourceHosts = @('www.msi.com', 'storage-asset.msi.com')
            SourceMinimum = 2
            IdentityHosts = @('modbios.io', 'gpumagick.com')
        }
        'asus-gtx750ti-oc-2gd5' = @{
            Meta = @(6, 2014)
            Text = @('NVIDIA', 'ASUS',
                'NVIDIA GeForce GTX 750 Ti (ASUS OC)', 'GTX750TI-OC-2GD5',
                'Version 82.07.32.00.20', '0xA2', 'GDDR5',
                'official_model_and_observed_vbios_identity')
            Pci = @('0X10DE', '0X1380', '0X1043', '0X84BB',
                '0X1AF4', '0XA106')
            Numeric = @(2048, 128, 1072000, 1150000, 2700000, 0)
            SourceHosts = @('www.asus.com'); SourceMinimum = 1
            IdentityHosts = @('www.techpowerup.com', 'gpumagick.com')
        }
        'msi-n750ti-2gd5-oc' = @{
            Meta = @(6, 2014)
            Text = @('NVIDIA', 'MSI',
                'NVIDIA GeForce GTX 750 Ti (MSI OC)', 'N750Ti-2GD5/OC',
                'Version 82.07.25.00.1F', '0xA2', 'GDDR5',
                'official_model_and_observed_unverified_rom')
            Pci = @('0X10DE', '0X1380', '0X1462', '0X8A9B',
                '0X1AF4', '0XA107')
            Numeric = @(2048, 128, 1059000, 1137000, 2700000, 0)
            SourceHosts = @('us.msi.com'); SourceMinimum = 1
            IdentityHosts = @('modbios.io', 'forum.proxmox.com')
        }
        'gigabyte-gv-n75toc-2gi' = @{
            Meta = @(6, 2014)
            Text = @('NVIDIA', 'Gigabyte',
                'NVIDIA GeForce GTX 750 Ti (Gigabyte OC)',
                'GV-N75TOC-2GI', 'Version 82.07.55.00.05', '0xA2',
                'GDDR5', 'official_model_and_observed_unverified_rom')
            Pci = @('0X10DE', '0X1380', '0X1458', '0X362D',
                '0X1AF4', '0XA108')
            Numeric = @(2048, 128, 1033000, 1111000, 2700000, 0)
            SourceHosts = @('www.gigabyte.com'); SourceMinimum = 1
            IdentityHosts = @('modbios.io', 'forum.ubuntuusers.de')
        }
        'evga-02g-p4-6150-kr' = @{
            Meta = @(4, 2016)
            Text = @('NVIDIA', 'EVGA',
                'NVIDIA GeForce GTX 1050 (EVGA Gaming)', '02G-P4-6150-KR',
                'Version 86.07.39.00.50', '0xA1', 'GDDR5',
                'official_model_and_observed_unverified_rom')
            Pci = @('0X10DE', '0X1C81', '0X3842', '0X6150',
                '0X1AF4', '0XA109')
            Numeric = @(2048, 128, 1354000, 1455000, 3504000, 0)
            SourceHosts = @('www.evga.com'); SourceMinimum = 1
            IdentityHosts = @('modbios.io', 'forums.libretro.com')
        }
        'msi-gtx1050-gaming-x-2g' = @{
            Meta = @(6, 2016)
            Text = @('NVIDIA', 'MSI',
                'NVIDIA GeForce GTX 1050 (MSI Gaming X)', 'G1050GX2',
                'Version 86.07.39.00.70', '0xA1', 'GDDR5',
                'official_model_and_observed_unverified_rom')
            Pci = @('0X10DE', '0X1C81', '0X1462', '0X3354',
                '0X1AF4', '0XA10A')
            Numeric = @(2048, 128, 1418000, 1531000, 3504000, 0)
            SourceHosts = @('us.msi.com'); SourceMinimum = 1
            IdentityHosts = @('modbios.io', 'gpumagick.com')
        }
        'gigabyte-gv-n1050oc-2gd' = @{
            Meta = @(6, 2016)
            Text = @('NVIDIA', 'Gigabyte',
                'NVIDIA GeForce GTX 1050 (Gigabyte OC)', 'GV-N1050OC-2GD',
                'Version 86.07.39.00.72', '0xA1', 'GDDR5',
                'official_model_and_observed_unverified_rom')
            Pci = @('0X10DE', '0X1C81', '0X1458', '0X372D',
                '0X1AF4', '0XA10B')
            Numeric = @(2048, 128, 1380000, 1493000, 3504000, 0)
            SourceHosts = @('www.gigabyte.com'); SourceMinimum = 1
            IdentityHosts = @('modbios.io', 'gpumagick.com')
        }
        'gigabyte-gv-n105toc-4gd' = @{
            Meta = @(6, 2016)
            Text = @('NVIDIA', 'Gigabyte',
                'NVIDIA GeForce GTX 1050 Ti (Gigabyte OC)',
                'GV-N105TOC-4GD', 'Version 86.07.39.40.99', '0xA1',
                'GDDR5', 'official_model_and_observed_unverified_rom')
            Pci = @('0X10DE', '0X1C82', '0X1458', '0X3763',
                '0X1AF4', '0XA10C')
            Numeric = @(4096, 128, 1316000, 1430000, 3504000, 0)
            SourceHosts = @('www.gigabyte.com'); SourceMinimum = 1
            IdentityHosts = @('www.techpowerup.com', 'www.reddit.com')
        }
        'asus-rx550-4g' = @{
            Meta = @(6, 2017)
            Text = @('AMD', 'ASUS', 'AMD Radeon RX 550 (ASUS 4G)',
                'RX550-4G', '015.050.002.001.000000', '0xC7', 'GDDR5',
                'official_model_and_observed_unverified_rom')
            Pci = @('0X1002', '0X699F', '0X1043', '0X0513',
                '0X1AF4', '0XA10D')
            Numeric = @(4096, 128, 1100000, 1183000, 3500000, 0)
            SourceHosts = @('www.asus.com'); SourceMinimum = 1
            IdentityHosts = @('www.techpowerup.com', 'steamcommunity.com')
        }
        'gigabyte-gv-rx550gaming-oc-2gd' = @{
            Meta = @(6, 2017)
            Text = @('AMD', 'Gigabyte',
                'AMD Radeon RX 550 (Gigabyte Gaming OC)',
                'GV-RX550GAMING OC-2GD', '015.050.002.001.000000',
                '0xC7', 'GDDR5',
                'official_model_and_observed_unverified_rom')
            Pci = @('0X1002', '0X699F', '0X1458', '0X22F2',
                '0X1AF4', '0XA10E')
            Numeric = @(2048, 128, 1100000, 1206000, 3500000, 0)
            SourceHosts = @('www.gigabyte.com'); SourceMinimum = 1
            IdentityHosts = @('www.techpowerup.com',
                'us.forums.blizzard.com')
        }
        'msi-rx550-aero-itx-2g-oc' = @{
            Meta = @(6, 2017)
            Text = @('AMD', 'MSI', 'AMD Radeon RX 550 (MSI Aero ITX OC)',
                'Radeon RX 550 AERO ITX 2G OC', '015.050.002.001.000000',
                '0xC7', 'GDDR5',
                'official_model_and_observed_vbios_identity')
            Pci = @('0X1002', '0X699F', '0X1462', '0X8A90',
                '0X1AF4', '0XA10F')
            Numeric = @(2048, 128, 1100000, 1203000, 3500000, 0)
            SourceHosts = @('it.msi.com', 'storage-asset.msi.com')
            SourceMinimum = 2
            IdentityHosts = @('www.techpowerup.com', 'learn.microsoft.com')
        }
        'asus-rog-strix-rx560-4g-gaming' = @{
            Meta = @(6, 2017)
            Text = @('AMD', 'ASUS',
                'AMD Radeon RX 560 (ASUS ROG Strix Gaming)',
                'ROG-STRIX-RX560-4G-GAMING', '015.050.002.001.000000',
                '0xCF', 'GDDR5',
                'official_model_and_observed_vbios_identity')
            Pci = @('0X1002', '0X67FF', '0X1043', '0X04BC',
                '0X1AF4', '0XA110')
            Numeric = @(4096, 128, 1175000, 1275000, 3500000, 0)
            SourceHosts = @('www.asus.com'); SourceMinimum = 1
            IdentityHosts = @('www.techpowerup.com', 'forums.ea.com')
        }
        'gigabyte-gv-rx560gaming-oc-4gd' = @{
            Meta = @(6, 2017)
            Text = @('AMD', 'Gigabyte',
                'AMD Radeon RX 560 (Gigabyte Gaming OC)',
                'GV-RX560GAMING OC-4GD', '015.050.002.001.000000',
                '0xCF', 'GDDR5',
                'official_model_and_observed_vbios_identity')
            Pci = @('0X1002', '0X67FF', '0X1458', '0X22ED',
                '0X1AF4', '0XA111')
            Numeric = @(4096, 128, 1175000, 1287000, 3500000, 0)
            SourceHosts = @('www.gigabyte.com'); SourceMinimum = 1
            IdentityHosts = @('www.techpowerup.com',
                'us.forums.blizzard.com')
        }
        'sapphire-pulse-rx560-4g-16cu' = @{
            Meta = @(5, 2017)
            Text = @('AMD', 'Sapphire',
                'AMD Radeon RX 560 (Sapphire Pulse 16 CU)',
                '11267-00/11267-25', '015.050.002.001.000000',
                '0xCF', 'GDDR5',
                'official_sku_family_and_observed_vbios_identity')
            Pci = @('0X1002', '0X67FF', '0X1DA2', '0XE348',
                '0X1AF4', '0XA112')
            Numeric = @(4096, 128, 1175000, 1300000, 3500000, 0)
            SourceHosts = @('www.sapphiretech.com'); SourceMinimum = 1
            IdentityHosts = @('www.techpowerup.com', 'gpumagick.com')
        }
    }
}

function Get-VMateGpuBoardContract {
    param([string]$Id)

    $contracts = Get-VMateGpuBoardContracts
    return $contracts[$Id]
}

function Get-VMateGpuBoardChipKey {
    param(
        [string]$PciVendor,
        [string]$PciDevice
    )

    return ($PciVendor.ToUpperInvariant() + ':' +
        $PciDevice.ToUpperInvariant())
}

function Add-VMateGpuBoardUniqueValue {
    param(
        [System.Collections.Generic.HashSet[string]]$Values,
        [string]$Value,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or -not $Values.Add($Value)) {
        throw "AIB GPU 目录包含空白或重复的 $Label：$Value"
    }
}

function Assert-VMateGpuBoardCatalogContract {
    param(
        [object[]]$Gpus,
        [int]$ExpectedCount,
        [int]$MinPartnersPerChip = 0
    )

    if ($ExpectedCount -lt 1 -or $MinPartnersPerChip -lt 0) {
        throw 'AIB GPU 集合的预期数量和芯片最低品牌数参数无效。'
    }
    $contracts = Get-VMateGpuBoardContracts
    $items = @($Gpus)
    if ($contracts.Count -ne $ExpectedCount -or
        $items.Count -ne $ExpectedCount) {
        throw "AIB GPU 契约与目录都必须精确包含 $ExpectedCount 条记录。"
    }

    $expectedIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    $expectedPartners = @{}
    foreach ($id in $contracts.Keys) {
        [void]$expectedIds.Add([string]$id)
        $contract = $contracts[$id]
        $chip = Get-VMateGpuBoardChipKey $contract.Pci[0] $contract.Pci[1]
        if (-not $expectedPartners.ContainsKey($chip)) {
            $expectedPartners[$chip] =
                [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
        }
        [void]$expectedPartners[$chip].Add([string]$contract.Text[1])
    }

    $actualIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    $partNumbers = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $subsystems = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $carriers = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $actualPartners = @{}
    foreach ($gpu in $items) {
        $id = [string]$gpu.id
        Add-VMateGpuBoardUniqueValue $actualIds $id '稳定 ID'
        Add-VMateGpuBoardUniqueValue $partNumbers ([string]$gpu.part_number) `
            '板卡料号'
        $chip = Get-VMateGpuBoardChipKey ([string]$gpu.pci_vendor) `
            ([string]$gpu.pci_device)
        $subsystem = $chip + ':' +
            ([string]$gpu.subsystem_vendor).ToUpperInvariant() + ':' +
            ([string]$gpu.subsystem_device).ToUpperInvariant()
        Add-VMateGpuBoardUniqueValue $subsystems $subsystem `
            '完整 PCI/subsystem 元组'
        $carrier = ([string]$gpu.carrier_vendor).ToUpperInvariant() + ':' +
            ([string]$gpu.carrier_device).ToUpperInvariant()
        Add-VMateGpuBoardUniqueValue $carriers $carrier 'virtio carrier'
        if (-not $actualPartners.ContainsKey($chip)) {
            $actualPartners[$chip] =
                [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
        }
        [void]$actualPartners[$chip].Add([string]$gpu.board_partner)
    }

    if (-not $expectedIds.SetEquals($actualIds)) {
        throw 'AIB GPU 目录 ID 集合与固定板卡契约不一致。'
    }
    if ($actualPartners.Count -ne $expectedPartners.Count) {
        throw 'AIB GPU 目录的 PCI 主芯片集合与固定板卡契约不一致。'
    }
    foreach ($chip in $expectedPartners.Keys) {
        if (-not $actualPartners.ContainsKey($chip) -or
            $actualPartners[$chip].Count -ne $expectedPartners[$chip].Count) {
            throw "AIB GPU 芯片 $chip 的不同板卡品牌数量与契约不一致。"
        }
        if ($MinPartnersPerChip -gt 0 -and
            $actualPartners[$chip].Count -lt $MinPartnersPerChip) {
            throw "AIB GPU 芯片 $chip 至少需要 $MinPartnersPerChip 个不同品牌。"
        }
    }
}

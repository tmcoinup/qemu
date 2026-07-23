# 离线读取 AIB 板卡目录，供 Guest 侧纯函数测试复用。

function Convert-TestGpuHex {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$Digits
    )
    if ($Text -cnotmatch ('\A0x[0-9A-Fa-f]{' + $Digits + '}\z')) {
        throw ("测试 GPU 目录包含非法十六进制值：" + $Text)
    }
    return [Convert]::ToInt32($Text.Substring(2), 16)
}

function Get-TestGpuBoardCases {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("缺少离线 GPU 板卡目录：" + $Path)
    }
    $catalog = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
        ConvertFrom-Json
    return @($catalog.boards | ForEach-Object {
        [pscustomobject][ordered]@{
            StableId = [string]$_.id
            Carrier = ([string]$_.carrier_device).Substring(2).ToUpperInvariant() +
                ([string]$_.carrier_vendor).Substring(2).ToUpperInvariant()
            CarrierVendor = Convert-TestGpuHex $_.carrier_vendor 4
            CarrierDevice = Convert-TestGpuHex $_.carrier_device 4
            Name = [string]$_.model
            Vendor = [string]$_.manufacturer
            Partner = [string]$_.board_partner
            Bios = [string]$_.bios
            PciVendor = Convert-TestGpuHex $_.pci_vendor 4
            Device = Convert-TestGpuHex $_.pci_device 4
            SubVendor = Convert-TestGpuHex $_.subsystem_vendor 4
            SubDevice = Convert-TestGpuHex $_.subsystem_device 4
            Revision = Convert-TestGpuHex $_.revision 2
            RamMb = [int]$_.ram_mb
            MemoryType = [string]$_.memory_type
            Width = [int]$_.memory_bus_width_bits
            Base = [int]$_.base_clock_khz
            Boost = [int]$_.boost_clock_khz
            Memory = [int]$_.memory_clock_khz
            Sli = [int]$_.sli_supported
        }
    })
}

function Assert-TestGpuBoardCoverage {
    param([Parameter(Mandatory = $true)][object[]]$Cases)

    if ($Cases.Count -ne 18) {
        throw ("AIB 测试目录应精确包含 18 块板卡，实际=" + $Cases.Count)
    }
    $vendors = @($Cases.Vendor | Sort-Object -Unique)
    if (($vendors -join ',') -cne 'AMD,NVIDIA') {
        throw ("AIB 测试目录厂商集合错误：" + ($vendors -join ','))
    }
    $actualCarriers = @($Cases | Sort-Object CarrierDevice |
        ForEach-Object { '{0:X4}' -f $_.CarrierDevice })
    $expectedCarriers = @(0xA101..0xA112 |
        ForEach-Object { '{0:X4}' -f $_ })
    if (($actualCarriers -join ',') -cne ($expectedCarriers -join ',')) {
        throw "AIB 测试目录 carrier 必须连续且精确为 A101..A112"
    }
    $chipGroups = @($Cases | Group-Object {
            '{0:X4}:{1:X4}' -f $_.PciVendor, $_.Device
        })
    if ($chipGroups.Count -ne 6) {
        throw ("AIB 测试目录应精确包含 6 个芯片型号，实际=" +
            $chipGroups.Count)
    }
    foreach ($group in $chipGroups) {
        $partners = @($group.Group.Partner | Sort-Object -Unique)
        if ($group.Count -ne 3 -or $partners.Count -ne 3) {
            throw ("芯片 " + $group.Name + " 未精确绑定三个不同品牌")
        }
    }
}

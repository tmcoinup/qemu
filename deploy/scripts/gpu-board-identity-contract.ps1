#Requires -Version 5.1

# Guest 侧 AIB carrier 与逻辑板卡身份的唯一合同。
#
# 这里只定义纯函数，不读取设备、注册表、网络或环境变量。物理显示设备始终保留
# stock virtio 1AF4:1050；A101..A112 仅用于把该物理 carrier 原子绑定到用户态
# 名称、VBIOS、显存、时钟和真实 AIB subsystem。未知 carrier 必须返回空或 false，
# 由调用方 fail-closed，绝不能回落成默认显卡。

function Get-GpuBoardIdentityContracts {
    # 每次调用都返回新对象，避免某个调用方修改共享 hashtable 后污染后续校验。
    return @(
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA101
            SpoofName='NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)'
            SpoofVendor='NVIDIA'; SpoofBios='Version 86.07.42.00.96'
            SpoofRamMb=4096; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=128
            SpoofBaseClockKHz=1291000; SpoofBoostClockKHz=1392000
            SpoofMemoryClockKHz=3504000; SpoofSliSupported=0
            SpoofPciVendorId=0x10DE; SpoofPciDeviceId=0x1C82
            SpoofSubsystemVendorId=0x1043; SpoofSubsystemDeviceId=0x8613
            SpoofRevisionId=0xA1
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA102
            SpoofName='NVIDIA GeForce GTX 1050 Ti (Colorful iGame U)'
            SpoofVendor='NVIDIA'; SpoofBios='Version 86.07.39.40.12'
            SpoofRamMb=4096; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=128
            SpoofBaseClockKHz=1380000; SpoofBoostClockKHz=1493000
            SpoofMemoryClockKHz=3504000; SpoofSliSupported=0
            SpoofPciVendorId=0x10DE; SpoofPciDeviceId=0x1C82
            SpoofSubsystemVendorId=0x7377; SpoofSubsystemDeviceId=0x0000
            SpoofRevisionId=0xA1
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA103
            SpoofName='NVIDIA GeForce GT 1030 (GALAX EXOC White)'
            SpoofVendor='NVIDIA'; SpoofBios='Version 86.08.0C.00.2B'
            SpoofRamMb=2048; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=64
            SpoofBaseClockKHz=1253000; SpoofBoostClockKHz=1506000
            SpoofMemoryClockKHz=3004000; SpoofSliSupported=0
            SpoofPciVendorId=0x10DE; SpoofPciDeviceId=0x1D01
            SpoofSubsystemVendorId=0x10DE; SpoofSubsystemDeviceId=0x11C7
            SpoofRevisionId=0xA1
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA104
            SpoofName='NVIDIA GeForce GT 1030 (ASUS Silent)'
            SpoofVendor='NVIDIA'; SpoofBios='Version 86.08.0C.00.1A'
            SpoofRamMb=2048; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=64
            SpoofBaseClockKHz=1228000; SpoofBoostClockKHz=1468000
            SpoofMemoryClockKHz=3004000; SpoofSliSupported=0
            SpoofPciVendorId=0x10DE; SpoofPciDeviceId=0x1D01
            SpoofSubsystemVendorId=0x1043; SpoofSubsystemDeviceId=0x85F4
            SpoofRevisionId=0xA1
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA105
            SpoofName='NVIDIA GeForce GT 1030 (MSI LP OCV1)'
            SpoofVendor='NVIDIA'; SpoofBios='Version 86.08.0C.00.18'
            SpoofRamMb=2048; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=64
            SpoofBaseClockKHz=1266000; SpoofBoostClockKHz=1519000
            SpoofMemoryClockKHz=3004000; SpoofSliSupported=0
            SpoofPciVendorId=0x10DE; SpoofPciDeviceId=0x1D01
            SpoofSubsystemVendorId=0x1462; SpoofSubsystemDeviceId=0x8C98
            SpoofRevisionId=0xA1
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA106
            SpoofName='NVIDIA GeForce GTX 750 Ti (ASUS OC)'
            SpoofVendor='NVIDIA'; SpoofBios='Version 82.07.32.00.20'
            SpoofRamMb=2048; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=128
            SpoofBaseClockKHz=1072000; SpoofBoostClockKHz=1150000
            SpoofMemoryClockKHz=2700000; SpoofSliSupported=0
            SpoofPciVendorId=0x10DE; SpoofPciDeviceId=0x1380
            SpoofSubsystemVendorId=0x1043; SpoofSubsystemDeviceId=0x84BB
            SpoofRevisionId=0xA2
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA107
            SpoofName='NVIDIA GeForce GTX 750 Ti (MSI OC)'
            SpoofVendor='NVIDIA'; SpoofBios='Version 82.07.25.00.1F'
            SpoofRamMb=2048; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=128
            SpoofBaseClockKHz=1059000; SpoofBoostClockKHz=1137000
            SpoofMemoryClockKHz=2700000; SpoofSliSupported=0
            SpoofPciVendorId=0x10DE; SpoofPciDeviceId=0x1380
            SpoofSubsystemVendorId=0x1462; SpoofSubsystemDeviceId=0x8A9B
            SpoofRevisionId=0xA2
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA108
            SpoofName='NVIDIA GeForce GTX 750 Ti (Gigabyte OC)'
            SpoofVendor='NVIDIA'; SpoofBios='Version 82.07.55.00.05'
            SpoofRamMb=2048; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=128
            SpoofBaseClockKHz=1033000; SpoofBoostClockKHz=1111000
            SpoofMemoryClockKHz=2700000; SpoofSliSupported=0
            SpoofPciVendorId=0x10DE; SpoofPciDeviceId=0x1380
            SpoofSubsystemVendorId=0x1458; SpoofSubsystemDeviceId=0x362D
            SpoofRevisionId=0xA2
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA109
            SpoofName='NVIDIA GeForce GTX 1050 (EVGA Gaming)'
            SpoofVendor='NVIDIA'; SpoofBios='Version 86.07.39.00.50'
            SpoofRamMb=2048; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=128
            SpoofBaseClockKHz=1354000; SpoofBoostClockKHz=1455000
            SpoofMemoryClockKHz=3504000; SpoofSliSupported=0
            SpoofPciVendorId=0x10DE; SpoofPciDeviceId=0x1C81
            SpoofSubsystemVendorId=0x3842; SpoofSubsystemDeviceId=0x6150
            SpoofRevisionId=0xA1
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA10A
            SpoofName='NVIDIA GeForce GTX 1050 (MSI Gaming X)'
            SpoofVendor='NVIDIA'; SpoofBios='Version 86.07.39.00.70'
            SpoofRamMb=2048; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=128
            SpoofBaseClockKHz=1418000; SpoofBoostClockKHz=1531000
            SpoofMemoryClockKHz=3504000; SpoofSliSupported=0
            SpoofPciVendorId=0x10DE; SpoofPciDeviceId=0x1C81
            SpoofSubsystemVendorId=0x1462; SpoofSubsystemDeviceId=0x3354
            SpoofRevisionId=0xA1
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA10B
            SpoofName='NVIDIA GeForce GTX 1050 (Gigabyte OC)'
            SpoofVendor='NVIDIA'; SpoofBios='Version 86.07.39.00.72'
            SpoofRamMb=2048; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=128
            SpoofBaseClockKHz=1380000; SpoofBoostClockKHz=1493000
            SpoofMemoryClockKHz=3504000; SpoofSliSupported=0
            SpoofPciVendorId=0x10DE; SpoofPciDeviceId=0x1C81
            SpoofSubsystemVendorId=0x1458; SpoofSubsystemDeviceId=0x372D
            SpoofRevisionId=0xA1
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA10C
            SpoofName='NVIDIA GeForce GTX 1050 Ti (Gigabyte OC)'
            SpoofVendor='NVIDIA'; SpoofBios='Version 86.07.39.40.99'
            SpoofRamMb=4096; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=128
            SpoofBaseClockKHz=1316000; SpoofBoostClockKHz=1430000
            SpoofMemoryClockKHz=3504000; SpoofSliSupported=0
            SpoofPciVendorId=0x10DE; SpoofPciDeviceId=0x1C82
            SpoofSubsystemVendorId=0x1458; SpoofSubsystemDeviceId=0x3763
            SpoofRevisionId=0xA1
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA10D
            SpoofName='AMD Radeon RX 550 (ASUS 4G)'
            SpoofVendor='AMD'; SpoofBios='015.050.002.001.000000'
            SpoofRamMb=4096; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=128
            SpoofBaseClockKHz=1100000; SpoofBoostClockKHz=1183000
            SpoofMemoryClockKHz=3500000; SpoofSliSupported=0
            SpoofPciVendorId=0x1002; SpoofPciDeviceId=0x699F
            SpoofSubsystemVendorId=0x1043; SpoofSubsystemDeviceId=0x0513
            SpoofRevisionId=0xC7
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA10E
            SpoofName='AMD Radeon RX 550 (Gigabyte Gaming OC)'
            SpoofVendor='AMD'; SpoofBios='015.050.002.001.000000'
            SpoofRamMb=2048; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=128
            SpoofBaseClockKHz=1100000; SpoofBoostClockKHz=1206000
            SpoofMemoryClockKHz=3500000; SpoofSliSupported=0
            SpoofPciVendorId=0x1002; SpoofPciDeviceId=0x699F
            SpoofSubsystemVendorId=0x1458; SpoofSubsystemDeviceId=0x22F2
            SpoofRevisionId=0xC7
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA10F
            SpoofName='AMD Radeon RX 550 (MSI Aero ITX OC)'
            SpoofVendor='AMD'; SpoofBios='015.050.002.001.000000'
            SpoofRamMb=2048; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=128
            SpoofBaseClockKHz=1100000; SpoofBoostClockKHz=1203000
            SpoofMemoryClockKHz=3500000; SpoofSliSupported=0
            SpoofPciVendorId=0x1002; SpoofPciDeviceId=0x699F
            SpoofSubsystemVendorId=0x1462; SpoofSubsystemDeviceId=0x8A90
            SpoofRevisionId=0xC7
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA110
            SpoofName='AMD Radeon RX 560 (ASUS ROG Strix Gaming)'
            SpoofVendor='AMD'; SpoofBios='015.050.002.001.000000'
            SpoofRamMb=4096; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=128
            SpoofBaseClockKHz=1175000; SpoofBoostClockKHz=1275000
            SpoofMemoryClockKHz=3500000; SpoofSliSupported=0
            SpoofPciVendorId=0x1002; SpoofPciDeviceId=0x67FF
            SpoofSubsystemVendorId=0x1043; SpoofSubsystemDeviceId=0x04BC
            SpoofRevisionId=0xCF
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA111
            SpoofName='AMD Radeon RX 560 (Gigabyte Gaming OC)'
            SpoofVendor='AMD'; SpoofBios='015.050.002.001.000000'
            SpoofRamMb=4096; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=128
            SpoofBaseClockKHz=1175000; SpoofBoostClockKHz=1287000
            SpoofMemoryClockKHz=3500000; SpoofSliSupported=0
            SpoofPciVendorId=0x1002; SpoofPciDeviceId=0x67FF
            SpoofSubsystemVendorId=0x1458; SpoofSubsystemDeviceId=0x22ED
            SpoofRevisionId=0xCF
        }
        [pscustomobject][ordered]@{
            CarrierVendorId=0x1AF4; CarrierDeviceId=0xA112
            SpoofName='AMD Radeon RX 560 (Sapphire Pulse 16 CU)'
            SpoofVendor='AMD'; SpoofBios='015.050.002.001.000000'
            SpoofRamMb=4096; SpoofMemoryType='GDDR5'; SpoofMemoryBusWidthBits=128
            SpoofBaseClockKHz=1175000; SpoofBoostClockKHz=1300000
            SpoofMemoryClockKHz=3500000; SpoofSliSupported=0
            SpoofPciVendorId=0x1002; SpoofPciDeviceId=0x67FF
            SpoofSubsystemVendorId=0x1DA2; SpoofSubsystemDeviceId=0xE348
            SpoofRevisionId=0xCF
        }
    )
}

function Get-GpuBoardIdentityContract {
    param(
        [Parameter(Mandatory = $true)][int]$CarrierVendorId,
        [Parameter(Mandatory = $true)][int]$CarrierDeviceId
    )

    if ($CarrierVendorId -lt 0 -or $CarrierVendorId -gt 0xFFFF -or
        $CarrierDeviceId -lt 0 -or $CarrierDeviceId -gt 0xFFFF) {
        return $null
    }
    $matches = @(Get-GpuBoardIdentityContracts | Where-Object {
            [int]$_.CarrierVendorId -eq $CarrierVendorId -and
            [int]$_.CarrierDeviceId -eq $CarrierDeviceId
        })
    if ($matches.Count -gt 1) {
        throw ('GPU board contract 包含重复 carrier：{0:X4}:{1:X4}' -f
            $CarrierVendorId, $CarrierDeviceId)
    }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Get-GpuBoardAutoDetectProfile {
    # Windows SUBSYS 文本顺序固定为 device 在前、vendor 在后。
    param([Parameter(Mandatory = $true)][string]$Subsys)

    if ($Subsys -cnotmatch '\A[0-9A-F]{8}\z') { return $null }
    $carrierDevice = [Convert]::ToInt32($Subsys.Substring(0, 4), 16)
    $carrierVendor = [Convert]::ToInt32($Subsys.Substring(4, 4), 16)
    $contract = Get-GpuBoardIdentityContract `
        -CarrierVendorId $carrierVendor -CarrierDeviceId $carrierDevice
    if ($null -eq $contract) { return $null }
    return @{
        Name=[string]$contract.SpoofName; Vendor=[string]$contract.SpoofVendor
        Bios=[string]$contract.SpoofBios; RamMb=[int]$contract.SpoofRamMb
        MemoryType=[string]$contract.SpoofMemoryType
        BusWidthBits=[int]$contract.SpoofMemoryBusWidthBits
        BaseClockKHz=[int]$contract.SpoofBaseClockKHz
        BoostClockKHz=[int]$contract.SpoofBoostClockKHz
        MemoryClockKHz=[int]$contract.SpoofMemoryClockKHz
        SliSupported=[int]$contract.SpoofSliSupported
        PciVendorId=[int]$contract.SpoofPciVendorId
        PciDeviceId=[int]$contract.SpoofPciDeviceId
        SubsystemVendorId=[int]$contract.SpoofSubsystemVendorId
        SubsystemDeviceId=[int]$contract.SpoofSubsystemDeviceId
        RevisionId=[int]$contract.SpoofRevisionId
    }
}

function Get-GpuBoardLogicalPciIdentity {
    param(
        [Parameter(Mandatory = $true)][int]$CarrierVendorId,
        [Parameter(Mandatory = $true)][int]$CarrierDeviceId
    )

    $contract = Get-GpuBoardIdentityContract `
        -CarrierVendorId $CarrierVendorId -CarrierDeviceId $CarrierDeviceId
    if ($null -eq $contract) { return $null }
    return [pscustomobject]@{
        PciVendorId=[int]$contract.SpoofPciVendorId
        PciDeviceId=[int]$contract.SpoofPciDeviceId
        SubsystemVendorId=[int]$contract.SpoofSubsystemVendorId
        SubsystemDeviceId=[int]$contract.SpoofSubsystemDeviceId
        RevisionId=[int]$contract.SpoofRevisionId
    }
}

function Test-GpuLogicalBinding {
    # 只接受受控 1AF4:A101..A112 carrier；schema-2 快照必须逐字段命中同一块板卡。
    param($Snapshot, [System.Text.RegularExpressions.Match]$Source)

    if ($null -eq $Snapshot -or $null -eq $Source -or
        -not $Source.Success -or $Source.Groups.Count -lt 4) {
        return $false
    }
    try {
        $carrierDevice = [Convert]::ToInt32($Source.Groups[1].Value, 16)
        $carrierVendor = [Convert]::ToInt32($Source.Groups[2].Value, 16)
        $sourceRevision = [Convert]::ToInt32($Source.Groups[3].Value, 16)
    } catch {
        return $false
    }
    if ($sourceRevision -ne [int]$Snapshot.SpoofRevisionId) { return $false }
    $expected = Get-GpuBoardIdentityContract `
        -CarrierVendorId $carrierVendor -CarrierDeviceId $carrierDevice
    if ($null -eq $expected -or [int]$Snapshot.IdentitySchemaVersion -ne 2) {
        return $false
    }
    foreach ($field in @(
            'SpoofName', 'SpoofVendor', 'SpoofBios', 'SpoofRamMb',
            'SpoofMemoryType', 'SpoofMemoryBusWidthBits', 'SpoofBaseClockKHz',
            'SpoofBoostClockKHz', 'SpoofMemoryClockKHz', 'SpoofSliSupported',
            'SpoofPciVendorId', 'SpoofPciDeviceId', 'SpoofSubsystemVendorId',
            'SpoofSubsystemDeviceId', 'SpoofRevisionId')) {
        $actual = if ($Snapshot -is [System.Collections.IDictionary]) {
            if (-not $Snapshot.Contains($field)) { return $false }
            $Snapshot[$field]
        } else {
            $member = $Snapshot.PSObject.Properties[$field]
            if ($null -eq $member) { return $false }
            $member.Value
        }
        if ($expected.$field -is [string]) {
            if ([string]$actual -cne [string]$expected.$field) { return $false }
        } elseif ([int64]$actual -ne [int64]$expected.$field) {
            return $false
        }
    }
    return $true
}

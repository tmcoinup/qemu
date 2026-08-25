#Requires -Version 5.1

<#
.SYNOPSIS
    在 P-11 guest 内只读采集 Hyper-V 固件和网卡身份，并与宿主期望值比对。

.DESCRIPTION
    本模块不修改 guest 注册表、设备或 SMBIOS。它只读取 Windows CIM 类，返回
    可审计的 GuestObserved 记录；CPU/GPU 品牌和 Hyper-V 平台标识保持真实只读。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:VMateGpuPGuestFirmwareFields = @(
    'BIOSGUID',
    'BIOSSerialNumber',
    'BaseBoardSerialNumber',
    'ChassisSerialNumber',
    'ChassisAssetTag'
)

function Get-VMateGpuPGuestIdentityProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Label = 'identity'
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Label 缺少 $Name 属性。" }
    return $property.Value
}

function ConvertTo-VMateGpuPGuestGuid {
    param([Parameter(Mandatory = $true)][string]$Value)

    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse($Value.Trim(), [ref]$parsed) -or
        $parsed -eq [Guid]::Empty) {
        throw "guest BIOSGUID 无效：$Value"
    }
    return '{' + $parsed.ToString('D').ToUpperInvariant() + '}'
}

function ConvertTo-VMateGpuPGuestMacAddress {
    param([Parameter(Mandatory = $true)][string]$Value)

    $normalized = [regex]::Replace($Value, '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{12}$') {
        throw "guest MAC 地址无效：$Value"
    }
    return $normalized
}

function Get-VMateGpuPGuestHardwareIdentitySnapshot {
    [CmdletBinding()]
    param()

    $biosRows = @(Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop)
    $boardRows = @(Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop)
    $enclosureRows = @(Get-CimInstance -ClassName Win32_SystemEnclosure `
            -ErrorAction Stop)
    $productRows = @(Get-CimInstance -ClassName Win32_ComputerSystemProduct `
            -ErrorAction Stop)
    $systemRows = @(Get-CimInstance -ClassName Win32_ComputerSystem `
            -ErrorAction Stop)
    foreach ($entry in @(
            [pscustomobject]@{ Name = 'Win32_BIOS'; Rows = $biosRows },
            [pscustomobject]@{ Name = 'Win32_BaseBoard'; Rows = $boardRows },
            [pscustomobject]@{ Name = 'Win32_SystemEnclosure'; Rows = $enclosureRows },
            [pscustomobject]@{ Name = 'Win32_ComputerSystemProduct'; Rows = $productRows },
            [pscustomobject]@{ Name = 'Win32_ComputerSystem'; Rows = $systemRows }
        )) {
        if (@($entry.Rows).Count -ne 1) {
            throw "guest $($entry.Name) 必须恰好返回一条记录。"
        }
    }

    $bios = $biosRows[0]
    $board = $boardRows[0]
    $enclosure = $enclosureRows[0]
    $product = $productRows[0]
    $system = $systemRows[0]
    $network = @(Get-CimInstance -ClassName Win32_NetworkAdapter `
            -ErrorAction Stop | Where-Object {
                [bool]$_.PhysicalAdapter -and
                -not [String]::IsNullOrWhiteSpace([string]$_.MACAddress)
            } | ForEach-Object {
                [pscustomobject][ordered]@{
                    Name = [string]$_.Name
                    PNPDeviceID = [string]$_.PNPDeviceID
                    MACAddress = ConvertTo-VMateGpuPGuestMacAddress `
                        ([string]$_.MACAddress)
                }
            } | Sort-Object MACAddress, PNPDeviceID)
    $processors = @(Get-CimInstance -ClassName Win32_Processor `
            -ErrorAction Stop | ForEach-Object {
                [pscustomobject][ordered]@{
                    Name = [string]$_.Name
                    Manufacturer = [string]$_.Manufacturer
                    NumberOfCores = [int]$_.NumberOfCores
                    NumberOfLogicalProcessors = [int]$_.NumberOfLogicalProcessors
                }
            })

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        Source = 'WindowsCimColdBootReadback'
        Firmware = [pscustomobject][ordered]@{
            BIOSGUID = ConvertTo-VMateGpuPGuestGuid ([string]$product.UUID)
            BIOSSerialNumber = [string]$bios.SerialNumber
            BaseBoardSerialNumber = [string]$board.SerialNumber
            ChassisSerialNumber = [string]$enclosure.SerialNumber
            ChassisAssetTag = [string]$enclosure.SMBIOSAssetTag
        }
        NetworkAdapters = $network
        Platform = [pscustomobject][ordered]@{
            Manufacturer = [string]$system.Manufacturer
            Model = [string]$system.Model
            HypervisorPresent = [bool]$system.HypervisorPresent
            BIOSManufacturer = [string]$bios.Manufacturer
            BaseBoardManufacturer = [string]$board.Manufacturer
            BaseBoardProduct = [string]$board.Product
            Processors = $processors
        }
        Match = $null
        Mismatches = @()
        ObservedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Test-VMateGpuPGuestHardwareIdentityMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Observed
    )

    $expectedFirmware = Get-VMateGpuPGuestIdentityProperty `
        $Expected 'Firmware' 'expected hardware identity'
    $observedFirmware = Get-VMateGpuPGuestIdentityProperty `
        $Observed 'Firmware' 'GuestObserved'
    $mismatches = [Collections.Generic.List[string]]::new()
    foreach ($field in $script:VMateGpuPGuestFirmwareFields) {
        $expectedValue = [string](Get-VMateGpuPGuestIdentityProperty `
                $expectedFirmware $field 'expected firmware')
        $actualValue = [string](Get-VMateGpuPGuestIdentityProperty `
                $observedFirmware $field 'guest firmware')
        if ($field -ceq 'BIOSGUID') {
            $expectedValue = ConvertTo-VMateGpuPGuestGuid $expectedValue
            $actualValue = ConvertTo-VMateGpuPGuestGuid $actualValue
        }
        if (-not [string]::Equals($expectedValue, $actualValue,
                [StringComparison]::OrdinalIgnoreCase)) {
            [void]$mismatches.Add("Firmware.$field")
        }
    }

    $expectedNetwork = @((Get-VMateGpuPGuestIdentityProperty `
                $Expected 'NetworkAdapters' 'expected hardware identity') |
        ForEach-Object {
            ConvertTo-VMateGpuPGuestMacAddress ([string](
                    Get-VMateGpuPGuestIdentityProperty $_ 'StaticMacAddress' `
                        'expected network adapter'))
        } | Sort-Object -Unique)
    $observedNetwork = @((Get-VMateGpuPGuestIdentityProperty `
                $Observed 'NetworkAdapters' 'GuestObserved') |
        ForEach-Object {
            ConvertTo-VMateGpuPGuestMacAddress ([string](
                    Get-VMateGpuPGuestIdentityProperty $_ 'MACAddress' `
                        'guest network adapter'))
        } | Sort-Object -Unique)
    $networkMatch = $expectedNetwork.Count -eq $observedNetwork.Count
    if ($networkMatch) {
        for ($index = 0; $index -lt $expectedNetwork.Count; $index++) {
            if ([string]$expectedNetwork[$index] -cne
                [string]$observedNetwork[$index]) {
                $networkMatch = $false
                break
            }
        }
    }
    if (-not $networkMatch) {
        [void]$mismatches.Add('NetworkAdapters.MACAddress')
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        Source = [string](Get-VMateGpuPGuestIdentityProperty `
                $Observed 'Source' 'GuestObserved')
        Firmware = $observedFirmware
        NetworkAdapters = @((Get-VMateGpuPGuestIdentityProperty `
                    $Observed 'NetworkAdapters' 'GuestObserved'))
        Platform = Get-VMateGpuPGuestIdentityProperty `
            $Observed 'Platform' 'GuestObserved'
        Match = $mismatches.Count -eq 0
        Mismatches = @($mismatches)
        ObservedAtUtc = [string](Get-VMateGpuPGuestIdentityProperty `
                $Observed 'ObservedAtUtc' 'GuestObserved')
    }
}

#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$system = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
$product = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop
$bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
$board = Get-CimInstance Win32_BaseBoard -ErrorAction Stop
$processorName = 'Intel(R) Core(TM) i7-14700F'

$values = [ordered]@{
    SystemManufacturer = [string]$system.Manufacturer
    SystemProductName = [string]$system.Model
    SystemFamily = [string]$system.SystemFamily
    SystemSKU = [string]$system.SystemSKUNumber
    SystemVersion = [string]$product.Version
    BaseBoardManufacturer = [string]$board.Manufacturer
    BaseBoardProduct = [string]$board.Product
    BIOSVendor = [string]$bios.Manufacturer
    BIOSVersion = [string]$bios.SMBIOSBIOSVersion
}

$hardwareRoot = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
    'SYSTEM\HardwareConfig')
if ($null -eq $hardwareRoot) { throw 'HardwareConfig registry root is unavailable.' }
try {
    $targets = @($hardwareRoot.GetSubKeyNames() | Where-Object {
            $_ -eq 'Current' -or $_ -match '^\{[0-9A-Fa-f-]{36}\}$'
        })
}
finally { $hardwareRoot.Dispose() }

foreach ($target in $targets) {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        "SYSTEM\HardwareConfig\$target", $true)
    if ($null -eq $key) { throw "HardwareConfig target unavailable: $target" }
    try {
        foreach ($entry in $values.GetEnumerator()) {
            $key.SetValue([string]$entry.Key, [string]$entry.Value,
                [Microsoft.Win32.RegistryValueKind]::String)
        }
    }
    finally { $key.Dispose() }
}

$processorRoot = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
    'HARDWARE\DESCRIPTION\System\CentralProcessor')
if ($null -eq $processorRoot) { throw 'Processor registry root is unavailable.' }
try { $processorTargets = @($processorRoot.GetSubKeyNames()) }
finally { $processorRoot.Dispose() }

foreach ($target in $processorTargets) {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        "HARDWARE\DESCRIPTION\System\CentralProcessor\$target", $true)
    if ($null -eq $key) { throw "Processor target unavailable: $target" }
    try {
        $key.SetValue('ProcessorNameString', $processorName,
            [Microsoft.Win32.RegistryValueKind]::String)
    }
    finally { $key.Dispose() }
}

Restart-Service -Name Winmgmt -Force -ErrorAction Stop
$observedProcessor = Get-CimInstance Win32_Processor -ErrorAction Stop
[pscustomobject][ordered]@{
    Status = 'RestoredFromGuestCim'
    HardwareConfigTargetCount = $targets.Count
    ProcessorTargetCount = $processorTargets.Count
    ComputerSystem = [pscustomobject]@{
        Manufacturer = [string](Get-CimInstance Win32_ComputerSystem).Manufacturer
        Model = [string](Get-CimInstance Win32_ComputerSystem).Model
    }
    Processor = [pscustomobject]@{
        Manufacturer = [string]$observedProcessor.Manufacturer
        Name = [string]$observedProcessor.Name
    }
}

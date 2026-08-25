#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$result = [ordered]@{
    StartedAtUtc = [DateTime]::UtcNow.ToString('o')
    HardwareConfigTargets = @()
    ProcessorTargets = @()
    Immediate = $null
    AfterWmiRestart = $null
    Restored = $false
    Error = $null
}
$changes = [Collections.Generic.List[object]]::new()

function Save-And-SetRegistryString {
    param(
        [Parameter(Mandatory = $true)][string]$SubKey,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubKey, $true)
    if ($null -eq $key) { throw "registry key unavailable: HKLM\$SubKey" }
    try {
        $names = @($key.GetValueNames())
        $exists = $names -contains $Name
        $oldValue = if ($exists) {
            $key.GetValue($Name, $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } else { $null }
        $oldKind = if ($exists) { $key.GetValueKind($Name) } else { $null }
        [void]$changes.Add([pscustomobject]@{
                SubKey = $SubKey
                Name = $Name
                Exists = $exists
                Value = $oldValue
                Kind = $oldKind
            })
        $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::String)
    }
    finally { $key.Dispose() }
}

function Restore-RegistryChanges {
    foreach ($change in @($changes | Select-Object -Reverse)) {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            [string]$change.SubKey, $true)
        if ($null -eq $key) { throw "rollback key unavailable: HKLM\$($change.SubKey)" }
        try {
            if ([bool]$change.Exists) {
                $key.SetValue([string]$change.Name, $change.Value,
                    [Microsoft.Win32.RegistryValueKind]$change.Kind)
            }
            else {
                $key.DeleteValue([string]$change.Name, $false)
            }
        }
        finally { $key.Dispose() }
    }
}

function Get-IdentityReadback {
    $system = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $product = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop
    $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
    $board = Get-CimInstance Win32_BaseBoard -ErrorAction Stop
    $processor = Get-CimInstance Win32_Processor -ErrorAction Stop
    [pscustomobject][ordered]@{
        ComputerSystem = [pscustomobject]@{
            Manufacturer = [string]$system.Manufacturer
            Model = [string]$system.Model
        }
        ComputerSystemProduct = [pscustomobject]@{
            Vendor = [string]$product.Vendor
            Name = [string]$product.Name
            Version = [string]$product.Version
        }
        BIOS = [pscustomobject]@{
            Manufacturer = [string]$bios.Manufacturer
            Version = [string]$bios.SMBIOSBIOSVersion
        }
        BaseBoard = [pscustomobject]@{
            Manufacturer = [string]$board.Manufacturer
            Product = [string]$board.Product
            Version = [string]$board.Version
        }
        Processor = [pscustomobject]@{
            Manufacturer = [string]$processor.Manufacturer
            Name = [string]$processor.Name
        }
    }
}

try {
    $hardwareRoot = 'SYSTEM\HardwareConfig'
    $hardwareKeys = [Collections.Generic.List[string]]::new()
    $root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($hardwareRoot)
    if ($null -eq $root) { throw 'HKLM\SYSTEM\HardwareConfig is unavailable.' }
    try {
        foreach ($name in @($root.GetSubKeyNames())) {
            if ($name -eq 'Current' -or $name -match '^\{[0-9A-Fa-f-]{36}\}$') {
                [void]$hardwareKeys.Add("$hardwareRoot\$name")
            }
        }
    }
    finally { $root.Dispose() }
    if ($hardwareKeys.Count -eq 0) {
        throw 'No current HardwareConfig registry target was found.'
    }
    $result.HardwareConfigTargets = @($hardwareKeys)

    $processorRoot = 'HARDWARE\DESCRIPTION\System\CentralProcessor'
    $root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($processorRoot)
    if ($null -eq $root) { throw 'HKLM processor registry root is unavailable.' }
    try {
        $processorKeys = @($root.GetSubKeyNames() | ForEach-Object {
                "$processorRoot\$_"
            })
    }
    finally { $root.Dispose() }
    if ($processorKeys.Count -eq 0) { throw 'No processor registry targets were found.' }
    $result.ProcessorTargets = @($processorKeys)

    $hardwareValues = [ordered]@{
        SystemManufacturer = 'VMate Projection Test'
        SystemProductName = 'P11 Projection Board'
        SystemFamily = 'VMate Test Family'
        SystemSKU = 'P11-TEST-SKU'
        SystemVersion = 'P11 Test Version'
        BaseBoardManufacturer = 'VMate Projection Test'
        BaseBoardProduct = 'P11 Projection Board'
        BIOSVendor = 'VMate Projection Test'
        BIOSVersion = 'P11.TEST.1'
    }
    foreach ($subKey in $hardwareKeys) {
        foreach ($entry in $hardwareValues.GetEnumerator()) {
            Save-And-SetRegistryString -SubKey $subKey -Name $entry.Key `
                -Value $entry.Value
        }
    }
    foreach ($subKey in $processorKeys) {
        Save-And-SetRegistryString -SubKey $subKey `
            -Name 'ProcessorNameString' -Value 'VMate P11 Projection CPU'
    }

    $result.Immediate = Get-IdentityReadback
    Restart-Service -Name Winmgmt -Force -ErrorAction Stop
    $result.AfterWmiRestart = Get-IdentityReadback
}
catch {
    $result.Error = $_.Exception.Message
}
finally {
    try {
        Restore-RegistryChanges
        Restart-Service -Name Winmgmt -Force -ErrorAction Stop
        $result.Restored = $true
    }
    catch {
        $rollbackError = "rollback failed: $($_.Exception.Message)"
        $result.Error = if ([String]::IsNullOrWhiteSpace([string]$result.Error)) {
            $rollbackError
        } else { "$($result.Error); $rollbackError" }
    }
}

$result.FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
[pscustomobject]$result

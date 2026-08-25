#Requires -Version 5.1

param(
    [string]$OutputPath = 'C:\VMateLab\hyperv-raw-configuration.json'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$namespace = 'root/virtualization/v2'

function Convert-VMateCimValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [Microsoft.Management.Infrastructure.CimInstance]) {
        return Convert-VMateCimInstance $Value
    }
    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { Convert-VMateCimValue $_ })
    }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [TimeSpan]) { return $Value.ToString() }
    return $Value
}

function Convert-VMateCimInstance {
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Management.Infrastructure.CimInstance]$InputObject
    )

    $properties = [ordered]@{}
    foreach ($property in @($InputObject.CimInstanceProperties |
            Sort-Object Name)) {
        $properties[$property.Name] = [pscustomobject][ordered]@{
            CimType = [string]$property.CimType
            Value = Convert-VMateCimValue $property.Value
        }
    }
    return [pscustomobject][ordered]@{
        ClassName = $InputObject.CimClass.CimClassName
        Properties = [pscustomobject]$properties
    }
}

$virtualMachines = @()
foreach ($vmName in @('pc01', 'pc02', 'P11-Lab')) {
    $vm = Get-VM -Name $vmName -ErrorAction Stop
    $id = $vm.Id.Guid.ToString()
    $computerSystem = Get-CimInstance -Namespace $namespace `
        -ClassName Msvm_ComputerSystem -Filter ("Name='" + $id + "'")
    $settings = @(Get-CimAssociatedInstance -InputObject $computerSystem `
        -Namespace $namespace -Association Msvm_SettingsDefineState `
        -ResultClassName Msvm_VirtualSystemSettingData)
    $settingRows = @()
    foreach ($setting in $settings) {
        $resources = @(Get-CimAssociatedInstance -InputObject $setting `
            -Namespace $namespace `
            -Association Msvm_VirtualSystemSettingDataComponent)
        $settingRows += [pscustomobject][ordered]@{
            Setting = Convert-VMateCimInstance $setting
            Resources = @($resources | ForEach-Object {
                    Convert-VMateCimInstance $_
                })
        }
    }
    $virtualMachines += [pscustomobject][ordered]@{
        Name = $vmName
        Id = $id
        ComputerSystem = Convert-VMateCimInstance $computerSystem
        Settings = $settingRows
    }
}

[pscustomobject][ordered]@{
    SchemaVersion = 1
    CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    VirtualMachines = $virtualMachines
} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputPath `
    -Encoding UTF8

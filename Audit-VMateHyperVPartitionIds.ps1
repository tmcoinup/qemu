#Requires -Version 5.1

[CmdletBinding()]
param([string]$OutputPath = 'C:\VMateLab\hyperv-partition-ids.json')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$instances = @(Get-CimInstance -ClassName `
        Win32_PerfRawData_HvStats_HyperVHypervisorPartition)
$rows = foreach ($instance in $instances) {
    $properties = [ordered]@{}
    foreach ($property in $instance.CimInstanceProperties) {
        $properties[[string]$property.Name] = $property.Value
    }
    [pscustomobject]$properties
}
[pscustomobject][ordered]@{
    CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    Rows = $rows
    Classes = @(Get-CimClass -ClassName 'Win32_PerfRawData_HvStats*' |
        ForEach-Object {
            [pscustomobject][ordered]@{
                Name = [string]$_.CimClassName
                Properties = @($_.CimClassProperties.Name)
            }
        })
} | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath $OutputPath -Encoding UTF8

[pscustomobject][ordered]@{
    OutputPath = $OutputPath
    Count = $rows.Count
} | ConvertTo-Json -Compress

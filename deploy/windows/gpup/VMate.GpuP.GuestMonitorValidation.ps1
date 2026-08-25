#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VMateGpuPGuestMonitorInventory {
    [CmdletBinding()]
    param()
    return @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
        Where-Object { $_.PNPClass -ceq 'Monitor' } | ForEach-Object {
            $presentProperty = $_.PSObject.Properties['Present']
            $problemProperty = $_.PSObject.Properties['ConfigManagerErrorCode']
            [pscustomobject][ordered]@{
                Name = [string]$_.Name
                InstanceId = [string]$_.PNPDeviceID
                Status = [string]$_.Status
                Present = $null -eq $presentProperty -or
                    [bool]$presentProperty.Value
                ProblemCode = if ($null -eq $problemProperty) { -1 }
                    else { [int]$problemProperty.Value }
                Service = [string]$_.Service
            }
        })
}

function Assert-VMateGpuPGuestMonitor {
    [CmdletBinding()]
    param()
    $present = @(Get-VMateGpuPGuestMonitorInventory | Where-Object {
            $_.Present -eq $true
        })
    $healthy = @($present | Where-Object {
            [string]$_.Status -ceq 'OK' -and [int]$_.ProblemCode -eq 0
        })
    $expected = @($healthy | Where-Object {
            [string]$_.Name -ceq 'VMate P-11 Virtual Console Monitor' -and
            [string]$_.InstanceId -match
                '(?i)^ROOT\\VMATEP11MONITOR\\[0-9A-F]+$' -and
            [String]::IsNullOrWhiteSpace([string]$_.Service)
        })
    if ($present.Count -ne 1 -or $healthy.Count -ne 1 -or
        $expected.Count -ne 1) {
        throw ('P-11 guest 必须有且只有一个健康的无驱动虚拟控制台 Monitor ' +
            "设备；Present=$($present.Count)，Healthy=$($healthy.Count)，" +
            "Expected=$($expected.Count)")
    }
    return $expected[0]
}

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-VMateGpuPMonitorText {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    return (-join @($Value | Where-Object { [int]$_ -ne 0 } |
            ForEach-Object { [char][int]$_ })).Trim()
}

function Get-VMateGpuPGuestMonitorInventory {
    [CmdletBinding()]
    param()

    $drivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver `
            -ErrorAction Stop | Where-Object { $_.DeviceClass -ceq 'MONITOR' })
    $driverById = @{}
    foreach ($driver in $drivers) {
        if ([string]$driver.DeviceID) {
            $driverById[[string]$driver.DeviceID] = $driver
        }
    }
    return @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
        Where-Object { $_.PNPClass -ceq 'Monitor' } | ForEach-Object {
            $id = [string]$_.PNPDeviceID
            $driver = if ($driverById.ContainsKey($id)) {
                $driverById[$id]
            } else { $null }
            $presentProperty = $_.PSObject.Properties['Present']
            $problemProperty = $_.PSObject.Properties[
                'ConfigManagerErrorCode']
            [pscustomobject][ordered]@{
                Name = [string]$_.Name
                InstanceId = $id
                HardwareIds = @($_.HardwareID)
                Status = [string]$_.Status
                Present = $null -eq $presentProperty -or
                    [bool]$presentProperty.Value
                ProblemCode = if ($null -eq $problemProperty) { -1 }
                    else { [int]$problemProperty.Value }
                Service = [string]$_.Service
                DriverProvider = if ($null -eq $driver) { '' }
                    else { [string]$driver.DriverProviderName }
                DriverVersion = if ($null -eq $driver) { '' }
                    else { [string]$driver.DriverVersion }
                InfName = if ($null -eq $driver) { '' }
                    else { [string]$driver.InfName }
                IsSigned = $null -ne $driver -and $driver.IsSigned -eq $true
                Signer = if ($null -eq $driver) { '' }
                    else { [string]$driver.Signer }
            }
        })
}

function Get-VMateGpuPGuestActiveMonitorIdentity {
    [CmdletBinding()]
    param()

    return @(Get-CimInstance -Namespace 'root\wmi' -ClassName WmiMonitorID `
            -ErrorAction Stop | Where-Object { $_.Active -eq $true } |
        ForEach-Object {
            [pscustomobject][ordered]@{
                InstanceName = [string]$_.InstanceName
                Manufacturer = ConvertFrom-VMateGpuPMonitorText `
                    $_.ManufacturerName
                ProductCode = ConvertFrom-VMateGpuPMonitorText `
                    $_.ProductCodeID
                SerialNumber = ConvertFrom-VMateGpuPMonitorText `
                    $_.SerialNumberID
                FriendlyName = ConvertFrom-VMateGpuPMonitorText `
                    $_.UserFriendlyName
                WeekOfManufacture = [int]$_.WeekOfManufacture
                YearOfManufacture = [int]$_.YearOfManufacture
            }
        })
}

function Assert-VMateGpuPGuestMonitor {
    [CmdletBinding()]
    param(
        [string]$ExpectedPnpCode = '',
        [string]$ExpectedFriendlyName = ''
    )

    $inventory = @(Get-VMateGpuPGuestMonitorInventory)
    $legacy = @($inventory | Where-Object {
            ([string]$_.Name + '|' + [string]$_.InstanceId) -match
                '(?i)(VMate|ROOT\\VMATEP11MONITOR)'
        })
    if ($legacy.Count -ne 0) {
        throw ('guest 中仍有旧 VMate Monitor PnP 节点：' +
            (($legacy.InstanceId) -join ', '))
    }

    $present = @($inventory | Where-Object { $_.Present -eq $true })
    $healthy = @($present | Where-Object {
            [string]$_.Status -ceq 'OK' -and [int]$_.ProblemCode -eq 0
        })
    if ($present.Count -ne 1 -or $healthy.Count -ne 1) {
        throw ('冷启动 P-11 guest 必须有且只有一个健康 Monitor；' +
            "Present=$($present.Count)，Healthy=$($healthy.Count)")
    }
    $monitor = $healthy[0]
    $facts = @([string]$monitor.InstanceId) + @($monitor.HardwareIds)
    if (($facts -join '|') -notmatch
        '(?i)(?:DISPLAY|MONITOR)\\(?<Code>[A-Z]{3}[0-9A-F]{4})(?:\\|$)') {
        throw "Monitor 没有标准 EISA PnP code：$($monitor.InstanceId)"
    }
    $pnpCode = $Matches.Code.ToUpperInvariant()
    if ($pnpCode -in @('MSH062E', 'DEFAULT_MONITOR') -or
        [string]$monitor.Name -match '(?i)^Generic (Non-)?PnP Monitor$') {
        throw "Monitor 仍是 Hyper-V/Generic 身份：$pnpCode / $($monitor.Name)"
    }
    if ($ExpectedPnpCode -and $pnpCode -cne
        $ExpectedPnpCode.Trim().ToUpperInvariant()) {
        throw "Monitor PnP code 与 profile 不一致：$pnpCode != $ExpectedPnpCode"
    }
    if ([string]$monitor.Service -ine 'monitor' -or
        $monitor.IsSigned -ne $true -or
        [string]::IsNullOrWhiteSpace([string]$monitor.Signer) -or
        [string]$monitor.DriverProvider -notmatch '(?i)^Microsoft') {
        throw 'Monitor 未绑定 Microsoft 签名的 inbox monitor stack。'
    }

    $active = @(Get-VMateGpuPGuestActiveMonitorIdentity)
    if ($active.Count -ne 1) {
        throw "WmiMonitorID 必须只有一个 active identity：$($active.Count)"
    }
    $identity = $active[0]
    $activeCode = (([string]$identity.Manufacturer) +
        ([string]$identity.ProductCode)).ToUpperInvariant()
    if ($activeCode -cne $pnpCode -or
        [string]::IsNullOrWhiteSpace([string]$identity.SerialNumber) -or
        [string]$identity.SerialNumber -ceq '0' -or
        [string]::IsNullOrWhiteSpace([string]$identity.FriendlyName) -or
        [string]$identity.FriendlyName -match '(?i)^HyperVMonitor$') {
        throw ('active EDID 身份与 Monitor PnP 节点不一致或仍是 Hyper-V 默认值：' +
            "$activeCode / $($identity.FriendlyName) / $($identity.SerialNumber)")
    }
    if ($ExpectedFriendlyName -and -not
        ([string]$identity.FriendlyName).Equals($ExpectedFriendlyName,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw ('Monitor EDID 名称与 profile 不一致：' +
            "$($identity.FriendlyName) != $ExpectedFriendlyName")
    }
    return [pscustomobject][ordered]@{
        Passed = $true
        PnpCode = $pnpCode
        Device = $monitor
        EdidIdentity = $identity
    }
}

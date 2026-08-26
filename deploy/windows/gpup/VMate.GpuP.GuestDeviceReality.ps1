#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.GpuP.GuestMonitorValidation.ps1')

function Get-VMateGpuPDevicePropertyData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$KeyName
    )
    try {
        return @((Get-PnpDeviceProperty -InstanceId $InstanceId `
                    -KeyName $KeyName -ErrorAction Stop).Data)
    }
    catch {
        return @()
    }
}

function Get-VMateGpuPGuestDeviceInventory {
    [CmdletBinding()]
    param()

    $drivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver `
            -ErrorAction Stop)
    $driverById = @{}
    foreach ($driver in $drivers) {
        if ([string]$driver.DeviceID) {
            $driverById[[string]$driver.DeviceID] = $driver
        }
    }
    return @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
        ForEach-Object {
            $id = [string]$_.PNPDeviceID
            $driver = if ($driverById.ContainsKey($id)) {
                $driverById[$id]
            } else { $null }
            $presentProperty = $_.PSObject.Properties['Present']
            $problemProperty = $_.PSObject.Properties[
                'ConfigManagerErrorCode']
            [pscustomobject][ordered]@{
                Class = [string]$_.PNPClass
                Name = [string]$_.Name
                InstanceId = $id
                Manufacturer = [string]$_.Manufacturer
                Present = $null -eq $presentProperty -or
                    [bool]$presentProperty.Value
                Status = [string]$_.Status
                ProblemCode = if ($null -eq $problemProperty) { -1 }
                    else { [int]$problemProperty.Value }
                Service = [string]$_.Service
                HardwareIds = @($_.HardwareID)
                CompatibleIds = @($_.CompatibleID)
                LocationInfo = @(Get-VMateGpuPDevicePropertyData $id `
                    'DEVPKEY_Device_LocationInfo')
                BusReportedDescription = @(
                    Get-VMateGpuPDevicePropertyData $id `
                        'DEVPKEY_Device_BusReportedDeviceDesc')
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

function Test-VMateGpuPOfficialVendorDisplayDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Device,
        [Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD')][string]$Vendor
    )

    $contract = if ($Vendor -ieq 'NVIDIA') {
        [pscustomobject]@{
            VendorId = '10DE'; Provider = '(?i)^NVIDIA(?: Corporation)?$'
            Service = '(?i)^nvlddmkm$'
            Signer = '(?i)(NVIDIA|Microsoft Windows Hardware Compatibility Publisher)'
        }
    }
    else {
        [pscustomobject]@{
            VendorId = '1002'
            Provider = '(?i)^(AMD|Advanced Micro Devices(?:, Inc\.)?)$'
            Service = '(?i)^(amdkmdag|amdwddmg|amdkmdap)$'
            Signer = '(?i)(AMD|Advanced Micro Devices|Microsoft Windows Hardware Compatibility Publisher)'
        }
    }
    $facts = @([string]$Device.InstanceId) + @($Device.HardwareIds)
    return $Device.Present -eq $true -and
        [string]$Device.Status -ceq 'OK' -and
        [int]$Device.ProblemCode -eq 0 -and
        ($facts -join '|') -match
            "(?i)(?:^|\|)PCI\\VEN_$($contract.VendorId)(?:&|\|)" -and
        [string]$Device.DriverProvider -match $contract.Provider -and
        [string]$Device.Service -match $contract.Service -and
        [string]$Device.InfName -notmatch '(?i)^(vrd|basicdisplay)\.inf$' -and
        $Device.IsSigned -eq $true -and
        [string]$Device.Signer -match $contract.Signer
}

function New-VMateGpuPRealityCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Detail,
        [ValidateSet('Required', 'Architecture')][string]$Kind = 'Required'
    )
    return [pscustomobject][ordered]@{
        Name = $Name
        Passed = $Passed
        Kind = $Kind
        Detail = $Detail
    }
}

function Get-VMateGpuPGuestDeviceReality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD')][string]$Vendor,
        [string]$ExpectedGpuName = '',
        [string]$ExpectedStorageModel = '',
        [string]$ExpectedNetworkModel = ''
    )

    $devices = @(Get-VMateGpuPGuestDeviceInventory)
    $present = @($devices | Where-Object { $_.Present -eq $true })
    $display = @($present | Where-Object { $_.Class -ceq 'Display' })
    $vendorDisplay = @($display | Where-Object {
            Test-VMateGpuPOfficialVendorDisplayDevice $_ $Vendor
        })
    $vmateNamed = @($devices | Where-Object {
            (@($_.Name, $_.InstanceId, $_.Service, $_.Manufacturer) -join '|') `
                -match '(?i)VMate'
        })
    $hyperVNamed = @($present | Where-Object {
            (@($_.Name, $_.Manufacturer, $_.BusReportedDescription) -join '|') `
                -match '(?i)(Microsoft Hyper-V|Hyper-V Virtual|VMBus)'
        })
    $problem = @($present | Where-Object {
            [int]$_.ProblemCode -gt 0 -or
            [string]$_.Status -notin @('', 'OK')
        })
    $disks = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop |
        Select-Object Index, Model, SerialNumber, FirmwareRevision,
            InterfaceType, PNPDeviceID, Size, Status)
    $primaryDisks = @($disks | Where-Object {
            [string]$_.PNPDeviceID -notmatch '(?i)(CDROM|VIRTUAL_DVD)'
        })
    $networks = @(Get-CimInstance -ClassName Win32_NetworkAdapter `
            -ErrorAction Stop | Where-Object {
                $_.PhysicalAdapter -eq $true -and $_.NetEnabled -eq $true
            } | Select-Object Name, ProductName, Manufacturer, PNPDeviceID,
                MACAddress, NetEnabled, PhysicalAdapter, ServiceName,
                AdapterType)

    $checks = [Collections.Generic.List[object]]::new()
    [void]$checks.Add((New-VMateGpuPRealityCheck 'NoVMateNamedDevices' `
        ($vmateNamed.Count -eq 0) "Count=$($vmateNamed.Count)"))
    [void]$checks.Add((New-VMateGpuPRealityCheck 'NoPresentProblemDevices' `
        ($problem.Count -eq 0) ("Count=$($problem.Count); " +
            (($problem | ForEach-Object {
                    "$($_.Name)[Code=$($_.ProblemCode)]"
                }) -join ', '))))
    [void]$checks.Add((New-VMateGpuPRealityCheck 'ExactlyOneDisplayAdapter' `
        ($display.Count -eq 1) ("Count=$($display.Count); " +
            (($display.Name) -join ', '))))
    [void]$checks.Add((New-VMateGpuPRealityCheck 'OfficialVendorPnpDriver' `
        ($vendorDisplay.Count -eq 1) ("Count=$($vendorDisplay.Count); " +
            (($display | ForEach-Object {
                    "$($_.Name)/$($_.Service)/$($_.InfName)/$($_.Signer)"
                }) -join ', '))))
    $nameMatch = $vendorDisplay.Count -eq 1 -and
        (-not $ExpectedGpuName -or
            ([string]$vendorDisplay[0].Name).Equals($ExpectedGpuName,
                [StringComparison]::OrdinalIgnoreCase))
    $gpuDetail = if ($vendorDisplay.Count -eq 1) {
        [string]$vendorDisplay[0].Name
    } else { 'No unique official vendor display' }
    [void]$checks.Add((New-VMateGpuPRealityCheck 'ExpectedGpuModel' `
        $nameMatch $gpuDetail))

    $diskIdentity = $primaryDisks.Count -eq 1 -and
        [string]$primaryDisks[0].Model -notmatch
            '(?i)(Microsoft|Msft).*Virtual|Virtual Disk' -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$primaryDisks[0].SerialNumber) -and
        [string]$primaryDisks[0].PNPDeviceID -notmatch
            '(?i)VEN_MSFT&PROD_VIRTUAL_DISK' -and
        (-not $ExpectedStorageModel -or
            ([string]$primaryDisks[0].Model).Equals($ExpectedStorageModel,
                [StringComparison]::OrdinalIgnoreCase))
    [void]$checks.Add((New-VMateGpuPRealityCheck 'PhysicalStorageIdentity' `
        $diskIdentity ("Count=$($primaryDisks.Count); " +
            (($primaryDisks | ForEach-Object {
                    "$($_.Model)/$($_.SerialNumber)/$($_.PNPDeviceID)"
                }) -join ', '))))

    $networkIdentity = $networks.Count -eq 1 -and
        [string]$networks[0].Name -notmatch '(?i)(Hyper-V|Virtual)' -and
        [string]$networks[0].PNPDeviceID -match '(?i)^PCI\\VEN_[0-9A-F]{4}' -and
        -not [string]::IsNullOrWhiteSpace([string]$networks[0].MACAddress) -and
        (-not $ExpectedNetworkModel -or
            ([string]$networks[0].Name).Equals($ExpectedNetworkModel,
                [StringComparison]::OrdinalIgnoreCase))
    [void]$checks.Add((New-VMateGpuPRealityCheck 'PhysicalNetworkIdentity' `
        $networkIdentity ("Count=$($networks.Count); " +
            (($networks | ForEach-Object {
                    "$($_.Name)/$($_.PNPDeviceID)/$($_.MACAddress)"
                }) -join ', '))))
    [void]$checks.Add((New-VMateGpuPRealityCheck 'HyperVNamedArchitecture' `
        ($hyperVNamed.Count -eq 0) ("Count=$($hyperVNamed.Count); " +
            (($hyperVNamed.Name) -join ', ')) 'Architecture'))

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        CollectedAtUtc = [DateTime]::UtcNow.ToString('o')
        ComputerName = $env:COMPUTERNAME
        Vendor = $Vendor
        Checks = @($checks)
        RequiredPassed = @($checks | Where-Object {
                $_.Kind -ceq 'Required' -and -not $_.Passed
            }).Count -eq 0
        SampleParityPassed = @($checks | Where-Object {
                -not $_.Passed
            }).Count -eq 0
        Devices = $devices
        DisplayDevices = $display
        OfficialVendorDisplayDevices = $vendorDisplay
        VMateNamedDevices = $vmateNamed
        HyperVNamedDevices = $hyperVNamed
        ProblemDevices = $problem
        DiskDrives = $disks
        ConnectedPhysicalNetworkAdapters = $networks
    }
}

function Assert-VMateGpuPGuestDeviceReality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD')][string]$Vendor,
        [string]$ExpectedGpuName = '',
        [string]$ExpectedStorageModel = '',
        [string]$ExpectedNetworkModel = '',
        [switch]$RequireNoHyperVNames
    )

    $report = Get-VMateGpuPGuestDeviceReality -Vendor $Vendor `
        -ExpectedGpuName $ExpectedGpuName `
        -ExpectedStorageModel $ExpectedStorageModel `
        -ExpectedNetworkModel $ExpectedNetworkModel
    $failed = @($report.Checks | Where-Object {
            -not $_.Passed -and
            ($_.Kind -ceq 'Required' -or $RequireNoHyperVNames.IsPresent)
        })
    if ($failed.Count -ne 0) {
        throw ('P-11 guest 设备现实门禁失败：' +
            (($failed | ForEach-Object {
                    "$($_.Name)=[$($_.Detail)]"
                }) -join '；'))
    }
    return $report
}

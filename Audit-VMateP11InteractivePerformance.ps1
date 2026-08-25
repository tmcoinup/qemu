#Requires -Version 5.1

param(
    [string]$OutputPath = 'C:\VMateLab\interactive-performance-baseline.json'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-VMateSamplePassword {
    $lines = Get-Content -LiteralPath `
        'C:\VMateLab\Probe-VMateSampleGuests.ps1' -Encoding UTF8
    $code = $lines[3] + [Environment]::NewLine + 'return $password'
    return & ([scriptblock]::Create($code))
}

function Get-VMateP11Credential {
    $lines = Get-Content -LiteralPath `
        'C:\VMateLab\Probe-VMateP11Guest.ps1' -Encoding UTF8
    $code = ($lines[3..4] -join [Environment]::NewLine) +
        [Environment]::NewLine + 'return $credential'
    return & ([scriptblock]::Create($code))
}

function Select-VMateProperties {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Property
    )
    if ($null -eq $InputObject) { return $null }
    return $InputObject | Select-Object -Property $Property
}

function Get-VMateGuestInteractiveSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][PSCredential]$Credential
    )

    $session = $null
    try {
        $session = New-PSSession -VMName $VMName -Credential $Credential `
            -ErrorAction Stop
        $snapshot = Invoke-Command -Session $session -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $display = @(Get-CimInstance Win32_PnPEntity | Where-Object {
                    $_.PNPClass -eq 'Display'
                } | Select-Object Name, Manufacturer, PNPDeviceID, Status,
                    ConfigManagerErrorCode, Service)
            $video = @(Get-CimInstance Win32_VideoController |
                Select-Object Name, PNPDeviceID, Status, DriverVersion,
                    AdapterRAM, VideoProcessor, CurrentHorizontalResolution,
                    CurrentVerticalResolution, CurrentRefreshRate)
            $pointing = @(Get-CimInstance Win32_PointingDevice |
                Select-Object Name, Manufacturer, PNPDeviceID, Status,
                    HardwareType, NumberOfButtons)
            $pnpInput = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
                Where-Object { $_.Class -in @('Mouse', 'HIDClass') } |
                Select-Object Class, FriendlyName, InstanceId, Status,
                    Manufacturer)
            $services = @(Get-CimInstance Win32_Service | Where-Object {
                    $_.Name -like 'vmic*' -or
                    $_.Name -in @('TermService', 'SessionEnv', 'UmRdpService',
                        'NVDisplay.ContainerLocalSystem') -or
                    $_.Name -match '(?i)guestctrl|vmspoofer|gameviewer'
                } | Select-Object Name, DisplayName, State, StartMode,
                    PathName, ProcessId)
            $processes = @(Get-CimInstance Win32_Process | Where-Object {
                    $_.Name -in @('dwm.exe', 'explorer.exe', 'rdpclip.exe',
                        'GuestCtrl.exe', 'VMSpoofer.exe', 'monitor.exe',
                        'nvidia-smi.exe')
                } | Select-Object Name, ProcessId, ParentProcessId, SessionId,
                    ExecutablePath, CommandLine)
            $mouse = Get-ItemProperty -LiteralPath `
                'HKCU:\Control Panel\Mouse' -ErrorAction SilentlyContinue
            $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue |
                Select-Object -First 1
            $smiRows = if ($null -eq $smi) { @() } else {
                try {
                    @(& $smi.Source `
                        '--query-gpu=name,driver_version,pstate,utilization.gpu,memory.total,memory.used,clocks.current.graphics' `
                        '--format=csv,noheader,nounits' 2>&1)
                }
                catch { @($_.Exception.Message) }
            }
            $activePowerScheme = try {
                @(& powercfg.exe /GetActiveScheme 2>&1)
            }
            catch { @($_.Exception.Message) }
            $sessions = try { @(& quser.exe 2>&1) }
            catch { @($_.Exception.Message) }
            return [pscustomobject][ordered]@{
                ComputerName = $env:COMPUTERNAME
                OperatingSystem = Get-CimInstance Win32_OperatingSystem |
                    Select-Object Caption, Version, BuildNumber, OSArchitecture,
                        LastBootUpTime, FreePhysicalMemory
                ComputerSystem = Get-CimInstance Win32_ComputerSystem |
                    Select-Object Manufacturer, Model, HypervisorPresent,
                        NumberOfLogicalProcessors, TotalPhysicalMemory
                Video = $video
                Display = $display
                PointingDevices = $pointing
                PresentInputDevices = $pnpInput
                Services = $services
                Processes = $processes
                MouseSettings = if ($null -eq $mouse) { $null } else {
                    [pscustomobject][ordered]@{
                        MouseSensitivity = [string]$mouse.MouseSensitivity
                        MouseSpeed = [string]$mouse.MouseSpeed
                        MouseThreshold1 = [string]$mouse.MouseThreshold1
                        MouseThreshold2 = [string]$mouse.MouseThreshold2
                    }
                }
                ActivePowerScheme = $activePowerScheme
                UserSessions = $sessions
                NvidiaSmi = $smiRows
            }
        } -ErrorAction Stop
        return [pscustomobject][ordered]@{
            VMName = $VMName
            Status = 'Ready'
            Snapshot = $snapshot
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            VMName = $VMName
            Status = 'Unavailable'
            Message = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

function Get-VMateHostVMSnapshot {
    param([Parameter(Mandatory = $true)][string]$VMName)

    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $processor = Get-VMProcessor -VMName $VMName -ErrorAction Stop
    $memory = Get-VMMemory -VMName $VMName -ErrorAction Stop
    $firmware = Get-VMFirmware -VMName $VMName -ErrorAction Stop
    $gpu = @(Get-VMGpuPartitionAdapter -VMName $VMName `
            -ErrorAction SilentlyContinue)
    return [pscustomobject][ordered]@{
        VM = Select-VMateProperties $vm @(
            'Name', 'Id', 'State', 'Status', 'Version', 'Generation',
            'ProcessorCount', 'MemoryStartup', 'MemoryAssigned', 'MemoryDemand',
            'MemoryStatus', 'Uptime', 'EnhancedSessionTransportType',
            'AutomaticStartAction', 'AutomaticStopAction', 'CheckpointType')
        Processor = Select-VMateProperties $processor @(
            'Count', 'Maximum', 'Reserve', 'RelativeWeight',
            'HwThreadCountPerCore', 'ExposeVirtualizationExtensions',
            'CompatibilityForMigrationEnabled',
            'CompatibilityForOlderOperatingSystemsEnabled',
            'EnableHostResourceProtection')
        Memory = Select-VMateProperties $memory @(
            'DynamicMemoryEnabled', 'Startup', 'Minimum', 'Maximum', 'Buffer',
            'Priority')
        Firmware = Select-VMateProperties $firmware @(
            'SecureBoot', 'SecureBootTemplate', 'PreferredNetworkBootProtocol',
            'ConsoleMode')
        GpuAdapters = @($gpu | Select-Object InstancePath, PartitionId,
            PartitionVfLuid, MinPartitionVRAM, MaxPartitionVRAM,
            OptimalPartitionVRAM, MinPartitionEncode, MaxPartitionEncode,
            OptimalPartitionEncode, MinPartitionDecode, MaxPartitionDecode,
            OptimalPartitionDecode, MinPartitionCompute, MaxPartitionCompute,
            OptimalPartitionCompute)
        IntegrationServices = @(Get-VMIntegrationService -VMName $VMName |
            Select-Object Name, Id, Enabled, PrimaryStatusDescription,
                SecondaryStatusDescription)
        NetworkAdapters = @(Get-VMNetworkAdapter -VMName $VMName |
            Select-Object Name, SwitchName, MacAddress, DynamicMacAddressEnabled,
                Status, IPAddresses)
        HardDisks = @(Get-VMHardDiskDrive -VMName $VMName |
            Select-Object ControllerType, ControllerNumber,
                ControllerLocation, Path)
        DvdDrives = @(Get-VMDvdDrive -VMName $VMName |
            Select-Object ControllerNumber, ControllerLocation, Path)
    }
}

$samplePassword = Get-VMateSamplePassword
$sampleCredentials = @{}
foreach ($vmName in @('pc01', 'pc02')) {
    $sampleCredentials[$vmName] = [PSCredential]::new(
        ($vmName + '\Administrator'), $samplePassword)
}
$p11Credential = Get-VMateP11Credential

$hostProcesses = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('VMSpoofer.exe', 'GuestCtrl.exe', 'monitor.exe',
            'vmconnect.exe', 'mstsc.exe', 'vmwp.exe')
    } | Select-Object Name, ProcessId, ParentProcessId, SessionId,
        ExecutablePath, CommandLine)
$partitionCommand = @('Get-VMHostPartitionableGpu',
    'Get-VMPartitionableGpu') | Where-Object {
        Get-Command -Name $_ -ErrorAction SilentlyContinue
    } | Select-Object -First 1
$hostPartitionable = if ($null -eq $partitionCommand) { @() } else {
    @(& $partitionCommand -ErrorAction Stop | Select-Object *)
}
$vmHost = Get-VMHost -ErrorAction Stop

$result = [pscustomobject][ordered]@{
    SchemaVersion = 1
    CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    Host = [pscustomobject][ordered]@{
        OperatingSystem = Get-CimInstance Win32_OperatingSystem |
            Select-Object Caption, Version, BuildNumber, OSArchitecture,
                LastBootUpTime, FreePhysicalMemory
        VMHost = Select-VMateProperties $vmHost @(
            'VirtualMachineMigrationEnabled', 'VirtualMachineMigrationAuthType',
            'UseAnyNetworkForMigration', 'MaximumVirtualMachineMigrations',
            'MaximumStorageMigrations', 'EnableEnhancedSessionMode',
            'MacAddressMinimum', 'MacAddressMaximum')
        PartitionableGpu = $hostPartitionable
        RelevantProcesses = $hostProcesses
    }
    VirtualMachines = @(
        Get-VMateHostVMSnapshot 'pc01'
        Get-VMateHostVMSnapshot 'pc02'
        Get-VMateHostVMSnapshot 'P11-Lab'
    )
    Guests = @(
        Get-VMateGuestInteractiveSnapshot 'pc01' $sampleCredentials.pc01
        Get-VMateGuestInteractiveSnapshot 'pc02' $sampleCredentials.pc02
        Get-VMateGuestInteractiveSnapshot 'P11-Lab' $p11Credential
    )
}

$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath `
    -Encoding UTF8
[pscustomobject][ordered]@{
    OutputPath = $OutputPath
    HostVmCount = @($result.VirtualMachines).Count
    GuestReady = @($result.Guests | Where-Object Status -EQ 'Ready').Count
    GuestUnavailable = @($result.Guests |
        Where-Object Status -NE 'Ready').Count
} | ConvertTo-Json -Compress

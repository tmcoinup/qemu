#requires -Version 5.1
<#
.SYNOPSIS
    在 Windows 客体内并行采集硬件、驱动、可选进程模块和错误日志。
.DESCRIPTION
    所有探针只读，每项输出独立 JSON/TXT 与状态文件。管理员权限会提供更完整的
    PnP/事件证据，但脚本不会请求提权，也不会修改注册表、驱动或系统设置。
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Get-Location) (
            "vmate-hardware-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [ValidateRange(1, 8)]
    [int]$Parallelism = 4,
    [ValidateRange(5, 600)]
    [int]$TimeoutSeconds = 90,
    [AllowEmptyCollection()]
    [string[]]$ProcessName = @()
)

$ErrorActionPreference = 'Stop'
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
[void](New-Item -ItemType Directory -Path $resolvedOutput -Force)

# 每个 job 只返回可序列化对象；父进程统一写 UTF-8，避免后台进程同时写同一文件。
$probes = [ordered]@{
    ComputerSystem = {
        Get-CimInstance Win32_ComputerSystem |
            Select-Object Manufacturer, Model, SystemFamily, SystemType,
                TotalPhysicalMemory, NumberOfProcessors, NumberOfLogicalProcessors,
                HypervisorPresent
    }
    ComputerSystemProduct = {
        Get-CimInstance Win32_ComputerSystemProduct |
            Select-Object Vendor, Name, Version, IdentifyingNumber, UUID, SKUNumber
    }
    BaseBoard = {
        Get-CimInstance Win32_BaseBoard |
            Select-Object Manufacturer, Product, Version, SerialNumber, Tag
    }
    Bios = {
        Get-CimInstance Win32_BIOS |
            Select-Object Manufacturer, SMBIOSBIOSVersion, ReleaseDate, SerialNumber,
                SMBIOSMajorVersion, SMBIOSMinorVersion, BiosCharacteristics
    }
    Processor = {
        Get-CimInstance Win32_Processor |
            Select-Object Manufacturer, Name, Description, ProcessorId, SocketDesignation,
                NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed, CurrentClockSpeed,
                AddressWidth, DataWidth, Family, Revision, SerialNumber, AssetTag
    }
    PhysicalMemory = {
        Get-CimInstance Win32_PhysicalMemory |
            Select-Object BankLabel, DeviceLocator, Capacity, Speed, ConfiguredClockSpeed,
                Manufacturer, PartNumber, SerialNumber, MemoryType, SMBIOSMemoryType,
                TypeDetail, FormFactor, TotalWidth, DataWidth, ConfiguredVoltage
    }
    MemoryArray = {
        Get-CimInstance Win32_PhysicalMemoryArray |
            Select-Object Location, Use, MemoryDevices, MaxCapacity, MaxCapacityEx,
                MemoryErrorCorrection
    }
    DiskDrive = {
        Get-CimInstance Win32_DiskDrive |
            Select-Object Index, Model, SerialNumber, FirmwareRevision, Size, InterfaceType,
                PNPDeviceID, SCSIBus, SCSIPort, Status
    }
    PhysicalDisk = {
        Get-PhysicalDisk |
            Select-Object FriendlyName, SerialNumber, FirmwareVersion, MediaType, BusType,
                Size, HealthStatus, OperationalStatus, PhysicalLocation
    }
    NetworkAdapter = {
        Get-CimInstance Win32_NetworkAdapter |
            Where-Object PhysicalAdapter |
            Select-Object Name, Manufacturer, MACAddress, PNPDeviceID, ProductName,
                NetConnectionStatus, Speed
    }
    VideoController = {
        Get-CimInstance Win32_VideoController |
            Select-Object Name, AdapterCompatibility, PNPDeviceID, DriverVersion,
                VideoProcessor, AdapterRAM, CurrentHorizontalResolution,
                CurrentVerticalResolution, CurrentRefreshRate, Status
    }
    SoundDevice = {
        Get-CimInstance Win32_SoundDevice |
            Select-Object Manufacturer, Name, ProductName, PNPDeviceID, Status
    }
    PnpSignedDrivers = {
        Get-CimInstance Win32_PnPSignedDriver |
            Select-Object DeviceName, DeviceID, Manufacturer, DriverProviderName,
                DriverVersion, DriverDate, InfName, IsSigned
    }
    SystemDrivers = {
        Get-CimInstance Win32_SystemDriver |
            Select-Object Name, DisplayName, Description, State, Status, Started,
                StartMode, ServiceType, PathName, ErrorControl, ExitCode, InstallDate
    }
    PnpDevices = {
        Get-PnpDevice -PresentOnly |
            Select-Object Class, FriendlyName, InstanceId, Status, Problem
    }
    Tpm = {
        if (Get-Command Get-Tpm -ErrorAction SilentlyContinue) {
            Get-Tpm |
                Select-Object TpmPresent, TpmReady, TpmEnabled, TpmActivated,
                    TpmOwned, ManufacturerIdTxt, ManufacturerVersion, SpecVersion
        } else {
            [pscustomobject]@{ Unavailable = 'Get-Tpm command not installed' }
        }
    }
    SystemErrors = {
        Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            Level = 1, 2, 3
        } -MaxEvents 300 |
            Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message
    }
    DriverInstallEvents = {
        $since = (Get-Date).AddDays(-7)
        $queries = @(
            [pscustomobject]@{ Name = 'KernelPnP'; Filter = @{
                    LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-PnP'
                    Id = 219, 225; StartTime = $since } },
            [pscustomobject]@{ Name = 'UserPnp'; Filter = @{
                    LogName = 'System'; ProviderName = 'Microsoft-Windows-UserPnp'
                    Id = 20001, 20003; StartTime = $since } },
            [pscustomobject]@{ Name = 'ServiceInstall'; Filter = @{
                    LogName = 'System'; ProviderName = 'Service Control Manager'
                    Id = 7045; StartTime = $since } },
            [pscustomobject]@{ Name = 'DeviceSetupManager'; Filter = @{
                    LogName = 'Microsoft-Windows-DeviceSetupManager/Admin'
                    Id = 400, 410, 420; StartTime = $since } }
        )
        $events = [Collections.Generic.List[object]]::new()
        $queryStatus = [Collections.Generic.List[object]]::new()
        $collectionErrors = [Collections.Generic.List[string]]::new()
        foreach ($query in $queries) {
            $queryEvents = @()
            $queryError = $null
            try {
                $queryEvents = @(Get-WinEvent -FilterHashtable $query.Filter -MaxEvents 1000 -ErrorAction Stop)
            } catch {
                $isEmptyResult = ([string]$_.FullyQualifiedErrorId).StartsWith(
                    'NoMatchingEventsFound', [StringComparison]::OrdinalIgnoreCase)
                if (-not $isEmptyResult) {
                    $queryError = $_.Exception.Message
                    $collectionErrors.Add("$($query.Name): $queryError")
                }
            }
            foreach ($event in $queryEvents) { $events.Add($event) }
            $queryStatus.Add([pscustomobject]@{
                    name = $query.Name
                    event_count = $queryEvents.Count
                    error = $queryError
                })
        }
        [pscustomobject][ordered]@{
            query_status = @($queryStatus)
            events = @($events | Sort-Object TimeCreated -Descending |
                Select-Object -First 3000 TimeCreated, Id, LevelDisplayName,
                    ProviderName, Message)
            collection_errors = @($collectionErrors)
        }
    }
}

function Write-ProbeResult {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Job]$Job,
        [Parameter(Mandatory)] [string]$Name
    )

    $statusPath = Join-Path $resolvedOutput "$Name.status.json"
    $dataPath = Join-Path $resolvedOutput "$Name.json"
    $status = [ordered]@{
        name = $Name
        state = $Job.State.ToString()
        completed_at = $null
        error = @()
    }
    try {
        $data = Receive-Job -Job $Job -ErrorAction Stop
        $data | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $dataPath -Encoding UTF8
        foreach ($item in @($data)) {
            if ($null -ne $item -and
                $null -ne $item.PSObject.Properties['collection_errors']) {
                foreach ($message in @($item.collection_errors)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$message)) {
                        $status.error += [string]$message
                    }
                }
            }
        }
    } catch {
        $status.error += $_.Exception.Message
    }
    foreach ($jobError in @($Job.ChildJobs.Error)) {
        if ($null -ne $jobError) { $status.error += $jobError.ToString() }
    }
    foreach ($reason in @($Job.ChildJobs.JobStateInfo.Reason)) {
        if ($null -ne $reason) { $status.error += $reason.Message }
    }
    $status.completed_at = (Get-Date).ToString('o')
    $status | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $statusPath -Encoding UTF8
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    return [pscustomobject]$status
}

# 进程、SetupAPI 与驱动二进制证据优先入队，避免短生命周期安装器在常规探针后退出。
$pending = [Collections.Queue]::new()
if ($ProcessName.Count -gt 0) {
    $helperPath = Join-Path $PSScriptRoot 'lib\VMate.ProcessEvidence.ps1'
    $fileHelperPath = Join-Path $PSScriptRoot 'lib\VMate.FileEvidence.ps1'
    foreach ($requiredHelper in @($helperPath, $fileHelperPath)) {
        if (-not (Test-Path -LiteralPath $requiredHelper -PathType Leaf)) {
            throw "缺少只读证据模块: $requiredHelper"
        }
    }
    $processContext = [pscustomobject]@{
        HelperPath = $helperPath
        RequestedNames = [string[]]@($ProcessName)
    }
    $pending.Enqueue([pscustomobject]@{
        Name = 'ProcessEvidence'
        ScriptBlock = {
            param($Context)
            . ([string]$Context.HelperPath)
            Get-VMateProcessEvidence -RequestedNames @($Context.RequestedNames)
        }
        ArgumentList = @($processContext)
    })
    $helperContext = [pscustomobject]@{ HelperPath = $helperPath }
    $pending.Enqueue([pscustomobject]@{
        Name = 'SetupApiDevLog'
        ScriptBlock = {
            param($Context)
            . ([string]$Context.HelperPath)
            Get-VMateSetupApiEvidence
        }
        ArgumentList = @($helperContext)
    })
    $pending.Enqueue([pscustomobject]@{
        Name = 'SystemDriverFiles'
        ScriptBlock = {
            param($Context)
            . ([string]$Context.HelperPath)
            Get-VMateSystemDriverEvidence
        }
        ArgumentList = @($helperContext)
    })
}
foreach ($entry in $probes.GetEnumerator()) {
    $pending.Enqueue([pscustomobject]@{
        Name = $entry.Key
        ScriptBlock = $entry.Value
        ArgumentList = @()
    })
}

# Start-Job 隔离可能卡顿的 CIM/WMI，并对每项执行硬超时；单项失败不会阻塞其它探针。
$running = @{}
$statuses = [Collections.Generic.List[object]]::new()
while ($pending.Count -gt 0 -or $running.Count -gt 0) {
    while ($pending.Count -gt 0 -and $running.Count -lt $Parallelism) {
        $entry = $pending.Dequeue()
        $startParameters = @{
            Name = $entry.Name
            ScriptBlock = $entry.ScriptBlock
        }
        if (@($entry.ArgumentList).Count -gt 0) {
            $startParameters.ArgumentList = @($entry.ArgumentList)
        }
        $job = Start-Job @startParameters
        $running[$job.Id] = [pscustomobject]@{
            Job = $job
            Name = $entry.Name
            Started = [DateTime]::UtcNow
        }
    }

    foreach ($id in @($running.Keys)) {
        $record = $running[$id]
        $elapsed = ([DateTime]::UtcNow - $record.Started).TotalSeconds
        if ($record.Job.State -in 'Completed', 'Failed', 'Stopped') {
            $statuses.Add((Write-ProbeResult -Job $record.Job -Name $record.Name))
            $running.Remove($id)
        } elseif ($elapsed -ge $TimeoutSeconds) {
            Stop-Job -Job $record.Job -ErrorAction SilentlyContinue
            $statuses.Add((Write-ProbeResult -Job $record.Job -Name $record.Name))
            $running.Remove($id)
        }
    }
    if ($running.Count -gt 0) { Start-Sleep -Milliseconds 150 }
}

# 原生命令补齐硬件 ID、当前 DriverStore 库存、电源能力和详细驱动列表。
$nativeCommands = [ordered]@{
    PnpUtil = @('pnputil.exe', '/enum-devices', '/connected', '/deviceids')
    PnpDriverStore = @('pnputil.exe', '/enum-drivers')
    PowerCfg = @('powercfg.exe', '/a')
    DriverQuery = @('driverquery.exe', '/v', '/fo', 'csv')
}
foreach ($entry in $nativeCommands.GetEnumerator()) {
    $outputPath = Join-Path $resolvedOutput "$($entry.Key).txt"
    $nativeStatus = [ordered]@{
        name = $entry.Key
        state = 'Completed'
        completed_at = $null
        exit_code = $null
        error = @()
    }
    try {
        $arguments = @($entry.Value | Select-Object -Skip 1)
        $commandOutput = @(& $entry.Value[0] @arguments 2>&1)
        $nativeStatus.exit_code = $LASTEXITCODE
        $commandOutput | Set-Content -LiteralPath $outputPath -Encoding UTF8
        if ($LASTEXITCODE -ne 0) {
            $nativeStatus.state = 'Failed'
            $nativeStatus.error += "原生命令退出码: $LASTEXITCODE"
        }
    } catch {
        $nativeStatus.state = 'Failed'
        $nativeStatus.error += $_.Exception.Message
        $_ | Out-String | Set-Content -LiteralPath $outputPath -Encoding UTF8
    }
    $nativeStatus.completed_at = (Get-Date).ToString('o')
    $nativeStatusPath = Join-Path $resolvedOutput "$($entry.Key).status.json"
    $nativeStatus | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $nativeStatusPath -Encoding UTF8
    $statuses.Add([pscustomobject]$nativeStatus)
}

$dxdiagStatus = [ordered]@{
    name = 'DxDiag'
    state = 'Completed'
    completed_at = $null
    exit_code = $null
    error = @()
}
try {
    & dxdiag.exe /whql:off /t (Join-Path $resolvedOutput 'DxDiag.txt') | Out-Null
    $dxdiagStatus.exit_code = $LASTEXITCODE
    if ($LASTEXITCODE -ne 0) {
        $dxdiagStatus.state = 'Failed'
        $dxdiagStatus.error += "dxdiag 退出码: $LASTEXITCODE"
    }
} catch {
    $dxdiagStatus.state = 'Failed'
    $dxdiagStatus.error += $_.Exception.Message
    $_ | Out-String |
        Set-Content -LiteralPath (Join-Path $resolvedOutput 'DxDiag-error.txt') -Encoding UTF8
}
$dxdiagStatus.completed_at = (Get-Date).ToString('o')
$dxdiagStatus | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath (Join-Path $resolvedOutput 'DxDiag.status.json') -Encoding UTF8
$statuses.Add([pscustomobject]$dxdiagStatus)

$failed = @($statuses | Where-Object {
        $_.state -ne 'Completed' -or @($_.error).Count -gt 0
    })
$summary = [ordered]@{
    generated_at = (Get-Date).ToString('o')
    computer = $env:COMPUTERNAME
    powershell = $PSVersionTable.PSVersion.ToString()
    output_directory = $resolvedOutput
    requested_process_names = @($ProcessName)
    contains_sensitive_data = $true
    probe_count = $statuses.Count
    failed_count = $failed.Count
    probes = $statuses
}
$summary | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $resolvedOutput 'SUMMARY.json') -Encoding UTF8

Write-Host "Windows hardware snapshot: $resolvedOutput"
Write-Host "probes=$($statuses.Count), failed=$($failed.Count)"
if ($failed.Count -gt 0) { exit 1 }

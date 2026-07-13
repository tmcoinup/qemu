#requires -Version 5.1
<#
.SYNOPSIS
    在 Windows 客体内并行采集 CPU、SMBIOS、PCI/USB、存储、TPM 和错误日志。
.DESCRIPTION
    所有探针只读，每项输出独立 JSON/TXT 与状态文件。管理员权限会提供更完整的
    PnP/事件证据，但脚本不会请求提权，也不会修改注册表、驱动或系统设置。
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Get-Location) ("vmate-hardware-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [ValidateRange(1, 8)]
    [int]$Parallelism = 4,
    [ValidateRange(5, 600)]
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
[void](New-Item -ItemType Directory -Path $resolvedOutput -Force)

# 每个 job 只返回可序列化对象；父进程统一写 UTF-8，避免后台进程同时写同一文件。
$probes = [ordered]@{
    ComputerSystem = {
        Get-CimInstance Win32_ComputerSystem |
            Select-Object Manufacturer, Model, SystemFamily, SystemType, TotalPhysicalMemory,
                NumberOfProcessors, NumberOfLogicalProcessors, HypervisorPresent
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
    PnpDevices = {
        Get-PnpDevice -PresentOnly |
            Select-Object Class, FriendlyName, InstanceId, Status, Problem
    }
    Tpm = {
        if (Get-Command Get-Tpm -ErrorAction SilentlyContinue) {
            Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, TpmActivated,
                TpmOwned, ManufacturerIdTxt, ManufacturerVersion, SpecVersion
        } else {
            [pscustomobject]@{ Unavailable = 'Get-Tpm command not installed' }
        }
    }
    SystemErrors = {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2, 3 } -MaxEvents 300 |
            Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message
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
        completed_at = (Get-Date).ToString('o')
        error = @()
    }
    try {
        $data = Receive-Job -Job $Job -ErrorAction Stop
        $data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $dataPath -Encoding UTF8
    } catch {
        $status.error += $_.Exception.Message
    }
    foreach ($reason in $Job.ChildJobs.JobStateInfo.Reason) {
        if ($null -ne $reason) {
            $status.error += $reason.Message
        }
    }
    $status | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statusPath -Encoding UTF8
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    return $status
}

# Start-Job 使用独立进程，CIM/WMI 卡顿不会阻塞界面或其它探针。队列限制并发数，
# 并对每个探针执行硬超时；超时只影响该项，最终摘要会明确标记失败。
$pending = [System.Collections.Queue]::new()
foreach ($entry in $probes.GetEnumerator()) {
    $pending.Enqueue($entry)
}
$running = @{}
$statuses = [System.Collections.Generic.List[object]]::new()
while ($pending.Count -gt 0 -or $running.Count -gt 0) {
    while ($pending.Count -gt 0 -and $running.Count -lt $Parallelism) {
        $entry = $pending.Dequeue()
        $job = Start-Job -Name $entry.Key -ScriptBlock $entry.Value
        $running[$job.Id] = [pscustomobject]@{
            Job = $job
            Name = $entry.Key
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
    if ($running.Count -gt 0) {
        Start-Sleep -Milliseconds 150
    }
}

# 原生命令保留文本输出，补齐 pnputil 的硬件 ID、powercfg 能力与 dxdiag 信息。
$nativeCommands = [ordered]@{
    PnpUtil = @('pnputil.exe', '/enum-devices', '/connected', '/deviceids')
    PowerCfg = @('powercfg.exe', '/a')
    DriverQuery = @('driverquery.exe', '/v', '/fo', 'csv')
}
foreach ($entry in $nativeCommands.GetEnumerator()) {
    $outputPath = Join-Path $resolvedOutput "$($entry.Key).txt"
    try {
        & $entry.Value[0] $entry.Value[1..($entry.Value.Count - 1)] 2>&1 |
            Set-Content -LiteralPath $outputPath -Encoding UTF8
    } catch {
        $_ | Out-String | Set-Content -LiteralPath $outputPath -Encoding UTF8
    }
}
try {
    & dxdiag.exe /whql:off /t (Join-Path $resolvedOutput 'DxDiag.txt') | Out-Null
} catch {
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $resolvedOutput 'DxDiag-error.txt') -Encoding UTF8
}

$failed = @($statuses | Where-Object { $_.state -ne 'Completed' -or $_.error.Count -gt 0 })
$summary = [ordered]@{
    generated_at = (Get-Date).ToString('o')
    computer = $env:COMPUTERNAME
    powershell = $PSVersionTable.PSVersion.ToString()
    output_directory = $resolvedOutput
    probe_count = $statuses.Count
    failed_count = $failed.Count
    probes = $statuses
}
$summary | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $resolvedOutput 'SUMMARY.json') -Encoding UTF8

Write-Host "Windows hardware snapshot: $resolvedOutput"
Write-Host "probes=$($statuses.Count), failed=$($failed.Count)"
if ($failed.Count -gt 0) { exit 1 }

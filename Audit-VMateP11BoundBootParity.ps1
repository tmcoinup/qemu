#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$DetectorPath = 'C:\VMateAudit\Detect-VGpuP.ps1',
    [string]$OutputPath = 'C:\VMateAudit\p11-bound-boot-parity.json',
    [string]$TaskName = 'VMateP11BoundBootAuditOnce',
    [ValidateRange(5, 300)][int]$ReadinessTimeoutSeconds = 180,
    [switch]$ShutdownAfterAudit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Invoke-VMateAuditSafe {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)

    try { return & $Script }
    catch {
        return [pscustomobject][ordered]@{
            AuditError = $_.Exception.Message
            ErrorType = $_.Exception.GetType().FullName
        }
    }
}

function Get-VMateNvidiaSmiPath {
    $command = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) { return [string]$command.Source }
    $candidate = Join-Path $env:ProgramFiles `
        'NVIDIA Corporation\NVSMI\nvidia-smi.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }
    return ''
}

$startedAt = [DateTime]::UtcNow
$deadline = $startedAt.AddSeconds($ReadinessTimeoutSeconds)
$ready = $false
$lastDisplays = @()
do {
    $lastDisplays = @(Get-CimInstance Win32_PnPEntity `
            -ErrorAction SilentlyContinue | Where-Object {
                [string]$_.PNPClass -ceq 'Display'
            })
    $ready = @($lastDisplays | Where-Object {
            [string]$_.Status -ceq 'OK' -and
            [int]$_.ConfigManagerErrorCode -eq 0
        }).Count -gt 0
    if (-not $ready) { Start-Sleep -Seconds 1 }
} while (-not $ready -and [DateTime]::UtcNow -lt $deadline)

$detectorPathResolved = [IO.Path]::GetFullPath($DetectorPath)
$outputPathResolved = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = [IO.Path]::GetDirectoryName($outputPathResolved)
[IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
$detectorOutput = Join-Path $outputDirectory 'detector.json'
$detectorExitCode = -1
$detector = $null
$detectorError = ''
try {
    if (-not (Test-Path -LiteralPath $detectorPathResolved -PathType Leaf)) {
        throw "Detector is missing: $detectorPathResolved"
    }
    $detectorText = @(& powershell.exe -NoLogo -NoProfile -NonInteractive `
            -ExecutionPolicy Bypass -File $detectorPathResolved -Json -NoPause `
            -OutputPath $detectorOutput 2>&1)
    $detectorExitCode = $LASTEXITCODE
    if ($detectorExitCode -ne 0) {
        throw ("Detector exit code {0}: {1}" -f $detectorExitCode,
            ($detectorText -join ' '))
    }
    $detector = Get-Content -LiteralPath $detectorOutput -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
}
catch { $detectorError = $_.Exception.Message }

$nvidiaSmiPath = Get-VMateNvidiaSmiPath
$nvidiaSmi = if ($nvidiaSmiPath) {
    Invoke-VMateAuditSafe {
        @(& $nvidiaSmiPath `
                '--query-gpu=name,driver_version,pci.bus_id,pstate,utilization.gpu,memory.total,memory.used' `
                '--format=csv,noheader,nounits' 2>&1)
    }
}
else { @() }

$displayDevices = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
    Where-Object { [string]$_.PNPClass -ceq 'Display' } |
    Select-Object Name, Manufacturer, PNPDeviceID, HardwareID, CompatibleID,
        Status, ConfigManagerErrorCode, Service, Present)
$location = @($displayDevices | ForEach-Object {
        $instanceId = [string]$_.PNPDeviceID
        $property = Get-PnpDeviceProperty -InstanceId $instanceId `
            -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue
        $locationInfo = ''
        if ($null -ne $property) {
            $dataProperty = $property.PSObject.Properties['Data']
            if ($null -ne $dataProperty) {
                $locationInfo = [string]$dataProperty.Value
            }
        }
        [pscustomobject][ordered]@{
            InstanceId = $instanceId
            LocationInfo = $locationInfo
        }
    })
$vmbus = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
    Where-Object { [string]$_.PNPDeviceID -like 'VMBUS\*' })
$guestParameters =
    'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters'
$hostDriverStore = Join-Path $env:windir `
    'System32\HostDriverStore\FileRepository'

$result = [pscustomobject][ordered]@{
    SchemaVersion = 1
    Contract = 'vmate-p11-bound-loader-cold-boot-parity-v1'
    CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    BootWaitSeconds = [Math]::Round(
        ([DateTime]::UtcNow - $startedAt).TotalSeconds, 3)
    DisplayReady = $ready
    ComputerSystem = Invoke-VMateAuditSafe {
        Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,
            Model, SystemFamily, SystemSKUNumber, HypervisorPresent,
            NumberOfProcessors, NumberOfLogicalProcessors, TotalPhysicalMemory
    }
    Processor = @(Invoke-VMateAuditSafe {
            Get-CimInstance Win32_Processor | Select-Object Manufacturer, Name,
                Description, ProcessorId, NumberOfCores,
                NumberOfLogicalProcessors, MaxClockSpeed, SocketDesignation
        })
    BaseBoard = @(Invoke-VMateAuditSafe {
            Get-CimInstance Win32_BaseBoard | Select-Object Manufacturer,
                Product, Version, SerialNumber
        })
    BIOS = @(Invoke-VMateAuditSafe {
            Get-CimInstance Win32_BIOS | Select-Object Manufacturer, Name,
                SMBIOSBIOSVersion, SerialNumber, Version, ReleaseDate
        })
    VideoController = @(Invoke-VMateAuditSafe {
            Get-CimInstance Win32_VideoController | Select-Object Name,
                PNPDeviceID, Status, DriverVersion, AdapterRAM, VideoProcessor,
                CurrentHorizontalResolution, CurrentVerticalResolution,
                CurrentRefreshRate
        })
    DisplayPnP = $displayDevices
    DisplayLocation = $location
    SignedDisplayDriver = @(Invoke-VMateAuditSafe {
            Get-CimInstance Win32_PnPSignedDriver | Where-Object {
                [string]$_.DeviceClass -ceq 'DISPLAY'
            } | Select-Object DeviceName, DeviceID, DriverProviderName,
                DriverVersion, InfName, IsSigned, Signer, Manufacturer
        })
    NvidiaSmi = $nvidiaSmi
    ArtifactEvidence = [pscustomobject][ordered]@{
        GuestParametersPresent = Test-Path -LiteralPath $guestParameters
        VmbusNodeCount = $vmbus.Count
        HostDriverStorePresent =
            Test-Path -LiteralPath $hostDriverStore -PathType Container
    }
    DetectorExitCode = $detectorExitCode
    DetectorError = $detectorError
    Detector = $detector
    OneShotTask = $TaskName
    ShutdownRequested = $ShutdownAfterAudit.IsPresent
}

$temporaryPath = $outputPathResolved + '.tmp'
$json = $result | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText($temporaryPath, $json,
    [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temporaryPath -Destination $outputPathResolved -Force

try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false `
        -ErrorAction Stop
}
catch { }

if ($ShutdownAfterAudit.IsPresent) {
    & shutdown.exe /s /t 15 /d p:4:1 `
        /c 'VMate one-shot bound-loader parity audit completed'
}

$result

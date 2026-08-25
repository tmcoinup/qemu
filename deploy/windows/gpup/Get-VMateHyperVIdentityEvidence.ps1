#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$VMName,
    [Parameter(Mandatory = $true)][ValidateNotNull()][pscredential]$Credential,
    [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$DetectorPath,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [ValidateRange(15, 300)][int]$TimeoutSeconds = 75,
    [switch]$SkipEfiStatus
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$vm = Get-VM -Name $VMName -ErrorAction Stop
if ($vm.State -ne 'Running') {
    throw "VM '$VMName' must be running for PowerShell Direct evidence collection."
}

$detectorSource = Get-Content -LiteralPath $DetectorPath -Raw -ErrorAction Stop
$session = New-PSSession -VMName $VMName -Credential $Credential -ErrorAction Stop
try {
    $result = Invoke-Command -Session $session -ScriptBlock {
        param($DetectorText, $ReadEfi, $DetectorTimeoutSeconds)

        $ErrorActionPreference = 'Continue'

        function Convert-CimRows {
            param([object[]]$Rows, [string[]]$Properties)

            @($Rows | ForEach-Object {
                    $row = [ordered]@{}
                    foreach ($property in $Properties) {
                        $row[$property] = $_.$property
                    }
                    [pscustomobject]$row
                })
        }

        $processorRegistry = @(
            Get-ChildItem -LiteralPath `
                'Registry::HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\CentralProcessor' `
                -ErrorAction SilentlyContinue |
                Sort-Object PSChildName |
                ForEach-Object {
                    $values = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                    [pscustomobject]@{
                        Index = $_.PSChildName
                        ProcessorNameString = $values.ProcessorNameString
                        Identifier = $values.Identifier
                        VendorIdentifier = $values.VendorIdentifier
                    }
                }
        )

        $nvidia = [ordered]@{ Found = $false; Output = @(); Error = $null }
        try {
            $nvidiaCommand = Get-Command nvidia-smi.exe -ErrorAction Stop
            $nvidia.Found = $true
            $nvidia.Output = @(
                & $nvidiaCommand.Source `
                    --query-gpu=name,driver_version,pci.bus_id `
                    --format=csv,noheader 2>&1 |
                    ForEach-Object { $_.ToString() }
            )
        }
        catch {
            $nvidia.Error = $_.Exception.Message
        }

        $detector = [ordered]@{
            Parsed = $false
            ExitCode = $null
            Raw = @()
            Result = $null
            Error = $null
        }
        $detectorToken = [Guid]::NewGuid().ToString('N')
        $detectorScriptPath = Join-Path $env:TEMP "vmate-detector-$detectorToken.ps1"
        $detectorOutputPath = Join-Path $env:TEMP "vmate-detector-$detectorToken.json"
        $detectorStdoutPath = Join-Path $env:TEMP "vmate-detector-$detectorToken.stdout"
        $detectorStderrPath = Join-Path $env:TEMP "vmate-detector-$detectorToken.stderr"
        try {
            [IO.File]::WriteAllText(
                $detectorScriptPath,
                $DetectorText,
                (New-Object Text.UTF8Encoding($true))
            )
            $powerShellPath = Join-Path $PSHOME 'powershell.exe'
            $arguments = @(
                '-NoLogo', '-NoProfile', '-NonInteractive',
                '-ExecutionPolicy', 'Bypass',
                '-File', ('"{0}"' -f $detectorScriptPath),
                '-Json', '-NoPause',
                '-OutputPath', ('"{0}"' -f $detectorOutputPath)
            )
            $detectorProcess = Start-Process -FilePath $powerShellPath `
                -ArgumentList $arguments -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput $detectorStdoutPath `
                -RedirectStandardError $detectorStderrPath
            if (-not $detectorProcess.WaitForExit($DetectorTimeoutSeconds * 1000)) {
                $detectorProcess.Kill()
                throw "Detector child process timed out after $DetectorTimeoutSeconds seconds."
            }
            # Refresh after the timed wait so Windows PowerShell exposes the
            # final exit code reliably across a PowerShell Direct session.
            $detectorProcess.WaitForExit()
            $detectorProcess.Refresh()
            $detector['ExitCode'] = [int]$detectorProcess.ExitCode
            $detectorOutput = @()
            if (Test-Path -LiteralPath $detectorStdoutPath -PathType Leaf) {
                $detectorOutput += @(Get-Content -LiteralPath $detectorStdoutPath)
            }
            if (Test-Path -LiteralPath $detectorStderrPath -PathType Leaf) {
                $detectorOutput += @(Get-Content -LiteralPath $detectorStderrPath)
            }
            $detector.Raw = @($detectorOutput | ForEach-Object { $_.ToString() })
            if (-not (Test-Path -LiteralPath $detectorOutputPath -PathType Leaf)) {
                throw "Detector child process did not create JSON (exit $($detector.ExitCode))."
            }
            $candidate = (Get-Content -LiteralPath $detectorOutputPath -Raw).Trim()
            $firstBrace = $candidate.IndexOf('{')
            $lastBrace = $candidate.LastIndexOf('}')
            if ($firstBrace -lt 0 -or $lastBrace -lt $firstBrace) {
                throw 'Detector output did not contain a JSON object.'
            }
            $jsonText = $candidate.Substring($firstBrace, $lastBrace - $firstBrace + 1)
            $detector.Result = $jsonText | ConvertFrom-Json -ErrorAction Stop
            $detector.Parsed = $true
        }
        catch {
            $detector.Error = $_.Exception.Message
        }
        finally {
            Remove-Item -LiteralPath $detectorScriptPath, $detectorOutputPath, `
                $detectorStdoutPath, $detectorStderrPath -Force -ErrorAction SilentlyContinue
        }

        $efiStatus = [ordered]@{
            Requested = [bool]$ReadEfi
            Read = $false
            Text = $null
            Error = $null
        }
        if ($ReadEfi) {
            $efiDrive = 'V:'
            $mountedByProbe = $false
            try {
                if (Get-PSDrive -Name $efiDrive.TrimEnd(':') -ErrorAction SilentlyContinue) {
                    throw "$efiDrive is already assigned; refusing to alter it."
                }
                & mountvol.exe $efiDrive /S | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "mountvol /S failed with exit code $LASTEXITCODE."
                }
                $mountedByProbe = $true
                $efiPath = "$efiDrive\EFI\VMate\identity-status.txt"
                if (-not (Test-Path -LiteralPath $efiPath -PathType Leaf)) {
                    throw 'EFI identity-status.txt was not found.'
                }
                $efiStatus.Text = [string](
                    Get-Content -LiteralPath $efiPath -Raw -ErrorAction Stop
                )
                $efiStatus.Read = $true
            }
            catch {
                $efiStatus.Error = $_.Exception.Message
            }
            finally {
                if ($mountedByProbe) {
                    & mountvol.exe $efiDrive /D | Out-Null
                }
            }
        }

        [pscustomobject]@{
            SchemaVersion = 1
            TimestampUtc = [DateTime]::UtcNow.ToString('o')
            ComputerSystem = Convert-CimRows @(Get-CimInstance Win32_ComputerSystem) `
                @('Manufacturer', 'Model', 'SystemFamily', 'SystemSKUNumber',
                    'SystemType', 'TotalPhysicalMemory')
            ComputerSystemProduct = Convert-CimRows @(Get-CimInstance Win32_ComputerSystemProduct) `
                @('Vendor', 'Name', 'Version', 'IdentifyingNumber', 'UUID', 'SKUNumber')
            BIOS = Convert-CimRows @(Get-CimInstance Win32_BIOS) `
                @('Manufacturer', 'Name', 'SMBIOSBIOSVersion', 'Version',
                    'SerialNumber', 'ReleaseDate')
            BaseBoard = Convert-CimRows @(Get-CimInstance Win32_BaseBoard) `
                @('Manufacturer', 'Product', 'Version', 'SerialNumber')
            Enclosure = Convert-CimRows @(Get-CimInstance Win32_SystemEnclosure) `
                @('Manufacturer', 'Version', 'SerialNumber', 'SMBIOSAssetTag', 'ChassisTypes')
            Processor = Convert-CimRows @(Get-CimInstance Win32_Processor) `
                @('Manufacturer', 'Name', 'Description', 'ProcessorId', 'NumberOfCores',
                    'NumberOfLogicalProcessors', 'MaxClockSpeed')
            PhysicalMemory = Convert-CimRows @(Get-CimInstance Win32_PhysicalMemory) `
                @('Manufacturer', 'PartNumber', 'SerialNumber', 'DeviceLocator', 'Capacity',
                    'Speed', 'ConfiguredClockSpeed', 'SMBIOSMemoryType')
            VideoController = Convert-CimRows @(Get-CimInstance Win32_VideoController) `
                @('Name', 'PNPDeviceID', 'Status', 'ConfigManagerErrorCode',
                    'AdapterCompatibility', 'DriverVersion', 'CurrentHorizontalResolution',
                    'CurrentVerticalResolution', 'CurrentRefreshRate')
            DisplayPnP = Convert-CimRows @(
                Get-CimInstance Win32_PnPEntity |
                    Where-Object { $_.PNPClass -in @('Display', 'Monitor') }
            ) @('Name', 'PNPDeviceID', 'Status', 'ConfigManagerErrorCode', 'Manufacturer', 'Service')
            ProcessorRegistry = $processorRegistry
            NvidiaSmi = [pscustomobject]$nvidia
            # Keep the detector document at the conventional property so it
            # can be consumed directly by VMate.GpuP.DetectionParity.ps1.
            Detector = $detector.Result
            DetectorExecution = [pscustomobject]@{
                Parsed = $detector.Parsed
                ExitCode = $detector.ExitCode
                Raw = $detector.Raw
                Error = $detector.Error
            }
            EfiStatus = [pscustomobject]$efiStatus
        }
    } -ArgumentList $detectorSource, (-not $SkipEfiStatus.IsPresent), $TimeoutSeconds
}
finally {
    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
}

if (-not $result) {
    throw 'PowerShell Direct evidence collection returned no result.'
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $outputDirectory -Force)
}
$json = $result | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText(
    $OutputPath,
    $json,
    (New-Object System.Text.UTF8Encoding($false))
)

[pscustomobject]@{
    VMName = $VMName
    OutputPath = $OutputPath
    ComputerSystem = $result.ComputerSystem[0]
    BaseBoard = $result.BaseBoard[0]
    BIOS = $result.BIOS[0]
    Processor = $result.Processor[0]
    NvidiaSmi = $result.NvidiaSmi
    DetectorParsed = $result.DetectorExecution.Parsed
    DetectorExitCode = $result.DetectorExecution.ExitCode
    DetectorError = $result.DetectorExecution.Error
    EfiStatus = $result.EfiStatus
}

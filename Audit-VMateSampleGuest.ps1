param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^pc0[12]$')]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^http://192\.168\.160\.1:8765/pc0[12]$')]
    [string]$Endpoint
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Select-CimFields {
    param([string]$ClassName, [string[]]$Properties)
    return @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop |
        Select-Object -Property $Properties)
}

$cpuid = $null
$cpuidPath = Join-Path $scriptRoot 'VMateCpuidProbe.exe'
if (Test-Path -LiteralPath $cpuidPath -PathType Leaf) {
    $cpuid = (& $cpuidPath | Out-String | ConvertFrom-Json)
}

$detector = $null
$detectorPath = Join-Path $scriptRoot 'Detect-VGpuP.ps1'
if (Test-Path -LiteralPath $detectorPath -PathType Leaf) {
    $detector = (& powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File $detectorPath -Json | Out-String | ConvertFrom-Json)
}

$processorRegistry = @()
$processorRoot = 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor'
if (Test-Path -LiteralPath $processorRoot) {
    $processorRegistry = @(Get-ChildItem -LiteralPath $processorRoot |
        ForEach-Object {
            $value = Get-ItemProperty -LiteralPath $_.PSPath
            [pscustomobject][ordered]@{
                Index = $_.PSChildName
                Identifier = [string]$value.Identifier
                ProcessorNameString = [string]$value.ProcessorNameString
                VendorIdentifier = [string]$value.VendorIdentifier
            }
        })
}

$result = [pscustomobject][ordered]@{
    SchemaVersion = 1
    VMName = $VMName
    ComputerName = $env:COMPUTERNAME
    CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    ComputerSystem = Select-CimFields Win32_ComputerSystem @(
        'Manufacturer', 'Model', 'SystemFamily', 'SystemSKUNumber',
        'TotalPhysicalMemory')
    ComputerSystemProduct = Select-CimFields Win32_ComputerSystemProduct @(
        'Vendor', 'Name', 'Version', 'IdentifyingNumber', 'UUID')
    BIOS = Select-CimFields Win32_BIOS @(
        'Manufacturer', 'Name', 'SMBIOSBIOSVersion', 'SerialNumber',
        'Version', 'ReleaseDate')
    BaseBoard = Select-CimFields Win32_BaseBoard @(
        'Manufacturer', 'Product', 'Version', 'SerialNumber')
    SystemEnclosure = Select-CimFields Win32_SystemEnclosure @(
        'Manufacturer', 'Name', 'Version', 'SerialNumber', 'SMBIOSAssetTag',
        'ChassisTypes')
    Processor = Select-CimFields Win32_Processor @(
        'Manufacturer', 'Name', 'Description', 'ProcessorId', 'Family',
        'Model', 'Stepping', 'Revision', 'NumberOfCores',
        'NumberOfLogicalProcessors', 'MaxClockSpeed', 'SocketDesignation')
    ProcessorRegistry = $processorRegistry
    Cpuid = $cpuid
    PhysicalMemory = Select-CimFields Win32_PhysicalMemory @(
        'BankLabel', 'DeviceLocator', 'Manufacturer', 'PartNumber',
        'SerialNumber', 'Capacity', 'Speed', 'ConfiguredClockSpeed',
        'SMBIOSMemoryType')
    DiskDrive = Select-CimFields Win32_DiskDrive @(
        'Model', 'SerialNumber', 'FirmwareRevision', 'InterfaceType',
        'PNPDeviceID', 'Size')
    NetworkAdapter = @(Get-CimInstance Win32_NetworkAdapter |
        Where-Object { $_.PhysicalAdapter -and $_.MACAddress } |
        Select-Object Name, Manufacturer, MACAddress, PNPDeviceID,
            NetConnectionStatus)
    VideoController = Select-CimFields Win32_VideoController @(
        'Name', 'PNPDeviceID', 'Status', 'DriverVersion', 'AdapterRAM',
        'VideoProcessor')
    DisplayPnP = @(Get-CimInstance Win32_PnPEntity | Where-Object {
            $_.PNPClass -eq 'Display'
        } | Select-Object Name, Manufacturer, PNPDeviceID, Status,
            ConfigManagerErrorCode, Service)
    GpuPDetector = $detector
}

$json = $result | ConvertTo-Json -Depth 12 -Compress
$response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Endpoint `
    -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json))
if ([int]$response.StatusCode -ne 200) {
    throw "Audit receiver returned HTTP $($response.StatusCode)."
}

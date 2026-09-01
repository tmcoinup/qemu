# Prepare one Windows image to boot from either the reviewed G-11 AHCI/SATA
# topology or the QEMU NVMe topology. Windows PowerShell 5.1 compatible.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [Environment]::Is64BitProcess) {
    throw 'Storage portability must run in 64-bit Windows PowerShell.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Storage portability must run as Administrator.'
}

$root = Join-Path $env:ProgramData 'VMate\G11'
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    New-Item -Path $root -ItemType Directory -Force -ErrorAction Stop |
        Out-Null
}
$rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
if ($rootItem -isnot [IO.DirectoryInfo] -or
    ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Storage portability root must be a regular directory: $root"
}

$services = @('storahci', 'stornvme')
foreach ($serviceName in $services) {
    $driver = Join-Path $env:SystemRoot "System32\drivers\${serviceName}.sys"
    $driverItem = Get-Item -LiteralPath $driver -Force -ErrorAction Stop
    if ($driverItem -isnot [IO.FileInfo] -or
        ($driverItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $driverItem.Length -le 0) {
        throw "Windows inbox storage driver is missing or unsafe: $driver"
    }

    $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
    if (-not (Test-Path -LiteralPath $serviceKey -PathType Container)) {
        throw "Windows inbox storage service is missing: $serviceKey"
    }
    Set-ItemProperty -LiteralPath $serviceKey -Name Start -Type DWord `
        -Value 0 -Force -ErrorAction Stop
    $overrideKey = Join-Path $serviceKey 'StartOverride'
    if (-not (Test-Path -LiteralPath $overrideKey -PathType Container)) {
        New-Item -Path $overrideKey -ItemType Directory -Force `
            -ErrorAction Stop | Out-Null
    }
    Set-ItemProperty -LiteralPath $overrideKey -Name '0' -Type DWord `
        -Value 0 -Force -ErrorAction Stop

    $start = [int](Get-ItemPropertyValue -LiteralPath $serviceKey `
        -Name Start -ErrorAction Stop)
    $override = [int](Get-ItemPropertyValue -LiteralPath $overrideKey `
        -Name '0' -ErrorAction Stop)
    if ($start -ne 0 -or $override -ne 0) {
        throw "Storage service did not retain boot-start policy: $serviceName"
    }
}

$marker = Join-Path $root 'storage-controller-portability.json'
$temporary = "$marker.new.$PID"
$receipt = [ordered]@{
    schemaVersion = 1
    contract = 'g11-windows-storage-controller-portability-v1'
    controllers = @('q35-ich9-ahci', 'qemu-nvme')
    services = [ordered]@{
        storahci = [ordered]@{ start = 0; startOverride0 = 0 }
        stornvme = [ordered]@{ start = 0; startOverride0 = 0 }
    }
}
$json = $receipt | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText($temporary, $json,
    (New-Object Text.UTF8Encoding($false)))
Move-Item -LiteralPath $temporary -Destination $marker -Force

$published = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop
if ([int]$published.schemaVersion -ne 1 -or
    [string]$published.contract -cne
        'g11-windows-storage-controller-portability-v1' -or
    (@($published.controllers) -join '|') -cne
        'q35-ich9-ahci|qemu-nvme' -or
    [int]$published.services.storahci.start -ne 0 -or
    [int]$published.services.storahci.startOverride0 -ne 0 -or
    [int]$published.services.stornvme.start -ne 0 -or
    [int]$published.services.stornvme.startOverride0 -ne 0) {
    throw 'Published storage portability receipt failed verification.'
}

Write-Host '[PASS] Windows storahci/stornvme boot-start portability is ready.' `
    -ForegroundColor Green

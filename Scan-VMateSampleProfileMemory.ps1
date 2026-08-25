#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$ScannerPath = 'C:\VMateLab\VMateProcessMemoryScan.exe',
    [string]$OutputPath = 'C:\VMateLab\vmspoofer-profile-scan.txt',
    [string]$SummaryPath = 'C:\VMateLab\vmspoofer-profile-scan.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ScannerPath -PathType Leaf)) {
    throw "memory scanner not found: $ScannerPath"
}
$processes = @(Get-Process -Name VMSpoofer -ErrorAction Stop)
if ($processes.Count -ne 1) {
    throw "expected one VMSpoofer process, found $($processes.Count)."
}
$patterns = @(
    '13th Gen Intel(R) Core(TM) i5-13600KF',
    '13th Gen Intel(R) Core(TM) i7-13700F',
    'GALAX B760 METALTOP D4',
    'B760M BOMBER WIFI (MS-7D90)',
    'NVIDIA GeForce RTX 4060 Ti',
    'b26d2383-add4-4f96-b6ce-f3589582d0d6',
    'b014cbbc-8351-430e-832d-732ab6922bb2',
    '282f1a79-363d-4267-a653-994d9b5d1d19',
    'guestConfig',
    'gpuDeviceId',
    'baseBoard',
    'serialNumber'
)

$lines = @(& $ScannerPath $processes[0].Id @patterns 2>&1 |
        ForEach-Object { [string]$_ })
[IO.File]::WriteAllLines($OutputPath, $lines,
    (New-Object Text.UTF8Encoding($false)))
$matches = @($lines | Where-Object { $_ -match '^pid=' })
$summary = [pscustomobject][ordered]@{
    SchemaVersion = 1
    CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    ProcessId = [int]$processes[0].Id
    ProcessStartTimeUtc = $processes[0].StartTime.ToUniversalTime().ToString('o')
    Patterns = $patterns
    MatchCount = $matches.Count
    OutputPath = $OutputPath
}
[IO.File]::WriteAllText($SummaryPath,
    ($summary | ConvertTo-Json -Depth 5),
    (New-Object Text.UTF8Encoding($false)))
$summary | ConvertTo-Json -Compress

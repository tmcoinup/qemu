#requires -Version 5.1
<# Read existing application AND Windows restart evidence; no settings are changed. #>
[CmdletBinding()]
param(
    [ValidateRange(1, 168)][int]$Hours = 48,
    [string]$OutputDirectory
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run inside the Windows game VM.' }
$until = Get-Date
$since = $until.AddHours(-$Hours)
$warnings = New-Object 'System.Collections.Generic.List[string]'
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path ([Environment]::GetFolderPath('Desktop')) (
        'G11-GameExit-' + $until.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
}
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Output already exists; choose a new directory.' }
$null = New-Item -ItemType Directory -Path $OutputDirectory

function Read-Events([string]$Log, [int[]]$Ids) {
    try {
        $items = @(Get-WinEvent -FilterHashtable @{
            LogName = $Log; Id = $Ids; StartTime = $since; EndTime = $until
        } -MaxEvents 400 -ErrorAction Stop)
        if ($items.Count -eq 400) { $warnings.Add("$Log reached the 400-event limit; older events may be omitted.") }
        foreach ($item in $items) {
            [xml]$xml = $item.ToXml()
            $data = [ordered]@{}
            $index = 0
            foreach ($node in $xml.SelectNodes('/*[local-name()="Event"]/*[local-name()="EventData"]/*[local-name()="Data"]')) {
                $name = $node.GetAttribute('Name')
                if (-not $name) { $name = 'Data' + $index }
                $data[$name] = $node.InnerText
                $index++
            }
            [pscustomobject]@{
                TimeLocal = $item.TimeCreated.ToString('o')
                TimeUtc = $item.TimeCreated.ToUniversalTime().ToString('o')
                Id = $item.Id; Provider = $item.ProviderName; RecordId = $item.RecordId
                Data = $data; Message = $item.Message; Xml = $item.ToXml()
            }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') {
            $warnings.Add("${Log}: $($_.Exception.Message)")
        }
    }
}

function Read-Cim([string]$Class, [string[]]$Properties) {
    try {
        Get-CimInstance $Class -OperationTimeoutSec 10 -ErrorAction Stop | Select-Object -Property $Properties
    } catch { $warnings.Add("${Class}: $($_.Exception.Message)") }
}

function Read-Registry([string]$Path, [string[]]$Properties) {
    try {
        if (Test-Path -LiteralPath $Path) {
            Get-ItemProperty -LiteralPath $Path | Select-Object -Property $Properties
        }
    } catch { $warnings.Add("Registry: $($_.Exception.Message)") }
}

Write-Host 'Reading application failures and Windows restart events...'
$application = @(Read-Events 'Application' @(1000, 1001, 1002))
$system = @(Read-Events 'System' @(41, 1074, 6005, 6006, 6008, 12, 13, 1001, 4101, 2004, 46, 161, 129, 153, 157))
$dumps = @()
foreach ($dir in @((Join-Path $env:LOCALAPPDATA 'CrashDumps'), (Join-Path $env:SystemRoot 'Minidump'))) {
    try {
        if (Test-Path -LiteralPath $dir) {
            $dumps += @(Get-ChildItem -LiteralPath $dir -File -Filter '*.dmp' |
                Where-Object { $_.LastWriteTime -ge $since -and
                    ($dir.EndsWith('Minidump') -or $_.Name -match '^DNF.*\.dmp$') } |
                Select-Object -First 30 Name, Length, LastWriteTime)
        }
    } catch { $warnings.Add("Dump metadata: $($_.Exception.Message)") }
}
$report = [ordered]@{
    Schema = 1; CollectedAt = $until.ToString('o'); TimeZone = [TimeZoneInfo]::Local.Id
    SinceLocal = $since.ToString('o'); UntilLocal = $until.ToString('o')
    ApplicationEvents = $application; SystemEvents = $system; DumpMetadata = $dumps
    CurrentOS = @(Read-Cim 'Win32_OperatingSystem' @('LastBootUpTime', 'Version', 'TotalVisibleMemorySize', 'FreePhysicalMemory', 'TotalVirtualMemorySize', 'FreeVirtualMemory'))
    CurrentPageFile = @(Read-Cim 'Win32_PageFileUsage' @('Name', 'AllocatedBaseSize', 'CurrentUsage', 'PeakUsage'))
    CurrentVideo = @(Read-Cim 'Win32_VideoController' @('Name', 'DriverVersion', 'Status'))
    CrashControl = Read-Registry 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' @('CrashDumpEnabled', 'AutoReboot', 'LogEvent', 'DumpFile', 'MinidumpDir')
    WerPolicy = Read-Registry 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' @('Disabled')
    WerService = Read-Registry 'HKLM:\SYSTEM\CurrentControlSet\Services\WerSvc' @('Start')
    Limits = 'Existing events only, at most 400 per log and 30 dump names per directory. No dump contents, game files, credentials or process memory collected. Current resources are not crash-time values. Event 41 alone does not identify the reset cause.'
    CollectionWarnings = $warnings
}
$report | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $OutputDirectory 'report.json') -Encoding UTF8
$summary = New-Object 'System.Collections.Generic.List[string]'
$summary.Add("Window: $($since.ToString('o')) to $($until.ToString('o')); timezone: $($report.TimeZone)")
foreach ($os in $report.CurrentOS) { $summary.Add("Windows last boot: $($os.LastBootUpTime.ToString('o'))") }
$gameCrashes = @($application | Where-Object { $_.Id -eq 1000 -and $_.Provider -eq 'Application Error' -and $_.Xml -match '(?i)DNF[^<]*\.exe' })
$summary.Add("DNF Application Error events: $($gameCrashes.Count)")
foreach ($item in $gameCrashes) { $summary.Add("APP $($item.TimeLocal): $($item.Data | ConvertTo-Json -Compress)") }
foreach ($item in $system | Where-Object {
    ($_.Id -eq 41 -and $_.Provider -eq 'Microsoft-Windows-Kernel-Power') -or
    ($_.Id -eq 6008 -and $_.Provider -eq 'EventLog') -or
    ($_.Id -eq 1074 -and $_.Provider -eq 'User32')
}) { $summary.Add("SYSTEM $($item.TimeLocal) $($item.Id) $($item.Provider): $($item.Data | ConvertTo-Json -Compress)") }
$summary.Add('No application crash event does NOT exclude a game exit. Check Windows restart times before attributing the disappearance to DNF.')
$summary.Add('Event 41/6008 means an unclean shutdown; a zero BugcheckCode does not identify a driver, power failure, or external reset.')
$summary.Add('Current RAM/pagefile/VRAM values cannot prove the resources available at the time of exit.')
foreach ($warning in $warnings) { $summary.Add('WARNING: ' + $warning) }
$summary | Set-Content (Join-Path $OutputDirectory 'summary.txt') -Encoding UTF8
$summary | Write-Output
Write-Host "Saved: $OutputDirectory" -ForegroundColor Green

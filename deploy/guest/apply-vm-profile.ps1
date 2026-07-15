#requires -Version 5.1
<#
.SYNOPSIS
  Persist the configured guest GPU name/specification in Windows.

.DESCRIPTION
  Run from an elevated 64-bit Windows PowerShell 5.1 console.  The script reads
  a schema-versioned whitelist JSON by URL or local path, installs local copies
  under C:\ProgramData\QemuVmProfile\versions\..., invokes
  patch-grid-strings.ps1 with the exact GPU values, and registers
  RefreshGridNames AtStartup as SYSTEM.  The task points at one immutable
  version directory; files directly under QemuVmProfile are compatibility
  copies for the documented hand-operated verification entry only.

  RefreshGridNames is deliberately offline: its action calls the installed
  copy of this script with the installed JSON and never needs the host HTTP
  server.  Re-running the script is safe and replaces the task/configuration.

  Hibernation and online monitor repair are opt-in.  The default operation only
  changes the GPU identity.  This script never restarts Windows; PENDING means
  the registry/task is ready but Windows still exposes cached live state.

.PARAMETER ManifestUrl
  HTTP(S) URL of the strict asset manifest used for initial installation.
  ManifestSha256 must be supplied over the trusted console path.  The profile
  and every downloaded dependency are verified against the manifest before a
  version can be committed.

.PARAMETER ConfigUrl
  Deprecated compatibility parameter.  Unauthenticated remote ConfigUrl use
  is rejected; use ManifestUrl plus ManifestSha256.

.PARAMETER ConfigPath
  Local whitelist JSON.  Dependencies are resolved beside that JSON, beside
  this script, or from the installed directory.  Startup tasks use this local
  path and never need the host HTTP server.

.PARAMETER DisableHibernation
  Explicitly run powercfg /hibernate off and disable Fast Startup.  This is not
  part of the default GPU-only operation.

.PARAMETER OnlineMonitorRescue
  Explicitly perform the existing one-shot spoof-monitor.ps1 repair.  No
  persistent monitor task is installed.

.PARAMETER VerifyOnly
  Make no changes.  Exit 0 when all requested checks pass, or 10 when any live
  state is pending.

.PARAMETER RequireTaskRun
  During verification, treat a newly installed task that has never run as
  pending.  Use after the first restart for strict persistence acceptance.
#>
[CmdletBinding(DefaultParameterSetName = 'Manifest')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Url')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigUrl,

    [Parameter(Mandatory = $true, ParameterSetName = 'Manifest')]
    [ValidateNotNullOrEmpty()]
    [string]$ManifestUrl,

    [Parameter(Mandatory = $true, ParameterSetName = 'Manifest')]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$ManifestSha256,

    [Parameter(Mandatory = $true, ParameterSetName = 'Path')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath,

    [string]$BaseUrl,
    [switch]$OnlineMonitorRescue,
    [switch]$DisableHibernation,
    [switch]$VerifyOnly,
    [switch]$RequireTaskRun,

    # Internal/idempotency switches used by RefreshGridNames.  -KeepHibernation
    # is explicit in the task action so a future default change cannot make a
    # boot task alter the machine's power state.
    [switch]$GpuOnly,
    [switch]$NoRegister,
    [switch]$KeepHibernation
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$InstallRoot = Join-Path $env:ProgramData 'QemuVmProfile'
$VersionsRoot = Join-Path $InstallRoot 'versions'
$InstalledApply = Join-Path $InstallRoot 'apply-vm-profile.ps1'
$InstalledConfig = Join-Path $InstallRoot 'profile.json'
$InstalledPatch = Join-Path $InstallRoot 'patch-grid-strings.ps1'
$InstalledMonitor = Join-Path $InstallRoot 'spoof-monitor.ps1'
$InstalledMonitorCatalog = Join-Path $InstallRoot 'monitor-profiles.tsv'
$GpuTaskName = 'RefreshGridNames'
$script:PendingMessages = @()
$script:ConfigParameterSet = $PSCmdlet.ParameterSetName
$script:DesiredConfigSha256 = $null
$script:TaskRegistrationAttempted = $false
$script:TaskRollbackConfirmed = $false

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run apply-vm-profile.ps1 from an elevated Administrator PowerShell console.'
    }
    if (-not [Environment]::Is64BitProcess) {
        throw 'Run the 64-bit Windows PowerShell executable; a 32-bit process uses redirected registry paths.'
    }
}

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "PASS: $Message" -ForegroundColor Green
}

function Write-Pending {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:PendingMessages += $Message
    Write-Host "PENDING: $Message" -ForegroundColor Yellow
}

function Assert-AllowedProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$Context
    )
    if ($null -eq $Object -or $null -eq $Object.PSObject) {
        throw "$Context must be a JSON object."
    }
    foreach ($property in @($Object.PSObject.Properties)) {
        if ($Allowed -notcontains [string]$property.Name) {
            throw "Unknown $Context property '$($property.Name)'."
        }
    }
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context,
        [switch]$Optional
    )
    $matches = @($Object.PSObject.Properties | Where-Object { $_.Name -ieq $Name })
    if ($matches.Count -eq 0 -and $Optional) { return $null }
    if ($matches.Count -ne 1 -or $null -eq $matches[0].Value) {
        throw "Missing required $Context property '$Name'."
    }
    return $matches[0].Value
}

function Get-NullablePropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $matches = @($Object.PSObject.Properties | Where-Object { $_.Name -ieq $Name })
    if ($matches.Count -ne 1) {
        throw "Missing required $Context property '$Name'."
    }
    return $matches[0].Value
}

function ConvertTo-RequiredString {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$MaximumLength = 128,
        [string]$Pattern = '^[\x20-\x7e]+$'
    )
    $text = ([string]$Value).Trim()
    if ($text.Length -lt 1 -or $text.Length -gt $MaximumLength -or
        $text -notmatch $Pattern) {
        throw "Invalid '$Name' value '$text'."
    }
    return $text
}

function ConvertTo-RequiredInt {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int64]$Minimum,
        [Parameter(Mandatory = $true)][int64]$Maximum
    )
    $parsed = 0L
    if (-not [int64]::TryParse(
        ([string]$Value),
        [Globalization.NumberStyles]::Integer,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsed
    ) -or $parsed -lt $Minimum -or $parsed -gt $Maximum) {
        throw "Invalid '$Name' integer '$Value' (expected $Minimum..$Maximum)."
    }
    return [int]$parsed
}

function ConvertTo-ValidatedMonitor {
    param([Parameter(Mandatory = $true)][object]$Raw)
    Assert-AllowedProperties $Raw @(
        'profile', 'serial', 'displayName', 'nativeX', 'nativeY', 'refreshHz'
    ) 'monitor'
    return [pscustomobject]@{
        Profile = ConvertTo-RequiredString `
            (Get-PropertyValue $Raw 'profile' 'monitor') `
            'monitor.profile' 64 '^[a-z0-9][a-z0-9-]*$'
        Serial = ConvertTo-RequiredString `
            (Get-PropertyValue $Raw 'serial' 'monitor') `
            'monitor.serial' 12 '^[\x21-\x7e]+$'
        DisplayName = ConvertTo-RequiredString `
            (Get-PropertyValue $Raw 'displayName' 'monitor') `
            'monitor.displayName' 128
        NativeX = ConvertTo-RequiredInt `
            (Get-PropertyValue $Raw 'nativeX' 'monitor') `
            'monitor.nativeX' 320 16384
        NativeY = ConvertTo-RequiredInt `
            (Get-PropertyValue $Raw 'nativeY' 'monitor') `
            'monitor.nativeY' 200 16384
        RefreshHz = ConvertTo-RequiredInt `
            (Get-PropertyValue $Raw 'refreshHz' 'monitor') `
            'monitor.refreshHz' 1 1000
    }
}

function ConvertTo-ValidatedConfig {
    param([Parameter(Mandatory = $true)][object]$Raw)

    Assert-AllowedProperties $Raw @(
        'schemaVersion', 'vmId', 'vmUuid', 'spoofMode', 'gpu', 'monitor'
    ) 'top-level'
    $schema = ConvertTo-RequiredInt `
        (Get-PropertyValue $Raw 'schemaVersion' 'top-level') `
        'schemaVersion' 1 1
    $vmId = ConvertTo-RequiredInt `
        (Get-PropertyValue $Raw 'vmId' 'top-level') `
        'vmId' 1 2147483647
    $vmUuid = ConvertTo-RequiredString `
        (Get-PropertyValue $Raw 'vmUuid' 'top-level') `
        'vmUuid' 36 '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
    $spoofMode = ConvertTo-RequiredString `
        (Get-PropertyValue $Raw 'spoofMode' 'top-level') `
        'spoofMode' 1 '^[Bb]$'
    if ($spoofMode -cne 'B') {
        # Accept lower-case input only long enough to issue a precise error;
        # the persisted schema is deliberately canonical and fail-closed.
        throw "Invalid 'spoofMode' value '$spoofMode' (only canonical 'B' is supported)."
    }
    $gpuRaw = Get-PropertyValue $Raw 'gpu' 'top-level'
    Assert-AllowedProperties $gpuRaw @(
        'profile', 'name', 'coreClockMHz', 'boostClockMHz', 'memoryClockMHz',
        'memoryBusBits', 'memoryBandwidthMBps', 'vramMB', 'expectedPnpId'
    ) 'gpu'
    $expectedPnpId = ConvertTo-RequiredString `
        (Get-PropertyValue $gpuRaw 'expectedPnpId' 'gpu') `
        'gpu.expectedPnpId' 64 '^PCI\\VEN_10DE&DEV_1E30$'
    if ($expectedPnpId -cne 'PCI\VEN_10DE&DEV_1E30') {
        throw "Invalid 'gpu.expectedPnpId' value '$expectedPnpId' (B mode requires PCI\VEN_10DE&DEV_1E30)."
    }
    $gpu = [pscustomobject]@{
        Profile = ConvertTo-RequiredString `
            (Get-PropertyValue $gpuRaw 'profile' 'gpu') `
            'gpu.profile' 64 '^[a-z0-9][a-z0-9_-]*$'
        Name = ConvertTo-RequiredString `
            (Get-PropertyValue $gpuRaw 'name' 'gpu') 'gpu.name' 31
        CoreClockMHz = ConvertTo-RequiredInt `
            (Get-PropertyValue $gpuRaw 'coreClockMHz' 'gpu') `
            'gpu.coreClockMHz' 1 10000
        BoostClockMHz = ConvertTo-RequiredInt `
            (Get-PropertyValue $gpuRaw 'boostClockMHz' 'gpu') `
            'gpu.boostClockMHz' 1 10000
        MemoryClockMHz = ConvertTo-RequiredInt `
            (Get-PropertyValue $gpuRaw 'memoryClockMHz' 'gpu') `
            'gpu.memoryClockMHz' 1 10000
        MemoryBusBits = ConvertTo-RequiredInt `
            (Get-PropertyValue $gpuRaw 'memoryBusBits' 'gpu') `
            'gpu.memoryBusBits' 1 1024
        MemoryBandwidthMBps = ConvertTo-RequiredInt `
            (Get-PropertyValue $gpuRaw 'memoryBandwidthMBps' 'gpu') `
            'gpu.memoryBandwidthMBps' 1 1000000
        VramMB = ConvertTo-RequiredInt `
            (Get-PropertyValue $gpuRaw 'vramMB' 'gpu') `
            'gpu.vramMB' 2048 2048
        ExpectedPnpId = $expectedPnpId
    }

    $monitorRaw = Get-PropertyValue $Raw 'monitor' 'top-level' -Optional
    $monitor = if ($null -ne $monitorRaw) {
        ConvertTo-ValidatedMonitor $monitorRaw
    } else {
        $null
    }
    if ($OnlineMonitorRescue -and $null -eq $monitor) {
        throw '-OnlineMonitorRescue requires the monitor object in the profile JSON.'
    }

    return [pscustomobject]@{
        SchemaVersion = $schema
        VmId = $vmId
        VmUuid = $vmUuid
        SpoofMode = $spoofMode
        Gpu = $gpu
        Monitor = $monitor
    }
}

function ConvertFrom-Utf8Bytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return [Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xFEFF)
}

function Get-Sha256HexFromBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return (($sha256.ComputeHash($Bytes) | ForEach-Object {
            $_.ToString('x2', [Globalization.CultureInfo]::InvariantCulture)
        }) -join '')
    } finally {
        $sha256.Dispose()
    }
}

function Get-Sha256HexFromText {
    param([Parameter(Mandatory = $true)][string]$Text)
    return Get-Sha256HexFromBytes ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Get-Sha256HexFromFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    return Get-Sha256HexFromBytes ([IO.File]::ReadAllBytes($Path))
}

function Assert-Sha256 {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $actual = Get-Sha256HexFromBytes $Bytes
    if ($actual -ine $Expected) {
        throw "$Context SHA-256 mismatch (actual $actual, expected $Expected)."
    }
}

function ConvertTo-ManifestAsset {
    param(
        [AllowNull()][object]$Raw,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Required
    )
    if ($null -eq $Raw) {
        if ($Required) { throw "Manifest asset '$Name' is required." }
        return $null
    }
    Assert-AllowedProperties $Raw @('name', 'sha256') "manifest.$Name"
    $fileName = ConvertTo-RequiredString `
        (Get-PropertyValue $Raw 'name' "manifest.$Name") `
        "manifest.$Name.name" 128 '^[A-Za-z0-9][A-Za-z0-9._-]*$'
    if ($fileName -eq '.' -or $fileName -eq '..' -or $fileName.Contains('..')) {
        throw "Invalid manifest.$Name.name '$fileName'."
    }
    $sha256 = ConvertTo-RequiredString `
        (Get-PropertyValue $Raw 'sha256' "manifest.$Name") `
        "manifest.$Name.sha256" 64 '^[0-9A-Fa-f]{64}$'
    return [pscustomobject]@{
        Name = $fileName
        Sha256 = $sha256.ToLowerInvariant()
    }
}

function ConvertTo-ValidatedManifest {
    param([Parameter(Mandatory = $true)][object]$Raw)
    Assert-AllowedProperties $Raw @(
        'schemaVersion', 'vmId', 'profile', 'patch',
        'monitorScript', 'monitorCatalog'
    ) 'manifest'
    $schema = ConvertTo-RequiredInt `
        (Get-PropertyValue $Raw 'schemaVersion' 'manifest') `
        'manifest.schemaVersion' 1 1
    $vmId = ConvertTo-RequiredInt `
        (Get-PropertyValue $Raw 'vmId' 'manifest') `
        'manifest.vmId' 1 2147483647
    $profile = ConvertTo-ManifestAsset `
        (Get-NullablePropertyValue $Raw 'profile' 'manifest') 'profile' -Required
    $patch = ConvertTo-ManifestAsset `
        (Get-NullablePropertyValue $Raw 'patch' 'manifest') 'patch' -Required
    $monitorScript = ConvertTo-ManifestAsset `
        (Get-NullablePropertyValue $Raw 'monitorScript' 'manifest') 'monitorScript'
    $monitorCatalog = ConvertTo-ManifestAsset `
        (Get-NullablePropertyValue $Raw 'monitorCatalog' 'manifest') 'monitorCatalog'
    if ($OnlineMonitorRescue -and
        ($null -eq $monitorScript -or $null -eq $monitorCatalog)) {
        throw '-OnlineMonitorRescue requires manifest.monitorScript and manifest.monitorCatalog.'
    }
    return [pscustomobject]@{
        SchemaVersion = $schema
        VmId = $vmId
        Profile = $profile
        Patch = $patch
        MonitorScript = $monitorScript
        MonitorCatalog = $monitorCatalog
    }
}

function ConvertTo-AbsoluteHttpUri {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )
    [Uri]$result = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$result) -or
        $result.Scheme -notin @('http', 'https')) {
        throw "$Name must be an absolute HTTP(S) URL: $Value"
    }
    return $result
}

function Get-UrlDirectory {
    param([Parameter(Mandatory = $true)][Uri]$Uri)
    $builder = New-Object UriBuilder($Uri)
    $builder.Query = ''
    $builder.Fragment = ''
    $slash = $builder.Path.LastIndexOf('/')
    $builder.Path = if ($slash -ge 0) {
        $builder.Path.Substring(0, $slash + 1)
    } else {
        '/'
    }
    return $builder.Uri.AbsoluteUri.TrimEnd('/')
}

function Normalize-BaseUrl {
    param([Parameter(Mandatory = $true)][string]$Value)
    $uri = ConvertTo-AbsoluteHttpUri ($Value.TrimEnd('/') + '/') 'BaseUrl'
    return $uri.AbsoluteUri.TrimEnd('/')
}

function Download-Bytes {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Context,
        [int]$MaximumBytes = 1048576
    )
    $uri = ConvertTo-AbsoluteHttpUri $Url $Context
    $client = New-Object Net.WebClient
    try {
        [byte[]]$bytes = $client.DownloadData($uri)
    } finally {
        $client.Dispose()
    }
    if ($bytes.Length -eq 0 -or $bytes.Length -gt $MaximumBytes) {
        throw "$Context size $($bytes.Length) is outside 1..$MaximumBytes bytes."
    }
    return ,$bytes
}

function Read-Configuration {
    $sourceDirectory = $null
    $resolvedBaseUrl = $null
    $manifest = $null
    if ($script:ConfigParameterSet -eq 'Manifest') {
        $manifestUri = ConvertTo-AbsoluteHttpUri $ManifestUrl 'ManifestUrl'
        $manifestBytes = Download-Bytes $manifestUri.AbsoluteUri 'manifest' 262144
        Assert-Sha256 $manifestBytes $ManifestSha256 'manifest'
        try {
            $manifestRaw = (ConvertFrom-Utf8Bytes $manifestBytes) |
                ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "Manifest is not valid JSON: $($_.Exception.Message)"
        }
        $manifest = ConvertTo-ValidatedManifest $manifestRaw
        $resolvedBaseUrl = if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
            Get-UrlDirectory $manifestUri
        } else {
            Normalize-BaseUrl $BaseUrl
        }
        $profileUrl = $resolvedBaseUrl.TrimEnd('/') + '/' + $manifest.Profile.Name
        $profileBytes = Download-Bytes $profileUrl 'profile JSON' 1048576
        Assert-Sha256 $profileBytes $manifest.Profile.Sha256 'profile JSON'
        $jsonText = ConvertFrom-Utf8Bytes $profileBytes
    } elseif ($script:ConfigParameterSet -eq 'Url') {
        throw 'Remote -ConfigUrl without an authenticated manifest is disabled; use -ManifestUrl and -ManifestSha256.'
    } else {
        if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
            throw '-BaseUrl cannot be combined with local -ConfigPath; local dependencies must be colocated.'
        }
        $resolvedPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).ProviderPath
        $jsonText = ConvertFrom-Utf8Bytes ([IO.File]::ReadAllBytes($resolvedPath))
        $sourceDirectory = Split-Path -Parent $resolvedPath
    }
    try {
        $raw = $jsonText | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Configuration is not valid JSON: $($_.Exception.Message)"
    }
    $config = ConvertTo-ValidatedConfig $raw
    if ($null -ne $manifest -and $manifest.VmId -ne $config.VmId) {
        throw "Manifest vmId $($manifest.VmId) does not match profile vmId $($config.VmId)."
    }
    return [pscustomobject]@{
        Text = $jsonText
        Config = $config
        SourceDirectory = $sourceDirectory
        BaseUrl = $resolvedBaseUrl
        Manifest = $manifest
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $encoding = New-Object Text.UTF8Encoding($false)
    $temporary = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temporary, $Text, $encoding)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Copy-FileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $sourcePath = [IO.Path]::GetFullPath($Source)
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    if ($sourcePath -ieq $destinationPath) { return }
    $temporary = "$Destination.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary -Force
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Download-FileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )
    $temporary = "$Destination.tmp-$([Guid]::NewGuid().ToString('N'))"
    $client = New-Object Net.WebClient
    try {
        $client.DownloadFile($Url, $temporary)
        if (-not (Test-Path -LiteralPath $temporary -PathType Leaf) -or
            (Get-Item -LiteralPath $temporary).Length -eq 0) {
            throw "Downloaded dependency is empty: $Url"
        }
        $actualSha256 = Get-Sha256HexFromFile $temporary
        if ($actualSha256 -ine $ExpectedSha256) {
            throw "Dependency '$Url' SHA-256 mismatch (actual $actualSha256, expected $ExpectedSha256)."
        }
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    } finally {
        $client.Dispose()
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Install-Dependency {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$SourceDirectory,
        [string]$ResolvedBaseUrl,
        [AllowNull()][object]$ManifestAsset
    )
    if (-not [string]::IsNullOrWhiteSpace($ResolvedBaseUrl)) {
        if ($null -eq $ManifestAsset) {
            throw "Manifest does not authorize remote dependency '$Name'."
        }
        Download-FileAtomically `
            ($ResolvedBaseUrl.TrimEnd('/') + '/' + $ManifestAsset.Name) `
            $Destination $ManifestAsset.Sha256
        return
    }
    foreach ($directory in @($SourceDirectory, $PSScriptRoot, $InstallRoot)) {
        if ([string]::IsNullOrWhiteSpace($directory)) { continue }
        $candidate = Join-Path $directory $Name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            Copy-FileAtomically $candidate $Destination
            return
        }
    }
    if (Test-Path -LiteralPath $Destination -PathType Leaf) { return }
    throw "Dependency '$Name' is unavailable; place it beside the config/script or use -BaseUrl."
}

function Assert-PowerShellScriptParses {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors
    ) | Out-Null
    if (@($errors).Count -gt 0) {
        $detail = (@($errors | ForEach-Object { $_.Message }) -join '; ')
        throw "$Context failed PowerShell parsing: $detail"
    }
}

function Test-PnpIdentityMatch {
    param(
        [AllowNull()][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    if ([string]::IsNullOrWhiteSpace($Actual)) { return $false }
    $actualUpper = $Actual.Trim().ToUpperInvariant()
    $expectedUpper = $Expected.Trim().ToUpperInvariant()
    return $actualUpper -eq $expectedUpper -or
        $actualUpper.StartsWith($expectedUpper + '&', [StringComparison]::Ordinal)
}

function Get-TargetGpuControllers {
    param([Parameter(Mandatory = $true)][object]$Gpu)
    return @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
        Where-Object { Test-PnpIdentityMatch ([string]$_.PNPDeviceID) $Gpu.ExpectedPnpId })
}

function Assert-GuestUuidMatches {
    param([Parameter(Mandatory = $true)][object]$Config)

    $products = @(Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop)
    if ($products.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$products[0].UUID)) {
        throw "Expected exactly one Win32_ComputerSystemProduct UUID; observed $($products.Count)."
    }
    try {
        $configuredUuid = [Guid]$Config.VmUuid
        $guestUuid = [Guid]([string]$products[0].UUID)
    } catch {
        throw "Could not parse guest/config UUID: $($_.Exception.Message)"
    }
    if ($configuredUuid -ne $guestUuid) {
        throw "Profile UUID $configuredUuid does not match this guest UUID $guestUuid; refusing all changes."
    }
    Write-Pass "guest UUID matches the profile."
}

function Assert-TargetDisplayReady {
    param([Parameter(Mandatory = $true)][object]$Config)

    $controllers = @(Get-TargetGpuControllers $Config.Gpu)
    if ($controllers.Count -ne 1) {
        $observed = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
            ForEach-Object { $_.PNPDeviceID } | Where-Object { $_ }) -join ', '
        throw "Expected exactly one present NVIDIA B-mode controller '$($Config.Gpu.ExpectedPnpId)'; observed $($controllers.Count) (all: $observed)."
    }
    $controller = $controllers[0]
    if ($null -eq $controller.ConfigManagerErrorCode -or
        [int]$controller.ConfigManagerErrorCode -ne 0) {
        throw "Target NVIDIA controller has ConfigManagerErrorCode=$($controller.ConfigManagerErrorCode); repair the GRID driver/license before applying an identity."
    }
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        $present = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
            Where-Object {
                Test-PnpIdentityMatch ([string]$_.InstanceId) $Config.Gpu.ExpectedPnpId
            })
        if ($present.Count -ne 1) {
            throw "Expected exactly one present PnP display '$($Config.Gpu.ExpectedPnpId)'; observed $($present.Count)."
        }
    }
    Write-Pass "present NVIDIA B-mode controller matches the profile and has Code 0."
}

function Disable-HibernationExplicitly {
    & powercfg.exe /hibernate off
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg /hibernate off failed with exit code $LASTEXITCODE."
    }
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    New-ItemProperty -Path $powerKey -Name HiberbootEnabled -PropertyType DWord `
        -Value 0 -Force | Out-Null
    Write-Pass 'hibernation and Fast Startup are disabled (HIBERNATION_DISABLED).'
}

function Invoke-GpuPatch {
    param(
        [Parameter(Mandatory = $true)][object]$Gpu,
        [Parameter(Mandatory = $true)][string]$PatchPath
    )
    $arguments = @{
        TargetName = $Gpu.Name
        CoreClockMHz = $Gpu.CoreClockMHz
        BoostClockMHz = $Gpu.BoostClockMHz
        MemoryClockMHz = $Gpu.MemoryClockMHz
        MemoryBusBits = $Gpu.MemoryBusBits
        MemoryBandwidthMBps = $Gpu.MemoryBandwidthMBps
        VramMB = $Gpu.VramMB
    }
    & $PatchPath @arguments
    Write-Pass "GPU identity patch completed for '$($Gpu.Name)'."
}

function Register-GpuRefreshTask {
    param(
        [Parameter(Mandatory = $true)][string]$VersionApply,
        [Parameter(Mandatory = $true)][string]$VersionConfig
    )
    foreach ($command in @(
        'New-ScheduledTaskAction', 'New-ScheduledTaskTrigger',
        'New-ScheduledTaskPrincipal', 'New-ScheduledTaskSettingsSet',
        'Register-ScheduledTask', 'Get-ScheduledTask',
        'Export-ScheduledTask', 'Unregister-ScheduledTask'
    )) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "ScheduledTasks command '$command' is unavailable."
        }
    }
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden ' +
        '-File "' + $VersionApply + '" -GpuOnly -NoRegister -KeepHibernation ' +
        '-ConfigPath "' + $VersionConfig + '"'
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
        -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes(2)) `
        -MultipleInstances IgnoreNew
    $oldTask = Get-ScheduledTask -TaskName $GpuTaskName -TaskPath '\' `
        -ErrorAction SilentlyContinue
    $oldXml = if ($null -ne $oldTask) {
        Export-ScheduledTask -TaskName $GpuTaskName -TaskPath '\' -ErrorAction Stop
    } else {
        $null
    }
    $script:TaskRegistrationAttempted = $true
    try {
        Register-ScheduledTask -TaskName $GpuTaskName -TaskPath '\' `
            -Action $action -Trigger $trigger -Principal $principal `
            -Settings $settings -Force | Out-Null
    } catch {
        $registrationError = $_
        try {
            if ($null -ne $oldXml) {
                Register-ScheduledTask -TaskName $GpuTaskName -TaskPath '\' `
                    -Xml $oldXml -Force | Out-Null
            } else {
                $possiblyCreated = Get-ScheduledTask -TaskName $GpuTaskName `
                    -TaskPath '\' -ErrorAction SilentlyContinue
                if ($null -ne $possiblyCreated) {
                    Unregister-ScheduledTask -TaskName $GpuTaskName -TaskPath '\' `
                        -Confirm:$false -ErrorAction Stop
                }
            }
            $script:TaskRollbackConfirmed = $true
        } catch {
            throw "Task registration failed and rollback also failed: $($registrationError.Exception.Message); rollback: $($_.Exception.Message)"
        }
        throw $registrationError
    }
    Write-Pass "$GpuTaskName is registered AtStartup as SYSTEM with an offline action."
}

function Invoke-OnlineMonitorRepair {
    param(
        [Parameter(Mandatory = $true)][object]$Monitor,
        [Parameter(Mandatory = $true)][string]$MonitorScriptPath
    )
    $arguments = @{
        Profile = $Monitor.Profile
        Serial = $Monitor.Serial
    }
    & $MonitorScriptPath @arguments
    Write-Pass "one-shot monitor repair completed for '$($Monitor.DisplayName)' ($($Monitor.Serial))."
}

function New-ProfileVersion {
    param([Parameter(Mandatory = $true)][object]$Source)

    New-Item -Path $VersionsRoot -ItemType Directory -Force | Out-Null
    $nonce = [Guid]::NewGuid().ToString('N')
    $candidateRoot = Join-Path $VersionsRoot ('.candidate-' + $nonce)
    $finalRoot = Join-Path $VersionsRoot (
        'vm{0}-{1}-{2}' -f $Source.Config.VmId,
        [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'), $nonce.Substring(0, 12)
    )
    $candidateApply = Join-Path $candidateRoot 'apply-vm-profile.ps1'
    $candidateConfig = Join-Path $candidateRoot 'profile.json'
    $candidatePatch = Join-Path $candidateRoot 'patch-grid-strings.ps1'
    $candidateMonitor = Join-Path $candidateRoot 'spoof-monitor.ps1'
    $candidateCatalog = Join-Path $candidateRoot 'monitor-profiles.tsv'
    $candidateCreated = Join-Path $candidateRoot 'version-created-utc.txt'
    try {
        New-Item -Path $candidateRoot -ItemType Directory -ErrorAction Stop | Out-Null
        Copy-FileAtomically $PSCommandPath $candidateApply
        Write-Utf8NoBom $candidateConfig $Source.Text

        $patchAsset = if ($null -ne $Source.Manifest) {
            $Source.Manifest.Patch
        } else {
            $null
        }
        Install-Dependency 'patch-grid-strings.ps1' $candidatePatch `
            $Source.SourceDirectory $Source.BaseUrl $patchAsset

        if ($OnlineMonitorRescue -and -not $GpuOnly) {
            $monitorAsset = if ($null -ne $Source.Manifest) {
                $Source.Manifest.MonitorScript
            } else {
                $null
            }
            $catalogAsset = if ($null -ne $Source.Manifest) {
                $Source.Manifest.MonitorCatalog
            } else {
                $null
            }
            Install-Dependency 'spoof-monitor.ps1' $candidateMonitor `
                $Source.SourceDirectory $Source.BaseUrl $monitorAsset
            Install-Dependency 'monitor-profiles.tsv' $candidateCatalog `
                $Source.SourceDirectory $Source.BaseUrl $catalogAsset
        }

        Assert-PowerShellScriptParses $candidateApply 'candidate apply script'
        Assert-PowerShellScriptParses $candidatePatch 'candidate GPU patch script'
        if ($OnlineMonitorRescue -and -not $GpuOnly) {
            Assert-PowerShellScriptParses $candidateMonitor 'candidate monitor script'
            if ((Get-Item -LiteralPath $candidateCatalog).Length -eq 0) {
                throw 'candidate monitor catalog is empty.'
            }
        }

        Write-Utf8NoBom $candidateCreated ([DateTime]::UtcNow.ToString('o'))

        Move-Item -LiteralPath $candidateRoot -Destination $finalRoot -ErrorAction Stop
        return [pscustomobject]@{
            Root = $finalRoot
            Apply = Join-Path $finalRoot 'apply-vm-profile.ps1'
            Config = Join-Path $finalRoot 'profile.json'
            Patch = Join-Path $finalRoot 'patch-grid-strings.ps1'
            Monitor = Join-Path $finalRoot 'spoof-monitor.ps1'
            MonitorCatalog = Join-Path $finalRoot 'monitor-profiles.tsv'
            Created = Join-Path $finalRoot 'version-created-utc.txt'
        }
    } catch {
        Remove-Item -LiteralPath $candidateRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $finalRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
        throw
    }
}

function Publish-CompatibilityCopies {
    param([Parameter(Mandatory = $true)][object]$Version)
    try {
        New-Item -Path $InstallRoot -ItemType Directory -Force | Out-Null
        Copy-FileAtomically $Version.Apply $InstalledApply
        Copy-FileAtomically $Version.Config $InstalledConfig
        Copy-FileAtomically $Version.Patch $InstalledPatch
        if (Test-Path -LiteralPath $Version.Monitor -PathType Leaf) {
            Copy-FileAtomically $Version.Monitor $InstalledMonitor
        }
        if (Test-Path -LiteralPath $Version.MonitorCatalog -PathType Leaf) {
            Copy-FileAtomically $Version.MonitorCatalog $InstalledMonitorCatalog
        }
        Write-Pass 'stable compatibility copies were published after the task commit.'
    } catch {
        # The committed task references the immutable version, never these
        # convenience copies.  Report the hand-operated interface as pending
        # without turning a successful task commit into a misleading failure.
        Write-Pending "task committed, but stable compatibility copies could not be refreshed: $($_.Exception.Message)"
    }
}

function Test-HibernationDisabled {
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    $property = Get-ItemProperty -Path $powerKey -Name HiberbootEnabled `
        -ErrorAction SilentlyContinue
    $hiberboot = if ($null -ne $property) { $property.HiberbootEnabled } else { $null }
    $hiberfilePresent = Test-Path -LiteralPath (Join-Path $env:SystemDrive 'hiberfil.sys')
    if ($hiberboot -eq 0 -and -not $hiberfilePresent) {
        Write-Pass 'hibernation state is disabled.'
    } else {
        Write-Pending "hibernation is enabled or incomplete (HiberbootEnabled=$hiberboot, hiberfil.sys=$hiberfilePresent)."
    }
}

function Test-GpuState {
    param([Parameter(Mandatory = $true)][object]$Gpu)
    try {
        $controllers = @(Get-TargetGpuControllers $Gpu)
    } catch {
        Write-Pending "Win32_VideoController query failed: $($_.Exception.Message)"
        $controllers = @()
    }
    if ($controllers.Count -ne 1) {
        Write-Pending "expected exactly one controller with PNP identity '$($Gpu.ExpectedPnpId)'; observed $($controllers.Count)."
    } else {
        $controller = $controllers[0]
        $controllerProblems = @()
        if ([string]$controller.Name -cne [string]$Gpu.Name) {
            $controllerProblems += "Name='$($controller.Name)' (expected '$($Gpu.Name)')"
        }
        if (-not (Test-PnpIdentityMatch ([string]$controller.PNPDeviceID) $Gpu.ExpectedPnpId)) {
            $controllerProblems += "PNPDeviceID='$($controller.PNPDeviceID)' (expected '$($Gpu.ExpectedPnpId)&...')"
        }
        if ($null -eq $controller.ConfigManagerErrorCode -or
            [int]$controller.ConfigManagerErrorCode -ne 0) {
            $controllerProblems += "ConfigManagerErrorCode=$($controller.ConfigManagerErrorCode) (expected 0)"
        }

        if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
            try {
                $pnpDevices = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
                    Where-Object {
                        Test-PnpIdentityMatch ([string]$_.InstanceId) $Gpu.ExpectedPnpId
                    })
                if ($pnpDevices.Count -ne 1) {
                    $controllerProblems += "present PnP device count=$($pnpDevices.Count) (expected 1)"
                } elseif ([string]$pnpDevices[0].FriendlyName -cne [string]$Gpu.Name) {
                    $controllerProblems += "Device Manager name='$($pnpDevices[0].FriendlyName)' (expected '$($Gpu.Name)')"
                }
            } catch {
                $controllerProblems += "present PnP query failed: $($_.Exception.Message)"
            }
        } else {
            $controllerProblems += 'Get-PnpDevice is unavailable, so present Device Manager identity cannot be verified'
        }

        if ($controllerProblems.Count -eq 0) {
            Write-Pass "the same present NVIDIA controller has the expected name, PNP identity, and Code 0."
        } else {
            Write-Pending ('target NVIDIA controller mismatch: ' + ($controllerProblems -join '; '))
        }
    }

    $specPath = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvAPI'
    $specKey = Get-Item -Path $specPath -ErrorAction SilentlyContinue
    $spec = Get-ItemProperty -Path $specPath -ErrorAction SilentlyContinue
    $expectedSpecs = [ordered]@{
        IdentityVramMB = $Gpu.VramMB
        IdentityCoreClockKHz = $Gpu.CoreClockMHz * 1000
        IdentityBoostClockKHz = $Gpu.BoostClockMHz * 1000
        IdentityMemoryClockKHz = $Gpu.MemoryClockMHz * 2000
        IdentityMemoryBusBits = $Gpu.MemoryBusBits
        IdentityMemoryBandwidthMBps = $Gpu.MemoryBandwidthMBps
    }
    $badSpecs = @()
    $nameProperty = @(if ($null -ne $spec) {
        $spec.PSObject.Properties | Where-Object { $_.Name -eq 'IdentityGpuName' }
    })
    $actualName = if ($nameProperty.Count -eq 1) {
        [string]$nameProperty[0].Value
    } else {
        $null
    }
    $actualNameKind = if ($null -ne $specKey) {
        try { [string]($specKey.GetValueKind('IdentityGpuName')) } catch { $null }
    } else { $null }
    if ($null -eq $actualName -or $actualName -cne [string]$Gpu.Name -or
        $actualNameKind -cne 'String') {
        $badSpecs += "IdentityGpuName='$actualName'/$actualNameKind (expected '$($Gpu.Name)'/String)"
    }
    foreach ($item in $expectedSpecs.GetEnumerator()) {
        # The output of an if statement is enumerated by the PowerShell 5.1
        # pipeline.  Keep the outer @() here so a single PSPropertyInfo still
        # has Count/index semantics under StrictMode.
        $actualProperty = @(if ($null -ne $spec) {
            $spec.PSObject.Properties | Where-Object { $_.Name -eq $item.Key }
        })
        $actual = if ($actualProperty.Count -eq 1) { $actualProperty[0].Value } else { $null }
        $actualKind = if ($null -ne $specKey) {
            try { [string]($specKey.GetValueKind($item.Key)) } catch { $null }
        } else { $null }
        if ($null -eq $actual -or [int64]$actual -ne [int64]$item.Value -or
            $actualKind -cne 'DWord') {
            $badSpecs += "$($item.Key)=$actual/$actualKind (expected $($item.Value)/DWord)"
        }
    }
    if ($badSpecs.Count -eq 0) {
        Write-Pass 'NVAPI identity registry values match the GPU profile.'
    } else {
        Write-Pending ('NVAPI identity mismatch: ' + ($badSpecs -join '; '))
    }

}

function Test-GpuTask {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        Write-Pending 'Get-ScheduledTask is unavailable; RefreshGridNames cannot be verified.'
        return
    }
    $tasks = @(Get-ScheduledTask -TaskName $GpuTaskName -TaskPath '\' `
        -ErrorAction SilentlyContinue)
    if ($tasks.Count -ne 1) {
        Write-Pending "$GpuTaskName task count is $($tasks.Count), expected exactly 1 in task path \ ."
        return
    }
    $task = $tasks[0]
    $problems = @()
    $triggers = @($task.Triggers)
    $actions = @($task.Actions)
    if ($triggers.Count -ne 1 -or
        $triggers[0].CimClass.CimClassName -ne 'MSFT_TaskBootTrigger' -or
        -not [bool]$triggers[0].Enabled) {
        $problems += 'task must have exactly one enabled boot trigger'
    }
    if ($actions.Count -ne 1) {
        $problems += "task action count is $($actions.Count), expected exactly 1"
    }

    $expectedPowerShell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    $taskConfigPath = $null
    $versionCreatedUtc = [DateTime]::MinValue
    if ($actions.Count -eq 1) {
        $action = $actions[0]
        $argumentPattern = '^-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "([^"]+)" -GpuOnly -NoRegister -KeepHibernation -ConfigPath "([^"]+)"$'
        $argumentMatch = [regex]::Match(
            [string]$action.Arguments, $argumentPattern,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ([string]$action.Execute -ine $expectedPowerShell -or
            -not $argumentMatch.Success) {
            $problems += 'task action executable/arguments do not exactly match the offline profile action'
        } else {
            $taskApplyPath = [IO.Path]::GetFullPath($argumentMatch.Groups[1].Value)
            $taskConfigPath = [IO.Path]::GetFullPath($argumentMatch.Groups[2].Value)
            $applyDirectory = [IO.Path]::GetDirectoryName($taskApplyPath)
            $configDirectory = [IO.Path]::GetDirectoryName($taskConfigPath)
            $taskPatchPath = Join-Path $applyDirectory 'patch-grid-strings.ps1'
            $createdPath = Join-Path $applyDirectory 'version-created-utc.txt'
            $versionsPrefix = [IO.Path]::GetFullPath($VersionsRoot).TrimEnd('\') + '\'
            if ($applyDirectory -ine $configDirectory -or
                -not ($applyDirectory + '\').StartsWith(
                    $versionsPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                [IO.Path]::GetFileName($taskApplyPath) -ine 'apply-vm-profile.ps1' -or
                [IO.Path]::GetFileName($taskConfigPath) -ine 'profile.json' -or
                -not (Test-Path -LiteralPath $taskApplyPath -PathType Leaf) -or
                -not (Test-Path -LiteralPath $taskConfigPath -PathType Leaf) -or
                -not (Test-Path -LiteralPath $taskPatchPath -PathType Leaf) -or
                -not (Test-Path -LiteralPath $createdPath -PathType Leaf)) {
                $problems += 'task action does not reference one complete immutable version directory'
            } else {
                try {
                    Assert-PowerShellScriptParses $taskApplyPath 'task apply script'
                    Assert-PowerShellScriptParses $taskPatchPath 'task GPU patch script'
                    $taskConfigHash = Get-Sha256HexFromFile $taskConfigPath
                    if ($taskConfigHash -ine $script:DesiredConfigSha256) {
                        $problems += "task profile hash $taskConfigHash does not match the requested profile $($script:DesiredConfigSha256)"
                    }
                    $createdText = (Get-Content -LiteralPath $createdPath -Raw `
                        -ErrorAction Stop).Trim()
                    if (-not [DateTime]::TryParse(
                        $createdText,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::RoundtripKind,
                        [ref]$versionCreatedUtc
                    )) {
                        $problems += "invalid version creation timestamp '$createdText'"
                    }
                } catch {
                    $problems += "task version validation failed: $($_.Exception.Message)"
                }
            }
        }
    }

    if ($task.Principal.UserId -notmatch '^(SYSTEM|S-1-5-18)$' -or
        [string]$task.Principal.LogonType -ine 'ServiceAccount' -or
        [string]$task.Principal.RunLevel -ine 'Highest') {
        $problems += 'task principal must be SYSTEM/ServiceAccount/Highest'
    }
    if ([string]$task.State -eq 'Disabled' -or -not [bool]$task.Settings.Enabled) {
        $problems += 'task is disabled'
    }

    if ($problems.Count -eq 0) {
        Write-Pass "$GpuTaskName has one enabled boot trigger, one immutable offline action, and the SYSTEM/Highest principal."
    } else {
        Write-Pending ("$GpuTaskName definition mismatch: " + ($problems -join '; '))
    }

    try {
        $info = Get-ScheduledTaskInfo -TaskName $GpuTaskName -TaskPath '\' `
            -ErrorAction Stop
        $neverRun = $info.LastRunTime -eq [DateTime]::MinValue -or
            [uint32]$info.LastTaskResult -eq [uint32]267011 -or
            ($versionCreatedUtc -ne [DateTime]::MinValue -and
             $info.LastRunTime.ToUniversalTime() -lt $versionCreatedUtc.ToUniversalTime())
        $currentlyRunning = [string]$task.State -eq 'Running'
        if ($currentlyRunning -and $GpuOnly) {
            Write-Pass "$GpuTaskName is executing the current offline refresh."
        } elseif ($neverRun) {
            if ($RequireTaskRun) {
                Write-Pending "$GpuTaskName has not run yet; restart Windows before strict verification."
            } else {
                Write-Pass "$GpuTaskName is newly installed and has not run yet (allowed before the first restart)."
            }
        } elseif ([uint32]$info.LastTaskResult -ne 0) {
            Write-Pending "$GpuTaskName last result is $($info.LastTaskResult), expected 0."
        } else {
            Write-Pass "$GpuTaskName last completed run result is 0."
        }
    } catch {
        Write-Pending "$GpuTaskName run history could not be verified: $($_.Exception.Message)"
    }
}

function Test-MonitorState {
    param([Parameter(Mandatory = $true)][object]$Monitor)
    $names = @(Get-CimInstance Win32_DesktopMonitor -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name } | Where-Object { $_ })
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        $names += @(Get-PnpDevice -Class Monitor -PresentOnly `
            -ErrorAction SilentlyContinue | ForEach-Object { $_.FriendlyName } |
            Where-Object { $_ })
    }
    if (@($names | Where-Object { $_ -eq $Monitor.DisplayName }).Count -gt 0) {
        Write-Pass "present monitor name includes '$($Monitor.DisplayName)'."
    } else {
        Write-Pending ("monitor name is '{0}'; expected '{1}'." -f
            (($names | Select-Object -Unique) -join ', '), $Monitor.DisplayName)
    }
}

function Test-ProfileState {
    param([Parameter(Mandatory = $true)][object]$Config)
    if ($DisableHibernation) { Test-HibernationDisabled }
    Test-GpuState $Config.Gpu
    Test-GpuTask
    if ($OnlineMonitorRescue -and -not $GpuOnly) {
        Test-MonitorState $Config.Monitor
    }
}

function Invoke-Main {
    Assert-Administrator
    if ($DisableHibernation -and $KeepHibernation) {
        throw '-DisableHibernation and -KeepHibernation cannot be combined.'
    }
    if ($GpuOnly -and $OnlineMonitorRescue) {
        throw '-GpuOnly and -OnlineMonitorRescue cannot be combined.'
    }
    if ($NoRegister -and -not $GpuOnly) {
        throw '-NoRegister is reserved for the offline -GpuOnly task action.'
    }
    if ($GpuOnly -and $script:ConfigParameterSet -ne 'Path') {
        throw '-GpuOnly requires the immutable local -ConfigPath task profile.'
    }

    $source = Read-Configuration
    $config = $source.Config
    $script:DesiredConfigSha256 = Get-Sha256HexFromText $source.Text
    Write-Host "[vm-profile] GPU='$($config.Gpu.Name)' profile=$($config.Gpu.Profile)" `
        -ForegroundColor Cyan

    # UUID mismatches are configuration/security failures, not merely a live
    # state that a restart can fix.  This check precedes every mutation.
    Assert-GuestUuidMatches $config

    if ($VerifyOnly) {
        Test-ProfileState $config
        if ($script:PendingMessages.Count -gt 0) { exit 10 }
        exit 0
    }

    Assert-TargetDisplayReady $config

    if ($GpuOnly) {
        $taskRoot = [IO.Path]::GetFullPath($source.SourceDirectory)
        $scriptRoot = [IO.Path]::GetFullPath($PSScriptRoot)
        $versionsPrefix = [IO.Path]::GetFullPath($VersionsRoot).TrimEnd('\') + '\'
        if ($taskRoot -ine $scriptRoot -or
            -not ($taskRoot.TrimEnd('\') + '\').StartsWith(
                $versionsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw '-GpuOnly must run from one immutable QemuVmProfile version directory.'
        }
        $taskPatch = Join-Path $taskRoot 'patch-grid-strings.ps1'
        if (-not (Test-Path -LiteralPath $taskPatch -PathType Leaf)) {
            throw "Offline GPU patch is missing: $taskPatch"
        }
        Assert-PowerShellScriptParses $taskPatch 'offline GPU patch script'
        Invoke-GpuPatch $config.Gpu $taskPatch
        Write-Host ''
        Write-Host '[vm-profile] offline refresh verification' -ForegroundColor Cyan
        Test-ProfileState $config
        return
    }

    $version = $null
    $taskCommitted = $false
    try {
        # Build and validate a complete immutable version while the existing
        # RefreshGridNames task continues to reference its old complete set.
        $version = New-ProfileVersion $source

        if ($DisableHibernation) { Disable-HibernationExplicitly }
        Invoke-GpuPatch $config.Gpu $version.Patch
        if ($OnlineMonitorRescue) {
            Invoke-OnlineMonitorRepair $config.Monitor $version.Monitor
        }

        # Registration is the commit point and has explicit rollback to the
        # prior task XML.  No fallible required operation follows it.
        Register-GpuRefreshTask $version.Apply $version.Config
        $taskCommitted = $true
    } finally {
        if (-not $taskCommitted -and $null -ne $version) {
            if (-not $script:TaskRegistrationAttempted -or
                $script:TaskRollbackConfirmed) {
                Remove-Item -LiteralPath $version.Root -Recurse -Force `
                    -ErrorAction SilentlyContinue
            } else {
                Write-Warning "task state is uncertain after rollback failure; preserving $($version.Root) so no possible task action points at missing files."
            }
        }
    }
    Publish-CompatibilityCopies $version

    Write-Host ''
    Write-Host '[vm-profile] verification' -ForegroundColor Cyan
    Test-ProfileState $config
    if ($script:PendingMessages.Count -gt 0) {
        Write-Host '[vm-profile] changes are installed; live Windows state is PENDING. No restart was performed.' `
            -ForegroundColor Yellow
    } else {
        Write-Host '[vm-profile] complete; all requested checks PASS. No restart was performed.' `
            -ForegroundColor Green
    }
}

try {
    Invoke-Main
} catch {
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 1
}

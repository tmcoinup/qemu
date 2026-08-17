[CmdletBinding(DefaultParameterSetName = 'Url')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Url')]
    [string]$LicenseUrl,

    [Parameter(Mandatory = $true, ParameterSetName = 'File')]
    [string]$TokenFile,

    [Parameter(ParameterSetName = 'File')]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$ExpectedTokenSha256,

    [Parameter(ParameterSetName = 'Url')]
    [switch]$InsecureTls,

    [Parameter(ParameterSetName = 'Url')]
    [switch]$AllowHttp,

    [ValidateRange(256, 1048576)]
    [int]$MinimumTokenBytes = 1024,

    [ValidateRange(5, 300)]
    [int]$WaitSeconds = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$serviceName = 'NVDisplay.ContainerLocalSystem'
$tokenDirectory = Join-Path $env:ProgramFiles 'NVIDIA Corporation\vGPU Licensing\ClientConfigToken'
$installedTokenPath = Join-Path $tokenDirectory 'client_configuration_token.tok'
$transactionId = [guid]::NewGuid().ToString('N')
$temporaryPath = Join-Path $tokenDirectory ('.client_configuration_token.{0}.tmp' -f $transactionId)
$headerPath = Join-Path $tokenDirectory ('.client_configuration_token.{0}.headers' -f $transactionId)
$rollbackPath = Join-Path $tokenDirectory ('.client_configuration_token.{0}.rollback' -f $transactionId)
$discardPath = Join-Path $tokenDirectory ('.client_configuration_token.{0}.discard' -f $transactionId)
$lockPath = Join-Path $tokenDirectory '.qemu-vgpu-license-install.lock'
$timeZonePath = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
$expectedTimeZone = 'China Standard Time'
$maximumClockSkewSeconds = 300
$serviceControlTimeoutSeconds = 30

function Wait-LicenseServiceStatus {
    param(
        [Parameter(Mandatory = $true)]
        [System.ServiceProcess.ServiceControllerStatus]$DesiredStatus,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $serviceName -ErrorAction Stop
        if ($service.Status -eq $DesiredStatus) {
            return $service
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    $service = Get-Service -Name $serviceName -ErrorAction Stop
    throw ("Service '{0}' did not reach {1} within {2} seconds " +
        "(current status: {3})" -f $serviceName, $DesiredStatus,
        $TimeoutSeconds, $service.Status)
}

function Invoke-LicenseServiceControl {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('start', 'stop')]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [System.ServiceProcess.ServiceControllerStatus]$DesiredStatus
    )

    $serviceController = Join-Path $env:SystemRoot 'System32\sc.exe'
    if (-not (Test-Path -LiteralPath $serviceController -PathType Leaf)) {
        throw "Windows service controller was not found: $serviceController"
    }

    $controlOutput = @(& $serviceController $Action $serviceName 2>&1)
    $controlExitCode = $LASTEXITCODE
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    if ($controlExitCode -ne 0 -and $service.Status -ne $DesiredStatus) {
        $detail = ($controlOutput | Out-String).Trim()
        throw ("Service control '{0}' failed for '{1}' (exit {2}, " +
            "status {3}): {4}" -f $Action, $serviceName,
            $controlExitCode, $service.Status, $detail)
    }

    return Wait-LicenseServiceStatus -DesiredStatus $DesiredStatus `
        -TimeoutSeconds $serviceControlTimeoutSeconds
}

function Restart-LicenseService {
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    if ($service.Status -eq
        [System.ServiceProcess.ServiceControllerStatus]::StopPending) {
        $service = Wait-LicenseServiceStatus `
            -DesiredStatus ([System.ServiceProcess.ServiceControllerStatus]::Stopped) `
            -TimeoutSeconds $serviceControlTimeoutSeconds
    }
    elseif ($service.Status -ne
        [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        $service = Invoke-LicenseServiceControl -Action stop `
            -DesiredStatus ([System.ServiceProcess.ServiceControllerStatus]::Stopped)
    }

    $service = Invoke-LicenseServiceControl -Action start `
        -DesiredStatus ([System.ServiceProcess.ServiceControllerStatus]::Running)
    Write-Host ("[license] service restart: {0}={1} " +
        "(bounded {2}s stop/start)" -f $serviceName, $service.Status,
        $serviceControlTimeoutSeconds)
}

function Find-NvidiaSmi {
    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),
        (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $command = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    throw 'nvidia-smi.exe was not found; install the NVIDIA vGPU guest driver first'
}

function Assert-LocalRtcContract {
    $timeConfiguration = Get-ItemProperty -LiteralPath $timeZonePath -ErrorAction Stop
    $timeZoneProperty = $timeConfiguration.PSObject.Properties['TimeZoneKeyName']
    $rtcProperty = $timeConfiguration.PSObject.Properties['RealTimeIsUniversal']

    if ($null -eq $timeZoneProperty -or $timeZoneProperty.Value -ne $expectedTimeZone) {
        $actual = if ($null -eq $timeZoneProperty) { '<missing>' } else { $timeZoneProperty.Value }
        throw "Windows timezone must be '$expectedTimeZone' for this VM (current: '$actual'). Change it in Windows Settings, fully shut down Windows, and retry; this installer only validates the RTC contract"
    }
    if ($null -ne $rtcProperty -and [int]$rtcProperty.Value -ne 0) {
        throw 'RealTimeIsUniversal must be absent or DWORD 0. The host owns RTC configuration and must launch QEMU with TZ=Asia/Shanghai and -rtc base=localtime,clock=host,driftfix=slew; fully shut down Windows after correcting the host/guest configuration'
    }

    $rtcValue = if ($null -eq $rtcProperty) { '<missing>' } else { [string][int]$rtcProperty.Value }
    Write-Host ('[license] RTC preflight: timezone={0} RealTimeIsUniversal={1} (read-only)' -f `
        $expectedTimeZone, $rtcValue)
}

function Assert-ServerClock {
    param([Parameter(Mandatory = $true)][string]$ResponseHeadersPath)

    $dateLines = @(
        Get-Content -LiteralPath $ResponseHeadersPath -ErrorAction Stop |
            Where-Object { $_ -match '(?i)^Date:\s*(.+?)\s*$' }
    )
    if ($dateLines.Count -eq 0) {
        throw 'The token response contained no HTTP Date header; refusing to install a token without an absolute UTC clock check'
    }

    $dateValue = ([regex]::Match($dateLines[-1], '(?i)^Date:\s*(.+?)\s*$')).Groups[1].Value
    $serverTime = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AllowWhiteSpaces -bor `
        [Globalization.DateTimeStyles]::AssumeUniversal -bor `
        [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTimeOffset]::TryParse(
            $dateValue,
            [Globalization.CultureInfo]::InvariantCulture,
            $styles,
            [ref]$serverTime
        )) {
        throw "The token response HTTP Date header could not be parsed: '$dateValue'"
    }

    $clockSkewSeconds = [Math]::Abs(
        ([DateTimeOffset]::UtcNow - $serverTime.ToUniversalTime()).TotalSeconds
    )
    if ($clockSkewSeconds -gt $maximumClockSkewSeconds) {
        throw ('Windows UTC time differs from the license server by {0:N0} seconds; NVIDIA may report Clock windback has been detected. Verify the host uses TZ=Asia/Shanghai with -rtc base=localtime,clock=host,driftfix=slew, fully shut down Windows, start a new QEMU process, and retry' -f $clockSkewSeconds)
    }
    Write-Host ('[license] clock preflight: timezone={0} UTC skew={1:N0}s' -f `
        $expectedTimeZone, $clockSkewSeconds)
}

function Assert-TokenConfiguration {
    $orphanedRollbacks = @(
        Get-ChildItem -LiteralPath $tokenDirectory `
            -Filter '.client_configuration_token*.rollback' -File -Force `
            -ErrorAction SilentlyContinue
    )
    if ($orphanedRollbacks.Count -ne 0) {
        $names = ($orphanedRollbacks | ForEach-Object { $_.Name }) -join ', '
        throw "A previous token transaction left a rollback file. Preserve it for manual recovery before retrying: $names"
    }

    $extraTokens = @(
        Get-ChildItem -LiteralPath $tokenDirectory -Filter '*.tok' -File -Force `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $installedTokenPath }
    )
    if ($extraTokens.Count -ne 0) {
        $names = ($extraTokens | ForEach-Object { $_.Name }) -join ', '
        throw "Multiple client configuration tokens are present. Keep only '$([IO.Path]::GetFileName($installedTokenPath))'; extra token(s): $names"
    }

    $legacyPaths = @(
        'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\GridLicensing',
        'HKLM:\SOFTWARE\NVIDIA Corporation\Global\GridLicensing'
    )
    $legacyNames = @('ServerAddress', 'ServerPort', 'BackupServerAddress', 'BackupServerPort')
    $legacyValues = @()
    foreach ($path in $legacyPaths) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        $settings = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        foreach ($name in $legacyNames) {
            $property = $settings.PSObject.Properties[$name]
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $legacyValues += "${path}\${name}=$($property.Value)"
            }
        }
    }
    if ($legacyValues.Count -ne 0) {
        throw ('Legacy NVIDIA license-server registry values are configured. Clear the Control Panel primary/secondary server fields and retry: ' + ($legacyValues -join '; '))
    }
}

function Get-LicenseLogHint {
    $logPath = Join-Path $env:SystemDrive `
        'Users\Public\Documents\NvidiaLogging\Log.NVDisplay.Container.exe.log'
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        return ''
    }

    $logMatches = @(
        Get-Content -LiteralPath $logPath -Tail 80 -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '(?i)clock windback|failed to acquire license|valid grid license not found' }
    )
    if ($logMatches.Count -eq 0) {
        return ''
    }
    return ([string]($logMatches[-1])).Trim()
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell session'
}

$uri = $null
$sourceTokenPath = $null
if ($PSCmdlet.ParameterSetName -eq 'Url') {
    if (-not [uri]::TryCreate($LicenseUrl, [UriKind]::Absolute, [ref]$uri)) {
        throw "LicenseUrl is not an absolute URL: $LicenseUrl"
    }
    if ($uri.Scheme -eq 'http') {
        if (-not $AllowHttp) {
            throw 'Plain HTTP is refused; use HTTPS or explicitly pass -AllowHttp on an isolated trusted network'
        }
    }
    elseif ($uri.Scheme -ne 'https') {
        throw "Unsupported LicenseUrl scheme: $($uri.Scheme)"
    }
}
else {
    $sourceTokenPath = (Resolve-Path -LiteralPath $TokenFile -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $sourceTokenPath -PathType Leaf)) {
        throw "TokenFile is not a file: $TokenFile"
    }
}

Assert-LocalRtcContract

if ($PSCmdlet.ParameterSetName -eq 'Url') {
    $curl = Get-Command 'curl.exe' -ErrorAction Stop
}
Get-Service -Name $serviceName -ErrorAction Stop | Out-Null
New-Item -ItemType Directory -Path $tokenDirectory -Force | Out-Null

$hadOriginal = $false
$tokenInstalled = $false
$activationSucceeded = $false
$tokenBytes = 0
$lockStream = $null

try {
    try {
        $lockStream = [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    }
    catch [IO.IOException] {
        throw 'Another vGPU license installation is already using the token directory'
    }

    Assert-TokenConfiguration
    $hadOriginal = Test-Path -LiteralPath $installedTokenPath -PathType Leaf
    Remove-Item -LiteralPath $temporaryPath, $headerPath, $discardPath -Force -ErrorAction SilentlyContinue

    if ($PSCmdlet.ParameterSetName -eq 'Url') {
        $protocolPolicy = if ($uri.Scheme -eq 'https') { '=https' } else { '=http,https' }
        $curlArguments = @(
            '--fail',
            '--silent',
            '--show-error',
            '--location',
            '--proto', $protocolPolicy,
            '--proto-redir', $protocolPolicy,
            '--connect-timeout', '10',
            '--max-time', '60',
            '--dump-header', $headerPath,
            '--output', $temporaryPath
        )
        if ($InsecureTls) {
            $curlArguments += '--insecure'
        }
        $curlArguments += @('--', $uri.AbsoluteUri)

        $curlOutput = @(& $curl.Source @curlArguments 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $detail = ($curlOutput | Out-String).Trim()
            throw "Token download failed (curl exit $LASTEXITCODE): $detail"
        }
        if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
            throw 'Token download reported success but did not create a file'
        }
        if (-not (Test-Path -LiteralPath $headerPath -PathType Leaf)) {
            throw 'Token download reported success but did not record response headers'
        }
        Assert-ServerClock -ResponseHeadersPath $headerPath
    }
    else {
        if ([IO.Path]::GetFullPath($sourceTokenPath) -ieq
            [IO.Path]::GetFullPath($installedTokenPath)) {
            throw 'TokenFile must be a transferred source file, not the installed NVIDIA token path'
        }
        Copy-Item -LiteralPath $sourceTokenPath -Destination $temporaryPath -Force
        $actualTokenSha256 = (Get-FileHash -LiteralPath $temporaryPath `
            -Algorithm SHA256 -ErrorAction Stop).Hash
        if (-not [string]::IsNullOrWhiteSpace($ExpectedTokenSha256) -and
            $actualTokenSha256 -ine $ExpectedTokenSha256) {
            throw "Transferred token SHA-256 mismatch (actual $actualTokenSha256, expected $ExpectedTokenSha256)"
        }
        Write-Host "[license] local token SHA-256=$actualTokenSha256; no HTTP download was used"
    }

    $candidateToken = Get-Item -LiteralPath $temporaryPath -ErrorAction Stop
    $tokenBytes = [int64]$candidateToken.Length
    if ($tokenBytes -lt $MinimumTokenBytes) {
        throw "Token is too small: $tokenBytes bytes (minimum $MinimumTokenBytes)"
    }

    $prefixBytes = @(Get-Content -LiteralPath $temporaryPath -Encoding Byte -TotalCount 256)
    $prefix = [Text.Encoding]::ASCII.GetString([byte[]]$prefixBytes)
    if ($prefix -match '(?i)<\s*(?:!doctype\s+html|html)') {
        throw 'The supplied token is HTML instead of a client configuration token'
    }

    if ($hadOriginal) {
        [IO.File]::Replace($temporaryPath, $installedTokenPath, $rollbackPath, $true)
    }
    else {
        Move-Item -LiteralPath $temporaryPath -Destination $installedTokenPath
    }
    $tokenInstalled = $true

    Restart-LicenseService
    $nvidiaSmi = Find-NvidiaSmi
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    $query = ''

    do {
        $queryLines = @(& $nvidiaSmi -q 2>&1)
        $queryExitCode = $LASTEXITCODE
        $query = $queryLines -join [Environment]::NewLine
        if ($queryExitCode -eq 0 -and
            $query -match '(?im)^\s*License Status\s*:\s*Licensed(?:\s+\([^\r\n]*\))?\s*$') {
            break
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)

    if ($queryExitCode -ne 0) {
        throw "nvidia-smi -q failed with exit code $queryExitCode"
    }
    if ($query -notmatch '(?im)^\s*License Status\s*:\s*Licensed(?:\s+\([^\r\n]*\))?\s*$') {
        $logHint = Get-LicenseLogHint
        $message = "NVIDIA license did not become Licensed within $WaitSeconds seconds; check guest time, network, and DLS logs"
        if (-not [string]::IsNullOrWhiteSpace($logHint)) {
            $message += "; NVIDIA client log: $logHint"
        }
        throw $message
    }

    $gpu = Get-CimInstance Win32_VideoController |
        Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' } |
        Select-Object -First 1
    if ($null -eq $gpu) {
        throw 'No NVIDIA display device was found in Win32_VideoController'
    }
    if ([int]$gpu.ConfigManagerErrorCode -ne 0) {
        throw "NVIDIA display device has ConfigManagerErrorCode=$($gpu.ConfigManagerErrorCode)"
    }

    $service = Get-Service -Name $serviceName -ErrorAction Stop
    if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
        throw "$serviceName is not running after activation"
    }

    $activationSucceeded = $true
    Remove-Item -LiteralPath $rollbackPath -Force -ErrorAction SilentlyContinue

    Write-Host "[license] token installed atomically: $installedTokenPath ($tokenBytes bytes)"
    Write-Host "[license] service=$($service.Status) license=Licensed"
    Write-Host "[license] gpu='$($gpu.Name)' driver=$($gpu.DriverVersion) code=$($gpu.ConfigManagerErrorCode)"
}
catch {
    $activationError = $_
    if ($tokenInstalled) {
        try {
            if ($hadOriginal -and (Test-Path -LiteralPath $rollbackPath -PathType Leaf)) {
                if (Test-Path -LiteralPath $installedTokenPath -PathType Leaf) {
                    [IO.File]::Replace($rollbackPath, $installedTokenPath, $discardPath, $true)
                    Remove-Item -LiteralPath $discardPath -Force -ErrorAction SilentlyContinue
                }
                else {
                    Move-Item -LiteralPath $rollbackPath -Destination $installedTokenPath
                }
            }
            elseif (-not $hadOriginal) {
                Remove-Item -LiteralPath $installedTokenPath -Force -ErrorAction SilentlyContinue
            }
            Restart-LicenseService
        }
        catch {
            throw "Activation failed: $($activationError.Exception.Message); token rollback also failed: $($_.Exception.Message)"
        }
    }
    throw $activationError
}
finally {
    Remove-Item -LiteralPath $temporaryPath, $headerPath, $discardPath -Force -ErrorAction SilentlyContinue
    if ($activationSucceeded) {
        Remove-Item -LiteralPath $rollbackPath -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
}

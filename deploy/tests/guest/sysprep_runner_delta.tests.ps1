#requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][string]$RunnerPath,
    [Parameter(Mandatory = $true)][string]$ServicingGatePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Context
    )
    if ($Actual -ne $Expected) {
        throw "$Context`: expected=$Expected actual=$Actual"
    }
}

. $RunnerPath
. $ServicingGatePath

if ($env:OS -ne 'Windows_NT') {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    Start-NativeProcessAndWait -FilePath /bin/sleep `
        -ArgumentList @('0.30')
    $stopwatch.Stop()
    if ($stopwatch.ElapsedMilliseconds -lt 250) {
        throw "native process wait returned too early: $($stopwatch.ElapsedMilliseconds)ms"
    }
}

Assert-Equal -Actual (Get-LogDeltaStartLine `
        -Before @('old-info', 'old-error') `
        -After @('old-info', 'old-error', 'new-info')) `
    -Expected 2 -Context 'append delta'
Assert-Equal -Actual (Get-LogDeltaStartLine `
        -Before @('old-info', 'old-error') `
        -After @('new-info')) `
    -Expected 0 -Context 'truncated log'
Assert-Equal -Actual (Get-LogDeltaStartLine `
        -Before @('old-info', 'old-error') `
        -After @('new-info', 'new-error')) `
    -Expected 0 -Context 'same-length rewrite'
Assert-Equal -Actual (Get-LogDeltaStartLine `
        -Before @() -After @('first-run')) `
    -Expected 0 -Context 'new log'

$oldFailure = '2026-09-01 14:00:00, Error SYSPRP old failure hr = 0x800F0975'
$currentInfo = '2026-09-01 15:00:00, Info SYSPRP clean validation passed'
$allLines = @($oldFailure, $currentInfo)
$delta = @(Get-LinesFromOffset -Lines $allLines -StartLine 1)
$failures = @(Get-SysprepFailureLines `
        -SetupErrDelta @() -SetupActDelta $delta)
Assert-Equal -Actual $failures.Count -Expected 0 `
    -Context 'historical error excluded from successful invocation'

$reservedFailure = @(
    '2026-09-01 15:01:00, Error SYSPRP Sysprep_Clean_Validate_Opk: reserved storage is in use; hr = 0x800F0975'
)
$failures = @(Get-SysprepFailureLines `
        -SetupErrDelta @() -SetupActDelta $reservedFailure)
Assert-Equal -Actual $failures.Count -Expected 1 `
    -Context 'current reserved-storage failure'

$appxFailure = @(
    '2026-09-01 15:02:00, Error SYSPRP Failed to remove apps for the current user: 0x80073cf2.'
)
$failures = @(Get-SysprepFailureLines `
        -SetupErrDelta @() -SetupActDelta $appxFailure)
Assert-Equal -Actual $failures.Count -Expected 1 `
    -Context 'current Appx failure'

$setuperrFailure = @(
    '2026-09-01 15:03:00, Error SYSPRP opaque future failure signature'
)
$failures = @(Get-SysprepFailureLines `
        -SetupErrDelta $setuperrFailure -SetupActDelta @())
Assert-Equal -Actual $failures.Count -Expected 1 `
    -Context 'any current setuperr line is fatal'

$zeroPaddedFailure = @(
    '2026-09-01 15:04:00, Error SYSPRP provider returned hr = 0x00000005'
)
$failures = @(Get-SysprepFailureLines `
        -SetupErrDelta @() -SetupActDelta $zeroPaddedFailure)
Assert-Equal -Actual $failures.Count -Expected 1 `
    -Context 'zero-padded nonzero HRESULT is fatal'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("vmate-sysprep-log-test-{0}" -f [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$testLog = Join-Path $testRoot 'setupact.log'
try {
    [IO.File]::WriteAllLines($testLog, @(
            '2026-09-01 14:00:00, Info unrelated 0x800F0975 text',
            '2026-09-01 14:01:02, Error SYSPRP reserved storage is in use; hr = 0x800F0975'
        ), (New-Object Text.UTF8Encoding($false)))
    $latestFailure = Get-LatestReservedStorageFailureTime `
        -LogPaths @($testLog)
    $expectedFailure = [DateTime]::ParseExact(
        '2026-09-01 14:01:02',
        'yyyy-MM-dd HH:mm:ss',
        [Globalization.CultureInfo]::InvariantCulture
    )
    Assert-Equal -Actual $latestFailure -Expected $expectedFailure `
        -Context 'latest current-boot reserved-storage timestamp'
} finally {
    if ([IO.File]::Exists($testLog)) { [IO.File]::Delete($testLog) }
    if ([IO.Directory]::Exists($testRoot)) {
        [IO.Directory]::Delete($testRoot, $false)
    }
}

Write-Host 'PASS: Sysprep runner Panther delta detection'

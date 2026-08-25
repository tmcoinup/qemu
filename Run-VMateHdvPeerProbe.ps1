[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ComputeSystemId,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$VmwpPid,

    [string]$ProbePath = 'C:\VMateLab\native\VMateHdvPeerProbe.exe',

    [switch]$CreateDevice,

    [switch]$AddFlexibleIov,

    [string]$LabVmName,

    [switch]$PauseBefore,

    [switch]$RunWhileRunning,

    [switch]$TurnOffAfter,

    [string]$OutputPath = 'C:\VMateLab\hdv-p11-run.json'
)

$ErrorActionPreference = 'Stop'
$stdoutPath = [IO.Path]::ChangeExtension($OutputPath, '.stdout.txt')
$stderrPath = [IO.Path]::ChangeExtension($OutputPath, '.stderr.txt')
Remove-Item -LiteralPath $stdoutPath, $stderrPath, $OutputPath `
    -Force -ErrorAction SilentlyContinue

$startedAt = [DateTime]::UtcNow
$arguments = @(
    '--id', $ComputeSystemId,
    '--initialize-hdv',
    '--vmwp-pid', [string]$VmwpPid
)
if ($CreateDevice) {
    $arguments += '--create-device'
}
if ($AddFlexibleIov) {
    if (-not $CreateDevice) {
        throw '-AddFlexibleIov requires -CreateDevice.'
    }
    if ([string]::IsNullOrWhiteSpace($LabVmName) -or
        -not $TurnOffAfter -or
        ([bool]$PauseBefore -eq [bool]$RunWhileRunning)) {
        throw ('-AddFlexibleIov requires -LabVmName, -TurnOffAfter, and ' +
            'exactly one of -PauseBefore or -RunWhileRunning so the ' +
            'runtime-only test is fail-closed.')
    }
    $arguments += '--add-flexible-iov'
}

$labVm = $null
$stateBefore = $null
$stateAfterPause = $null
$stateAfterCleanup = $null
if (-not [string]::IsNullOrWhiteSpace($LabVmName)) {
    $labVm = Get-VM -Name $LabVmName -ErrorAction Stop
    if ([guid]$labVm.Id -ne [guid]$ComputeSystemId) {
        throw ('VM {0} has ID {1}, not requested compute-system ID {2}.' -f
            $LabVmName, $labVm.Id, $ComputeSystemId)
    }
    $stateBefore = [string]$labVm.State
}

$process = $null
$runError = $null
$cleanupError = $null
try {
    if ($PauseBefore) {
        if ($null -eq $labVm) {
            throw '-PauseBefore requires -LabVmName.'
        }
        if ($labVm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) {
            Suspend-VM -VM $labVm -Confirm:$false -ErrorAction Stop
        }
        $labVm = Get-VM -Name $LabVmName -ErrorAction Stop
        $stateAfterPause = [string]$labVm.State
        if ($labVm.State -ne [Microsoft.HyperV.PowerShell.VMState]::Paused) {
            throw ('VM {0} did not enter Paused state; current state is {1}.' -f
                $LabVmName, $labVm.State)
        }
    }
    if ($RunWhileRunning) {
        if ($null -eq $labVm) {
            throw '-RunWhileRunning requires -LabVmName.'
        }
        $labVm = Get-VM -Name $LabVmName -ErrorAction Stop
        if ($labVm.State -ne [Microsoft.HyperV.PowerShell.VMState]::Running) {
            throw ('VM {0} must be Running for the live modify test; ' +
                'current state is {1}.' -f $LabVmName, $labVm.State)
        }
        $stateAfterPause = [string]$labVm.State
    }

    $process = Start-Process -FilePath $ProbePath -ArgumentList $arguments `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
} catch {
    $runError = $_.Exception.Message
} finally {
    if ($TurnOffAfter) {
        try {
            if ($null -eq $labVm) {
                throw '-TurnOffAfter requires -LabVmName.'
            }
            $labVm = Get-VM -Name $LabVmName -ErrorAction Stop
            if ($labVm.State -ne [Microsoft.HyperV.PowerShell.VMState]::Off) {
                Stop-VM -VM $labVm -TurnOff -Force -Confirm:$false `
                    -ErrorAction Stop
            }
            $stateAfterCleanup = [string](
                Get-VM -Name $LabVmName -ErrorAction Stop
            ).State
        } catch {
            $cleanupError = $_.Exception.Message
        }
    }
}
$finishedAt = [DateTime]::UtcNow

$stdout = if (Test-Path -LiteralPath $stdoutPath) {
    [IO.File]::ReadAllText($stdoutPath)
} else {
    ''
}
$stderr = if (Test-Path -LiteralPath $stderrPath) {
    [IO.File]::ReadAllText($stderrPath)
} else {
    ''
}

$record = [ordered]@{
    SchemaVersion = 1
    Operation = 'run-hdv-peer-probe'
    ComputeSystemId = $ComputeSystemId
    VmwpPid = $VmwpPid
    CreateDevice = [bool]$CreateDevice
    AddFlexibleIov = [bool]$AddFlexibleIov
    LabVmName = $LabVmName
    PauseBefore = [bool]$PauseBefore
    RunWhileRunning = [bool]$RunWhileRunning
    TurnOffAfter = [bool]$TurnOffAfter
    StateBefore = $stateBefore
    StateAfterPause = $stateAfterPause
    StateAfterCleanup = $stateAfterCleanup
    StartedAtUtc = $startedAt.ToString('o')
    FinishedAtUtc = $finishedAt.ToString('o')
    ExitCode = if ($null -ne $process) { $process.ExitCode } else { $null }
    ExitCodeHex = if ($null -ne $process) {
        '0x{0:X8}' -f ($process.ExitCode -band 0xffffffffL)
    } else {
        $null
    }
    RunError = $runError
    CleanupError = $cleanupError
    Stdout = $stdout.Trim()
    Stderr = $stderr.Trim()
}

$json = $record | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText(
    $OutputPath,
    $json,
    [Text.UTF8Encoding]::new($false)
)
$json

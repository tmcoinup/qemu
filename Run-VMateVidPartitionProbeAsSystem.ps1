#Requires -Version 5.1

<#
.SYNOPSIS
    Runs the read-only VID partition probe once as LocalSystem.

.DESCRIPTION
    Hyper-V worker processes can deny PROCESS_DUP_HANDLE even to an elevated
    administrator.  This diagnostic uses a short-lived scheduled task to
    distinguish an administrator boundary from a protected-process boundary.
    The task is always removed by the caller and the probe never registers or
    changes CPUID results.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 2147483647)]
    [int]$VmwpPid,

    [string]$ProbePath =
        'C:\VMateLab\native\VMateVidPartitionProbe.exe',

    [string]$OutputPath =
        'C:\VMateLab\vid-system-probe.json',

    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 30,

    [UInt64]$SourceHandle = 0,

    [switch]$ImpersonateTarget,

    [switch]$SpawnTargetToken,

    [switch]$SystemWorker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-VMateIsLocalSystem {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return $identity.IsSystem
}

function Write-VMateSystemProbeResult {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Result
    )

    $directory = Split-Path -Parent $Path
    if (-not [String]::IsNullOrWhiteSpace($directory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $json = $Result | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText(
        $Path,
        $json,
        [Text.UTF8Encoding]::new($false))
}

if ($SystemWorker) {
    if (-not (Test-VMateIsLocalSystem)) {
        throw 'SystemWorker must run as LocalSystem.'
    }
    if (-not (Test-Path -LiteralPath $ProbePath -PathType Leaf)) {
        throw "VID probe is missing: $ProbePath"
    }

    $probeArguments = @('--pid', [string]$VmwpPid)
    if ($SourceHandle -ne 0) {
        $probeArguments += @('--handle', ('0x{0:X}' -f $SourceHandle))
    }
    if ($ImpersonateTarget) {
        $probeArguments += '--impersonate-target'
    }
    if ($SpawnTargetToken) {
        $probeArguments += '--spawn-target-token'
    }
    $probeOutput = @(& $ProbePath @probeArguments 2>&1 |
            ForEach-Object { $_.ToString() })
    $probeExitCode = $LASTEXITCODE
    Write-VMateSystemProbeResult -Path $OutputPath -Result (
        [pscustomobject][ordered]@{
            SchemaVersion = 1
            Operation = 'read-only-local-system-vid-probe'
            Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            VmwpPid = $VmwpPid
            SourceHandle = if ($SourceHandle -ne 0) {
                '0x{0:X}' -f $SourceHandle
            } else { '' }
            TargetImpersonationRequested = [bool]$ImpersonateTarget
            TargetProcessTokenRequested = [bool]$SpawnTargetToken
            ProbePath = $ProbePath
            ProbeExitCode = $probeExitCode
            ProbeOutput = $probeOutput
            CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        })
    return
}

if (-not (Test-Path -LiteralPath $ProbePath -PathType Leaf)) {
    throw "VID probe is missing: $ProbePath"
}
if ([String]::IsNullOrWhiteSpace($PSCommandPath) -or
    -not (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
    throw 'This diagnostic must be launched from a saved .ps1 file.'
}

$taskName = 'VMate-VidProbe-{0}-{1}' -f $VmwpPid, $PID
$escapedScript = $PSCommandPath.Replace("'", "''")
$escapedProbe = $ProbePath.Replace("'", "''")
$escapedOutput = $OutputPath.Replace("'", "''")
$workerCommand = (
    "& '$escapedScript' -VmwpPid $VmwpPid " +
    "-ProbePath '$escapedProbe' -OutputPath '$escapedOutput' " +
    '-SystemWorker')
if ($SourceHandle -ne 0) {
    $workerCommand += " -SourceHandle $SourceHandle"
}
if ($ImpersonateTarget) {
    $workerCommand += ' -ImpersonateTarget'
}
if ($SpawnTargetToken) {
    $workerCommand += ' -SpawnTargetToken'
}
$encodedCommand = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($workerCommand))
$powershellPath = Join-Path $PSHOME 'powershell.exe'
$action = New-ScheduledTaskAction -Execute $powershellPath -Argument (
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
    "-EncodedCommand $encodedCommand")
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
    -LogonType ServiceAccount -RunLevel Highest

if (Test-Path -LiteralPath $OutputPath) {
    Remove-Item -LiteralPath $OutputPath -Force
}

try {
    Register-ScheduledTask -TaskName $taskName -Action $action `
        -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline -and
        -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        throw ("LocalSystem VID probe timed out; LastTaskResult=0x{0:X8}." `
                -f [uint32]$taskInfo.LastTaskResult)
    }
    Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
}
finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false `
        -ErrorAction SilentlyContinue
}

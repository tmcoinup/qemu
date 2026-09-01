#requires -Version 5.1
<#
.SYNOPSIS
  Runs G-11 Sysprep quietly and detects failure from this invocation's logs.

.DESCRIPTION
  Sysprep validation failures are not reliably reflected in the process exit
  code. This wrapper snapshots the Panther logs in memory, invokes Sysprep with
  Microsoft's automation switch /quiet, and evaluates only newly written log
  lines. On failure it creates and opens the read-only diagnostic report.
#>
[CmdletBinding()]
param(
    [string]$AnswerFile = (Join-Path $PSScriptRoot 'g11-sysprep-clone.xml'),
    [string]$DiagnosticScript = (
        Join-Path $PSScriptRoot 'Collect-Sysprep-Diagnostics.ps1'
    ),
    [string]$DiagnosticOutput = (
        Join-Path $PSScriptRoot 'Sysprep-Diagnostics.txt'
    )
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Resolve-PlainFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item -isnot [IO.FileInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context must be a regular, non-reparse file: $Path"
    }
    return $item.FullName
}

function Get-LogLines {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $Path -ErrorAction Stop |
        ForEach-Object { [string]$_ })
}

function Get-LogDeltaStartLine {
    param(
        [AllowEmptyCollection()][string[]]$Before = @(),
        [AllowEmptyCollection()][string[]]$After = @()
    )

    if ($Before.Count -eq 0) { return 0 }
    if ($After.Count -lt $Before.Count) { return 0 }
    for ($index = 0; $index -lt $Before.Count; $index++) {
        if (-not [string]::Equals(
                [string]$Before[$index],
                [string]$After[$index],
                [StringComparison]::Ordinal)) {
            return 0
        }
    }
    return $Before.Count
}

function Get-LinesFromOffset {
    param(
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [ValidateRange(0, [int]::MaxValue)][int]$StartLine = 0
    )

    if ($StartLine -ge $Lines.Count) { return @() }
    return @($Lines[$StartLine..($Lines.Count - 1)])
}

function Get-SysprepFailureLines {
    param(
        [AllowEmptyCollection()][string[]]$SetupErrDelta = @(),
        [AllowEmptyCollection()][string[]]$SetupActDelta = @()
    )

    $failures = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' `
        ([StringComparer]::Ordinal)
    foreach ($line in $SetupErrDelta) {
        if (-not [string]::IsNullOrWhiteSpace($line) -and $seen.Add($line)) {
            [void]$failures.Add($line)
        }
    }

    $fatalPattern = '(?i)\bSYSPRP\b.*(?:Hit failure|halting sysprep|Error in validating|Failure occurred|Failed (?:while|to)|(?:hr|dwRet)\s*=\s*0x0*[1-9a-f][0-9a-f]*)'
    foreach ($line in $SetupActDelta) {
        if ($line -match $fatalPattern -and $seen.Add($line)) {
            [void]$failures.Add($line)
        }
    }
    return $failures.ToArray()
}

function Get-ImageState {
    return [string](Get-ItemProperty -LiteralPath `
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' `
        -Name ImageState -ErrorAction Stop).ImageState
}

function Start-NativeProcessAndWait {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList
    )

    Start-Process -FilePath $FilePath -ArgumentList $ArgumentList `
        -Wait -ErrorAction Stop
}

function Write-FailureReport {
    param(
        [Parameter(Mandatory = $true)][string]$Collector,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [ValidateRange(0, [int]::MaxValue)][int]$SetupErrStartLine,
        [ValidateRange(0, [int]::MaxValue)][int]$SetupActStartLine
    )

    try {
        & $Collector -OutputPath $OutputPath `
            -SetupErrStartLine $SetupErrStartLine `
            -SetupActStartLine $SetupActStartLine `
            -InvocationScoped
        Write-Host "[PASS] Report saved as $OutputPath" -ForegroundColor Green
        try {
            Start-Process -FilePath notepad.exe `
                -ArgumentList @(('"{0}"' -f $OutputPath))
        } catch {
            Write-Host "[WARN] Report was saved but Notepad could not be opened: $($_.Exception.Message)" `
                -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[ERROR] Could not create the automatic report: $($_.Exception.Message)" `
            -ForegroundColor Red
        Write-Host 'Inspect %WINDIR%\System32\Sysprep\Panther\setuperr.log and setupact.log.' `
            -ForegroundColor Yellow
    }
}

function Invoke-G11SysprepMain {
    $answerPath = Resolve-PlainFile -Path $AnswerFile `
        -Context 'Sysprep answer file'
    $collectorPath = Resolve-PlainFile -Path $DiagnosticScript `
        -Context 'Sysprep diagnostic collector'
    $outputFullPath = [IO.Path]::GetFullPath($DiagnosticOutput)
    $outputParent = [IO.Path]::GetDirectoryName($outputFullPath)
    $outputParentItem = Get-Item -LiteralPath $outputParent -Force `
        -ErrorAction Stop
    if ($outputParentItem -isnot [IO.DirectoryInfo] -or
        ($outputParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) `
            -ne 0) {
        throw "Diagnostic output parent must be a regular directory: $outputParent"
    }

    $sysprepPath = Resolve-PlainFile -Path (
        Join-Path $env:SystemRoot 'System32\Sysprep\Sysprep.exe'
    ) -Context 'Microsoft Sysprep executable'
    $panther = Join-Path $env:WINDIR 'System32\Sysprep\Panther'
    $setupErr = Join-Path $panther 'setuperr.log'
    $setupAct = Join-Path $panther 'setupact.log'
    $beforeErr = @(Get-LogLines -Path $setupErr)
    $beforeAct = @(Get-LogLines -Path $setupAct)

    Write-Host '[INFO] Starting Microsoft Sysprep in automated quiet mode.' `
        -ForegroundColor Cyan
    Write-Host '[INFO] A validation failure will be diagnosed automatically; no modal error confirmation is required.' `
        -ForegroundColor Gray

    $sysprepArguments = @(
        '/generalize',
        '/oobe',
        '/shutdown',
        '/quiet',
        ('/unattend:"{0}"' -f $answerPath)
    )
    Start-NativeProcessAndWait -FilePath $sysprepPath `
        -ArgumentList $sysprepArguments

    # A successful /shutdown may terminate this process before post-validation.
    # If execution continues, Sysprep has already closed and its logs are stable.
    $afterErr = @(Get-LogLines -Path $setupErr)
    $afterAct = @(Get-LogLines -Path $setupAct)
    $errStart = Get-LogDeltaStartLine -Before $beforeErr -After $afterErr
    $actStart = Get-LogDeltaStartLine -Before $beforeAct -After $afterAct
    $newErr = @(Get-LinesFromOffset -Lines $afterErr -StartLine $errStart)
    $newAct = @(Get-LinesFromOffset -Lines $afterAct -StartLine $actStart)
    $failureLines = @(Get-SysprepFailureLines `
            -SetupErrDelta $newErr -SetupActDelta $newAct)

    $imageState = 'UNKNOWN'
    $successfulState = $false
    for ($attempt = 0; $attempt -lt 20 -and
        $failureLines.Count -eq 0; $attempt++) {
        try {
            $imageState = Get-ImageState
            $successfulState = $imageState -eq `
                'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
            if ($successfulState) { break }
        } catch {
            $imageState = "QUERY_FAILED: $($_.Exception.Message)"
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if ($failureLines.Count -gt 0) {
        try {
            $imageState = Get-ImageState
        } catch {
            $imageState = "QUERY_FAILED: $($_.Exception.Message)"
        }
    }
    if ($failureLines.Count -eq 0 -and $successfulState) {
        Write-Host '[PASS] Sysprep generalized the template; waiting for Windows shutdown.' `
            -ForegroundColor Green
        return 0
    }

    if ($failureLines.Count -gt 0) {
        Write-Host '[ERROR] This Sysprep invocation wrote fatal Panther errors.' `
            -ForegroundColor Red
        foreach ($line in @($failureLines | Select-Object -Last 12)) {
            Write-Host "  $line" -ForegroundColor Red
        }
    } else {
        Write-Host ("[ERROR] Sysprep returned without fatal log lines, but ImageState={0}; expected IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE." -f `
                $imageState) -ForegroundColor Red
    }

    Write-FailureReport -Collector $collectorPath -OutputPath $outputFullPath `
        -SetupErrStartLine $errStart -SetupActStartLine $actStart
    Write-Host 'Fix only the reported blocker, then run Seal-G11-Template.cmd again.' `
        -ForegroundColor Yellow
    return 1
}

if ($MyInvocation.InvocationName -eq '.') { return }

try {
    exit (Invoke-G11SysprepMain)
} catch {
    Write-Host "[ERROR] Sysprep automation failed closed: $($_.Exception.Message)" `
        -ForegroundColor Red
    exit 2
}

#requires -Version 5.1
<#
.SYNOPSIS
  Return an experimental G-11 clone to template-safe application state.

.DESCRIPTION
  Uses the saved Guest Lite and guest-performance rollback baselines, in
  reverse apply order, before removing exact VMate-owned clone state.  It is
  intended only for Seal-G11-Template.cmd and accepts no caller-provided path.

  Per-VM system NVAPI projection state is deliberately not removed here.  The
  preceding read-only readiness gate refuses that state because its supported
  rollback requires its own verified package and a reboot.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ProgramDataRoot = [IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
$KitRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$GuestLiteRollback = Join-Path $KitRoot `
    'Template-Reset\GuestLite\G11-Guest-Lite.ps1'
$PerformanceRollback = Join-Path $KitRoot `
    'Template-Reset\GuestPerformance\Optimize-Guest.ps1'
$GuestLiteRoot = Join-Path $ProgramDataRoot 'G11GuestLite'
$PerformanceRoot = Join-Path $ProgramDataRoot 'G11GuestPerformance'
$PortableStateRoot = Join-Path $ProgramDataRoot 'QemuGpuZProfile'
$VMateRoot = Join-Path $ProgramDataRoot 'VMate\G11'
$ProjectionRoot = Join-Path $ProgramDataRoot 'G11\SystemNvapiProjection'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Assert-ProgramDataChild {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $prefix = $ProgramDataRoot + '\'
    if (-not $fullPath.StartsWith(
            $prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing a path outside ProgramData: $fullPath"
    }
    return $fullPath
}

function Get-PlainFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item -isnot [IO.FileInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context must be a regular, non-reparse file: $Path"
    }
    return $item
}

function Get-PlainDirectoryIfPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $fullPath = Assert-ProgramDataChild $Path
    if (-not (Test-Path -LiteralPath $fullPath)) { return $null }
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if ($item -isnot [IO.DirectoryInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context must be a regular, non-reparse directory: $fullPath"
    }
    return $item
}

function Invoke-SavedRollbackIfPresent {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$RollbackScript,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $root = Get-PlainDirectoryIfPresent $StateRoot "$Label state root"
    if ($null -eq $root) {
        Write-Host "[reset] $Label state: not present" -ForegroundColor Gray
        return
    }
    $statePath = Join-Path $root.FullName 'state.json'
    if (-not (Test-Path -LiteralPath $statePath)) {
        Write-Host "[reset] $Label active baseline: not present" `
            -ForegroundColor Gray
        return
    }
    $null = Get-PlainFile $statePath "$Label rollback baseline"
    $script = Get-PlainFile $RollbackScript "$Label rollback script"
    $powerShell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    Write-Host "[reset] rolling back $Label from its saved baseline" `
        -ForegroundColor Cyan
    & $powerShell -NoLogo -NoProfile -NonInteractive `
        -ExecutionPolicy Bypass -File $script.FullName -Mode Rollback
    if ($LASTEXITCODE -ne 0) {
        throw "$Label rollback failed with exit code $LASTEXITCODE. State was retained for a safe retry."
    }
}

function Remove-OwnedTaskIfPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ExpectedActionPath
    )

    $tasks = @(Get-ScheduledTask -TaskPath '\' -TaskName $Name `
        -ErrorAction SilentlyContinue)
    if ($tasks.Count -eq 0) { return }
    if ($tasks.Count -ne 1) {
        throw "Expected at most one owned task '$Name'; observed $($tasks.Count)."
    }
    $actions = @($tasks[0].Actions)
    $actionText = (@($actions | ForEach-Object {
        (([string]$_.Execute) + ' ' + ([string]$_.Arguments)).Trim()
    }) -join ' | ')
    if ($actions.Count -ne 1 -or
        $actionText.IndexOf($ExpectedActionPath,
            [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Task '$Name' is not owned by the expected G-11 path; refusing removal. Action: $actionText"
    }
    Stop-ScheduledTask -TaskPath '\' -TaskName $Name `
        -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskPath '\' -TaskName $Name `
        -Confirm:$false -ErrorAction Stop
    Write-Host "[reset] removed owned scheduled task: $Name" `
        -ForegroundColor Gray
}

function Remove-ExactTreeIfPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $root = Get-PlainDirectoryIfPresent $Path $Context
    if ($null -eq $root) { return }
    $reparseEntries = @(Get-ChildItem -LiteralPath $root.FullName -Force `
        -Recurse -ErrorAction Stop | Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        })
    if ($reparseEntries.Count -gt 0) {
        throw "$Context contains a reparse point; refusing recursive removal: $($reparseEntries[0].FullName)"
    }
    Remove-Item -LiteralPath $root.FullName -Recurse -Force `
        -ErrorAction Stop
    Write-Host "[reset] removed $Context" -ForegroundColor Gray
}

function Remove-ExactFileIfPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $fullPath = Assert-ProgramDataChild $Path
    if (-not (Test-Path -LiteralPath $fullPath)) { return }
    $item = Get-PlainFile $fullPath $Context
    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
    Write-Host "[reset] removed $Context" -ForegroundColor Gray
}

try {
    if (-not (Test-Administrator)) {
        throw 'Template reset must run as Administrator.'
    }
    $programData = Get-Item -LiteralPath $ProgramDataRoot -Force `
        -ErrorAction Stop
    if ($programData -isnot [IO.DirectoryInfo] -or
        ($programData.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "ProgramData must be a regular, non-reparse directory: $ProgramDataRoot"
    }
    $null = Get-PlainFile $GuestLiteRollback `
        'packaged Guest Lite rollback script'
    $null = Get-PlainFile $PerformanceRollback `
        'packaged guest-performance rollback script'
    if (Test-Path -LiteralPath $ProjectionRoot) {
        throw 'Per-VM system NVAPI projection state is present. The read-only readiness gate should have refused this instance; nothing was reset.'
    }

    Remove-OwnedTaskIfPresent 'VMate-G11-Clone-Continuation' `
        (Join-Path $VMateRoot 'Finalize-Clone.ps1')

    # Reverse the apply order so overlapping settings return to the real
    # pre-clone baseline: Guest Lite was applied after portable performance.
    Invoke-SavedRollbackIfPresent $GuestLiteRoot $GuestLiteRollback `
        'Guest Lite'
    Invoke-SavedRollbackIfPresent $PerformanceRoot $PerformanceRollback `
        'guest performance'

    # A successful Guest Lite rollback removes its owned task.  If an early
    # interrupted run left only the task, remove it after verifying its action.
    Remove-OwnedTaskIfPresent 'G11GuestLite-EnforceProfile' `
        (Join-Path $GuestLiteRoot 'tools\G11-Guest-Lite.ps1')

    Remove-ExactTreeIfPresent $GuestLiteRoot 'Guest Lite clone state'
    Remove-ExactTreeIfPresent $PerformanceRoot `
        'guest-performance clone state'
    Remove-ExactTreeIfPresent $PortableStateRoot `
        'licensed portable clone result'
    Remove-ExactTreeIfPresent (Join-Path $VMateRoot 'logs') `
        'clone initialization logs'
    Remove-ExactFileIfPresent (Join-Path $VMateRoot `
        'clone-initialization.json') 'clone completion marker'
    Remove-ExactFileIfPresent (Join-Path $VMateRoot `
        'clone-initialization-error.txt') 'clone failure marker'

    Write-Host '[PASS] Clone-bound application state was rolled back and removed.' `
        -ForegroundColor Green
    Write-Host 'Windows SID and MachineGuid were not edited; Sysprep /generalize handles them.' `
        -ForegroundColor Gray
    Write-Host 'No BCD, driver-signing, or kernel-driver change was attempted.' `
        -ForegroundColor Gray
    exit 0
} catch {
    Write-Host ''
    Write-Host "[ERROR] Template state reset failed: $($_.Exception.Message)" `
        -ForegroundColor Red
    Write-Host 'Sysprep was not started. Fix the reported item and run Seal again.' `
        -ForegroundColor Yellow
    exit 1
}

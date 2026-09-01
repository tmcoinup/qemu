#requires -Version 5.1
<#
.SYNOPSIS
  Read-only Windows servicing gate immediately before G-11 Sysprep.

.DESCRIPTION
  Blocks known reboot/update/component-servicing states without changing
  Reserved Storage, Windows Update, Sysprep, BCD, drivers, or registry data.
  Microsoft exposes no authoritative read-only "Reserved Storage is in use"
  query, so a PASS means only that no known blocker was observed. Sysprep's
  own validation remains authoritative.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Add-Signal {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Signals,
        [Parameter(Mandatory = $true)][string]$Text
    )
    if (-not $Signals.Contains($Text)) {
        [void]$Signals.Add($Text)
    }
}

function Test-RegistryKeyPresent {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [bool](Test-Path -LiteralPath $Path -ErrorAction Stop)
}

function Get-NonEmptyRegistryMultiString {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    try {
        $values = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        $property = $values.PSObject.Properties[$Name]
        if ($null -eq $property) { return @() }
        return @($property.Value | Where-Object {
                $null -ne $_ -and
                -not [string]::IsNullOrWhiteSpace([string]$_)
            })
    } catch [System.Management.Automation.ItemNotFoundException] {
        return @()
    }
}

function Get-LatestReservedStorageFailureTime {
    param([Parameter(Mandatory = $true)][string[]]$LogPaths)

    $latest = [DateTime]::MinValue
    foreach ($path in $LogPaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        foreach ($match in @(Select-String -LiteralPath $path -Pattern `
                '(?i)SYSPRP.*(?:0x800F0975|reserved storage is in use)' `
                -ErrorAction Stop)) {
            $line = [string]$match.Line
            if ($line.Length -lt 19) { continue }
            $parsed = [DateTime]::MinValue
            if ([DateTime]::TryParseExact(
                    $line.Substring(0, 19),
                    'yyyy-MM-dd HH:mm:ss',
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeLocal,
                    [ref]$parsed) -and $parsed -gt $latest) {
                $latest = $parsed
            }
        }
    }
    if ($latest -eq [DateTime]::MinValue) { return $null }
    return $latest
}

function Get-CheapServicingState {
    $signals = New-Object 'System.Collections.Generic.List[string]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $cbsRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
    $wuRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'

    foreach ($entry in @(
            @{ Path = (Join-Path $cbsRoot 'RebootPending'); Name = 'CBS RebootPending' },
            @{ Path = (Join-Path $cbsRoot 'RebootInProgress'); Name = 'CBS RebootInProgress' },
            @{ Path = (Join-Path $cbsRoot 'PackagesPending'); Name = 'CBS PackagesPending' },
            @{ Path = (Join-Path $wuRoot 'RebootRequired'); Name = 'Windows Update RebootRequired' }
        )) {
        if (Test-RegistryKeyPresent -Path $entry.Path) {
            Add-Signal -Signals $signals -Text $entry.Name
        }
    }

    $sessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    foreach ($name in @(
            'PendingFileRenameOperations',
            'PendingFileRenameOperations2'
        )) {
        $pendingRenames = @(Get-NonEmptyRegistryMultiString `
                -Path $sessionManager -Name $name)
        if ($pendingRenames.Count -gt 0) {
            Add-Signal -Signals $warnings `
                -Text ("{0} ({1} non-empty entries)" -f `
                    $name, $pendingRenames.Count)
            foreach ($pendingRename in @($pendingRenames | Select-Object -First 4)) {
                $display = ([string]$pendingRename) -replace '[\r\n]+', ' '
                if ($display.Length -gt 180) {
                    $display = $display.Substring(0, 177) + '...'
                }
                Add-Signal -Signals $warnings `
                    -Text ("{0} entry: {1}" -f $name, $display)
            }
        }
    }

    try {
        $updates = Get-ItemProperty -LiteralPath `
            'HKLM:\SOFTWARE\Microsoft\Updates' -ErrorAction Stop
        $volatileProperty = $updates.PSObject.Properties['UpdateExeVolatile']
        if ($null -ne $volatileProperty -and
            [int64]$volatileProperty.Value -ne 0) {
            Add-Signal -Signals $signals -Text `
                ("UpdateExeVolatile={0}" -f [int64]$volatileProperty.Value)
        }
    } catch [System.Management.Automation.ItemNotFoundException] {
        # Missing legacy signal means it is not pending.
    }

    $wuInfo = $null
    try {
        $wuInfo = New-Object -ComObject Microsoft.Update.SystemInfo
        if ([bool]$wuInfo.RebootRequired) {
            Add-Signal -Signals $signals -Text 'Windows Update API RebootRequired'
        }
    } finally {
        if ($null -ne $wuInfo -and
            [Runtime.InteropServices.Marshal]::IsComObject($wuInfo)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($wuInfo)
        }
    }

    $wuInstaller = $null
    try {
        $wuInstaller = New-Object -ComObject Microsoft.Update.Installer
        if ([bool]$wuInstaller.IsBusy) {
            Add-Signal -Signals $signals -Text 'Windows Update installer is busy'
        }
    } finally {
        if ($null -ne $wuInstaller -and
            [Runtime.InteropServices.Marshal]::IsComObject($wuInstaller)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($wuInstaller)
        }
    }

    $panther = Join-Path $env:WINDIR 'System32\Sysprep\Panther'
    $latestReservedFailure = Get-LatestReservedStorageFailureTime -LogPaths @(
        (Join-Path $panther 'setuperr.log'),
        (Join-Path $panther 'setupact.log')
    )
    if ($null -ne $latestReservedFailure) {
        $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15
        $lastBoot = [DateTime]$os.LastBootUpTime
        if ($latestReservedFailure -ge $lastBoot.AddSeconds(-2)) {
            Add-Signal -Signals $signals -Text `
                '0x800F0975 was already logged during this boot; a normal restart is required'
        }
    }

    return [pscustomobject]@{
        Signals = @($signals.ToArray())
        Warnings = @($warnings.ToArray())
    }
}

function Get-DismServicingState {
    param([Parameter(Mandatory = $true)][int]$WindowsBuild)

    Import-Module Dism -ErrorAction Stop

    $pendingPackages = @(Get-WindowsPackage -Online -ErrorAction Stop |
        Where-Object {
            @('InstallPending', 'UninstallPending', 'PartiallyInstalled') `
                -contains [string]$_.PackageState
        })
    $signals = New-Object 'System.Collections.Generic.List[string]'
    foreach ($package in $pendingPackages) {
        Add-Signal -Signals $signals -Text `
            ("DISM package {0}: {1}" -f `
                [string]$package.PackageName,
                [string]$package.PackageState)
    }

    $pendingFeatures = @(Get-WindowsOptionalFeature -Online `
        -ErrorAction Stop | Where-Object {
            @('EnablePending', 'DisablePending') -contains [string]$_.State
        })
    foreach ($feature in $pendingFeatures) {
        Add-Signal -Signals $signals -Text `
            ("DISM feature {0}: {1}" -f `
                [string]$feature.FeatureName,
                [string]$feature.State)
    }

    $reservedStorageState = "NotQueryableOnBuild$WindowsBuild"
    if ($WindowsBuild -ge 19041) {
        $reserved = Get-WindowsReservedStorageState -ErrorAction Stop
        $stateProperty = $reserved.PSObject.Properties['ReservedStorageState']
        if ($null -eq $stateProperty) {
            throw 'DISM did not return ReservedStorageState.'
        }
        $reservedStorageState = [string]$stateProperty.Value
    }
    return [pscustomobject]@{
        Signals = @($signals.ToArray())
        ReservedStorageState = $reservedStorageState
    }
}

function Write-NextAction {
    Write-Host 'Install every Windows update and choose Restart.' `
        -ForegroundColor Yellow
    Write-Host 'Repeat Check for updates + Restart until nothing is pending, then rerun Seal.' `
        -ForegroundColor Yellow
    Write-Host 'Do not delete pending registry values, edit ReserveManager, or disable Reserved Storage.' `
        -ForegroundColor Yellow
    Write-Host 'If the same pending-file-rename signal remains after Restart, stop and identify its owning installer; do not delete the whole value.' `
        -ForegroundColor Yellow
}

if ($MyInvocation.InvocationName -eq '.') { return }

try {
    if (-not (Test-Administrator)) {
        throw 'Run Seal-G11-Template.cmd as administrator.'
    }
    if (-not [Environment]::Is64BitOperatingSystem -or
        -not [Environment]::Is64BitProcess) {
        throw 'The servicing gate requires 64-bit Windows PowerShell.'
    }
    $operatingSystem = Get-CimInstance Win32_OperatingSystem `
        -OperationTimeoutSec 15
    $windowsBuild = [int]$operatingSystem.BuildNumber

    $firstState = Get-CheapServicingState
    $firstSignals = @($firstState.Signals)
    foreach ($warning in @($firstState.Warnings)) {
        Write-Host "[WARN] $warning" -ForegroundColor Yellow
    }
    if (@($firstState.Warnings).Count -gt 0) {
        Write-Host '[WARN] Pending file renames are not a Sysprep blocker by themselves. Restart normally; if unchanged, identify the owning installer and do not delete the registry value.' `
            -ForegroundColor Yellow
    }
    if ($firstSignals.Count -gt 0) {
        Write-Host '[BLOCK] Windows Update or component servicing is incomplete; Sysprep was not started.' `
            -ForegroundColor Red
        foreach ($signal in $firstSignals) {
            Write-Host "  - $signal" -ForegroundColor Red
        }
        Write-NextAction
        exit 20
    }

    $dismState = Get-DismServicingState -WindowsBuild $windowsBuild
    Write-Host ("[INFO] ReservedStorageState={0}; Enabled is capability state, not proof that it is in use." -f `
            $dismState.ReservedStorageState) -ForegroundColor Gray
    if ($windowsBuild -lt 19041) {
        Write-Host '[INFO] This Windows build predates the public Reserved Storage Get cmdlet; the other read-only servicing checks still apply.' `
            -ForegroundColor Gray
    }
    if (@($dismState.Signals).Count -gt 0) {
        Write-Host '[BLOCK] DISM reports pending component servicing; Sysprep was not started.' `
            -ForegroundColor Red
        foreach ($signal in @($dismState.Signals)) {
            Write-Host "  - $signal" -ForegroundColor Red
        }
        Write-NextAction
        exit 20
    }

    $secondState = Get-CheapServicingState
    $secondSignals = @($secondState.Signals)
    foreach ($warning in @($secondState.Warnings | Where-Object {
                @($firstState.Warnings) -notcontains $_
            })) {
        Write-Host "[WARN] New observation during gate: $warning" `
            -ForegroundColor Yellow
    }
    if ($secondSignals.Count -gt 0) {
        Write-Host '[BLOCK] Servicing state changed during the read-only gate; Sysprep was not started.' `
            -ForegroundColor Red
        foreach ($signal in $secondSignals) {
            Write-Host "  - $signal" -ForegroundColor Red
        }
        Write-NextAction
        exit 20
    }

    Write-Host '[PASS] No known update or component-servicing blocker was observed.' `
        -ForegroundColor Green
    Write-Host '[INFO] This does not guarantee that Reserved Storage is idle; Sysprep validation remains authoritative.' `
        -ForegroundColor Gray
    Write-Host 'No Windows Update, Reserved Storage, Sysprep, BCD, or driver setting was changed.' `
        -ForegroundColor Gray
    exit 0
} catch {
    Write-Host '[UNKNOWN] Servicing state could not be verified reliably; Sysprep was not started.' `
        -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-NextAction
    Write-Host 'If this UNKNOWN query error repeats after one normal update/restart cycle, save the exact error and report it instead of retrying in a loop.' `
        -ForegroundColor Yellow
    exit 21
}

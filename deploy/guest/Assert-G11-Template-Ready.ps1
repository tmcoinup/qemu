#requires -Version 5.1
<#
.SYNOPSIS
  Read-only safety gate before a G-11 Windows template is generalized.

.DESCRIPTION
  Confirms that the operator is running on Windows 10 as Administrator and
  that Microsoft Defender Tamper Protection was turned off through Windows
  Security.  It also refuses a clone that already contains a per-VM system
  NVAPI projection; that projection must never become template state.

  This script does not change Defender, BCD, driver-signing policy, drivers,
  registry ACLs, or any other Windows setting.
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

function Assert-PlainDirectoryIfPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item -isnot [IO.DirectoryInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context must be a regular, non-reparse directory: $Path"
    }
    return $true
}

try {
    if (-not (Test-Administrator)) {
        throw 'Right-click Seal-G11-Template.cmd and choose Run as administrator.'
    }

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $build = [int]$os.BuildNumber
    if ([int]$os.ProductType -ne 1 -or $build -lt 10240 -or
        $build -ge 22000) {
        throw "G-11 template sealing supports Windows 10 client only. Detected: $($os.Caption), build $build."
    }

    $defender = Get-MpComputerStatus -ErrorAction Stop
    $tamperProperty = $defender.PSObject.Properties['IsTamperProtected']
    if ($null -eq $tamperProperty) {
        throw 'Windows did not report IsTamperProtected. Open Windows Security and verify Tamper Protection manually before retrying.'
    }
    if ([bool]$tamperProperty.Value) {
        throw 'Tamper Protection is ON. Open Windows Security > Virus & threat protection > Manage settings, turn Tamper Protection OFF manually, then run Seal again.'
    }

    $projectionRoot = Join-Path $env:ProgramData 'G11\SystemNvapiProjection'
    if (Assert-PlainDirectoryIfPresent $projectionRoot `
            'Per-VM system NVAPI projection state') {
        throw 'This Windows instance already contains a per-VM system NVAPI projection. Do not seal it into a base. Use a clone that failed before the projection stage, or uninstall and verify that projection through its reviewed package and reboot first.'
    }

    Write-Host '[PASS] Windows 10 template readiness gate passed.' `
        -ForegroundColor Green
    Write-Host '[PASS] Tamper Protection is OFF; no per-VM system NVAPI projection is present.' `
        -ForegroundColor Green
    Write-Host 'No Defender, BCD, driver-signing, or kernel-driver setting was changed.' `
        -ForegroundColor Gray
    exit 0
} catch {
    Write-Host ''
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'The readiness gate is read-only. Nothing was changed.' `
        -ForegroundColor Yellow
    exit 1
}

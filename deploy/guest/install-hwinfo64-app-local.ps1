<#
.SYNOPSIS
  Experimentally stage the audited x64 NVAPI identity shim beside one
  explicitly selected, production-signed HWiNFO64.exe.

.DESCRIPTION
  This helper is deliberately separate from the portable GPU-Z installer.
  It never discovers HWiNFO automatically, never downloads a file, never
  launches HWiNFO, and never replaces a Windows NVAPI DLL.  It delegates only
  to the audited app-local branch of install-nvapi-shim.ps1.

  The app-local shim can affect only NVAPI calls that HWiNFO makes through the
  sibling nvapi64.dll.  HWiNFO can also use PCI/PnP data, its own kernel
  driver, expansion-ROM data, and private interfaces.  Therefore successful
  installation does not guarantee removal of HWiNFO's [FAKE], GRID, or TU104
  labels.

.EXAMPLE
  .\install-hwinfo64-app-local.ps1 `
    -ApplicationExe 'C:\Program Files\HWiNFO64\HWiNFO64.exe'

.EXAMPLE
  .\install-hwinfo64-app-local.ps1 `
    -ApplicationExe 'C:\Tools\HWiNFO64.exe' -Uninstall
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ApplicationExe,

    [string]$InstallerPath = '',
    [string]$X64ShimPath = '',
    [switch]$Uninstall
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# These hashes bind this small wrapper to the two source-tree artifacts whose
# app-local behavior was statically audited.  A rebuild or installer change
# must update both this file and its repository test before publication.
$ExpectedInstallerSha256 = '4894A6A75B3706FFFBD7E8E4E8BA03A61275937A7ACD7240A15CCC3CC4BEB816'
$ExpectedX64ShimSha256 = '534F3E5965F73FB5EF75690A37C5C3FA0361FE9A3CBBD1BAD35CF0AB9465A324'

function Resolve-RegularFile {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "$Label is missing: $LiteralPath"
    }
    $item = Get-Item -LiteralPath $LiteralPath
    if ($item.PSProvider.Name -cne 'FileSystem') {
        throw "$Label must use the file-system provider: $LiteralPath"
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label must not be a reparse point: $($item.FullName)"
    }
    $directory = $item.Directory
    while ($null -ne $directory) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label must not be below a reparse-point directory: $($item.FullName)"
        }
        $directory = $directory.Parent
    }
    return $item.FullName
}

function Get-PeMachine {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $bytes = [IO.File]::ReadAllBytes($LiteralPath)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or
        $bytes[1] -ne 0x5a) {
        throw "HWiNFO executable is not a valid PE image: $LiteralPath"
    }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($peOffset -lt 0x40 -or $peOffset + 6 -gt $bytes.Length -or
        $bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or
        $bytes[$peOffset + 2] -ne 0 -or $bytes[$peOffset + 3] -ne 0) {
        throw "HWiNFO executable has an invalid PE header: $LiteralPath"
    }
    return [int][BitConverter]::ToUInt16($bytes, $peOffset + 4)
}

function Assert-OfficialHWiNFO64 {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    if (-not [string]::Equals(
            [IO.Path]::GetFileName($LiteralPath),
            'HWiNFO64.exe',
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'ApplicationExe must explicitly identify HWiNFO64.exe.'
    }
    $machine = Get-PeMachine $LiteralPath
    if ($machine -ne 0x8664) {
        throw ('HWiNFO64.exe must be an x64 PE image; found machine 0x{0:X4}.' `
            -f $machine)
    }

    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($LiteralPath)
    $identityText = @(
        [string]$version.CompanyName,
        [string]$version.ProductName,
        [string]$version.FileDescription,
        [string]$version.OriginalFilename
    ) -join "`n"
    if ($identityText -notmatch '(?i)HWiNFO' -or
        $identityText -notmatch '(?i)REALiX') {
        throw 'ApplicationExe metadata does not identify official REALiX HWiNFO64.'
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $LiteralPath
    if ([string]$signature.Status -cne 'Valid' -or
        $null -eq $signature.SignerCertificate) {
        throw 'HWiNFO64.exe must have a currently valid Authenticode signature.'
    }
    $subject = [string]$signature.SignerCertificate.Subject
    $issuer = [string]$signature.SignerCertificate.Issuer
    if ($subject -ceq $issuer -or $subject -notmatch '(?i)REALiX') {
        throw 'HWiNFO64.exe must be signed by the official REALiX publisher, not a self-issued certificate.'
    }
}

function Assert-PinnedFileHash {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $actual = (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash
    if ($actual -cne $ExpectedSha256) {
        throw "$Label SHA256 mismatch: actual $actual, expected $ExpectedSha256"
    }
}

if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $InstallerPath = Join-Path $PSScriptRoot 'install-nvapi-shim.ps1'
}
if ([string]::IsNullOrWhiteSpace($X64ShimPath)) {
    $X64ShimPath = Join-Path $PSScriptRoot 'nvapi64.dll'
}

$application = Resolve-RegularFile $ApplicationExe 'ApplicationExe'
$installer = Resolve-RegularFile $InstallerPath 'App-local NVAPI installer'
Assert-OfficialHWiNFO64 $application
Assert-PinnedFileHash $installer $ExpectedInstallerSha256 'App-local NVAPI installer'

if ($Uninstall) {
    & $installer -ApplicationExe $application -Uninstall
    Write-Host 'Experimental HWiNFO64 app-local NVAPI pair removed.' -ForeColor Green
    return
}

$shim = Resolve-RegularFile $X64ShimPath 'x64 NVAPI shim'
Assert-PinnedFileHash $shim $ExpectedX64ShimSha256 'x64 NVAPI shim'

# Supplying both ApplicationExe and a local X64Path makes the delegated
# installer select its x64 app-local branch and prevents its compatibility
# download path from being used.
& $installer `
    -ApplicationExe $application `
    -X64Path $shim `
    -ExpectedX64Sha256 $ExpectedX64ShimSha256

Write-Host 'Experimental HWiNFO64 x64 app-local NVAPI pair installed.' -ForeColor Green
Write-Warning (
    'This proves only safe app-local staging. It does not prove that HWiNFO ' +
    'loaded this DLL or that [FAKE], GRID, Quadro, or TU104 will disappear. ' +
    'Close and restart HWiNFO, then validate its rendered output.'
)

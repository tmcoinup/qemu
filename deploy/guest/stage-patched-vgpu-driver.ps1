<#
.SYNOPSIS
  Validate, catalog-sign, and pre-stage the audited NVIDIA 538.33 GTX 1050
  vGPU package without touching the currently active display device.

.DESCRIPTION
  The host builder leaves the original NVIDIA catalog in the artifact only as
  provenance.  Because nvgridsw.inf was changed, this script verifies every
  other payload byte, rebuilds nvgridsw.cat outside the cataloged tree, signs
  it with a clearly named VM-local test certificate, and runs pnputil add-only.

  This script deliberately supports one audited tuple.  Add future profiles
  together with new locked hashes and tests instead of accepting arbitrary INF
  edits from command-line parameters.
#>

[CmdletBinding()]
param(
    [string]$ArtifactRoot = 'C:\nv\538.33-gtx1050_2gb-patched'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Expected = [ordered]@{
    ManifestSchema  = 1
    Artifact        = 'nvidia-vgpu-538.33-consumer-id-patch'
    ProfileKey      = 'gtx1050_2gb'
    Name            = 'NVIDIA GeForce GTX 1050'
    PciId           = '10DE:1C81'
    SubsystemId     = '1028:11C0'
    SourceZipSha256 = 'a3d7ad8b8082d6ac6214565b4766b5190a819bc9b7574765b14897e0db809690'
    SourceInfSha256 = '67a240e1d464cf97dabfec1a7cecf000eaa9ddfd702f32ba2c8771f17905dc2b'
    PatchedInfSha256 = 'c7e38910c800fc9f5e72ec4d3613594a64b3e7b0465114e81a167ead43d42e4f'
    ManifestSha256 = '084f162bc01527da46f98525ab0e85eec0b3c3086b39f3b18949ec4985f4e72d'
    NvlddmkmSha256 = '67828f58171181da3b12a7b481e1251ed8255a34de78d7118fa9ac3781663c15'
    DriverVer       = '01/25/2024, 31.0.15.3833'
    CatalogRelative = 'Display.Driver/nvgridsw.cat'
    SignerSubject   = 'CN=QEMU vGPU Guest Driver Signing'
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    if (-not $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated Administrator PowerShell session.'
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)]$ExpectedValue,
        [Parameter(Mandatory)][string]$Label
    )
    if ($Actual -ne $ExpectedValue) {
        throw "$Label mismatch: expected '$ExpectedValue', got '$Actual'"
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-InfSectionLines {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Section
    )
    $header = "[$Section]"
    $indexes = @()
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -ceq $header) {
            $indexes += $index
        }
    }
    if ($indexes.Count -ne 1) {
        throw "Expected exactly one INF section $header; found $($indexes.Count)"
    }
    $start = $indexes[0] + 1
    $end = $Lines.Count
    for ($index = $start; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\[.+\]$') {
            $end = $index
            break
        }
    }
    if ($end -le $start) {
        return @()
    }
    return @($Lines[$start..($end - 1)])
}

function Assert-CodeSigningCertificate {
    param(
        [Parameter(Mandatory)]$Certificate,
        [switch]$RequirePrivateKey
    )
    Assert-Equal $Certificate.Subject $Expected.SignerSubject 'signer subject'
    if ($Certificate.NotAfter -le (Get-Date).AddDays(30)) {
        throw "Signer certificate is expired or too close to expiry: $($Certificate.NotAfter)"
    }
    if ($RequirePrivateKey -and -not $Certificate.HasPrivateKey) {
        throw 'Signer certificate does not have its private key.'
    }
    $codeSigningEku = @($Certificate.EnhancedKeyUsageList | Where-Object {
            [string]$_.ObjectId -eq '1.3.6.1.5.5.7.3.3'
        })
    if ($codeSigningEku.Count -ne 1) {
        throw 'Signer certificate does not have exactly one Code Signing EKU.'
    }
}

function Assert-Catalog {
    param(
        [Parameter(Mandatory)][string]$DriverRoot,
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][string]$Thumbprint
    )
    $catalogResult = Test-FileCatalog -Path $DriverRoot `
        -CatalogFilePath $CatalogPath -Detailed
    if ([string]$catalogResult.Status -ne 'Valid') {
        throw "Catalog payload validation failed: $($catalogResult.Status)"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $CatalogPath
    Assert-Equal ([string]$signature.Status) 'Valid' 'catalog signature status'
    if ($null -eq $signature.SignerCertificate) {
        throw 'Signed catalog has no signer certificate.'
    }
    Assert-Equal $signature.SignerCertificate.Thumbprint $Thumbprint `
        'catalog signer thumbprint'
}

Assert-Administrator
if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "Windows PowerShell 5.1 or newer is required; got $($PSVersionTable.PSVersion)"
}
$secureBootEnabled = Get-ItemPropertyValue `
    'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' `
    -Name UEFISecureBootEnabled -ErrorAction SilentlyContinue
if ($null -ne $secureBootEnabled -and [int]$secureBootEnabled -eq 1) {
    throw 'Secure Boot is enabled; refuse a VM-local test catalog.'
}
$deviceGuard = Get-CimInstance Win32_DeviceGuard `
    -Namespace 'root\Microsoft\Windows\DeviceGuard' `
    -ErrorAction SilentlyContinue
if ($null -ne $deviceGuard -and
        ([int]$deviceGuard.CodeIntegrityPolicyEnforcementStatus -eq 2 -or
         @($deviceGuard.SecurityServicesRunning) -contains 2)) {
    throw 'An enforced Code Integrity policy or HVCI is active; refuse test catalog staging.'
}
$ArtifactRoot = [IO.Path]::GetFullPath($ArtifactRoot.TrimEnd('\'))
$manifestPath = Join-Path $ArtifactRoot '.vgpu-patch-manifest.json'
$driverRoot = Join-Path $ArtifactRoot 'Display.Driver'
$infPath = Join-Path $driverRoot 'nvgridsw.inf'
$catalogPath = Join-Path $driverRoot 'nvgridsw.cat'
$stateRoot = Join-Path $env:ProgramData 'QEMU\vgpu-driver-stage'
$statePath = Join-Path $stateRoot '538.33-gtx1050_2gb.json'
$receiptPath = Join-Path $stateRoot '538.33-gtx1050_2gb.receipt'

Write-Host '[1/7] Validate locked host artifact' -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Missing artifact manifest: $manifestPath"
}
if (-not (Test-Path -LiteralPath $driverRoot -PathType Container)) {
    throw "Missing Display.Driver directory: $driverRoot"
}
Assert-Equal (Get-Sha256 $manifestPath) $Expected.ManifestSha256 `
    'locked manifest SHA256'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-Equal ([int]$manifest.schema) $Expected.ManifestSchema 'manifest schema'
Assert-Equal $manifest.artifact $Expected.Artifact 'artifact type'
Assert-Equal $manifest.source.sha256 $Expected.SourceZipSha256 'source ZIP SHA256'
Assert-Equal $manifest.source.inf_sha256 $Expected.SourceInfSha256 'source INF SHA256'
Assert-Equal $manifest.source.driver_ver $Expected.DriverVer 'manifest DriverVer'
Assert-Equal $manifest.profile.key $Expected.ProfileKey 'profile key'
Assert-Equal $manifest.profile.name $Expected.Name 'profile name'
Assert-Equal $manifest.profile.pci_id $Expected.PciId 'PCI identity'
Assert-Equal $manifest.profile.subsystem_id $Expected.SubsystemId 'subsystem identity'
Assert-Equal $manifest.patch.patched_inf_sha256 $Expected.PatchedInfSha256 `
    'patched INF SHA256'
Assert-Equal $manifest.catalog.path $Expected.CatalogRelative 'catalog path'
Assert-Equal $manifest.catalog.status 'vendor-catalog-invalid-after-inf-patch' `
    'catalog status'
Assert-Equal $manifest.catalog.required_action 'regenerate-and-sign-before-pnputil' `
    'catalog required action'

$inventory = @{}
foreach ($property in $manifest.files.PSObject.Properties) {
    $inventory[$property.Name] = $property.Value
}
if ($inventory.Count -lt 100) {
    throw "Manifest inventory is unexpectedly small: $($inventory.Count) files"
}
$actualPaths = @(Get-ChildItem -LiteralPath $ArtifactRoot -Recurse -File |
    ForEach-Object {
        $_.FullName.Substring($ArtifactRoot.Length + 1).Replace('\', '/')
    } | Where-Object { $_ -ne '.vgpu-patch-manifest.json' } | Sort-Object)
$expectedPaths = @($inventory.Keys | Sort-Object)
$inventoryDiff = @(Compare-Object -ReferenceObject $expectedPaths `
    -DifferenceObject $actualPaths)
if ($inventoryDiff.Count -ne 0) {
    throw "Artifact file inventory changed: $($inventoryDiff | Out-String)"
}
foreach ($relative in $expectedPaths) {
    if ($relative -eq $Expected.CatalogRelative) {
        continue
    }
    $filePath = Join-Path $ArtifactRoot $relative.Replace('/', '\')
    $record = $inventory[$relative]
    Assert-Equal (Get-Item -LiteralPath $filePath).Length ([Int64]$record.size) `
        "file size for $relative"
    Assert-Equal (Get-Sha256 $filePath) ([string]$record.sha256) `
        "file SHA256 for $relative"
}

Write-Host '[2/7] Validate exact GTX 1050 INF transformation' -ForegroundColor Cyan
Assert-Equal (Get-Sha256 $infPath) $Expected.PatchedInfSha256 'patched INF SHA256'
$kernelDriverPath = Join-Path $driverRoot 'nvlddmkm.sys'
Assert-Equal (Get-Sha256 $kernelDriverPath) $Expected.NvlddmkmSha256 `
    'nvlddmkm.sys SHA256'
$kernelSignature = Get-AuthenticodeSignature -LiteralPath $kernelDriverPath
Assert-Equal ([string]$kernelSignature.Status) 'Valid' `
    'embedded nvlddmkm.sys signature status'
if ($null -eq $kernelSignature.SignerCertificate -or
        $kernelSignature.SignerCertificate.Subject -notmatch '^CN=Microsoft Windows Hardware Compatibility Publisher,') {
    throw 'nvlddmkm.sys is not signed by the expected Microsoft hardware publisher.'
}
$infFiles = @(Get-ChildItem -LiteralPath $driverRoot -Recurse -File -Filter '*.inf')
if ($infFiles.Count -ne 1 -or $infFiles[0].FullName -ne $infPath) {
    throw 'Display.Driver must contain exactly one INF: nvgridsw.inf.'
}
$infText = Get-Content -LiteralPath $infPath -Raw -Encoding ASCII
if (-not $infText.EndsWith("`r`n") -or $infText -match '(?<!\r)\n|\r(?!\n)') {
    throw 'nvgridsw.inf is not the expected CRLF text.'
}
$lines = @($infText -split "`r`n")
$model14393 = '%NVIDIA_DEV.1C81.11C0.1028% = Section019, PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028'
$model17098 = '%NVIDIA_DEV.1C81.11C0.1028% = Section020, PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028'
$stringsLine = 'NVIDIA_DEV.1C81.11C0.1028 = "NVIDIA GeForce GTX 1050"'
$section14393 = @(Get-InfSectionLines $lines 'NVIDIA_Devices.NTamd64.10.0...14393')
$section17098 = @(Get-InfSectionLines $lines 'NVIDIA_Devices.NTamd64.10.0...17098')
$strings = @(Get-InfSectionLines $lines 'Strings')
Assert-Equal (@($section14393 | Where-Object { $_ -ceq $model14393 }).Count) 1 `
    '14393 GTX 1050 model row count'
Assert-Equal (@($section17098 | Where-Object { $_ -ceq $model17098 }).Count) 1 `
    '17098 GTX 1050 model row count'
Assert-Equal (@($strings | Where-Object { $_ -ceq $stringsLine }).Count) 1 `
    'GTX 1050 Strings row count'
$targetLines = @($lines | Where-Object {
        $_ -match 'DEV_1C81|NVIDIA_DEV\.1C81|SUBSYS_11C01028'
    })
if ($targetLines.Count -ne 3 -or
        @($targetLines | Where-Object {
                $_ -cne $model14393 -and $_ -cne $model17098 -and
                $_ -cne $stringsLine
            }).Count -ne 0) {
    throw 'nvgridsw.inf contains an unexpected or relaxed GTX 1050 target row.'
}
Assert-Equal (@($lines | Where-Object {
            $_ -ceq 'CatalogFile = nvgridsw.CAT'
        }).Count) 1 'CatalogFile row count'
Assert-Equal (@($lines | Where-Object {
            $_ -match '^DriverVer\s*=\s*01/25/2024, 31\.0\.15\.3833$'
        }).Count) 1 'DriverVer row count'

Write-Host '[3/7] Create or recover the VM-local signing identity' -ForegroundColor Cyan
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$state = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 |
            ConvertFrom-Json
    } catch {
        throw "Cannot read prior stage state: $statePath"
    }
}
$cert = $null
if ($null -ne $state -and $state.signer_thumbprint) {
    $candidatePath = "Cert:\LocalMachine\My\$($state.signer_thumbprint)"
    if (Test-Path -LiteralPath $candidatePath) {
        $candidate = Get-Item -LiteralPath $candidatePath
        # Early VM3-only builds used a machine-specific subject.  Do not trust
        # or delete that identity, and do not let it make the reusable package
        # fail: create the audited generic identity below instead.
        if ($candidate.Subject -eq $Expected.SignerSubject) {
            $cert = $candidate
            Assert-CodeSigningCertificate $cert -RequirePrivateKey
        }
    }
}
if ($null -eq $cert) {
    $cert = New-SelfSignedCertificate -Subject $Expected.SignerSubject `
        -Type CodeSigningCert -KeyUsage DigitalSignature `
        -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
        -KeyExportPolicy NonExportable `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -NotAfter (Get-Date).AddYears(5)
    Assert-CodeSigningCertificate $cert -RequirePrivateKey
}
$certificatePath = Join-Path $stateRoot "$($cert.Thumbprint).cer"
Export-Certificate -Cert $cert -FilePath $certificatePath -Force | Out-Null
foreach ($store in @('Root', 'TrustedPublisher')) {
    $trustedPath = "Cert:\LocalMachine\$store\$($cert.Thumbprint)"
    if (-not (Test-Path -LiteralPath $trustedPath)) {
        Import-Certificate -FilePath $certificatePath `
            -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
    }
    $trusted = Get-Item -LiteralPath $trustedPath
    Assert-CodeSigningCertificate $trusted
}

Write-Host '[4/7] Rebuild and sign catalog outside Display.Driver' -ForegroundColor Cyan
$vendorCatalogHash = [string]$inventory[$Expected.CatalogRelative].sha256
$currentCatalogHash = if (Test-Path -LiteralPath $catalogPath -PathType Leaf) {
    Get-Sha256 $catalogPath
} else {
    ''
}
$alreadySigned = $false
if ($currentCatalogHash -ne $vendorCatalogHash) {
    if ($null -eq $state -or
            $state.patched_inf_sha256 -ne $Expected.PatchedInfSha256 -or
            $state.catalog_sha256 -ne $currentCatalogHash -or
            $state.signer_thumbprint -ne $cert.Thumbprint) {
        throw 'Catalog differs from the vendor artifact without valid prior stage state.'
    }
    Assert-Catalog $driverRoot $catalogPath $cert.Thumbprint
    $alreadySigned = $true
}
if (-not $alreadySigned) {
    $catalogWorkRoot = Join-Path $stateRoot ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $catalogWorkRoot -Force | Out-Null
    $catalogTemporary = Join-Path $catalogWorkRoot 'nvgridsw.cat'
    $catalogBackup = Join-Path $catalogWorkRoot 'nvgridsw.vendor.cat'
    Copy-Item -LiteralPath $catalogPath -Destination $catalogBackup
    try {
        Remove-Item -LiteralPath $catalogPath -Force
        $remainingCatalogs = @(Get-ChildItem -LiteralPath $driverRoot `
            -Recurse -File -Filter '*.cat')
        if ($remainingCatalogs.Count -ne 0) {
            throw 'Display.Driver still contains a catalog before regeneration.'
        }
        New-FileCatalog -Path $driverRoot -CatalogFilePath $catalogTemporary `
            -CatalogVersion 2.0 | Out-Null
        $unsignedResult = Test-FileCatalog -Path $driverRoot `
            -CatalogFilePath $catalogTemporary -Detailed
        Assert-Equal ([string]$unsignedResult.Status) 'Valid' `
            'unsigned catalog payload status'
        $signature = Set-AuthenticodeSignature -LiteralPath $catalogTemporary `
            -Certificate $cert -HashAlgorithm SHA256
        Assert-Equal ([string]$signature.Status) 'Valid' `
            'new catalog signature status'
        Assert-Equal $signature.SignerCertificate.Thumbprint $cert.Thumbprint `
            'new catalog signer thumbprint'
        Move-Item -LiteralPath $catalogTemporary -Destination $catalogPath
        Assert-Catalog $driverRoot $catalogPath $cert.Thumbprint
    } catch {
        if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
            Copy-Item -LiteralPath $catalogBackup -Destination $catalogPath -Force
        }
        throw
    } finally {
        Remove-Item -LiteralPath $catalogWorkRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}

$stateRecord = [ordered]@{
    schema              = 1
    profile             = $Expected.ProfileKey
    driver_ver          = $Expected.DriverVer
    patched_inf_sha256  = $Expected.PatchedInfSha256
    catalog_sha256      = Get-Sha256 $catalogPath
    signer_thumbprint   = $cert.Thumbprint
    staged_at_utc       = [DateTime]::UtcNow.ToString('o')
}
$stateTemporary = "$statePath.tmp"
$stateRecord | ConvertTo-Json | Set-Content -LiteralPath $stateTemporary `
    -Encoding UTF8
Move-Item -LiteralPath $stateTemporary -Destination $statePath -Force

Write-Host '[5/7] Pre-stage only; do not switch the active display device' `
    -ForegroundColor Cyan
$activeDisplayBefore = @(Get-CimInstance Win32_VideoController |
    Where-Object { [int]$_.ConfigManagerErrorCode -eq 0 } |
    Select-Object Name, PNPDeviceID, DriverVersion, ConfigManagerErrorCode,
        CurrentHorizontalResolution, CurrentVerticalResolution |
    Sort-Object PNPDeviceID | ConvertTo-Json -Compress)
$pnputilOutput = & pnputil.exe /add-driver $infPath 2>&1
$pnputilExit = $LASTEXITCODE
$pnputilOutput | ForEach-Object { Write-Host "  $_" }
if ($pnputilExit -ne 0 -and $pnputilExit -ne 3010) {
    throw "pnputil add-only failed with exit code $pnputilExit"
}

Write-Host '[6/7] Verify the published OEM INF' -ForegroundColor Cyan
$published = @(Get-ChildItem -LiteralPath "$env:windir\INF" -File `
        -Filter 'oem*.inf' | Where-Object {
        $candidate = Get-Content -LiteralPath $_.FullName -Raw -Encoding ASCII
        $candidate -match 'DriverVer\s*=\s*01/25/2024, 31\.0\.15\.3833' -and
        $candidate -match [regex]::Escape($model14393) -and
        $candidate -match [regex]::Escape($model17098) -and
        $candidate -match [regex]::Escape($stringsLine)
    })
if ($published.Count -ne 1) {
    throw "Expected exactly one published GTX 1050 package; found $($published.Count)."
}
Assert-Equal (Get-Sha256 $published[0].FullName) $Expected.PatchedInfSha256 `
    'published OEM INF SHA256'
$windowsDrivers = @(Get-WindowsDriver -Online -All | Where-Object {
        $_.Driver -eq $published[0].Name
    })
if ($windowsDrivers.Count -ne 1) {
    throw "Expected one DISM record for $($published[0].Name); found $($windowsDrivers.Count)."
}
$windowsDriver = $windowsDrivers[0]
Assert-Equal (Split-Path -Leaf $windowsDriver.OriginalFileName) 'nvgridsw.inf' `
    'published original INF name'
Assert-Equal $windowsDriver.ProviderName 'NVIDIA' 'published driver provider'
Assert-Equal $windowsDriver.ClassName 'Display' 'published driver class'
Assert-Equal ([string]$windowsDriver.Version) '31.0.15.3833' `
    'published driver version'
$activeDisplayAfter = @(Get-CimInstance Win32_VideoController |
    Where-Object { [int]$_.ConfigManagerErrorCode -eq 0 } |
    Select-Object Name, PNPDeviceID, DriverVersion, ConfigManagerErrorCode,
        CurrentHorizontalResolution, CurrentVerticalResolution |
    Sort-Object PNPDeviceID | ConvertTo-Json -Compress)
Assert-Equal ($activeDisplayAfter -join "`n") ($activeDisplayBefore -join "`n") `
    'active display state after add-only staging'
$stateRecord.published_inf = $published[0].Name
$stateRecord | ConvertTo-Json | Set-Content -LiteralPath $stateTemporary `
    -Encoding UTF8
Move-Item -LiteralPath $stateTemporary -Destination $statePath -Force

# The one-click EXE consumes this deliberately simple, exact receipt.  JSON is
# retained for diagnostics, while the receipt is easy to validate without a
# permissive parser and carries the per-Windows oemN.inf allocation.
$receiptTemporary = "$receiptPath.tmp"
@(
    'QEMU_VGPU_DRIVER_STAGE_V1'
    "PROFILE=$($Expected.ProfileKey)"
    "PCI_ID=$($Expected.PciId)"
    "SUBSYSTEM_ID=$($Expected.SubsystemId)"
    "DRIVER_VERSION=31.0.15.3833"
    "DRIVER_INF=$($published[0].Name)"
    "PATCHED_INF_SHA256=$($Expected.PatchedInfSha256)"
) | Set-Content -LiteralPath $receiptTemporary -Encoding ASCII
Move-Item -LiteralPath $receiptTemporary -Destination $receiptPath -Force

Write-Host '[7/7] Stage complete' -ForegroundColor Green
Write-Host "  profile:       $($Expected.ProfileKey) / $($Expected.Name)"
Write-Host "  PCI tuple:     $($Expected.PciId) / subsystem $($Expected.SubsystemId)"
Write-Host "  DriverVer:     $($Expected.DriverVer)"
Write-Host "  signer:        $($cert.Thumbprint) ($($Expected.SignerSubject))"
Write-Host "  published INF: $($published.Name -join ', ')"
Write-Host "  receipt:       $receiptPath"
Write-Host '  active device was not rebound; shut down before enabling PCI spoof mode.'

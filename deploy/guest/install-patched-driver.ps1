<#
.SYNOPSIS
  End-to-end: disable testsigning, install self-signed cert, regenerate
  .cat for the patched NVIDIA INF (now with DEV_1D01 -> "NVIDIA GeForce GT 1030"),
  sign the cat, install via pnputil, trigger PCI re-bind.

.NOTES
  Windows 10/11 ships New-FileCatalog + Set-AuthenticodeSignature, so this
  does not need Windows SDK / WDK.
#>

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

$root = 'C:\nv\538.33-patched'
$zipUrl = 'http://192.168.30.127:8080/Display.Driver.zip'

Write-Host '[1/9] Disable testsigning + nointegritychecks (driver will be properly signed)' -Fore Cyan
bcdedit /set testsigning off | Out-Null
bcdedit /set nointegritychecks off | Out-Null

Write-Host '[2/9] Download patched driver zip (with DEV_1D01 entry in INF)' -Fore Cyan
Remove-Item $root -Recurse -Force -EA 0
New-Item -Type Directory -Force $root | Out-Null
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest $zipUrl -OutFile "$root\..\Display.Driver.zip" -UseBasicParsing
Expand-Archive "$root\..\Display.Driver.zip" $root -Force
Write-Host "  files: $((Get-ChildItem $root -Recurse -File).Count)"

Write-Host '[3/9] Self-sign code signing certificate' -Fore Cyan
$existing = Get-ChildItem 'Cert:\LocalMachine\My' | Where-Object { $_.Subject -eq 'CN=NVIDIA Corporation' } | Select-Object -First 1
if ($existing) {
    Write-Host "  reusing existing cert thumbprint=$($existing.Thumbprint)"
    $cert = $existing
} else {
    $cert = New-SelfSignedCertificate -Subject 'CN=NVIDIA Corporation' `
        -Type CodeSigning -KeyUsage DigitalSignature `
        -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -NotAfter (Get-Date).AddYears(10)
    Write-Host "  new cert thumbprint=$($cert.Thumbprint)"
}

Write-Host '[4/9] Trust that cert (Root + TrustedPublisher)' -Fore Cyan
$cerPath = 'C:\nv\vgpu-patch.cer'
Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null
foreach ($store in @('Root','TrustedPublisher')) {
    Import-Certificate -FilePath $cerPath -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
    Write-Host "  imported into LocalMachine\$store"
}

Write-Host '[5/9] Delete old NVIDIA catalog, regenerate with current patched INF + files' -Fore Cyan
Remove-Item "$root\nvgridsw.cat" -Force -EA 0
New-FileCatalog -Path $root -CatalogFilePath "$root\nvgridsw.cat" -CatalogVersion 2.0 | Out-Null
Write-Host "  new cat size: $((Get-Item "$root\nvgridsw.cat").Length)"

Write-Host '[6/9] Sign the catalog' -Fore Cyan
$sig = Set-AuthenticodeSignature -FilePath "$root\nvgridsw.cat" -Certificate $cert `
    -HashAlgorithm SHA256
Write-Host "  sign status: $($sig.Status)   sig: $($sig.SignerCertificate.Subject)"
if ($sig.Status -ne 'Valid') { throw "catalog signing failed: $($sig.Status) - $($sig.StatusMessage)" }

Write-Host '[7/9] Uninstall any existing NVIDIA oem INF to avoid conflict' -Fore Cyan
$drvs = pnputil /enum-drivers
$lastOem = ''
foreach ($line in $drvs -split "`r`n") {
    if ($line -match '(oem\d+\.inf)') { $lastOem = $Matches[1] }
    if ($line -match 'nvgridsw\.inf' -and $lastOem) {
        Write-Host "  remove $lastOem"
        pnputil /delete-driver $lastOem /uninstall /force | Out-Null
    }
}

Write-Host '[8/9] Install patched + freshly-signed INF' -Fore Cyan
pnputil /add-driver "$root\nvgridsw.inf" /install 2>&1 | ForEach-Object { "  $_" }

Write-Host '[9/9] Verify' -Fore Cyan
bcdedit /enum '{current}' | Select-String 'testsigning|integritychecks'
pnputil /enum-drivers | Select-String NVIDIA -Context 0,4 | Select-Object -First 6
Get-PnpDevice | Where-Object { $_.InstanceId -like 'PCI\VEN_10DE*' } |
    Format-Table Status, FriendlyName, InstanceId -AutoSize

Write-Host ''
Write-Host 'Driver install with self-signed catalog done.' -Fore Green
Write-Host 'Reboot required to clear testsigning watermark and re-bind PnP cleanly.' -Fore Yellow
Write-Host 'shutdown /r /t 5 to reboot now.' -Fore Yellow

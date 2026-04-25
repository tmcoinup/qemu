# sign-cert.ps1 -- create (or reuse) a self-signed code-signing certificate
# for CihSigner and export it as PFX + CER so signtool and certutil can
# use it.  Idempotent: if a cert with the given Subject already exists in
# CurrentUser\My, we reuse it instead of making a new one.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Subject,
    [Parameter(Mandatory)] [string] $PfxPath,
    [Parameter(Mandatory)] [string] $CerPath,
    [Parameter(Mandatory)] [string] $Password
)

$ErrorActionPreference = 'Stop'

if ((Test-Path $PfxPath) -and (Test-Path $CerPath)) {
    Write-Host "[sign-cert] reusing existing $PfxPath / $CerPath"
    exit 0
}

$store  = 'Cert:\CurrentUser\My'
$cert   = Get-ChildItem $store |
          Where-Object { $_.Subject -eq $Subject -and $_.HasPrivateKey } |
          Select-Object -First 1

if ($cert -and ($cert.NotBefore -gt (Get-Date))) {
    Write-Host "[sign-cert] existing cert NotBefore=$($cert.NotBefore) is in the future, removing"
    Remove-Item -Force "Cert:\CurrentUser\My\$($cert.Thumbprint)"
    $cert = $null
}

if (-not $cert) {
    Write-Host "[sign-cert] creating new self-signed cert $Subject"
    $cert = New-SelfSignedCertificate `
        -Type                 CodeSigningCert `
        -Subject              $Subject `
        -KeyUsage             DigitalSignature `
        -KeyAlgorithm         RSA `
        -KeyLength            2048 `
        -HashAlgorithm        SHA256 `
        -NotBefore            ((Get-Date).AddDays(-1)) `
        -NotAfter             ((Get-Date).AddYears(10)) `
        -CertStoreLocation    $store
}

$secpwd = ConvertTo-SecureString -String $Password -Force -AsPlainText
Export-PfxCertificate        -Cert $cert -FilePath $PfxPath -Password $secpwd | Out-Null
Export-Certificate           -Cert $cert -FilePath $CerPath -Type CERT        | Out-Null

Write-Host ("[sign-cert] exported {0} / {1}" -f $PfxPath, $CerPath)

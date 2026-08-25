#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\VMateLab\host-esp-audit.json',
    [ValidatePattern('^[A-Z]:$')][string]$Drive = 'W:'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$driveName = $Drive.TrimEnd(':')
if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
    throw "$Drive is already assigned; refusing to alter it."
}

$mounted = $false
try {
    & mountvol.exe $Drive /S | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "mountvol /S failed with exit code $LASTEXITCODE."
    }
    $mounted = $true
    $efiRoot = "$Drive\EFI"
    if (-not (Test-Path -LiteralPath $efiRoot -PathType Container)) {
        throw "$efiRoot was not found after mounting the system ESP."
    }

    $records = foreach ($item in @(Get-ChildItem -LiteralPath $efiRoot `
                -Recurse -Force -File -ErrorAction Stop | Where-Object {
                    $_.Extension -ieq '.efi' -or
                    $_.Name -match '(?i)bootmgfw|voyager|vmspoofer'
                })) {
        $signature = Get-AuthenticodeSignature -LiteralPath $item.FullName
        [pscustomobject][ordered]@{
            RelativePath = $item.FullName.Substring($Drive.Length).TrimStart('\')
            Length = [uint64]$item.Length
            LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
            Sha256 = (Get-FileHash -LiteralPath $item.FullName `
                -Algorithm SHA256).Hash
            SignatureStatus = [string]$signature.Status
            Signer = if ($null -eq $signature.SignerCertificate) { '' } else {
                [string]$signature.SignerCertificate.Subject
            }
        }
    }

    $document = [pscustomobject][ordered]@{
        SchemaVersion = 1
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        EfiFiles = @($records | Sort-Object RelativePath)
    }
    $json = $document | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText(
        $OutputPath,
        $json,
        (New-Object Text.UTF8Encoding($false))
    )
    [pscustomobject]@{
        OutputPath = $OutputPath
        EfiFileCount = @($records).Count
        UnsignedCount = @($records | Where-Object {
                $_.SignatureStatus -ne 'Valid'
            }).Count
    }
}
finally {
    if ($mounted) {
        & mountvol.exe $Drive /D | Out-Null
    }
}

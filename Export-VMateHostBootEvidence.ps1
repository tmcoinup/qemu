#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]:$')][string]$Drive = 'W:',
    [string]$OutputRoot = 'C:\VMateLab\host-boot-evidence'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
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
    $bootRoot = "$Drive\EFI\Microsoft\Boot"
    $sources = @(
        [pscustomobject]@{
            Name = 'bootmgfw-current.efi'
            Path = Join-Path $bootRoot 'bootmgfw.efi'
        },
        [pscustomobject]@{
            Name = 'bootmgfw-microsoft-backup.efi'
            Path = Join-Path $bootRoot 'bootmgfw.efi.backup'
        }
    )
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $records = foreach ($source in $sources) {
        if (-not (Test-Path -LiteralPath $source.Path -PathType Leaf)) {
            throw "required boot evidence is missing: $($source.Path)"
        }
        $destination = Join-Path $OutputRoot $source.Name
        [IO.File]::Copy($source.Path, $destination, $true)
        $item = Get-Item -LiteralPath $destination -Force
        $signature = Get-AuthenticodeSignature -LiteralPath $destination
        [pscustomobject][ordered]@{
            Name = $source.Name
            Path = $destination
            Length = [uint64]$item.Length
            Sha256 = (Get-FileHash -LiteralPath $destination `
                -Algorithm SHA256).Hash
            SignatureStatus = [string]$signature.Status
            Signer = if ($null -eq $signature.SignerCertificate) { '' } else {
                [string]$signature.SignerCertificate.Subject
            }
        }
    }
    [pscustomobject][ordered]@{
        OutputRoot = $OutputRoot
        Files = @($records)
    } | ConvertTo-Json -Depth 5 -Compress
}
finally {
    if ($mounted) {
        & mountvol.exe $Drive /D | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "mountvol /D failed with exit code $LASTEXITCODE."
        }
    }
}

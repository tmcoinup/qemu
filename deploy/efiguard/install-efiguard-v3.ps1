$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$stage  = 'C:\stealth\efiguard'
$loader = "$stage\Loader.efi"
$dxe    = "$stage\EfiGuardDxe.efi"
foreach ($f in @($loader,$dxe)) {
    if (-not (Test-Path $f)) { Write-Error "missing: $f"; exit 1 }
}

& mountvol S: /S | Out-Null

$msbootDir = 'S:\EFI\Microsoft\Boot'
$bootmgfw  = "$msbootDir\bootmgfw.efi"
$backup    = "$msbootDir\bootmgfw.efi.original"

Write-Host "before: bootmgfw.efi    = $((Get-Item $bootmgfw -EA 0).Length) bytes (exists=$(Test-Path $bootmgfw))"
Write-Host "before: bootmgfw.original = $((Get-Item $backup -EA 0).Length) bytes (exists=$(Test-Path $backup))"

# 1. Copy Loader -> bootmgfw.efi
Copy-Item -LiteralPath $loader -Destination $bootmgfw -Force
Write-Host "after copy: bootmgfw.efi = $((Get-Item $bootmgfw -EA 0).Length) bytes"

# 2. Copy DXE driver
Copy-Item -LiteralPath $dxe -Destination "$msbootDir\EfiGuardDxe.efi" -Force
Write-Host "after copy: EfiGuardDxe.efi = $((Get-Item ${msbootDir}\EfiGuardDxe.efi -EA 0).Length) bytes"

Write-Host ''
Write-Host '=== final relevant ESP files ==='
Get-ChildItem $msbootDir -Filter 'bootmgfw*'  | Format-Table Name,Length,LastWriteTime -AutoSize
Get-ChildItem $msbootDir -Filter 'EfiGuard*'  | Format-Table Name,Length,LastWriteTime -AutoSize

& mountvol S: /D | Out-Null

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$stage  = 'C:\stealth\efiguard'
$loader = Join-Path $stage 'Loader.efi'
$dxe    = Join-Path $stage 'EfiGuardDxe.efi'
foreach ($f in @($loader,$dxe)) {
    if (-not (Test-Path $f)) { throw "missing: $f" }
}

& mountvol S: /S | Out-Null
$msbootDir = 'S:\EFI\Microsoft\Boot'

$bootmgfw = "$msbootDir\bootmgfw.efi"
$backup   = "$msbootDir\bootmgfw.efi.original"

Write-Host "before: bootmgfw.efi exists = $(Test-Path $bootmgfw)"
Write-Host "before: backup    exists = $(Test-Path $backup)"

# Use cmd.exe copy /Y which is more reliable on FAT32 ESP than Copy-Item
& cmd /c "del /F /Q `"$bootmgfw`"" 2>&1 | Out-Null
Write-Host "after del: bootmgfw.efi exists = $(Test-Path $bootmgfw)"

& cmd /c "copy /Y /B `"$loader`" `"$bootmgfw`""
Write-Host "after copy loader->bootmgfw: bootmgfw.efi exists = $(Test-Path $bootmgfw); size = $((Get-Item $bootmgfw -EA 0).Length)"

& cmd /c "copy /Y /B `"$dxe`" `"$msbootDir\EfiGuardDxe.efi`""
Write-Host "after copy dxe: EfiGuardDxe.efi size = $((Get-Item ${msbootDir}\EfiGuardDxe.efi -EA 0).Length)"

Write-Host ''
Write-Host '=== final relevant ESP files ==='
Get-ChildItem $msbootDir -Filter 'bootmgfw*'  | Format-Table Name,Length,LastWriteTime -AutoSize
Get-ChildItem $msbootDir -Filter 'EfiGuard*'  | Format-Table Name,Length,LastWriteTime -AutoSize

& mountvol S: /D | Out-Null

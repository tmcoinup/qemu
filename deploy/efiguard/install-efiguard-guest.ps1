# install-efiguard-guest.ps1 — runs in guest as Administrator
#
# 1. Mount the EFI System Partition under a temp drive letter
# 2. Backup the original bootmgfw.efi
# 3. Replace bootmgfw.efi with EfiGuard Loader.efi (which loads EfiGuardDxe.efi)
# 4. Drop EfiGuardDxe.efi alongside it
#
# Reboot to pick up the patched boot path. EfiGuardDxe hooks the Windows boot
# loader to NOP DSE checks before kernel CI initializes.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$stage = 'C:\stealth\efiguard'
$loader = Join-Path $stage 'Loader.efi'
$dxe    = Join-Path $stage 'EfiGuardDxe.efi'

foreach ($f in @($loader,$dxe)) {
    if (-not (Test-Path $f)) { throw "missing: $f" }
}

# --- Mount ESP --------------------------------------------------------
$letter = 'S'
& mountvol "${letter}:" /S 2>&1 | Out-Null
if (-not (Test-Path "${letter}:\")) {
    throw "failed to mount EFI System Partition under ${letter}:"
}

$msbootDir = "${letter}:\EFI\Microsoft\Boot"
if (-not (Test-Path $msbootDir)) { throw "ESP layout unexpected: $msbootDir not found" }

$bootmgfw = Join-Path $msbootDir 'bootmgfw.efi'
$backup   = Join-Path $msbootDir 'bootmgfw.efi.original'

Write-Host "=== ESP layout BEFORE ==="
Get-ChildItem $msbootDir | Select-Object Name,Length | Format-Table -AutoSize

# --- Backup (only on first run) -------------------------------------
if (-not (Test-Path $backup)) {
    Copy-Item $bootmgfw $backup -Force
    Write-Host "backed up bootmgfw.efi -> bootmgfw.efi.original ($((Get-Item $backup).Length) bytes)"
} else {
    Write-Host "backup already exists at $backup ($((Get-Item $backup).Length) bytes); leaving as-is"
}

# --- Install ---------------------------------------------------------
Copy-Item $loader $bootmgfw -Force
Copy-Item $dxe    (Join-Path $msbootDir 'EfiGuardDxe.efi') -Force

Write-Host ""
Write-Host "=== ESP layout AFTER ==="
Get-ChildItem $msbootDir | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize

# --- Cleanup --------------------------------------------------------
& mountvol "${letter}:" /D 2>&1 | Out-Null

Write-Host ""
Write-Host "EfiGuard installed. Reboot to activate."
Write-Host "Recovery: if boot fails, mount ESP from a recovery env and:"
Write-Host "  copy bootmgfw.efi.original bootmgfw.efi"

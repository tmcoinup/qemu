# destealth-revert.ps1 — back out EfiGuard + patched viogpudo on a guest that
# already had install-stealth-guest.ps1 applied. Used when ACE/anti-cheat
# rejects the deeper stealth path. After this script the guest is in
# "shallow stealth": stock virtio-win driver bound to PCI VEN_1AF4&DEV_1050
# (subsys still spoofed to NVIDIA via QEMU cmdline). No more bootmgr swap,
# no more NVIDIA-fake CA chain in the kernel signature path.
#
# Run as Administrator from the guest:
#     irm http://192.168.30.33:8765/destealth-revert.ps1 | iex

$ErrorActionPreference = 'Continue'
Write-Host "=== destealth-revert ===" -ForegroundColor Cyan

# ----------------------------------------------------------------------
# 1) Restore the original Windows bootmgr (undo EfiGuard's Loader.efi swap)
# ----------------------------------------------------------------------
Write-Host "`n[1/6] restoring bootmgfw.efi" -ForegroundColor Yellow
mountvol S: /S 2>&1 | Out-Null
$boot = 'S:\EFI\Microsoft\Boot\bootmgfw.efi'
$orig = "$boot.original"
$gd   = "$boot.efiguard"
if (Test-Path $orig) {
    if (Test-Path $boot) { Move-Item $boot $gd -Force -ErrorAction Continue }
    Move-Item $orig $boot -Force -ErrorAction Continue
    Write-Host "  bootmgfw restored from .original"
} else {
    Write-Host "  no .original found; bootmgr probably already stock"
}
foreach ($f in @(
    'S:\EFI\Boot\EfiGuardDxe.efi',
    'S:\EFI\Microsoft\Boot\EfiGuardDxe.efi',
    "$boot.efiguard"
)) {
    if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}
mountvol S: /D 2>&1 | Out-Null

# ----------------------------------------------------------------------
# 2) Strip backdated NVIDIA-fake CA roots from Trusted Root / Intermediate
# ----------------------------------------------------------------------
Write-Host "`n[2/6] removing fake NVIDIA Code Signing Root from cert stores" -ForegroundColor Yellow
foreach ($store in @('Cert:\LocalMachine\Root','Cert:\LocalMachine\CA','Cert:\LocalMachine\TrustedPublisher')) {
    Get-ChildItem $store -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -match 'NVIDIA' -and $_.Subject -notmatch 'DigiCert|VeriSign' } |
        ForEach-Object {
            Write-Host "  $store removing: $($_.Subject)"
            Remove-Item -Path $_.PSPath -Force -ErrorAction SilentlyContinue
        }
}

# ----------------------------------------------------------------------
# 3) Uninstall the patched viogpudo-nvidia.inf (oem*.inf) from the driver
#    store. We force-delete because the device is currently bound to it.
# ----------------------------------------------------------------------
Write-Host "`n[3/6] removing patched viogpudo-nvidia.inf from driver store" -ForegroundColor Yellow
$oems = pnputil /enum-drivers 2>&1
$current = $null
$targets = @()
foreach ($line in $oems) {
    if ($line -match 'Published Name:\s*(oem\d+\.inf)') { $current = $matches[1] }
    elseif ($line -match 'Original Name:\s*(viogpudo-nvidia|viogpudo)\.inf' -and $current) { $targets += $current }
}
$targets = $targets | Sort-Object -Unique
foreach ($oem in $targets) {
    Write-Host "  pnputil /delete-driver $oem /uninstall /force"
    pnputil /delete-driver $oem /uninstall /force 2>&1 | Select-Object -Last 3
}

# Also drop the stale C:\Windows\System32\drivers\viogpudo.sys hardlink so
# next PnP install hardlinks fresh from the driver store
$drv = 'C:\Windows\System32\drivers\viogpudo.sys'
if (Test-Path $drv) {
    takeown /f $drv /a 2>&1 | Out-Null
    icacls $drv /grant Administrators:F 2>&1 | Out-Null
    Remove-Item $drv -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $drv)) { Write-Host "  removed stale $drv" }
}

# ----------------------------------------------------------------------
# 4) Stop / delete the kernel service so the patched binary is fully gone
# ----------------------------------------------------------------------
Write-Host "`n[4/6] removing VioGpuDod service" -ForegroundColor Yellow
sc.exe stop  VioGpuDod 2>&1 | Out-Null
sc.exe delete VioGpuDod 2>&1 | Out-Null
Write-Host "  service removed"

# ----------------------------------------------------------------------
# 5) Make sure DSE is enforced normally
# ----------------------------------------------------------------------
Write-Host "`n[5/6] BCD check" -ForegroundColor Yellow
bcdedit /deletevalue '{current}' nointegritychecks 2>&1 | Out-Null
bcdedit /set '{current}' testsigning No 2>&1 | Out-Null
bcdedit /enum '{current}' | Select-String -Pattern 'testsigning|nointegritychecks|path'

# ----------------------------------------------------------------------
# 6) Drop the C:\stealth payload (so a future ACE walk doesn't see the
#    dropper directory) but keep apply-gpu-spoof.ps1 / nvapi64.dll if you
#    still want those userland-only spoofs. Comment out if you want to
#    keep the bundle around for re-install.
# ----------------------------------------------------------------------
Write-Host "`n[6/6] cleaning C:\stealth\efiguard and signed-driver bundle" -ForegroundColor Yellow
foreach ($p in @(
    'C:\stealth\efiguard',
    'C:\stealth\nv-driver',
    'C:\stealth\driver-signing'
)) {
    if (Test-Path $p) {
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  removed $p"
    }
}

Write-Host "`n=== done ===" -ForegroundColor Green
Write-Host "Next:" -ForegroundColor Yellow
Write-Host "  1. shutdown /s /t 5 /f"
Write-Host "  2. on host, relaunch with GPU_SELFSIGNED=0 (the script will say so)"
Write-Host ""
Write-Host "Run now (will reboot in 5 s)?  Enter to confirm, Ctrl-C to skip"
$null = Read-Host
shutdown /s /t 5 /f

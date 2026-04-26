# install-stealth-guest.ps1 — runs INSIDE Win10 guest as Administrator.
#
# One-shot installer for:
#   1. backdated CA chain into LocalMachine\Root + TrustedPublisher
#   2. viogpudo-nvidia driver package (pnputil /add-driver, no /install)
#   3. nvapi64.dll shim into System32
#   4. registry GPU rename (apply-gpu-spoof.ps1)
#   5. EfiGuard custom-build into ESP (\EFI\Microsoft\Boot\bootmgfw.efi
#      replaced by Loader.efi; original moved to bootmgfw.efi.original;
#      EfiGuardDxe.efi placed at both \EFI\Microsoft\Boot\ and \EFI\Boot\)
#   6. BCD testsigning No, nointegritychecks No, fast-startup off
#   7. AutoReboot off + minidump enabled (for triage if anything crashes)
#
# Idempotent: safe to re-run.
#
# Expects these files staged on guest (pushed by deploy/scripts/install-stealth.sh):
#   C:\stealth\driver-signing\backdated-ca.der
#   C:\stealth\driver-signing\backdated-signer.der
#   C:\stealth\nv-driver\viogpudo.sys
#   C:\stealth\nv-driver\viogpudo.cat
#   C:\stealth\nv-driver\viogpudo-nvidia.inf
#   C:\stealth\nvapi64.dll
#   C:\stealth\efiguard\Loader.efi
#   C:\stealth\efiguard\EfiGuardDxe.efi
#   C:\stealth\apply-gpu-spoof.ps1
#
# After this script returns, host should `shutdown /s` and relaunch QEMU
# with `GPU_SELFSIGNED=1` so the guest comes up with PCI VEN_10DE.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Step($n, $msg) { Write-Host ('[' + $n + '] ' + $msg) -Fore Cyan }

# --- Sanity ---------------------------------------------------------
foreach ($f in @(
    'C:\stealth\driver-signing\backdated-ca.der',
    'C:\stealth\driver-signing\backdated-signer.der',
    'C:\stealth\nv-driver\viogpudo.sys',
    'C:\stealth\nv-driver\viogpudo.cat',
    'C:\stealth\nv-driver\viogpudo-nvidia.inf',
    'C:\stealth\nvapi64.dll',
    'C:\stealth\efiguard\Loader.efi',
    'C:\stealth\efiguard\EfiGuardDxe.efi',
    'C:\stealth\apply-gpu-spoof.ps1'
)) {
    if (-not (Test-Path $f)) { throw "missing staged file: $f" }
}

# --- 1) backdated CA + signer trust ---------------------------------
Step 1 'install backdated CA into LocalMachine\Root + signer into TrustedPublisher'
& certutil -addstore -f Root            'C:\stealth\driver-signing\backdated-ca.der'     | Out-Null
& certutil -addstore -f TrustedPublisher 'C:\stealth\driver-signing\backdated-signer.der' | Out-Null

# --- 2) driver package staging --------------------------------------
Step 2 'pnputil /add-driver viogpudo-nvidia.inf (DriverStore only)'
& pnputil /add-driver 'C:\stealth\nv-driver\viogpudo-nvidia.inf' | Out-Null

# --- 3) nvapi64.dll into System32 -----------------------------------
Step 3 'nvapi64.dll -> C:\Windows\System32 (GPU-Z / 鲁大师 NVAPI fakery)'
$nvapiDst = 'C:\Windows\System32\nvapi64.dll'
if (Test-Path $nvapiDst) {
    & takeown /f $nvapiDst | Out-Null
    & icacls   $nvapiDst /grant 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null
}
Copy-Item 'C:\stealth\nvapi64.dll' $nvapiDst -Force

# --- 4) registry GPU rename ----------------------------------------
Step 4 'apply-gpu-spoof.ps1 — rewrite Win32_VideoController name + DEVPKEY'
& powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\stealth\apply-gpu-spoof.ps1' -SkipTask | Out-Host

# --- 5) install EfiGuard into ESP -----------------------------------
Step 5 'install EfiGuard into ESP via mountvol'

# Defender flags Loader.efi as a bootkit. Add path + extension exclusions
# *before* placing the file so realtime scan doesn't quarantine it.
Add-MpPreference -ExclusionPath 'C:\stealth\efiguard'  -EA 0
Add-MpPreference -ExclusionExtension '.efi'            -EA 0

& mountvol S: /S | Out-Null
$ms   = 'S:\EFI\Microsoft\Boot'
$bm   = "$ms\bootmgfw.efi"
$bmO  = "$ms\bootmgfw.efi.original"

# First-time install: back up original bootmgfw.efi (only if .original missing).
# Re-runs: skip backup so we don't overwrite the real backup with a Loader.efi.
if (-not (Test-Path $bmO)) {
    Write-Host ('  backup ' + $bm + ' -> ' + $bmO)
    Copy-Item -LiteralPath $bm -Destination $bmO -Force
}

# Replace bootmgfw.efi with our Loader.efi (chain target = bootmgfw.efi.original)
Copy-Item -LiteralPath 'C:\stealth\efiguard\Loader.efi' -Destination $bm -Force

# EfiGuardDxe.efi at both standard search paths (Loader looks at \EFI\Boot\* first)
Copy-Item -LiteralPath 'C:\stealth\efiguard\EfiGuardDxe.efi' -Destination "$ms\EfiGuardDxe.efi"          -Force
Copy-Item -LiteralPath 'C:\stealth\efiguard\EfiGuardDxe.efi' -Destination 'S:\EFI\Boot\EfiGuardDxe.efi'  -Force

# Sanity print
Get-ChildItem $ms -Filter 'bootmgfw*'  | Format-Table Name,Length,LastWriteTime -AutoSize | Out-Host
Get-ChildItem 'S:\EFI\Boot' -Filter 'EfiGuard*' | Format-Table Name,Length,LastWriteTime -AutoSize | Out-Host

& mountvol S: /D | Out-Null

# --- 6) BCD ---------------------------------------------------------
Step 6 'BCD: testsigning No, nointegritychecks No, fast-startup off'
& bcdedit /set '{current}' testsigning      No | Out-Null
& bcdedit /set '{current}' nointegritychecks No | Out-Null
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' HiberbootEnabled 0 -Type DWord -Force
& powercfg /hibernate off | Out-Null
& bcdedit | Select-String -Pattern 'testsigning|nointegritychecks' | Out-Host

# --- 7) Crash dump + auto-restart -----------------------------------
Step 7 'crash dump: minidump + AutoReboot off (for triage)'
$cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
Set-ItemProperty $cc AutoReboot 0 -Type DWord -Force
Set-ItemProperty $cc CrashDumpEnabled 3 -Type DWord -Force
Set-ItemProperty $cc AlwaysKeepMemoryDump 1 -Type DWord -Force -EA 0
New-Item -Path 'C:\Windows\Minidump' -ItemType Directory -Force | Out-Null

Write-Host ''
Write-Host '=== install-stealth-guest done ===' -Fore Green
Write-Host 'Host should: shutdown /s the guest, then relaunch QEMU with GPU_SELFSIGNED=1.' -Fore Yellow
Write-Host 'On next boot you should see EfiGuard banner; viogpudo loads via DSE_DISABLE_AT_BOOT.' -Fore Yellow

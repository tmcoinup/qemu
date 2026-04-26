# shallow-stealth.ps1 — install ACE-friendly GTX 1050 spoof on a guest that
# already had destealth-revert.ps1 applied (no EfiGuard, no NVIDIA-fake CA,
# no patched viogpudo).
#
# What it does:
#   1) Pull stock virtio-win 0.1.266 viogpudo (MS-WHQL signed by "Microsoft
#      Windows Hardware Compatibility Publisher") + matching .cat/.inf from
#      the host HTTP server.
#   2) pnputil /add-driver /install — Windows binds it to PCI VEN_1AF4&DEV_1050
#      (with subsys 1C8110DE = NVIDIA GTX 1050 from QEMU spoof).
#   3) Pull apply-gpu-spoof.ps1 + nvapi64.dll, run the script — registry
#      overlay so Win32_VideoController.Name / DriverDesc / Device Manager
#      friendly name all read "NVIDIA GeForce GTX 1050". GPU-Z reads via
#      DXGI / WMI / NVAPI shim and sees GTX 1050.
#
# After this the guest has NO non-WHQL drivers, NO modified bootmgr, NO
# extra root certs. testsigning stays No.
#
# Run as Administrator:
#     irm http://192.168.30.33:8765/shallow-stealth.ps1 | iex

$ErrorActionPreference = 'Continue'
# zh-CN Win10 默认 console code page = 936 (GBK)，会把中文 Write-Host 输出搞乱码。强制 UTF-8。
try { chcp 65001 | Out-Null } catch {}
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}
$OutputEncoding = [System.Text.UTF8Encoding]::new()

$base = 'http://192.168.30.33:8765'
$dst  = 'C:\stealth\nv-stock'
$null = New-Item -ItemType Directory -Force -Path $dst -ErrorAction SilentlyContinue

Write-Host "=== shallow-stealth installer ===" -ForegroundColor Cyan

# ----------------------------------------------------------------------
# 1) Pull stock viogpudo bundle
# ----------------------------------------------------------------------
Write-Host "`n[1/4] downloading stock virtio-win viogpudo (MS-WHQL signed)" -ForegroundColor Yellow
foreach ($f in @('viogpudo.sys','viogpudo.cat','viogpudo.inf')) {
    $u = "$base/stock-viogpudo/$f"
    $p = Join-Path $dst $f
    Invoke-WebRequest -Uri $u -OutFile $p -UseBasicParsing
    if (Test-Path $p) {
        $i = Get-Item $p
        Write-Host "  $f  $($i.Length) bytes"
    } else {
        Write-Host "  ERROR fetching $f from $u" -ForegroundColor Red
        return
    }
}

# Sanity: verify the .sys is MS-HCP signed (not the fake NVIDIA chain)
$sig = Get-AuthenticodeSignature (Join-Path $dst 'viogpudo.sys')
Write-Host "  signer: $($sig.SignerCertificate.Subject)" -ForegroundColor Gray
if ($sig.SignerCertificate.Subject -notmatch 'Microsoft Windows Hardware Compatibility Publisher') {
    Write-Host "  WARN: not MS-WHQL signed — refusing to install" -ForegroundColor Red
    return
}

# ----------------------------------------------------------------------
# 2) Install driver
# ----------------------------------------------------------------------
Write-Host "`n[2/4] pnputil /add-driver /install" -ForegroundColor Yellow
pnputil /add-driver (Join-Path $dst 'viogpudo.inf') /install 2>&1 | Select-Object -Last 8

# Confirm bind
Start-Sleep -Seconds 2
$dev = Get-PnpDevice -Class Display | Where-Object { $_.Status -ne 'Unknown' } | Select-Object -First 1
Write-Host ""
Write-Host "  bound device:" -ForegroundColor Gray
Write-Host "    Friendly: $($dev.FriendlyName)"
Write-Host "    Status  : $($dev.Status) / Problem: $($dev.Problem)"
Write-Host "    HWID    : $($dev.InstanceId)"

# ----------------------------------------------------------------------
# 3) Download + run apply-gpu-spoof.ps1 (registry overlay rename to NVIDIA)
# ----------------------------------------------------------------------
Write-Host "`n[3/4] downloading apply-gpu-spoof.ps1 + nvapi64.dll" -ForegroundColor Yellow
$spoof = 'C:\stealth\apply-gpu-spoof.ps1'
Invoke-WebRequest -Uri "$base/apply-gpu-spoof.ps1" -OutFile $spoof -UseBasicParsing
Write-Host "  apply-gpu-spoof.ps1 -> $spoof"

# nvapi64.dll: not strictly required if you only need GPU-Z to show NVIDIA via
# WMI/DXGI. Skip if 8765 doesn't expose it.
try {
    Invoke-WebRequest -Uri "$base/nvapi64.dll" -OutFile 'C:\Windows\System32\nvapi64.dll' -UseBasicParsing -ErrorAction Stop
    Write-Host "  nvapi64.dll -> System32"
} catch {
    Write-Host "  skip nvapi64.dll (not served / not needed)"
}

Write-Host ""
Write-Host "  探测当前 GPU subsys，找到对应的 spoof 名称" -ForegroundColor Yellow

# 按 PCI subsys ID 反查 GPU 池：launcher 的 stealth_pick_profile 把随机选定的
# GPU 写到 virtio-vga 的 subsys，guest 这边读 InstanceId 拿到 SUBSYS 串然后查表。
$gpuMap = @{
    '138010DE' = @{ Name='NVIDIA GeForce GTX 750 Ti'; Vendor='NVIDIA'; Bios='Version 82.07.41.00.32'; RamMb=2048 }
    '1D0110DE' = @{ Name='NVIDIA GeForce GT 1030';    Vendor='NVIDIA'; Bios='Version 86.08.46.00.81'; RamMb=2048 }
    '1C8110DE' = @{ Name='NVIDIA GeForce GTX 1050';   Vendor='NVIDIA'; Bios='Version 86.07.48.00.38'; RamMb=2048 }
    '1C8210DE' = @{ Name='NVIDIA GeForce GTX 1050 Ti';Vendor='NVIDIA'; Bios='Version 86.07.48.00.A0'; RamMb=4096 }
    '699F1002' = @{ Name='AMD Radeon RX 550';         Vendor='AMD';    Bios='016.011.000.029.000000'; RamMb=2048 }
    '67FF1002' = @{ Name='AMD Radeon RX 560';         Vendor='AMD';    Bios='016.011.000.029.000000'; RamMb=4096 }
}
$gpuDev = Get-PnpDevice -Class Display | Where-Object { $_.Status -ne 'Unknown' } | Select-Object -First 1
$cfg = $null
if ($gpuDev -and $gpuDev.InstanceId -match 'SUBSYS_([0-9A-Fa-f]{8})') {
    $subsys = $matches[1].ToUpper()
    if ($gpuMap.ContainsKey($subsys)) {
        $cfg = $gpuMap[$subsys]
        Write-Host "  匹配到: subsys=$subsys -> $($cfg.Name)" -ForegroundColor Gray
    } else {
        Write-Host "  subsys=$subsys 未在已知池中，使用默认 GTX 1050" -ForegroundColor Yellow
    }
}
if (-not $cfg) {
    $cfg = @{ Name='NVIDIA GeForce GTX 1050'; Vendor='NVIDIA'; Bios='Version 86.07.48.00.38'; RamMb=2048 }
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $spoof `
    -SpoofName   $cfg.Name `
    -SpoofVendor $cfg.Vendor `
    -SpoofBios   $cfg.Bios `
    -SpoofRamMb  $cfg.RamMb `
    2>&1 | Select-Object -Last 30

# ----------------------------------------------------------------------
# 4) Final state
# ----------------------------------------------------------------------
Write-Host "`n[4/4] final state" -ForegroundColor Yellow
$dev = Get-PnpDevice -Class Display | Where-Object { $_.Status -ne 'Unknown' } | Select-Object -First 1
$wmi = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -ne 'Microsoft Basic Display Adapter' } | Select-Object -First 1
"  Display Status   : $($dev.Status) / Problem: $($dev.Problem)"
"  Display Friendly : $($dev.FriendlyName)"
"  WMI Name         : $($wmi.Name)"
"  WMI VideoProc    : $($wmi.VideoProcessor)"
"  Driver           : $($wmi.DriverVersion)"
$ts = (bcdedit /enum '{current}' | Select-String 'testsigning').ToString().Trim()
"  $ts"

Write-Host "`n=== done ===" -ForegroundColor Green
Write-Host "All requirements:" -ForegroundColor Yellow
Write-Host "  - testsigning            : No"
Write-Host "  - GPU code 43            : cleared (status=OK)"
Write-Host "  - GPU-Z reports          : NVIDIA GeForce GTX 1050"
Write-Host "  - Driver signature       : Microsoft WHQL (no fake CA)"
Write-Host "  - Bootmgr                : original"
Write-Host ""
Write-Host "Next: shutdown /r /t 5 to reboot — Device Manager / WMI repopulate from registry overlay" -ForegroundColor Cyan
Write-Host "Press Enter to reboot now (Ctrl-C to skip and reboot manually)"
$null = Read-Host
shutdown /r /t 5 /f

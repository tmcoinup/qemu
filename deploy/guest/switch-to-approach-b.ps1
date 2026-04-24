<#
.SYNOPSIS
  Switch from approach A (patched INF + self-signed cat) to approach B (original
  NVIDIA INF + registry string rewrite). After this:
    - 数字签名者 becomes Microsoft Windows Hardware Compatibility Publisher again
    - Device Manager / WMI / dxdiag show "NVIDIA GeForce GTX 1050" (or whatever)
    - PCI layer remains the Quadro RTX 6000 true ID (DEV_1E30)
    - No testsigning / nointegritychecks residue

.DESCRIPTION
  Prereq: host must boot VM in --no-spoof mode (QEMU must NOT overwrite
  x-pci-device-id). Otherwise Windows PnP sees DEV_1D01, won't match the
  unmodified INF.

  Steps executed:
    1. Remove self-signed cert CN=vGPU-Patch-Signer from Root + TrustedPublisher
    2. Uninstall patched oem INF(s)
    3. Install original nvgridsw.inf (from C:\nv\538.33-orig\)
    4. Run patch-grid-strings.ps1 with requested TargetName
    5. Reboot is required after to apply

.EXAMPLE
  \\tsclient\nv\switch-to-approach-b.ps1 -TargetName 'GeForce GT 1030'
#>
[CmdletBinding()]
param(
    [string]$TargetName = 'GeForce GT 1030',
    [string]$Vendor = ''
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

Write-Host '[1/5] Remove self-signed vGPU-Patch-Signer from Root / TrustedPublisher' -Fore Cyan
foreach ($store in @('Root','TrustedPublisher','My')) {
    Get-ChildItem "Cert:\LocalMachine\$store" -EA 0 |
        Where-Object { $_.Subject -eq 'CN=vGPU-Patch-Signer' -or $_.Subject -eq 'CN=NVIDIA Corporation (vGPU-Patch)' } |
        ForEach-Object {
            Write-Host "  rm $store / $($_.Thumbprint) $($_.Subject)"
            Remove-Item "Cert:\LocalMachine\$store\$($_.Thumbprint)" -DeleteKey -Force
        }
}

Write-Host '[2/5] Uninstall current NVIDIA oem INF(s)' -Fore Cyan
$drvs = pnputil /enum-drivers
$lastOem = ''
foreach ($line in $drvs -split "`r`n") {
    if ($line -match '(oem\d+\.inf)') { $lastOem = $Matches[1] }
    if ($line -match 'nvgridsw\.inf' -and $lastOem) {
        Write-Host "  removing $lastOem"
        pnputil /delete-driver $lastOem /uninstall /force | Out-Null
    }
}

Write-Host '[3/5] Install original nvgridsw.inf (must pre-exist at C:\nv\538.33-orig\)' -Fore Cyan
$origInf = 'C:\nv\538.33-orig\nvgridsw.inf'
if (-not (Test-Path $origInf)) {
    throw "Original INF not found at $origInf -- re-download Display.Driver.zip from http://192.168.30.127:8080/ first"
}
# Sanity: original cat should still be valid (Microsoft / NVIDIA chain)
Get-AuthenticodeSignature 'C:\nv\538.33-orig\nvgridsw.cat' | Format-List Status, SignerCertificate

pnputil /add-driver $origInf /install 2>&1 | ForEach-Object { "  $_" }

Write-Host '[4/5] Run patch-grid-strings.ps1 to rewrite registry to requested name' -Fore Cyan
# Copy the helper locally so it survives reboot
$psPath = 'C:\nv\patch-grid-strings.ps1'
if (Test-Path '\\tsclient\nv\patch-grid-strings.ps1') {
    Copy-Item '\\tsclient\nv\patch-grid-strings.ps1' $psPath -Force
} elseif (-not (Test-Path $psPath)) {
    # Fall back to http
    Invoke-WebRequest 'http://192.168.30.127:8080/patch-grid-strings.ps1' -OutFile $psPath -UseBasicParsing
}
& $psPath -TargetName $TargetName -Vendor $Vendor

Write-Host '[5/5] Verify + prompt reboot' -Fore Cyan
Write-Host 'Current signer on installed INF:' -Fore Yellow
pnputil /enum-drivers | Select-String -Pattern 'NVIDIA' -Context 0,5 | Select-Object -First 10

Write-Host ''
Write-Host 'Approach B install complete.' -Fore Green
Write-Host 'On host, relaunch VM with --no-spoof mode so PCI stays DEV_1E30:' -Fore Yellow
Write-Host '  ./start-vm.sh 1 --rdp --no-spoof' -Fore Yellow
Write-Host ''
Write-Host 'Reboot now to pick up registry rewrites (WMI caches a lot of these at logon):' -Fore Yellow
Write-Host '  shutdown /r /t 5'

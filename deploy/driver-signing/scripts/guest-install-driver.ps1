$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$pkgDir = 'C:\stealth\nv-driver'
$inf    = Join-Path $pkgDir 'viogpudo-nvidia.inf'
$cat    = Join-Path $pkgDir 'viogpudo.cat'
$sys    = Join-Path $pkgDir 'viogpudo.sys'

Write-Host '=== signatures (both must be Valid with our NVIDIA Code Signing Root chain) ==='
foreach ($f in @($cat,$sys)) {
    $s = Get-AuthenticodeSignature $f
    Write-Host ('{0} : {1} : {2}' -f (Split-Path $f -Leaf), $s.Status, $s.SignerCertificate.Subject)
}
Write-Host ''

Write-Host '=== existing viogpudo INFs in DriverStore ==='
pnputil /enum-drivers | Select-String -Pattern 'viogpudo|oem[0-9]+\.inf' -Context 0,4 | ForEach-Object { $_.ToString() } | Select-Object -First 40
Write-Host ''

Write-Host '=== pnputil /add-driver (no /install — will bind on next boot with VEN_10DE) ==='
& pnputil /add-driver $inf
Write-Host ("exit = $LASTEXITCODE")
Write-Host ''

Write-Host '=== staging nvapi64.dll into System32 ==='
$nvapiSrc = Join-Path $pkgDir 'nvapi64.dll'
$nvapiDst = 'C:\Windows\System32\nvapi64.dll'
if (Test-Path $nvapiDst) {
    & takeown /f $nvapiDst | Out-Null
    & icacls $nvapiDst /grant 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null
}
Copy-Item $nvapiSrc $nvapiDst -Force
Write-Host ("nvapi64.dll -> System32 ({0} bytes)" -f (Get-Item $nvapiDst).Length)

Write-Host ''
Write-Host '=== post-install DriverStore list ==='
pnputil /enum-drivers | Select-String -Pattern 'viogpudo|NVIDIA' -Context 0,4 | ForEach-Object { $_.ToString() } | Select-Object -First 40

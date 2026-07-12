$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$pkgDir = 'C:\stealth\nv-driver'
$inf2cat = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x86\Inf2Cat.exe'
if (-not (Test-Path $inf2cat)) { throw "Inf2Cat not found: $inf2cat" }

# Inf2Cat wants all driver files in one dir and takes the dir as argument.
# The INF's CatalogFile= attribute names the cat that will be produced.
Push-Location $pkgDir
try {
    & $inf2cat /driver:. /os:10_x64 /verbose
    if ($LASTEXITCODE -ne 0) { throw "Inf2Cat failed exit=$LASTEXITCODE" }
} finally { Pop-Location }

Write-Host ''
Write-Host '=== generated files ==='
Get-ChildItem $pkgDir | Format-Table Name,Length,LastWriteTime -AutoSize

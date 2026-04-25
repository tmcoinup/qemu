$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$st = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe'
$sys = 'C:\Windows\System32\drivers\viogpudo.sys'
$cat = 'C:\Windows\System32\DriverStore\FileRepository\viogpudo-nvidia.inf_amd64_d16065a3e9bb4901\viogpudo.cat'
$dsSys = 'C:\Windows\System32\DriverStore\FileRepository\viogpudo-nvidia.inf_amd64_d16065a3e9bb4901\viogpudo.sys'

Write-Host '=== signtool verify /v /pa (Authenticode default policy) sys ==='
& $st verify /v /pa $sys
Write-Host ''
Write-Host '=== signtool verify /v /kp (kernel driver policy) sys ==='
& $st verify /v /kp $sys
Write-Host ''
Write-Host '=== signtool verify /v /pa cat ==='
& $st verify /v /pa $cat
Write-Host ''
Write-Host '=== signtool verify /v /kp cat ==='
& $st verify /v /kp $cat
Write-Host ''
Write-Host '=== signtool verify /v /c <cat> sys (catalog-based) ==='
& $st verify /v /c $cat $sys
Write-Host ''
Write-Host '=== system CatRoot contents for our driver hash ==='
$hash = (Get-FileHash -Algorithm SHA256 $sys).Hash
Write-Host ("driver SHA256 = " + $hash)
Write-Host 'searching CatRoot for that hash in any .cat...'
$catRoots = 'C:\Windows\System32\catroot'
$all = Get-ChildItem -Recurse -Filter *.cat -Path $catRoots -ErrorAction SilentlyContinue
Write-Host ("total cats registered: " + $all.Count)

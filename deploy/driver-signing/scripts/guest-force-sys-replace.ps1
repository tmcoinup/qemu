$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$src = 'C:\stealth\nv-driver\viogpudo.sys'
$tgt = 'C:\Windows\System32\drivers\viogpudo.sys'

Write-Host '=== hash before ==='
Write-Host ('sys32 = ' + (Get-FileHash $tgt).Hash)
Write-Host ('staged = ' + (Get-FileHash $src).Hash)

Write-Host ''
Write-Host '=== takeown + replace ==='
& takeown /f $tgt | Out-Null
& icacls $tgt /grant 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null
Copy-Item $src $tgt -Force

Write-Host '=== hash after ==='
Write-Host ('sys32 = ' + (Get-FileHash $tgt).Hash)

Write-Host ''
Write-Host '=== signtool verify /v /kp ==='
$st = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe'
& $st verify /v /kp $tgt

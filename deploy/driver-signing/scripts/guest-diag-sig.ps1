$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== live system32 sys signature ==='
$s = Get-AuthenticodeSignature 'C:\Windows\System32\drivers\viogpudo.sys'
Write-Host ('Status  : ' + $s.Status)
Write-Host ('Subject : ' + $s.SignerCertificate.Subject)
Write-Host ('SignType: ' + $s.SignatureType)

Write-Host ''
Write-Host '=== hashes (System32 vs DriverStore FileRepository) ==='
$sys32 = 'C:\Windows\System32\drivers\viogpudo.sys'
Write-Host ("System32 = " + ((Get-FileHash $sys32).Hash))
Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Filter 'viogpudo.sys' -ErrorAction SilentlyContinue | ForEach-Object {
    $h = (Get-FileHash $_.FullName).Hash
    Write-Host ("  " + $_.FullName + " = " + $h)
}

Write-Host ''
Write-Host '=== oem7 DriverStore files (hashes + sigs) ==='
$store = 'C:\Windows\System32\DriverStore\FileRepository\viogpudo-nvidia.inf_amd64_d16065a3e9bb4901'
Get-ChildItem $store | ForEach-Object {
    Write-Host ('--- ' + $_.Name + ' (' + $_.Length + ' bytes) ---')
    if ($_.Extension -in '.sys','.cat','.dll') {
        $s2 = Get-AuthenticodeSignature $_.FullName
        Write-Host ('  sig status  : ' + $s2.Status)
        Write-Host ('  sig subject : ' + $s2.SignerCertificate.Subject)
        Write-Host ('  sig issuer  : ' + $s2.SignerCertificate.Issuer)
        Write-Host ('  sig message : ' + $s2.StatusMessage)
    }
}

Write-Host ''
Write-Host '=== setupapi.dev.log tail 150 (viogpudo / VEN_10DE / signer) ==='
$log = 'C:\Windows\INF\setupapi.dev.log'
if (Test-Path $log) {
    $lines = Get-Content $log -Tail 400
    $lines | Where-Object { $_ -match 'viogpudo|VEN_10DE|signer|signed|signature|install\.|hash|cat file|oem7|oem3|dvi:|sig:' } | Select-Object -Last 60
}

Write-Host ''
Write-Host '=== setupapi error tail ==='
$elog = 'C:\Windows\INF\setupapi.dev.log'
Get-Content $elog -Tail 800 -ErrorAction SilentlyContinue | Where-Object { $_ -match '!!|!   !|Error|error|failed' } | Select-Object -Last 30

Write-Host ''
Write-Host '=== recent System events for driver load ==='
Get-WinEvent -LogName System -MaxEvents 200 -ErrorAction SilentlyContinue | Where-Object {
    $_.Message -match 'viogpudo|signature|integrity|VioGpu' -or
    $_.Id -in @(7000,7001,7009,7011,7026,7031,7034,7036,7045,219,1,3)
} | Select-Object -First 10 | ForEach-Object {
    Write-Host ('-- ' + $_.TimeCreated + ' ' + $_.ProviderName + ' Id=' + $_.Id + ' ' + $_.LevelDisplayName)
    Write-Host ('   ' + ($_.Message -split "`n")[0])
}

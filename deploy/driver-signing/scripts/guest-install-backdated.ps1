# guest-install-backdated.ps1
#
# Runs on the Win10 guest. Installs the backdated cert chain into the machine
# trust stores, replaces C:\Windows\System32\drivers\viogpudo.sys with the
# pre-2015-signed copy, and disables testsigning so the driver is gated only
# by the grandfather rule.
#
# Expects these files staged in C:\stealth\driver-signing:
#   backdated-ca.der      (root CA in DER)
#   backdated-signer.der  (leaf code-signing cert in DER)
#   viogpudo.sys          (re-signed driver with signingTime < 2015-07-29)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$stage = 'C:\stealth\driver-signing'
$ca    = "$stage\backdated-ca.der"
$signer= "$stage\backdated-signer.der"
$newSys= "$stage\viogpudo.sys"
$tgt   = 'C:\Windows\System32\drivers\viogpudo.sys'

foreach ($f in @($ca,$signer,$newSys)) {
    if (-not (Test-Path $f)) { throw "missing staged file: $f" }
}

Write-Host '=== step 1: install CA into LocalMachine\Root ==='
& certutil -addstore -f Root $ca
if ($LASTEXITCODE -ne 0) { throw "certutil addstore Root failed ($LASTEXITCODE)" }

Write-Host '=== step 2: install signer into LocalMachine\TrustedPublisher ==='
& certutil -addstore -f TrustedPublisher $signer
if ($LASTEXITCODE -ne 0) { throw "certutil addstore TrustedPublisher failed ($LASTEXITCODE)" }

Write-Host '=== step 3: snapshot existing driver signature ==='
$before = Get-AuthenticodeSignature $tgt
Write-Host ("before: status={0} subject={1}" -f $before.Status, $before.SignerCertificate.Subject)

Write-Host '=== step 4: takeown + grant SYSTEM full control on target .sys ==='
& takeown /f $tgt | Out-Null
& icacls $tgt /grant 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null

Write-Host '=== step 5: backup old sys, write new sys ==='
$bak = "$tgt.bak-backdated-$(Get-Date -Format yyyyMMddHHmmss)"
Copy-Item $tgt $bak -Force
Copy-Item $newSys $tgt -Force
Write-Host "backup -> $bak"

Write-Host '=== step 6: verify new signature ==='
$after = Get-AuthenticodeSignature $tgt
Write-Host ("after : status={0} subject={1}" -f $after.Status, $after.SignerCertificate.Subject)
if ($after.Status -ne 'Valid') {
    Write-Warning ("new signature NOT Valid (status={0}); check CA trust and chain. StatusMessage={1}" -f $after.Status, $after.StatusMessage)
}

Write-Host '=== step 7: disable testsigning ==='
& bcdedit /set testsigning off | Out-Null
& bcdedit /set nointegritychecks off | Out-Null
& bcdedit /enum | Select-String -Pattern 'testsigning|nointegritychecks'

Write-Host '=== step 8: echo reboot plan ==='
Write-Host 'to apply: shutdown /r /t 0 /f'

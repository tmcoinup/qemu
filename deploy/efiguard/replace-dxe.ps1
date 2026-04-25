$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$src = 'C:\stealth\efiguard\EfiGuardDxe.efi'
if (-not (Test-Path $src)) { throw "missing $src" }

# Mount ESP and replace EfiGuardDxe.efi at both standard locations
& mountvol S: /S | Out-Null
foreach ($dst in @('S:\EFI\Microsoft\Boot\EfiGuardDxe.efi','S:\EFI\Boot\EfiGuardDxe.efi')) {
    Write-Host ('-- ' + $dst)
    Write-Host ('   before: ' + (Get-Item $dst -EA 0).Length + ' bytes')
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-Host ('   after : ' + (Get-Item $dst -EA 0).Length + ' bytes')
}

Write-Host ''
Write-Host '=== set BCD testsigning ON (so viogpudo can load at boot) ==='
& bcdedit /set '{current}' testsigning Yes
& bcdedit /set '{current}' nointegritychecks No
& bcdedit /enum '{current}' | Select-String -Pattern 'testsigning|nointegritychecks'

& mountvol S: /D | Out-Null

Write-Host ''
Write-Host 'next: shutdown /r and verify post-reboot'

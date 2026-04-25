$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
& 'C:\stealth\efiguard\EfiDSEFix.exe' -d 2>&1
Write-Host ('exit=' + $LASTEXITCODE)

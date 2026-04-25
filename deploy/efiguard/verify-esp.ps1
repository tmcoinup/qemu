$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
& mountvol S: /S | Out-Null
Get-ChildItem 'S:\EFI\Microsoft\Boot' -Filter 'bootmgfw*' | Format-Table Name,Length,LastWriteTime -AutoSize
Get-ChildItem 'S:\EFI\Microsoft\Boot' -Filter 'EfiGuard*' | Format-Table Name,Length,LastWriteTime -AutoSize
& mountvol S: /D | Out-Null

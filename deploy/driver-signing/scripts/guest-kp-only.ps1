$st = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe'
& $st verify /v /kp 'C:\Windows\System32\drivers\viogpudo.sys'
Write-Host ("ExitCode=$LASTEXITCODE")

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '===BCD==='
bcdedit /enum | Select-String -Pattern 'testsigning|nointegritychecks'

Write-Host ''
Write-Host '===Win32_VideoController==='
Get-CimInstance Win32_VideoController | Select-Object Name,Status,PNPDeviceID,ConfigManagerErrorCode,DriverVersion | Format-List

Write-Host '===DriverService==='
Get-CimInstance Win32_SystemDriver -Filter "Name='viogpudo'" | Select-Object Name,State,StartMode,PathName | Format-List

Write-Host '===Signature==='
$sig = Get-AuthenticodeSignature C:\Windows\System32\drivers\viogpudo.sys
Write-Host ("status={0}" -f $sig.Status)
Write-Host ("subject={0}" -f $sig.SignerCertificate.Subject)
Write-Host ("issuer={0}" -f $sig.SignerCertificate.Issuer)
Write-Host ("signtype={0}" -f $sig.SignatureType)

Write-Host ''
Write-Host '===Root-CAs (NVIDIA matches)==='
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match 'NVIDIA' } | Select-Object Subject,Thumbprint,NotBefore,NotAfter | Format-List

Write-Host '===TrustedPublisher==='
Get-ChildItem Cert:\LocalMachine\TrustedPublisher | Where-Object { $_.Subject -match 'NVIDIA' } | Select-Object Subject,Thumbprint,NotBefore,NotAfter | Format-List

Write-Host '===System-Events-last10min==='
Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddMinutes(-10)} -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'Kernel-PnP|CodeIntegrity|VioGpu|DriverFrameworks' -or $_.Message -match 'signature|integrity|viogpudo' } |
    Select-Object TimeCreated,ProviderName,Id,LevelDisplayName,Message | Format-List

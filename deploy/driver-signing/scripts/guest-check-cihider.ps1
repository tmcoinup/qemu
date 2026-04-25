$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== CiHider service registry ==='
$svcPaths = @(
    'HKLM:\SYSTEM\CurrentControlSet\Services\CiHider',
    'HKLM:\SYSTEM\CurrentControlSet\Services\cihider',
    'HKLM:\SYSTEM\CurrentControlSet\Services\CihSigner'
)
foreach ($p in $svcPaths) {
    if (Test-Path $p) {
        Write-Host "--- $p ---"
        Get-ItemProperty $p | Select-Object ImagePath,Start,Type,DisplayName,ErrorControl | Format-List
    }
}

Write-Host '=== All services with cih in name ==='
Get-CimInstance Win32_BaseService | Where-Object { $_.Name -match 'cih|CiHider' } | Select-Object Name,State,StartMode,PathName | Format-Table -AutoSize

Write-Host '=== system32\drivers\cih* ==='
Get-ChildItem 'C:\Windows\System32\drivers' -Filter 'cih*' -ErrorAction SilentlyContinue | Format-Table Name,Length -AutoSize

Write-Host '=== sc query cihider / CiHider ==='
& sc.exe query cihider 2>&1 | Select-Object -First 10
Write-Host '---'
& sc.exe query CiHider 2>&1 | Select-Object -First 10

Write-Host '=== Enum\Root\LEGACY_* for cihider ==='
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\Root' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'cihider|cih' } | Select-Object -First 3 | ForEach-Object { Write-Host $_.PSPath }

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== Current Enum\PCI\VEN_10DE device state ==='
$pciRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'
Get-ChildItem $pciRoot | Where-Object { $_.PSChildName -like 'VEN_10DE*' } | ForEach-Object {
    $ven = $_
    Get-ChildItem $ven.PSPath | ForEach-Object {
        $i = $_
        $p = Get-ItemProperty -Path $i.PSPath
        Write-Host ''
        Write-Host ('[{0}\{1}]' -f $ven.PSChildName, $i.PSChildName)
        Write-Host ("  DeviceDesc   = {0}" -f $p.DeviceDesc)
        Write-Host ("  FriendlyName = {0}" -f $p.FriendlyName)
        Write-Host ("  Driver       = {0}" -f $p.Driver)
        Write-Host ("  Service      = {0}" -f $p.Service)
        Write-Host ("  ConfigFlags  = {0}" -f $p.ConfigFlags)
        Write-Host ("  HardwareID   = {0}" -f ($p.HardwareID -join ' ; '))
        Write-Host ("  CompatibleIDs= {0}" -f ($p.CompatibleIDs -join ' ; '))
        Write-Host ("  Mfg          = {0}" -f $p.Mfg)
    }
}

Write-Host ''
Write-Host '=== Class\{4d36e968-...} NNNN subkeys ==='
$classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
Get-ChildItem $classRoot | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
    $p = Get-ItemProperty -Path $_.PSPath
    Write-Host ''
    Write-Host ('[' + $_.PSChildName + ']')
    Write-Host ("  DriverDesc    = {0}" -f $p.DriverDesc)
    Write-Host ("  DriverVersion = {0}" -f $p.DriverVersion)
    Write-Host ("  DriverDate    = {0}" -f $p.DriverDate)
    Write-Host ("  InfPath       = {0}" -f $p.InfPath)
    Write-Host ("  InfSection    = {0}" -f $p.InfSection)
    Write-Host ("  ProviderName  = {0}" -f $p.ProviderName)
    Write-Host ("  MatchingDeviceId = {0}" -f $p.MatchingDeviceId)
}

Write-Host ''
Write-Host '=== pnputil /enum-drivers (Display class filtered) ==='
pnputil /enum-drivers | Select-String -Pattern 'Published Name|Original Name|Provider Name|Driver Version|Signer Name|Class Name' -Context 0,0 | Select-Object -First 60

Write-Host ''
Write-Host '=== DriverStore FileRepository contents (viogpudo*) ==='
Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Include 'viogpudo*.inf','viogpudo*.cat','viogpudo*.sys' -ErrorAction SilentlyContinue | Select-Object FullName,Length | Format-Table -AutoSize

Write-Host ''
Write-Host '=== Setupapi.dev.log last 50 lines ==='
$log = 'C:\Windows\INF\setupapi.dev.log'
if (Test-Path $log) {
    Get-Content $log -Tail 120 | Where-Object { $_ -match 'viogpudo|VEN_10DE|Signature|oem[0-9]|Signer|verify|validat' }
}

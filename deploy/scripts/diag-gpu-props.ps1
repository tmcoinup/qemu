# diag-gpu-props.ps1 — dump PnP DriverProvider/DriverDesc registry layout
# Run as admin, pipe output back for analysis.

$fmt = '{a8b865dd-2e3d-4094-ad97-e593a70c75d6}'
$enumRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'
$classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'

function Dump-Pid-Reg {
    # Properties 子树对 Admin 有 ACL 限制, PS 的 registry provider 会报
    # PermissionDenied. 用 reg.exe 绕过 (admin 上 reg.exe 会启 SeBackupPrivilege).
    param([string]$PidKey, [string]$Label)
    $regPath = $PidKey -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' `
                      -replace '^HKEY_LOCAL_MACHINE', 'HKLM' `
                      -replace '^HKLM:', 'HKLM'
    Write-Host "  $Label $regPath (via reg.exe)" -ForegroundColor Yellow
    $out = & reg.exe query "$regPath" /s 2>&1
    foreach ($line in $out) { Write-Host "    $line" }
}

Write-Host "== Enum\PCI (device instance properties) ==" -ForegroundColor Cyan
Get-ChildItem $enumRoot | Where-Object { $_.PSChildName -like 'VEN_1AF4*' } | ForEach-Object {
    $venKey = $_
    Get-ChildItem $venKey.PSPath | ForEach-Object {
        $instPath = $_.PSPath
        Write-Host ("-- " + $venKey.PSChildName + "\" + $_.PSChildName) -ForegroundColor Green
        $pn = (Get-ItemProperty -Path $instPath -Name Mfg,FriendlyName,DeviceDesc,Driver -ErrorAction SilentlyContinue)
        Write-Host ("    Enum-level Mfg='{0}'  FriendlyName='{1}'  DeviceDesc='{2}'" -f $pn.Mfg, $pn.FriendlyName, $pn.DeviceDesc)
        Write-Host ("    Enum-level Driver='{0}'" -f $pn.Driver)
        foreach ($p in '0003','0004','0009') {
            Dump-Pid-Reg ($instPath + '\Properties\' + $fmt + '\' + $p) "pid=$p"
        }
    }
}

Write-Host ""
Write-Host "== Control\Class (class subkey properties) ==" -ForegroundColor Cyan

Get-ChildItem $classRoot | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
    $classSub = $_.PSPath
    $dd = (Get-ItemProperty -Path $classSub -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
    if ($dd) {
        Write-Host ("-- " + $_.PSChildName + " DriverDesc='" + $dd + "'") -ForegroundColor Green
        $pn = (Get-ItemProperty -Path $classSub -Name ProviderName -ErrorAction SilentlyContinue).ProviderName
        Write-Host ("    ProviderName = '" + $pn + "'")
        foreach ($p in '0003','0004','0009') {
            Dump-Pid-Reg ($classSub + '\Properties\' + $fmt + '\' + $p) "pid=$p"
        }
    }
}

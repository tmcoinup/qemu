#Requires -Version 5.1

param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][string]$VhdPath,
    [string]$AuditScriptPath = 'C:\VMateLab\Audit-VMateGuestDisplayStack.ps1',
    [string]$BootstrapPath = 'C:\VMateLab\VMateAuditBootstrap.exe'
)

$ErrorActionPreference = 'Stop'
$vm = Get-VM -Name $VMName -ErrorAction Stop
if ([string]$vm.State -ne 'Off') { throw "VM 必须先关机：$VMName" }
$mounted = Mount-VHD -Path $VhdPath -Passthru -ErrorAction Stop
$systemHiveName = 'VMateDisplayAuditSystem'
$softwareHiveName = 'VMateDisplayAuditSoftware'
$systemLoaded = $false
$softwareLoaded = $false
try {
    $disk = $mounted | Get-Disk
    $windowsRoot = $null
    foreach ($partition in @($disk | Get-Partition)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -eq $volume -or
            [String]::IsNullOrWhiteSpace([string]$volume.DriveLetter)) { continue }
        $candidate = ([string]$volume.DriveLetter) + ':\'
        if (Test-Path -LiteralPath (Join-Path $candidate `
                    'Windows\System32\Config\SYSTEM') -PathType Leaf) {
            $windowsRoot = $candidate
            break
        }
    }
    if ($null -eq $windowsRoot) { throw "找不到 Windows 分区：$VhdPath" }
    $auditRoot = Join-Path $windowsRoot 'VMateAudit'
    [IO.Directory]::CreateDirectory($auditRoot) | Out-Null
    Remove-Item -LiteralPath (Join-Path $auditRoot 'display-stack.json') `
        -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $auditRoot 'bootstrap-result.txt') `
        -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $AuditScriptPath `
        -Destination (Join-Path $auditRoot 'Audit-VMateGuestDisplayStack.ps1') -Force
    Copy-Item -LiteralPath $BootstrapPath `
        -Destination (Join-Path $auditRoot 'VMateAuditBootstrap.exe') -Force

    $systemHive = Join-Path $windowsRoot 'Windows\System32\Config\SYSTEM'
    & reg.exe load "HKLM\$systemHiveName" $systemHive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '加载 SYSTEM hive 失败。' }
    $systemLoaded = $true
    $select = Get-ItemProperty -LiteralPath `
        "Registry::HKEY_LOCAL_MACHINE\$systemHiveName\Select"
    $controlSet = 'ControlSet{0:D3}' -f [int]$select.Current
    $servicePath = "Registry::HKEY_LOCAL_MACHINE\$systemHiveName\" +
        "$controlSet\Services\VMateDisplayAuditOnce"
    [void](New-Item -Path $servicePath -Force)
    [void](New-ItemProperty -Path $servicePath -Name Type -Value 16 `
            -PropertyType DWord -Force)
    [void](New-ItemProperty -Path $servicePath -Name Start -Value 2 `
            -PropertyType DWord -Force)
    [void](New-ItemProperty -Path $servicePath -Name ErrorControl -Value 1 `
            -PropertyType DWord -Force)
    [void](New-ItemProperty -Path $servicePath -Name ImagePath `
            -Value 'C:\VMateAudit\VMateAuditBootstrap.exe' `
            -PropertyType ExpandString -Force)
    [void](New-ItemProperty -Path $servicePath -Name DisplayName `
            -Value 'VMate one-time display audit' -PropertyType String -Force)

    # Remove the earlier interactive RunOnce trigger; the boot service supersedes it.
    $softwareHive = Join-Path $windowsRoot 'Windows\System32\Config\SOFTWARE'
    & reg.exe load "HKLM\$softwareHiveName" $softwareHive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '加载 SOFTWARE hive 失败。' }
    $softwareLoaded = $true
    $runOnce = "Registry::HKEY_LOCAL_MACHINE\$softwareHiveName\" +
        'Microsoft\Windows\CurrentVersion\RunOnce'
    Remove-ItemProperty -LiteralPath $runOnce -Name 'VMateDisplayAuditOnce' `
        -ErrorAction SilentlyContinue
}
finally {
    if ($softwareLoaded) {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        & reg.exe unload "HKLM\$softwareHiveName" | Out-Null
    }
    if ($systemLoaded) {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        & reg.exe unload "HKLM\$systemHiveName" | Out-Null
    }
    Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue
}

#Requires -Version 5.1

param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][string]$VhdPath,
    [string]$AuditScriptPath = 'C:\VMateLab\Audit-VMateGuestDisplayStack.ps1',
    [string]$Endpoint = ''
)

$ErrorActionPreference = 'Stop'
$vm = Get-VM -Name $VMName -ErrorAction Stop
if ([string]$vm.State -ne 'Off') { throw "VM 必须先关机：$VMName" }
$mounted = Mount-VHD -Path $VhdPath -Passthru -ErrorAction Stop
$hiveName = 'VMateDisplayAudit_' + ($VMName -replace '[^A-Za-z0-9_]', '_')
$hiveLoaded = $false
try {
    $disk = $mounted | Get-Disk
    $windowsRoot = $null
    foreach ($partition in @($disk | Get-Partition)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -eq $volume -or
            [String]::IsNullOrWhiteSpace([string]$volume.DriveLetter)) { continue }
        $candidate = ([string]$volume.DriveLetter) + ':\'
        if (Test-Path -LiteralPath (Join-Path $candidate `
                    'Windows\System32\Config\SOFTWARE') -PathType Leaf) {
            $windowsRoot = $candidate
            break
        }
    }
    if ($null -eq $windowsRoot) { throw "找不到 Windows 分区：$VhdPath" }
    $auditRoot = Join-Path $windowsRoot 'VMateAudit'
    [IO.Directory]::CreateDirectory($auditRoot) | Out-Null
    Copy-Item -LiteralPath $AuditScriptPath `
        -Destination (Join-Path $auditRoot 'Audit-VMateGuestDisplayStack.ps1') -Force
    $software = Join-Path $windowsRoot 'Windows\System32\Config\SOFTWARE'
    & reg.exe load "HKLM\$hiveName" $software | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "加载 SOFTWARE hive 失败：$hiveName" }
    $hiveLoaded = $true
    $runOnce = "Registry::HKEY_LOCAL_MACHINE\$hiveName\" +
        'Microsoft\Windows\CurrentVersion\RunOnce'
    [void](New-Item -Path $runOnce -Force)
    $command = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ' +
        '-File C:\VMateAudit\Audit-VMateGuestDisplayStack.ps1 ' +
        '-OutputPath C:\VMateAudit\display-stack.json'
    if (-not [String]::IsNullOrWhiteSpace($Endpoint)) {
        $command += ' -Endpoint ' + $Endpoint
    }
    [void](New-ItemProperty -Path $runOnce -Name 'VMateDisplayAuditOnce' `
            -Value $command -PropertyType String -Force)
}
finally {
    if ($hiveLoaded) {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        & reg.exe unload "HKLM\$hiveName" | Out-Null
    }
    Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue
}

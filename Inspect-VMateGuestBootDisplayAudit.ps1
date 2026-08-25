#Requires -Version 5.1

param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][string]$VhdPath,
    [string]$OutputRoot = 'C:\VMateLab'
)

$ErrorActionPreference = 'Stop'
$vm = Get-VM -Name $VMName -ErrorAction Stop
if ([string]$vm.State -ne 'Off') { throw "VM 必须先关机：$VMName" }
$mounted = Mount-VHD -Path $VhdPath -Passthru -ErrorAction Stop
$hiveName = 'VMateDisplayAuditInspect'
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
                    'Windows\System32\Config\SYSTEM') -PathType Leaf) {
            $windowsRoot = $candidate
            break
        }
    }
    if ($null -eq $windowsRoot) { throw "找不到 Windows 分区：$VhdPath" }
    $auditRoot = Join-Path $windowsRoot 'VMateAudit'
    $files = if (Test-Path -LiteralPath $auditRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $auditRoot -Force |
            Select-Object Name, Length, CreationTimeUtc, LastWriteTimeUtc,
                Attributes)
    } else { @() }
    $streams = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $auditRoot -File `
            -ErrorAction SilentlyContinue)) {
        $streams += @(Get-Item -LiteralPath $file.FullName -Stream * `
                -ErrorAction SilentlyContinue |
            Select-Object @{ Name = 'File'; Expression = { $file.Name } },
                Stream, Length)
    }

    $systemHive = Join-Path $windowsRoot 'Windows\System32\Config\SYSTEM'
    & reg.exe load "HKLM\$hiveName" $systemHive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '加载 SYSTEM hive 失败。' }
    $hiveLoaded = $true
    $select = Get-ItemProperty -LiteralPath `
        "Registry::HKEY_LOCAL_MACHINE\$hiveName\Select"
    $controlSet = 'ControlSet{0:D3}' -f [int]$select.Current
    $servicePath = "Registry::HKEY_LOCAL_MACHINE\$hiveName\" +
        "$controlSet\Services\VMateDisplayAuditOnce"
    $service = if (Test-Path -LiteralPath $servicePath) {
        Get-ItemProperty -LiteralPath $servicePath |
            Select-Object Type, Start, ErrorControl, ImagePath, DisplayName
    } else { $null }
    $eventRoot = Join-Path $windowsRoot 'Windows\System32\winevt\Logs'
    $eventCopies = [Collections.Generic.List[string]]::new()
    foreach ($name in @('System.evtx',
            'Microsoft-Windows-CodeIntegrity%4Operational.evtx')) {
        $source = Join-Path $eventRoot $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $destination = Join-Path $OutputRoot ($VMName + '-' + $name)
            Copy-Item -LiteralPath $source -Destination $destination -Force
            [void]$eventCopies.Add($destination)
        }
    }
    [pscustomobject][ordered]@{
        VMName = $VMName
        WindowsRoot = $windowsRoot
        AuditFiles = $files
        AuditFileStreams = $streams
        ServiceRegistration = $service
        EventLogs = @($eventCopies)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath `
        (Join-Path $OutputRoot ($VMName + '-boot-audit-inspect.json')) `
        -Encoding UTF8
}
finally {
    if ($hiveLoaded) {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        & reg.exe unload "HKLM\$hiveName" | Out-Null
    }
    Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue
}

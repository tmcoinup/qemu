#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# P-11 曾经在 Monitor class 下注册 ROOT\VMATEP11MONITOR 伪设备。该设备没有
# EDID、没有显示输出，也没有签名驱动；重复枚举时还会留下 Code 28 的历史节点。
# 新实现只负责离线清理这个旧格式。真实显示器身份必须由 active monitor 的
# Microsoft inbox monitor stack 与可回读的 EDID 提供；仅写无效注册表值不算完成，
# 也绝不再创建 VMate 命名的 PnP 节点。
$script:VMateLegacyGuestMonitorServiceName = 'VMateP11GuestProvisioner'
$script:VMateLegacyGuestMonitorRelativePath =
    'System32\VMate\VMateGuestMonitorProvisioner.exe'
$script:VMateLegacyGuestMonitorEnumRelativePath =
    'Enum\Root\VMATEP11MONITOR'

function Invoke-VMateGpuPOfflineSystemHive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SystemHivePath,
        [Parameter(Mandatory = $true)][scriptblock]$Operation
    )

    $mountName = 'VMateP11GuestSystem_' + [Guid]::NewGuid().ToString('N')
    $nativeName = "HKLM\$mountName"
    $providerRoot = "Registry::HKEY_LOCAL_MACHINE\$mountName"
    $reg = Join-Path $env:SystemRoot 'System32\reg.exe'
    $loadOutput = & $reg load $nativeName $SystemHivePath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "无法加载离线 Guest SYSTEM hive：$($loadOutput -join ' ')"
    }
    try {
        return & $Operation $providerRoot
    }
    finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        $unloaded = $false
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $unloadOutput = & $reg unload $nativeName 2>&1
            if ($LASTEXITCODE -eq 0) { $unloaded = $true; break }
            Start-Sleep -Milliseconds 100
        }
        if (-not $unloaded) {
            throw "无法卸载离线 Guest SYSTEM hive：$($unloadOutput -join ' ')"
        }
    }
}

function Get-VMateGpuPOfflineControlSets {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$HiveRoot)

    $select = Get-ItemProperty -LiteralPath (Join-Path $HiveRoot 'Select') `
        -ErrorAction Stop
    $numbers = @($select.Current, $select.Default, $select.LastKnownGood |
        Where-Object { $null -ne $_ -and [int]$_ -gt 0 } |
        ForEach-Object { [int]$_ } | Sort-Object -Unique)
    if ($numbers.Count -eq 0) {
        throw '离线 Guest SYSTEM hive 没有有效 ControlSet。'
    }
    return @($numbers | ForEach-Object { 'ControlSet{0:D3}' -f $_ })
}

function Remove-VMateGpuPLegacyGuestMonitorRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GuestWindowsRoot)

    $hive = Join-Path $GuestWindowsRoot 'System32\Config\SYSTEM'
    if (-not (Test-Path -LiteralPath $hive -PathType Leaf)) {
        throw "Guest SYSTEM hive 缺失：$hive"
    }
    return Invoke-VMateGpuPOfflineSystemHive -SystemHivePath $hive `
        -Operation {
        param($root)
        $removed = [Collections.Generic.List[string]]::new()
        $controlSets = @(Get-VMateGpuPOfflineControlSets -HiveRoot $root)
        foreach ($controlSet in $controlSets) {
            $targets = @(
                (Join-Path $root ("$controlSet\Services\" +
                        $script:VMateLegacyGuestMonitorServiceName)),
                (Join-Path $root ("$controlSet\" +
                        $script:VMateLegacyGuestMonitorEnumRelativePath))
            )
            foreach ($target in $targets) {
                if (Test-Path -LiteralPath $target) {
                    Remove-Item -LiteralPath $target -Recurse -Force `
                        -ErrorAction Stop
                    if (Test-Path -LiteralPath $target) {
                        throw "旧 P-11 Monitor 注册表项删除后仍存在：$target"
                    }
                    [void]$removed.Add($target.Substring($root.Length + 1))
                }
            }
        }
        return [pscustomobject][ordered]@{
            ControlSets = $controlSets
            Removed = @($removed)
        }
    }
}

function Remove-VMateGpuPLegacyGuestMonitorFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GuestWindowsRoot)

    $removed = [Collections.Generic.List[string]]::new()
    $windows = (Get-Item -LiteralPath $GuestWindowsRoot -Force `
        -ErrorAction Stop).FullName
    # .NET Framework 对 \\?\Volume{GUID}\Windows 的 GetPathRoot 可能返回空；
    # Windows 目录的已验证直接父级才是这里需要的卷根。
    $volumeRoot = [IO.Directory]::GetParent($windows).FullName
    $targets = @(
        (Join-Path $windows $script:VMateLegacyGuestMonitorRelativePath),
        (Join-Path $volumeRoot `
            'ProgramData\VMate\GuestProvisioner\monitor-status.json'),
        (Join-Path $volumeRoot `
            'ProgramData\VMate\GuestProvisioner\.monitor-status.tmp')
    )
    foreach ($target in $targets) {
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            Remove-Item -LiteralPath $target -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $target) {
                throw "旧 P-11 Monitor 文件删除后仍存在：$target"
            }
            [void]$removed.Add($target)
        }
    }
    return @($removed)
}

function Remove-VMateGpuPLegacyGuestMonitorArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GuestWindowsRoot,
        [switch]$DryRun
    )

    $root = (Get-Item -LiteralPath $GuestWindowsRoot -Force `
        -ErrorAction Stop).FullName
    if ($DryRun) {
        return [pscustomobject][ordered]@{
            Status = 'DryRun'
            LegacyServiceName = $script:VMateLegacyGuestMonitorServiceName
            LegacyGuestRelativePath =
                $script:VMateLegacyGuestMonitorRelativePath
            LegacyEnumPath = $script:VMateLegacyGuestMonitorEnumRelativePath
            CreatesMonitorDevice = $false
            GuestTestSigningRequired = $false
            GuestKernelDriverInstalled = $false
        }
    }
    $registry = Remove-VMateGpuPLegacyGuestMonitorRegistry `
        -GuestWindowsRoot $root
    $files = @(Remove-VMateGpuPLegacyGuestMonitorFiles `
            -GuestWindowsRoot $root)
    $changed = @($registry.Removed).Count -gt 0 -or $files.Count -gt 0
    return [pscustomobject][ordered]@{
        Status = if ($changed) { 'LegacyArtifactsRemoved' }
            else { 'AlreadyClean' }
        ControlSets = @($registry.ControlSets)
        RemovedRegistry = @($registry.Removed)
        RemovedFiles = $files
        CreatesMonitorDevice = $false
        IdentityPolicy = 'signed-inbox-monitor-with-validated-active-edid'
        GuestTestSigningRequired = $false
        GuestKernelDriverInstalled = $false
    }
}

# 保留旧函数名作为内部调用兼容层，但语义已经是“清理旧伪设备”。新代码应调用
# Remove-VMateGpuPLegacyGuestMonitorArtifacts。
function Install-VMateGpuPGuestMonitorProvisioner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GuestWindowsRoot,
        [switch]$DryRun
    )
    return Remove-VMateGpuPLegacyGuestMonitorArtifacts `
        -GuestWindowsRoot $GuestWindowsRoot -DryRun:$DryRun
}

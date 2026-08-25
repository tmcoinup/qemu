#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:VMateGuestMonitorServiceName = 'VMateP11GuestProvisioner'
$script:VMateGuestMonitorRelativePath =
    'System32\VMate\VMateGuestMonitorProvisioner.exe'

function Get-VMateGpuPGuestMonitorProvisionerSource {
    [CmdletBinding()]
    param()

    $source = Join-Path $PSScriptRoot `
        'native\bin\VMateGuestMonitorProvisioner.exe'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "P-11 Guest Monitor 配置器缺失：$source"
    }
    $resolved = (Get-Item -LiteralPath $source -Force -ErrorAction Stop).FullName
    if (Get-Command Get-VMateGpuPPeMachine -CommandType Function `
            -ErrorAction SilentlyContinue) {
        $pe = Get-VMateGpuPPeMachine -Path $resolved
        if ($pe.Architecture -cne 'x64') {
            throw "Guest Monitor 配置器不是 Windows x64 PE：$($pe.Machine)"
        }
    }
    return [pscustomobject][ordered]@{
        Path = $resolved
        SHA256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
    }
}

function Copy-VMateGpuPGuestMonitorProvisioner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GuestWindowsRoot,
        [Parameter(Mandatory = $true)][object]$Source
    )

    $directory = Join-Path $GuestWindowsRoot 'System32\VMate'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force `
                -ErrorAction Stop)
    }
    if (Get-Command Assert-VMateGpuPNoReparsePoint -CommandType Function `
            -ErrorAction SilentlyContinue) {
        Assert-VMateGpuPNoReparsePoint -Path $directory `
            -BoundaryRoot $GuestWindowsRoot
    }
    $destination = Join-Path $GuestWindowsRoot `
        $script:VMateGuestMonitorRelativePath
    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ieq
        [string]$Source.SHA256) {
        return [pscustomobject]@{ Path = $destination; Changed = $false }
    }
    $temporary = Join-Path $directory `
        ('.VMateGuestMonitorProvisioner.' +
            [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Copy-Item -LiteralPath ([string]$Source.Path) -Destination $temporary `
            -Force -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ine
            [string]$Source.SHA256) {
            throw 'Guest Monitor 配置器离线复制后哈希不一致。'
        }
        Move-Item -LiteralPath $temporary -Destination $destination -Force `
            -ErrorAction Stop
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine
        [string]$Source.SHA256) {
        throw 'Guest Monitor 配置器原子发布后哈希不一致。'
    }
    return [pscustomobject]@{ Path = $destination; Changed = $true }
}

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

function Set-VMateGpuPGuestMonitorOfflineService {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GuestWindowsRoot)

    $hive = Join-Path $GuestWindowsRoot 'System32\Config\SYSTEM'
    if (-not (Test-Path -LiteralPath $hive -PathType Leaf)) {
        throw "Guest SYSTEM hive 缺失：$hive"
    }
    return Invoke-VMateGpuPOfflineSystemHive -SystemHivePath $hive `
        -Operation {
        param($root)
        $select = Get-ItemProperty -LiteralPath (Join-Path $root 'Select') `
            -ErrorAction Stop
        $numbers = @($select.Current, $select.Default, $select.LastKnownGood |
            Where-Object { $null -ne $_ -and [int]$_ -gt 0 } |
            ForEach-Object { [int]$_ } | Sort-Object -Unique)
        if ($numbers.Count -eq 0) {
            throw '离线 Guest SYSTEM hive 没有有效 ControlSet。'
        }
        $configured = [Collections.Generic.List[string]]::new()
        foreach ($number in $numbers) {
            $controlSet = 'ControlSet{0:D3}' -f $number
            $service = Join-Path $root `
                "$controlSet\Services\$script:VMateGuestMonitorServiceName"
            [void](New-Item -Path $service -Force -ErrorAction Stop)
            $values = @{
                Type = @('DWord', 0x10)
                Start = @('DWord', 2)
                ErrorControl = @('DWord', 1)
                DelayedAutoStart = @('DWord', 0)
                DisplayName = @('String', 'VMate P-11 Guest Provisioner')
                Description = @('String',
                    'Ensures the P-11 virtual console Monitor class device.')
                ObjectName = @('String', 'LocalSystem')
                ImagePath = @('ExpandString',
                    ('"%SystemRoot%\{0}" --service' -f
                        $script:VMateGuestMonitorRelativePath))
                VMateContractId = @('String',
                    'vmate-p11-guest-monitor-service-v1')
            }
            foreach ($entry in $values.GetEnumerator()) {
                New-ItemProperty -LiteralPath $service -Name $entry.Key `
                    -PropertyType $entry.Value[0] -Value $entry.Value[1] `
                    -Force -ErrorAction Stop | Out-Null
            }
            [void]$configured.Add($controlSet)
        }
        return @($configured)
    }
}

function Install-VMateGpuPGuestMonitorProvisioner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GuestWindowsRoot,
        [switch]$DryRun
    )

    $root = (Get-Item -LiteralPath $GuestWindowsRoot -Force `
        -ErrorAction Stop).FullName
    $source = Get-VMateGpuPGuestMonitorProvisionerSource
    if ($DryRun) {
        return [pscustomobject][ordered]@{
            Status = 'DryRun'
            ServiceName = $script:VMateGuestMonitorServiceName
            SourceSHA256 = $source.SHA256
            GuestRelativePath = $script:VMateGuestMonitorRelativePath
            GuestTestSigningRequired = $false
            GuestKernelDriverInstalled = $false
        }
    }
    $copy = Copy-VMateGpuPGuestMonitorProvisioner `
        -GuestWindowsRoot $root -Source $source
    $controlSets = @(Set-VMateGpuPGuestMonitorOfflineService `
            -GuestWindowsRoot $root)
    return [pscustomobject][ordered]@{
        Status = if ($copy.Changed) { 'Provisioned' } else { 'UpToDate' }
        ServiceName = $script:VMateGuestMonitorServiceName
        Path = $copy.Path
        SHA256 = $source.SHA256
        ControlSets = $controlSets
        Startup = 'AutomaticLocalSystem'
        MonitorClass = '{4d36e96e-e325-11ce-bfc1-08002be10318}'
        GuestTestSigningRequired = $false
        GuestKernelDriverInstalled = $false
    }
}

#Requires -Version 5.1

param([string]$OutputRoot = 'C:\VMateLab\gpup-profile')

$ErrorActionPreference = 'Stop'
$targets = [ordered]@{
    pc01 = 'C:\vms\pc01.vhdx'
    pc02 = 'C:\vms\pc02.vhdx'
}
$rows = [Collections.Generic.List[object]]::new()

foreach ($entry in $targets.GetEnumerator()) {
    $vm = Get-VM -Name $entry.Key -ErrorAction Stop
    if ([string]$vm.State -ne 'Off') { throw "VM 必须先关机：$($entry.Key)" }
    $mounted = Mount-VHD -Path $entry.Value -Passthru -ErrorAction Stop
    $hiveName = 'VMateDetector_' + $entry.Key
    $hiveLoaded = $false
    try {
        $disk = $mounted | Get-Disk
        $windowsRoot = $null
        foreach ($partition in @($disk | Get-Partition)) {
            $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
            if ($null -eq $volume -or
                [String]::IsNullOrWhiteSpace([string]$volume.DriveLetter)) {
                continue
            }
            $candidate = ([string]$volume.DriveLetter) + ':\'
            if (Test-Path -LiteralPath (Join-Path $candidate `
                        'Windows\System32\Config\SOFTWARE') -PathType Leaf) {
                $windowsRoot = $candidate
                break
            }
        }
        if ($null -eq $windowsRoot) {
            throw "找不到 Windows 分区：$($entry.Value)"
        }
        $auditRoot = Join-Path $windowsRoot 'VMateAudit'
        $source = Join-Path $auditRoot 'live-detector.json'
        $destination = Join-Path $OutputRoot `
            ("live-detector-$($entry.Key).json")
        $result = $null
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination $destination -Force
            $result = Get-Content -LiteralPath $source -Raw -Encoding UTF8 |
                ConvertFrom-Json -ErrorAction Stop
        }

        $software = Join-Path $windowsRoot `
            'Windows\System32\Config\SOFTWARE'
        & reg.exe load "HKLM\$hiveName" $software | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "加载 SOFTWARE hive 失败：$hiveName" }
        $hiveLoaded = $true
        $runOnce = "Registry::HKEY_LOCAL_MACHINE\$hiveName\" +
            'Microsoft\Windows\CurrentVersion\RunOnce'
        Remove-ItemProperty -Path $runOnce -Name 'VMateDetectorOnce' `
            -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $auditRoot -PathType Container) {
            Remove-Item -LiteralPath $auditRoot -Recurse -Force
        }
        [void]$rows.Add([pscustomobject][ordered]@{
                VMName = $entry.Key
                Found = $null -ne $result
                Verdict = if ($null -eq $result) { '' } else {
                    [string]$result.Verdict
                }
                Functional = if ($null -eq $result) { -1 } else {
                    [int]$result.FunctionalGpuPSignalCount
                }
                Intrinsic = if ($null -eq $result) { -1 } else {
                    [int]$result.IntrinsicGpuPSignalCount
                }
                Artifacts = if ($null -eq $result) { -1 } else {
                    [int]$result.ArtifactExposureSignalCount
                }
                OutputPath = if ($null -eq $result) { '' } else { $destination }
            })
    }
    finally {
        if ($hiveLoaded) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            & reg.exe unload "HKLM\$hiveName" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "卸载 SOFTWARE hive 失败：$hiveName"
            }
        }
        Dismount-VHD -Path $entry.Value -ErrorAction SilentlyContinue
    }
}

@($rows) | ConvertTo-Json -Depth 5

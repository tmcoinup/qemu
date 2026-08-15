#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VMateGpuPPeMachine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).FullName
    $stream = [IO.File]::Open($resolved, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) {
            throw "文件不是有效 PE 映像（缺少 MZ）：$resolved"
        }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -lt 64 -or [uint64]$peOffset + 6 -gt [uint64]$stream.Length) {
            throw "PE header 偏移越界：$resolved"
        }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "文件不是有效 PE 映像（缺少 PE signature）：$resolved"
        }
        $machine = $reader.ReadUInt16()
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }

    $architecture = switch ($machine) {
        0x8664 { 'x64' }
        0xAA64 { 'arm64' }
        0x014C { 'x86' }
        default { 'unknown' }
    }
    return [pscustomobject][ordered]@{
        Path = $resolved
        Machine = ('0x{0:X4}' -f $machine)
        MachineValue = [uint16]$machine
        Architecture = $architecture
    }
}

function Assert-VMateGpuPGuestWindowsImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GuestWindowsRoot
    )

    $root = (Get-Item -LiteralPath $GuestWindowsRoot -Force `
        -ErrorAction Stop).FullName
    $kernel = Join-Path $root 'System32\ntoskrnl.exe'
    $systemHive = Join-Path $root 'System32\Config\SYSTEM'
    $driverStore = Join-Path $root 'System32\DriverStore'
    foreach ($required in @($kernel, $systemHive, $driverStore)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "离线 guest 不是完整的 Windows 系统卷，缺少：$required"
        }
        if (Get-Command -Name Assert-VMateGpuPNoReparsePoint `
                -CommandType Function -ErrorAction SilentlyContinue) {
            Assert-VMateGpuPNoReparsePoint -Path $required -BoundaryRoot $root
        }
    }

    $pe = Get-VMateGpuPPeMachine -Path $kernel
    if ($pe.Architecture -cne 'x64') {
        throw ("GPU-P HostDriverStore 同步只支持 x64 Windows guest；" +
            "检测到 $($pe.Architecture) ($($pe.Machine))。")
    }
    $nativeArchitecture = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else { $env:PROCESSOR_ARCHITECTURE }
    if (-not [Environment]::Is64BitOperatingSystem -or
        ($env:OS -eq 'Windows_NT' -and $nativeArchitecture -ine 'AMD64')) {
        throw 'GPU-P Windows 宿主必须是 x64。'
    }

    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($kernel)
    $kernelVersion = if (-not [String]::IsNullOrWhiteSpace($version.FileVersion)) {
        [string]$version.FileVersion
    }
    else {
        '{0}.{1}.{2}.{3}' -f $version.FileMajorPart,
            $version.FileMinorPart, $version.FileBuildPart,
            $version.FilePrivatePart
    }
    return [pscustomobject][ordered]@{
        WindowsRoot = $root
        Architecture = $pe.Architecture
        PeMachine = $pe.Machine
        KernelVersion = $kernelVersion
        BuildCompatibilityPolicy = 'Windows builds may differ; validate vendor UMD with D3D in guest'
    }
}

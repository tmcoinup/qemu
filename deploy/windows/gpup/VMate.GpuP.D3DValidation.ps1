#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-VMateGpuPD3D11ProbeType {
    [CmdletBinding()]
    param()

    if ($null -ne ('VMate.GpuP.D3D11HardwareProbe' -as [type])) {
        return
    }
    $source = @'
using System;
using System.Runtime.InteropServices;

namespace VMate.GpuP
{
    public static class D3D11HardwareProbe
    {
        private const uint D3D_DRIVER_TYPE_HARDWARE = 1;
        private const uint D3D11_SDK_VERSION = 7;

        [DllImport("d3d11.dll", CallingConvention = CallingConvention.StdCall)]
        private static extern int D3D11CreateDevice(
            IntPtr adapter,
            uint driverType,
            IntPtr software,
            uint flags,
            IntPtr featureLevels,
            uint featureLevelCount,
            uint sdkVersion,
            out IntPtr device,
            out uint selectedFeatureLevel,
            out IntPtr immediateContext);

        public static int Create(
            out uint featureLevel,
            out IntPtr device,
            out IntPtr immediateContext)
        {
            device = IntPtr.Zero;
            immediateContext = IntPtr.Zero;
            featureLevel = 0;
            return D3D11CreateDevice(
                IntPtr.Zero,
                D3D_DRIVER_TYPE_HARDWARE,
                IntPtr.Zero,
                0,
                IntPtr.Zero,
                0,
                D3D11_SDK_VERSION,
                out device,
                out featureLevel,
                out immediateContext);
        }

        public static void Release(IntPtr device, IntPtr immediateContext)
        {
            if (immediateContext != IntPtr.Zero)
            {
                Marshal.Release(immediateContext);
            }
            if (device != IntPtr.Zero)
            {
                Marshal.Release(device);
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function Invoke-VMateGpuPD3D11HardwareProbe {
    [CmdletBinding()]
    param()

    if ($env:OS -cne 'Windows_NT') {
        throw 'Direct3D 11 hardware probe 只能在 Windows guest 运行。'
    }
    Initialize-VMateGpuPD3D11ProbeType
    [uint32]$featureLevel = 0
    [IntPtr]$device = [IntPtr]::Zero
    [IntPtr]$context = [IntPtr]::Zero
    try {
        $hresult = [VMate.GpuP.D3D11HardwareProbe]::Create(
            [ref]$featureLevel, [ref]$device, [ref]$context)
        if ($hresult -lt 0) {
            $unsigned = [BitConverter]::ToUInt32(
                [BitConverter]::GetBytes([int32]$hresult), 0)
            throw ('D3D11 hardware device 创建失败，HRESULT=0x{0:X8}。' -f $unsigned)
        }
        if ($featureLevel -lt 0xA000) {
            throw ('D3D11 hardware feature level 低于 10_0：0x{0:X4}' -f $featureLevel)
        }

        # device/context 仍存活时查看当前 pwsh 进程模块。这是
        # D3D11CreateDevice 实际加载的 UMD，不是 DriverStore 中任意旧 DLL。
        $process = [Diagnostics.Process]::GetCurrentProcess()
        try {
            $loadedModulePaths = @($process.Modules | ForEach-Object {
                    [string]$_.FileName
                } | Where-Object {
                    -not [String]::IsNullOrWhiteSpace($_)
                } | Sort-Object -Unique)
        }
        finally {
            $process.Dispose()
        }
        $label = switch ($featureLevel) {
            0xC200 { '12_2' }
            0xC100 { '12_1' }
            0xC000 { '12_0' }
            0xB100 { '11_1' }
            0xB000 { '11_0' }
            0xA100 { '10_1' }
            0xA000 { '10_0' }
            default { '0x{0:X4}' -f $featureLevel }
        }
        return [pscustomobject][ordered]@{
            Passed = $true
            DriverType = 'Hardware'
            WarpFallbackAllowed = $false
            FeatureLevel = $label
            FeatureLevelValue = $featureLevel
            HResult = $hresult
            LoadedModulePaths = $loadedModulePaths
        }
    }
    finally {
        [VMate.GpuP.D3D11HardwareProbe]::Release($device, $context)
    }
}

function Assert-VMateGpuPD3DLoadedVendorModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$ProbeResult,
        [Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD')][string]$Vendor,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    $property = $ProbeResult.PSObject.Properties['LoadedModulePaths']
    if ($null -eq $property) {
        throw 'D3D11 probe 没有返回 device 存活期的已加载模块。'
    }
    $pattern = if ($Vendor -ieq 'NVIDIA') {
        '(?i)^nvwgf2umx?\.dll$'
    }
    else {
        '(?i)^(?:atidxx(?:32|64)|amdxx(?:32|64))\.dll$'
    }
    $candidates = @($property.Value | Where-Object {
            -not [String]::IsNullOrWhiteSpace([string]$_) -and
            [IO.Path]::GetFileName([string]$_) -match $pattern
        } | Sort-Object -Unique)
    if ($candidates.Count -eq 0) {
        throw "D3D11 hardware device 未在当前 pwsh 进程加载 $Vendor D3D UMD。"
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $candidates) {
        try {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw '已加载模块路径不可读'
            }
            [void](Assert-VMateGpuPSignedBinary -Path $path -Publisher $Vendor)
            $version = [string](Get-Item -LiteralPath $path `
                    -ErrorAction Stop).VersionInfo.FileVersion
            $version = $version -replace '[,\s]', ''
            if (-not $version -or -not (Test-VMateGpuPVersionMatch `
                    $version $ExpectedVersion $Vendor)) {
                throw "版本 $version 与期望 $ExpectedVersion 不一致"
            }
            $ProbeResult | Add-Member -NotePropertyName LoadedVendorModule `
                -NotePropertyValue ([pscustomobject][ordered]@{
                    Path = [string]$path
                    FileName = [IO.Path]::GetFileName([string]$path)
                    Version = $version
                    Vendor = $Vendor
                }) -Force
            return $ProbeResult
        }
        catch {
            [void]$failures.Add("$path：$($_.Exception.Message)")
        }
    }
    throw ("D3D11 实际加载的 $Vendor UMD 未通过签名/版本校验：" +
        ($failures -join '；'))
}

function Assert-VMateGpuPVendorApiFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD')][string]$Vendor)

    # NVAPI 与 ADL 都只允许目标厂商的官方签名文件。另一厂商
    # 的 API DLL 在干净新镜像中属于旧驱动/投影残留，必须拒绝。
    Assert-VMateGpuPNoNvapiShim $Vendor
    $adlPaths = @(@(
            (Join-Path $env:windir 'System32\atiadlxx.dll'),
            (Join-Path $env:windir 'SysWOW64\atiadlxy.dll'),
            (Join-Path $env:windir 'SysWOW64\atiadlxx.dll')
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($Vendor -ieq 'NVIDIA' -and $adlPaths.Count -gt 0) {
        throw 'NVIDIA guest 中发现 AMD ADL 文件；拒绝异厂驱动或 shim 残留。'
    }
    foreach ($path in $adlPaths) {
        [void](Assert-VMateGpuPSignedBinary -Path $path -Publisher AMD)
    }
}

function Invoke-VMateNvidiaSmiValidation {
    param([Parameter(Mandatory = $true)][string]$ExpectedName,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [switch]$Required)
    $command = Get-Command -Name nvidia-smi.exe -CommandType Application `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        if ($Required) {
            throw '要求验证 nvidia-smi，但 guest 中不存在官方 nvidia-smi.exe。'
        }
        return $null
    }
    [void](Assert-VMateGpuPSignedBinary ([string]$command.Source) NVIDIA)
    $output = @(& $command.Source `
            '--query-gpu=name,driver_version,uuid' `
            '--format=csv,noheader,nounits' 2>&1)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) {
        throw "nvidia-smi 未返回唯一 GPU：$($output -join '; ')"
    }
    $fields = [string]$output[0] -split '\s*,\s*', 3
    if ($fields.Count -ne 3 -or
        -not $fields[0].Trim().Equals($ExpectedName,
            [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-VMateGpuPVersionMatch $fields[1] $ExpectedVersion NVIDIA)) {
        throw "nvidia-smi 型号/版本与宿主期望不一致：$($output[0])"
    }
    # 消费卡可能不实现 serial/memory.total；都只作单独的尽力观察，
    # 绝不伪造字段，也不用显存观察值声称物理显存独占。
    $serialOutput = @(& $command.Source '--query-gpu=serial' `
            '--format=csv,noheader,nounits' 2>&1)
    $serial = if ($LASTEXITCODE -eq 0 -and $serialOutput.Count -eq 1 -and
        ([string]$serialOutput[0]).Trim() -notmatch
            '^(?i)(N/?A|Not Supported|)$') {
        ([string]$serialOutput[0]).Trim()
    } else { $null }
    $memoryOutput = @()
    $memoryExitCode = -1
    try {
        $memoryOutput = @(& $command.Source '--query-gpu=memory.total' `
                '--format=csv,noheader,nounits' 2>&1)
        $memoryExitCode = $LASTEXITCODE
    } catch { $memoryOutput = @() }
    [uint64]$memoryMiB = 0
    $reportedMemoryMiB = if ($memoryExitCode -eq 0 -and
        $memoryOutput.Count -eq 1 -and [uint64]::TryParse(
            ([string]$memoryOutput[0]).Trim(), [ref]$memoryMiB)) {
        $memoryMiB
    } else { $null }
    return [pscustomobject]@{
        Name = $fields[0].Trim()
        DriverVersion = $fields[1].Trim()
        Uuid = if ($fields[2].Trim() -match '^(?i)(N/?A|Not Supported|)$') {
            $null
        } else { $fields[2].Trim() }
        Serial = $serial
        ReportedMemoryTotalMiB = $reportedMemoryMiB
    }
}

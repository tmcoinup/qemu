#Requires -Version 5.1
<#
.SYNOPSIS
    在 Windows guest 内检测当前显卡是否处于 Hyper-V GPU-P（半虚拟化 / vGPU-P）环境。

.DESCRIPTION
    纯用户态、只读、无副作用。分层采集证据并给出总判定：

      Bare-Metal      未见虚拟化痕迹（裸机或整卡直通，显卡为真实 PCI 设备）
      GPU-P           在 Hyper-V VM 内且显卡为半虚拟化适配器
      VM-NoGpuP       在 VM 内但未检出 GPU-P 显卡（可能仅 Hyper-V Video / WARP）
      Inconclusive    证据不足以判定

    判定不依赖 GPU 型号、驱动版本或设备 ID 白名单，只依赖架构性特征。

.PARAMETER Json
    以 JSON 输出结构化结果（并跳过结尾暂停），便于接入自检流水线。

.PARAMETER NoPause
    正常输出后不暂停等待按键（在已打开的窗口里连续运行时用）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Detect-VGpuP.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Detect-VGpuP.ps1 -Json
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$NoPause,
    [string]$OutputPath = ''
)

# 关键：不设置全局 Stop，避免任一非核心查询抛异常导致整脚本秒退。
# 不启用 StrictMode，避免访问不存在的属性触发终止错误。
$ErrorActionPreference = 'Continue'

function Test-PhysicalPciLocationInfo {
    param([AllowEmptyString()][string]$Value)

    # DEVPKEY_Device_LocationInfo 的真实 PCI 位置必须同时包含总线、设备和功能号。
    # “Virtual PCI Bus Slot ...” 只是 Hyper-V vPCI 文本，不能按含有 “PCI Bus”
    # 就误判成物理 PCI 拓扑。兼容英文和简体中文系统的 inbox 表述。
    return $Value -match (
        '(?ix)^\s*PCI\s*(?:' +
        'bus\s+\d+\s*,\s*device\s+\d+\s*,\s*function\s+\d+|' +
        '总线\s*\d+\s*[,，、]\s*设备\s*\d+\s*[,，、]\s*功能\s*\d+' +
        ')\s*$')
}

function Invoke-VGpuPDetection {

    $signals = [System.Collections.Generic.List[object]]::new()
    function Add-Signal {
        param(
            [ValidateSet('Hypervisor', 'Display', 'D3DKMT')][string]$Layer,
            [string]$Name,
            [bool]$Hit,
            [string]$Detail = ''
        )
        [void]$signals.Add([pscustomobject]@{
                Layer = $Layer; Name = $Name; Hit = $Hit; Detail = $Detail
            })
    }

    # -----------------------------------------------------------------------
    # 第 1 层：虚拟化 / Hyper-V（GPU-P 的前置条件；非 GPU-P 独有）
    # -----------------------------------------------------------------------
    $inVM = $false
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $isHvModel = ("$($cs.Manufacturer)" -match 'Microsoft' -and "$($cs.Model)" -match 'Virtual Machine')
        if ($isHvModel) { $inVM = $true }
        Add-Signal Hypervisor 'ComputerSystem=Microsoft/Virtual Machine' $isHvModel `
        ("{0} / {1}" -f $cs.Manufacturer, $cs.Model)
    } catch {
        Add-Signal Hypervisor 'Win32_ComputerSystem' $false "查询失败: $($_.Exception.Message)"
    }

    try {
        $guestKey = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters'
        $hasGuestKey = Test-Path -LiteralPath $guestKey
        if ($hasGuestKey) { $inVM = $true }
        Add-Signal Hypervisor 'HyperV Guest\Parameters 注册表键' $hasGuestKey $guestKey
    } catch {
        Add-Signal Hypervisor 'HyperV Guest\Parameters' $false "查询失败: $($_.Exception.Message)"
    }

    try {
        $vmbus = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
                Where-Object { "$($_.PNPDeviceID)" -like 'VMBUS\*' })
        $hasVmbus = $vmbus.Count -gt 0
        if ($hasVmbus) { $inVM = $true }
        Add-Signal Hypervisor 'VMBus 设备节点' $hasVmbus ("节点数: {0}" -f $vmbus.Count)
    } catch {
        Add-Signal Hypervisor 'VMBus 设备节点' $false "查询失败: $($_.Exception.Message)"
    }

    # -----------------------------------------------------------------------
    # 第 2 层：显示适配器（GPU-P 的决定性证据）
    # -----------------------------------------------------------------------

    # 2a. HostDriverStore —— 裸机 Windows 不存在此目录，只有 GPU-PV guest 才有
    $hostStore = Join-Path $env:windir 'System32\HostDriverStore\FileRepository'
    $hasHostStore = Test-Path -LiteralPath $hostStore -PathType Container
    Add-Signal Display 'HostDriverStore\FileRepository 存在' $hasHostStore $hostStore

    # 2b. 目标显卡的 PnP 实例路径是否为真实 PCI 设备
    $gpuIsNonPci = $false
    $gpuDisplayName = ''
    try {
        $displays = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
                Where-Object {
                    "$($_.PNPClass)" -eq 'Display' -and "$($_.Name)" -and
                    "$($_.Name)" -notmatch 'Microsoft Hyper-V Video' -and
                    "$($_.Name)" -notmatch 'Microsoft Basic Display'
                })
        $iddPattern = '(?i)Virtual Display|Indirect Display|IddCx|GameViewer|Parsec|Sunshine|DisplayLink|USB Display|Meridian'
        foreach ($d in $displays) {
            $id = "$($d.PNPDeviceID)"
            $name = "$($d.Name)"
            $isPci = $id -match '(?i)^PCI\\VEN_[0-9A-F]{4}&DEV_'
            if ($name -match $iddPattern) {
                # IDD 虚拟显示器（如 GameViewer）：负责远程串流，不是 GPU-P 分区，不计入判定
                Add-Signal Display ("IDD 虚拟显示器 [{0}] (非GPU-P)" -f $name) $false $id
                continue
            }
            if (-not $isPci) { $gpuIsNonPci = $true; $gpuDisplayName = $name }
            Add-Signal Display ("显卡 PnP 路径非 PCI [{0}]" -f $name) (-not $isPci) $id
        }
        if ($displays.Count -eq 0) {
            Add-Signal Display '存在厂商显示适配器' $false '未枚举到 Hyper-V Video 之外的显示设备'
        }
    } catch {
        Add-Signal Display '显卡 PnP 枚举' $false "查询失败: $($_.Exception.Message)"
    }

    # 2c. 缺失 PCI 位置信息（裸机/直通 = "PCI bus N, device N, function N"）
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        try {
            foreach ($d in @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
                        Where-Object { "$($_.FriendlyName)" -notmatch 'Hyper-V Video' -and
                            "$($_.FriendlyName)" -notmatch 'Basic Display' })) {
                $loc = Get-PnpDeviceProperty -InstanceId $d.InstanceId `
                    -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue
                $val = if ($loc) { "$($loc.Data)" } else { '' }
                $missing = -not (Test-PhysicalPciLocationInfo $val)
                Add-Signal Display ("显卡缺失 PCI 位置信息 [{0}]" -f $d.FriendlyName) $missing `
                ("LocationInfo='{0}'" -f $val)
            }
        } catch {
            Add-Signal Display '显卡 PCI 位置信息' $false "查询失败: $($_.Exception.Message)"
        }
    }

    # 2d. UMD 驱动路径落在 HostDriverStore
    try {
        $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        $umdInHostStore = $false
        foreach ($sub in @(Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -match '^\d{4}$' })) {
            $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
            $idd = ''
            if ($p -and ($p.PSObject.Properties.Name -contains 'InstalledDisplayDrivers')) {
                $idd = ([string[]]$p.InstalledDisplayDrivers) -join ';'
            }
            if ($idd -match '(?i)HostDriverStore') {
                $umdInHostStore = $true
                $desc = if ($p.PSObject.Properties.Name -contains 'DriverDesc') { "$($p.DriverDesc)" } else { '' }
                Add-Signal Display ("UMD 指向 HostDriverStore [{0}]" -f $desc) $true $idd
            }
        }
        if (-not $umdInHostStore) {
            Add-Signal Display 'UMD 指向 HostDriverStore' $false '未发现指向 HostDriverStore 的显示驱动条目'
        }
    } catch {
        Add-Signal Display 'UMD 驱动路径' $false "查询失败: $($_.Exception.Message)"
    }

    # -----------------------------------------------------------------------
    # 第 3 层：D3DKMT ADAPTERTYPE.Paravirtualized（微软官方 API 位，最干净）
    # -----------------------------------------------------------------------
    $paravirtFlag = $null   # $true / $false / $null(未测得)
    try {
        if ($null -eq ('VMate.VGpuP.D3DKmtProbe' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace VMate.VGpuP
{
    public static class D3DKmtProbe
    {
        [StructLayout(LayoutKind.Sequential)]
        struct LUID { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)]
        struct D3DKMT_QUERYADAPTERINFO
        { public uint hAdapter; public uint Type; public IntPtr pData; public uint DataSize; }
        [StructLayout(LayoutKind.Sequential)]
        struct D3DKMT_CLOSEADAPTER { public uint hAdapter; }
        [StructLayout(LayoutKind.Sequential)]
        struct D3DKMT_ADAPTERTYPE { public uint Value; }
        [StructLayout(LayoutKind.Sequential)]
        struct D3DKMT_ENUMADAPTERS2 { public uint NumAdapters; public IntPtr pAdapters; }
        [StructLayout(LayoutKind.Sequential)]
        struct D3DKMT_ADAPTERINFO
        {
            public uint hAdapter; public LUID AdapterLuid;
            public uint NumOfSources; public uint bPrecisePresentRegionsPreferred;
        }
        const uint KMTQAITYPE_ADAPTERTYPE = 15;
        // WDK d3dkmthk.h：D3DKMT_ADAPTERTYPE 位域（bit0 起，LSB）：
        //   bit6 = IndirectDisplayDevice, bit7 = Paravirtualized, bit8 = ACGSupported
        const uint INDIRECTDISPLAY_BIT = 1u << 6;
        const uint PARAVIRTUALIZED_BIT = 1u << 7; // 修正：之前误用 bit8(ACGSupported) 造成假阳性

        [DllImport("gdi32.dll")] static extern int D3DKMTEnumAdapters2(ref D3DKMT_ENUMADAPTERS2 p);
        [DllImport("gdi32.dll")] static extern int D3DKMTQueryAdapterInfo(ref D3DKMT_QUERYADAPTERINFO p);
        [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(ref D3DKMT_CLOSEADAPTER p);

        // 返回：-1 未测得；否则为命中的 Paravirtualized 适配器数量。
        // out total = 适配器总数；out idd = IndirectDisplayDevice(IDD/虚拟显示器) 数量。
        public static int CountParavirtualized(out int total, out int idd)
        {
            total = 0; idd = 0;
            int stride = Marshal.SizeOf(typeof(D3DKMT_ADAPTERINFO));
            var e = new D3DKMT_ENUMADAPTERS2();
            if (D3DKMTEnumAdapters2(ref e) != 0) return -1;
            if (e.NumAdapters == 0) return 0;
            IntPtr buf = Marshal.AllocHGlobal((int)e.NumAdapters * stride);
            try
            {
                e.pAdapters = buf;
                if (D3DKMTEnumAdapters2(ref e) != 0) return -1;
                total = (int)e.NumAdapters;
                int hits = 0;
                for (int i = 0; i < e.NumAdapters; i++)
                {
                    var ai = (D3DKMT_ADAPTERINFO)Marshal.PtrToStructure(
                        (IntPtr)(buf.ToInt64() + (long)i * stride), typeof(D3DKMT_ADAPTERINFO));
                    var at = new D3DKMT_ADAPTERTYPE();
                    IntPtr atBuf = Marshal.AllocHGlobal(Marshal.SizeOf(at));
                    try
                    {
                        Marshal.StructureToPtr(at, atBuf, false);
                        var q = new D3DKMT_QUERYADAPTERINFO {
                            hAdapter = ai.hAdapter, Type = KMTQAITYPE_ADAPTERTYPE,
                            pData = atBuf, DataSize = (uint)Marshal.SizeOf(at) };
                        if (D3DKMTQueryAdapterInfo(ref q) == 0)
                        {
                            var got = (D3DKMT_ADAPTERTYPE)Marshal.PtrToStructure(atBuf, typeof(D3DKMT_ADAPTERTYPE));
                            if ((got.Value & PARAVIRTUALIZED_BIT) != 0) hits++;
                            if ((got.Value & INDIRECTDISPLAY_BIT) != 0) idd++;
                        }
                    }
                    finally { Marshal.FreeHGlobal(atBuf); }
                    var c = new D3DKMT_CLOSEADAPTER { hAdapter = ai.hAdapter };
                    D3DKMTCloseAdapter(ref c);
                }
                return hits;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
    }
}
'@ -ErrorAction Stop
        }
        $total = 0; $idd = 0
        $hits = [VMate.VGpuP.D3DKmtProbe]::CountParavirtualized([ref]$total, [ref]$idd)
        if ($hits -lt 0) {
            Add-Signal D3DKMT 'D3DKMT_ADAPTERTYPE.Paravirtualized' $false 'D3DKMT 查询未成功(未测得)'
        } else {
            $paravirtFlag = ($hits -gt 0)
            Add-Signal D3DKMT 'D3DKMT_ADAPTERTYPE.Paravirtualized' $paravirtFlag `
            ("Paravirtualized 适配器 {0}/{1}" -f $hits, $total)
            if ($idd -gt 0) {
                Add-Signal D3DKMT 'IndirectDisplayDevice(IDD 虚拟显示器)' $false `
                ("IDD 适配器 {0}/{1}（远程串流，非 GPU-P）" -f $idd, $total)
            }
        }
    } catch {
        Add-Signal D3DKMT 'D3DKMT_ADAPTERTYPE.Paravirtualized' $false "探针不可用: $($_.Exception.Message)"
    }

    # -----------------------------------------------------------------------
    # 总判定
    # -----------------------------------------------------------------------
    $hypervisorExposure = @($signals | Where-Object {
            $_.Hit -and $_.Layer -eq 'Hypervisor'
        }).Count
    $displayExposure = @($signals | Where-Object {
            $_.Hit -and $_.Layer -eq 'Display'
        }).Count
    $intrinsicGpuP = @($signals | Where-Object {
            $_.Hit -and $_.Layer -eq 'D3DKMT'
        }).Count
    # 保留原 GpuPSignalCount 语义，便于与旧结果和样例做同口径回归；
    # 同时单独报告虚拟化痕迹，禁止用功能阳性数量掩盖痕迹差距。
    $gpupPositive = $displayExposure + $intrinsicGpuP
    $artifactExposure = $hypervisorExposure + $displayExposure
    $totalPositive = $artifactExposure + $intrinsicGpuP

    if (($paravirtFlag -eq $true) -or $hasHostStore -or $gpuIsNonPci) {
        $verdict = 'GPU-P'
    } elseif ($inVM) {
        $verdict = 'VM-NoGpuP'
    } elseif ($gpupPositive -eq 0) {
        $verdict = 'Bare-Metal'
    } else {
        $verdict = 'Inconclusive'
    }

    [pscustomobject]@{
        Verdict          = $verdict
        InVirtualMachine = $inVM
        HostDriverStore  = $hasHostStore
        GpuNonPciPath    = $gpuIsNonPci
        ParavirtAdapter  = $paravirtFlag
        GpuName          = $gpuDisplayName
        GpuPSignalCount              = $gpupPositive
        FunctionalGpuPSignalCount    = $gpupPositive
        IntrinsicGpuPSignalCount     = $intrinsicGpuP
        HypervisorExposureSignalCount = $hypervisorExposure
        DisplayExposureSignalCount   = $displayExposure
        ArtifactExposureSignalCount  = $artifactExposure
        TotalPositiveSignalCount     = $totalPositive
        Signals                      = $signals
    }
}

# ============================ 入口（防崩壳） ============================
$exitCode = 0
try {
    $result = Invoke-VGpuPDetection

    if ($Json) {
        $jsonOutput = $result | ConvertTo-Json -Depth 5
        if (-not [String]::IsNullOrWhiteSpace($OutputPath)) {
            $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
            $parent = [IO.Path]::GetDirectoryName($resolvedOutput)
            if (-not [IO.Directory]::Exists($parent)) {
                throw "输出目录不存在: $parent"
            }
            [IO.File]::WriteAllText($resolvedOutput, $jsonOutput,
                (New-Object Text.UTF8Encoding($true)))
        }
        Write-Output $jsonOutput
    } else {
        Write-Host ''
        Write-Host '==== vGPU-P 环境检测 ====' -ForegroundColor Cyan
        foreach ($grp in ($result.Signals | Group-Object Layer)) {
            Write-Host ("[{0}]" -f $grp.Name) -ForegroundColor DarkCyan
            foreach ($s in $grp.Group) {
                $mark = if ($s.Hit) { '[+]' } else { '[ ]' }
                $color = if ($s.Hit) { 'Yellow' } else { 'DarkGray' }
                Write-Host ("  {0} {1}" -f $mark, $s.Name) -ForegroundColor $color
                if ($s.Detail) { Write-Host ("      {0}" -f $s.Detail) -ForegroundColor DarkGray }
            }
        }
        Write-Host ''
        $vColor = switch ($result.Verdict) {
            'GPU-P' { 'Green' } 'Bare-Metal' { 'Gray' }
            'VM-NoGpuP' { 'Yellow' } default { 'Red' }
        }
        Write-Host ("判定: {0}" -f $result.Verdict) -ForegroundColor $vColor
        Write-Host ("  在虚拟机内       : {0}" -f $result.InVirtualMachine)
        Write-Host ("  HostDriverStore  : {0}" -f $result.HostDriverStore)
        Write-Host ("  显卡非PCI路径    : {0}" -f $result.GpuNonPciPath)
        $pv = if ($null -eq $result.ParavirtAdapter) { '未测得' } else { $result.ParavirtAdapter }
        Write-Host ("  Paravirt适配器   : {0}" -f $pv)
        Write-Host ("  GPU-P功能信号    : {0}" -f $result.FunctionalGpuPSignalCount)
        Write-Host ("  虚拟化痕迹信号   : {0}" -f $result.ArtifactExposureSignalCount)
        Write-Host ''
    }
} catch {
    $exitCode = 1
    Write-Host ''
    Write-Host '脚本执行出错:' -ForegroundColor Red
    Write-Host ("  {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("  位置: {0}" -f $_.InvocationInfo.PositionMessage) -ForegroundColor DarkGray
} finally {
    if (-not $Json -and -not $NoPause) {
        Write-Host '按 Enter 键退出...' -ForegroundColor DarkGray
        try { [void][System.Console]::ReadLine() } catch { }
    }
}
exit $exitCode

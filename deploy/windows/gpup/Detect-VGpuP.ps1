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
    以 JSON 输出结构化结果，便于接入自检流水线。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Detect-VGpuP.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Detect-VGpuP.ps1 -Json
#>
[CmdletBinding()]
param(
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$signals = [System.Collections.Generic.List[object]]::new()
function Add-Signal {
    param(
        [Parameter(Mandatory)][ValidateSet('Hypervisor', 'Display', 'D3DKMT')][string]$Layer,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Hit,
        [string]$Detail = ''
    )
    [void]$signals.Add([pscustomobject]@{
            Layer  = $Layer
            Name   = $Name
            Hit    = $Hit
            Detail = $Detail
        })
}

# ---------------------------------------------------------------------------
# 第 1 层：虚拟化 / Hyper-V（GPU-P 的前置条件；非 GPU-P 独有）
# ---------------------------------------------------------------------------
$inVM = $false
try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $isHvModel = ($cs.Manufacturer -match 'Microsoft' -and $cs.Model -match 'Virtual Machine')
    if ($isHvModel) { $inVM = $true }
    Add-Signal Hypervisor 'Win32_ComputerSystem=Microsoft/Virtual Machine' $isHvModel `
        ("{0} / {1}" -f $cs.Manufacturer, $cs.Model)
} catch {
    Add-Signal Hypervisor 'Win32_ComputerSystem' $false "查询失败：$($_.Exception.Message)"
}

try {
    $guestKey = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters'
    $hasGuestKey = Test-Path -LiteralPath $guestKey
    if ($hasGuestKey) { $inVM = $true }
    $detail = ''
    if ($hasGuestKey) {
        $gp = Get-ItemProperty -LiteralPath $guestKey -ErrorAction SilentlyContinue
        if ($gp) {
            $detail = ("Host={0} VM={1}" -f $gp.PhysicalHostName, $gp.VirtualMachineName)
        }
    }
    Add-Signal Hypervisor 'HyperV Guest\Parameters 注册表键存在' $hasGuestKey $detail
} catch {
    Add-Signal Hypervisor 'HyperV Guest\Parameters' $false "查询失败：$($_.Exception.Message)"
}

try {
    $vmbus = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.PNPDeviceID -like 'VMBUS\*' })
    $hasVmbus = $vmbus.Count -gt 0
    if ($hasVmbus) { $inVM = $true }
    Add-Signal Hypervisor 'VMBus 设备节点存在' $hasVmbus ("VMBus 节点数：{0}" -f $vmbus.Count)
} catch {
    Add-Signal Hypervisor 'VMBus 设备节点' $false "查询失败：$($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 第 2 层：显示适配器（GPU-P 的决定性证据）
# ---------------------------------------------------------------------------

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
                $_.PNPClass -eq 'Display' -and
                $_.Name -and $_.Name -notmatch 'Microsoft Hyper-V Video' -and
                $_.Name -notmatch 'Microsoft Basic Display'
            })
    foreach ($d in $displays) {
        $id = [string]$d.PNPDeviceID
        $isPci = $id -match '(?i)^PCI\\VEN_[0-9A-F]{4}&DEV_'
        if (-not $isPci) { $gpuIsNonPci = $true; $gpuDisplayName = $d.Name }
        Add-Signal Display ("显卡 PnP 路径非 PCI [{0}]" -f $d.Name) (-not $isPci) $id
    }
    if ($displays.Count -eq 0) {
        Add-Signal Display '存在厂商显示适配器' $false '未枚举到 Hyper-V Video 之外的显示设备'
    }
} catch {
    Add-Signal Display '显卡 PnP 枚举' $false "查询失败：$($_.Exception.Message)"
}

# 2c. 缺失 PCI 位置信息（裸机/直通 = "PCI bus N, device N, function N"）
try {
    $noLocation = $false
    foreach ($d in @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
                Where-Object { $_.FriendlyName -notmatch 'Hyper-V Video' -and
                    $_.FriendlyName -notmatch 'Basic Display' })) {
        $loc = Get-PnpDeviceProperty -InstanceId $d.InstanceId `
            -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue
        $val = if ($loc) { [string]$loc.Data } else { '' }
        $missing = -not ($val -match '(?i)PCI\s+bus')
        if ($missing) { $noLocation = $true }
        Add-Signal Display ("显卡缺失 PCI 位置信息 [{0}]" -f $d.FriendlyName) $missing `
            ("LocationInfo='{0}'" -f $val)
    }
    if (-not $noLocation) { }
} catch {
    Add-Signal Display '显卡 PCI 位置信息' $false "查询失败（可能非 PnP cmdlet 环境）：$($_.Exception.Message)"
}

# 2d. UMD 驱动路径落在 HostDriverStore
try {
    $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $umdInHostStore = $false
    foreach ($sub in @(Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match '^\d{4}$' })) {
        $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
        $idd = if ($p -and ($p.PSObject.Properties.Name -contains 'InstalledDisplayDrivers')) {
            [string[]]$p.InstalledDisplayDrivers -join ';'
        } else { '' }
        if ($idd -match '(?i)HostDriverStore') {
            $umdInHostStore = $true
            Add-Signal Display ("UMD 指向 HostDriverStore [{0}]" -f $p.DriverDesc) $true $idd
        }
    }
    if (-not $umdInHostStore) {
        Add-Signal Display 'UMD 指向 HostDriverStore' $false '未发现指向 HostDriverStore 的显示驱动条目'
    }
} catch {
    Add-Signal Display 'UMD 驱动路径' $false "查询失败：$($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 第 3 层：D3DKMT ADAPTERTYPE.Paravirtualized（微软官方 API 位，最干净）
# ---------------------------------------------------------------------------
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
        struct D3DKMT_OPENADAPTERFROMLUID { public LUID AdapterLuid; public uint hAdapter; }

        [StructLayout(LayoutKind.Sequential)]
        struct D3DKMT_QUERYADAPTERINFO
        {
            public uint hAdapter; public uint Type;
            public IntPtr pPrivateDriverData; public uint PrivateDriverDataSize;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct D3DKMT_CLOSEADAPTER { public uint hAdapter; }

        // D3DKMT_ADAPTERTYPE：位域，本探针只关心 Paravirtualized 位（bit 8）。
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
        const int ADAPTERINFO_SIZE = 24; // hAdapter(4)+LUID(8)+2*uint(8) 对齐后
        // Paravirtualized 在 D3DKMT_ADAPTERTYPE 位域中的位序（WDK d3dkmthk.h）。
        const uint PARAVIRTUALIZED_BIT = 1u << 8;

        [DllImport("gdi32.dll")] static extern int D3DKMTEnumAdapters2(ref D3DKMT_ENUMADAPTERS2 p);
        [DllImport("gdi32.dll")] static extern int D3DKMTOpenAdapterFromLuid(ref D3DKMT_OPENADAPTERFROMLUID p);
        [DllImport("gdi32.dll")] static extern int D3DKMTQueryAdapterInfo(ref D3DKMT_QUERYADAPTERINFO p);
        [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(ref D3DKMT_CLOSEADAPTER p);

        // 返回：-1 未测得；0 无 Paravirt 适配器；>0 命中的 Paravirt 适配器数量。
        public static int CountParavirtualizedAdapters(out int totalAdapters)
        {
            totalAdapters = 0;
            var enum2 = new D3DKMT_ENUMADAPTERS2();
            if (D3DKMTEnumAdapters2(ref enum2) != 0) return -1;   // 首次调用取数量
            uint n = enum2.NumAdapters;
            if (n == 0) return 0;
            IntPtr buf = Marshal.AllocHGlobal((int)(n * ADAPTERINFO_SIZE));
            try
            {
                enum2.pAdapters = buf;
                if (D3DKMTEnumAdapters2(ref enum2) != 0) return -1;
                totalAdapters = (int)enum2.NumAdapters;
                int hits = 0;
                for (int i = 0; i < enum2.NumAdapters; i++)
                {
                    var ai = (D3DKMT_ADAPTERINFO)Marshal.PtrToStructure(
                        (IntPtr)(buf.ToInt64() + i * ADAPTERINFO_SIZE), typeof(D3DKMT_ADAPTERINFO));
                    var at = new D3DKMT_ADAPTERTYPE();
                    IntPtr atBuf = Marshal.AllocHGlobal(Marshal.SizeOf(at));
                    try
                    {
                        Marshal.StructureToPtr(at, atBuf, false);
                        var q = new D3DKMT_QUERYADAPTERINFO {
                            hAdapter = ai.hAdapter, Type = KMTQAITYPE_ADAPTERTYPE,
                            pPrivateDriverData = atBuf, PrivateDriverDataSize = (uint)Marshal.SizeOf(at) };
                        if (D3DKMTQueryAdapterInfo(ref q) == 0)
                        {
                            var got = (D3DKMT_ADAPTERTYPE)Marshal.PtrToStructure(atBuf, typeof(D3DKMT_ADAPTERTYPE));
                            if ((got.Value & PARAVIRTUALIZED_BIT) != 0) hits++;
                        }
                    }
                    finally { Marshal.FreeHGlobal(atBuf); }
                    var close = new D3DKMT_CLOSEADAPTER { hAdapter = ai.hAdapter };
                    D3DKMTCloseAdapter(ref close);
                }
                return hits;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
    }
}
'@ -ErrorAction Stop
    }
    $total = 0
    $hits = [VMate.VGpuP.D3DKmtProbe]::CountParavirtualizedAdapters([ref]$total)
    if ($hits -lt 0) {
        Add-Signal D3DKMT 'D3DKMT_ADAPTERTYPE.Paravirtualized' $false 'D3DKMT 查询未成功（未测得）'
    } else {
        $paravirtFlag = ($hits -gt 0)
        Add-Signal D3DKMT 'D3DKMT_ADAPTERTYPE.Paravirtualized' $paravirtFlag `
            ("Paravirtualized 适配器 {0}/{1}" -f $hits, $total)
    }
} catch {
    Add-Signal D3DKMT 'D3DKMT_ADAPTERTYPE.Paravirtualized' $false "探针不可用：$($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 总判定
# ---------------------------------------------------------------------------
$gpupPositive = @($signals | Where-Object {
        $_.Hit -and $_.Layer -in @('Display', 'D3DKMT')
    }).Count

$verdict =
if ($paravirtFlag -eq $true -or $hasHostStore -or $gpuIsNonPci) {
    'GPU-P'
} elseif ($inVM -and $gpupPositive -eq 0 -and $paravirtFlag -eq $false) {
    'VM-NoGpuP'
} elseif ($inVM) {
    'VM-NoGpuP'
} elseif ($gpupPositive -eq 0) {
    'Bare-Metal'
} else {
    'Inconclusive'
}

$result = [pscustomobject]@{
    Verdict            = $verdict
    InVirtualMachine   = $inVM
    HostDriverStore    = $hasHostStore
    GpuNonPciPath      = $gpuIsNonPci
    ParavirtAdapter    = $paravirtFlag       # $true/$false/$null
    GpuName            = $gpuDisplayName
    GpuPSignalCount    = $gpupPositive
    Signals            = $signals
}

if ($Json) {
    $result | ConvertTo-Json -Depth 5
    return
}

Write-Host ''
Write-Host ('==== vGPU-P 环境检测 ====') -ForegroundColor Cyan
$byLayer = $signals | Group-Object Layer
foreach ($grp in $byLayer) {
    Write-Host ("[{0}]" -f $grp.Name) -ForegroundColor DarkCyan
    foreach ($s in $grp.Group) {
        $mark = if ($s.Hit) { '●' } else { '·' }
        $color = if ($s.Hit) { 'Yellow' } else { 'DarkGray' }
        Write-Host ("  {0} {1}" -f $mark, $s.Name) -ForegroundColor $color
        if ($s.Detail) { Write-Host ("      {0}" -f $s.Detail) -ForegroundColor DarkGray }
    }
}
Write-Host ''
$vColor = switch ($verdict) {
    'GPU-P' { 'Green' } 'Bare-Metal' { 'Gray' }
    'VM-NoGpuP' { 'Yellow' } default { 'Red' }
}
Write-Host ("判定: {0}" -f $verdict) -ForegroundColor $vColor
Write-Host ("  在虚拟机内       : {0}" -f $inVM)
Write-Host ("  HostDriverStore  : {0}" -f $hasHostStore)
Write-Host ("  显卡非PCI路径    : {0}" -f $gpuIsNonPci)
Write-Host ("  Paravirt适配器   : {0}" -f ($(if ($null -eq $paravirtFlag) { '未测得' } else { $paravirtFlag })))
Write-Host ''

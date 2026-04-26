param(
    [string]$Subkey = "",
    [switch]$ListOnly,
    [switch]$SkipTask,                          # skip the scheduled-task install step
    [string]$SpoofName    = 'NVIDIA GeForce GTX 1050',
    [string]$SpoofVendor  = 'NVIDIA',           # 'NVIDIA' / 'AMD'
    [int]   $SpoofRamMb   = 2048,               # 显存 MB（注册表 HardwareInformation.MemorySize）
    [string]$SpoofBios    = 'Version 86.07.48.00.38'
)

# zh-CN Win10 默认 console code page = 936 (GBK)，把 Write-Host 中文当 GBK 输出 → 终端乱码。
try { chcp 65001 | Out-Null } catch {}
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}
$OutputEncoding = [System.Text.UTF8Encoding]::new()

# apply-gpu-spoof.ps1 - run INSIDE the Win10 guest, as Administrator.
#
# One-shot installer for the NVIDIA GTX 1050 spoof:
#
#   1) Class\{4d36e968-...}\NNNN        -> WMI VideoProcessor / AdapterRAM /
#                                           DriverDesc / HardwareInformation.*
#
#   2) Enum\PCI\VEN_...&DEV_...\<inst>  -> FriendlyName + DeviceDesc
#      (this is what Device Manager and Win32_VideoController.Name read)
#
#   3) C:\ProgramData\StealthGPU\refresh-gpu-name.ps1
#      + scheduled task "StealthGPU-RefreshName" (AtStartup + AtLogOn, SYSTEM,
#      highest privs). Windows' built-in BasicDisplay driver overwrites
#      DeviceDesc from display.inf on every init, so we re-apply the spoof
#      strings a couple of seconds after every boot. Pass -SkipTask to omit.
#
# IMPORTANT followup:
#   Device Manager's "驱动程序提供商 / 驱动程序说明" (Driver Provider / Desc)
#   on the Driver tab read the DEVPKEY storage under
#     Enum\PCI\<hwid>\<inst>\Properties\{a8b865dd-...}\0009|0004\00000000
#   which is locked to TrustedInstaller AND must use DEVPROP type 0xFFFF0012,
#   not REG_SZ. Both the ACL and the type field can only be fixed reliably
#   offline. After running this script, shut down the VM and run on the host:
#     sudo deploy/scripts/host-fix-gpu-devpkey.sh <INSTANCE>
#   (see USAGE.md §7.7). Without that step you'll see "驱动程序提供商: 未知"
#   even though WMI / Class\ fields are already NVIDIA.
#
# Usage (PowerShell as Admin):
#   powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1
#   powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -Subkey 0001
#   powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -ListOnly
#   powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -SkipTask

# 参数化（来自 -SpoofName/-SpoofVendor，默认仍是 GTX 1050 兼容老调用方式）
$spoofName    = $SpoofName
$spoofVendor  = $SpoofVendor                             # Win32_VideoController.AdapterCompatibility / DxDiag 制造商
$spoofBios    = $SpoofBios                               # HardwareInformation.BiosString (随机 NVIDIA/AMD)
$spoofRamMb   = $SpoofRamMb                              # HardwareInformation.MemorySize (字节 = $spoofRamMb * 1MB)
# Monitor 字段必须和 EDID 协调一致:
#   QEMU edid-generate.c 现在把 EDID 上报为 SAM:0x0F65 + week32/2018,
#   PnP HardwareID 自动变成 MONITOR\SAM0F65 — 这是真实 Samsung S24F350F
#   面板的产品码. 注册表里的可读名也对齐到同一个具体型号.
$monitorName  = 'Samsung S24F350F'
$monitorMfg   = 'Samsung Electronics Co., Ltd.'
$monitorHwId  = 'MONITOR\SAM0F65'                        # PnP HardwareID 主键
$monitorPNP   = 'SAM0F65'                                # Enum\DISPLAY 子键名
$classGuid    = '{4d36e968-e325-11ce-bfc1-08002be10318}'   # Display adapters
$monClassGuid = '{4d36e96e-e325-11ce-bfc1-08002be10318}'   # Monitors
$classRoot    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $classGuid
$monClassRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $monClassGuid
$enumRoot     = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'
$displayEnum  = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'

# DEVPROPKEY fmtid for driver-related PnP properties (DEVPKEY_Device_Driver*):
#   pid 4 = DriverDesc    pid 9 = DriverProvider
#   pid 3 = DriverVersion pid 2 = DriverDate
# Device Manager 的"驱动程序"选项卡读的是这一组, 不是 Class\...\ProviderName.
$fmtDev       = '{a8b865dd-2e3d-4094-ad97-e593a70c75d6}'

function Convert-ToRegPath {
    param([string]$PSPath)
    $r = $PSPath
    $r = $r -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    $r = $r -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
    $r = $r -replace '^HKLM:', 'HKLM'
    return $r
}

# --- TrustedInstaller ACL 穿透: SeTakeOwnership + SeRestorePrivilege + Take-RegOwnership ---
# Enum\PCI\<hwid>\<inst>\Properties\{a8b865dd-...} 子树默认 owner=TrustedInstaller,
# Admin/SYSTEM 连读都不行. 光 reg.exe /f 穿不过去, 必须先启 token 特权再 SetOwner.
if (-not ('StealthPriv' -as [type])) {
    Add-Type -Namespace Stealth -Name Priv -MemberDefinition @'
[DllImport("advapi32.dll", SetLastError=true)]
public static extern bool OpenProcessToken(System.IntPtr h, uint da, out System.IntPtr tok);
[DllImport("advapi32.dll", SetLastError=true)]
public static extern bool LookupPrivilegeValue(string sys, string name, out long luid);
[DllImport("advapi32.dll", SetLastError=true)]
public static extern bool AdjustTokenPrivileges(System.IntPtr tok, bool dis, ref TOKEN_PRIVILEGES np, uint bl, System.IntPtr pp, System.IntPtr rl);
[DllImport("kernel32.dll")] public static extern System.IntPtr GetCurrentProcess();
[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr h);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct TOKEN_PRIVILEGES {
    public uint Count; public long Luid; public uint Attr;
}
public static bool Enable(string name) {
    System.IntPtr tok;
    if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return false;
    long luid;
    if (!LookupPrivilegeValue(null, name, out luid)) { CloseHandle(tok); return false; }
    TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
    tp.Count = 1; tp.Luid = luid; tp.Attr = 2;
    bool ok = AdjustTokenPrivileges(tok, false, ref tp, 0, System.IntPtr.Zero, System.IntPtr.Zero);
    CloseHandle(tok);
    return ok;
}
'@ -ErrorAction SilentlyContinue
}
try { [Stealth.Priv]::Enable('SeTakeOwnershipPrivilege') | Out-Null } catch {}
try { [Stealth.Priv]::Enable('SeRestorePrivilege')       | Out-Null } catch {}
try { [Stealth.Priv]::Enable('SeBackupPrivilege')        | Out-Null } catch {}

function Take-RegOwnership {
    # 给 Admin 拿下 owner 并授 FullControl, 调用者保证 Enable 了 SeTakeOwnership/SeRestore.
    param([string]$HiveRelPath)   # e.g. 'SYSTEM\CurrentControlSet\Enum\PCI\...'
    try {
        $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $HiveRelPath,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if (-not $key) { return $false }
        $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
        $acl.SetOwner($admins)
        $key.SetAccessControl($acl)
        $key.Close()

        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $HiveRelPath,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        if (-not $key) { return $false }
        $acl = $key.GetAccessControl()
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
            $admins, 'FullControl',
            ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'),
            'None', 'Allow')
        $acl.AddAccessRule($rule)
        $key.SetAccessControl($acl)
        $key.Close()
        return $true
    } catch {
        return $false
    }
}

function Set-DevProp {
    # 关键: reg.exe 只能写 REG_SZ (type 0x1), 而 DEVPKEY 存储期望
    # DEVPROP_TYPE_STRING (type 0xFFFF0012). 类型不对 SetupDiGetDeviceProperty
    # 返回失败, Device Manager "驱动程序提供商" 显示 "未知".
    #
    # - Class\{4d36e968-...}\NNNN\Properties\{fmtid}\... 这一路历史上不严格,
    #   reg.exe REG_SZ 落得下去, Class 子键也不是 DNF 查询的主路径, 保留.
    # - Enum\PCI\<hwid>\<inst>\Properties\{fmtid}\...\00000000 才是 Device Manager
    #   Driver 选项卡读的那一份, 这里必须保持 vk.type=0xFFFF0012, 由
    #   host-fix-gpu-devpkey.sh 在 host 侧 offline 写. 我们在这里 *绝对不能*
    #   用 reg.exe /t REG_SZ /f 去写: /f 会把 vk.type 重置成 0x1, 把 host-fix
    #   的成果抹掉, 重启后 "未知" 又回来.
    param([string]$DevPath, [string]$Fmtid, [string]$PidHex, [string]$Value)
    # 路径里带 Enum\PCI = 交给 host-fix, 这里 skip
    if ($DevPath -match 'Enum\\PCI\\') { return }
    $propKey = $DevPath + '\Properties\' + $Fmtid + '\' + $PidHex
    $r = Convert-ToRegPath $propKey
    & reg.exe add "$r" /v "00000000" /t REG_SZ /d $Value /f 2>$null | Out-Null
    $q = & reg.exe query "$r" /v "00000000" 2>$null
    if ($LASTEXITCODE -eq 0 -and $q) { return }
    $propRoot = ($r -replace '^HKLM\\', '') -replace '\\\d{4}$', ''
    $taken = Take-RegOwnership $propRoot
    if ($taken) {
        & reg.exe add "$r" /v "00000000" /t REG_SZ /d $Value /f 2>$null | Out-Null
    }
}

# Chinese localized needles built from char codes - keeps the source ASCII
# so Windows PowerShell 5.1 parses it correctly regardless of codepage.
$zhBasicDisplay = [string]::new([char[]](0x57fa,0x672c,0x663e,0x793a))
$zhStandardVGA1 = [string]::new([char[]](0x6807,0x51c6,0x0020,0x0056,0x0047,0x0041))
$zhStandardVGA2 = [string]::new([char[]](0x6807,0x51c6,0x0056,0x0047,0x0041))

$fakeNeedles = @(
    'virtio', 'Red Hat', 'Microsoft Basic', 'Standard VGA', 'QXL', 'Cirrus',
    $zhBasicDisplay, $zhStandardVGA1, $zhStandardVGA2
) -join '|'

# ---- list ------------------------------------------------------------------
Write-Host ("Adapters under " + $classRoot + " :") -ForegroundColor Cyan
Get-ChildItem $classRoot -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
        $d = (Get-ItemProperty -Path $_.PSPath -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
        Write-Host ("  {0}  -  {1}" -f $_.PSChildName, $d)
    }
Write-Host ""

if ($ListOnly) {
    Write-Host "ListOnly mode - exiting without changes." -ForegroundColor Yellow
    exit 0
}

# ---- pick class subkey(s) --------------------------------------------------
if ($Subkey) {
    $p = Join-Path $classRoot $Subkey
    if (-not (Test-Path $p)) {
        Write-Host ("ERROR: subkey '" + $Subkey + "' does not exist") -ForegroundColor Red
        exit 1
    }
    $dd = (Get-ItemProperty -Path $p -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
    $targets = @([pscustomobject]@{ Path=$p; Desc=$dd; Sub=$Subkey })
} else {
    $targets = Get-ChildItem $classRoot -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
            $p  = $_.PSPath
            $dd = (Get-ItemProperty -Path $p -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
            if ($dd -and ($dd -match $fakeNeedles -or $dd -eq $spoofName)) {
                [pscustomobject]@{ Path=$p; Desc=$dd; Sub=$_.PSChildName }
            }
        }
}

if (-not $targets) {
    Write-Host "No fake adapter auto-detected. Use one of the subkeys above:" -ForegroundColor Yellow
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -Subkey 0001" -ForegroundColor Yellow
    exit 1
}

# ---- patch class subkey(s) -------------------------------------------------
foreach ($t in $targets) {
    Write-Host ""
    Write-Host ("Patching class " + $t.Sub + " (was: " + $t.Desc + ")") -ForegroundColor Cyan
    # ChipType (GPU-Z 等读 HardwareInformation.ChipType): 用 SpoofName 去掉 vendor 前缀作为芯片型号
    $chipType = $spoofName -replace '^(NVIDIA|AMD)\s+', ''
    # MemorySize: $spoofRamMb * 1MB. byte[] little-endian QWORD.
    $memBytes = [BitConverter]::GetBytes([UInt64]$spoofRamMb * 1MB)

    Set-ItemProperty -Path $t.Path -Name "DriverDesc"   -Type String -Value $spoofName
    Set-ItemProperty -Path $t.Path -Name "ProviderName" -Type String -Value $spoofVendor
    Set-ItemProperty -Path $t.Path -Name "HardwareInformation.AdapterString" -Type String -Value $spoofName
    Set-ItemProperty -Path $t.Path -Name "HardwareInformation.ChipType"      -Type String -Value $chipType
    Set-ItemProperty -Path $t.Path -Name "HardwareInformation.DacType"       -Type String -Value "Integrated RAMDAC"
    Set-ItemProperty -Path $t.Path -Name "HardwareInformation.BiosString"    -Type String -Value $spoofBios
    Set-ItemProperty -Path $t.Path -Name "HardwareInformation.MemorySize" -Type Binary -Value $memBytes[0..3]
    if (Get-ItemProperty -Path $t.Path -Name "HardwareInformation.qwMemorySize" -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $t.Path -Name "HardwareInformation.qwMemorySize"
    }
    New-ItemProperty -Path $t.Path -Name "HardwareInformation.qwMemorySize" -PropertyType QWord -Value ([UInt64]$spoofRamMb * 1MB) | Out-Null
    # PnP properties on class subkey (fallback for Driver tab)
    Set-DevProp -DevPath $t.Path -Fmtid $fmtDev -PidHex '0004' -Value $spoofName
    Set-DevProp -DevPath $t.Path -Fmtid $fmtDev -PidHex '0009' -Value $spoofVendor
    Write-Host ("  -> DriverDesc now: " + (Get-ItemProperty -Path $t.Path -Name DriverDesc).DriverDesc) -ForegroundColor Green
}

# ---- patch Enum\PCI FriendlyName + DeviceDesc ------------------------------
$targetSubs = $targets | ForEach-Object { $_.Sub }
Write-Host ""
Write-Host "Scanning Enum\PCI for nodes bound to the patched class subkey(s)..." -ForegroundColor Cyan
$matchedEnum = @()
Get-ChildItem $enumRoot -ErrorAction SilentlyContinue | ForEach-Object {
    $venDev = $_
    Get-ChildItem $venDev.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
        $inst = $_
        $drv = (Get-ItemProperty -Path $inst.PSPath -Name Driver -ErrorAction SilentlyContinue).Driver
        if ($drv) {
            foreach ($s in $targetSubs) {
                $needle = $classGuid + '\' + $s
                if ($drv -like ("*" + $needle + "*")) {
                    $matchedEnum += [pscustomobject]@{
                        Path = $inst.PSPath
                        Short = ($venDev.PSChildName + '\' + $inst.PSChildName)
                    }
                }
            }
        }
    }
}

if (-not $matchedEnum) {
    Write-Host "  (no matching Enum\PCI node found)" -ForegroundColor Yellow
} else {
    foreach ($m in $matchedEnum) {
        Set-ItemProperty -Path $m.Path -Name FriendlyName -Type String -Value $spoofName
        Set-ItemProperty -Path $m.Path -Name DeviceDesc   -Type String -Value $spoofName
        # Mfg -> DxDiag "制造商" 字段的真正来源 (INF Provider string, burned into PnP at install)
        Set-ItemProperty -Path $m.Path -Name Mfg          -Type String -Value $spoofVendor
        # DEVPKEY_Device_DriverDesc / DriverProvider -> 设备管理器"驱动程序"选项卡.
        # Set-DevProp 检测到 Enum\PCI 路径会 skip, 这一条 DEVPKEY 要靠
        # host-fix-gpu-devpkey.sh 在 host 侧 offline 写 0xFFFF0012 才能生效.
        Set-DevProp -DevPath $m.Path -Fmtid $fmtDev -PidHex '0004' -Value $spoofName
        Set-DevProp -DevPath $m.Path -Fmtid $fmtDev -PidHex '0009' -Value $spoofVendor
        Write-Host ("  " + $m.Short + " -> " + $spoofName + " (Mfg=" + $spoofVendor + ", DriverProvider=" + $spoofVendor + ")") -ForegroundColor Green
    }
}

# ---- patch Monitor class ---------------------------------------------------
# Monitor 的来源 (按检测路径的高频顺序):
#   1) Enum\DISPLAY\<PNPID>\<inst>\{DeviceDesc, FriendlyName, Mfg, HardwareID,
#      CompatibleIDs}            -> Device Manager / Win32_DesktopMonitor /
#                                    DxDiag 显示器制造商/型号
#   2) Class\{4d36e96e-...}\NNNN\{DriverDesc, ProviderName} -> 已装的监视器
#                                    INF 驱动 (没装就只有 generic 那一份)
#
# EDID (我们的 hw/display/edid-generate.c 改动) 已经把厂商/产品码上报为
# SAM:0x0F65, 实际 PnP 出的 HardwareID 就是 MONITOR\SAM0F65 — 对应真实
# Samsung S24F350F. 没装专用 INF 时 Windows 会用 display.inf 的 generic
# 节点, 注册表里 DeviceDesc 落 "Generic PnP Monitor". 这里直接覆写到
# "Samsung S24F350F" + Mfg = "Samsung Electronics Co., Ltd.", WMI 和
# DxDiag 就一致了.
Write-Host ""
Write-Host "Patching Monitor (DISPLAY enum + {4d36e96e-...} class)..." -ForegroundColor Cyan
Get-ChildItem $displayEnum -ErrorAction SilentlyContinue | ForEach-Object {
    $pnp = $_
    Get-ChildItem $pnp.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
        $inst = $_
        Set-ItemProperty -Path $inst.PSPath -Name DeviceDesc   -Type String -Value $monitorName
        Set-ItemProperty -Path $inst.PSPath -Name FriendlyName -Type String -Value $monitorName
        Set-ItemProperty -Path $inst.PSPath -Name Mfg          -Type String -Value $monitorMfg
        # HardwareID/CompatibleIDs 是 PnP 在第一次发现 EDID 时根据上报的
        # 厂商:产品码自动写的, 但只有当前枚举的 PNPID 跟我们 EDID 一致
        # (SAM0F65) 时才能匹配 -- 给非匹配 PNPID 节点 (留下来的旧 EDID
        # 缓存) 一并刷成 SAM0F65 让残留枚举也对齐.
        Set-ItemProperty -Path $inst.PSPath -Name HardwareID `
            -Type MultiString -Value @($monitorHwId)
        Set-ItemProperty -Path $inst.PSPath -Name CompatibleIDs `
            -Type MultiString -Value @('MONITOR\Default_Monitor')
        Set-DevProp -DevPath $inst.PSPath -Fmtid $fmtDev -PidHex '0004' -Value $monitorName
        Set-DevProp -DevPath $inst.PSPath -Fmtid $fmtDev -PidHex '0009' -Value $monitorMfg
        Write-Host ("  " + $pnp.PSChildName + "\" + $inst.PSChildName + " -> " + $monitorName) -ForegroundColor Green
    }
}
Get-ChildItem $monClassRoot -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
        $p = $_.PSPath
        if (Get-ItemProperty -Path $p -Name DriverDesc -ErrorAction SilentlyContinue) {
            Set-ItemProperty -Path $p -Name DriverDesc   -Type String -Value $monitorName
            Set-ItemProperty -Path $p -Name ProviderName -Type String -Value $monitorMfg
            Set-DevProp -DevPath $p -Fmtid $fmtDev -PidHex '0004' -Value $monitorName
            Set-DevProp -DevPath $p -Fmtid $fmtDev -PidHex '0009' -Value $monitorMfg
            Write-Host ("  Class\{4d36e96e-...}\" + $_.PSChildName + " -> " + $monitorName) -ForegroundColor Green
        }
    }

# ---- install boot-time refresh task ----------------------------------------
if (-not $SkipTask) {
    Write-Host ""
    Write-Host "Installing boot-time refresh task (defeats BasicDisplay clobber)..." -ForegroundColor Cyan

    $taskName  = 'StealthGPU-RefreshName'
    $scriptDir = 'C:\ProgramData\StealthGPU'
    $scriptPath = Join-Path $scriptDir 'refresh-gpu-name.ps1'
    New-Item -Path $scriptDir -ItemType Directory -Force | Out-Null

    # 把当前 spoof 配置持久化到 HKLM:\SOFTWARE\StealthGPU，让开机后的 refresh
    # 任务读到当前 VM 实际选定的 GPU（不再硬编码 GTX 1050）。
    New-Item -Path 'HKLM:\SOFTWARE\StealthGPU' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\StealthGPU' -Name SpoofName    -Type String -Value $spoofName
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\StealthGPU' -Name SpoofVendor  -Type String -Value $spoofVendor
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\StealthGPU' -Name SpoofBios    -Type String -Value $spoofBios
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\StealthGPU' -Name SpoofRamMb   -Type DWord  -Value $spoofRamMb

    $body = @'
$ErrorActionPreference = 'SilentlyContinue'
# 从 HKLM:\SOFTWARE\StealthGPU 读出本 VM 选定的 spoof 名称（apply-gpu-spoof.ps1
# 安装时写入），缺省回退到 GTX 1050 兼容老安装。
$cfg = Get-ItemProperty 'HKLM:\SOFTWARE\StealthGPU' -ErrorAction SilentlyContinue
$spoofName    = if ($cfg.SpoofName)   { $cfg.SpoofName }   else { 'NVIDIA GeForce GTX 1050' }
$spoofVendor  = if ($cfg.SpoofVendor) { $cfg.SpoofVendor } else { 'NVIDIA' }
$spoofBios    = if ($cfg.SpoofBios)   { $cfg.SpoofBios }   else { 'Version 86.07.48.00.38' }
$spoofRamMb   = if ($cfg.SpoofRamMb)  { [int]$cfg.SpoofRamMb } else { 2048 }
$chipType     = $spoofName -replace '^(NVIDIA|AMD)\s+', ''
$memBytes     = [BitConverter]::GetBytes([UInt64]$spoofRamMb * 1MB)
$monitorName  = 'Samsung S24F350F'
$monitorMfg   = 'Samsung Electronics Co., Ltd.'
$monitorHwId  = 'MONITOR\SAM0F65'
$classGuid    = '{4d36e968-e325-11ce-bfc1-08002be10318}'
$monClassGuid = '{4d36e96e-e325-11ce-bfc1-08002be10318}'
$fmtDev       = '{a8b865dd-2e3d-4094-ad97-e593a70c75d6}'
$classRoot    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $classGuid
$monClassRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $monClassGuid
$enumRoot     = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'
$displayEnum  = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'

# SYSTEM-context refresh task. 主 spoof 脚本已经在首轮安装时把
# Enum\PCI\...\Properties\{a8b865dd-...} 的 owner 改为 Administrators + FullControl,
# 所以这里 reg.exe add 直接能落; 不用再 Take-RegOwnership (而且内嵌 @'...'@ Add-Type
# 会和本文件的外层 heredoc 终结符冲突, 放在主脚本里就够了).

function Set-DevProp {
    # Enum\PCI\...\Properties\{a8b865dd-...} 由 host-fix-gpu-devpkey.sh 独占.
    # reg.exe /f 会把 vk.type 从 0xFFFF0012 重置回 0x1, 让 Device Manager 的
    # "驱动程序提供商" 再次变成 "未知", 所以这里对 Enum\PCI 路径直接 skip.
    param([string]$DevPath, [string]$Fmtid, [string]$PidHex, [string]$Value)
    if ($DevPath -match 'Enum\\PCI\\') { return }
    $propKey = $DevPath + '\Properties\' + $Fmtid + '\' + $PidHex
    $r = $propKey -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' `
                  -replace '^HKEY_LOCAL_MACHINE', 'HKLM' `
                  -replace '^HKLM:', 'HKLM'
    & reg.exe add "$r" /v "00000000" /t REG_SZ /d $Value /f 2>$null | Out-Null
}

# -- GPU: Enum\PCI FriendlyName/DeviceDesc/Mfg + DEVPKEY_Device_Driver{Desc,Provider} --
foreach ($ven in Get-ChildItem $enumRoot) {
    if ($ven.PSChildName -notlike 'VEN_1AF4*' -and
        $ven.PSChildName -notlike 'VEN_1B36*' -and
        $ven.PSChildName -notlike 'VEN_1234*') { continue }
    foreach ($inst in Get-ChildItem $ven.PSPath) {
        $drv = (Get-ItemProperty -Path $inst.PSPath -Name Driver).Driver
        if ($drv -like ('*' + $classGuid + '*')) {
            Set-ItemProperty -Path $inst.PSPath -Name FriendlyName -Type String -Value $spoofName
            Set-ItemProperty -Path $inst.PSPath -Name DeviceDesc   -Type String -Value $spoofName
            Set-ItemProperty -Path $inst.PSPath -Name Mfg          -Type String -Value $spoofVendor
            Set-DevProp -DevPath $inst.PSPath -Fmtid $fmtDev -PidHex '0004' -Value $spoofName
            Set-DevProp -DevPath $inst.PSPath -Fmtid $fmtDev -PidHex '0009' -Value $spoofVendor
        }
    }
}

# -- Services\VioGpuDod\Video\DeviceDesc is Windows' own cache of the INF
#    DeviceDesc, and 鲁大师 / some third-party tools read it directly.
#    If we leave it referencing "@oem2.inf,%viogpudod.devicedesc%;Red Hat VirtIO..."
#    the "Red Hat" tail survives every registry sweep. Overwrite with a plain
#    resolved string so there is nothing for Windows to re-lookup. --
$vgdVideo = 'HKLM:\SYSTEM\CurrentControlSet\Services\VioGpuDod\Video'
if (Test-Path $vgdVideo) {
    Set-ItemProperty -Path $vgdVideo -Name DeviceDesc -Type String -Value $spoofName -EA 0
}

# -- GPU: Class\{4d36e968-...} DriverDesc/ProviderName/HardwareInformation.* --
foreach ($sub in Get-ChildItem $classRoot) {
    if ($sub.PSChildName -notmatch '^\d{4}$') { continue }
    $p  = $sub.PSPath
    $dd = (Get-ItemProperty -Path $p -Name DriverDesc).DriverDesc
    if ($dd) {
        Set-ItemProperty -Path $p -Name DriverDesc   -Type String -Value $spoofName
        Set-ItemProperty -Path $p -Name ProviderName -Type String -Value $spoofVendor
        Set-ItemProperty -Path $p -Name 'HardwareInformation.AdapterString' -Type String -Value $spoofName
        Set-ItemProperty -Path $p -Name 'HardwareInformation.ChipType'      -Type String -Value $chipType
        Set-ItemProperty -Path $p -Name 'HardwareInformation.DacType'       -Type String -Value 'Integrated RAMDAC'
        Set-ItemProperty -Path $p -Name 'HardwareInformation.BiosString'    -Type String -Value $spoofBios
        Set-ItemProperty -Path $p -Name 'HardwareInformation.MemorySize' -Type Binary -Value $memBytes[0..3]
        New-ItemProperty -Path $p -Name 'HardwareInformation.qwMemorySize' -PropertyType QWord -Value ([UInt64]$spoofRamMb * 1MB) -Force | Out-Null
        Set-DevProp -DevPath $p -Fmtid $fmtDev -PidHex '0004' -Value $spoofName
        Set-DevProp -DevPath $p -Fmtid $fmtDev -PidHex '0009' -Value $spoofVendor
    }
}

# -- Monitor: Enum\DISPLAY and Class\{4d36e96e-...} --
foreach ($pnp in Get-ChildItem $displayEnum) {
    foreach ($inst in Get-ChildItem $pnp.PSPath) {
        Set-ItemProperty -Path $inst.PSPath -Name DeviceDesc   -Type String -Value $monitorName
        Set-ItemProperty -Path $inst.PSPath -Name FriendlyName -Type String -Value $monitorName
        Set-ItemProperty -Path $inst.PSPath -Name Mfg          -Type String -Value $monitorMfg
        Set-ItemProperty -Path $inst.PSPath -Name HardwareID `
            -Type MultiString -Value @($monitorHwId)
        Set-ItemProperty -Path $inst.PSPath -Name CompatibleIDs `
            -Type MultiString -Value @('MONITOR\Default_Monitor')
        Set-DevProp -DevPath $inst.PSPath -Fmtid $fmtDev -PidHex '0004' -Value $monitorName
        Set-DevProp -DevPath $inst.PSPath -Fmtid $fmtDev -PidHex '0009' -Value $monitorMfg
    }
}
foreach ($sub in Get-ChildItem $monClassRoot) {
    if ($sub.PSChildName -notmatch '^\d{4}$') { continue }
    $p = $sub.PSPath
    $dd = (Get-ItemProperty -Path $p -Name DriverDesc).DriverDesc
    if ($dd) {
        Set-ItemProperty -Path $p -Name DriverDesc   -Type String -Value $monitorName
        Set-ItemProperty -Path $p -Name ProviderName -Type String -Value $monitorMfg
        Set-DevProp -DevPath $p -Fmtid $fmtDev -PidHex '0004' -Value $monitorName
        Set-DevProp -DevPath $p -Fmtid $fmtDev -PidHex '0009' -Value $monitorMfg
    }
}
'@
    # Write refresh script as UTF-8 with BOM so PS 5.1 on any codepage parses it
    $bom   = [byte[]](0xEF,0xBB,0xBF)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    [System.IO.File]::WriteAllBytes($scriptPath, $bom + $bytes)

    schtasks.exe /Delete /TN $taskName /F 2>$null | Out-Null

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scriptPath + '"')
    $trigBoot  = New-ScheduledTaskTrigger -AtStartup
    $trigLogon = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable
    $task = New-ScheduledTask -Action $action -Trigger @($trigBoot, $trigLogon) `
        -Principal $principal -Settings $settings
    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null

    Write-Host ("  -> installed " + $scriptPath) -ForegroundColor Green
    Write-Host ("  -> task '" + $taskName + "' registered (AtStartup + AtLogOn, SYSTEM)") -ForegroundColor Green

    # ---- 立刻 SYSTEM 上下文跑一遍, 穿 Properties\{a8b865dd-...} 的 ACL ----
    Write-Host "  -> running task once now as SYSTEM to apply ACL-restricted keys..." -ForegroundColor Cyan
    schtasks.exe /Run /TN $taskName | Out-Null
    Start-Sleep -Seconds 3
    Write-Host "  -> done (refresh script logged to " $scriptDir ")" -ForegroundColor Green

    # ---- user-session task: force 1920x1080@60Hz via ChangeDisplaySettingsEx ----
    # viogpudo 不填 dmDisplayFrequency, "高级显示设置" 里有源信号 -1×-1
    # / 刷新率 1.000 Hz. ChangeDisplaySettingsEx 必须在交互会话里跑
    # (Session 0 的 SYSTEM 没桌面, EnumDisplaySettings 全返 0). 用
    # 当前登录用户 (autologon Administrator) 跑.
    Write-Host ""
    Write-Host "Installing user-session task to force 1920x1080@60Hz..." -ForegroundColor Cyan
    $freqTask   = 'StealthGPU-ForceDisplayFreq'
    $freqScript = Join-Path $scriptDir 'force-displayfreq.ps1'

    $freqBody = @'
# Force the active display mode to 1920x1080@60Hz so 高级显示设置 stops
# showing 有源信号 -1×-1 / 刷新率 1.000 Hz. Idempotent; if the mode is
# already correct, ChangeDisplaySettingsEx returns DISP_CHANGE_SUCCESSFUL
# without flicker.
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -ErrorAction Stop @"
using System;
using System.Runtime.InteropServices;
public class StDisp {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
        public ushort dmSpecVersion;
        public ushort dmDriverVersion;
        public ushort dmSize;
        public ushort dmDriverExtra;
        public uint   dmFields;
        public int    dmPositionX;
        public int    dmPositionY;
        public uint   dmDisplayOrientation;
        public uint   dmDisplayFixedOutput;
        public short  dmColor;
        public short  dmDuplex;
        public short  dmYResolution;
        public short  dmTTOption;
        public short  dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
        public ushort dmLogPixels;
        public uint   dmBitsPerPel;
        public uint   dmPelsWidth;
        public uint   dmPelsHeight;
        public uint   dmDisplayFlags;
        public uint   dmDisplayFrequency;
        public uint   dmICMMethod;
        public uint   dmICMIntent;
        public uint   dmMediaType;
        public uint   dmDitherType;
        public uint   dmReserved1;
        public uint   dmReserved2;
        public uint   dmPanningWidth;
        public uint   dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int ChangeDisplaySettings(ref DEVMODE devMode, uint flags);
}
"@

$dm = New-Object StDisp+DEVMODE
$dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
$rc = [StDisp]::EnumDisplaySettings($null, -1, [ref]$dm)
if ($rc -eq 0) { exit 0 }   # session has no display (Session 0 fallback) — give up

$dm.dmPelsWidth        = 1920
$dm.dmPelsHeight       = 1080
$dm.dmBitsPerPel       = 32
$dm.dmDisplayFrequency = 60
# DM_PELSWIDTH(0x80000) | DM_PELSHEIGHT(0x100000) | DM_BITSPERPEL(0x40000) | DM_DISPLAYFREQUENCY(0x400000)
$dm.dmFields = 0x5C0000
[StDisp]::ChangeDisplaySettings([ref]$dm, 0) | Out-Null
'@
    $freqBytes = [System.Text.Encoding]::UTF8.GetBytes($freqBody)
    [System.IO.File]::WriteAllBytes($freqScript, $bom + $freqBytes)

    schtasks.exe /Delete /TN $freqTask /F 2>$null | Out-Null
    $freqAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $freqScript + '"')
    $freqTrig = New-ScheduledTaskTrigger -AtLogOn -User 'Administrator'
    $freqPrincipal = New-ScheduledTaskPrincipal -UserId 'Administrator' `
        -LogonType Interactive -RunLevel Highest
    $freqSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
    $freqSched = New-ScheduledTask -Action $freqAction -Trigger $freqTrig `
        -Principal $freqPrincipal -Settings $freqSettings
    Register-ScheduledTask -TaskName $freqTask -InputObject $freqSched -Force | Out-Null
    Write-Host ("  -> task '" + $freqTask + "' registered (AtLogOn, Administrator/Interactive)") -ForegroundColor Green
    Write-Host "  -> running once now in current user session..." -ForegroundColor Cyan
    schtasks.exe /Run /TN $freqTask | Out-Null
    Start-Sleep -Seconds 2
}

# ---- force PnP property cache refresh --------------------------------------
# 设备管理器和 CM_GetDevNodeProperty 会缓存 DEVPKEY; 光改 registry 不会触发刷新.
# 把 display 类下的设备 Disable + Enable 一轮, 强制 PnP 重读所有 property.
Write-Host ""
Write-Host "Forcing PnP re-enumeration so Device Manager picks up new DEVPKEY..." -ForegroundColor Cyan
try {
    $gpus = Get-PnpDevice -Class 'Display' -Status OK -ErrorAction SilentlyContinue
    foreach ($g in $gpus) {
        try {
            Disable-PnpDevice -InstanceId $g.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            Enable-PnpDevice  -InstanceId $g.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host ("  cycled " + $g.InstanceId) -ForegroundColor Green
        } catch {
            Write-Host ("  (cycle failed for " + $g.InstanceId + ": " + $_.Exception.Message + ")") -ForegroundColor DarkYellow
        }
    }
} catch {
    Write-Host ("  (Get-PnpDevice unavailable: " + $_.Exception.Message + ")") -ForegroundColor DarkYellow
}

# ---- verify ----------------------------------------------------------------
Write-Host ""
Write-Host "Verifying via WMI..." -ForegroundColor Cyan
Get-WmiObject Win32_VideoController | Select-Object Name, VideoProcessor, AdapterRAM, DriverVersion | Format-List

Write-Host "Verifying Enum\PCI DriverProvider DEVPKEY (should be NVIDIA)..." -ForegroundColor Cyan
foreach ($m in $matchedEnum) {
    $r = (Convert-ToRegPath ($m.Path + '\Properties\' + $fmtDev + '\0009'))
    Write-Host ("  " + $r)
    $q = & reg.exe query "$r" /v "00000000" 2>&1
    foreach ($line in $q) { Write-Host "    $line" }
}

Write-Host "Done. The scheduled task re-applies the spoof within ~2s of every boot," -ForegroundColor Yellow
Write-Host "so Device Manager and WMI stay NVIDIA even after reboot."                  -ForegroundColor Yellow

Write-Host ""
Write-Host "=============== NEXT STEP (required!) ===============" -ForegroundColor Red
Write-Host "Device Manager Driver tab 'Driver Provider' will still show 未知 until"    -ForegroundColor Red
Write-Host "you shut down this VM and run on the HOST:"                                 -ForegroundColor Red
Write-Host "    sudo deploy/scripts/host-fix-gpu-devpkey.sh <INSTANCE>"                 -ForegroundColor Red
Write-Host "The DEVPKEY slot under Enum\PCI\...\Properties\{a8b865dd-...} needs an"    -ForegroundColor Red
Write-Host "offline fix (TrustedInstaller ACL + DEVPROP type 0xFFFF0012) which cannot"  -ForegroundColor Red
Write-Host "be done reliably from inside the guest."                                    -ForegroundColor Red
Write-Host "=====================================================" -ForegroundColor Red

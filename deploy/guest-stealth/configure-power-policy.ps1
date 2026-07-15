# configure-power-policy.ps1 —— 为正式 guest 严格禁止息屏、S3 与休眠。
#
# 统一 EXE 会在任何 GPU/PnP 修改之前调用本脚本。写入和回读都使用 Windows 自带
# PowrProf API，避开 powercfg /query 的本地化文本；只有“删除 hiberfil.sys”使用
# System32\powercfg.exe /hibernate off。脚本不安装服务、驱动、计划任务或第三方模块。

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { chcp 65001 | Out-Null } catch {}
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new() } catch {}
$OutputEncoding = [Text.UTF8Encoding]::new()

function Assert-PowerPolicyAdministrator {
    # PowerWrite*、PowerSetActiveScheme 与 powercfg /hibernate off 都要求提升后的
    # 管理员令牌。正式 launcher 已带 requireAdministrator；这里为手工调试再设门禁。
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole(
            [Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw '配置电源策略需要管理员权限。请运行统一 respawn-stealth.exe。'
    }
}

function Resolve-SystemPowerCfg {
    # 高权限脚本不能从当前目录或 PATH 搜索同名程序。System32 路径由 Windows API
    # 返回，并拒绝重解析点，防止普通用户预置 powercfg.exe 劫持管理员执行流。
    $systemDirectory = [Environment]::SystemDirectory
    if ([string]::IsNullOrWhiteSpace($systemDirectory)) {
        throw 'Windows 未返回 System32 目录。'
    }

    $path = Join-Path $systemDirectory 'powercfg.exe'
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw ('System32 powercfg.exe 不存在或是重解析点：' + $path)
    }
    return $item.FullName
}

function Invoke-PowerCfgChecked {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    # stderr 一并进入正式日志，但成功与否只认退出码。Windows 的提示文本会本地化，
    # 不能用中文或英文字符串作为协议。
    $output = @(& $Executable @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw ('powercfg ' + ($Arguments -join ' ') + ' 失败，退出码=' +
            $exitCode + '，输出=' + ($output -join ' | '))
    }
    return $output
}

function Initialize-PowerPolicyNativeApi {
    # Add-Type 只在当前 PowerShell 进程内编译一个 P/Invoke 桥，不向 guest 安装 DLL
    # 或程序集。显式 Size=128 的缓冲区大于 Win10 SYSTEM_POWER_CAPABILITIES；结构中
    # HiberFilePresent 的文档偏移为 8，用它证明 hiberfil 已被真正移除。
    if ('StealthPowerPolicyNative' -as [type]) { return }

    $source = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class StealthPowerPolicyNative
{
    [StructLayout(LayoutKind.Explicit, Size = 128)]
    private struct PowerCapabilitiesBuffer
    {
        [FieldOffset(8)] public byte HiberFilePresent;
    }

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern uint PowerGetActiveScheme(
        IntPtr userRootPowerKey, out IntPtr activePolicyGuid);

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern uint PowerSetActiveScheme(
        IntPtr userRootPowerKey, ref Guid schemeGuid);

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern uint PowerSettingAccessCheck(
        uint accessFlags, ref Guid powerGuid);

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern uint PowerWriteACValueIndex(
        IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroupGuid,
        ref Guid settingGuid, uint valueIndex);

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern uint PowerWriteDCValueIndex(
        IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroupGuid,
        ref Guid settingGuid, uint valueIndex);

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern uint PowerReadACValueIndex(
        IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroupGuid,
        ref Guid settingGuid, out uint valueIndex);

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern uint PowerReadDCValueIndex(
        IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroupGuid,
        ref Guid settingGuid, out uint valueIndex);

    [DllImport("powrprof.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.U1)]
    private static extern bool GetPwrCapabilities(
        out PowerCapabilitiesBuffer capabilities);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    private static void RequireSuccess(uint code, string operation)
    {
        if (code != 0) {
            throw new Win32Exception((int)code, operation);
        }
    }

    public static Guid GetActiveScheme()
    {
        IntPtr pointer;
        RequireSuccess(PowerGetActiveScheme(IntPtr.Zero, out pointer),
            "PowerGetActiveScheme failed");
        try {
            return (Guid)Marshal.PtrToStructure(pointer, typeof(Guid));
        } finally {
            if (pointer != IntPtr.Zero) { LocalFree(pointer); }
        }
    }

    public static void EnsureWritable(Guid setting)
    {
        Guid local = setting;
        RequireSuccess(PowerSettingAccessCheck(0, ref local),
            "AC power setting is policy-protected or inaccessible");
        local = setting;
        RequireSuccess(PowerSettingAccessCheck(1, ref local),
            "DC power setting is policy-protected or inaccessible");
    }

    public static void WriteZero(Guid scheme, Guid subgroup, Guid setting)
    {
        RequireSuccess(PowerWriteACValueIndex(IntPtr.Zero, ref scheme,
            ref subgroup, ref setting, 0), "PowerWriteACValueIndex failed");
        RequireSuccess(PowerWriteDCValueIndex(IntPtr.Zero, ref scheme,
            ref subgroup, ref setting, 0), "PowerWriteDCValueIndex failed");
    }

    public static uint ReadAc(Guid scheme, Guid subgroup, Guid setting)
    {
        uint value;
        RequireSuccess(PowerReadACValueIndex(IntPtr.Zero, ref scheme,
            ref subgroup, ref setting, out value), "PowerReadACValueIndex failed");
        return value;
    }

    public static uint ReadDc(Guid scheme, Guid subgroup, Guid setting)
    {
        uint value;
        RequireSuccess(PowerReadDCValueIndex(IntPtr.Zero, ref scheme,
            ref subgroup, ref setting, out value), "PowerReadDCValueIndex failed");
        return value;
    }

    public static void Activate(Guid scheme)
    {
        RequireSuccess(PowerSetActiveScheme(IntPtr.Zero, ref scheme),
            "PowerSetActiveScheme failed");
    }

    public static bool IsHiberFilePresent()
    {
        PowerCapabilitiesBuffer capabilities;
        if (!GetPwrCapabilities(out capabilities)) {
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "GetPwrCapabilities failed");
        }
        return capabilities.HiberFilePresent != 0;
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function New-StrictPowerSettings {
    # 不能只写 STANDBYIDLE：它仅阻止空闲超时，用户或程序仍可主动请求 S3。
    # ALLOWSTANDBY=0 才禁止 S1/S2/S3；其余项覆盖锁屏显示、无人值守与混合睡眠。
    $videoSubGroup = [guid]'7516b95f-f776-4464-8c53-06167f40cc99'
    $sleepSubGroup = [guid]'238c9fa8-0aad-41ed-83f4-97be242c8f20'
    return @(
        [pscustomobject]@{ Label = '自动关闭显示器'; SubGroup = $videoSubGroup
            Setting = [guid]'3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e' },
        [pscustomobject]@{ Label = '锁屏后关闭显示器'; SubGroup = $videoSubGroup
            Setting = [guid]'8ec4b3a5-6868-48c2-be75-4f3044be88a7' },
        [pscustomobject]@{ Label = '空闲自动进入 S3'; SubGroup = $sleepSubGroup
            Setting = [guid]'29f6c1db-86da-48c5-9fdb-f2b67b1f44da' },
        [pscustomobject]@{ Label = '无人值守自动睡眠'; SubGroup = $sleepSubGroup
            Setting = [guid]'7bc4a2f9-d8fc-4469-b07b-33eb785aaca0' },
        [pscustomobject]@{ Label = '允许主动 S1/S2/S3'; SubGroup = $sleepSubGroup
            Setting = [guid]'abfc2519-3608-4c2a-94ea-171b0ed546ab' },
        [pscustomobject]@{ Label = '混合睡眠'; SubGroup = $sleepSubGroup
            Setting = [guid]'94ac6d29-73ce-41a6-809f-6363ba21b47e' }
    )
}

function Assert-StrictPowerSettings {
    param(
        [Parameter(Mandatory = $true)][guid]$Scheme,
        [Parameter(Mandatory = $true)][object[]]$Settings
    )

    foreach ($setting in $Settings) {
        $ac = [StealthPowerPolicyNative]::ReadAc(
            $Scheme, $setting.SubGroup, $setting.Setting)
        $dc = [StealthPowerPolicyNative]::ReadDc(
            $Scheme, $setting.SubGroup, $setting.Setting)
        if ($ac -ne 0 -or $dc -ne 0) {
            throw ($setting.Label + ' 回读不为禁用：AC=' + $ac + '，DC=' + $dc)
        }
        Write-Host ('  已验证 ' + $setting.Label + '：AC/DC=0') -ForegroundColor Green
    }
}

try {
    Assert-PowerPolicyAdministrator
    Initialize-PowerPolicyNativeApi
    $powerCfg = Resolve-SystemPowerCfg
    $settings = @(New-StrictPowerSettings)
    $sessionPower = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    $appliedScheme = $null

    Write-Host '=== 配置 guest 电源策略：严格禁止息屏、S3 和休眠 ===' `
        -ForegroundColor Cyan
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $scheme = [StealthPowerPolicyNative]::GetActiveScheme()
        foreach ($setting in $settings) {
            [StealthPowerPolicyNative]::EnsureWritable($setting.Setting)
            [StealthPowerPolicyNative]::WriteZero(
                $scheme, $setting.SubGroup, $setting.Setting)
        }

        # 修改方案后必须重新激活才会向内核广播。若另一个进程在写入期间切换方案，
        # 不把旧方案强行切回去，而是有限重试当前新方案。
        if ([StealthPowerPolicyNative]::GetActiveScheme() -ne $scheme) {
            Write-Host ('  活动电源方案在写入期间变化，重试 ' + $attempt + '/3') `
                -ForegroundColor Yellow
            continue
        }
        [StealthPowerPolicyNative]::Activate($scheme)

        # HIBERNATEIDLE=0 在部分系统具有 adaptive hibernate 语义，不能作为“从不”
        # 证明。因此直接关闭 hiberfil，再用 GetPwrCapabilities.HiberFilePresent 验收。
        Invoke-PowerCfgChecked -Executable $powerCfg `
            -Arguments @('/hibernate', 'off') | Out-Null
        Set-ItemProperty -LiteralPath $sessionPower -Name 'HiberbootEnabled' `
            -Type DWord -Value 0 -Force -ErrorAction Stop

        Assert-StrictPowerSettings -Scheme $scheme -Settings $settings
        $hiberboot = Get-ItemPropertyValue -LiteralPath $sessionPower `
            -Name 'HiberbootEnabled' -ErrorAction Stop
        if ([uint32]$hiberboot -ne 0) { throw 'HiberbootEnabled 回读不为 0。' }
        if ([StealthPowerPolicyNative]::IsHiberFilePresent()) {
            throw 'powercfg 已返回成功，但 GetPwrCapabilities 仍报告 hiberfil 存在。'
        }

        if ([StealthPowerPolicyNative]::GetActiveScheme() -ne $scheme) {
            Write-Host ('  活动电源方案在验证期间变化，重试 ' + $attempt + '/3') `
                -ForegroundColor Yellow
            continue
        }
        $appliedScheme = $scheme
        break
    }

    if ($null -eq $appliedScheme) {
        throw '活动电源方案连续三次变化，无法证明当前方案已禁用睡眠。'
    }
    Write-Host ('  已固定活动电源方案：' + $appliedScheme) -ForegroundColor Green
    Write-Host '  Windows hiberfil、休眠和快速启动已关闭。' -ForegroundColor Green
    Write-Host '=== guest 电源策略配置完成 ===' -ForegroundColor Green
    exit 0
} catch {
    Write-Host ('FAIL: guest 电源策略配置失败：' + $_.Exception.Message) `
        -ForegroundColor Red
    exit 20
}

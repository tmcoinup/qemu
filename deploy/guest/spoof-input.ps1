<#
.SYNOPSIS
  Input-device cosmetic spoof — make Device Manager 显示一个国产大众
  品牌的鼠标/键盘节点，而不是裸的 "USB Input Device" + "QEMU USB
  Tablet"。

.HOW
  QEMU `-device usb-tablet` 走 USB HID class，idVendor=0x0627
  idProduct=0x0001。Windows 在 PnP 枚举之后把它的 FriendlyName 写到：

    HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_0627&PID_0001\<inst>\
        FriendlyName / DeviceDesc

  以及对应的 HID 子节点。我们 Set-ItemProperty 写新名（必须以
  "@xxx.inf,%key%;..." 格式骗过 Win10 monitor INF 解析），然后
  Disable / Enable 触发 Device Manager 刷新。

  下游 HID-compliant Mouse / HID Keyboard Device 都从这个 USB 节点
  长出来，所以**只改这一个**就把整条 input 链伪装好了。

.PARAMETER Brand
  选预设的国产/在华大众外设品牌：
    rapoo-v303    雷柏 V303 (默认 — 大众无线鼠标)
    dareu-em901   达尔优 EM901
    a4tech-x9     双飞燕 X9
    logitech-m220 罗技 M220 (跨国但中国卖最多的款)

.EXAMPLE
  irm http://192.168.30.127:8080/spoof-input.ps1 | iex
  或在 setup-guest.sh 链路里默认调一次。
#>
[CmdletBinding()]
param(
    [ValidateSet('rapoo-v303','dareu-em901','a4tech-x9','logitech-m220')]
    [string]$Brand = 'rapoo-v303'
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}
$ErrorActionPreference = 'Continue'

$brandMap = @{
    'rapoo-v303'    = @{ DeviceDesc = '雷柏 V303 无线鼠标';   Mfg = 'Rapoo Technology'   }
    'dareu-em901'   = @{ DeviceDesc = '达尔优 EM901 鼠标';     Mfg = 'Dareu Tech'         }
    'a4tech-x9'     = @{ DeviceDesc = '双飞燕 X9 USB 鼠标';    Mfg = 'A4Tech Co.'         }
    'logitech-m220' = @{ DeviceDesc = '罗技 M220 静音鼠标';    Mfg = 'Logitech'           }
}
$choice = $brandMap[$Brand]
Write-Host "[spoof-input] brand=$Brand → DeviceDesc='$($choice.DeviceDesc)'" -Fore Cyan

# ────────────────────────── target USB nodes ──────────────────────
# `-device usb-tablet` reports VID=0627 PID=0001. usb-kbd (legacy
# fallback if user later splits HID in vm.conf) reports the same VID
# different PID — we patch any 0627 child.
$base = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB'
$vendorKey = Join-Path $base 'VID_0627&PID_0001'
$instances = @()
if (Test-Path $vendorKey) {
    $instances += Get-ChildItem $vendorKey -EA 0
}
# Also catch some edge cases where Windows enumerates per-interface
# (HID-compliant mouse) under different parent paths.
foreach ($vp in @('VID_0627&PID_0001&MI_00','VID_0627&PID_0001&MI_01')) {
    $k = Join-Path $base $vp
    if (Test-Path $k) { $instances += Get-ChildItem $k -EA 0 }
}

if (-not $instances) {
    Write-Host '[spoof-input] no VID_0627 USB node found — is usb-tablet attached?' -Fore Yellow
    return
}

foreach ($inst in $instances) {
    $p = $inst.PSPath
    try {
        Set-ItemProperty -Path $p -Name 'FriendlyName' -Value $choice.DeviceDesc -Type String -Force
        Set-ItemProperty -Path $p -Name 'DeviceDesc'   -Value $choice.DeviceDesc -Type String -Force
        Set-ItemProperty -Path $p -Name 'Mfg'          -Value $choice.Mfg        -Type String -Force
        Write-Host "  patched $p" -Fore Gray
    } catch {
        Write-Host "  FAILED $p : $_" -Fore Yellow
    }
}

# ────────────────────────── HID children ──────────────────────────
# 当 Windows 把 USB HID 设备拆成 "HID-compliant mouse" / "HID
# Keyboard Device" 时显示在 Device Manager 鼠标 / 键盘 类目下；这些
# 走 HID\VID_0627&PID_0001\... 路径。改它们的 FriendlyName 让"键盘"
# 和"鼠标"展开里也是国产品牌。
$hidBase = 'HKLM:\SYSTEM\CurrentControlSet\Enum\HID'
if (Test-Path $hidBase) {
    Get-ChildItem $hidBase -EA 0 | Where-Object { $_.PSChildName -match '^VID_0627' } |
        ForEach-Object {
            Get-ChildItem $_.PSPath -EA 0 | ForEach-Object {
                try {
                    Set-ItemProperty -Path $_.PSPath -Name 'FriendlyName' -Value $choice.DeviceDesc -Type String -Force
                    Set-ItemProperty -Path $_.PSPath -Name 'DeviceDesc'   -Value $choice.DeviceDesc -Type String -Force
                    Set-ItemProperty -Path $_.PSPath -Name 'Mfg'          -Value $choice.Mfg        -Type String -Force
                    Write-Host "  patched HID $($_.PSPath)" -Fore Gray
                } catch {
                    Write-Host "  FAILED HID $($_.PSPath): $_" -Fore Yellow
                }
            }
        }
}

# ────────────────────────── force re-enum ─────────────────────────
# Get-PnpDevice / Disable/Enable 让 Device Manager 立刻刷新名字 —
# 不重启也能见效。失败不致命（reboot 也会拿到新名）。
Write-Host '[spoof-input] forcing PnP re-enum' -Fore Cyan
try {
    Get-PnpDevice -PresentOnly -Class 'HIDClass','Mouse','Keyboard' -EA 0 |
        Where-Object { $_.InstanceId -match 'VID_0627' } |
        ForEach-Object {
            try {
                Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -EA 0
                Start-Sleep -Milliseconds 200
                Enable-PnpDevice  -InstanceId $_.InstanceId -Confirm:$false -EA 0
            } catch {
                # benign — Class may also be 'USB' depending on Win10 build
            }
        }
} catch {
    Write-Host "[spoof-input] PnP re-enum skipped: $_" -Fore Yellow
}

Write-Host ''
Write-Host '======================================================' -Fore Green
Write-Host 'Done. Verify in guest:' -Fore Green
Write-Host '  Get-PnpDevice -PresentOnly | Where-Object FriendlyName -match "雷柏|达尔优|双飞燕|罗技"' -Fore Gray
Write-Host '  设备管理器 → 鼠标和其他指针设备 / 键盘 → 节点名' -Fore Gray

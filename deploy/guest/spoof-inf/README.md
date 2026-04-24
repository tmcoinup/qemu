# Guest 侧 GRID → 消费卡 INF 伪装

## 背景

本项目的显示栈分两层：

1. **宿主层** `vgpu_unlock-rs` 已经把 mdev 的 PCI `vendor:device` 改成
   `10DE:1C81` (GTX 1050) 或 `10DE:1D01` (GT 1030)。
   —— 但宿主 NVIDIA host driver 返回给 guest 的 vGPU 仍是「RTX6000-2Q Profile」，
   guest 里如果直接装 GeForce 驱动，PnP 不匹配，装不上。

2. **Guest 层** 需要按用户实际策略走两步:

   * **步骤 A** 先装 vGPU GRID 553.74 (i.e. `553.74_grid_win10_..._dch_64bit_international.exe`)
     把 NVIDIA display stack 正常跑起来，`nvidia-smi` 能 license，`Device Manager`
     里能看到 "NVIDIA RTX A6000 / RTX6000-2Q" 设备且工作正常 (Code 0)。
   * **步骤 B** 再用本目录脚本把已装驱动包里的 INF 改写 DeviceID
     (把 `DEV_1E30` / `DEV_1BB0` 等 GRID Quadro ID 换成 `DEV_1C81` GTX 1050 或 `DEV_1D01` GT 1030)，
     用 `pnputil /delete-driver` 卸载当前 GRID driver，再用修改后的 INF
     `pnputil /add-driver ... /install` 重装。

> ❌ 内存里明确记录：**不要再搞 "驱动安装后锁定整链"**（lock-gpu-driver.ps1 等 DenyDeviceClasses 已废弃）。本目录的脚本只做 DeviceID 改写，不做任何 policy 阻断。

## 核心前提

- vGPU 17.6 (host 550.163.02 + guest 553.74) 是当前**唯一已验证**可工作的组合，
  不要在 guest 上装 553.74 / 18.x。
- 本项目所有「显示卡死」问题的根因多半是
  `nvlddmkm.sys + nvwgf2umx.dll` 没装全，先检查 `C:\Windows\System32\drivers\nvlddmkm.sys`
  是否存在、`System32\nvwgf2umx.dll` 是否存在。
- guest 需处于 **RDP 模式** (std-vga 会卡死)，见 memory `project_display_rdp`。

## 工作流程

```powershell
# 1. guest 下载 vGPU 17.6 的 Windows Guest Driver
#    路径: ~/Downloads/vGPU17.6/Guest_Drivers/553.74_grid_win10_win11_server2022_dch_64bit_international.exe
# 2. 正常运行 .exe，选 Express Install，装完重启。
#    这一步后 nvidia-smi 必须能看到设备 + Licensed。
# 3. 执行本目录 inf-patch.ps1 (需要管理员权限):
.\inf-patch.ps1 -Profile gtx1050_2gb -DriverRoot "C:\NVIDIA\DisplayDriver\553.74"
# 4. 重启，Device Manager 里应该显示 "NVIDIA GeForce GTX 1050"。
```

## 原理细节 — 要改的 INF 段

NVIDIA Windows driver 是基于 `nvdm*.inf` 的多 INF 集合。关键段:

```inf
[Strings]
NVIDIA_DEV.1E30 = "NVIDIA RTX A6000"
NVIDIA_DEV.1BB0 = "NVIDIA RTX 6000"   ; vGPU pass-through 的 host PCI ID

[Manufacturer]
%NVIDIA_A%    = NVIDIA_Devices, NTamd64.10.0...

[NVIDIA_Devices.NTamd64.10.0...]
%NVIDIA_DEV.1E30% = Section023, PCI\VEN_10DE&DEV_1E30
%NVIDIA_DEV.1BB0% = Section024, PCI\VEN_10DE&DEV_1BB0
```

脚本改写为:

```inf
[Strings]
NVIDIA_DEV.1C81 = "NVIDIA GeForce GTX 1050"

[NVIDIA_Devices.NTamd64.10.0...]
%NVIDIA_DEV.1C81% = Section023, PCI\VEN_10DE&DEV_1C81
```

原 Quadro/RTX 条目保留不动（避免破坏别的 SKU 支持），仅追加我们需要的 ID。

## 卸载并重装

```powershell
# 列出所有 oem 驱动
pnputil /enum-drivers | Select-String -Pattern 'nvidia' -Context 0,4

# 找到 "oemXX.inf" 后卸载 (可能要卸载多条)
pnputil /delete-driver oemXX.inf /uninstall /force

# 用修改后的 INF 重装
pnputil /add-driver C:\NVIDIA\DisplayDriver\553.74\Display.Driver\nvdm*.inf /install
```

## 失败回退

如果改完后 Device Manager 出现 Code 43，先回滚:

```powershell
# 用 DDU (Display Driver Uninstaller) 安全模式干净卸载
# 重装原版 553.74 exe (express install)
# 只有 vgpu_unlock + licensed 两步都通过后，再尝试 INF 改写
```

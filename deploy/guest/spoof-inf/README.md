# Guest 侧 GRID → 消费卡 INF 伪装

> **当前状态（2026-07-12）**：本目录保留的是完整 PCI 身份方案 A 的设计与旧版
> 实验记录，不是当前 535.161.05/538.33 baseline 的可直接执行教程。
> `inf-patch.ps1` 只搜索 `nvdm*.inf` 并写死 `Section400`，而当前稳定包是
> `nvgridsw.inf`、使用 `Section019/020`；直接照下面旧命令运行会失败。
> 当前生产流程使用 `--spoof-name-only` + `sync-vgpu-profile.sh`，见
> [`../../docs/VGPU-VM-CREATION.md`](../../docs/VGPU-VM-CREATION.md) 和
> [`../../docs/DRIVER-INSTALL.md`](../../docs/DRIVER-INSTALL.md)。

## 背景

本项目的显示栈分两层：

1. **资源层**始终创建 `nvidia-257 / RTX6000-2Q`，实际 framebuffer 是
   2048MB。宿主的 mdev type 没有为每个消费卡型号各建一份。

2. **身份层**由 QEMU 按 `vms/N/vm.conf`，在同一时刻只向 guest 暴露一个消费卡
   PCI Device ID：`1380` (GTX 750 Ti)、`1D01` (GT 1030) 或
   `1C81` (GTX 1050)。

3. **Guest 层**需要让同一份 GRID driver 能匹配上述三个 ID：

   * **步骤 A** 先装 vGPU GRID 553.74 (i.e. `553.74_grid_win10_..._dch_64bit_international.exe`)
     把 NVIDIA display stack 正常跑起来，`nvidia-smi` 能 license，`Device Manager`
     里能看到 "NVIDIA RTX A6000 / RTX6000-2Q" 设备且工作正常 (Code 0)。
   * **步骤 B** 再用本目录脚本给驱动 INF 追加消费卡 Device ID
     (`DEV_1380` / `DEV_1D01` / `DEV_1C81`)，
     用 `pnputil /delete-driver` 卸载当前 GRID driver，再用修改后的 INF
     `pnputil /add-driver ... /install` 重装。

> ❌ 内存里明确记录：**不要再搞 "驱动安装后锁定整链"**（lock-gpu-driver.ps1 等 DenyDeviceClasses 已废弃）。本目录的脚本只做 DeviceID 改写，不做任何 policy 阻断。

## 核心前提

- host 与 guest GRID driver 必须属于兼容的 vGPU branch；以当前部署脚本配置和
  `start-vm.sh` 的 `EXPECT_VER` 为准，不要混装不同大版本。
- 本项目所有「显示卡死」问题的根因多半是
  `nvlddmkm.sys + nvwgf2umx.dll` 没装全，先检查 `C:\Windows\System32\drivers\nvlddmkm.sys`
  是否存在、`System32\nvwgf2umx.dll` 是否存在。
- 准备 driver 时必须用 `--no-spoof` 保留 GRID 原生 PCI ID；显示窗口可以走当前
  native SDL/GTK，旧部署也可以走 RDP。

## 工作流程

### “在 Windows base 中加入三个”到底是什么意思

不是给 base VM 挂三张显卡，也不是分配 `3 × 2GB` 显存。它只是在 Windows
驱动包的 INF 中预先加入三条硬件匹配规则：

```text
PCI\VEN_10DE&DEV_1380  -> NVIDIA GeForce GTX 750 Ti
PCI\VEN_10DE&DEV_1D01  -> NVIDIA GeForce GT 1030
PCI\VEN_10DE&DEV_1C81  -> NVIDIA GeForce GTX 1050
```

base 被克隆后，每台 VM 仍然只会从池中选一条。例如 vm4 抽到 1030，QEMU
只呈现 `DEV_1D01`；vm5 抽到 1050，只呈现 `DEV_1C81`。提前把三条都写进
base 的 Driver Store，是为了让任意克隆盘都能直接找到同一份 GRID driver。

如果 base 里只有 `DEV_1D01`，抽到 GTX 750 Ti 或 GTX 1050 的 VM 就可能出现
“没有匹配驱动”、设备无法启动或安装器不识别；这就是必须在制作 base 时一次
加入三条的原因。

### 推荐的 base 制作顺序

1. 选一台专门制作模板的 VM（通常 vm1），先用 `--no-spoof` 启动。此时 guest
   看到 GRID 原生 PCI ID，便于安装原厂 GRID driver。
2. 在 Windows 中安装与 host 匹配的 GRID guest driver 和 license，确认
   Device Manager 无错误、`nvidia-smi` 正常。
3. 备份当前 qcow2。INF 修改会触发 NVIDIA driver 卸载/重装，不要省略备份。
4. 在管理员 PowerShell 中运行一次 `all_2gb`：

```powershell
.\inf-patch.ps1 -Profile all_2gb `
  -DriverRoot 'C:\NVIDIA\DisplayDriver\553.74\International\Display.Driver' `
  -SkipReinstall
```

5. `-SkipReinstall` 很重要：先只生成修改后的 INF。修改 INF 后必须沿用本项目
   的 catalog 重新生成/签名和受信任证书流程；直接修改厂商 INF 会使原 catalog
   哈希失效。按 `deploy/docs/DRIVER-INSTALL.md` 完成签名后，再用 `pnputil`
   安装已签名的驱动包并重启。不要先让脚本直接重装一个尚未重新签名的 INF。
6. 验证驱动源目录中三条都存在：

```powershell
Get-ChildItem 'C:\NVIDIA\DisplayDriver\553.74' -Recurse -Filter 'nvdm*.inf' |
  Select-String -Pattern 'DEV_(1380|1C81|1D01)'
```

7. Windows 正常关机，在宿主执行：

```bash
./deploy/scripts/promote-base.sh 1
```

之后 `create-disk.sh` 从 `vms/bases/win10-base.qcow2` 克隆，不需要每台新 VM 重做
`all_2gb`。新 VM 第一次进入 Windows 后只需运行
`./deploy/sync-vgpu-profile.sh <vm_id>`，把该 VM 实际抽到的单个型号名称和
NVAPI 规格写入 guest。

### 单型号调试

```powershell
# 1. guest 下载 vGPU 17.6 的 Windows Guest Driver
#    路径: ~/Downloads/vGPU17.6/Guest_Drivers/553.74_grid_win10_win11_server2022_dch_64bit_international.exe
# 2. 正常运行 .exe，选 Express Install，装完重启。
#    这一步后 nvidia-smi 必须能看到设备 + Licensed。
# 3. 只调试 GTX 1050 时也可指定单项；正式 base 推荐 all_2gb:
.\inf-patch.ps1 -Profile gtx1050_2gb `
  -DriverRoot "C:\NVIDIA\DisplayDriver\553.74" -SkipReinstall
# 4. 重新生成/签名 catalog，安装修改后的包，再重启验证。
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

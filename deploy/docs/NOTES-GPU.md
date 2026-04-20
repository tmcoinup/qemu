# GPU 身份伪造（无直通场景）

## 为什么"只改主机端"不够

没有 GPU 直通的 Win10 客机装不上 NVIDIA 用户态驱动——那个驱动只肯绑到一块真 NVIDIA PCI 设备上，而且会走一轮内核态探测（MMIO BAR 布局、VBIOS ROM 读取、PCI 电源状态走查、NvEncodeAPI 握手）。

单纯把 virtio-gpu-pci 的 VID/PID 改成 `10DE:1C81` **不能**让任务管理器显示"GTX 1050"：NVIDIA INF 还是会拒绝绑定，Windows 会退回到 Microsoft Basic Display Adapter（或者我们的 virtio WDDM 驱动），DXGI 报的就是那个字符串。

## 两种可行思路

### 方案 A — 在客机里把适配器改名

大多数消费级反作弊（包括 DNF 用的 XignCode3）读的是 WMI 的 `Win32_VideoController.Name` 或者 DXGI 的 `DXGI_ADAPTER_DESC.Description`。这两个值都来自驱动元数据，我们可以改写。

本包提供的工具：

* `deploy/scripts/apply-gpu-spoof.ps1`——一次到位的安装器。会扫 `Class\{4d36e968-...}`，自动挑出 `DriverDesc` 匹配 `virtio / Red Hat / Microsoft Basic / Standard VGA` 或其中文本地化字串（`基本显示`、`标准 VGA`）的那一项来改，**同时**改 `Enum\PCI\VEN_...\...\FriendlyName` 和 `DeviceDesc`（这两个才是 `Win32_VideoController.Name` 和设备管理器显示名的真正来源），**并安装一个开机自启的任务计划**做持久化（见下文）。
* `deploy/scripts/host-fix-gpu-devpkey.sh`——host 侧 offline 修补器。`apply-gpu-spoof.ps1` 跑完后，shutdown VM 再跑一次这个，把 `Enum\PCI\...\Properties\{a8b865dd-...}` 下 DriverDesc / DriverProvider 的 DEVPROP 类型从 `0x1` 改成 `0xFFFF0012`，同时绕开 TrustedInstaller ACL（否则 Device Manager 驱动程序选项卡显示"驱动程序提供商: 未知"）。详见 `USAGE.md` 第 7.6 节。

脚本写入 `Class\{4d36e968-...}\NNNN` 的值：

```
DriverDesc                         = "NVIDIA GeForce GTX 1050"
ProviderName                       = "NVIDIA"
MatchingDeviceId                   = "PCI\VEN_10DE&DEV_1C81"
HardwareInformation.AdapterString  = "NVIDIA GeForce GTX 1050"
HardwareInformation.ChipType       = "GeForce GTX 1050"
HardwareInformation.DacType        = "Integrated RAMDAC"
HardwareInformation.BiosString     = "Version 86.07.48.00.38"
HardwareInformation.MemorySize     = REG_BINARY 00 00 00 80   (2 GiB)
HardwareInformation.qwMemorySize   = REG_QWORD 0x80000000     (2 GiB)
```

以及 `Enum\PCI\VEN_*\<instance>` 节点：

```
FriendlyName                       = "NVIDIA GeForce GTX 1050"
DeviceDesc                         = "NVIDIA GeForce GTX 1050"
```

跑完后重启一次，DXGI / DxDiag / 任务管理器才会刷新成新字符串。

这套能骗过 WMI / DxDiag / CPU-Z 的显卡字符串，**骗不过**：

* 任何走 `nvml.dll` / `NvAPI_Initialize` 的代码——我们没有真 NVIDIA 驱动，调用会失败，而"失败本身"也是一个信号
* 走 `PCI_COMMON_CONFIG` 遍历 BAR 大小的内核态探测
* 尝试 `CreateFile` 打开 `\\.\Nvidia*` 设备名的代码

### 为什么必须装任务计划

如果不装，重启后一切被打回原形。Windows 默认没有 `VEN_1AF4&DEV_1050` 的签名 virtio-gpu WDDM 驱动，所以 PnP 会回落到内置的 `BasicDisplay`（`msbasic.sys` + `display.inf`）内核驱动。这个驱动**每次开机都会把 `Enum\PCI\...\DeviceDesc` 从 `display.inf` 里刷回本地化默认字串**（中文系统就是「Microsoft 基本显示适配器」），同时清空 `FriendlyName`。Class 子键里的 `HardwareInformation.*` 不会被动，但 `Win32_VideoController.Name` 和设备管理器读的都是 Enum 节点这一侧，所以开机后客机又"长回"基本显示适配器。

`apply-gpu-spoof.ps1` 为此会多装两样东西：

* `C:\ProgramData\StealthGPU\refresh-gpu-name.ps1`——把 Enum 节点上每个匹配项的 `FriendlyName` / `DeviceDesc` 再刷一遍，同时把 Class 子键字符串钉回 NVIDIA
* 任务计划 `StealthGPU-RefreshName`——触发器 `AtStartup` + `AtLogOn`，以 `SYSTEM` 用户、最高权限跑。在参考 VM 上实测开机 2 秒左右就跑完，赶在任何反作弊枚举适配器之前

加 `-SkipTask` 参数可以跳过任务计划安装（仅对照测试时用）。

### 方案 B — 以后搭配主机端 vGPU 切片

等主机装第二块 GPU（或把当前 3060 Ti 换成支持 vGPU 的卡）之后，重新启用 vGPU_unlock，给每台 VM 分配一个 GTX 1050 级别的 MDEV profile。那时本包里的 SMBIOS / CPU / NVMe 补丁组完全不用动，只需把 `win10-ryzen3-stealth.sh` 里的 `-device virtio-vga-gl` 替换成 `-device vfio-pci,sysfsdev=...,display=off` 一段即可。

保持部署包与 GPU 方案解耦，后续升级不需要重新打 QEMU 补丁。

## 帧抓取（不走 Looking Glass / Sunshine）

启动器给每个 VM 一个独立的 QMP socket。`qmp-frame.sh N screenshot out.png` 会对 virtio-vga 头部触发一次 `screendump`，并把 PPM 转成 PNG。想连续串流，可以用 `-vnc :N`（HEADLESS 模式已默认开启），用任意 VNC 客户端或 ffmpeg（`ffmpeg -f x11grab -i :N ...`）拉流。

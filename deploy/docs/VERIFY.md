# 验证矩阵 — DNF 检测面清单

本文档列出 DNF 反作弊（XignCode3）和常见中国市场 VM 检测器会做的探测，以及本部署包是如何封堵的。

## 指令 / CPU 级别

| 探测                          | 修改前          | 修改后                                       | 实现路径                                         |
|-------------------------------|-----------------|----------------------------------------------|--------------------------------------------------|
| `cpuid(1).ECX[31]`            | 1（HV 标志）    | 0                                            | `target/i386/kvm/kvm.c` 擦除段                  |
| `cpuid(0x40000000)`           | `KVMKVMKVM`     | 叶返回 0（表里不存在）                       | 同上                                             |
| `cpuid(0x40000100-ff)`        | Hyper-V         | 叶被丢弃                                     | 同上                                             |
| Vendor 字符串                 | 因主机而异      | `AuthenticAMD`                               | `-cpu ...vendor=AuthenticAMD`                    |
| family / model / stepping     | 主机透传        | 23 / 1 / 1                                   | `target/i386/cpu.c` 新增 Ryzen3-1200            |
| invariant TSC                 | 可能缺失        | 存在                                         | `FEAT_8000_0007_EDX |= CPUID_APM_INVTSC`        |
| AES / AVX2 / SHA-NI           | 主机决定        | 保证开启                                     | Ryzen3-1200 特性位                               |
| 拓扑（核 / 线程）             | 暴露 SMT        | 4 / 4（无 SMT）                              | `-smp cpus=4,threads=1`                          |

## SMBIOS / DMI（Win32_* 类）

| WMI 类                        | 显示值                                    |
|-------------------------------|-------------------------------------------|
| `Win32_BIOS.Manufacturer`     | `American Megatrends Inc.`                |
| `Win32_BIOS.SMBIOSBIOSVersion`| 从池 `6203..2401` 随机                    |
| `Win32_BIOS.ReleaseDate`      | 2020..2023 池随机                         |
| `Win32_BaseBoard.Manufacturer`| 随机 AM4 厂商                             |
| `Win32_BaseBoard.Product`     | 对应型号                                  |
| `Win32_BaseBoard.SerialNumber`| 每次启动随机，厂商风格                    |
| `Win32_SystemEnclosure.*`     | Desktop / Tower，带厂商序列号             |
| `Win32_Processor.Name`        | `AMD Ryzen 3 1200 Quad-Core Processor`    |
| `Win32_PhysicalMemory.*`      | Kingston / DDR4-3200 / 双通道              |

## ACPI

| 表           | OEM_ID   | OEM_Table_ID |
|--------------|----------|--------------|
| RSDT / XSDT  | ALASKA   | A M I        |
| FADT / FACP  | ALASKA   | A M I        |
| DSDT / SSDT  | ALASKA   | A M I        |
| APIC / MCFG  | ALASKA   | A M I        |

之前所有表都写 `BOCHS ` / `BXPC    `——一眼就能判为虚拟机；现在统一伪装成 ASUS / MSI / Gigabyte / ASRock 这类消费主板固件。

## 存储

| 字段                  | 值                                   |
|-----------------------|--------------------------------------|
| PCI vendor/device     | 144D:A809（Samsung）                 |
| 子 vendor/device      | 144D:A801（970 PRO 级）              |
| Identify Ctrl `MN`    | `Samsung SSD 970 PRO 512GB`          |
| Identify Ctrl `FR`    | `1B2QEXM7`                           |
| 标称容量              | 512,000,000,000 B（厂家标签 512 × 10^9，PCIe 3.0 x4） |
| IEEE OUI              | 00:25:38（Samsung）                  |
| SUBNQN                | `nqn.1994-11.com.samsung:nvme:...`   |

## 网卡

| 字段               | 值                                                     |
|--------------------|--------------------------------------------------------|
| 设备               | Intel 82574L（`e1000e`）——不用 virtio-net             |
| MAC OUI            | 从 Intel / Realtek / ASUS 池随机（`_gen_mac`）         |
| 是否避开 52:54:00  | 是——启动器里曾硬编码 QEMU/KVM OUI，本次修复           |
| PHY 链路           | 1 Gbit 自动协商（e1000e 默认）                         |

## 内存（双通道）

| 字段                         | 值                                                       |
|------------------------------|-----------------------------------------------------------|
| 主机拓扑                     | 2 × `memory-backend-memfd`、2 × NUMA node                 |
| Win32_PhysicalMemory 数量    | 2 条 DIMM（每个 memfd 后端一条）                          |
| 单条容量                     | `RAM / 2` MiB（默认 8 GiB 总量时每条 4 GiB）              |
| 厂商                         | Kingston                                                  |
| 部件号                       | `HX426C16FB3A/4`（真实 HyperX Fury 4GB DDR4-2666 编号）   |
| 速率                         | 2666 MT/s（Ryzen 3 1200 JEDEC 上限；可通过 `MEM_SPEED=` 改） |
| Bank locator（DIMM 0）       | `P0 CHANNEL A`                                            |
| Bank locator（DIMM 1）       | `P0 CHANNEL B`                                            |
| 实现                         | `0006-smbios-dual-channel-bank.patch` 在 `hw/smbios/smbios.c` 加了 `%C` 替换，使同一条 `-smbios type=17,bank="P0 CHANNEL %C"` 按 DIMM 下标展开成 A/B |

## 网络链路

| 项                    | 值                                                                       |
|-----------------------|--------------------------------------------------------------------------|
| 默认后端              | user-mode NAT（SLIRP），`10.0.2.0/24` + SSH/RDP hostfwd                 |
| 推荐后端（stealth）   | 桥接 `BRIDGE=br0`，`deploy/scripts/setup-bridge.sh` 一次性配好            |
| 理由                  | `10.0.2.x` / `192.168.76.x` 这类 NAT 段是 VM 信号；桥接后客机是上游 LAN 里一条正常 DHCP 租约 |
| helper 权能           | `qemu-bridge-helper` 设 `cap_net_admin+ep`（比 suid root 更干净）         |
| ACL                   | `/etc/qemu/bridge.conf` 里必须有 `allow br0`                             |

## OEM 字符串（SMBIOS type 11）

真实的 ASUS / MSI AM4 主板会带 3–5 条厂商字符串（`ASUS_MB_RSVD`、`ASUS_MB_CPU=…`、`ASUS_MB_LINK_URL=…`）。**缺失** type 11 比内容错误更显眼——我们现在产出一组 ASUS 风格的最小集。

## 本包尚未封堵的残留面

### 主机端（需要更多 QEMU 补丁）

| 面                             | 当前值                     | 目标值                              | 成本                                         |
|--------------------------------|----------------------------|-------------------------------------|----------------------------------------------|
| virtio-gpu PCI VEN:DEV         | `1AF4:1050`（Red Hat）     | `10DE:1C81`（NVIDIA GTX 1050）      | **已尝试**改主 VID → OVMF 的 virtio-gpu GOP 驱动按 `VEN_1AF4` 匹配，改成 10DE 后 UEFI 直接"Display output is not active"，整个启动链没画面；**不可行**，只能走客机端改名 |
| 显示器 EDID 厂商 / 产品名      | 原 `RHT` / `QEMU Monitor`  | `SAM` / `SyncMaster`                | ✅ 已由 `0007-pci-gpu-edid-spoof.patch` 封堵，改 `hw/display/edid-generate.c` 默认串 |
| qemu-xhci PCI VEN:DEV          | `1B36:000D`（Red Hat）     | `1022:43BA`（AMD X370 USB3）        | 补 `hw/usb/hcd-xhci-pci.c`                   |
| intel-hda PCI VEN:DEV          | `8086:2668`（Intel ICH9）  | 不需要——Intel HDA 通用              | 无                                            |
| e1000e subsystem ID            | `8086:0000`（默认）        | 板厂 OEM-ID（ASUS `1043:xxxx`）      | `-global` 打到设备上                         |
| ACPI DSDT 方法名               | QEMU 默认                  | BIOS 厂商特定                        | 侵入 `hw/i386/acpi-build.c`，改动大          |

### 客机端（装完系统后必做）

| 任务                                                          | 方法                                                                                     |
|---------------------------------------------------------------|------------------------------------------------------------------------------------------|
| GPU 改名为 GeForce GTX 1050（WMI / DxDiag / 任务管理器）      | 以管理员身份跑 `deploy/scripts/apply-gpu-spoof.ps1`                                       |
| 关闭 Memory Integrity（HVCI）                                 | Windows 安全中心 → 设备安全 → 内核隔离 → 关                                                |
| 关闭 Virtualization-Based Security                            | `bcdedit /set hypervisorlaunchtype off` + 重启                                            |
| 移除 Hyper-V 可选组件                                         | `Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All`              |
| 不要装 virtio-win guest tools                                 | 会引入 `qemu-ga.exe` 和 Red Hat 签名的驱动                                                 |
| 不要装 SPICE guest tools                                      | 同上类型的暴露                                                                             |

### 进阶（前面全做完 DNF 还是报 0x403 时再处理）

* **驱动二进制名**——`viogpudo.sys` 在属性里写着 "Red Hat VirtIO"。重命名得先关驱动签名强制，有风险
* **`NvAPI_Initialize()` / `nvml.dll`**——没有真 NVIDIA 运行时。如果 XignCode 把"查询失败"本身当信号，主机端伪造无法修
* **RDTSC 确定性**——已经设了 `+invtsc`；更深的时序探测仍可能看到虚拟化抖动

## 运行时验证命令

在主机上、启动 Windows 之前：

```bash
deploy/scripts/verify-stealth.sh
```

从运行中的客机里：

```powershell
# 应打印 True
(Get-WmiObject Win32_BIOS).Manufacturer -eq "American Megatrends Inc."

# 结果应该**不**包含 BOCHS 或 BXPC
[Regex]::Match((Get-WmiObject Win32_ComputerSystem | Out-String),"BOCHS|BXPC").Success

# 所有核都应是 False
(Get-WmiObject Win32_Processor).HypervisorPresent
```

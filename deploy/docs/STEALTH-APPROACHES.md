# 三种 "Win32_VideoController 显示 NVIDIA / AMD" 方案对比

| 方案 | 是否需要物理 GPU | 适用反作弊 | 是否需要 testsigning | 当前是否运行 |
|---|---|---|---|---|
| **方案 0 — 浅层 (virtio-vga + 注册表化妆)** | ❌ 不需要 | DNF TP / ACE / NP | ❌ 无 | ✅ VM1/VM2 默认 |
| 方案 A — VFIO 直通 + INF patch + 自签 | ✅ 需 NVIDIA GPU | Riot Vanguard / EAC 等深度 | ⚠️ 一次性需开 | 历史 vm-nb 分支 |
| 方案 B — VFIO 直通 + 原版 driver + registry 化妆 | ✅ 需 NVIDIA GPU | 同 A，但更保守 | ❌ 无 | 历史方案 |

DNF / 腾讯 TP 用浅层就够，绝大多数生产 VM 跑的是这条。下面三个方案各自详述。

## 方案 0 — 浅层 (virtio-vga 软渲染 + subsys spoof + 注册表化妆) ⭐ 当前主流

**机制**：
- QEMU `-device virtio-vga,x-pci-sub-vendor-id=0x10DE,x-pci-sub-device-id=0x1C81,x-pci-revision=0xA1`
  - 主 PCI ID 留 `1AF4:1050` (virtio)，stock virtio-win 驱动能绑定
  - 子系统 ID 改成 `1C81:10DE` → guest PCI 树看见 NVIDIA GTX 1050 子系统
- Guest 装 **stock virtio-win 0.1.266 viogpudo.{sys,cat,inf}** —— `Microsoft Windows Hardware Compatibility Publisher` 原签，无任何自签 / 无 testsigning
- `apply-gpu-spoof.ps1` 注册表覆盖：把 `HKLM\Enum\PCI\VEN_1AF4&DEV_1050\...` 下的 `DeviceDesc` / `FriendlyName` / `DriverDesc` / `DEVPKEY_*` 全改 `NVIDIA GeForce GTX 1050`，再改 `Control\Class\{4d36e968-...}\` 和 `Control\Video\{...}\`
- `nvapi64.dll` shim 替换 `System32\nvapi64.dll`，让 NVAPI 查询返回伪 NVIDIA 信息
- `GPU-Z` / `DxDiag` / `Win32_VideoController` / `Get-PnpDevice` 全部读注册表覆盖值 → 显示 NVIDIA GTX 1050

**优点**：
- ✅ **不需要物理 GPU**，host 无 IOMMU 也能跑
- ✅ 驱动 100% Microsoft WHQL 签，无自签链、无 testsigning
- ✅ Bootmgr 原版，无 EfiGuard
- ✅ 通过 ACE 13-131106-0（腾讯反作弊 / DNF / 网易 NP / WeGame 都过）
- ✅ 配合 stealth-lib.sh `GPU_POOL` 6 款随机抽（NVIDIA GT 1030 / GTX 1050 / GTX 1050 Ti / GTX 750 Ti / AMD RX 550 / RX 560），每 VM 不同型号

**缺点**：
- ❌ 实际 PCI 主 ID 是 `1AF4:1050` (virtio)。如果反作弊在内核态读 PCI config space 的主 VEN:DEV，看到 virtio 一眼识破（**实测 TP/ACE 不查**）
- ❌ 性能 WARP 兜底（virtio-vga 无 GL）。DNF 2D + DX9 完全够；3A 大作不行
- ❌ `Win32_VideoController.CurrentRefreshRate = 1` 这种 viogpudo 内核 bug 仍残留（详见 README "已知限制"）

**这是 VM1 / VM2 历史上 GPU-Z 显示 1050 的实际方案**——不是下面的 A/B。

## 方案 A — VFIO 直通 + INF patch + QEMU PCI spoof + 自签 cat

> ⚠️ **需要物理 NVIDIA GPU + IOMMU + vfio-pci 内核模块**。host 不能用该 GPU 做显示。

**机制**：
- QEMU `-device vfio-pci,x-pci-device-id=0x1D01,x-pci-sub-vendor-id=0x1043,x-pci-sub-device-id=0x85F9` → PCI config space 的 `VEN:DEV:SUBSYS` 真的就是 `10DE:1D01:8FF91043`

**机制**：
- QEMU `-device vfio-pci,x-pci-device-id=0x1D01,x-pci-sub-vendor-id=0x1043,x-pci-sub-device-id=0x85F9` → PCI config space 的 `VEN:DEV:SUBSYS` 真的就是 `10DE:1D01:8FF91043`
- Guest INF `nvgridsw.inf` 里手工加了 `%NVIDIA_DEV.1D01.85F9.1043% = Section019/020, PCI\VEN_10DE&DEV_1D01&SUBSYS_85F91043`
- INF 改了 → `nvgridsw.cat` hash 失配 → `New-FileCatalog` + `Set-AuthenticodeSignature` 自签证书 `CN=vGPU-Patch-Signer` 装到 Root + TrustedPublisher
- Windows PnP 按 `PCI\VEN_10DE&DEV_1D01` bind → Device Manager 显示 "NVIDIA GeForce GT 1030"

**优点**：
- ✅ PCI layer 真的是 GT 1030。任何程序（包括 kernel-mode TP）读 PCI config 看到 `DEV_1D01`，和显示层一致
- ✅ Win32_VideoController / dxdiag / DXGI 完全一致 "GT 1030"
- ✅ 打开 subsystem ID（ASUS），增加硬件厂商指纹

**缺点**：
- ❌ Device 属性里"数字签名者" = `vGPU-Patch-Signer`（自签）。TP 若查 cert chain 会发现不是 NVIDIA/Microsoft
- ❌ 安装过程必经 `testsigning on` 一次才能把自签证书 import 成功（虽然**最终状态关回来了**），在某些 forensic 软件里有痕
- ❌ INF 改了，未来 NVIDIA driver 更新要重新 patch 重签

## 方案 B — VFIO 直通 + 原版 INF + Registry 化妆

> ⚠️ 同 A 需要物理 NVIDIA GPU；qemu2 vm-nb 分支原方案

**机制**：
- QEMU 不改 PCI config → guest 看到 `PCI\VEN_10DE&DEV_1E30&SUBSYS_132610DE` (Quadro RTX 6000 真实 ID)
- Guest 装**原版** NVIDIA `nvgridsw.inf`（cat 签名 `Microsoft Windows Hardware Compatibility Publisher` / NVIDIA 链完好）
- Windows PnP 自然 bind → 初始显示 "NVIDIA GRID RTX6000-2Q"
- 跑 `patch-grid-strings.ps1` 把 registry 里的 `GRID RTX6000-*` 字符串全部替换成 `GeForce GTX 1050`：
  - `HKLM\SYSTEM\CurrentControlSet\Enum\PCI\VEN_10DE&DEV_1E30\...\*` (所有 string value)
  - `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4D36E968-...}\*`
  - `HKLM\SYSTEM\CurrentControlSet\Control\Video\{...}\*`
  - `DeviceDesc` 里 `@oemN.inf,%...%;` 前缀也剥掉
- `Win32_VideoController` / `dxdiag` / `Get-PnpDevice` 查 registry → 显示 "GTX 1050"

**优点**：
- ✅ 数字签名者保持 **Microsoft Windows Hardware Compatibility Publisher**（NVIDIA 原 cat）
- ✅ 不需要 testsigning 任何阶段
- ✅ NVIDIA 驱动更新直接覆盖安装，不破坏 stealth（再跑一次 patch-grid-strings.ps1 即可）
- ✅ 脚本简单（~150 行 PowerShell）

**缺点**：
- ❌ PCI config space 的 `VEN:DEV` 还是 `10DE:1E30`（RTX 6000）。如果 TP 直接读 PCI config (`ZwQueryObject` / DeviceIoControl / `SetupAPI` 走特殊 flag)，看到**与 WMI 显示不一致**，可能当虚拟化指纹
- ❌ subsystem ID 是 NVIDIA 自家 `0x12BA10DE`，不是 AIB 厂家的，假 GPU 的真实感稍弱（实际 TP 一般不查）

## 关键差异一张表

| 维度 | 方案 0 (浅层 / virtio-vga) ⭐ | 方案 A (VFIO + INF patch) | 方案 B (VFIO + registry 化妆) |
|-----|---------|---------|---------|
| 需要物理 GPU | ❌ | ✅ NVIDIA | ✅ NVIDIA |
| QEMU 设备 | `virtio-vga` | `vfio-pci` | `vfio-pci` |
| PCI `VEN:DEV` (硬件层) | 1AF4:1050 (virtio) | 10DE:1D01 (GT 1030 真) | 10DE:1E30 (Quadro RTX 6000 真) |
| PCI `SUBSYS` | 10DE:1C81 等（profile 池 6 选 1） | 1043:85F9 (ASUS) | 10DE:1326 (NVIDIA) |
| Guest 驱动 | stock virtio-win 0.1.266 viogpudo (MS-WHQL 原签) | patched nvgridsw + 自签 cat | 原版 nvgridsw + MS-WHQL |
| WMI / dxdiag 显示 | 池里抽的型号（GTX 1050 / GT 1030 / RX 550...） | NVIDIA GeForce GT 1030 | NVIDIA GeForce GTX 1050 |
| Device Manager 数字签名者 | **Microsoft Windows Hardware Compatibility Publisher** | vGPU-Patch-Signer (自签) | **Microsoft Windows Hardware Compatibility Publisher** |
| 装证书流程 | **无** | 需 `testsigning on` → import → `off` | **无** |
| 过程遗留 | **无** | `bcdedit` 记录里有过 testsigning on | 无 |
| NVIDIA driver 热升级 | virtio-win 升级即可 | 要重 patch INF + 重签 | 跑一次 registry script |
| 3D 加速 | WARP (软件) | 原生 GPU | 原生 GPU |
| 单纯 WMI/DXGI 级 TP（DNF/ACE）| **过** | **过** | **过** |
| 深度 kernel TP 读 PCI config | **不过**（看到 virtio 主 ID） | **可能过**（PCI 也被伪装） | 读到 Quadro 可能拒绝 |

## 实际推荐

### DNF TP 的普遍已知检测面

DNF 的 TP (Tencent Protect) 主要查：
- CPU 特征（品牌字符串 / HYPERVISOR bit / CPUID 0x40000000 签名）
- HypervisorPresent / Win32_ComputerSystem
- SMBIOS 主板 / BIOS 关键字
- WMI Win32_VideoController 名字（查"GPU 型号是否合理"）
- MAC 前缀（是否 52:54:00 这种 QEMU 默认）
- 极少查 PCI config space 的 raw `VEN:DEV`

结论：**方案 0（浅层）对 DNF 就够**，是当前 VM1/VM2 实际跑的方案；不需要物理 GPU、不需要 EfiGuard、不需要自签 CA、不需要 testsigning。

### 方案 A / B 的适用场景

- 高端反作弊（Riot Vanguard / EAC 等）会真读 PCI config space
- host 已有空闲 NVIDIA GPU 且 IOMMU 配好
- 不在乎 testsigning 痕迹（A 路径）
- 已经不打算再升级 NVIDIA driver（A 路径）

3A 大作 / GPU 加速密集型游戏需要原生 GPU 性能 → A 或 B。DNF / 蜂巢 / 网吧类 → 方案 0 性能足够。

---

## 如果你要从 A 回滚到 B（保持 Microsoft 签名者）

流程（我已经准备好脚本，见 `deploy/guest/switch-to-approach-b.ps1` 和 `patch-grid-strings.ps1`）：

1. 关 VM
2. 改 `start-vm.sh` 用 `--no-spoof` 模式（默认 spoof=0 不传 `x-pci-device-id`）
3. 启动 VM
4. RDP 进去：
   - 卸当前自签 INF (oemNN.inf)
   - 装原版 nvgridsw.inf (仍在 `C:\nv\538.33-orig\` 或重新下)
   - 跑 `patch-grid-strings.ps1 -TargetName "GeForce GTX 1050"`
   - 移除自签证书 `Cert:\LocalMachine\Root` 下 `CN=vGPU-Patch-Signer`
5. 重启 → Device Manager 显示 "GeForce GTX 1050"，签名者 Microsoft

---

## Remote Display Adapter 为什么避不开

`Microsoft Remote Display Adapter` = Windows 内置 **Indirect Display Driver (IDD)**，只在 **RDP session 连上时自动实例化**，连接断开就消失。

- 无法 uninstall（系统组件）
- `pnputil /disable-device` 能禁用但 **RDP 就不能用了**（RDP session 的 framebuffer 依赖它）

已知可行的"看起来只有 1 张显卡"方式：

1. **不走 RDP**，guest 里用 **VNC 或物理显示器** / 捕获卡，Remote Display Adapter 就不出现
2. 改走 **Session 0 Console mirror**（`mstsc /admin`），仍走 RDP 协议但 session=0，理论上不实例化 IDD
3. DNF 运行时**临时 disable RDP 服务**，`net stop TermService`，断 RDP 再本地/VNC 启动游戏（RDP adapter 消失）

实测：DNF TP **一般不挑 RDP adapter**（大量玩家通过网吧 / 云电脑 / VPS 玩也都有 RDP），优先级低。

## 数字签名者可以显示成 "NVIDIA Corporation" 吗？

能，但有风险。

```powershell
# 创建一个 Subject 里显示 "NVIDIA Corporation" 的自签证书
$cert = New-SelfSignedCertificate -Subject 'CN=NVIDIA Corporation' `
    -Type CodeSigning -KeyUsage DigitalSignature `
    -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
    -CertStoreLocation 'Cert:\LocalMachine\My' -NotAfter (Get-Date).AddYears(10)
```

- Device Manager → "数字签名者" 会显示 "NVIDIA Corporation"（取 Subject CN）
- 但点"详细信息"，证书链里 **Issuer** 也是自签的 `CN=NVIDIA Corporation`，不是 `DigiCert High Assurance EV Root CA` 之类
- TP 如果做 cert chain 验证（`WinVerifyTrust` / `CertGetCertificateChain` 深查），**发现不是由 Microsoft Trusted Root 签发**会触发
- 多数 TP 只看 display name（Subject CN），不深查 chain —— 这种情况下伪造 "NVIDIA Corporation" 够用

**不能** 的是：让 Windows 认为这个自签是 NVIDIA 真实 CA 签发的。需要 NVIDIA 私钥（拿不到）。

## 方案 C（理论最强）— 方案 A + 自签 Subject = "NVIDIA Corporation"

把方案 A 的 self-signed cert 的 Subject 改成 `CN=NVIDIA Corporation`。这样：
- PCI layer GT 1030 真实
- 数字签名者显示 "NVIDIA Corporation"
- 只要 TP 不做深度 cert chain 验证，最 stealth

风险点：`bcdedit` 仍然曾经 `testsigning on` 过一次（import cert 时）。要完全不留痕，需要在**一开始装系统时就完全不开过 testsigning**（比如用 `certutil -addstore -f Root` 直接 import 不依赖 testsigning）。

---

## 方案 0 操作流程（5 步）

> 这是当前 VM1/VM2 实际操作流程；前置假设：QEMU stealth bundle 已编译过、`setup-bridge.sh` 已跑过一次。

```bash
# Host: 起 stealth HTTP 服务器（一次性，guest 用来拉 ps1/驱动/dll）
nohup python3 /home/ubuntu/projects/qemu/deploy/scripts/serve-stealth-http.py 8765 \
    &> /tmp/serve-http.log &

# Host: 启动新 VM（首次自动 reroll 整 profile，含 GPU/显示器/键鼠等池子）
/home/ubuntu/projects/qemu/deploy/scripts/start-vm.sh 1 \
    --iso=/mnt/disk2/iso/Win10_22H2_Chinese_Simplified_x64v1.iso
```

启动日志会显示 `=== stealth profile ===`，其中 `GPU` 那行是这次抽到的型号——`shallow-stealth.ps1` 会自动按 PCI subsys 匹配到同一个名字（无需手动指定）。

装完 Windows 10 22H2 + Windows Update 到 19045 后，guest 内：

```powershell
# 管理员 PowerShell，host 的 br0 IP 替换 192.168.30.33
irm http://192.168.30.33:8765/shallow-stealth.ps1 | iex
```

shallow-stealth.ps1 内部 4 步全自动跑完：
1. 下载 stock virtio-win viogpudo (MS-WHQL 签)
2. `pnputil /add-driver /install` → Windows 自动 PnP 绑定到 `VEN_1AF4&DEV_1050&SUBSYS_<XXXX>10DE`
3. 探测当前 PCI subsys → 反查 GPU 池映射表 → 调 `apply-gpu-spoof.ps1` 注册表覆盖
4. 显示最终状态，回车自动重启

重启后 `GPU-Z` / `Win32_VideoController.Name` / Device Manager 全部显示 profile 抽到的型号。

## QEMU patches 全清单 (deploy/patches/)

| 编号 | 文件 | 改的 |
|------|------|------|
| 0001 | cpu add ryzen3-1200 | `target/i386/cpu.c` 加 Ryzen3-1200/2300X 型号 |
| 0002 | kvm strip hypervisor | `target/i386/kvm/kvm.c` 擦 CPUID 0x1.ECX[31] 和 0x40000000-ff |
| 0003 | acpi oem spoof | 所有 ACPI 表 OEM_ID → `ALASKA / A M I` |
| 0004 | nvme samsung id | `hw/nvme/ctrl.c` 加 `use-samsung-id=on` 让 NVMe 走 Samsung IEEE OUI |
| 0005 | pci ids | xHCI / pcie-root-port / e1000e subsys 改成 AMD / ASUS 真值 |
| 0006 | smbios type17 双通道 + per-DIMM 唯一 SN | `hw/smbios/smbios.c`：`bank=P0 CHANNEL %C` / `loc_pfx=DIMM_%C2` 的 `%C` 按 DIMM 展开 A/B；`serial` 支持 `\|` 分隔的 per-DIMM 列表（`serial=SN1\|SN2`），让双通道两条内存各自唯一 SN（共用同 SN 是一眼假的伪造特征） |
| 0007 | pci gpu edid spoof | EDID 默认 `RHT/QEMU Monitor` → `SAM/SyncMaster` 类 |
| 0008 | virtio-gpu subsys | `x-pci-sub-vendor-id` / `x-pci-sub-device-id` cmdline 选项 |
| **0009** | **virtio-gpu edid strings** | virtio-vga 加 `edid-vendor=` / `edid-name=` / `edid-serial=` / `edid-width-mm=` / `edid-height-mm=` 五个 prop；virtio-gpu-base.c 传到 `qemu_edid_info`。让每 VM 用 profile 池里的不同显示器型号。 |
| **0010** | **usb-hid vid/pid/strings** | usb-kbd / usb-mouse / usb-tablet 加 `vendorid=` / `productid=` / `manufacturer=` / `product=` prop；`patched_desc` 副本机制覆写 const USBDesc；让每 VM 用不同品牌键鼠（Microsoft / Logitech / A4Tech / Rapoo / Dell / HUION / VEIKK / XP-Pen）。 |

## OVMF 自编 patches (deploy/firmware/edk2-patches/)

OVMF 源码在 `~/src/edk2`（edk2 主线 tag），通过 `deploy/tools/build-ovmf.sh` 一键重 build。当前 stealth patches：

| 编号 | 文件 | 改的 |
|------|------|------|
| 0001 | OvmfPkg-QemuVideoDxe-NVIDIA-1c81-GOP-whitelist.patch | `OvmfPkg/QemuVideoDxe/Driver.c::gQemuVideoCardList[]` 加 NVIDIA `0x10de:0x1c81` 条目，让 UEFI GOP driver 在 virtio-vga subsys 被 spoof 成 NVIDIA GTX 1050 时仍认得显卡，避免 "Display output is not active" 黑屏直到 viogpudo.sys 在 Windows 阶段加载。 |

build 时**强制** `-D TPM2_ENABLE=TRUE`（Ubuntu 默认 edk2 包关 TPM2 → guest tpm.msc 报 "找不到兼容的 TPM"）。Tcg2Dxe / Tcg2Pei / Tcg2ConfigDxe / Tcg2PlatformDxe 四个模块都进 FV，guest TBS 才能正常激活 TPM。

## 下一步如果继续 stealth 深化

| 补丁 | 位置 | stealth 收益 |
|------|------|-------------|
| CPUID leaf 0x16 (Processor Frequency) | `target/i386/cpu.c` 在 `x86_cpu_get_supported_feature_word` 或 CPUID 处理处补 | WMI `CurrentClockSpeed` 和 brand string 一致（都显示 3200 MHz 不是 QEMU 默认 2000）|
| SMBIOS type 4 (Processor 真实 serial/part) | `hw/smbios/smbios.c` 扩展 `qemu_smbios_type4_opts` | `wmic cpu get serialnumber,manufacturer,partnumber` 不再全空 |
| SMBIOS type 7 (Cache) | 同上新建 type 7 | 物理机都有 L1/L2/L3 cache 条目，VM 默认没 |
| SMBIOS type 9 (PCI slots) | 同上 | 真机有 PCIe slot 列表 |
| SMBIOS type 11 (OEM Strings) | 同上 | 真机 OEM 把 ASUS 串塞这 |
| `vmware-cpuid-freq=off` | start-vm.sh `-cpu ...,vmware-cpuid-freq=off` | 关掉 VMware 频率 CPUID leaf（我们 kvm=off 时本就不发，但显式关更干净）|
| ACPI DSDT QEMU 字样清理 | `hw/i386/acpi-build.c` 改 OEM ID / Creator ID | `wmic os get systemdirectory, oemid` 不再是 "BOCHS" 等 |
| Windows 注册表 QEMU 字样 | guest 侧 `HKLM\HARDWARE\DESCRIPTION\System` 下 SystemBiosVersion | `Get-ItemProperty ... | Select SystemBiosVersion` 不再有 "QEMU" |
| EDID 厂商/型号代码 vs. PNP HardwareID 自洽 | EDID `SAM C24F390` ↔ 注册表 `MONITOR\SAM<product_code>` | Win32_DesktopMonitor.PNPDeviceID 不再泄漏 QEMU0001 等 |

## Remote Display Adapter 隐藏命令（参考）

如果确定不用 RDP 图形（走 VNC / 物理屏）：

```powershell
# Permanently disable Remote Display Adapter (RDP still works via other paths)
$idd = Get-PnpDevice | Where-Object { $_.FriendlyName -match 'Remote Display' }
Disable-PnpDevice -InstanceId $idd.InstanceId -Confirm:$false
```

想完全让它不枚举：
```powershell
# 关 Remote Display Adapter 的 class filter driver
# HKLM\System\CurrentControlSet\Services\RdpIdd\Start = 4 (disabled)
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Services\RdpIdd' -Name Start -Value 4
# 重启后不再有 Remote Display Adapter (RDP 登录会走 Microsoft Basic Display Adapter，但我们 -vga none 也没了，session 0 console 本地即可)
```

注意：禁用后 RDP 的 fancy 远程绘图能力下降，可能变老的 XDDM 路径。

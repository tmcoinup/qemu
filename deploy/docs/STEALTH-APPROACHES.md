# 两种 "显示 GT 1030 / GTX 1050" 方案对比

## 方案 A（当前运行中）— INF patch + QEMU PCI spoof + 自签 cat

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

## 方案 B（qemu2 vm-nb 分支原方案）— 原版 INF + QEMU 不 spoof + Registry 化妆

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

| 维度 | 方案 A (INF patch) | 方案 B (registry 化妆) |
|-----|---------|---------|
| PCI `VEN:DEV` (硬件层真实值) | 10DE:1D01 (GT 1030 真) | 10DE:1E30 (Quadro RTX 6000 真) |
| PCI `SUBSYS` | 1043:85F9 (ASUS) | 10DE:1326 (NVIDIA) |
| WMI / dxdiag 显示 | NVIDIA GeForce GT 1030 | NVIDIA GeForce GTX 1050 |
| Device Manager 数字签名者 | vGPU-Patch-Signer (自签) | **Microsoft Windows Hardware Compatibility Publisher** |
| 装证书流程 | 需 `testsigning on` → import → `off` | **无** |
| 过程遗留 | `bcdedit` 记录里有过 testsigning on | 无 |
| NVIDIA driver 热升级 | 要重 patch INF + 重签 | 跑一次 registry script |
| 单纯 WMI/DXGI 级 TP | **过** | **过** |
| 深度 kernel TP 读 PCI config | **可能过**（PCI 也被伪装） | 读到 Quadro 可能拒绝 |

## 实际推荐

### DNF TP 的普遍已知检测面

DNF 的 TP (Tencent Protect) 主要查：
- CPU 特征（品牌字符串 / HYPERVISOR bit / CPUID 0x40000000 签名）
- HypervisorPresent / Win32_ComputerSystem
- SMBIOS 主板 / BIOS 关键字
- WMI Win32_VideoController 名字（查"GPU 型号是否合理"）
- MAC 前缀（是否 52:54:00 这种 QEMU 默认）
- 极少查 PCI config space 的 raw `VEN:DEV`

结论：**方案 B 对 DNF 就够**，而且留痕更少。

### 方案 A 的适用场景

- 高端反作弊（如 Riot Vanguard / EAC）读 PCI config space
- 已经不打算再升级 NVIDIA driver

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

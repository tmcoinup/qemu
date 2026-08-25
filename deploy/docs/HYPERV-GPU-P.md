# P-11 Hyper-V GPU-P 后端

P-11 是独立的 Windows Hyper-V GPU-P 产品线。它不使用 QEMU/WHPX 显卡、GPU
直通、RemoteFX、VioGpuDod、`respawn-stealth.exe` 或 NVAPI/ADL 身份投影。目标是让
多个 Generation 2 VM 共享宿主真实 NVIDIA/AMD GPU 分区，并在 Windows guest 中
加载与宿主匹配的官方签名 WDDM 用户态驱动。

## 实现边界

| 层 | P-11 行为 |
|---|---|
| VM 后端 | Hyper-V VMMS；`New-VM`、`Add/Set-VMGpuPartitionAdapter` |
| GPU 选择 | 运行时兼容枚举新版 `Get-VMHostPartitionableGpu` 与 Win10 `Get-VMPartitionableGpu`，只接受真实 `VEN_10DE`/`VEN_1002` |
| 多卡/多品牌 | `Auto` 在当前宿主真实可分区候选中稳定随机选择；不改厂商、型号或 AIB 字符串 |
| 多 VM 配额 | 按每张卡报告的 VRAM/Encode/Decode/Compute 上下限缩放并核算总量；可显式请求完整宿主报告配额 |
| Guest 驱动 | 从 Windows Hyper-V 宿主最终选中的 PnP 实例动态解析官方 WDDM 签名包，离线同步到 `HostDriverStore` |
| Guest 显示 | 只接受所选宿主真实型号；拒绝 virtio、VioGpuDod、IDD 和身份 shim |
| Guest Monitor | VM 关机同步时注入无凭据 LocalSystem 配置器；只注册一个无内核驱动的 P-11 控制台 Monitor 类设备 |
| Host IDD | 只在宿主盘点；可校验并静默运行用户显式提供的外部签名安装器 |
| 身份 | VMId + 256-bit seed；每 VM 首次生成并固定受支持的固件序列与静态 MAC；GPU 物理序列只读 |

微软的 GPU-P 架构由 guest `dxgkrnl` 经 VMBus 把硬件调用交给宿主 KMD，guest
保留厂商 UMD；所以 guest 显示宿主 GPU 型号、官方驱动和 `nvidia-smi` 并不表示
PCIe 整卡直通。架构说明见 [GPU paravirtualization](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/gpu-paravirtualization)。

## 支持等级

P-11 的代码不包含 GPU 型号、设备 ID 或驱动版本白名单。它在每台物理机上动态验证：

1. GPU 是否由当前 Hyper-V 模块的 partitionable GPU cmdlet 报告；
2. PCI vendor 是否为 NVIDIA 或 AMD；
3. PnP、官方签名驱动、服务和驱动文件关联是否唯一且一致；
4. 资源上下限和 partition 数是否足够；
5. guest 是否实际加载同型号、同版本的官方栈。

这不等同于厂商生产支持。微软当前的 Windows Server 2025 支持清单包括特定 NVIDIA
数据中心卡以及 AMD Radeon PRO V710；消费级 GTX 1060、RTX 4060 Ti 和多数 Radeon
在 Windows 10/11 客户端属于实验路径。它们即使被宿主报告为 partitionable，也必须
逐机完成驱动、3D、计算、编码和长稳测试。权威清单与前提见
[GPU partitioning](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/gpu-partitioning) 和
[GPU-P 故障排除](https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/troubleshoot-hyper-v-gpu-assignment-partitioning-passthrough-issues)。

当前自动 DriverStore 同步和严格 guest 验收只接受 Windows Hyper-V 宿主与 Windows
guest。Ubuntu/Linux 的内核模块和 `.so` 不能复制给 Windows guest 使用，QEMU/KVM
也不提供 Hyper-V GPU-P 的 VMBus/VRD 设备。P-11 不在 Linux 宿主上模拟同名显卡或
宣称提供多 VM GPU-P。

在消费级 Windows client 实验路径中，guest 不应把普通 GeForce/Adrenalin 安装器当作
PCI 直通驱动重复安装。P-11 从最终选中的 Windows 宿主 PnP 包复制官方签名 UMD、
DriverStore 及其明确关联的 System32/SysWOW64 文件到 guest 的 `HostDriverStore` 映射，
guest 内核侧仍是 Microsoft VRD。微软允许 guest Windows build 比宿主新或旧；P-11
因此不强制 build 相同，但只接受 x64 Windows 镜像，并以实际 D3D/厂商工具验收兼容性。
Windows Server 2025 的正式 NVIDIA/AMD vGPU 部署应遵循 IHV 的 host/guest 驱动与授权
流程，不能把消费级手工同步路径当作等价的生产支持。

## 宿主前提

- Windows Hyper-V 完整角色及 Hyper-V PowerShell 模块，不只是 WHPX；
- BIOS/UEFI 已开启虚拟化、IOMMU/VT-d/AMD-Vi，以及硬件要求时的 SR-IOV；
- NVIDIA 或 AMD 官方 Windows WDDM 宿主驱动已正常安装；Linux 驱动不适用；
- 管理员 PowerShell；
- Windows guest 使用 Generation 2 VHD/VHDX；不接受 qcow2；
- 配置和驱动同步时 VM 必须完全处于 `Off`。

VMate 启动时会先只读检查 P-11 环境；发现红项后通过 UAC 执行一次全量幂等修复，
再做独立复检。修复中心使用同一入口。创建或启动 P-11 时，管理员生命周期入口还会
重新读取一次真实状态，避免检测后被其它工具改写形成 TOCTOU 窗口。检查/修复范围包括
Hypervisor Platform、完整 Hyper-V、Hyper-V PowerShell、`hypervisorlaunchtype Auto`、
`vmms`、Hyper-V Administrators、partitionable GPU、版本锁定冷启动工件及外部内核/GPU
工具运行态，以及实际 ESP `EFI\Microsoft\Boot\bootmgfw.efi` 的 Microsoft 签名。
检测到样例或其它工具留下的外部启动加载器时，修复器先按 SHA-256 保存可回滚副本，
再从签名有效的 Windows 原版恢复源替换；P-11 VM 的宿主自动启动策略固定为 `Nothing`，
不能绕过受控冷启动入口。

当前 21 套自定义 CPU/主板使用测试签名的版本锁定宿主扩展。虽然纯 `host-native`
GPU-P 本身不依赖测试模式，为保证安装后的任意 profile 都能直接使用，当前 P-11
运行环境统一要求宿主 BCD 为 `TESTSIGNING=Yes`、`nointegritychecks=No`，且本次内核的
test signing 已实际生效。若配置与运行态不一致，VM 启动先失败关闭，修复器直接安排
15 秒后的宿主自动重启，不弹出重启确认，也不要求手动重启。启动后 LocalSystem
一次性任务会自动复检并在就绪后自删除；登录后通过 RunOnce 自动重新打开 VMate。
同一配置最多进行两次无人值守重启，仍不就绪时停止重启并继续阻断 VM，避免无限循环。
实验机对照验证表明恢复 Microsoft 启动管理器后可保留原 VBS/Device Guard 策略，无需
为了 P-11 关闭 VBS。改用生产签名扩展后可取消宿主测试模式要求。

上述动作只作用于宿主。P-11 guest 始终必须保持生产 Code Integrity，不允许 guest 的
`TESTSIGNING`、debug 模式或 `nointegritychecks`，也不会为了宿主修复而改写 guest BCD。

先做只读检查：

```powershell
powershell -ExecutionPolicy Bypass -File `
  deploy\windows\gpup\Get-VMateGpuPStatus.ps1
```

`PartitionableGpus` 必须至少有一个 `Ready=True` 的条目。若为空，P-11 不会通过修改
设备名称绕过宿主能力。每张卡的 `Resources.VRAM` 会同时给出 Total/Available/Min/Max/
Optimal；`FullHostVramQuotaAvailable=True` 只表示当前驱动报告的 Max 与 Total 相等。

P-11 会按所选 GPU 自己报告的 `ValidPartitionCounts` 规划容量；`PartitionCount` 不足时，
只在宿主没有该卡的既有或归属不明 adapter 时，事务化选择能容纳 `GuestCapacity` 的最小
有效值。已有数量足够时绝不降低。P-11 优先使用新版
`Set-VMHostPartitionableGpu`，并自动回退 Win10 的 `Set-VMPartitionableGpu`；
只有两者都不存在且当前数量不足时才停止。

## 全新镜像流程

P-11 不迁移 V-11 镜像。推荐创建空的 Generation 2 VHDX，先安装干净 Windows：

```powershell
powershell -ExecutionPolicy Bypass -File `
  deploy\windows\gpup\New-VMateGpuPVM.ps1 `
  -VMName p11-01 `
  -VhdPath D:\VMs\p11-01\system.vhdx `
  -CreateVhd `
  -VhdSizeBytes 127GB `
  -IsoPath D:\ISO\Windows.iso `
  -SwitchName 'Default Switch' `
  -Vendor Auto `
  -GuestCapacity 2 `
  -ProcessorCount 12 `
  -CpuMaximumPercent 90 `
  -CpuReservePercent 5 `
  -CpuRelativeWeight 200 `
  -HwThreadCountPerCore 2 `
  -ExposeVirtualizationExtensions:$false `
  -GpuPercentage 50 `
  -StartVM
```

此阶段只创建 VM、VHDX、随机 VMId 和持久化 256-bit 内部 seed，不给未安装系统的
磁盘复制驱动。完成
Windows 安装后正常关机，再运行：

```powershell
powershell -ExecutionPolicy Bypass -File `
  deploy\windows\gpup\Enable-VMateGpuP.ps1 `
  -VMName p11-01 `
  -Vendor Auto `
  -GuestCapacity 2 `
  -VramPercentage 50 `
  -EncodePercentage 50 `
  -DecodePercentage 50 `
  -ComputePercentage 50
```

创建器还会返回完整的 `ResumeArguments`。若创建阶段使用了 `-FullSharedGpuQuota`，恢复
参数和 `NextAction` 会保留该模式；不要安装完成后仅运行无参数的默认 50% 配置。

`Auto` 会复用创建时已经固定的真实 `InstancePath`，不会因候选顺序或重启改选其它卡。
要直接使用一块已经安装好干净 Windows 的独立 VHDX，可省略 `-CreateVhd/-IsoPath`；
创建器会在同一流程中同步驱动并配置 GPU-P。

## 基础 VHDX 独立克隆

基础盘必须是未挂载、无父盘、非重解析点的独立 `.vhdx`，并在制作时先在 guest
执行 `sysprep /generalize /oobe /shutdown`。创建器将它完整复制到每 VM 目录，核对长度后
原子提交，再调用 `Set-VHD -ResetDiskIdentifier`；不使用 differencing disk，也不会
让以后修改母盘影响已创建 VM。

```powershell
.\deploy\windows\gpup\New-VMateGpuPVM.ps1 `
  -VMName p11-clone-01 `
  -VhdPath D:\VMs\p11-clone-01\system.vhdx `
  -BaseImagePath D:\Base\win10-generalized.vhdx `
  -HardwareProfileId amd-am4-r3-1200-asus-prime-b350-plus `
  -Vendor Auto -StartVM
```

每次新建/克隆都生成新 VMId、虚拟磁盘 ID、BIOS GUID、固件/机箱/主板序列号、
静态 MAC 和 256-bit partition seed。Windows MachineGuid、计算机名和本地用户 SID 由 Sysprep
在首启重建。GPU-P 仍共享同一块物理 GPU：驱动若报告物理 GPU UUID/序列号，
多个 VM 可能相同，这不是可安全改写的逐 VM 身份。

## 成组硬件池与保真边界

P-11 从 `deploy\hardware\p11-platforms.json` 读取硬件 profile，并复用共享
`platforms.json` 与 `household-compatibility.json`。当前可选择 22 组：`host-native`、两组
经授权实验机观测的 LGA1700 参考、六组共享 Intel 平台，以及兼容矩阵去除一组等价别名后
得到的十三组 Intel/AMD 家用平台。CPU、主板、BIOS、内存和设备只能按整个
`HardwareProfileId` 选择，禁止分别随机后拼接；相同 CPU、主板、内存代际与速率的候选会
折叠为一组，不能靠重复别名虚增池大小。profile 在 VM 首次创建时写入身份清单，策略为
`select-once-no-reroll`；普通启动不能换 profile 或目录 revision。

例如选择 i5-13600KF / GALAX B760 参考束：

```powershell
.\deploy\windows\gpup\New-VMateGpuPVM.ps1 `
  -VMName p11-13600kf `
  -VhdPath D:\VMs\p11-13600kf\system.vhdx `
  -CreateVhd -IsoPath D:\ISO\Windows.iso `
  -HardwareProfileId lab-intel-i5-13600kf-galax-b760-metaltop-d4
```

该 profile 会真实应用标准 Hyper-V 支持的 20 vCPU、静态内存、CPU 调度参数、一次生成的
固件序号和静态 MAC。21 组自定义 profile 在没有显式传 GPU 配额时，默认使用经实验机
读回校准的 `Win10Reference100`：VRAM/Decode/Compute 都是 `1,000,000,000`，Encode 是
`9,223,372,036,854,775,808`（`2^63`）。这正是 pc01、pc02 在样例界面选择“GPU 100%”后
落入 Hyper-V 的值，不再把它误写成“Encode 50%”。该模式还使用 3GB Low MMIO、32GB
High MMIO、VM 配置版本 9.2，以及 VMConnect `Maximum/3840×2400`。宿主不支持 9.2，或
Encode 能力不是 `Total/Max=UInt64.MaxValue、Min=0` 时会在创建前停止。

显式传入 `-GpuPercentage` 会改用普通百分比；`-FullSharedGpuQuota` 则使用宿主报告的四项
完整最大值。也可以在不使用硬件 profile 时显式传 `-Win10ReferenceGpuQuota`。样例兼容档
与完整宿主档互斥，避免同一个“100%”标签对应两套编码值。

标准 Hyper-V 没有逐 VM 改写 CPUID brand、System/BaseBoard Manufacturer/Product、内存
条子、磁盘/NIC 型号或 GPU PnP 实例的公开接口。因此参考束会完整持久化这些观测元数据，
并标记 `IdentityFidelity=host-extension-required`、`FullIdentitySupported=False`；标准
启动入口绝不声称 guest 已经显示这些值。

P-11 现在另有经过授权实验机验证的版本锁定宿主扩展。它只允许 VM 从 Off 进入极短的
Paused 冷启动窗口，先定位并核对唯一 VID partition，再应用受限的 CPUID brand 叶；身份
启动链投影同一 profile 的 CPU/主板平台事实。`Start-VMateGpuPVM.ps1` 要求部署清单同时
锁定扩展、`vmwp/vid` 与 Microsoft hypervisor 摘要，任一步失败都会关闭本次 VM，禁止
普通启动后再运行中切换。`Confirm-VMateGpuPVMIdentity.ps1` 还会把同一 BootId 的 guest
直接 CPUID/CIM 回读写入证明。通用仓库中的未签名构建输出不能充当生产工件；目标宿主
更新后必须重新签名、生成摘要并全量复测。严格 `-RequireFullHardwareIdentity` 在缺少
同次 guest 回读时仍按设计拒绝，不能用“已保存 profile”冒充完整呈现。

冷启动入口使用 `Start-VM -AsJob` 提交异步启动，并在首次观察到 `Running` 时立即暂停；
同步 `Start-VM` 在繁忙宿主上可能延迟数秒返回，导致 Windows 先缓存宿主 CPU 名称。暂停
时点超过 0.25 秒会失败关闭，不能继续启动一个直接 CPUID 与 WMI 名称不一致的 guest。
授权实验机连续三次完整关机冷启动的暂停时点为 0.031、0.056、0.071 秒；三次直接 CPUID
和 `Win32_Processor.Name` 都回读 `13th Gen Intel(R) Core(TM) i7-13700F`。

Guest Windows servicing 可能用更新的 Microsoft 签名 `bootmgfw.efi` 替换已安装的
身份扩展。下次受控启动只在新文件 Authenticode 有效且签名为 Microsoft 时，
才会事务性轮换 stock backup 并重新安装扩展；未签名、签名无效或未知漂移仍失败
关闭。更新中任一步失败都会恢复 boot、stock、config 和 manifest，不需要用户确认。

该边界也与微软公开契约一致：
[`Msvm_VirtualSystemSettingData`](https://learn.microsoft.com/zh-cn/windows/win32/hyperv_v2/msvm-virtualsystemsettingdata)
公开的是 BIOS GUID 与 BIOS/BaseBoard/Chassis 序号；微软 HCS schema 的
[`Chipset`](https://github.com/microsoft/hcsshim/blob/7c9ff7f481383ff47524bade75d1b25d631b49ce/internal/hcs/schema2/chipset.go)
和
[`VirtualMachineProcessor`](https://github.com/microsoft/hcsshim/blob/7c9ff7f481383ff47524bade75d1b25d631b49ce/internal/hcs/schema2/virtual_machine_processor.go)
也没有 System/BaseBoard Manufacturer/Product 或 CPU brand 配置字段。

两组实验机参考分别是 i5-13600KF / GALAX B760 METALTOP D4 与 i7-13700F /
MSI B760M BOMBER WIFI。样例 guest 的 BaseBoard/BIOS serial 实际显示 `Default string`，
而宿主 VM 配置中的固件序号并未按相同值透传；P-11 因而只借鉴成组型号事实，不复制样例
序号或 MAC，每台新 VM 继续生成唯一值。

AMD CPU 路径使用 `AuthenticAMD` CPUID 厂商字符串，目前成组包含 Athlon II
X2 250 / M5A78L-M/USB3、Phenom II X4 955 / M5A78L-M/USB3、Athlon 200GE /
PRIME B350-PLUS 和 Ryzen 3 1200 / PRIME B350-PLUS。它们与 Intel profile 使用同一
完整性、冷启动和不可重抽门禁，不允许把 AMD CPU 与 Intel 主板拆开拼接。

AMD GPU 路径接受宿主真实 `VEN_1002` partitionable GPU，动态选取 AMD 官方
签名 DriverStore/KMD/UMD，在 guest 核对型号、版本、签名与 D3D11 hardware device。
AMD 验收明确禁止 NVAPI 残留，也不运行 `nvidia-smi`。当前自动化已完成 AMD
目录、厂商选择和驱动栈模拟回归；由于这台授权实验宿主只有 NVIDIA RTX
4060 Ti，AMD GPU 真机 D3D/编解码/长稳验收仍需在带 Radeon 的宿主上完成。

## 单显卡、显示器与直连输入

P-11 的终态策略是移除宿主合成显示控制器，guest 设备管理器只保留一张健康的
NVIDIA/AMD `VirtualRender` GPU-P 显卡，并通过 Hyper-V Enhanced Session/RDP 传输桌面。
这避免 `Microsoft Hyper-V Video` 成为第二张 Display adapter，但也意味着 VMConnect
basic mode 不再是可靠备用通道。执行单显卡转换前必须先验证 Enhanced Session/RDP。

GPU-P VRD 加远程会话本身不保证枚举 `Monitor` class devnode。P-11 在 VM 关机同步
DriverStore 时，同时把 `VMateGuestMonitorProvisioner.exe` 写入 guest，并在离线 SYSTEM
hive 注册 `VMateP11GuestProvisioner` LocalSystem 自动服务。服务在 guest 启动后通过
Windows SetupAPI 幂等注册且只保留一个 `VMate P-11 Virtual Console Monitor`；不需要
guest 凭据、确认或重启，也不安装 IDD、显示 miniport、`monitor.sys` 或任何自签名 guest
内核驱动，因此仍只有一张 Display adapter，guest 继续使用生产 Code Integrity。

该 Monitor 节点明确表示 P-11 虚拟控制台端点，不冒充物理面板、EDID 或扫描输出；实际
分辨率、刷新率和桌面传输仍以 Enhanced Session/RDP 与 `Msvm_VideoHead` 回读为准。
配置器每次启动只做自修复并将结果写入
`C:\ProgramData\VMate\GuestProvisioner\monitor-status.json`。

`Set-VMVideo Maximum 3840×2400` 是控制台允许的上限，不等于 guest 当前桌面模式。当前
分辨率和刷新率由 `Msvm_VideoHead` 回读；实验样例 pc01、pc02 分别实测为
1920×1080@60 和 1280×720@60。P-11 不通过自动登录或持久化密码强改用户桌面模式。

管理器输入固定使用 Hyper-V WMI v2 的 `Msvm_Keyboard` 与
`Msvm_SyntheticMouse`，不依赖 VNC 鼠标注入，也不允许运行中切换输入模型。启动本机桥：

```powershell
powershell -ExecutionPolicy Bypass -File `
  deploy\windows\gpup\Start-VMateHyperVInputBridge.ps1 `
  -Port 18082
```

桥只监听 `127.0.0.1`，兼容样例的 `/sendMouse`、`/getMousePosition`、
`/sendKey`、`/getResolution` 路径。键盘事件严格成对、重复 down/up 被抑制，批次失败和
管理器退出时会释放已记录的按键/按钮，避免一个按键连续输入。鼠标相对坐标在宿主转换为
当前视频头范围内的绝对坐标。每个会话的传输常量为 `DirectHyperVCim`，没有运行时模式
切换入口。若必须占用样例默认的 8082 端口，应先确认样例 API 未运行，避免端口冲突。

## 启动并严格验收 guest

自动验收通过 PowerShell Direct 临时复制验证模块；执行后立即删除，不安装服务，
也不在 guest 持久化凭据。调用者必须显式提供管理员凭据：

```powershell
$credential = Get-Credential
powershell -ExecutionPolicy Bypass -File `
  deploy\windows\gpup\Enable-VMateGpuP.ps1 `
  -VMName p11-01 `
  -StartVM `
  -ValidateGuest `
  -GuestCredential $credential `
  -StrictGuestDisplay:$false `
  -RequireNvidiaSmi
```

AMD VM 不传 `-RequireNvidiaSmi`。验证器要求：

- 只有一张健康、Present 的目标显示设备；
- 型号与所选宿主 PnP 名称完全一致；
- NVIDIA/AMD 官方 Provider、签名、版本和 UMD/WDDM 文件有效；
- 能创建真正的 D3D11 `HARDWARE` device，且不允许回退到 WARP；
- NVIDIA `nvidia-smi` 只返回一张同型号、同版本 GPU，并尽力记录其 `memory.total`；
- guest 内没有 GameViewer/IDD、virtio/VioGpuDod 或项目 NVAPI shim；
- 显式传 `-RequireMonitor` 时，只有一个健康、Code 0、无内核驱动的 P-11 Monitor 节点；
- 厂商工具能读取 GPU UUID/serial 时只作诊断记录，不把它当作可写的 VM 身份。

微软设计的 GPU-P VRD 默认可能与 `Microsoft Hyper-V Video` 同时枚举。默认严格模式
仍要求只有目标 GPU 一个 Present 节点，适合独立检测回归。面向 VMConnect 的正常管理
场景应传 `-StrictGuestDisplay:$false`：它只额外允许身份完整匹配的微软 VMBUS 控制台
节点处于健康状态或 Code 22，不允许第二张厂商/第三方显卡。P-11 不使用注册表隐藏；
宿主 IDD 也不能替代 guest 的 VMConnect 输出。

也可把 `Test-VMateGpuPGuest.ps1`、`VMate.GpuP.GuestValidation.ps1` 与
`VMate.GpuP.D3DValidation.ps1` 放在 guest 同一目录后手工执行。NVIDIA 示例：

```powershell
.\Test-VMateGpuPGuest.ps1 `
  -ExpectedVendor NVIDIA `
  -ExpectedGpuName '宿主状态输出中的精确名称' `
  -ExpectedDriverVersion '宿主状态输出中的精确版本' `
  -RequireNvidiaSmi `
  -RequireMonitor
```

## 与样例同口径检测

`Detect-VGpuP.ps1 -Json` 现在分别输出：

- `FunctionalGpuPSignalCount`：兼容旧 `GpuPSignalCount`，统计 Display 与 D3DKMT 的
  GPU-P 功能证据；
- `IntrinsicGpuPSignalCount`：只统计微软 D3DKMT `Paravirtualized` API 位；
- `ArtifactExposureSignalCount`：统计 Hypervisor 与 Display 层可见痕迹，数值越低越好。

用相同版本检测脚本采集 reference/candidate JSON 后执行：

```powershell
.\deploy\windows\gpup\Compare-VMateGpuPDetection.ps1 `
  -ReferenceJsonPath .\pc01.json `
  -CandidateJsonPath .\p11.json `
  -ReferenceLabel pc01 -CandidateLabel P11-Lab -Json
```

比较器要求 candidate 的功能信号不少于 reference、D3DKMT 固有信号不少于 reference，
且痕迹信号不多于 reference，才返回 `OverallParity=True`；不达标时进程退出码为 2。它也能
从旧检测 JSON 的 `Signals` 推导新指标。

2026-08-24 使用 SHA-256
`3FA3F1D8CCF9DDCAE517F0C889F7C3793F55F47E503B8CA3993A0F895CA702C1` 的同一检测器
完成冷启动复测：pc01、pc02、P11-Lab 的功能信号均为 2、D3DKMT 固有信号均为 1、
Hypervisor 暴露均为 1、Display 暴露均为 1、总痕迹均为 2。P11-Lab 分别对两台样例的
`OverallParity=True`，所有 delta 为 0。P11-Lab 同时保持四类完整宿主报告配额、0 个合成
显示控制器、1 个 GPU-P adapter、Enhanced Session Ready 与单个健康 RTX 4060 Ti 节点。
这只证明本项目同版本检测器策略下达到样例，不代表裸机不可区分；VMBus、
HostDriverStore 和 `D3DKMT_ADAPTERTYPE.Paravirtualized` 等固有事实仍然存在。

## 资源和多 VM

`GpuPercentage`/四个资源百分比不是虚构显存。P-11 把百分比换算到该物理卡自己报告的
Min/Max 边界，再把所有 VM 的最大配额求和；默认超出总量会停止。`-AllowOvercommit`
只允许操作者显式接受调度超配，不会增加物理显存、编码器或 partition 数。

`-GuestCapacity` 是希望这张物理 GPU 至少容纳的 VM 数，不是当前 VM 独占的份数；其值
必须能映射到厂商报告的有效 partition 数。更改宿主分区拓扑可能影响既有 VM，因此一旦
发现目标卡已有 adapter，P-11 不会自动改拓扑，而会要求先安全停用相关分配。

guest 中出现与宿主相同的“6 GB/16 GB”等型号文字不代表每台 VM 各自独占整卡显存。
应以实际 GPU-P 配额、压力测试及宿主监控为准。

若目标实验组合允许每台 VM 配置为宿主驱动报告的完整 GPU-P 显存额度，可显式使用：

```powershell
powershell -ExecutionPolicy Bypass -File `
  deploy\windows\gpup\Enable-VMateGpuP.ps1 `
  -VMName p11-01 `
  -GuestCapacity 2 `
  -FullSharedGpuQuota
```

`-FullSharedGpuQuota` 把 VRAM/Encode/Decode/Compute 请求都设为 100%，并显式接受
P-11 的多 VM 配额 overcommit。它只有在所选驱动报告的
`MaxPartitionVRAM == TotalVRAM` 时才继续，配置后还会回读 12 个 adapter 配额字段；
否则在写 adapter 前停止。输出中的 `QuotaMode=FullHostReportedGpuPQuota`、
`FullHostVramQuota=True` 只表示这些 **GPU-P 配额字段** 相等，不表示：

- guest UI、DXGI 或 `nvidia-smi` 必然显示板卡标称的 6 GB/16 GB；
- 每台 VM 得到一份新的物理显存或可以同时占满整卡；
- 编解码器、计算单元或性能被复制；
- Hyper-V/厂商驱动一定接受所有 VM 同时高负载运行。

`-Win10ReferenceGpuQuota` 是不同的兼容语义：只有 Encode 使用 Win10 样例的有符号边界
`2^63`，其余三项仍取 100%。它同样显式接受多 VM overcommit，但会先核验 Encode 哨兵
能力形状；它与 `-FullSharedGpuQuota` 不能同时使用。

消费级驱动有时会自然向每个 guest 报告同一型号和总显存；P-11 只记录这种实测结果，
不会改注册表或注入 shim 去制造它。受支持服务器 GPU 常按 `PartitionCount` 报告较小的
partition 上限，此时该模式会按设计拒绝。`GuestCapacity` 只规划可用 partition 数，和每
VM 的百分比是两个独立维度；overcommit 也不会增加物理资源。

微软把 `MaxPartitionVRAM` 定义为 partition 中出现的最大显存额度；服务器配置也明确
说明改变 `PartitionCount` 会改变每份显存大小。参见
[Msvm_GpuPartitionSettingData](https://learn.microsoft.com/en-us/windows/win32/hyperv_v2/msvm-gpupartitionsettingdata) 和
[Partition and assign GPUs](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/partition-assign-vm-gpu)。

## 每 VM 随机身份与品牌

P-11 采用“首次随机、随后固定”的身份生命周期。默认创建 VM 时使用系统 CSPRNG 生成身份，
原子保存到 `%ProgramData%\VMate\GpuP\<VMId>\identity.json` 的
`HardwareIdentity`，再在 VM 完全关闭时应用。重启、重新启用 GPU-P、更新驱动或重复执行
创建恢复流程都复用原值，不会重新抽取；只有新的 Hyper-V VMId 才生成一套新身份。

首次创建时也可以显式提供固件五字段和一张网卡的 locally-administered unicast MAC；
未提供的字段仍随机生成。显式值同样写入身份清单并遵守 no-reroll，后续传入不同值会失败，
不会静默换号。序列字段接受 4..64 位字母、数字、空格、点、下划线和连字符：

```powershell
.\deploy\windows\gpup\New-VMateGpuPVM.ps1 `
  -VMName p11-profile-01 `
  -VhdPath D:\VMs\p11-profile-01\system.vhdx `
  -BIOSGUID '{12345678-1234-4234-9234-1234567890AB}' `
  -BIOSSerialNumber 'BIOS-REAL-0001' `
  -BaseBoardSerialNumber 'BOARD-REAL-0001' `
  -ChassisSerialNumber 'CHASSIS-REAL-0001' `
  -ChassisAssetTag 'ASSET-REAL-0001' `
  -StaticMacAddress '02AABBCCDDEE'
```

这些是 Hyper-V 公开的固件序列字段，不是主板 Manufacturer/Product/SKU 的任意改写。
最终是否由特定 guest build 原样呈现，仍以冷启动后的 `GuestObserved` 为准。

当前由宿主官方 Hyper-V 接口管理且可逐 VM 固定的字段为：

- `BIOSGUID`、`BIOSSerialNumber`、`BaseBoardSerialNumber`；
- `ChassisSerialNumber`、`ChassisAssetTag`；
- 创建时已经存在的每张 Hyper-V 虚拟网卡的 locally-administered unicast 静态 MAC；
- Hyper-V VMId、256-bit `PartitionIdentitySeed` 和首次选中的真实 GPU `InstancePath`。

固件字段通过 `Msvm_VirtualSystemSettingData`/`ModifySystemSettings` 事务写入；静态 MAC 在
宿主全部 Hyper-V 网卡和 P-11 已保存身份中做碰撞检查。Win10 上 BIOSGUID 首次改写后
可能不能改回，因此流程先持久化 `Prepared` 期望值，先提交可回滚的 MAC，最后才写固件；
失败时保留同一组期望值供幂等重试，不承诺回滚 BIOSGUID，也不会重新抽号。没有虚拟网卡
时明确记录 `NotPresent`，不会为了生成 MAC 而擅自增加设备。

宿主 `State=Applied` 且 `HostObserved.Match=True`（即 HostApplied）只表示 Hyper-V
WMI/cmdlet 接受了设置且宿主回读一致，**不等于** Windows guest 已经显示同一个值。
不同 Hyper-V/Windows 版本可能继续向 guest 返回空值、平台默认值或经过规范化的值。
使用 `Enable-VMateGpuP.ps1 -StartVM -ValidateGuest` 时，P-11 会在 PowerShell Direct
临时会话中读取 `Win32_BIOS`、`Win32_BaseBoard`、`Win32_SystemEnclosure`、
`Win32_ComputerSystemProduct` 和物理网卡，生成来源为
`WindowsCimColdBootReadback` 的证据；五个固件字段和 MAC 全部匹配后才原子保存
`GuestObserved.Match=True`。未运行 guest 验收时该值仍为 `null`，明确表示“未验证”。
凭据和验证脚本不会写入状态清单，临时 guest 目录在会话结束时删除。

以下字段没有受支持的逐 VM 随机接口，P-11 不用注册表、驱动 shim 或字符串投影绕过：

- CPU 厂商、型号、序列和 CPUID；
- DIMM SPD、内存条序列及内存控制器身份；
- Hyper-V 合成 SCSI/VMBus 控制器厂商、PCI ID、固件和序列，以及 guest 磁盘 serial；
- NVIDIA/AMD 物理 GPU serial、UUID、厂商、型号和显存规格。

## CPU 配置档与真实边界

`New-VMateGpuPVM.ps1` 和 `Set-VMateGpuPComputeProfile.ps1` 支持 Hyper-V 官方公开的
`Count`、`Maximum`、`Reserve`、`RelativeWeight`、
`HwThreadCountPerCore` 与 `ExposeVirtualizationExtensions`。独立修改现有 VM 的示例：

```powershell
.\deploy\windows\gpup\Set-VMateGpuPComputeProfile.ps1 `
  -VMName p11-01 `
  -ProcessorCount 12 `
  -CpuMaximumPercent 90 `
  -CpuReservePercent 5 `
  -CpuRelativeWeight 200 `
  -HwThreadCountPerCore 2 `
  -ExposeVirtualizationExtensions $false
```

命令要求 VM 为 `Off`，先读取快照，写入后逐项回读，失败时恢复全部 CPU 字段；
`-DryRun` 不写配置。它对应“CPU 线程/占用/虚拟化/SMT 拓扑”，不改变 guest 所见
CPU 品牌、厂商、ProcessorId 或 CPUID。P-11 不弹窗切换模型，也不在 VM 运行中改配置。

P-11 也不会为了制造 guest 磁盘 serial 而改写 VHDX `VirtualDiskId`：该字段不保证映射为
guest 所见序列，而且会永久修改调用者提供的磁盘文件。Windows 安装在 guest 内自行创建
的 GPT/分区/卷标识不属于 Hyper-V 硬件身份，也不由本层重抽。

多卡宿主用 seed 在稳定排序后的真实候选池中选择，所以可以随机落到宿主实际存在的
AMD/NVIDIA/不同板卡，但一张物理 NVIDIA 卡不会显示成 AMD 或其它 AIB 品牌。
`PartitionId`/`PartitionVfLuid` 和厂商工具返回的 GPU UUID 只是平台观察值。普通
`nvidia-smi --query-gpu=uuid` 可能在共享同一物理 GPU 的多台 guest 中返回相同值，这不
构成 VM 身份碰撞。NVIDIA GRID/vGPU 的随机 UUID 语义只适用于对应产品，不能推断到普通
消费级 Windows GPU-P。参考
[NVIDIA vGPU identification properties](https://docs.nvidia.com/vgpu/7.0/grid-management-sdk-user-guide/index.html#abstract-vgpu-identification-properties-that-do-not-apply-to-a-vgpu)。

旧 Win10 的 `Add-VMGpuPartitionAdapter` 可能没有 `-InstancePath`。P-11 只在宿主返回的
全部 partitionable GPU 恰好一个、没有空名或重复项时省略该参数，并在添加后回读确认；
否则在首次写入前停止。多卡/多品牌稳定选择要求本机 Hyper-V cmdlet 支持显式路径。

## 宿主 IDD

GameViewer Virtual Display Adapter 一类 IddCx 驱动只负责宿主虚拟 monitor、桌面采集和
远程显示，不负责 GPU 分区。P-11 不携带 GameViewer 私有文件，也绝不把 IDD 安装到
guest。`Get-VMateGpuPStatus.ps1` 会只读列出宿主 IDD。

P-11 当前不实现 IDD 到某台 VM 的帧采集、传输或输入控制链。GPU-P 可提供 3D，但要
达到 GameViewer 的完整远程显示效果，仍需保留 GameViewer 或接入独立的 RDP/采集方案。

## 操作 VM 与区域推流

P-11 不运行 QEMU，因此旧的 QEMU `fb-shm` object、`qemu-fb-shm-stream.exe` 和
`stream-fb-shm.ps1` 不能读取 Hyper-V VM 的画面。GPU-P 只提供渲染/计算加速，不提供
帧传输或键鼠通道。当前可用的官方交互路径是：

- 安装系统和应急控制使用 VMConnect basic mode；
- 日常桌面使用 VMConnect enhanced mode 或 RDP；enhanced mode 本身使用 terminal
  session remoting；
- 自动化命令、文件复制和 guest 验收使用带显式 guest 凭据的 PowerShell Direct。

P-11 提供事务化 Enhanced Session 配置入口。它固定使用 VMConnect/RDP over VMBus，
显式接收只用于本次 PowerShell Direct 会话的 `PSCredential`，不会把凭据写入文件；同时
启用 RDP、硬件图形适配器、H.264/AVC 硬件编码和 AVC 4:4:4 策略。任一 guest 步骤失败
会恢复 guest 注册表、服务状态和原宿主 Enhanced Session 设置：

```powershell
$credential = Get-Credential
.\deploy\windows\gpup\Enable-VMateHyperVEnhancedSession.ps1 `
  -VMName p11-01 -GuestCredential $credential

# 若结果 RestartRequired=True，先正常关机，再通过该 profile 的固定冷启动入口启动。
.\deploy\windows\gpup\Connect-VMateGpuPVM.ps1 -VMName p11-01
```

控制台入口只启动 Microsoft 签名的 inbox `vmconnect.exe`，不注入鼠标/键盘，也不在运行
中切换 CPU、主板或 GPU profile。Basic mode 仍作为安装和故障恢复路径保留。

如果验收明确要求设备管理器只保留 GPU-P 显卡，P-11 还提供可选的
`EnhancedSessionGpuOnly` 拓扑。它在 VM 完全关机时通过 Hyper-V WMI
`RemoveResourceSettings` 移除合成显示控制器，既不禁用 guest PnP 节点，也不修改
ClassGUID、驱动或代码完整性策略。变更前必须已经启用 Enhanced Session/VMBus，并且 VM
必须恰好有一个 GPU partition adapter：

```powershell
$receipt = 'C:\ProgramData\VMate\GpuP\p11-01-display-topology.json'
.\deploy\windows\gpup\Set-VMateGpuPDisplayTopology.ps1 `
  -VMName p11-01 -ReceiptPath $receipt

# 仍通过绑定 profile 的冷启动入口启动，随后只使用 Enhanced Session 连接。
.\deploy\windows\gpup\Start-VMateGpuPVM.ps1 -VMName p11-01 `
  -ArtifactManifestPath C:\ProgramData\VMate\GpuP\cpuid-artifacts.json
.\deploy\windows\gpup\Connect-VMateGpuPVM.ps1 -VMName p11-01
```

该模式没有 VMConnect basic-mode 画面；PowerShell Direct 仍可用于自动验收。恢复时先正常
关闭 VM，再使用同一 receipt 加回合成显示控制器并恢复原分辨率：

```powershell
.\deploy\windows\gpup\Restore-VMateGpuPDisplayTopology.ps1 `
  -VMName p11-01 -ReceiptPath $receipt
```

receipt 在移除前原子写入；写入、移除或回读失败会自动恢复。该拓扑解决的是“双 Display
设备”与 basic console 竞争问题，不会伪装 VMBus、VRD、HostDriverStore 或
`D3DKMT_ADAPTERTYPE.Paravirtualized`，因此不能把它表述为裸机或虚拟化隐藏功能。

如果不需要宿主与 guest 之间的 KVP 元数据交换，可选启用 `MinimalHostMetadata`。
它通过 Hyper-V 官方 integration-service 接口仅禁用 Key-Value Pair Exchange；服务停止后
清理 guest 中遗留的 `Virtual Machine\Guest\Parameters`（其中包含宿主名称、VM 名称和
VM ID）。PowerShell Direct、Enhanced Session、Heartbeat、Shutdown、Time Sync、VSS 与
GPU-P 均不在修改范围内。禁用 KVP 会失去这部分宿主/guest 元数据交换及依赖它的监控信息，
因此必须显式选择并保存 receipt：

```powershell
$credential = Get-Credential
$receipt = 'C:\ProgramData\VMate\GpuP\p11-01-metadata-exchange.json'
.\deploy\windows\gpup\Disable-VMateGpuPMetadataExchange.ps1 `
  -VMName p11-01 -GuestCredential $credential -ReceiptPath $receipt

# 恢复原 KVP enable 状态和清理前的 guest Parameters 值。
.\deploy\windows\gpup\Restore-VMateGpuPMetadataExchange.ps1 `
  -VMName p11-01 -GuestCredential $credential -ReceiptPath $receipt
```

该模式不安装 guest 服务或计划任务，不持久化凭据，也不拦截注册表/PnP 查询；VMBus 和
`D3DKMT_ADAPTERTYPE.Paravirtualized` 等 GPU-P 固有信号仍会如实存在。

参见微软的 [GPU-P 桌面远程方式](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/gpu-paravirtualization#remoting-of-the-vmcontainer-desktop)、
[VMConnect](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/virtual-machine-connection) 和
[PowerShell Direct](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/powershell-direct)。

“只推指定显示器、窗口或矩形区域”目前未实现。它必须作为与 GPU-P 分离的媒体后端：
在 guest 内经用户明确选择后用 Windows Graphics Capture/Desktop Duplication 取得帧，
按裁剪区域编码，再通过经过认证的 VMate 通道传输；输入侧还要处理分辨率/DPI 坐标映射、
焦点和按键去重。宿主 GameViewer IDD 不能直接变成 guest 的采集源。Windows Graphics
Capture 的能力边界见 [Screen capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture)。

## 干净 guest 与可检测边界

P-11 的“干净”定义是：不安装 guest IDD/GameViewer、virtio/VioGpuDod、
`respawn-stealth.exe`、NVAPI/ADL 投影 shim 或伪造的显卡身份；D3D 实际加载的必须是
目标 NVIDIA/AMD 官方签名 UMD。驱动同步会保留可审计的 HostDriverStore 清单和恢复材料，
不会为了隐藏虚拟化而删除证据。

这不等于“与裸机不可区分”。除上述显式 KVP 最小化选项外，P-11 不修改 WMI/注册表查询
结果；官方 GPU-PV 架构本身仍可能通过 VRD、VMBus、
HostDriverStore、Hyper-V 系统信息以及禁用后仍 Present/Code 22 的 Hyper-V Video 节点被
识别。P-11 不修改内核枚举、WMI 查询或厂商 API 来隐瞒这些事实，也不承诺绕过虚拟机
检测。若验收要求硬件拓扑与裸机完全一致，只能使用整卡直通；该方案明确不属于 P-11。

如需安装合法获得的宿主 IDD，可 dot-source `VMate.GpuP.Display.ps1` 后调用
`Invoke-VMateSignedHostIddInstaller`。它要求安装包位于仓库外、Authenticode 为
`Valid`、Publisher 与调用者固定值匹配，并使用静默参数。IDD 模型说明见
[Indirect display driver model](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/indirect-display-driver-model-overview)。

## 更新、状态与停用

宿主升级显卡驱动后，VM 完全关机并同步同版本 guest 文件：

```powershell
.\deploy\windows\gpup\Update-VMateGpuPDriver.ps1 -VMName p11-01
.\deploy\windows\gpup\Get-VMateGpuPStatus.ps1 -VMName p11-01
```

只删除 GPU-P adapter、保留官方驱动文件和身份以便重启用：

```powershell
.\deploy\windows\gpup\Disable-VMateGpuP.ps1 -VMName p11-01
```

所有配置入口均提供 `-DryRun`。创建/配置不启动 guest，除非显式传 `-StartVM`；不会
弹出模型切换，也不会在运行中更换已固定的物理 GPU。

## 回归与实机验收

Linux CI 可执行静态、配额、路径和事务合同：

```bash
bash deploy/scripts/tests/test_windows_gpup_host.sh
bash deploy/scripts/tests/test_windows_gpup_partition.sh
bash deploy/scripts/tests/test_windows_gpup_driverstore.sh
bash deploy/scripts/tests/test_windows_gpup_display.sh
bash deploy/scripts/tests/test_windows_gpup_workflow.sh
```

最终发布必须再在目标 Windows 物理机验证：两个以上 VM 并发 D3D 11/12、厂商计算
API、NVENC/NVDEC 或 AMF、显存压力、驱动升级/回滚、宿主睡眠/重启及长稳。当前 Linux
开发机不能替代 Hyper-V 真机验收；仅看到设备名称或一次 `nvidia-smi` 成功不足以判定
资源隔离和稳定性。

# P-11 Hyper-V GPU-P 后端

P-11 是独立的 Windows Hyper-V GPU-P 产品线。它不使用 QEMU/WHPX 显卡、GPU
直通、RemoteFX、VioGpuDod、`respawn-stealth.exe` 或 NVAPI/ADL 身份投影。目标是让
多个 Generation 2 VM 共享宿主真实 NVIDIA/AMD GPU 分区，并在 Windows guest 中
加载与宿主匹配的官方签名 WDDM 用户态驱动。

## 实现边界

| 层 | P-11 行为 |
|---|---|
| VM 后端 | Hyper-V VMMS；`New-VM`、`Add/Set-VMGpuPartitionAdapter` |
| GPU 选择 | 运行时枚举 `Get-VMHostPartitionableGpu`，只接受真实 `VEN_10DE`/`VEN_1002` |
| 多卡/多品牌 | `Auto` 在当前宿主真实可分区候选中稳定随机选择；不改厂商、型号或 AIB 字符串 |
| 多 VM 配额 | 按每张卡报告的 VRAM/Encode/Decode/Compute 上下限缩放并核算总量；可显式请求完整宿主报告配额 |
| Guest 驱动 | 从 Windows Hyper-V 宿主最终选中的 PnP 实例动态解析官方 WDDM 签名包，离线同步到 `HostDriverStore` |
| Guest 显示 | 只接受所选宿主真实型号；拒绝 virtio、VioGpuDod、IDD 和身份 shim |
| Host IDD | 只在宿主盘点；可校验并静默运行用户显式提供的外部签名安装器 |
| 身份 | Hyper-V VMId + VMate 256-bit 随机 seed；PartitionId/VfLuid 只记录平台分配值，物理序列只读、不伪造 |

微软的 GPU-P 架构由 guest `dxgkrnl` 经 VMBus 把硬件调用交给宿主 KMD，guest
保留厂商 UMD；所以 guest 显示宿主 GPU 型号、官方驱动和 `nvidia-smi` 并不表示
PCIe 整卡直通。架构说明见 [GPU paravirtualization](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/gpu-paravirtualization)。

## 支持等级

P-11 的代码不包含 GPU 型号、设备 ID 或驱动版本白名单。它在每台物理机上动态验证：

1. GPU 是否由 `Get-VMHostPartitionableGpu` 报告；
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
有效值。已有数量足够时绝不降低。旧 Win10 Hyper-V 模块若没有
`Set-VMHostPartitionableGpu`，只有当前数量已经足够时才可继续。

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
  -DisableHyperVVideo `
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
- 厂商工具能读取 GPU UUID/serial 时只作诊断记录，不把它当作可写的 VM 身份。

微软设计的 GPU-P VRD 默认可能与 `Microsoft Hyper-V Video` 同时枚举。P-11 可以只
禁用明确匹配的 Microsoft 节点；部分 Windows build 禁用后仍保留一个 Code 22 devnode。
默认严格模式会因此失败，因为项目不使用注册表隐藏。确认接受“唯一健康 GPU + 一个已
禁用微软 devnode”时，可显式传 `-StrictGuestDisplay:$false`；这不允许第二张健康显卡。
禁用 `Microsoft Hyper-V Video` 可能让 VMConnect basic mode 黑屏；操作前必须先验证
PowerShell Direct、RDP 或其它远程通道可用。宿主 IDD 不能替代 guest 的 VMConnect 输出。

也可把 `Test-VMateGpuPGuest.ps1`、`VMate.GpuP.GuestValidation.ps1` 与
`VMate.GpuP.D3DValidation.ps1` 放在 guest 同一目录后手工执行。NVIDIA 示例：

```powershell
.\Test-VMateGpuPGuest.ps1 `
  -ExpectedVendor NVIDIA `
  -ExpectedGpuName '宿主状态输出中的精确名称' `
  -ExpectedDriverVersion '宿主状态输出中的精确版本' `
  -RequireNvidiaSmi
```

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

消费级驱动有时会自然向每个 guest 报告同一型号和总显存；P-11 只记录这种实测结果，
不会改注册表或注入 shim 去制造它。受支持服务器 GPU 常按 `PartitionCount` 报告较小的
partition 上限，此时该模式会按设计拒绝。`GuestCapacity` 只规划可用 partition 数，和每
VM 的百分比是两个独立维度；overcommit 也不会增加物理资源。

微软把 `MaxPartitionVRAM` 定义为 partition 中出现的最大显存额度；服务器配置也明确
说明改变 `PartitionCount` 会改变每份显存大小。参见
[Msvm_GpuPartitionSettingData](https://learn.microsoft.com/en-us/windows/win32/hyperv_v2/msvm-gpupartitionsettingdata) 和
[Partition and assign GPUs](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/partition-assign-vm-gpu)。

## 随机身份与品牌

创建 VM 时生成并持久化：

- Hyper-V VMId；
- 256-bit `PartitionIdentitySeed`；
- 首次选中的真实 GPU `InstancePath`；
- Hyper-V 分配并由 P-11 观测到的 `PartitionId`/`PartitionVfLuid`；
- 厂商工具返回的 GPU UUID 观察值（物理/虚拟 scope 未知）。

同一 VM 重启不会重抽内部 seed；新 VM 得到新 seed。多卡宿主用 seed 在稳定排序后的
真实候选池中选择，所以可以随机落到真实 AMD/NVIDIA/不同板卡，但一张物理 NVIDIA 卡
不会被显示成 AMD 或其它 AIB 品牌。seed 只参与选择和审计，绝不写入厂商驱动、固件或
guest 可见标识。P-11 不生成、修改或保证 guest 可见的 serial/UUID；serial 常为 `N/A`，
UUID 仅在厂商工具实际返回时记录。普通 `nvidia-smi --query-gpu=uuid` 可能报告共享物理
GPU 的 UUID，多台合法 guest 出现相同值不构成碰撞。NVIDIA GRID/vGPU 文档中的随机 UUID
语义只适用于该产品，不能据此推断普通消费级 Windows GPU-P。参考
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

## 干净 guest 与可检测边界

P-11 的“干净”定义是：不安装 guest IDD/GameViewer、virtio/VioGpuDod、
`respawn-stealth.exe`、NVAPI/ADL 投影 shim 或伪造的显卡身份；D3D 实际加载的必须是
目标 NVIDIA/AMD 官方签名 UMD。驱动同步会保留可审计的 HostDriverStore 清单和恢复材料，
不会为了隐藏虚拟化而删除证据。

这不等于“与裸机不可区分”。官方 GPU-PV 架构本身仍可能通过 VRD、VMBus、
HostDriverStore、Hyper-V 系统信息以及禁用后仍 Present/Code 22 的 Hyper-V Video 节点被
识别。P-11 不修改内核枚举、WMI/注册表或厂商 API 来隐瞒这些事实，也不承诺绕过虚拟机
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

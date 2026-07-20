# GPU 身份方案：当前实现与历史路径

本文只说明项目中 GPU 身份、驱动绑定与图形能力之间的关系。当前发布流程只有一条
受支持路径：保持 virtio-gpu 的物理主 PCI ID，使用原签名显示驱动，再在用户态提供
一致的逻辑身份。历史 VFIO 与自签路径仅用于解释设计差异，不再提供操作步骤。

## 结论

- 物理主 PCI ID 固定为 `1AF4:1050`，确保 Windows 能绑定 stock、Microsoft-WHQL
  `VioGpuDod`。
- PCI subsystem 配置为 vendor `10DE`、device `1C82`。Windows PnP 实例字符串通常
  写成 `SUBSYS_1C8210DE`；按 vendor:device 表示时，它对应 `10DE:1C82`。
- 注册表身份与 x86/x64 系统搜索 NVAPI 把用户态逻辑身份投影为
  `NVIDIA GeForce GTX 1050 Ti` / `10DE:1C82`。
- SetupAPI HardwareID 使用“逻辑首项 + 完整物理数组”；InstanceId、PCI 配置空间和
  `VioGpuDod` 绑定仍为 `1AF4:1050`。
- 用户态逻辑 `10DE:1C82` 不会改写 PCI config space；读取原始 PCI 配置的组件仍会
  看到主 ID `1AF4:1050`。
- 当前路径不安装 NVIDIA 驱动，不使用 patched driver、自签证书、testsigning、
  EfiGuard 或 `GPU_SELFSIGNED` 深层模式。
- 身份投影不增加 Windows 客体的 Direct3D、CUDA、NVENC 或 NVIDIA GPU 性能。

## 方案对比

| 维度 | 当前：virtio 浅层投影 | 历史：VFIO + 原版驱动 | 历史：改版驱动 + 自签 |
| --- | --- | --- | --- |
| 项目支持状态 | 唯一受支持方案 | 不属于当前发布流程 | 已退役，禁止恢复 |
| 物理 GPU | 不需要直通 GPU | 需要可直通的物理 GPU | 依具体旧实现而定 |
| 原始主 PCI ID | `1AF4:1050` | 物理设备的真实 ID | 由旧版硬件/驱动改动决定 |
| 用户态逻辑身份 | `10DE:1C82`，GTX 1050 Ti | 通常跟随物理设备与原版驱动 | 可能与原始硬件不一致 |
| Windows 显示驱动 | stock Microsoft-WHQL `VioGpuDod` | 原厂驱动 | patched driver / 自签链 |
| 系统目录 NVAPI | 固定摘要 x86/x64 用户态 shim | 由原厂驱动管理 | 旧实现可能全局安装 |
| 客体 GPU 计算/编码 | 无 CUDA/NVENC | 取决于直通硬件与驱动 | 不作保证 |
| 维护与信任边界 | 固定摘要、原签驱动、单 EXE | 依赖 IOMMU、硬件与原厂栈 | 破坏原签名，维护成本高 |

## 当前受支持方案

### 1. 物理设备与驱动绑定

QEMU 向客体提供的显示设备主 ID 是 `1AF4:1050`。这是驱动绑定事实，不能用注册表
或 NVAPI shim 改变。subsystem 携带逻辑 profile 的 vendor/device，即
`10DE:1C82`；它只为上层身份映射提供输入，不会把设备变成原生 NVIDIA PCI 设备。

客体初始化首先枚举在线 PCI 显示设备，并在任何名称写入前确认：

1. 物理主 ID 是 `1AF4:1050`；
2. 实际服务已经绑定为 `VioGpuDod`；
3. 使用的 INF/SYS/CAT 是构建时锁定摘要的 stock 驱动，并保留
   Microsoft Windows Hardware Compatibility Publisher 签名。

任一条件不满足时流程应当失败关闭，不能仅把 Microsoft Basic Display Adapter 或
其他显示设备改名后当作安装成功。物理主 ID 若直接改成 `10DE:1C82`，stock
`VioGpuDod` 不再具备对应的正常绑定条件，因此不属于当前方案。

### 2. 注册表用户态身份

驱动验证成功后，初始化脚本才会按当前 subsystem 生成版本化身份，并写入
`HKLM\SOFTWARE\StealthGPU`。1050 Ti profile 的关键逻辑值包括：

- 名称：`NVIDIA GeForce GTX 1050 Ti`
- vendor：`10DE`（十进制 `4318`）
- device：`1C82`（十进制 `7298`）
- 模式：`shallow-user-projection`

随后脚本同步 Windows 显示设备相关的名称字段。该层服务于设备管理器、WMI 和普通
用户态诊断接口，但它不改变原始 PCI 配置，也不让 NVIDIA 内核驱动接管设备。

### 3. 双架构系统搜索 NVAPI

发布 payload 同时包含 PE32 `nvapi.dll` 与 PE32+ `nvapi64.dll`，分别服务于 32 位和
64 位工具。GPU-Z 2.70 主程序是 PE32，因此统一 EXE 将 x86 文件事务发布到 SysWOW64，
并把 x64 文件发布到 System32 供内嵌辅助组件使用。

两个架构都只枚举一个 NVAPI 物理句柄。`NvAPI_GPU_GetPCIIdentifiers` 使用同一块
OS 显示适配器的承载主键 `1AF4:1050`，并复用 QEMU 已真实写入 PCI 配置空间的
subsystem、revision 和 BDF；名称、显存、时钟及外部产品号仍来自 NVIDIA profile。
因此同时使用 SetupAPI/PCI 与 NVAPI 的系统级硬件扫描器会把两条信息合并到一个设备，
不会再把 `Red Hat VirtIO` 承载层和 NVIDIA 用户态身份误列成两块显卡。
DLL 初始化会用 SetupAPI 与 Configuration Manager 重新绑定 `SourceInstanceId`：
唯一在线 `1AF4:1050` devnode、`VioGpuDod`、完整物理 HardwareID 回退条目和实际
BDF 必须全部与 snapshot 一致；否则不枚举厂商 API 设备。AMD ADL 同样把验证后的
真实 UDID、PNP 和 Driver path 返回给调用方，不再合成第二个 AMD PNP 实例。
此外，启动/登录刷新会逐项回读 `FriendlyName`、`DeviceDesc`、`Mfg`、
`DriverDesc`、`ProviderName` 和 `HardwareInformation.AdapterString`；身份名称必须
以 canonical 厂商开头，并显式拒绝 `Red Hat`/`VirtIO`。即使第三方工具再次拆分枚举，
通过 Windows SetupAPI/WMI 显示的承载项也仍使用 profile 中的 NVIDIA 名称。
AMD RX 550/RX 560 使用相同的 SUBSYS、身份事务、名称刷新和 HardwareID 投影链路，
对应字段写为 `AMD Radeon ...` / `AMD`。NVAPI 是 NVIDIA 专用接口；AMD profile
不会伪造 NVAPI 句柄，而是明确返回“无 NVIDIA 设备”，因此不会额外枚举一张 N 卡。

这个机制具有明确边界：

- 只接受当前或历史 VMate 固定摘要，拒绝覆盖真实 NVIDIA/未知 DLL；
- 直接忽略 Windows 显示字段、只按原始 PCI `1AF4` 厂商数据库命名的工具仍可能显示
  `Red Hat`；彻底改变该层需要非 stock 驱动，本分支为保持 WHQL `VioGpuDod` 不这样做；
- 不修改工具原目录；
- 不修改全局 `PATH`；
- 不创建全局 NVAPI 安装标记；
- 两个架构先完整 staging，提交失败时跨架构回滚；
- 影响所有通过标准系统搜索加载这两个名称的用户态进程。

系统发布恢复了 Git 历史中的 GPU-Z 直接双击语义，并补齐 PE32 主程序所需的 x86
路径。真实 Windows 客体中的端到端界面结果仍需验证，不能仅凭文件搜索与 ABI 单元
测试承诺所有字段一定显示为预期值。

### 4. 统一 guest-stealth EXE

`deploy/guest-stealth/dist/respawn-stealth.exe` 是唯一受支持的客体发布物。它内嵌并
校验 stock 显示驱动、初始化脚本以及双架构 NVAPI payload，以固定顺序完成驱动确认、
身份持久化、名称同步和双架构系统 NVAPI 发布。

当前发布流程不再使用 host HTTP 提供松散脚本，也不安装 NVIDIA 驱动或常驻服务。
系统级内容只增加两份固定摘要的用户态 DLL、项目脚本和两条 Windows 内置计划任务；
历史脚本入口仅保留为明确报错的退役入口，不能作为兼容安装路径。

## 图形能力边界

stock `VioGpuDod` 是 Display-Only 驱动。它负责 Windows 显示输出和模式枚举，但不是
NVIDIA WDDM 3D 驱动。因此，即使用户态显示 GTX 1050 Ti 和 `10DE:1C82`：

- Windows 客体也不会获得 GTX 1050 Ti 的 Direct3D 加速；
- 不会获得 CUDA；
- 不会获得 NVENC/NVDEC；
- 不会获得真实 NVIDIA 驱动的性能、功能集或遥测。

host 侧使用 `virtio-vga-gl`、virgl、EGL 或 GPU handle，只说明 host 显示/传输路径可能
使用 GPU。它不等价于 Windows 客体加载了可提供 Direct3D 的 virtio 3D 驱动，不能用
host 日志中的 GL 成功信息推导客体具有 3D 加速。

## 历史路径的概念差异

### VFIO + 原版驱动

VFIO 把物理 GPU 交给客体，原始 PCI ID、驱动绑定和图形能力都来自真实硬件。它可能
提供原生 3D、计算和编码能力，但需要合适的物理 GPU、IOMMU 隔离、复位支持以及原厂
驱动。这是硬件直通架构，不是当前 virtio 浅层投影的增强开关，也不属于当前统一 EXE
的安装范围。

### patched driver / 自签路径

旧实现曾通过修改驱动匹配或签名链来配合不同的原始 PCI 身份。这类路径会失去原始
发布者签名的一致性，并引入证书、启动策略和驱动升级维护成本。当前实现已移除相关
安装能力，不接受自签驱动，也不会借助 EfiGuard 或深层模式恢复它。

浅层方案与上述历史路径不能混用：浅层方案依赖 `1AF4:1050` 与 stock `VioGpuDod`
这一完整绑定关系；VFIO 则应由真实硬件和对应原厂驱动形成自己的完整关系。

## 验证口径

当前方案完成后，应分别验证三个层面，避免把名称变化误判为底层能力变化：

| 层面 | 期望事实 |
| --- | --- |
| 驱动层 | 在线 PCI 显示设备主 ID 为 `1AF4:1050`，服务为 `VioGpuDod` |
| 用户态身份层 | profile 为 GTX 1050 Ti，逻辑 vendor/device 为 `10DE:1C82` |
| 能力层 | Windows 客体仍按 Display-Only 路径工作，无 CUDA/NVENC/原生 NVIDIA 3D |

具体打包、客体初始化与诊断方式见
[`guest-stealth/README.md`](../guest-stealth/README.md) 和
[`VM-WORKFLOW.md`](VM-WORKFLOW.md)。GPU-Z 2.70 的最终判定必须以真实客体端到端验证
为准。

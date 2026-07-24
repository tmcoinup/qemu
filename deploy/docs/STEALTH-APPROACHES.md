# GPU 身份方案：当前实现与历史路径

本文只说明项目中 GPU 身份、驱动绑定与图形能力之间的关系。当前发布流程只有一条
受支持路径：保持 virtio-gpu 的物理主 PCI ID，使用原签名显示驱动，再在用户态提供
一致的逻辑身份。历史 VFIO 与自签路径仅用于解释设计差异，不再提供操作步骤。

## 结论

- 物理主 PCI ID 固定为 `1AF4:1050`，确保 Windows 能绑定 stock、Microsoft-WHQL
  `VioGpuDod`。
- 物理 PCI subsystem 使用 `1AF4:A101`–`1AF4:A112` carrier 选择完整 AIB profile；
  例如 Colorful GTX 1050 Ti 是 `SUBSYS_A1021AF4`。逻辑主 ID `10DE:1C82` 与该板卡
  自身的 `7377:0000` subsystem 分开保存，不能把 device ID 当成 subsystem。
- identity schema-2 的 `SpoofName` 保留完整 AIB canonical 标签用于校验；Windows
  展示字段与 x86/x64 系统搜索 NVAPI 按 `10DE:1C82` 统一映射为标准
  `NVIDIA GeForce GTX 1050 Ti`。
- PnP HardwareID 属于同一个 VioGpuDod devnode：MULTI_SZ 首项是规范逻辑
  VEN/DEV/AIB SUBSYS/REV，后续逐项保留完整物理 `1AF4:1050` 数组；这不是两张卡。
- NVAPI 主 PCI 关联键保持物理 `1AF4:1050` 以便跨接口归并；external device、AIB
  SUBSYS/REV、标准型号和独显类型保持逻辑 NVIDIA 身份。
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
或 NVAPI shim 改变。物理 subsystem 使用 `1AF4:A101`–`1AF4:A112` carrier 选择
上层 profile；逻辑 `10DE:1C82` 和真实 AIB subsystem 保存在版本化快照与厂商 API
中，不会把设备变成原生 NVIDIA PCI 设备。

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
`HKLM\SOFTWARE\StealthGPU`。以 Gigabyte 1050 Ti profile 为例，关键逻辑值包括：

- `SpoofName`：`NVIDIA GeForce GTX 1050 Ti (Gigabyte OC)`
- Windows 标准显示名：`NVIDIA GeForce GTX 1050 Ti`
- vendor：`10DE`（十进制 `4318`）
- device：`1C82`（十进制 `7298`）
- 模式：`shallow-user-projection`

identity snapshot 仍是 schema-2。新的 transaction schema-5 把按 PCI VEN/DEV
封闭映射得到的标准芯片名写入 Enum `FriendlyName`/`DeviceDesc`、Class
`DriverDesc`、`HardwareInformation.AdapterString` 和
`HardwareInformation.ChipType`，并把 Enum `Mfg` 与 Class `ProviderName` 写为
芯片厂商。`MatchingDeviceId`、`InfPath`、`InfSection`、`Service` 仍保持 stock
`VioGpuDod` 值；transaction schema 1/2/3/4 仅用于恢复旧 journal。该层服务于设备
管理器、SetupAPI、WMI 和普通用户态诊断接口，但不改变原始 PCI 配置，也不让厂商
内核驱动接管设备。

schema-5 把 PnP HardwareID 投影为“规范逻辑首项 + 完整物理尾项”。这些字符串都属于
唯一的物理 `1AF4:1050` devnode；InstanceId、BDF、MatchingDeviceId、Driver、
Service 和 PCI 配置空间不变。对于 4 GiB profile，NVAPI legacy `MemoryInfo`
v1/v2/v3 与 frame-buffer size 接口返回 `4194304 KiB`，`MemoryInfoEx` v1 返回
`4294967296 bytes`。旧 32 位
`HardwareInformation.MemorySize` 饱和为 `2047 MiB`
（`0x7FF00000`），确保错误按有符号 Int32 读取它的旧工具仍得到正数；64 位
`HardwareInformation.qwMemorySize` 与相应厂商接口精确保存 `4 GiB`。
历史 schema-4 journal 只参与恢复，并按原语义重建 `4095 MiB`。

### 3. 双架构系统搜索 NVAPI

发布 payload 同时包含 PE32 `nvapi.dll` 与 PE32+ `nvapi64.dll`，分别服务于 32 位和
64 位工具。GPU-Z 2.70 主程序是 PE32，因此统一 EXE 将 x86 文件事务发布到 SysWOW64，
并把 x64 文件发布到 System32 供内嵌辅助组件使用。

两个架构都只枚举一个 NVAPI 物理句柄。`NvAPI_GPU_GetPCIIdentifiers` 的主
`deviceId` 有意返回物理 `1AF4:1050` carrier，作为 PnP/BDF/NVAPI 的跨接口关联键；
subsystem、revision、external device 与标准型号来自同一个已验证 NVIDIA 逻辑
profile。该句柄通过 InstanceId、BDF、Service 和规范 HardwareID 数组唯一绑定到真实
carrier；逻辑返回值不会合成第二个 devnode。
DLL 初始化会用 SetupAPI 与 Configuration Manager 重新绑定 `SourceInstanceId`：
唯一在线 `1AF4:1050` devnode、`VioGpuDod`、规范逻辑首项 + 完整物理尾项的
HardwareID 数组和实际 BDF 必须全部与 snapshot 一致；否则不枚举厂商 API 设备。AMD
ADL 同样把验证后的
真实 UDID、PNP 和 Driver path 返回给调用方，不再合成第二个 AMD PNP 实例。
此外，启动/登录刷新会逐项回读 `FriendlyName`、`DeviceDesc`、`Mfg`、
`DriverDesc`、`ProviderName` 和 `HardwareInformation.AdapterString`；这些名称/
厂商展示面必须来自受控 PCI 主 ID 映射，并显式拒绝 `Red Hat`/`VirtIO`。因此通过
标准 SetupAPI、Class 注册表、WMI 或厂商 API 枚举的工具都读取同一个标准芯片名和
厂商；真实绑定仍由保持 stock 的 `MatchingDeviceId`、INF、Service 与 physical-only
HardwareID 尾项证明。AMD RX 550/RX 560 使用相同的 carrier、身份事务和名称刷新链路，
逻辑 VEN/DEV、AIB SUBSYS 与独显拓扑由 ADL 回答，对应展示字段写为
`AMD Radeon ...` / `AMD`。NVAPI 是 NVIDIA 专用接口；AMD profile
不会伪造 NVAPI 句柄，而是明确返回“无 NVIDIA 设备”，因此不会额外枚举一张 N 卡。

这个机制具有明确边界：

- 只接受当前或历史 VMate 固定摘要，拒绝覆盖真实 NVIDIA/未知 DLL；
- 直接忽略 Windows 显示字段、只按原始 PCI `1AF4` 厂商数据库命名的工具仍可能显示
  `Red Hat`；彻底改变该层需要非 stock 驱动，本分支为保持 WHQL `VioGpuDod` 不这样做；
- NVAPI 主 `deviceId` 与真实 PnP carrier 同为 `1AF4:1050`，用于跨接口关联；型号与
  AIB 信息必须读取 external device、subsystem/revision 和标准名称，不能把关联键误当
  成逻辑 NVIDIA 主 ID；
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
系统级内容只增加固定摘要的用户态 DLL、项目脚本、名称刷新任务和
`StealthGPU-ProjectHardwareId` 维护任务。重跑时先停用 writer 并临时恢复
physical-only 数组完成驱动/PnP 门禁，事务提交后再由
`project-gpu-hardware-id.ps1` Apply/Verify 规范逻辑首项 + 完整物理尾项，并注册
启动/登录维护。其它历史脚本入口仅保留为明确报错的退役入口，不能作为兼容安装路径。

## 图形能力边界

stock `VioGpuDod` 是 Display-Only 驱动。它负责 Windows 显示输出和模式枚举，但不是
NVIDIA WDDM 3D 驱动。因此，即使用户态显示 GTX 1050 Ti 和 `10DE:1C82`：

- Windows 客体也不会获得 GTX 1050 Ti 的 Direct3D 加速；
- 不会获得 CUDA；
- 不会获得 NVENC/NVDEC；
- 不会获得真实 NVIDIA 驱动的性能、功能集或遥测。

host 侧使用 `virtio-vga-gl`、virgl、EGL 或 GPU handle，只说明 host 显示/传输路径可能
使用 GPU。它不等价于 Windows 客体加载了可提供 Direct3D 的 virtio 3D 驱动，不能用
host 日志中的 GL 成功信息推导客体具有 3D 加速。stock `VioGpuDod` 的 DXGI adapter
描述、真实 InstanceId/BDF/Service/Driver 和直接读取 PCI 配置空间的工具仍会看到
物理 virtio 身份；SetupAPI 同时可见逻辑首项和物理尾项，NVAPI/ADL 的受支持查询
返回逻辑厂商 AIB 与独显类型。以上身份投影不会增加渲染能力、可分配显存或性能。

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
| 驱动层 | 只有一个在线 `1AF4:1050` PCI 显示 devnode，真实 BDF/Service/Driver 不变，服务为 `VioGpuDod` |
| 用户态身份层 | HardwareID 为规范 `10DE:1C82` 首项 + 完整 `1AF4:1050` 尾项；NVAPI 主关联键为物理 carrier，external/AIB/型号为逻辑 NVIDIA |
| 能力层 | Windows 客体仍按 Display-Only 路径工作，无 CUDA/NVENC/原生 NVIDIA 3D |

具体打包、客体初始化与诊断方式见
[`guest-stealth/README.md`](../guest-stealth/README.md) 和
[`VM-WORKFLOW.md`](VM-WORKFLOW.md)。GPU-Z 2.70 的最终判定必须以真实客体端到端验证
为准。

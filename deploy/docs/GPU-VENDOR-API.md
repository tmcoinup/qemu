# GPU 厂商 API 系统兼容层

本分支保持唯一的真实显示承载设备 `PCI\VEN_1AF4&DEV_1050` 和 stock
`VioGpuDod` 驱动，不做 GPU passthrough、vGPU 或厂商内核驱动替换。为了让不同硬件
检测工具从用户态入口读取到同一份逻辑身份，guest 安装包同时携带 NVIDIA NVAPI 和
AMD ADL 的兼容层，但系统搜索目录只保留当前 profile 对应的一个厂商。

当前 schema-2 目录覆盖 6 个芯片型号，每个型号 3 个板卡品牌，共 18 块 AIB：
12 块 NVIDIA 使用 NVAPI，6 块 AMD 使用 ADL。`1AF4:A101`–`1AF4:A112`
仅是内部 carrier；唯一物理显示设备始终为 `1AF4:1050`。目录没有
`GPU_SERIAL` 或其它标准、可核验的显卡序列来源，因此兼容层不会合成序列号。

identity schema 保持为 2，`GPU_NAME`/`SpoofName` 是完整 AIB canonical 标签。
该标签只用于原子校验 AIB bundle；Windows Enum/Class、NVAPI 与 ADL 的公开
adapter 名称都按已经通过校验的逻辑 PCI VEN/DEV 映射标准芯片名，不会从 AIB
字符串裁剪括号。

这不是 GPU-Z、HWiNFO 或 AIDA64 的进程专用适配。DLL 不读取进程名，也不按调用者
返回不同结果；所有调用者都读取
`HKLM\SOFTWARE\StealthGPU\Identities\<CurrentIdentity>` 指向的同一个版本化快照。ADL
仅在调用方显式请求 `Refresh` 时重新验证并替换其进程内快照；刷新失败会保留最后一次
验证通过的快照，同时向该次调用返回错误。

## 推荐的 clone 基线

基础镜像应保持厂商中立：不需要预先运行 `respawn-stealth.exe`，也不预发布 VMate
NVAPI/ADL 系统 DLL。clone 创建自己的宿主 GPU profile，首次启动再由注入的
FirstLogon 命令启动一次 EXE；EXE 从当前 clone 的 PCI SUBSYS 选择 AMD/NVIDIA，必要
重启由自身的 resume 状态自动续跑。迁移状态机仍兼容已经运行过旧版 respawn 的基础盘，
以便现有 AMD/NVIDIA base 可以交叉克隆，但新基础盘不再主动制造这类继承状态。

## 分层关系

| 层 | 数据来源 | 保持一致的内容 |
| --- | --- | --- |
| PCI / PnP / 驱动 | QEMU `1AF4:1050` + `VioGpuDod` | 唯一 devnode 的真实 InstanceId、BDF、Service、Driver 与驱动绑定保持物理 |
| SetupAPI / Enum/Class 展示 | 严格投影 | HardwareID 为规范逻辑首项 + 完整物理尾项；标准芯片名、厂商、显存来自同一 identity |
| NVIDIA NVAPI | `nvapi.dll` / `nvapi64.dll` | 主 `deviceId` 为物理 carrier 关联键；标准芯片名、DGPU、显存、VBIOS、时钟、external device 与 AIB SUBSYS/REV 为逻辑身份 |
| AMD ADL / ADL2 | `atiadlxy.dll` / `atiadlxx.dll` | 标准芯片名、独显拓扑、显存、VBIOS、核心信息、逻辑 AIB 身份、静态时钟与 BDF |

NVIDIA profile 只发布 NVAPI，AMD profile 只发布 ADL。统一 EXE 仍携带两套受验
payload，方便同一个安装包处理不同 clone；真正的发布目标来自已经完成物理载体、
SUBSYS、schema 与 pointer 校验的 staged identity，而不是 clone 从 base 继承的旧
`CurrentIdentity`。profile 跨厂商切换时，协调事务同时收口非目标厂商的受管残留，
避免系统 DLL 搜索把两个厂商 API 一起装入同一进程。

## 系统搜索位置

统一 EXE 携带并校验以下文件；每次运行只把当前 profile 对应的一组留在系统目录：

```text
# NVIDIA profile
C:\Windows\SysWOW64\nvapi.dll
C:\Windows\System32\nvapi64.dll

# AMD profile
C:\Windows\SysWOW64\atiadlxy.dll
C:\Windows\SysWOW64\atiadlxx.dll
C:\Windows\System32\atiadlxx.dll
```

`SysWOW64\atiadlxx.dll` 与 `atiadlxy.dll` 使用同一份 PE32 实现。部分 32 位检测工具
会先尝试 `atiadlxx.dll` 再回退到 `atiadlxy.dll`；同时管理两个名称可避免旧文件在
标准回退之前截获调用。`System32\atiadlxx.dll` 则是独立的 PE32+ 实现。

安装器只接受当前项目摘要或显式登记的历史项目摘要。非目标厂商文件也只有命中受管
摘要时才允许移出系统搜索目录。若任一目标是未知 DLL，包括真实 NVIDIA/AMD 驱动安装
的厂商 DLL，所有目标会在第一次系统文件 Move 之前停止，且不修改所有权、ACL、签名
策略或启动链。

## 身份读取合同

两个厂商 API reader 都固定打开 64 位注册表视图，并遵守：

1. 读取 `CurrentIdentity`；
2. 打开对应的不可变 `Identities\<token>`；
3. 用 SetupAPI 枚举当前 PRESENT Display，并用 Configuration Manager 复读同一
   devnode：`SourceInstanceId` 必须精确匹配且唯一、实际 BDF 必须等于 snapshot；
4. 要求唯一的物理 `PCI\VEN_1AF4&DEV_1050` 载体和 `VioGpuDod` Service，并精确验证
   `HardwareID` MULTI_SZ：首项必须是当前 identity 生成的规范逻辑
   VEN/DEV/SUBSYS/REV，其后必须逐项、逐序等于原始完整 `VEN_1AF4&DEV_1050` 数组；
5. 读取实际 `SPDRP_DRIVER` 与 Display class 子键，确认后才生成 ADL Driver 路径；
6. 再次读取 pointer 与 schema；
7. 只有前后完全一致才发布进程内快照。

NVAPI 严格接受 12 块 NVIDIA `10DE` AIB；ADL 严格接受 6 块 AMD `1002`
AIB（RX 550 / RX 560 各 3 个品牌），并在返回 `ABSENT` 前完整验证 NVIDIA
板卡。两者在完整验证 schema-2 `SpoofName` 后，按相同 PCI VEN/DEV 封闭映射返回
标准芯片名，与 Windows Enum `FriendlyName`/`DeviceDesc`、Class `DriverDesc`、
`HardwareInformation.AdapterString` 和 `HardwareInformation.ChipType` 保持一致。
NVAPI 的 `GetPCIIdentifiers` 使用分层关联语义：主 `deviceId` 返回物理
`1AF4:1050` carrier，作为 PnP/BDF/NVAPI 的跨接口去重键；AIB
subsystem/revision 与 external device 来自同一个 NVIDIA 逻辑 profile。
`GetGPUType` 明确返回 DGPU，名称接口返回标准 NVIDIA 型号。该组合让多源工具把结果
归并到唯一 devnode，同时不把真实 InstanceId、BDF、Service 或 Driver 改成 NVIDIA。
AMD profile 同样从 ADL 的单卡、非 PowerXpress 拓扑和逻辑 AIB bundle 回答用户态
身份。真实 virtio 主 ID 与驱动绑定只由前述载体门禁维护。
Enum `Mfg` 与 Class `ProviderName` 使用同一芯片厂商。NVAPI legacy
`NvAPI_GPU_GetMemoryInfo` v1/v2/v3 与 legacy frame-buffer size 接口以 KiB 为单位，
4 GiB 返回 `4194304 KiB`；`NvAPI_GPU_GetMemoryInfoEx` v1 以 bytes 为单位，返回
`4294967296 bytes`。这两套 ABI 不能互换。4 GiB profile 的旧 32 位
`HardwareInformation.MemorySize` 饱和为 `2047 MiB`（`0x7FF00000`），确保错误
按有符号 Int32 读取它的旧工具仍得到正数；64 位
`HardwareInformation.qwMemorySize` 与相应 NVAPI/ADL 精确保存 `4 GiB`。厂商不匹配、
字段缺失、Red Hat/VirtIO 名称泄漏、SUBSYS/REV/BDF 交叉校验失败、实际实例缺失、
出现第二个物理 virtio Display，或 HardwareID 不是精确的“规范逻辑首项 + 完整物理
尾项”时均 fail closed。

## 通用 ADL 能力

ADL 实现基于 AMD GPUOpen 发布的公开 ADL/ADL2 C ABI，同时提供 32 位未修饰
`__cdecl` 导出和 64 位导出。通用检测路径包括：

- ADL1/ADL2 初始化、销毁和 adapter 枚举；
- adapter active/accessibility、名称和真实载体 BDF；`AdapterInfo.strUDID`、
  `strPNPString`、`strDriverPath`/`strDriverPathExt` 直接来自经验证的 Windows
  InstanceId、物理 HardwareID 条目和 Driver class 路径，不合成 AMD PNP 实例；
- 显存容量/类型/带宽、VBIOS、graphics core 信息；
- Overdrive capability、默认/当前静态核心与显存时钟；
- 单卡、非 CrossFire/PowerXpress 的拓扑回答。

温度、风扇、负载、功耗、电压、PMLog 和 I²C 没有可信的真实硬件数据源。相关接口返回
AMD 官方 `ADL_ERR_NOT_SUPPORTED`，写接口同样拒绝；兼容层不会把固定值冒充实时遥测。

AMD 官方 ABI 参考：

- <https://gpuopen-librariesandsdks.github.io/adl/>
- <https://github.com/GPUOpen-LibrariesAndSDKs/display-library>

## 跨组件事务

identity、目标厂商 reader 与非目标厂商清理使用同一个 32 位大写 GUID
TransactionId，但保留独立 durable journal。NVAPI 的既有两项 receipt schema 不扩成
四项或五项，确保升级中的旧收据仍能恢复。

提交顺序固定为：

1. 先以 `Vendor=Auto` 恢复 identity、NVAPI、ADL 的遗留 journal；Auto 同时校验
   reservation、receipt、identity terminal State 和精确 pointer，不采用 base 的旧厂商值；
2. 从当前唯一在线的 `1AF4:1050` 载体读取 SUBSYS，Stage 新 identity；
3. 严格回读 staged identity；coordinator 要求 identity schema-2、transaction
   schema-5、Prepared、`PendingIdentity=TransactionId`、current=previous，并把
   snapshot 的 `SpoofVendor` 作为本事务唯一厂商参数；
4. 创建以 TransactionId 为 owner 的 GPU API coordinator 持久 reservation；
5. 对目标厂商发布和非目标厂商受管残留做全量只读预检；
6. Prepare 对应 durable receipt；
7. Commit `CurrentIdentity`，再 Complete identity；
8. 使用同一个 staged vendor Finalize，删除旧备份并释放 reservation。

如果 GPU-Z、鲁大师等已运行进程仍映射着被原子改名的历史 DLL，Windows 可能只拒绝
删除旧 backup，而新目标、identity 和 receipt 都已经完整提交。此时 Finalize 仅对
原生错误码 5/32 进入 `CleanupDeferred`：再次核对 canonical 路径、普通文件类型和
receipt 中的精确 SHA-256，保留 receipt/reservation，并由统一入口只安排一次重启。
重启后的 `Recover` 重新做同样校验后再删除；若跨过启动边界仍失败，则停止自动重试，
保留 journal 供排查。流程不会修改 ACL、杀死硬件工具，也不会登记未经重启复核的
按路径延迟删除。

reservation 从 Prepare 保持到 Finalize/Rollback；任何新的 Prepare（不同或相同
TransactionId）都不能进入该窗口。失败时先恢复旧 identity pointer，再按相反方向恢复
目标 reader 与非目标清理。若 identity 已 durable 完成而 Finalize 中断，下次启动的
`Vendor=Auto` 只在 `Completed/current` 时 Finalize，或在
`RolledBack/previous-pointer` 时 Rollback；Prepared/Committed、厂商不符或后续事务
pointer 均保留 reservation 并 fail closed，避免提前或跨事务恢复。

这里的 schema-5 只属于 identity transaction：它发布标准 Windows Enum/Class
名称、厂商、兼容 32 位消费者的显存字段，以及同一 devnode 的规范逻辑 HardwareID
首项；原始完整 `1AF4:1050` 数组作为尾项保留，`MatchingDeviceId`、`InfPath`、
`InfSection`、`Service` 也保持 stock。identity snapshot 本身仍是 schema-2。
transaction schema 1/2/3/4 不再用于新提交，只在启动时兼容恢复旧 journal；历史
schema-4 恢复仍按原语义重建 legacy `MemorySize=4095 MiB`。

## 能力边界

厂商 API 兼容层只统一用户态硬件查询，不改变真实 PCI vendor/device，不提供厂商
WDDM 驱动、Direct3D、CUDA、OpenCL、NVENC、AMF 或真实显存/时钟控制。检测工具展示的
型号规格是 profile 投影，不代表虚拟机获得对应物理 GPU 的性能或功能。SetupAPI
可见逻辑首项和物理尾项；stock `VioGpuDod` 的 DXGI 描述、真实
InstanceId/BDF/Service/Driver 以及直接读取 PCI 配置空间的工具仍可看到
virtio/`1AF4:1050`。系统不会因此多出第二个显卡设备，也不会改变渲染路径、显存分配
或性能。

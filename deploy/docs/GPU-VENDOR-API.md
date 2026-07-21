# GPU 厂商 API 系统兼容层

本分支保持唯一的真实显示承载设备 `PCI\VEN_1AF4&DEV_1050` 和 stock
`VioGpuDod` 驱动，不做 GPU passthrough、vGPU 或厂商内核驱动替换。为了让不同硬件
检测工具从用户态入口读取到同一份逻辑身份，guest 安装包同时携带 NVIDIA NVAPI 和
AMD ADL 的兼容层，但系统搜索目录只保留当前 profile 对应的一个厂商。

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
| PCI / 驱动 | QEMU `1AF4:1050` + `VioGpuDod` | InstanceId、Service、真实 BDF、驱动绑定 |
| SetupAPI / WMI | Enum/Class 严格投影 | 名称、厂商、显存、逻辑 HardwareID 首项 |
| NVIDIA NVAPI | `nvapi.dll` / `nvapi64.dll` | NVIDIA 型号、显存、VBIOS、时钟、PCI 载体关联 |
| AMD ADL / ADL2 | `atiadlxy.dll` / `atiadlxx.dll` | AMD 型号、显存、VBIOS、核心信息、静态时钟、BDF |

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
4. 要求唯一的物理 `PCI\VEN_1AF4&DEV_1050` 载体、`VioGpuDod` Service，以及
   fake-first `HardwareID` 多字符串中仍保留完整的物理条目；
5. 读取实际 `SPDRP_DRIVER` 与 Display class 子键，确认后才生成 ADL Driver 路径；
6. 再次读取 pointer 与 schema；
7. 只有前后完全一致才发布进程内快照。

NVAPI 严格接受 NVIDIA `10DE` profile；ADL 严格接受 AMD `1002` profile 和当前硬件池
中的 RX 550 / RX 560 bundle。厂商不匹配、字段缺失、Red Hat/VirtIO 名称泄漏、
SUBSYS/REV/BDF 交叉校验失败、实际实例缺失、出现第二个物理 virtio Display，或
`HardwareID` 丢失物理回退条目时均 fail closed。

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
3. 严格回读 staged identity；coordinator 再要求 schema-2、Prepared、
   `PendingIdentity=TransactionId`、current=previous，并把 snapshot 的 `SpoofVendor`
   作为本事务唯一厂商参数；
4. 创建以 TransactionId 为 owner 的 GPU API coordinator 持久 reservation；
5. 对目标厂商发布和非目标厂商受管残留做全量只读预检；
6. Prepare 对应 durable receipt；
7. Commit `CurrentIdentity`，再 Complete identity；
8. 使用同一个 staged vendor Finalize，删除旧备份并释放 reservation。

reservation 从 Prepare 保持到 Finalize/Rollback；任何新的 Prepare（不同或相同
TransactionId）都不能进入该窗口。失败时先恢复旧 identity pointer，再按相反方向恢复
目标 reader 与非目标清理。若 identity 已 durable 完成而 Finalize 中断，下次启动的
`Vendor=Auto` 只在 `Completed/current` 时 Finalize，或在
`RolledBack/previous-pointer` 时 Rollback；Prepared/Committed、厂商不符或后续事务
pointer 均保留 reservation 并 fail closed，避免提前或跨事务恢复。

## 能力边界

厂商 API 兼容层只统一用户态硬件查询，不改变真实 PCI vendor/device，不提供厂商
WDDM 驱动、Direct3D、CUDA、OpenCL、NVENC、AMF 或真实显存/时钟控制。检测工具展示的
型号规格是 profile 投影，不代表虚拟机获得对应物理 GPU 的性能或功能。

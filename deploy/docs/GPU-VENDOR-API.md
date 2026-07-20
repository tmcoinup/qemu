# GPU 厂商 API 系统兼容层

本分支保持唯一的真实显示承载设备 `PCI\VEN_1AF4&DEV_1050` 和 stock
`VioGpuDod` 驱动，不做 GPU passthrough、vGPU 或厂商内核驱动替换。为了让不同硬件
检测工具从用户态入口读取到同一份逻辑身份，guest 安装包同时提供 NVIDIA NVAPI 和
AMD ADL 的系统级兼容层。

这不是 GPU-Z、HWiNFO 或 AIDA64 的进程专用适配。DLL 不读取进程名，也不按调用者
返回不同结果；所有调用者都读取
`HKLM\SOFTWARE\StealthGPU\Identities\<CurrentIdentity>` 指向的同一个版本化快照。ADL
仅在调用方显式请求 `Refresh` 时重新验证并替换其进程内快照；刷新失败会保留最后一次
验证通过的快照，同时向该次调用返回错误。

## 分层关系

| 层 | 数据来源 | 保持一致的内容 |
| --- | --- | --- |
| PCI / 驱动 | QEMU `1AF4:1050` + `VioGpuDod` | InstanceId、Service、真实 BDF、驱动绑定 |
| SetupAPI / WMI | Enum/Class 严格投影 | 名称、厂商、显存、逻辑 HardwareID 首项 |
| NVIDIA NVAPI | `nvapi.dll` / `nvapi64.dll` | NVIDIA 型号、显存、VBIOS、时钟、PCI 载体关联 |
| AMD ADL / ADL2 | `atiadlxy.dll` / `atiadlxx.dll` | AMD 型号、显存、VBIOS、核心信息、静态时钟、BDF |

NVIDIA profile 下只有 NVAPI 枚举一张设备，ADL 返回零个 AMD adapter；AMD profile
下行为相反。两套 DLL 始终随统一 EXE 安装，因此 profile 切换只发布一个新的
`CurrentIdentity` 指针，不需要增删 DLL，也不会留下第二张逻辑显卡。

## 系统搜索位置

统一 EXE 发布并校验以下文件：

```text
C:\Windows\SysWOW64\nvapi.dll
C:\Windows\System32\nvapi64.dll
C:\Windows\SysWOW64\atiadlxy.dll
C:\Windows\SysWOW64\atiadlxx.dll
C:\Windows\System32\atiadlxx.dll
```

`SysWOW64\atiadlxx.dll` 与 `atiadlxy.dll` 使用同一份 PE32 实现。部分 32 位检测工具
会先尝试 `atiadlxx.dll` 再回退到 `atiadlxy.dll`；同时管理两个名称可避免旧文件在
标准回退之前截获调用。`System32\atiadlxx.dll` 则是独立的 PE32+ 实现。

安装器只接受当前项目摘要或显式登记的历史项目摘要。若目标是未知 DLL，包括真实
NVIDIA/AMD 驱动安装的厂商 DLL，所有目标会在第一次系统文件 Move 之前停止，且不修改
所有权、ACL、签名策略或启动链。

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

identity、NVAPI 与 ADL 使用同一个 32 位大写 GUID TransactionId，但保留三个独立
durable journal。NVAPI 的既有两项 receipt schema 不扩成四项或五项，确保升级中的
旧收据仍能恢复。

提交顺序固定为：

1. 恢复 identity、NVAPI、ADL 的遗留 journal；
2. Stage 新 identity；
3. 创建以 TransactionId 为 owner 的 GPU API coordinator 持久 reservation；
4. 对全部 NVIDIA/AMD 系统目标做只读预检；
5. 分别 Prepare NVAPI 和 ADL durable receipt；
6. Commit `CurrentIdentity`；
7. Complete identity；
8. Finalize 两套 reader、删除旧备份并释放 reservation。

reservation 从 Prepare 保持到 Finalize/Rollback；任何新的 Prepare（不同或相同
TransactionId）都不能进入该窗口。失败时先恢复旧 identity pointer，再按相反方向恢复 reader。若 identity
已 durable 完成而 Finalize 中断，下次启动依据 `CurrentIdentity` 完成遗留收据并释放
reservation；否则回滚两套 reader。

## 能力边界

厂商 API 兼容层只统一用户态硬件查询，不改变真实 PCI vendor/device，不提供厂商
WDDM 驱动、Direct3D、CUDA、OpenCL、NVENC、AMF 或真实显存/时钟控制。检测工具展示的
型号规格是 profile 投影，不代表虚拟机获得对应物理 GPU 的性能或功能。

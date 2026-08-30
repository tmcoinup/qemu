# guest-stealth：Win10 客机离线统一安装与初始化

正式包提供两个行为相同、界面不同的独立 guest 入口：
`respawn-stealth.exe` 保留完整控制台输出，`respawn-stealth-progress.exe` 只显示
通用进度窗口。每个 PE64 文件都完整内嵌电源策略、芯片组识别 INF、显示驱动、
GPU 初始化脚本及 x86/x64 NVIDIA NVAPI / AMD ADL 系统兼容库；运行时不请求
host HTTP，也不要求 EXE 旁边存在 `.ps1/.sys/.cat/.inf/.dll`。

只想完成正式部署时，请直接阅读
[`QUICKSTART.zh-CN.md`](./QUICKSTART.zh-CN.md)；该教程只要求复制并双击一个 EXE，
不需要在 guest 内另装 PowerShell 模块、RDP、QEMU guest agent 或 NVIDIA 软件。

完整装机/克隆顺序见 [`VM-WORKFLOW.md`](../docs/VM-WORKFLOW.md)。

当前 host GPU 目录覆盖 6 个芯片型号，每个型号 3 个板卡品牌，共 18 块 AIB：
12 块 NVIDIA 与 6 块 AMD。`1AF4:A101`–`1AF4:A112` 只是 profile 与物理
virtio 节点之间的受控 carrier；Windows 中唯一真实显示主 ID 仍是 `1AF4:1050`，
本方案不做 GPU passthrough/vGPU。GPU 目录明确不暴露或合成序列号，guest 身份
schema 也没有 `GPU_SERIAL`。

版本化 identity 仍使用 schema-2。host `GPU_NAME` 与快照 `SpoofName` 保存完整的
AIB canonical 标签，例如 `NVIDIA GeForce GTX 1050 Ti (Gigabyte OC)`，用于整行
校验板卡的 SUBSYS、VBIOS、显存和时钟。完整 AIB bundle 通过校验后，Windows
`FriendlyName`、`DeviceDesc`、Class `DriverDesc`、
`HardwareInformation.AdapterString`、`HardwareInformation.ChipType` 以及
NVAPI/ADL 的公开 adapter 名称统一按逻辑 PCI VEN/DEV 的封闭映射使用标准芯片名，例如
`NVIDIA GeForce GTX 1050 Ti`。该名称不通过删除括号猜测，未知 PCI 主 ID 会直接失败。
Enum `Mfg`、Class `ProviderName` 和常规页 `DEVPKEY_Device_Manufacturer` 使用独立的
Windows 厂商映射：AMD 为 `Advanced Micro Devices, Inc.`，NVIDIA 仍为 `NVIDIA`；
内部 `SpoofVendor` 则继续保留 `AMD`/`NVIDIA`，不混入展示字符串。
真实驱动节点的 `MatchingDeviceId`、`InfPath`、`InfSection` 与 `Service` 仍保持
stock VioGpuDod 值。

最终架构始终只有一个 VioGpuDod 显示 devnode。它的 PnP `HardwareIds` 是规范逻辑
VEN/DEV/AIB SUBSYS/REV 首项 + 原始完整 `1AF4:1050` 尾项；真实 InstanceId、BDF、
Service、Driver 和 PCI 配置空间仍为物理 carrier。MULTI_SZ 中的多条匹配字符串不是
多张显卡，也不会改变渲染路径、显存分配或性能。

## 发布物与源码

| 文件 | 作用 |
| --- | --- |
| `dist/respawn-stealth.exe` | 详细模式；保留原确认框、控制台输出和错误信息 |
| `dist/respawn-stealth-progress.exe` | 仅进度模式；隐藏详细输出，只显示通用进度与结果 |
| `build-exe.sh` | 校验 stock 驱动摘要，用 MinGW 同时构建两个 Windows PE64 EXE |
| `configure-power-policy.ps1` | 用 PowrProf 将屏幕/自动睡眠设为“从不”，保留桌面 S3 并关闭休眠 |
| `install-chipset-device.ps1` | 覆盖硬件池全部 Intel SMBus：为 A323/A123/1C22/1E22/8C22 幂等绑定 WHCP NO_DRV INF，并验证 inbox 2930 |
| `install-display-driver.ps1` | 真实驱动探测与幂等安装；必须先成功，才允许执行名称覆盖 |
| `display-driver-trust.ps1` | 校验活动 VioGpuDod、发布 INF 与内嵌 WHCP 包；仅放行缺失发布 INF 的官方恢复 |
| `project-monitor-identity.ps1` | 按 EDID 派生 PnP ID 只投影 Monitor 的 `DEVPKEY_Device_FriendlyName` |
| `launcher/monitor-friendly-name-projector.c` | 用 Config Manager 写入并回读显示器 FriendlyName，不触碰驱动栈身份 |
| `install-gpu-api-system.ps1` | 按 staged vendor 互斥发布 NVAPI/ADL，并用同一 identity TransactionId 收口 |
| `gpu-api-identity-binding.ps1` | 校验 staged vendor、identity 终态和 previous pointer，阻止提前/跨事务收口 |
| `install-nvapi-system.ps1` | 独立事务发布或移除 x86/x64 NVIDIA NVAPI 用户态 shim |
| `nvapi-system-validation.ps1` | NVAPI 安装与恢复共用的普通文件、SHA-256 和 PE 架构校验 |
| `install-adl-system.ps1` | 独立事务发布或移除三目标 AMD ADL/ADL2 用户态 shim |
| `persist-gpu-profile.ps1` | 校验完整型号 bundle，并组织 identity schema-2、transaction schema-6 的 Stage/Commit/Complete/Recover |
| `gpu-profile-transaction.ps1` | 持久化 GPU 身份 journal、指针 CAS、投影回读与崩溃恢复；transaction schema 1–5 仅用于兼容恢复 |
| `gpu-profile-registry-core.ps1` | GPU 身份事务共用的精确注册表读取、回读与 pointer CAS 基元 |
| `gpu-spoof-apply-support.ps1` | apply 共用的 AutoDetect、Code 22、计划任务与显示模式验收函数 |
| `refresh-gpu-name.ps1` | 在全局写锁内严格投影唯一 VioGpuDod 实例的 Enum/Class 属性 |
| `gpu-manufacturer-projection.ps1` | 通过 Config Manager 投影常规页制造商，并在前后直接复核 PnP/INF/SYS/WHCP |
| `gpu-hardware-id-plan.ps1` | 规划规范逻辑首项 + 完整物理尾项，并严格识别可恢复的原始数组 |
| `gpu-hardware-id-transaction.ps1` | 管理 HardwareID 耐久 journal；先写入并回读 `RollbackHardwareIds`，再进入 Applying |
| `project-gpu-hardware-id.ps1` | HardwareID 唯一 writer；提供 Apply、Verify、RestorePhysical 与事务恢复 |
| `respawn-stealth-local.ps1` | 串联驱动安装、`apply-gpu-spoof -AutoDetect`、收尾与重启 |
| `respawn-restart-state.ps1` | 集中管理一次性恢复任务、显示设备就绪等待与单次重启阶段 |
| `launcher/` | UAC manifest、payload 释放器、仅进度 UI 和应用图标 |
| `package.sh` | 清理旧发布目录并同时生成两个独立 EXE |

驱动输入来自 `deploy/scripts/stock-viogpudo/`：

- `viogpudo.sys`
- `viogpudo.cat`
- `viogpudo.inf`

构建器与 Windows 安装器会同时锁定三份 SHA-256。SYS/CAT/INF 不是可任意混用的
独立文件；任何一个摘要不匹配都会在安装前失败。

芯片组识别输入来自 `deploy/scripts/stock-intel-chipset-inf/`，覆盖硬件池全部 SMBus：
H310/A323、H110/A123、H61/1C22、B75/1E22、H81/8C22 分别使用
`CannonLake-HSystem.inf`、`SunrisePoint-HSystem.inf`、`CougarPointSystem.inf`、
`PantherPointSystem.inf`、`PatsburgSystem.inf`、`LynxPointSystem.inf` 及其 CAT。
六套包均由 Microsoft
WHCP 签名并引用 inbox `machine.inf` 的 `NO_DRV` section；Q35/ICH9 compatibility
的 2930 则直接验证 Win10 inbox `machine.inf`，不随 EXE 分发第六套 INF。它们只清除
Code 28 并正确命名，不包含 SMBus `.sys` 或服务。来源、版本和摘要见 `SOURCES.md`。

NVIDIA 用户态身份库来自 `deploy/nvapi-shim/`：PE32 `nvapi.dll` 给 32 位程序，PE32+
`nvapi64.dll` 给 64 位程序。两者共用版本化注册表身份并锁定 SHA-256、Machine、
DLL 标志和唯一导出；缺任一架构都视为发布失败。GPU-Z 2.70 主程序是 PE32，所以
NVIDIA profile 下，统一 EXE 把 x86 文件发布为 `SysWOW64\nvapi.dll`，并把
x64 文件发布为 `System32\nvapi64.dll`。installer 只替换当前或历史 VMate
固定摘要，遇到真实 NVIDIA 或其它未知同名 DLL 会在写入前停止。

两份 DLL 都只枚举一个 NVAPI 句柄，并在初始化时把它唯一关联到 OS 中实际存在的
`1AF4:1050` 显示承载设备。`GetPCIIdentifiers` 的主 `deviceId` 有意返回物理
`1AF4:1050`，用作 PnP/BDF/NVAPI 的跨接口去重键；AIB SUBSYS/REV、external device
和标准型号仍来自 NVIDIA 逻辑 identity。这个分层返回让鲁大师等多源工具把结果归并
到同一个 devnode，不会创建第二个 PnP 显卡。
`GetGPUType` 明确返回 DGPU，`GetFullName` 与 Windows 投影使用同一个标准芯片名。
真实 BDF、InstanceId、Service、Driver 和 HardwareID 物理尾项继续负责载体绑定。
`NvAPI_SYS_GetDriverAndBranchVersion` 返回经回归锁定的 `54633 / r545_99` 兼容快照；
GPU-Z 2.70 因而不会把明确失败误判成旧驱动并跳入未实现的 display-handle 回退入口。
legacy `NvAPI_GPU_GetMemoryInfo` v1/v2/v3 与 frame-buffer size 接口使用 KiB，4 GiB
返回 `4194304 KiB`；`NvAPI_GPU_GetMemoryInfoEx` v1 使用 bytes，返回
`4294967296 bytes`。
安装完成后还会分别运行 x86/x64 runtime probe，真实调用 Initialize、Enum、
GetPCIIdentifiers、GetFullName 和 GetGPUType，并复核 NVIDIA vendor、external
device、DGPU、驱动版本及最小 QueryInterface 面；任一位数失败都会停止自动
重启并把原始状态追加到 `respawn.log`。

每次 DLL 首次初始化还会以 SetupAPI/Configuration Manager 对 `SourceInstanceId`
进行实例级复核：必须只有一个 online `1AF4:1050` Display devnode，snapshot BDF
必须与该 devnode 的 Bus/Address 一致，Service 必须仍为 `VioGpuDod`。HardwareID
MULTI_SZ 必须精确等于当前 identity 的规范逻辑首项 + 原始完整 `1AF4:1050` 尾项；
出现未知首项、尾项缺失或顺序变化时，NVAPI/ADL 均拒绝发布，绝不猜测另一个载体。

AMD 用户态身份库来自 `deploy/adl-shim/`。AMD profile 下，PE32 实现发布到
`SysWOW64\atiadlxy.dll` 和 `SysWOW64\atiadlxx.dll`，PE32+ 实现发布到
`System32\atiadlxx.dll`。它实现通用 ADL/ADL2 枚举、显存、VBIOS、核心信息与
静态时钟查询，不判断调用进程；`AdapterInfo.strAdapterName` 使用与 Windows
投影一致的标准芯片名，并与同一 `1AF4:1050` 载体关联；逻辑 `1002` VEN/DEV、
所选 AIB SUBSYS/REV 同时进入规范 HardwareID 首项并由 ADL 回答，单卡独显拓扑由
ADL 用户态合同回答。NVIDIA profile
不向系统搜索目录发布 ADL，并事务移除已知 VMate 残留。
实时温度、功耗、风扇等没有可信数据源的接口返回官方“不支持”，
不会伪造遥测。完整合同见
[`GPU-VENDOR-API.md`](../docs/GPU-VENDOR-API.md)。

ADL 的 `AdapterInfo` 中 UDID、PNP 字符串和 Driver path 也传递上一步已经验证的
真实 Windows 载体信息，而不是额外合成一条 `VEN_1002` PNP 实例；因此系统级扫描器
不会把 AMD 逻辑规格与同一 virtio 显示设备拆成两张卡。

## 一次运行的真实顺序

1. EXE 从 Windows Known Folder 定位 ProgramData，拒绝重解析点或非可信 Owner；
   所有 payload 先写入受保护 staging 并逐字节复核，再整目录发布到
   `C:\ProgramData\StealthGPU\respawn-exe\`。管理员 PowerShell 使用受控最小
   环境；`COMPUTERNAME` 来自 Windows API，`USERNAME/USERDOMAIN` 从当前提权
   token 解析，既不继承用户可修改的同名变量，也满足系统 `shutdown.exe` 的环境契约。
2. 在任何 GPU/PnP 写入前，通过 Windows PowrProf API 把当前活动方案中的“屏幕”和
   “睡眠”都设为“从不”：关闭普通及锁屏显示超时、空闲及无人值守自动睡眠和混合
   睡眠，同时设置 `ALLOWSTANDBY=1`，保留正常台式机的 S1–S3 能力与“睡眠”区块；
   再执行 inbox `powercfg /hibernate off`，回读六项 AC/DC 值、活动方案及
   `HiberFilePresent`。失败就停止，不会继续改显卡。
3. 枚举 `PresentOnly` 的全硬件池 SMBus：`8086:A323/A123/1C22/1E22/8C22/2930`。
   前五款已正常绑定时跳过，否则验证对应 INF/CAT 的固定摘要、NO_DRV 语义与
   Microsoft WHCP 签名，再用 inbox `pnputil /add-driver ... /install` 清除 Code 28；
   2930 只验证 Win10 inbox `machine.inf`。若要求重启，先记录
   `ChipsetVerification` 阶段并继续完成 GPU 流程；最终一次重启后只复核该 INF，
   不会再次运行 GPU 流程或安排第二次重启。若首次启动边界来自显示/API 恢复，而
   Full 恢复时芯片组仍待重启，则任务切换为纯 `ChipsetVerification`、返回 `30`
   并等待人工重启，不会调用第二次自动关机。
4. 停止 `StealthGPU-ProjectHardwareId` writer 并只读检查当前在线实例；必要时恢复
   原始 physical-only 数组，再次门禁。后续驱动安装和 PnP scan 因而只处理唯一的
   stock `1AF4:1050` 载体；最终投影在身份事务完成后恢复。
5. 只枚举 `PresentOnly` 的 PCI 显示设备，先要求物理主 ID 全部为 `1AF4:1050`，
   再读取不受 FriendlyName 伪装影响的
   `DEVPKEY_Device_Service`。
6. 通过物理门禁且已经绑定 `VioGpuDod` 时跳过 `pnputil`。这是克隆机无扰动快速路径。
7. 若是全新系统的 `PCI\VEN_1AF4&DEV_1050`，校验内嵌文件摘要与 Microsoft
   Windows Hardware Compatibility Publisher 签名，然后执行
   `pnputil /add-driver viogpudo.inf /install`。
8. 再次读取 `Service`。没有真实变成 `VioGpuDod` 就停止，不执行 GPU 名称覆盖。
9. 仅对本次新装驱动的系统清理旧 `GraphicsDrivers` 模式缓存；克隆机不清理。
10. 在旧 SYSTEM writer 已停止的窗口先完整发布持久投影依赖，再执行
   `apply-gpu-spoof.ps1 -AutoDetect -NvapiPayloadDir <受保护目录>`：按当前 PCI
   SUBSYS 对齐完整 AIB 标签和版本化 identity schema-2，并在 identity 尚未
   `Complete` 时完整预检；新写入的 transaction schema-6 使用标准芯片名和正式
   Windows 厂商名提交展示字段。对于大于 2047 MiB 的 profile，legacy 32 位
   `HardwareInformation.MemorySize` 写为 2047 MiB（`0x7FF00000`），避免旧工具
   错按有符号 Int32 读取时得到负数；NVAPI legacy MemoryInfo 返回
   `4194304 KiB`，MemoryInfoEx 返回 `4294967296 bytes`，`qwMemorySize` 仍精确投影
   4 GiB。schema 1–5 只参与旧 journal 恢复：schema-5 保留历史短厂商名，
   schema-4 按原语义重建 4095 MiB。随后先移除非目标厂商的
   受管 DLL，再把目标厂商投影发布到 SysWOW64/System32。installer 失败会由同一
   durable `finally` 回滚 identity；流程不写 GPU-Z 原目录、不修改 PATH，也不安装
   NVIDIA 驱动、控制面板或服务。
   重复运行时不再用可被本工具改写的 `DriverDesc` 名称找目标，而是用 staged
   `SourceInstanceId`、Enum `Driver`、`ClassSubkey`、`Service=VioGpuDod` 和
   `InfPath/InfSection` 唯一绑定；RDP/远程显示 Class 只参与诊断列表。
11. 厂商 API 成功后，在同一 devnode 上依次 Apply、probe、Verify 规范逻辑
    HardwareID 首项 + 完整物理尾项；全部成功后注册 SYSTEM/Highest 的
    `StealthGPU-ProjectHardwareId` 启动/登录维护任务。失败会删除任务并恢复
    physical-only，避免留下半提交数组。Apply 在写设备前先持久化并回读
    `RollbackHardwareIds`；即使最终 journal 收尾任一写点中断，下次 Recover
    仍能从 before/expected 两种状态确定性恢复。
12. `gpu-manufacturer-projection.ps1` 仅把设备管理器常规页制造商投影成
    `Advanced Micro Devices, Inc.`/`NVIDIA`；投影前后都要求活动
    `Service/InfPath` 不变，并重新验证发布 INF、运行中 SYS 的固定摘要与
    Microsoft WHCP 证书指纹。
13. 按在线 Monitor 的 EDID 派生 PnP ID 查硬件池，只写入并回读
    `DEVPKEY_Device_FriendlyName`，再注册 `StealthGPU-ProjectMonitorIdentity`；
    EDID、HardwareID、INF、Monitor Class 与 `monitor.sys` 前后必须保持不变。
14. 最后通过统一 helper 校验 System32 `shutdown.exe` 并立即核对其原生退出码，
    再安排默认重启；当前 profile 对应的 NVAPI 或 ADL 会从系统目录读取同一身份。
    工具若调用没有可信数据源的实时遥测或厂商驱动功能，会收到明确的“不支持”结果，
    而不是伪造数值。

若 Finalize 只因某个正在运行的硬件工具仍映射旧 NVAPI/ADL backup 而返回内部状态
`12`，新 DLL 与 identity 保持提交，固定摘要 receipt 也不会被删除。统一入口会关闭
本轮流程并只跨一次启动边界，登录后先 `Recover` 再继续；重启后仍失败时停止自动
重启并保留 journal，避免永久 ACL 或第三方占用造成循环。

因此，“设备管理器显示 GTX 1050 Ti”不再被当成成功条件。旧 EXE 能把
Microsoft Basic Display Adapter 改名成 GTX，但底层仍是 BasicDisplay，UEFI 下的
分辨率会锁在启动帧缓冲（例如 1280×800）。新流程必须确认真实 Service。

SetupAPI 首项和 NVAPI/ADL 的逻辑身份只统一用户态查询，不增加渲染能力。
stock `VioGpuDod` 是 Display-Only 驱动；Windows 客体不会因为显示 `10DE:1C82`
就获得 GTX 1050 Ti 的 Direct3D、CUDA、NVENC 或真实 NVIDIA 驱动性能。读取 stock
`VioGpuDod` DXGI adapter 描述、HardwareID 物理尾项或原始 PCI 配置的工具仍会看到
virtio/`1AF4:1050`；真实 InstanceId、BDF、Service 和 Driver 也始终不变。

## 固定 1920×1080 原生模式

本项目的 Linux 与 Windows VM 启动器都会默认给 `virtio-vga`/`virtio-vga-gl`
显式追加 `edid-fixed-native=on`。该参数把 EDID 的首选时序固定为 profile 配置的
`xres=1920,yres=1080`，避免 SDL 初始窗口或后续缩放把动态 `req_state` 回写成
1280×800。它只稳定显示器上报的原生模式，不能代替 guest 内真实绑定
`VioGpuDod`；驱动安装与固定 EDID 两层都成功后，Windows 才能可靠枚举 1080p。

QEMU 设备属性本身仍默认关闭，以保持普通 QEMU 调用方的动态缩放兼容性；本项目
通过启动器默认显式开启，因此正常使用 `start-vm.sh`/`start-vm.ps1` 无需额外传参。
四款显示器都以当前硬件 profile 生成的实时 QEMU EDID 为唯一事实源；统一 EXE 仅按
EDID 中的厂商码和产品码，通过 `DEVPKEY_Device_FriendlyName` 投影设备管理器标签，
不改 EDID、Monitor HardwareID、INF、Monitor Class 或 inbox `monitor.sys`：

| EDID PnP code / HardwareID | 设备管理器 FriendlyName |
| --- | --- |
| `SAM0D20` / `MONITOR\SAM0D20` | Samsung S24F350 |
| `AOC2402` / `MONITOR\AOC2402` | AOC 24B2XH |
| `XMI23C3` / `MONITOR\XMI23C3` | Xiaomi Mi Monitor (RMMNT238NF) |
| `LEN66BC` / `MONITOR\LEN66BC` | Lenovo L24e-30 |

## 全新 VM 用法

在 host 重新构建：

```bash
bash deploy/guest-stealth/package.sh
sha256sum deploy/guest-stealth/dist/respawn-stealth*.exe
```

普通使用可只把 `respawn-stealth-progress.exe` 拷进 Windows；需要观察完整诊断时
则只复制原 `respawn-stealth.exe`。两者都是可独立运行的单文件程序，任选其一双击并
等待自动重启。无需启动 `serve-stealth-http.py`，也不要再执行旧的
`irm .../shallow-stealth.ps1 | iex` 作为默认安装。

无人值守首次登录使用：

```powershell
Start-Process -FilePath 'D:\工具\respawn-stealth.exe' `
    -ArgumentList '--firstlogon' -Wait
```

手动诊断但暂不重启：

```powershell
Start-Process -FilePath '.\respawn-stealth.exe' -ArgumentList '-NoReboot' -Wait
```

## 直接运行 GPU-Z 2.70

关闭所有 GPU-Z 窗口后运行一次最新 `respawn-stealth.exe` 并重启。之后普通用户可以从
任意目录直接双击 `GPU-Z.2.70.0.exe`，不需要 PowerShell helper、旁置 DLL、环境变量
或 NVIDIA 软件。GPU-Z 文件本身的下载来源与 Authenticode 签名仍由用户核验。

本次 `--firstlogon` 投影链不新增 RDP、调试 HTTP、QEMU guest agent、厂商服务或
第三方守护程序；新增持久项只有项目脚本、当前 profile 对应的一组 NVAPI 或 ADL DLL，
以及 Windows 自带 Task Scheduler 中的 GPU 名称、HardwareID 与
`StealthGPU-ProjectMonitorIdentity` 启动/登录维护任务。电源方案只由 Windows
内置 API 原地更新，不新增服务。VM2 现场验收使用过的 USB/HTTP 调试路径不会进入 EXE。

直接运行使用两个固定系统搜索目录，但两组厂商 DLL 互斥：

```text
# NVIDIA profile
C:\Windows\SysWOW64\nvapi.dll      # GPU-Z 2.70 PE32 主程序
C:\Windows\System32\nvapi64.dll   # 内嵌 x64 辅助组件

# AMD profile
C:\Windows\SysWOW64\atiadlxy.dll  # 标准 32 位 AMD ADL 名称
C:\Windows\SysWOW64\atiadlxx.dll  # 32 位工具优先探测名称
C:\Windows\System32\atiadlxx.dll  # 64 位 AMD ADL 名称
```

这些 DLL 是无厂商签名的用户态身份投影，不是显示驱动。它们会成为系统级完整性检查
可见面，并会与未来真实 NVIDIA/AMD 驱动的同名文件冲突；installer 因而拒绝覆盖任何
未知摘要。若以后改装真实厂商/VFIO 栈，应先移除本项目 DLL，而不能强制覆盖厂商文件。

## 克隆机兼容性

- 物理 ID 为 `1AF4:1050` 且已绑定 `VioGpuDod`：不运行 `pnputil`，不清模式缓存，
  只按新 profile 重对齐名称。
- 物理 PCI ID 不是 `1AF4:1050`：明确拒绝继续，避免把浅层用户态投影误用于不兼容
  的驱动绑定；本流程不会恢复自签驱动路径。
- 可重复执行：payload 每次覆盖为当前 EXE 版本；驱动安装与缓存清理只在需要时发生。
- clone 的每个 `SourceInstanceId` 使用独立 SHA-256 命名备份；旧实例不会阻止新 SUBSYS
  实例建立自己的事务。FirstLogon 保留 GPU 名称、HardwareID 和 Monitor 标签维护，
  交互显示任务仍按首次登录规则跳过。

`autounattend.xml` 的 clone 首次登录命令仍固定调用
`D:\工具\respawn-stealth.exe --firstlogon`，所以封 base 前必须把最新 EXE 放到该路径。

## 验证与日志

在 SDL 控制台登录 Windows 后执行：

```powershell
Get-PnpDevice -Class Display -PresentOnly | ForEach-Object {
    $_
    Get-PnpDeviceProperty -InstanceId $_.InstanceId `
        -KeyName DEVPKEY_Device_Service,DEVPKEY_Device_DriverInfPath
}
$smbus = Get-PnpDevice -PresentOnly | Where-Object {
    $_.InstanceId -match '^PCI\\VEN_8086&DEV_(A323|A123|1C22|1E22|8C22|2930)&'
}
$smbus | Format-List Status,Class,FriendlyName,InstanceId,Problem
$smbus | ForEach-Object {
    Get-PnpDeviceProperty -InstanceId $_.InstanceId `
        -KeyName DEVPKEY_Device_ProblemCode,DEVPKEY_Device_DriverInfPath,
            DEVPKEY_Device_Service
}
$display = Get-PnpDevice -Class Display -PresentOnly |
    Where-Object InstanceId -Like 'PCI\VEN_1AF4&DEV_1050*' |
    Select-Object -First 1
$hardwareIds = (Get-PnpDeviceProperty -InstanceId $display.InstanceId `
    -KeyName DEVPKEY_Device_HardwareIds).Data
$hardwareIds
# Colorful GTX 1050 Ti 示例；其它 AIB 应使用其 identity 中的 SUBSYS/REV。
$expectedLogical = 'PCI\VEN_10DE&DEV_1C82&SUBSYS_00007377&REV_A1'
if (-not $hardwareIds -or $hardwareIds.Count -lt 2 -or
    $hardwareIds[0] -cne $expectedLogical -or
    @($hardwareIds[1..($hardwareIds.Count - 1)] | Where-Object {
        $_ -notlike 'PCI\VEN_1AF4&DEV_1050*'
    }).Count -ne 0) {
    throw 'HardwareID 不是规范逻辑首项 + 完整物理尾项'
}
Get-CimInstance Win32_VideoController |
    Format-List Name,AdapterRAM,DriverVersion,CurrentHorizontalResolution,
        CurrentVerticalResolution
$identityRoot = 'HKLM:\SOFTWARE\StealthGPU'
$currentIdentity = (Get-ItemProperty -LiteralPath $identityRoot `
    -Name CurrentIdentity).CurrentIdentity
if ($currentIdentity -notmatch '^[0-9A-F]{32}$') {
    throw 'CurrentIdentity 不是有效的已提交身份指针'
}
Get-ItemProperty -LiteralPath (Join-Path $identityRoot "Identities\$currentIdentity") |
    Format-List IdentitySchemaVersion,IdentityMode,SpoofName,SpoofPciVendorId,
        SpoofPciDeviceId,SpoofRevisionId,SpoofRamMb,SpoofMemoryType,
        SpoofMemoryBusWidthBits,SpoofBaseClockKHz,SpoofBoostClockKHz,
        SpoofMemoryClockKHz,SpoofSliSupported
Get-FileHash 'C:\ProgramData\StealthGPU\respawn-exe\nvapi.dll' -Algorithm SHA256
Get-FileHash 'C:\ProgramData\StealthGPU\respawn-exe\nvapi64.dll' -Algorithm SHA256
Get-FileHash "$env:WINDIR\SysWOW64\nvapi.dll" -Algorithm SHA256
Get-FileHash "$env:WINDIR\System32\nvapi64.dll" -Algorithm SHA256
```

期望 PCI 显示设备的 `DEVPKEY_Device_Service` 为 `VioGpuDod`，INF 为 `oem*.inf`，重启后
显示设置可枚举 1920×1080；1050 Ti profile 的十进制逻辑 VEN/DEV 分别为
`4318/7298`（十六进制 `10DE/1C82`）。ProgramData 与系统搜索目录中的两份 DLL 摘要
必须分别一致。HardwareID 首项应是当前 AIB 的规范逻辑 ID，尾项完整保留
`1AF4:1050`；NVAPI 主 PCI 关联键也应是物理 carrier，而 external/AIB/型号保持逻辑
NVIDIA。若通过 RDP 查看，分辨率下拉由 RDP 客户端控制，本来就会变灰；驱动与本地
输出必须在 SDL 控制台验证。

SMBus 期望 `Status=OK`、`Class=System`、ProblemCode `0` 且 Service 为空；前五款
payload 型号的 INF 为 `oem*.inf`，2930 为 inbox `machine.inf`。空 Service 正是
Intel/Windows NO_DRV 识别包的正确结果。

GTX 1050 Ti 的快照还应为 schema `2`、`GDDR5`、128 bit、base
`1290000` kHz、boost `1392000` kHz、NVAPI memory `3504000` kHz 和
`SpoofSliSupported=0`。`SpoofName` 应保持所选板卡的完整 AIB canonical 标签；
设备管理器投影与 NVAPI/ADL adapter 名称则统一为按 `10DE:1C82` 映射的
`NVIDIA GeForce GTX 1050 Ti`，`Win32_VideoController.Name` 也使用该标准名。
4 GiB profile 的 legacy `AdapterRAM`/`HardwareInformation.MemorySize` 为
2047 MiB（`0x7FF00000`），确保错误按有符号 Int32 读取该字段的旧工具仍得到正数；
NVAPI legacy `MemoryInfo` v1/v2/v3 与 frame-buffer size 接口为
`4194304 KiB`，`MemoryInfoEx` v1 为 `4294967296 bytes`；
`HardwareInformation.qwMemorySize` 与相应厂商接口保留精确 4 GiB。历史
transaction schema-4 journal 恢复时仍按原语义重建 4095 MiB，新提交只使用
schema-6。GPU-Z 将 memory clock 显示为 1752 MHz；这是查询投影，不是真实频率管理
或显存分配。

日志：

- `C:\ProgramData\StealthGPU\power-policy.log`
- `C:\ProgramData\StealthGPU\chipset-device-install.log`
- `C:\ProgramData\StealthGPU\display-driver-install.log`
- `C:\ProgramData\StealthGPU\gpu-hardware-id-projection.log`
- `C:\ProgramData\StealthGPU\monitor-identity-projection.log`
- `C:\ProgramData\StealthGPU\respawn.log`

NVAPI installer 的逐行输出并入 `respawn.log`，因此 identity 回滚原因和双 DLL
事务结果位于同一条正式部署日志中。

从旧 HardwareID 布局升级时，直接运行最新统一 EXE。它会先停止旧
`StealthGPU-ProjectHardwareId` writer，恢复并门禁原始 physical-only 数组；身份事务
成功后再用当前 AIB 生成规范逻辑首项，逐项接回完整物理尾项，执行 Apply/Verify 并
重新注册启动/登录维护任务。不要手工并发运行旧 projector；
`gpu-hardware-id-projection.log` 记录恢复、投影与验证全过程。

若首次运行报“payload 目录 Owner 不受信”，说明固定目录曾被普通用户预建；为避免
管理员执行竞态，程序会故意停止。确认目录内没有用户文件后，以管理员身份删除
`C:\ProgramData\StealthGPU\respawn-exe`（必要时连同空的 `StealthGPU` 根目录删除），
再重新运行 EXE；不要用 `takeown` 后原地放行。

## 源码调试入口

PowerShell 脚本文件只供源码调试，默认发布目录不包含它们。如确实需要：

```bash
INCLUDE_LEGACY_SCRIPTS=1 bash deploy/guest-stealth/package.sh
```

脚本调试必须把芯片组/显示驱动 installer、六套 Intel INF/CAT、
`install-nvapi-system.ps1`、`nvapi-system-validation.ps1`、
`nvapi-system-transaction.ps1`、`install-adl-system.ps1`、
`adl-system-transaction.ps1`、`install-gpu-api-system.ps1`、
`gpu-api-identity-binding.ps1`、stock 显示驱动三件套、
`nvapi.dll`、`nvapi64.dll`、`atiadlxy.dll`、`atiadlxx32.dll`、`atiadlxx.dll`、
`configure-power-policy.ps1`、
`apply-gpu-spoof.ps1`、`gpu-spoof-apply-support.ps1`、
`persist-gpu-profile.ps1`、`gpu-profile-transaction.ps1`、
`gpu-profile-registry-core.ps1`、
`refresh-gpu-name.ps1`、`gpu-manufacturer-projection.ps1`、
`gpu-manufacturer-projector.exe`、`project-monitor-identity.ps1`、
`monitor-friendly-name-projector.exe`、`monitor-identities.json`、
`respawn-restart-state.ps1`、
`display-driver-trust.ps1`、
`gpu-hardware-id-plan.ps1`、`project-gpu-hardware-id.ps1` 和
`force-displayfreq.ps1` 放在同一 payload 目录；生产环境从两个发布物中任选一个
单独运行，不要并发启动。

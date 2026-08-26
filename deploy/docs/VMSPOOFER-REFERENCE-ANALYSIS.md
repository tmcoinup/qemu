# VMSpoofer 与配套 WIM 参考分析

本文记录 2026-08-25 在授权实验机上对 VMSpoofer、pc01、pc02、宿主 ESP 备份和
下载目录 WIM 的只读分析结果。目的只是为 P-11 的可维护
实现建立证据基线；P-11 不复制样例的私有二进制、联网协议或加密配置。

结论中的证据等级：

- **已验证**：由文件摘要、反汇编、Hyper-V 配置或 guest 直接回读确认。
- **高可信推断**：至少两层独立证据一致，但尚未取得源码或完整协议语义。
- **未验证**：当前证据不足，不能作为 P-11 功能声明。

## 结论摘要

1. **已验证：样例不是 GPU 直通。** pc01、pc02 都使用 Hyper-V GPU-P adapter，
   配额为宿主可用上下界的 100%；guest 中 D3DKMT 仍报告
   `Paravirtualized` adapter。
2. **已验证：WIM 不负责硬件真机化。** WIM 是共享的 Windows 10 基础镜像；
   CPU、主板和序列号的差异来自每 VM 不同的 guest EFI 以及宿主引导期扩展。
3. **已验证：样例由三层组成。** 管理器负责 Hyper-V/WIM/ESP 生命周期；宿主
   `Voyager_Host` 派生 EFI 在 Windows/Hyper-V 加载期植入扩展；每 VM
   `Voyager` 派生 EFI 通过专用 CPUID 通道取得宿主 UUID，解密并启动一个
   EFI runtime payload。后者继续进入 Windows kernel 路径，修改 PnP、驱动回读和
   注册表对象；它不是单纯的 SMBIOS 固件模板。
4. **已验证：样例宿主不依赖 Windows test signing。** 它使用未签名 UEFI
   启动加载器，因而要求关闭 Secure Boot；这不等价于“签名完善”，也不等价于
   Microsoft 支持的扩展接口。
5. **已验证：样例的设备管理器并不干净。** pc01、pc02 均有多个同名为
   `NVIDIA GeForce RTX 4060 Ti` 的显示节点和三个 D3D adapter；其中包含非
   NVIDIA PCI ID。它在检测信号数量上是基线，不应成为 P-11 复制错误设备链的
   理由。
6. **已验证：当前 P-11 功能不少于样例，但暴露尚未相等。** 修正物理 PCI 位置
   判断后，P-11 为功能信号 3、固有 GPU-P 信号 1、暴露项 3、总阳性 4；样例
   保存证据为 2/1/2/3。P-11 多出的类别是 `HostDriverStore`，且当前唯一显示
   节点仍是 Microsoft `VEN_1414/VirtualRender/vrd.inf`，尚未达到“原厂单显卡”
   质量门槛。
7. **已验证：丰富硬件池由服务端模板和 per-VM 固件共同提供。** 管理器包含
   `getArchTpls/getArchTpl`、`downloadGuestFirm/guestConfig` 等 API 路径，并把
   `archId` 写入每 VM 配置；完整模板集合不在 EXE 或 WIM 中。pc01、pc02 当前
   分别引用不同的 `archId`，因此不能把两台 VM 的离线数据误当成完整硬件库。
8. **已验证：样例的 `monitor.exe` 不是显示器驱动。** 它是有效签名的
   `usbipd-win 5.3.0`；`attacher.exe` 是旧版 `usbip-win` client。配套目录的
   USB/IP、VBoxUSB、TFTP、IPMsg 和虚拟音频组件主要承担外设/交互/部署，不会
   生成原厂 GPU、EDID 或物理显示输出。
9. **已验证：样例输入 API 不是仅本机接口。** 管理器把五条 GET route 注册到
   `httplib::Server`，并在配置端口监听 `0.0.0.0`；route 注册和五个 handler 中均未
   观察到 token、header、来源地址或调用者身份校验。P-11 的兼容桥只监听
   `127.0.0.1`，并对重复/中断事件执行 release-all，安全性和卡键恢复优于样例。

## 工件账本

| 工件 | 大小 | SHA-256 | 结论 |
|---|---:|---|---|
| 磁盘上的 `VMSpoofer.exe` | 13,822,976 | `9FF46535914668EA8C1443D1119A8610A8EE065DB22F0355CD0B5CD803EF612C` | 无 Authenticode security directory；磁盘 PE 被保护 |
| 运行态归一化 PE | 25,501,696 | `25CBB91156FB5F9540C6C361DE433931ACBC0DA54B07AD9E22581C6E22A797B4` | 从授权进程映像重建，供静态反汇编 |
| `.text` 分析副本 | 25,501,696 | `53C4E34FAE1675AAAF91242D5EA9466F32D64811C00A7CBC63951B919437ACB5` | 保留已解密 `.text/.rdata/.data`，恢复有效异常表并取消保护段执行属性；仅供离线分析 |
| 管理器全函数反编译报告 | 17,717,413 | `0D02CB221DD00CA64D307F46D5DB86BCC35814D9EC605C27CA8A0B8F1B5F19C7` | 导出 Ghidra 识别的全部 12,731 个函数；8,690 个入口位于真实 `.text` |
| pc01 guest `bootmgfw.efi` | 1,082,880 | `C73710EBA749EAF2D103397E3FB501A54083820CED74A8563CADC495DC9DAD6F` | 未签名，per-profile |
| pc02 guest `bootmgfw.efi` | 1,082,880 | `094F69E37A8723C166FF5CC762775897008F967CDDBA02EFFB75025ED271EB0B` | 未签名，per-profile，与 pc01 不同 |
| 样例宿主 EFI 备份 | 1,622,016 | `4DA3DC26D9070FCC07361477F0CD1D0FCC8D9FD906A4E345F4176DD3B0EFC295` | 未签名，`Voyager_Host` 派生 |
| 解密后的宿主 Hyper-V payload | 1,459,712 | `D41DA7021C6F38929C03B42C6C77594D2DF410CE0DA75979B7BEF6A91EB7DAD9` | x64 DLL，导出 `voyager_context/vm_e_a/vm_e_b` |
| 解密后的 pc02 runtime payload | 954,368 | `2029001FC12DBB4902D5D53C2132F70B8D36FDE6F05543C8FB534E31B527E9B1` | x64 EFI runtime driver，后续进入 Windows kernel 路径 |
| 恢复后的 Microsoft 宿主 EFI | 1,588,056 | `E721EB274AEB9F3102B9EB5E168CBE6C781942E26A2B62BB06A306C933988D07` | Microsoft 签名有效 |
| `WINDOWS10_22H2_19045.7417_X64.wim` | 3,315,605,012 | `0860744F42E4FD8AB5280CE4D60C56886A32015A928E77A8DFB2196E474DFEBD` | 单索引共享基础镜像 |
| `GuestCtrl.exe` | 9,739,264 | `F541EB362FA292A388242C6EF3A3315E3EFC22D27B62AAA5FA3468E2817FC925` | 未签名、受保护的 guest 控制程序 |
| `monitor.exe` | 8,803,720 | `78FD94CA4125DB7407C77BD7B985971A1AC95705A331401976F748770035325B` | 有效签名的 `usbipd-win 5.3.0`，不是显示器组件 |
| `attacher.exe` | 1,305,088 | `5A57753F17BFC6436708FBAAC22B1E324F178B25B505111819989EEFE936D281` | 未签名的 `usbip-win 0.3.4` debug build |
| `ets.exe` | 191,616 | `6FF1378D634B12B2507A8E03CCD50855806CA7538524B7CCBC7A5587FE42B108` | ETS 1.03，旧证书链当前验证失败 |
| `WinRing0x64.sys` | 14,544 | `11BD2C9F9E2397C9A16E0990E4ED2CF0679498FE0FD418A3DFDAC60B5C160EE5` | WinRing0 1.2.0.5，实验机回读签名有效但年代久远 |

原始 VMSpoofer PE 把正常 `.text/.rdata/.data/.pdata/.umn` 的磁盘 raw size
清零，入口落在约 13 MiB 的保护段 `.1Nn`。运行后这些正常节已在内存中解密，
归一化映像恢复出约 2.32 MiB `.text`、560 KiB `.rdata`、119 KiB `.data`
和 8 MiB `.umn`。因此仅对磁盘文件跑字符串工具会漏掉绝大多数行为。

为避免 PE 保护器伪异常表把分析器带进伪代码，分析副本使用运行态组合表中前 9,733 个
有效 `.text` `RUNTIME_FUNCTION` 条目重建 `.pdata`，并清除 `.umn/.1Nn` 的执行属性、
raw data 以及 import/export/TLS/load-config/IAT directory。全量报告随后对 Ghidra
识别的 12,731 个函数逐个执行反编译；其中 8,690 个入口位于真实 `.text`，其余 4,041
个是分析器沿残余假目标建立的未初始化地址，报告会明确显示
`Disassembly not permitted within uninitialized memory block`，不能作为样例行为证据。
本文所有结论均来自真实 `.text` 的 handler、字符串交叉引用，或解密后 host/guest
payload 的独立交叉验证，而不是这些伪目标。

## 运行架构

| 层 | 已验证职责 | 不承担的职责 |
|---|---|---|
| VMSpoofer 管理器 | 创建/删除/启动 VM；设置 CPU 数量、内存、固件序列、网络、GPU-P 12 项配额；WIM→VHDX；挂载 VM EFI；安装/恢复宿主 EFI；下载 profile 固件 | 不在普通用户态直接模拟 GPU |
| 宿主 EFI / Hyper-V 扩展 | `bootmgfw → winload → Hyper-V loader` 链路；加载加密 payload；处理专用 CPUID 通道 | 不是 DDA，也不是 Windows 测试驱动 |
| guest EFI | 每 VM profile 引导握手；解密 EFI runtime payload；后者挂接 guest kernel/驱动路径并改写硬件回读 | 不携带共享 Windows 系统文件或厂商显示驱动包 |
| WIM | Windows 10 系统、运行库、无人值守和裁剪策略 | 不含 NVIDIA/AMD 显示驱动，不含 profile，不含宿主扩展 |
| Microsoft GPU-P | 分区实际宿主 GPU；提供厂商计算/编码能力和 vendor runtime | 不提供物理输出口、独立物理 EDID 或每 VM 物理 GPU 序列号 |

宿主和 guest 自定义 EFI 的 PDB 路径分别包含：

```text
F:\vc_workspace\Voyager_Host\x64\release\bootmgfw_release.pdb
F:\vc_workspace\Voyager\x64\release\bootmgfw_release.pdb
```

其链路与公开 Voyager 的设计一致：先挂钩 Windows boot manager，再进入
winload/Hyper-V loader，扩展 hypervisor image 并接管 VM-exit。样例是私有更新版；
公开版本的签名和 Windows 版本范围不能直接当作 19045.7417 可用证明。

## 管理器、模板池与创建链

运行态归一化管理器的字符串和调用点确认了以下创建顺序：

1. `Get-WindowsImage` 检查 WIM/ESD/ISO 版本，调用随附的 `Convert-wim.ps1` 将
   index 1 应用到动态 VHDX，并替换无人值守模板中的用户名、主机名和密码占位符；
   该脚本主体是微软 `Convert-WindowsImage` 示例的副本加薄封装，不是硬件投影代码；
2. `New-VM` 创建 Generation 2 VM，设置 vCPU、内存、网络、固件、分辨率上限和
   Hyper-V integration service；克隆路径使用 `Convert-VHD`，随后调用
   `Set-VHD -ResetDiskIdentifier`；
3. 对选定的 `Msvm_PartitionableGpu` 调用标准
   `Add-VMGpuPartitionAdapter`，再设置 VRAM、Encode、Decode、Compute 的
   min/max/optimal 共 12 个 quota。所谓“100% GPU 配额”就是这些 GPU-P quota，
   不是 DDA 或 PCIe passthrough；
4. `SyncGpuDriver` 从宿主选定 Display adapter 的 INF/FileRepository 同步厂商
   package；`InitVMDevices` 挂载 guest VHDX，离线修改 DriverDatabase/Enum，并把
   guest 工具放入 `ProgramData\\tools` 和公共 Startup；
5. 管理器挂载 EFI partition，写入该 VM 的 guest `bootmgfw.efi`，再可靠卸载 VHDX；
   启动前由宿主扩展与 guest 固件完成 CPUID 握手和 profile runtime 初始化。

模板获取链同样是确定的。反编译后的 `getArchTpls` 请求携带
`vendor/family/model`，`getArchTpl` 携带 `arch_id`；`create2` 同时提交
`uuid/name/arch_id/json` 与宿主身份字段。之后 `downloadGuestFirm` 以已创建的
`uuid`、CPU 与宿主身份取回 guest 固件，`guestConfig` 再提交 Secure Boot、HRR、
TSC 等开关；宿主部分另走拼写保留的 `downloadHostFrim`，并携带 Windows
build/UBR。pc01、pc02 的本地配置分别记录 `archId=35` 和 `archId=169`。管理器
本体只留有 Intel/AMD generation 名称、UI 字段和少量默认 PCI 映射，没有完整模板
实体；WIM 中也没有这些 profile。因此：

- 样例的硬件池在当前订阅/服务端不可用时不能完整离线恢复；
- “新建/克隆后硬件码变化”由 `create2 + archId + per-VM firmware` 实现，不是
  WIM 每次启动随机；
- P-11 的 21 套组合必须维护自己的版本化、本地可审计 profile schema，分别约束
  CPU/主板/芯片组/内存/磁盘/网卡/显示器的合理搭配，并在创建或克隆时只生成一次
  VMId、MAC、UUID、磁盘 ID 和序列号后持久化；
- 只有名称/序列号字段落地不能等价于样例的启动期设备路径。当前 P-11 对 AMD CPU
  可保存 profile 元数据，但真正的 AMD CPUID family/model 投影仍依赖未来可审计的
  宿主扩展；AMD GPU 则必须在 Radeon 宿主上以真实 GPU-P 驱动链验收。

## 解密后的两级 payload

宿主 EFI 的 `FUN_1800033D0`（VA `0x1800033D0`）读取 SMBIOS Type 1 UUID。
它将 UUID 原始字段按标准显示顺序转换为 16 个大写 ASCII 十六进制字符，作为
AES-128-CBC 密钥；IV 为全零。实验宿主 UUID 为
`106B1C00-10FD-11EF-99CF-C59D090F2A00`，所以外层密钥为
`106B1C0010FD11EF`。两个容器都使用相同格式：

1. AES-CBC 解密 32-byte header；
2. header 前 16 byte 作为 RC4 key；
3. 容器偏移 32 的 little-endian `uint32` 是 payload 长度；
4. 从偏移 36 开始 RC4 解密正文。

宿主 JSON 明文列出 `hv.exe/hvix64.exe/hvax64.exe`、`hvloader.efi`、
`voyager_context`、`vm_e_a/vm_e_b`、`BlLdrLoadImage`、
`BlGetBootOptionBoolean` 以及 bootmgfw 原版/备份路径。第二容器是一个带
`.shadowh/.shadowp/.vcpuExt/.vmContext` 节的 x64 PE；PDB 为
`F:\vc_workspace\Voyager_Host\x64\release\payload_intel_release.pdb`。

宿主 EFI 的注入函数 `FUN_18000A510` 把该 PE 作为新 `payload` section 复制进
Hyper-V image、处理重定位、解析三个 export，并填写 `voyager_context`。其中
context 偏移 `0x61` 保存完整宿主 UUID。payload 的 CPUID dispatcher 位于
`0x180007BB0` 附近；`0x1800084D0` 处理 `0x51530D` 子命令：它先验证 guest
CPUID 指令附近约 100 byte 启动代码，再把 context 中的 36-byte UUID 写到 guest
提供的缓冲区。失败分支返回的是固定代码字节，不是可用密钥。

因此 pc02 guest EFI 可完全离线解开。其 AES key 是返回 UUID 字符串的前 16 byte，
即 `106B1C00-10FD-11`。明文 JSON 包含宿主 UUID、pc02 VMId
`B014CBBC-8351-430E-832D-732AB6922BB2`、`set_msr_hook/set_msr_origin` 等符号和
两个 profile 数字串。第二容器 PDB 为
`F:\vc_workspace\Voyager\x64\release\bootmgfwdriver_release.pdb`。

guest payload 不是普通驱动安装包。已反编译的关键行为包括：

| VA | 已验证行为 |
|---:|---|
| `0x1800410B0` | EFI runtime entry，进入约 80 KiB 的 profile/初始化主函数 |
| `0x180006C20` | 根据 `vmbus.sys/mssmbios.sys/vpci.sys`、显示、输入等映像加载事件分派 hook |
| `0x18000C4D0` | 动态解析大量 kernel API，包括 image notify、registry callback、PnP/IRP 和物理内存 API |
| `0x180029BE0` | 遍历 PnP 节点，删除 `VmGeneration/VmGid/VMBus/PNP0A08` 痕迹，并交换 `wvmbusvideo/vrd` 节点内部属性指针 |
| `0x180003B90` | 覆盖显示 adapter 的 `HardwareInformation.*` 注册表值，AMD/Radeon 走单独编码分支 |
| `0x180010280` | 在 SCSI inquiry 路径中把 `Msft Virtual Disk` 替换成 profile 型号 |
| `0x180011020` | 在内存中改写 `DISPLAY\\`、`MONITOR\\` instance ID 和固定 UID |
| `0x1800081F0` | 识别 `nvlddmkm/igdkmd*/amdkmdag`，随后选择不同 HyperVideo hook 路径 |

payload 还包含固定的 `GPU-721729bf-6c7d-6b4e-f8a2-cd2675374e2c`、
`PCI\\VEN_10DE&DEV_1380`、`PCI\\VEN_10EC&DEV_8168`、Intel chipset IDs、
`Great Wall GW600S 512GB`，以及 2014 年 GTX 750 VBIOS 文本。pc02 对外却声明
RTX 4060 Ti。这证明样例的“硬件池丰富”主要是运行时替换/指针交换层，内部来源并不
始终与所选型号一致；设备管理器中的厂商名和原厂驱动存在，并不证明该 devnode 的
PCI 拓扑、VBIOS、UUID、签名归属和实际 GPU 一致。

## CPUID 协议和宿主初始化

归一化管理器与 guest EFI 中出现以下命令。没有完全确定的命令不得在 P-11 中
凭常量名称猜测实现。

| 值 | 证据 | 当前语义 |
|---:|---|---|
| `EAX=0x5153, ECX=0x515152` | 管理器 `0x140102CFA` 直接执行 CPUID，并检查 `EBX=ECX=EDX=1` | **已验证：** 宿主 payload 能力探测 |
| `0x515301` | 管理器启动初始化路径 | **高可信推断：** CPU vendor/profile 初始化；参数语义未完全恢复 |
| `0x51530C` | 管理器 `0x1401986A0`，先后传 `RCX=1/RDX=MCFG base` 和 `RCX=2/RDX=bus<<20` | **已验证：** ACPI MCFG/PCIe 配置空间几何信息，不是 profile ID |
| `0x51530D` | pc02 guest EFI 首个有效流程；`RCX=6`，`RDX` 指向 36-byte buffer | **已验证：** 校验 guest 启动 stub 后返回宿主 UUID；UUID 前 16 byte 解密 guest JSON/runtime payload |
| `0x51530F` | 管理器分配最多 `0x100` 项并读取返回描述符 | **已验证：** 从宿主 payload 请求 MSR 描述符 |
| `0x515310` | 每次 WinRing0 MSR 读取后回送值/状态 | **已验证：** 回送宿主 MSR 采样结果 |
| `0x515312` | 环境设置函数附近 | **未验证：** 不能声明为硬件 profile 命令 |
| `0x515313/0x515314` | 订阅、plan、price、expired/trial 路径 | **已验证：** 出现在授权逻辑；不是 CPU/主板配置证据 |

样例管理器临时使用 `WinRing0x64.sys`，通过 IOCTL `0x9C402084` 读取 MSR，
再由 `0x515310` 回送。这是宿主 CPU 能力采样，不是 GPU 直通。P-11 不采用
WinRing0：其攻击面、签名历史和长期驻留方式都不符合 P-11 的生产门槛。

guest payload 还直接调用 `0x515302/03/08/09/0D` 完成 VM 生命周期状态、内存
映射/修改、hook 表登记和上下文读取。换言之，隐藏 Hyper-V 设备、磁盘字符串、
显示/显示器 ID 与 CPU/平台投影是同一条宿主 VM-exit + guest runtime hook 链，
不能从 WIM 单独复制，也不能用标准 GPU-P cmdlet 等价实现。

## pc01 / pc02 身份与随机性

| 项 | pc01 | pc02 |
|---|---|---|
| CPU | i5-13600KF | i7-13700F |
| 主板 | GALAX B760 METALTOP D4 | MSI B760M BOMBER WIFI / MS-7D90 |
| vCPU | 20，`HwThreadCountPerCore=1` | 20，`HwThreadCountPerCore=1` |
| VMId | `B26D2383-ADD4-4F96-B6CE-F3589582D0D6` | `B014CBBC-8351-430E-832D-732AB6922BB2` |
| MAC | `50-FF-48-51-E8-C7` | `50-D9-88-23-2A-73` |
| BIOS/板/机箱序列 | `2138-0670-4737-8302-3904-4643-43` | `5483-1337-0926-0147-2078-2282-44` |
| GPU 配额 | 100% | 100% |

两台 VM 的 VMId、MAC、固件 GUID、序列号和 guest EFI 摘要不同，说明样例确实
为新建 VM 生成独立身份。P-11 的 21 套 profile 也必须遵守同一原则：profile
只定义合理的型号组合；VMId、MAC、磁盘 ID、系统 UUID 和全部序列号在克隆时生成
一次并持久化，不能每次开机变化。

GPU UUID 不属于上述可随机字段。当前 P-11 普通 GPU-P 回读为
`GPU-cb6dec81-5f26-ce43-e272-d17cf84170ae`。**高可信推断：** 同一宿主物理
4060 Ti 的多个 GPU-P guest 会看到相同的 vendor UUID，样例也无法仅靠改 EFI
生成独立的原厂 NVIDIA UUID。尚未在不启动 pc01/pc02 的前提下取得两台样例的
直接 UUID 回读，因此不能把“样例两台一定相同”写成已验证事实。P-11 不伪造
`nvidia-smi`/NVAPI 返回值；若未来驱动提供官方 partition UUID，再以直接回读为准。

## 配套程序与交互链

样例安装目录的 `data\\2` 不是 WIM 内容，而是创建 VM 时再复制/安装的工具仓库。
完整清单包含 `GuestCtrl.exe`、USB/IP host/client、Oracle VBoxUSB filter、Tftpd64、
IPMsg、两套 2014/2015 年 VBCABLE、旧版 WinRing0 和提权辅助程序。管理器中的
`ProgramData\\tools`、公共 Startup、`GuestCtrl.exe`、`attacher.exe`、`IPMsg`、
`VBCABLE` 和 `ets.exe` 字符串与该目录逐项对应。

| 组件 | 文件证据 | 已验证用途与边界 |
|---|---|---|
| `GuestCtrl.exe` | 磁盘 PE 绝大多数正常节 raw size 为 0，入口落在约 9.3 MiB 高熵保护段；仅保留 `newdev/SetupAPI/WinINet/WS2_32` 等稀疏 import；无 Authenticode | guest 在线设备安装/控制程序，含 PnP 与网络能力；未取得干净运行态映像，不能把未验证语义写成显示驱动能力 |
| `monitor.exe` | Product `usbipd-win`，version `5.3.0-54`，PDB 为官方构建路径 `Usbipd/.../usbipd.pdb`；签名人为开源开发者 Frans van Dorsselaer | USB/IP host/service。文件名 `monitor` 是重命名，不提供 Monitor class、EDID、IDD 或 GPU 显示输出 |
| `attacher.exe` | Product `usbip-win 0.3.4`，PDB `D:\\work\\usbip-win\\Debug\\x64\\attacher.pdb`；未签名 | USB/IP client/forwarder；debug build，不应直接复制进 P-11 发布包 |
| VBoxUSB / UDE | `VBoxUSB.inf` 注册 `USB\\VID_80EE&PID_CAFE` 和 `VBoxUSB` service；UDE INF 注册 `USBIPWIN\\root/vhci`、`ROOT\\VHCI_ude` | host USB 共享、guest virtual host controller；会额外增加 VirtualBox/USBIP 命名 devnode |
| Tftpd64 / IPMsg | TFTP service 配置开放 UDP 69、相对 base directory；IPMsg 为单独 LAN 工具 | guest 文件/消息通道，和显示帧传输没有直接证据 |
| VBCABLE / VBCABLE_A | 2014/2015 年的两套 virtual audio package | 音频重定向；会增加虚拟音频设备，不能作为“真机声卡” |
| `ets.exe` | Product `ETS (Elevate To System) 1.03`，创建临时 LocalSystem service；旧证书链当前验证失败 | 提权辅助，不是 GPU/显示组件；P-11 不采用 |

随附 `api.html` 定义四个控制接口：`/sendMouse`、`/getMousePosition`、
`/sendKey`、`/getResolution`；管理器还注册 `/help`。反编译确认 route 初始化函数
`0x1400865C0` 使用 `httplib::Server` 并在配置端口监听 `0.0.0.0`，不是仅监听
loopback。五个 handler 只解析 query 参数，route 注册和 handler 内均未观察到 token、
header、来源地址或调用者身份检查，因此同一局域网可达性取决于宿主防火墙，不能把它
当作已认证控制通道。P-11 保持 `127.0.0.1` 监听；若以后需要远程控制，应由独立、经过
认证且有访问控制的 VMate 通道代理，不能直接扩大监听范围。

五个实际 handler 已从 C++ `std::function` vtable 还原，不能把相邻的 RTTI getter
误判为处理函数：

| route | handler VA | 已验证参数/行为 |
|---|---:|---|
| `/help` | `0x140086BF0` | 读取安装目录 `api.html` 并返回 `text/html` |
| `/sendMouse` | `0x140086EF0` | `vm/type/button/buttonAction/pos`；支持 relative/absolute、多组坐标和 left/middle/right 的 down/up；absolute 按 VM 当前宽高及 scale 转换为 0..65535 |
| `/getMousePosition` | `0x140087A10` | 以 `vm` 查找活动 VM 会话，向内部窗口/输入对象发消息后返回 `x/y` |
| `/sendKey` | `0x140087F70` | `vm/action/code`；接受逗号分隔的标准 MakeCode，含 `0xE0xx` extended code，逐个发送 down/up |
| `/getResolution` | `0x140088B30` | 以 `vm` 返回 `width/height/scale` |

实际输入并不经 VNC。管理器为每台活动 VM 维护内部对象，鼠标和键盘分别封装为
type 4、type 5 的消息后投递；这与其 `VMConnect` 路径共同解释了样例的鼠标手感，
但不构成 GPU 渲染或显示驱动证据。键盘 down 与 up 仍是两个独立 HTTP 请求；窗口失焦、
HTTP 中断或进程退出若没有 finally-release，就会留下按键按下状态。已分析的 route、
handler 和配套页面中未发现统一 release-all 路径。这与调试 VM 时出现“一次按键连续
输入”的风险一致。P-11 的控制台必须维护 pressed-key/button 集合，并在 focus loss、
disconnect、VM stop、窗口销毁和异常路径统一发送 release-all；禁止把自动重复请求当成
输入平滑方案。

`SaveVMScreenshot.ps1` 使用 Hyper-V WMI 的 `Msvm_VideoHead` 和
`GetVirtualSystemThumbnailImage`，再缩放成 20% 缩略图。它只服务列表预览，不是实时
高帧率控制台。样例同时保留 `VMConnect` 和上述输入 API；因此 pc01/pc02 主观更流畅
可能来自 VMConnect/增强会话、guest input channel 或 USB 重定向，但当前没有证据证明
USB/IP 或 `GuestCtrl` 改善了 GPU 渲染。显示链和输入链必须分别验收。

## GPU-P 实测对比

同一版 `Detect-VGpuP.ps1` 的结果：

| 指标 | pc01（保存证据） | pc02（保存证据） | P-11 修正版实测 |
|---|---:|---:|---:|
| 功能 GPU-P 信号 | 2 | 2 | 3 |
| 固有 `D3DKMT Paravirtualized` | 1 | 1 | 1 |
| Hyper-V 暴露 | 1 | 1 | 1 |
| Display 暴露 | 1 | 1 | 2 |
| 暴露项合计 | 2 | 2 | 3 |
| 总阳性 | 3 | 3 | 4 |

旧规则只搜索 `PCI bus` 子串，曾把 `Virtual PCI Bus Slot ...` 误当成物理 PCI
位置。修正版只接受完整英文或中文 `PCI bus N, device N, function N` 结构。
P-11 结果来自 2026-08-25 直接冷启动复采；随后又对运行中的 Hyper-V VM
`VMate-P11-1`（备注 `P11-Lab`）通过 PowerShell Direct 执行同一份检测器，结果仍为
3/1/3/4。pc01、pc02 保持 Off，表中样例数字由已保存证据逐项 signal 重算。两台
样例原本都已有一个空位置节点，因此新增规则不会增加它们的暴露类别，但恢复可用后仍应
使用同一 SHA-256 的检测器直接复采。

类别计数不能代表设备链一致：

- pc01/pc02 各有两个同名 4060 Ti 显示节点；一个实际是
  `PCI\VEN_10DE&DEV_2803`、绑定官方 `nvlddmkm/oem20.inf`，另一个实际是 Intel
  芯片组 PCI ID、绑定 `VirtualRender`，只是被改成相同显示名。D3DKMT 总共枚举
  三个 adapter。样例因此不是“设备管理器只有一张原厂显卡”的参考实现。
- 当前 P-11 只有一个显示节点，但它是
  `PCI\VEN_1414&DEV_008E`、`VirtualRender`、`vrd.inf`、Microsoft provider。
- 当前 P-11 的 `nvidia-smi` 已通过官方 NVIDIA 595.95 runtime 访问 4060 Ti，
  报告 `00000000:01:00.0`、device `0x280310DE`、8188 MiB；guest DriverStore 与
  HostDriverStore 中 `nvlddmkm.sys` 均为 32.0.15.9595、摘要相同且 WHCP 签名
  有效。但这个厂商运行时没有对应的 present `VEN_10DE` Display devnode。
- 样例把官方 NVIDIA 包放在普通 `DriverStore\FileRepository`，没有
  `HostDriverStore`；它借助宿主/guest 启动扩展产生额外的 vendor PCI devnode。
  P-11 不能仅删除 `HostDriverStore`：在没有等价且可审计的启动期设备路径前，这会
  破坏现有 GPU-P runtime。当前结论是“功能不少于样例、暴露多 1、设备真实性未达到
  目标”；禁止把 VRD 重命名继续算作原厂单显卡。

同一次 P-11 回读还确认：磁盘仍显示 `Microsoft Virtual Disk`、无序列号；网卡仍
显示 `Microsoft Hyper-V Network Adapter/netvsc/VMBUS`；BIOS version 数组仍含
`VRTUAL - 1`；Monitor class 和 `WmiMonitorID` 都为 0。按名称、实例 ID 和厂商
组合过滤后仍有 21 个 `Hyper-V/Virtual/VMBUS` 暴露节点。宿主和 guest 均为
`testsigning=off/nointegritychecks=off`；这些签名状态正确，但不改变上述设备链事实。
这四类问题都必须保留在严格门禁的失败列表中。

## WIM 完整分析

### 元数据

```text
Index                 1
Name                  Windows 10 专业版（Admin）
Architecture          x86_64
Edition               Professional
Language              zh-CN
Build                 19045.7417
Directories / files   26,037 / 85,696
Uncompressed bytes    12,007,950,131
Created               2026-06-10 00:07:00 UTC
Modified              2026-07-30 03:40:59 UTC
```

与用户提供的 `/home/ubuntu/images/iso/win10.iso` 中 Windows 10 Pro（index 4）相比：

| 项目 | 原版 ISO Pro | 样例 WIM | 差异 |
|---|---:|---:|---:|
| Windows build | 19041.2965（22H2） | 19045.7417 | 样例后续集成更新 |
| 未压缩大小 | 15,953,918,905 | 12,007,950,131 | 样例少约 3.95 GB |
| 文件 | 104,951 | 85,696 | 少 19,255 |
| 目录 | 29,085 | 26,037 | 少 3,048 |
| DriverStore INF/目录 | 663 | 504 | 少 159 |
| WinSxS manifests | 17,730 | 15,303 | 少 2,427 |
| servicing package ID | 725 | 562 | 少 163 |
| WindowsApps 顶层目录 | 169 | 22 | 少 147 |
| SystemApps 顶层目录 | 38 | 19 | 少 19 |

原版 ISO SHA-256 为
`D485D370406CBCB68959718817BD12ED87E537A14C885F84962E07136FC4A049`；其中
`install.wim` SHA-256 为
`050BD94AD5995A658ADAF73FC65CB6E0E8A55679D38A25A1C4F2A6ED166CF2E2`。
版本差异意味着逐文件差异不能全部解释为“删除”，但组件 ID 和应用 family 对比仍能
确认样例进行了大幅裁剪。

### 驱动

WIM DriverStore 的 Display/Monitor INF 全部是 Microsoft inbox 组件：

```text
Display: c_display.inf, display.inf, displayoverride.inf, rdpidd.inf,
         rdvgwddmdx11.inf, vrd.inf, wvmbusvideo.inf
Monitor: c_monitor.inf, monitor.inf
```

`NVIDIA` 字样只出现在 PCI 表、网络或 `nvraid.inf` SCSI storage driver 中；没有
NVIDIA Display class INF。AMD 命中是 GPIO/I2C/SATA/SBS/系统 PCI 表等 inbox
芯片组支持；没有 AMD Display class INF。因此 4060 Ti/AMD GPU runtime 必须由
VMate 在 VM 关闭时从已验证的宿主 driver package 同步，不能宣称 WIM 已内置。

`Windows\System32\drivers` 顶层有 404 个 `.sys`，原版 ISO Pro 为 413 个。
按不区分大小写的文件名比较，样例只多出 6 个、原版多出 15 个；样例多出的
`hidspicx/iastorac/iastorafs/iastorvd/mrxsmb10/srv` 均可由版本或 inbox 组件差异
解释，没有 VMSpoofer、NVIDIA、AMD display 或未知自定义 `.sys`。这再次排除
“WIM 内藏显示伪装驱动”这一假设。

镜像中也不存在 `GuestCtrl.exe`、`attacher.exe`、`monitor.exe`、WinRing0、
Voyager、USB/IP、VBoxUSB、VBCABLE、Tftpd64 或 IPMsg 工件。它只包含微软 inbox
`vrd/wvmbusvideo/monitor`，没有第三方 IDD 或 monitor INF。因而 WIM 与样例的搭配
边界是：WIM 提供可启动且经过裁剪的基础 Windows；管理器在 VHDX 创建后同步 GPU
driver、复制 guest 工具、修改离线 registry/EFI；真正的平台与设备投影由下载的
per-VM firmware/runtime payload 在启动期完成。单独安装该 WIM 不会得到 pc01/pc02
的 CPU、主板、显卡或显示器效果。

离线 SYSTEM hive 中样例有 636 个 service key，原版有 663 个。受 build 差异影响，
不能把所有集合差都归因于裁剪；但 47 个原版 service 名在样例中不存在，其中包括
`WinDefend/WdNisSvc/SecurityHealthService/WdBoot/WdFilter/WdNisDrv/Sense/wscsvc`。
20 个样例独有名称主要来自更新后的 inbox 版本。29 个两边共有的 service 修改了
`Start`，典型值为 `DiagTrack 2→4`、`GraphicsPerfSvc 3→4`、`iphlpsvc 2→4`、
`SysMain 2→4`、`UsoSvc 2→3`、`WaaSMedicSvc 3→4`、`WdiServiceHost/`
`WdiSystemHost 3→4`、`WerSvc 3→4`。Hyper-V integration、PnP 和 GPU-P 所需
核心 service 仍注册在镜像内；部分 PnP/更新服务是在首次登录任务中被反复停止，
不是被一套更真实的设备栈替换。

Code Integrity hive 未启用 testsigning/nointegritychecks；Device Guard policy 反而有
`RequireMicrosoftSignedBootChain=1`。样例仍能运行，是因为宿主关闭 Secure Boot 后在
Windows CI 生效前执行未签名 EFI，再由启动期 payload 修改后续运行路径；不能据此把
guest 中看到的设备签名当成其自定义启动代码的原版签名。

样例还从组件存储中完整移除了 Windows Defender 的 22 个原版 package，离线 SYSTEM
中没有 `WinDefend`、`WdNisSvc` 或 `SecurityHealthService`，并删除了
`Microsoft.Windows.SecHealthUI`。这不是显示驱动兼容要求，也不应进入 P-11 基础镜像。

### Setup payload

| 文件 | 大小 | SHA-256 | 行为 |
|---|---:|---|---|
| `DirectX.exe` | 32,188,093 | `69B2910545525B11FAA8319998994D67B132891B5C74D555EE1B9E8A20269365` | 未签名 7-Zip SFX，直接展开旧版 D3DX/XAudio/XInput DLL |
| `MSVBCRT.exe` | 47,262,429 | `AD6D41D4EE8D338A12DF850A8DEF25715B13A606C2151DDBC690417F06FA5884` | 未签名运行库封装，SetupComplete 执行 |
| `NSudoLG.exe` | 178,176 | `5094AD359D8CF6DC5324598605C35F68519CC5AF9C7ED5427E02A6B28121E4C7` | 未签名 NSudo Launcher 9.0 Preview 1 |

四个 CMD 文件使用多层变量/字符拼接混淆。解开第一层后的实际策略包括：

| 脚本 | SHA-256 |
|---|---|
| `SetupComplete.cmd` | `8BDF1DBB92D6B182B34DF6B2773DD7A106D7E4B6F3F0D20522415157DE85DDF4` |
| `FirstLogon.cmd` | `218A10AA3CCAD102E95981A33EFA5C423C99954B5FDA24CF14CAFFBB197143B1` |
| `ToDesktop.cmd` | `59B8A00E675D67050348EA65F9DC218A493AA1158369A463034072E02EE161B8` |
| `schtask.cmd` | `96C8E150D0DC8BC931C64B95A75545F7D4E4F711F709E2FC2C0A80F089B5E239` |

镜像状态为 `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`，说明它确实被封装为 OOBE
母盘；Panther 目录只留下这一份 `Unattend.xml`。脚本伪装了 UTF-16LE BOM，正文实际是
ASCII/GBK 与 CMD substring 混合编码，普通文本查看器会显示乱码；这也是其策略不易审计的
原因，而不是 GPU-P 所需格式。

- `FirstLogon.cmd`：删除一次自动登录值、设置密码永不过期、启用旧照片查看器，
  随后设置 `EnableLUA=0` 和 `ConsentPromptBehaviorAdmin=0`。
- `ToDesktop.cmd`：把网络设为 Private；关闭所有 Windows Firewall profile；阻止
  feature update；设置 legacy boot menu、`disabledynamictick`；关闭休眠、AC/DC
  睡眠和 USB selective suspend；启用 CompactOS。
- `schtask.cmd`：结束并禁用 71 个 Windows 任务，包括 Windows Update、PnP、
  WER、WOF hash validation、磁盘/内存诊断；另建 8 个 LocalSystem 开机任务停止
  `CDPSvc`、`NcdAutoSetup`、`RmSvc`、`DPS`、`UsoSvc`、`WSearch`、`wuauserv`
  和 `COMSysApp`。
- WIM 自带 unattend 使用明文 Administrator password 和 9,999,999 次自动登录；
  VMSpoofer 生成的 `autounattend.xml` 还会把明文 password 写入 Winlogon
  `DefaultPassword`。

这些是安全性和可维护性倒退，不是硬件真机化。P-11 可以借鉴 WIM→VHDX、无人值守
安装和运行库准备流程，但默认不得关闭 UAC、防火墙、更新、PnP、WOF 校验或诊断。
基础镜像必须经 sysprep/generalize，密码由创建流程设置后删除 unattend 和 Winlogon
明文字段。

样例还删除了 Windows Store、照片、相机、录音、反馈、Quick Assist、OpenSSH Client、
OneDrive、Defender/Sense、部分中文 OCR/手写/语音以及大量容器/企业可选组件。P-11
无需恢复所有消费应用，但基础镜像验收必须保留驱动 servicing、PnP、Windows Update、
防火墙、安全中心、诊断与 RDP/Enhanced Session 所需组件；裁剪动作必须白名单化并在
每个受支持 Windows build 上回归，不能复用样例的黑名单脚本。

## 宿主 D 盘来源

VMSpoofer 编辑 VM EFI 时拼接执行：

```powershell
Mount-VHD -Path '<vm>.vhdx'
$partitions = Get-DiskImage -ImagePath '<vm>.vhdx' | Get-Disk | Get-Partition
# 定位 partition 2 / EFI volume
Dismount-VHD -Path '<vm>.vhdx'
```

`Mount-VHD` 触发 Windows automount，数据分区会临时获得空闲盘符。异常、中断或管理器
被关闭时，样例没有可靠 `finally` 清理，因此 pc02 数据分区会遗留为宿主 D 盘。它不是
第二块直通盘，也不是 WIM。VMate 的离线编辑必须以 VMId + 唯一 VHDX + 磁盘摘要绑定，
在 `finally` 中卸载，并在退出时只恢复本进程创建的挂载，不能按盘符猜测目标。

## P-11 实现约束

1. GPU-P adapter 从 VM 启动前到关机必须持续存在；禁止已初始化后 pause/hot-add。
2. 现有 VID paused CPUID 实验与 GPU-P 组合已分别触发 `dxgkrnl` BugCheck `0x3B`
   和 `vmuidevices.dll` access violation，必须失败关闭，不能自动重试。
3. CPU brand/family/model 的长期方案必须移到可审计的宿主引导期扩展；使用独立、可回滚
   的 UEFI boot entry，链入 Microsoft 原版 boot manager，不覆盖原文件且不使用
   WinRing0。Secure Boot 关闭是这类未签名 UEFI 实验的前提；guest 始终保持
   `testsigning=off`、`nointegritychecks=off`。
4. Monitor 必须来自真实显示输出或正式签名的 IDD/monitor 路径并具备 EDID/WMI 回读；
   仅写注册表、注册 ROOT devnode 或把 RDP 会话当物理面板都不合格。
5. “单显卡”必须是唯一健康 `VEN_10DE`/`VEN_1002` Display devnode，并绑定厂商
   INF/KMD/UMD/有效签名；`VEN_1414 + vrd.inf` 改名后仍判失败。
6. 磁盘和网卡的型号文本可由 profile 展示，但 Hyper-V VMBus/SCSI 架构事实不能靠
   改名消失。严格报告应区分“用户可见名称”与“不可消除的架构信号”。
7. 输入控制必须对 key/button down 建账，并在失焦、断连、VM 停止和异常退出时
   release-all；连接窗口禁止通过无边界重复注入来掩盖延迟。
8. P-11 发布包只能带来源明确、许可证兼容且签名/摘要可审计的组件；不得复制样例的
   私有 `GuestCtrl`、guest/host firmware、调试版 USB/IP、PFX 或旧提权工具。

以上边界用于防止 P-11 为追求分数复制样例的重复节点、错误 PCI ID、明文凭据或不安全
系统裁剪。最终“超过样例”按设备链一致性、稳定性、回滚能力和签名完整性判定，不只看
三项检测计数。

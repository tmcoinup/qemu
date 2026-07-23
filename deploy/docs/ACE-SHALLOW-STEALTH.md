# 浅层 GPU 身份投影：当前设计与约束

本文解释当前浅层 GPU 方案的设计边界。它不是另一套安装流程；实际部署仍只使用
`deploy/guest-stealth/package.sh` 生成的统一离线 `respawn-stealth.exe`。操作步骤见
[`STEALTH-WORKFLOW.md`](STEALTH-WORKFLOW.md)，实现细节见
[`guest-stealth/README.md`](../guest-stealth/README.md)。

第三方软件的检测规则会变化，本项目不能承诺某个特定产品必然接受当前环境。本文只
说明可以审计的技术事实，不把显示名称或一次测试结果当成兼容性保证。

当前硬件目录包含 6 个芯片型号 × 3 个板卡品牌，共 18 块 AIB（12 NVIDIA、
6 AMD），内部 carrier 为 `1AF4:A101`–`1AF4:A112`。本文继续用 GTX 1050 Ti
说明三层模型，但同一原子校验也适用于其余 NVIDIA/AMD 板卡；物理设备始终为
`1AF4:1050`，不做 GPU passthrough/vGPU，也不虚构 GPU 序列号。

## 1. 为什么采用浅层方案

当前原则是让内核驱动绑定保持真实、稳定、可验证，同时把应用需要的展示身份限制在
用户态：

- 物理主 PCI ID 固定为 virtio-gpu 的 `1AF4:1050`。
- Windows 只绑定 stock Microsoft-WHQL `VioGpuDod`。
- GTX 1050 Ti 的逻辑 `10DE:1C82` 不冒充物理总线枚举结果。
- 名称、逻辑 PCI 字段和 NVAPI 查询结果来自注册表与固定摘要的系统用户态 DLL。
- 不改变 Windows 启动链、代码完整性策略或信任根。
- 客体尽量不安装软件；除 stock 显示驱动外，不增加 NVIDIA 软件栈或常驻服务。

这样做的直接好处是 stock 驱动仍能按照它支持的硬件 ID 正常绑定。把物理主 ID 直接改成
`10DE:1C82` 并不会让 `VioGpuDod` 变成 NVIDIA 驱动，反而会破坏原有匹配关系，可能出现
驱动无法启动或 Code 43。

## 2. 三层身份模型

### 2.1 物理层：保持 `1AF4:1050`

PCI InstanceId、配置空间和内核驱动匹配仍基于：

```text
PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8210DE&REV_A1
```

其中主 Vendor/Device `1AF4:1050` 决定 stock `VioGpuDod` 的驱动绑定；SUBSYS
`1C8210DE` 只用于选择对应用户态 profile。统一 EXE 会先校验所有在线 PCI 显示设备
的物理主 ID，发现非 `1AF4:1050` 就停止。

真实成功条件不是“设备名称看起来像 GTX”，而是：

- PnP 状态正常；
- Problem 为 0；
- `DEVPKEY_Device_Service` 为 `VioGpuDod`；
- 已绑定的驱动包通过固定摘要和 Microsoft WHCP 签名检查。

### 2.2 注册表层：投影 `10DE:1C82`

驱动确认成功后，初始化脚本根据 SUBSYS 写入版本化的
`HKLM\SOFTWARE\StealthGPU` 身份。GTX 1050 Ti profile 的逻辑值为：

| 字段 | 逻辑值 |
| --- | --- |
| 名称 | `NVIDIA GeForce GTX 1050 Ti` |
| Vendor ID | `10DE`（十进制 `4318`） |
| Device ID | `1C82`（十进制 `7298`） |
| Revision | `A1` |
| 模式 | shallow user projection |

这些值供名称刷新和用户态查询使用。专用 projector 仅把 SetupAPI HardwareID 排成
“逻辑首项 + 完整物理数组”；它不改变 PnP InstanceId、PCI 配置空间或驱动绑定。

### 2.3 进程层：双架构系统 NVAPI

统一 EXE 内含 PE32 `nvapi.dll` 和 PE32+ `nvapi64.dll`。GPU-Z 2.70 主程序是 32 位，
所以前者事务发布到 `SysWOW64`；后者发布到 `System32`，覆盖其 x64 辅助组件。
installer 不写 GPU-Z 原始目录或 PATH，也不会覆盖未知同名 DLL。两份文件只是用户态
身份查询层，没有服务、驱动、控制面板或 NVIDIA 运行时安装包。

## 3. 唯一部署入口

host 在仓库根目录构建：

```bash
bash deploy/guest-stealth/package.sh
sha256sum deploy/guest-stealth/dist/respawn-stealth.exe
```

把生成的 `deploy/guest-stealth/dist/respawn-stealth.exe` 离线复制到 Windows 客体，
推荐路径为 `D:\工具\respawn-stealth.exe`。客体只运行这个 EXE；它会按以下顺序完成：

1. 安全释放和验证内嵌 payload；
2. 对物理 `1AF4:1050` 做前置门禁；
3. 仅在需要时安装 stock Microsoft-WHQL `VioGpuDod`；
4. 再次验证真实驱动服务；
5. 提交注册表浅层身份；
6. 事务发布双架构系统 NVAPI，未知目标 fail-closed；
7. 注册内置计划任务并同步提交 fake-first HardwareID；
8. 重启使驱动、EDID 和名称初始化完整生效。

当前部署不启动 HTTP 服务，不从网络下载或管道执行脚本，也不要求用户安装 NVIDIA
驱动、控制面板或其它 GPU 工具。GPU-Z 若用于验证，应使用用户自行核验来源的单文件
版本；统一 EXE 初始化后可直接双击，不依赖专用 helper。

## 4. 明确禁止的深层行为

当前方案不使用，也不提供以下行为的回退入口：

- 自签名证书或自签名显示驱动；
- patched `viogpudo`；
- EfiGuard 或任何 boot manager / winload 替换；
- 非标准 Trusted Root；
- 测试签名、禁用代码完整性或 PatchGuard 修改；
- GPU 深层主 PCI ID 模式；
- 覆盖真实 NVIDIA 或其它未知摘要的 System32/SysWOW64 NVAPI；
- 把用户态 NVAPI shim 误称为 NVIDIA 驱动或 3D 运行时。

历史版本中出现过这些实验性路径。它们只可作为不可执行的历史背景，不是当前工作流、
故障修复步骤或兼容性备选项。

## 5. 3D 加速边界

浅层身份投影不增加 Windows 客体的 3D 能力。stock `VioGpuDod` 是 Display-Only
驱动，负责显示扫描输出，不提供 GTX 1050 Ti 的渲染或计算接口。因此当前模式没有：

- guest Direct3D 加速；
- CUDA；
- NVENC/NVDEC；
- NVIDIA 内核驱动、控制面板或真实显存/频率管理。

host 侧 EGL、virgl、GL texture scanout 或 GPU handle 成功，只说明 QEMU 在宿主侧的
显示处理路径；它不会把 Windows `VioGpuDod` 变成支持 virgl 3D 的客体驱动。NVAPI
shim 同样只回答身份查询，不参与渲染。

## 6. GPU-Z 2.70 验证边界

初始化完成并重启后，普通用户直接双击 `GPU-Z.2.70.0.exe`。工具来源与
Authenticode 签名仍由用户负责核验，不需要旁置 DLL、PowerShell helper 或环境变量。

系统搜索路径和 SetupAPI fake-first 共同解决当前 GPU-Z 路径；若工具改读 PCI 配置空间，
仍会看到物理 `1AF4:1050`，而未实现的 NVAPI 私有接口也可能使部分字段为空。该版本必须在
真实 Windows 客体做端到端测试，不能仅凭静态单元测试承诺所有字段或第三方检测结果。

## 7. 审计检查

在 SDL 本地控制台检查：

```powershell
$display = Get-PnpDevice -Class Display -PresentOnly
$display | Format-List FriendlyName,Status,Problem,InstanceId

$display | ForEach-Object {
    Get-PnpDeviceProperty -InstanceId $_.InstanceId `
        -KeyName DEVPKEY_Device_Service,DEVPKEY_Device_DriverInfPath
}

$identityRoot = 'HKLM:\SOFTWARE\StealthGPU'
$currentIdentity = (Get-ItemProperty -LiteralPath $identityRoot `
    -Name CurrentIdentity).CurrentIdentity
if ($currentIdentity -notmatch '^[0-9A-F]{32}$') {
    throw 'CurrentIdentity 不是有效的已提交身份指针'
}
Get-ItemProperty -LiteralPath (Join-Path $identityRoot "Identities\$currentIdentity") |
    Format-List IdentitySchemaVersion,IdentityMode,SpoofName,SpoofPciVendorId,
        SpoofPciDeviceId,SpoofRevisionId,SpoofMemoryType,
        SpoofMemoryBusWidthBits,SpoofBaseClockKHz,SpoofBoostClockKHz,
        SpoofMemoryClockKHz,SpoofSliSupported
```

期望同时看到物理 InstanceId `1AF4:1050`、HardwareID 逻辑首项 `10DE:1C82`、第二项
物理 `1AF4:1050`、服务 `VioGpuDod` 和注册表逻辑 `10DE:1C82/A1`。GTX 1050 Ti
还应是 schema 2、`GDDR5/128 bit`、`1290000/1392000/3504000` kHz 与
`SLI=0`。如果只有名称正确而服务不是 `VioGpuDod`，应视为失败并重新运行最新
统一 EXE，而不是继续叠加名称覆盖或安装深层驱动。

还应核对 `SysWOW64\nvapi.dll` 和 `System32\nvapi64.dll` 与 ProgramData payload 摘要
一致。出现其它摘要时必须视为冲突，不能强制覆盖。

## 8. 结论

当前浅层方案的准确表述是：

> 物理 PCI 与内核驱动保持 `1AF4:1050 + stock VioGpuDod`；SetupAPI HardwareID 使用
> profile 逻辑首项和完整物理尾部，双架构 NVAPI 通过标准系统搜索支持 GPU-Z 直接运行。

它解决的是用户态身份兼容和显示名称一致性，不是 NVIDIA 硬件仿真、驱动移植或客体
3D 加速。所有部署都从统一离线 EXE 进入，不恢复早期深层路径。

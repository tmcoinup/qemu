# Stealth Workflow：当前统一流程

本文描述全新 Windows 客体和克隆客体共用的当前流程。客体初始化只有一个发布入口：
由 `deploy/guest-stealth/package.sh` 生成的离线 `respawn-stealth.exe`。

本流程坚持“客体尽量不安装软件”：不在客体下载脚本，不修改启动链，也不安装自签名、
补丁或 NVIDIA 显示驱动。为满足 GPU-Z 2.70 直接双击，额外内容仅为两份固定摘要的
无签名用户态 NVAPI shim、项目脚本、名称刷新任务和 HardwareID 维护任务；没有服务、
控制面板、运行时安装包或第三方常驻进程。

详细实现与文件职责见 [`guest-stealth/README.md`](../guest-stealth/README.md)，完整 VM
创建、克隆和收尾顺序见 [`VM-WORKFLOW.md`](VM-WORKFLOW.md)。

当前目录包含 6 个芯片型号 × 3 个板卡品牌，共 18 块 AIB（12 NVIDIA、6 AMD）；
carrier 连续为 `1AF4:A101`–`1AF4:A112`，物理显示主 ID 始终是
`1AF4:1050`。下文 GTX 1050 Ti/`10DE:1C82` 仅是其中一个 NVIDIA 示例。
本流程不做 GPU 直通，也不定义或虚构 GPU 序列号。

## 1. 当前方案的边界

| 层次 | 当前实现 | 不代表什么 |
| --- | --- | --- |
| 物理 PCI | 固定 `VEN_1AF4&DEV_1050` | 不是物理 NVIDIA PCI 设备 |
| 内核显示驱动 | stock Microsoft-WHQL `VioGpuDod` | 不是 NVIDIA Windows 驱动 |
| 物理 PCI SUBSYS | 例如 Colorful 1050 Ti 的 `SUBSYS_A1021AF4` | carrier 只选择完整 AIB profile |
| 注册表逻辑身份 | GTX 1050 Ti 对应 `10DE:1C82/A1` | 不改变总线枚举出的主 PCI ID |
| PnP HardwareID | 同一 devnode 的规范逻辑首项 + 完整 `1AF4:1050` 物理尾项 | MULTI_SZ 多条匹配字符串不是多个显卡设备 |
| NVAPI/ADL 兼容 | 系统目录中的双架构厂商 API shim | NVAPI 主键以物理 carrier 去重，external/AIB/型号保持逻辑身份；不是厂商运行时 |
| 显示输出 | `VioGpuDod` 提供 Display-Only 扫描输出 | 不提供客体 Direct3D、CUDA 或 NVENC |

必须同时满足以下约束：

- Windows 枚举到的物理主 PCI ID 始终是 `1AF4:1050`。
- PCI 显示设备的真实服务必须是 `VioGpuDod`，驱动包必须通过固定摘要和 Microsoft
  Windows Hardware Compatibility Publisher 签名校验。
- GTX 1050 Ti 的逻辑 VEN/DEV 与所选 AIB SUBSYS/REV 存在于版本化身份、
  PnP HardwareID 规范首项和系统搜索到的 NVAPI shim 返回值中；原始完整
  `1AF4:1050` HardwareID 数组作为尾项保留。
- x86/x64 DLL 只写固定的 SysWOW64/System32 文件名，不写 GPU-Z 原目录或全局 `PATH`；
  目标若不是当前或历史 VMate 固定摘要，必须在任何覆盖前停止。
- 不使用自签名证书、patched driver、EfiGuard 或任何深层 PCI 主 ID 切换模式。
- 物理 PCI 门禁、真实驱动服务和 payload 校验任一失败时，流程必须停止，不能只改名称
  制造“已经安装成功”的假象。

## 2. Host 构建唯一发布物

在仓库根目录执行：

```bash
bash deploy/guest-stealth/package.sh
sha256sum deploy/guest-stealth/dist/respawn-stealth.exe
```

构建结果只有一个需要交付给客体的文件：

```text
deploy/guest-stealth/dist/respawn-stealth.exe
```

EXE 已内嵌 stock 驱动三件套、驱动安装器、GPU 注册表初始化脚本、双架构 NVAPI
payload 和系统发布 helper。每次修改这些输入后都要重新执行打包脚本，并用最新 EXE
替换客体中的旧副本。

不要为当前流程启动 HTTP 脚本服务器，也不要从网络管道执行 PowerShell。将 EXE 通过
现有数据盘、只读 ISO、共享目录或其它受控离线方式拷进客体即可。

## 3. 创建或启动 VM

新装系统时，在 host 使用标准启动器进入 Windows 安装介质：

```bash
deploy/scripts/start-vm.sh 2 --iso=/path/to/windows.iso
```

宿主平台确实需要 Q35/ICH9 compatibility 时，显式接受该兼容边界：

```bash
deploy/scripts/start-vm.sh 2 \
  --allow-platform-compatibility \
  --iso=/path/to/windows.iso
```

系统装好后，日常启动不添加 GPU 深层模式开关：

```bash
deploy/scripts/start-vm.sh 2
```

启动器输出应表明 GPU 是 virtio display，并明确旧 NVIDIA 名称只是浅层用户态标签。
host 端启用 GL/virgl 只改变 QEMU 的宿主渲染或扫描输出路径，不改变 Windows 客体的
`VioGpuDod` Display-Only 能力。

## 4. Guest 只运行统一 EXE

推荐把最新发布物放在：

```text
D:\工具\respawn-stealth.exe
```

在 Windows 客体中双击 EXE，接受 UAC 提权并等待自动重启；或者在管理员 PowerShell
中执行：

```powershell
Start-Process -FilePath 'D:\工具\respawn-stealth.exe' -Wait
```

无人值守首次登录可以使用统一 EXE 的首次登录参数：

```powershell
Start-Process -FilePath 'D:\工具\respawn-stealth.exe' `
    -ArgumentList '--firstlogon' -Wait
```

EXE 的关键执行顺序如下：

1. 从 Windows Known Folder 定位 ProgramData，把内嵌 payload 安全发布到受保护目录。
2. 停止旧的 `StealthGPU-ProjectHardwareId` writer，先验当前在线实例；必要时恢复
   原始 physical-only 数组，并在任何驱动/PnP 操作前再次门禁完整物理 HardwareID。
3. 枚举所有在线 PCI 显示设备，要求物理主 ID 全部为 `1AF4:1050`。
4. 已绑定 `VioGpuDod` 的克隆客体走无扰动快速路径；未绑定的全新客体才校验并安装
   内嵌 stock Microsoft-WHQL 驱动。
5. 再次确认真实服务是 `VioGpuDod`；确认失败就停止，不写 GPU 伪装名称。
6. 根据 PCI SUBSYS 持久化注册表逻辑身份。GTX 1050 Ti profile 映射为
   `10DE:1C82/A1`，物理 `1AF4:1050` 不变；identity schema-2 的 `SpoofName`
   保留完整 AIB canonical 标签。
7. 先预检/staging x86/x64 NVAPI，再事务发布到 SysWOW64/System32；未知同名 DLL
   fail-closed，第二架构失败会回滚第一架构。新的 transaction schema-5 把 Enum
   `FriendlyName`/`DeviceDesc` 和 Class `DriverDesc` 写为标准芯片名，把
   `Mfg`/`ProviderName` 写为芯片厂商；schema 1/2/3/4 只兼容恢复旧 journal。
   重跑时 Class 目标只按 staged 物理实例的 Driver/Service/INF 唯一绑定，不按
   DriverDesc 名称筛选。若已加载工具仅锁住旧 backup，则保留精确摘要 receipt，
   只重启一次后 Recover 清理，不修改 ACL 或登记无凭据的延迟删除。
8. 在同一 VioGpuDod devnode 上 Apply/Verify HardwareID 的规范逻辑首项 + 完整物理
   尾项，并在该最终状态运行厂商 API probe；随后注册 SYSTEM/Highest 的名称刷新任务
   以及启动/登录 `StealthGPU-ProjectHardwareId` 维护任务。
   Apply 在设备写入前持久化并回读 `RollbackHardwareIds`，使 journal 收尾的任一
   中断点都可恢复。全流程最多安排一次自动重启；若恢复后芯片组仍待重启，任务切到
   `ChipsetVerification` 并返回 `30`，由人工重启后只做 INF 复核。
   `MatchingDeviceId`、`InfPath`、`InfSection`、`Service`、真实 BDF 和 Driver
   仍保持 stock `VioGpuDod` 绑定值，随后默认重启。

因此，客体中唯一安装的驱动是 stock `VioGpuDod`。脚本、名称刷新任务和厂商 API payload
由统一 EXE 管理；用户不需要另外安装 NVIDIA 驱动、控制面板、证书或第三方服务。

## 5. 重启后验证

在 SDL 本地控制台登录 Windows，以 PowerShell 检查真实设备和逻辑投影：

```powershell
Get-PnpDevice -Class Display -PresentOnly | ForEach-Object {
    $_
    Get-PnpDeviceProperty -InstanceId $_.InstanceId `
        -KeyName DEVPKEY_Device_Service,DEVPKEY_Device_DriverInfPath
}

Get-CimInstance Win32_VideoController |
    Format-List Name,AdapterCompatibility,DriverVersion,Status,
        CurrentHorizontalResolution,CurrentVerticalResolution

$display = Get-PnpDevice -Class Display -PresentOnly |
    Where-Object InstanceId -Like 'PCI\VEN_1AF4&DEV_1050*' |
    Select-Object -First 1
$hardwareIds = (Get-PnpDeviceProperty -InstanceId $display.InstanceId `
    -KeyName DEVPKEY_Device_HardwareIds).Data
# Colorful GTX 1050 Ti 示例；其它 AIB 应使用其 identity 中的 SUBSYS/REV。
$expectedLogical = 'PCI\VEN_10DE&DEV_1C82&SUBSYS_00007377&REV_A1'
if (-not $hardwareIds -or $hardwareIds.Count -lt 2 -or
    $hardwareIds[0] -cne $expectedLogical -or
    @($hardwareIds[1..($hardwareIds.Count - 1)] | Where-Object {
        $_ -notlike 'PCI\VEN_1AF4&DEV_1050*'
    }).Count -ne 0) {
    throw 'PnP HardwareID 不是规范逻辑首项 + 完整物理尾项'
}

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
```

GTX 1050 Ti profile 的期望结果：

- PnP 实例仍以 `PCI\VEN_1AF4&DEV_1050` 开头。
- `DEVPKEY_Device_Service` 为 `VioGpuDod`，设备状态为 OK 且 Problem 为 0。
- 注册表 `IdentityMode` 为浅层用户态投影模式。
- 逻辑 VEN/DEV 十进制为 `4318/7298`，即十六进制 `10DE/1C82`。
- 身份 schema 为 `2`；GTX 1050 Ti 的显存/时钟投影为 `GDDR5`、128 bit、
  `1290000/1392000/3504000` kHz，`SpoofSliSupported=0`。
- `SpoofName` 保留所选板卡的完整 AIB canonical 标签用于校验；Enum
  `FriendlyName`/`DeviceDesc`、Class `DriverDesc`、设备管理器、WMI 和 NVAPI/ADL
  adapter 名称统一为按 `10DE:1C82` 映射的 `NVIDIA GeForce GTX 1050 Ti`，
  `Mfg`/`ProviderName` 为 `NVIDIA`。
- PnP HardwareID 首项是当前 AIB 的规范逻辑
  `VEN_10DE&DEV_1C82&SUBSYS_00007377&REV_A1`，其后逐项保留原始完整
  `VEN_1AF4&DEV_1050` 数组；这仍是一个 devnode。NVAPI 主 PCI 关联键为物理
  `1AF4:1050`，external device、AIB SUBSYS/REV 与 DGPU 类型保持逻辑 NVIDIA；
  AMD profile 的对应逻辑身份由 ADL 返回。
- 4 GiB profile 的旧 32 位 `HardwareInformation.MemorySize` 写为
  `2047 MiB`（`0x7FF00000`），确保错误按有符号 Int32 读取它的旧工具仍得到正数；
  NVAPI legacy `MemoryInfo` v1/v2/v3 与 frame-buffer size 接口返回
  `4194304 KiB`，`MemoryInfoEx` v1 返回 `4294967296 bytes`；
  `HardwareInformation.qwMemorySize` 与相应厂商接口精确保留 `4 GiB`。新提交
  使用 transaction schema-5；schema 1/2/3/4 只用于恢复，其中历史 schema-4
  仍按原语义重建 `4095 MiB`。该兼容字段差异不会改变 profile 的逻辑显存容量。
- `SysWOW64\nvapi.dll` 与 `System32\nvapi64.dll` 的摘要必须分别等于统一 EXE
  内嵌版本；它们是本项目用户态 shim，不应带 NVIDIA 厂商签名。

RDP 会接管远程会话分辨率，分辨率下拉可能正常变灰。驱动服务、EDID 和本地输出应在
SDL 控制台验证，不能用 RDP 分辨率界面代替设备检查。

## 6. 直接运行 GPU-Z

最新统一 EXE 成功运行并重启后，普通用户直接双击自己核验来源的
`GPU-Z.2.70.0.exe`。不再使用 PowerShell helper，也不在 GPU-Z 目录旁置文件。

GPU-Z 2.70 的 PE32 主程序会通过标准系统搜索加载 `SysWOW64\nvapi.dll`；其 x64
辅助组件对应 `System32\nvapi64.dll`。这恢复了 Git 历史中的直接运行语义，并补齐
历史浅层方案缺少的 x86 主路径。实际界面仍必须在 Windows 客体做端到端验证；系统
DLL 已正确加载不代表所有 GPU-Z 私有查询接口都已实现。GPU-Z 通过 SetupAPI 逻辑首项
筛选候选，NVAPI 主 PCI 键再以 `1AF4:1050` 把逻辑身份归并到真实载体。若工具绕过
NVAPI/ADL，改读 stock `VioGpuDod` 的 DXGI 描述、HardwareID 物理尾项或原始 PCI
配置，仍会看到 virtio/`1AF4:1050`。

## 7. 3D 能力结论

当前模式对 Windows 客体 3D 加速没有帮助。stock `VioGpuDod` 是 Display-Only 驱动，
逻辑 `10DE:1C82` 和系统 NVAPI shim 只回答身份查询，不会提供：

- 客体 Direct3D 渲染；
- CUDA 计算；
- NVENC/NVDEC 编解码；
- NVIDIA 驱动性能、频率控制或真实显存行为。

即使 QEMU 使用 `virtio-vga-gl`，日志显示 host EGL/virgl 已激活，也不能据此推断 Windows
客体获得 virgl 3D。两者位于不同层次，必须分别判断。

## 8. 常见失败

| 现象 | 判断 | 当前处理 |
| --- | --- | --- |
| 名称像 GTX，但分辨率仍锁在启动帧缓冲 | 可能只有名称覆盖，真实驱动未绑定 | 更新统一 EXE 并重跑，确认 `Service=VioGpuDod` |
| EXE 报物理 PCI 门禁失败 | 当前设备不是 `1AF4:1050` | 停止；恢复标准启动配置后再运行，不切换深层主 ID |
| 设备 Code 43 | 物理 ID、驱动或旧状态不匹配 | 保持 `1AF4:1050`，用统一 EXE 核验 stock 驱动；不装 patched driver |
| payload 目录 Owner 不受信 | 固定目录可能被普通用户预建 | 核对无用户文件后，以管理员删除该目录，再重新运行 EXE |
| GPU-Z 未显示预期逻辑字段 | 系统 DLL 未发布、加载了未知版本或查询接口仍缺失 | 核对 `nvapi-system-install.log`、双 DLL 摘要与 GPU-Z 已加载模块，再做 2.70 E2E |

日志位于 `C:\ProgramData\StealthGPU\`：

- `display-driver-install.log`
- `nvapi-system-install.log`
- `respawn.log`

## 9. 已退役路径

早期版本曾尝试网络下发脚本、自签或补丁显示驱动、非标准根证书、启动链修改以及
深层 PCI 主 ID 切换。这些内容只具有历史诊断价值，不属于当前可执行流程，也不能
作为失败后的回退方案。当前系统目录 NVAPI 是独立用户态 shim，不恢复上述驱动链。

当前规则只有一条：保持物理 `1AF4:1050` 与 stock Microsoft-WHQL `VioGpuDod`，通过
统一离线 EXE 完成注册表浅层投影，并以固定摘要事务发布双架构系统 NVAPI/ADL，使
PnP HardwareID 使用规范逻辑首项 + 完整物理尾项，NVAPI 以物理 carrier 跨接口去重
并保留逻辑 external/AIB/型号。全局仍只有一个显示 devnode，渲染路径、可用显存和
性能不变。

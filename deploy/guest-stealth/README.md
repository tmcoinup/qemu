# guest-stealth：Win10 客机离线统一安装与初始化

`respawn-stealth.exe` 是全新 VM 与克隆 VM 共用的唯一 guest 入口。它把电源策略、
芯片组识别 INF、显示驱动、GPU 初始化脚本及 x86/x64 NVIDIA NVAPI / AMD ADL
系统兼容库全部编译进一个 PE64 文件；
运行时不请求 host HTTP，也不要求 EXE 旁边存在 `.ps1/.sys/.cat/.inf/.dll`。

只想完成正式部署时，请直接阅读
[`QUICKSTART.zh-CN.md`](./QUICKSTART.zh-CN.md)；该教程只要求复制并双击一个 EXE，
不需要在 guest 内另装 PowerShell 模块、RDP、QEMU guest agent 或 NVIDIA 软件。

完整装机/克隆顺序见 [`VM-WORKFLOW.md`](../docs/VM-WORKFLOW.md)。

## 发布物与源码

| 文件 | 作用 |
| --- | --- |
| `dist/respawn-stealth.exe` | 唯一发布物；双击后提权、释放内嵌文件、初始化并重启 |
| `build-exe.sh` | 校验 stock 驱动摘要，用 MinGW 构建 Windows PE64 EXE |
| `configure-power-policy.ps1` | 用 PowrProf 将屏幕/自动睡眠设为“从不”，保留桌面 S3 并关闭休眠 |
| `install-chipset-device.ps1` | 为 A123/A323 幂等绑定 Microsoft WHCP 签名的 Intel NO_DRV 识别 INF |
| `install-display-driver.ps1` | 真实驱动探测与幂等安装；必须先成功，才允许执行名称覆盖 |
| `display-driver-trust.ps1` | 校验活动 VioGpuDod、发布 INF 与内嵌 WHCP 包；仅放行缺失发布 INF 的官方恢复 |
| `install-gpu-api-system.ps1` | 用同一 identity TransactionId 协调 NVAPI 与 ADL |
| `install-nvapi-system.ps1` | 独立事务发布 x86/x64 NVIDIA NVAPI 用户态 shim |
| `install-adl-system.ps1` | 独立事务发布三目标 AMD ADL/ADL2 用户态 shim |
| `persist-gpu-profile.ps1` | 校验完整型号 bundle，并组织 schema-2 身份的 Stage/Commit/Complete/Recover |
| `gpu-profile-transaction.ps1` | 持久化 GPU 身份 journal、指针 CAS、投影回读与崩溃恢复公共实现 |
| `gpu-profile-registry-core.ps1` | GPU 身份事务共用的精确注册表读取、回读与 pointer CAS 基元 |
| `refresh-gpu-name.ps1` | 在全局写锁内严格投影唯一 VioGpuDod 实例的 Enum/Class 属性 |
| `gpu-manufacturer-projection.ps1` | 通过 Config Manager 投影常规页制造商，并在前后复核 WHCP 签名绑定 |
| `gpu-hardware-id-plan.ps1` | 无副作用地规划“逻辑首项 + 完整物理数组”，供生产脚本与测试共用 |
| `project-gpu-hardware-id.ps1` | 唯一的 GPU Enum `HardwareID` writer；幂等投影、验证与回滚 |
| `respawn-stealth-local.ps1` | 串联驱动安装、`apply-gpu-spoof -AutoDetect`、收尾与重启 |
| `respawn-restart-state.ps1` | 集中管理一次性恢复任务、显示设备就绪等待与单次重启阶段 |
| `launcher/` | UAC manifest、payload 释放器和应用图标 |
| `package.sh` | 清理旧发布目录并重新生成单 EXE |

驱动输入来自 `deploy/scripts/stock-viogpudo/`：

- `viogpudo.sys`
- `viogpudo.cat`
- `viogpudo.inf`

构建器与 Windows 安装器会同时锁定三份 SHA-256。SYS/CAT/INF 不是可任意混用的
独立文件；任何一个摘要不匹配都会在安装前失败。

芯片组识别输入来自 `deploy/scripts/stock-intel-chipset-inf/`。H310/A323 使用
`CannonLake-HSystem.inf` + `cannonlake-h.cat`，H110/A123 使用
`SunrisePoint-HSystem.inf` + `sunrisepoint-h.cat`。它们都由 Microsoft WHCP
签名并引用 inbox `machine.inf` 的 `NO_DRV` section：作用是清除 Code 28 和正确命名，
不包含 SMBus `.sys` 或服务。上游 Catalog 链接、版本和摘要见该目录的 `SOURCES.md`。

NVIDIA 用户态身份库来自 `deploy/nvapi-shim/`：PE32 `nvapi.dll` 给 32 位程序，PE32+
`nvapi64.dll` 给 64 位程序。两者共用版本化注册表身份并锁定 SHA-256、Machine、
DLL 标志和唯一导出；缺任一架构都视为发布失败。GPU-Z 2.70 主程序是 PE32，所以
统一 EXE 把 x86 文件发布为 `SysWOW64\nvapi.dll`，并把 x64 文件发布为
`System32\nvapi64.dll`。installer 只替换当前或历史 VMate 固定摘要，遇到真实 NVIDIA
或其它未知同名 DLL 会在写入前停止。

两份 DLL 都把唯一 NVAPI 句柄关联到 OS 中实际存在的 `1AF4:1050` 显示承载设备；
subsystem、revision 和 BDF 与真实 PCI 配置保持一致，而名称、显存及型号细节继续
读取 NVIDIA profile。这样 SetupAPI/PCI 与 NVAPI 的双通道扫描结果会合并为一块
NVIDIA 显卡，不会额外出现一块 `Red Hat VirtIO` 卡。

每次 DLL 首次初始化还会以 SetupAPI/Configuration Manager 对 `SourceInstanceId`
进行实例级复核：必须只有一个 online `1AF4:1050` Display devnode，snapshot BDF
必须与该 devnode 的 Bus/Address 一致，Service 必须仍为 `VioGpuDod`。HardwareID
投影的逻辑首项允许存在，但完整物理条目必须保留；任一项不符时 NVAPI/ADL 均拒绝
发布，绝不猜测另一个载体。

AMD 用户态身份库来自 `deploy/adl-shim/`。PE32 实现发布到
`SysWOW64\atiadlxy.dll` 和 `SysWOW64\atiadlxx.dll`，PE32+ 实现发布到
`System32\atiadlxx.dll`。它实现通用 ADL/ADL2 枚举、显存、VBIOS、核心信息与
静态时钟查询，不判断调用进程；AMD profile 下返回一张与同一 `1AF4:1050` 载体
关联的 adapter，NVIDIA profile 下返回零张。实时温度、功耗、风扇等没有可信数据源
的接口返回官方“不支持”，不会伪造遥测。完整合同见
[`GPU-VENDOR-API.md`](../docs/GPU-VENDOR-API.md)。

ADL 的 `AdapterInfo` 中 UDID、PNP 字符串和 Driver path 也传递上一步已经验证的
真实 Windows 载体信息，而不是额外合成一条 `VEN_1002` PNP 实例；因此系统级扫描器
不会把 AMD 逻辑规格与同一 virtio 显示设备拆成两张卡。

## 一次运行的真实顺序

1. EXE 从 Windows Known Folder 定位 ProgramData，拒绝重解析点或非可信 Owner；
   所有 payload 先写入受保护 staging 并逐字节复核，再整目录发布到
   `C:\ProgramData\StealthGPU\respawn-exe\`。
2. 在任何 GPU/PnP 写入前，通过 Windows PowrProf API 把当前活动方案中的“屏幕”和
   “睡眠”都设为“从不”：关闭普通及锁屏显示超时、空闲及无人值守自动睡眠和混合
   睡眠，同时设置 `ALLOWSTANDBY=1`，保留正常台式机的 S1–S3 能力与“睡眠”区块；
   再执行 inbox `powercfg /hibernate off`，回读六项 AC/DC 值、活动方案及
   `HiberFilePresent`。失败就停止，不会继续改显卡。
3. 枚举 `PresentOnly` 的 `8086:A123`/`8086:A323`；已正常绑定时跳过，否则验证
   对应 INF/CAT 的固定摘要、NO_DRV 语义与 Microsoft WHCP 签名，再用 inbox
   `pnputil /add-driver ... /install` 清除 SMBus Code 28。若要求重启，先记录
   `ChipsetVerification` 阶段并继续完成 GPU 流程；最终一次重启后只复核该 INF，
   不会再次运行 GPU 流程或安排第二次重启。
4. 若存在上次正式身份，先停止旧投影任务并把 `HardwareID` 恢复为 physical-only；
   后续驱动安装和 PnP scan 因而始终只看到 stock `1AF4:1050`。
5. 只枚举 `PresentOnly` 的 PCI 显示设备，先要求物理主 ID 全部为 `1AF4:1050`，
   再读取不受 FriendlyName 伪装影响的
   `DEVPKEY_Device_Service`。
6. 通过物理门禁且已经绑定 `VioGpuDod` 时跳过 `pnputil`。这是克隆机无扰动快速路径。
7. 若是全新系统的 `PCI\VEN_1AF4&DEV_1050`，校验内嵌文件摘要与 Microsoft
   Windows Hardware Compatibility Publisher 签名，然后执行
   `pnputil /add-driver viogpudo.inf /install`。
8. 再次读取 `Service`。没有真实变成 `VioGpuDod` 就停止，不执行 GPU 名称覆盖。
9. 仅对本次新装驱动的系统清理旧 `GraphicsDrivers` 模式缓存；克隆机不清理。
10. 执行 `apply-gpu-spoof.ps1 -AutoDetect -NvapiPayloadDir <受保护目录>`：按当前
   PCI SUBSYS 对齐名称和版本化身份，并在 identity 尚未 `Complete` 时完整预检、
   staging NVAPI 与 ADL，再事务发布到 SysWOW64/System32。installer 失败会由同一
   durable `finally` 回滚 identity；流程不写 GPU-Z 原目录、不修改 PATH，也不安装
   NVIDIA 驱动、控制面板或服务。
11. 厂商 API 成功后，先注册 `StealthGPU-ProjectHardwareId` 内置计划任务（SYSTEM、
    启动及登录触发），且复核其动作、权限、触发器和 `IgnoreNew` 设置。
12. 同一份持久 `project-gpu-hardware-id.ps1` 随后同步把 HardwareID 精确写成
   `profile 逻辑首项 + 完整物理数组`。例如首项为 `10DE:1C82`，第二项起仍是
   `1AF4:1050`；设备实例路径、Service、Driver、CompatibleIDs 和 PCI 配置空间不变。
13. `gpu-manufacturer-projection.ps1` 仅把设备管理器常规页制造商投影成
    AMD/NVIDIA；投影前后都要求活动 `oemN.inf` 仍为 Red Hat、`IsSigned=True` 且
    signer 为 Microsoft Windows Hardware Compatibility Publisher。
14. 然后默认重启；不按进程区分的 NVAPI/ADL 查询会从系统目录读取同一身份。工具若调用
    没有可信数据源的实时遥测或厂商驱动功能，会收到明确的“不支持”结果，而不是伪造数值。

因此，“设备管理器显示 GTX 1050 Ti”不再被当成成功条件。旧 EXE 能把
Microsoft Basic Display Adapter 改名成 GTX，但底层仍是 BasicDisplay，UEFI 下的
分辨率会锁在启动帧缓冲（例如 1280×800）。新流程必须确认真实 Service。

NVAPI、ADL 和逻辑 PCI 投影只统一用户态工具的身份查询，不增加渲染能力。
stock `VioGpuDod` 是 Display-Only 驱动；Windows 客体不会因为显示 `10DE:1C82`
就获得 GTX 1050 Ti 的 Direct3D、CUDA、NVENC 或真实 NVIDIA 驱动性能。

## 固定 1920×1080 原生模式

本项目的 Linux 与 Windows VM 启动器都会默认给 `virtio-vga`/`virtio-vga-gl`
显式追加 `edid-fixed-native=on`。该参数把 EDID 的首选时序固定为 profile 配置的
`xres=1920,yres=1080`，避免 SDL 初始窗口或后续缩放把动态 `req_state` 回写成
1280×800。它只稳定显示器上报的原生模式，不能代替 guest 内真实绑定
`VioGpuDod`；驱动安装与固定 EDID 两层都成功后，Windows 才能可靠枚举 1080p。

QEMU 设备属性本身仍默认关闭，以保持普通 QEMU 调用方的动态缩放兼容性；本项目
通过启动器默认显式开启，因此正常使用 `start-vm.sh`/`start-vm.ps1` 无需额外传参。

## 全新 VM 用法

在 host 重新构建：

```bash
bash deploy/guest-stealth/package.sh
sha256sum deploy/guest-stealth/dist/respawn-stealth.exe
```

只把 `deploy/guest-stealth/dist/respawn-stealth.exe` 拷进 Windows 任意位置。推荐固定为
`D:\工具\respawn-stealth.exe`，然后双击运行并等待自动重启。无需启动
`serve-stealth-http.py`，也不要再执行旧的 `irm .../shallow-stealth.ps1 | iex` 作为默认安装。

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
第三方守护程序；新增持久项只有项目脚本、两份 NVAPI DLL、三项目标 ADL DLL，以及 Windows 自带 Task
Scheduler 中的名称刷新和 HardwareID 投影两条任务。电源方案只由 Windows 内置 API
原地更新，不新增服务。VM2 现场验收使用过的 USB/HTTP 调试路径不会进入 EXE。

直接运行依赖两个固定系统搜索位置：

```text
C:\Windows\SysWOW64\nvapi.dll      # GPU-Z 2.70 PE32 主程序
C:\Windows\System32\nvapi64.dll   # 内嵌 x64 辅助组件
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
  实例建立自己的事务。FirstLogon 保留名称刷新与 HardwareID 投影，仅跳过交互显示任务。

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
    $_.InstanceId -match '^PCI\\VEN_8086&DEV_(A123|A323)&'
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
if ($hardwareIds[0] -notlike 'PCI\VEN_10DE&DEV_1C82*' -or
    $hardwareIds[1] -notlike 'PCI\VEN_1AF4&DEV_1050*') {
    throw 'HardwareID 不是 profile-first / physical-second'
}
Get-CimInstance Win32_VideoController |
    Format-List Name,DriverVersion,CurrentHorizontalResolution,CurrentVerticalResolution
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
必须分别一致。若通过 RDP 查看，分辨率下拉由 RDP 客户端控制，本来就会变灰；驱动与
本地输出必须在 SDL 控制台验证。

SMBus 期望 `Status=OK`、`Class=System`、ProblemCode `0`、INF 为 `oem*.inf`，
且 `DEVPKEY_Device_Service` 为空；服务为空正是 Intel NO_DRV 包的正确结果。

GTX 1050 Ti 的快照还应为 schema `2`、`GDDR5`、128 bit、base
`1290000` kHz、boost `1392000` kHz、NVAPI memory `3504000` kHz 和
`SpoofSliSupported=0`。GPU-Z 将该 memory clock 显示为 1752 MHz；这是查询
投影，不是真实频率管理或显存分配。

日志：

- `C:\ProgramData\StealthGPU\power-policy.log`
- `C:\ProgramData\StealthGPU\chipset-device-install.log`
- `C:\ProgramData\StealthGPU\display-driver-install.log`
- `C:\ProgramData\StealthGPU\gpu-hardware-id-projection.log`
- `C:\ProgramData\StealthGPU\respawn.log`

NVAPI installer 的逐行输出并入 `respawn.log`，因此 identity 回滚原因和双 DLL
事务结果位于同一条正式部署日志中。

仅回滚 HardwareID 浅层投影时，以管理员身份执行持久目录中的：

```powershell
& 'C:\ProgramData\StealthGPU\project-gpu-hardware-id.ps1' -Mode Rollback
Unregister-ScheduledTask -TaskName 'StealthGPU-ProjectHardwareId' -Confirm:$false
```

若首次运行报“payload 目录 Owner 不受信”，说明固定目录曾被普通用户预建；为避免
管理员执行竞态，程序会故意停止。确认目录内没有用户文件后，以管理员身份删除
`C:\ProgramData\StealthGPU\respawn-exe`（必要时连同空的 `StealthGPU` 根目录删除），
再重新运行 EXE；不要用 `takeown` 后原地放行。

## 源码调试入口

PowerShell 脚本文件只供源码调试，默认发布目录不包含它们。如确实需要：

```bash
INCLUDE_LEGACY_SCRIPTS=1 bash deploy/guest-stealth/package.sh
```

脚本调试必须把芯片组/显示驱动 installer、两套 Intel INF/CAT、
`install-nvapi-system.ps1`、stock 显示驱动三件套、
`nvapi.dll`、`nvapi64.dll`、
`configure-power-policy.ps1`、
`apply-gpu-spoof.ps1`、`persist-gpu-profile.ps1`、`gpu-profile-transaction.ps1`、
`gpu-profile-registry-core.ps1`、
`refresh-gpu-name.ps1`、`gpu-manufacturer-projection.ps1`、
`gpu-manufacturer-projector.exe`、`respawn-restart-state.ps1`、
`display-driver-trust.ps1`、
`gpu-hardware-id-plan.ps1`、`project-gpu-hardware-id.ps1` 和
`force-displayfreq.ps1` 放在同一 payload 目录；生产环境始终使用单 EXE。

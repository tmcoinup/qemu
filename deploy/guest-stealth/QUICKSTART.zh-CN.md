# guest-stealth 傻瓜式使用教程（Windows 10 guest）

本教程用于正式 guest。发布目录会生成两个可独立运行的文件：
`respawn-stealth.exe` 显示完整细节，`respawn-stealth-progress.exe` 只显示通用
进度。普通使用推荐复制后者；芯片组识别 INF、显示驱动、初始化脚本和 x86/x64
身份查询库都已内嵌，不需要安装 RDP、QEMU guest agent、PowerShell 模块、
NVIDIA 驱动或其它第三方软件。

## 先看清楚它能做什么

这套方案是“浅层身份投影”，不是显卡直通：

- QEMU 设备的真实主 PCI ID 仍是 `1AF4:1050`，设备实例仍绑定 stock
  `VioGpuDod` Display-Only 驱动。
- 系统中只有一个显示 devnode。PnP `HardwareIds` 的 MULTI_SZ 首项是当前 AIB 的
  规范逻辑 VEN/DEV/SUBSYS/REV，其后逐项保留原始完整 `1AF4:1050` 数组；多条匹配
  字符串不是多张显卡。
- NVAPI 主 PCI 关联键使用物理 `1AF4:1050` carrier 跨接口去重；external device、
  AIB SUBSYS/REV、标准型号和独显类型保持逻辑 NVIDIA 身份。
- 当前目录在 GT 1030、GTX 750 Ti、GTX 1050、GTX 1050 Ti、RX 550、RX 560
  六个芯片型号下各提供 3 个品牌板卡，共 18 块 AIB（12 NVIDIA、6 AMD）。
  GPU-Z 等用户态程序看到所选 profile 的逻辑型号；后文 GTX 1050 Ti 只是示例。
- `1AF4:A101`–`1AF4:A112` 只是内部 carrier，不是物理 AIB subsystem；项目也不
  虚构或展示没有标准可核验来源的 GPU 序列号。
- 它不会给 Windows guest 增加 Direct3D、CUDA、NVENC、AMF 或厂商 3D 性能。
  host 侧 virgl/GL 加速也不会因此变成 guest 内的 NVIDIA/AMD 3D 加速。
- **不要安装 NVIDIA 或 AMD 官方显示驱动。** 逻辑 `10DE`/`1002` 身份只是查询结果，
  真实设备不能由对应厂商驱动接管；强行安装只会破坏现有显示链路。

如果你需要真正的 guest 3D/CUDA，应另外设计 GPU/VFIO 直通方案，不能使用本教程
代替。

## 一键安装

1. 在 Linux host 确认 VM 使用本项目兼容的 `1AF4:1050` + `VioGpuDod` 配置启动。
2. 从下面两个文件中任选一个复制到 Windows 10 guest 的任意本地目录：

   ```text
   deploy/guest-stealth/dist/respawn-stealth-progress.exe  （普通使用，仅显示进度）
   deploy/guest-stealth/dist/respawn-stealth.exe           （诊断使用，显示完整细节）
   ```

   两个 EXE 都完整内嵌依赖，不需要放在一起；不要同时运行它们。
3. 双击所选 EXE，在 Windows UAC 对话框中选择“是”。仅进度版不会显示控制台细节。
4. 保持进度或控制台窗口开启。程序会先把当前 Windows 台式机电源页面的“屏幕”和“睡眠”都设为
   “从不”，同时关闭休眠，再自动修复硬件池 A323/A123/1C22/1E22/8C22 SMBus
   的 Code 28，并验证 2930 的 inbox `machine.inf`，然后完成显示驱动检查、身份
   事务和系统级 x86/x64 查询库发布；不要中途关机或结束进程。
5. 程序成功后会自动重启 Windows。重新登录后即可直接打开已有的 GPU-Z 或其它硬件
   查询软件；不需要 helper、旁置 DLL、环境变量或常驻调试服务。

重复运行同一个最新版 EXE 是安全的：已绑定 `VioGpuDod` 时会走幂等快速路径，不会
无意义地重复安装显示驱动；SMBus 已正常进入 System 类时也会跳过 `pnputil`。

一次只运行一个最新版统一 EXE，并等待它完全退出。不要同时运行另一个 EXE，也不要
把 `C:\ProgramData\StealthGPU` 中释放出的 helper 与旧版平铺调试脚本并发执行；统一
EXE 内部会串行化整包事务，手工绕过入口则不属于受支持的并发方式。

电源设置同时覆盖 AC/DC、普通显示超时、锁屏显示超时、空闲/无人值守睡眠、混合
睡眠、Windows 休眠和快速启动。`ALLOWSTANDBY=1` 会保留正常台式机的 S1–S3 能力，
所以设置页仍显示“睡眠”区块；自动超时保持为 0，因此“屏幕”和“睡眠”均显示
“从不”。VM 是台式机且没有电池设备，页面只显示“接通电源”是正常结果。它通过
Windows 内置 PowrProf 与 `powercfg.exe` 修改当前活动方案，不安装电源服务或常驻
程序。如果以后手工切换到另一套电源方案，应重新运行一次统一 EXE，让新活动方案也
收敛到同一设置。

## 成功后应该看到什么

以项目内 GTX 1050 Ti profile 为例，GPU-Z 2.70 应显示以下逻辑查询值：

| 字段 | 期望值 |
| --- | --- |
| Name | NVIDIA GeForce GTX 1050 Ti |
| GPU / Device ID | GP107 / 逻辑 `10DE:1C82` + 所选 AIB SUBSYS |
| Shaders / ROPs / TMUs | 768 / 32 / 48 |
| Memory | 4096 MB GDDR5，128 bit |
| GPU Clock | 1290 MHz（Boost 1392 MHz） |
| Memory Clock / Bandwidth | 1752 MHz / 112.1 GB/s |

显示器型号仍以 host profile 注入的 EDID 为唯一事实源。统一 EXE 只通过
`DEVPKEY_Device_FriendlyName` 投影设备管理器标签，不改 EDID、HardwareID、INF
或 inbox `monitor.sys`；四款映射为 `SAM0D20 → Samsung S24F350`、
`AOC2402 → AOC 24B2XH`、`XMI23C3 → Xiaomi Mi Monitor (RMMNT238NF)`、
`LEN66BC → Lenovo L24e-30`。

这些数值来自当前 profile 的一致性投影，不代表 guest 拥有同等显存、频率或运算能力。
物理 PCI 配置空间、设备实例路径、`Service` 和实际显示驱动不会被伪装成 NVIDIA
设备。stock `VioGpuDod` 暴露的 DXGI adapter 描述和直接读取 PCI/PNP 的工具仍可能
看到 virtio/`1AF4:1050`；这是当前非直通架构的预期边界。
4 GiB 在 NVAPI legacy MemoryInfo 中是 `4194304 KiB`，在 MemoryInfoEx 中是
`4294967296 bytes`；两者只是不同 ABI 单位，不是两个显存容量。

不用安装 GPU-Z 也能做底层快速检查。以管理员身份打开 Windows PowerShell，执行：

```powershell
$display = Get-PnpDevice -Class Display -PresentOnly |
    Where-Object InstanceId -Like 'PCI\VEN_1AF4&DEV_1050*' |
    Select-Object -First 1
$display | Format-List FriendlyName,Status,InstanceId
Get-PnpDeviceProperty -InstanceId $display.InstanceId `
    -KeyName DEVPKEY_Device_Service,DEVPKEY_Device_DriverInfPath,
        DEVPKEY_Device_HardwareIds,DEVPKEY_Device_Manufacturer
$smbus = Get-PnpDevice -PresentOnly | Where-Object {
    $_.InstanceId -match '^PCI\\VEN_8086&DEV_(A323|A123|1C22|1E22|8C22|2930)&'
}
$smbus | Format-List FriendlyName,Status,Class,Problem,InstanceId
Get-PnpDeviceProperty -InstanceId $smbus.InstanceId `
    -KeyName DEVPKEY_Device_ProblemCode,DEVPKEY_Device_DriverInfPath,
        DEVPKEY_Device_Service
$monitor = Get-PnpDevice -Class Monitor -PresentOnly | Where-Object {
    $_.InstanceId -match '^DISPLAY\\(SAM0D20|AOC2402|XMI23C3|LEN66BC)\\'
}
$monitor | Format-List FriendlyName,Status,InstanceId
Get-PnpDeviceProperty -InstanceId $monitor.InstanceId `
    -KeyName DEVPKEY_Device_FriendlyName,DEVPKEY_Device_HardwareIds,
        DEVPKEY_Device_DriverInfPath,DEVPKEY_Device_Service
```

应同时满足：

- `Status` 为 `OK`，`Service` 为 `VioGpuDod`；
- AMD profile 的 Manufacturer 为 `Advanced Micro Devices, Inc.`，NVIDIA
  profile 仍为 `NVIDIA`；
- `InstanceId` 仍以物理 `PCI\VEN_1AF4&DEV_1050` 开头；
- `HardwareIds` 首项是当前 AIB 的规范逻辑 ID，其后每一项都以物理
  `PCI\VEN_1AF4&DEV_1050` 开头；真实 BDF、Service 和 Driver 不变；
- SMBus 为 `Status=OK`、`Class=System`、ProblemCode `0` 且 Service 为空；
  A323/A123/1C22/1E22/8C22 的 INF 为 `oem*.inf`，2930 为 inbox `machine.inf`；
- Monitor 的 FriendlyName 与上面的四款映射一致，HardwareID 仍为对应
  `MONITOR\XXXNNNN`，INF 和 `monitor.sys` 保持 Windows inbox 值。

## 复制前后校验 EXE

每次重新构建都会产生新的 SHA-256，不要照抄旧版本摘要。在 Linux host 记录当前
发布物摘要：

```bash
sha256sum deploy/guest-stealth/dist/respawn-stealth*.exe
```

复制进 guest 后，用 Windows 自带 PowerShell 重新计算：

```powershell
Get-FileHash 'D:\工具\respawn-stealth-progress.exe' -Algorithm SHA256
```

两边摘要必须完全相同。不同就重新复制，不要运行损坏或来源不明的 EXE。

## 失败时怎么处理

先查看正式部署日志：

```text
C:\ProgramData\StealthGPU\power-policy.log
C:\ProgramData\StealthGPU\chipset-device-install.log
C:\ProgramData\StealthGPU\display-driver-install.log
C:\ProgramData\StealthGPU\gpu-hardware-id-projection.log
C:\ProgramData\StealthGPU\monitor-identity-projection.log
C:\ProgramData\StealthGPU\respawn.log
```

`gpu-hardware-id-projection.log` 记录 physical-only 恢复、最终逻辑首项投影及验证；
事务在写设备前先持久化并回读 `RollbackHardwareIds`，因此 journal 收尾中断也能在
下次运行恢复。当前版本会维护 GPU HardwareID 与 Monitor FriendlyName 启动/登录任务。

常见处理方式：

- 窗口再次黑屏并显示 `[Stopped]`：这是 guest 进入 ACPI S3，不是 QEMU 退出。查看
  `power-policy.log`；若运行 EXE 后又手工切换过电源方案，重新运行最新版 EXE。
- GPU-Z 为空或仍显示旧值：先完整重启；仍异常时关闭所有 GPU-Z 窗口，再重复运行
  最新 `respawn-stealth.exe`。程序会恢复未完成的身份事务后重新部署。
- 日志提示物理 PCI ID 不是 `1AF4:1050`：当前 VM 启动配置不兼容，应修正 host 配置，
  不要在 guest 中强行绕过门禁。
- 日志提示设备没有绑定 `VioGpuDod`：让统一 EXE 完成内嵌 stock 驱动安装；不要手工
  改名，也不要安装 NVIDIA 驱动。
- 设备管理器仍显示“SM 总线控制器”Code 28：查看
  `chipset-device-install.log`；不要安装来源不明的 SMBus `.sys`，本项目使用的是
  六套 Microsoft WHCP 签名的 Intel NO_DRV 识别 INF（含 X79/Patsburg）；2930 使用 inbox
  `machine.inf`。
- 显示器仍显示“通用即插即用监视器”：查看 `monitor-identity-projection.log`；
  不要安装或改写厂商 Monitor INF，标签必须由当前 EDID PnP ID 唯一选择。
- `respawn.log` 返回 `30` 且提示 `ChipsetVerification`：本轮自动重启额度已经使用，
  请人工重启一次。登录任务只复核芯片组 INF，不会重跑 GPU 流程或自动二次重启。
- 日志提示未知 `nvapi.dll`/`nvapi64.dll`：系统可能已有真实 NVIDIA 或第三方同名库。
  installer 会故意拒绝覆盖。先确认该 guest 的用途和原驱动来源，不要强制删除。
- 日志提示 payload 目录 Owner 不受信：确认
  `C:\ProgramData\StealthGPU\respawn-exe` 内没有用户文件后，以管理员身份删除该目录，
  再运行 EXE；不要用 `takeown` 原地放行。

需要观察完整输出但暂不自动重启时，可在管理员 PowerShell 中执行：

```powershell
Start-Process -FilePath 'D:\工具\respawn-stealth.exe' `
    -ArgumentList '-NoReboot' -Wait
```

检查完毕后仍应手动重启一次。

## 从旧 HardwareID 布局升级

直接运行最新 `respawn-stealth.exe`。它会停止旧 writer，先恢复并门禁原始
physical-only 数组；身份与厂商 API 事务成功后，再按当前 AIB Apply/Verify 规范逻辑
首项 + 完整物理尾项，并重新注册 GPU HardwareID 与 Monitor 标签维护任务。
不要手工并发运行旧 projector。

需要恢复整个 guest 时，优先使用部署前的 VM 快照。不要直接删除身份注册表 journal，
否则会破坏下次运行时的自动恢复依据。

## 正式包不会安装的调试组件

VM2 验收期间可以临时使用 RDP、USB/FAT 载荷、HTTP、探针或其它调试入口，但它们不
属于正式发布物，也不会被 `respawn-stealth.exe` 安装。普通双击正式 EXE 后，guest
新增的持久内容是项目脚本、内嵌 Intel 识别 INF、stock 显示驱动包、必要的 x86/x64
用户态身份库，以及
`RefreshName`、`ProjectHardwareId` 和 `ProjectMonitorIdentity` 启动/登录维护任务；普通交互运行
还可维护 `ForceDisplayFreq`。仅当设备尚未绑定兼容驱动时，程序才会
安装 Windows 显示所必需的 `VioGpuDod` 内核驱动。封装镜像的 `--firstlogon` 路径保留
上述三项维护任务并抑制交互显示模式任务。两种路径都不新增 RDP、QGA、HTTP、网络或调试
服务；默认 host 发布目录只保留详细模式与仅进度模式这两个 EXE。

完整实现、验证命令和源码调试方式见 [`README.md`](./README.md)。

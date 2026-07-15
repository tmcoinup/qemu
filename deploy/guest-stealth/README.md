# guest-stealth：Win10 客机离线统一安装与初始化

`respawn-stealth.exe` 是全新 VM 与克隆 VM 共用的唯一 guest 入口。它把电源策略、
显示驱动、GPU 初始化脚本及 x86/x64 NVAPI 浅层兼容库全部编译进一个 PE64 文件；
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
| `configure-power-policy.ps1` | 用 PowrProf 精确禁止息屏、S1–S3、混合睡眠与休眠 |
| `install-display-driver.ps1` | 真实驱动探测与幂等安装；必须先成功，才允许执行名称覆盖 |
| `install-nvapi-system.ps1` | 事务发布 x86/x64 用户态 shim，使 GPU-Z 2.70 可直接双击 |
| `persist-gpu-profile.ps1` | 校验完整型号 bundle，并组织 schema-2 身份的 Stage/Commit/Complete/Recover |
| `gpu-profile-transaction.ps1` | 持久化 GPU 身份 journal、指针 CAS、投影回读与崩溃恢复公共实现 |
| `refresh-gpu-name.ps1` | 在全局写锁内严格投影唯一 VioGpuDod 实例的 Enum/Class 属性 |
| `gpu-hardware-id-plan.ps1` | 无副作用地规划“逻辑首项 + 完整物理数组”，供生产脚本与测试共用 |
| `project-gpu-hardware-id.ps1` | 唯一的 GPU Enum `HardwareID` writer；幂等投影、验证与回滚 |
| `respawn-stealth-local.ps1` | 串联驱动安装、`apply-gpu-spoof -AutoDetect`、收尾与重启 |
| `launcher/` | UAC manifest、payload 释放器和应用图标 |
| `package.sh` | 清理旧发布目录并重新生成单 EXE |

驱动输入来自 `deploy/scripts/stock-viogpudo/`：

- `viogpudo.sys`
- `viogpudo.cat`
- `viogpudo.inf`

构建器与 Windows 安装器会同时锁定三份 SHA-256。SYS/CAT/INF 不是可任意混用的
独立文件；任何一个摘要不匹配都会在安装前失败。

用户态身份库来自 `deploy/nvapi-shim/`：PE32 `nvapi.dll` 给 32 位程序，PE32+
`nvapi64.dll` 给 64 位程序。两者共用版本化注册表身份并锁定 SHA-256、Machine、
DLL 标志和唯一导出；缺任一架构都视为发布失败。GPU-Z 2.70 主程序是 PE32，所以
统一 EXE 把 x86 文件发布为 `SysWOW64\nvapi.dll`，并把 x64 文件发布为
`System32\nvapi64.dll`。installer 只替换当前或历史 VMate 固定摘要，遇到真实 NVIDIA
或其它未知同名 DLL 会在写入前停止。

## 一次运行的真实顺序

1. EXE 从 Windows Known Folder 定位 ProgramData，拒绝重解析点或非可信 Owner；
   所有 payload 先写入受保护 staging 并逐字节复核，再整目录发布到
   `C:\ProgramData\StealthGPU\respawn-exe\`。
2. 在任何 GPU/PnP 写入前，通过 Windows PowrProf API 把当前活动方案配置为不息屏、
   不睡眠：关闭普通及锁屏显示超时、空闲及无人值守睡眠、主动 S1–S3 和混合睡眠；
   再执行 inbox `powercfg /hibernate off`，回读六项 AC/DC 值、活动方案及
   `HiberFilePresent`。失败就停止，不会继续改显卡。
3. 若存在上次正式身份，先停止旧投影任务并把 `HardwareID` 恢复为 physical-only；
   后续驱动安装和 PnP scan 因而始终只看到 stock `1AF4:1050`。
4. 只枚举 `PresentOnly` 的 PCI 显示设备，先要求物理主 ID 全部为 `1AF4:1050`，
   再读取不受 FriendlyName 伪装影响的
   `DEVPKEY_Device_Service`。
5. 通过物理门禁且已经绑定 `VioGpuDod` 时跳过 `pnputil`。这是克隆机无扰动快速路径。
6. 若是全新系统的 `PCI\VEN_1AF4&DEV_1050`，校验内嵌文件摘要与 Microsoft
   Windows Hardware Compatibility Publisher 签名，然后执行
   `pnputil /add-driver viogpudo.inf /install`。
7. 再次读取 `Service`。没有真实变成 `VioGpuDod` 就停止，不执行 GPU 名称覆盖。
8. 仅对本次新装驱动的系统清理旧 `GraphicsDrivers` 模式缓存；克隆机不清理。
9. 执行 `apply-gpu-spoof.ps1 -AutoDetect -NvapiPayloadDir <受保护目录>`：按当前
   PCI SUBSYS 对齐名称和版本化身份，并在 identity 尚未 `Complete` 时完整预检、
   staging 双架构 NVAPI，再事务发布到 SysWOW64/System32。installer 失败会由同一
   durable `finally` 回滚 identity；流程不写 GPU-Z 原目录、不修改 PATH，也不安装
   NVIDIA 驱动、控制面板或服务。
10. NVAPI 成功后，先注册 `StealthGPU-ProjectHardwareId` 内置计划任务（SYSTEM、
    启动及登录触发），且复核其动作、权限、触发器和 `IgnoreNew` 设置。
11. 同一份持久 `project-gpu-hardware-id.ps1` 随后同步把 HardwareID 精确写成
   `profile 逻辑首项 + 完整物理数组`。例如首项为 `10DE:1C82`，第二项起仍是
   `1AF4:1050`；设备实例路径、Service、Driver、CompatibleIDs 和 PCI 配置空间不变。
12. 然后默认重启；GPU-Z 2.70 可从任意目录直接双击。

因此，“设备管理器显示 GTX 1050 Ti”不再被当成成功条件。旧 EXE 能把
Microsoft Basic Display Adapter 改名成 GTX，但底层仍是 BasicDisplay，UEFI 下的
分辨率会锁在启动帧缓冲（例如 1280×800）。新流程必须确认真实 Service。

NVAPI 和逻辑 PCI 投影只修复 GPU-Z 等用户态工具的身份查询，不增加渲染能力。
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

本次 `--firstlogon` 投影链不新增 RDP、调试 HTTP、QEMU guest agent、NVIDIA 服务或
第三方守护程序；新增持久项只有项目脚本、两份 NVAPI DLL 和 Windows 自带 Task
Scheduler 中的一条投影任务。电源方案只由 Windows 内置 API 原地更新，不新增服务或
常驻任务。VM2 现场验收使用过的 USB/HTTP 调试路径不会进入 EXE。

直接运行依赖两个固定系统搜索位置：

```text
C:\Windows\SysWOW64\nvapi.dll      # GPU-Z 2.70 PE32 主程序
C:\Windows\System32\nvapi64.dll   # 内嵌 x64 辅助组件
```

这两个 DLL 是无厂商签名的用户态身份投影，不是显示驱动。它们会成为系统级完整性检查
可见面，并会与未来真实 NVIDIA 驱动的同名文件冲突；installer 因而拒绝覆盖任何未知
摘要。若以后改装真实 NVIDIA/VFIO 栈，应先移除本项目 DLL，而不能强制覆盖厂商文件。

## 克隆机兼容性

- 物理 ID 为 `1AF4:1050` 且已绑定 `VioGpuDod`：不运行 `pnputil`，不清模式缓存，
  只按新 profile 重对齐名称。
- 物理 PCI ID 不是 `1AF4:1050`：明确拒绝继续，避免把浅层用户态投影误用于不兼容
  的驱动绑定；本流程不会恢复自签驱动路径。
- 可重复执行：payload 每次覆盖为当前 EXE 版本；驱动安装与缓存清理只在需要时发生。
- clone 的每个 `SourceInstanceId` 使用独立 SHA-256 命名备份；旧实例不会阻止新 SUBSYS
  实例建立自己的事务。FirstLogon 仍只保留必要的 HardwareID 投影任务。

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

GTX 1050 Ti 的快照还应为 schema `2`、`GDDR5`、128 bit、base
`1290000` kHz、boost `1392000` kHz、NVAPI memory `3504000` kHz 和
`SpoofSliSupported=0`。GPU-Z 将该 memory clock 显示为 1752 MHz；这是查询
投影，不是真实频率管理或显存分配。

日志：

- `C:\ProgramData\StealthGPU\power-policy.log`
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

脚本调试必须把显示驱动 installer、`install-nvapi-system.ps1`、stock 驱动三件套、
`nvapi.dll`、`nvapi64.dll`、
`configure-power-policy.ps1`、
`apply-gpu-spoof.ps1`、`persist-gpu-profile.ps1`、`gpu-profile-transaction.ps1`、
`refresh-gpu-name.ps1`、
`gpu-hardware-id-plan.ps1`、`project-gpu-hardware-id.ps1` 和
`force-displayfreq.ps1` 放在同一 payload 目录；生产环境始终使用单 EXE。

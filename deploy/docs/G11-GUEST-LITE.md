# G-11 Guest Lite 2.6.4：Windows 10 全面精简/提速傻瓜教程

本工具只属于 **G-11/vGPU**。V-11 是独立分支；不要互拷 VM bundle、驱动或配置。
2.6.4 面向受控 Windows 10 VM，一次处理 Defender、防火墙、系统/软件自动更新、
资讯、天气、商店、OneDrive/同步、通知、任务栏搜索框、消费 App、后台服务/任务和常见 VM 高 I/O 项；
同时开启游戏模式、关闭 Xbox/Game DVR 后台录制、选择高性能电源计划、通过正式
NVIDIA 驱动的 NVAPI DRS 设置“最高性能优先”，并为精确白名单 DNF 映像配置 High
（非 Realtime）优先级。Apply 会安全清理两个固定 Temp 目录中创建/最后写入均超过
24 小时的普通文件，
把默认播放端点静音，并把输入顺序设为 en-US/US keyboard 第一、中文（简体）
Microsoft Pinyin 第二。

`2.6.4` 保留 2.6.3 的 MpsSvc/NVIDIA 控制面板兼容性与克隆快速路径，并修复真实克隆中
Task Scheduler 把 SID 返回为账户名时的等价身份校验，不减少显卡、授权或防火墙验收项：

- vGPU 首启不再让 DISM 枚举整个在线驱动库，而是按当前 GPU 的 DeviceID 精确查询
  `Win32_PnPSignedDriver`，再把已发布 INF 的 SHA-256 与正在加载的
  `nvlddmkm.sys` 所在 `nvgridsw.inf_*` DriverStore 目录逐一绑定；INF 版本、CAT 和
  SYS 的正式 NVIDIA/WHCP 签名及非 Flight 微软生产根仍全部硬性验证；
- 新建回滚基线时，服务和计划任务各只读取一次系统清单；刚创建的完整基线不再立即
  做第二轮升级扫描；
- 自动 `CloneApply` 与短时 SYSTEM 补强任务不再同步等待 `gpupdate /force`。脚本仍先
  原子写入 `Registry.pol + gpt.ini`，并直接写入每个受管运行态值；Windows 后续正常
  策略处理仍保留。交互式 Apply 和 Rollback 的刷新路径不变；
- 内部重启后，finalizer 会复用本次开机已经成功完成的那一次 SYSTEM 补强，前提是
  Task Scheduler 返回 0、运行时间晚于本次开机、日志生成时间也晚于本次开机，并且
  日志中的计算机名、MachineGuid、用户 SID 和全部结果逐项匹配。任一条件不满足才会
  启动一次新的补强任务。

此外，三种防火墙 profile 仍关闭，但 `MpsSvc` 改为必须 `Auto/Running/PID>0`。
Windows AppContainer 注册不再因 0x800706D9 失败，NVIDIA 控制面板可正常启动。

因此提速没有开启 `testsigning`/`nointegritychecks`，没有修改 BCD，没有安装测试或
自签名内核驱动，也没有放宽授权、Code 0、系统 NVAPI、防火墙运行态或回滚验收。

它是激进配置：完成后系统没有启用的内置杀毒、防火墙 profile 和自动安全更新。先只在用户指定的
实验机 **VM1** 验收，不要直接批量投放。

临时文件删除不可逆：运行前关闭安装器、解压器和其他正在使用 Temp 的程序，并确认
不再需要 `%LOCALAPPDATA%\Temp`、`%SystemRoot%\Temp` 内超过 24 小时的内容。脚本不碰
Downloads、桌面、自定义 TEMP、WindowsApps、WinSxS 或浏览器用户资料。

`2.6.4` 保留 2.2 在 VM1 实测发现的“只有 Registry.pol、缺少 gpt.ini 时，重启后策略仍被
清掉”补齐完整原生本地策略状态：原始 `Registry.pol` 和 `gpt.ini` 均逐字节存入回滚
基线，受管副本只写本地 GPO 支持的 `Version` 并同时递增机器/用户版本。Local System 补强
任务在开机/登录延迟 45 秒后重写原生策略和运行态，然后立即退出；没有常驻进程
或第三方服务。2.0.1 的 PowerShell 5.1 异常显示修复也继续保留。

VM1 的第二轮重启审计还定位出 Windows PowerShell 5.1 Registry provider 的陷阱：对
已经存在的叶键反复执行 `New-Item -Force` 会重建该键并删除刚写入的兄弟值，表现为同一
键下只有最后一个策略留下。2.6.1 继续仅在键不存在时创建；设置和回滚都不再重建现有
叶键。Appx 审计也从逐包查询改为一次枚举后按精确白名单过滤，明显缩短应用/验证时间。

2.6.1 新增任务栏搜索框默认隐藏，并修复克隆内部重启后 finalizer 以 Local System 身份
误读 SYSTEM `HKCU` 的问题。克隆验收现在把 `state.json` 中保存的用户 SID 映射到
`HKEY_USERS`，通知、搜索和语言顺序都核验同一个目标用户。自动 CloneApply 的逐项输出
改写入 ProgramData 日志，避免虚拟显示逐行重绘，并跳过与完整基线采集和重启后严格
验收重复的两个全量审计；服务、Appx 和策略操作仍使用 Windows 原生接口顺序执行，
因此无需也不引入第三方运行库。

2.6.1 同时修复旧克隆升级边界：已经确认 `WinDefend` 不运行且没有 `MsMpEng`
进程时，Defender 接口可能无法再返回篡改防护状态，此时允许重施现有策略；若引擎
仍活动，未知状态继续硬性拒绝。明确检测到篡改防护为 `On` 时永远不会绕过。

2.6.4 的真实克隆又确认：个别封装镜像连
HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds\EnableFeeds 也会被 ACL
保护。机器策略和 HKCU 的 ShellFeedsTaskbarViewMode 现在都只作兼容尝试；失败时不
夺注册表所有权、不改 ACL，也不阻断克隆。资讯/天气属于界面精简项，不参与显卡、
授权、MpsSvc、通知核心开关或宿主初始化标记的硬性验收。

## 一、VM1 最短流程

宿主仓库根目录执行一条命令：

```bash
./deploy/scripts/guest-lite.sh 1 usb-mount
```

这会重建固定目录
`/home/ubuntu/images/vms/shared/usb/G11GuestLite/`，再热插整个公共目录为只读 U 盘；
不会自动运行 guest 程序，也不会修改其他 VM。

然后在 VM1 的 Windows 10 内：

1. 打开“Windows 安全中心 → 病毒和威胁防护 → 管理设置”，手工关闭“篡改防护”。
   工具不会绕过它。没有这个开关时先运行 `G11GuestLite.exe /audit`。
2. 打开卷标为 `U盘` 的磁盘，进入 `G11GuestLite`，双击
   `G11GuestLite.exe`；UAC 点“是”，风险确认点 `Yes`。
3. 等待 `APPLY PASS` 或 `APPLY PARTIAL`，不要中途关机，然后从 Windows 开始菜单
   正常“重启”。进入桌面后等待至少 3 分钟，让一次性补强任务及策略刷新执行完。
4. 重启后双击：

   ```text
   C:\ProgramData\G11GuestLite\tools\02-Audit.cmd
   ```

5. 只有窗口显示 `VERIFY PASS` 才是完整通过。详细报告在：

   ```text
   C:\ProgramData\G11GuestLite\reports
   ```

6. 可选 DNF 实测：正常启动 DNF 后再次双击 `02-Audit.cmd`。报告内正在运行的
   `DNF`/`DNFClient`/`DNFChina`/`DNFLauncher` 应显示 `priority=High`。DNF 未运行时
   `dnfProcessFound=False` 是正常状态；下次启动仍由 Windows 自动套用 High。不要改成
   `Realtime`，也不要给 `TCls` 等反作弊进程强制提权。

验收后宿主可弹出只读 U 盘：

```bash
./deploy/scripts/guest-lite.sh 1 usb-eject
```

若只能使用光驱兼容路径：

```bash
./deploy/scripts/guest-lite.sh 1 mount
./deploy/scripts/guest-lite.sh 1 eject
```

## 二、VM1 防火墙/CPU 专项验收

工具用 Windows 自带 `Set-NetFirewallProfile` 关闭 Domain、Private、Public 三种配置
文件，同时要求 `MpsSvc` 为 `Auto/Running`。它不删除服务、规则或文件，不修改服务
ACL，也不停止 `BFE` 和其他网络基础服务。Windows 10 若拒绝普通管理员修改 MpsSvc，
受回滚基线管理的 Local System 补强任务会恢复它，不接管 ACL、不删服务。

这遵循“关闭 profile、保留 MpsSvc”的 Windows 组件兼容边界；NVIDIA 控制面板等
AppContainer 应用仍能向防火墙基础设施注册。若网络或应用异常，在 VM1 本地双击
`C:\ProgramData\G11GuestLite\tools\03-Rollback.cmd`，看到 `ROLLBACK PASS` 后重启。

管理员 PowerShell 可只读复核：

```powershell
Get-NetFirewallProfile | Format-Table Name, Enabled
Get-CimInstance Win32_Service -Filter "Name='MpsSvc'" |
  Format-List Name, StartMode, State, ProcessId
Get-Process | Sort-Object CPU -Descending |
  Select-Object -First 15 ProcessName, CPU, Id
```

重启后的目标是 `MpsSvc StartMode=Auto`、`State=Running`、`ProcessId>0`，同时三个
profile 的 `Enabled` 均为 `False`。
注意 `CPU` 列是进程启动后的累计 CPU 时间，不是瞬时百分比；任务管理器“详细信息”页
更适合观察重启后 3–5 分钟的实时占用。若仍然出现 50%，把最新 audit 报告和任务管理器
中具体进程名保留下来，再定位是否实际为 `MsMpEng`、`svchost` 内另一服务或第三方
网络过滤器。

## 三、2.6 实际修改矩阵

| 类别 | 处理 | 保留/边界 |
|---|---|---|
| Defender | 本地策略与 `Set-MpPreference` 双通道关闭扫描，取消当前扫描，停可管理任务；开机/登录后补强并检查实际扫描字段 | 不夺服务 ACL，不删 Defender 文件；新版 Windows 可保留空闲的 `MsMpEng`/`WinDefend` 外壳及“引擎已加载”信息字段，是否通过以实时、行为、下载、访问、网络保护字段为准 |
| 防火墙 | 三种 profile 全关；`MpsSvc` 保持 Auto/Running，保存 profile 及服务原值 | 不删服务/规则/文件，不改 ACL；保留 `BFE`；兼容 AppContainer/NVIDIA 控制面板，异常走本地回滚 |
| Windows 更新 | 关 WU/公网/Delivery Optimization 对等下载策略，停 `wuauserv`/`UsoSvc`/Update Health 和可管理任务 | 受 Windows 保护的 `DoSvc`/UpdateOrchestrator 对象可保留但被上游策略和服务链路架空；保留 BITS/CryptSvc |
| 软件更新 | 关 Edge/Office/Google 策略及 Edge/Google/Adobe/Mozilla 常见更新服务、任务、进程 | 浏览器、Office、Adobe 本体不卸载 |
| 商店 | 禁用 Store 策略/服务，移除当前用户 Store 与购买 App 注册 | 保留 AppXSvc/ClipSVC 和预配载荷供回滚 |
| 云盘/同步 | 禁 OneDrive、设置/活动/剪贴板同步，删 OneDrive 启动值，停更新任务/进程 | OneDrive 程序载荷不硬删，回滚后可恢复 |
| 资讯/天气 | 隐藏 Win10 资讯和兴趣，移除 Bing News/Weather | 无通配卸载 |
| 消费 App | 当前用户移除 Xbox、Phone Link、Teams、Outlook、Mail/Calendar、3D、纸牌等白名单包 | 保留计算器、照片、画图、记事本、DesktopAppInstaller 和框架依赖 |
| 通知 | 关闭通知总开关、应用/锁屏 Toast、通知中心和 Windows Security 通知 | 不删通知组件；所有原值进入精确回滚基线 |
| 任务栏 | `SearchboxTaskbarMode=0`，默认隐藏搜索框 | 开始菜单/Win 键搜索仍可用；回滚恢复原显示方式 |
| 声音 | 通过 Windows Core Audio 把默认播放端点设为静音，启动补强和审计再次核验 | 保留 Audiosrv、音频设备及驱动；回滚恢复 Apply 前的静音状态 |
| 默认输入 | `en-US` + US (`0409:00000409`) 第一，`zh-CN` + Microsoft Pinyin (`0804:{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}{FA550B04-5AD7-411F-A5AC-CA038EC515D7}`) 第二 | 其他原有语言排在后面，Win+Space 可切换；回滚恢复原语言列表和默认覆盖 |
| 游戏模式/录制 | `AllowAutoGameMode=1`、`AutoGameModeEnabled=1`；关闭 Game DVR、AppCapture 和 HistoricalCapture | 游戏模式与后台录制分别设置；关闭录制不等于关闭游戏模式；原值逐项回滚 |
| 后台/隐私 | 关后台 App、内容投放、遥测、推送、地图、定位等白名单服务/任务；结束更新器、Game Bar、Teams/Widgets 等精确白名单进程 | 不按 CPU 排名盲杀，不碰网络/音频驱动、打印和 NVIDIA 服务；仅静音默认播放端点 |
| Windows 性能 | 关 SysMain/搜索索引、电源节流、透明/任务栏动画和启动延时；切换内置“高性能”方案 | 保留桌面背景和字体平滑；2.2 自动恢复旧版 `VisualFXSetting` 基线；不改分页文件、时钟、HPET 或 BCD |
| NVIDIA 性能 | 通过 System32 正式 NVIDIA NVAPI 的 DRS 全局 profile 设置 `PREFERRED_PSTATE_ID=0x1057EB71` 为 `PREFER_MAX=1` | 不写私有 PowerMizer 注册表，不替换 NVAPI/驱动/服务；原覆盖值或“未覆盖”状态精确回滚；驱动不支持会明确 PARTIAL |
| DNF 优先级 | 仅 `DNF.exe`、`DNFClient.exe`、`DNFChina.exe`、`DNFLauncher.exe` 使用 IFEO `PerfOptions/CpuPriorityClass=3`，并立即检查已运行实例 | `3` 对应 High；不使用通配符、不提升反作弊进程、不使用 Realtime；回滚删除/恢复原 IFEO 值并恢复 Apply 时仍存活的进程优先级 |
| 临时文件 | 遍历当前用户 LocalAppData Temp 与 Windows Temp；只删创建/最后写入均超过 24 小时的普通文件及清空后的旧目录 | 固定本机目录、拒绝根目录/网络盘/重解析点，不跟随联接；占用/拒绝项保留并报告；删除不可回滚 |
| 重启持久化 | 保存并扩展机器/用户 `Registry.pol`，生成/合并合法的 `gpt.ini Version`，开机和目标用户登录后由 SYSTEM 延迟刷新、补强一次 | `gPCMachineExtensionNames`/`gPCUserExtensionNames` 是 AD GPO 对象属性，绝不写进本地 gpt.ini；无常驻服务、无密码、无第三方库；回滚逐字节还原原 policy/metadata 文件 |

脚本不会按“名称里含 update/service”粗暴匹配。固定对象用精确名称；版本化 Google/
OneDrive 服务和计划任务只允许通过锚定的路径/正则白名单发现。发现到的每一个对象都
先写进 `state.json`，再修改。

## 四、回滚基线与重复运行

首次 Apply 在任何修改前保存：

```text
C:\ProgramData\G11GuestLite\state.json
```

其中包含 MachineGuid、计算机名、用户 SID、注册表值/类型、防火墙三 profile、原始
音频静音状态、原始用户语言/输入列表、活动电源方案、NVIDIA DRS 覆盖状态、Apply 时
仍运行的 DNF 进程 PID/启动时间/优先级、服务
启动/运行状态、任务启用状态、当前用户 App 清单，以及机器/用户原始
`Registry.pol`、`gpt.ini` 字节和补强任务是否原先存在。目录 ACL 只允许 Administrators 和
SYSTEM。重复 Apply 复用首次基线，不把“已经禁用”的状态覆盖成原始值。

若 VM1 已经运行过旧版，2.6 会先把新增项目（包括 NVIDIA DRS、DNF 运行态、游戏设置）的当前状态
补进旧基线、原子保存为 schema 6，再开始新增修改。VM1 从 2.1 升级时，原基线已保存
最初的 Registry.pol；2.1 没有创建过 gpt.ini，因此新版可安全补记“原文件不存在”并
保证回滚精确删除它。

回滚只需双击：

```text
C:\ProgramData\G11GuestLite\tools\03-Rollback.cmd
```

看到 `ROLLBACK PASS` 后重启。回滚会先删除 Guest Lite 补强任务、恢复原始
`Registry.pol`/`gpt.ini`，再恢复语言/输入、注册表、防火墙、声音静音、NVIDIA DRS、
仍存活的原 DNF 进程优先级、服务、任务、App 和电源。已删除的临时文件不能恢复。
失败时显示
`ROLLBACK PARTIAL`，原 state 不删除，可修复后重试。App 只恢复首次 Apply 前存在的
包；若其他工具后来删除 WindowsApps 预配文件，本工具不会从互联网下载来源不明的 Appx。

若 VM1 以前已应用 `G11GuestPerformance`/新版 `VgpuPortable.exe` 的性能项，Guest
Lite 会把当时状态作为自己的基线。多个可回滚工具必须按应用的反顺序恢复：先回滚
Guest Lite，再回滚 Guest Performance；不要交叉覆盖各自的 `state.json`。

## 五、独立封装与无第三方运行库证明

只构建，不挂载：

```bash
./deploy/package-guest-lite.sh
```

默认输出固定在：

```text
/home/ubuntu/images/staging/guest-lite/G11GuestLite/G11GuestLite.exe
/home/ubuntu/images/staging/guest-lite/G11GuestLite/G11GuestLite.iso
```

也可指定无凭据的绝对目录：

```bash
./deploy/package-guest-lite.sh --output-root /absolute/output/directory
```

EXE 是普通 x86-64 Windows 用户态 PE，内嵌可审查的 PS1/CMD/README；MinGW 编译器
支持静态链接，导入表测试只允许 Windows inbox 的
`ADVAPI32/bcrypt/KERNEL32/msvcrt/SHELL32/USER32`。Windows 运行时只需要系统自带
DLL、Windows PowerShell 5.1、CIM/NetSecurity/Defender/Appx/TaskScheduler cmdlet
和 `powercfg/sc/icacls`；NVIDIA 项仅动态调用已安装驱动的 System32 `nvapi64.dll`，
不随包携带或替换 NVAPI。工具不安装 VC++/.NET/Python/Java 等第三方运行库。

运行完整封装回归：

```bash
./deploy/tests/vgpu/test_guest_lite_package.sh
```

测试会验证确定性构建、PE 架构/UAC 清单、严格 DLL 导入白名单、内嵌资源、ISO/USB
目录、CRLF 启动器、schema 6 policy/metadata/task/audio/language/NVIDIA/DNF 回滚、
Game Mode/Game DVR、固定 Temp 白名单/重解析点保护、合法 gpt.ini、
克隆 manifest、禁止 BCD/签名/驱动/系统包删除操作及 2.6 必需控制项。

### en-US 是否需要离线语言包

这里的目标是“英语（美国）US 键盘作为默认输入”，不是把 Windows 显示界面改成
英文。US 键盘布局属于 Windows 10 inbox 组件；Guest Lite 使用系统自带
`New-WinUserLanguageList`/`Set-WinUserLanguageList` 建立 `en-US` 输入项，Sysprep
应答文件也在 `specialize` 和 `oobeSystem` 写入同一顺序，因此没有网络、没有 CAB
也能完成。

部分 Windows 10 会把第二项的 BCP-47 标签规范化成 `zh-Hans-CN`；这与 `zh-CN` 指向
同一简体中文输入项。验收接受这两个等价标签，但仍要求第二项包含上面的微软拼音 TIP，
不会因为标签别名而放宽到其他输入法。

当前两张安装 ISO 都是 zh-CN，仓库外镜像目录也没有与该系统版本匹配的微软官方
en-US Language Pack/FOD CAB，所以本次不会把来源不明或版本不匹配的 CAB 塞进母盘。
若未来要把整个 Windows UI 改成英文，应单独准备与目标 Win10 build、架构和累计更新
严格匹配的微软官方 LP/FOD，再增加离线 DISM 阶段；这不影响本次 US 键盘输入目标。

## 六、克隆后自动运行与 VM2 验收

这条自动链只接到 **G-11 私有 Sysprep 母盘**，不改 V-11，也不把宿主凭据写入镜像。
制作母盘时先在 Windows 安全中心手工关闭“篡改防护”，然后按现有私有母盘流程执行
Sysprep `/generalize /oobe /shutdown`。这是 Defender 的人工安全边界，脚本不会绕过。

重新注入当前首启载荷后，克隆命令仍是一条：

```bash
./deploy/scripts/clone-from-base.sh win10-base 2 --start
```

等待 VM2 自动内部重启一次并最终完整关机；不要在初始化窗口运行时强制停止。命令行
用户随后执行：

```bash
sudo ./deploy/scripts/initialize-clone.sh 2
./deploy/scripts/start-vm.sh 2
```

如果第一条明确显示来宾仍是旧 `schemaVersion`/Guest Lite 版本，不要重复点“初始”，
也不要改 BCD 或驱动。先完整关机并按
[`G11-CLONE-PAYLOAD-RECOVERY.md`](G11-CLONE-PAYLOAD-RECOVERY.md) 运行：

```bash
sudo ./deploy/scripts/repair-clone-init.sh 2
```

同时对用于后续克隆的私有母盘执行一次
`./deploy/scripts/refresh-g11-private-base.sh win10-base`，即可避免其它新克隆重复命中
旧载荷。

第一条会严格验收来宾完成标记、独立 Windows 身份、Licensed/Code 0、系统 NVAPI、
Guest Lite 的 SYSTEM `pass/0` 回执、`MpsSvc=Auto/Running/PID>0` 与
`BFE=Auto/Running`、默认声音静音以及精确输入顺序，并刷新显示器缓存；任一项失败都
保留等待门禁，绝不发布半成品。

首启顺序如下：

1. 自动 OOBE/独立 MachineGuid、机器 SID 和 `DESKTOP-XXXXXXX` 名称；
2. VgpuPortable 做 DLS Licensed、GRID 538.33、DEV_1E30/Code 0 校验；
3. finalizer 校验 `clone-manifest.json` 固定摘要及 Guest Lite 每个载荷摘要，自动运行
   `CloneApply`，保存该克隆 RID-500 用户的原始外观/策略/App/服务回滚基线；
4. 复用系统 NVAPI 的内部重启，SYSTEM 验证 NVAPI/显示器，同时要求
   `MpsSvc=Auto/Running/PID>0`、`BFE=Auto/Running`、通知关闭、默认声音静音、
   en-US/US 第一、Microsoft Pinyin 第二、本地 policy 文件及 Guest Lite 补强任务完整；
5. 只有全部通过才写 schema-4 完成标记并完整关机；宿主“初始”只读复核后再启动。

若母盘篡改防护仍开启，自动链会明确失败并保留
`C:\ProgramData\VMate\G11\clone-initialization-error.txt`，不会静默跳过 Defender。修复
母盘后重建；不要通过 BCD、测试签名、驱动或 ACL 绕过。

桌面 Retry 使用 Auto 模式：若系统 NVAPI 已产生严格绑定的 validated receipt，会
直接续跑 Complete 验收，不重复 Apply、不覆盖首次回滚基线。Windows 在投影阶段改名
不会造成误判，因为状态绑定采用 `MachineGuid + RID-500 SID`；SYSTEM 补强任务则以
启动前后 `LastRunTime` 确实递增和返回码 0 为准，不依赖本机时间容差。

## 七、明确禁止和保留项

- 不运行 `bcdedit`，不设置 `testsigning`/`nointegritychecks`；
- 不安装、替换、测试签名或自签名任何内核驱动；
- 不修改正式 NVIDIA GRID/vGPU、网卡、音频、打印和存储驱动；只调用正式驱动公开的
  用户态 NVAPI DRS 配置接口；
- 不使用 TrustedInstaller/接管 ACL/删除系统服务的手段；
- 不调用 `Remove-AppxProvisionedPackage`，不删 WinSxS/System32/WindowsApps；
- 不停 BITS、CryptSvc、AppXSvc、ClipSVC；
- 不关闭桌面背景或字体平滑，不再设置全局“最佳性能”视觉预设；
- 不写入或索取宿主/guest 凭据，包内不含 VM ID、UUID、token 或账号信息；
- 不清理 Downloads、桌面、用户资料、自定义 TEMP、WindowsApps 或组件存储；固定
  Temp 内删除的旧文件不可回滚；
- 只支持 Windows 10 client，不在 Windows 11/Server 执行。

## 八、为什么可能出现 PARTIAL

Windows 10 1903+ 的篡改防护会阻止 Defender 本地改动；新版 Defender 平台可能忽略
旧式 `DisableAntiSpyware`、`DisableAntiVirus`、`ServiceKeepAlive` 总开关。2.2 把这
三个值视为可选兼容项，严格检查受支持的实时、行为、下载、访问和网络保护有效状态。
Update Orchestrator/DoSvc 的受保护对象
不接管 ACL，而是验证其上游 WU 策略及 `wuauserv`/`UsoSvc` 已关闭。其他必需策略、
服务、任务、App、进程或三种防火墙 profile 不符时仍返回 PARTIAL。
正式 NVIDIA 驱动缺失、NVAPI DRS 不支持/拒绝写入，或两个固定 Temp 根目录均无法
安全处理时也返回 PARTIAL；不会用私有驱动注册表值或安装其他组件伪装成功。

参考：

- [Microsoft Defender DisableAntiSpyware 与篡改防护限制](https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/security-malware-windows-defender-disableantispyware)
- [Windows Update 策略](https://learn.microsoft.com/windows/deployment/update/waas-wu-settings)
- [OneDrive DisableFileSyncNGSC 策略](https://learn.microsoft.com/windows/client-management/mdm/policy-csp-system#disableonedrivefilesync)
- [Microsoft Edge Update 策略](https://learn.microsoft.com/deployedge/microsoft-edge-update-policies)
- [Google Update/Chrome 自动更新策略](https://support.google.com/chrome/a/answer/6350036)
- [Mozilla Firefox DisableAppUpdate 策略](https://mozilla.github.io/policy-templates/#disableappupdate)
- [Adobe Acrobat/Reader bUpdater 策略](https://www.adobe.com/devnet-docs/acrobatetk/tools/PrefRef/Windows/Updater-Win.html)
- [Windows Firewall 概览与微软“不停止 MpsSvc”的风险说明](https://learn.microsoft.com/windows/security/operating-system-security/network-security/windows-firewall/)
- [Set-NetFirewallProfile](https://learn.microsoft.com/powershell/module/netsecurity/set-netfirewallprofile)
- [Get-NetFirewallProfile](https://learn.microsoft.com/powershell/module/netsecurity/get-netfirewallprofile)
- [Windows 默认输入区域设置/TIP 表](https://learn.microsoft.com/windows-hardware/manufacture/desktop/default-input-locales-for-windows-language-packs)
- [New-WinUserLanguageList](https://learn.microsoft.com/powershell/module/international/new-winuserlanguagelist)
- [Microsoft Group Policy gpt.ini 版本格式](https://learn.microsoft.com/openspecs/windows_protocols/ms-gpol/59bb540a-64f4-4c52-9c55-5ca2fd2c0270)
- [Microsoft Registry.pol 消息格式（键名和值名必须为 NUL 结尾 UTF-16LE）](https://learn.microsoft.com/openspecs/windows_protocols/ms-gpreg/5c092c22-bf6b-4e7f-b180-b20743d368f5)
- [NVIDIA NVAPI DRS API](https://docs.nvidia.com/nvapi/group__drsapi.html)
- [NVIDIA NVAPI PREFERRED_PSTATE 设置和值](https://docs.nvidia.com/nvapi/NvApiDriverSettings_8h.html)

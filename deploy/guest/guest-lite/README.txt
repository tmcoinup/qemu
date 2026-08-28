G-11 Windows 10 Guest Lite 2.6.4（全面精简/提速一键包）
=====================================================

用途
----

只用于 G-11/vGPU 的受控 Windows 10 实验机或模板。V-11 是独立分支，不要把
G-11 的 VM 目录、驱动或配置复制给 V-11。

2.6.4 一次完成 Defender 杀毒、防火墙、Windows/商店/常见软件自动更新、资讯、
天气、OneDrive/设置同步、通知、任务栏搜索框、消费 App、后台任务和 VM 高 I/O 项的停用/精简；
同时开启 Windows 游戏模式、关闭 Xbox/Game DVR 后台录制、切换高性能电源计划、
通过正式 NVIDIA 驱动的 NVAPI DRS 设置全局“最高性能优先”，并把 DNF 精确白名单
映像固定为 High（绝不使用 Realtime）优先级。Apply 还会清理当前用户 LocalAppData\Temp
和 Windows\Temp 内“创建时间和最后写入时间均超过 24 小时”的普通临时文件，跳过
重解析点、新文件和占用中的文件。
把默认播放端点静音，并把输入顺序设为 en-US/US keyboard 第一、zh-CN/Microsoft
Pinyin 第二，同时保存精确回滚基线。它不会安装
第三方运行库：G11GuestLite.exe 是普通 64 位用户态 EXE，
编译器支持已静态链接，启动器运行时只导入 Windows 自带 DLL；优化脚本调用
PowerShell 5.1、系统命令，以及来宾已安装正式 NVIDIA 驱动的 System32 NVAPI。

2.6.4 的克隆快速路径不会减少验收：当前 GPU 的签名驱动按 DeviceID 精确查询，已
发布 INF 与正在加载的 nvlddmkm.sys 所在 nvgridsw.inf_* DriverStore 目录按 SHA-256
绑定，INF 版本、CAT/SYS 正式 NVIDIA/WHCP 签名和微软生产根继续硬性检查。服务与
计划任务清单各只枚举一次；新建完整回滚基线不再立即重复升级扫描。自动 CloneApply
和 SYSTEM 补强会原子写 Registry.pol/gpt.ini 并直接写全部运行态值，因此不再同步
等待重复的 gpupdate；交互 Apply/回滚路径保留。内部重启后只有任务返回 0、时间属于
本次开机，且日志的计算机名、MachineGuid、用户 SID 与全部结果精确一致时，finalizer
才复用已经完成的那次 SYSTEM 补强，否则仍启动一次新的补强。
这不改 BCD，不开启 testsigning/nointegritychecks，不安装测试/自签名内核驱动，也不
放宽 Licensed、Code 0、x86/x64 系统 NVAPI、防火墙或回滚检查。

2.6.4 保留 NVIDIA 控制面板兼容性：三种防火墙 profile 仍保持关闭，但不再禁用
MpsSvc。脚本和每次 SYSTEM 补强都会要求 MpsSvc=Auto/Running；Windows Store/UWP
的 AppContainer 注册因此可正常完成，避免 NVIDIA 控制面板出现 0x800706D9 后无界面。
这只调整 Windows 用户态服务策略，不修改 BCD、代码完整性或任何内核驱动。

2.6.4 会保存并扩展 Windows 原生机器/用户 Registry.pol，同时只生成/更新本地 GPO
真正支持的 gpt.ini Version 字段；另外安装一个 Local System 开机/登录延迟
45 秒执行的短时补强任务，重新禁用受管服务/计划任务、结束更新进程、重写策略和
高性能电源方案后退出，无常驻进程。原 Registry.pol 和
gpt.ini 都逐字节进入回滚基线。2.0.1 的 PowerShell 5.1 异常显示修复继续保留。
VM1 还验证了 Windows PowerShell 5.1 对已存在注册表叶键执行 New-Item -Force 会清掉
同键兄弟值；2.6.1 继续只创建不存在的键，因此同一策略键下的全部值都会保留，回滚
也不会因重建叶键而误删无关值。App 审计改为一次枚举后按精确名称过滤，避免逐包查询。
当前修订还修复了 Windows 改计算机名后补强任务返回 1 的问题：状态改用不随重命名
变化的 MachineGuid + 本地用户 SID 绑定，登录触发器也直接绑定 SID；审计会显示补强
任务的上次运行时间和返回码。它不会放宽到另一套 Windows 身份或另一名用户。
2.6.1 另外隐藏任务栏搜索框，并修复克隆重启后由 Local System finalizer 错把
SYSTEM 的 HKCU 当成 Administrator HKCU 的问题；finalizer 现在按 state.json 中保存的
SID 读取 HKEY_USERS，并从同一用户 Hive 核验语言顺序。克隆 Apply 的详细输出写入日志，
不再逐行刷新虚拟显示窗口，也跳过与基线采集/重启验收重复的前后全量审计；Windows
服务/Appx 操作本身仍按安全顺序执行。
2.6.1 还允许已经停用 WinDefend 且不存在 MsMpEng 进程的旧克隆升级：此时 Defender
接口可能无法再报告篡改防护状态，但系统里也没有可被绕过的活动防护引擎。只要任一
引擎组件仍在运行，未知状态仍会硬性失败并要求人工检查；篡改防护明确为 On 时始终
拒绝执行。

2.6.4 的真实克隆确认部分镜像还会保护机器级 EnableFeeds。机器级 EnableFeeds 和
用户级 ShellFeedsTaskbarViewMode 都只作兼容尝试；失败时不夺所有权、不改 ACL，
也不阻断初始化。资讯/天气是界面精简项，不属于显卡、授权、MpsSvc 或通知核心开关
的硬性验收。Task Scheduler 把登录 SID 规范化为账户名时，也会先解析回 SID 再校验，
不会再把同一用户误判为提示任务注册失败。

实验机 VM1：宿主机只执行这一条
------------------------------

  cd /home/ubuntu/projects/qemu
  ./deploy/scripts/guest-lite.sh 1 usb-mount

这只会把固定包热挂载成只读工具 U 盘，不会自动修改 Windows。不要对其他 VM 执行。

Windows 里只做 4 步
------------------

1. 打开“Windows 安全中心 -> 病毒和威胁防护 -> 管理设置”，手工关闭“篡改防护”。
   工具不会绕过篡改防护。没有此开关时，先运行 G11GuestLite.exe /audit。
2. 打开新出现的只读 U 盘，进入 G11GuestLite 文件夹，双击 G11GuestLite.exe。
   UAC 选“是”，红色风险确认选“Yes”。SmartScreen 出现时，确认来源是受管工具
   U 盘后选“更多信息 -> 仍要运行”。
3. 等窗口显示 APPLY PASS 或 APPLY PARTIAL，再正常重启 Windows；处理中不要关机。
4. 重启进入桌面后等待至少 3 分钟，再打开 C:\ProgramData\G11GuestLite\tools，双击
   02-Audit.cmd。
   只有显示 VERIFY PASS 才是完整成功；报告保存在：

   C:\ProgramData\G11GuestLite\reports

可选 DNF 实测：先正常启动 DNF，再双击 02-Audit.cmd。报告中正在运行的
DNF/DNFClient/DNFChina/DNFLauncher 必须显示 priority=High；未启动 DNF 时显示
dnfProcessFound=False 是正常结果，下次启动仍会由 Windows IFEO PerfOptions 自动设为
High。不要手工改成 Realtime。

会做什么
--------

- Defender：本地策略 + Set-MpPreference 双通道关闭实时/行为/脚本/下载扫描，取消
  当前扫描；重启后补强并核验实际扫描状态。新版 Windows 可保留受保护但空闲的
  MsMpEng.exe/WinDefend 外壳及“引擎已加载”信息字段，本工具不夺 ACL，是否通过以
  实时、行为、下载、访问和网络保护字段为准。
- 防火墙：关闭 Domain、Private、Public 三种配置文件，但保留 MpsSvc
  Auto/Running；不删除服务/规则/文件，不改 ACL，保留 BFE 和其他网络基础服务。
  MpsSvc 在部分 Win10 上拒绝普通管理员改启动类型时，工具会调用受回滚管理的 Local
  System 补强任务恢复，不夺权。重启审计要求 StartMode=Auto、State=Running、PID>0，
  同时三个 profile 的 Enabled 均为 False；这样 NVIDIA 控制面板等 AppContainer 应用
  可正常注册，而防火墙 profile 仍按本配置关闭。
- 系统更新：停用 Windows Update、Update Orchestrator、Update Health、商店安装
  服务及可管理任务；关闭 Delivery Optimization 对等下载。受保护的 DoSvc/更新任务
  可保留，但被 WU 策略及 wuauserv/UsoSvc 服务链路架空。
- 软件更新：停用 Edge、Office、Google、Adobe、Mozilla 的常见自动更新策略、服务、
  计划任务和正在运行的更新进程；浏览器/Office/Adobe 软件本体不卸载。
- 云盘/同步：禁用 OneDrive 文件同步、Windows 设置/活动/跨设备剪贴板同步，删除
  当前用户 OneDrive 自启动值，停用其更新任务并结束 OneDrive 进程。OneDrive 本体
  保留为可恢复载荷，但运行态和自动启动均被禁用。
- 资讯/天气/商店/App：隐藏任务栏资讯和兴趣，移除当前用户的 Bing News/Weather、
  Store、Xbox、Phone Link、Teams、Outlook、Mail/Calendar、3D、纸牌等审计清单内
  App。系统预配载荷保留，便于可靠回滚；消费内容和后台 App 再投放策略会关闭。
- 通知：关闭当前用户通知总开关、应用和锁屏 Toast、通知中心，以及 Windows 安全中心
  通知；不卸载通知系统组件。Apply、开机补强和审计使用同一组精确策略值，Rollback
  恢复首次 Apply 前的每个值。
- 任务栏：把当前用户 SearchboxTaskbarMode 设为 0，默认隐藏搜索框；开始菜单和
  Win 键搜索仍可用，Rollback 恢复首次 Apply 前的显示方式。
- 声音：只把默认播放端点设为静音；不禁用 Windows Audio 服务，不卸载/禁用音频
  设备或驱动。Apply 前的静音状态进入回滚基线，开机补强和审计会再次核验。
- 输入法：把当前用户语言/输入列表固定为 English (United States) - US
  (`0409:00000409`) 第一、中文（简体）Microsoft Pinyin
  (`0804:{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}{FA550B04-5AD7-411F-A5AC-CA038EC515D7}`)
  第二；其他原有语言继续排在后面，Win+Space 可切换。US 键盘布局是 Windows 10
  自带组件。部分 Win10 会把第二项规范化显示为 zh-Hans-CN；Microsoft Pinyin TIP
  不变，审计同时接受 zh-CN/zh-Hans-CN 这两个等价标签。
  这项输入需求可完全离线封装，不需要 en-US 显示语言 CAB。若需要把整个
  Windows 界面改成英文，必须另备与目标 Win10 版本、架构、补丁级别匹配的微软官方
  Language Pack/FOD CAB；本包不携带也不下载来源或版本不明的语言包。
- 性能：关闭 SysMain、搜索索引、遥测、推送、地图、定位、Xbox 等审计清单内服务
  和任务，结束 OneDrive、更新器、Game Bar、Teams/Widgets 等精确白名单后台进程；
  关闭透明/任务栏动画、启动延时、电源节流，并选择 Windows 自带“高性能”电源方案。
  开启游戏模式，同时关闭 Game DVR/AppCapture/HistoricalCapture 后台录制。
- NVIDIA：仅通过 System32 中已安装正式驱动提供的 NVAPI DRS，把全局
  Power management mode 设为 Prefer maximum performance；不写 PowerMizer 私有值，
  不替换 DLL、驱动或服务。原 DRS 覆盖状态进入 schema 6 回滚基线。
- DNF：只允许 DNF.exe、DNFClient.exe、DNFChina.exe、DNFLauncher.exe 使用 High
  优先级；Apply 会立即检查当前进程，Windows 后续创建这些映像时也自动应用。
  不匹配通配符，不提升 TCls/反作弊进程，不使用 Realtime。
- 临时文件：只遍历当前用户 LocalAppData\Temp 与 Windows\Temp 两个固定本地目录；
  仅删创建/最后写入均超过 24 小时的普通文件及清空后的旧目录，不跟随符号链接/联接点。被占用或
  无权限项保留并写报告。此项释放的文件不可回滚，其余配置仍可精确回滚。
  保留桌面背景和字体平滑；2.2 会恢复旧版曾改动的全局 VisualFXSetting。
- 每次执行都会生成执行前/后的文本报告。首次 Apply 前把注册表、防火墙、音频静音、
  用户语言/输入、电源、NVIDIA DRS、Apply 时仍在运行的 DNF 优先级、服务、任务、
  当前用户 App、原始 Registry.pol/gpt.ini 和补强
  任务状态保存到受限 ACL 的 state.json；重复 Apply 不会覆盖最初基线。旧基线会先
  安全扩展为 schema 6。

克隆后的自动运行（G-11 私有 Sysprep 母盘）
-------------------------------------------

母盘封装前必须在 Windows 安全中心手工关闭一次“篡改防护”，再执行 Sysprep；工具不
会绕过该安全开关。当前私有 G-11 首启 finalizer 会在 VgpuPortable 完成 Licensed
校验后，校验内置 Guest Lite manifest 和每个文件的 SHA-256，再以内部 CloneApply
模式自动应用；它复用系统 NVAPI 的那一次验证重启，不额外安装第三方组件。重启后
SYSTEM 同时验收 MpsSvc=Auto/Running/PID>0、BFE=Auto/Running、policy 文件、通知
关闭、默认声音静音、en-US/US 第一、Microsoft Pinyin 第二、目标用户 SID 和精确回滚
基线；finalizer 还会主动运行一次 SYSTEM 补强任务，并要求返回码为 0、日志为 pass，
全部通过才写宿主可接受的完成标记并关机。V-11 不走此链。

package-g11-sysprep-kit.sh 会一次编译并生成完整的公开 G11SysprepKit：其中 Payload
目录已经归集 Finalize、Retry、固定 manifest 的 Guest Lite 自动载荷，
Standalone-GuestLite 目录还包含一个供其他已有 Windows 手工使用的 G11GuestLite.exe。
模板中只运行 Seal-G11-Template.cmd；它会把公开自动载荷预置到
C:\ProgramData\VMate\G11，不能在模板里提前运行 G11GuestLite.exe。

公开工具包仍不包含授权 VgpuPortable 或 token。模板关机镜像还必须经
build-g11-private-base.sh（或私有 installer）注入授权 EXE并再次校验/刷新首启载荷，
克隆才会自动运行上述完整链。

若首启桌面出现 Retry-Clone-Initialization，先打开：

  C:\ProgramData\VMate\G11\clone-initialization-error.txt

按其中的明确错误处理后，再右键 Retry-Clone-Initialization 选择“以管理员身份运行”。
不要反复重做母盘；错误文件、Guest Lite enforce-last.txt 和 reports 目录就是排错依据。

恢复（同样只需双击）
--------------------

打开 C:\ProgramData\G11GuestLite\tools，双击 03-Rollback.cmd，看到 ROLLBACK PASS
后重启。它会先删除 Guest Lite 补强任务并逐字节恢复原 Registry.pol/gpt.ini，再恢复首次
Apply 前的用户语言/输入顺序、策略/启动项、防火墙配置、声音静音、电源方案、NVIDIA
DRS、仍存活的原 DNF 进程优先级、服务、任务，并尝试从保留的
WindowsApps 载荷重新注册原有 App。任一项失败时 state.json 会保留，修复原因后可
再次运行回滚。已删除的临时文件不会也不能由 Rollback 伪造回来。

命令行
------

  G11GuestLite.exe /apply      应用（双击默认动作）
  G11GuestLite.exe /audit      只审计；Apply 后会严格验证
  G11GuestLite.exe /rollback   恢复保存的原始基线

明确不会做
----------

- 不修改 BCD，不开启 testsigning 或 nointegritychecks；
- 不安装、替换、测试签名或自签名任何内核驱动；
- 不改 NVIDIA/vGPU、网卡、音频、打印和存储驱动；NVIDIA 只改可回滚的用户态 DRS 设置；
- 不夺取 WinDefend/MpsSvc/TrustedInstaller 所有权，不删除防火墙规则；
- 不删除 WinSxS、System32、WindowsApps 或 Appx 预配载荷；
- 不停 BITS、CryptSvc、AppXSvc、ClipSVC，不删除 Edge/WebView2、计算器、照片、
  画图、记事本、DesktopAppInstaller、VCLibs/.NET/UI.Xaml 等常见软件依赖；
- 不猜测卸载第三方杀毒，不写入或索取宿主机/来宾机凭据。

重要限制
--------

- 仅支持 Windows 10 客户端，不支持 Windows 11/Server。
- 临时清理是唯一不可逆的数据删除项；运行前先关闭安装器/解压器，并确认不需要
  两个 Temp 目录中超过 24 小时的内容。工具不会清理 Downloads、桌面、WindowsApps、
  WinSxS、浏览器资料或任意自定义 TEMP 路径。
- 这是面向受控 VM 的激进配置：完成后没有启用的内置杀毒、防火墙 profile 和自动安全更新。VM1
  验证无误并制作可恢复快照/母盘后，才能考虑给其他 G-11 VM 使用。
- 若防火墙 profile 设置后网络或应用异常，在 VM1 本地双击
  C:\ProgramData\G11GuestLite\tools\03-Rollback.cmd，看到 ROLLBACK PASS 后重启；
  不要先部署到只能远程管理的机器。
- Defender for Endpoint 接管的企业设备会拒绝 Apply。新版 Defender 平台会保护或
  忽略旧式 DisableAntiSpyware/DisableAntiVirus/ServiceKeepAlive 总开关；它们作为
  兼容项记录，不代替对实时、行为、下载、访问和网络保护有效状态的严格验收。
- Windows 会保护部分 DoSvc/Update Orchestrator 对象。工具不会夺权绕过；这些对象
  保留但由策略和已禁用的上游服务架空，报告会标记 required=False。其余必需项不符
  仍返回 PARTIAL。
- App 卸载针对运行工具的当前管理员账户。模板应在最终实际账户中运行；不批量改写
  其他用户配置文件。

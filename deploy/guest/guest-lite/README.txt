G-11 Windows 10 Guest Lite 2.3.0（全面精简/提速一键包）
=====================================================

用途
----

只用于 G-11/vGPU 的受控 Windows 10 实验机或模板。V-11 是独立分支，不要把
G-11 的 VM 目录、驱动或配置复制给 V-11。

2.3.0 一次完成 Defender 杀毒、防火墙、Windows/商店/常见软件自动更新、资讯、
天气、OneDrive/设置同步、消费 App、后台任务和 VM 高 I/O 项的停用/精简，并保存
精确回滚基线。它不会安装第三方运行库：G11GuestLite.exe 是普通 64 位用户态 EXE，
编译器支持已静态链接，运行时只调用 Windows 自带 DLL、PowerShell 5.1 和系统命令。
2.3.0 会保存并扩展 Windows 原生机器/用户 Registry.pol，同时只生成/更新本地 GPO
真正支持的 gpt.ini Version 字段；另外安装一个 Local System 开机/登录延迟
45 秒执行的短时补强任务，强制刷新策略后退出，无常驻进程。原 Registry.pol 和
gpt.ini 都逐字节进入回滚基线。2.0.1 的 PowerShell 5.1 异常显示修复继续保留。
VM1 还验证了 Windows PowerShell 5.1 对已存在注册表叶键执行 New-Item -Force 会清掉
同键兄弟值；2.3.0 现在只创建不存在的键，因此同一策略键下的全部值都会保留，回滚
也不会因重建叶键而误删无关值。App 审计改为一次枚举后按精确名称过滤，避免逐包查询。

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

会做什么
--------

- Defender：本地策略 + Set-MpPreference 双通道关闭实时/行为/脚本/下载扫描，取消
  当前扫描；重启后补强并核验实际扫描状态。新版 Windows 可保留受保护但空闲的
  MsMpEng.exe/WinDefend 外壳及“引擎已加载”信息字段，本工具不夺 ACL，是否通过以
  实时、行为、下载、访问和网络保护字段为准。
- 防火墙：先关闭 Domain、Private、Public 三种配置文件，再禁用 MpsSvc 开机启动并
  尝试停止当前实例；不删除服务/规则/文件，不改 ACL，保留 BFE 和其他网络基础服务。
  MpsSvc 在部分 Win10 上拒绝普通管理员改启动类型，工具会立即调用自己受回滚管理的
  Local System 补强任务完成，不夺权；第一次正常重启就应为 Stopped/PID 0。
  微软不推荐停 MpsSvc，因为可能影响网络发现、IPsec 或部分 Windows 组件；这是用户
  明确指定的 VM1 实验项。重启审计要求 StartMode=Disabled、State=Stopped、PID=0。
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
- 性能：关闭 SysMain、搜索索引、遥测、推送、地图、定位、Xbox 等审计清单内服务
  和任务；关闭透明/任务栏动画、启动延时、电源节流，并选择 Windows 自带“高性能”
  电源方案。保留桌面背景和字体平滑；2.2 会恢复旧版曾改动的全局 VisualFXSetting。
- 每次执行都会生成执行前/后的文本报告。首次 Apply 前把注册表、防火墙、电源、
  服务、任务、当前用户 App、原始 Registry.pol/gpt.ini 和补强任务状态保存到受限 ACL 的
  state.json；重复 Apply 不会覆盖最初基线。旧基线会先安全扩展为 schema 4。

克隆后的自动运行（G-11 私有 Sysprep 母盘）
-------------------------------------------

母盘封装前必须在 Windows 安全中心手工关闭一次“篡改防护”，再执行 Sysprep；工具不
会绕过该安全开关。当前私有 G-11 首启 finalizer 会在 VgpuPortable 完成 Licensed
校验后，校验内置 Guest Lite manifest 和每个文件的 SHA-256，再以内部 CloneApply
模式自动应用；它复用系统 NVAPI 的那一次验证重启，不额外安装第三方组件。重启后
SYSTEM 同时验收 MpsSvc=Disabled/Stopped/PID 0、BFE=Auto/Running、policy 文件、目标
用户 SID 和精确回滚基线，全部通过才写宿主可接受的完成标记并关机。V-11 不走此链。

恢复（同样只需双击）
--------------------

打开 C:\ProgramData\G11GuestLite\tools，双击 03-Rollback.cmd，看到 ROLLBACK PASS
后重启。它会先删除 Guest Lite 补强任务并逐字节恢复原 Registry.pol/gpt.ini，再恢复首次
Apply 前的策略/启动项、防火墙配置、电源方案、服务、任务，并尝试从保留的
WindowsApps 载荷重新注册原有 App。任一项失败时 state.json 会保留，修复原因后可
再次运行回滚。

命令行
------

  G11GuestLite.exe /apply      应用（双击默认动作）
  G11GuestLite.exe /audit      只审计；Apply 后会严格验证
  G11GuestLite.exe /rollback   恢复保存的原始基线

明确不会做
----------

- 不修改 BCD，不开启 testsigning 或 nointegritychecks；
- 不安装、替换、测试签名或自签名任何内核驱动；
- 不改 NVIDIA/vGPU、网卡、音频、打印和存储驱动；
- 不夺取 WinDefend/MpsSvc/TrustedInstaller 所有权，不删除防火墙规则；
- 不删除 WinSxS、System32、WindowsApps 或 Appx 预配载荷；
- 不停 BITS、CryptSvc、AppXSvc、ClipSVC，不删除 Edge/WebView2、计算器、照片、
  画图、记事本、DesktopAppInstaller、VCLibs/.NET/UI.Xaml 等常见软件依赖；
- 不猜测卸载第三方杀毒，不写入或索取宿主机/来宾机凭据。

重要限制
--------

- 仅支持 Windows 10 客户端，不支持 Windows 11/Server。
- 这是面向受控 VM 的激进配置：完成后没有内置杀毒、防火墙和自动安全更新。VM1
  验证无误并制作可恢复快照/母盘后，才能考虑给其他 G-11 VM 使用。
- 禁用 MpsSvc 后若网络或应用异常，在 VM1 本地双击
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

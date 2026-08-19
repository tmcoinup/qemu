G-11 Windows 10 Guest Lite（一键关闭杀毒、更新、商店并精简）
================================================================

当前版本：1.5。已兼容 Windows PowerShell 5.1 对泛型列表转数组的
旧版绑定行为，也兼容 Defender for Endpoint 状态键存在但可选的
OnboardingState 值不存在的正常情况；从受管只读 U 盘运行后，EXE 也会保存到
C:\ProgramData\G11GuestLite\tools，供重启后直接审计或回滚。1.5 兼容不提供
FileAttributeTagInfo 的 FAT 可移动盘，同时仍拒绝网络来源和重解析点。

只需这样做：

1. 先在 Windows 安全中心 -> 病毒和威胁防护 -> 管理设置，手工关闭“篡改防护”。
   如果没有这个开关，先运行 G11GuestLite.exe /audit；工具不会绕过篡改防护。
2. 双击 G11GuestLite.exe，UAC 选择“是”，安全警告选择 Yes。
   这是本机编译的未签名用户态 EXE；若 SmartScreen 出现，确认文件来自受管公共
   U 盘后选择“更多信息 -> 仍要运行”。封装不生成内容哈希；
   01-OneClick-Apply.cmd 是透明脚本回退入口。
3. 看到 APPLY PASS 后重启 Windows。
4. 重启后双击 02-Audit.cmd；报告在：
   C:\ProgramData\G11GuestLite\reports
   只有报告中 msMpEngRunning=False、winDefendState 不为 Running，且各 Defender
   Enabled 字段均为 False，才代表图中的 Antimalware Service Executable 已停。

需要恢复：

双击 C:\ProgramData\G11GuestLite\tools\03-Rollback.cmd，完成后重启。

EXE 命令行：

G11GuestLite.exe /apply      应用（双击默认动作）
G11GuestLite.exe /audit      审计/验证
G11GuestLite.exe /rollback   回滚

会做什么：

- 通过 Windows 策略和 Set-MpPreference 双通道停用 Microsoft Defender Antivirus；
- 立即取消当前 Defender 扫描，并在不能完全停用时把扫描平均 CPU 负载目标降到 5%；
- 重启后明确检查 MsMpEng.exe（Antimalware Service Executable）与 WinDefend；
- 停用 Windows Update、Update Orchestrator、Delivery Optimization；
- 停用并为当前用户移除 Microsoft Store；
- 移除当前用户的资讯、天气、Xbox、Phone Link、反馈中心、3D、纸牌等消费 App；
- 停用遥测、地图、零售演示、Xbox、电话、钱包等明确列出的可选服务和任务；
- 保存修改前的注册表、服务、任务和 App 清单，支持回滚。

明确不会做：

- 不修改 BCD，不开启 testsigning/nointegritychecks；
- 不安装、替换、测试签名或自签名任何内核驱动；
- 不改 Defender 服务 ACL，不删除 WinSxS、System32 或 WindowsApps 文件；
- 不以 Stop-Service/TrustedInstaller/内核手段强杀受保护的 WinDefend 服务；
- 不关闭 Windows 防火墙；
- 不碰 NVIDIA/vGPU、网络、音频、打印、搜索、BITS、加密、Edge/WebView2；
- 不写入或索取任何宿主机/来宾机凭据。
- 只处理 Windows 自带的 Microsoft Defender；不会猜测并卸载第三方杀毒软件。
- EXE 是普通 64 位用户态启动器，仅用 UAC 启动内置 PowerShell；不含或安装驱动。

重要限制：

- 仅支持 Windows 10 客户端；不支持 Windows 11/Windows Server。
- Defender for Endpoint 已接管的企业设备会拒绝执行。
- Windows 10 Pro/Home 对“关闭商店”策略支持不完整，所以工具还会移除当前用户的
  Store 注册，但保留系统预配副本供回滚。
- 精简后系统没有内置杀毒，也不会自动获得安全更新；只应在受控、可恢复的 VM 中使用。
- Windows 可能保护少数更新任务/服务。此时结果显示 APPLY PARTIAL，并在屏幕和报告中
  列出；工具不会夺取所有权或绕过保护。
- 新版 Defender 平台可能忽略旧的“总关闭”策略。若重启后 MsMpEng.exe 仍存在，
  02-Audit.cmd 会显示 VERIFY PARTIAL，不会把“只关实时扫描”误报成完全停用。
- 重启后 02-Audit.cmd 会给出 VERIFY PASS/PARTIAL；AUDIT PASS 只表示尚未 Apply 时
  成功生成了只读报告。

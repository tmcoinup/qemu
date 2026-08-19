# G-11 Windows 10 一键关闭杀毒、更新、商店与系统精简

这是放进 Windows guest、由登录用户主动运行的独立维护工具。它只加入当前
`G-11` 分支；没有把改动复制到独立的 `V-11` 分支。

## 傻瓜步骤

首选：在当前终端输入实际 VM 编号，再更新公共工具目录并把它直接挂成只读 U 盘：

```bash
read -r -p '请输入 VM 编号: ' VM_ID
./deploy/scripts/guest-lite.sh "$VM_ID" usb-mount
```

后续示例继续使用同一个 `VM_ID`；如果换了终端，先重新执行上面的输入命令。
脚本不依赖某个固定 VM，删除验收机不会影响公共包或其他 VM。

公共 U 盘根目录固定为 `/home/ubuntu/images/vms/shared/usb/`；每个工具只管理自己的
子目录，Guest Lite 固定在：

```text
/home/ubuntu/images/vms/shared/usb/G11GuestLite/
```

不使用内容哈希，不创建历史目录。Windows 中打开卷标 `U盘` 的可移动磁盘，
再进入 `G11GuestLite` 子目录。它是本机构建、未签名的普通 64 位 Windows 用户态
程序，内嵌同目录可审查的 PowerShell/CMD 源码；没有驱动，也不改 BCD 或驱动签名
策略。

若只生成公共目录而暂时不挂 U 盘：

```bash
./deploy/scripts/guest-lite.sh "$VM_ID" prepare
```

只读光驱仍作为兼容入口：

```bash
./deploy/scripts/guest-lite.sh "$VM_ID" mount
```

`mount` 是运行中热插入 `usb-bot + scsi-cd` 光驱，不会自动运行 Windows 工具。
如果该 VM 已插入另一张手动 ISO，命令会拒绝换盘；只有明确加 `--replace` 才换盘。

然后在 Windows 10 内：

1. 打开“Windows 安全中心 → 病毒和威胁防护 → 管理设置”，手工关闭
   “篡改防护”。工具不会也不能绕过这个保护。
2. 打开 `U盘\G11GuestLite`，双击 `G11GuestLite.exe`（光盘和独立
   EXE 的入口相同）。
3. UAC 选择“是”，安全警告选择 `Yes`，等待窗口显示 `APPLY PASS`。
   因为仓库没有代码签名私钥，SmartScreen 可能显示“Windows 已保护你的电脑”；确认
   文件来自受管公共 U 盘后，选择“更多信息 → 仍要运行”。若不信任 EXE，可直接审查
   同目录源码并运行 `01-OneClick-Apply.cmd`，功能相同。封装按要求不生成内容哈希。
4. 从 Windows 开始菜单选择“重启”。
5. 重启后，运行公共目录中的
   `C:\ProgramData\G11GuestLite\tools\02-Audit.cmd`；检查报告路径：

   ```text
   C:\ProgramData\G11GuestLite\reports
   ```

窗口还会直接显示 `VERIFY PASS` 或逐项列出 `VERIFY PARTIAL`，不要求用户自己猜十六
进制安全中心状态。尚未执行 Apply 时，`AUDIT PASS` 只表示只读报告生成成功。

EXE 参数为：

```text
G11GuestLite.exe /apply       # 应用；双击时的默认动作
G11GuestLite.exe /audit       # 只审计，或重启后验证
G11GuestLite.exe /rollback    # 恢复首次 Apply 前保存的状态
```

Apply 成功或部分成功后，EXE 和透明脚本入口会保存在
`C:\ProgramData\G11GuestLite\tools`，以后不需要再次挂 U 盘或光驱。

若窗口顶部显示 `Guest Lite 1.1`，并报
`Property OnboardingState does not exist`，或顶部显示 `1.2` 并报
`Argument types do not match`，运行的都是旧包。两个错误都发生在 Apply 的
首次审计阶段，服务、任务、Defender 和 App 尚未开始修改；重新执行 `usb-mount`，
再从 `U盘\G11GuestLite` 运行顶部显示 `1.5` 的 `G11GuestLite.exe` 即可。
不要继续运行复制到桌面的旧包。

`1.3` 从 U 盘执行 Apply 后可能提示 `the EXE could not be copied`；`1.4` 已允许
可移动盘来源，但部分 FAT 可移动盘不提供它使用的句柄属性查询，仍会出现同一提示。
Apply、脚本回滚和报告都有效，但重启后没有本地 EXE。`1.5` 对受管 FAT/ISO 介质
使用文件属性校验，把当前 EXE 保存到受保护的本地工具目录，同时仍拒绝网络路径和
重解析点来源。

若显示 `APPLY PARTIAL`，不是整包失败：Windows 拒绝了屏幕上列出的某个受保护
服务或任务。原始状态已经保存，可以先重启并审计，也可以直接回滚。工具不会为了
追求全绿而夺取系统服务/任务所有权。

完成后宿主可弹出公共 U 盘：

```bash
./deploy/scripts/guest-lite.sh "$VM_ID" usb-eject
```

如果使用的是兼容光驱，则执行：

```bash
./deploy/scripts/guest-lite.sh "$VM_ID" eject
```

公共 U 盘、任意 host 目录挂载和刷新限制见
[G11-USB-DIRECTORY.md](G11-USB-DIRECTORY.md)。

## 一键预设会做什么

- 通过 Windows Defender ADMX 对应策略停用 Defender Antivirus 的实时、行为、
  下载文件和云端样本保护，并停用其四个内置计划任务；同时调用
  `Set-MpPreference` 立即关闭实时/行为/IOAV/脚本扫描，取消当前按需扫描；若平台
  仍保留引擎，则把扫描平均 CPU 负载目标设为 5%；不删除 Defender 文件；
- 用 Windows Update 策略停用自动更新及其 UI/公网连接，停用 `wuauserv`、
  `UsoSvc`、`DoSvc` 和已知更新任务；保留 BITS 与加密服务；
- 停用 Store 策略、`InstallService`、`PushToInstall`，并移除当前用户的
  `Microsoft.WindowsStore`/`StorePurchaseApp` 注册；
- 移除当前用户的资讯、天气、反馈中心、Phone Link、Xbox、3D、纸牌、音乐、视频、
  地图、Cortana、Teams/Spotify/常见广告预装 App；
- 停用遥测、地图、零售演示、Fax、定位、电话、Insider、钱包、Xbox、错误报告、
  Remote Registry 等明确列出的可选服务和遥测任务；
- 关闭消费内容静默安装、建议、广告 ID、Web 搜索建议、Cortana 和 Game DVR。

App 只对执行工具的当前用户卸载。工具有意不调用
`Remove-AppxProvisionedPackage`，因此预配包仍留在系统中，回滚可以从安全的
`C:\Program Files\WindowsApps` 清单重新注册。这样不如离线删镜像节省磁盘多，
但不容易把 Store 和 UWP 依赖永久做坏。

## 保留项

下列内容不会被精简：

- BCD、启动完整性、`testsigning`、`nointegritychecks`；
- 任何内核、NVIDIA、GRID/vGPU 驱动以及驱动签名设置；
- Windows 防火墙、网络、音频、打印、Windows Search、BITS、CryptSvc；
- AppXSvc/ClipSVC、Edge/WebView2、桌面应用安装器、计算器、照片、画图、记事本；
- VCLibs、.NET Native、UI.Xaml 等 Appx 框架依赖；
- 宿主机配置与凭据。

EXE 只是带 `requireAdministrator` UAC 清单的启动器：它把内嵌、固定名称的资源解压
到仅 `Administrators`/`SYSTEM` 可访问的本地临时目录，使用固定的
`System32\WindowsPowerShell\v1.0\powershell.exe` 路径执行，结束后删除临时目录。
它不是安装器，不包含服务、内核组件、测试签名或自签名驱动。

工具只处理 Windows 自带的 Microsoft Defender。若 guest 另外安装了第三方杀毒，
审计报告会列出它，但不会按模糊名称静默卸载第三方软件。

任务管理器中的 `Antimalware Service Executable` 就是 `MsMpEng.exe`，由受保护的
`WinDefend` 服务承载。Apply 后必须重启；`02-Audit.cmd` 会明确检查：

```text
msMpEngRunning=False
winDefendState=<非 Running>
amServiceEnabled=False
realtimeEnabled=False
```

只要其中任一仍启用，就返回 `VERIFY PARTIAL`。Windows 将反恶意软件服务作为受保护
进程运行，普通管理员也不能可靠地停止或改变其启动类型；本工具不会夺取服务 ACL、
冒用 TrustedInstaller、改内核驱动或通过 BCD 绕过保护。这样可能无法让所有新版
Defender 平台上的进程彻底消失，但不会把“设置了注册表”误报成“已经停用”。

`G11GuestPerformance` 与本工具都包含 Game DVR 设置。若两个工具都用，建议先运行
性能优化，再运行本精简工具；需要恢复时按相反顺序，先回滚本工具，再回滚性能工具。

## 回滚

在 Windows 内双击：

```text
C:\ProgramData\G11GuestLite\tools\03-Rollback.cmd
```

回滚会恢复首次 Apply 前的精确注册表值、服务启动/运行状态、任务启用状态，并尝试
重新注册被本工具移除的当前用户 App。显示 `ROLLBACK PASS` 后重启。

若 App 的预配文件后来被其他维护工具或系统升级删除，会显示 `ROLLBACK PARTIAL`，
状态文件会保留以便重试；本工具不会从互联网下载来源不明的 Appx 包。

## 使用边界

- 只支持 Windows 10 客户端，不在 Windows 11/Windows Server 上执行；
- 若 Defender for Endpoint 已接管设备，工具拒绝与企业管理策略对抗；
- Windows 10 Home/Pro 不完整支持“关闭 Store”策略，所以当前用户 Store 还会被移除；
- 关闭 Defender 和更新后，guest 没有内置恶意软件防护，也不会自动收到安全修复。
  仅应用于受控网络、可从快照/基础镜像恢复的 VM；
- Windows 10 已结束普通支持，策略和平台版本不同可能令某些 Defender 设置被忽略。
  `02-Audit.cmd` 的结果比“脚本运行过”更重要。

微软说明：Windows 10 1903 以后篡改防护会阻止本地 Defender 变更；平台
4.18.2108.4 及以后会在相应客户端上忽略旧 `DisableAntiSpyware`/`DisableAntivirus`
总开关。工具因此同时使用细粒度策略和 `Set-MpPreference`、检查篡改防护/MDE
状态，并要求重启后审计，而不宣称能绕过受保护服务。

参考：

- [Microsoft Defender Antivirus 策略和篡改防护](https://learn.microsoft.com/windows/client-management/mdm/policy-csp-admx-microsoftdefenderantivirus)
- [DisableAntiSpyware 的版本限制](https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/security-malware-windows-defender-disableantispyware)
- [反恶意软件受保护服务限制](https://learn.microsoft.com/windows/win32/services/protecting-anti-malware-services-)
- [Set-MpPreference 参数](https://learn.microsoft.com/powershell/module/defender/set-mppreference)
- [Windows Update 策略](https://learn.microsoft.com/windows/deployment/update/waas-wu-settings)
- [关闭 Microsoft Store 的受支持策略](https://learn.microsoft.com/windows/configuration/store/)
- [Appx 当前用户卸载与预配包区别](https://learn.microsoft.com/windows-hardware/manufacture/desktop/sideload-apps-with-dism-s14)

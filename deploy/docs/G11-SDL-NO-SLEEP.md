# G-11 SDL 空闲不黑屏傻瓜教程

G-11 的“无操作后黑屏”分成两层：Linux 宿主的屏保/DPMS，以及 Windows guest 的
显示器超时/自动睡眠。SDL 默认处理宿主层；Guest Lite、新版 VgpuPortable 和旧
guest-performance 维护入口以可回滚方式处理 Windows 层。两层都不改 BCD，不开启
`testsigning`/`nointegritychecks`，也不
安装任何测试签名或自签名内核驱动。改动只在 G-11 分支；不要当作 V-11 发布物。

## 已封装的默认行为

使用标准入口启动 SDL，不需要额外参数：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/start-vm.sh 9 --sdl
```

把 `9` 换成实际 VM 编号。启动日志必须出现：

```text
[start-vm] SDL 宿主防息屏已启用：窗口空闲不会触发宿主屏保/显示器休眠
```

此后只要该 QEMU SDL 进程仍在运行，SDL 会向桌面会话申请阻止屏保/空闲息屏。
GNOME、KDE 和常见 X11/XWayland 会话通常会遵守该申请；独立 DPMS 工具、显示器自身
定时器或桌面策略仍可能覆盖它，所以必须完成下面的实机等待验收。QEMU 正常退出时会
恢复宿主自动息屏资格，不会永久修改 GNOME/KDE 设置。

## 第一次使用：一键构建与检查

在宿主机终端整段复制：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/build-qemu.sh
bash deploy/tests/qemu/test_sdl_no_sleep_static.sh
```

看到下面成功信息后，关闭旧 QEMU 进程，再从标准入口重新启动 VM：

```text
OK: SDL host-display no-sleep static checks passed
```

只重建但继续观察已经运行的旧 QEMU 进程不会生效。

## 傻瓜式实机验收

1. 用上面的 `start-vm.sh` 启动 VM，并确认日志显示“SDL 宿主防息屏已启用”。
2. 保持 SDL 窗口可见，不碰键盘和鼠标，等待超过宿主原来的自动息屏时间。
3. 物理显示器应持续点亮，SDL 中最后一帧应保持可见。
4. 正常关闭 VM，再按宿主原来的自动息屏时间等待；宿主应重新可以自动息屏。

“整台宿主显示器变黑”属于本功能处理范围。如果宿主桌面和其他窗口仍然可见，
只有 Windows 画面在 SDL 客户区内变黑，则通常是 Guest 自己关闭显示输出或 GPU
scanout 异常。先按下一节处理 guest 电源策略；仍复现再查 QEMU/GPU 日志。

## Windows guest 也设为不自动黑屏/睡眠

新版 `VgpuPortable.exe` 已封装这一步；日常只需在 Windows 内双击它并让 UAC 通过。
旧包维护入口则双击：

```text
02-Apply-Recommended.cmd
```

它把**每个已安装电源计划**的 `VIDEOIDLE` 和 `STANDBYIDLE` AC/DC 值设为 0（从不
自动关闭显示器、从不因空闲自动睡眠），用户主动关机/睡眠仍可使用。

覆盖全部计划而不只是“高性能”是有意为之：只设活动计划的话，任何把计划切回
“平衡”的操作（Windows 更新、驱动安装、厂商调优工具）都会让空闲黑屏重新生效。
而 guest 一旦停止刷新显示输出，fb-shm 仍会按配置帧率重复发布同一帧，消费端因此
看到「帧率正常但画面冻结」——依赖画面做识别的消费端还会把那张旧图当成实时状态。
QEMU 侧的 `keepalive`（默认开启）是同一问题的兜底，两者互不替代。

原值按计划分别保存在：

```text
C:\ProgramData\G11GuestPerformance\state.json
```

要完整回退，双击：

```text
C:\ProgramData\G11GuestPerformance\tools\04-Rollback.cmd
```

应用后用 `03-Verify.cmd` 检查；详细步骤见
[G11-GUEST-PERFORMANCE.md](G11-GUEST-PERFORMANCE.md)。

Guest Lite 2.6.7 也执行同一合同，并把基线保存到：

```text
C:\ProgramData\G11GuestLite\state.json
```

旧 Guest Lite 只记录过高性能计划时，新版保留这些行的真实原值，只追加尚未记录的
计划/设置组合，不会把工具已经写入的 0 重新采样成原值。

这里不根据“平衡/高性能/节能”文字判断：工具解析本机
`powercfg /List` 输出中与语言无关的 GUID，所以 OEM 自定义计划和其他系统语言也
走同一逻辑。计划注册表不存在 `ACSettingIndex`/`DCSettingIndex` 时只代表“继承
默认值”，并非不支持该设置。回滚会恢复原有显式值，或删除工具新增值以
恢复继承。

## 补出 Windows“睡眠”页面并保留手动 S3

超时设置只能决定“多久后睡眠”，不能创造 Windows 没枚举到的睡眠能力。截图中页面
只有“屏幕”是因为旧 VM 启动参数把 q35/ICH9 的 ACPI S3 隐藏了。当前 G-11
`start-vm.sh` 已暴露 S3；这项 ACPI 能力必须在 QEMU 新进程启动时生成。

傻瓜验收：

1. 先在 Windows 内正常“关机”，不要点重启、睡眠或休眠。
2. 宿主确认 `./deploy/scripts/vmctl.sh status 1` 显示 `VM_STATUS=stopped`。
3. 执行 `./deploy/scripts/vmctl.sh start 1`，登录后打开“设置 → 系统 → 电源和睡眠”。
4. 页面应同时有“屏幕”和“睡眠”，所有下拉框都是“从不”；`powercfg /a` 应列出
   待机 (S3)。休眠/Fast Startup 仍关闭。
5. 保存工作后可只在 VM1 主动试一次“睡眠”；本地键鼠没能恢复时，宿主执行：

   ```bash
   ./deploy/scripts/vmctl.sh wake 1
   ```

S3 是运行态暂停，不是干净关机。驱动安装、母盘封装和宿主离线读写 Windows 磁盘时
仍必须完整关机。Guest Lite 不结束 `SystemSettings.exe`/`ApplicationFrameHost.exe`；
若“设置”窗口本身崩溃，应查 Windows 应用程序事件日志，而不是继续修改电源超时。

## “设置”窗口为什么会自动关闭

已在 VM1 定位为旧版 Guest Lite 禁用 `CDPSvc` 所引起的 Windows Settings
兼容性崩溃，不是 DGame 关窗、VM 睡眠、QEMU/SDL 关窗，也不是进程白名单杀掉
`SystemSettings.exe`。故障会在“设置 → 系统”已经显示后延迟发生，因此看起来像是
页面自己关闭；直接启动 `ms-settings:powersleep` 没有经过完全相同的导航/初始化路径，
所以可能暂时不复现。

证据链为：

- 每次自动退出都生成 `Application Error / 1000`：
  `SystemSettings.exe 10.0.19041.6456`、`msvcrt.dll 7.0.19041.3636`、
  `0x40000015`、偏移 `0xae22`；
- 为 `SystemSettings.exe` 启用临时 LocalDumps 后，连续捕获了三份完整用户态转储；
- VM1 的旧 `state.json` 记录 `CDPSvc` 真实原值为
  `Auto + DelayedAutoStart=1 + Running`，当前却被旧工具改为
  `Disabled + Stopped`；
- 只按该原始快照恢复 `CDPSvc` 后，从 Win+I 首页依次进入“系统 → 显示 →
  电源和睡眠”，窗口连续保持 4 分钟以上，无新崩溃事件和转储。

这是同一台 VM、同一导航路径的单变量 A/B，因果已经确认。

只读复核（管理员 PowerShell）：

```powershell
$since = (Get-Date).AddMinutes(-30)
Get-WinEvent -FilterHashtable @{ LogName='Application'; Id=1000; StartTime=$since } |
  Where-Object { $_.Message -match 'SystemSettings\.exe' } |
  Select-Object TimeCreated, Id, ProviderName, Message |
  Format-List
```

通用修复不会在所有机器上写死一个 `CDPSvc` 启动类型。2.6.7 将它从活跃禁用
清单退役：旧安装升级时，只使用已有 `state.json` 中的原始快照恢复；新安装没有
该快照时保持 Windows、OEM 或用户原状。所以修复方式是保留 `state.json` 并重施 Guest Lite
2.6.7，不是删状态文件或手工批量改服务。`NcbService` 也没有被 Guest Lite 禁用。

测试中的 `ORIGINAL high-perf value was overwritten -- rollback would be destroyed`
只是宿主负向断言：故意破坏电源基线合并函数时应当失败。它不会进入 VM，
与 Settings 崩溃无关。LocalDumps 仅为本次诊断临时启用，配置见
[MS-ERREF NTSTATUS](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-erref/596a1078-e883-4972-9bbc-49e60bebca55)
和 [Collecting User-Mode Dumps](https://learn.microsoft.com/en-us/windows/win32/wer/collecting-user-mode-dumps)。

## 确实需要宿主自动息屏时

例如笔记本使用电池时，可只对本次启动恢复上游 QEMU 行为：

```bash
cd /home/ubuntu/projects/qemu
QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP=1 \
  ./deploy/scripts/start-vm.sh 9 --sdl
```

日志会明确显示：

```text
[start-vm] SDL 允许宿主自动息屏（显式兼容模式）
```

要重新启用默认防息屏，去掉该环境变量即可；不需要运行 `gsettings`、`xset`、
`systemd-inhibit` 或任何 root 命令。宿主凭据不会被读取或写入仓库。

## 仍然黑屏时

先确认运行的是本次构建的二进制：

```bash
readlink -f build/qemu-system-x86_64
pgrep -af qemu-system-x86_64
```

然后记录以下信息再排查：宿主桌面环境、`XDG_SESSION_TYPE`、是否整台显示器都黑、
黑屏前等待时间、启动日志中的防息屏状态，以及 Guest 按键后能否恢复。不要通过
修改 BCD、开启测试签名或安装自签名驱动来解决宿主 SDL 息屏问题。

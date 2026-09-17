# G-11：DNF 消失、Windows 自动重启的傻瓜诊断

先区分游戏进程退出和整台 Windows 重启。不能只看宿主 SDL 窗口仍在，就认定是
DNF.exe 自身闪退：Windows 可以在同一个 QEMU 进程内重新启动。

## 本次 VM2 的已知事实（2026-09-16 宿主时间）

- 用户描述为挂机/空闲时退出，并确认没有手动重启或点重置。
- Windows 最近一次启动是北京时间 **2026-09-17 06:03:54.500**，对应宿主
  America/Los_Angeles 时间 **2026-09-16 15:03:54.500**。
- 同次启动留下 `Kernel-Power / 41` 和 `EventLog / 6008`，没有与本次重启对应的
  `User32 / 1074` 正常关机发起记录；`BugcheckCode=0`、`SleepInProgress=0`、
  `PowerButtonTimestamp=0`。Windows 已配置小型系统转储，但没有找到转储文件。
- QEMU 进程仍是宿主 03:06 左右启动的进程；宿主内核日志没有发现对应的 NVIDIA
  Xid、OOM 杀进程或磁盘 I/O 错误。vGPU 使用正式 GRID 538.33，授权为 Licensed。
- 最近 24 小时未找到 DNF 的 Application Error 1000、WER 或现有用户态转储。
  Windows WER 服务和上传策略处于禁用状态，不能把没有报告当作没有故障。
- 重启后采样为 8 GiB RAM、约 7.25 GiB 系统管理分页文件、2 GiB vGPU。
  这些是重启后的值，不能证明退出时内存或显存足够。

结论：已确认无人操作时 Windows 发生非正常重启，足以解释运行中的 DNF 消失。
**尚未确认触发重启的底层原因**，也不能排除更早发生过独立的游戏退出。
事件 6008 文本中的上次关闭时间是 Windows 的记录，不能代替精确的崩溃时刻。
没有证据支持将本次归因为 SDL 刷新率、显存不足、Windows 更新或某个特定驱动。

## 1. 一条命令开始宿主观察

在宿主终端执行：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/game-diagnostics.sh 2 watch
```

开头显示 `REPORT=/tmp/g11-exit-vm2-.../lifecycle.jsonl`，记下路径。保持终端打开，
按平常方式运行游戏或挂机。默认观察 24 小时；按 Ctrl+C 只停止记录，不停止 VM。
更换 VM 时把 `2` 改为编号。运行中 VM 通过唯一 QEMU 进程及 QMP 名称/实际 socket
进程识别，不依赖磁盘默认路径。包内使用 `/opt/gmate/deploy/g11/scripts/` 对应入口。

需要自定时长或保存路径时：

```bash
./deploy/scripts/game-diagnostics.sh 2 watch --seconds 7200 --output /tmp/vm2-new-session.jsonl
```

文件必须不存在。观察器只发送 QMP 能力握手、查询 VM 名称、每 30 秒查询运行状态，
并记录 RESET、SHUTDOWN、STOP、RESUME、睡眠/唤醒、panic、watchdog、I/O 和内存
错误事件。它不会发按键、复位、关机或修改参数。QMP 断开/身份变化即退出并标记
覆盖中断，不自动连接另一个进程；重新开机后须重新执行。

观察从启动命令那一刻开始，**不能补出过去的 RESET**。QMP 的 `guest-reset` 或
`host-qmp-system-reset` 等 reason 可以缩小范围，但不一定能指认驱动或发起进程。
`GUEST_PANICKED` 依赖虚拟机已有的通知能力；没有这个事件不能排除蓝屏。
这里只看 VM 生命周期，不能独立检测 DNF 进程退出，也不承诺修复或提高 FPS。

## 2. 双击采集 Windows 证据

在另一个宿主终端执行：

```bash
./deploy/scripts/game-diagnostics.sh 2 usb-mount
```

然后在 **vm2 的 Windows**：

1. 打开“此电脑”，进入卷标 `G11EXIT` 的 U 盘。
2. 双击 `01-Audit.cmd`，等待显示 `Saved`。
3. 打开桌面新建的 `G11-GameExit-日期-编号` 文件夹，先看 `summary.txt`。
4. 私下保留 `summary.txt`、`report.json` 和宿主 `lifecycle.jsonl`，记录消失时刻。
   若有 WARNING，保留原文；权限不足或达到采集上限不能解释成“没有错误”。

该 U 盘是只读目录映射，无须下载或安装 Windows 驱动。不联网，不采集密码、
游戏进程内存或转储内容。事件原文可能含本机路径、机器名、账户名，请勿公开上传。
如已有其它目录 U 盘，默认拒绝替换；确认不用旧盘后才加 `--replace`。
自定义 VM 目录可追加 `--vm-dir /绝对路径/2` 或 `--vms-dir /绝对路径`。

使用完后：

```bash
./deploy/scripts/game-diagnostics.sh 2 eject
```

没有系统设置需要回滚。关闭采集窗口和宿主观察器即可；报告在看完后可以自行删除。
不修改 BCD、testsigning/nointegritychecks、驱动、分页文件、电源或错误报告服务。

## 3. 怎样决定下一步优化

| 证据 | 下一步 |
|---|---|
| Windows 41/6008 + QMP RESET | 对齐 reason、宿主内核日志和蓝屏转储，查整机重置来源 |
| Windows 1074 | 查事件里记录的发起程序和原因，再处理对应任务 |
| DNF 1000/1001，Windows 未重启 | 按故障模块和异常码查应用崩溃，必要时用官方方式采集用户态转储 |
| 2004 资源耗尽或退出前提交量接近上限 | 再评估 RAM/分页文件及持续增长的进程；重启后空闲值不能代替峰值 |
| Display 4101 或宿主 NVIDIA Xid | 再查显卡复位、vGPU 驱动/配置和 GPU 状态 |
| 没有匹配事件 | 保留未定结论，结合游戏自身日志和退出前采样，不凭空更换驱动或扩大显存 |

解释依据：[Microsoft 事件 41 排查](https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/event-id-41-restart)、
[应用崩溃事件排查](https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-application-service-crashing-behavior)。
事件 41 本身不足以确定根因；代码为零也不能排除未成功写入转储的系统崩溃。

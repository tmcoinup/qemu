# G-11 Windows 启动与刚进桌面卡顿优化

本页处理的是 Windows guest 已经出现登录界面以后，桌面迟迟不稳定、开机启动软件
很晚才弹出，以及刚登录的一段时间鼠标/窗口明显发卡。它不把宿主脚本启动 QEMU 前
的几秒与 Windows 自己的启动阶段混在一起。

## 这台 VM 为什么像“又慢回去了”

vm8 本次宿主准备在 QEMU launch 前约为 7.8 秒；vGPU driver 很快接管，但从 driver
接管到 1920×1080 桌面稳定仍有约 94 秒。仓库历史 guest 安装链路会留下以下组件：

- `NvDisplayContainer` 启动 `NvStreamSvc`/`AudioSvcHost` 抓取桌面；native SDL/GTK
  已直接读取 vGPU console，不再需要这套 guest relay；
- `HideRdpIdd` 在启动和登录后每 2 秒枚举一次 PnP，最长约 30 秒；
- `PurgeRdpGhosts` 在启动、登录和 RDP 会话事件时枚举显示设备；
- 旧 `StealthMonitor-Refresh*` 在启动/登录后再次写显示器缓存，而当前 G-11 已在
  VM 关闭时由宿主离线同步 EDID；
- Explorer 默认会有意延后普通启动项，因此桌面出现不等于启动软件立即放行。

这些工作会与 DWM、NVIDIA 初始化和用户启动项争用 4 个 vCPU，现象正是“进桌面后
先卡一阵，软件过很久才出现”。优化器只处理能核实为本仓库旧链路的精确名称和
执行路径；同名但路径不符的服务或任务只报警，不修改。

## 傻瓜步骤（只记一个 EXE）

新版性能优化已经封装进通用 `VgpuPortable.exe`。Windows 中不再依次运行 Audit 和
Apply：

1. 双击公共桌面的 `VgpuPortable.exe`，UAC 点“是”。
2. 等它自动完成显卡身份/授权和推荐性能优化，最终显示 `INSTALL PASS`。
3. 从 Windows 开始菜单选择“关机”，不要睡眠或休眠。
4. 宿主重新启动（vm8 示例）：

   ```bash
   ./deploy/scripts/start-vm.sh 8 --proxy
   ```

日常到这里结束。`01-Audit.cmd`、`02-Apply-Recommended.cmd` 和
`guest-performance.sh` 仅保留给旧 EXE/故障诊断，不是新 VM 的操作步骤。新版 EXE
会把 Verify、Rollback 等维护工具自动保存到
`C:\ProgramData\G11GuestPerformance\tools`；只有排障或回滚时才需要它们。

service CPU 继续使用产品默认值 `0`，不会自动额外占用逻辑 CPU。只有需要单独做
A/B 时才显式传 `--svc-cpus N`；本优化流程不添加该参数。

仍持有旧版 `VgpuPortable.exe`、又暂时无法替换时，才使用兼容维护包：

```bash
./deploy/scripts/guest-performance.sh 8 mount
```

在光驱内直接运行 `02-Apply-Recommended.cmd`；`01-Audit.cmd` 是可选只读诊断，不是
必经步骤。看到 `APPLY PASS` 后完整关机。新建 VM 不走这条兼容路径。

## 推荐项会修改什么

- 禁用但不删除已核实归属的旧 relay/RDP/在线显示器任务；
- 停止并禁用自定义 `NvDisplayContainer`、旧 `AudioDeviceGraphHost` 及其 relay
  进程；
- 将 `StartupDelayInMSec` 设为 0，让 Explorer 立即放行普通启动项；
- 选择 Windows 内置“高性能”电源计划（存在时），关闭 VM 内前台任务节流；
- 将该计划的显示器空闲超时和系统自动睡眠（AC/DC）设为“从不”，避免 guest
  无操作后自己黑屏；用户主动睡眠/关机仍然可用；
- 关闭透明效果、任务栏动画和重复的 guest Game DVR；G-11 的 host DGame/QEMU
  画面不受影响。

脚本会先保存注册表原值、电源计划、该计划的 AC/DC 超时原值、服务状态和每个任务的
启用状态。状态与报告在：

```text
C:\ProgramData\G11GuestPerformance\state.json
C:\ProgramData\G11GuestPerformance\reports
```

## 明确不做的事情

优化器不修改 BCD，不开启 `testsigning`/`nointegritychecks`，不安装、替换或签名
任何内核驱动，不碰正式 GRID driver 和官方
`NVDisplay.ContainerLocalSystem`。它也不关闭 Defender、Windows Update、SysMain、
Windows Search 或分页文件，不保存或索取宿主/guest 凭据。

当前系统身份投影所创建的 `G11-System-NVAPI-*`、`G11-Monitor-Identity-*`，以及
合法 portable 的 `RefreshGridNames` 不属于本优化器的停用范围。

## 回滚与旧显示模式

若效果不满意，在 Windows 双击：

```text
C:\ProgramData\G11GuestPerformance\tools\04-Rollback.cmd
```

它按保存的原状态恢复，不猜测默认值。若以后要使用 `--legacy-shmem` 或 `--rdp`，
必须先回滚，因为旧模式需要 guest relay；默认、`--sdl`、`--gtk`、`--vgpu-sdl`
和 `--vgpu-gtk` 才适用本优化。

若 Verify 仍报告慢启动，把 `reports` 中最新的 `before-apply` 与 `verify` 文本复制出来。
报告包含 Windows Diagnostics-Performance 事件、启动项和 3 秒进程 CPU 排名，可据此
继续处理具体第三方启动软件，而不靠批量关服务碰运气。

## 是否关闭 CPU 隔离

默认保持 `CPU_ISOLATION=required` 和 `svc-cpus=0`。当前实现中，非 vCPU 的 QEMU
线程会被限制在同一个 4-CPU cpuset；关闭隔离后它们能借用更多宿主 CPU，因此某次
启动突发可能更短，但 vCPU 也会迁核并与宿主桌面争用，运行时帧时间未必更好。
隔离会保持 guest 2C4T 到 host 2C4T 的 core/SMT 对应；8 台相同 VM 使用
16C32T，22C44T host 仍留下 6C12T。service CPU 默认 0，不额外占用这部分余量。

guest 优化并完成一次正常冷启动后，仍觉得慢才做一次性 A/B：

```bash
# A：正式默认
./deploy/scripts/start-vm.sh 8 --proxy

# Windows 正常关机后再测 B；不写入默认配置
./deploy/scripts/start-vm.sh 8 --proxy --no-cpu-isolate
```

两次都从完整关机开始，比较进入桌面、启动软件全部出现的时间和 SDL FPS/卡顿。
不要同时改 `svc-cpus`，否则无法判断差异来自哪一项。若 B 只快几秒但窗口更抖，
继续使用默认隔离；只有重复冷启动都明显更快且运行同样稳定，才考虑手工指定。

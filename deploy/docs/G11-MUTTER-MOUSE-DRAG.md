# G-11 GNOME/Mutter 实体鼠标拖动卡顿

这页处理一个宿主合成器问题：在 Ubuntu 24.04 GNOME Wayland 中，用高回报率
实体鼠标操作大型 SDL/XWayland 窗口时，画面可能在 16ms/33ms 之间跳动，看起来
“一卡一卡”。它不修改 Windows、BCD、QEMU vGPU 驱动或 Guest 内核驱动。

## 当前机器已经核实的链路

VM3 不是原生 Wayland 窗口，实际链路是：

```text
Logitech G502（实测约 997Hz）
  -> libinput / GNOME Shell 46
  -> Mutter 46.2 Wayland compositor
  -> XWayland 23.2.6
  -> SDL2 X11 + 1920x1080 EGL child window
  -> QEMU VM3
```

宿主输出是 RX 580 的 `2560x1440 @ 59.91Hz`。当前 Mutter 的独立
`KMS thread` 使用 `SCHED_RR`、实时优先级 20。也就是说，实体鼠标每个显示刷新
大约产生 16 次事件；自动化拖动若只合成约 60 次/秒，就可能看起来正常，不能代替
997Hz 实体鼠标验收。

Ubuntu 的公开问题
[`#2087879`](https://bugs.launchpad.net/bugs/2087879)记录了同一类组合：
Ubuntu 24.04、GNOME Wayland、AMD 显示 GPU、移动鼠标时 vsync 画面从 60 FPS
下降并出现 16/33ms 锯齿。该问题给出的 workaround 是在启动 GNOME Shell 前设置：

```text
MUTTER_DEBUG_KMS_THREAD_TYPE=user
```

本机安装的 Mutter 已包含 Ubuntu `#2080698` 的“拖动窗口不再让整个 framebuffer
全损伤”补丁，因此不能把问题简单归因于缺少该补丁。这里的受控 A/B 专门检查
高频鼠标与实时 KMS thread 的组合。

## 换电脑是否要再运行

`/etc/environment` 是每台宿主机自己的配置，不会跟着 VM 或 qcow2 复制到新电脑。
因此，换宿主机后要重新检测，但不是每次启动 VM 都要重复执行 `enable`：

- 当前用户运行的是 GNOME Shell Wayland，且独立 `KMS thread` 确实使用
  `SCHED_FIFO`/`SCHED_RR` 和正实时优先级时，才建议启用。
- GNOME Xorg、非 GNOME 桌面、没有独立实时 KMS thread 的新实现都不建议自动改。
- 高回报率鼠标会放大问题，但普通用户无法稳定、无特权地测准所有设备的
  实际 polling rate，因此它不是启用建议的硬门禁。
- 配置已生效后，重启 VM、客机或 VMate 都不需要重写；只需要在系统升级或
  更换桌面环境后重新检测。

## VMate 机器状态接口

产品集成应使用不需要 sudo 的 JSON 状态，不要解析面向人的中文输出：

```bash
./deploy/host/g11-mutter-kms-thread.sh status --json
```

输出是单行、固定 schema，例如：

```json
{"schema":1,"config":"absent","session_type":"wayland","session_mode":"unset","kms_thread":"realtime","recommendation":"enable","managed":false,"relogin_required":false}
```

`schema` 是数字 `1`，且 JSON 只有上述八个字段，不存在兼容的第二套协议。
`config` 只会是 `absent` / `managed-user` / `unmanaged` / `invalid`；
`session_type` 只会是 `wayland` / `x11` / `unknown` / `absent`；
`session_mode` 只会是 `user` / `kernel` / `unset` / `other` / `absent` /
`unknown`；`kms_thread` 只会是 `realtime` / `normal` / `absent` / `unknown`。
不输出 PID、TID、文件路径、桌面自由文本或任何原始环境变量值。

VMate 应按 `recommendation` 处理：

| 值 | 含义 | 可否自动弹出修复 |
|---|---|---|
| `ready` | `user` 已在当前 GNOME Wayland 会话生效，独立 KMS thread 已消失 | 否 |
| `enable` | GNOME Wayland 上确认了 FIFO/RR 实时 KMS thread，且没有已有赋值 | 是，但必须由用户点击并授权 |
| `relogin` | 启用或回滚后，磁盘配置和当前 Shell 仍不一致 | 否；提示保存工作、关闭 VM 并注销再登录 |
| `not-applicable` | 没有 GNOME Shell、Xorg、非实时 KMS thread 或已无这条调度链 | 否 |
| `conflict` | 存在管理员自己的赋值，或 G11 marker 块损坏 | 否；不能覆盖或删除 |
| `unknown` | 存在 GNOME Shell 候选，但会话或调度关键信息不可读/不完整 | 否；只给人工检查提示 |

`managed` 表示配置块由本 helper 管理；`relogin_required` 表示是否必须新建登录会话。
鼠标回报率不在 JSON 协议中，也不参与 `enable` 的硬门禁。

`status --json` 对可报告的 `conflict` / `unknown` 仍返回有效 JSON；只有参数错误、
不安全文件类型或无法读取目标这类接口本身错误才以非零状态退出。

## 傻瓜式启用

先只查看，不改任何设置：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/g11-mutter-kms-thread.sh status
```

确认输出显示当前是默认 `kernel`/独立 KMS thread 后，显式启用：

```bash
sudo ./deploy/host/g11-mutter-kms-thread.sh enable
./deploy/host/g11-mutter-kms-thread.sh status
```

第二次 `status` 在当前登录会话中应明确提示“文件已写入，但当前会话尚未生效”。
这是正常的：Mutter 只在 GNOME Shell 启动时读取该变量。

接下来：

1. 正常关闭 VM，确认 Windows 已完全关机。
2. 保存宿主其他程序的工作。
3. 从 GNOME 菜单注销当前用户，再重新登录；不需要重启宿主机。
4. 重新启动 VM3，再运行 `status`。
5. 只用实体 G502 在 SDL 中重复相同的移动和拖动，不用自动化结果代替。

生效后应看到：

```text
当前 gnome-shell：... 环境=user（workaround 已在本会话生效）
当前未发现独立 KMS thread
```

脚本不会自动注销、重启 GNOME Shell、重启宿主机或停止 VM，也不会保存 sudo
密码。`enable` 只原子加入以下唯一受管块：

```text
# BEGIN G11 MANAGED MUTTER KMS THREAD
MUTTER_DEBUG_KMS_THREAD_TYPE=user
# END G11 MANAGED MUTTER KMS THREAD
```

若 `/etc/environment` 已有不带上述 marker 的
`MUTTER_DEBUG_KMS_THREAD_TYPE`，脚本会拒绝覆盖。发布时保留原文件的 owner、group、
mode、ACL/xattr，不打印文件里的其他环境变量，也不创建含宿主环境内容的仓库文件。

## 一键回滚

```bash
cd /home/ubuntu/projects/qemu
sudo ./deploy/host/g11-mutter-kms-thread.sh disable
./deploy/host/g11-mutter-kms-thread.sh status
```

同样需要正常关闭 VM、注销并重新登录，当前 Shell 才会从 `user` 回到默认模式。
`disable` 只删除完全匹配的 G11 三行块；块被人工扩展、marker 不完整或存在外部赋值
时会拒绝猜测和删除。

## 如何验收

必须把两类动作分开测：

1. **SDL 内操作 Guest**：在 Windows 内连续拖动任务管理器窗口，观察 Guest 内容、
   Host 光标和帧率是否仍呈规律性 16/33ms 跳动。
2. **拖整个宿主 SDL 窗口**：抓住 Linux 标题栏移动。此时 Mutter 持有交互 grab，
   SDL/Guest 暂时不会收到这段鼠标运动，不能把它当作 Guest 输入延迟测试。

推荐 A/B 每档各做 20 秒，移动轨迹、速度和 VM 状态保持一致：

```bash
./deploy/host/g11-mutter-kms-thread.sh status
./deploy/scripts/g11-sdl-performance.sh verify 3
```

若 `user` 模式显著改善实体鼠标拖动而自动化拖动前后都正常，就确认瓶颈在宿主
Mutter 调度，不在 USB tablet 的 1ms endpoint。若完全无变化，可以临时把 G502
板载回报率从 1000Hz 改为 500Hz再做一次诊断；这会把最大采样间隔从约 1ms 变成
约 2ms，但不要由部署脚本永久替用户修改鼠标板载配置。

## “多个鼠标”为什么不是同一个问题

这个 workaround 只解决宿主合成节拍，不会凭空生成 Guest cursor plane。

- Host cursor 是宿主硬件光标，立即跟随实体鼠标。
- 当前 R535 VFIO REGION 没有向 QEMU 提供可用的独立 Guest cursor sprite。
- Windows 光标若已经合成进主 framebuffer，就会随 Guest 帧晚一拍；Host fallback
  再叠在上面时会看到两个位置。
- 拖整个 Linux SDL 窗口时，framebuffer 中的旧 Guest 光标还会和窗口一起移动，
  而 Mutter 的 Host 光标停在实际抓取点。

因此不能靠 Mutter 设置从主 framebuffer 中可靠“抠掉”第二个光标。安全策略仍是：
QEMU 只有收到权威 Guest 光标形状/热点/可见性时才切换；否则保留 Host fallback，
避免鼠标进入 SDL 后完全消失。彻底同步形状需要 Guest 用户态 cursor bridge，不需要、
也不允许靠测试签名、自签内核驱动或修改 BCD 实现。

## 安全边界

- 不开启 `testsigning` 或 `nointegritychecks`；
- 不修改 BCD；
- 不安装测试签名/自签名内核驱动；
- 不把宿主凭据写入仓库；
- 不自动注销、重启 GNOME Shell、重启宿主机或强停 VM；
- 回滚只处理带明确 G11 marker 的配置块。

# G-11 切画面卡顿：一键只读采样

`collect-g11-performance.py` 在宿主机上每秒读取正在运行的 QEMU、线程、内存、I/O
和 NUMA 信息，帮助对齐“进入副本、切换角色、黑屏开始、画面恢复”的时间。
只需 Python 3，无需给 Windows 添加软件。它不启动或停止 VM，不改参数、驱动或缓存，
不访问远端，也不读取 `/proc/PID/mem`。

## 1. 保持同一个 false/false 基线

已经运行的 VM 直接采样，不必重启。保持现有的
`--cpu-isolate=false --memory-prealloc=false`，同一轮不更改分辨率、vCPU、RAM、
刷新间隔或窗口模式。脚本开头应显示 `CPU隔离=off` 和 `prealloc=off`；读不到时为
`unknown`，不会把启动终端的默认值当作实际配置。

仅在本来就需要新启动时，源码目录的原启动命令可以明确写成：

```bash
./deploy/scripts/start-vm.sh 2 --proxy --cpu-isolate=false --memory-prealloc=false
```

将示例中的 `2` 改为实际 VM 编号。使用 GMate 客户端时保持相同的 CPU/内存选择，
在宿主终端运行下面的采样命令即可。

## 2. 运行采样

源码目录：

```bash
cd /home/ubuntu/projects/qemu
python3 deploy/host/collect-g11-performance.py --vm 2 --seconds 90 \
  --output /tmp/g11-vm2-first.json
```

GMate G-11 安装包目录：

```bash
python3 /opt/gmate/deploy/g11/host/collect-g11-performance.py --vm 2 --seconds 90 \
  --output /tmp/g11-vm2-first.json
```

已核对当前安装目录及 VMate 打包脚本：G-11 的路径是 `/opt/gmate/deploy/g11`；
`/opt/gmate/share/qemu/deploy` 不是当前包的安装路径。本脚本和本教程随新包的
`deploy/g11/host` 目录带入，旧包若没有脚本，可以在源码目录使用同一个单文件脚本。
识别进程支持源码 QEMU 名称和包内的 `qemu-system-x86_64.g11.real`，无需传安装路径。

`--seconds` 默认 60，允许 1–3600；也可以用 `--pid 实际PID` 替代 `--vm 2`。
只有唯一匹配的运行中 QEMU 才会开始，进程退出、身份变化或失去必要权限时停止。
开始前读取执行文件计算 SHA256，随后打印 `采样开始 started_at=...` 并进入每秒采样。

JSON 输出文件**必须不存在**，脚本不覆盖已有文件。第二次把文件名改为
`/tmp/g11-vm2-second.json`；已有文件会在采样前拒绝，最终写入仍保留独占创建保护。
省略 `--output` 时只在终端输出。

若当前用户无法读取 QEMU 的 `/proc` 信息，用 `sudo` 重跑同一命令，并选择新的文件名：

```bash
sudo python3 /opt/gmate/deploy/g11/host/collect-g11-performance.py --vm 2 --seconds 90 \
  --output /tmp/g11-vm2-privileged.json
```

密码只在 `sudo` 的交互提示中输入，不写入命令、环境变量、脚本或报告。脚本只输出
经过筛选的参数和统计，不保存完整命令行、进程环境、日志、磁盘路径或凭据。
JSON 权限为 `0600`，使用 sudo 创建的报告归 root；终端输出仍可直接复制。
`unknown`（JSON 中的 `null`）表示信息不可用，不能当作零；未启用 schedstats 时，
线程排队等待也会显示 unknown，采样器不会为此修改内核设置。

## 3. 重现并记录操作时间

看到 `采样开始` 后先静止约 10 秒，再按平常方式进入副本或切换角色，画面恢复后
重复同一操作。记录黑屏起止、恢复时刻以及当时标题的 Content/Present。
需要记操作时间时，可在同一宿主的另一个终端执行：

```bash
date --iso-8601=seconds
```

把时间和“开始切角色”等短说明一起保留。报告的 `started_at` 是每秒采样基线时刻，
`finished_at` 是结束并完成最后一次只读检查的时刻，均为含时区偏移的 ISO 时间。
每条 `samples[].timestamp` 在该次快照读取结束时记录，终端每秒行也会显示它，
便于对齐操作记录。各 `/proc` 项是依次读取的，不能把时间戳理解为原子采样时刻。
原有相对 `second` 和 `elapsed_seconds` 仍使用单调时钟，不受系统时钟校正影响。

采样结束后，提供终端开头配置、结尾 `SUMMARY`、操作时间记录和 JSON 报告。
报告包含实际 prealloc、vCPU、SDL 配置、mdev 刷新间隔/FRL、NVIDIA 驱动、PCI/NUMA、
线程 CPU/缺页、QEMU 读取量、系统 swap/PSI，以及前后内存节点分布。
线程新建或退出时，`thread_coverage_complete=false` 提示线程增量存在覆盖缺口。

## 4. 和 Content/Present 一起理解

`Content` 是 QEMU 向 SDL 报告内容更新的频率，`Present` 是宿主窗口提交频率。
静止桌面的 `Content 0/s | Present 60/s` 可以正常；fixed 模式会重复提交同一张纹理，
所以 Present 接近 60 不能证明画面仍在变化。Content 也不是 GPU 内部唯一新帧计数。
本采样器不读取窗口标题，需把现场观察与同一时刻的报告一起比较。

首次进入时 minor faults 明显增长，可提示新页分配，但不能单独证明卡顿原因；
major faults、swap-in 和内存压力同时增加，更支持内存回收停顿；只有首次磁盘读取
突出、第二次明显减轻，则需继续检查加载与缓存。系统 PSI/swap 是整机指标，
不能全部归因于这台 VM。主线程 CPU 高、Content/Present 下降且没有对应 I/O 或内存
压力时，再继续调查显示复制与提交链路。单次报告不自动证明根因或“全程 GPU”。

## 5. 后台采样并通过 QMP 显式操作

`control-g11-console.py` 只提供 `status`、`key`、`click`、`screenshot` 四种操作。
它根据 VM 编号找到唯一 QEMU，核对 Unix socket 实际进程，再用 QMP `query-name`
核对目标；不安装 Guest 软件，
不激活宿主窗口，不接受任意 QMP 命令，也不读取窗口标题。

下面是源码目录的示例。安装包环境把 `deploy/host/` 换成
`/opt/gmate/deploy/g11/host/`。**输入和截图必须由运行 QEMU 的同一用户执行**，
不要因为采样器使用了 sudo 就给控制命令加 sudo；`status` 在具有读取权限时可跨用户查询。

先在新目录中后台采样，避免覆盖已有报告：

```bash
G11_REPORT_DIR=$(mktemp -d /tmp/g11-session.XXXXXX)
python3 deploy/host/collect-g11-performance.py --vm 2 --seconds 120 \
  --output "$G11_REPORT_DIR/performance.json" > "$G11_REPORT_DIR/performance.log" &
G11_SAMPLE_PID=$!
printf '%s\n' "$G11_REPORT_DIR"
python3 deploy/host/control-g11-console.py --vm 2 status
```

确认 `performance.log` 已出现 `采样开始`，再按需截取当前画面：

```bash
python3 deploy/host/control-g11-console.py --vm 2 screenshot \
  --output-dir "$G11_REPORT_DIR/before"
xdg-open "$G11_REPORT_DIR/before/screenshot.png"
```

截图目录必须是不存在的新目录。QEMU 先写私有临时文件，脚本验证 PNG 后独占发布
`screenshot.png`，不会覆盖已有图片。命令返回实际 `width`、`height`；截图也会有
读取和编码开销，因此用于确认操作目标，不必每秒重复截图。

只有确认画面上的目标后才发送按键或点击。例如，确认当前适合按 Esc 时：

```bash
python3 deploy/host/control-g11-console.py --vm 2 key esc
```

点击需明确给出**最近截图的真实宽高和目标像素坐标**。下面是语法占位，替换后再执行，
不能照抄任意坐标盲点；画面布局或分辨率改变后应重新截图：

```text
python3 deploy/host/control-g11-console.py --vm 2 click --x 目标X --y 目标Y --width 截图宽度 --height 截图高度
```

点击拆分为移动、等待、按下、等待、释放；释放在清理逻辑中尝试执行。按键使用 QEMU
`send-key`，100ms 后自动释放。控制命令在终端输出含时区的 `started_at/finished_at`，
可以重定向到本次新目录中的独立事件文件，和采样的 `timestamp` 对齐；不要记录原始
命令行或拼接敏感文本作为操作标签。

操作后用另一个新目录（如 `after`）再截图确认结果。最后等待采样结束并查看摘要：

```bash
wait "$G11_SAMPLE_PID"
tail -n 4 "$G11_REPORT_DIR/performance.log"
```

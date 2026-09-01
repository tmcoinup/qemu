# G-11 SDL 鼠标修复与光标说明

这次修复只落在 G-11，不合并 V-11 整个提交，也不改变 Windows BCD、
`testsigning`、`nointegritychecks` 或 guest 内核驱动。
窗口最小化/恢复的独立构建与验收步骤见
[`G11-SDL-MINIMIZE.md`](G11-SDL-MINIMIZE.md)。
宿主处于拼音/Fcitx 时 Guest 键盘无输入，见
[`G11-SDL-HOST-IME.md`](G11-SDL-HOST-IME.md)。

## 一键构建与验证

在 QEMU 仓库根目录执行：

```bash
./deploy/host/build-qemu.sh
./deploy/tests/run-g11-sdl.sh
```

第一条命令用仓库自带的 Meson 环境增量构建 QEMU。第二条是封装后的 G-11
验证入口，会运行 SDL 静态回归、`test-sdl2-pointer` 坐标单测和
`test-sdl2-cursor` framebuffer 光标匹配单测。不要直接使用
Ubuntu 自带的 Meson 1.3；当前 QEMU 构建目录使用更新的仓库环境。

只想快速重跑本功能时：

```bash
bash deploy/tests/qemu/test_sdl_pointer_mapping_static.sh
bash deploy/tests/qemu/test_sdl_cursor_auto_static.sh
build/tests/unit/test-sdl2-pointer --tap
build/tests/unit/test-sdl2-cursor --tap
```

## 启动

把 `9` 换成实际 VM 编号：

```bash
./deploy/scripts/start-vm.sh 9 --sdl
```

已经运行中的 QEMU 不会热加载新二进制。先在 Windows 内保存工作并正常关机，确认
旧 QEMU 退出后再执行上面的启动命令；不要直接杀进程。vm3 的生产默认就是：

```bash
./deploy/scripts/start-vm.sh 3 --sdl
```

这会使用现有生产默认：SDL、60Hz target、2ms 输入事件泵、fixed Present、
8333us R535 REGION 周期、FRL off 和 `host` 光标。默认始终保留宿主即时箭头，以
跟手为优先；Windows 拖窗口时 primary framebuffer 的延迟箭头可能形成可接受的重影。

需要把这些关键默认显式写出来做诊断时：

```bash
./deploy/scripts/start-vm.sh 9 --sdl --host-cursor
```

只有需要继续试验“确认到第二个箭头后隐藏 host”时才显式启用自动模式：

```bash
./deploy/scripts/start-vm.sh 9 --sdl --auto-cursor
```

`--guest-cursor` 仍只请求优先使用 QEMU 收到的权威 guest cursor sprite。当前
R535 REGION 实机没有提供该 sprite，因此缺失时保留 host fallback，不会盲目隐藏：

```bash
./deploy/scripts/start-vm.sh 9 --sdl --guest-cursor
```

三个参数只设置本次进程的 `QEMU_SDL_CURSOR_MODE=auto|host|guest`，不会写
`vm.conf`。G-11 启动器和直接运行 QEMU 都默认 `host`，作为跟手优先的失效安全
值。非法值会被启动器拒绝，QEMU 自身回退到 `host`。

默认 `usb-tablet` 是绝对坐标设备。窗口模式下无需抓住鼠标；指针应能从任意
边自然离开窗口。只有纯相对鼠标或用户显式按下 `Ctrl+Alt+G` 时，SDL 才约束
宿主指针。

## 傻瓜式验收

1. 先按 `Ctrl+Alt+0`，让窗口恢复 guest 原生大小。
2. 在 Windows 桌面把鼠标缓慢移到四个边角，guest 指针应到达对应边角。
3. 把窗口放大到出现黑边，再重复四边测试。进入黑边时 guest 坐标只钳制到
   最近边缘，不应在画面内部提前卡住。
4. 从左、右、上、下任意一边移出窗口，再移入；不应再依赖“换一个方向出去”
   才恢复。
5. 缩小窗口并慢速移动鼠标，连续的小位移不应被整数缩放永久吃掉。
6. 打开资源管理器，按住标题栏慢拖和快拖：默认 host 箭头应始终紧跟物理鼠标；
   framebuffer 延迟箭头可以形成重影，但不能替代即时箭头造成顿挫或跳动。
7. 松开左键后在桌面静止、慢移，再做桌面框选：光标应持续可见且跟手。
8. 仅测试 auto 时追加 `--auto-cursor`，或按 `Ctrl+Alt+C` 从 host 切到 guest、
   再切到 auto；完成测试后再循环回 host。热键只影响当前 QEMU 进程。

## auto 如何做到“只在确实有第二个箭头时隐藏”

“鼠标位置”和“光标图片”是两条独立通道：

| 数据来源 | SDL 行为 |
|---|---|
| `usb-tablet` 绝对坐标 | 宿主位置映射到 guest；本次已修复 |
| QEMU 收到权威 guest cursor shape/热点/可见性 | SDL 使用该 guest sprite，标题显示 `guest-only (guest sprite)` |
| NVIDIA R535 VFIO REGION | 只有 primary 画面，没有 cursor shape/visible 元数据；auto 未确认时使用 host 箭头 |
| 左键按住且最近位置附近匹配配置的箭头 | 临时隐藏 host fallback，显示 framebuffer 内的软件箭头 |

auto 不把“有 damage”或“附近有黑白像素”当成光标。QEMU 优先从启动器提供的
`aero_arrow.cur` 选取 32×32 帧；文件不存在时使用二进制内置的同款抗锯齿 Aero
箭头。随后抽取高不透明度深色边缘和完全不透明浅色内部两组样本；只检查 500 ms
内记录的左键拖动坐标及其 ±2 px 邻域。深色和浅色样本必须
分别达到 85% 与 90% 才确认。连续两次画面更新不再匹配，或发生松键、失焦、
最小化、surface/scanout 切换，立即恢复 host 光标。

因此失配方向是安全的：Windows 改了光标主题、缩放或形状时，最坏结果是拖动时仍
看到两个箭头，不会让唯一光标消失。极端情况下，如果画面本身恰好在最近指针位置
放着几乎相同的箭头图案，host 光标可能在按住左键期间短暂隐藏；松键或两次失配后
必定恢复。

SDL 的 `Ctrl+Alt+C` 按 `auto → host → guest → auto` 循环。该热键只改当前 QEMU
进程，不写 guest，也不持久化。`guest` 模式只有收到 shape、热点和 visible 状态后
才使用权威 sprite；否则仍显示 host fallback。

## 为什么不做 Guest 用户态 cursor bridge

严格的 Guest 隐蔽性原则下，不应做。常驻 bridge 至少会留下可枚举的进程和可执行
文件；为了自启动还会增加启动项、任务或服务，并需要某种 IPC/共享内存/虚拟设备
把状态传给宿主。使用 `SetWinEventHook`、轮询窗口状态或替换系统 cursor 也会形成
Guest 内可观察的行为。改名只能改变特征，不能消除这些对象。

本方案完全在宿主 QEMU/SDL 内完成：Guest 中没有新增进程、文件、注册表项、服务、
计划任务、hook、IPC endpoint、虚拟设备或驱动，Guest 软件无法通过枚举 Guest 对象
发现一个 cursor bridge。它也不改 BCD，不开启 `testsigning` 或
`nointegritychecks`，不安装测试签名/自签名内核驱动。这里的结论只针对本功能；
QEMU/vGPU 平台原本具有的其他可识别面不因此消失。

## 拖动 Guest 窗口时为什么会看到两个鼠标（2026-08-22 实测）

这一节是 vm3 上的实机测量结论，不是推断。测法：QMP `input-send-event` 注入
`usb-tablet` 绝对坐标与左键，`screendump` 抓 guest 原始画面（不含 host 光标），
再用光标模板做 NCC 定位。

### 触发条件只有“拖动窗口”一种

| 操作 | Guest framebuffer 里有光标吗 | 证据 |
|---|---|---|
| 静止悬停 | 没有 | 模板 NCC 0.44（无匹配） |
| 慢速移动 | 没有 | 移动前后整屏 diff **0 像素** |
| 快速移动 | 没有 | 光标位置邻域无黑/白像素 |
| 桌面框选拖动 | 没有 | 画面变了 3501 px，但仍无光标 |
| **按住标题栏拖窗口** | **有** | 模板 **NCC 1.000** |
| 松开左键后 | 没有 | 立刻恢复无匹配 |

平时 Windows 走硬件 cursor plane，光标不进 primary；只有进入窗口 move modal
loop 时才切软件光标，把箭头**画进 primary framebuffer**。此时 REGION 路径抓到的
画面里就自带一个箭头，叠上 QEMU 的 host fallback 箭头，于是屏幕上有两个。

### 残影是延迟差，不是重复绘制

host 光标由宿主合成器直接送 KMS cursor plane，延迟约 0；guest 画面要走
`usb-tablet → Windows 重绘 → vGPU console REGION → QEMU 轮询拷贝`。
实测到 QEMU surface 为 **32~36 ms**，加 SDL present 与 Mutter 合成后到屏幕约
60~80 ms。拖动中窗口边框与 framebuffer 光标**在同一帧**跳到新位置，说明这是整条
画面链路的延迟，不是光标独有的问题。

两个箭头的间距 ≈ 鼠标速度 × 延迟：800 px/s 时约 50 px，甩动时更远；停手约 0.3 s
后 framebuffer 光标追上 host 光标（实测残差 1 px），视觉上“合并回一个”。

### 已排除的做法

关闭“拖动时显示窗口内容”（`DragFullWindows=0`）**实测无效**：拖动改成显示虚框后，
光标照样被合成进 framebuffer。测试后已恢复原设置。系统里“在鼠标指针下显示阴影”
本来就是关闭状态，也不是诱因。

关闭 Windows 选项不能解决这个问题。G-11 保留宿主侧 auto matcher 作为显式实验：
它在确认 framebuffer 软件箭头后隐藏 host fallback，针对 vm3 已实测的默认
32×32 箭头，而不是一个能同步任意游戏 cursor 形状的通用协议。生产默认使用
host，避免只剩延迟 framebuffer 箭头时出现顿挫或跳动。

## 常用热键

- `Ctrl+Alt+0`：恢复 1:1 窗口大小。
- `Ctrl+Alt+G`：显式抓取或释放相对鼠标。
- `Ctrl+Alt+C`：按 `auto → host → guest → auto` 循环切换，仅影响当前进程。
- `Ctrl+Alt+F`：切换全屏。

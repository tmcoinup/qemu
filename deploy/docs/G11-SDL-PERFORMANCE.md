# G-11 SDL 画面、鼠标、键盘低延迟傻瓜教程

本页只适用于 **G-11 NVIDIA vGPU 的本地 SDL 窗口**。V-11 是独立分支，不要把
这里的 vGPU、VFIO REGION 或启动参数直接复制过去。

这套封装只设置当前 QEMU 进程的 Linux 宿主环境并委托现有
`deploy/scripts/start-vm.sh`。它不修改 Windows BCD，不开启 `testsigning` 或
`nointegritychecks`，不安装测试签名/自签名内核驱动，也不把宿主凭据写入仓库。

## 最短步骤

第一次使用，在仓库根目录整段复制：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/build-qemu.sh
./deploy/tests/run-g11-sdl.sh
./deploy/scripts/g11-sdl-performance.sh audit
```

三步都成功后，把 `9` 换成真实 VM 编号：

```bash
./deploy/scripts/g11-sdl-performance.sh start 9
```

Windows 进入桌面后，另开一个宿主终端：

```bash
./deploy/scripts/g11-sdl-performance.sh verify 9
```

`verify` 成功只表示当前进程确实使用推荐 SDL argv 和环境，不表示它已经测得了
“每一帧都是新画面”。继续完成下面的动态画面、鼠标和键盘实机验收。

优先测试最低键鼠排队和显示线程竞争，可在完整关机后使用：

```bash
./deploy/scripts/g11-sdl-performance.sh start 9 --ultra-responsive
```

先读完下文的光标能力和 USB descriptor 说明；这不是对所有 VM 静默启用的默认值。

## 封装固定了什么

`start` 每次只为本次启动强制下列值，不写入 `vm.conf`：

| 设置 | 推荐值 | 作用 |
|---|---:|---|
| `QEMU_SDL_TARGET_FPS` | `60` | 可见 SDL 刷新目标为 60Hz |
| `QEMU_SDL_INPUT_POLL_MS` | `2` | 聚焦窗口以 2ms 周期抽取 SDL 键鼠事件 |
| `QEMU_SDL_PRESENT_MODE` | `fixed` | 可见窗口按固定节拍 Present，减少恢复后旧帧停留 |
| `QEMU_SDL_CURSOR_MODE` | `host` | 保留宿主即时箭头，以跟手为优先；auto 仅显式测试 |
| `QEMU_SDL_TITLE_FPS` | `auto` | X11 实时标题；Wayland 有 Cairo libdecor 才实时，否则静态防 GDK 刷屏 |
| `VGPU_CONSOLE_INTERVAL_US` | `8333` | R535 上以 120Hz 更新 console REGION，让 60Hz Present 尽量取得最新帧 |
| `VGPU_FRAME_RATE_LIMITER` | `0` | 禁用 vGPU FRL，避免它与宿主 60Hz Present 同频但不同相造成拍频 |
| `QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP` | `0` | SDL 运行期间不让宿主因空闲关闭物理显示器 |

上表是默认 `low-latency-v1`。它还保持 `QEMU_SERVICE_CPUS=0` 和原设备 USB
descriptor，不会因为一次性能优化改变所有 VM 的 CPU 容量或可枚举指纹。

封装最终追加 `--sdl`，因此不会误进 GTK、RDP、安装或救援模式。确需这些模式时，
直接使用对应的 `start-vm.sh` 正式入口；不要把安装参数塞给本封装。
Wayland 标题的 userspace Cairo 一键安装、自动静态回退和 VM3 验收见
[`G11-SDL-WAYLAND-TITLE.md`](G11-SDL-WAYLAND-TITLE.md)。
每次 `start` 还会先自动执行同一套只读审计；源码和当前 QEMU build 不匹配时会在
分配 mdev、启动 Windows 之前失败，不会带着一个忽略新参数的旧二进制继续运行。

启动时仍可追加不改变显示模式的原有参数。例如只比较本地 SDL、不创建默认 DGame
preview：

```bash
./deploy/scripts/g11-sdl-performance.sh start 9 --no-dgame-preview
```

默认模式与 `--no-dgame-preview` 必须分别从 Windows 完整关机开始测试，不要在同一
QEMU 进程中得出结论。默认 DGame GPU preview 可能启用 native EGL/X11；关闭后少一条
preview 路径，但 DGame 本地预览也会不可用，不能把这个取舍静默改成所有 VM 的默认。

## 显式原生 Wayland A/B（非默认）

当宿主实际登录在 GNOME Wayland，而默认 SDL 窗口被 XWayland 调度时，可对
同一 VM 做一次受控窗口协议 A/B。先在 Windows 内选择“关机”，确认 QEMU
进程已退出，再运行：

```bash
./deploy/scripts/g11-sdl-performance.sh start 9 --native-wayland
```

这不是默认模式，也不会写入 `vm.conf`。wrapper 必须同时验证
`XDG_SESSION_TYPE=wayland`、`WAYLAND_DISPLAY`、`XDG_RUNTIME_DIR` 与真实 Unix socket；
在 X11 会话、伪造的环境变量或显式 `SDL_VIDEODRIVER=x11` 下会在启动 VM 前拒绝。
通过后，它为同一个 `start-vm.sh` 进程原子设置：

```text
G11_SDL_WINDOW_MODE=native-wayland-v1
SDL_VIDEODRIVER=wayland
QEMU_SDL_NATIVE_EGL=0
```

现有 DGame GPU-first 共享链依赖 X11-only native EGL 子窗口，不能原样搬到
SDL/Wayland。因此该 A/B 还会自动传入 `--no-dgame-preview-gpu`：DGame preview
端点仍存在，只禁用 X11 native-EGL/GPU-first 启动并保留 DGame SHM fallback。
它会拒绝同时传入
`--dgame-preview-gpu`，不会先用错误 EGL provider 启动后再猜测。

进入 Windows 后运行：

```bash
./deploy/scripts/g11-sdl-performance.sh verify 9
```

应看到 `WINDOW_CONTRACT=native-wayland-v1 driver=wayland native-egl=0`。完成拖窗、
快速移动指针和标题 `Content/Present` 对比后，再让 Windows **完整关机**，
下次省略 `--native-wayland` 就回到默认 X11/XWayland 路径。两种窗口协议
不能在已运行的 QEMU 内热切换。原生 Wayland 只是隔离 XWayland 影响的对照组，
不代表它必然修复 NVIDIA REGION 新帧不足或 Guest framebuffer 自画的第二个光标。

如果卡顿只在抓住 Linux 标题栏、拖动整个 SDL 外层窗口时出现，而 Windows 内部拖窗
正常，应按宿主合成器问题处理。当前机器的 1000Hz 鼠标与 Mutter 实时 KMS thread
诊断、显式启用及一键回滚步骤见
[G11-MUTTER-MOUSE-DRAG.md](G11-MUTTER-MOUSE-DRAG.md)。

## audit 看什么

```bash
./deploy/scripts/g11-sdl-performance.sh audit
```

它只读检查：

1. 当前源码是否认识四个 SDL 环境开关；
2. `start-vm.sh` 是否仍有 R535 console interval 封装；
3. 当前 `build/qemu-system-x86_64` 是否包含相同开关并编译了 SDL backend；
4. 对带 `build.ninja` 的本地 build 做 Ninja dry-run，确认源码/构建配置没有待编译项；
5. 当前是 X11、Wayland/XWayland 还是无本地图形会话。

若显示 `QEMU_BUILD=missing`、任一 `binary ...=no` 或
`QEMU_BUILD_FRESH=no/unknown`，先执行：

```bash
./deploy/host/build-qemu.sh
./deploy/scripts/g11-sdl-performance.sh audit
```

已经运行的旧 QEMU 不会被新二进制热替换；必须让 Windows 完整关机后重新启动。
通过 `QEMU_BIN` 指向仓库外部、且旁边没有 `build.ninja` 的二进制时，审计会明确显示
`QEMU_BUILD_FRESH=not-checkable`；此时只能核对二进制合同，无法证明外部源码与它一致。

## verify 能证明什么、不能证明什么

```bash
./deploy/scripts/g11-sdl-performance.sh verify 9
```

它从 `/proc` 精确寻找 `-name vm9` 的 QEMU，只读取以下有限信息：

- PID、运行时间、CPU/内存占用和线程数；
- `/proc/PID/exe` 是否仍是当前 build；重编译后仍在运行的 `(deleted)` 旧映像会要求
  完整关机重启，不会拿新源码/新文件替旧进程背书；
- `-display sdl,...` 与 native vGPU `display=on`；
- 响应 profile、SDL 低延迟环境和 QEMU service CPU 请求；
- 从受限的 vfio-pci `sysfsdev` argv 解析 mdev UUID，再读取实际生效的
  `intervaltime/vgaintervaltime/frame_rate_limiter`；不会把已经被启动器消费的
  环境变量误报为缺失；
- `usb-kbd` 是否真的带 1ms endpoint，以及当前 host/guest cursor 策略；
- `G11_SDL_WINDOW_MODE`、`SDL_VIDEODRIVER` 与 native EGL 是否组成合法
  `native-wayland-v1` 原子合同；未选 A/B 时只报告启动器默认值。

它不会打印整个进程环境，因此不会把无关 token 或凭据带进日志。若 VM 没运行，
会明确输出 `VERIFY_RESULT=not-running` 并以状态码 `3` 退出；若当前用户无权读取目标
进程环境，会输出 `partial`，不会猜测参数。

当前 QEMU 标题同时显示：

- `Content`：QEMU 内容更新/损伤合并后送到 SDL 的次数每秒；
- `Present`：宿主窗口提交率。

fixed 模式可以把同一张旧纹理重复提交 60 次/秒，所以 **Present 约 60/s 不能证明
画面在变化**。静止桌面显示 `Content 0/s | Present 60/s (fixed)` 正常；持续视频中
Content 长时间归零才提示 source/staging 链路可能停住。Content 不是 GPU 内部 frame sequence，
也不是“唯一新画面”计数：REGION 高运动比较旁路会在运动停止后短暂继续报更新，完全
相同的连续帧又可能被去重。因此它只能与动态测试画面和 Present 一起诊断。

命令行 `verify` 目前不能安全读取 SDL 窗口标题或导出逐帧序号，因此仍固定输出：

```text
SOURCE_FRAME_TELEMETRY=unavailable
```

这是 `verify` 的能力边界，不是报错；现场仍可直接看标题里的 Content。不能把进程
CPU、Present rate 或静止桌面的相同帧包装成“零定格证明”。

### 静止画面是不是仍按正常频率“推流”

是，但这里是本地 SDL Present，不是网络推流。fixed 模式每个显示 tick 都会先查询
VFIO REGION，并把 live mmap 与稳定 staging 的可见像素逐行比较：像素变化就 copy、
upload；完全相同时省掉无意义的 full upload，但仍按目标频率重复 Present 已缓存纹理。
因此 `Content 3/s | Present 60/s (fixed)` 的准确含义是“约 3 次内容更新、约 60 次窗口提交”，不是
另外 57 次没有检查源画面。

不要为了把标题中的 Content 伪装成 60 而默认强制 full copy/upload。1920x1080 BGRA
全帧约 8.3MB，60 次/秒仅 staging copy 就约 0.5GB/s，随后还有纹理上传；若 R535
没有写入新像素，复制 60 次仍是同一帧，也不会生成缺失的 Guest 光标。当前高运动
路径已在持续全画面变化时自动短时绕过逐行比较，不会让游戏永远支付双重扫描成本。

## 单窗口极致响应 A/B

默认档先通过后，想减少键鼠排队和 QEMU main/display 与 vCPU 的竞争时，完整关闭
Windows 后运行：

```bash
./deploy/scripts/g11-sdl-performance.sh profile ultra
./deploy/scripts/g11-sdl-performance.sh start 9 --ultra-responsive
```

`ultra-responsive-v1` 只影响本次进程；与普通入口一样使用 120Hz REGION、关闭
vGPU FRL，同时让 SDL 保持固定 60Hz Present：

| 设置 | ultra 值 | 实际作用 |
|---|---:|---|
| SDL/REGION 内部节拍 | `60Hz` / `8333us` | 每次 Present 前最多提前约 8.3ms 取得新 REGION |
| vGPU FRL | `0` | 避免独立 60Hz 限制器与 SDL Present 拍频 |
| SDL 输入事件泵 | `1ms` | 更快抽取宿主键鼠事件 |
| QEMU service CPU | `auto` | 宿主有余量时给 main/display 服务线程一个候选 CPU；不足时安全回到 0 |
| USB 键盘/相对鼠标 | `1ms` | 本次启用 low-latency HID descriptor；绝对 tablet 原本就是 1ms |
| Present | `fixed 60Hz` | 即使静止也重复提交缓存纹理 |

当前 VM3 的非-vCPU main/GL/I/O 线程与 8 个 vCPU 共用同一 cpuset；`service=auto`
因此是比盲目翻倍画面轮询更可信的尾延迟优化。回退只需完整关机，下一次省略
`--ultra-responsive`；不写配置、不改 BCD、不安装 Guest 驱动。

### 仅单窗口实验：120Hz Present

若 60Hz 响应档已经验证稳定，仍愿意用约两倍窗口提交成本换取理论上最多约
8.3ms、平均约 4.2ms 的额外相位缩短，可单独测试：

```bash
./deploy/scripts/g11-sdl-performance.sh profile experimental-120
./deploy/scripts/g11-sdl-performance.sh start 9 --experimental-120hz
```

它使用 `120Hz Present / 8333us REGION / FRL off / fixed / input 1ms / service auto /
keyboard 1ms`。普通和 ultra 已经以 8333us 扫描 REGION，实验档只把 SDL 提交率从
60 提高到 120；约 59.91Hz 的物理显示器不会显示 120 个独立帧，高运动时却会增加
纹理提交成本。只有 240fps 相机或调度 p95/p99 能稳定证明收益时才保留；否则回到
`--ultra-responsive`。多个 VM 不要同时使用实验档。

建议对同一 VM、同一连续拖窗/60FPS 移动条分别测 balanced、ultra 和实验 120 各 2 分钟，记录
标题、`verify`、QEMU main thread CPU，并用 120/240fps 相机拍“物理鼠标动作→Guest
像素变化”。只凭手感或把重复旧帧算作新帧，无法给出可信的端到端毫秒数。

## 画面不定格实机验收

1. 从完整关机启动 VM，确认摘要有 R535
   `console REGION 周期=8333us FRL=0`、SDL fixed/60Hz 和 2ms 输入配置。
2. 进入 Windows 后持续播放本地 60FPS 测试视频，或连续拖动一个内容不断变化的窗口
   2 分钟。不要用完全静止的桌面判断“相同帧”。
3. 同时观察 SDL 客户区和标题。持续动态内容时 `Content` 应持续非零，画面不应停住
   数秒后突然跳动；`Present` 约 60 只说明宿主提交节拍。
4. 最小化 5 秒再恢复，画面应立即补全；连续重复 10 次，不应黑屏、残留旧尺寸或
   停在恢复前的画面。
5. 最大化、恢复、拖动缩放各做 10 次。宿主缩放不应改变 Windows 内的原生分辨率。
6. 若出现定格，记录发生时间、持续秒数、窗口是否最小化、标题速率、
   `verify` 输出和 QEMU 日志。不要用修改 BCD/签名或安装内核驱动来掩盖宿主显示问题。

若要用旧的 damage-driven Present 做一次诊断对比，完整关机后直接运行正式底层入口：

```bash
QEMU_SDL_PRESENT_MODE=dynamic \
  ./deploy/scripts/start-vm.sh 9 --sdl
```

这不是低延迟封装的生产默认。dynamic 下静止画面的 Content/Present 都显示 `0/s`
可以是正常去重；持续动态画面突然归零才有诊断价值。

## 无操作后黑屏/睡眠

推荐 wrapper 已设置 `QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP=0`，所以 QEMU 运行期间宿主
屏保/DPMS 不会因空闲关闭整台物理显示器；QEMU 退出时会恢复宿主原有资格。

如果宿主桌面仍亮、只有 Windows 客户区变黑，则在 guest 内运行新版
`VgpuPortable.exe`（旧维护包运行 `02-Apply-Recommended.cmd`）。它把 Windows
每个已安装电源计划的显示器超时和系统自动睡眠 AC/DC 设为“从不”，并把每个计划的
精确原值保存到
`C:\ProgramData\G11GuestPerformance\state.json`。双击 tools 目录里的
`04-Rollback.cmd` 可完整恢复；不改 BCD、签名策略或驱动。

页面只有“屏幕”而没有“睡眠”不是超时值造成的，而是旧 QEMU 启动隐藏了 ACPI S3。
使用当前 G-11 启动器完整关机再冷启动一次后，“睡眠”项会出现；空闲值仍为“从不”，
用户可主动睡眠。若本地键鼠未唤醒，宿主运行 `./deploy/scripts/vmctl.sh wake ID`。

若两层均已禁用仍黑屏，按“最小化→恢复”“切走焦点→返回”和持续动态画面三种场景
分别记录 Content/Present 与 QEMU 日志。这时应排查 REGION/scanout 恢复，而不是继续
改电源或安装驱动。

### 渲染恢复边界

- SDL/GLX 是普通本地窗口的稳定默认路径；X11 native EGL 只在现有启动链
  显式启用时使用。`--native-wayland` 仅作为关闭该 native EGL 的完整重启 A/B。
- 短暂的 surface、纹理或 scanout 候选失败会保留最后一张已提交画面并限速重试；
  窗口重建只替换 EGL surface/X11 子窗口，根 context 保持不变，避免切断 virgl/fb-shm
  share group。
- SDL 父窗口、GLX context 或 2D renderer 创建失败采用 100ms 快速重试、随后 1 秒
  慢速重试并抑制重复日志，不会在 60Hz refresh 中忙循环；隐藏窗口只记待补帧，
  不做整帧 GL 上传、DMA-BUF import 或 scanout FBO 创建。
- VFIO DMA-BUF reset 即使当前 primary 已因 RAMFB/no-plane 切换而清空，也会释放缓存，
  避免设备恢复后复用旧 ID/FD 而显示黑屏。
- 若驱动报告 `EGL_CONTEXT_LOST`、EGL display 失效或配置永久不匹配，QEMU 会停止该
  本地 EGL 渲染链并输出一次明确日志，不会冒险切换到不兼容的 GLX context。VM、QMP
  和输入主循环仍可继续，但恢复本地画面需要正常关闭并重新启动该 QEMU 进程。

这些保护降低“恢复后永久黑屏”和重复失败风暴的概率，但源码/编译测试不能替代真实
NVIDIA mdev、X11/XWayland、显示器和电源策略的长时间验收。

## 鼠标验收

默认绝对指针无需抓住鼠标：

1. 按 `Ctrl+Alt+0` 恢复 1:1 客户区。
2. 缓慢移到 Windows 桌面四角，guest 指针必须到达四角。
3. 放大窗口产生黑边，再测四角；黑边只允许钳制到最近边缘，不能在画面内部卡住。
4. 从上下左右任意边移出再移入，不能丢点击，也不能必须换一个方向才能离开。
5. 连续快速画圆、点击和滚轮 60 秒，不应出现数秒无响应或释放后仍保持按下。
6. 打开资源管理器，按住标题栏慢拖和快拖，默认 `host` 箭头必须始终跟手；允许
   framebuffer 的延迟箭头形成重影，但不能隐藏即时 host 箭头。

纯相对鼠标或游戏需要抓取时使用 `Ctrl+Alt+G`。NVIDIA R535 REGION 当前没有向
QEMU 提供权威 cursor shape/visible 元数据，实机也证明 active desktop 不能可靠依赖
framebuffer 光标。G-11 默认 `host`，以宿主即时箭头的响应为优先。显式
`--auto-cursor` 才在左键按住期间，以配置的 32×32 Windows 箭头模板和最近 Guest
坐标严格确认 framebuffer 软件光标；确认后临时隐藏 Host fallback，失配、松键、
失焦或 surface 切换立即恢复。`--guest-cursor` 仍只使用权威 Guest sprite。
实现完全在 Host，不修改 Guest；
阈值、失效边界与独立验收见 [`G11-SDL-MOUSE.md`](G11-SDL-MOUSE.md)。

## 键盘验收

1. 宿主先切到中文拼音/Fcitx，SDL 内打开 Windows 记事本。
2. 输入 `abc123`、Backspace、Enter，并分别按住再释放 Shift/Ctrl/Alt。
3. `Alt+Tab` 离开再返回，首键不能丢，guest 中不能留下“按住不放”的键。
4. Windows 内切换微软拼音输入中文；候选框应属于 guest，宿主不应吞物理按键。
5. 鼠标位于窗口且窗口聚焦时，确认 `Super`、`Alt+Tab`、`Ctrl+Alt+Del` 按当前
   G-11 快捷键保护策略交给 guest；离开窗口后宿主快捷键应恢复。

这些操作检查的是功能和明显卡顿。没有外部高速摄像/输入时间戳设备时，不应虚构
“点击到像素为多少毫秒”的端到端测量值。

## 高级 A/B：Guest USB HID 1ms（默认不要开）

上面的 2ms 是宿主 SDL 事件泵。键盘和相对鼠标进入 Windows 前还经过虚拟 USB HID
interrupt endpoint。G-11 保留了一个显式、单次启动的 1ms A/B 开关：

```bash
./deploy/scripts/g11-sdl-performance.sh start 9 --low-latency-input
```

它只把 `usb-kbd` 和相对 `usb-mouse` 的 endpoint interval 改为 1ms；默认绝对
`usb-tablet` 本来就是 1ms，不会为了好看的日志再改一次。这个选项会改变 USB
endpoint descriptor，也就改变可枚举的设备指纹，所以低延迟 wrapper **默认不启用**。
只有同一 VM、同一场景的键鼠 A/B 确认有实际收益时才考虑使用。

回退时完整关闭 Windows，下一次直接省略参数，或明确执行：

```bash
./deploy/scripts/g11-sdl-performance.sh start 9 --no-low-latency-input
```

该选择不写入 `vm.conf`，也不需要 Guest 驱动、BCD 或签名改动。A/B 时记录启动摘要中
的 `USB 输入延迟` 行；没有该行就是默认 profile descriptor。

## 一键回归与 build 缺失

完整 SDL 专项回归：

```bash
./deploy/tests/run-g11-sdl.sh
```

它聚合 SDL source 静态门禁、VFIO REGION 去重/回退、R535 interval、native display
启动 fixture，以及 input、pointer、NumLock 和 USB HID queue 编译测试。

只做不依赖 build 的快速检查：

```bash
./deploy/tests/run-g11-sdl.sh --static-only
```

若 build 目录或编译二进制缺失，默认模式会继续完成静态测试，明确列出 `SKIP`，最后
以状态码 `2` 报告 `INCOMPLETE`，而不是把“没运行”写成通过。修复命令只有：

```bash
./deploy/host/build-qemu.sh
./deploy/tests/run-g11-sdl.sh
```

鼠标坐标细节见 [G11-SDL-MOUSE.md](G11-SDL-MOUSE.md)，宿主输入法隔离见
[G11-SDL-HOST-IME.md](G11-SDL-HOST-IME.md)，最小化恢复见
[G11-SDL-MINIMIZE.md](G11-SDL-MINIMIZE.md)，防息屏见
[G11-SDL-NO-SLEEP.md](G11-SDL-NO-SLEEP.md)。宿主 CPU/TSC/内存和 NVMe 的独立
性能策略见 [G11-PERFORMANCE-QUICKSTART.md](G11-PERFORMANCE-QUICKSTART.md)。

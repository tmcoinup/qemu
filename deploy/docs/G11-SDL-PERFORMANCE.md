# G-11 SDL 画面、鼠标、键盘低延迟傻瓜教程

本页只适用于 **G-11 NVIDIA vGPU 的本地 SDL 窗口**。V-11 是独立分支，不要把
这里的 vGPU、VFIO REGION 或启动参数直接复制过去。

单路/双路共享满载、8–16 开容量分析和新增前台60/后台15Hz显示档，见
[G-11 全面性能优化教程](G11-FULL-PERFORMANCE.md)。

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

三步都成功后，在 Windows 内选择“关机”，等待旧 QEMU 窗口和进程退出。
下面以 VM1 为例，保留共享 CPU、按需 RAM；把 `1` 换成真实 VM 编号：

```bash
./deploy/scripts/g11-sdl-performance.sh start 1 --proxy \
  --cpu-isolate=false --memory-prealloc=false
```

Windows 进入桌面后，另开一个宿主终端：

```bash
./deploy/scripts/g11-sdl-performance.sh verify 1
```

应看到 `RESOURCE CPU_ISOLATION=off` 和 `RESOURCE RAM_PREALLOC=off`。这次显示优化
不要求开启 CPU 隔离或 RAM 预分配，也不需要在 Guest 安装任何新软件。

`verify` 成功只表示当前进程确实使用推荐 SDL argv 和环境，不表示它已经测得了
“每一帧都是新画面”。继续完成下面的动态画面、鼠标和键盘实机验收。

V100 + 精确 `570.172.07` 若仍读取旧 `VGPU_CONSOLE_INTERVAL_US=0`，先按
[已有 V100/R570 配置的 SDL 周期迁移](G11-VGPU-HOST-QUICKSTART.md#已有-v100r570-配置的-sdl-周期迁移)
完成维护窗口迁移。旧配置不会自动覆盖，且会覆盖封装传入的同名环境变量。
该版本 `8333us` 仅通过 vendor 静态审核，尚无真实 V100 的运行性能与稳定性验证。

想单独比较更快的键鼠轮询，可在完整关机后使用：

```bash
./deploy/scripts/g11-sdl-performance.sh start 1 --proxy --ultra-responsive \
  --cpu-isolate=false --memory-prealloc=false
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
| `VGPU_CONSOLE_INTERVAL_US` | `8333` | 请求约 120Hz 的 console 拷贝周期；R535 已有实测，精确 R570.172.07 仅静态审核，旧宿主配置可覆盖此值 |
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

## 共享 CPU、按需内存时卡顿怎么比较

当前正常 G-11 vGPU SDL/GTK 默认共享 CPU、全量预分配 RAM。所以只运行
`./deploy/scripts/start-vm.sh 1 --proxy`，在没有显式 CPU 环境策略时，对应
`--cpu-isolate=false --memory-prealloc=true`。`--proxy` 只是 QMP socket 的兼容别名，
不负责 SDL 画面传输；DGame preview 是否启用由自己的参数决定。

`--memory-prealloc=false` 把新页的分配、清零和映射成本延后到 Guest 实际使用时，
可能在开程序、切场景时增加延迟；共享 CPU 则让 QEMU 与其他负载竞争可运行的核。
这些是需要实测的影响，画面突然全黑也可能来自 Guest 显示模式切换或宿主 GL 链路，
不能仅凭两个 `false` 就认定根因。

每组对比前在 Windows 中选择“关机”，等 QEMU 退出。保持同一个 VM、应用和画面，
先记录当前配置，再只改变内存预分配：

```bash
# 第一组：保留共享 CPU 和按需 RAM
./deploy/scripts/g11-sdl-performance.sh start 1 --proxy \
  --cpu-isolate=false --memory-prealloc=false

# 完整关机后第二组：只恢复 RAM 预分配
./deploy/scripts/g11-sdl-performance.sh start 1 --proxy \
  --cpu-isolate=false --memory-prealloc=true
```

每组进入桌面后，在另一个宿主终端运行：

```bash
./deploy/scripts/g11-sdl-performance.sh verify 1
```

确认 `RESOURCE CPU_ISOLATION=off`，以及两组 `RESOURCE RAM_PREALLOC` 分别为 `off`
和 `on`。连续运行相同动态画面两分钟，记录黑屏出现时间、持续时间和标题中的
Content/Present；同时比较启动程序或切场景是否更顺畅。第二组有收益时可以保留
预分配；需要按需占用时继续第一组命令。仅凭 `verify` 成功无法证明帧时间改善。

需要保留两个 `false` 并比较更快输入轮询，可在第一组命令追加 `--ultra-responsive`；
它会使用 1ms SDL 输入轮询和键盘 endpoint，但服务核不会在共享 CPU 模式下应用。
不要把这一步同时与内存 A/B 混在一起；USB descriptor 的影响见后文。

### 本次切画面优化做了什么

本次修改都在 Linux 宿主的 QEMU 内，重新构建并完整关机再启动后生效：

- SDL 收到同一轮的多个画面更新时先合并变化区域，真正绘制窗口前再上传一次，减少
  切场景和过渡动画期间重复的纹理上传与 GL context 操作。
- 新建或恢复纹理时，创建操作已经上传完整画面，就不再紧接着重复上传同一张图。
- VFIO 高运动路径从连续跳过 60 次比较，改为每 8 次更新重新精确比较源画面。
  过渡动画结束、画面静止或保持全黑后，可更早停止无意义的整帧复制和上传；仍在运动
  时继续走整帧更新。

这些修改减少宿主的重复工作，仍然使用 REGION → CPU staging → 宿主 GPU → SDL。
它们不增加 Guest 软件、不改变两个资源参数，也不把当前链路变成“全程 GPU”。
如果 Guest 本身没有产生新帧，或源显示平面暂时不可用，宿主优化不会生成缺失画面。

本轮尚未完整关闭并重新启动现场 VM 测量收益，因此没有实机帧时间或提速百分比。
代码检查和构建通过也不能代替这一步。按本页的关机、启动、`verify` 和动态画面
验收步骤，以相同场景比较切换耗时、黑屏持续时间与 QEMU CPU 占用。

### 双 GPU 显示路径的边界

当 NVIDIA 提供 vGPU、AMD 等另一张 GPU 驱动宿主显示器时，当前 R535 路径仍是
NVIDIA console → 系统内存 REGION → QEMU staging → 宿主显示 GPU 纹理 → SDL。
这条链路有 CPU 读取/复制和纹理上传，不能通过 `--proxy` 或 `--memory-prealloc=false`
变成跨 GPU 零拷贝。当前 DGame GPU preview 还使用自己的私有纹理上传；导出的
DMA-BUF 属于后续预览环节，不代表原始 vGPU scanout 已能直接交给显示 GPU。
R535 的 REGION/DMA-BUF 支持边界见 [兼容性说明](COMPATIBILITY.md)。

不增加 Guest 软件、不重启 VM 的源能力实测已封装为：

```bash
python3 deploy/host/probe-vgpu-dmabuf.py --vm 1
```

本次 VM1 返回 `SOURCE_DMABUF=unsupported`、`SOURCE_REGION=supported`。此时换副卡
不能补上 NVIDIA 源头的接口；先保留现有 N+A 组合。完整条件和结果判读见
[宿主 DMA-BUF 探测教程](G11-VGPU-DMABUF-PROBE.md)。

不要为了绕过这条边界盲目提高到 120Hz Present。先完成 60Hz 的黑屏恢复和上述对比；
高帧率增加提交成本，不能修复源画面停更。

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

## R570.172.07 白名单的静态审核依据

新增的 console interval 白名单仅覆盖精确 `570.172.07`。审核对象来自官方 host
包 `nvidia-vgpu-ubuntu-570_570.172.07_amd64.deb` 内的
`usr/lib/x86_64-linux-gnu/libnvidia-vgpu.so.570.172.07`。只解压并读取文件，未安装
或加载该库，也未修改宿主参数、运行 VM；vendor 二进制不随仓库提交。

该库 SHA256 为：

```text
9f77cd0b14086b9da0792116e94882a9dbeffacec3b25ae409d3498c7b27381a
```

下表为该文件的 **ELF 虚拟地址（VMA，不是文件偏移）**，可用 `objdump -d`、
`objdump -s` 对同一哈希的库复核。符号名经过混淆，因此记录实际地址和数据流：

| 环节 | 静态证据 |
|---|---|
| 参数识别与范围 | `0xa0770` 起比较 `intervaltime`、`vgaintervaltime`；解析分支要求数值至少 `5000`，否则走错误路径并可打印对应 minimum 日志 |
| 写入有效参数 | `0xa0b90` 将 `intervaltime` 写入全局 `0x337548`；`0xa0bea` 将 `vgaintervaltime` 写入 `0x337540` |
| 实际初值 | `.data` 中上述两个 64 位槽均为 `0x186a0`，即 `100000`；参数表附近的字符串 `5000` 不能当作默认周期 |
| 实例初始化 | `0xaeb9a`、`0xaebac` 分别把两全局值乘 `1000`，保存到实例 `+0x548`、`+0x550` |
| 主周期消费 | `0xac6bb` 调用 `vmiop_thread_get_time`；`0xac6c0` 读取实例 `+0x548` 并计算下一周期边界；`0xac70f` 将结果交给 `vmiop_thread_event_wait` |
| FRL 解析 | `0xa08a0` 起识别 `frame_rate_limiter`，零值清除、非零值设置实例 `+0xe8c` 的 `0x80000000` 位；`0xa09a7` 是清位分支 |

对照本机 `libnvidia-vgpu.so.535.161.05`：有效参数写入点为
`0x82b80` / `0x82be0`，对应全局 `0x4e8528` / `0x4e8520` 也均初始为
`100000`；`0x86f4f` / `0x86f69` 同样乘 `1000` 后保存到实例。两版的最小值检查
和 FRL 零/非零位操作一致。R570 包内 `vgpuConfig.xml` 的 `V100X-1Q`、
`V100X-2Q` 均配置 `frlConfig=0x3c`、`frame_rate_limiter=1`。

开源部分的 `nvidia-vgpu-vfio.c` 也核对了修改时机：R570 的
`vgpu_params_store`（第 116 行起）仅在 `usage_count == 0` 时保存参数；第 2469 行
起把参数放入 OPEN_DEVICE 事件，`vgpu-ctldev.c` 第 319 行将其交给用户态。
R535 对应通过 `rm_vgpu_vfio_ops.update_request` 传递参数。sysfs 读回只是已保存
输入，不代表插件已应用，也不提供实际源帧率。

这些证据支持在 QEMU 打开 mdev 前，通过既有封装显式试用 `8333us`，不构成
V100 实机性能或稳定性验收。主周期存在事件唤醒路径，实际帧率仍需观测，不能仅凭
默认数值断言所有场景都恰好 10 FPS。本次没有外推其它 R570 小版本或 R580，
也没有因此删除 NVIDIA page-safe 检查。

## audit 看什么

```bash
./deploy/scripts/g11-sdl-performance.sh audit
```

它只读检查：

1. 当前源码是否认识四个 SDL 环境开关；
2. `start-vm.sh` 是否仍有 NVIDIA console interval 封装；
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

## 使用 VMate 时怎么生效

这次 QEMU 显示优化不需要修改 VMate 业务代码。VMate 的现有 Linux 打包流程会先同步
G-11 的 QEMU 构建，再把 G-11 runtime 和当前 `deploy` 一起装进新包；只更新源码或
重装以前生成的旧包不会带入修复。

同次构建会生成 `vmate_版本号_amd64.deb` 和 `gmate_版本号_amd64.deb` 两个独立包。
当前 G-11 客户端是 **GMate G11**，应安装 `gmate` 包；实际使用 VMate 客户端时才选
`vmate` 包。两个包分别更新自己的安装目录，安装 `vmate` 不会更新 `/opt/gmate`。

打包人员在包含本次修改的源码上执行现有入口：

```bash
cd /home/ubuntu/projects/vmate
VMATE_QEMU_SRC=/home/ubuntu/projects/qemu ./packaging/client/build-deb.sh
```

安装时按以下顺序操作：

1. 在 Windows 中正常关机，等待客户端中该 VM 停止、旧 QEMU 进程退出。
2. 使用构建末尾输出的本次对应安装包。下面以 G-11 的 `gmate` 包为例，将文件名中的
   `版本号` 换成实际文件名；`--reinstall` 也能覆盖包版本号相同的旧构建。

   ```bash
   sudo apt install --reinstall ./dist/client/gmate_版本号_amd64.deb
   ```

3. 重新打开实际使用的客户端，保持原来的共享 CPU、按需内存设置，正常启动 G-11 VM。
   无需重建 Windows 镜像，也无需额外安装 Guest 工具。
4. 按本页“画面不定格实机验收”复测。仅在 Windows 中点“重启”不会替换正在运行的
   宿主 QEMU；必须先让旧 QEMU 退出。

本轮没有构建或安装新的 VMate/GMate 包，也没有通过客户端重启 VM 验收；以上是交付新包时的
生效步骤，不是已经完成的现场测量。打包依据是 VMate 的
`packaging/client/build-deb.sh` 中 QEMU 构建同步、`stage_qemu_runtime_family g11`
和 `copy_deploy_assets "$QEMU/deploy"` 三个既有步骤。

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
- `RESOURCE CPU_ISOLATION` 来自当前进程的有限环境字段，`RESOURCE RAM_PREALLOC`
  来自实际 `memory-backend-memfd,id=ram0` argv；不拿本次终端的默认值代替运行值；
- `SERVICE_CPUS_APPLIED=no` 表示隔离关闭、服务核请求未应用；`unverified` 表示没有
  核验实际线程亲和力，不能据此判断是否分配成功。这些资源项不改变已有 profile 验证结果；
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
VFIO REGION；通常把 live mmap 与稳定 staging 的可见像素逐行比较，高运动时每
8 次更新重新精确比较一次，其余更新直接复制整帧。变化区域在 SDL 中合并，到实际
绘制前再上传；
比较确认完全相同时省掉无意义的上传，但仍按目标频率重复 Present 已缓存纹理。
因此 `Content 3/s | Present 60/s (fixed)` 的准确含义是“约 3 次内容更新、约 60 次窗口提交”，不是
另外 57 次没有检查源画面。

不要为了把标题中的 Content 伪装成 60 而默认强制 full copy/upload。1920x1080 BGRA
全帧约 8.3MB，60 次/秒仅 staging copy 就约 0.5GB/s，随后还有纹理上传；若 R535
没有写入新像素，复制 60 次仍是同一帧，也不会生成缺失的 Guest 光标。当前高运动
路径已在持续全画面变化时自动短时绕过逐行比较，不会让游戏永远支付双重扫描成本。

## 单窗口极致响应 A/B

默认档先通过后，想比较更快的键鼠处理时，完整关闭 Windows 后运行：

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
| QEMU service CPU | `auto` | 仅开启 CPU 隔离时参与服务核分配；共享 CPU 模式不应用 |
| USB 键盘/相对鼠标 | `1ms` | 本次启用 low-latency HID descriptor；绝对 tablet 原本就是 1ms |
| Present | `fixed 60Hz` | 即使静止也重复提交缓存纹理 |

当前正常 vGPU 启动默认关闭 CPU 隔离，因此上面的 ultra 命令主要比较输入轮询和
USB endpoint 的变化，不能声称已经为 main/GL/I/O 分配了服务核。确需单独测试隔离
和服务核时，在完整关机后执行：

```bash
./deploy/scripts/g11-sdl-performance.sh start 9 --ultra-responsive --cpu-isolate=true
```

隔离需要宿主有足够可分配的核，并通过启动器的 helper 校验；`auto` 服务核在容量
不足时可以回到 0。检查启动输出的隔离结果；`verify` 中的环境请求不能替代实际线程
亲和力检查。回退只需完整关机，下一次省略 `--ultra-responsive` 并明确使用
`--cpu-isolate=false`；不写配置、不改 BCD、不安装 Guest 驱动。

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

1. 从完整关机启动 VM，确认摘要有 `NVIDIA <实际驱动版本>` 和
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

- 本次修复让纹理上传函数的失败结果真正传回 SDL，触发已有重试；每次渲染还会显式
  绑定当前画面纹理，避免同一 GL context 其他操作留下的纹理绑定使窗口采样错误画面。
  同时移除 shader 渲染不需要的 `glEnable(GL_TEXTURE_2D)`，避免 OpenGL core context
  将它报为非法操作，导致正常纹理被误判失败并反复重建。
  按开头步骤重新编译后，需让 Windows 正常关机、QEMU 退出，再启动 VM 才会加载修复。
  这些代码修复不能保证解决现场所有黑屏，仍需完成动态画面与恢复验收。
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

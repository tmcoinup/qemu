# fb-shm —— 共享内存推流通道（默认开）

deploy bundle 的默认显示模式是 fb-shm 推流：guest 完全不可见地把 framebuffer 写到
host 一块共享内存里，外部进程通过一个 unix socket 拿 fd 读帧推 ffmpeg / NVENC。
反作弊看不到任何额外 PCI 设备 / 驱动，与 NVIDIA-spoof virtio-gpu + ACE 浅层
stealth 完全兼容。

底层 ABI 与 `-display fb-shm` / `-object fb-shm` 的 QEMU 文档：
[`docs/system/fb-shm.rst`](../../docs/system/fb-shm.rst) ·
[`include/ui/fb-shm-abi.h`](../../include/ui/fb-shm-abi.h)

## SDL 与 fb-shm 默认并存

| 命令 | 本地窗口 | 远程显示 | 推流通道 |
|---|---|---|---|
| `start-vm.sh 1`              | **SDL** | 无 | **fb-shm** |
| `start-vm.sh 1 --no-sdl`     | 无 | 无 | fb-shm（后台 daemon）|
| `start-vm.sh 1 --headless`   | 无 | VNC | + fb-shm |
| `start-vm.sh 1 --no-fb-shm`  | SDL | 无 | — |
| `start-vm.sh 1 --headless --no-fb-shm` | 无 | VNC | — |

`nohup ... &` 之类无 DISPLAY 又非 tty 的场景会自动降级 `--no-sdl`，避免 SDL crash。

QEMU 端实现：fb-shm 注册成 `-object fb-shm,id=stealth-${N},...` 用户可创建对象，
在 `machine_init_done` 后给 console 0 装一条独立 `DisplayChangeListener`。`-display`
插槽留给 SDL/none/VNC 用，互不干扰。

## 默认参数

| Knob | 默认 | 含义 |
|---|---|---|
| Socket | `/tmp/qemu-stealth-${INSTANCE}.fb` | `--fb-shm-sock=PATH` 覆盖 |
| 帧率   | `60` Hz                            | `--fb-shm-rate=N`（钳位 [1,240]）|
| ROI    | 全屏                                | `--fb-shm-roi=x,y,w,h` |
| 像素   | `BGR0`（x8r8g8b8 LE）                | 由 ABI 决定，不可改 |
| 双缓冲 | 2 个 ROI 大小的槽 + atomic seq      | `include/ui/fb-shm-abi.h` |

## 单 VM：录到本地 mp4

```bash
deploy/scripts/start-vm.sh 1                                         # 后台跑

# 另开终端
scripts/qemu-fb-shm-stream.py --sock /tmp/qemu-stealth-1.fb \
    --output /tmp/vm1.mp4 \
    --encoder libx264 --preset veryfast --bitrate 4M
```

## 单 VM：推 RTMP / NVENC

```bash
scripts/qemu-fb-shm-stream.py --sock /tmp/qemu-stealth-1.fb \
    --output 'rtmp://ingest.example/live/vm1' \
    --encoder h264_nvenc --preset p1 --bitrate 6M --gop 60
```

NVENC 消费级显卡默认 5 路同时推流上限，超出加 [nvidia-patch] 解锁。

## 单 VM：低带宽 / ROI 推流（DNF 1080p 主战场）

```bash
deploy/scripts/start-vm.sh 1 \
    --fb-shm-roi=0,0,1280,720 --fb-shm-rate=30      # host 端只截 720p

scripts/qemu-fb-shm-stream.py --sock /tmp/qemu-stealth-1.fb \
    --output 'udp://127.0.0.1:5000?pkt_size=1316' \
    --encoder h264_nvenc --bitrate 3M
```

ROI 是在 QEMU 进程里通过 `pixman_image_composite32` 一次完成裁剪 + BGR0 格式转换，
省下的内存带宽和编码器算力都是真实节约。

## 一个 VM：多个订阅端并行

一个 fb-shm socket 可以同时被多个消费端连接 —— 比如一边 RTMP 推流一边本地归档：

```bash
./deploy/scripts/start-vm.sh 1                                  # 起 VM

# 终端 A: RTMP 推 NVENC
scripts/qemu-fb-shm-stream.py --sock /tmp/qemu-stealth-1.fb \
    --output 'rtmp://ingest/live/vm1' --encoder h264_nvenc --bitrate 6M &

# 终端 B: 本地存档 x264
scripts/qemu-fb-shm-stream.py --sock /tmp/qemu-stealth-1.fb \
    --output /tmp/vm1.mp4 --encoder libx264 --preset veryfast &

# 终端 C: 自定义 Rust/Python 分析（仅读像素，不编码）
./my-pixel-analyser --sock /tmp/qemu-stealth-1.fb &
```

每个消费端经 `SCM_RIGHTS` 各拿一份 memfd + eventfd（kernel 引用计数），
**全部 mmap 同一块物理页 → 零额外内存代价**。慢消费端只会自己跳帧，不反压 QEMU
也不影响其它端。

实测 3 个并行消费端 30Hz × 2 秒：A=62 帧，B=62 帧，C=62 帧，seq 范围对齐
1..62，无丢失。

边界：
- `listen` backlog = 16，超过 16 个**并发 connect()** 才会 ECONNREFUSED
  （现实里消费端慢慢接入不会撞）。
- eventfd doorbell 共享 —— 第一个 read 拿走计数，其他端见 EAGAIN 但已经被
  level-triggered 唤醒；靠 `frame_seq` seqlock 判断有无新帧（参考 consumer
  脚本已正确处理）。
- 各消费端可独立选不同 ROI/编码/帧率（每端跳过它不需要的 frame_seq）。

## 多 VM：每台独立推流

```bash
# 起 4 台
for i in 1 2 3 4; do
    nohup deploy/scripts/start-vm.sh $i > /tmp/qemu$i.log 2>&1 &
done

# 用编排器把每台绑独立 CPU 核 + 独立 NVENC 会话
cat > /tmp/multivm.yaml <<'EOF'
vms:
  - id: vm1
    sock: /tmp/qemu-stealth-1.fb
    output: rtmp://ingest/live/vm1
    encoder: h264_nvenc
    cpus: "0-3"
  - id: vm2
    sock: /tmp/qemu-stealth-2.fb
    output: rtmp://ingest/live/vm2
    encoder: h264_nvenc
    cpus: "4-7"
  - id: vm3
    sock: /tmp/qemu-stealth-3.fb
    output: udp://127.0.0.1:5003?pkt_size=1316
    encoder: h264_nvenc
    cpus: "8-11"
  - id: vm4
    sock: /tmp/qemu-stealth-4.fb
    output: udp://127.0.0.1:5004?pkt_size=1316
    encoder: h264_nvenc
    cpus: "12-15"
EOF
scripts/qemu-fb-shm-multivm.py --config /tmp/multivm.yaml
```

`--cpus` 给每路消费进程绑独立核，编码慢的一路不会反压其它 VM。

## 边玩边录（默认就是这样）

```bash
deploy/scripts/start-vm.sh 1             # SDL 窗口直接弹出，可以玩
# 同时另起一个推流（共用一个 fb-shm socket）
scripts/qemu-fb-shm-stream.py --sock /tmp/qemu-stealth-1.fb \
    --output /tmp/replay.mp4 --encoder libx264
```

QEMU 内部 SDL 是一条 DCL，fb-shm 是另一条 DCL，guest 一份 surface 同步广播给两边。

## 运行时切换通道（不关机）

`deploy/scripts/ctl-vm.sh <INSTANCE> <action>` 走 QMP 调控当前显示通道。三组动作：

| 一键动作 | 等价 | 用途 |
|---|---|---|
| `stream-only` | sdl 暂停 + fb-shm 恢复 | 配置完进入纯推流，CPU 让给 NVENC |
| `sdl-only`    | fb-shm 暂停 + sdl 恢复 | 临时不录、专心玩 |
| 细粒度       | `sdl-hide` / `sdl-show` / `fb-pause` / `fb-resume` / `fb-off` / `fb-on [rate]` | 手动控制 |

典型流程：

```bash
# 1) 起 VM，SDL 窗口和 fb-shm 同时开
./deploy/scripts/start-vm.sh 1

# 2) 用 SDL 窗口装驱动 / 配设置...（约 10 分钟）

# 3) 切换到纯推流：SDL 窗口隐藏（DCL 暂停），fb-shm 全速跑
./deploy/scripts/ctl-vm.sh 1 stream-only

# 4) 启外部消费端（NVENC 推 RTMP）
scripts/qemu-fb-shm-stream.py --sock /tmp/qemu-stealth-1.fb \
    --output 'rtmp://...' --encoder h264_nvenc --bitrate 6M

# 5) 临时回去操作
./deploy/scripts/ctl-vm.sh 1 sdl-show

# 6) 又切回纯推流
./deploy/scripts/ctl-vm.sh 1 sdl-hide
```

QMP 命令直接调用：

```bash
QMP=/tmp/qemu-stealth-1.qmp
echo '{"execute":"qmp_capabilities"}{"execute":"display-pause","arguments":{"name":"sdl2"}}' \
    | socat - UNIX-CONNECT:$QMP

echo '{"execute":"qmp_capabilities"}{"execute":"display-resume","arguments":{"name":"sdl2"}}' \
    | socat - UNIX-CONNECT:$QMP
```

`name` 走前缀匹配：`sdl2` 同时命中 `sdl2-2d` / `sdl2-gl`；`fb-shm` 命中 fb-shm DCL。

| 动作          | DCL refresh | SDL 窗口 | host CPU 节省 (1080p60) |
|---|---|---|---|
| `display-pause sdl2` | 跳过 | `SDL_HideWindow` | ~3-7% 一个核 + GPU 唤醒 |
| `display-resume sdl2` | 恢复 | `SDL_ShowWindow` + `graphic_hw_invalidate` 触发重绘 | -- |
| `display-pause fb-shm` | 跳过 | -- | ~1-2% 一个核 |
| `object-del stealth-N` | unregister | -- | 同上 + 释放 memfd / socket |

## 反检测视角

* **没有新增 PCI 设备 / 驱动 / ACPI 表项**：fb-shm 完全在 host 进程地址空间里
  做事，guest CPU 看不到任何 MMIO / PIO / DMA 改动。
* **不改 USB HID / GPU PCI ID**：跟现有 ACE 浅层 + NVIDIA-spoof virtio-gpu 兼容；
  `apply-gpu-spoof.ps1` 注册表覆盖照常生效。
* **CPU 开销**：每帧一次 `pixman_image_composite32`（4 KB 主循环 ~1.5 GB/s 带宽）
  + 一次 atomic store + 一次 8 字节 `write(eventfd)`。1080p60 实测 ≤2% 一个 vCPU。
* **不与 memflow 冲突**：fb-shm 用独立 memfd，不动 guest RAM 的
  `memory-backend-memfd,share=on` 路径；VMI 工具继续直读 guest 物理内存。

## 抓单帧（替代 QMP screendump）

`QMP screendump` 是单连接、走 PPM/PNG 编码 + 文件 I/O 的慢路径。如果工具只是想
偶尔抓一张图（比如 image-search 的"找按钮"），强烈建议改走 fb-shm：

* fb-shm 抓帧 = 一次 mmap + 一次 seqlock 读 + memcpy，typical 1080p < 10 ms；
* QMP screendump = encode + write file + read file，typical 1080p > 100 ms；
* fb-shm 是多订阅的，不和 dgame 抢 QMP 单 slot。

参考 Python：抓一帧存 PNG 的 ~30 行：

```python
import importlib.util, sys
spec = importlib.util.spec_from_file_location(
    'fbshm', '/path/to/qemu/scripts/qemu-fb-shm-stream.py')
m = importlib.util.module_from_spec(spec); sys.modules['fbshm']=m
spec.loader.exec_module(m)

sock, mfd, evfd, ack = m.hello('/tmp/qemu-stealth-1.fb')
r = m.FrameReader(mfd, evfd, ack[0])
r.wait_frame(timeout=1.0)
frame = r.read_frame()                # bytes, BGR0
# frame -> PIL/Image / OpenCV / 直接喂模型
```

如果调用方暂时无法改（比如某些工具只会 QMP），用 `deploy/scripts/qmp-proxy.py`
做 QMP 多客户端 fanout（短期 workaround，见 [USAGE.md 6.4](USAGE.md#64-qmp-多客户端qmp-proxypy)）。

## 故障排查

| 现象 | 原因 / 修法 |
|---|---|
| `bind() failed: Permission denied` | `FB_SHM_SOCK` 指到 root-only 目录；改用 `/tmp/qemu-stealth-N.fb`（默认）或 `chmod g+w`。|
| `recvmsg: connection refused` | QEMU 还没启动到 `machine_init_done`；等 1-2 秒重试，或脚本里循环 `until [ -S $SOCK ]; do sleep 0.1; done`。|
| 帧率达不到 `--fb-shm-rate` | guest 自己渲染速度低（idle 时驱动不重画），属正常；按生产端 commit 节奏走。|
| HELLO 后 `frame_seq` 不动 | guest 还在黑屏 / ESC 启动菜单；进系统后会回正。|
| 拉到的画面是 `bgr0` 不是 `nv12` | ABI v1 输出 BGR0；`pix_fmt bgr0 -> NV12` 转换让 NVENC 自己做（CUDA 上去），效率更高。|

## 参考

* [`docs/system/fb-shm.rst`](../../docs/system/fb-shm.rst) — QEMU 上游级文档（架构图、ABI、性能策略、GPU passthrough 替代）
* [`scripts/qemu-fb-shm-stream.py`](../../scripts/qemu-fb-shm-stream.py) — 参考消费端
* [`scripts/qemu-fb-shm-multivm.py`](../../scripts/qemu-fb-shm-multivm.py) — 多 VM 编排器
* [`include/ui/fb-shm-abi.h`](../../include/ui/fb-shm-abi.h) — 二进制 ABI

[nvidia-patch]: https://github.com/keylase/nvidia-patch

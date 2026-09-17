# G-11 SDL 标题栏 `Content` 掉低：审查结论、优化与傻瓜教程

本页适用于 G-11 的 **VFIO REGION → staging → SDL** 路径。仅凭
`-display sdl` 和 `display=on` 不能确定走 REGION：`vfio_display_probe()`
先探测 DMA-BUF，再探测 REGION；走 DMA-BUF 的设备不使用本页新增优化。
V-11 是独立分支，不直接套用这里的 vGPU 方案。

## 1. 审查后采用哪些修改

| 原方案 | 处理结果 | 理由与边界 |
|---|---|---|
| 优化 1：减少整屏上传 | **已实现** | 删除 dirty 行数 ≥50% 就整屏更新的阈值，改用实际纵向包围盒；不引入缺少基准依据的 90% 阈值 |
| 优化 4：REGION 静止观测 | **已实现有限版本** | 显式开启后按 2/10/30 秒分级报告观测到的像素静止，恢复变化时报告一次；不把静止当故障，也不声称能区分 guest 和驱动原因 |
| 游戏持续运动时跳过比较 | **已作为正常 G-11 启动默认** | 每次全量复制 staging，再发一次全屏更新；`--game-content-compare` 可显式回退为比较加局部上传 |
| 稀疏探针替代全屏比较 | **本次新增评估，未实施** | 以互质质数步长抽样 64 B 探针 + 每帧轮转相位，只用于快速否决“无变化”；命中仍走精确比较。静止场景读取量约降至 1/64，不改善游戏持续运动，详见第 6 节 |
| 优化 2：独立 poller 线程 | **暂不实施** | 主线程总 CPU 不能证明比较阶段是瓶颈；还需阶段耗时证据、缓冲所有权设计和模式切换压力验证 |
| 优化 3：按像素变化推断供帧周期 | **不采用原推导** | 相邻变化时间不是驱动供帧时间；缺少帧序号和写入完成信号，不能可靠锁相或保证不丢帧 |

本次修改不调整 `QEMU_SERVICE_CPUS` / svc-cpus、不改宿主 `intervaltime` 配置，
也不提高 SDL 的目标帧率。没有修改 BCD、开启 `testsigning` / `nointegritychecks`，
或安装测试签名/自签名内核驱动；封装不保存宿主凭据。

### 已实现的上传优化

`vfio_region_update_staging()` 继续逐行比较、把变化像素复制到 staging。
`vfio_region_update_bounds()` 取第一个 dirty run 的起点和最后一个 run 的终点，
合成一个纵向范围，`vfio_display_region_update()` 每次仍只发出一次更新。

- 1920×1080 中间连续 600 行变化：原来请求上传 1080 行，现在请求 600 行，
  **这次纹理上传的像素量减少 44.4%**。
- 分散的变化会包含中间未变行；若首尾都变化，包围盒自然是整屏。
- 超过 32 个 dirty run 时列表不完整，继续整屏更新，避免漏掉末尾变化。
- 初始 surface、故障后强制刷新、既有高运动跳过比较仍可整屏更新。
  SDL 重建纹理或恢复窗口时也可能要求全量上传。

这项修改减少的是更新范围，并没有消除全屏比较；44.4% 不是整条链路、CPU 占用
或帧率的收益承诺。收益取决于实际 dirty 分布和监听器的上传方式。

### 游戏模式为什么可以不比较

比较用于跳过重复上传、计算局部更新范围和观测像素变化，不是 VFIO 显示的必要条件。
用户补充的 f1→f2 微基准如下；本次没有重跑该基准：

| 像素处理方式 | 用户报告的耗时 | 按 60 次/秒折算单核运行时间 |
|---|---:|---:|
| 静止帧逐行比较 | 0.701ms | 4.2% |
| 游戏帧比较并复制 600/1080 个变化行 | 2.751ms | 16.5% |
| 不比较、全量 memcpy | 0.623ms | 3.7% |

这组数据中，比较加局部复制的耗时约为全量复制的 4.4 倍，差 2.128ms/次，
按 60 次/秒折算约 12.8 个百分点单核时间。**在修改前的 50% 阈值实现里，
600 行变化也会整屏上传，两种做法最终请求的上传量相同**，因此该场景下比较
没有换来上传量节省。修改后的 compare 模式可上传 600 行，再与全量复制模式比较
时，则要把额外 480 行的 GL 上传成本也计入。

逐行交替比较/复制与大块顺序复制的访问方式不同，确实值得实测；但仅凭耗时
不能确定硬件预取被打断或 memcpy 使用了 non-temporal store。具体指令和缓存
行为需要本机 libc/CPU 的反汇编、性能计数器及相同缓存条件的基准支持。
这些数值也不能直接拆分另一段采样中主线程总计 27.6% 的每项来源。

`QEMU_VFIO_REGION_UPDATE_MODE=copy` 在正常更新中跳过所有像素比较，
只执行一次全量 staging 复制和一次全屏更新。正常 G-11 启动器默认传 `copy`；
直接调用裸 QEMU 且未设置该变量时，底层仍默认 `compare`。
QUERY、布局/映射校验、失败退避和稳定 staging 仍保留，不让 SDL 直接读取
驱动正在写入的映射。首次建图、恢复和无 plane 分支也仍按既有安全路径处理。

copy 模式不能判断源是否真的变化，静止画面也会重复上传。它的 `Content`
是内容更新通知速率，可能接近 Present，不能拿这个数值上升当作 guest FPS 提升。
该模式不产生像素静止报告；封装拒绝同时使用 `--game-content-copy` 和
`--content-diagnostics`，避免把“未比较”误读成“已经确认画面持续变化”。

### 已实现的静止观测

QEMU 环境变量 `QEMU_VFIO_REGION_IDLE_REPORT=1` 开启报告，默认关闭。
推荐通过下文的 `--content-diagnostics` 封装启用。

只有完成了精确像素比较的样本才参与观测。每段静止在 2/10/30 秒阈值各报一次
`info`，携带 REGION 编号、宽、高、stride 和 DRM format；长时间没有采样后，
只报告已跨过的最高一级，不补打一串日志。确认像素重新变化时再报一次。

失败、没有 plane、切换 REGION/模式、强制全量复制和高运动跳过比较都会重置
观测。没有执行比较的时段不能作为“确认像素未变”的样本。
这项报告不依赖 fb-shm consumer；默认关闭时不读取额外计时时钟。

日志表示“在这些采样中未观察到变化”，不证明采样间隔内源完全静止，
也不证明 guest 卡死。正常静止桌面同样会触发。整幅图只要聊天框、时钟等区域
仍变化，就可能不触发，因此它也不能单独诊断黑色游戏 ROI。

### GPU 优先策略与当前边界

本方案遵循“能使用 GPU 的阶段优先使用 GPU”。当前已有以下路径：

| 阶段 | 现有 GPU 路径 | REGION 回退的限制 |
|---|---|---|
| VFIO scanout | 先探测 DMA-BUF，拿到有效 FD 后由 EGL 导入纹理 | 驱动只提供 REGION 时，源是宿主 mmap 指针，不能直接当 DMA-BUF 导入 |
| SDL 绘制 | GL 纹理上传、shader 绘制和交换 | staging 仍由 CPU 维护；`--game-content-copy` 是 CPU memcpy，不是 GPU copy |
| DGame/fb-shm 预览 | 默认请求 GPU 路径，具备 GPU 裁剪、DMA-BUF 导出与 fence 同步 | 实际取决于硬件和客户端能力；CPU surface 模式仍需上传 ROI，SHM consumer 仍可能需要 CPU 数据 |

这些路径已经存在，本次保留 GPU 优先选择。DMA-BUF 显示还要求合适的 EGL context；
单有 `gl=on` 不代表源可零拷贝。对仅有 REGION 的设备，现有 GPU helper 接收的是
真实 DMA-BUF FD 或 GL texture，没有把任意 VFIO mmap 注册为 GPU 可访问资源的接口。

先上传再让 GPU 比较，会保留整帧上传成本；若仍要 CPU 使用 dirty 行结果，还需
同步/回读。因此本次没有新增 GPU 比较，也没有把 CPU 复制包装成 GPU 加速。
后续更值得评估的是 SDL 与 fb-shm 共享已上传纹理、减少重复上传，但必须先解决
更新顺序、context 同步、纹理生命周期和窗口隐藏后的更新责任。

## 2. 最短使用步骤

在仓库根目录执行构建与验证：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/build-qemu.sh
./deploy/tests/run-g11-sdl.sh
./deploy/scripts/g11-sdl-performance.sh audit
```

三条均成功后，在 Windows 中完整关机，等旧 QEMU 进程退出，再启动新二进制。
以后直接通过唯一启动器启动即可，以 VM1 为例：

```bash
./deploy/scripts/start-vm.sh 1 --proxy
```

正常 G-11 vGPU SDL/GTK 默认等价于
`--cpu-isolate=false --memory-prealloc=false --game-content-copy`：共享 CPU、按需 RAM、
REGION 全量复制。无需先运行性能封装，也无需每次重复三个默认参数。
显式 CPU 环境策略或 CLI 参数仍可覆盖默认；安装、救援等模式保留原有资源策略。

`g11-sdl-performance.sh start 1 --proxy` 同样采用这些默认值，并附带自己的
SDL 档位设置。两个启动入口都接受 `--game-content-copy`、`--game-content-compare`
和 `--content-diagnostics`，不写入 `vm.conf`。

要比较收益，在 Windows 完整关机后改用：

```bash
./deploy/scripts/start-vm.sh 1 --proxy --game-content-compare
```

这会仅对本次启动启用比较加局部上传。保持同一场景，比较主线程 CPU、Present、可见
卡顿和输入延迟，不用 Content 上升作为收益判据。

需要调查像素静止时，另一次完整关机后选择以下诊断启动；开关只影响本次启动：

```bash
./deploy/scripts/start-vm.sh 1 --proxy --content-diagnostics
```

诊断开关自动选择 compare 并开启静止报告，无需另传 `--game-content-compare`。
显式复制与比较/诊断开关不能同时指定。若想恢复 CPU 隔离和全量内存预分配，可使用：

```bash
./deploy/scripts/start-vm.sh 1 --proxy --cpu-isolate=true --memory-prealloc=true
```

上述启动命令选择一条执行。使用游戏复制模式时也可追加原有资源参数。
封装会检查所选新功能是否存在于当前二进制；旧 build 不会静默忽略开关。
现有 balanced/ultra/multi-vm 档位策略不因这两个开关改变。
显式 compare 模式的局部上传优化自动生效，不依赖诊断开关。

启动后另开一个宿主终端：

```bash
./deploy/scripts/g11-sdl-performance.sh verify 1
```

开启诊断时应看到 `ENV QEMU_VFIO_REGION_IDLE_REPORT=1`。这只确认进程参数，
不证明本 VM 一定采用 REGION 路径，也不证明每次 Present 都有新画面。
普通启动应看到 `ENV QEMU_VFIO_REGION_UPDATE_MODE=copy`；显式比较或诊断为 `compare`。
直接启动摘要也会打印 `REGION UPDATE_MODE=copy IDLE_REPORT=0（仅本次启动）`。

默认目录下查看日志；自定义存储目录时，把路径换成启动输出中的 QEMU 日志路径：

```bash
tail -F /home/ubuntu/images/vms/1/log/qemu.log
```

静止时会出现如下字段：

```text
vfio-display-region: idle level=1 unchanged_ms=... region=... width=... height=... stride=... drm_format=...; no pixel change observed, guest/driver cause unknown
vfio-display-region: pixels changed after unchanged_ms=... region=... width=... height=... stride=... drm_format=...
```

验证时先显示持续运动的内容，再保持静止超过 30 秒，最后恢复运动。
静止期间每级最多一条，恢复后应有变化报告；普通桌面有时钟、光标闪烁时，
可能一直不满足全屏静止条件。没有日志不能推出 REGION 健康或损坏。

关闭诊断：Windows 完整关机后，删除启动命令中的 `--content-diagnostics` 再启动。
封装会明确传 `QEMU_VFIO_REGION_IDLE_REPORT=0`，不继承外层 shell 遗留的启用值。
普通启动同时恢复 copy；若要关闭日志并保留比较，则使用 `--game-content-compare`。
这些选择只影响新启动进程，不改变运行中的 VM。

## 3. `Content` / `Present` 实际测什么

```text
guest 渲染 → 驱动发布 VFIO console REGION
                     ↓
graphic_hw_update() → vfio_display_region_update()
                     ↓ QUERY_GFX_PLANE、比较/复制到 staging
              dpy_gfx_update()
                     ↓
              sdl2_gl_update() → sdl2_note_content_update()
                     ↓ 累积 damage
              sdl2_gl_refresh() → 纹理上传、绘制、swap
                                             ↓
                                    sdl2_note_present()
```

代码入口：[`hw/vfio/display.c`](../../hw/vfio/display.c)、
[`display-region-motion.h`](../../hw/vfio/display-region-motion.h)、
[`ui/sdl2-gl.c`](../../ui/sdl2-gl.c)、[`ui/sdl2.c`](../../ui/sdl2.c)。

`Content` 是 **SDL 收到的、在 pending 标志清除前去重的内容更新通知次数/秒**。
正常 REGION 精确比较时，它通常对应观察到的像素变化，但不是 guest FPS：

- 高运动路径可连续跳过 7 次比较，每次仍复制并通知更新。
- surface 切换、故障恢复后的强制更新也会计数，即使没有证明像素变了。
- 内容通知发生在上传/present 之前，上传或交换失败时，Present 不一定增加。

因此不能写成无条件的 `Content ≤ Present ≤ QEMU_SDL_TARGET_FPS`。
目标 FPS 是刷新节奏；计数窗口、手动重绘、其他更新触发及失败路径都有影响。
在健康稳定的 60Hz 刷新中，Content 通常不会超过该节奏，但仍只是观察指标。

固定 Present 模式允许反复显示同一帧，所以 `Present≈60、Content≈1` 可以出现。
稳定静止画面通常为 `Content=0`，高运动刚停止时还可能有少量冗余通知。
`Present=0` 也不是窗口最小化的充分证据，还要检查渲染失败、进程状态和标题
是否仍实时更新。Wayland 的静态标题模式不能用于现场实时测量。

## 4. 原现场记录与归因边界

以下保留原文标注的 2026-09-16 vm3 记录：RTX 2080 / GRID RTX6000-2Q /
host driver 535.161.05 / SDL GL / 1920×1080 / DNF 窗口化。
**本次是源码审查及本地回归测试，没有连接该宿主复测，也没有据此宣称实机提升。**

| 原记录 | 值 | 可得出的结论 |
|---|---|---|
| 正常态标题（60 秒） | Content 43–52/s，Present 59.9–60.0/s | 两个计数器确实可能不同；不能单独确定 guest FPS |
| 主线程 schedstat（10 秒） | 2756ms，约 27.6% 单核 | 是主线程总运行时间，不是 memcmp 专属耗时 |
| console REGION 映射 | 16MB，`rw-s`，VmFlags 无 `io` | 不能仅凭这些字段确定 CPU 缓存属性；代码读取源但 mmap 本身并非只读映射 |
| mdev 配置 | intervaltime=16667 | 是配置周期；实际发布节奏仍需测量 |
| FRL 显示 | N/A | 单独的 N/A 不足以证实限流已关闭，还需实际参数 |
| 三张正常态截图的差异 | 600/1080 行，1–3 runs，包围盒放大 1.00–1.02× | 支持构造局部更新场景；截图间隔不是每次刷新间隔，不能推成每帧分布 |
| 正常态 screendump | 有完整游戏画面 | 说明采集时 staging 有画面；不能排除异常时其他环节故障 |

原文按全屏 `memcmp`、dirty `memcpy`、全屏上传估出约 34MB/帧、50Hz 时约
1.7GB/s，只能作为粗略成本模型。memcmp 遇到差异可以提前返回，CPU 缓存、实际
轮询频率和高运动 bypass 也影响流量，不能凭模型认定主线程 27% 就是该阶段成本。

### 排查顺序

1. 确认窗口可见、标题实时更新、QEMU 仍运行，检查 SDL/GL 错误。
2. 查 REGION 查询、映射、布局及恢复日志。100ms 是**失败后重试间隔下限**，
   对应重试频率至多约 10Hz；持续失败时 Content 完全可能为 0 或 1。
   ioctl 和 mmap 的已有报错不都以 `vfio-display-region:` 开头，不能只查该前缀。
3. 同时比较异常时的 QEMU screendump、宿主窗口和 guest 渲染/事件证据。
   黑游戏画布、周边 UI 正常与供帧路径异常相容，但不能单凭截图确定是驱动未送帧，
   更不能直接断言 DWM 中游戏区域本来就是空的。
4. 有了同步证据后再分析 guest 没产生变化、驱动没发布、采样/上传失败各占多少。
   仅凭静止像素、plane 元数据或 Content 计数无法把这几种原因完全分开。

`vfio_display_region_update()` 已经在每次通过失败退避检查后执行
`QUERY_GFX_PLANE`。再次查询不是新增修复手段；元数据相同也不能证明 guest 停止供帧。

## 5. 现场截图的正确用法

`screendump` 会请求一次硬件更新，再保存 console surface；在 REGION 路径通常
读取 staging，绕过 SDL 的纹理上传和窗口交换。更新失败仍可能读到上一张 staging，
默认选择 console 0。因此两次截图相同只表示**这两次采集结果相同**。

在运行 QEMU 的宿主、以同一用户执行下面整段。默认 VM3；自定义目录时先修改
`QMP`，多显示设备时设置 `DEVICE` 为实际显示设备 ID。截图会保存在临时目录，
QMP 错误或超时会明确失败，不把截图失败误判成零差异：

```bash
QMP=/home/ubuntu/images/vms/3/run/qmp.sock
OUT=$(mktemp -d /tmp/g11-content.XXXXXX)
DEVICE=''
python3 - "$QMP" "$OUT" "$DEVICE" <<'PYCODE'
import json
import pathlib
import socket
import sys
import time

endpoint, folder, device = sys.argv[1:]
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    sock.settimeout(10)
    sock.connect(endpoint)
    stream = sock.makefile('rwb', buffering=0)
    greeting = json.loads(stream.readline())
    if 'QMP' not in greeting:
        raise RuntimeError('不是 QMP socket')

    def command(name, arguments=None):
        request = {'execute': name, 'id': name}
        if arguments is not None:
            request['arguments'] = arguments
        sock.sendall((json.dumps(request) + '\n').encode())
        while True:
            line = stream.readline()
            if not line:
                raise RuntimeError('QMP 连接已关闭')
            response = json.loads(line)
            if response.get('id') == name:
                if 'error' in response:
                    raise RuntimeError(response['error'])
                return response['return']

    command('qmp_capabilities')
    frames = []
    for index in range(3):
        path = pathlib.Path(folder) / f'frame-{index + 1}.ppm'
        args = {'filename': str(path), 'format': 'ppm'}
        if device:
            args['device'] = device
        command('screendump', args)
        data = path.read_bytes()
        if not data.startswith(b'P6\n'):
            raise RuntimeError(f'无效 PPM: {path}')
        frames.append(data)
        print(path)
        if index < 2:
            time.sleep(0.4)
    for index in range(2):
        print(f'{index + 1} → {index + 2}:',
              '采集结果相同' if frames[index] == frames[index + 1]
              else '采集结果不同（还需检查尺寸/像素差异）')
PYCODE
```

- staging 有完整动态画面而宿主窗口黑/不动：继续查 SDL/GL 和窗口状态。
- staging 也黑或相同：结合查询/映射日志、静止报告和 guest 证据，不能直接归咎 vGPU。
- 截图发生变化也不证明游戏 ROI 正常；应查看具体画布区域，而不只比较整份文件。

截图操作本身会触发额外更新，采集时序也不能代表未取证时的稳态 FPS。

## 6. 稀疏探针：用抽样代替全屏比较（本次新增评估，未实施）

现在只有两档：`compare` 对源和 staging 做逐行比较，`copy` 完全不比较。
正常 G-11 启动默认 `copy`，裸 QEMU 未设置策略时默认 `compare`。
稀疏探针是中间一档——**先用极少量抽样回答“有没有变”，命中了再做精确逐行比较
取包围盒**。下面的数据都来自本次在宿主上跑的微基准，实现代码尚未提交。

### 它解决什么，不解决什么

- **目标是静止和低动态**：桌面挂机、游戏读条、窗口被完全遮挡。此时 `compare`
  每帧照样读满两份全屏，而结论恒为“没变”。
- **不针对游戏持续运动**。探针几乎每帧命中，仍要走精确比较，还要多付探针本身
  的成本。游戏工况仍由 `copy` 模式覆盖，两者互补而不是替代。
- 它**不减少上传量**，只减少“确认无变化”的读取量。包围盒逻辑不受影响。

### 三个设计要点，缺一不可

**① 步长必须与 stride 互质。** 这是本次最容易被忽略的一条。按固定字节步长撒点
时，探针的横坐标只能落在 `gcd(步长, stride)` 决定的少数几列上：

| 探针步长 | `gcd(步长, 7680)` | 探针可落的字节列数 | 列间距 |
|---:|---:|---:|---:|
| 1024 / 4096 / 8192 / 16384 | 512 | 15 | 128 像素 |
| 4099（质数） | 1 | 7680 | 全覆盖 |

1920×1080 的 stride 是 7680，所有 2 的幂步长都退化成 15 列、128 像素间距。
一个 8 像素宽的变化块因此有很大概率整个落进列间距里。**选质数步长**可回避：
4099 是质数，与下列常见模式的 stride 全部互质（本次已逐个核验）——
1920×1080、1920×1200、1600×900、1280×1024、1280×720、1024×768、
2560×1440、3840×2160、800×600。这条对 1 GB 的 1Q profile 同样成立。

**② 每帧轮转探针相位。** 相位固定时，一个静止的小块会被**每帧确定性漏检**，
不是概率问题。第 f 帧从 `(f × 64) % 步长` 起扫，才能把漏检变成有界延迟。

**③ 保留强制全量兜底。** 探针永远只能给出“肯定变了”，给不出“肯定没变”。
计数超过上限就无条件走一次全量比较，作为安全网。

### 本次实测：成本

1920×1080（一屏 7.91 MB），64 B 探针粒度，单核，探针全未命中（最坏情况，
要扫完全部探针；命中时提前返回更快）：

| 方式 | 探针数 | 读取量 | ms/帧 | 按 60 次/秒折算单核 |
|---|---:|---:|---:|---:|
| 步长 4099 | 2023 | 253 KB | 0.028 | 0.17% |
| 步长 6151 | 1348 | 169 KB | 0.018 | 0.11% |
| 步长 12289 | 674 | 84 KB | 0.008 | 0.05% |
| **全量逐行（现状）** | 1080 行 | **16200 KB** | **0.699** | **4.19%** |

步长 4099 的读取量约为全量的 **1/64**，实测耗时约为 **1/25**。

### 本次实测：单帧漏检率

在真实帧 f1 上随机位置注入变化块，各 1000 次，相位固定：

| 变化块 | 4096 | 4099 | 6151 | 12289 |
|---|---:|---:|---:|---:|
| 8×8 | 83.2% | 81.4% | 91.8% | 94.7% |
| 16×16 | 76.9% | 67.0% | 83.5% | 91.5% |
| 64×64 | 39.5% | **0.0%** | 46.8% | 74.8% |
| 120×18 文本行 | 0.0% | **0.0%** | 58.1% | 65.1% |
| 200×30 时钟 | 0.0% | **0.0%** | 28.8% | 41.9% |
| 1067×600 游戏画布 | 0.0% | **0.0%** | 0.0% | 0.0% |

**小块高漏检是探针密度的数学必然，换步长解决不了。** 8×8 块只有 8 段各 32 B，
而 4099 步长的覆盖率是 64/4099≈1.6%，逐段独立估算即得约 83%，与实测吻合。
换句话说：**探针是零误报的“肯定变了”检测器，不是“肯定没变”的证明。**

### 本次实测：相位轮转后的检出延迟

静止小块 + 每帧轮转相位，统计需要几帧才检出（各 1000 次随机位置）：

| 变化块 | 步长 | 中位 | P95 | P99 | 最坏 |
|---|---:|---:|---:|---:|---:|
| 8×8 | **4099** | 4 | 8 | 8 | **8** |
| 8×8 | 6151 | 12 | 22 | 23 | 24 |
| 8×8 | 12289 | 12 | 23 | 24 | 24 |
| 16×16 | **4099** | 3 | 6 | 7 | **7** |
| 64×64 | **4099** | 1 | 1 | 1 | **1** |
| 200×30 | **4099** | 1 | 1 | 1 | **1** |

步长 4099 下，≥64×64 的变化**当帧即检出**；最难的 8×8 静止块在这 1000 次采样中
最坏 8 帧（60 Hz 约 133 ms）。6151/12289 虽然更省，但最坏延迟涨到 22–24 帧，
不值得。**这 8 帧是采样得到的观测上界，不是数学证明的上界**，所以要点 ③ 的
强制兜底必须保留。

### 折算

静止桌面、兜底设为每 8 帧一次全量时，均摊 `(7×0.028 + 0.699)/8 ≈ 0.112 ms/帧`，
相对现状 0.699 ms/帧 约减少 84%，按 60 次/秒折算约 3.5 个百分点单核时间。
游戏持续运动时探针几乎每帧命中，成本变成 `0.028 + 精确比较`，即多付约 0.17
个百分点。

### 边界与尚未验证的部分

- **微基准跑在普通匿名内存上，不是 VFIO mmap。** `/proc/<pid>/smaps` 显示
  console REGION 无 `io` 标志、`Rss` 全额驻留，属可缓存系统内存，但读取
  行为仍可能与匿名页不同。**落地前必须在真实 REGION 上重测**。
- 漏检与延迟数据基于注入的纯色块和一帧真实底图。真实 guest 的小面积变化
  （抗锯齿文字、渐变动画）字节分布不同，结果可能偏移。
- 上表按 1920×1080 采集。其他分辨率的探针数、漏检率和延迟都会变，
  RTX 2080 与 V100 需分别验收。
- 探针命中即走精确比较，**不改变任何一帧的最终像素内容**，只影响“何时发现
  变化”。因此风险集中在延迟，不在正确性——前提是兜底生效。
- 与现有 `copy` 模式互斥：`copy` 不做任何比较，探针无处可插。三档应当是
  `copy` / `probe` / `compare` 的单选，而不是叠加。

## 7. 暂不采用的性能推论与后续验收

两套时钟周期接近时，抖动和频率差可能造成重复采样；但**同频本身并不必然丢帧**。
完全同频且相位固定时，可以每次看到上一张新帧，只是延迟不同。
不能仅凭 16667us 与 60Hz 的配置解释 Content 43–52/s。

本地 `vgpu-host.conf` 的赋值确实可覆盖封装传入的同名变量，这是现有配置优先级。
各驱动/机型的 intervaltime 策略仍有版本条件，不能概括成所有 V100 固定 8333。
更快轮询只能更频繁地观察驱动已经发布的像素，不能恢复驱动没有发布的中间帧；
临时提高采样率后 Content 不变，也不能单独证明 guest FPS 低。

若要推进独立 poller，先分别测量 QUERY、比较、复制、上传和 swap 的时间。
设计必须覆盖缓冲读者的持有期限、释放和复用、模式切换、VM 挂起恢复及失败退避。
QEMU 内部双缓冲/seqlock 不会让外部 NVIDIA 写入者同步参与，不能保证读到完整源帧。

本次本地验证覆盖真实像素流的更新范围、32/33 runs 边界、静止阈值/恢复/reset，
游戏模式的全量复制（包括 padding、连续变化和静止/黑帧），以及封装默认值、
显式开关、互斥检查和旧二进制拒绝。实机仍需在同一 VM、相同动态场景下
对比 CPU、Content/Present 和可见画面，并验证 resize、全屏切换、最小化恢复。
RTX 2080 与 V100 应分别验收；这些本地测试不等于黑画布根因已复现或修复。

相关：[SDL 性能教程](G11-SDL-PERFORMANCE.md) ·
[全面性能](G11-FULL-PERFORMANCE.md) ·
[fb-shm 同步](G11-FB-SHM-GPU-SYNC.md) ·
[窗口最小化](G11-SDL-MINIMIZE.md)

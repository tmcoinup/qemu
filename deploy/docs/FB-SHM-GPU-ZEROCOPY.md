# fb-shm 零拷贝 GPU 推流设计说明

> **版本基线**：QEMU `11.0.2` + `V-11` 分支。本文所称 SDL/EGL 是 QEMU 11
> 官方 SDL/OpenGL 集成路径；旧版定制 native EGL 子窗口实现已不再作为当前架构。

本文档给代码审核和运维使用，说明本仓库当前 `fb-shm` 的 GPU 零拷贝导出能力、
Linux/Windows 差异、consumer 模式，以及仍需后续接入的 native GPU encoder 边界。

## 目标

`fb-shm` 原本只提供一条共享内存帧路径：

1. QEMU 从 DisplaySurface 或 GL texture 得到画面；
2. 写入 BGR0 双缓冲共享内存；
3. consumer 读共享内存；
4. consumer 通过 ffmpeg stdin 推给 NVENC/QSV/x264。

这条路径低延迟、跨平台、对 guest 不可见，但 GL/virgl 场景仍可能经过
`glReadPixels` / PBO / CPU 可见内存。新实现的目标是新增一条 GPU resident frame
控制面，让支持硬件导入的 consumer 能直接拿到同一份 GPU backing：

- Linux：`dma-buf` fd；
- Windows：D3D11 shared texture 名称；
- 旧 SHM BGR0 ABI 不破坏，继续作为默认兼容回退。

## 新 ABI

新增内容位于 `include/ui/fb-shm-abi.h`：

| 名称 | 作用 |
|---|---|
| `FB_SHM_CTL_NOTIFY_GPU_FRAME` | QEMU 主动推送 GPU frame metadata |
| `FB_SHM_CTL_GPU_FRAME_DONE` | Windows consumer 释放 keyed mutex 后确认该 frame 已用完 |
| `FB_SHM_HELLO_F_GPU_FRAMES` | consumer 订阅 GPU frame 通知 |
| `FB_SHM_HELLO_F_GPU_REQUIRED` | strict GPU 模式，不接受 SHM-only 握手 |
| `FB_SHM_HELLO_F_GPU_SYNC` | consumer 明确支持 Windows D3D11 keyed-mutex/DONE 协议 |
| `FbShmGpuFrame` | GPU backing 的几何、格式、句柄类型和序列号 |

`FbShmHeader` 没有改变，所以旧 consumer 不设置新 flag 时不会收到新消息，仍按原来的
`HELLO -> mmap/MapViewOfFile -> eventfd/Event -> seqlock` 流程工作。

## Linux 路径

Linux 下 QEMU 有两种 GPU 导出来源：

1. `dpy_gl_scanout_dmabuf()` 直接收到 `QemuDmaBuf`：
   - QEMU `dup()` 该 dma-buf fd；
   - 发送 `FbShmCtlAck + FbShmGpuFrame`；
   - 通过 `SCM_RIGHTS` 附带 dma-buf fd。
   - 普通 `./start-vm.sh <N>` 默认是 `STABLE_DISPLAY=1` + `GPU_DISPLAY=sdl`：
     使用 QEMU 11 普通 SDL 和 `virtio-vga`，不启用 virgl、blob/hostmem 或 GPU
     handle 导出，fb-shm 直接使用 SHM 路径。这是 Windows 游戏长跑的默认策略。
   - 需要 GPU 导出时，显式设置 `STABLE_DISPLAY=0`，或使用 `--gpu-sdl-egl` /
     `--gpu-headless`。后两个 GPU flag（以及对应的显式 `GPU_DISPLAY` 值）会在未显式
     设置 `STABLE_DISPLAY` 时自动 opt-in GL；显式 `STABLE_DISPLAY=1` 始终优先。
   - SDL/GL opt-in 使用 QEMU 11 官方 OpenGL 路径，并默认追加
     `blob=true,hostmem=256M`，优先给 guest/renderer 提供可共享 backing；
     `GPU_HOSTMEM=512M` 可调整 host-visible window。`--no-gpu-zerocopy` 只移除
     blob/hostmem 偏好；EGL/renderer 仍可能从普通 texture 导出 dma-buf。
   - 这是一项能力偏好而非成功保证。virglrenderer 无法导出当前 scanout 的
     dma-buf 时，QEMU 在同一运行实例内自动继续 SHM/PBO，不重启 VM、不关闭 SDL。
   - `GPU_DISPLAY=sdl-egl` 是显式 GL 入口，显示实现直接复用
     QEMU 11 官方 SDL/EGL 窗口与 context，不再在 SDL 父窗口内创建额外 X11/EGL
     子窗口。DGame 的显示/隐藏始终操作同一个 SDL 窗口；fb-shm 从当前 EGL
     provider 对应的 texture 尝试导出 dma-buf。
   - 如需无本地窗口的纯推流验证，可用
     `deploy/scripts/start-vm.sh <N> --gpu-headless --gpu-rendernode=/dev/dri/renderD128`
     切到 rendernode EGL 后端。

2. 只有 GL texture、没有现成 dma-buf：
   - 如果构建带 `CONFIG_GBM`，通过 QEMU 11 的
     `egl_dmabuf_export_texture()` 尝试导出 dma-buf；该接口按 plane 返回
     fd、offset、stride 和 modifier，可正确承载带压缩元数据的多平面纹理；
   - 导出前会核对当前 EGL display/context 与所需扩展。导出失败返回 `false`，
     调用方继续走 SHM/PBO fallback，不会把失败误报成 GPU frame。

GPU frame 的 ROI 语义是 metadata 裁剪：`FbShmGpuFrame.x/y/width/height`
描述同一份 backing 内要编码的区域，不把 ROI 复制到新 buffer。

## Windows 路径

Windows 下 QEMU 接收 GL/ANGLE 提供的 `ID3D11Texture2D` 指针。为了让 SDL 与外部
consumer 安全共享同一份原始 scanout，纹理必须同时支持
`D3D11_RESOURCE_MISC_SHARED_NTHANDLE` 和
`D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX`，并执行显式所有权交接：

1. consumer 在 HELLO 同时设置 `GPU_FRAMES|GPU_SYNC`；strict 模式再加
   `GPU_REQUIRED`。Windows 同一 `QemuConsole`（即使挂了多个 fb-shm sidecar）只接纳
   一个同步 D3D consumer，其它订阅端继续使用 SHM，避免多个进程争用同一个 mutex；
2. QEMU 用 `CreateSharedHandle()` 创建带 READ/WRITE 权限的命名 handle（consumer
   必须执行 `ReleaseSync`）。当前帧先完成 SDL 与其它 display listener 绘制，再由
   bottom half 执行 D3D immediate-context `Flush()`、`ReleaseSync(key=0)`，并只异步
   暂停该 console 的 GL producer；SDL 事件/输入循环、QEMU 主循环和其它 VM 不阻塞；
3. consumer 用 `OpenSharedResourceByName()` 打开 texture，执行
   `AcquireSync(key=0)`，完成 GPU import/copy/encode 后 `ReleaseSync(key=0)`；
4. consumer 发送 `GPU_FRAME_DONE`，其中 `w/h` 分别携带 `frame_seq` 的低/高
   32 位；QEMU 校验序列号、`AcquireSync(key=0, timeout=0)` 收回所有权，然后恢复
   renderer。若返回 `EBUSY`，consumer 应在确认 `ReleaseSync` 完成后用同一序列重试。

同步 consumer 断连时，QEMU 也只做非阻塞 `AcquireSync(0, 0)`；暂时超时会保留该
console 的 renderer block，并用 10ms timer 重试，直到成功或资源 abandoned。这样
SDL 窗口仍可响应移动、关闭和输入事件，但画面保持上一帧，不会用“立即回退”换取
外部进程读纹理与 renderer 写纹理的竞态；mutex 收回后会重放积压的窗口 redraw。

未声明 `GPU_SYNC` 的旧 consumer 不会收到 D3D11 handle。ANGLE 没给 D3D texture、
纹理没有 keyed mutex、共享 handle 创建失败或同步握手不成立时，QEMU 保留 SDL 窗口并
继续 SHM BGR0 fallback；不会发布一个可能永久阻塞或存在写读竞态的 D3D handle。

`deploy/windows/start-vm.ps1` 会先探测 QEMU 是否注册 `virtio-vga-gl`：只有带
virglrenderer 的构建才使用 `-display sdl,gl=on`、`virtio-vga-gl` 和默认
`blob=true,hostmem=256M`。`-NoGpuZeroCopy` 只关闭这组属性偏好，ANGLE 仍可能
导出普通 texture。当前常规 Windows cross 构建缺少 virglrenderer，会自动保留
普通 SDL 窗口并改用 `virtio-vga` + SHM。真正的 Windows GPU handoff 还需要
ANGLE/libEGL 提供 D3D11
shared texture；`-NoSdl`/`-Headless` 同样不能描述成 GPU 零拷贝路径。

## Consumer 模式

`qemu-fb-shm-stream` 新增：

```bash
--mode auto|gpu|shm
```

| 模式 | 行为 |
|---|---|
| `auto` | 默认。请求 GPU metadata，但实际推流仍使用 SHM rawvideo fallback |
| `shm` | 不订阅 GPU frame，完全保持历史行为 |
| `gpu` | strict GPU。要求 QEMU 发布 GPU frame，不允许静默降级到 SHM |

当前仓库内置 streamer 仍是 ffmpeg stdin/rawvideo backend，不能直接把 dma-buf/D3D11
texture 导入 NVENC/AMF/QSV，也不会声明 Windows `GPU_SYNC`。因此：

- `--mode auto` 是生产默认，兼容当前 ffmpeg 推流；
- Linux `--mode gpu` 可验证 QEMU 是否真的发布 dma-buf；Windows 内置 streamer 的
  strict GPU 握手会明确失败，直到 native D3D encoder 实现 keyed-mutex/DONE 协议；
- 真正端到端 GPU 零拷贝编码需要后续实现 native GPU encoder backend。

strict GPU 模式下，如果只有有效的 `GPU_REQUIRED` 客户端连接，QEMU 在发布 GPU frame
后不做 PBO/SHM CPU readback。只要存在普通 SHM consumer，QEMU 会继续维护 SHM
fallback，保证多订阅端兼容。Windows strict consumer 还必须声明 `GPU_SYNC`。

## configured rate 与 effective rate

启动参数 `rate=60` 和 QOM `rate` 表示配置/consumer 目标值。fb-shm 完成初始 mapping
后如果没有 consumer，会把内部 DisplayChangeListener 的 effective tick 暂时降至
最低 `1Hz`，避免空闲旁路每秒触发 60 次显示更新；因此启动日志出现 `rate=1Hz` 不代表
`rate=60` 丢失。普通 SHM 或 GPU consumer 完成 HELLO 后会重新计算 effective rate；
consumer 还可通过 `SET_RATE` 修改目标值。该节流逻辑在 Linux 和 Windows 相同。

## 典型命令

默认生产推流：

```bash
qemu-fb-shm-stream --sock /tmp/qemu-stealth-1.fb \
    --output 'rtmp://ingest/live/vm1' \
    --encoder h264_nvenc --bitrate 6M --mode auto
```

只验证 GPU export：

```bash
qemu-fb-shm-stream --sock /tmp/qemu-stealth-1.fb \
    --output /tmp/unused.mp4 \
    --mode gpu
```

强制旧 SHM 行为：

```bash
qemu-fb-shm-stream --sock /tmp/qemu-stealth-1.fb \
    --output /tmp/vm1.mp4 \
    --encoder libx264 --preset veryfast --mode shm
```

Windows PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File deploy\windows\stream-fb-shm.ps1 `
  -Instance 1 `
  -Output rtmp://ingest.example/live/vm1 `
  -Encoder h264_nvenc `
  -Bitrate 6M `
  -Mode auto
```

## 审核重点

代码审核时重点看以下文件：

| 文件 | 审核点 |
|---|---|
| `include/ui/fb-shm-abi.h` | 新 ABI 是否保持旧 header 不变，旧 consumer 是否兼容 |
| `ui/fb-shm.c` | GPU/SHM 调度、D3D 单 consumer 同步和 strict GPU-only 是否跳过 readback |
| `ui/fb-shm-gpu.c` | dma-buf/D3D 导出、keyed mutex 与 fd/COM/handle 生命周期 |
| `tools/fb-shm-stream/platform.c` | `NOTIFY_RESIZED` 与 `NOTIFY_GPU_FRAME` 是否能在同一控制 socket 上正确分流 |
| `tools/fb-shm-stream/main.c` | `--mode` 是否避免把 SHM fallback 伪装成 GPU 零拷贝 |
| `deploy/scripts/tests/test_gpu_zerocopy_launcher.sh` | Linux 默认 stable、显式 GL/blob opt-in、优先级与冲突矩阵是否一致 |
| `deploy/scripts/tests/test_windows_fb_shm_static.sh` | Windows/Linux 关键字符串和语法检查是否覆盖新路径 |

## 已验证命令

```bash
ninja -C build qemu-system-x86_64 qemu-fb-shm-stream
deploy/scripts/tests/test_gpu_zerocopy_launcher.sh
deploy/scripts/tests/test_windows_fb_shm_static.sh
git diff --check
rg -n "unwrap\(" include/ui/fb-shm-abi.h ui/fb-shm.c tools/fb-shm-stream \
    deploy/windows deploy/scripts/tests/test_windows_fb_shm_static.sh \
    docs/system/fb-shm.rst deploy/docs/FB-SHM.md \
    deploy/docs/WINDOWS-PACKAGING.md deploy/docs/USAGE.md \
    qapi/ui.json qapi/qom.json
```

## 当前限制

- 内置 `qemu-fb-shm-stream` 尚未实现 native libav/NVENC/AMF/QSV GPU import backend；
- Linux texture 到 dma-buf 的导出依赖 `CONFIG_GBM` 和 EGL 扩展；
- 默认 stable 路径不会添加 `blob=true,hostmem=SIZE`，因此只使用 SHM；显式 GL 后，
  Windows/virgl 仍可能只给 QEMU 普通 GL texture；缺少 EGL texture export 时不会产生 `NOTIFY_GPU_FRAME`，
  只能继续走 SHM fallback；
- `GPU_DISPLAY=sdl` 本身是默认普通 SDL；只有 `STABLE_DISPLAY=0` 时才使用 SDL/OpenGL。
  实际 EGL/GL provider 由 SDL 与宿主能力共同决定，因此缺少 dma-buf export 扩展时仍会走 SHM/CPU
  fallback。显式 GL 路径默认打开 blob/hostmem 也只能增加成功条件；DGame UI 只有收到
  实际 GPU frame 后才能显示 `G`，不能仅凭启动参数宣称零拷贝成功；
- `--gpu-headless` 会关闭 SDL 窗口并使用 `egl-headless` display backend；这是
  fb-shm GPU 预览/转码的无窗口模式，不适合作为宿主本地交互窗口；
- Windows GPU export 依赖 ANGLE/D3D11 keyed-mutex texture 和实现 `GPU_SYNC/DONE`
  的 native consumer；纯 OpenGL、无 keyed mutex 或旧 consumer 默认回退 SHM；
- `ui/fb-shm.c` 是既有大单体文件，本次为降低 QEMU DCL 状态拆分风险只做局部接入。

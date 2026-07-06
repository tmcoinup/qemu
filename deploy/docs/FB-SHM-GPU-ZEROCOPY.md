# fb-shm 零拷贝 GPU 推流设计说明

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
| `FB_SHM_HELLO_F_GPU_FRAMES` | consumer 订阅 GPU frame 通知 |
| `FB_SHM_HELLO_F_GPU_REQUIRED` | strict GPU 模式，不接受 SHM-only 握手 |
| `FbShmGpuFrame` | GPU backing 的几何、格式、句柄类型和序列号 |

`FbShmHeader` 没有改变，所以旧 consumer 不设置新 flag 时不会收到新消息，仍按原来的
`HELLO -> mmap/MapViewOfFile -> eventfd/Event -> seqlock` 流程工作。

## Linux 路径

Linux 下 QEMU 有两种 GPU 导出来源：

1. `dpy_gl_scanout_dmabuf()` 直接收到 `QemuDmaBuf`：
   - QEMU `dup()` 该 dma-buf fd；
   - 发送 `FbShmCtlAck + FbShmGpuFrame`；
   - 通过 `SCM_RIGHTS` 附带 dma-buf fd。
   - 普通 `./start-vm.sh <N>` 默认保持历史 `GPU_DISPLAY=sdl` / SDL+GLX 路径，
     不自动追加 `blob=true,hostmem=...`，避免游戏本地窗口走实验显示链路。
   - 需要验证 GPU 零拷贝时，显式使用 `--gpu-sdl-egl` 或 `--gpu-zerocopy`；
     `GPU_HOSTMEM=512M` 可调整 host-visible window 大小。
   - `GPU_DISPLAY=sdl-egl` 使用 SDL 父窗口 + native EGL 子窗口：宿主本地
     SDL 窗口仍存在，DGame 的显示/隐藏仍然操作同一个窗口；fb-shm 则尝试从
     EGL texture 导出 dma-buf 给 GPU consumer。
   - 如需无本地窗口的纯推流验证，可用
     `deploy/scripts/start-vm.sh <N> --gpu-headless --gpu-rendernode=/dev/dri/renderD128`
     切到 rendernode EGL 后端。

2. 只有 GL texture、没有现成 dma-buf：
   - 如果构建带 `CONFIG_GBM`，通过 `egl_get_fd_for_texture()` 尝试导出 dma-buf；
   - 导出失败时不影响 SHM fallback。

GPU frame 的 ROI 语义是 metadata 裁剪：`FbShmGpuFrame.x/y/width/height`
描述同一份 backing 内要编码的区域，不把 ROI 复制到新 buffer。

## Windows 路径

Windows 下 QEMU 接收 GL/ANGLE 提供的 `ID3D11Texture2D` 指针：

1. 通过 `IDXGIResource1::CreateSharedHandle()` 创建命名共享纹理；
2. QEMU 持有共享 handle 到 scanout 切换；
3. consumer 收到 `FbShmGpuFrame.handle_name`；
4. native GPU consumer 可用 `ID3D11Device1::OpenSharedResourceByName()` 打开同一份 texture。

如果 ANGLE 没有给 D3D texture，或共享 handle 创建失败，QEMU 只禁用 GPU metadata，
SHM BGR0 fallback 仍继续工作。

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
texture 导入 NVENC/AMF/QSV。因此：

- `--mode auto` 是生产默认，兼容当前 ffmpeg 推流；
- `--mode gpu` 用来验证 QEMU 端是否真的发布 GPU handle；
- 真正端到端 GPU 零拷贝编码需要后续实现 native GPU encoder backend。

strict GPU 模式下，如果只有 `GPU_REQUIRED` 客户端连接，QEMU 在发布 GPU frame 后直接
返回，不做 PBO/SHM CPU readback。只要存在普通 SHM consumer，QEMU 会继续维护 SHM
fallback，保证多订阅端兼容。

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
| `ui/fb-shm.c` | dma-buf/D3D shared texture 发布、strict GPU-only 是否跳过 readback |
| `tools/fb-shm-stream/platform.c` | `NOTIFY_RESIZED` 与 `NOTIFY_GPU_FRAME` 是否能在同一控制 socket 上正确分流 |
| `tools/fb-shm-stream/main.c` | `--mode` 是否避免把 SHM fallback 伪装成 GPU 零拷贝 |
| `deploy/scripts/tests/test_windows_fb_shm_static.sh` | Windows/Linux 关键字符串和语法检查是否覆盖新路径 |

## 已验证命令

```bash
ninja -C build qemu-system-x86_64 qemu-fb-shm-stream
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
- 如果启动时没有 `blob=true,hostmem=SIZE`，Windows/virgl 常只给 QEMU 普通 GL
  texture；在缺少 EGL texture export 的宿主上不会产生 `NOTIFY_GPU_FRAME`，
  只能继续走 SHM fallback；
- `GPU_DISPLAY=sdl` 是默认兼容 SDL/GLX 路径，可能只能走 SHM/CPU fallback；
  需要 DGame UI 预览显示 `G` 时，应显式使用 `--gpu-sdl-egl`；
- `--gpu-headless` 会关闭 SDL 窗口并使用 `egl-headless` display backend；这是
  fb-shm GPU 预览/转码的无窗口模式，不适合作为宿主本地交互窗口；
- Windows GPU export 依赖 ANGLE/D3D11 texture，纯 OpenGL 或没有 shared texture 时会回退 SHM；
- `ui/fb-shm.c` 是既有大单体文件，本次为降低 QEMU DCL 状态拆分风险只做局部接入。

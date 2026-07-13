# Windows 打包与启动方案

> **版本基线**：当前维护目标为 QEMU `11.0.2` + `vmate` 分支。安装包继续保留
> `qemu-system-x86_64.exe`、`qemu-img.exe` 等上游兼容文件名，避免破坏脚本、
> QMP 管理工具和既有自动化；`vmate` 用于标识本仓库维护分支和下游构建来源。

本文档覆盖 Windows 10 / Windows 11 宿主运行 patched QEMU 的方案。目标是：

- QEMU、`fb-shm`、启动脚本、推流工具在 Windows/Linux 上共用 ABI 和 SHM
  fallback；GPU handle 能力按各自构建依赖探测，不能把可选能力描述成无条件 1:1。
- Windows 运行时不要求用户额外安装 Python；启动、停止和推流封装均为 PowerShell 5.1 + 原生 exe。
- 打包产物走仓库已有 NSIS installer target，安装后包含 `qemu-system-x86_64.exe` 与 `qemu-fb-shm-stream.exe`。

## fb-shm 是否还是 Linux-only

不是。当前实现已经拆成同一套 ABI、不同宿主承载：

| 项 | Linux | Windows 10/11 |
|---|---|---|
| 控制通道 | `AF_UNIX` stream socket | `AF_UNIX` stream socket |
| 帧共享内存 | `memfd_create` + `mmap` | `CreateFileMappingA` + `MapViewOfFile` |
| 帧通知 | `eventfd` | 每客户端 `CreateEventA` |
| resize/ROI 热切换 | `NOTIFY_RESIZED` + `SCM_RIGHTS` 重新发 fd | `NOTIFY_RESIZED` + 命名 mapping/event 重新发名称 |
| GPU frame export | `NOTIFY_GPU_FRAME` + `dma-buf` fd | `NOTIFY_GPU_FRAME` + D3D11 shared texture 名称 |
| 帧 ABI | `include/ui/fb-shm-abi.h` | 同一份 `include/ui/fb-shm-abi.h` |

Windows 侧没有 `SCM_RIGHTS`，所以 HELLO 时如果 client 带
`FB_SHM_HELLO_F_WIN32_NAMES`，QEMU 会在普通 ack 后追加固定长度的
`FbShmWin32Names`，里面是 mapping 和 event 的 Win32 名称。消费端仍然按同一
`FbShmHeader`、双缓冲、`frame_seq` seqlock 读帧。

表中的 Windows GPU frame export 是可选构建能力：需要 QEMU 同时构建
`virtio-vga-gl`、virglrenderer，以及可提供 ANGLE/D3D11 texture 的 EGL/ANGLE
运行栈。texture 还必须支持 `SHARED_NTHANDLE|SHARED_KEYEDMUTEX`，consumer 必须
实现 `GPU_SYNC/GPU_FRAME_DONE` 所有权协议。缺任一条件时仍有完整 SDL+SHM 路径，
但不会产生不安全的 D3D11 shared texture 通知。

## 运行时组件

安装目录需要有这些文件：

- `qemu-system-x86_64.exe`：patched QEMU 主程序。
- `qemu-img.exe`：可选，用于维护 qcow2 镜像。
- `qemu-fb-shm-stream.exe`：原生 fb-shm 消费端，不依赖 Python。
- `deploy/windows/start-vm.ps1`：Windows 启动程序。
- `deploy/windows/stream-fb-shm.ps1`：Windows 推流封装。
- `deploy/windows/stop-vm.ps1`：通过 QMP 发 `quit` 的停止脚本。
- `ffmpeg.exe`：只有推流/录制时需要；建议放到 PATH。

Windows PowerShell 5.1 是 Windows 10/11 自带组件，不算额外运行时依赖。

## Windows 宿主准备

1. 启用 Windows Hypervisor Platform：

   ```powershell
   Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
   ```

2. 重启 Windows。

3. 准备 VM 目录和磁盘，例如：

   ```powershell
   New-Item -ItemType Directory -Force C:\qemu\vms\1 | Out-Null
   qemu-img.exe create -f qcow2 C:\qemu\vms\1\disk.qcow2 120G
   ```

4. 确认 OVMF 固件存在。启动脚本会按顺序查找：

   - `deploy\firmware\OVMF_CODE_4M_stealth.fd`
   - QEMU 安装目录下的 `share\qemu\edk2-x86_64-code.fd`
   - QEMU 安装目录下的 `edk2-x86_64-code.fd`

## 启动 VM

默认始终保留 SDL 本地窗口 + fb-shm 推流通道。启动器先用
`qemu-system-x86_64.exe -device virtio-vga-gl,help` 做只读能力探测：存在该设备时
选择 `sdl,gl=on`、`virtio-vga-gl` 和 `blob=true,hostmem=256M`；当前常规
`build-win64-vmate` 未找到 virglrenderer，因此会明确提示并自动选择普通 SDL、
`virtio-vga` 和 SHM，不会因缺少可选 GL 模块导致 VM 启动失败。

```powershell
powershell -ExecutionPolicy Bypass -File deploy\windows\start-vm.ps1 `
  -Instance 1 `
  -Disk C:\qemu\vms\1\disk.qcow2
```

常用参数：

| 参数 | 作用 |
|---|---|
| `-Qemu C:\path\qemu-system-x86_64.exe` | 指定 patched QEMU |
| `-Disk C:\path\disk.qcow2` | 指定 VM 磁盘 |
| `-MemoryMiB 8192` | 内存大小 |
| `-Cpus 4` | vCPU 数 |
| `-Iso C:\path\install.iso` | 挂载安装 ISO |
| `-NoSdl` | 不开本地 SDL 窗口，仅后台显示 |
| `-Headless` | `-display none` + VNC |
| `-NoFbShm` | 关闭 fb-shm |
| `-FbShmPath C:\qemu-run\fb-1.sock` | 指定 fb-shm 控制 socket |
| `-FbShmRate 60` | 配置/consumer 目标帧率；无 consumer 时 effective tick 可降至 1 Hz |
| `-FbShmRoi 0,0,1280,720` | 只导出 ROI |
| `-NoGpuZeroCopy` | GL 设备存在时仍保留 SDL/GL，只移除 blob/hostmem 偏好；ANGLE/renderer 仍可能从普通 texture 导出 handle，失败才回退 SHM |
| `-GpuHostmem 512M` | 调整 virtio-gpu host-visible window；默认 `256M` |
| `-GpuGlProbe Available|Unavailable` | 仅允许与 `-DryRun` 一起供 CI 注入探测结果；真实启动强制使用默认 `Auto`，不能越过能力检查 |
| `-DryRun` | 只打印 QEMU 参数，不启动 |

脚本默认把 fb-shm socket 放在 `C:\qemu-run\fb-<N>.sock`。Windows `AF_UNIX`
路径长度限制比 Linux 更敏感，短路径能避免用户目录过长导致 connect 失败。

## 推流或录制

本地录制：

```powershell
powershell -ExecutionPolicy Bypass -File deploy\windows\stream-fb-shm.ps1 `
  -Instance 1 `
  -Output C:\qemu\captures\vm1.mp4 `
  -Encoder libx264 `
  -Preset veryfast `
  -Bitrate 4M `
  -Mode auto
```

RTMP + NVENC：

```powershell
powershell -ExecutionPolicy Bypass -File deploy\windows\stream-fb-shm.ps1 `
  -Instance 1 `
  -Output rtmp://ingest.example/live/vm1 `
  -Encoder h264_nvenc `
  -Preset p1 `
  -Bitrate 6M `
  -Gop 60 `
  -Mode auto
```

也可以直接调用原生工具：

```powershell
qemu-fb-shm-stream.exe --sock C:\qemu-run\fb-1.sock `
  --output C:\qemu\captures\vm1.mp4 `
  --encoder libx264 --preset veryfast --bitrate 4M --mode auto
```

`-Mode auto` 会请求 GPU resident frame metadata。只有带 virglrenderer 且实际由
ANGLE/D3D11 提供共享 texture 的构建才可能发布 D3D11 shared texture 名称；普通
Windows 构建自动使用 SHM。当前内置 ffmpeg stdin backend 即使收到 metadata，仍以
SHM rawvideo 作为实际推流路径。`-Mode gpu` 保持 strict 语义：能力或同步协议不完整
就明确失败，不会把 SHM 回退伪装成零拷贝 GPU 编码。

Windows 的原始 scanout 不能由 virgl/SDL 和外部进程无同步并发访问。native D3D
consumer 的 HELLO 必须设置 `GPU_FRAMES|GPU_SYNC`；QEMU 刷新 D3D immediate context 后
`ReleaseSync(0)`，consumer `AcquireSync(0)` 并在用完后 `ReleaseSync(0)`，再发送
`GPU_FRAME_DONE`（`w/h` 为 64 位 `frame_seq` 的低/高 32 位）。QEMU 收到匹配 ACK
并非阻塞地 `AcquireSync(0,0)` 后恢复该 GL console；`EBUSY` 要以同一序列重试。
handoff 由 bottom half 安排在整轮 SDL/display listener 绘制之后。同一
`QemuConsole` 只允许一个同步 D3D consumer，其它客户端继续走 SHM。断连时若 mutex
暂未归还，10ms timer 会保持 renderer block 并异步重试；SDL 事件仍响应，收回后重放
窗口 redraw。当前内置 streamer 没有 D3D import/GPU_SYNC，因此 Windows `auto`
默认走 SHM，strict `gpu` 会明确拒绝，而不是发布存在竞态的 handle。

## 停止 VM

`start-vm.ps1` 默认打开 `127.0.0.1:(4440 + Instance)` 的 QMP TCP 端口。
优雅退出：

```powershell
powershell -ExecutionPolicy Bypass -File deploy\windows\stop-vm.ps1 -Instance 1
```

脚本会先发送 `qmp_capabilities`，再发送 `quit`。连接阶段使用异步 connect，
端口不可达时会按 `-TimeoutMs` 退出，不会长时间卡住控制台。

## 打包方式

推荐使用仓库现有的 Fedora win64 cross 容器。这个 Dockerfile 已包含
`mingw64-gcc`、`mingw64-glib2`、`mingw64-pixman`、`mingw64-SDL2`、
`mingw32-nsis` 等 Windows 构建与 NSIS installer 依赖：

```bash
podman build -t qemu-win64-cross -f tests/docker/dockerfiles/fedora-win64-cross.docker .
```

进入容器后配置 Windows x86_64 目标：

```bash
mkdir -p build-win64-vmate
cd build-win64-vmate
../configure \
  --cross-prefix=x86_64-w64-mingw32- \
  --target-list=x86_64-softmmu \
  --enable-sdl \
  --enable-slirp \
  --enable-whpx \
  --enable-pixman \
  --disable-docs
```

上述常规容器没有 Windows virglrenderer，configure 会报告 virglrenderer not found，
所以不会构建 `virtio-vga-gl`；这是受支持的 SDL+SHM 产物。要实验 Windows GPU
handoff，必须另外提供匹配 MinGW ABI 的 virglrenderer，并接入 ANGLE/libEGL 与
D3D11 shared texture 支持后重新配置 `--enable-opengl --enable-virglrenderer`。
仅强制 `-GpuGlProbe Available` 不会补齐依赖，真实启动不要使用该测试覆盖值。

构建并生成 NSIS 安装包：

```bash
ninja
ninja installer
```

输出文件名由 Meson 生成，形如：

```text
build-win64-vmate/qemu-setup-11.0.2.exe
```

`scripts/nsis.py` 会先执行 `make install DESTDIR=...`，再分析 exe/dll 依赖并复制
MinGW DLL，最后调用 `makensis`。`qemu-fb-shm-stream.exe` 已加入 Meson
install 目标，因此会随 installer 一起进入安装包。

## Python 说明

- Windows 运行 VM、停止 VM、fb-shm 推流不需要 Python。
- 从源码构建 QEMU 仍会使用 Python 作为 Meson/QAPI/NSIS 构建工具，这是构建环境依赖，不是用户运行时依赖。
- 旧的 `scripts/qemu-fb-shm-stream.py` 仍可作为协议参考，但 Windows 方案默认使用原生 `qemu-fb-shm-stream.exe`。

## 已验证范围

本次在 Linux 构建环境验证：

- `qemu-system-x86_64`
- `qemu-fb-shm-stream`
- QAPI 条件生成
- fb-shm Linux 路径未被 Windows 改动破坏

本机没有 MinGW/NSIS 完整 Windows cross 环境时，无法在当前机器实际产出
`qemu-setup-*.exe`。Windows 打包应在上述 cross 容器或 MSYS2/MinGW 环境中执行。

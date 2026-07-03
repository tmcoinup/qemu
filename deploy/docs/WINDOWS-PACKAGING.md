# Windows 打包与启动方案

本文档覆盖 Windows 10 / Windows 11 宿主运行 patched QEMU 的方案。目标是：

- QEMU、`fb-shm`、启动脚本、推流工具在 Windows/Linux 上功能 1:1 对齐。
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

默认是 SDL 本地窗口 + fb-shm 推流通道同时开启：

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
| `-FbShmRate 60` | 推流目标帧率 |
| `-FbShmRoi 0,0,1280,720` | 只导出 ROI |
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

`-Mode auto` 会请求 GPU resident frame metadata。Windows GL/ANGLE 路径可发布
D3D11 shared texture 名称；当前内置 ffmpeg stdin backend 仍以 SHM rawvideo
作为实际推流路径。`-Mode gpu` 用于 strict 验证 GPU export，不会把 SHM 回退
伪装成零拷贝 GPU 编码。

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
mkdir -p build-win64
cd build-win64
../configure \
  --cross-prefix=x86_64-w64-mingw32- \
  --target-list=x86_64-softmmu \
  --enable-sdl \
  --enable-slirp \
  --enable-whpx \
  --enable-pixman \
  --disable-docs
```

构建并生成 NSIS 安装包：

```bash
ninja
ninja installer
```

输出文件名由 Meson 生成，形如：

```text
build-win64/qemu-setup-9.2.0.exe
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

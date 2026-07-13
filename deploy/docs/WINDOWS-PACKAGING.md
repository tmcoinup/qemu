# Windows 打包与启动方案

> **版本基线**：当前维护目标为 QEMU `11.0.2` + `vmate` 分支。安装包继续保留
> `qemu-system-x86_64.exe`、`qemu-img.exe` 等上游兼容文件名，避免破坏脚本、
> QMP 管理工具和既有自动化；`vmate` 用于标识本仓库维护分支和下游构建来源。

本文档覆盖 Windows 10 / Windows 11 宿主运行 patched QEMU 的方案。Windows 10
和 Linux 客体属于当前可启动范围；Windows 11 客体需要 TPM 2.0 与可验证的 Secure
Boot，而 Windows 原生构建尚未提供这两项的完整链路，因此启动器会提前拒绝。

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
- `deploy/windows/lib/*.ps1`：profile、WHPX 预检和 QEMU 参数模块。
- `deploy/hardware/platforms.json`：Linux/Windows 共用的版本化整机事实源。
- `deploy/hardware/components.json`：SSD、显示器与 HID 的关联部件目录。
- `ffmpeg.exe`：只有推流/录制时需要；建议放到 PATH。

Windows PowerShell 5.1 是 Windows 10/11 自带组件，不算额外运行时依赖。

## Windows 宿主准备

1. 启用 Windows Hypervisor Platform：

   ```powershell
   Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
   ```

2. 重启 Windows。

   启动器会同时检查 Windows build、`HypervisorPresent`、QEMU `11.0.2` 版本和
   `-accel help` 中的 WHPX。任何确定性失败都会终止；只有显式
   `-AllowTcgFallback` 才允许软件 TCG 进入候选列表。该模式把 `-cpu` 改为 TCG
   可用的 `max`；如果真的回退，CPU/SMBIOS 不再满足真机一致性，只用于救援启动。

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

首次启动会从 `deploy/hardware/platforms.json` 的 `enabled=true` 项中选择一个与
宿主 CPU 厂商一致的平台，并将平台 ID、manifest 摘要、UUID、MAC、NVMe/内存序列号、
内存和 vCPU 数写入 `hardware-profile.json`。普通重启只加载，不重新随机；manifest
事实或内存/vCPU 发生变化时会拒绝启动。`-RerollHardwareProfile` 是破坏性显式操作，
脚本会先保留时间戳 `.bak`。

可更换件统一从 `deploy/hardware/components.json` 读取。profile 同时固化 component
schema、`catalog_revision`、目录摘要以及 SSD/显示器/键盘/鼠标 ID；目录被篡改、组件
被替换或旧 profile 缺少绑定时都会 fail-closed。当前唯一启用组合是 Samsung 970 PRO
512GB（`144d:a804`、subsystem `144d:a801`、`1B2QEXP7`、序列绑定 NQN）、Samsung
S24F350 深层 EDID、Microsoft 045e:0750 键盘和 045e:00cb 鼠标。真实启动还会调用同
目录的 `qemu-img.exe`，要求 qcow2 的虚拟容量精确等于目录中的 `512110190592` bytes；
不能只改型号字符串却保留不匹配容量。

这些字段按真实 bundle 原子组合：主板 PCI subsystem、M.2 插槽链路、SSD 端点、NIC
subsystem/OUI、USB descriptor 和 EDID 不会各自独立乱抽。ALC887 当前明确标记为
`protocol_identity_only`，只保证控制器/codec ID、revision 和 subsystem 一致，不声称
完整复刻真实 codec 节点与插孔拓扑；GPU 直通/vGPU 也不在本分支范围内。

WHPX 在 QEMU 11 中忽略自定义 `-cpu` 模型，所以 Windows 路线明确传入
`-cpu host`，SMBIOS Type 4 也使用宿主 CPU 名称。严格模式只允许宿主 CPU 名称与
manifest CPU SKU 精确相同；E5 等没有对应平台的宿主会拒绝真机 profile。显式
`-AllowHostCpuPlatformMismatch` 可以进入仅功能模式，但不能宣称 CPU/主板物理匹配。
默认加速器是 `whpx,hyperv=off,kernel-irqchip=off`；需要 Hyper-V
enlightenments 时必须显式传 `-ExposeHyperv`。WHPX 不支持本项目所需的嵌套虚拟化，
`-RequireNestedVirtualization` 会直接失败。

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
| `-QemuImg C:\path\qemu-img.exe` | 指定同版本容量核验工具；默认取 QEMU 同目录 |
| `-Disk C:\path\disk.qcow2` | 指定 VM 磁盘 |
| `-MemoryMiB 8192` | 内存大小 |
| `-Cpus 4` | vCPU 数；必须等于所选平台完整线程数 |
| `-HardwareManifest path` | 覆盖共享 manifest 路径 |
| `-ComponentManifest path` | 覆盖共享 SSD/显示器/HID catalog 路径 |
| `-HardwareProfile path` | 覆盖持久化 profile 路径 |
| `-PlatformId id` | 首次创建时选择指定的启用平台 |
| `-RerollHardwareProfile` | 备份并重建全部随机身份 |
| `-AllowHostCpuPlatformMismatch` | 接受 WHPX 宿主 CPU 与平台不匹配，仅用于功能模式 |
| `-AllowTcgFallback` | 显式接受 WHPX 失败后使用软件 TCG |
| `-ExposeHyperv` | 使用 `whpx,hyperv=auto` 暴露 enlightenments |
| `-GuestOs Windows10|Linux` | 选择 RTC/客体前置策略；Windows11 当前拒绝 |
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

默认 `-Encoder auto` 会依次对 `h264_nvenc`、`h264_qsv`、`h264_amf` 和
`libx264` 做 64×64 单帧运行时探测。这样不仅检查 ffmpeg 是否列出编码器，也验证
当前驱动和硬件 session 能否真正创建；失败会继续下一项。显式指定 `-Encoder` 时
保持严格语义，运行时探测失败就终止，不静默换编码器。

本地录制：

```powershell
powershell -ExecutionPolicy Bypass -File deploy\windows\stream-fb-shm.ps1 `
  -Instance 1 `
  -Output C:\qemu\captures\vm1.mp4 `
  -Encoder auto `
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

进入容器后配置 Windows x86_64 目标。源码版本变化时必须删除或重新配置旧 build
目录；`scripts/nsis.py` 会把源码 `VERSION` 与输出文件名比较，并拒绝旧配置请求的
`qemu-setup-9.2.0.exe`：

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
install 目标。x86_64 下游源码还会生成不可取消的 `VMate Runtime` section，把
`qemu-img.exe`、`qemu-fb-shm-stream.exe`、`deploy/windows`、两个 hardware manifest
和本说明按原相对目录装入 `$INSTDIR`；因此自定义安装目录也能直接运行 launcher。
普通上游源码没有 `deploy/windows/start-vm.ps1` 时不会定义该 section，原 NSIS
打包内容保持不变；检测到入口但运行文件不完整则打包阶段直接失败。

## Python 说明

- Windows 运行 VM、停止 VM、fb-shm 推流不需要 Python。
- 从源码构建 QEMU 仍会使用 Python 作为 Meson/QAPI/NSIS 构建工具，这是构建环境依赖，不是用户运行时依赖。
- 旧的 `scripts/qemu-fb-shm-stream.py` 仍可作为协议参考，但 Windows 方案默认使用原生 `qemu-fb-shm-stream.exe`。

## 已验证范围

本次在 Linux 构建环境验证：

- PowerShell AST 解析和 Windows 启动器 DryRun（DryRun 无文件副作用）
- profile 原子持久化、重载稳定性和 reroll 备份
- component catalog schema/关联字段、profile 修订/ID 绑定及篡改拒绝
- NVMe subsystem/NQN、Microsoft HID 和 Samsung EDID 深层参数接线
- 默认无 TCG、显式 TCG、`hyperv=off/auto`、Win11 与 nested fail-closed
- NVENC/QSV/AMF/libx264 选择器的确定性注入测试
- NSIS 11.0.2 文件名门禁和 fb-shm 跨平台静态回归

这些测试不等于真实 Windows WHPX 验收。本机没有 MinGW/NSIS 完整 Windows cross
环境时，无法实际产出安装包或验证 WHPX 长稳；发布前仍要在目标 Windows 版本完成
启动、重启、profile 读取、编码器回退和至少 24 小时压力测试。

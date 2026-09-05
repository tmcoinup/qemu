# G-11：不重启 VM 检查源 DMA-BUF 能力

本工具只在 Linux x86_64 宿主运行。Windows 不需要安装软件，VM 保持运行。
它回答的是“NVIDIA vGPU 源能否导出 VFIO DMA-BUF”，不会把后续 SDL/DGame 的纹理
导出当作原始 vGPU 已经实现全程 GPU。

## 复制一条命令

在仓库根目录执行，把 `1` 换成 VM 编号：

```bash
python3 deploy/host/probe-vgpu-dmabuf.py --vm 1
```

它按 `-name vm1` 精确寻找唯一 QEMU，读取其 VFIO device fd 编号，用 `pidfd_getfd`
复制同一设备 fd，仅查询 `PROBE|DMABUF` 和 `PROBE|REGION` 两项能力，然后关闭本工具
的副本。不暂停 QEMU，不抓取像素，不获取 DMA-BUF handle，不 reset 设备，不创建 mdev，
不更换驱动，也不读取进程环境或宿主凭据。G-11 的 BCD 和驱动签名约束保持不变。

只检查当前权限和 fd 复制、完全不发 ioctl 时使用：

```bash
python3 deploy/host/probe-vgpu-dmabuf.py --vm 1 --check-only
```

诊断时也接受 `--pid QEMU进程号`；若同一 VM 有多个 QEMU，或同一进程有多个 VFIO
device fd，工具会拒绝猜测。后者可用 `--fd 数字` 明确选择；它只接受 VFIO device fd，
不会在 group/container、磁盘或网络 fd 上尝试 ioctl。

## 怎么读结果

2026-09-05，在 NVIDIA RTX 2080 / 535.161.05 提供 vGPU、AMD RX 570 提供宿主显示
的机器上，对运行中的 VM1 实测返回：

```text
SOURCE_DMABUF=unsupported
SOURCE_DMABUF_ERRNO=22
SOURCE_REGION=supported
SOURCE_REGION_ERRNO=0
END_TO_END_GPU=unavailable
PROBE_RESULT=complete
```

这说明当前 vGPU 驱动拒绝源 DMA-BUF 能力查询，且独立确认支持系统内存 REGION。
当前路径仍需要 REGION → CPU staging → 宿主显示 GPU 的纹理上传；更换 NVIDIA 或 AMD
副卡不能凭空补上源头缺失的导出接口。完整边界见 [兼容性说明](COMPATIBILITY.md)。

如果未来看到 `SOURCE_DMABUF=supported`，本工具仍输出 `END_TO_END_GPU=unverified`：
还没有验证实际帧 handle、跨 GPU 导入、格式/modifier、同步或连续动态画面，不能把一次
能力查询写成全程 GPU 已成功。

不在 Guest 增加采集软件时，要继续尝试必须先具备源驱动的 GPU 帧缓冲导出能力，
然后实测副卡能否导入同一缓冲。两张 NVIDIA 也不自动满足这些条件；当前没有理由
仅为本次尝试更换已能运行宿主 OpenGL 的 AMD 卡。
[Linux 像素缓冲交换文档](https://cdn.kernel.org/doc/html/latest/userspace-api/dma-buf-alloc-exchange.html)
要求导出方和导入方协商格式、modifier 等约束。
[DMA-BUF 文档](https://www.kernel.org/doc/html/latest/driver-api/dma-buf.html)
还说明底层可能迁移缓冲的存储位置，因此成功导入也不能单独证明像素从未经过系统内存。

只有 UAPI 明确规定的 `EINVAL`（22）被记为 `unsupported`。权限不足、设备退出、
`ENOTTY` 或其他错误会输出 `error/unknown`、`PROBE_RESULT=incomplete` 并以状态码 `2`
退出。权限由 Linux 对 `pidfd_getfd` 的访问检查决定；工具不会自动 sudo，也不会降低
ptrace 等宿主安全设置。正常用户在本次宿主上已能完成查询，无需 sudo。

接口依据是本机 `/usr/include/linux/vfio.h`，与 QEMU `hw/vfio/display.c` 的启动能力
查询相同；可对照 [Linux VFIO UAPI](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/uapi/linux/vfio.h)
和 [pidfd_getfd 手册](https://man7.org/linux/man-pages/man2/pidfd_getfd.2.html)。

## 升级驱动能解决吗

2026-09-05 又核对了本机驱动源码和保存的两个 NVIDIA 安装包；仅只读解包相关源码，
没有安装包、执行维护脚本、编译内核模块或切换运行中的驱动。

| 精确版本 | 核查方式 | 标准 VFIO 显示 DMA-BUF 结果 |
|---|---|---|
| 535.161.05 | 当前 VM1 能力实测与 `/usr/src` 源码互证 | 不支持 |
| 570.172.07（vGPU 18.4） | 本地 `.deb` 中普通及 open 两份 VFIO 源码 | 两份都直接拒绝不含 REGION 的请求 |
| 580.159.01（vGPU 19.5） | 本地 `.deb` 中 VFIO 源码 | 同样直接拒绝不含 REGION 的请求 |

三者的 `VFIO_DEVICE_QUERY_GFX_PLANE` 都先要求 `VFIO_GFX_PLANE_TYPE_REGION`，
不含它就返回 `-EINVAL`；REGION 的 PROBE 则返回成功。核查的 R570/R580 VFIO 源码
也没有实现 `VFIO_DEVICE_GET_GFX_DMABUF`。因此，不能把升级到这两个精确版本当作
已知解法。这里没有做 R570/R580 实机切换，也不外推所有未来版本或其他厂商私有接口。

可复核位置均为 `nvidia-vgpu-vfio/nvidia-vgpu-vfio.c`：535 当前源码第 3977 行；
570 普通模块第 4477 行、open 模块第 4367 行；580 第 4544 行。
安装包路径分别位于 `Downloads/vGPU18.4/Host_Drivers/` 和
`Downloads/vGPU19.5/Host_Drivers/`，文件及 SHA256 为：

```text
nvidia-vgpu-ubuntu-570_570.172.07_amd64.deb
37e13ef147fe97f77be44736fb4b9996f67355c1f19ef3da7be48a9a4af34fe9
nvidia-vgpu-ubuntu-580_580.159.01_amd64.deb
033d2aec703ea366f35cade25207ab30a279b8076eb7382daa31e9649bf3f246
```

不能只把拒绝分支改成成功：还缺真实 GPU 缓冲的导出、生命周期和同步实现。
CUDA/GPUDirect 支持 DMA-BUF 也不能代替这部分；例如
[CUDA 的句柄导出 API](https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__MEM.html)
针对指定的 CUDA 内存分配，并没有按 vGPU UUID 取得 Windows 控制台纹理的语义。

## 不增加 Guest 软件的其他方向

- 保留当前 SDL/vGPU：继续优化宿主复制、纹理上传和帧调度，减少主线程等待。
  异步上传与减少重复上传属于后续可研究方向；仍有 REGION 系统内存阶段，不能称为
  端到端 GPU。现有黑屏恢复修复和实机验收见 [SDL 教程](G11-SDL-PERFORMANCE.md)。
- 使用 Windows 自带远程桌面：这是绕开 QEMU REGION 的另一条显示通道，不需安装
  新的 Guest 应用，但需要支持接收 RDP 的系统版本、启用系统功能及策略，并验证两端
  实际硬编硬解。[微软列出的版本条件](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remotepc/remote-desktop-allow-access)
  包括 Pro/Enterprise/Education/Server，Home 不能作为接收端。
  [硬件编码策略](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-terminalserver#ts_server_avc_hw_encode_preferred)
  出错时会回退软件，因此也不能承诺全 GPU。它会把会话转接到远程终端，
  [并非 SDL 控制台的同步镜像](https://learn.microsoft.com/en-us/windows/win32/termserv/consoles-vs-terminals)。
  本仓库 `start-vm.sh --rdp` 仍是旧的 `legacy-shmem` 别名，不会启用上述系统 RDP 通道。

本次只核查这些边界，没有启用 Windows RDP、修改 Guest 策略或切换会话。

## 不碰 VM 的回归检查

```bash
python3 deploy/tests/qemu/test_vgpu_dmabuf_probe.py
```

测试用 mock fd/ioctl 验证两项 PROBE、错误分类、身份变化时退出和 fd 清理，不访问真实
GPU。工具不保存状态，运行完不需要回滚。

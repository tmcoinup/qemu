# gpu-mode — RTX 2080 vGPU ⇄ 消费版驱动 切换

## 这是什么

宿主机在 **vGPU host driver**（拆给 VM 用的 NVIDIA Grid 服务端，配 vgpu_unlock-rs）和 **消费版驱动**（CUDA / OpenGL / 游戏 / NVENC，宿主自己用）之间快速来回切换的脚本。

不是 passthrough。这是宿主驱动层的二选一切换：

| 模式       | 加载的内核模块                                              | 服务                  | 用途                                   |
| ---------- | ----------------------------------------------------------- | --------------------- | -------------------------------------- |
| `vgpu`     | `nvidia` + `nvidia_vgpu_vfio`                               | `nvidia-vgpu-mgr`     | mdev 拆 VM、vgpu_unlock-rs 注入        |
| `consumer` | `nvidia` (+ on-demand `nvidia_modeset/uvm/drm`)             | （无）                | 宿主直接跑 CUDA / NVENC / OpenGL / Vk  |

俩模式互斥：内核里只能挂一份 `nvidia.ko`，userspace 也只能存一份 `libnvidia-*`，所以切换 = 全套 .ko + 全套 .so + 二进制 + firmware 一起换。

## 已确认的版本组合

- **vGPU host driver**: `535.161.05` (vGPU 16.x host)，由 NVIDIA 官方 deb `nvidia-vgpu-ubuntu-535` 安装；本机已验证 guest 为 538.33 (`31.0.15.3833`)
- **消费版**: `nvidia-driver-580`（apt 包，noble / noble-updates 仓库；变量 `CONSUMER_DRV_MAJOR` 控制）
  - 之前是 `nvidia-driver-535`；为支持 PyTorch / CUDA 13 升到 580，需要 driver ≥ 580 才认 cu130 runtime
  - 改主版本号 = 改 `gpu-mode.sh` 顶部的 `CONSUMER_DRV_MAJOR` 常量 + 重跑 `init-consumer`
- **内核**: `6.8.0-31-generic`（vGPU dkms src 在此内核 build 失败，但 runtime .ko 已经在 /lib/modules 里跑得动；consumer 580 dkms 在此内核 OK）

两条线版本独立：vGPU 钉死 535（vGPU 16.x 系列），consumer 跟 NVIDIA 主线走（535 / 570 / 580 / ...）。
切换时全套文件都从对应快照解出来，不存在版本串味。

为什么用 apt 而不是 .run installer：vGPU 是 deb 装的，`.run` installer 检测到"alternate install method"会跳过 .ko 安装步骤，导致 modprobe 找不到模块。apt 路线干净直接。

## 工作原理

```
/opt/nvidia-modes/
├── snapshots/
│   ├── vgpu.tar.zst       (231M) ← 完整 vGPU 安装树打包（含 dkms src）
│   └── consumer.tar.zst   (371M) ← 完整消费版安装树打包
├── manifests/
│   ├── vgpu.list          25 paths
│   └── consumer.list      85 paths
├── state/
│   └── current            ← 一行: vgpu / consumer
└── cache/
    ├── NVIDIA-Linux-x86_64-535.230.02.run                  (备 .run 文件)
    └── libnvidia-egl-wayland1_1.1.13-1build1_amd64.deb     (绕本地透明代理)
```

切换流程（约 5–7 秒，期间 `/dev/nvidia*` 不可用）：

1. 拒绝继续：如果有 `qemu-system` 跑 / 有 mdev 设备 / lock 文件已占
2. `systemctl mask --runtime nvidia-vgpu-mgr nvidia-vgpud` + stop（mask 防 udev/systemd auto-start）
3. `rmmod` 倒序卸所有 nvidia\* 模块
4. `rm -rf` 两个 manifest **并集** + 当前文件树 expand_managed 扫到的所有路径（清掉前模式的孤儿）
5. `tar --zstd -xpf snapshots/<目标>.tar.zst -C /` 解压目标快照
6. `depmod -a` + `modprobe nvidia`（vgpu 模式再 `modprobe nvidia_vgpu_vfio`）
7. `vgpu` 模式 unmask + start nvidia-vgpu-mgr；`consumer` 模式保持 mask
8. 重启 gdm
9. 写 `state/current`

## 一次性初始化

> 必须在 vGPU 已经能正常用、guest 没在跑的时候做。

```bash
# 1) 把当前正在用的 vGPU 安装树打成快照
sudo /home/ubuntu/projects/qemu/deploy/host/gpu-mode.sh init-vgpu

# 2) 走 apt 路线装消费版，打 consumer 快照（默认）
sudo /home/ubuntu/projects/qemu/deploy/host/gpu-mode.sh init-consumer
```

`init-consumer` 的 apt 路线流程（以 `CONSUMER_DRV_MAJOR=580` 为例）：
1. mask + stop vGPU 栈，rmmod
2. apt-get update（noble / noble-updates 仓库可达）
3. dpkg -i 预装 `libnvidia-egl-wayland1` 绕本地透明代理对 main 仓库个别小包的偶发屏蔽
4. **显式 purge `nvidia-vgpu-ubuntu-535`**（跨主版本 535→580 apt 不会自动解冲突，必须先腾出 dpkg 名字空间；同主版本如 535→535 也走这条路统一处理）
5. `apt install nvidia-driver-580 nvidia-utils-580 libnvidia-encode-580 libnvidia-decode-580`
6. dkms 自动编译 consumer 580.x 到 `/lib/modules/.../updates/dkms/`
7. unload modules → snapshot consumer（snapshot 现在是 580 的文件层）
8. apt purge 所有 consumer 580 包（清 dpkg 状态，留 nvidia-dkms 包会阻止 vGPU 恢复）
9. dpkg -i 重装 `nvidia-vgpu-ubuntu-535_535.161.05_amd64.deb`（路径在 `VGPU_DEB_PATH` 常量里）
   - **当前内核 6.8 下 dkms build vGPU 535.161.05 会失败**（`eventfd_signal` API 改了），dpkg -i 会 exit 10。这一步失败可以接受，因为 .ko 已经从 vgpu 快照恢复在 /lib/modules 里
10. apt-mark hold + apply_snapshot vgpu + modprobe + start

如果 .run 路线想用：传 .run 路径作为参数。**但不推荐，原因见上**。

## 当前 dpkg 状态（"by design 空"）

成功 init 后，`dpkg -l 'nvidia-*' | awk '/^ii/'` 输出空。这是有意为之：
- 没有 dpkg 包"装着"，所以 `apt upgrade` 不会触发任何 nvidia 升级
- 没有 dpkg 冲突，可以随便 swap 文件层
- nvidia-smi / nvidia-vgpu-mgr 等都是 /usr/bin/ 里的二进制，不靠 dpkg

副作用：`apt list --installed | grep nvidia` 看不到任何包；`dpkg -L nvidia-driver-580` 找不到。但这不影响功能。

## 日常使用

```bash
sudo /home/ubuntu/projects/qemu/deploy/host/gpu-mode.sh status      # 看当前模式
sudo ./gpu-mode.sh consumer       # 切到消费版（宿主玩 / 跑 CUDA）
sudo ./gpu-mode.sh vgpu           # 切回 vGPU（开 VM）
sudo ./gpu-mode.sh doctor         # 排错信息一把梭
```

切换前 **必须** 把所有 VM 停干净，否则 `assert_no_gpu_users` 会拒绝：

```bash
~/projects/qemu/deploy/scripts/stop-vm.sh 1     # 或逐一停止所有 VM
ls /sys/bus/mdev/devices/               # 应当为空
```

## 升级 consumer 主版本

把 `CONSUMER_DRV_MAJOR` 改成新版（如 `570` → `580`），然后：

```bash
sudo /home/ubuntu/projects/qemu/deploy/host/gpu-mode.sh init-consumer
```

`init-consumer` 内部会先把当前 mode 切到中间状态（unload 模块）→ apt install 新版 → snapshot →
apt purge → dpkg -i 复原 vGPU → 落到 vgpu 模式。完成后再 `gpu-mode.sh consumer` 即可加载新版驱动。

何时需要升 consumer：跟 PyTorch / CUDA runtime 走。比如：

| PyTorch wheel | 最低 NVIDIA driver | 对应 `CONSUMER_DRV_MAJOR` |
| --- | --- | --- |
| `torch+cu121` / `cu124` | ≥ 525 | 535 OK |
| `torch+cu126` / `cu128` | ≥ 535 | 535 OK |
| `torch+cu130` | ≥ 580 | **必须 580+** |

vGPU 钉死 535 不动；升 vGPU 是另一码事（要换 vGPU 17.x 的 host deb）。

## 内核升级后

vGPU 535.161.05 的 dkms src 在 kernel 6.8 下编译失败（eventfd_signal API 变化）。如果升级到更新内核：

- consumer 端：apt 包 + dkms 通常能跟上新内核，重跑 `init-consumer` 重打 snapshot
- vGPU 端：535.161.05 src 不会自动适配新内核。当前 `/lib/modules/6.8.0-31-generic/updates/dkms/nvidia*.ko.zst` 是过去某个内核 build 产物，**只有当前内核能跑**。如果升级内核：
  - 找新内核兼容的 vGPU 版本（比如 vGPU 17.x 的 host driver）
  - 或回退到旧内核

如果只切换两个模式都要再用一次，建议 **不升级内核**，直到迁移到新 vGPU 栈。

## 已知边界

- **宿主显示输出**：当前 host 跑在 Intel iGPU，gdm 不绑 nvidia，所以切换不会真黑屏（只是脚本会 stop/start gdm 保险）。
- **vgpu_unlock-rs 不动**：unlock 的 `LD_PRELOAD` 只在 `nvidia-vgpu-mgr.service.d/unlock.conf` 里，consumer 模式服务不起，自然不注入；切回 vgpu 照旧。
- **CUDA toolkit / nvenc**：consumer 模式自带 `libcuda.so` 和 `libnvcuvid.so`，glob 已抓。如果你装 `cuda-toolkit-12-x` 之类 deb 包，那部分文件 **不归脚本管**（属于发行版包管理），切换时不会被动到。
- **Wayland gdm**：Ubuntu 24.04 默认 gdm Wayland。consumer 模式启动后如果想让 gdm 走 nvidia DRM，需要 `nvidia-drm.modeset=1`（见 `/etc/modprobe.d/nvidia.conf` 或 GRUB cmdline）。这是另外一回事，跟切换无关。
- **mask --runtime / unmask --runtime 必须对称**：脚本里 mask 用 `--runtime`（写到 /run/systemd/system/），unmask 也要 `--runtime`。否则会留下未清理的 mask symlink，下次 start 失败。
- **consumer 模式必须显式 modprobe nvidia_uvm**：靠 udev 按需加载在某些发行版组合下首次 `torch.cuda.is_available()` 会返回 False 并报 "CUDA unknown error"。`reload_modules` 在 consumer 分支已经 modprobe `nvidia_uvm` + `nvidia_modeset`，加载顺序：`nvidia` → `nvidia_uvm` → `nvidia_modeset`。

## 触发硬约束的注意事项

memory `feedback_hard_constraints.md` 写了"禁止整卡 passthrough"。**consumer 模式不是 passthrough** —— 是宿主自己用 GPU。约束没有违反。

但同一时刻只能一个角色：

- 在 consumer 模式下你 **不能** 同时用 vfio-pci / mdev 把卡给 VM
- `start-vm.sh` 在 consumer 模式启动 vGPU VM 会失败（mdev 类型不存在）
- 反过来 vgpu 模式宿主跑 CUDA 也跑不了（消费版 `libcuda.so` 不在）

脚本只管模式切换，业务侧调用方该自己判断 `gpu-mode.sh status` 决定能不能往下走。

## 排错

```bash
sudo ./gpu-mode.sh doctor
# 看 /var/log/dpkg.log              （apt install 失败时）
# 看 /var/lib/dkms/*/build/make.log （dkms 编译失败时）
# 看 dmesg | grep -i nvidia         （rmmod / modprobe 失败）
# 看 systemctl status nvidia-vgpu-mgr （vgpu 模式服务起不来）
```

常见坑：

| 现象                              | 原因                                   | 修法                                      |
| --------------------------------- | -------------------------------------- | ----------------------------------------- |
| `rmmod nvidia 失败`               | 还有进程持 `/dev/nvidia*`              | `lsof /dev/nvidia*` 找出来停掉            |
| `modprobe nvidia` 失败            | 内核升过级，快照里 .ko 不匹配          | 跑 `init-consumer` 重打；vGPU 端无解（看上文）|
| 切到 consumer 后 `nvidia-smi` 报错 | userspace .so 跟 .ko 版本不齐          | 大概率快照不全 → 重 `init-consumer`        |
| 切到 vgpu 后 mdev 类型为空         | `nvidia-vgpu-mgr` 没起来               | `systemctl status nvidia-vgpu-mgr` 看日志；可能 mask --runtime 没解 |
| `nvidia-vgpu-mgr` 起不来 "is masked" | 上次切换没 unmask 干净                  | `systemctl unmask --runtime nvidia-vgpu-mgr.service` |

## 文件清单

```
deploy/host/gpu-mode.sh         主脚本
deploy/host/gpu-mode.README.md  本文档
/opt/nvidia-modes/              所有快照与状态（脚本自建，sudo 可见）
/opt/nvidia-modes/state/current 当前模式，同时作为切换/恢复/mdev create-remove 的持久共享 flock inode
/home/ubuntu/Downloads/vGPU16.4/Host_Drivers/nvidia-vgpu-ubuntu-535_535.161.05_amd64.deb
                                vGPU 原 deb，init-consumer 时引用（VGPU_DEB_PATH 常量）
```

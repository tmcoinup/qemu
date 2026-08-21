# G-11 vGPU 宿主快速配置教程

这份教程用于把一张 NVIDIA GPU 固定到 G-11 的单一 framebuffer 档。默认推荐
2GB/2Q，适用于当前 RTX 2080 16GB，也为 Tesla V100 PCIe 16GB/32GB 提供封装。

如果你正在部署 V100，请先完整阅读
[`V100-ADAPTATION.md`](V100-ADAPTATION.md)。V100 在完成真卡验收前只能标记为
`hardware-unverified`。

## 先记住四条

1. 同一张物理 GPU 上只能运行同 framebuffer 大小的 vGPU。1GB 与 2GB 不能混开。
2. 16GB/32GB 使用完整标称显存，不人为扣固定余量：分别是 16384/32768MB。
3. 真 V100 使用官方 vGPU driver，`VGPU_MDEV_IDENTITY_MODE=off`，不装
   `vgpu_unlock`。
4. 不开启 `testsigning`/`nointegritychecks`，不改 BCD，不安装测试签名或自签名
   内核驱动；密码、license token、SSH 密钥等凭据不得写入仓库。

## 第 0 步：确认你买的是哪一种卡

在 Linux 宿主运行只读命令：

```bash
lspci -Dnn | grep -i nvidia
nvidia-smi --query-gpu=name,pci.bus_id,memory.total \
  --format=csv,noheader
```

记下 vGPU 卡的完整 BDF，例如 `0000:65:00.0`。不要照抄教程地址。

常用选择：

| 实际卡 | preset | 2GB resource | 满显存理论边界 |
|---|---|---|---:|
| RTX 2080 魔改 16GB | `rtx2080-16gb` | `nvidia-257` | 8 台，仍需实机启动验证 |
| Tesla V100 PCIe 16GB | `v100-pcie-16gb` | `V100-2Q` | 8 台，必须验第 8 台 |
| Tesla V100 PCIe 32GB | `v100-pcie-32gb` | `V100D-2Q` | 16 台，必须验第 16 台 |

SXM2 不是普通 PCIe 插卡。没有匹配的平台/载板、供电和散热方案时不要选择 SXM2
preset。

## 第 1 步：先停掉这张 GPU 上的全部 VM

不要一边运行 VM 一边切档。先正常关闭所有使用目标 NVIDIA GPU 的 VM，再检查：

```bash
find /sys/bus/mdev/devices -mindepth 1 -maxdepth 1 -printf '%f\n'
```

切档前这里应没有属于目标 GPU 的活动 mdev。不确定 UUID 属于哪张卡时先停止，不要
猜测删除。封装脚本不会替你停止 VM，也不会删除 mdev。

## 第 2 步：为宿主生成单档策略

进入仓库：

```bash
cd /home/ubuntu/projects/qemu
GPU_BDF=0000:65:00.0   # 改成第 0 步查到的真实地址
```

三种常用命令只选一条。

### A. 当前 RTX 2080 16GB，固定 2GB

```bash
bash deploy/configure-g11-vgpu-host.sh \
  --preset rtx2080-16gb \
  --tier 2048 \
  --gpu "$GPU_BDF"
```

### B. Tesla V100 PCIe 16GB，固定 2GB

```bash
bash deploy/configure-g11-vgpu-host.sh \
  --preset v100-pcie-16gb \
  --tier 2048 \
  --gpu "$GPU_BDF"
```

### C. Tesla V100 PCIe 32GB，固定 2GB

```bash
bash deploy/configure-g11-vgpu-host.sh \
  --preset v100-pcie-32gb \
  --tier 2048 \
  --gpu "$GPU_BDF"
```

默认输出是：

```text
deploy/host/vgpu-host.conf
```

该文件已 gitignore，内容只应是 GPU BDF、档位、profile 和容量，不应包含任何凭据。

若文件已存在且内容不同，脚本会拒绝覆盖。确认所有 VM/mdev 已停止且 preset/BDF
无误后，才可在同一命令末尾加 `--force`。`--force` 只原子替换策略文件，不会切换
驱动或清理正在运行的 VM。已初始化的宿主上，封装会从活动 mdev 检查一直持有与
分配器相同的全局锁到原子发布；锁被占用、锁文件不安全或出现活动 mdev 都会拒绝。
只有尚未安装驱动/模式状态、没有锁且 mdev 为空的 pre-driver 环境可无锁生成。

`create-vm.sh` 和 `start-vm.sh` 只接受可读普通、非符号链接的 host config；坏语法、
目录、符号链接或显式缺失都会 fail-closed，不会静默回退到 2048MB。

## 第 3 步：人工检查生成结果

```bash
sed -n '1,80p' deploy/host/vgpu-host.conf
```

V100 16GB/2Q 应看到这些关键值：

```text
VGPU_HOST_FB_TIER_MB=2048
VGPU_RESOURCE_PROFILE=V100-2Q
VGPU_RESOURCE_FB_MB=2048
VGPU_TOTAL_FB_MB=16384
VGPU_CAPACITY_CHECK=both
VGPU_CONSOLE_INTERVAL_US=0
VGPU_MDEV_IDENTITY_MODE=off
SPOOF_MODE=off
```

V100 32GB/2Q 应是 `V100D-2Q` 和 `32768`。如果同时出现 1Q/2Q 两条 resource
映射，或 16GB 被写成 15872，请停止使用并重新生成。

### 当前 RTX 2080：检查 vgpu_unlock 全局 profile 基线

这一步只适用于当前 RTX 2080 unlock 宿主；真 V100 必须跳过。先做只读检查：

```bash
sudo deploy/host/sync-vgpu-profile-override.sh --check
```

返回“synchronized”即可继续。若报告 drift，先关闭该 NVIDIA GPU 上全部 VM，确认
没有活动 mdev，再执行：

```bash
sudo deploy/host/sync-vgpu-profile-override.sh --apply
sudo deploy/host/sync-vgpu-profile-override.sh --check
```

`--apply` 只把仓库受管的全局 `nvidia-256/257` 表语义合并到现有 TOML；所有未知
profile 和 `[mdev."UUID"]` 都会保留。它按固定顺序同时持有宿主分配锁和 root admin
helper 锁，再拒绝活动 mdev、建立备份并原子发布；它不会重启 vGPU 服务。不要直接用仓库模板覆盖整个
`/etc/vgpu_unlock/profile_override.toml`。

## 第 4 步：V100 只读预检

RTX 2080 可把下面 profile 换成 `nvidia-257`。V100 16GB：

```bash
deploy/host/probe-vgpu-host.sh \
  --config deploy/host/vgpu-host.conf \
  --profile V100-2Q
```

V100 32GB：

```bash
deploy/host/probe-vgpu-host.sh \
  --config deploy/host/vgpu-host.conf \
  --profile V100D-2Q
```

必须确认：

- parent BDF 就是目标卡；
- vendor 是 NVIDIA，driver 正确，`device_api` 是 `vfio-pci`；
- profile 恰好匹配一个 type；
- framebuffer 是 2048MB；
- `available_instances` 可读。

probe 失败时不要改成某个猜测的 `nvidia-NNN`，也不要退回 RTX6000 profile。

## 第 5 步：新建 VM

宿主策略存在后，不指定显卡也只会从当前固定档随机：

```bash
./deploy/scripts/create-vm.sh 101
```

也可以显式确认 2GB：

```bash
./deploy/scripts/create-vm.sh 101 --gpu-vram 2048
```

若指定 `--gpu-vram 1024`，脚本应拒绝，因为宿主固定为 2048MB。这是正确保护，
不要绕过。已有 1GB VM 也不能在 2GB 宿主档上启动；应先规划全池迁移，而不是修改
某一台 VM 的只读身份。

## 第 6 步：V100 首次启动必须保持原生身份

V100 使用 NVIDIA 官方签名且与 host bundle 兼容的 guest driver。安装介质和 driver
由管理员通过自己的安全渠道提供，不放进仓库，也不把下载凭据写进命令历史或脚本。

首次正常 vGPU 启动显式加：

```bash
./deploy/scripts/start-vm.sh 101 --no-spoof
```

通过标准：

- Windows Device Manager 为 Code 0；
- guest `nvidia-smi` 显示所选 V100 Q profile；
- license 有效；
- Windows PnP/PCI 保持原生 V100 vGPU 身份；
- OVMF/ramfb、Windows 动态桌面、SDL/GTK 显示和分辨率切换正常；
- 宿主无新增 NVIDIA Xid。

不要运行 RTX 2080 专用的 `setup-vgpu-unlock.sh`、`gpu-mode.sh` 或当前
`recover-vgpu-gpu.sh`。不要安装 `profile_override.toml`，不要给 V100 manager
注入 unlock `LD_PRELOAD`。

## 第 7 步：验证第 8/16 台，不只看 mdev 创建

全部测试 VM 必须固定 2048MB，并落在同一张 V100 上。

### 16GB V100

依次启动 1～8 台。第 8 台必须真的进入 Windows、加载 vGPU driver、Device
Manager Code 0 且 license 有效。

### 32GB V100

依次启动 1～16 台。第 16 台必须达到相同标准。

两种型号都要继续检查：

```bash
nvidia-smi vgpu
journalctl -u nvidia-vgpu-mgr --since today
dmesg | grep -Ei 'NVRM|Xid|vfio|mdev'
```

验收时还要观察温度、CPU、内存和 SSD。若 CPU/SSD 先到上限，无法真正启动第
8/16 台，只能记录当前已验证台数，不能宣称 GPU 满容量已验证。

mdev 创建成功不算通过。若边界 VM 启动失败，应停止测试、确认失败实例被回收并
保存日志；不要把 `VGPU_TOTAL_FB_MB` 改成 15872/31744 之类固定预留值来掩盖问题。

## 第 8 步：停机与残留检查

全部 VM 正常关闭后：

```bash
nvidia-smi vgpu
find /sys/bus/mdev/devices -mindepth 1 -maxdepth 1 -printf '%f\n'
```

确认无残留，再做一次宿主重启和重新并发启动。异常中止 QEMU 后也要验证 mdev 能
自动回收或被受控流程清理。

## 如何整体切到 1GB

只有明确需要 1GB 池时才这样做：

1. 关闭目标 GPU 上全部 VM；
2. 确认无活动/残留 mdev；
3. 用同一个 preset 重跑封装，把 `--tier 2048` 改成 `--tier 1024`，并加
   `--force`；
4. 只创建/启动 1GB VM；
5. 重新做完整实机验收。

不能保留一部分 2GB VM 同时运行，也不能把已有 VM 的显存字段随手改小。

## 凭据应该放哪里

- `deploy/host/vgpu-host.conf` 不含凭据；
- vGPU license 配置按 NVIDIA 官方方式保存在仓库外，并限制文件权限；
- SSH 私钥、宿主密码、license token 不写入 Git、Markdown、示例配置或测试 fixture；
- 自动化需要时，使用安全凭据服务或短期环境变量；任务结束后清理 shell 环境；
- 不要把 `SUDO_PASSWORD=...` 写进脚本、`.env` 或命令历史。

只要出现来源不明的驱动、要求开启测试签名/完整性绕过或修改 BCD 的步骤，就立即
停止。这些步骤不属于 G-11 的 V100 正式部署流程。

# Tesla V100 宿主适配说明

> 当前状态：**单 framebuffer 档的软件适配已完成，V100 实机尚未验收
> （hardware-unverified）**。假 sysfs、配置生成和 dry-run 只能证明软件选择逻辑，
> 不能证明某一张 V100 已达到生产要求。第一次到卡必须完成本文的 8/16 台实机验收。

傻瓜式首次部署见
[`G11-VGPU-HOST-QUICKSTART.md`](G11-VGPU-HOST-QUICKSTART.md)。本文解释为什么要
这样配置、16GB/32GB 型号的差异，以及什么结果才允许标记为生产可用。

## 1. 不可突破的边界

当前路径是 NVIDIA 官方 vGPU host driver 提供 mdev，再由 QEMU/VFIO 交给 Windows：

```text
物理 Tesla V100
  -> NVIDIA 官方 vGPU 16 host driver / mdev_supported_types
  -> 一个 mdev UUID
  -> QEMU vfio-pci-nohotplug,sysfsdev=...
  -> NVIDIA 官方签名的 vGPU guest driver
```

因此：

- 这是 mediated device，不是 QEMU 模拟 CUDA、图形核心或显存；
- 不是把整张 V100 独占直通给一台 VM；
- 需要 IOMMU、VFIO、`nvidia-vgpu-mgr`、兼容的 host/guest driver 组合及有效
  vGPU license；
- QEMU 的 PCI 参数不会改变物理 V100、真实 framebuffer 或调度份额；
- Tesla V100 是官方支持的 vGPU 卡，**不得安装或加载 `vgpu_unlock`**；
- `VGPU_MDEV_IDENTITY_MODE` 必须为 `off`。初次验收必须使用原生 V100 vGPU
  身份，不能把消费卡名称投射当成 V100 已适配成功；
- 只使用 NVIDIA 官方签名的 host/guest 驱动。**禁止**测试签名、自签名内核驱动，
  禁止开启 Windows `testsigning` 或 `nointegritychecks`，禁止修改 BCD；
- license、宿主密码、SSH 密钥、token 等凭据不得写进仓库。需要时只通过安全渠道、
  短期环境变量或仓库外的 root-owned 配置提供。

V100 没有当前 RTX 2080 `vgpu_unlock` 的 per-mdev 营销名称后端。
`SPOOF_MODE=off`/`--no-spoof` 下 Windows 看到原生 V100 vGPU 身份是正确结果，不是
缺陷。若业务以后需要另一种 guest-visible identity，应作为独立功能重新验收，
不能在 V100 首次上线时顺带开启。

## 2. 同一物理 GPU 只能使用一个 framebuffer 档

[NVIDIA vGPU 16 的有效 time-sliced 配置](https://docs.nvidia.com/vgpu/16.0/grid-vgpu-user-guide/index.html)
要求同一物理 GPU 使用相同 framebuffer 大小。1Q 与 2Q 分别是 1024MB 和
2048MB，不能在同一张 V100 上同时运行。这个约束也适用于当前 RTX 2080 unlock
宿主，不是换成官方支持的 V100 后就会消失。

G-11 采用两层 fail-closed 保护：

1. 宿主策略只生成一个 `VGPU_HOST_FB_TIER_MB` 和一个
   `VGPU_RESOURCE_PROFILE`；
2. mdev 分配锁内读取该物理 GPU 上所有活动 mdev 的真实 framebuffer，发现不同
   档位或无法读取时拒绝新分配。

默认生产档为 **2048MB/2Q**。这会避开 1GB Kepler 身份与当前 R535 guest driver
基线的版本矛盾，也与现有 CPU、内存和存储承载规模更匹配。

如确需切到 1024MB/1Q，必须先关闭该物理 GPU 上所有 VM，确认没有残留 mdev，
再用封装脚本整体切档。不能让新建账号自行随机决定 1GB 或 2GB，也不能只改某一台
VM 的 `vm.conf`。

## 3. V100 型号、preset 与 resource profile

`nvidia-NNN` 目录编号会随 GPU SKU 和 host driver 改变，不能硬编码。配置使用
sysfs `name` 中的官方 profile 名，并由只读 probe 确认它在目标宿主上唯一存在。

| 物理 V100 变体 | 封装 preset | 1GB 档 | 2GB 档（推荐） | `VGPU_TOTAL_FB_MB` |
|---|---|---|---|---:|
| Tesla V100 PCIe 16GB | `v100-pcie-16gb` | `V100-1Q` | `V100-2Q` | `16384` |
| Tesla V100 PCIe 32GB | `v100-pcie-32gb` | `V100D-1Q` | `V100D-2Q` | `32768` |
| Tesla V100 SXM2 16GB | `v100-sxm2-16gb` | `V100X-1Q` | `V100X-2Q` | `16384` |
| Tesla V100 SXM2 32GB | `v100-sxm2-32gb` | `V100DX-1Q` | `V100DX-2Q` | `32768` |
| Tesla V100S PCIe 32GB | `v100s-pcie-32gb` | `V100S-1Q` | `V100S-2Q` | `32768` |
| Tesla V100 FHHL 16GB | `v100-fhhl-16gb` | `V100L-1Q` | `V100L-2Q` | `16384` |

SXM2 模组不是普通 PCIe 插卡。采购前必须确认主机平台、载板、供电和散热支持；
不能因为封装脚本存在 SXM2 preset，就认为当前 X99 PCIe 主机能直接安装 SXM2。
Tesla PCIe 卡还必须核对机箱风道、被动散热条件、供电接口和 PSU 余量。

最终以目标宿主实际导出的 `mdev_supported_types/*/{name,description,
available_instances,device_api}` 为准。profile 不存在、有歧义、framebuffer 不符，
都必须停止，不能退回 `RTX6000-2Q` 或猜一个 `nvidia-NNN`。

## 4. 完整使用 16GB/32GB，不扣固定余量

本项目按用户要求不预留固定 framebuffer：

- 16GB 型号写 `VGPU_TOTAL_FB_MB=16384`；
- 32GB 型号写 `VGPU_TOTAL_FB_MB=32768`；
- 不写 `15872`、`31744` 之类人为扣减值；
- 容量门禁同时检查 NVIDIA 的实时 `available_instances` 和当前 parent 下活动
  mdev 的 framebuffer 求和。

“不扣固定余量”不等于提前承诺满额并发。mdev 创建成功也不等于 VM 已成功打开
VFIO、进入 Windows 并加载驱动。2Q 档的理论边界是：

- V100 16GB：8 × 2048MB；
- V100 32GB：16 × 2048MB。

因此 16GB 的第 8 台、32GB 的第 16 台必须在真卡上做完整启动验收。若边界实例
失败，应让启动事务回收 mdev，保存 NVIDIA/QEMU 日志并保持
`hardware-unverified`；不能偷偷改成固定显存预留后宣称问题解决，也不能只以
“成功创建第 8/16 个 mdev”作为通过证据。

## 5. 用统一封装生成宿主策略

不要复制双档模板或手工同时填写 1Q/2Q。统一使用：

[`deploy/configure-g11-vgpu-host.sh`](../configure-g11-vgpu-host.sh)

它只生成宿主资源策略，不安装驱动、不创建 mdev、不修改 BCD，也不写凭据。
默认输出为 gitignored 的 `deploy/host/vgpu-host.conf`，已存在且内容不同则拒绝覆盖；
只有确认目标 GPU 上所有 VM/mdev 都已停止后才能加 `--force`。

16GB PCIe V100，推荐 2Q：

```bash
cd /home/ubuntu/projects/qemu
GPU_BDF=0000:65:00.0   # 替换为 lspci -D 查到的真实地址

bash deploy/configure-g11-vgpu-host.sh \
  --preset v100-pcie-16gb \
  --tier 2048 \
  --gpu "$GPU_BDF"
```

32GB PCIe V100，推荐 2Q：

```bash
cd /home/ubuntu/projects/qemu
GPU_BDF=0000:65:00.0   # 替换为真实地址

bash deploy/configure-g11-vgpu-host.sh \
  --preset v100-pcie-32gb \
  --tier 2048 \
  --gpu "$GPU_BDF"
```

生成的 16GB/2Q 策略应等价于：

```bash
VGPU_MGPU=0000:65:00.0
VGPU_HOST_FB_TIER_MB=2048
VGPU_RESOURCE_PROFILE=V100-2Q
VGPU_RESOURCE_FB_MB=2048
VGPU_TOTAL_FB_MB=16384
VGPU_CAPACITY_CHECK=both
VGPU_CONSOLE_INTERVAL_US=0
VGPU_MDEV_IDENTITY_MODE=off
SPOOF_MODE=off
```

32GB/2Q 只有 profile 和总显存变化为 `V100D-2Q`、`32768`。不要手工加入另一档
映射。

如果策略必须放在仓库外，可用 `--output` 生成到专用路径，并在启动时明确传入：

```bash
sudo install -d -o root -g root -m 0750 /etc/qemu-vgpu

# 先生成到当前用户拥有的安全临时路径，再由管理员审核并安装；
# 不要把密码、license token 写进策略文件。
bash deploy/configure-g11-vgpu-host.sh \
  --preset v100-pcie-16gb --tier 2048 --gpu "$GPU_BDF" \
  --output /tmp/g11-vgpu-host.conf
sudo install -o root -g root -m 0644 \
  /tmp/g11-vgpu-host.conf /etc/qemu-vgpu/v100-pcie-16gb.conf

VGPU_HOST_CONFIG=/etc/qemu-vgpu/v100-pcie-16gb.conf \
  ./deploy/scripts/start-vm.sh 1 --no-spoof
```

`/tmp/g11-vgpu-host.conf` 只含非敏感资源策略，但审核安装后仍应删除。任何 license
凭据应按 NVIDIA 官方方式配置在仓库外；宿主密码只通过安全渠道或短期环境变量提供。

## 6. 驱动、unlock 与宿主工具边界

V100 使用同一 vGPU 16 release family 中兼容的官方 host manager 与 guest driver。
不能只看主版本数字接近，也不能直接沿用当前 RTX 2080 的包路径或驱动快照。

V100 宿主禁止运行：

- `deploy/host/setup-vgpu-unlock.sh`；
- 面向 RTX 2080 的 `deploy/host/gpu-mode.sh`；
- 面向当前单卡 unlock 状态的 `deploy/host/recover-vgpu-gpu.sh`；
- 任何会安装测试签名/自签名内核驱动或修改 Windows BCD 的旧流程。

不要把 `deploy/host/profile_override.toml` 安装到 V100 profile，也不要给
`nvidia-vgpu-mgr` 注入 `vgpu_unlock` 的 `LD_PRELOAD`。首次验收应检查服务环境中
没有残留 unlock drop-in。

`VGPU_CONSOLE_INTERVAL_US=16667` 是当前 R535/RTX 2080 的实验参数，不是稳定 ABI。
V100 默认保持 `0`。只有真卡上分别测试静态桌面、高动态画面、Xid 和 CPU 占用后，
才能为该精确 SKU/driver 组合评估非零值。

## 7. 无卡阶段能验证什么

无卡测试可以证明：

- preset 能生成正确的单档 profile、16/32GB 完整容量和 identity-off 策略；
- `VGPU_MGPU` 完整 BDF、profile 唯一匹配、vendor/API/framebuffer 校验会 fail closed；
- 另一张 GPU 上的 mdev 不会计入当前 parent；
- 活动 mdev 与请求 framebuffer 不同会在分配锁内被拒绝；
- `available_instances=0`、framebuffer 不符和总量超限会在写 sysfs 前失败；
- QEMU dry-run 使用 mdev `sysfsdev`，而不是整卡 `host=BDF` 直通。

推荐定向回归：

```bash
deploy/tests/vgpu/test_vgpu_mdev_portability.sh
deploy/tests/vgpu/test_root_start_vm_native_display.sh
deploy/tests/vgpu/test_vgpu_console_interval_static.sh
deploy/tests/vgpu/test_vgpu_profile_catalog.sh
```

这些测试不能证明实际 V100 会导出目标 Q profile、VFIO display REGION 可用、
第 8/16 台能进入 Windows，或 license 能成功获取。

## 8. V100 到卡后的强制验收

每一种实际采购的 V100 SKU 都要独立验收，不能用 16GB PCIe 的结果替代 32GB、
SXM2、V100S 或 FHHL。

### 8.1 硬件与驱动

- 用 `lspci -Dnn`、`nvidia-smi -q` 核对 SKU、显存、完整 BDF 和序列号；
- 核对供电、风道、温度、PCIe 链路、IOMMU group，确认宿主桌面和其它进程未占卡；
- 核对官方 vGPU 16 host driver、`nvidia-vgpu-mgr`、`nvidia-vgpud` 和 license；
- 检查服务环境无 `vgpu_unlock`、无 profile override、无测试/自签名驱动；
- 以精确 BDF 重新生成策略，生产多卡宿主不要使用 `auto`。

### 8.2 只读 profile 预检

以 16GB/2Q 为例：

```bash
deploy/host/probe-vgpu-host.sh \
  --config deploy/host/vgpu-host.conf \
  --profile V100-2Q
```

32GB 改为 `V100D-2Q`。输出必须确认：所选 profile 唯一、framebuffer=2048MB、
parent 是配置的 V100、`device_api=vfio-pci`。不得同时为 1Q 和 2Q 建立生产策略。

### 8.3 单 VM 显示与 Windows 验收

- 先用 `--no-spoof` 启动，确认外部 PCI/PnP 保持原生 V100 vGPU 身份；
- 验证 OVMF/ramfb、Windows driver 接管、SDL/GTK 动态画面和分辨率切换；
- 确认 Device Manager Code 0、guest `nvidia-smi` profile 正确、license 有效；
- 如果 QEMU 报 `device doesn't support any (known) display method`，仅 compute
  可用不能算 G-11 验收通过。

### 8.4 第 8/16 台满边界验收

所有测试 VM 必须使用同一个 2048MB 档和同一个物理 V100：

- 16GB：依次启动 1～8 台，第 8 台也必须进入 Windows、加载驱动且 Code 0；
- 32GB：依次启动 1～16 台，第 16 台也必须达到同一标准；
- 满载保持计划的压力测试时长，持续检查 `dmesg`、journal、NVIDIA Xid、温度、
  显示刷新和输入响应；
- 随机停止、重启一台，确认 mdev 正确释放并能重新分配；
- 全部停止后确认无残留 mdev，再做一次宿主重启后的复测。

如果 CPU、内存或 SSD 先达到上限，导致无法并发启动到第 8/16 台，就只能记录
“本宿主已验证到 N 台”，不能宣称 V100 满容量已验收。32GB V100 不会自动解决
当前宿主的 CPU 或单 SSD 瓶颈。

完成上述项目并保存不含凭据的验收记录后，才可把该精确 SKU、driver、profile
和宿主组合从 `hardware-unverified` 改为生产已验证。

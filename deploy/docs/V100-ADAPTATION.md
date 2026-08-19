# Tesla V100 宿主适配说明

> 当前状态：**1GB/2GB 软件预适配已完成，V100 实机未验收
> （hardware-unverified）**。配置、假 sysfs 和 dry-run 已在无卡环境验证；
> 下文“到机后”清单完成前不代表生产可用。

本文说明如何把当前 NVIDIA vGPU 启动链路从 RTX 2080 宿主迁移到 Tesla V100。
重点是宿主资源选择、驱动边界和验证方法；它不把 V100 加成一个 QEMU 模拟设备。

## 路径边界

当前方案使用 NVIDIA vGPU host driver 在物理 GPU 上创建 mediated device
（mdev），再由 QEMU 的 VFIO 设备把该 mdev 交给客户机：

```text
物理 Tesla V100
  -> NVIDIA vGPU host driver / mdev_supported_types
  -> 一个 mdev UUID
  -> QEMU vfio-pci-nohotplug,sysfsdev=...
  -> Windows NVIDIA vGPU guest driver
```

因此，这条路径：

- 是 mdev/vGPU，不是由 QEMU 软件模拟 CUDA、图形核心或显存；
- 不是把整张 V100 独占直通给一台虚拟机；每台虚拟机拿到的是所选 vGPU
  resource profile 对应的 mediated device；
- 仍依赖 IOMMU、VFIO、NVIDIA vGPU manager、匹配的 guest driver 和 vGPU
  license；
- QEMU 命令行中的 `x-pci-*` 只改变客户机看到的 PCI 身份，不会改变物理
  V100 型号、实际 framebuffer 或调度份额。

仓库提供的官方 V100 模板默认同时设置 `SPOOF_MODE=off` 和
`VGPU_MDEV_IDENTITY_MODE=off`：初次验收时 Windows 的系统 PCI/PnP 身份应保持
V100 vGPU 原生值。所选 1GB/2GB 消费卡目录行只绑定同容量资源和便携用户态元数据，
不能当成物理 V100 身份已被改变的证明。

mdev 的分配和回收入口见
[`deploy/lib/vgpu-mdev.sh`](../lib/vgpu-mdev.sh)，QEMU 的
`display=on,ramfb=on,enable-migration=off` 启动路径见
[`deploy/scripts/start-vm.sh`](../scripts/start-vm.sh)。

## V100 型号与 1Q/2Q resource profile

V100 的 `nvidia-NNN` mdev type 编号由安装的 host driver 和机器实际导出的
sysfs 内容决定，不能在代码或配置里猜测。适配时按 sysfs `name` 匹配下表中的
profile 名，再记录实际的 `nvidia-NNN` 目录。

| 物理 V100 变体 | 1GB 身份映射 | 2GB 身份映射 | `VGPU_TOTAL_FB_MB` |
|---|---:|---:|---:|
| Tesla V100 PCIe 16GB | `V100-1Q` | `V100-2Q` | `16384` |
| Tesla V100 PCIe 32GB | `V100D-1Q` | `V100D-2Q` | `32768` |
| Tesla V100 SXM2 16GB | `V100X-1Q` | `V100X-2Q` | `16384` |
| Tesla V100 SXM2 32GB | `V100DX-1Q` | `V100DX-2Q` | `32768` |
| Tesla V100S PCIe 32GB | `V100S-1Q` | `V100S-2Q` | `32768` |
| Tesla V100 FHHL | `V100L-1Q` | `V100L-2Q` | `16384` |

名称、framebuffer 和每卡最大实例数以
[NVIDIA vGPU 16 Virtual GPU Types Reference](https://docs.nvidia.com/vgpu/16.0/grid-vgpu-user-guide/index.html#virtual-gpu-types-reference)
为基线；最终仍以目标宿主实际导出的 sysfs `name` 和 `available_instances` 为准。

表中的总显存是型号的标称 framebuffer 容量，用于启动前的资源上限检查；
最终可创建实例数还必须服从 host driver 暴露的 profile 能力、保留开销和
`available_instances`。不要仅凭 `总显存 / 单实例显存` 承诺可并发
VM 数量；1GB 与 2GB 混合时同样必须以 driver 实时结果为准。

SXM2 设备在系统中仍会有可供 sysfs 使用的 PCI BDF，`VGPU_MGPU` 应填写该设备
实际枚举出的地址，不能照抄另一台机器的值。

## 宿主配置变量

V100 适配使用以下宿主资源变量。它们描述物理资源，不应再与每台 VM 的
guest-visible GPU 身份混在一起：

| 变量 | 含义 |
|---|---|
| `VGPU_HOST_CONFIG` | 可选的宿主配置文件路径。启动器默认读取 `deploy/host/vgpu-host.conf`；只有要改用其他文件时才设置此变量。 |
| `VGPU_RESOURCE_PROFILE_1024` | 1GB guest 身份要匹配的官方 vGPU resource profile 名，例如 `V100-1Q`。 |
| `VGPU_RESOURCE_PROFILE_2048` | 2GB guest 身份要匹配的官方 vGPU resource profile 名，例如 `V100-2Q`。 |
| `VGPU_RESOURCE_PROFILE` / `VGPU_RESOURCE_FB_MB` | 只保留给单一容量的 legacy 静态配置；不能与上述同容量映射冲突，新 V100 部署不使用它们。 |
| `VGPU_MGPU` | 物理 V100 的完整 PCI BDF，例如 `0000:65:00.0`；也可用 `auto`，但 profile 在全宿主必须唯一匹配。 |
| `VGPU_TOTAL_FB_MB` | 该物理 GPU 的 framebuffer 上限，16GB 型号为 `16384`，32GB 型号为 `32768`。 |
| `VGPU_CONSOLE_INTERVAL_US` | R535 console REGION copy 周期；当前实验值为 `16667`，`0` 表示不写 NVIDIA 私有参数。 |
| `VGPU_MDEV_IDENTITY_MODE` | host per-mdev 名称后端；官方 V100 无 vgpu_unlock，必须设为 `off`。 |

仓库提供通用模板
[`deploy/host/vgpu-host-v100.conf.example`](../host/vgpu-host-v100.conf.example)。
先复制为启动器默认读取的本机配置；该文件属于宿主状态，不应直接改写通用模板：

```bash
cp deploy/host/vgpu-host-v100.conf.example deploy/host/vgpu-host.conf
```

以 16GB PCIe V100 为例，`deploy/host/vgpu-host.conf` 最终应表达以下内容；
尖括号内容必须在到卡后替换，不能作为出厂默认值：

```bash
VGPU_RESOURCE_PROFILE_1024=V100-1Q
VGPU_RESOURCE_PROFILE_2048=V100-2Q
VGPU_MGPU=<目标宿主上的完整PCI-BDF>
VGPU_TOTAL_FB_MB=16384
VGPU_CONSOLE_INTERVAL_US=0
VGPU_MDEV_IDENTITY_MODE=off
```

如需把实际配置放在仓库外或维护多套宿主配置，再通过路径覆盖默认文件：

```bash
VGPU_HOST_CONFIG=/etc/qemu-vgpu/v100-pcie-16gb.conf \
  ./deploy/scripts/start-vm.sh 1
```

32GB PCIe 型号只需按表同时改为 `V100D-1Q`/`V100D-2Q` 和
`32768`；其他变体同理。配置加载后
应校验数值格式、BDF 格式、profile 唯一匹配和 framebuffer 上限，遇到未知值
必须拒绝启动，不能静默退回 RTX 6000/`nvidia-257`。

## 驱动与 vgpu_unlock

Tesla V100 是官方支持 vGPU 的数据中心 GPU，不需要 `vgpu_unlock`。V100 宿主
应使用未注入 unlock hook 的官方 vGPU host driver，不应执行当前面向消费卡的
[`deploy/host/setup-vgpu-unlock.sh`](../host/setup-vgpu-unlock.sh)，也不应把
[`deploy/host/profile_override.toml`](../host/profile_override.toml) 中的 RTX 6000
override 套到 V100 profile 上。

[`deploy/host/gpu-mode.sh`](../host/gpu-mode.sh) 也是当前 RTX 2080 宿主的本机
驱动快照/切换工具，其 deb 路径、驱动版本和 consumer package 均已钉死。
V100 到机时不要直接运行它；如果还需要在“vGPU 宿主”与“宿主 CUDA”
间切换，应先为 V100 的官方驱动单独建立并验证快照。

R535 / NVIDIA vGPU 16 支持上述 V100 1Q/2Q profile，但 host 与 guest driver 必须
来自兼容的 vGPU release 组合。不能只看两边都含“535”，也不能直接复用仓库中
为现有 RTX 2080 环境写死的 guest 版本判断。部署前应以同一 vGPU 16 driver
bundle 的兼容组合为准，并同时核对 vGPU manager、guest display driver 和
license 状态。

`VGPU_CONSOLE_INTERVAL_US=16667` 使用的是当前 R535 环境验证过的 NVIDIA 私有
console 参数，不属于稳定 ABI。换 minor version、V100 变体或 profile 后必须重新
测动态画面；若参数节点不存在、driver 拒绝或出现稳定性问题，应设为 `0`，使用
驱动默认周期，而不是强制写入。相关版本保护逻辑在
[`deploy/lib/vgpu-mdev.sh`](../lib/vgpu-mdev.sh)。

## 没有 V100 时可以完成的工作

以下工作不需要目标显卡，可以先完成并纳入回归测试：

1. 将宿主资源配置与 guest-visible GPU identity 解耦，只通过本文列出的
   `VGPU_*` 宿主变量选择物理资源。
2. 建立 V100-1Q/2Q 配置 fixture，断言 1024/2048MB 身份自动选中
   同容量资源，且 16GB 上 7个 2GB + 2个 1GB 的混合容量边界正确。
3. 用临时目录构造假的 `mdev_supported_types`：覆盖唯一名称匹配、没有匹配、
   重复匹配、profile 目录编号变化和 `available_instances=0`。
4. 测试 `VGPU_MGPU` 的 BDF 校验，以及所指 sysfs 设备的 vendor、parent GPU 和
   mdev type 归属检查；不要让其它 GPU 上的 mdev 被计入当前卡的资源用量。
5. 测试 16GB/32GB 容量边界、单实例 framebuffer 不一致和并发分配拒绝逻辑。
6. 用 `start-vm.sh --dry-run` 断言最终参数仍含正确的 mdev `sysfsdev`、
   `display=on`、`ramfb=on` 和 `enable-migration=off`，且不出现整卡 `host=BDF`
   直通参数。
7. 为官方 V100 宿主配置增加断言：不加载 `vgpu_unlock`、不安装
   `LD_PRELOAD` override、不套用 RTX 6000 profile override。
8. 运行 shell 语法检查、profile 单元测试和 native-display dry-run 测试。

现有无硬件测试可参考：

- [`test_vgpu_profile_catalog.sh`](../tests/vgpu/test_vgpu_profile_catalog.sh)
  使用临时 VM root 验证 profile 和配置生成；
- [`test_root_start_vm_native_display.sh`](../tests/vgpu/test_root_start_vm_native_display.sh)
  使用 fake QEMU 验证 native/legacy 参数且不创建 mdev；
- [`test_vgpu_console_interval_static.sh`](../tests/vgpu/test_vgpu_console_interval_static.sh)
  使用临时 sysfs 形状验证 console 参数保护。
- [`test_vgpu_mdev_portability.sh`](../tests/vgpu/test_vgpu_mdev_portability.sh)
  构造 V100 + 另一张 GPU 的假 sysfs，验证动态 profile、父卡隔离、
  framebuffer 和 16GB 边界。

定向回归可直接运行：

```bash
deploy/tests/vgpu/test_vgpu_mdev_portability.sh
deploy/tests/vgpu/test_root_start_vm_native_display.sh
deploy/tests/vgpu/test_vgpu_console_interval_static.sh
deploy/tests/vgpu/test_vgpu_profile_catalog.sh
```

上述测试只能证明配置选择和命令生成正确，不能证明 V100 driver 会导出目标
profile、VFIO display REGION 可用或 Windows driver 能正常启动。

## V100 到机后必须验证的项目

每一种实际采购的 V100 变体至少完整执行一次以下清单；不能用某一张 PCIe V100
的结果替代 SXM2、V100S 或 FHHL 的验收。

### 1. 硬件、IOMMU 与驱动

- 用 `lspci -nn` 和 `nvidia-smi -q` 确认准确 SKU、显存、PCI BDF 和序列号；将
  实际 BDF 写入 `VGPU_MGPU`。
- 确认 IOMMU 已启用、设备所在 group 符合部署要求，且宿主桌面或其它进程没有
  占用该 V100。
- 确认加载的是计划使用的官方 R535/vGPU 16 host driver，
  `nvidia-vgpu-mgr` 和 `nvidia-vgpud` 正常运行，服务环境中没有
  `vgpu_unlock` 的 `LD_PRELOAD`。
- 核对 host/guest driver 的兼容组合和 license 服务，不接受“版本看起来接近”
  作为通过标准。

### 2. mdev profile 与资源

- 枚举 `${VGPU_MGPU}/mdev_supported_types` 下每个目录的 `name`、`description`、
  `available_instances` 和 `device_api`。
- 先分别运行两档只读预检：

  ```bash
  deploy/host/probe-vgpu-host.sh --config deploy/host/vgpu-host.conf --fb-mb 1024
  deploy/host/probe-vgpu-host.sh --config deploy/host/vgpu-host.conf --fb-mb 2048
  ```

- 确认表中对应的 1Q 和 2Q 名称各恰好匹配一个 type，并记录实际
  `nvidia-NNN`；若任一名称
  不存在或有歧义，应停止适配并保存完整 sysfs 输出，不能回退到
  `RTX6000-2Q`。
- 创建一个 mdev，确认其 parent 是目标 V100、`/dev/vfio` 权限正确，然后完整
  删除；重复创建/删除并检查没有残留 UUID。
- 分别验证 1GB、2GB 和两者混合实例的 `available_instances`、
  `VGPU_TOTAL_FB_MB` 上限、driver 保留开销和失败后的回收行为。

### 3. QEMU 与显示路径

- 先用未做 PCI 身份覆盖的路径启动，确认 QEMU 接受该 mdev，参数包含
  `display=on,ramfb=on,enable-migration=off`。
- 验证 OVMF/ramfb 早期画面、Windows driver 接管、SDL/GTK 动态画面、分辨率切换
  和窗口重开。
- 确认 V100 profile 实际提供 QEMU 支持的 VFIO display REGION 或 DMA-BUF。
  如果 QEMU 报 `device doesn't support any (known) display method`，则 native
  SDL/GTK 路径未适配成功；仅 compute 可用不能算本项目验收通过。
- 分别以 `VGPU_CONSOLE_INTERVAL_US=0` 和 `16667` 测静态桌面、视频和高动态画面，
  比较刷新率、CPU 占用、Xid 和画面完整性，再决定该硬件配置的默认值。

### 4. Windows guest 与稳定性

- 用 1GB 和 2GB guest 各启动至少一台；安装与 host/profile 兼容的
  NVIDIA vGPU guest driver，确认 Device Manager 无 Code 43，guest
  `nvidia-smi` 能识别对应 profile 且 license 为有效状态。
- 验证重启 guest、重启 vGPU manager、宿主重启、异常中止 QEMU 后 mdev 都能
  正确恢复和回收。
- 至少执行单 VM 长稳和计划并发数的多 VM 压力测试；持续检查 `dmesg`、
  `journalctl`、NVIDIA Xid、显存上限、显示刷新和输入响应。
- 若仍启用 guest PCI 身份覆盖，分别验证安装阶段的真实 ID 路径和运行阶段的
  override 路径；资源 profile 与实际 framebuffer 必须始终保持本文配置值。

满足以上到机验证后，才能把对应 `VGPU_HOST_CONFIG` 标为已验证。仅完成无卡的
代码、fixture、dry-run 或编译测试，应标记为“预适配”，不能宣称 V100 已可用于
生产。

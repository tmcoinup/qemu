# Tesla V100 / vGPU 19.5 适配与验证结论

完整的空白宿主操作步骤见
[`G11-V100-VGPU19.5-FRESH-INSTALL.md`](G11-V100-VGPU19.5-FRESH-INSTALL.md)。
本文只说明技术边界和已经实机证明的结果。

## 固定版本合同

V100 的 G-11 生产入口只接受：

| 层 | 固定版本 |
|---|---|
| Ubuntu | 24.04，GA `6.8.*-generic` |
| vGPU host | 19.5 / `580.159.01` |
| Windows GRID guest | `582.53` / `32.0.15.8253` |
| identity Hook | 固定上游 commit + 仓库内 R535/R580.159 审核补丁 |

旧 vGPU 19.0 已从资产选择、VM 启动映射、VMate 修复和教程中移除。RTX 2080 的
R535 路径仍独立保留；V100 选择 19.5 不意味着把 R535 宿主升级到 R580。

要求 6.8 的原因不是“V100 只能用 6.8”，也不是 unlock 的通用限制，而是当前精确
`580.159.01` host 包、DKMS、IOMMU/mdev、Hook 和 Windows 验收只在 Ubuntu GA 6.8
形成了完整可复现合同。VMate 会先在隔离目录编译门禁，再选择 6.8 启动项；未验证的
HWE 内核不会被猜测性放行。

## 数据路径和 Hook 边界

```text
Tesla V100
  -> NVIDIA 580.159.01 vGPU host / mdev profile
  -> V100*-1Q 或 V100*-2Q mdev
  -> QEMU VFIO + Windows 正式签名 GRID 582.53
  -> R580 RM identity Hook（仅审核字段）
```

V100 的 mdev、调度、显存份额和 guest 驱动都来自 NVIDIA 官方栈。R580 Hook 不伪造
硬件能力，也不打开官方 unlock：其 `/etc/vgpu_unlock/config.toml` 固定
`unlock=false`。它只把 G-11 profile 中经过实测的总线位宽、显存厂商和 RAM 类型等
RM 身份字段投影到单个 mdev。

Windows 仍只安装正式签名驱动。禁止 testsigning、nointegritychecks、自签名内核
驱动及 BCD 修改。

## 1Q、2Q 和 RAM_TYPE

已验证的 V100 SXM2 16GB 使用 `V100X-1Q` 与 `V100X-2Q`：

| 场景 | 结果 | Hook 策略 |
|---|---|---|
| 单 1Q / 1024MB | Code 0、WHCP、正常关机 | 位宽、显存厂商、RAM_TYPE 均可写 |
| 单 2Q / 2048MB | Code 0、WHCP、正常关机 | 位宽/厂商可写，RAM_TYPE 自动跳过 |
| 1Q + 2Q 同卡 | 两台 Code 0，可同时运行/关机 | 每个 mdev 按自身 framebuffer 决策 |

2Q 跳过 RAM_TYPE 不是 guest 侧降级。早期实验中向 2Q 强写消费卡 RAM_TYPE 会触发
Windows 关机死锁；R580 Hook 因此在运行时读取该 mdev 的真实 framebuffer，仅对
精确 1024MB 放行 RAM_TYPE，2048MB 或无法识别时 fail-closed。1Q 正常包含
RAM_TYPE。

## mixed mode

vGPU 19.5 在已测 V100 上报告：

```text
Heterogeneous Time-Slice Sizes : Supported
vGPU Heterogeneous Mode        : Enabled
```

`install-vgpu-mixed-mode.sh` 安装 root-owned helper、systemd service/timer，并在开机
或 GPU reset 后复检/恢复。mdev 分配器只有同时满足以下条件才允许 1Q/2Q 混搭：

- host driver 精确为 `580.159.01`；
- 目标设备为审核的 Tesla V100 PCI ID；
- NVIDIA capability 为 `Supported` 且 mode 为 `Enabled`；
- profile、framebuffer、parent BDF 和总显存容量全部通过实时校验。

业务全部使用 1Q 时，可保持 mixed mode 但只创建 `--gpu-vram 1024`；也可在所有
VM/mdev 停止后生成 `equal + 1024` 策略。RTX 2080/R535 仍只能使用整卡统一档位。

## V100 SKU 与 profile 前缀

| 物理 SKU | preset | 1Q | 2Q | 总显存 MB |
|---|---|---|---|---:|
| PCIe 16GB | `v100-pcie-16gb` | `V100-1Q` | `V100-2Q` | 16384 |
| PCIe 32GB | `v100-pcie-32gb` | `V100D-1Q` | `V100D-2Q` | 32768 |
| SXM2 16GB | `v100-sxm2-16gb` | `V100X-1Q` | `V100X-2Q` | 16384 |
| SXM2 32GB | `v100-sxm2-32gb` | `V100DX-1Q` | `V100DX-2Q` | 32768 |
| V100S 32GB | `v100s-pcie-32gb` | `V100S-1Q` | `V100S-2Q` | 32768 |
| FHHL 16GB | `v100-fhhl-16gb` | `V100L-1Q` | `V100L-2Q` | 16384 |

最终必须以目标机 `mdev_supported_types/*/{name,description,available_instances}` 为准。
脚本按完整 16384/32768MB 做容量门禁，不人为扣固定余量，但满额并发仍须按实际 SKU
逐台验证。

## CPU2 / NUMA 与显示输出

已测 V100 位于 NUMA node 1。第二颗 CPU 安装并在线后，VM 的 vCPU 与服务线程在
node 1 做了不重叠绑核验证。新主机若 V100 所在节点没有在线 CPU，VMate 会拒绝
继续，而不是跨节点假装完成部署。

V100 作为 vGPU 目标不承担 Ubuntu 桌面输出，宿主显示器应接 RX550 等另一张卡。
RX550 无画面属于宿主显示栈/BIOS 主卡的独立复检项，不影响已经完成的 V100 mdev、
Hook 和 guest Code 0 结论。

## 最终验收与未覆盖范围

每个新 SKU/新主机仍要验证：

- 精确 BDF、NUMA、IOMMU group、PCIe 链路、温度和供电；
- 1Q 单机、需要时 2Q 单机与 1Q+2Q 同卡；
- Device Manager Code 0、正式签名、正确显存和 license；
- 顺序/同时关机后的 QEMU、mdev、CPU 隔离回收；
- `nvidia-vgpu-mgr`、Xid、AER、MCE/EDAC 日志；
- 16GB/32GB 的业务所需并发边界。

本次实机结果证明的是该 V100 SXM2 16GB + 580.159.01 + 582.53 + 6.8 组合，不能
自动外推到其他 V100 SKU、其他 R580 小版本或其他内核。

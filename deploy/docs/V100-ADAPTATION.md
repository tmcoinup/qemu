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
`unlock=false`。生产策略继续用 Hook 写每个 mdev 的名称和 FHD 显示合同，但在
R580.159.01/V100 上保留 NVIDIA 原生 RM framebuffer tuple。

Windows 仍只安装正式签名驱动。禁止 testsigning、nointegritychecks、自签名内核
驱动及 BCD 修改。

## 1Q、2Q 和 RM framebuffer tuple

2026-08-30 在目标 V100 SXM2 16GB、同一 VM/磁盘、`V100X-1Q` 与正式 582.53
guest 上完成了 A/B 对照：

| 场景 | 宿主日志结果 | 结论 |
|---|---|---|
| 完整消费卡 RM tuple | guest 查询出现 `RAM_TYPE 15 -> 8`，随后 PTE pin/translate 失败、TDR、XID 43，约 9 秒循环卸载/重载 | 不可用于生产 |
| 完全关闭 per-mdev identity | 582.53 只加载一次，约 2 分钟内上述错误计数为 0 | 官方 1Q/R580 基础链路稳定 |
| 保留名称/FHD、关闭 RM tuple | GTX 名称/FHD 合同写入，582.53 稳定加载，4 分钟内上述错误计数为 0，正式停机后资源全部回收 | 当前生产策略 |

因此不能再把“1Q 可安全改写 RAM_TYPE”当作已验证结论。日志最强地指向实际发生的
`RAM_TYPE` 改写，但本次安全收口按完整 tuple 处理，不猜测位宽等未单独验收字段。
`VGPU_RM_FB_IDENTITY_MODE=off` 只影响 RM 身份展示字段，不改变 1024MB 配额、正式
签名驱动或官方 mdev 能力。`Unlicensed (Unrestricted)` 与两组对照相同，且稳定组
没有 XID，故本次故障不是 DLS 授权拒绝。

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
2Q/混搭的宿主能力门禁仍然有效，但改为 name-only 后应在目标 SKU 上另做正式 guest
回归，不能从旧 RM tuple 结果外推 Code 0。

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
Hook 和宿主侧稳定性结论。本轮没有 guest 凭据，Device Manager Code 0、签名和显存
回执仍是正式封盘验收项。

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

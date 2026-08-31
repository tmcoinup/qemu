# Tesla V100：vGPU 16.4/R535 与 19.5/R580 实机结论

V100 全部按 1Q 使用时，当前推荐
[`G11-V100-R535-VGPU16.4-FRESH-INSTALL.md`](G11-V100-R535-VGPU16.4-FRESH-INSTALL.md)。
需要保留 R580/19.5 name-only 或研究 2Q/mixed 时，使用
[`G11-V100-VGPU19.5-FRESH-INSTALL.md`](G11-V100-VGPU19.5-FRESH-INSTALL.md)。
两条分支共享 VM 生命周期代码，但驱动资产、Hook ABI 和 Guest Driver 独立；VMate
会识别当前分支，不做在线跨分支升级。

## 固定版本合同

| 路线 | host | guest | framebuffer/Hook | 当前用途 |
|---|---|---|---|---|
| R535，推荐 | vGPU 16.4 `535.161.05` | 正式签名 `538.33` / `31.0.15.3833` | 全卡 `V100*-1Q`、equal 1024MB、R535 RM identity | 已验证的全 1Q 生产路线 |
| R580，可选 | vGPU 19.5 `580.159.01` | 正式签名 `582.53` / `32.0.15.8253` | 1Q/2Q capability；生产只投影名称/FHD，RM tuple 保持原生 | mixed 研究或 R580 name-only |

两条路线目前都固定 Ubuntu 24.04 GA `6.8.*-generic`。这不表示 V100 硬件只能使用
6.8，也不是 unlock 的通用限制，而是本项目只在这些精确 host 包、DKMS、IOMMU/mdev、
Hook、QEMU 和 Windows 组合上形成了完整可复现合同。

vGPU 16.4 的官方 R535 源码早于 Ubuntu 24.04 的部分 Linux 6.8 ABI。仓库中的
`patch-nvidia-vgpu-r535-linux68.py` 只适配 VFIO/IOMMUFD、eventfd、IOMMU 与 DRM
编译接口，并同时校验补丁前/后的精确源码摘要；它不是 unlock，也不修改 Windows
签名策略。

## RAM_TYPE、位宽与 XID/TDR 对照

目标机为 V100 SXM2 16GB，BDF `0000:81:00.0`，NUMA node 1。两轮关键结果如下：

| 组合 | RM identity | 实机结果 | 结论 |
|---|---|---|---|
| R580.159.01 + 582.53 + `V100X-1Q` | 完整消费卡 tuple，日志出现 `RAM_TYPE 15 -> 8` | PTE pin/translate 失败、Guest TDR、XID 43，约 9 秒循环卸载/重载 | 不可用于生产 |
| R580.159.01 + 582.53 + `V100X-1Q` | `VGPU_RM_FB_IDENTITY_MODE=off`，仅名称/FHD | 4 分钟内上述错误为 0，正常关机并回收；该轮未读取 Device Manager | R580 当前安全策略 |
| R535.161.05 + 538.33 + `V100X-1Q` | R535 Hook，日志确认 `RAM_TYPE 15 -> 8`、位宽 `4096 -> 128` | Device Manager Code 0、WHCP、GTX 750/1024MiB；SDL 1920×1080 约 9 分钟内 XID/TDR/PTE/display-copy timeout/unload 全为 0，关机后资源完整回收 | 当前全 1Q 推荐路线 |

因此答案不是“1Q 天生没有 RAM_TYPE”，也不是“只要改 RAM_TYPE 就必然 XID”。1Q
同样会查询 RAM_TYPE；实际稳定性取决于精确 host/guest 世代、RM ABI 和整组身份字段
的组合。R535/16.4 已解决的是**上表这套 V100 1Q 合同**，不能据此宣称 R535 的 2Q、
混搭或任意驱动小版本也稳定。

显存厂家字段已写入 profile，但本轮 R535 Manager 没有查询，所以只能记录为“已配置、
未证明”。RAM_TYPE 和位宽有实际查询/改写日志，可以写成已验证。

失败组和稳定组的 DLS 状态相同，稳定组没有 XID，故这次 XID/TDR 不是 DLS 授权
拒绝。`Unlicensed (Unrestricted)` 是否满足业务仍是独立授权问题。

## 1Q、2Q 与 mixed mode

vGPU 19.5 在已测 V100 上报告：

```text
Heterogeneous Time-Slice Sizes : Supported
vGPU Heterogeneous Mode        : Enabled
```

所以 R580 分支在 capability、精确版本、BDF、profile、容量和实时 mode 都通过时，
可以从宿主能力层允许 1Q/2Q mixed。但是 name-only 策略下的 2Q Guest Code 0、长期负载
以及 1Q+2Q 同卡仍须单独验收。

R535/16.4 分支不混搭：VMate 固定 `equal + 1024MB`，只发布与实卡匹配的
`V100*-1Q`。这与用户当前全部 1Q 的业务一致，也避免了最初的 1024/2048MB 宿主
固定档冲突。

## V100 SKU 与 profile 前缀

| 物理 SKU | preset | 1Q | 2Q | 总显存 MB |
|---|---|---|---|---:|
| PCIe 16GB | `v100-pcie-16gb` | `V100-1Q` | `V100-2Q` | 16384 |
| PCIe 32GB | `v100-pcie-32gb` | `V100D-1Q` | `V100D-2Q` | 32768 |
| SXM2 16GB | `v100-sxm2-16gb` | `V100X-1Q` | `V100X-2Q` | 16384 |
| SXM2 32GB | `v100-sxm2-32gb` | `V100DX-1Q` | `V100DX-2Q` | 32768 |
| V100S 32GB | `v100s-pcie-32gb` | `V100S-1Q` | `V100S-2Q` | 32768 |
| FHHL 16GB | `v100-fhhl-16gb` | `V100L-1Q` | `V100L-2Q` | 16384 |

最终必须以目标机 `mdev_supported_types/*/{name,description,available_instances}` 为准，
不得猜测 `nvidia-NNN`。16GB/32GB 容量门禁分别使用完整 16384/32768MB，不人为扣
固定余量；满槽并发仍需逐个 SKU 做真实 Windows 验收。

## CPU2、NUMA 与宿主显示

已测 V100 位于 NUMA node 1。第二颗 CPU 在线后，VM vCPU 与服务线程已在 node 1
做不重叠绑核验证。若 V100 所在节点没有在线 CPU，VMate 会停止修复，不跨节点假装
完成。

V100 不承担 Ubuntu 桌面输出，显示器应接 RX550 等另一张卡。RX550 暂时无画面属于
宿主 BIOS/显示栈的独立问题；可以先做无显示的驱动与 mdev 验证，但交付前仍要单独
正常重启确认宿主控制台。

## 安全边界与最终验收

Windows 始终只安装 NVIDIA/Microsoft 正式签名驱动。禁止 testsigning、
nointegritychecks、BCD 修改、测试签名或自签名内核驱动。宿主 Secure Boot 必须在
BIOS 关闭；自动化不会注册 MOK 或绕过安全策略。

每个新主机/SKU 仍要验证：

- 精确 BDF、NUMA、IOMMU group、PCIe 链路、温度和供电；
- Device Manager Code 0、正式签名、1024MiB 和业务所需身份字段；
- SDL/实际业务负载，以及 XID、TDR、PTE、display-copy timeout；
- 正常关机后的 QEMU、mdev、TPM、CPU 隔离和磁盘一致性；
- `nvidia-vgpu-mgr`、AER、MCE/EDAC 日志；
- 业务需要的并发上限和 DLS 授权状态。

当前强结论只覆盖 V100 SXM2 16GB + R535.161.05 + 538.33 + 1Q + GA 6.8。其它
V100 SKU要按相同清单复验；2Q、mixed、其它 R535/R580 小版本不能自动外推。

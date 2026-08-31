# Tesla V100：R535 默认与 R570/18.4 可选分支

全 1Q 的 V100 新主机默认采用 R535：host `535.161.05`、Windows guest `538.33`。
确实需要 2Q 或 1Q+2Q 混合时，vGPU 18.4/R570 作为可选分支：host
`570.172.07`、Windows guest `573.48`（`32.0.15.7348`）。一键切换入口是
[`G11-V100-R535-R570-SWITCH.md`](G11-V100-R535-R570-SWITCH.md)。

R580/19.5 只保留 name-only 和故障定位记录。
三个分支共享 VM 生命周期代码，但驱动资产、Hook ABI 和验证合同彼此独立，不能根据
版本号相近直接外推。

## 固定版本合同

| 路线 | host / guest | framebuffer 与 Hook | 当前用途 |
| --- | --- | --- | --- |
| R535，默认 | `535.161.05` / 正式签名 `538.33` | equal 1024；仅 `V100*-1Q`；436-byte ABI | 全 1Q 主机、旧 RTX 2080 |
| R570，可选 | `570.172.07` / 正式签名 `573.48` | mixed；`V100*-1Q` + `V100*-2Q`；460-byte ABI；RAM_TYPE 只允许精确 1024/2048 MiB | 需要 2Q 或混合时启用 |
| R580，历史 | `580.159.01` / 正式签名 `582.53` | 1028-byte ABI；V100 保持 native capability；RM identity off/name-only | 问题定位，不作为统一生产版本 |

固定 6.8 不是 V100 硬件或 unlock 的普遍限制，而是本项目只对上述精确 host 包、
DKMS、IOMMU/mdev、Hook、QEMU 和 Windows 组合形成可复现合同。R535 为 Linux 6.8
所需的源码适配只处理内核编译接口，不修改 Windows 签名策略。

## RAM_TYPE、2Q 和 mixed 实测

目标机为 V100 SXM2 16GB，BDF `0000:81:00.0`，位于第二颗 CPU 的 NUMA node。
第二颗 CPU 安装并上线后，R570/18.4 得到以下结果：

| 场景 | RAM_TYPE 日志 | Guest | 宿主与回收 |
| --- | --- | --- | --- |
| 单独 `V100X-1Q` | `15 -> 8` | GTX 750 / 1024 MiB，Code 0，WHCP，TDR=0 | 无 XID/PTE/copy timeout，正常关机回收 |
| 单独 `V100X-2Q` | `15 -> 8` | GTX 750 Ti / 2048 MiB，Code 0，WHCP，TDR=0 | 无 XID/PTE/copy timeout，正常关机回收 |
| `V100X-1Q` + `V100X-2Q` | 两台均 `15 -> 8` | 两台驱动均为 573.48，约 5 分钟内 TDR=0 | 同卡并行无 XID/PTE/copy timeout，两台正常关机并回收 |

所以 1Q 和 2Q 都会查询 RAM_TYPE；并不存在“RAM_TYPE 只影响 2Q”或“1Q 没有
RAM_TYPE”。是否稳定取决于精确 host/guest 世代、RM ABI、framebuffer 档位和整组
身份字段。R570 Hook 对未知显存档位 fail-closed，不能用这次结果开放 4Q 或其它档。

## 为什么 R580 曾出现 XID 43/TDR

R580.159.01 + 582.53 的 V100 1Q 在改写完整消费卡 framebuffer tuple 时，虽然能看到
RAM_TYPE `15 -> 8`，随后却重复出现 PTE pin/translate 失败、Guest TDR、XID 43 和
驱动循环卸载。关闭 RM framebuffer identity、只保留名称/FHD 后，短时宿主错误消失并
能正常关机。

这组失败与稳定组的 DLS 状态相同，因此当时的 XID/TDR 不是 DLS 授权拒绝造成的。
它是 R580 RM 身份组合的运行时故障；授权状态仍须作为独立业务项验收。R570 的 2Q
通过也不能反向证明 R580 2Q 安全，因此 R580 Hook 仍保持精确 1Q 门禁。

## V100 SKU 与 profile 前缀

| 物理 SKU | preset | 1Q | 2Q | 总显存 MiB |
| --- | --- | --- | --- | ---: |
| PCIe 16GB | `v100-pcie-16gb` | `V100-1Q` | `V100-2Q` | 16384 |
| PCIe 32GB | `v100-pcie-32gb` | `V100D-1Q` | `V100D-2Q` | 32768 |
| SXM2 16GB | `v100-sxm2-16gb` | `V100X-1Q` | `V100X-2Q` | 16384 |
| SXM2 32GB | `v100-sxm2-32gb` | `V100DX-1Q` | `V100DX-2Q` | 32768 |
| V100S 32GB | `v100s-pcie-32gb` | `V100S-1Q` | `V100S-2Q` | 32768 |
| FHHL 16GB | `v100-fhhl-16gb` | `V100L-1Q` | `V100L-2Q` | 16384 |

最终必须以目标机 `mdev_supported_types/*/{name,description,available_instances}` 和
官方 mixed capability/mode 为准，不得猜测 `nvidia-NNN`。16GB/32GB 容量门禁按
16384/32768 MiB 计算；不同 SKU 和满槽并发仍需重复做真实 Windows 验收。

## CPU2、显示输出与安全边界

V100 所在插槽连接哪颗 CPU，对应 CPU 必须存在且 NUMA node 有在线核心。V100 不承担
Ubuntu 桌面输出，显示器应接 RX550 等另一张卡；宿主显示异常与 vGPU Guest 是否能
装载是两条独立链路，交付前仍要冷启动确认控制台。

Windows 只安装 NVIDIA/Microsoft 正式签名驱动。禁止 `testsigning`、
`nointegritychecks`、BCD 修改、测试签名或自签名内核驱动。宿主 Secure Boot 必须在
BIOS 关闭；自动化不会注册 MOK 或绕过安全策略。

每台新宿主至少验收 Device Manager Code 0、正式签名、1Q、2Q、1Q+2Q、实际业务
画面、TDR/XID/PTE/copy timeout，以及正常关机后的 QEMU/mdev/TPM/CPU/磁盘回收。

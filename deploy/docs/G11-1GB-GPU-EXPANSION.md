# G-11 1GB 显卡扩容傻瓜教程

G-11 曾把显卡身份池从 12 个 2GB 原子配置扩为 24 个；当前再加入 1 条显式 EVGA
后，总目录为 25 条。当前生命周期是 12 条 2GB 默认、4 条 GTX 750 1GB Maxwell
新建、1 条显式和 8 条 GT 730/GT 740 Kepler legacy。12 个 1GB 厂商型号仍全部
保留在目录中，但不会全部进入新 VM 的无参数随机。

先纠正名称：NVIDIA 有 **GeForce GTX 750 1GB**，设备 ID 是 `10DE:1381`；没有
这代正式零售型号“RTX 750”。它也不是已有的 GTX 750 Ti 2GB（`10DE:1380`）。

## 已核验的 12 个 1GB 厂商型号

| 芯片型号 | 品牌 | 厂商正式型号 / P/N | G-11 profile | 厂商资料 |
|---|---|---|---|---|
| GT 740 | MSI | `N740-1GD5` | `gt740_1gb` | [MSI 规格页](https://www.msi.com/Graphics-Card/N740-1GD5/Specification) |
| GT 740 | ASUS | `GT740-OC-1GD5`（P/N `60YV06J2-VG0A04`） | `gt740_asus_1gb` | [ASUS BIOS 支持页](https://www.asus.com/supportonly/gt740-oc-1gd5/helpdesk_bios/) |
| GT 740 | Gigabyte | `GV-N740D5OC-1GI` | `gt740_gigabyte_1gb` | [Gigabyte 规格页](https://www.gigabyte.com/Graphics-Card/GV-N740D5OC-1GI/sp) |
| GT 740 | ZOTAC | `ZT-71002-10L` | `gt740_zotac_1gb` | [ZOTAC 官方 PDF](https://www.zotac.com/old_zotac/fileadmin/Redakteure/Products/Pdf/ZT-71002-10L_GT-740_1GB-DDR5_v1.2.pdf) |
| GT 730 | ASUS | `GT730-1GD5-BRK` | `gt730_1gb` | [ASUS 支持页](https://www.asus.com/us/supportonly/gt730-1gd5-brk/helpdesk_download/) |
| GT 730 | MSI | `N730K-1GD5LP/OC` | `gt730_msi_1gb` | [MSI 规格页](https://www.msi.com/Graphics-Card/N730K-1GD5LPOC/Specification) |
| GT 730 | Gigabyte | `GV-N730D5OC-1GI` | `gt730_gigabyte_1gb` | [Gigabyte 规格页](https://www.gigabyte.com/Graphics-Card/GV-N730D5OC-1GI/sp) |
| GT 730 | ZOTAC | `ZT-71102-10L` | `gt730_zotac_1gb` | [ZOTAC 产品页](https://www.zotac.com/eu/product/graphics_card/geforce%C2%AE-gt-730-1gb-ddr5-0) |
| GTX 750 | ASUS | `GTX750-PHOC-1GD5` | `gtx750_asus_1gb` | [ASUS 支持页](https://www.asus.com/us/supportonly/gtx750-phoc-1gd5/helpdesk_manual/) |
| GTX 750 | MSI | `N750 GAMING 1GD5/OC` | `gtx750_msi_1gb` | [MSI 官方规格 PDF](https://storage-asset.msi.com/datasheet/original/vga/global/N750-GAMING-1GD5OC.pdf) |
| GTX 750 | Gigabyte | `GV-N750OC-1GI` | `gtx750_gigabyte_1gb` | [Gigabyte 规格页](https://www.gigabyte.com/Graphics-Card/GV-N750OC-1GI/sp) |
| GTX 750 | ZOTAC | `ZT-70701-10M` | `gtx750_zotac_1gb` | [ZOTAC 历史产品页](https://www.zotac.com/old_zotac/index.php?L=7&id=170045&tx_zoprodisp_pi1%5Bproduid%5D=6019) |

机器可读的采购/验收清单在
[`G11-1GB-GPU-EVIDENCE.tsv`](G11-1GB-GPU-EVIDENCE.tsv)。它记录厂商公开的 P/N、
UPC/EAN（厂商有公布时）、device ID、容量和位宽；另外两列明确命名为
`g11_subsystem_projection` / `g11_vbios_projection`，仅表示 G-11 目录投影，不是
厂商对实物批次的证明。

这些老卡多数已经停产。商城商品标题、库存号和二手卖家的图片会变化，不能代替
厂商 P/N。公开页面通常不披露 subsystem，也不能覆盖同一正式型号的全部 PCB、显存
和固件批次。ASUS 公布的完整 VBIOS 后缀还可能含 `AS14`/`AS09` 这类厂商字符，而
当前目录的五字节兼容投影会归一为 `.14`/`.09`。采购实卡时必须读取原始值、另行
审核后再绑定，不能把投影值或外壳名称当成到货验收结果。

## “型号、货号、序列号”不要混用

- 正式型号 / P/N（例如 `ZT-70701-10M`）对同款产品公开，已写入上表。
- UPC/EAN 是零售目录号，不是单卡序列号；只登记厂商明确公布的值。
- PCI subsystem 和 VBIOS 描述一个板卡/固件批次，不是实体卡唯一 S/N。
- 每张实卡的 S/N 只在卡背标签、包装、发票或厂商保修系统中出现。公开商城无法
  查询未采购实卡的 S/N，G-11 固定使用 `serialPolicy=not-exposed`，绝不编造 S/N。

收货时给每张卡拍清晰标签照，并保存以下只读结果到仓库外的资产系统：

```bash
lspci -nn -s <PCI-BDF>
sudo nvidia-smi -q -i <GPU索引>
```

Windows 实卡可另存 GPU-Z 的 Lookup/BIOS 信息。照片、发票、机器凭据、授权 token
都不得提交到仓库。

## 直接使用

先从仓库根目录列出全部 25 个配置：

```bash
./deploy/package-vgpu-portable.sh --list-gpu-profiles
```

新建 VM 时指定其中一行，例如 ASUS GTX 750 1GB：

```bash
./deploy/scripts/create-vm.sh 101 --gpu-profile gtx750_asus_1gb
./deploy/scripts/start-vm.sh 101 --dry-run
./deploy/scripts/start-vm.sh 101
```

不指定 `--gpu-profile` 时按 `VGPU_HOST_FB_TIER_MB` 从对应单档新建层随机一次并
写进该 VM 的 `vm.conf`：1024MB 档只使用 4 条 GTX 750 Maxwell 行，2048MB 档
只使用 12 条 2GB 默认行；显式行和 8 条 Kepler legacy 行不参加无参数随机。
以后启动不会重新随机。所有 1GB 行只走 B/native、原版签名驱动路径，不开启
`testsigning`/`nointegritychecks`，不改 BCD，也不安装测试签名或自签名内核驱动。

## 一键封装

构建不绑定 VM ID/UUID 的通用 Windows 包：

```bash
./deploy/package-vgpu-one-click.sh
```

如果默认 staging 已有旧目录摘要的认证包，封装器会拒绝静默覆盖。保留旧包作为回退，
给新目录显式指定版本化输出即可；本机本轮交付使用：

```bash
./deploy/package-vgpu-one-click.sh --portable \
  --output-dir /home/ubuntu/images/staging/VgpuPortable-25/.host-bundle \
  --output-exe /home/ubuntu/images/staging/VgpuPortable-25/VgpuPortable.exe
```

生成的 `VgpuPortable.exe` 内含全部 25 个原子 profile；展开的 host audit bundle
还包含本教程和 TSV 来源表。需要正式 NVIDIA 授权时，token 必须从仓库外的
mode-0600 文件显式传入，不能写进仓库：

```bash
chmod 600 /安全路径/client_configuration_token.tok
./deploy/package-vgpu-one-click.sh \
  --token-file /安全路径/client_configuration_token.tok
```

## 更换 Tesla V100 后选择一个 framebuffer 档

先确认该 NVIDIA GPU 上没有运行中的 VM/mdev，再用统一封装生成宿主本地策略。
例如 16GB PCIe V100 的 1GB 档：

```bash
bash deploy/configure-g11-vgpu-host.sh \
  --preset v100-pcie-16gb \
  --tier 1024 \
  --gpu 0000:04:00.0
```

把示例 BDF 换成实卡的完整地址；32GB 卡把 preset 换成
`v100-pcie-32gb`。脚本按 16384/32768MB 完整显存计算，不扣固定预留，并为真 V100
固定 `VGPU_MDEV_IDENTITY_MODE=off`、`SPOOF_MODE=off`。然后只读核验该档：

```bash
./deploy/host/probe-vgpu-host.sh \
  --config deploy/host/vgpu-host.conf \
  --profile V100-1Q
```

启动时 1GB 行拿 `V100-1Q/1024MB`；2GB VM 会被明确拒绝。要整池切到 2GB，先
关闭该 NVIDIA GPU 上所有 VM/mdev，再用配置封装统一生成 `V100-2Q/2048MB`。
官方 V100 模板默认 `SPOOF_MODE=off` 且
`VGPU_MDEV_IDENTITY_MODE=off`，所以 Windows 系统 PCI/PnP 身份保持 V100 vGPU 原生
值；消费卡目录只负责容量合同和可选的便携用户态元数据，不能宣称改变了物理卡或
系统 PCI 身份。启动器会拒绝容量不一致、同名 profile 多卡歧义和超额分配。

完整的 V100 驱动、license、变体名称和到机验收见
[`V100-ADAPTATION.md`](V100-ADAPTATION.md)。在真 V100 上完成所选档位的
驱动 Code 0、图形输出、授权、压力与满槽并发验证前，状态仍是
`hardware-unverified`，不能宣称生产验收完成。

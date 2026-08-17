# G-11 Windows 高速安装介质傻瓜教程

## 先照抄这两条命令

从仓库根目录执行：

```bash
./deploy/host/verify-usb-install-boot-helper.sh
./deploy/scripts/start-vm.sh 9 --install /home/ubuntu/images/iso/win10.iso
```

看到 `Press any key to boot from CD or DVD...` 时只按一次空格。Windows 文件复制后
第一次重启不要再按键，它会自然回落到系统盘。安装完并完整关机后，正式启动只用：

```bash
./deploy/scripts/start-vm.sh 9
```

正式启动不会挂载 Windows ISO、OOBE 应答 ISO 或 UEFI helper，Windows 中也不会
残留这些光驱/USB 安装设备。

## 默认路径与兼容回退

| 模式 | 临时附加设备 | 启动顺序 | 正式启动是否存在 |
|---|---|---|---|
| 默认 `--install` | 只读 UEFI helper、xHCI USB Windows 光盘、可选应答光盘 | helper=1，系统盘=2，USB 光盘=3；helper 转入已连接的 USB 光盘 | 否 |
| `--install --manual-oobe` | helper、USB Windows 光盘；无应答光盘 | 同上 | 否 |
| `--install-media ide` | IDE Windows 光盘、可选应答光盘；无 helper | IDE 光盘=1，系统盘=2 | 否 |
| 普通/救援启动 | 无安装介质 | 系统盘 | 不存在 |

只有默认路径在 fresh NVRAM 中需要 helper。OVMF 能高速读取 USB BOT 光盘，却不会为
这类 Windows El Torito 布局自动建立可用启动项；helper 只负责查找同时含有
`\\EFI\\BOOT\\BOOTX64.EFI` 和 `\\sources\\boot.wim` 的另一介质并启动它。
Windows ISO 的 `bootindex=3` 只促使 OVMF 提前连接文件系统；数据仍直接从 USB
光盘读取，首次入口仍是 helper，重启时系统盘仍先于 ISO。

如果特定固件/ISO 确实不能走默认路径，可临时回退：

```bash
./deploy/scripts/start-vm.sh 9 --install /home/ubuntu/images/iso/win10.iso \
  --install-media ide
```

IDE 是诊断回退，不会写入 `vm.conf`。它会恢复 ICH9-AHCI ATAPI PIO，读取 Windows
安装镜像可能明显变慢。

## 这次慢启动的根因与结果

旧路径不是 i5-4570、Tianocore 图片或“90 秒定时器”卡住，而是 WinPE 经 IDE ATAPI
PIO 读取 `boot.wim`：约 753,934,336 字节被拆成 367,914 次、约 2 KiB/次的后端请求，
累计块设备时间约 124.84 秒。

VM10 的默认 USB A/B 读取约 760 MB 时只产生约 12,000 次、约 64 KiB/次的请求，
后端累计约 0.7–1.1 秒；冷启动按键后约 15 秒进入“安装程序正在启动”，随后正常出现
产品密钥页面。实际总时间还会受宿主 CPU、ISO 和 WinPE 初始化影响，不把该数字当成
硬性承诺。

## helper 校验与重建

运行时资产是 `deploy/firmware/g11-usb-install-boot.img`。它由仓库内独立实现的
`ChainLauncher.c` 构建，不复制 V-11 那个缺少源码的历史二进制。日常只需校验：

```bash
./deploy/host/verify-usb-install-boot-helper.sh
```

开发者修改源码后才需要重建：

```bash
./deploy/host/build-usb-install-boot-helper.sh
./deploy/host/verify-usb-install-boot-helper.sh
bash deploy/tests/vgpu/test_usb_install_boot_helper.sh
```

构建依赖、固定哈希和历史边界见
[`../firmware/chainloader/README.md`](../firmware/chainloader/README.md) 与
[`../firmware/chainloader/PROVENANCE.md`](../firmware/chainloader/PROVENANCE.md)。

## 常见情况

- 落到 `Shell>`：通常是错过了光盘按键窗口。停止 VM，重新执行同一条 `--install`
  命令，在提示出现时按一次空格；不需要手敲 UEFI 路径。
- helper 缺失或哈希不符：启动器会在生成应答盘、创建空系统盘、启动 TPM/完整 VM 之前
  fail-closed，并打印重建或 IDE 回退命令。
- Windows 已装完：完整关机后改用不带 `--install` 的正式启动命令，三种安装期设备
  会全部消失。
- `--manual-oobe`：只关闭应答 ISO，不会关闭 Windows ISO 或 helper。
- 将来启用 Secure Boot：当前 helper 没有第三方签名，不得通过关闭完整性检查或改
  BCD 绕过；保持现有 G-11 固件合同，或显式用 IDE 回退并另行审核正式签名方案。

本方案不开启 `testsigning`/`nointegritychecks`，不修改 BCD，不安装任何测试签名或
自签名内核驱动，也不保存宿主机密码。

# G-11 宿主双显卡开机花屏修复

适用现象：宿主机开机到登录桌面之前反复花屏或闪屏，进入桌面后正常，guest 画面也
正常。这个页面只处理 **Linux 宿主显示链路**，不修改 guest。

## 当前机器为什么会花屏

当前 G-11 宿主的实际拓扑是：

| 用途 | PCI 地址 | 驱动/显示节点 | 固件标记 |
|---|---|---|---|
| NVIDIA RTX 2080，提供 vGPU | `0000:04:00.0` | `nvidia`，没有 DRM card | `boot_vga=1` |
| AMD RX 580，宿主桌面 | `0000:05:00.0` | `amdgpu`，唯一 `/dev/dri/card0` | `boot_vga=0` |

Ubuntu 的 GDM 规则只看到 NVIDIA 专有驱动版本较新，于是在
`/run/gdm3/custom.conf` 写入 `PreferredDisplayServer=xorg`。Xorg 又按固件的
`boot_vga=1` 先选 RTX 2080，但这张卡在 G-11 中只提供 vGPU，没有宿主 DRM 显示
节点。因此本次启动连续失败 6 次，日志为：

```text
[drm] Failed to open DRM device for pci:0000:04:00.0: -19
Cannot run in framebuffer mode. Please specify busIDs for all framebuffer devices
```

GDM 最后回退到 RX 580 上的 Wayland，所以进入桌面后完全正常。guest 正常也符合这个
结论：guest 的 NVIDIA vGPU 数据面没有坏，异常仅发生在宿主登录器选卡阶段。

## 一键修复

先进入仓库，只读审核不需要 sudo：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/g11-host-display.sh audit
```

当前机器应看到 `display=0000:05:00.0`、`vgpu=0000:04:00.0`、
`firmware_primary=vgpu`、`preferred=xorg` 和 `xorg_boot_failures=6`。PCI 地址由脚本
实时识别；换机器时不要照抄上面的地址。

VMate 修复中心使用同一 helper 的只读结构化入口：

```bash
./deploy/host/g11-host-display.sh status --json
```

该命令只输出 `schema=1` JSON；VMate 依据其中的受管配置、GDM 运行态、本次 Xorg
失败数和 `recommendation` 显示“建议修复 / 等待重启 / 正常 / 不适用”，不会解析中文
日志，也不会把这个可选宿主显示项作为 VM 创建门禁。

应用修复：

```bash
sudo ./deploy/host/g11-host-display.sh apply
```

脚本只会安装
`/etc/systemd/system/gdm.service.d/90-g11-host-display.conf`，让 GDM 启动前明确开启并
首选已经在本机跑通的 AMD Wayland 路径。它会先验证“恰好一张 AMD DRM 显示卡 +
一张没有 DRM card 的 NVIDIA vGPU 卡”，不符合就拒绝写入；已有同名非受管配置、
目录或符号链接也不会覆盖。

`apply` 不会重启 GDM，因此当前桌面不会突然退出。保存工作后只需重启一次宿主：

```bash
sudo reboot
```

重启进入桌面后验收：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/g11-host-display.sh check
```

通过时最后一行包含：

```text
g11-host-display: ready=yes ... preferred=wayland ... xorg_boot_failures=0
```

再启动一台原有 guest 验证即可；不需要重装或修改 guest 驱动。

## 如果厂商 Logo 到 Linux 接管前也花屏

软件封装修掉的是日志已经证明的 GDM/Xorg 六次重试。当前固件仍把 vGPU 专用的
NVIDIA 卡标为启动主卡，因此在厂商 Logo、UEFI 或 Linux 图形栈接管前仍可能出现一次
固件级切屏。

这种情况进入 BIOS/UEFI，把 `Primary Display`、`Initial Display Output`、
`Initiate Graphic Adapter` 或同义选项改成 **AMD RX 580 所在 PCIe 插槽**，显示器线也
接 RX 580。不同 X99 主板菜单名称不同；不确定插槽时先拍 BIOS 页面确认，不要猜。
修改后运行 `audit`，理想结果是 `firmware_primary=display`。

不要为了消除早期画面去改内核启动参数、屏蔽 amdgpu，或让宿主桌面占用 NVIDIA。
G-11 的 NVIDIA 卡应继续只承担 vGPU。

## 一键回滚

```bash
cd /home/ubuntu/projects/qemu
sudo ./deploy/host/g11-host-display.sh rollback
sudo reboot
```

回滚只删除本脚本带有管理标记的 drop-in；遇到同名外部配置会拒绝删除。删除的配置
可随时再次运行 `apply` 重新生成。

## 安全边界

- 不修改 BCD、GRUB 或内核命令行；
- 不开启任何签名绕过，不安装/替换内核驱动；
- 不加载、卸载或重启 NVIDIA/amdgpu 模块；
- 不停止 VM、不创建/删除 mdev，不修改任何 guest 磁盘；
- 不重启当前 GDM 会话；重启宿主始终由管理员显式执行；
- 不读取或保存宿主凭据。

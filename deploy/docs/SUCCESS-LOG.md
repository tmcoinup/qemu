# vGPU 16.4 guest 身份验证记录

> **历史记录，不是当前操作指南。** 本页 VM3 strict-A 结果依赖修改 INF、VM 本地
> 自签 catalog 和私有根，现已判定不符合生产签名要求。相关入口已禁用、产物已归档；
> 不得复现这些证书/Driver Store 步骤。VM3 的 legacy A 已使用生产迁移流程切回
> 未修改 GRID 538.33 + B/native；受支持的最终状态是 B。

## 2026-08-17：VM9 通用系统身份 FINAL PASS

VM9 只作为验收样机；实现和包均从 VM 的 canonical GPU/monitor profile 读取，
没有 VM9、鲁大师、ASUS 或 AOC 特例。

| 项 | 实机验收结果 |
|---|---|
| Present Display | 恰好 1 个 `NVIDIA GeForce GTX 750 Ti`，Code 0 |
| 原生 transport | `PCI\VEN_10DE&DEV_1E30&SUBSYS_132610DE` |
| Guest driver | GRID 538.33 / `31.0.15.3833` / NVIDIA+WHCP 正式签名 |
| 系统 NVAPI merge | transport device 保持 `10DE:1E30`，Subsystem 为 ASUS `1043:84BB` |
| 板卡/显存 | ASUS / Samsung / GDDR5 / 2 GB / 128 bit / 86.4 GB/s |
| 显示器 | `AOC 2470W`，present/OK，1920×1080@60 |
| 32/64 位 | `SystemNvapiProbe32.exe` 与 `SystemNvapiProbe64.exe` 均 PASS，GPU count=1 |
| 3D | `dxdiag` 只有一个 Display Devices；DDI 12、WDDM 2.7、Feature Levels 12_1～9_1 |
| 稳定性 | 本次原生 538.33 启动后无新增 host Xid/TDR，SDL 保持可见 |

鲁大师先在总览点“重新扫描”后，显卡页显示 ASUS、SAMSUNG、GDDR5、128 bit、
86.4 GB/s 和正确时钟，并且不再出现“本机共有 2 块显卡”。这只是清理该软件旧
缓存的验收步骤；系统实现对进程名无判断，普通 32/64 位 NVAPI 调用者使用同一
系统合同。

VM9 安装的已验证合同：

```text
contract = D4B7F7A9123D25C7B29ECFD490DA0918E7C206BE0722B710CA8C41C342440A28
installed v9 ISO SHA256 = D0010A0B87A8E4179A543897C4D7F4ABF25FB3C371CF88BB41635F4AA90E2083
validated receipt = C:\ProgramData\G11\SystemNvapiProjection\receipts\<contract>-validated.json
```

文档与门禁收口后又从当前源码重新生成最终交付 ISO，合同 ID 不变（payload 与
VM 事实相同），输出为
`SystemNvapiProjection-final/vm9-...-D4B7F7A9123D25C7.iso`，SHA-256 为
`78F10D0F4156412C8B7B147C172C24D76B10E06A1443B753AF26490EBFD4CC02`。

对照中 desktop 537.58 / `31.0.15.3758` 曾产生 host `Xid 43` 和 guest TDR/驱动
卸载，解释了此前偶发黑屏。两条 537.58 审计行已改为
`quarantined-runtime-instability`：隔离克隆仍可复现实验，但生产 stage/commit、
正常启动、monitor sync 和系统身份打包全部拒绝。

通用包回归另生成三台独立 fixture，覆盖 GTX 750 Ti/GT 1030/GTX 1050、
ASUS/MSI/Gigabyte、Samsung/Micron/SK hynix 及 AOC/Dell/Samsung 显示器；三组
合同、EDID、x86/x64 payload 和 ISO 均通过。因此本次结果不是单独为 VM9 或某个
检测程序适配。

## 2026-07-20：VM3 生产签名 B/native FINAL PASS

| 项 | 当前 VM3 已验证值 |
|---|---|
| Device Manager | `NVIDIA GeForce GTX 1050`，只有一张 present Display，Code 0 |
| Guest 原生 PnP | vGPU `DEV_1E30`；不再使用 strict-A `DEV_1C81` 驱动绑定 |
| Guest driver | 原始 GRID 538.33 / `31.0.15.3833` / 动态 `oem2.inf` |
| 数字签名者 | `Microsoft Windows Hardware Compatibility Publisher` |
| BCD | `testsigning=false`、`nointegritychecks=false` |
| 分辨率 | 1920×1080 |
| GPU-Z | 2.70，显示 GTX 1050 / 2 GB / GDDR5 / WHQL |
| legacy 清理 | 旧自签 package、私有测试证书和一次性续跑任务已移除 |

`oem2.inf` 仅是 VM3 当时的 Windows 动态编号，不能作为其他 VM 的固定条件。
GPU-Z 的 WHQL 文本不是签名链证明；签名结论来自实际 DriverStore catalog、加载中
内核文件和 WHCP/Authenticode 验证。详细操作见
[G11-QUICKSTART.md](G11-QUICKSTART.md)。

## 2026-07-15：VM3 严格 GTX 1050 历史实验（已禁用）

本节是 VM3 当时的 strict-A 实验记录，不是当前配置，也不是将底层物理 GPU 或
mdev 资源改成了
GTX 1050。Guest 可见身份、驱动绑定、显示模式和 host FRL 状态分别验收：

| 项 | VM3 已验证值 |
|---|---|
| Guest 产品名 | `NVIDIA GeForce GTX 1050` / GP107 |
| QEMU 外层 PCI identity | `10DE:1C81`, subsystem `1028:11C0` |
| NVIDIA 内部 per-mdev identity | `vdev_id=0x1C8111C0`, `pdev_id=0x1C81` |
| Guest driver | GRID 538.33 / `31.0.15.3833`, `nvlddmkm` Running, Device Manager Code 0 |
| Guest 显存 | 2048 MiB |
| 本地 console 分辨率 | 1920×1080 @ 59/60 Hz |
| Host license 状态 | `Unlicensed`；GeForce 身份下 NVIDIA 控制面板不显示 vGPU 激活页 |
| Host frame-rate limiter | per-mdev `frl_enabled=0`；`nvidia-smi vgpu -q` 显示 `Frame Rate Limit: N/A` |
| 动态画面抽查 | WinSAT 动态 workload 下 SDL Present 观察值明确高于 3 FPS |
| Host backing resource | 仍是 `nvidia-257/2048MB` mdev；未改变物理 GPU、调度份额或计算能力 |

GPU-Z 已同时报告 `DEV_1C81 / SUBSYS_11C01028`、GP107、2048 MB 和 538.33；
Windows 不再回退到 Microsoft Basic Display Adapter，并恢复了 1920×1080 模式。
`Unlicensed` 没有被伪造成 `Licensed`；本次解决的是客户机严格消费卡身份与
3 FPS 限制，不是 NVIDIA 正式授权状态。

上述动态抽查只足以排除“被固定在 3 FPS”，不是完整 GPU 跑分，也不代表
所有 workload 都能持续 60 FPS。REGION console、SDL Present 频率和
guest 实际渲染帧率仍是三个不同的量。

## 2026-04-23 历史 GT 1030 成功状态

以下 GT 1030 / `DEV_1D01` 内容是 2026-04-23 的历史记录，用于保留当时的
patcher 经验；它不是 2026-07-15 VM3 的当前配置或 GTX 1050 验收标准。
当时主机为 Ubuntu 24.04 + Xeon E5-2696 v4 + RTX 2080 魔改 16GB + AMD RX 570。

| 项 | 值 |
|----|----|
| Host driver | nvidia-vgpu-ubuntu-535 `535.161.05` (closed, **patched by vGPU-Unlock-patcher**) |
| vGPU stack | vGPU 16.4 (535.161.05 host / 538.33 Win guest) |
| Guest driver | 538.33 DCH |
| License | NVIDIA RTX Virtual Workstation (fastapi-dls)，Expiry 2026-7-22 |
| Guest Device Manager | **NVIDIA GeForce GT 1030** (唯一显卡，无基本显示适配器) |
| testsigning / nointegritychecks | **No** (正常模式) |
| VM uptime 当时 | 5h+ 0 Xid 43 / 0 TDR |

## 从 0 到成功的关键转折

### ❌ 弯路 1: vgpu_unlock-rs (mbilker upstream 2.5.0) + vGPU 17.6
- host 升 17.6 (550.163.02) + guest 553.74 + mbilker vgpu_unlock-rs
- 症状：VM 启动 ~10 分钟后 Xid 43 + csrss TDR 风暴，Windows VIDEO_SCHEDULER_INTERNAL_ERROR 蓝屏
- 根因：mbilker 2.5.0 的 LD_PRELOAD hook 对 550.163 的新 RM 控制命令覆盖不完整
- **不是** license grace period，也不是 host/guest 版本错位（验证过对齐也 TDR）

### ❌ 弯路 2: 降 17.4 (550.127.06 + 553.24) 还是 TDR
- mbilker 在 17.4 早期确实能用，但本机 17.4 装好也 8-11 分钟 Xid 43
- 说明 hook 对某些 R550 API 路径存在盲区
- GreenDamTan/vgpu_unlock-rs@GreenDam 分支有 "17.x vGPU info multiple times" fix，未验证是否能救

### ✅ 正解: vGPU-Unlock-patcher + 16.4

patcher 不是 hook 而是 **直接改 driver 源码**：kernel module compat + 加 vup hooks + blob binary patch + vcfgclone XML 重签，全部编进 DKMS。稳定性在另一个级别（1h+ 0 xid）。

## vGPU-Unlock-patcher 在本机的完整落地步骤

### 宿主侧（`.deb` → patched DKMS）

官方 patcher 只支持 `.run` 输入，我们的 17.4/16.4 NVIDIA 包都是 `.deb`。走 `.deb` + 源码路径：

```bash
# 1. 装 16.4 host driver 只解包（dkms 自动 build 会失败，先 --unpack 跳过 postinst）
sudo dpkg --purge nvidia-vgpu-ubuntu-535  # 先清干净
sudo dpkg --unpack ~/Downloads/vGPU16.4/Host_Drivers/nvidia-vgpu-ubuntu-535_535.161.05_amd64.deb

# 2. Apply kernel-compat patches (path 用 -p2 剥 kernel/ 前缀)
cd /usr/src/nvidia-535.161.05
for p in kernel-driver-fix-detach_ioas.patch \
         kernel-driver-fix-drm_gem_object_vmap.patch \
         kernel-driver-fix-eventfd_signal-and-iommu_ops.patch; do
    sudo patch -p2 -i /tmp/vGPU-Unlock-patcher/patches/$p
done

# 3. 加 unlock 相关新文件 (patcher 原本 cp 到 .run 解压树，.deb 要手做)
sudo cp /tmp/vGPU-Unlock-patcher/unlock/kern.ld /usr/src/nvidia-535.161.05/nvidia/
sudo mkdir -p /usr/src/nvidia-535.161.05/unlock
sudo cp /tmp/vGPU-Unlock-patcher/unlock/vgpu_unlock_hooks.c /usr/src/nvidia-535.161.05/unlock/
sudo cp /tmp/vGPU-Unlock-patcher/patches/nv_hooks.c      /usr/src/nvidia-535.161.05/unlock/

# 4. Inject include / Kbuild append
sudo sed -e 's:^\(#include "nv-time\.h"\):\1\n#include "../unlock/vgpu_unlock_hooks.c":' \
    -i /usr/src/nvidia-535.161.05/nvidia/os-interface.c
echo 'NVIDIA_SOURCES += unlock/nv_hooks.c'                        | sudo tee -a /usr/src/nvidia-535.161.05/nvidia/nvidia-sources.Kbuild
echo 'OBJECT_FILES_NON_STANDARD_nv_hooks.o := y'                  | sudo tee -a /usr/src/nvidia-535.161.05/nvidia/nvidia.Kbuild
echo 'ldflags-y += -T $(src)/nvidia/kern.ld'                      | sudo tee -a /usr/src/nvidia-535.161.05/nvidia/nvidia.Kbuild

# 5. kernel 6.x symbol 限制：把 nvidia_vgpu_vfio_get_ops/set_ops 转成 GPL 导出
sudo sed -i \
    -e 's/^EXPORT_SYMBOL(nvidia_vgpu_vfio_get_ops)/EXPORT_SYMBOL_GPL(nvidia_vgpu_vfio_get_ops)/' \
    -e 's/^EXPORT_SYMBOL(nvidia_vgpu_vfio_set_ops)/EXPORT_SYMBOL_GPL(nvidia_vgpu_vfio_set_ops)/' \
    /usr/src/nvidia-535.161.05/nvidia/nv-vgpu-vfio-interface.c

# 6. Apply 剩余源码 patches
for p in disable-nvidia-blob-version-check.patch \
         vgpu_unlock_hooks-510.patch \
         setup-vup-hooks.patch \
         vgpu-kvm-optional-vgpu-v2.patch \
         vgpu-kvm-nvidia-535.54-compat.patch \
         workaround-for-cards-with-inforom-error.patch; do
    sudo patch -p2 -d /usr/src/nvidia-535.161.05 -i /tmp/vGPU-Unlock-patcher/patches/$p
done

# 7. Blob binary patch NVIDIA 闭源 nv-kernel.o_binary
bash /tmp/blobpatch.sh /usr/src/nvidia-535.161.05/nvidia/nv-kernel.o_binary \
    /tmp/vGPU-Unlock-patcher/patches/blob-535.161.05.diff   # status=0 ideal

# 8. DKMS 编译
sudo dkms add /usr/src/nvidia-535.161.05
sudo IGNORE_CC_MISMATCH=1 dkms install -m nvidia -v 535.161.05 -k $(uname -r)

# 9. 改 vgpuConfig.xml: vcfgclone Quadro RTX 6000 block → RTX 2080 (0x1E82)
XML=/usr/share/nvidia/vgpu/vgpuConfig.xml
sudo cp $XML $XML.bak
sudo bash -c "sed -e '/<pgpu/ b found' -e b -e ':found' -e '/<\\/pgpu>/ b clone' -e N -e 'b found' \
  -e ':clone' -e p \
  -e 's/\\(.* deviceId=\"\\)0x1E30\\(\" subsystemVendorId=\"\\)0x10de\\(\" subsystemId=\"\\)0x12BA\\(\".*\\)/\\10x1E82\\20x10de\\30x0000\\4/' \
  -e t -e d -i $XML"

# 10. Apply vcfg-* patches
for p in vcfg-v15vcs.patch vcfg-testing.patch; do
    sudo patch -d /usr/share/nvidia/vgpu -p1 -i /tmp/vGPU-Unlock-patcher/patches/$p
done

# 11. reload
sudo systemctl stop nvidia-vgpu-mgr nvidia-vgpud
for m in nvidia_vgpu_vfio nvidia_drm nvidia_modeset nvidia_uvm nvidia; do sudo rmmod $m 2>/dev/null; done
sudo modprobe nvidia && sudo modprobe nvidia_vgpu_vfio
sudo systemctl start nvidia-vgpu-mgr
sudo systemctl enable --now nvidia-vgpud  # 这个必开，否则 mdev_supported_types 不出现

# 12. 验证
cat /proc/driver/nvidia/version   # 535.161.05 closed
ls /sys/bus/pci/devices/0000:04:00.0/mdev_supported_types/   # nvidia-257 RTX6000-2Q
```

### QEMU 启动参数

```
-device vfio-pci,sysfsdev=<mdev>,display=off,enable-migration=off,bus=pcie.0,addr=0x10,
    x-pci-vendor-id=0x10DE,x-pci-device-id=0x1D01,
    x-pci-sub-vendor-id=0x1043,x-pci-sub-device-id=0x85F9
-vga none
```

关键点：
- **`enable-migration=off`** — NVIDIA 550+ 不支持 QEMU 11 默认开的 vfio migration v2 uapi，不关会 HAL_INITIALIZATION_FAILED
- **`-vga none`** — 不挂 std-vga，guest Device Manager 不出现"Microsoft 基本显示适配器"；代价是 OVMF 启动到 Windows 登录的过程 VNC 看不到（已 RDP / WinRM 时不需要）

### Guest 侧历史实验（已禁用，禁止复现）

历史实验曾修改 `nvgridsw.inf`、生成本地证书、导入 Root/TrustedPublisher、重建
catalog 并用 `pnputil` 安装。即使 BCD 测试选项关闭，这仍是私有根自签内核驱动，
不等于 NVIDIA/Microsoft 生产签名。当前两个 guest stager 会在任何上述动作前
无条件拒绝；不要从旧日志恢复命令。

## 踩过的坑 (对未来的你)

| # | 坑 | 触发点 | 解决 |
|---|----|--------|------|
| 1 | QEMU 11 vfio migration v2 | 任意 vfio-pci vGPU 启动 | `enable-migration=off` |
| 2 | DKMS 默认装 open module (Turing vGPU host 不支持) | apt install 16.4 host driver | `dkms remove -open` + `install closed` |
| 3 | kernel 6.x symbol_get 仅 GPL | nvidia-vgpu-vfio 加载 | `EXPORT_SYMBOL → EXPORT_SYMBOL_GPL` for `nvidia_vgpu_vfio_get_ops/set_ops` |
| 4 | 535.161 源码对 kernel 6.8 不兼容 (iommu_ops / eventfd_signal / drm_gem_object_vmap) | DKMS build | patcher 的 3 个 kernel-driver-fix patches |
| 5 | patcher 只支持 `.run`，我们只有 `.deb` | 全程 | 手工把 .deb 解包的 source tree 映射到 patcher 的 TARGET/kernel/ 相对路径 (用 `-p2`) |
| 6 | vgpuConfig.xml 里 RTX 2080 (0x1E82) 不在支持列表 | vgpu-mgr 启动 | vcfgclone Quadro RTX 6000 block |
| 7 | patcher 不自动启 nvidia-vgpud | 第一次重启后 mdev_supported_types 不出现 | `systemctl enable --now nvidia-vgpud` |
| 8 | guest INF 修改后 vendor catalog 失效 | 正式签名验证拒绝 | 不重签、不导入私有根；迁移到原始 GRID 538.33 + B/native |
| 9 | WinRM session 装 NVIDIA driver 时 timeout (WDDM 重启断 WinRM) | 远程 Invoke-Command pnputil /add-driver /install | 改用 Scheduled Task SYSTEM 跑 + 外层轮询 |
| 10 | pnputil /add-driver 在 WinRM session 下取不到 `\\tsclient\nv` | 远程 Copy-Item 失败 | 宿主起 `python3 -m http.server 8080`，guest `Invoke-WebRequest` 下载 |

## 稳定性 vs mbilker/vgpu_unlock-rs

| | mbilker (runtime LD_PRELOAD hook) | vGPU-Unlock-patcher (static source patch) |
|--|--|--|
| 装驱动后 ~10 分钟 | **csrss TDR 风暴** / BSoD | 0 Xid, 0 TDR |
| 一小时 VM uptime 统计 | 多次 Xid 43 | 0 |
| 对新 R550 API 兼容 | 有 hook 覆盖盲区 | kernel 层重写路径全覆盖 |
| 维护难度 | 每个 NVIDIA driver 版本都要跟进 hook | 每个 driver minor 可能要新的 patch 集合 |

结论：vGPU-Unlock-patcher 路线 **稳定度质变**。

## 光驱生命周期与高速安装边界（2026-08-04 收口）

> 2026-08-18 更新：现行合同继续保持“普通启动零光驱”。
> `--install` 才在启动期创建临时光驱；日常 ISO 由 `vmctl cdrom mount`
> 热插 USB-BOT/SCSI 光驱，`eject` 删除整台设备。当前操作以
> [`G11-OPTICAL-DRIVE.md`](G11-OPTICAL-DRIVE.md) 为准。

Q35 machine 自带板载 ICH9-AHCI (`VEN_8086&DEV_2922`)，QEMU 默认会在其空闲 AHCI 端口（当前拓扑为 `ide.2`）自动挂一个空 ATAPI CDROM。Windows Device Manager 里显示 `QEMU QEMU DVD-ROM`，是最明显的虚拟化指纹之一。

源码仍支持显式 `-device ide-cd,model=...` 的 ATAPI INQUIRY 投影。在 2026-08-04
收口时，G-11 生产启动器暂未使用这一能力。没有逐型号审核和真实序列证据时，
把 TSST/HL-DT-ST 字符串覆盖到临时安装介质反而会制造不可信身份。

现行启动脚本：普通启动不挂空光驱，并通过
`-global ide-cd.bootindex=-1` 抑制 QEMU 自动创建默认 CD-ROM；只有
`--install` 会向 guest 暴露安装介质。默认 Windows ISO 不再走每 2 KiB 一次请求的
ICH9-AHCI ATAPI PIO，而是由安装期 FAT helper 自动 chainload 到 xHCI USB BOT 光盘。

```bash
# start-vm.sh - 普通模式：抑制 QEMU 默认空光驱，不创建 ide-cd 设备
-global ide-cd.bootindex=-1

# start-vm.sh --install 默认路径：helper=1、系统盘=2、USB ISO=3
-drive file=$HELPER,if=none,id=installboot,format=raw,readonly=on
-drive file=$ISO,if=none,id=odd0,media=cdrom,readonly=on,format=raw
-device usb-storage,id=installboot-usb,drive=installboot,bus=xhci.0,port=4,bootindex=1,removable=on
-device usb-storage,id=odd0-usb,drive=odd0,bus=xhci.0,port=3,bootindex=3,removable=on

# 自动 OOBE 应答介质同样使用通用临时身份
-drive if=none,id=answer0,media=cdrom,readonly=on,format=raw,file=$UNATTEND_ISO
-device ide-cd,drive=answer0,bus=ide.2
```

默认 USB 安装期光驱明确属于 `generic transient ODD`：只承载介质，不进入硬件品牌池，
不生成或查重虚构序列。启动器在载入 `vm.conf` 前后清除旧
`ODD_MODEL`/`ODD_SERIAL`，调用环境和历史配置都不能重新注入型号或序列。

helper 同样是无品牌的安装期实现设备，由 G-11 独立源码确定性构建并在启动前核验
SHA-256。它、Windows ISO 和应答 ISO 在不带 `--install` 的正式启动中全部不存在。
显式 `--install-media ide` 只作慢速兼容回退且不挂 helper。VM10 A/B 中，约 760 MB
读取由旧 ATAPI 的 367,914 次/124.84 秒降至 USB 的约 12,000 次/约 0.7–1.1 秒。
完整操作见 [`G11-INSTALL-MEDIA.md`](G11-INSTALL-MEDIA.md)。

## 可用资产

- `/tmp/vGPU-Unlock-patcher/` — clone 过的官方 patcher 仓库
- `/tmp/nv-transfer/` — guest 共享目录（Display.Driver.zip + ps1 脚本等）
- `/usr/src/nvidia-535.161.05/` — patched driver 源码（重装 / 内核升级时要重走一遍）
- `/usr/share/nvidia/vgpu/vgpuConfig.xml.bak` — 原始 xml 备份，vcfgclone 改动可回滚
- `deploy/scripts/start-vm.sh`（`--rdp` 模式）：`-vga none` + vfio-pci spoof=ON 的完整参数

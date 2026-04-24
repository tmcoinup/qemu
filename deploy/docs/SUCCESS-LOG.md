# vGPU 16.4 + patcher → guest 显示 GT 1030 全流程心得

记录日期 2026-04-23。本机 Ubuntu 24.04 + Xeon E5-2696 v4 + RTX 2080 魔改 16GB + AMD RX 570。

## 成功状态

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

### Guest 侧 (INF patch + 自签 cat)

1. 宿主 sed 在 `nvgridsw.inf` 加 DEV_1D01 entry（14393 和 17098 两个 section 各一条，复用 Section019/020 driver install block）
2. 宿主 HTTP server 把 patched Display.Driver 目录 zip 起来
3. Guest WinRM 触发一个 Scheduled Task (SYSTEM 权限) 跑 PowerShell:
   - `New-SelfSignedCertificate -Subject 'CN=vGPU-Patch-Signer' -Type CodeSigning ...`
   - Import 自签证书到 `LocalMachine\Root` + `LocalMachine\TrustedPublisher`
   - `New-FileCatalog` 根据 patched INF 重新生成 `nvgridsw.cat`
   - `Set-AuthenticodeSignature` 签 cat
   - `pnputil /add-driver nvgridsw.inf /install`
4. `bcdedit /set testsigning off` + `/set nointegritychecks off` 可以保持关闭（签名走自签链）

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
| 8 | guest INF 修改后 nvgridsw.cat hash 失配 | pnputil /add-driver 拒绝 | New-FileCatalog 重签 + 自签证书装 Root+TrustedPublisher |
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

## 光驱伪装 (2026-04-23 补)

Q35 machine 自带板载 ICH9-AHCI (`VEN_8086&DEV_2922`)，其 `ide.0` bus 默认被 QEMU 自动挂一个空 ATAPI CDROM。Windows Device Manager 里显示 `QEMU QEMU DVD-ROM`，是最明显的虚拟化指纹之一。

`-device ide-cd,model=...` 属性已有，但 **ATA/ATAPI INQUIRY 响应走硬编码** (`hw/ide/atapi.c:801-802`)，不读 `s->drive_model_str`。

源码补丁：把 cmd_inquiry 里的 `padstr8(buf+8, 8, "QEMU")` / `padstr8(buf+16, 16, "QEMU DVD-ROM")` 改成读 `s->drive_model_str` 并按首个空格拆分成 vendor(8 byte) + product(16 byte)。

启动脚本：

```bash
# start-vm.sh - 任何模式都挂一个 ide-cd 到板载 ide.0 bus
-drive if=none,id=odd0,media=cdrom,readonly=on       # 生产 (空壳)
-drive if=none,id=odd0,media=cdrom,readonly=on,file=$ISO   # install
-device ide-cd,drive=odd0,bus=ide.0,model=TSSTcorp CDDVDW SH-224DB,serial=R8PG6VCD${VM_ID}23456
```

结果：
- `SCSI\CDROM&VEN_TSSTCORP&PROD_CDDVDW_SH-224DB` （InstanceId）
- Win32_CDROMDrive Caption = `TSSTcorp CDDVDW SH-224DB`

注意事项：
- 第一次启动后 guest 里 `QEMU QEMU DVD-ROM` phantom 记录会残留，需 `pnputil /remove-device <InstanceId> /force`
- model 字符串首个空格前最多 8 字符（SCSI INQUIRY vendor field 大小）。常见模式 "TSSTcorp"(8) "Samsung"(7) "PIONEER"(7) "LG"(2) 都合适
- 空格后部分被截到 16 字符（product field）

## 可用资产

- `/tmp/vGPU-Unlock-patcher/` — clone 过的官方 patcher 仓库
- `/tmp/nv-transfer/` — guest 共享目录（Display.Driver.zip + ps1 脚本等）
- `/usr/src/nvidia-535.161.05/` — patched driver 源码（重装 / 内核升级时要重走一遍）
- `/usr/share/nvidia/vgpu/vgpuConfig.xml.bak` — 原始 xml 备份，vcfgclone 改动可回滚
- `deploy/start-vm.sh` (--rdp 模式): `-vga none` + vfio-pci spoof=ON 的完整参数

# G-11 Windows 安装 `USBXHCI.SYS` 蓝屏恢复教程

> 本页只适用于 **G-11/vGPU 分支**。V-11 是独立分支，不要互相拷贝
> 启动脚本、配置或测试结论。

## 什么情况用这页

Windows 10 安装或第一次冷启动时出现：

```text
Stop code: PAGE_FAULT_IN_NONPAGED_AREA
What failed: USBXHCI.SYS
```

G-11 旧启动链会把 QEMU 的通用 `qemu-xhci` 控制器伪装成 Intel
`8086:A12F`。Windows 会把 PCI 身份当作驱动行为契约，据此启用真实
Intel PCH 的复位、链路电源和状态转换 workaround；`qemu-xhci` 并不具备
那套硬件行为。修复后控制器固定为与虚拟模型匹配的完整上游身份：

```text
1B36:000D rev01 / SUBSYS 1AF4:1100
```

`vm.conf` 中的 Intel xHCI 字段仍作为目标主板 profile 事实保留，但不再
投影到 Windows PnP。这不是关闭 USB 电源管理，而是让 Windows 选择与虚拟
控制器匹配的通用路径。

## VM8 一次恢复：直接照抄

### 1. 先确认 VM 已停

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/vmctl.sh status 8
```

看到 `VM_STATUS=stopped` 再继续。若仍在蓝屏循环，先用封装入口优雅停机：

```bash
./deploy/scripts/vmctl.sh stop 8
```

不要删除 `disk.qcow2`、`nvram.fd` 或 TPM 状态。

### 2. 增量重编一次

```bash
./deploy/host/build-qemu.sh
```

启动器会拒绝未重编的旧 G-11 QEMU，并明确提示这条命令。无需
`--clean`，正常增量编译即可。

### 3. 运行安全门禁

```bash
bash deploy/tests/vgpu/test_xhci_identity_safety.sh
```

通过时最后一行是：

```text
OK: qemu-xhci behavior identity is fixed to 1B36:000D / SUBSYS 1AF4:1100
```

该门禁同时检查源码、启动参数、已编译设备属性和实际 PCI 配置空间。

### 4. 用原 VM8 继续安装

```bash
./deploy/scripts/start-vm.sh 8 --install /home/ubuntu/images/iso/win10.iso
```

`vm.conf` 和 `disk.qcow2` 已存在时，这条命令会原样复用，不会重建或覆盖
已安装到一半的磁盘。启动摘要应包含：

```text
xHCI: qemu-xhci 1B36:000D rev01 / SUBSYS 1AF4:1100
```

Windows Setup 通常会从原有阶段继续。如果想做完全独立的对照安装，
使用一个新 VM ID，不要直接删除 VM8：

```bash
./deploy/scripts/start-vm.sh 9 --install /home/ubuntu/images/iso/win10.iso
```

## 不需要做的事

- 不需要启用 `testsigning` 或 `nointegritychecks`；
- 不需要、也不得修改 BCD；
- 不需要安装测试签名/自签名内核驱动；
- 不要手改只读 `vm.conf` 里的 `XHCI_PCI_*` 字段；
- 不要换成 NEC xHCI 或额外 USB 控制器。当前默认安装明确使用行为身份固定的
  upstream `qemu-xhci` + USB BOT Windows 光盘；物理 PCH tuple 只作事实校验，
  不再投影到控制器。应答 ISO 仍是很小的临时 IDE 光盘。
- 排除旧 QEMU/xHCI 二进制后，确需绕开 USB 路径可临时加
  `--install-media ide`；它较慢、不挂 helper、不会写入 `vm.conf`。详见
  [`G11-INSTALL-MEDIA.md`](G11-INSTALL-MEDIA.md)。

启动时出现的 `clflushopt` / `xsavec` / `xgetbv1` CPUID 警告是宿主 CPU
特性与 profile 的差异，与本次 `USBXHCI.SYS` 的 `PAGE_FAULT` 没有直接因果关系。

## 如果仍然蓝屏

先不要删盘。保留蓝屏照片，并在宿主执行下面的只读采集：

```bash
./deploy/scripts/vmctl.sh status 8
tail -n 200 /home/ubuntu/images/vms/8/log/qemu.log
./build/qemu-system-x86_64 -device qemu-xhci,help 2>&1 |
  rg 'x-pci-(vendor-id|device-id|revision)' || true
```

正确重编后，最后一条不应输出任何内容。这些命令不读取或写入宿主
凭据。

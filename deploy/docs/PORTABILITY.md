# PORTABILITY — host 迁移兼容说明

本页记录把 VM bundle 迁移到其它 host 时必须保持的约束。原则是：路径和二进制位置可以变，guest 可见的真机画像不能静默降级。

## 主要改动

### 1. VM 数据根目录可配置

默认仍使用历史路径：

```bash
IMAGE_ROOT=/home/ubuntu/images
VMS_DIR=$IMAGE_ROOT/vms
VM_DIR=$VMS_DIR/<INSTANCE>
```

迁移到新 host 或新磁盘时只需要改 `IMAGE_ROOT`：

```bash
IMAGE_ROOT=/mnt/vm-images ./deploy/scripts/start-vm.sh 1 --proxy
```

也可以只覆盖某台 VM：

```bash
VM_DIR=/mnt/fastssd/vm1 ./deploy/scripts/start-vm.sh 1 --proxy
```

`DISK` 仍可单独覆盖；未指定时默认是 `$VM_DIR/disk.qcow2`。

### 2. QEMU / qemu-img 可配置

迁移 host 后不要用系统自带 stock QEMU。启动器默认使用仓库内构建产物：

```bash
QEMU=build/qemu-system-x86_64
QEMU_IMG=build/qemu-img
```

如果二进制放在其它位置：

```bash
QEMU=/opt/qemu-stealth/bin/qemu-system-x86_64 \
QEMU_IMG=/opt/qemu-stealth/bin/qemu-img \
IMAGE_ROOT=/mnt/vm-images \
./deploy/scripts/start-vm.sh 1 --proxy
```

### 3. 启动前 QEMU 能力预检

`start-vm.sh` 会 source `lib/sv-portability.sh`，默认执行 `QEMU_CAP_CHECK=1`。它会检查 patched QEMU 是否支持以下 guest-visible stealth 属性：

- NVMe：`use-samsung-id` / `model-number` / `firmware-rev`
- virtio-vga：EDID 字符串和 PCI subsystem override
- USB HID：`vendorid` / `productid` / `manufacturer` / `product`
- PCIe root-port / xHCI：平台 PCI ID 和链路属性 override
- fb-shm / memfd object

缺失时 fail-fast，避免误用 stock QEMU 让 guest 看到 Red Hat NVMe、默认显示器或默认 USB 设备。只有非隐身调试才建议跳过：

```bash
QEMU_CAP_CHECK=0 ./deploy/scripts/start-vm.sh 1 --no-bridge
```

### 4. NVMe I/O 路径保持稳定

不要给 emulated NVMe 加 `iothread=...`。当前 NVMe DMA helper 需要 BlockBackend 留在主 AioContext；强行迁移到 IOThread 会触发 `dma_blk_cb` 断言。

当前稳定参数是：

```bash
-drive file=...,if=none,id=nvm0,format=qcow2,cache=none,aio=threads,discard=unmap
-device nvme,...,drive=nvm0,use-samsung-id=on,model-number=...,firmware-rev=...
```

这不影响 guest 看到的 Samsung NVMe 真机画像。

## 迁移 checklist

1. 在新 host 构建或复制 patched QEMU：

```bash
deploy/tools/build.sh --verify
```

2. 准备 VM 数据目录：

```bash
mkdir -p /mnt/vm-images/vms
rsync -a /home/ubuntu/images/vms/ /mnt/vm-images/vms/
```

3. 检查桥接和 OVMF 依赖：

```bash
sudo UPLINK=<iface> deploy/scripts/setup-bridge.sh
ls /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd
```

4. dry-run 验证路径和 QEMU 能力：

```bash
IMAGE_ROOT=/mnt/vm-images \
DRY_RUN=1 TPM=0 HOST_TUNE=0 \
./deploy/scripts/start-vm.sh 1 --no-sdl --no-fb-shm --no-bridge
```

5. 正式启动：

```bash
IMAGE_ROOT=/mnt/vm-images ./deploy/scripts/start-vm.sh 1 --proxy
```

## 测试

本次新增的轻量回归测试：

```bash
deploy/scripts/tests/test_start_vm_perf.sh
```

覆盖内容：

- dry-run 不生成 `nvme,iothread=...`
- Samsung NVMe identity/model/firmware/serial 仍在
- QEMU 能接受 Samsung NVMe 属性
- `IMAGE_ROOT` dry-run 不落盘且路径正确

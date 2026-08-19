# G-11：把 host 目录挂成 Windows U 盘

这个功能使用 QEMU 自带的 VVFAT，把一个 host 目录临时呈现为 FAT16 块设备，再通过
标准 `usb-storage` 热插到正在运行的 Windows。Windows 使用自带 USB 大容量存储驱动，
不需要安装 virtio、测试签名或自签名驱动，也不修改 BCD。

## Guest Lite 一键用法

在仓库根目录输入实际 VM 编号并执行；后续示例继续使用同一终端里的 `VM_ID`：

```bash
read -r -p '请输入 VM 编号: ' VM_ID
./deploy/scripts/guest-lite.sh "$VM_ID" usb-mount
```

脚本没有固定验收机依赖；VM 被删除或重新编号时，只需重新输入编号。

命令会完成三件事：

1. 在公共 U 盘根目录下更新 Guest Lite 自己的固定子目录；
2. 将公共根目录映射为只读 U 盘；
3. 热插到运行中的 VM，不重启 QEMU，也不调整网卡。

所有 G-11 VM 共用的 host U 盘根目录是：

```text
/home/ubuntu/images/vms/shared/usb/
```

每个工具只管理自己的子目录。Guest Lite 固定在：

```text
/home/ubuntu/images/vms/shared/usb/G11GuestLite/
```

不使用内容哈希，不创建版本历史。兼容光驱文件也放在 Guest Lite 自己的目录：

```text
/home/ubuntu/images/vms/shared/usb/G11GuestLite/G11GuestLite.iso
```

进入 Windows 后，打开“此电脑”中新出现的 `U盘` 可移动磁盘，再打开
`G11GuestLite` 子目录并双击 `G11GuestLite.exe`。确认窗口第一行显示当前版本后再
继续。

公共封装把“U盘”直接写成 FAT16 的真实卷标，并按简体中文 Windows 使用的 CP936
编码保存；不会再生成 `autorun.inf` 来覆盖资源管理器名称。因此资源管理器、卷属性
和 `vol` 命令看到的是同一个名称，不会出现 `U鐩` 乱码或底层仍叫 `USB` 的情况。

查看状态：

```bash
./deploy/scripts/guest-lite.sh "$VM_ID" usb-status
```

用完完整热拔：

```bash
./deploy/scripts/guest-lite.sh "$VM_ID" usb-eject
```

下一次再次执行 `usb-mount` 时，封装会先弹出该 VM 的旧 VVFAT 视图、只更新
`G11GuestLite` 子目录，再重新挂载整个公共根目录，因此 Windows 不会继续读取上
一次的目录清单，其他工具的子目录也不会被覆盖。

只刷新公共 U 盘而不重新生成 Guest Lite：

```bash
./deploy/scripts/shared-usb.sh "$VM_ID" mount
./deploy/scripts/shared-usb.sh "$VM_ID" status
./deploy/scripts/shared-usb.sh "$VM_ID" eject
```

## 任意 host 目录

通用封装允许明确指定其他目录：

```bash
./deploy/scripts/usb-directory.sh "$VM_ID" mount /绝对路径/要传入的目录
./deploy/scripts/usb-directory.sh "$VM_ID" status
./deploy/scripts/usb-directory.sh "$VM_ID" eject
```

自定义 Windows 卷标：

```bash
./deploy/scripts/usb-directory.sh "$VM_ID" mount /绝对路径/目录 --label MY_USB
```

通用入口的自定义卷标只能使用 1 至 11 个 ASCII 字母、数字、空格、`_` 或 `-`；
公共工具封装固定使用经过专门编码验证的中文卷标 `U盘`。

目录内容在 VVFAT 后端打开时建立索引。host 文件有变化后，用同一路径强制刷新：

```bash
./deploy/scripts/usb-directory.sh "$VM_ID" mount /绝对路径/目录 --replace
```

如果当前挂的是另一个目录，没有 `--replace` 时命令会拒绝静默替换。

VM 存放在非默认位置时，先指定该 VM 的目录，三个动作都使用同一个选择器，例如：

```bash
VM_DIR="/数据盘/vms/$VM_ID"
./deploy/scripts/usb-directory.sh "$VM_ID" mount /绝对路径/目录 --vm-dir "$VM_DIR"
./deploy/scripts/usb-directory.sh "$VM_ID" status --vm-dir "$VM_DIR"
./deploy/scripts/usb-directory.sh "$VM_ID" eject --vm-dir "$VM_DIR"
```

## 行为边界

- 默认且唯一支持只读；Windows 无法删除、感染或覆盖 host 文件；
- 它不是实时共享目录。挂载期间不要修改 host 源目录；修改后执行 `--replace`；
- VVFAT 默认是约 504 MiB 的 FAT16 虚拟盘，适合安装器、脚本和小型工具包；更大的
  目录应使用只读 ISO 或另行制作磁盘镜像；
- 源目录不能是 `/`，不能包含符号链接、socket、设备节点或 FIFO；
- 完整停止并重新启动 QEMU 后 U 盘默认不存在，需要时重新执行 `mount`；
- 不导出宿主凭据、私钥、token 或包含这些内容的目录；
- 公共根目录下每个工具使用自己的固定子目录，不把文件散放在 U 盘根目录；
- U 盘与光驱使用不同的 QEMU 设备 ID，可以分别查询和弹出，但传同一份 Guest Lite
  时通常只保留一种介质，避免 Windows 中出现两个副本。

成功状态应包含：

```text
USB_DIRECTORY_STATE=present
USB_DIRECTORY_ATTACHED=yes
USB_DIRECTORY_TRANSPORT=usb-storage/scsi-hd/vvfat
USB_DIRECTORY_MODE=read-only
USB_DIRECTORY_PATH=/home/ubuntu/images/vms/shared/usb
USB_DIRECTORY_LABEL=U盘
USB_DIRECTORY_LABEL_CHARSET=CP936
USB_DIRECTORY_USB_MANUFACTURER=SanDisk
USB_DIRECTORY_USB_PRODUCT=Ultra USB 3.0
USB_DIRECTORY_DISK_VENDOR=SanDisk
USB_DIRECTORY_DISK_PRODUCT=Ultra USB 3.0
USB_DIRECTORY_SERIAL_POLICY=none
```

`eject` 后必须显示 `USB_DIRECTORY_STATE=absent`。它会同时删除热插的 USB 设备和
VVFAT 块后端，不在下次启动中留下空 U 盘。

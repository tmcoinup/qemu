# G-11 默认零光驱与手动挂 ISO 傻瓜教程

## 结论先说

G-11 现在的光驱生命周期是：

- `./deploy/scripts/start-vm.sh 8`：不创建光驱，也不挂 ISO。
- `./deploy/scripts/start-vm.sh 8 --install [ISO]`：只在安装模式创建临时光驱。
- `vmctl.sh cdrom ... mount`：对已运行 VM 热插一台只读光驱并放入 ISO。
- `vmctl.sh cdrom ... eject`：热拔整台手动光驱，不留一台空光驱。

启动器保留 `-global ide-cd.bootindex=-1` 来抑制 Q35 可能自动创建的
`QEMU DVD-ROM`。所以普通、救援、SDL、GTK 等非安装模式都是零光驱。

## 已经用旧启动器启动的 VM

旧版会把一台空的 `g11-odd` 放在 `ide.0`。QEMU 的 `ide.0` 不支持
在线热拔整台 ATAPI 光驱，因此已经运行的旧 VM 必须完整停机后再启动。
以 VM 8 为例：

```bash
./deploy/scripts/vmctl.sh stop 8
./deploy/scripts/vmctl.sh start 8
```

不要强杀正在写盘的 Windows。如果停止脚本提示 guest 没有正常关机，先在
Windows 里点“关机”，然后重试。

## 查询默认状态

VM 正常启动后执行：

```bash
./deploy/scripts/vmctl.sh cdrom 8 status
```

未挂载时应看到：

```text
OPTICAL_STATE=absent
MEDIA_STATE=absent
```

`absent` 表示整台光驱都不存在，不是“有一台空光驱”。

## 手动挂载 ISO

使用统一封装，ISO 必须是真实存在的绝对路径：

```bash
./deploy/scripts/vmctl.sh cdrom 8 mount /absolute/path/package.iso
```

也可直接调用底层手动脚本：

```bash
./deploy/scripts/optical-media.sh 8 mount /absolute/path/package.iso
```

脚本会通过 QMP 创建 `usb-bot + scsi-cd`，不重启 Windows/QEMU。为避免 Windows
在 SCSI LUN 尚未就绪时枚举到半成品设备，脚本先以 `attached=false` 完成设备栈，
再用 QOM 原子发布为 `attached=true`。ISO 只读打开，设备层使用已审核的无伪造
序列身份：

```text
OPTICAL_MODEL=HL-DT-ST DVDRAM GH24NS50
OPTICAL_FIRMWARE=XP02
OPTICAL_SERIAL_POLICY=none
OPTICAL_USB_SERIAL_POLICY=none
OPTICAL_TRANSPORT=usb-bot/scsi-cd
OPTICAL_STATE=present
OPTICAL_ATTACHED=yes
MEDIA_STATE=inserted
MEDIA_READ_ONLY=yes
```

GH24NS50 的实机型号与 XP02 固件证据见
[LG GH24NS50 支持页](https://www.lg.com/bd/support/product/lg-GH24NS50.AUAU10B) 和
[LG GH24NS50 规格表](https://www.lg.com/us/products/documents/GH24NS50%20spec%20sheet.pdf)。
手动热插时的 guest 传输是 USB BOT/SCSI；文档不把它误说成已热插的板载 SATA。

## 换盘和弹出

重复挂同一张 ISO 是幂等操作。已有另一张 ISO 时，默认拒绝突然打断读取；
确认换盘才加 `--replace`：

```bash
./deploy/scripts/vmctl.sh cdrom 8 mount /absolute/path/new.iso --replace
```

用完后执行：

```bash
./deploy/scripts/vmctl.sh cdrom 8 eject
```

`eject` 会依次删除 `scsi-cd`、`usb-bot` 和只读块后端。再次 `status` 应回到
`OPTICAL_STATE=absent`。

## `--install` 的用法

从 ISO 安装 Windows 时才在启动参数中挂光驱：

```bash
./deploy/scripts/start-vm.sh 8 --install /home/ubuntu/images/iso/win10.iso
```

安装完成并完整关机后，换回普通启动：

```bash
./deploy/scripts/start-vm.sh 8
```

这次不会继续挂 Windows ISO、UEFI helper、应答 ISO 或空光驱。

## Windows 侧验收

挂载后在管理员 PowerShell 执行：

```powershell
Get-CimInstance Win32_CDROMDrive |
  Select-Object Name, Drive, MediaLoaded, PNPDeviceID
```

弹出后重新执行，该手动光驱应消失。Windows 盘符刷新可能延迟 2～5 秒，
可在“此电脑”按 `F5`。

若旧版脚本曾输出 `OPTICAL_STATE=present`、Windows 却没有光驱，直接重新执行同一条
`mount` 命令即可在线修复遗留的 `attached=false` 状态，不需要重启虚拟机。

若 QEMU 进程是在无序列号描述符修复前启动的，脚本会输出
`OPTICAL_USB_SERIAL_POLICY=topology-generated-compat`：这是让当前 Windows 会话能够
正常枚举光驱的临时兼容模式。完整关闭并重新启动 VM 后，再次挂载会自动变为
`OPTICAL_USB_SERIAL_POLICY=none`，对应 USB 规范的 `iSerialNumber=0`，不会制造空字符串
或伪造硬件序列号。

## 常见报错

- `QMP socket 不存在`：VM 没运行，先普通启动 VM。
- `检测到旧版开机常驻光驱`：完整停机，再用新启动器普通启动一次。
- `Bus 'xhci.0' not found`：运行中的 VM 由过旧的启动参数创建；完整停机再启动。
- `光驱已有另一张 ISO`：先 `eject`，或确认后给 mount 加 `--replace`。
- `ISO 必须是非符号链接`：传入 ISO 真实文件的绝对路径，不要传 symlink。

本功能不修改 BCD，不开启 `testsigning`/`nointegritychecks`，不导入测试证书，
不安装测试签名或自签名内核驱动，也不读取或保存宿主机凭据。

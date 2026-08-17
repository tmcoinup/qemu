# G-11 与 V-11 运行操作对齐说明（2026-08-12）

本页以最新 `origin/V-11` 的 `e768c73d9d528db9d033b40fdc8269dfcc6b86f0`
为对照基线。结论是：两边启动后的 Windows 日常操作已经基本一致，但不是同一种
虚拟显卡实现，也不能追求逐参数、逐驱动文件完全相同。

G-11 是 NVIDIA mdev/vGPU；V-11 是 virtio 显示方案。可以共用生命周期、输入、
QMP、磁盘和宿主稳定性能力，不能互拷显示驱动、PCI 身份、guest 签名链或 GPU
验收规则。

## 结论矩阵

| 操作/能力 | 当前结论 | 说明 |
|---|---|---|
| 创建、启动、状态、停止 | 基本一致 | G-11 的规范入口同样位于 `deploy/scripts/`，傻瓜入口是 `deploy/scripts/vmctl.sh` |
| Windows 内键盘、鼠标、关机 | 一致 | G-11 已补入暂停态释放、USB HID 队列满时 all-up 和 duplicate-make 过滤 |
| SDL 交互延迟/恢复 | 一致 | 独立 8 ms 输入泵、鼠标移动合并、输入先于重显示更新；2D renderer reset 会重建/重传当前画面；G-11 仍保持自己的固定 60 Hz Present |
| 运行中隐藏/恢复窗口 | 默认 SDL 一致 | `vmctl display ID window-hide/window-show`；先核验 QMP 的 `query-name`，不会连错 VM |
| 运行中切到仅推流 | 条件一致 | G-11 必须在启动时显式带 `--stream URL`，之后才能 `stream-only`；无 fb-shm 时不会先隐藏唯一窗口 |
| GTK 运行中隐藏/恢复 | 尚不一致 | GTK 没有与 G-11 SDL 等价的安全 hide/show hook；默认生产窗口是 SDL |
| 冷启动无窗口/纯 headless | 尚不一致 | V-11 有 `--no-sdl`/`--headless`；G-11 当前只支持启动 SDL 后切 `stream-only`，没有把未实机验证的 vGPU headless 路径冒充成已支持 |
| GNOME Dock 独立编号图标 | 宿主便利项不同 | V-11 会写用户级隐藏 `.desktop`；G-11 不在 VM 启动时自动修改 `~/.local`，统一从 `vmctl.sh` 启停和显示/隐藏窗口 |
| QMP 截图/按键/快照工具箱 | 有意不原样移植 | G-11 只封装经过 VM 身份核验的状态、显示切换和关机；V-11 的 raw QMP、`savevm/loadvm` 不能视为 mdev/vGPU 安全快照 |
| 无桥接 NAT 回退 | 生产策略不同 | V-11 有 `--no-bridge`；G-11 维持经过校验的 bridge/VLAN 生命周期，不把改变授权和远程可达性的 user-mode NAT 冒充成等价网络 |
| 显卡加速/驱动 | 有意不同 | G-11 使用 NVIDIA vGPU + GRID/正式签名 consumer qualification；V-11 使用 virtio 显示，不能移植其驱动链 |
| 光标形状 | 硬件边界不同 | 当前 R535 mdev REGION 不提供 Windows 硬件 cursor plane；G-11 使用 host 箭头或 framebuffer-cursor 策略，V-11 的 virtio cursor 不能直接补过来 |
| fb-shm 默认状态 | 不同 | V-11 默认创建 fb-shm；G-11 只有显式 `--stream` 才创建 listener 和编码 sidecar，避免无目标的后台资源占用 |
| 推流范围 | G-11 边界更明确 | 当前只传视频，不含音频、远程输入、ABR/CDN；本地 SDL 键鼠不受影响 |
| fb-shm 静止帧/节拍 | 已对齐 | 新 consumer、ROI/帧率变更会立即补 bootstrap 帧；静止桌面不再每 tick 整块重拷贝，编码/网络落后不追帧 |
| 磁盘空间保护 | 已对齐 | 启动和建盘默认至少保留 16 GiB 且 5%，低于 10% 告警；支持明确的紧急 `DISK_FORCE=1` |
| qcow2 零块回收 | 已对齐 | 系统盘使用 `discard=unmap,detect-zeroes=unmap`，新空盘继续 metadata preallocation |
| 磁盘 AIO 后端 | 已对齐 | 默认 active-read 实测 `io_uring`，失败依次降级 `native`、`threads`；显式内核后端失败关闭，不接受静默线程池回退 |
| QEMU service CPU | 已对齐 | 默认 `auto`：容量足够时为辅助线程分配 1 个逻辑 CPU，否则回退 0；显式数字不自动降级 |
| 宿主 OOM 保护 | 已对齐 | 启动器及其 QEMU/swtpm/sidecar 后代默认临时使用 `oom_score_adj=-500`；不改全局 sysctl，随 VM 退出失效 |
| NVMe APST 宿主管理 | 已对齐（可选） | 单文件 `host-nvme-apst.sh` 已加入，但从不自动修改宿主；只能由管理员显式执行 |

因此，“进入 Windows 后能否正常点、打字、开关机”的答案是基本一样；“显示设备、
驱动、无窗口启动、cursor plane 和推流默认值是否完全一样”的答案是否定的。

## 本次已补齐的 G-11 功能

1. `deploy/scripts/ctl-vm.sh`：安全的运行期 SDL/fb-shm 控制，带 VM 身份校验。
2. `deploy/scripts/vmctl.sh display ...`：统一封装，不要求手写 QMP JSON 或 socket 路径。
3. USB HID 队列保护：重复按下不再挤满队列；队列满时 KEYUP 失败关闭为 all-up。
4. VM 暂停期间仍允许本地窗口发出 key/button release，并保证对应 sync 被提交。
5. SDL 输入独立 8 ms 轮询、连续 motion 合并、窗口 resize/redraw 合并、每轮一次 2D Present，以及 renderer reset 后的静止桌面恢复。
6. fb-shm 只在真实 damage 后复制完整 ROI；新 consumer/配置变更依然强制首帧，编码端不追过期节拍。
7. 建盘/启动磁盘余量门禁、qcow2 metadata 预分配与零块 unmap。
8. 文件 AIO active-read 自动选择：`io_uring` → `native` → `threads`，并拒绝假成功。
9. service CPU `auto` 策略，并把其它 VM 已占用的 cgroup CPU 纳入容量判断。
10. 每 VM 进程树的临时 OOM 保护：固定策略、调用 UID 与 PID generation 校验。
11. V-11 最新的通用 NVMe APST 单文件工具及无宿主副作用回归测试。

这些改动不启用 `testsigning`、不启用 `nointegritychecks`、不修改 Windows BCD，
也不安装任何测试签名或自签名内核驱动。

## 傻瓜操作：普通本地窗口

首次拉取本次改动后增量构建一次：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/build-qemu.sh
```

启动一台已有 VM（把 `11` 换成实际 ID）：

```bash
./deploy/scripts/vmctl.sh start 11
```

另开一个宿主终端查看状态、隐藏和恢复窗口：

```bash
./deploy/scripts/vmctl.sh display 11 status
./deploy/scripts/vmctl.sh display 11 window-hide
./deploy/scripts/vmctl.sh display 11 window-show
```

正常关机：

```bash
./deploy/scripts/vmctl.sh stop 11
```

`window-hide` 只暂停 SDL DisplayChangeListener 并隐藏窗口，不暂停 Windows、网络、
磁盘或 vGPU。`window-show` 会恢复 listener 并强制重画静止桌面。

## 傻瓜操作：本地窗口与推流之间切换

G-11 必须在启动时给出明确推流目标。示例目标不包含凭据；真实目标或 token 只通过
批准的运行时安全渠道提供，不写入仓库：

```bash
./deploy/scripts/vmctl.sh start 11 \
  --stream 'srt://edge.example:9000' \
  --stream-rate 60
```

另一个终端执行：

```bash
# 先确认 QMP、窗口后端、fb-shm socket 和编码 sidecar
./deploy/scripts/vmctl.sh display 11 status

# 先恢复/确认 fb-shm 成功，再隐藏 SDL；失败时窗口保持可见
./deploy/scripts/vmctl.sh display 11 stream-only

# 恢复本地 SDL，再暂停 fb-shm listener
./deploy/scripts/vmctl.sh display 11 window-only

# 也可分别控制
./deploy/scripts/vmctl.sh display 11 stream-pause
./deploy/scripts/vmctl.sh display 11 stream-resume
./deploy/scripts/vmctl.sh display 11 window-hide
./deploy/scripts/vmctl.sh display 11 window-show
```

兼容 V-11 的动作别名仍可用：`sdl-hide`、`sdl-show`、`fb-pause`、`fb-resume`、
`sdl-only`。不提供 `fb-off/fb-on`，因为 G-11 的 fb-shm object 与编码 sidecar 是一个
经过启动器校验的生命周期合同，运行中随意 object-del/object-add 会绕过 socket、
PID 和输出目标校验。

使用自定义 VM 根目录时，所有命令都带同一个选择器：

```bash
./deploy/scripts/vmctl.sh display 11 status --vms-dir /mnt/fast-vms
```

## 磁盘余量门禁

默认无需设置任何变量。启动器会在 mdev、TPM 和 QEMU 产生主要资源副作用之前检查
实例盘所在文件系统：

- 硬门禁：`max(16 GiB, 文件系统总容量的 5%)`；
- 告警线：10%；
- `--dry-run` 不因当前宿主余量改变规划结果。

空间不足时应先释放或迁移数据。只有紧急救援且明确接受 qcow2/guest ENOSPC 风险时，
才对单次命令使用：

```bash
DISK_FORCE=1 ./deploy/scripts/vmctl.sh start 11
```

永久关闭门禁不推荐；如确需诊断，可单次设置 `DISK_GUARD=0`。阈值可通过
`DISK_MIN_FREE_GIB`、`DISK_MIN_FREE_PERCENT`、`DISK_WARN_FREE_PERCENT` 调整。

## 磁盘 AIO 自动选择

普通启动不需要增加参数。`QEMU_DISK_AIO=auto` 是默认值，启动器会读取 QEMU
可执行文件自身完成一次真实 4 KiB O_DIRECT 读取，不创建临时盘，也不读写 VM
系统盘。启动摘要会显示实际结果，例如：

```text
>> disk aio:    io_uring (policy=auto)
```

`io_uring` 不可用时自动试 `native`，两者都不可用才选择可靠的 `threads`。
如需定位宿主内核/文件系统问题，可以对单次启动显式指定；`native` 或
`io_uring` 探测失败时会直接拒绝启动，不会悄悄换成线程池：

```bash
QEMU_DISK_AIO=native ./deploy/scripts/vmctl.sh start 11
QEMU_DISK_AIO=threads ./deploy/scripts/vmctl.sh start 11
```

该策略只改变宿主 qcow2 文件 I/O 后端；Windows 看到的 NVMe/SATA 控制器、型号、
序列号和 PCI 身份不变。`--dry-run` 无法代表当前宿主实测结果，因此保守显示
`threads`，真实启动仍重新探测。

## 运行期宿主 OOM 保护

默认 `HOST_OOM_PROTECT=1`。root-owned helper 只接受当前调用用户、精确
VM ID 和 PID starttime 匹配的 `start-vm.sh` 进程，并且只能应用固定
`-500` 策略；已从受信父进程继承更强的负值时不会反向削弱。

这只是 Linux 对全局 OOM killer 候选顺序的临时偏置，不会凭空增加内存；
`MEM_GUARD` 仍负责启动前的 RAM+swap 容量门禁。只在明确接受运行期 VM
更容易被 OOM killer 选中时，对单次启动使用：

```bash
HOST_OOM_PROTECT=0 ./deploy/scripts/vmctl.sh start 11
```

## 可选：宿主 NVMe APST

这不是 VM 启动必需项，也不会由 G-11 自动执行。先只读检查：

```bash
./deploy/scripts/host-nvme-apst.sh check
```

需要关闭宿主本地 PCIe NVMe APST 时，推荐先持久化、人工安排宿主重启、再验证：

```bash
sudo ./deploy/scripts/host-nvme-apst.sh persist
# 由管理员在维护窗口正常重启宿主
sudo ./deploy/scripts/host-nvme-apst.sh verify
```

也可显式 `apply` 尝试在线设置。该工具修改的是 Linux 宿主的 NVMe 模块/启动参数，
不是 Windows BCD；脚本自身不重启、不 reset 控制器、不卸载文件系统。完整说明见
[NVME-APST.md](NVME-APST.md)。

## 回归验证

以下测试不需要真实 vGPU；伪 QMP、伪 cgroup、临时文件系统和 qtest 不修改宿主：

```bash
bash deploy/tests/vgpu/test_display_control.sh
bash deploy/tests/vgpu/test_disk_headroom.sh
bash deploy/tests/vgpu/test_storage_aio.sh
bash deploy/tests/vgpu/test_cpu_isolation.sh
bash deploy/tests/vgpu/test_host_oom_protection.sh
bash deploy/scripts/tests/test_host_nvme_apst.sh

ninja -C build \
  tests/unit/test-input-paused-release \
  tests/unit/test-sdl2-event \
  tests/qtest/usb-hid-keyboard-queue-test \
  qemu-system-x86_64

build/tests/unit/test-input-paused-release --tap
build/tests/unit/test-sdl2-event --tap
QTEST_QEMU_BINARY="$PWD/build/qemu-system-x86_64" \
  build/tests/qtest/usb-hid-keyboard-queue-test --tap
```

真正的最终验收仍需一台 G-11 实机 VM：默认 SDL 启动、键鼠、失焦/暂停释放、
`stream-only` 往返、完整 Windows 关机，以及 NVIDIA driver/license 状态都通过。

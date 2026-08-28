# G-11 宿主内存按需占用

这个开关只改变 Linux 宿主怎样为 QEMU 的 memfd 触页。Windows 里的内存上限、
DIMM/SPD、SMBIOS 和 NUMA 拓扑都不变，也不会新增 balloon、virtio-mem、VMBus 或
Hyper-V 身份。它适合“给 Guest 配 8G，但空闲时不希望 QEMU 一启动就让 8G 全部
驻留”的场景。

## 一键开启

先完整关闭 VM，再执行：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/start-vm.sh 1 --proxy --cpu-isolate=false --memory-prealloc=false
```

也可以使用统一封装；后面的启动参数会原样、安全地交给唯一启动器：

```bash
./deploy/scripts/vmctl.sh start 1 --proxy --cpu-isolate=false --memory-prealloc=false
```

启动摘要看到下面这行就表示已生效：

```text
宿主内存: 按需触页（Guest 上限 8192 MiB 与 DIMM/SMBIOS 身份不变……）
```

这两个布尔键只作用于本次启动，不写入固定 Guest 硬件身份。以后每次需要共享 CPU
和按需占用时继续传 `--cpu-isolate=false --memory-prealloc=false`。两个键都省略时
默认值均为 `true`，即 CPU 隔离和内存全量预分配。

## 恢复原来的低延迟模式

完整关闭 VM，再执行：

```bash
./deploy/scripts/vmctl.sh start 1 --proxy --cpu-isolate=false
```

省略 `--memory-prealloc` 就恢复默认的 `true`；若也要恢复默认 CPU 隔离，则两个布尔键
都省略即可。

## 怎么验证实际节省

不要用 Windows 任务管理器里的“已使用”数字推算宿主释放量。分别以两种模式冷启动，
在同一阶段、同一负载下找到 QEMU PID，然后比较 Linux 的 `VmRSS`、`VmLck`、
`VmSwap` 和 memfd RSS/PSS。至少记录空闲 10 分钟、启动游戏、持续负载和退出游戏四个
阶段；同时检查宿主 swap、NVIDIA Xid 和画面帧时间。

`--memory-prealloc=false` 只避免 QEMU 主动预触尚未使用的页。Guest 已经触及过的页，即使
Windows 后来把它标为可用，也不保证立即归还宿主；NVIDIA 535 闭源 mdev 驱动还可能
按工作集额外 pin 页。因此不能承诺固定节省多少 GiB，工作集仍可能增长到配置上限。

## 容量和安全边界

- 启动器仍按 Guest 完整上限执行 `MemAvailable + SwapFree` 护栏；按需模式不是超售
  授权。多台 VM 之后同时用满仍可能 OOM。
- 不要为追求“真正动态回收”自行添加 `virtio-balloon`、`hv-balloon`、`virtio-mem`
  或 `x-balloon-allowed=on`。R535 mdev 没有经本项目验证的安全页丢弃合同，且这些
  设备会改变 Guest 可见硬件/Hyper-V 身份。
- 本功能不修改 BCD，不开启 `testsigning`/`nointegritychecks`，也不安装任何测试签名
  或自签名内核驱动。

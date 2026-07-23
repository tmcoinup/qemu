# DGame 区域定位与 QEMU 叶节点授权记录（2026-07-22）

## 现象与影响

DGame 的窗口卡片可以收到 1920×1080 推流帧，但显示的是完整 Windows 桌面，
没有裁剪到 DNF 游戏客户区。日志同时出现：

```text
内存定位：打开 guest 内存失败
procfs 高速内存后端无权读取 QEMU pid=...: Operation not permitted
```

疲劳 OCR 的固定 HUD ROI 随后也可能报告不可读，但它不是窗口定位方案。当前窗口
矩形由 DGame 的 `src/features/dnf/memory/window_rect/` 内存流水线解析；不再使用
小地图锚点或整帧 OCR 猜测游戏位置。内存定位失败时无法得到可信客户区，因此不会
向 fb-shm 推送错误的 `SET_ROI`，UI 只能继续显示完整桌面。

## 根因

Linux 默认 Yama `kernel.yama.ptrace_scope=1` 会限制 `process_vm_readv`。DGame 与
QEMU 虽由同一普通用户运行，DGame 仍不是 QEMU 的父进程；QEMU 未设置进程级 Yama
例外时，毫秒级 procfs 内存后端会收到 `EPERM`。

`PR_SET_PTRACER_ANY` 会跨 `execve` 保留，但不会经过普通 `fork` 自动传给后代。
所以授权程序必须直接 `exec` 最终 QEMU，不能包装 `start-vm.sh`，也不能放在
`gnome-session-inhibit` 或 `systemd-inhibit` 外面。

错误顺序：

```text
dgame_qemu_ptracer → start-vm.sh → inhibit → fork → QEMU
```

正确顺序：

```text
gnome-session-inhibit
  → systemd-inhibit
    → dgame_qemu_ptracer（或 setpriv --ptracer any）
      → exec QEMU
```

wrapper 在 `exec` 后会被 QEMU 原地替换，PID 不变，所以启动完成后的 `ps` 中看不到
wrapper 是正常现象。QEMU 不能增加 `-daemonize`，否则它会再次 fork 并丢失授权。

这里的 `PR_SET_PTRACER_ANY` 不是“只对白名单 DGame 开放”。它只针对该 QEMU 进程
解除 Yama scope=1 的父子关系限制；调用者仍须满足相同 UID、目标可 dump、传统 Unix
权限及其它 LSM 规则。AppArmor/SELinux、不同 UID 或不同完整性边界仍可能拒绝读取。

## 自动修复

`start-vm.sh` 在真实启动路径中 source `lib/sv-qemu-ptracer.sh`，并在最终调用
显示生命周期守护前构造 QEMU 叶命令。选择顺序为：

1. 可选环境变量 `DGAME_QEMU_PTRACER` 指定的可执行文件；
2. `start-vm.sh` 同目录随发布包携带的 `dgame_qemu_ptracer`；
3. `PATH` 中的 `dgame_qemu_ptracer`；
4. 仓库自带的 `qemu-ptracer-wrapper.py`，由现有 Python 3 运行时执行；
5. `/usr/bin/setpriv --ptracer any --`，再回退到 `PATH` 中支持该参数的 `setpriv`。

正常部署不需要设置任何变量。Python 3 已是本项目宿主依赖，所以 Ubuntu 22.04、
24.04 等旧版 `setpriv` 尚无 `--ptracer` 的机器也会自动使用第 4 条。`setpriv` 仅是
探测到 util-linux 2.41+ 能力后的末级回退。所有候选都不存在、显式 wrapper 不可
执行，或 QEMU 参数包含 `-daemonize` 时，启动器会 fail closed，不会悄悄裸启一个
无法定位窗口的 VM。

非 DRY_RUN 的 wrapper 与 Yama 策略预检早于后续磁盘创建、身份提交、TPM 和
host tune 模块；失败时 shell 会释放 `sv-cli` 已取得的实例锁，但可能保留它此前创建
的空 VM 目录。`ptrace_scope=0/1` 可启动；scope 2/3 会在启动前明确拒绝，因为普通
用户的叶节点例外不足以越过这些模式。没有 Yama 的内核可继续，但仍须由 DGame 的
只读部署检查验证其它 LSM/权限条件。

该步骤在每次 `start-vm.sh <实例号>` 中独立执行，没有共享锁、端口或全局授权状态。
因此 VM1、VM2、VM3… 多开时会分别授权各自的 QEMU，不需要按实例新增配置。

`DRY_RUN=1` 仍只打印纯 QEMU argv，不加入 wrapper，保证原有参数回归基线稳定；
真实启动才包装叶命令。

## 已运行 VM 的一次性处理

授权必须在进程启动前设置，无法补到当前已经运行的 QEMU。部署本修复时，所有旧 VM
都需要各自正常停止并通过同一个入口启动一次：

```bash
deploy/scripts/stop-vm.sh 1
deploy/scripts/start-vm.sh 1

deploy/scripts/stop-vm.sh 2
deploy/scripts/start-vm.sh 2
```

可以逐台滚动重启，不要求同时停掉全部 VM。完成这一次后，后续普通开机、重启和新增
实例都自动走叶节点授权。

宿主应保留默认 `kernel.yama.ptrace_scope=1`。不要再把全局 scope 持久化为 0；那会
扩大整台宿主的进程读取范围，也会掩盖启动链部署错误。若本次排障临时设成 0，应在
所有仍依赖旧启动链的 VM 完成滚动重启后恢复为 1。

## 验收

先确认启动日志包含：

```text
>> DGame memory: QEMU 叶节点 Yama 例外就绪 (...)
```

然后在 `ptrace_scope=1` 下运行 DGame 的只读部署检查：

```bash
/home/ubuntu/projects/dgame/client/target/release/dgame \
  provision-memory --target procfs vm-001
```

预期结果是目标 QEMU PID 与真实 RAM 读取通过；DGame 日志不再出现
“procfs 高速内存后端无权读取”。启动 DNF 后，窗口矩形流水线应在毫秒级得到客户区，
fb-shm 随后应用对应 ROI，窗口卡片不再显示完整 Windows 桌面。

回归测试覆盖显式 wrapper、发布包自动发现、旧 Ubuntu 可用的内置 Python wrapper、
原地 exec/PID 保持、Yama 0/1/2/3 策略、非法配置 fail closed、`-daemonize` 门禁、
带空格 argv，以及实际 `systemd-inhibit → wrapper → QEMU` 顺序：

```bash
bash deploy/scripts/tests/test_qemu_ptracer_launch.sh
```

## 平台与依赖边界

- Linux/KVM：使用 QMP 地址转换与 `process_vm_readv`；需要本文件描述的叶节点授权。
- Windows 宿主：使用同用户、同完整性级别的 `ReadProcessMemory`，不运行 `setpriv`，
  也不受 Linux Yama 影响；若跨用户或完整性级别，仍应按 Windows 权限模型处理。
- `libvmi.so`：本路径不安装也不动态链接系统 libvmi。可选的 memflow/microvmi 后端
  是另一条能力路径，不是窗口区域定位和默认 procfs 后端的运行依赖。
- OCR：只读取现有 UI 帧副本并裁剪业务 ROI；它不负责改变推流 ROI，也不能替代
  内存窗口矩形定位。

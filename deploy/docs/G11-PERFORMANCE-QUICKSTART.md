# G-11 性能与时钟：傻瓜式提速

这套调整只修改 Linux 宿主的运行时性能策略和本次 QEMU 参数。它不会开启
`testsigning` / `nointegritychecks`，不会修改 BCD，也不会安装测试签名或自签名
内核驱动。宿主凭据只由 `sudo` 提示或进程内的 `SUDO_PASSWORD` 接收，不会写入仓库。

## 第一次使用：复制三条命令

在仓库根目录执行：

```bash
./deploy/scripts/g11-performance.sh audit
./deploy/scripts/g11-performance.sh apply
./deploy/scripts/start-vm.sh VM编号
```

`apply` 第一次会安装固定的 root-owned helper，并只给当前用户开放两个无参数命令：
`apply` 和 `restore`。成功输出必须包含：

```text
ready=yes
latency-first-v1
persistent=yes
memory=host-native-unthrottled
```

随后应完整关闭 Windows 和旧 QEMU 进程，再启动一次；只在 Windows 内点“重启”不能
切换 QEMU 的 RTC 参数。

以后普通 `start-vm.sh` 会以 `G11_HOST_PERFORMANCE=auto` 检查并复用该策略。helper
未安装且当前会话拿不到 sudo 时，自动模式会明确告警但仍允许 VM 启动；要求缺一项就
拒绝启动时使用：

```bash
G11_HOST_PERFORMANCE=required ./deploy/scripts/start-vm.sh VM编号
```

## 实际改变了什么

资源策略 CLI 只接受 `--cpu-isolate=true|false` 和
`--memory-prealloc=true|false`。正常 G-11 vGPU SDL/GTK 在未显式配置 CPU 环境策略时，
默认 `--cpu-isolate=false`；内存仍默认 `--memory-prealloc=true`。需要隔离时明确传
`--cpu-isolate=true`，不要把省略参数当作启用隔离。

- CPU：每个 cpufreq policy 的最低/最高值恢复为硬件 `cpuinfo_min/max_freq`，优先选择
  `performance` governor（不支持时才回退到可用的动态 governor），并开启 turbo/boost。
  负载低时仍可降频，负载到来时可以升到硬件上限；绝不按来宾 CPU 的标称频率给
  宿主 `scaling_max_freq` 封顶。
- TSC：来宾计时器仍保持恒定。启动器先查询 `KVM_CAP_TSC_CONTROL` 和真实宿主 TSC；
  能缩放时使用硬件目录频率，不能缩放时自动使用宿主 invariant TSC。动态睿频只改变
  指令执行速度，不会让来宾时钟忽快忽慢。
- RTC：默认改为与 V-11 相同的
  `-rtc base=localtime,clock=vm,driftfix=slew`，PIT 保持 `delay`，减少宿主 wall clock
  与来宾 TSC 两条时基在调度抖动时产生的同步告警。
- 内存：默认继续使用 `memory-backend-memfd,share=on,prealloc=on`，也可显式传
  `--memory-prealloc=false` 改成 `prealloc=off`；两者都保持 `merge=off`、Guest 固定容量
  和相同 DIMM/SMBIOS 身份。SPD 中的 DDR3-1600/1866 是型号身份，不是带宽限速；
  来宾实际使用宿主原生内存带宽。按需模式说明见
  [`G11-MEMORY-ON-DEMAND.md`](G11-MEMORY-ON-DEMAND.md)。THP 使用 `madvise`，同步
  defrag 关闭。
- I/O：NVMe 有 `none` 调度器时优先使用；磁盘仍由启动器实测选择
  `io_uring` / native AIO / threads，不强塞不适合 qcow2 的 IOThread。

`--cpu-isolate` 决定是否进行 vCPU/cpuset 隔离；`--svc-cpus 4` 只有开启隔离时才参与
QEMU 主循环/显示/I/O 辅助线程的留核分配。隔离关闭时，服务核请求不会应用。
两者都不会改变 RTC/TSC 的时间基准，也不会把 2C4T 来宾变成 4C8T。SDL 黑屏或切场景
卡顿还需要区分按需触页、宿主调度和显示恢复，见
[SDL 低延迟教程](G11-SDL-PERFORMANCE.md#共享-cpu按需内存时卡顿怎么比较)。

## SDL 切场景卡顿：保留共享 CPU 和按需内存

本次 QEMU 优化会把同一轮 SDL 变化区域合并后再上传，省掉新建纹理后的重复上传，
并将 VFIO 高运动时连续跳过 60 次比较改为每 8 次更新精确重查，让画面静止后更早停止
整帧复制。全部修改都在宿主，不需要 Guest 新软件，也不要求开启 CPU 隔离或内存
预分配；当前仍是 REGION → CPU → 宿主 GPU，不能称为全程 GPU。

在 QEMU 仓库根目录执行构建与审计：

```bash
./deploy/host/build-qemu.sh
./deploy/scripts/g11-sdl-performance.sh audit
```

在 Windows 中正常关机并等待旧 QEMU 退出，然后用下面命令启动 VM1；其他 VM 替换
数字 `1`，两个 `false` 保持原值：

```bash
./deploy/scripts/g11-sdl-performance.sh start 1 --proxy \
  --cpu-isolate=false --memory-prealloc=false
```

进入桌面后另开宿主终端运行：

```bash
./deploy/scripts/g11-sdl-performance.sh verify 1
```

应看到 `RESOURCE CPU_ISOLATION=off` 与 `RESOURCE RAM_PREALLOC=off`。本轮尚未重启
现场 VM 测得性能收益；`verify` 只核对运行参数，不能证明提速。按
[SDL 动态画面验收](G11-SDL-PERFORMANCE.md#画面不定格实机验收)比较同一应用的切换、
全黑过渡和恢复表现。通过 VMate 使用时，只需重新构建带入最新 G-11 QEMU 与 `deploy`
的新包，按实际客户端选择安装包（当前 G-11 为 `gmate` 包），正常关闭并启动 VM 后生效，
无需修改 VMate 业务代码；具体命令见
[VMate 生效步骤](G11-SDL-PERFORMANCE.md#使用-vmate-时怎么生效)。

## 时钟 A/B 对比

默认先测试 `clock=vm`：

```bash
./deploy/scripts/start-vm.sh VM编号
```

若某个旧 Windows 镜像在新策略下反而更差，完整关机后仅做一次兼容对比：

```bash
G11_RTC_CLOCK=host ./deploy/scripts/start-vm.sh VM编号
```

不要同时乱改多个时钟开关。`G11_TSC_POLICY=auto` 是生产默认；以下仅用于定位：

```bash
G11_TSC_POLICY=host ./deploy/scripts/start-vm.sh VM编号
G11_TSC_POLICY=profile ./deploy/scripts/start-vm.sh VM编号
```

`profile` 在宿主不能实现目标 TSC 时会失败关闭；`host` 使用宿主 invariant TSC。

## 回滚

同一次宿主开机期间，首次 `apply` 前的值保存在 root-only 的
`/run/qemu-g11-performance/original-state.tsv`。一条命令恢复：

```bash
./deploy/scripts/g11-performance.sh restore
```

`apply` 同时启用 `qemu-g11-performance.service`，以后每次开机都会重放同一策略；
`restore` 会先禁用该服务，再恢复本次启动首次 apply 前的值。RTC 只需下次启动临时
指定 `G11_RTC_CLOCK=host`；没有写入 Windows 注册表或 BCD。

## 验收

```bash
./deploy/scripts/g11-performance.sh audit
python3 ./deploy/scripts/kvm-capabilities.py --format json
bash ./deploy/tests/vgpu/test_host_performance.sh
bash ./deploy/tests/vgpu/test_tsc_policy.sh
```

性能体感对比必须使用同一 VM、同一应用场景，并分别记录 CPU 利用率、宿主
`scaling_cur_freq`、Windows 时钟告警和帧时间。已有 2C4T VM 的核心数不会被本策略
静默改写；需要更高吞吐时应新建或显式迁移到审核后的 4C8T 平台。

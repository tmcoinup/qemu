# G-11 单路 / 双路 E5：共享满载与多开性能教程

目标是让 Guest 有足够并行工作时，共享宿主允许使用的全部 CPU 和内存节点，减少
显示、内存和调度的额外开销。适用于 G-11 NVIDIA vGPU；V-11 独立维护。

单路 E5-2696 v4 通常是 22C/44T，双路是 44C/88T，实际以在线拓扑为准。
不写死 44/88，不要求两路 NUMA 编号连续，也不把每台 Guest 改成 88 vCPU。
共享模式没有本项目施加的 CPU 时间配额；上级 systemd/cgroup、任务亲和性仍可能限制资源。
内存容量、vCPU 数量和真实 vGPU framebuffer 仍按每台 VM 配置执行。

## 先理解 8 开与 16 开

| 双路 44C/88T 的配置 | vCPU 总数 | 与 88 个逻辑线程的比值 | 使用条件 |
|---|---:|---:|---|
| 8 台 × 6C12T | 96 | 1.09 | 共享调度可运行；全部线程同时繁忙时会争用 |
| 16 台 × 6C12T | 192 | 2.18 | 需要任务错峰或较低平均负载，不能承诺全部同时高帧率 |
| 16 台 × 4C8T | 128 | 1.45 | 新建时可比较，适合实测没有用满 12 vCPU 的应用 |
| 16 台 × 2C4T | 64 | 0.73 | 仅适合轻负载，不能据此认定游戏更快 |

这些比值不是性能倍率，也不是开机数量限制。88 个 SMT 线程共享 44 个物理核的
执行资源，不能当作 88 个完整物理核。CPU 总占用 50–60% 仍可能有单线程满载、
SMT 争用、跨 NUMA 访问、GPU 等待或磁盘停顿。一个游戏线程不能同时在多个核心执行；
必须用每线程和各资源的采样确认是否存在可解除的上限。

当前开发机是单路；2026-09-16 的短时采样中，两台 VM 各为 12 vCPU/8 GiB，线程
亲和性均为 `0-43`，可读的上级 `cpu.max` 均无限额。VM1 曾有单 vCPU 约 100%，
显示主线程约 30%，未见 swap-in/major fault；memfd 大页未启用。这些数据只属于
开发机，**不能用于判定其他双路电脑的 8 开卡顿原因**，也不是本次修改的提速结果。

## 最短操作

### 源码方式

在每台实际宿主分别执行，先编译新增的 SDL 后台节拍能力，再应用宿主策略：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/build-qemu.sh
./deploy/scripts/g11-performance.sh apply
./deploy/scripts/g11-performance.sh audit
./deploy/scripts/g11-sdl-performance.sh audit --multi-vm
```

宿主审计应有 `ready=yes`、`turbo=on`；提供对应接口的机器还应有
`max_perf_pct=100 shmem_thp=advise`。不支持的接口显示 `n/a`。
更新已有策略时会补记新增旋钮的原值，保留本次开机最早的已有快照，支持恢复。

正常关闭要更换启动参数的 Windows，等旧 QEMU 退出。**保持所有窗口原有显示刷新率、
只解除宿主资源限制**，以 VM1 为例：

```bash
./deploy/scripts/start-vm.sh 1 --shared-performance --memory-prealloc=false
```

`--shared-performance` 明确使用全部可用 CPU 节点，并在全部可用内存节点交错分配，
覆盖旧宿主配置中的 `local/local`；关闭独占分核，并要求性能策略成功。
与显式 `--cpu-isolate=true` 或 `--no-host-performance` 同用会报错。
不会解除外部 systemd/cgroup 的限制；先用下文采样核对，修改限制应在其所属服务配置中完成。

如果多开时只操作一个前台窗口，可以使用新增的多开显示档：

```bash
./deploy/scripts/g11-sdl-performance.sh start 1 --multi-vm --memory-prealloc=false
```

每台要使用这一档的 VM 都用自己的编号启动。前台 SDL 60Hz，失去键盘焦点的 SDL
15Hz，获得焦点自动恢复。DGame 默认预览降至 15Hz，需要更快的识别采样可追加
`--dgame-preview-rate 30` 或 `60`；这会增加拷贝与预览负载。
档位请求 REGION 16667us、FRL=0，并自动附加 `--shared-performance`。
旧 `host/vgpu-host.conf` 中显式的 console 周期仍优先，必须用 `verify` 核对实际值；
按当前受支持驱动的宿主配置流程调整，不能只看封装打印的请求值。

**降低后台 SDL/预览帧率只减少宿主显示工作；Guest CPU、游戏与 GPU 渲染任务继续运行。**
它不是游戏后台限帧，也不是 CPU 限速。需要所有窗口持续 60Hz 时用上面的普通共享命令。
原有默认档位不启用后台限帧。无须在 Guest 安装任何新软件。

默认建议按需分配，上面的命令均明确使用 `--memory-prealloc=false`，与 VMate 新建一致。
只有需要比较预分配时才显式选择 `true`：它先完成清零/触页，可能减少首次访问停顿，
但增加启动时间和初始宿主内存占用。`false` 实际用满后仍可占到配置容量。
新大页策略只是允许合适的映射使用大页，不保证分配成功；已有 VFIO 固定的页也不保证
立即变成大页，应在正常关机、新进程启动后比较。

### GMate 安装版

安装包含本次修改的新包，在“修复中心 → G-11 宿主动态性能”应用策略。
新建默认共享 CPU、按需内存。创建、打开、批量启动自动携带
`--sdl --shared-performance --cpu-isolate=false --memory-prealloc=false`，无需手动填写。
显式选择独占隔离时不带共享性能，显式选择预分配时传 `--memory-prealloc=true`；
旧 G-11 配置缺失上述 CPU/内存策略字段时也采用两个 `false`，已有保存值继续生效。
新后台显示档可用安装包脚本入口：

```bash
/opt/gmate/deploy/g11/scripts/g11-sdl-performance.sh start 1 --multi-vm --memory-prealloc=false
```

脚本、宿主 helper、采样器由现有打包流程带入，新教程安装在
`/usr/share/doc/gmate/README.G11-FULL-PERFORMANCE.md`（VMate 包对应 `/usr/share/doc/vmate/`）。
不要只替换正在运行的 QEMU 就认为旧进程已升级；二进制与启动参数在新进程中生效。

## 在发生卡顿的双路机器上定位

以正在运行的 VM1 为例，采样不改任何运行设置：

```bash
python3 deploy/host/collect-g11-performance.py --vm 1 --seconds 60
```

安装版将 `deploy/host/` 换成 `/opt/gmate/deploy/g11/host/`。可追加
`--output /tmp/g11-vm1-before.json` 保存报告，文件必须不存在。
先静止约 10 秒，再复现卡顿，同一轮保留原有分辨率、VM 数量和应用场景。

| 观察 | 意义与下一步 |
|---|---|
| `sockets=2 physical_cores=44 online_threads=88` | 确认两路均在线；NUMA 节点数量不一定正好等于插槽数 |
| `线程可用CPU` 只覆盖一部分在线线程 | 检查绑核、旧隔离模式与上级 cpuset；不要假定总 CPU 空闲就没有局部争用 |
| 某一层 `cpu_max=400000 100000` | 整个该组最多约 4 个逻辑 CPU 的时间预算；父组还与组内其他进程共享预算 |
| `cpu_max=max 100000` | 该层没有 CPU 时间配额；`null` 表示无接口/不可读，不能当作无限额 |
| `memory_max`/`memory_high` 为数字 | 有 cgroup 内存上限或回收阈值，结合内存 PSI 判断 |
| 单 vCPU 长期接近 100%，总利用率不高 | 可能受单线程、Guest 内忙等或锁争用限制；增加 vCPU 不保证改善 |
| SDL 主线程接近 100% | 检查分辨率、预览帧率、源帧复制和 GL 提交；比较多开显示档 |
| CPU PSI 上升且线程可用 CPU 完整 | 整机有调度竞争，检查其他宿主负载；PSI 是全机指标，不是此 VM 独占统计 |
| swap-in / major fault / 内存 PSI 上升 | 先减少工作集或并发，再比较预分配；不能把磁盘 swap 当作可用 RAM |
| GPU 忙但 CPU 有空闲 | 看实际 GPU 占用、时钟、功耗和真实 framebuffer，不按 Guest 显卡名称判断 |

采样中 CPU% 以一个逻辑线程满载为 100%，统计窗口和取整可能使峰值略高于 100%。
`Content`/`Present` 是显示提交指标，不能代替游戏内部帧率或唯一新帧计数。
使用 wrapper 启动后另执行 `./deploy/scripts/g11-sdl-performance.sh verify 1` 核对实际参数。

## 全面优化的优先级

| 项目 | 建议 | 原因与边界 |
|---|---|---|
| CPU | performance、Turbo、全局 `max_perf_pct=100`，共享模式用全部允许的在线 CPU | 本次补齐全局上限；逐个 cpufreq policy 设置，自动覆盖单路/双路 |
| NUMA | 先用 all/all 验证多开总吞吐；内存条按主板手册均匀装到两路的通道 | 全部节点可用不等于最低延迟；交错分配可能增加跨插槽访问。若追求单台帧时间，另做 local/local 对照 |
| RAM | memfd `shmem_enabled=advise`，THP 整理 `never`，保留 swappiness=1 | QEMU 已对 RAM 发出 MADV_HUGEPAGE；只改匿名 THP 对 memfd 不够。本次补齐共享内存策略和回滚 |
| 容量 | 按每台实际工作集规划，并给 Linux、DGame、驱动和缓存留余量 | 8 台×8GiB 已是 64GiB，16 台×8GiB 是 128GiB；宿主必须在这之外有余量，按需分配不保证已用页马上归还 |
| vCPU | 先保留 6C12T 做对照；新建相同工作负载比较 4C8T，减少无收益的并行线程 | 不自动重写已有 VM 的 CPU 身份或拓扑。Guest 的标称 GHz 不会把宿主真实频率固定在该值 |
| SDL | 多开前台60/后台15，保持输入独立轮询；所有窗口必须60时用普通共享入口 | 本次实现后台节拍，并防止另一条高速预览监听器把 SDL 再拉回60Hz |
| 分辨率 | 在应用允许时比较 1920×1080 与 1280×720 | 每帧像素数降至约44%；REGION读、staging拷贝和纹理上传的数据量随之下降，实际提速需测 |
| 预览/自动化 | DGame 按识别需求用15/30Hz；不用预览时显式 `--no-dgame-preview` | 避免每台 VM 为无人查看的预览重复传输；识别依赖预览时不要关闭 |
| vGPU | 读真实 profile、显存占用和 scheduler；Best Effort 适合借用空闲 GPU 时间，Equal Share 侧重并发公平 | CPU 共享不会解除真实显存配额或 GPU 时间片限制。必须按实际驱动分支支持的策略操作，不直接套用新版驱动命令 |
| 存储 | 优先本地低延迟 SSD/NVMe，保留已有 cache=none 与经过探测的异步 I/O；错开批量冷启动和大规模更新 | 现有 G-11 NVMe/AHCI 不是 virtio-blk；当前 nvme 设备没有 iothread 参数，不能机械附加无效选项 |
| Windows | 保留现有 Guest Lite 的高性能电源计划、游戏模式与关闭后台录制，清理实际多余的常驻应用 | 不叠加多个“一键优化器”；不因提速修改 BCD、testsigning 或安装测试签名驱动 |
| 散热/供电 | 检查满载实际频率、温度与功耗是否触墙 | Turbo 峰值不是所有核心长期满载的保证。QEMU 参数不能解除物理限制 |

核实资源共享与性能策略后，先测8台，再逐步增加到10、12、16台，每级至少复现相同的
战斗/切图场景。记录应用帧时间（可获得时用95/99百分位）、单vCPU峰值、CPU PSI、GPU
占用、内存 PSI 和 swap。只按 Windows 或 Linux 的整机 CPU 百分比决定加开数量不可靠。

宿主超频不是本次软件优化路径。E5-2600 v4 这类服务器平台应先使用支持的 Turbo、
散热与内存通道配置；不承诺倍频解锁或全核峰值频率。即使宿主变快，所有 Guest
共享的总能力也仍然只有这一台宿主的能力。
[Intel Xeon 超频说明](https://www.intel.com/content/www/us/en/support/articles/000030611/processors/intel-xeon-processors.html)、
[Turbo 的负载与频率边界](https://www.intel.com/content/www/us/en/support/articles/000056901/processors/intel-xeon-processors.html)。

全局 P-state 上限和 memfd 大页的依据见
[Linux intel_pstate](https://docs.kernel.org/admin-guide/pm/intel_pstate.html)、
[Linux THP](https://docs.kernel.org/admin-guide/mm/transhuge.html)；vGPU 调度取舍见
[NVIDIA vGPU 功能说明](https://docs.nvidia.com/knowledge-base/latest/vgpu-features.html)。

## 本次验证

本次本地验证：QEMU 编译、一次 `cargo check`、既有宿主策略和 SDL wrapper 检查通过。
临时模拟44/88个CPU policy验证了频率上限、大页、升级快照与恢复；没有新增测试文件。
隔离 X11 中两个暂停的测试实例测得前台 Present 约60/s、后台约15/s，交换焦点后恢复。
这验证的是SDL节拍，不是vGPU游戏帧率；其他双路宿主的8/16开收益尚待实测。

## 恢复

源码入口正常关闭 Windows，下次启动去掉 `--multi-vm` 和 `--shared-performance`，即恢复原有启动策略。
VMate 的共享模式默认携带共享性能；需对照源头默认时使用不带此选项的源码入口。
只想恢复后台全速显示，去掉 `--multi-vm`，仍保留 `--shared-performance` 即可。

宿主运行时参数可通过下列命令恢复本次开机保存的原值：

```bash
./deploy/scripts/g11-performance.sh restore
```

源码 wrapper 的 restore 只恢复运行时，不禁用已安装的开机服务；要停止开机应用，执行
`sudo systemctl disable qemu-g11-performance.service`，并在后续启动时显式
`--no-host-performance`（不能同时使用共享性能档）。安装版可用修复中心的“恢复原设置”。

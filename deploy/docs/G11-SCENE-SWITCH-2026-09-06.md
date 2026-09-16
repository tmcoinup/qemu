# VM2 切角色后台采样记录（2026-09-06）

## 本次结论

后台 QMP 操作已完成一次选择角色、选中另一名已有角色、进入游戏。无需激活
宿主窗口，也未给 Guest 安装软件。切换时确实出现 Content 很低而 Present
继续约 60/s 的情况；这次证据不支持把停顿简单归因于宿主按需分配内存。
尚不能在 Guest 加载等待和 NVIDIA REGION 画面采集之间确定最终原因。

用户先前手动进入副本的一轮也有相同趋势：06:59:15–06:59:17 的三个标题样本
Content 为 0/s，Present 为约 60/s；同时 pidstat 的 QEMU 主线程为 31%、24%、31%，
进程 major faults 为 0/s。该轮 CPU 采样在约 06:59:43 结束，标题记录持续到
07:00:19，不能用前面的 CPU 数据解释后面未覆盖的事件。下面的详细记录专门描述
后台脚本控制的角色切换，未把两轮数据混在一起。

## 固定条件

- 本地 RTX 2080 + RX570，NVIDIA 535.161.05；不是远端 V100 + RX550。
- VM2：12 vCPU、8192M、`CPU_ISOLATION=off`、`prealloc=off`。
- SDL：GL 开启、固定 60 Present、输入轮询 2 ms。
- 实际 mdev：`intervaltime=16667,vgaintervaltime=16667,frame_rate_limiter=0`。
- VM RAM 采样前已有约 8 GiB 常驻，QEMU Swap 为 0；RAM 与 mdev 都在 node0。
- 运行映像与磁盘二进制 SHA256 相同：
  `f5b4753caaff7dfe2a750c2afe912e188a9d5921b47a2f07d3cb6ab6d9efee91`。

监控保留 false/false 启动基线，未更改驱动参数、重启 VM 或改变 CPU/内存策略。

## 操作和观测

下表时间为本地 UTC−07:00。性能样本为 1 Hz，窗口标题为 2 Hz 读取；标题本身
约每秒更新，不能用它精确测量某一帧的延迟。此轮采样器尚无绝对时间字段，
性能样本与操作按两脚本启动时间对齐，误差约 1 秒。

| 时间 | 观测 |
|---|---|
| 07:06:00–07:10:00 | 连续采样 240 秒 |
| 07:07:46.947 | 点击游戏菜单的“选择角色” |
| 07:07:47.315 | QMP 截图中游戏主要区域已经黑色，桌面及侧边区域仍显示 |
| 07:08:25.329 | 下一次人工核对截图已处于角色选择页；两张截图之间不能当作黑屏持续时间 |
| 07:09:01.908 | 选中相邻的已有角色 |
| 07:09:10.132 | 点击“游戏开始” |
| 07:09:12–07:09:14 | 标题 Content 为 0、0、1/s，Present 约 56–58/s |
| 07:09:15–07:09:17 | Content 从 7 升到 44、56.9/s |
| 07:09:50.708 | 截图确认新角色已经进入游戏；Content/Present 接近 60/s |

进入角色附近的 1 秒样本，QEMU 主线程 CPU 约 23%–37%（100% 表示占满一个
逻辑 CPU），没有出现持续占满单核。各 vCPU 合计约 2–3 个逻辑 CPU，不能
据此排除 Guest 内某个加载线程串行运行或等待。

Content 低谷附近没有宿主 swap-in，内存 PSI 停顿为 0，系统 IO PSI 停顿很低。
有约几十 MiB/s 的 QEMU 进程底层读取，但这不是 Guest 文件级耗时统计。
所采集的存活线程没有 major fault；部分样本发生线程创建/退出，计数不覆盖
这些短命线程。宿主未开启 schedstats，线程调度排队时间为 unknown，不能记为 0。

## 为什么还不能认定是 SDL 或 Guest 的单一问题

`Content` 是 QEMU 收到的画面更新通知统计，不是游戏内部 FPS。
`Present` 是窗口提交频率，固定模式可以重复提交旧画面。

QMP `screendump` 读取 QEMU 显示 surface，位于 SDL 最终 GL 绘制之前。
退出角色时这里也已经黑色，因此单改 SDL 最后的纹理绘制无法把该帧恢复成游戏内容。
这个 surface 仍经过 NVIDIA REGION 和 QEMU staging，截图不能越过这些环节
直接证明 Guest 当时有没有渲染新内容。

当前证据缩小了排查范围，但不能用一秒 CPU 平均值排除短暂阻塞，也不能把
07:07 的黑色截图直接当作 07:09 的逐帧证据。

## 数据位置和重复方法

本机临时记录（不打入安装包）：

- `/tmp/g11-vm2-qmp-switch.json`：240 秒宿主性能。
- `/tmp/g11-vm2-qmp-title.jsonl`：标题 Content/Present。
- `/tmp/g11-vm2-character-events.jsonl`：操作时刻。
- `/tmp/g11-vm2-character-click.png`：退出角色时的 QMP 黑色源画面。
- `/tmp/g11-vm2-character-entered.png`：重新进入游戏后的 QMP 画面。

通用采样器和重复操作说明见
[宿主性能采样教程](../host/README-g11-performance.md)。后续报告已经补充绝对时间，
不再依赖手工对齐启动时间。截图可能含游戏账号/聊天画面，不应直接提交进仓库。

远端 V100 必须另行采样，不能套用本地结论。先确认它实际加载的 NVIDIA 版本
与 mdev 周期，再以同样 false/false 配置比较第一次和第二次进入同一角色。
旧配置 `VGPU_CONSOLE_INTERVAL_US=0` 表示不写该参数，可能保留驱动默认周期；
单纯重打 deb 不会自动改掉已有宿主策略，也不会改变已经运行的 VM。

## 包审计

已只读解包用户给出的 `gmate_0.1.40-2_amd64.deb`：G-11 运行时来源 revision 为
`5bbbd09ce701b08f00a2258dd0df299b222b793a`，已经包含前一轮 SDL 优化。
该包 SHA256 为 `51b8bb0f968de7b1f0578380dd2a8372d4c8a5c93f3f937a8f60dab69e5b3fe1`。
本轮没有替换或重新构建此 deb。

## 封装收尾验证与稍后的画面

新增 `control-g11-console.py` 提供状态、按键、点击、截图四个明确操作，校验
目标进程身份、Unix socket 对端 PID 和 QMP VM 名称。采样器及控制器的 Python
语法/帮助检查通过，VM2 的只读 `status` 与 PNG 截图成功。两项部署周期行为检查
及宿主配置生成器检查均通过；VMate 最终状态 `cargo check` 通过。

07:25:19 的封装截图验证中，游戏主要区域再次黑色，且明确显示
“正在连接服务器……”提示。这是四分钟性能采样结束之后的另一时刻：连接/服务器
等待也应纳入后续排查，但不能倒推此前所有 Content 低谷都由网络引起。
没有继续点击该提示。截图仅保留在
`/tmp/g11-vm2-wrapper-check-20260906/screenshot.png`。

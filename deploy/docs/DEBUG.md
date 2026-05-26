# 调试与日志

## QEMU 侧

### 结构化 trace
```bash
# 启用所有 trace 事件
./build/qemu-system-x86_64 -trace enable='vfio*' -trace enable='kvm*' ...

# 或写入文件
./build/qemu-system-x86_64 -trace enable='vfio*',file=/tmp/qemu-vfio.log ...
```

### guest CPU / 指令异常
```bash
-d guest_errors,unimp,mmu -D /tmp/qemu-${VM_ID}.log
```

### GDB attach 到 QEMU 进程
```bash
sudo gdb -p "$(cat deploy/run/vm${VM_ID}.pid)"
(gdb) info threads
(gdb) thread N
(gdb) bt
```

### guest CPUID 断点（核心验证点）
排查 HYPERVISOR bit 是否真的被压下去：
```bash
(gdb) break x86_cpu_load_def
(gdb) cont
# 触发后看 env->features[FEAT_1_ECX] 里 CPUID_EXT_HYPERVISOR (1<<31) 是否 0。
```

### QMP 监控
```bash
socat - unix-connect:deploy/run/vm${VM_ID}.qmp
{"execute":"qmp_capabilities"}
{"execute":"query-cpu-model-expansion","arguments":{"type":"full","model":{"name":"Core-i5-6500"}}}
```

## Host KVM 侧

### perf kvm stat — 查 vm-exit 分布
```bash
sudo perf kvm --host --guest stat live
# 主要看 EXTERNAL_INTERRUPT / IO_INSTRUCTION / MSR_WRITE 的占比
# DNF 启动时 vm-exit 过多可能卡 TP
```

### /proc/sys/kernel/kvm/
```bash
cat /sys/module/kvm/parameters/tdp_mmu          # 应该 1 (加速 EPT)
cat /sys/module/kvm_intel/parameters/ept        # 1
cat /sys/module/kvm_intel/parameters/flexpriority# 1
```

## ACE 反作弊 / 计时检测侧

### `游戏计时异常` → `(13-131130-8)`
```
检测到游戏计时异常。请关闭并卸载变速器等可能影响游戏计时的软件，重启后重试。
(13-131130-8)
```
**注意先分清两个 ACE 码**：`13-131106-0` 是 **GPU PCI 主 ID** 异常（深层 `GPU_SELFSIGNED=1`
改 `10DE:1C81` 才会触发，浅层不碰）；`13-131130-8` 是 **计时（timing）异常**，跟 GPU 无关，
矛头指向 vCPU 服务延迟 / 时钟进度的方差。

**两类根因，都在 host 侧（非 guest 配置）**：

① **调度/时钟抖动**——
- `governor=powersave`：核在 vm-exit 之间降频，每次 exit 服务延迟忽高忽低；
- `halt_poll_ns` 太短（默认 200000）：guest HLT 后唤醒落在 poll 窗外 → IPI 唤醒延迟尖刺；
- THP `defrag=madvise/always`：khugepaged / 同步整理 stall 把 vCPU 冻住几毫秒 → 计时跳变。
这些都会让 ACE 读到的帧/tick 计时方差超阈值，误判成「变速器」。

② **超规格频率（关键，易漏）**——guest 的 TSC 被钉死在伪装 CPU 的 `tsc-freq`（如
Ryzen3-1200=3.1GHz），但**指令是按 host 真实频率执行的**。host(5800) governor=performance
能 boost 到 4.4GHz+，而伪装 CPU 自报的 SMBIOS Type4 `max-speed` 只有 3400MHz。于是 guest
「单位 TSC tick 内干的活」远超这颗 CPU 该有的量 = 一台超频/变速的机器 → 直接踩 `13-131130-8`。
⚠ 注意：单开 `governor=performance` 反而**加重**②（把 host 顶到满 boost），必须同时封顶频率。

**修复**：`start-vm.sh` 默认 `HOST_TUNE=1` + `CPU_FREQ_CAP=1`，起 VM 前自动跑
`host-performance.sh`：governor=performance + halt_poll=500000 + THP defrag=never（治①），
并把 `scaling_max_freq` 封顶到本实例 `CPU_MAX_MHZ`（治②，**只降不升**）。手动：
```bash
sudo deploy/scripts/host-performance.sh 3400000   # 位置参数=封顶 kHz(3400MHz=伪装 CPU 上限)
# 已装 /etc/sudoers.d/qemu-hostperf → 仅此脚本免密；start-vm 自动调优不再提示输密码。
# 多 VM 并发时 start-vm 自动取「在跑各 VM CPU_MAX_MHZ 最小值」做全局封顶(任一都不超规格)。
```
**验证调优是否生效**：
```bash
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | sort -u   # performance
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq  | sort -u   # =CPU_MAX_MHZ*1000(如3400000)
cat /sys/module/kvm/parameters/halt_poll_ns                          # 500000
cat /sys/kernel/mm/transparent_hugepage/defrag                       # [never]
grep -m4 MHz /proc/cpuinfo                                           # 应 ≤ 封顶值, 不再 4.4G
cat /proc/sys/vm/nr_hugepages                                        # 必须仍是 0(memfd 不预留)
```
**绝不能动的反检测命脉**（动了反而更可疑，且与计时检测无关）：`-cpu` 的
`tsc-freq=`/`+invtsc`/`+tsc-deadline`、`kvm=off`/`hypervisor=off`/`vendor=`、vCPU 数/拓扑
（`cores=N` 对应伪 N 核）、`-rtc clock=vm,driftfix=slew`、`-overcommit cpu-pm=on`。

> 若调优后仍报 `13-131130-8`：排查 host 是否被别的重负载抢核（`pidstat`/`perf kvm stat`），
> 或 vCPU 超额订阅（运行的 VM 总 vCPU > host 逻辑核）。本机 8c/16t，单 VM 4 vCPU，
> ≤4 台不超订。考虑给 VM 做 vCPU pinning 进一步降抖动（尚未默认开启）。

## swtpm / TPM 侧

### `CMD_INIT: 0x9` → QEMU 秒退（exit status 1）
```
qemu-system-x86_64: tpm-emulator: TPM result for CMD_INIT: 0x9 operation failed
```
**根因**：被强杀(SIGKILL / OOM-kill)的 qemu 留下的 swtpm `--daemon`（PPID 已脱离
qemu）仍持 `vms/<N>/tpm-state` 的 NVRAM flock。新 swtpm 能应答控制通道（start-vm 打印
"TPM 2.0 ready"），但 QEMU 发 CMD_INIT 时抢不到锁。`tpm.log` 实锤：
```
SWTPM_NVRAM_Lock_Dir: Could not lock access to lockfile: Resource temporarily unavailable
```
失败重试还会再叠加孤儿（曾累计到 3 个）。

**自愈**：`start-vm.sh` 起 daemon 前有 preflight reaper（无活 qemu 占用本实例 tpm-sock
时按 `dir=.../vms/<N>/tpm-state` 精确清理，跨实例零误杀），所以正常重跑
`start-vm.sh <N>` 即恢复；`stop-vm.sh <N>` 停机时也会一并收 swtpm。

**手动兜底**：
```bash
pkill -f 'swtpm socket --tpmstate dir=.*vms/<N>/tpm-state'   # 只清这一实例
# ⚠ 绝不删 vms/<N>/tpm-state/tpm2-00.permall —— 那是真 TPM 持久态(EK/Platform cert)，
#   删了 guest BitLocker / 证明链会崩
```

## NVIDIA vgpu_unlock 侧

```bash
# 运行时日志
sudo journalctl -fu nvidia-vgpu-mgr

# unlock 的 profile 是否生效
sudo grep -i 'profile override\|vdev_id' /var/log/syslog
```

## fastapi-dls 侧

```bash
cd /opt/fastapi-dls
sudo docker compose logs -f

# 已授权 VM 列表
curl -k https://<HOST_IP>/-/leases | jq
```

## Guest 侧 (Windows)

```powershell
# Event Log 看 NVIDIA 驱动加载
Get-WinEvent -LogName 'Application','System' -MaxEvents 200 |
    Where-Object { $_.ProviderName -match 'nvlddmkm|NVLoad|NVDisplay' }

# nvidia-smi
nvidia-smi -q | findstr /i "license"

# Device Manager (pnputil 视角)
pnputil /enum-drivers | Select-String -Context 0,5 NVIDIA
```

## 内存里记录的「复用老经验」

- Windows 启动后先等 RDP 可连 (通常 60–90s 后 3389 端口才 listen)；
  装完 GRID 驱动后 listener 会因为 WDDM 切换短暂重启，
  内存 `project_rdp_wddm_black` 记载连续断 3 次 Ctrl-Alt-Del 可踢 capture 还原。
- NVIDIA driver install 走 Express 模式最稳；Custom 经常漏装 `nvlddmkm.sys`。
- guest 里装完驱动后如果 RDP 黑屏，按 memory `project_vm1_rdp_broken`
  首先用 `Get-Service TermService,UmRdpService` 确认服务在跑，
  然后 `Test-Path HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters`
  ServiceDll 是否完整；如果 Parameters 整个不见了就是 RDP 栈损坏，
  只能 DISM + chkdsk 或重装。

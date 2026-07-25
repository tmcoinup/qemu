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

## ACE 仿真机 / 计时检测侧

### `游戏计时异常` → `(13-131130-8)`
```
检测到游戏计时异常。请关闭并卸载变速器等可能影响游戏计时的软件，重启后重试。
(13-131130-8)
```
**注意先分清两个 ACE 码**：`13-131106-0` 是 **GPU PCI 主 ID** 异常（历史深层模式把
物理主 ID 改成 `10DE` 时会触发；该模式现已删除并由启动器明确拒绝）；`13-131130-8`
是 **计时（timing）异常**，跟 GPU 无关，矛头指向 vCPU 服务延迟 / 时钟进度的方差。

**两类根因，都在 host 侧（非 guest 配置）**：

① **调度/时钟抖动**——
- 未选择性能偏好：核在 vm-exit 之间降频，每次 exit 服务延迟忽高忽低；
- `halt_poll_ns` 太短（默认 200000）：guest HLT 后唤醒落在 poll 窗外 → IPI 唤醒延迟尖刺；
- THP `defrag=madvise/always`：khugepaged / 同步整理 stall 把 vCPU 冻住几毫秒 → 计时跳变。
这些都会让 ACE 读到的帧/tick 计时方差超阈值，误判成「变速器」。

② **超规格频率（关键，易漏）**——guest 的 TSC 被钉死在伪装 CPU 的 `tsc-freq`（如
Ryzen3-1200=3.1GHz），但**指令是按 host 真实频率执行的**。host 性能策略
能 boost 到 4.4GHz+，而伪装 CPU 自报的 SMBIOS Type4 `max-speed` 只有 3400MHz。于是 guest
「单位 TSC tick 内干的活」远超这颗 CPU 该有的量 = 一台超频/变速的机器 → 直接踩 `13-131130-8`。
⚠ 注意：单开性能策略反而**加重**②（允许 host 满 boost），必须同时封顶频率。

**修复**：`start-vm.sh` 默认 `HOST_TUNE=1`、`CPU_FREQ_CAP=0`，起 VM 前自动跑
`host-performance.sh`：PPD performance（无 PPD 时回退 performance governor）+
可配置 halt_poll + THP defrag=never（治①），
但不会默认改变全机频率上限。确认单/多 VM 的全局影响后，可用 `--freq-cap` 显式把
`scaling_max_freq` 封顶到在跑实例最小 `CPU_MAX_MHZ`（治②，**只降不升**）。手动：
```bash
sudo /usr/local/libexec/qemu-vmate-host-performance 3400000 0
# 参数依次为封顶 kHz（0=不封顶）和 halt_poll ns；helper 固定 root-owned 并使用 NOSETENV。
# 多 VM 并发时 start-vm 自动取「在跑各 VM CPU_MAX_MHZ 最小值」做全局封顶(任一都不超规格)。
```
**验证调优是否生效**：
```bash
powerprofilesctl get                                                   # performance
cat /sys/devices/system/cpu/cpufreq/policy*/scaling_governor | sort -u # PPD + Intel P-State: powersave
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq  | sort -u   # =CPU_MAX_MHZ*1000(如3400000)
cat /sys/module/kvm/parameters/halt_poll_ns                          # 默认 0；启动器低延迟诊断可设 KVM_HALT_POLL_NS=500000
cat /sys/kernel/mm/transparent_hugepage/defrag                       # [never]
grep -m4 MHz /proc/cpuinfo                                           # 应 ≤ 封顶值, 不再 4.4G
cat /proc/sys/vm/nr_hugepages                                        # 必须仍是 0(memfd 不预留)
```
**绝不能动的反检测命脉**（动了反而更可疑，且与计时检测无关）：`-cpu` 的
`tsc-freq=`/`+invtsc`/`+tsc-deadline`、`kvm=off`/`hypervisor=off`/`vendor=`、vCPU 数/拓扑
（`cores=N` 对应伪 N 核）、`-rtc clock=vm,driftfix=slew`。`-overcommit cpu-pm`
默认保持 `off`，与 QEMU 上游默认一致，避免把 host CPU power management 能力交给
guest 后影响宿主调度统计；只有单 VM 低延迟实验需要时，才用 `QEMU_CPU_PM=1`
显式打开。

> 若调优后仍报 `13-131130-8`：检查 CPU isolate `status`、1:1 logical exact 和宿主
> 重负载（`pidstat`/`perf kvm stat`）。2C2T/2C4T/4C4T 分别占 2/4/4 条唯一线程；
> 8C/16T 在 auto 预留 2 核、service=0 时的同型上限分别为 6/3/3 台。

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
# 当前浅层模式只应有一个在线 PCI 显示设备；真实 InstanceId 保持 1AF4:1050。
$display = Get-PnpDevice -Class Display -PresentOnly
$display | Format-List FriendlyName,Status,Problem,InstanceId
$display | ForEach-Object {
    Get-PnpDeviceProperty -InstanceId $_.InstanceId `
        -KeyName DEVPKEY_Device_Service,DEVPKEY_Device_DriverInfPath,
            DEVPKEY_Device_HardwareIds
}

Get-CimInstance Win32_VideoController |
    Format-List Name,AdapterCompatibility,DriverVersion,PNPDeviceID
Get-CimInstance Win32_SystemDriver -Filter "Name='VioGpuDod'" |
    Format-List Name,State,Started,PathName
Get-AuthenticodeSignature "$env:WINDIR\System32\drivers\viogpudo.sys" |
    Format-List Status,SignerCertificate

Get-Content 'C:\ProgramData\StealthGPU\display-driver-install.log' -Tail 100
Get-Content 'C:\ProgramData\StealthGPU\nvapi-system-install.log' -Tail 100
Get-Content 'C:\ProgramData\StealthGPU\respawn.log' -Tail 100
```

## 当前 Display-Only 路径的判断原则

- 驱动成功标准是物理 `PCI\VEN_1AF4&DEV_1050`、`Service=VioGpuDod`、Problem=0，
  不是 `nvlddmkm`、`nvidia-smi` 或 NVIDIA 服务；当前流程不会安装这些组件。
- `HardwareIds` 应为当前 AIB 的规范逻辑首项 + 完整 `1AF4:1050` 物理尾项；它们属于
  上述同一个 devnode，真实 BDF、Service 和 Driver 不会因此改变。
- 显示模式必须在 SDL 本地控制台验证。RDP 会接管会话分辨率，不能用 RDP 下灰掉的
  分辨率控件判断 VioGpuDod 是否失败。
- 安装器返回 34 表示活动驱动未通过固定 stock 摘要/WHCP/服务路径验证。不要关闭签名
  强制或恢复自签名；先备份，按日志清理异常旧驱动，再运行最新统一 EXE。
- WMI/GPU-Z 名称正确不代表存在 guest 3D。stock VioGpuDod 是 Display-Only，预期没有
  Direct3D、CUDA、NVENC/NVDEC 或 NVIDIA 频率/显存管理。

# 调试与日志

下列绝对路径是默认 G-11 布局。使用自定义 bundle 时，先运行
`./deploy/scripts/start-vm.sh "$VM_ID" --vm-dir /abs/path/N --print-paths`，再使用输出的
`VM_RUN`、`VM_LOG` 和 `VM_CONFIG`，不要猜路径。

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
sudo gdb -p "$(cat /home/ubuntu/images/vms/${VM_ID}/run/qemu.pid)"
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

需要两个或更多 host 工具同时连接时，启动 VM 加 `--proxy`。这是 QMP 并发
开关，不是 HTTP/SOCKS 或 guest 网络代理：

```bash
# 终端 1
./deploy/scripts/start-vm.sh "$VM_ID" --proxy

# 终端 2（也可使用同目录下的 qmp.sock.proxy 兼容别名）
socat - unix-connect:/home/ubuntu/images/vms/${VM_ID}/run/qmp.sock
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

## swtpm / TPM 侧

### `CMD_INIT: 0x9` → QEMU 秒退（exit status 1）
```
qemu-system-x86_64: tpm-emulator: TPM result for CMD_INIT: 0x9 operation failed
```
**根因**：被强杀(SIGKILL / OOM-kill)的 qemu 留下的 swtpm `--daemon`（PPID 已脱离
qemu）仍持 `vms/N/tpm/state` 的 NVRAM flock。新 swtpm 能应答控制通道（start-vm 打印
"TPM 2.0 ready"），但 QEMU 发 CMD_INIT 时抢不到锁。`tpm.log` 实锤：
```
SWTPM_NVRAM_Lock_Dir: Could not lock access to lockfile: Resource temporarily unavailable
```
失败重试还会再叠加孤儿（曾累计到 3 个）。

**自愈**：`start-vm.sh` 起 daemon 前有 preflight reaper（无活 qemu 占用本实例 tpm-sock
时按 `dir=.../vms/N/tpm/state` 精确清理，跨实例零误杀），所以正常重跑
`start-vm.sh <N>` 即恢复；`stop-vm.sh <N>` 停机时也会一并收 swtpm。

**手动兜底**：
```bash
vm=3
pkill -f "swtpm socket --tpmstate dir=.*/vms/${vm}/tpm/state,"
# ⚠ 绝不删 vms/N/tpm/state/tpm2-00.permall —— 那是真 TPM 持久态(EK/Platform cert)，
#   删了 guest BitLocker / 证明链会崩
```

## NVIDIA vgpu_unlock 侧

```bash
# 运行时日志
sudo journalctl -fu nvidia-vgpu-mgr

# unlock 的 profile 是否生效
sudo grep -i 'profile override\|vdev_id' /var/log/syslog
```

### `Failed to allocate device: 0x59` / VFIO `Connection timed out`

`nvidia-vgpu-mgr` 通常先报 `Failed to allocate device: 0x59`，约 25 秒后 QEMU 才
显示 `error getting device from group ...: Connection timed out`。这属于 host vGPU
资源/RM 状态，不是 Windows SYSTEM hive 或 guest 驱动错误。不要反复启动 VM；也
不要用 `setpci` bus reset、强制 `rmmod` 或删除 TPM/NVRAM。

先用对应 VM 的标准停止封装回收它记录的孤立 mdev；若另一个已停止 VM 留有
`run/mdev.uuid`，也只对那个实例运行同一命令。确认没有任何 QEMU/mdev 后，照抄：

```bash
./deploy/scripts/stop-vm.sh N
sudo ./deploy/host/recover-vgpu-gpu.sh --check --resume
sudo ./deploy/host/recover-vgpu-gpu.sh --resume
./deploy/scripts/start-vm.sh N --proxy
```

第一条 recovery 命令严格只读。第二条持有与 `gpu-mode`/mdev 生命周期相同的全局
锁，并再次检查无 mdev、无 NVIDIA/VFIO fd 使用者、目标 PCI 函数与 headless 模块
集合；它依次尝试 NVIDIA 默认 reset、干净模块重载、最后一次仅限 `flr` 的函数级
reset，并用 one-shot `nvidia-vgpud` 恢复 profile。脚本不会选择 bus reset、不会
强卸模块，也不会自动重启。若一次封装仍失败，保持所有 VM 关闭并停止操作；取得宿主
重启授权后再受控重启，不能把失败循环升级成 slot/bus reset。

### VM3 legacy 严格 GTX 1050 快照诊断（只读）

以下仅用于识别并安全回退历史自签 VM3，不是当前通过条件，也不得据此恢复 strict-A。
先在 guest 的本地 console 管理员 PowerShell 查硬件身份、驱动绑定和当前模式：

```powershell
$gpus = @(Get-CimInstance Win32_VideoController |
  Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' })
$gpus | Format-List Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode,
  AdapterRAM,CurrentHorizontalResolution,CurrentVerticalResolution

Get-CimInstance Win32_SystemDriver -Filter "Name='nvlddmkm'" |
  Format-List Name,State,StartMode,PathName

$smi = (Get-Command nvidia-smi.exe -ErrorAction Stop).Source
& $smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
```

历史快照曾记录：

- 只有一个当前 NVIDIA display controller；
- `Name` 是 `NVIDIA GeForce GTX 1050`；
- `PNPDeviceID` 以
  `PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028` 开头；
- `DriverVersion=31.0.15.3833`、`ConfigManagerErrorCode=0`，
  `nvlddmkm` 是 `Running`；
- `nvidia-smi` 报告 GTX 1050、538.33 和 2048 MiB；
- 脱离 RDP 后的本地 console 是 1920×1080 @ 59/60 Hz。

Host 侧只核对这个 VM 的稳定 UUID，不要用全局 `nvidia-257` 名称判定
per-mdev 结果：

```bash
vm=3
conf="/home/ubuntu/images/vms/${vm}/vm.conf"
uuid=$(sed -n 's/^VM_UUID=//p' "$conf")

sed -n '/^GPU_PROFILE=/p;/^SPOOF_MODE=/p;/^VGPU_MDEV_INTERNAL_PCI_IDENTITY=/p;
         /^VGPU_MDEV_FRL_ENABLED=/p;/^VGPU_PATCHED_DRIVER_VERSION=/p' "$conf"

sudo sed -n "/^\[mdev\.\"${uuid}\"\]/,/^\[/p" \
  /etc/vgpu_unlock/profile_override.toml
nvidia-smi vgpu -q
sudo journalctl -b -u nvidia-vgpu-mgr.service --no-pager |
  rg -i "$uuid|Virtual Device Id|Guest NVIDIA Driver Information|license state"
```

历史自签状态可能看到 `SPOOF_MODE=A`、内部 PCI 开关为 `1`、`frl_enabled=0`、
`pci_id=0x1C8111C0` 和 `pci_device_id=0x1C81`。Host 仍可能报
`License Status: Unlicensed`，控制面板可能没有 vGPU 激活页。这些只说明旧状态，
不是生产合规或已激活。Backing resource 仍是 `nvidia-257/2048MB`，它不会因 guest
显示 GTX 1050 而改变。当前支持路径应按下节恢复到正式签名 driver + B/Licensed。

### Basic Display Adapter / 分辨率减少的 off 安全恢复

如果历史 A 模式已暴露 `DEV_1C81`，但匹配驱动不合规或没有绑定，Windows
会回退到 Microsoft Basic Display Adapter，分辨率和可选模式随之减少。这时先修
驱动绑定，不要先强行添加自定义分辨率。

1. 让 Windows 完整关机，不要休眠或只在 guest 中点“重启”。无法操作桌面时，
   host 可先用 `./deploy/scripts/stop-vm.sh 3` 优雅关机。
2. 用通用安全驱动恢复入口：

   ```bash
   ./deploy/scripts/vmctl.sh driver-install 3
   ```

   封装只影响这次启动，不会改写只读 `vm.conf`；它让外层 PCI/per-mdev 身份回到
   native PnP，并用标准 VGA 隔离 mdev console，不带入 VM3 的 FRL 覆盖。
3. 封装会验证原生 538.33、完整关机并离线收敛。不要手工删除当前 NVIDIA device，
   也不要用未校验的 INF 覆盖 Driver Store。
4. 保持 off/B，不运行历史 GTX1050 strict ZIP/finish。先取得与目标 PnP/版本匹配的
   NVIDIA/Microsoft 正式生产签名驱动；在此之前不要恢复 A/internal/FRL marker。
   启动器会在磁盘干净离线时同步 EDID。第一次尚未建立 NVIDIA 显示器缓存时，普通
   vGPU 启动会拒绝首次枚举；统一使用上面的 `vmctl.sh driver-install 3`，让标准
   VGA 隔离窗口完成枚举和完整关机，下一次冷启动才进入 NVIDIA console。

如果 Code 0 已恢复且 NVIDIA 已列出 1920×1080，但当前模式仍不对，应在
本地 console 的 Windows 显示设置或 NVIDIA 控制面板中选择 1920×1080 @ 60 Hz；
不要根据 RDP 会话里的模式列表改 EDID。

### RDP 只用于临时调试

RDP 可用于传文件、运行一次性安装器和查看非显示会话状态，但不能作为
最终分辨率、模式列表或帧率验收环境。RDP 可引入 Microsoft Remote Display /
Indirect Display 设备，切换 Windows session，并通过编码和网络独立限制画面频率。

最终验收前应断开 RDP，回到 QEMU SDL 本地 console，再结合 guest
`Win32_VideoController` / `nvidia-smi` 和 host `nvidia-smi vgpu -q` 判定。WinRM
Session 0 可用来查静态 PnP identity、驱动版本和 Code 0，但它也不能代替
本地 console 的分辨率与动态帧率验收。

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

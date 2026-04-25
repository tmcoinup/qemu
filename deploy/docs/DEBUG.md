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

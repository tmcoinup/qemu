# G-11 vGPU 宿主快速配置

本文用于已经安装 VMate/QEMU 的宿主。默认全 1Q 池统一使用 R535；V100 需要 2Q 或
1Q+2Q 时，把 vGPU 18.4/R570 作为可选分支。两者的一键切换见
[`G11-V100-R535-R570-SWITCH.md`](G11-V100-R535-R570-SWITCH.md)。

## 当前受支持组合

| 物理 GPU | host / guest | 宿主策略 | 当前定位 |
| --- | --- | --- | --- |
| Tesla V100 | vGPU 16.4：`535.161.05` / `538.33` | equal 1024，仅 1Q | 默认全 1Q、与旧 RTX 宿主统一 |
| Tesla V100 | vGPU 18.4：`570.172.07` / `573.48` | mixed，发布 1Q 与 2Q；RM identity required | 可选分支；已实测单 1Q、单 2Q、1Q+2Q |
| RTX 2080 | R535：`535.161.05` / `538.33` | equal 1024 或 equal 2048 | 旧显卡稳定分支 |
| Tesla V100 | vGPU 19.5：`580.159.01` / `582.53` | name-only，RM identity off | 历史问题定位；不作为统一版本 |

宿主 CPU 与 Guest RAM 默认全部放开。所有 preset 都生成
`VGPU_HOST_CPU_NODE_BIND=all` 和 `VGPU_HOST_MEMORY_NODE_BIND=all`；`start-vm.sh`
使用 `numactl --cpunodebind=all --interleave=all`。两颗 CPU 都可参与调度，Guest RAM
也在两路内存 node 间交错分配，让 8 台 VM 实际使用全部内存条。缺少新键的旧配置也按
`all/all` 处理；只有两键同时显式设为 `local` 才回退到显卡本地 node。

这不会增加 Guest 看到的插槽、核心或线程数；`all` 也不保证一台小 VM 每时每刻同时
跑满两颗 CPU。V100 位于 node1 时，node0 内存页访问 V100 会经过两颗 CPU 间互联，
这是使用全部内存容量的正常代价。

不要把 R570 的 2Q 结果外推到 R535 或 R580，也不要混装其它小版本。任何切档前都必须
先关闭该物理 GPU 上的全部 VM，并确认 `/sys/bus/mdev/devices` 为空。

本项目不启用 Windows `testsigning`/`nointegritychecks`，不修改 BCD，也不安装测试签名
或自签名内核驱动。凭据只在运行时安全输入，不写入仓库或配置文件。

## 1. 只读识别宿主

```bash
lspci -Dnn | grep -Ei 'NVIDIA|VGA|3D|Display'
uname -r
cat /sys/module/nvidia/version
find /sys/bus/mdev/devices -mindepth 1 -maxdepth 1 -type l -print
./deploy/host/probe-vgpu-host.sh
```

V100/R570 还应确认官方 mixed mode：

```bash
sudo /usr/local/libexec/qemu-vgpu-mixed-mode status 0000:81:00.0
```

将示例 BDF 换成实际 V100。结果必须同时显示 capability `Supported`、mode `Enabled`。

## 2. 配置 V100/R570 1Q+2Q 混合池

```bash
./deploy/configure-g11-vgpu-host.sh \
  --preset v100-sxm2-16gb \
  --gpu 0000:81:00.0 \
  --fb-mode mixed \
  --cpu-node-bind all \
  --force

sudo ./deploy/host/install-vgpu-mixed-mode.sh --bdf 0000:81:00.0
```

如果 V100 是 PCIe、32GB、V100S 或 FHHL，按 `--help` 选择对应 preset，不能仅凭名称
猜容量。配置成功后复检两档映射：

```bash
./deploy/host/probe-vgpu-host.sh --fb-mb 1024
./deploy/host/probe-vgpu-host.sh --fb-mb 2048
```

R570 的受管配置应包含：

```text
VGPU_HOST_FB_MODE=mixed
VGPU_HOST_CPU_NODE_BIND=all
VGPU_HOST_MEMORY_NODE_BIND=all
VGPU_RESOURCE_PROFILE_1024=V100X-1Q
VGPU_RESOURCE_PROFILE_2048=V100X-2Q
VGPU_RM_FB_IDENTITY_MODE=required
```

这里的 `V100X` 只是 SXM2 16GB 示例；其它 V100 型号使用各自前缀。

## 3. 配置旧 RTX 2080/R535 固定档

整卡只能同时使用一个显存档。配置 1GB：

```bash
./deploy/configure-g11-vgpu-host.sh \
  --preset rtx2080-16gb \
  --gpu 0000:04:00.0 \
  --fb-mode equal \
  --tier 1024 \
  --force
```

配置 2GB 时只把 `--tier` 改为 `2048`。脚本发现运行中的 mdev 或固定档冲突会拒绝
继续；不要手工删除仍被 QEMU 占用的 mdev。

## 4. 创建 VM

V100/R570 mixed 池无需先切整卡档位，可以直接按 VM 请求 1GB 或 2GB：

```bash
./deploy/scripts/clone-from-base.sh win10-base 1 \
  --gpu-vram 1024 \
  --platform i7-4820k-p9x79-elpida-8g \
  --ssd-profile samsung-970-pro-512gb \
  --start

./deploy/scripts/clone-from-base.sh win10-base 2 \
  --gpu-vram 2048 \
  --platform i7-4820k-p9x79-elpida-8g \
  --ssd-profile samsung-970-pro-512gb \
  --start
```

也可以创建单台指定身份：

```bash
./deploy/scripts/vmctl.sh create 8 --gpu-profile gtx750_asus_1gb
./deploy/scripts/vmctl.sh create 9 --gpu-profile gtx750ti_msi_2gb
```

若仍提示“空池固定 2048MB”，说明正在读取旧 equal 配置；先确认配置文件来源，再用
本节第 2 步生成 mixed 策略。不要用环境变量绕过实时驱动/mode/容量门禁。

## 5. 双路 CPU 与全部内存傻瓜切换、验收

下面以 8 台实例、V100 BDF `0000:81:00.0`、待验收 `vm1` 为例；BDF 和 VM 编号必须
换成实机值。先在 Windows 内保存工作，然后**完整关闭全部 8 台 VM**。不要强杀 QEMU，
也不要手工删除仍被占用的 mdev。SDL 窗口“隐藏”不等于 VM 已关机；平时只调出一扇
窗口操作时，其余 7 个 QEMU/mdev 仍是活动状态，也必须正常关闭：

```bash
cd /home/ubuntu/projects/qemu
for VM_ID in {1..8}; do
  ./deploy/scripts/stop-vm.sh "$VM_ID" --graceful-only || exit 1
done
pgrep -af qemu-system-x86_64 || true
find /sys/bus/mdev/devices -mindepth 1 -maxdepth 1 -type l -print
```

最后两条必须没有 QEMU/mdev 输出。随后二选一生成配置：

1. 使用仓库脚本启动 VM：按本页第 2 节原命令重新生成策略；缺省即为
   `--cpu-node-bind all --memory-node-bind all`；
2. 使用 VMate 启动 VM：打开“修复中心 → 自动修复”，或运行本页第 7 节的
   `repair-env.sh`。V100 自动修复默认写入 `all`。

确认实际启动入口读取的文件。仓库脚本检查第一条，VMate 检查第二条：

```bash
grep -E '^VGPU_HOST_(CPU|MEMORY)_NODE_BIND=' deploy/host/vgpu-host.conf
sudo grep -E '^VGPU_HOST_(CPU|MEMORY)_NODE_BIND=' /etc/vmate/g11-vgpu-host.conf
```

应看到 CPU、MEMORY 两行都是 `all`。在第一个终端重新启动 `vm1`，该命令会一直跟随
SDL/QEMU 生命周期，不要等它返回：

```bash
./deploy/scripts/vmctl.sh start 1
```

保持 VM 运行，在第二个终端执行：

```bash
cd /home/ubuntu/projects/qemu
VM_RUN=$(./deploy/scripts/vmctl.sh path 1 | sed -n 's/^VM_RUN=//p')
QEMU_PID=$(cat "$VM_RUN/qemu.pid")
GPU_NODE=$(cat /sys/bus/pci/devices/0000:81:00.0/numa_node)

for CPU_LIST in /sys/devices/system/node/node*/cpulist; do
  printf '%s: ' "${CPU_LIST%/cpulist}"
  cat "$CPU_LIST"
done
grep '^Cpus_allowed_list:' "/proc/$QEMU_PID/status"
awk '/^Cpus_allowed_list:/{print $2}' "/proc/$QEMU_PID"/task/*/status | sort -u
sudo awk '/file=\/memfd:ram0/ {
  printf "%s", $2
  for (i=3; i<=NF; i++) if ($i ~ /^N[0-9]+=/) printf " %s", $i
  print ""
}' "/proc/$QEMU_PID/numa_maps"
```

验收含义：

- 默认共享启动（`--cpu-isolate=false`）中，QEMU 主线程和任务线程的
  `Cpus_allowed_list` 应覆盖两颗 CPU 的 node；显式开启 CPU isolation 会再次缩窄
  CPU/cpuset 范围，不属于本节 all/all 效果；
- `numa_maps` 的 ram0 映射应显示 `interleave:0-1`（node 编号以实机为准），并同时有
  `N0=...`、`N1=...`，证明两路内存条都在承载 Guest RAM；
- 启动终端应显示
  `vGPU NUMA policy: CPU nodes=all, RAM nodes=all (interleave)`。

已核对的 88 线程双路宿主是 node0=`0-21,44-65`、node1=`22-43,66-87`，V100 在
node1。默认共享启动时，主进程和任务线程预期 `Cpus_allowed_list: 0-87`；ram0 映射
预期为 `interleave:0-1`，同时出现 `N0=...`、`N1=...`。其它机器必须以本节实际
输出为准，不能照抄这些编号。

如需精确排除 CPU 隔离对验收输出的影响，可完整关机后仅做一次诊断启动：

```bash
./deploy/scripts/vmctl.sh start 1 --cpu-isolate=false
```

这时 `Cpus_allowed_list` 应直接包含两颗 CPU 的在线逻辑 CPU。验收后正常关机，再按
生产默认参数启动，不要把诊断参数写进 `vm.conf`。

## 6. 业务快速验收

每种新硬件或重装宿主至少完成：单开 1Q、单开 2Q、同时开 1Q+2Q。检查：

- Device Manager：`Status=OK`、`ConfigManagerErrorCode=0`；
- 1Q 为 GTX 750 / 1024 MiB，2Q 为 GTX 750 Ti / 2048 MiB；
- Guest driver 为正式签名 `573.48`，不使用任何签名绕过；
- Guest System 日志没有 Display 4101/TDR；
- 宿主日志没有 NVIDIA XID、PTE 或 display-copy timeout；
- 正常关机后 QEMU 退出，mdev 被回收。

2026-08-31 的物理 V100/R570 验收中，单 2Q 和 1Q+2Q 混合均实际执行 RAM_TYPE
`15 -> 8`；两台 Guest 均 Code 0、TDR=0，宿主错误计数为 0，并完成正常关机回收。

## 7. VMate 修复中心

VMate 启动时只做授权检查。宿主依赖、6.8 默认内核、R570 驱动、Hook、mixed mode、
mdev 和性能项由“修复中心 → 自动修复”统一处理。命令行等价入口：

```bash
sudo /opt/vmate/repair-env.sh g11 \
  --target-bdf 0000:81:00.0 \
  --model v100 \
  --target-uid "$(id -u)"
```

修复器不会自动重启。页面要求重启时手动重启，再执行一次自动修复完成收口。已有 VM
或 mdev 时它会拒绝重启 manager/切换分支，这是保护，不应绕过。

## 8. 回滚到单 node CPU/内存策略

先按第 5 节完整关闭全部 VM并确认 QEMU/mdev 为空，再用与当前显存分支完全相同的
preset、`--fb-mode` 和 `--tier` 参数重新生成配置，并同时加入：

```text
--cpu-node-bind local
--memory-node-bind local
```

确认实际配置的 CPU、MEMORY 两行均为 `local` 后重启 VM，再检查
`Cpus_allowed_list` 与 `numa_maps`。此时 CPU 和 RAM 都应限制在 GPU 所在 node。
VMate 再次执行自动修复会恢复两项默认 `all`。
回滚不涉及 Windows Guest，不改 BCD，不改签名策略，也不安装任何驱动。

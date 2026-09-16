# G-11：已有 VM 只换显卡、统一改为 2G

本教程用于本机 RTX 2080 16GB、host `535.161.05`、B/name-only、equal 显存池。
新封装 `deploy/scripts/resize-vgpu.sh` 默认只读预览；加 `--apply` 才备份并写入。
它不用于 V-11，也不把 V100/R570 的 mixed 策略迁移到这台机器。

## 旧封装生成单引号导致启动失败

如果已经改成 2GB，却在启动时看到 `unquoted value for GPU_NAME is malformed`，
原因是旧封装把显卡名称/VBIOS 写成了单引号，而启动器只接受双引号字符串。
这不代表硬件身份冲突，也不是 Windows 或驱动损坏。新版写入前会调用启动器
本身的配置解析器验证。

完整关闭这些 VM，更新到修复后的脚本，从普通用户终端运行：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/resize-vgpu.sh --repair-quotes 1 2 3
```

这条修复命令只规范显卡字段的引号，不改变任何字段值，也不写宿主配置；实例
目录归当前用户所有时无需 sudo。备份位于
`vms/control/gpu-quote-backups/<时间-随机后缀>/`。源码之外的启动入口可通过
`--host-config /etc/gmate/g11-vgpu-host.conf` 指定只读宿主策略。
这次格式修复本身不需要重新安装驱动或客体身份包。若刚从 1GB 升到 2GB，
还需要完成下节的安全枚举；引号解析通过不等于 Windows 已完成新显卡绑定。
原 1GB→2GB 迁移日志仍可用于回滚：恢复器只额外认可这一种已知的引号修正，
仍会拒绝覆盖后续对其它硬件配置的修改。

## 已改成 2G，却提示“Windows 尚未安装认证 GRID 驱动”

本次日志中，旧的 `VEN_10DE&DEV_1E30&SUBSYS_132510DE` 被跳过，而新 2Q 应为
`VEN_10DE&DEV_1E30&SUBSYS_132610DE`。这表示新 PnP 实例还没有通过驱动绑定认证，
不能据此断定 Driver Store 中没有 GRID。旧提示把这两件事混为一谈，现已修正。
旧教程也遗漏了首次安全枚举步骤：R535 必须先通过下述窗口绑定新卡，不能直接
启动正常 vGPU console，更不能用 `--no-monitor-sync` 绕过保护。

VM1 当前直接运行下面一条命令，**不要在整条命令前加 sudo**：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/vmctl.sh gpu-rebind 1 --proxy --cpu-isolate=false --memory-prealloc=false
```

1. 在宿主终端按提示输入 sudo 密码，脚本只临时取得票据。
2. 弹出的窗口临时使用标准 VGA；新 NVIDIA vGPU 仍挂载，但 `display=off`。
   登录原 Windows，等待设备管理器识别 NVIDIA 显卡。未出现时，选择
   **操作 → 扫描检测硬件改动**。此时暂时多出标准 VGA 属于显卡迁移窗口。
3. 保存工作，在 Windows CMD 输入 `shutdown.exe /s /t 0`，等窗口自然退出。
   不要直接关闭窗口，不要用休眠；此阶段先不要安装新身份包。
4. 脚本会离线校验新 PnP 绑定、正式驱动 INF/CAT 和显示模式。全部通过才恢复
   普通 vGPU 窗口，此后更新下文对应的客体身份包。

VM2、VM3 把命令里的 `1` 分别换成 `2`、`3`，逐台完成。也可直接运行本次交付的
`Rebind-VM1.sh`、`Rebind-VM2.sh`、`Rebind-VM3.sh`，位于
`/home/ubuntu/images/staging/VM1-VM2-VM3-2G-20260908/`。

Windows 会为新设备选择 Driver Store 中匹配的驱动，所以先尝试复用原正式签名
GRID 包。[Microsoft：Windows 如何选择设备驱动](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/how-windows-selects-a-driver-for-a-device)。
封装不会运行驱动安装器，也不修改 `vm.conf`；前后会验证整个配置的 SHA256。
若安全枚举后仍返回 12/13，它会保持 VM 停止，此时才进一步检查是否缺少匹配的
正式驱动，并使用提示中的 `vmctl.sh driver-install` 修复；该自动安装入口另需
通过安全运行时环境提供 `GUEST_PASS`，不要把密码写到脚本或命令历史里。
返回 11 表示 Windows 仍处于休眠/未干净关机，按休眠恢复教程处理后再试。

只看封装步骤可追加 `--dry-run`；只完成绑定和离线校验、暂不普通启动可追加
`--no-start`。预览和回归测试不等于实际 Windows 已通过认证。

## 已能正常启动，但设备管理器仍显示 GTX 750

普通 vGPU 窗口能够启动，只说明 2Q 的正式驱动绑定和离线显示校验已经通过。
Windows 内的旧身份任务仍可能发布 `GTX 750 / 1024MB`；不会因为宿主改了
`vm.conf` 就自动改成另一套客体身份包。实际分配应以宿主
`nvidia-smi vgpu -q` 的 `FB Memory Usage / Total: 2048 MiB` 为准。

本次三台均由 `clone-from-base.sh g-1 ID` 创建。`g-1` 的 schema-8 制作记录
明确使用 `licensed-portable-system-nvapi-two-boot-v1`：克隆首次初始化会安装
SystemNvapiProjection。因此这三台使用 **各自的新系统身份包** 升级，
不要重新运行母盘中的旧 VgpuPortable.exe，也不要重新克隆或重装 GRID。

旧版系统身份安装器不支持这次已有 VM 的完整换卡更新：预检要求显卡已经显示
新名称；克隆主机名状态又绑定旧包编号；字符串替换也只处理 GRID 名称。
新版允许安装/身份刷新阶段接收旧名称，仍严格检查 UUID、唯一 NVIDIA PnP、
Code 0、正式签名与驱动版本。它精确更新已发布的旧型号，通过 SetupAPI 更新
当前显卡 FriendlyName，并为同一个 VM 更新主机名状态的包编号，不重命名系统。
因此应使用本次重新生成的包，不能继续安装早先生成的旧版 2G ISO。

操作步骤：

1. 先让对应 VM 按原命令正常启动。`driver-install` 窗口含临时标准 VGA，
   不能用于安装系统身份包。若提示 `Display；当前数量=2`，先在 Windows 内执行
   `shutdown.exe /s /t 0`，等安全枚举封装切回普通窗口；若终端已返回命令行，
   则用原 `start-vm.sh ID --proxy --cpu-isolate=false --memory-prealloc=false`
   命令启动。普通窗口只应有一张 NVIDIA 显卡，不要卸载临时 VGA 的驱动来绕过检查。
2. 在宿主执行本次交付目录中的 `Mount-Identity-VM1.sh`；VM2、VM3 使用各自编号
   的脚本。入口会先检查当前是否为普通单 vGPU 模式，再挂载对应 VM 的新 2G
   身份光盘；安全枚举模式会直接在宿主提示并停止挂载。
3. Windows 中打开“此电脑”里的光驱，先保存工作，再双击
   **Run-As-Administrator.cmd** 并确认 UAC。
4. 安装器会更新用户态身份组件和刷新任务，自动弹出光盘并重启 Windows。
   重启后等约一分钟，让启动时的身份刷新和验证完成，再打开设备管理器。
   目标应为 **NVIDIA GeForce GTX 750 Ti**，NVAPI 身份显存为 **2048MB**。
5. 如需手动验收，可重新挂载同一个新包，运行 `Verify-As-Administrator.cmd`；
   验收通过后在宿主执行 `vmctl.sh cdrom ID eject` 移除光盘。

三台的包分别绑定原 VM UUID、MSI/ASUS/Gigabyte 的目标 GPU 和各自原显示器。
主机名、VM UUID、MAC、CPU、主板、内存、磁盘、显示器序列号不随本次更新重建。
安装失败时查看 Windows 的 `C:\Windows\Temp\G11-System-NVAPI-Install.log`，
验收日志为 `C:\Windows\Temp\G11-System-NVAPI-Verify.log`。

## 本次 VM1、VM2、VM3 的完整显卡方案

| VM | 原配置 | 目标配置 |
|---|---|---|
| 1 | MSI GTX 750 1GB | `gtx750ti_msi_2gb` |
| 2 | ASUS GTX 750 1GB | `gtx750ti_asus_2gb` |
| 3 | Gigabyte GTX 750 1GB | `gtx750ti_gigabyte_2gb` |

每台实际分配 2048MiB，三台共 6144MiB。显卡按目录更换完整型号、子系统、VBIOS、
时钟和显存信息；不能把 GTX 750 的 1GB 行随手改成 2048。
显卡之外，UUID、MAC、CPU、主板及序列号、系统内存、SSD、显示器及序列号、USB
身份与其它配置内容逐字保留。脚本不会打开或改写 qcow2、NVRAM、TPM 状态。

不要用 `create-vm.sh --force` 做本次升级：该入口会生成新的 UUID、MAC 和多个
硬件序列号。只换显卡使用本页的专用入口。

## Windows 和软件是否重装

| 项目 | 操作 |
|---|---|
| Windows、应用、游戏 | 无需重装，继续用原系统盘 |
| NVIDIA GRID 内核驱动 | 先保留原版正式签名 538.33；1Q/2Q 都走此驱动栈。先用 `gpu-rebind` 安全枚举新卡，完整关机认证后再普通启动；无法匹配/绑定时才修复安装 |
| 仅安装了 VgpuPortable | 通用 EXE 无需按 VM 重新打包；换卡启动后重新运行一次，更新原先固定为 1GB 的身份与刷新任务。目录摘要不兼容的旧 EXE 才需更新 |
| 已安装系统 NVAPI 投影 | 给每台生成并安装新的 `SystemNvapiProjection` 包；它绑定 VM UUID 和 GPU/显示器配置，旧启动任务会重发旧显卡合同 |
| DLS 授权 | 保留已有 token 和服务器配置，重新验收 `Licensed`；不要重新制作或传播 token |

**已安装系统 NVAPI 投影时，不要直接叠加运行旧 VgpuPortable。** 当前 Portable
安装器要求系统 NVAPI 为 NVIDIA 正式签名原件，会拒绝已替换成用户态投影 DLL 的
系统。此时使用新系统投影包进行受校验升级；它支持验证旧收据和原件后更新。
若只是 Portable，按上一行重跑通用 EXE。三台宿主目录中有旧系统投影包，不等于
已证实三台 Windows 都安装了它；客体内可用下面命令确认：

```powershell
Get-ChildItem 'C:\ProgramData\G11\SystemNvapiProjection\receipts\*-validated.json'
```

全过程不启用 testsigning/nointegritychecks，不改 BCD，不安装测试签名或自签名
内核驱动。系统投影更新的是用户态组件。

## 第一步：保存工作，完整关机

从三台 Windows 内正常关机，等待 QEMU 退出和 mdev 回收。窗口隐藏、暂停、
休眠都不算完整关机。宿主预检会拒绝活动 QEMU、mdev 或生命周期锁。
本机的 equal 策略必须整池切档，同一 GPU 上不能留下仍要运行的 1GB 配置。
[NVIDIA 16.x 对同一物理 GPU 的 framebuffer 约束](https://docs.nvidia.com/vgpu/16.0/grid-vgpu-user-guide/index.html#valid-time-sliced-virtual-gpu-configurations-on-a-single-gpu)。

## 第二步：预览，只看改动

本机源码、GMate 和旧 VMate 路径都存在。下面把这些启动入口的显存档一起更新，
各文件原有的画面周期、CPU/内存策略和其它键继续保持原值。别的宿主应只填写该
VM 池实际存在且使用的路径，不能照抄不存在的文件。

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/resize-vgpu.sh \
  --vm 1:gtx750ti_msi_2gb \
  --vm 2:gtx750ti_asus_2gb \
  --vm 3:gtx750ti_gigabyte_2gb \
  --host-config /home/ubuntu/projects/qemu/deploy/host/vgpu-host.conf \
  --host-config /etc/gmate/g11-vgpu-host.conf \
  --host-config /etc/vmate/g11-vgpu-host.conf \
  --host-config /opt/gmate/deploy/g11/host/vgpu-host.conf \
  --host-config /opt/vmate/deploy/g11/host/vgpu-host.conf
```

输出必须只有显卡字段及宿主的三个档位字段，末尾是三台 × 2048MiB。
每个文件会输出非显卡内容的 SHA256；应用前后这些字节必须相同。

## 第三步：应用

在上面命令前加 `sudo`、末尾追加 `--apply`，在宿主终端安全输入 sudo 密码。
无需把密码放进命令、仓库、脚本或文档。当前普通用户不能写 `/etc/gmate` 等
root 所有的配置；封装会在任何配置写入前检查所有目标的权限，避免只改一半。

本次还提供了仓库外的一键入口：

```bash
bash /home/ubuntu/images/staging/VM1-VM2-VM3-2G-20260908/Apply-2G.sh
```

该入口先显示方案，再通过 sudo 执行应用，随后按实际新配置生成三台的系统
NVAPI 包。它不自动启动 VM。备份及精确回滚日志在：

```text
/home/ubuntu/images/vms/control/gpu-resize-backups/<时间-随机后缀>/
```

备份包括新旧配置、摘要和原所有者/权限。发布遇到可捕获错误会恢复已写入的
配置；主机断电或进程被强杀时，用下方日志回滚。不要手工复制到一半后启动 VM。

## 第四步：安全枚举新显卡

按上方 `gpu-rebind` 教程逐台完成新显卡绑定、完整关机和离线认证。
不能跳过这一步直接从原 GMate/VMate 界面普通启动；旧驱动包可复用并不代表
新 2Q 的 PnP 绑定已经存在。成功后封装会自动打开普通 vGPU 窗口。

## 第五步：更新客体身份

系统投影包可以由一键入口生成，也可在应用完成后从普通用户终端单独生成：

```bash
for vm_id in 1 2 3; do
  ./deploy/package-system-nvapi-projection.sh "$vm_id" || break
done
```

输出位于各 VM 的 `packages/SystemNvapiProjection`。每个目录/ISO 只给对应 VM
使用，不能把 VM1 的包给 VM2。在上一步认证通过后的普通 vGPU 窗口中，将新输出
目录完整复制进去，或通过 `vmctl.sh cdrom ID mount /绝对路径/新包.iso` 挂载。
确认是 **新 2GB 包** 后，双击 `Run-As-Administrator.cmd`，保存工作后允许它重启。
等待一两分钟，再运行 `Verify-As-Administrator.cmd`。

只有 Portable 且系统 NVAPI 仍是 NVIDIA 原件的 VM，可以改为双击同一份
`VgpuPortable.exe`，等待 `INSTALL PASS` 后正常完整关机、重新启动。

## 第六步：验收

在客体运行：

```powershell
Get-CimInstance Win32_VideoController |
  Format-List Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode
nvidia-smi --query-gpu=memory.total --format=csv,noheader
nvidia-smi -q
```

确认实际显存属于 2048MiB 档（可用显存/预算可能扣除预留）、设备 Code 0、驱动仍为
`31.0.15.3833`、DLS 为 `Licensed`；系统投影的 32/64 位验证通过。宿主也可用
`nvidia-smi vgpu -q` 复核每台分配。不要只凭软件显示名称判断实际显存。
正常启动时显卡 PnP 的 subsystem 从 1Q 的 `132510DE` 变为 2Q 的 `132610DE`
属于本次显卡变更；其它硬件身份保持原值。最后运行原应用验证正常显示和 3D。

## 回滚

先完整关闭三台，再用应用时打印的实际备份目录执行：

```bash
sudo ./deploy/scripts/resize-vgpu.sh --restore /实际备份目录
```

回滚同时恢复宿主显存档和各 VM 的原显卡配置。若迁移后有人另改了这些配置，
封装会拒绝覆盖。若 Windows 已安装新系统投影，回到 1GB 后还要按恢复后的
`vm.conf` 用新版 `package-system-nvapi-projection.sh ID` 重新生成并安装 1GB 包，
让更新后的安装器处理显卡身份和包编号变化；不要使用不支持换卡升级的旧安装器。
只有 Portable 的则重跑通用 EXE。该回滚不回退游戏和系统数据。

GMate/VMate 的旧“修复环境”脚本可能重新生成 1GB 默认宿主策略；以后执行修复
或重装宿主包后，先复核实际配置仍为 equal/2048，再启动这三台。

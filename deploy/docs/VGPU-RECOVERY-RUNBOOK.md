# G-11 授权 + 显示器：傻瓜恢复

只看本页即可完成日常恢复。授权和显示器是两件事：

| 问题 | 在哪里处理 | 唯一入口 |
|---|---|---|
| NVIDIA 显示 `Unlicensed` /“管理许可证” | Windows guest | 私有 `VgpuPortable.exe` |
| 显示“通用即插即用监视器”或分辨率不对 | Linux host，VM 关机时 | `vmctl.sh monitor` |

授权 EXE 不会修改显示器；host 显示器同步也不会申请授权。

## 已修好的 VM：平时只启动

```bash
cd /home/ubuntu/projects/qemu
sudo -v
./deploy/scripts/vmctl.sh start <vm_id>
```

不要每次开机都重装授权或强制同步显示器。

## 同时修复授权和显示器

### 1. 在 Windows 里运行一个 EXE

把这个文件安全复制进目标 Windows：

```text
/home/ubuntu/images/staging/VgpuPortableLicensed/VgpuPortable.exe
```

右键“以管理员身份运行”，等待窗口同时出现：

```text
[vGPU identity] INSTALL PASS
License: Licensed
Power: hibernation/Fast Startup disabled
```

任何一项不是 PASS 都不要继续。这个 EXE 已包含 guest 授权脚本，不需要再手工复制
`.tok`，也不要在 NVIDIA 控制面板填写主/次服务器。

只有 DLS token 更新后才需要在 host 重建 EXE：

```bash
cd /home/ubuntu/projects/qemu
./deploy/package-vgpu-one-click.sh --with-license-token --replace-licensed
```

当前 DLS 是 `dls.gvmates.com:443`。token 是仓库外凭据；不要打印、提交或放进通用
base。打包器会先验证并保留旧私有包。

### 2. 完整关机

在 Windows 管理员 PowerShell 执行：

```powershell
shutdown.exe /s /f /t 0
```

等 QEMU 窗口自然退出。若 Windows 正在配置更新，继续等，不要强停。

### 3. 在 host 同步显示器并冷启动

```bash
cd /home/ubuntu/projects/qemu
sudo -v
./deploy/scripts/vmctl.sh monitor <vm_id> --force
./deploy/scripts/vmctl.sh start <vm_id>
```

封装会自动按 VM 的资源档选择原生生产驱动端点：1GB/`nvidia-256` 使用
`SUBSYS_132510DE`，2GB/`nvidia-257` 使用 `SUBSYS_132610DE`，不需要手工填写 PnP
编号。同步成功必须出现 `EDID_OVERRIDE 写入`、`NVIDIA NV_Modes 命中 1` 和
`hivex commit 完成`；出现 `WAIT` 时不要当作成功。这个 host 命令只修改关机磁盘
缓存；Windows 启动后由私有系统身份任务通过 SetupAPI 发布设备管理器实时名称。

密码只在 `sudo` 提示中输入，不写入仓库、配置文件或命令参数。

### 4. 只验收这三项

Host：

```bash
nvidia-smi vgpu -q | grep -E 'Guest Driver Version|License Status|Frame Rate Limit'
```

必须看到 GRID guest driver `538.33` 和 `License Status: Licensed`。

Windows 本地 SDL/GTK 窗口：

```powershell
Get-PnpDevice -Class Monitor | Format-Table FriendlyName,Status
```

设备名和分辨率必须符合该 VM 的 `MONITOR_PROFILE`。RDP 的 Remote Display Adapter
和动态分辨率不算验收。

VM9 的结果应为：

```text
AOC 2470W
1920×1080 @ 60 Hz
License Status: Licensed
```

## 只在提示休眠/Fast Startup 时

若同步器报告 `hibernated`、`Fast Startup` 或 dirty，不要强挂载磁盘：

```bash
cd /home/ubuntu/projects/qemu
sudo -v
./deploy/scripts/recover-hibernated-vm.sh <vm_id>
```

在弹出的本地 Windows 管理员窗口执行：

```bat
powercfg.exe /hibernate off
shutdown.exe /s /f /t 0
```

等窗口自然退出；封装会自动完成显示器同步。不要把恢复命令整体写成 `sudo ...`。

## 失败时只看这四条

| 现象 | 处理 |
|---|---|
| 新 DLS 443 可通但仍 `Unlicensed` | 使用新 token 重建私有 EXE，再在 guest 运行；旧 EXE 仍带旧 token |
| 显示器仍是“通用即插即用监视器” | 先确认首启初始化已成功；若有 `clone-initialization-error.txt`，管理员运行 `Retry-Clone-Initialization.cmd`。再完整关机执行 `vmctl.sh monitor N --force` 并正常启动，等待 SYSTEM 身份任务 |
| Windows 正在配置更新 | 等它完成；不要关闭 QEMU 或强停 VM |
| NVIDIA 是 Basic Display Adapter / Code 28/43 | 这是驱动绑定问题，不是授权或 EDID；转到 `DRIVER-INSTALL.md` |

禁止修改 BCD，禁止开启 `testsigning` / `nointegritychecks`，禁止安装测试签名或
自签名内核驱动，也不要删除 Driver Store、强删 `hiberfil.sys` 或用 `ntfsfix` 清状态。

技术细节只在排障时看：[`VGPU-LICENSING.md`](VGPU-LICENSING.md)（token/DLS）和
[`G11-MONITOR-POOL.md`](G11-MONITOR-POOL.md)（显示器 profile/EDID）。

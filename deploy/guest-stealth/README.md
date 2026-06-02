# guest-stealth —— Win10 客机本地一键 GPU spoof 重对齐

把 `deploy/scripts/respawn-stealth.ps1`（原本要连 host HTTP 拉脚本）改写成
**纯本地、一键、可打包进基础镜像**的版本。断网 / host 关机也能在客机里直接跑。

> 📖 完整 VM 装机/克隆流程里它怎么定位、什么时候用，见
> [`deploy/docs/VM-WORKFLOW.md`](../docs/VM-WORKFLOW.md) 的「客机本地一键重对齐 GPU」一节。
> 本文件只讲这个目录本身。

## 文件

| 文件 | 作用 |
| --- | --- |
| `respawn-stealth.bat` | **一键入口**：双击 → 自动 UAC 提权 → 跑下面的 `.ps1` |
| `respawn-stealth-local.ps1` | 本地主逻辑：定位本机 `apply-gpu-spoof.ps1` → `-AutoDetect` → 清 RunOnce → 重启 |
| `package.sh` | 在 host 上打一个**完全自带依赖**的发布目录 `dist/`（把 `apply-gpu-spoof.ps1` 一并拷进来） |

## 它做什么

委托给本机的 `apply-gpu-spoof.ps1 -AutoDetect`：

1. 按当前显卡 **PCI SUBSYS** 自动选定伪装型号（GPU 池映射表，clone 后型号变了也能跟上）
2. 重写 `Class\{4d36e968}\NNNN` + `Enum\PCI` + `Enum\DISPLAY` 注册表覆盖
   → `Win32_VideoController` / 设备管理器 / 显示器名 全部对齐伪装型号
3. 装开机自刷计划任务（`StealthGPU-RefreshName` / `StealthGPU-ForceDisplayFreq`）
4. 清掉可能残留的 `RunOnce\*StealthRespawn`（旧 clone 注入的 HTTP 入口，本地版用不到）
5. 完成后重启让覆盖生效

## 跟原 `respawn-stealth.ps1` 的区别

- **不连 host**：原版 `irm http://192.168.30.33:8765/... | iex` 拉 `apply-gpu-spoof.ps1`；
  本版从本机磁盘定位（**无任何网络依赖**）。
- 多了 UAC 自提权、管理员自检、退出码判断（失败不盲目重启）、`-NoReboot` 开关。

## 一键用法（在客机里）

直接双击 **`respawn-stealth.bat`**，点「是」过 UAC，等它跑完自动重启即可。

> 也可手动跑（管理员 PowerShell）：
> ```powershell
> powershell -NoProfile -ExecutionPolicy Bypass -File .\respawn-stealth-local.ps1
> powershell -NoProfile -ExecutionPolicy Bypass -File .\respawn-stealth-local.ps1 -NoReboot
> ```

## 打包进基础镜像

`apply-gpu-spoof.ps1` 的定位顺序：

1. **与 `respawn-stealth-local.ps1` 同目录**
2. `C:\stealth\apply-gpu-spoof.ps1`（`install-stealth.sh` 装机后必然存在）
3. `C:\ProgramData\StealthGPU\apply-gpu-spoof.ps1`

所以有两种打包方式，任选其一：

- **省事**：base 里 `C:\stealth\apply-gpu-spoof.ps1` 已经有了，只要把
  `respawn-stealth.bat` + `respawn-stealth-local.ps1` 拷进客机任意目录
  （例如 `C:\stealth\`）即可，会自动找到 `C:\stealth\apply-gpu-spoof.ps1`。

- **完全独立**：在 host 上先 `bash package.sh`，把生成的 `dist/` 整个目录
  （含 `apply-gpu-spoof.ps1`）拷进客机，放哪都能跑，不依赖 `C:\stealth`。

把目录拷进客机磁盘的常用手段：`scp` / virtio-9p 共享，或封 base 前在客机里放好。
封好 base 后用 `clone-from-base.sh` 克隆出来的实例都自带这份一键脚本。

> 注：`clone-from-base.sh` 的自动首启重对齐（autounattend `FirstLogonCommands`
> Order=10）仍走 host HTTP，本目录**不改动**那条既有链路；本目录是给你
> 「在客机里手动随时重跑」用的本地后备 / 主力入口。

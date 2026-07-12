# guest-stealth —— Win10 客机本地一键 GPU spoof 重对齐

把 `deploy/scripts/respawn-stealth.ps1`（原本要连 host HTTP 拉脚本）改写成
**纯本地、一键、单 EXE、可打包进基础镜像**的版本。断网 / host 关机也能在客机里直接跑。
现在 clone 首启也走本地 EXE：`FirstLogonCommands` 会在 OOBE 后首次登录时执行
`D:\工具\respawn-stealth.exe --firstlogon` 一次，不再依赖固定 host IP 或 HTTP 拉取。

> 📖 完整 VM 装机/克隆流程里它怎么定位、什么时候用，见
> [`deploy/docs/VM-WORKFLOW.md`](../docs/VM-WORKFLOW.md) 的「客机本地一键重对齐 GPU」一节。
> 本文件只讲这个目录本身。

## 文件

| 文件 | 作用 |
| --- | --- |
| `dist/respawn-stealth.exe` | **发布入口**：单文件拷进 guest，双击 → UAC 提权 → 释放内嵌脚本 → 执行 |
| `build-exe.sh` | 在 host 上用 MinGW 生成上面的 Windows PE64 EXE |
| `respawn-stealth.bat` | 历史脚本入口：源码调试用，发布包默认不再带它 |
| `respawn-stealth-local.ps1` | 本地主逻辑：定位本机 `apply-gpu-spoof.ps1` → `-AutoDetect` → 清 RunOnce → 重启 |
| `package.sh` | 在 host 上打一个默认只含 `respawn-stealth.exe` 的发布目录 `dist/` |

## 它做什么

委托给本机的 `apply-gpu-spoof.ps1 -AutoDetect`：

1. 按当前显卡 **PCI SUBSYS** 自动选定伪装型号（GPU 池映射表，clone 后型号变了也能跟上）
2. 重写 `Class\{4d36e968}\NNNN` + `Enum\PCI` + `Enum\DISPLAY` 注册表覆盖
   → `Win32_VideoController` / 设备管理器 / 显示器名 全部对齐伪装型号
3. 普通手动模式会装开机自刷计划任务；`--firstlogon` 模式会跳过并清理这些任务
4. 清掉可能残留的 `RunOnce\*StealthRespawn`（旧 clone 注入的 HTTP 入口，本地版用不到）
5. 完成后重启让覆盖生效

## 跟原 `respawn-stealth.ps1` 的区别

- **不连 host**：原版 `irm http://192.168.30.33:8765/... | iex` 拉 `apply-gpu-spoof.ps1`；
  本版从本机磁盘定位（**无任何网络依赖**）。
- 多了 UAC 自提权、管理员自检、退出码判断（失败不盲目重启）、`-NoReboot` 开关。
- 发布形态变成**单 EXE**：`apply-gpu-spoof.ps1` 和本地 respawn 脚本在构建时嵌入 EXE；
  guest 里只需要拷一个文件。EXE 运行时调用 Windows 10 自带的 `powershell.exe` 执行内嵌脚本，
  不需要 Python、.NET SDK、MinGW 或其它额外发布环境。
- EXE 每次运行都会先弹一个确认框。注意：如果 guest 登录的是内置 `Administrator`
  且 UAC/管理员批准模式关闭，Windows 本身不会弹系统 UAC；这时看到的是 EXE 自己的确认框。
  普通管理员账号开启 UAC 时，则会先弹系统 UAC，再弹 EXE 确认框。
- FirstLogon 自动执行时用 `--firstlogon` / `--no-confirm` 跳过应用层确认框，
  并跳过持久计划任务，避免后续每次开机重复执行；手动双击仍会确认。

## 一键用法（在客机里）

host 上先打包：

```bash
bash deploy/guest-stealth/package.sh
```

然后只把 **`deploy/guest-stealth/dist/respawn-stealth.exe`** 拷进 guest 任意位置，
双击运行，点「是」过 UAC，等它跑完自动重启即可。

> 源码调试时也可手动跑（管理员 PowerShell）：
> ```powershell
> powershell -NoProfile -ExecutionPolicy Bypass -File .\respawn-stealth-local.ps1
> powershell -NoProfile -ExecutionPolicy Bypass -File .\respawn-stealth-local.ps1 -NoReboot
> ```

## 打包进基础镜像

推荐把 `respawn-stealth.exe` 直接放进 `D:\工具\`。EXE 每次运行都会把内嵌的
`respawn-stealth-local.ps1` 和 `apply-gpu-spoof.ps1` 释放到
`C:\ProgramData\StealthGPU\respawn-exe\`，并用同目录 payload 执行，所以发布时不依赖
`C:\stealth\apply-gpu-spoof.ps1` 是否存在。

脚本版 `respawn-stealth-local.ps1` 的 `apply-gpu-spoof.ps1` 定位顺序仍保留：

1. **与 `respawn-stealth-local.ps1` 同目录**
2. `C:\stealth\apply-gpu-spoof.ps1`（`install-stealth.sh` 装机后必然存在）
3. `C:\ProgramData\StealthGPU\apply-gpu-spoof.ps1`

如果确实要恢复旧的脚本发布包，可在 host 上运行：

```bash
INCLUDE_LEGACY_SCRIPTS=1 bash deploy/guest-stealth/package.sh
```

把 EXE 拷进客机磁盘的常用手段：`scp` / virtio-9p 共享，或封 base 前在客机里放好。
固定放到 `D:\工具\respawn-stealth.exe`；clone 自动首启只执行这个路径。

> 注：clone 自动首启已经改成本地 EXE 链路；旧 HTTP 版不再用于 clone 首启。

# ACE/腾讯反作弊兼容路径（浅层 stealth）

> 实测 2026-04-26：DNF / WeGame 等腾讯系 ACE 反作弊在此配置下连续 1 小时游戏未触发
> `13-131106-0`。**这是当前 VM2 的工作配置，ACE 类游戏首选这条路径。**

---

## 思路

ACE 13 系列环境异常会重点扫：

| 扫描点 | 浅层方案 |
|---|---|
| **黑名单内核驱动**（WinRing0 / RTCore64 / GPU-Z driver / EneIo / iqvw64 等） | 不装这类工具；保持 `Get-CimInstance Win32_SystemDriver` 全是 MS/AMD/Intel/NVIDIA |
| **测试签名 / nointegritychecks** | `bcdedit testsigning No`，无 `nointegritychecks` |
| **bootmgr.efi / winload.efi 哈希** | 原版微软签名，无 EfiGuard 替换 |
| **PatchGuard 状态** | 启用，无 patch |
| **Trusted Root 异常根证书** | 只保留 Microsoft / 真 NVIDIA / 真 AMD 等公认 CA，无伪造根 |
| **驱动 Authenticode 签名链** | viogpudo 走 stock virtio-win = MS Hardware Compatibility Publisher 链 |
| **Hyper-V / VBS / HVCI** | 全关 |

GPU-Z / WMI / Device Manager 想看到「NVIDIA GeForce GTX 1050」，靠的是：

1. **PCI Subsystem ID**：QEMU 启动器已把 `x-pci-sub-vendor-id=0x10DE,x-pci-sub-device-id=0x1C81` 打到 virtio-vga 上
2. **注册表覆盖**：`apply-gpu-spoof.ps1` 改 `Class\{4d36e968-...}` 和 `Enum\PCI\...` 下的 `DeviceDesc / FriendlyName / DriverDesc / DEVPKEY`
3. **NVAPI shim**：`nvapi64.dll` 替换 `C:\Windows\System32\nvapi64.dll`，让查 NVIDIA 私有接口的程序（GPU-Z、N卡控制面板检测脚本）拿到伪造的 1050 信息

整条链不需要任何非 WHQL 驱动、非微软的根证书或 boot chain 修改。

---

## 一次性宿主机准备

```bash
# QEMU stealth 构建
deploy/tools/build.sh

# 桥接（让 guest 拿宿主 LAN DHCP IP）
sudo UPLINK=enp5s0 deploy/scripts/setup-bridge.sh

# stock virtio-win 资源（已 ship 在 deploy/scripts/stock-viogpudo/）
ls deploy/scripts/stock-viogpudo/
#   viogpudo.sys  viogpudo.cat  viogpudo.inf

# HTTP 服务器（一次起好，多 VM 共用）
cd deploy/scripts && python3 -m http.server 8765 --bind 192.168.30.<host-ip-on-br0> &
```

---

## 装一个新 VM2

```bash
# 1. 装系统（autounattend 自动跳过 OOBE）
DISPLAY=:1 EXTRA_ISO=/home/ubuntu/images/autounattend-vm2.iso \
    deploy/scripts/start-vm.sh 2 --iso=/home/ubuntu/images/win10_ltsc.iso

# 2. 装完进桌面后（Administrator / 123456 自动登录），管理员 PowerShell 跑：
#    irm http://192.168.30.<host>:8765/shallow-stealth.ps1 | iex
#
#    会做：
#      - 拉 stock viogpudo (MS-WHQL 签名)
#      - pnputil /add-driver /install 绑到 PCI 1AF4:1050
#      - 拉 apply-gpu-spoof.ps1 + nvapi64.dll
#      - 跑 spoof 改注册表为 NVIDIA GeForce GTX 1050
#      - 装 StealthGPU-RefreshName 计划任务（开机后 2s 重新覆盖）
#      - reboot

# 3. 重启完直接进游戏
```

---

## 日常启动

VM2 第一次跑完 shallow-stealth.ps1 之后，每次只需要：

```bash
DISPLAY=:1 deploy/scripts/start-vm.sh 2
```

不带任何 `INSTANCE=` / `BRIDGE=` / `STABLE_DISPLAY=` / `GPU_SELFSIGNED=`：

- BRIDGE 默认 `br0`
- STABLE_DISPLAY 默认 `1`（virtio-vga，无 GL，ACE 友好，且不会因为 virgl bug 长时间运行 BSOD）
- GPU_SELFSIGNED 默认 `0`（PCI 主 ID 留 1AF4:1050，stock 驱动可绑）
- CPU_MODEL 从 `vms/<N>/profile` 读取（首次随机生成，AMD Ryzen3-1200/2300X 或 Intel i3-9100F/G6400/G5400 等）

---

## 验证

进 VM 跑：

```powershell
# Win32_VideoController
Get-CimInstance Win32_VideoController | Select Name,VideoProcessor,AdapterCompatibility,DriverVersion,Status

# 期望：
#   Name                 : NVIDIA GeForce GTX 1050
#   AdapterCompatibility : NVIDIA
#   DriverVersion        : 100.100.104.26600   (stock 0.1.266)
#   Status               : OK

# 测试模式
bcdedit /enum '{current}' | Select-String testsigning
# 期望：testsigning             No

# 启动链（应该是原版）
mountvol S: /S
Get-FileHash S:\EFI\Microsoft\Boot\bootmgfw.efi -Algorithm SHA256
mountvol S: /D
# 期望：和 Microsoft 原版 bootmgr 哈希一致（绝不应等于 EfiGuard Loader.efi 的哈希）

# Trusted Root 中 NVIDIA 相关
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match 'NVIDIA' }
# 期望：空
```

GPU-Z 打开后应该看到 `NVIDIA GeForce GTX 1050`、Subvendor `NVIDIA`、Device ID `10DE 1C81`。NVAPI 可见的核心频率/显存/驱动版本由 `nvapi64.dll` shim 提供。

---

## 故障定位

| 症状 | 原因 | 处理 |
|---|---|---|
| `Win32_VideoController.Name = "Microsoft Basic Display Adapter"` | stock virtio-win 没装上，或装了但 `apply-gpu-spoof.ps1` 没执行覆盖 | 重跑 `irm .../shallow-stealth.ps1 \| iex` |
| GPU 设备 `Problem = CM_PROB_FAILED_POST_START`（code 43） | 误用了 `GPU_SELFSIGNED=1` 启动器，但 guest 里是 stock viogpudo | 关 VM，去掉 `GPU_SELFSIGNED=1` 重启；或装 patched viogpudo（=深层路径，丢 ACE） |
| Device Manager 驱动程序提供商显示「未知」 | DEVPKEY `{a8b865dd-...}\0009` 槽位需 TrustedInstaller 权限 + DEVPROP 类型 0xFFFF0012 才能写对，guest 内 `apply-gpu-spoof.ps1` 写不进 | 关 VM，host 跑 `sudo deploy/scripts/host-fix-gpu-devpkey.sh 2` |
| ACE 仍报 13-131106-0 | 系统里有黑名单驱动 / 测试模式开了 / 装过 EfiGuard 没回退干净 | 跑 `irm .../destealth-revert.ps1 \| iex` 全部回退，再走浅层 |

---

## 与深层路径的关系

| | 浅层（本文档） | 深层（`STEALTH-WORKFLOW.md` §3b） |
|---|---|---|
| GPU PCI 主 ID | 1AF4:1050（virtio） | 10DE:1C81（NVIDIA） |
| viogpudo.sys 签名 | MS-WHQL（stock 0.1.266） | 伪 NVIDIA Driver Signer（patched） |
| EfiGuard | 不装 | 装（替换 bootmgfw） |
| Trusted Root 多余根证书 | 无 | 加伪 NVIDIA Code Signing Root |
| GPU-Z 看到 1050 | ✅（注册表 + nvapi shim） | ✅（PCI 主 ID + 注册表 + nvapi shim） |
| testsigning | No | No |
| ACE 13-131106-0 | **过** | **不过** |
| 适用场景 | 腾讯 ACE / 网易 NP / 一般用户态防 VM 检测 | 不打 ACE 系，对抗内核态 PCI 主 ID 检查 |

两条路径共用同一份启动器和身份 profile，靠 `GPU_SELFSIGNED` 开关切换。

# Stealth Workflow — 一键全流程

从一张全新 Win10/LTSC ISO 到「testsigning=No + GPU-Z 识别 GTX 1050 + Device Manager 干净」的最小步骤。

---

## 选路径：浅层 vs 深层

> 2026-04-26 实测：腾讯 ACE 反作弊（DNF / WeGame 等）会拒**深层**配置，报错
> `ACE 安全中心：检测到系统环境异常 (13-131106-0)`。
> 真凶是 EfiGuard 改了 bootmgr + patched viogpudo 用伪 NVIDIA CA 签名 + Trusted
> Root 里出现非真实根证书。**ACE 类反作弊请走浅层。**

| 路径 | GPU-Z 看到 1050？ | testsigning | ACE 13-131106-0 | 加分 |
|---|---|---|---|---|
| **浅层（推荐，ACE 兼容）** | ✅ 是（subsys 1C8110DE + 注册表覆盖 + nvapi shim） | No | **过** | stock virtio-win = MS-WHQL 签名，零非标驱动；零启动链改动；可对抗腾讯 ACE / 网易 NP 类 |
| 深层（现有流程） | ✅ 是（PCI 主 ID 真改 10DE:1C81） | No | **不过** | 仅适合无 ACE 类反作弊的轻场景 |

二选一：
- 想用 ACE 类游戏（DNF/CF/和平精英 等） → **第 2-3 节走浅层**
- 不打 ACE 系，只防一般 VM 检测 → 第 2-3 节走深层

---

## 0. 一次性的宿主机准备（多 VM 共享）

```bash
# 桥接（让 guest 拿宿主 LAN 的 DHCP IP；多 VM 共用 br0）
sudo UPLINK=enp5s0 deploy/scripts/setup-bridge.sh

# QEMU 自身（含 hw/ stealth 改动）
deploy/tools/build.sh                    # → build/qemu-system-x86_64

# Backdated CA + leaf signer + TSA cert（一次签好 viogpudo.sys + cat）
deploy/driver-signing/scripts/gen-backdated-ca.sh
deploy/driver-signing/scripts/gen-backdated-tsa.sh
deploy/driver-signing/scripts/sign-backdated.sh \
    deploy/driver-signing/in/viogpudo-original.sys \
    deploy/driver-signing/out/viogpudo.sys
# (cat 文件由 install-stealth-guest 在 guest 端用 Inf2Cat 重新生成)

# EfiGuard custom-build（patch 见 deploy/efiguard/patches/）
# 已经 ship 在 deploy/efiguard/custom-build/，正常情况不用重编
```

---

## 1. 创建一个新 VM（每个 INSTANCE 一份磁盘 + 身份）

```bash
# 启动到 ISO 安装
deploy/scripts/start-vm.sh 2 --iso=/path/to/win10_ltsc.iso

# 想全自动跳过 OOBE：附加 autounattend ISO
EXTRA_ISO=/home/ubuntu/images/autounattend-vm2.iso \
    deploy/scripts/start-vm.sh 2 --iso=/path/to/win10_ltsc.iso
```

启动器会自动：
- 在 `/home/ubuntu/images/vms/<N>/disk.qcow2` 创建空白 512GB 盘
- 在 `/home/ubuntu/images/vms/<N>/profile` 随机出一份硬件身份并固化
- `/home/ubuntu/images/vms/<N>/ovmf-vars.fd` 独立 NVRAM
- 端口分配：`10022+N` (SSH fwd)、`13389+N` (RDP fwd)、`5900+N-1` (VNC)

走 OOBE：选语言 → 创建本地账户 `Administrator` / `123456` → 进桌面。

---

## 2. Guest 内一行命令做 bootstrap（OpenSSH + autologin + Defender 关）

宿主先起一个简易 HTTP server 提供脚本：

```bash
# host
cd deploy/scripts
nohup python3 deploy/scripts/serve-stealth-http.py 8765 &> /tmp/serve-http.log &
```

Guest（管理员 PowerShell）：

```powershell
irm http://192.168.30.<host>:8765/vm-bootstrap.ps1 | iex
```

完成后 guest 上：
- OpenSSH server 起来，监听 22 (host SSH 直接连 guest 的 LAN IP)
- Administrator 自动登录
- Fast Startup / Defender 实时扫描 / AutoReboot 全关
- minidump 配好（避免崩溃没线索）

---

## 3a. **浅层路径**（ACE/腾讯反作弊兼容，推荐）

Guest 内**管理员 PowerShell** 跑：

```powershell
irm http://192.168.30.<host>:8765/shallow-stealth.ps1 | iex
```

脚本做的事（全部幂等）：

1. 拉 stock virtio-win 0.1.266 viogpudo（MS-WHQL 签名，**非伪 CA**）到 `C:\stealth\nv-stock\`
2. `pnputil /add-driver /install` 把 stock 驱动绑到 PCI VEN_1AF4&DEV_1050
3. 拉 `apply-gpu-spoof.ps1` + `nvapi64.dll`，跑 spoof 脚本：
   - 注册表覆盖 `Win32_VideoController.Name` / `DriverDesc` / `FriendlyName` / DEVPKEY → "NVIDIA GeForce GTX 1050"
   - `nvapi64.dll` 放进 `C:\Windows\System32\`，让查 NVIDIA 私有接口的程序也认识 1050
   - 装一个 `StealthGPU-RefreshName` 计划任务（开机和登录后 2 秒重新覆盖一次，防 BasicDisplay 复位）
4. 重启

期望终态：

```
testsigning            : No
Win32_VideoController.Name : NVIDIA GeForce GTX 1050
Win32_VideoController.AdapterCompatibility : NVIDIA
Status                 : OK
PNPDeviceID            : PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8110DE&REV_A1
DriverVersion          : 100.100.104.26600  (stock virtio-win 0.1.266 / MS-WHQL)
ConfigManagerErrorCode : 0
bootmgr                : 原版（未替换）
Trusted Root           : 无非标根证书
```

启动器命令保持默认 `GPU_SELFSIGNED=0`：

```bash
deploy/scripts/start-vm.sh <INSTANCE>
```

→ 进游戏，ACE 验证通过。

---

## 3b. **深层路径**（无 ACE 反作弊场景）

```bash
deploy/scripts/install-stealth.sh <INSTANCE>
```

脚本做的事（全部幂等）：

1. SSH 进 guest，把整套 bundle scp 到 `C:\stealth\`
2. Guest 跑 `install-stealth-guest.ps1` —— 装伪 NVIDIA CA、加 patched driver 包、放 nvapi 到 System32、改 GPU 名字注册表、装 EfiGuard 到 ESP、设 testsigning=No
3. 远程 `shutdown /s` 让 QEMU 优雅退出
4. 用 `GPU_SELFSIGNED=1 STABLE_DISPLAY=1` 重启 QEMU（PCI 切到 VEN_10DE）
5. 等 SSH 回来 + 打印验证状态

期望终态：

```
testsigning            : No
Win32_VideoController.Name : NVIDIA GeForce GTX 1050
Status                 : OK
PNPDeviceID            : PCI\VEN_10DE&DEV_1C81&SUBSYS_1C8110DE&REV_A1
DriverVersion          : 100.93.0.0    (backdated 自签 viogpudo)
ConfigManagerErrorCode : 0
```

⚠️ **此路径会被 ACE/腾讯反作弊判异常 (13-131106-0)**，因为：
- bootmgfw.efi 被 EfiGuard `Loader.efi` 替换（哈希对不上）
- Trusted Root 里出现伪 "NVIDIA Code Signing Root"
- viogpudo.sys 用伪 NVIDIA Driver Signer 签（非 MS Trusted Publisher）
- PatchGuard 被 EfiGuard 在内核里 patch 掉

如果跑了深层流程后游戏被拒，**回退到浅层**：

```powershell
# guest 内
irm http://192.168.30.<host>:8765/destealth-revert.ps1 | iex
# 关机
# host 重启（保持 GPU_SELFSIGNED=0 默认）
deploy/scripts/start-vm.sh <INSTANCE>
# guest 内再跑浅层
irm http://192.168.30.<host>:8765/shallow-stealth.ps1 | iex
```

---

## 4. 验证 GPU-Z

进 SDL 窗口 → 跑 GPU-Z → 应该完整识别：
- Name: NVIDIA GeForce GTX 1050
- Subvendor: NVIDIA / Device ID 10DE:1C81
- (核心频率/显存等由 nvapi shim 提供 — 见 `deploy/nvapi-shim/nvapi64.c`)

---

## 5. 多 VM（同时跑多台）

每个 INSTANCE 一份 profile / 磁盘 / NVRAM / 端口。同时跑两台（浅层默认，ACE 兼容）：

```bash
# VM1
nohup deploy/scripts/start-vm.sh 1 > /tmp/qemu1.log 2>&1 &

# VM2
nohup deploy/scripts/start-vm.sh 2 > /tmp/qemu2.log 2>&1 &
```

需要深层路径（无 ACE 类反作弊）时加 `GPU_SELFSIGNED=1`：

```bash
GPU_SELFSIGNED=1 nohup deploy/scripts/start-vm.sh 1 > /tmp/qemu1.log 2>&1 &
```

注意：
- 每台 VM 默认 8GB RAM，宿主要够。
- `STABLE_DISPLAY=1` 用 virtio-vga 不带 GL，避开 `VIDEO_DXGKRNL_FATAL_ERROR` BSOD（virgl 在长时间运行时状态不稳）。
- 所有 stealth 资产（cert / driver / EfiGuard） 都是每个 VM 独立装在自己的 ESP 里 —— 一份装好不影响另一份。

---

## 6. 故障排查

| 现象 | 排查 | 修法 |
|---|---|---|
| boot 卡黑屏不动 (>3 min) | EfiGuard 跟 ntoskrnl pattern 不匹配 | offline 还原 bootmgfw.efi.original，参 `efiguard/patches/README.md` 里的 pattern 调整 |
| Code 52 + testsigning=No | EfiGuard DSE patch 没生效 / Loader 没跑 | 截 boot screen 看 EfiGuard 日志（绿色文字）；检查 ESP 里 bootmgfw.efi 是不是 45KB Loader |
| 30 min 自动重启（无 BSOD） | ACE 检测到 ci.dll 文本 patch | 这是 `DSE_DISABLE_AT_BOOT` 模式的代价，目前唯一干净修法是买 EV cert 走 Microsoft attestation |
| WeGame `(3, 1020, 143008)` | testsigning=Yes 暴露在 BCD | 确认 `bcdedit | findstr testsigning` 是 No；如果 No 还报这个错，看 EfiGuard 日志 patch 是不是真生效 |
| BSOD 后查 dump | `deploy/efiguard/grab-minidumps.ps1` (guest 端列 dump)，scp 拉回，`deploy/efiguard/analyze-minidump.sh <dump>` (host 端) | bug check 0x113 → virgl/DxgKrnl，0x109 → PG，0x139 → CI 安全检查 |

更详细的检测面在 `DETECTION.md`，调试方法在 `DEBUG.md`，方案 A/B 对比在 `STEALTH-APPROACHES.md`。

# Stealth Workflow — 一键全流程（DNF / 腾讯反作弊）

从一张全新 Win10/LTSC ISO 到「testsigning=No + GPU-Z 识别 GTX 1050 + Device Manager 干净」的最小步骤。

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
DISPLAY=:1 INSTANCE=2 BRIDGE=br0 STABLE_DISPLAY=1 \
    deploy/scripts/win10-ryzen3-stealth.sh --iso=/path/to/win10_ltsc.iso
```

启动器会自动：
- 在 `/home/ubuntu/images/win10-inst<N>.qcow2` 创建空白 512GB 盘
- 在 `/home/ubuntu/images/stealth-inst<N>.profile` 随机出一份硬件身份并固化
- `/home/ubuntu/images/ovmf-vars-<N>.fd` 独立 NVRAM
- 端口分配：`10022+N` (SSH fwd)、`13389+N` (RDP fwd)、`5900+N-1` (VNC)

走 OOBE：选语言 → 创建本地账户 `Administrator` / `123456` → 进桌面。

---

## 2. Guest 内一行命令做 bootstrap（OpenSSH + autologin + Defender 关）

宿主先起一个简易 HTTP server 提供脚本：

```bash
# host
cd deploy/scripts
python3 -m http.server 8765 --bind 192.168.30.<host-ip-on-br0> &
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

## 3. Host 一行命令做完整 stealth（CA + 自签 driver + nvapi + EfiGuard + BCD）

```bash
deploy/scripts/install-stealth.sh <INSTANCE>
```

脚本做的事（全部幂等）：

1. SSH 进 guest，把整套 bundle scp 到 `C:\stealth\`
2. Guest 跑 `install-stealth-guest.ps1` —— 装 CA、加 driver 包、放 nvapi 到 System32、改 GPU 名字注册表、装 EfiGuard 到 ESP、设 testsigning=No
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

---

## 4. 验证 GPU-Z

进 SDL 窗口 → 跑 GPU-Z → 应该完整识别：
- Name: NVIDIA GeForce GTX 1050
- Subvendor: NVIDIA / Device ID 10DE:1C81
- (核心频率/显存等由 nvapi shim 提供 — 见 `deploy/nvapi-shim/nvapi64.c`)

---

## 5. 多 VM（同时跑多台）

每个 INSTANCE 一份 profile / 磁盘 / NVRAM / 端口。同时跑两台：

```bash
# VM1
DISPLAY=:1 INSTANCE=1 BRIDGE=br0 GPU_SELFSIGNED=1 STABLE_DISPLAY=1 \
    nohup deploy/scripts/win10-ryzen3-stealth.sh > /tmp/qemu1.log 2>&1 &

# VM2
DISPLAY=:1 INSTANCE=2 BRIDGE=br0 GPU_SELFSIGNED=1 STABLE_DISPLAY=1 \
    nohup deploy/scripts/win10-ryzen3-stealth.sh > /tmp/qemu2.log 2>&1 &
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

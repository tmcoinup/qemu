# QEMU 9.2.0 stealth bundle for DNF / 腾讯反作弊

让 Win10 客户机看起来像一台 AMD Ryzen 3 1200 + NVIDIA GTX 1050 的裸机工作站。

## 当前状态

| 层 | 伪造目标 | 实现 |
|---|---|---|
| CPU | AMD Ryzen 3 1200 (Zen 1), CPUID HYPERVISOR=0, KVM/HV leaves stripped | `-cpu Ryzen3-1200,kvm=off,hypervisor=off,enforce=off` + repo 内 hw/i386 patch |
| 主板/BIOS/RAM | ASUS/MSI/Gigabyte/ASRock 随机池 + American Megatrends BIOS + 2× Kingston HyperX Fury DDR4-2666 SPD | `stealth-lib.sh` 随机池 + `hw/i2c/smbus_eeprom.c` SPD 合成 |
| NVMe | Samsung 970 PRO 512GB, 固件 `1B2QEXM7` | `nvme,use-samsung-id=on,model-number=...,serial=...` |
| 显卡（PCI 真值）| `VEN_10DE&DEV_1C81&SUBSYS_1C8110DE&REV_A1` (GTX 1050) | `virtio-vga + x-pci-vendor-id=0x10DE,x-pci-device-id=0x1C81` (`GPU_SELFSIGNED=1` 路径) |
| 显卡驱动 | viogpudo.sys 自签为 "NVIDIA Driver Signer" + INF 绑 `VEN_10DE&DEV_1C81` | `deploy/driver-signing/` 全套：backdated CA + signer + TSA + Inf2Cat 重生成 cat |
| Windows DSE | `testsigning=No` 在 BCD 里，但 boot 时 EfiGuard 把 ci.dll DSE 检查 NOP 掉 | `deploy/efiguard/custom-build/` (Loader.efi + EfiGuardDxe.efi，`DSE_DISABLE_AT_BOOT` + Loader fallback patch) |
| nvapi | GPU-Z / 鲁大师调 NVAPI 时返回 GTX 1050 元数据 | `deploy/nvapi-shim/nvapi64.dll` → `C:\Windows\System32\` |
| ACPI | `ALASKA / A M I` OEM ID | `hw/acpi/` patch |
| 监视器 | `Samsung S24F350F` (PNP `MONITOR\SAM0F65`, 1920×1080@60, 530×300mm, HDMI) | `hw/display/edid-generate.c` (CEA-861 timing + Samsung-specific descriptor) + 注册表 HardwareID/CompatibleIDs |
| 分辨率列表 | 只暴露 ≤1080p 模式（不出 4K/UWQHD） | `hw/display/virtio-gpu-base.c` 加 `xmax/ymax` 属性 + launcher 传 `xmax=1920,ymax=1080` |
| 时区 | guest RTC = 北京时间 (`Asia/Shanghai`) 不论 host 时区 | launcher exec QEMU 前 `export TZ=Asia/Shanghai` |

## 一键流程

完整流程见 **[STEALTH-WORKFLOW.md](STEALTH-WORKFLOW.md)** —— 从全新 LTSC ISO 到「testsigning=No + GPU-Z 识别 1050 + 干净 Device Manager」全套。

简化版：

```bash
# 1. 一次性宿主准备
sudo UPLINK=enp5s0 deploy/scripts/setup-bridge.sh
deploy/tools/build.sh                                       # build patched QEMU
deploy/driver-signing/scripts/gen-backdated-ca.sh           # CA + leaf signer
deploy/driver-signing/scripts/gen-backdated-tsa.sh          # TSA cert (RFC3161)

# 2. 起 VM 装系统
DISPLAY=:1 INSTANCE=2 BRIDGE=br0 STABLE_DISPLAY=1 \
    deploy/scripts/win10-ryzen3-stealth.sh --iso=/path/to/win10_ltsc.iso
# 走 OOBE，本地账户 Administrator/123456，进桌面

# 3. Guest bootstrap
# host: python3 -m http.server 8765 --bind <host-br0-ip> （在 deploy/scripts/）
# guest 管理员 PowerShell:  irm http://<host>:8765/vm-bootstrap.ps1 | iex

# 4. 一键全套 stealth
deploy/scripts/install-stealth.sh 2
```

## 多 VM

启动器 `win10-ryzen3-stealth.sh` 用 `INSTANCE=N` 区分实例。每个 N 自动有自己的：
- qcow2 磁盘 `/home/ubuntu/images/win10-inst<N>.qcow2`
- 硬件身份 profile `/home/ubuntu/images/stealth-inst<N>.profile`（首次启动随机生成、固化）
- OVMF NVRAM `/home/ubuntu/images/ovmf-vars-<N>.fd`
- QMP socket `/tmp/qemu-stealth-<N>.qmp`
- VNC display `N-1`（端口 5900+N-1）
- SSH 转发 `127.0.0.1:1002<N+2>`、RDP 转发 `127.0.0.1:1338<N+8>`
- MAC 从 Realtek/Intel/ASUS OUI 池随机一份

每个 VM 的 stealth 资产（cert、driver、EfiGuard）装在它自己的 ESP 里，互不影响。

## 目录

```
deploy/
├── docs/                           # 文档（本目录）
│   ├── README.md                   # 本文件 — 总览
│   ├── STEALTH-WORKFLOW.md         # 一键全流程（最常用）
│   ├── STEALTH-APPROACHES.md       # 方案 A (INF patch) vs B (registry rename) 对比
│   ├── DETECTION.md                # 反作弊全检测面清单
│   ├── DEBUG.md                    # QEMU trace + GDB + QMP 调试
│   ├── USAGE.md                    # （历史）单 VM 详细操作手册
│   └── VERIFY.md                   # 离线自检 / 验收清单
├── patches/                        # QEMU hw/ 补丁（已合并到本仓库分支）
├── scripts/
│   ├── win10-ryzen3-stealth.sh     # 主启动器（多实例）
│   ├── install-stealth.sh          # 主一键全套（host）
│   ├── install-stealth-guest.ps1   # 主一键全套（guest 内部，由上者调用）
│   ├── vm-bootstrap.ps1            # guest 内裸机首启 bootstrap (OpenSSH + autologin)
│   ├── apply-gpu-spoof.ps1         # 注册表 GPU 改名（被 install-stealth-guest 调用）
│   ├── setup-bridge.sh             # 一次性桥接配置
│   ├── stop-vm.sh                  # 优雅停机
│   ├── reroll-identity.sh          # 重置硬件身份
│   ├── stealth-lib.sh              # 随机池（被 win10-ryzen3-stealth.sh 调用）
│   ├── host-performance.sh         # 主机调优 (透明大页 / CPU governor)
│   ├── host-fix-gpu-devpkey.sh     # offline 修 DEVPKEY ACL（少用）
│   ├── qmp-frame.sh                # QMP 截图 / sendkey
│   ├── rdp-connect.sh              # 用 xfreerdp 进 guest
│   ├── diag-gpu-props.ps1          # guest 内 GPU 属性诊断
│   └── verify-stealth.sh           # 离线自检
├── driver-signing/
│   ├── scripts/                    # gen-CA / sign / Inf2Cat / verify
│   ├── certs/                      # 生成的 CA + signer + TSA (.key/.pfx 不入仓)
│   └── out/                        # signed viogpudo.sys / .cat / -nvidia.inf
├── efiguard/
│   ├── custom-build/               # 我们 patch 过的 Loader.efi + EfiGuardDxe.efi
│   ├── patches/                    # 跟 upstream 的 diff（默认配置 + Loader fallback）
│   ├── grab-minidumps.ps1          # guest 内列 minidump
│   └── analyze-minidump.sh         # host 端简单 dump 分析
├── nvapi-shim/                     # NVAPI shim DLL（mingw 编译，guest 装到 System32）
├── firmware/
│   └── OVMF_CODE_4M_stealth.fd     # 自编译 OVMF（NVIDIA GOP whitelist）
├── tools/
│   └── build.sh                    # ./configure + ninja，含 --clean / --debug
└── virtio-win/
    └── viogpudo-nvidia.inf         # 修改过的 INF（绑 VEN_10DE&DEV_1C81）
```

## 已知限制

1. **EfiGuard `DSE_DISABLE_AT_BOOT` 会改 ci.dll text** — ACE 如果做内核哈希校验有概率被 30 分钟周期触发主动 reboot。彻底解只有买 EV cert + Microsoft attestation。
2. **EfiGuard pattern matching 跟 ntoskrnl 版本绑定** — 已验证 19041.1266 / 19041.6456 / 19045.x 工作；新 KB 出来如失效，看 `efiguard/patches/README.md`。
3. **`STABLE_DISPLAY=1`（默认推荐）禁了 virgl** — guest 没 GL 加速，DirectX 走 WARP；DNF 仍可玩。如果你信任你的环境可以去掉它。
4. **PCI VEN_10DE 只是 PCI header 重写** — 实际 device 还是 virtio-vga，ACE 如果在内核态走 PCI BAR / config space 反向探测可能识破。
5. **`Win32_VideoController.CurrentRefreshRate = 1`、有源信号分辨率 -1×-1** — viogpudo 内核驱动 `BuildVideoSignalInfo` 把所有 freq 设成 `D3DKMDT_FREQUENCY_NOTSPECIFIED`。源码 patch 已写在 `deploy/driver-signing/patches/0001-viogpudo-realistic-vsync-freq.patch`，但需要正确集成的 VS Community + WDK 才能编出能加载的 `.sys`（VS Build Tools SKU 装不上 WDK VSIX；手 copy toolset 文件能编但缺 kernel-mode flag → Code 38）。短期权宜：留着这个 fingerprint。
6. **`Win32_PnPSignedDriver.IsSigned = False` for GPU** — `WinVerifyTrust(DRIVER)` 内置 MS 根证书白名单，自签 backdated CA 不在名单里。同根因导致 DxDiag "未数字签名"。彻底解：EV cert + Microsoft Hardware Attestation 走 WHQL 流程。

## 当前已知 bug

记 memory 里。最重要的：
- 30 分钟 ACE 主动重启（`wininit.exe` 触发 `0x800000ff`）—— 见 `feedback_efiguard_default.md`
- VIDEO_DXGKRNL_FATAL_ERROR if `STABLE_DISPLAY=0`（virgl 状态机长时间崩）

## 反检测路线（仍在探索）

| 路线 | 状态 |
|---|---|
| EV cert + Microsoft attestation | 未做（贵 + 慢，一周左右） |
| Userland NtQSI hook in wegame.exe | 未做（需要 DLL 注入 + 应对 WeGame 自校验） |
| KDMapper-style 通过签名漏洞驱动 manual map | 未做（合规风险） |

更多见 `STEALTH-APPROACHES.md`。

# QEMU 9.2.0 stealth bundle

让 Win10/11 LTSC 客户机看起来像一台 AMD Ryzen 3 + NVIDIA GTX 1050 的裸机工作站。
两条强度可选，按反作弊场景挑：

| 路径 | 适用 | GPU PCI 主 ID | 驱动签名 | 启动链 | ACE 13-131106-0 |
|---|---|---|---|---|---|
| **浅层** | 腾讯 ACE / 网易 NP / 一般 VM 检测 | `1AF4:1050`（virtio）+ subsys `1C8110DE`(NVIDIA) | stock virtio-win 0.1.266，**MS-WHQL** | 原版 Microsoft bootmgr | **过** ✅ |
| 深层 | 不打 ACE 系，对抗 PCI 主 ID 内核检查 | `10DE:1C81` (NVIDIA 真改) | patched + 伪 NVIDIA Driver Signer | EfiGuard `Loader.efi` 替换 `bootmgfw.efi` | **不过** ❌ |

两条路径共用同一份启动器和 stealth profile，靠 `GPU_SELFSIGNED` 开关切换。**默认是浅层**。

## 当前状态

| 层 | 伪造目标 | 实现 |
|---|---|---|
| CPU | AMD Ryzen 3 1200 (Zen 1) 默认 / 2300X (Zen+) 可选；CPUID HYPERVISOR=0、KVM/HV leaves stripped | `-cpu Ryzen3-1200,kvm=off,hypervisor=off,enforce=off` + repo 内 `target/i386` patch |
| CPU 持久化 | per-instance | `stealth-inst<N>.profile` 写入 `CPU_MODEL=`，下次启动直接复用 |
| 主板/BIOS/RAM | ASUS/MSI/Gigabyte/ASRock 随机池 + American Megatrends BIOS + 2× Kingston HyperX Fury DDR4-2666 SPD | `stealth-lib.sh` 随机池 + `hw/i2c/smbus_eeprom.c` SPD 合成 |
| NVMe | Samsung 970 PRO 512GB, 固件 `1B2QEXM7` | `nvme,use-samsung-id=on,model-number=...,serial=...` |
| 显卡（浅层）| 主 `VEN_1AF4&DEV_1050` + subsys `1C8110DE` (NVIDIA GTX 1050) | `virtio-vga + x-pci-sub-vendor-id=0x10DE,x-pci-sub-device-id=0x1C81` |
| 显卡（深层）| 主 `VEN_10DE&DEV_1C81&SUBSYS_1C8110DE` (NVIDIA 真改) | 同上 + `x-pci-vendor-id=0x10DE,x-pci-device-id=0x1C81` (`GPU_SELFSIGNED=1`) |
| viogpudo（浅层）| stock virtio-win 0.1.266，MS Windows Hardware Compatibility Publisher 签 | `deploy/scripts/stock-viogpudo/`（从 `virtio-win.iso` w10/amd64 抽出） |
| viogpudo（深层）| patched .sys，伪 NVIDIA Driver Signer 签 | `deploy/driver-signing/{certs,out}/` 全套 backdated 链 |
| Windows DSE（浅层）| `testsigning=No`，DSE 正常生效 | guest 里 `bcdedit testsigning No`，无 EfiGuard |
| Windows DSE（深层）| `testsigning=No` + EfiGuard 在 boot 时 NOP 掉 ci.dll DSE 检查 | `deploy/efiguard/custom-build/` |
| GPU-Z 看到 1050 | 注册表覆盖 + nvapi shim | `deploy/scripts/apply-gpu-spoof.ps1` 改 `Class\{4d36e968-...}` 和 `Enum\PCI\...` 下的 `DeviceDesc / FriendlyName / DriverDesc / DEVPKEY`，`deploy/nvapi-shim/nvapi64.dll` 替换 `System32\nvapi64.dll` |
| ACPI | `ALASKA / A M I` OEM ID + `_HID PNP0C02`（不再泄漏 `QEMU0002`） | `hw/acpi/` patch + `hw/i386/fw_cfg.c` |
| PCI 设备 ID | xHCI = AMD `1022:43BB`，root-port = AMD `1022:1453`，e1000e subsys = ASUS `1043:86C0` | hw/usb/hcd-xhci-pci.c, hw/pci-bridge/gen_pcie_root_port.c, hw/net/e1000e.c patch |
| USB HID | "Microsoft" 制造商串 + Microsoft `045E:00CB`/`045E:0750` + Wacom `056A:00FB` | `hw/usb/dev-hid.c` patch |
| 监视器 | `Samsung S24F350F` (PNP `MONITOR\SAM0F65`, 1920×1080@60, 530×300mm, HDMI) | `hw/display/edid-generate.c` + 注册表 HardwareID/CompatibleIDs |
| 时区 | guest RTC = 北京时间 (`Asia/Shanghai`) | launcher exec QEMU 前 `export TZ=Asia/Shanghai` |

## 一键流程

完整流程见 **[STEALTH-WORKFLOW.md](STEALTH-WORKFLOW.md)**；ACE 兼容专用见 **[ACE-SHALLOW-STEALTH.md](ACE-SHALLOW-STEALTH.md)**。

简化版（浅层 / ACE 兼容）：

```bash
# 1. 一次性宿主准备
sudo UPLINK=enp5s0 deploy/scripts/setup-bridge.sh
deploy/tools/build.sh                                # build patched QEMU
cd deploy/scripts && python3 -m http.server 8765 --bind 192.168.30.<host-ip-on-br0> &

# 2. 装系统（autounattend 自动跳过 OOBE，~10 分钟到桌面）
DISPLAY=:1 EXTRA_ISO=/home/ubuntu/images/autounattend-vm2.iso \
    deploy/scripts/start-vm.sh 2 --iso=/home/ubuntu/images/win10_ltsc.iso

# 3. 装完进桌面，guest 管理员 PowerShell：
#    irm http://192.168.30.<host>:8765/shallow-stealth.ps1 | iex
#    （拉 stock viogpudo + 注册表覆盖 + 重启）

# 4. 日常启动（无任何 env var）
DISPLAY=:1 deploy/scripts/start-vm.sh 2
```

简化版（深层 / 无 ACE）：

```bash
# 1+2 同上；guest 内：irm .../vm-bootstrap.ps1 | iex
# 3. 一键全套 stealth（host）
deploy/scripts/install-stealth.sh 2
# 4. 日常启动（带 GPU_SELFSIGNED=1）
DISPLAY=:1 GPU_SELFSIGNED=1 deploy/scripts/start-vm.sh 2
```

## 多 VM

启动器 `start-vm.sh` 用 `INSTANCE=N` 区分实例。每个 N 自动有自己的：
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
│   ├── start-vm.sh     # 主启动器（多实例）
│   ├── install-stealth.sh          # 主一键全套（host）
│   ├── install-stealth-guest.ps1   # 主一键全套（guest 内部，由上者调用）
│   ├── vm-bootstrap.ps1            # guest 内裸机首启 bootstrap (OpenSSH + autologin)
│   ├── apply-gpu-spoof.ps1         # 注册表 GPU 改名（被 install-stealth-guest 调用）
│   ├── setup-bridge.sh             # 一次性桥接配置
│   ├── stop-vm.sh                  # 优雅停机
│   ├── reroll-identity.sh          # 重置硬件身份
│   ├── stealth-lib.sh              # 随机池（被 start-vm.sh 调用）
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

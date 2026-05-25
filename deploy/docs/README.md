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
| CPU 池（无 iGPU） | AMD Ryzen 3 1200/2300X + Intel i3-9100F（F 后缀=无 iGPU）；CPUID HYPERVISOR=0、KVM/HV leaves stripped | `-cpu ...,kvm=off,hypervisor=off,enforce=off` + `target/i386` patch |
| CPU 持久化 | per-instance；DIMM SN / NVMe SN / Board SN 等全部一次性生成写 profile，跨重启不变 | `stealth_pick_profile` → `vms/<N>/profile` |
| 主板池（27 条） | ASUS/MSI/Gigabyte/ASRock × AM4/LGA1151/LGA1200，每条带 PCI 子系统 vendor/device ID | `stealth-lib.sh::BOARD_POOL`；start-vm.sh 不再 hardcoded ASUS subsys |
| 内存拓扑 | ≤4GB：1 条 DIMM + 单 NUMA（卡槽 2 占 1 空 1）；>4GB：2 条 DIMM + 双 NUMA + 双通道（槽位 DIMM_A2/DIMM_B2）。内存量钉 `profile.MEM_TOTAL_MB`，启动命令不变；`set-vm-memory.sh <N> 8G` 切换 | 动态 `MEMORY_ARGS` 数组；T16_NUM_DEVICES 始终 = 2（卡槽数不变）；memfd `prealloc=off` 按需分配（未用页不占 host 物理内存）；起前内存 preflight 护栏防 OOM（`MEM_GUARD` / `MEM_FORCE`） |
| 内存 SN 持久化 + 双通道唯一 SN | DIMM 0 一次性生成 8-char hex 写 profile；双通道第 2 条按 `sha256(MEM_SERIAL-dimm2)` 派生，两条各自唯一（共用同 SN 是伪造特征，必查 `Win32_PhysicalMemory`） | `MEM_SERIAL` 字段；`t17` emit `serial=SN1\|SN2`；`smbios.c` type17 serial 支持 `\|` 分隔的 per-DIMM 列表 |
| NVMe | 5 款 Samsung (970 PRO / 970 EVO / 980 PRO / 980 / 990 PRO) 池，每款带真实 advertised 字节数 | `NVME_POOL` 含 `RAW_BYTES` 列；qcow2 大小按 profile 选定 model 同步建（Model ↔ Size 自洽） |
| 显示器（随机）| 10 款 24" 1920×1080@60 池：SAM C24F390 / AOC 24G2E5 / BNQ GW2480 / DEL SE2419HR / **HKC SG24A1 国产** / LG / Philips / 三星曲面 | `MONITOR_POOL` + **patch 0009** virtio-vga 加 `edid-vendor/name/serial/width-mm/height-mm` cmdline 选项 |
| 显卡 GPU（浅层）| 主 `VEN_1AF4&DEV_1050` + subsys `1C8110DE`-类（NVIDIA / AMD 池随机抽） | `virtio-vga + x-pci-sub-vendor-id/device-id`；池里 NVIDIA GT 1030/GTX 1050/1050Ti/750Ti + AMD RX 550/560 |
| 显卡 GPU（深层）| 主 `VEN_10DE&DEV_1C81&SUBSYS_1C8110DE` (NVIDIA 真改) | 同上 + `x-pci-vendor-id=0x10DE,x-pci-device-id=0x1C81` (`GPU_SELFSIGNED=1`) |
| 键盘（随机）| 5 款池：Microsoft Wired Keyboard 600 / Logitech K120 / **A4Tech 双飞燕 KK-3** / **Rapoo 雷柏 N1820** / Dell USB Keyboard | `KBD_POOL` + **patch 0010** usb-kbd 加 `vendorid/productid/manufacturer/product` cmdline；`serial` 已在 USBDevice 父级 |
| 鼠标（随机）| 5 款池：Microsoft Optical / Logitech M105 / A4Tech OP-720 / Rapoo N1162 / Dell | `MOUSE_POOL` + patch 0010 同上 |
| 数位板（随机）| 4 款池：HUION PenTablet / HUION H640P / **VEIKK A30** / **XP-Pen Star G640** | `TABLET_POOL` + patch 0010 同上 |
| viogpudo（浅层）| stock virtio-win 0.1.266，MS Windows Hardware Compatibility Publisher 签 | `deploy/scripts/stock-viogpudo/` |
| viogpudo（深层）| patched .sys，伪 NVIDIA Driver Signer 签 | `deploy/driver-signing/{certs,out}/` |
| Windows DSE（浅层）| `testsigning=No`，DSE 正常生效 | guest 里 `bcdedit testsigning No`，无 EfiGuard |
| Windows DSE（深层）| `testsigning=No` + EfiGuard NOP 掉 ci.dll DSE 检查 | `deploy/efiguard/custom-build/` |
| GPU-Z 看到 NVIDIA | 注册表覆盖 + nvapi shim | `apply-gpu-spoof.ps1` + `nvapi-shim/nvapi64.dll` |
| ACPI OEM | `ALASKA / A M I` 全表 + `_HID PNP0C02`（不再泄漏 `QEMU0002`） | `hw/acpi/` patch + `hw/i386/fw_cfg.c` |
| ACPI BGRT | 20-byte 伪 boot logo 表 (status=migrated)，OEMID `ALASKA / A M I` 对齐 DSDT | `firmware/bgrt.bin` + `-acpitable sig=BGRT,data=...` |
| ACPI 热区/风扇 | `\_SB.TZQE` ThermalZone (_TMP/_CRT/_PSV) + `\_SB.FANE` PNP0C0B 风扇 | `firmware/ssdt-thermal.{asl,aml}` (iasl 编) + `-acpitable file=...` |
| **TPM 2.0** | swtpm + tpm-crb 设备；per-VM state 目录 `$VM_DIR/tpm-state`；Win11 / 现代裸金属画像 | start-vm.sh 检测 swtpm 后启动 daemon + 挂 `-tpmdev emulator,id=tpm0`。**OVMF 必须含 Tcg2 模块**——用 `deploy/tools/build-ovmf.sh` 重 build (`-D TPM2_ENABLE=TRUE`)。swtpm 是脱离 qemu 的 `--daemon`，start-vm 起 daemon 前 + stop-vm 停机后都按实例 reap 孤儿 swtpm（防 NVRAM 锁残留致下次 `CMD_INIT 0x9` 秒退） |
| PCI 设备 ID | xHCI = AMD `1022:43BB`，root-port = AMD `1022:1453`；e1000e subsys 跟 BOARD_MFR 走（ASUS/MSI/Giga/ASRock 真实子厂值，不再固定 ASUS） | hw/usb/hcd-xhci-pci.c, hw/pci-bridge/gen_pcie_root_port.c, hw/net/e1000e.c |
| **RTC 时钟** | `clock=vm`（不是 host），让 RDTSC 与 wall-clock 自然漂移；裸金属晶振温漂特征 | `-rtc base=localtime,clock=vm,driftfix=slew` |
| 时区 | guest RTC = 北京时间 (`Asia/Shanghai`) | launcher exec QEMU 前 `export TZ=Asia/Shanghai` |
| QEMU 进程名 | `win10-${INSTANCE}`（不再写 `win10-ryzen3-`，避免 host `ps` 暴露 stealth 设计） | `-name "win10-${INSTANCE}"` |
| 启动自检 | 13 段 verify-stealth.sh 全过才放行 | `deploy/scripts/verify-stealth.sh` |

## 重 build OVMF（首次安装后一般不再需要）

stealth OVMF 在 `deploy/firmware/OVMF_CODE_4M_stealth.fd`，由 `deploy/tools/build-ovmf.sh` 从 `~/src/edk2` 源码编出。当前应用的 patch：

- `firmware/edk2-patches/0001-OvmfPkg-QemuVideoDxe-NVIDIA-1c81-GOP-whitelist.patch` —— 让 virtio-vga subsys=NVIDIA 1C81 在 UEFI 阶段也认识，避免 OVMF 找不到 GOP 卡死黑屏
- 编译时 `-D TPM2_ENABLE=TRUE` —— guest 看到 tpm-crb，`Get-Tpm` 返回真实状态

```bash
# 增量 build (约 10 秒)；patch 自动幂等应用
deploy/tools/build-ovmf.sh

# 切 DEBUG 版本（有 .debug 符号，~5MB 大）
deploy/tools/build-ovmf.sh --target DEBUG

# 不应用 stealth patch（要纯 OVMF 验对照）
deploy/tools/build-ovmf.sh --no-patch
```

build 完自动备份旧 fd → `.bak.<unix-ts>`，可回滚。

## 一键流程

完整流程见 **[STEALTH-WORKFLOW.md](STEALTH-WORKFLOW.md)**；ACE 兼容专用见 **[ACE-SHALLOW-STEALTH.md](ACE-SHALLOW-STEALTH.md)**。

简化版（浅层 / ACE 兼容）：

```bash
# 1. 一次性宿主准备
sudo UPLINK=enp5s0 deploy/scripts/setup-bridge.sh
deploy/tools/build.sh                                # build patched QEMU
nohup python3 deploy/scripts/serve-stealth-http.py 8765 &> /tmp/serve-http.log &

# 2. 装系统（autounattend 自动跳过 OOBE，~10 分钟到桌面）
EXTRA_ISO=/home/ubuntu/images/autounattend-vm2.iso \
    deploy/scripts/start-vm.sh 2 --iso=/home/ubuntu/images/win10_ltsc.iso

# 3. 装完进桌面，guest 管理员 PowerShell：
#    irm http://192.168.30.<host>:8765/shallow-stealth.ps1 | iex
#    （拉 stock viogpudo + 注册表覆盖 + 重启）

# 4. 日常启动（无任何 env var；默认走 fb-shm 推流，无 SDL 窗口）
deploy/scripts/start-vm.sh 2
# 想要本地窗口加 --sdl；想要 VNC 加 --headless；两者都不开就是纯推流：
#   scripts/qemu-fb-shm-stream.py --sock /tmp/qemu-stealth-2.fb --output ...
```

简化版（深层 / 无 ACE）：

```bash
# 1+2 同上；guest 内：irm .../vm-bootstrap.ps1 | iex
# 3. 一键全套 stealth（host）
deploy/scripts/install-stealth.sh 2
# 4. 日常启动（带 GPU_SELFSIGNED=1）
GPU_SELFSIGNED=1 deploy/scripts/start-vm.sh 2
```

## clone-from-base 工作流（多 VM 增量克隆）

把生产 VM 1 装好（含 Win10 + shallow-stealth + DNF + sysprep 可选）后，密封成 base：

```bash
# 1) guest 内 shutdown /s + powercfg -h off （没关 fast startup 会 hibernation 阻塞）
# 2) host 密封
deploy/scripts/seal-base.sh 1 win10-shallow-dnf-v1
ls -la /home/ubuntu/images/vms/_base/win10-shallow-dnf-v1.qcow2
chmod -w /home/ubuntu/images/vms/_base/win10-shallow-dnf-v1.qcow2     # 物理锁死
```

之后新建 VM **一行**：

```bash
sudo deploy/scripts/clone-from-base.sh win10-shallow-dnf-v1 2
deploy/scripts/start-vm.sh 2
```

`clone-from-base.sh` 自动做完 5 件事：

| # | 步骤 | 干啥 |
|---|---|---|
| 1 | 创建 qcow2 backing-file 增量层 | base 共享只读，新 VM 只存增量（首次几百 MB） |
| 2 | `stealth_pick_profile` 重新随机硬件身份 | CPU / 主板 / GPU / MAC / UUID / NVMe SN 全换 |
| 3 | `qemu-img resize` 匹配 profile.NVME_SIZE_BYTES | 新 profile 抽到 1TB Samsung 980 → qcow2 扩到 1TB；避免 Win Model=1TB 但 Size=512GB 的跨向量矛盾 |
| 4 | `host-fix-gpu-devpkey.sh` 重写 DEVPKEY | 新 GPU_NAME（比如 base 是 GTX 750 Ti，clone 抽到 GTX 1050 Ti）→ 设备管理器立刻显示新名字 + Provider=NVIDIA |
| 5 | `host-inject-runonce.sh` 注入 RunOnce | guest 首次开机自动拉 `respawn-stealth.ps1` → 走 `apply-gpu-spoof.ps1 -AutoDetect` → 按新 PCI subsys 改注册表 → 重启 |

**clone 后哪些脚本还要手动跑？答案：零**。NumLock / Fast Startup / vm-bootstrap / Windows Update / DNF 安装 全部继承 base，硬件指纹相关的 GPU 改名 / DEVPKEY 自动重写。

### base 想换怎么办

**不要直接改 base**（base 一旦改了，所有 clone 增量层里残留的 NTFS 元数据指针会指错 → 蓝屏 / chkdsk 报错）。正确做法是滚版本：

```bash
# 1) 从老 base 克隆一个临时 VM
sudo deploy/scripts/clone-from-base.sh win10-shallow-dnf-v1 99
deploy/scripts/start-vm.sh 99
# 2) guest 内更新 DNF / 装新软件
# 3) 关机 + sysprep + 密封新 base
deploy/scripts/seal-base.sh 99 win10-shallow-dnf-v2
# 4) 老 VM (instance 2/3/4) 继续用 v1，新建的 VM 用 v2
```

老 VM 想跟上 v2？让它们自己跑 wegame 自动更新——慢但每个 VM 行为 = 真实玩家。

## 多 VM

启动器 `start-vm.sh` 用 `INSTANCE=N` 区分实例。每个 N 自动有自己的：
- qcow2 磁盘 `/home/ubuntu/images/vms/<N>/disk.qcow2`（大小按 profile 选定 NVMe model 同步：500GB / 512GB / 1TB）
- 硬件身份 profile `/home/ubuntu/images/vms/<N>/profile`（首次启动随机生成、固化；含 60+ 字段，详见 [PROFILE-FIELDS.md](PROFILE-FIELDS.md)）
- OVMF NVRAM `/home/ubuntu/images/vms/<N>/ovmf-vars.fd`
- **TPM 2.0 state** `/home/ubuntu/images/vms/<N>/tpm-state/`（swtpm 首启自动 init EK/Platform cert）
- TPM control socket `/home/ubuntu/images/vms/<N>/tpm-sock`
- QMP socket `/tmp/qemu-stealth-<N>.qmp`
- **fb-shm socket `/tmp/qemu-stealth-<N>.fb`（默认开；外部推流入口）**
- VNC display `N-1`（端口 5900+N-1，仅 `--headless` 时实际监听）
- SSH 转发 `127.0.0.1:1002<N+2>`、RDP 转发 `127.0.0.1:1338<N+8>`
- MAC 从 Realtek/Intel/ASUS OUI 池随机一份
- **完全独立的 USB HID 品牌组合**（键盘 5 选 1、鼠标 5 选 1、数位板 4 选 1、显示器 10 选 1 = 1000 种独立 HID 画像）

每个 VM 的 stealth 资产（cert、driver、EfiGuard）装在它自己的 ESP 里，互不影响。
完整字段清单见 **[PROFILE-FIELDS.md](PROFILE-FIELDS.md)**。

## 跨 VM 反指纹（多账号同主机场景）

每个 VM 的 profile 在首次启动时**独立抽样**以下池子，并写到文件持久化（不再每次重启变）：

| 池 | 字段 | 数量 |
|---|---|---|
| CPU_POOL | CPU 型号 / vendor / family / model / stepping | 3 |
| BOARD_POOL | 主板 mfr / product / SUBSYS_VEN / SUBSYS_DEV | 27 |
| GPU_POOL | 显卡 vendor / name / PCI ID / BIOS / VRAM | 6 |
| **MONITOR_POOL** | EDID vendor / name / 尺寸 mm / SN 前缀 | 10 |
| NVME_POOL | NVMe model / firmware / 字节数 | 5 |
| MEM_POOL | DIMM 厂商 / part 号 | 4 |
| **KBD_POOL** | 键盘 USB VID/PID / 制造商 / 产品名 | 5 |
| **MOUSE_POOL** | 鼠标 USB VID/PID / 制造商 / 产品名 | 5 |
| **TABLET_POOL** | 数位板 USB VID/PID / 制造商 / 产品名 | 4 |

理论独立组合 = `3×27×6×10×5×4×5×5×4` ≈ **9.7 万** 种独立硬件画像。多账号农场跨 VM 行为分析的"同主机印记"信号显著降低。

## 目录

```
deploy/
├── docs/                           # 文档（本目录）
│   ├── README.md                   # 本文件 — 总览
│   ├── VM-WORKFLOW.md              # ⭐ 装机 → seal base → clone 完整操作手册（最常看）
│   ├── STEALTH-WORKFLOW.md         # 一键全流程（深层 / 跟 install-stealth.sh 配合）
│   ├── STEALTH-APPROACHES.md       # 方案 A (INF patch) vs B (registry rename) 对比 + patches/ 全清单
│   ├── PROFILE-FIELDS.md           # vms/<N>/profile 60+ 字段全表 + pool 来源 + WMI 映射 + 老 profile 升级路径
│   ├── DETECTION.md                # 反作弊全检测面清单
│   ├── DEBUG.md                    # QEMU trace + GDB + QMP 调试
│   ├── USAGE.md                    # （历史）单 VM 详细操作手册
│   ├── FB-SHM.md                   # fb-shm 共享内存推流通道（默认开）
│   └── VERIFY.md                   # 13 段离线自检 + guest 端验证命令
├── patches/                        # QEMU hw/ 补丁（已合并到本仓库分支）
├── scripts/
│   ├── start-vm.sh     # 主启动器（多实例）
│   ├── install-stealth.sh          # 主一键全套（host）
│   ├── install-stealth-guest.ps1   # 主一键全套（guest 内部，由上者调用）
│   ├── vm-bootstrap.ps1            # guest 内裸机首启 bootstrap (OpenSSH + autologin)
│   ├── apply-gpu-spoof.ps1         # 注册表 GPU 改名（被 install-stealth-guest 调用）
│   ├── setup-bridge.sh             # 一次性桥接配置
│   ├── stop-vm.sh                  # 优雅停机
│   ├── ctl-vm.sh                   # 运行时切换 SDL/fb-shm（不关机）
│   ├── qmp-proxy.py                # QMP 多客户端 fanout（dgame + image-search 同时连）
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
│   ├── build.sh                    # ./configure + ninja 编 patched QEMU
│   └── build-ovmf.sh               # 一键重 build stealth OVMF (TPM2_ENABLE + NVIDIA GOP whitelist)
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

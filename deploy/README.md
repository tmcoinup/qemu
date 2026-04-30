# QEMU v11.0.0 反虚拟化化 + vGPU 拆分工程（DNF TP 可玩目标）

## 入口脚本（host）

| 命令 | 干什么 |
|---|---|
| `./deploy/start-vm.sh <vm_id>` | **一条龙**：起 VM + (按需) setup-guest + SDL2 viewer。Ctrl+C 优雅关 |
| `./deploy/stop-vm.sh <vm_id>` | 关 VM (另一终端用 / start-vm.sh 退出后兜底) |
| `./deploy/service.sh <vm_id> {stop\|start\|status\|restart}` | guest 内 NvDisplayContainer 服务控制；玩 TP-sensitive 游戏前 `stop` 把 stream 全关 |

`setup-guest.sh` / `connect.sh` 仍然在，供单独调试用，但日常工作流不需要碰。

## 工作流

**首次部署 / driver 未装**：
```bash
./deploy/start-vm.sh 1 --no-spoof    # PCI 真身，driver 才装得上（A 模式下 GRID INF 不匹配会 -436207360）
# setup-task 自动检测 driver 缺 → 跑 setup-guest:
#   1) install-vgpu-driver  (装 GRID 553.24 + 写注册表 block Windows Update)
#   2) install-vgpu-license (从 fastapi-dls 拉 token + 重启 NVDisplay daemon)
#   3) ivshmem driver  4) NvDisplayContainer service  5) name spoof  6) EDID spoof
# guest 重启进 1080p，viewer 自动看到画面
```

**日常使用**：
```bash
./deploy/start-vm.sh 1               # 默认 SPOOF_MODE=A (PCI + name spoof)
# setup-task 检测到全 OK → 直接 viewer
# Ctrl+C / 关 SDL 窗口 / 另一终端 ./stop-vm.sh 1 都能优雅关
```

GNOME/Ubuntu 桌面下，默认启动会启用 viewer 侧的动态宿主快捷键保护：鼠标在 VM 窗口内时临时关闭宿主侧 `Super`/`Meta`、`Alt+Tab`、锁屏等 GNOME/IBus 快捷键，鼠标移出、最小化、隐藏或退出立即恢复。保留宿主快捷键行为可加 `--no-tame-gnome`。

**spoof 切换**：
```bash
./deploy/start-vm.sh 1 --no-spoof          # off：装 driver / 调试用
./deploy/start-vm.sh 1 --spoof-name-only   # B：PCI 真身 + name spoof，driver 最稳
./deploy/start-vm.sh 1                     # A：PCI + name 全 spoof（默认，最彻底）
echo 'SPOOF_MODE=B' >> /home/ubuntu/images/vms/configs/vm1.conf  # per-VM 永久切到 B
```

玩游戏前临时停 stream：
```bash
./deploy/service.sh 1 stop      # NvSvcStream / nv_stream_relay 全停，0 GPU 0 网络 0 ring traffic
# 玩游戏...
./deploy/service.sh 1 start     # 玩完恢复
```

数据通路：
```
guest:  vGPU desktop ─DDA→ D3D11 staging ─Map→ BGRA bytes ─tile diff→ ivshmem ring
                                                                             │
host:   /dev/shm/nv-shmem-vmN ◄──────────────────────────────────────────────┘
        │
        └─ stream_client_dda (SDL2): per-tile SDL_UpdateTexture → present
        └─ X11 input events ─RFB→ ivshmem input ring → AudioSvcHost (local 127.0.0.1)
```

零网络 listener、无 mpv、无 ffmpeg、无 NVENC、无 codec 库。

## 本仓库的源码级改动

| 位置 | 改动 |
|------|------|
| `target/i386/cpu.h` | 新字段 `stealth_hypervisor` (X86CPU) |
| `target/i386/cpu.c` | 新属性 `x-hv-stealth`；gate `FEAT_1_ECX` 里的 HYPERVISOR bit；新增三个 CPU 模型 `Core-i5-4590` / `Core-i5-6500` / `Core-i3-8100` |
| `hw/smbios/smbios.c` | type 17 新增 `memtype` / `typedetail` / `width` / `totalwidth` 选项，把 DDR 类型/宽度/同步属性真填进 SMBIOS |
| `hw/nvme/nvme.h` + `hw/nvme/ctrl.c` | NVMe 新增 `model=` 属性（默认 `QEMU NVMe Ctrl` 覆盖为 SSD 真实型号） |
| `hw/ide/atapi.c` | ATAPI INQUIRY 不再硬编码 `QEMU`/`QEMU DVD-ROM`。`-device ide-cd,model=...` 给出值时按空格拆分成 `vendor(8)+product(16)` 填入 SCSI INQUIRY 响应，Windows 里光驱显示真实型号如 `TSSTcorp CDDVDW SH-224DB` |
| `target/i386/cpu.c` | 新增 CPUID leaf `0x16` (Processor Frequency Info) 处理：从 tsc-freq 派生 base/max MHz + 100 MHz bus clock，让 Windows `Win32_Processor.CurrentClockSpeed` 与 brand string 一致（原 fallback=0 / OVMF 显示 2.00 GHz）|
| `include/hw/firmware/smbios.h` + `hw/smbios/smbios.c` | 新增 SMBIOS type 7 (Cache Information) 完整实现：struct、opts schema、parse、build + main build path 调用。`-smbios type=7,socket_designation=...,level=N,installed_size=KB,...` 生效。Windows `Win32_CacheMemory` 从空 → L1/L2/L3 三条记录 |
| `hw/smbios/smbios.c` | **type 4 → type 7 cache handle 链接**：以前 `l1/l2/l3_cache_handle` 硬编 `0xFFFF`，导致 Windows `Win32_Processor.L2CacheSize` 为空 / `L3CacheSize=0`。现在先 build type 7、按 level (1/2/3) 记录 handle，再 build type 4 把 handle 填进去。顺序不能反，否则 level→handle 表仍是 0xFFFF |
| `hw/smbios/smbios.c` | type 4 新增 `external-clock` (默认 100 MHz BCLK) / `voltage` (默认 0x8C = 1.2V) 选项；type 3 新增 `chassis_type` 选项，默认从硬编 `0x01 (Other)` → `0x03 (Desktop)`，`start-vm.sh` 显式传 `chassis_type=3` |
| `hw/smbios/smbios.c` | type 1/2/3 `version=` 参数必须显式传。**为空时**会落到 `smbios_set_defaults()` 从 `mc->name` 继承成 `"pc-q35-11.0"` — `Win32_BaseBoard.Version = "pc-q35-11.0"` 是 QEMU 指纹。`start-vm.sh` 已显式填 `version=1.0` 等 |
| `target/i386/cpu.c` | 新增三个 CPU 模型各自 `.cache_info = &desktop_skl_cache_info` (L1 32K 8-way / L2 256K 4-way/core / L3 6M 12-way shared)。没有 cache_info 时 `cpu->legacy_cache=true` 导致 CPUID leaf 4 回退到 legacy 4M L2 / 16M L3 — 典型虚拟化足迹 |
| `hw/pci/pci.c` | `pci_default_sub_vendor_id/device_id` 可通过 env vars `QEMU_PCI_SUBVENDOR_ID/SUBDEVICE_ID` 覆盖（默认 `0x1AF4/0x1100` = Red Hat/QEMU 是典型虚拟化指纹）。start-vm.sh 按 `BOARD_BRAND` 查表设成 MSI/ASUS/Gigabyte/ASRock 真实 OEM subsystem ID，guest 里 `lspci` 再也看不到 Red Hat/QEMU |
| `hw/audio/hda-codec.c` | `QEMU_HDA_ID_VENDOR` 从 `0x1AF4` (Red Hat) 改为 `0x10EC` (Realtek)。Windows 里 HD Audio Device 不再显示 "Red Hat High Definition Audio"，codec InstanceId 是 `HDAUDIO\FUNC_01&VEN_10EC&...` |
| `hw/nvme/ctrl.c` | NVMe 默认 PCI vendor 从 `PCI_VENDOR_ID_REDHAT` (0x1B36) 改为 Micron (`0x1344`/`0x5407`) = Crucial；与 `model=Crucial P3 Plus 512GB` 一致 |
| `hw/usb/hcd-xhci-pci.c` | xHCI 默认 PCI 从 `PCI_VENDOR_ID_REDHAT` 改为 Intel Sunrise Point-H (`0x8086`/`0xA12F`)，USB 3.0 控制器看起来像 100-series 主板板载 |
| `hw/smbios/smbios.c` | type 17 `device_locator` 从 `DIMM 0/1/...` 改成 `DIMM_A1/B1/A2/B2/...` 交替分配到 channel A/B；`bank_locator` 带 `Channel{A,B}-DIMM{n}` 后缀；配合 `pc_q35_machine_11_0_options.smbios_memory_device_size = 4 GiB` 让 8GB guest 拆成 2 条 4GB = 双通道视图 |
| `hw/i386/pc_q35.c` | `pc_q35_machine_11_0_options` 里 `m->smbios_memory_device_size = 4 * GiB`（上游默认 2 TiB，导致 8 GB 塞一条大 DIMM） |
| `deploy/host/OVMF_CODE_4M_stealth.fd` | 本地 rebuild 的 OVMF，`PcdFirmwareVendor` 从 `"Ubuntu distribution of EDK II"` → `"American Megatrends Inc."`。源码在 `host/ovmf-build/edk2-2024.02/debian/rules` 第 26-28 行。用 `OVMF_CODE=host/OVMF_CODE_4M_stealth.fd ./start-vm.sh 1` 启用。实测 `SystemBiosVersion` 第三项已从 `Ubuntu ... - 10000` → `American Megatrends Inc. - 10000` |

编译后通过 `build/qemu-system-x86_64 -cpu help | grep Core-i` 可以看到三个新 CPU 模型。

## 目录速查

```
deploy/
├── README.md                 # 本文件
├── create-vm.sh              # 一次性生成 vmN.conf (随机选平台+硬件池+序列号)
├── start-vm.sh               # 统一启动脚本，支持 install/rdp/gtk/sdl/no-gpu
├── lib/
│   └── vgpu-mdev.sh          # mdev 动态分配/回收（带 16 GB 上限检查）
├── host/
│   ├── netplan-br0.yaml      # 宿主网桥配置示例
│   ├── setup-bridge.sh       # qemu-bridge-helper setuid + /etc/qemu/bridge.conf
│   ├── setup-vgpu-unlock.sh  # 编译 vgpu_unlock-rs + LD_PRELOAD 注入 systemd
│   ├── profile_override.toml # vgpu_unlock 的 profile 覆写规则 (vdev_id → 1050/1030)
│   └── setup-fastapi-dls.sh  # 本地 vGPU license 服务器 (Docker)
├── guest/
│   └── spoof-inf/
│       ├── README.md         # GRID → GeForce INF 伪装流程
│       └── inf-patch.ps1     # 自动改 INF 并 pnputil 重装
# vmN.conf / runtime sockets / qcow2 / VARS / log 全在
# $VM_ROOT (默认 /home/ubuntu/images/vms/) 下:
#   configs/vmN.conf  run/vmN.{pid,qmp,mon}  log/vmN.log
#   win10-base.qcow2  win10-vmN.qcow2  vmN_VARS.fd
└── docs/
    ├── DETECTION.md          # 反虚拟化检测面清单（按层组织）
    └── DEBUG.md              # 调试手段 (perf / GDB / trace / 日志)
```

## 一次完整部署顺序

### 0. 宿主前置

1. 内核加 `intel_iommu=on iommu=pt`，重启后 `dmesg | grep -i iommu` 确认 DMAR 启用。
2. 加载 `vfio-pci` + `vfio-mdev` 模块。
3. NVIDIA vGPU host driver (17.6 / 550.163.02) 已装，`nvidia-smi vgpu` 能列出支持的 type。
4. 物理显示靠 AMD RX 570，不要让 Ubuntu desktop 动 NVIDIA 卡。

### 1. vgpu_unlock-rs + profile_override

```bash
cd deploy
./host/setup-vgpu-unlock.sh
sudo systemctl restart nvidia-vgpu-mgr
```

### 2. fastapi-dls vGPU 授权服务器

```bash
./host/setup-fastapi-dls.sh
```

### 3. 宿主网桥

```bash
# 先改 netplan-br0.yaml 里的网卡名
./host/setup-bridge.sh          # 这一步只装 helper 和 bridge.conf
# 自行 cp YAML + netplan try + netplan apply
```

### 4. 生成 VM 配置

```bash
./create-vm.sh 1
./create-vm.sh 2
# 每个 VM 的平台/主板/内存/序列号/MAC 全部写死到 $VM_ROOT/configs/vmN.conf
```

### 5. 建 qcow2 盘 + 初次装 Windows (NO_VFIO install 模式)

```bash
sudo qemu-img create -f qcow2 /vms/win10-vm1.qcow2 120G

# 安装阶段必须旁路 vfio-pci（内存 feedback_no_vfio_install：
#   否则 OVMF PCI 枚举会挂起）
./start-vm.sh 1 --install /iso/win10_ltsc.iso --vnc :1
# VNC 连到 localhost:5901 安装
```

装好后去掉 CD，再用 `--no-gpu` 模式先跑起来、开 RDP、装好 Windows 基础。

### 6. 装 vGPU guest 驱动 (still --no-gpu)

把 `~/Downloads/vGPU17.6/Guest_Drivers/553.74_grid_win10_win11_server2022_dch_64bit_international.exe` 拷进 guest，
Express Install，装完重启。

### 7. 切换到 --rdp 模式 + INF 伪装

```bash
# guest 里 (管理员 PowerShell)
# 具体见 deploy/guest/spoof-inf/README.md
.\inf-patch.ps1 -Profile gtx1050_2gb -DriverRoot C:\NVIDIA\DisplayDriver\553.74\...\Display.Driver
shutdown /r /t 0
```

宿主下次启动:

```bash
./start-vm.sh 1 --rdp
xfreerdp3 /v:<vm-ip> /u:Administrator /p:<pw> /dynamic-resolution /gfx:avc444
```

### 8. License & 验证

```bash
# 宿主生成 token
curl -k https://<host_ip>/-/client-token -o /tmp/client_configuration_token.tok
# 传入 guest，放到
# C:\Program Files\NVIDIA Corporation\vGPU Licensing\ClientConfigToken\
Restart-Service NVDisplay.ContainerLocalSystem
nvidia-smi -q | findstr /i license
# 应该看到 Licensed
```

### 9. 装 DNF 实测

把 DNF 客户端装进 guest，启动 `dnf.exe`，期望:

- 不触发 TP "检测到虚拟机" 弹窗
- 正常进登录
- 进角色选择 → TP 过检
- 游戏可以跑（性能看 vGPU 实际带宽）

## 其它重要提醒 (memory 里的硬约束)

- 永远不做整卡 passthrough。
- 真实显卡日常只 1 张；gtk/sdl 模式下 2 张（人工交互，禁跑 DNF）。
- 生产通道禁用 Sunshine / Moonlight / Parsec / Looking-Glass；只保留 RDP、本地、捕获卡。
- Licensing 通的前提是 guest 时间和 host 时区对齐（memory 里 `project_licensing_stuck`：一度因为 PDT vs CST 差 15h 卡住）。

- GRID 驱动"只装了半截"(缺 `nvlddmkm.sys`, `nvwgf2umx.dll`) 是历史最频繁故障 — 永远先 Express Install 再改 INF。

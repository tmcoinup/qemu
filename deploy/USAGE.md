# 使用手册

## 🚀 快速操作（3 条命令 cover 日常）

```bash
cd ~/projects/qemu/deploy
STEALTH_OVMF=1 ./up.sh --connect            # 启动 vm1 + 等 RDP + 自动弹 xfreerdp3
./down.sh                                   # 优雅关机 (WinRM shutdown /s) + 更新 baseline
./restore.sh                                # VM 改废了：从 win10-ok.qcow2 回滚
```

### 脚本与常用开关

| 脚本 | 开关 / 环境变量 |
|---|---|
| `up.sh` | `--connect` 起 VM + 自动 xfreerdp3；`--connect-only` 不起 VM，只连；`--no-gpu` 装机/救援 (std-vga + VNC) |
| `down.sh` | `--force` 强杀 QEMU (guest 卡死时)；`--no-backup` 关机后不覆盖 baseline |
| `restore.sh` | 把 `win10-vm1.qcow2` 覆盖成 `win10-ok.qcow2`；当前坏盘挪到 `.broken-<ts>` 留底 |

### 环境变量

| 变量 | 默认 | 作用 |
|---|---|---|
| `VM_ID` | `1` | 用哪台 VM（对应 `vm-configs/vmN.conf`） |
| `GUEST_IP` | 自动 | 跳过 ARP 探 IP（从 MAC → br0 neigh 表查），手动指定 |
| `GUEST_USER` | `Administrator` | RDP 账号 |
| `GUEST_PASS` | `123456` | RDP 密码 |
| `SUDO_PASSWORD` | `123456` | 宿主 sudo 密码 (mdev 分配 / 清理用) |
| `STEALTH_OVMF` | `0` | =1 用 `host/OVMF_CODE_4M_stealth.fd`（FirmwareVendor 已擦干净为 AMI），默认关是用 `/usr/share/OVMF/OVMF_CODE_4M.fd` |
| `RDP_SIZE` | `1920x1080` | xfreerdp3 初始窗口大小，`/dynamic-resolution` 继续 handle 后续 resize |

### 默认常量

- VM 标识：`vm1`（配置在 `vm-configs/vm1.conf`，里面有 MAC / UUID / 伪装过的 SMBIOS 序列号等）
- Guest 网络：桥接到 `br0`，MAC → 自动探 IP
- Guest 登录：`Administrator` / `123456`（密码写死在配置里）
- 活动盘：`/home/ubuntu/images/vms/win10-vm1.qcow2`  
- Baseline 备份：`/home/ubuntu/images/vms/win10-ok.qcow2`（`down.sh` 每次关机后自动刷新）

### 日常 workflow

1. `STEALTH_OVMF=1 ./up.sh --connect` — RDP 直接弹出，1920×1080。
2. 里面做事。
3. 做了有风险的改动前先 `./down.sh`（自动备份），这样出问题能回滚。
4. 坏了：`./down.sh --force && ./restore.sh && STEALTH_OVMF=1 ./up.sh --connect`。

调试：
- `tail -f /tmp/vm1.log` 看 QEMU 实时 stderr
- `tmux attach -t vm1` 进 QEMU 的 tmux session（Ctrl-b d 退出不杀 VM）
- QMP 截屏（VM 挂死时）：
  ```
  echo '{"execute":"qmp_capabilities"}{"execute":"screendump","arguments":{"filename":"/tmp/s.ppm","format":"ppm"}}' \
    | nc -q2 -U ~/projects/qemu/deploy/run/vm1.qmp
  convert /tmp/s.ppm /tmp/s.png && xdg-open /tmp/s.png
  ```

### OVMF stealth 重建（升级 edk2 包后重做）

```bash
./host/build-stealth-ovmf.sh
```
幂等脚本：首次 `apt-get source edk2` + 应用 `host/ovmf-stealth.patch` + `dpkg-buildpackage --target build-ovmf`（~8 分钟），产出 `host/OVMF_CODE_4M_stealth.fd`。重跑只做增量 build。

patch 实质是 `debian/rules` 里把 `PcdFirmwareVendor` 从 `"<lsb_release -is> distribution of EDK II"`（值 = "Ubuntu ..."）改成 `"American Megatrends Inc."`，同理 `PcdFirmwareVersionString` 和 `PcdFirmwareReleaseDateString`。Windows 通过 `HKLM\HARDWARE\DESCRIPTION\System\SystemBiosVersion` 读这三个 PCD 组成的字串数组。

> 废弃方案：以前试过 `patch-ovmf-string.py`（in-place 解 LZMA → 改字 → 重压），EDK2 DXE 阶段对 LZMA 流有额外校验会挂，已走不通。源码 rebuild 才稳。

### Ctrl+C 与信号处理

`up.sh` 在等 RDP 期间按 Ctrl+C：脚本退出，**VM 不会被杀**（tmux 托管）。消息会告诉你怎么继续。

`down.sh` 在等 guest 优雅关机期间按 Ctrl+C：脚本退出，VM 可能还在关机中 — 再跑一次 `./down.sh` 继续等，或 `./down.sh --force` 直接杀。

### VNC 进 guest（不加显示适配器的备用通道）

RDP 必然在 guest 设备管理器里留一条 Microsoft Remote Display Adapter。想完全没这个 PnP 条目可以走 **TightVNC**（GDI polling，**无 mirror driver**）。

一次性装（guest 内运行）：

```powershell
cd C:\nv
powershell -ExecutionPolicy Bypass -File .\install-tightvnc.ps1
# 默认 pw 123456，端口 5900
# 或: .\install-tightvnc.ps1 -Password 'mypw12' -Port 5901
```

宿主连：

```bash
./vnc-guest.sh                    # 自动探 IP，密码 123456
./vnc-guest.sh --port 5901 --password mypw12
```

区别：
- `vnc-vm.sh` = 连 QEMU 自己的 `-vnc` socket（宿主端口 5901+，`--no-gpu` 模式用）
- `vnc-guest.sh` = 连 **guest 内**的 TightVNC Server（guest IP:5900，无 mirror driver，无 Display 适配器）

trade-off：
- ✅ 设备管理器比 RDP 干净，没有 Microsoft Remote Display Adapter 混进来
- ✅ tvnserver 作为服务跑在 SYSTEM 下，不占 session
- ⚠️ 加了一个进程 `tvnserver.exe`（如果 DNF TP 扫进程名要改 service binary 名）
- ⚠️ GDI polling，帧率和色彩不如 H.264 AVC444 的 RDP；不适合打游戏，适合装软件/设置

---

> 下面是完整参考手册。按「从零到 DNF 可玩」的时间顺序写。前面 0–4 节是**一次性**操作；
> 5 节开始是**每次使用**要做的事；最后是故障排查。

宿主: Ubuntu 24.04 + Xeon E5-2696 v4 + NVIDIA RTX 2080 16GB (魔改) + AMD RX 570
Guest: Windows 10 LTSC (企业版)

---

## 0. 总体架构 & 关键文件

```
物理机 (Ubuntu 24.04)
├── AMD RX 570                     → 宿主 Ubuntu 显示 (amdgpu，独立于 NVIDIA)
├── NVIDIA RTX 2080 16GB (魔改)     → vgpu_unlock-rs 拆 N 个 2GB vGPU 实例
└── 每个 VM:
    ├── vGPU 伪装成 GTX 1050 / GT 1030
    ├── SMBIOS/CPU/SSD/NIC 指纹随机并固化到 vmN.conf
    └── 通过 br0 与宿主同网段，获真实 IP
```

关键目录:

| 位置 | 作用 |
|------|------|
| `build/qemu-system-x86_64` | 本项目定制版 QEMU v11.0.0 |
| `deploy/create-vm.sh` | 生成单台 VM 的硬件指纹 (vm-configs/vmN.conf) |
| `deploy/create-disk.sh` | 建 qcow2 盘 (厂家规格 512GB = 512×10⁹ 字节) |
| `deploy/start-vm.sh` | 启动 VM (install / no-gpu / rdp / gtk / sdl 五种模式) |
| `deploy/vm-configs/vmN.conf` | **只读**，VM 的硬件指纹 (UUID/序列号/MAC/CPU 型号) |
| `deploy/host/` | 宿主端一次性部署脚本 (vgpu_unlock / fastapi-dls / bridge) |
| `deploy/guest/spoof-inf/` | guest 里跑的 INF 驱动伪装 |
| `deploy/run/vmN.{pid,mon,qmp,log}` | 运行时 socket / pid / 日志 |
| `/home/ubuntu/images/vms/` | 所有 qcow2 盘 + 每 VM 独立的 `vmN_VARS.fd` |
| `/home/ubuntu/images/win10-ltsc.iso` | 默认安装 ISO |
| `~/Downloads/vGPU17.6/` | NVIDIA vGPU 17.6 驱动包 |
| `/opt/fastapi-dls/` | 本地 vGPU License 服务器 (Docker) |
| `/opt/vgpu_unlock-rs/` | vgpu_unlock-rs 源码与 build 产物 |
| `/opt/vgpu_unlock/libvgpu_unlock_rs.so` | 被 nvidia-vgpu-mgr `LD_PRELOAD` 的库 |
| `/etc/vgpu_unlock/profile_override.toml` | vGPU profile → 消费卡字段覆写 |

---

## 1. 宿主一次性部署（已做完，仅供重置/迁移时参考）

```bash
cd /home/ubuntu/projects/qemu

# 1.1 编译本项目定制 QEMU 11.0.0
./configure --target-list=x86_64-softmmu --enable-kvm --enable-vhost-net \
    --enable-vhost-user --enable-slirp --enable-tools --enable-vnc \
    --disable-docs --disable-gtk --disable-sdl \
    --prefix=/home/ubuntu/projects/qemu/install
(cd build && make -j20)

# 1.2 vgpu_unlock-rs: 让 RTX 2080 能做 vGPU 拆分，并把 vGPU 伪装成 1050/1030
SUDO_PASSWORD=123456 ./deploy/host/setup-vgpu-unlock.sh
sudo systemctl restart nvidia-vgpu-mgr

# 1.3 本地 vGPU License 服务器 (fastapi-dls)
SUDO_PASSWORD=123456 ./deploy/host/setup-fastapi-dls.sh
# 验证
curl -sk https://192.168.30.127/-/health        # 应该 {"status":"up"}

# 1.4 网桥 helper (br0 已经在 netplan 里)
SUDO_PASSWORD=123456 ./deploy/host/setup-bridge.sh
# 1.4.1 QEMU build tree 的 helper 需要在 bundle 路径下能找到 bridge.conf:
BUNDLE_ETC=/home/ubuntu/projects/qemu/build/qemu-bundle/home/ubuntu/projects/qemu/install/etc/qemu
mkdir -p "$BUNDLE_ETC" && ln -sfn /etc/qemu/bridge.conf "$BUNDLE_ETC/bridge.conf"
```

验证清单：

```bash
systemctl is-active nvidia-vgpu-mgr                  # active
systemctl show nvidia-vgpu-mgr --property=Environment # 包含 LD_PRELOAD=/opt/vgpu_unlock/libvgpu_unlock_rs.so
ls /sys/bus/pci/devices/0000:04:00.0/mdev_supported_types/ | head   # nvidia-256..nvidia-444+
ls -l /home/ubuntu/projects/qemu/build/qemu-bridge-helper  # rwsrwxr-x (setuid)
cat /etc/qemu/bridge.conf                             # allow br0
docker ps | grep fastapi-dls                          # healthy
ip -4 -o addr show br0                                # 192.168.30.127/24
```

---

## 2. 创建一台 VM

```bash
cd /home/ubuntu/projects/qemu/deploy

# 2.1 随机选平台 + 硬件池 + 生成序列号/UUID/MAC，写入 vm-configs/vm1.conf
./create-vm.sh 1

# 2.2 建 qcow2 盘 (默认 512GB 厂家规格；自定义: ./create-disk.sh 1 1024)
./create-disk.sh 1
```

**注意**: `vm-configs/vmN.conf` 被设为 444 只读。要换硬件指纹就 `./create-vm.sh 1 --force`，但同一块 qcow2 里装过的 Windows 会因为硬件变化需要重新激活。

---

## 3. 启动模式一览

| 模式 | 典型用途 | 是否挂 vGPU | 图形输出 |
|------|---------|-----------|---------|
| `--install <iso>` | 首次装系统 (旁路 vfio-pci，防 OVMF 枚举挂) | ❌ | std-vga + VNC |
| `--no-gpu` | 装驱动前/驱动故障时用 | ❌ | std-vga + VNC |
| `--rdp` | 生产：装完驱动后日常使用 | ✅ GTX 1050/GT 1030 | std-vga + VNC（登录用）+ RDP 接管 |
| `--gtk` / `--sdl` | 宿主本机桌面窗口（**最多同时 2 张物理 GPU 使用中**，且 **禁跑 DNF**） | ✅ | gtk/sdl 窗口 |

常用启动命令（脱离 shell，登出也不挂）：

```bash
cd /home/ubuntu/projects/qemu/deploy
nohup setsid ./start-vm.sh 1 --no-gpu --vnc :1 > run/vm1.log 2>&1 </dev/null & disown
```

或用 tmux：

```bash
tmux new -s vm1 -d 'cd /home/ubuntu/projects/qemu/deploy && ./start-vm.sh 1 --no-gpu --vnc :1'
tmux a -t vm1     # 看日志
# Ctrl-b d        # 断开但保留
```

### 停机

优雅关机（发 ACPI shutdown，等 Windows 自己关）：

```bash
echo 'system_powerdown' | socat - unix-connect:deploy/run/vm1.mon
```

硬关：

```bash
kill "$(cat deploy/run/vm1.pid)"
```

### 查看状态

```bash
ss -ltn | grep 590   # VNC 端口，默认 5901 = vm1
ps aux | grep qemu-system
tail -f deploy/run/vm1.log
```

### VNC 连接（Ubuntu 宿主上）

```bash
sudo apt install -y tigervnc-viewer
xtigervncviewer 192.168.30.127:5901   # vm1 默认 :1
```

---

## 4. 首次装 Windows 10 的流程

### 4.1 启动安装

```bash
cd /home/ubuntu/projects/qemu/deploy
nohup setsid ./start-vm.sh 1 --install --vnc :1 > run/vm1.log 2>&1 </dev/null & disown
```

### 4.2 VNC 连上后

1. OVMF 蓝色 logo → "Press any key to boot from CD/DVD..." → 按 Enter
2. Windows Setup 蓝界面：
   - 语言 = 中文 / 英文（决定后续时区、locale）
   - Install now → "I don't have a product key" → 选 LTSC
   - Custom: Install Windows only → 选 477 GiB 未分配盘 → Next
3. 装完自动重启进 OOBE → 建本地账户 → 桌面

### 4.3 重启后：启用 RDP 并拿 IP

在 Win10 里（VNC 操作）：

```powershell
# 管理员 PowerShell
# 打开 RDP
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
    -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup '远程桌面'       # 中文系统
# Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'  # 英文系统

# 创建密码 (RDP 不允许空密码登录)
# net user Administrator <your-pw> /active:yes

# 时区设成北京 (vGPU license 强依赖)
Set-TimeZone -Id 'China Standard Time'
w32tm /resync /force

# 拿 IP
ipconfig | findstr IPv4
```

把这个 IP 记住。下一步宿主这边用 RDP 连：

```bash
xfreerdp3 /v:<VM_IP> /u:Administrator /p:<pw> /dynamic-resolution /gfx:avc444 /size:1920x1080
```

### 4.4 关机换模式

```bash
# guest 里
shutdown /s /t 0
# 或 host 发 ACPI
echo 'system_powerdown' | socat - unix-connect:deploy/run/vm1.mon
sleep 8 && ps aux | grep qemu-system   # 确认退出
```

### 4.5 装 GRID 驱动之前：--no-gpu 再起一次，RDP 操作更顺

```bash
nohup setsid ./start-vm.sh 1 --no-gpu --vnc :1 > run/vm1.log 2>&1 </dev/null & disown
# RDP 连上
xfreerdp3 /v:<VM_IP> /u:Administrator /p:<pw> /dynamic-resolution
```

---

## 5. 在 Guest 里装 vGPU 17.6 驱动 + INF 伪装

### 5.1 把驱动和 token 传进 VM

宿主上生成 license token（给后面 5.4 用）：

```bash
curl -sk -o /tmp/client_configuration_token.tok https://192.168.30.127/-/client-token
```

然后把以下文件拷进 guest（SMB 共享 / SFTP / RDP 剪贴板拖拽均可）：

| 宿主路径 | guest 建议路径 |
|---------|--------------|
| `~/Downloads/vGPU17.6/Guest_Drivers/553.74_grid_win10_win11_server2022_dch_64bit_international.exe` | `C:\nv\553.74.exe` |
| `/tmp/client_configuration_token.tok` | `C:\nv\client_configuration_token.tok` |
| `deploy/guest/spoof-inf/inf-patch.ps1` | `C:\nv\inf-patch.ps1` |

### 5.2 Express Install GRID 驱动

guest 里双击 `C:\nv\553.74.exe`：

- 许可接受
- **Express (推荐)** —— 不要 Custom，Custom 容易漏装 `nvlddmkm.sys` / `nvwgf2umx.dll`
- 等安装完弹出"重启" → 重启

重启后 RDP 重新连（断几十秒正常），验证：

```powershell
# 管理员 PowerShell
nvidia-smi                                                 # 应该看到 RTX A6000 / RTX6000-2Q
Test-Path 'C:\Windows\System32\drivers\nvlddmkm.sys'       # True
Test-Path 'C:\Windows\System32\nvwgf2umx.dll'              # True
```

如果 `nvidia-smi` 认不出、Device Manager 黄感叹号，去 5.6 故障排查。

### 5.3 把 vGPU 伪装成消费卡（INF 改写）

```powershell
# 管理员 PowerShell
# 根据 vm-configs/vm1.conf 里的 GPU_PROFILE 选 profile:
#   gtx1050_2gb → 1050
#   gt1030_2gb  → 1030
#
# DriverRoot 指向 553.74 exe 自解压后的 Display.Driver 目录。
# Express 安装把驱动放在 C:\NVIDIA\DisplayDriver\553.74\<locale>\Display.Driver
C:\nv\inf-patch.ps1 -Profile gt1030_2gb `
    -DriverRoot "C:\NVIDIA\DisplayDriver\553.74\International\Display.Driver"
```

脚本做的事：

1. 备份 `nvdm*.inf` → `.bak`
2. 在 `[Strings]` 里加 `NVIDIA_DEV.1D01 = "NVIDIA GeForce GT 1030"`
3. 在 `[NVIDIA_Devices.NTamd64.*]` 段加 `PCI\VEN_10DE&DEV_1D01` 匹配项
4. `pnputil /delete-driver` 卸所有 NVIDIA oemNN.inf
5. `pnputil /add-driver ... /install` 用改过的 INF 重装

完成后重启。Device Manager 里应显示 `NVIDIA GeForce GT 1030`（或 1050）。

### 5.4 导入 License token

```powershell
# 管理员 PowerShell
Copy-Item C:\nv\client_configuration_token.tok `
    'C:\Program Files\NVIDIA Corporation\vGPU Licensing\ClientConfigToken\' -Force

Restart-Service NVDisplay.ContainerLocalSystem

# 1-2 分钟后确认
nvidia-smi -q | Select-String 'License'
# 应该看到: License Status : Licensed (Expiry: ... days N minutes)
```

宿主端也能看：

```bash
curl -sk https://192.168.30.127/-/leases | jq .
```

### 5.5 切到 --rdp 生产模式

关机：

```powershell
shutdown /s /t 0
```

宿主用 `--rdp` 启动（这次真挂 vfio-pci vGPU）：

```bash
cd /home/ubuntu/projects/qemu/deploy
nohup setsid ./start-vm.sh 1 --rdp --vnc :1 > run/vm1.log 2>&1 </dev/null & disown
# 等 30-60 秒 Windows 起来，RDP 接管
xfreerdp3 /v:<VM_IP> /u:Administrator /p:<pw> /dynamic-resolution /gfx:avc444 /size:1920x1080
```

RDP 连上后确认：

- `dxdiag` → 显示设备应该是 "NVIDIA GeForce GT 1030" (或 1050)
- `nvidia-smi` 依然 Licensed
- Device Manager 里没有黄感叹号

### 5.6 验证反虚拟化效果

guest 里跑：

```powershell
Get-CimInstance Win32_Processor | Select-Object Name, Family, Model, Stepping
# Name 应该是 'Intel(R) Core(TM) i5-6500 CPU @ 3.20GHz' 之类

Get-CimInstance Win32_ComputerSystem | Select-Object Model, Manufacturer, HypervisorPresent
# HypervisorPresent = False   (x-hv-stealth=on 的关键验证)

Get-CimInstance Win32_BaseBoard | Select-Object Manufacturer, Product, SerialNumber
# 应该看到 vm1.conf 里写的主板

Get-CimInstance Win32_PhysicalMemory | Select-Object Manufacturer, PartNumber, Speed, SMBIOSMemoryType
# SMBIOSMemoryType: 24=DDR3, 26=DDR4
```

CPU-Z / AIDA64 / GPU-Z 都可用来进一步肉眼核对。

---

## 6. 装 DNF 与 TP 过检

- 装 wegame / DNF 客户端
- 确认游戏能启动到登录
- 登录 → 选角 → 如能进图就是 TP 过检

**如果 TP 弹"检测到虚拟机"或启动直接退出**：查 `docs/DETECTION.md` 逐层排查。

---

## 7. 多 VM

同一张 RTX 2080 16GB 最多 8 个 2GB vGPU（魔改卡真实上限 16GB，不信 `available_instances` 的 24）。

```bash
./create-vm.sh 2
./create-disk.sh 2
# --vnc :2 等价于 tcp 5902
tmux new -s vm2 -d 'cd /home/ubuntu/projects/qemu/deploy && ./start-vm.sh 2 --no-gpu --vnc :2'
```

每台 VM 有独立的：UUID / 序列号 / MAC / GPU profile 伪装 / CPU 型号 —— 互相不冲突。

**硬约束**: RDP 生产模式下最多 1 台同时开（只有 1 张物理 NVIDIA）；`--gtk` / `--sdl` 模式可并 2 台（用于人工调试，禁跑 DNF）。

---

## 8. 宿主重启后需要重做的

`setup-bridge.sh` 的 setuid 和 `/etc/qemu/bridge.conf` 都是持久化的；
`netplan` / fastapi-dls (`restart: always`) / nvidia-vgpu-mgr (systemd enabled) 都会自启。
**不需要重做任何事**，直接 `./start-vm.sh` 就能用。

例外：nvidia 驱动版本被内核 apt upgrade 动过 → 需要重跑 `./deploy/host/setup-vgpu-unlock.sh` 校准。

---

## 9. 故障排查速查

### 9.1 VM 启不起来

```bash
tail -30 deploy/run/vm1.log         # 看 QEMU stderr
```

| 现象 | 原因 | 修法 |
|------|------|------|
| `invalid option -no-hpet` | QEMU 11 语法变了 | start-vm.sh 已改用 `hpet=off`；重新 pull |
| `bridge helper failed` | `/etc/qemu/bridge.conf` 缺 `allow br0` 或 helper 没 setuid | 重跑 `setup-bridge.sh` |
| `enforce` + `Host doesn't support requested features` | Broadwell 宿主缺 Skylake 指令 | start-vm.sh 已去 enforce；重新 pull |
| `SIGABRT` / vfio-pci 冲突 | vfio-pci 绑错；或 vGPU 先被别的 VM 占了 | `lsof /sys/bus/mdev/devices/*`；清 stale mdev |

### 9.2 VNC 连不上 / 黑屏

```bash
ss -ltn | grep 5901                 # LISTEN 才有戏
ps aux | grep qemu-system           # 确认 QEMU 还活着
```

- QEMU 活着但 VNC 黑屏 → 没按 Enter 触发 CDROM 引导。OVMF 里 Esc 进 Boot Manager 手选 DVD。
- `EFI Shell` 卡住 → 在 shell 敲 `exit` 回到 menu，再选 DVD。

### 9.3 GRID 驱动 Code 43 或半装

- 症状: Device Manager 黄感叹号 / `nvidia-smi` 找不到设备。
- 第一步检查 `nvlddmkm.sys` 和 `nvwgf2umx.dll` 是否都在（Express Install 常漏其一）。
- 用 DDU（安全模式）干净卸载 → 关机 → `--no-gpu` 启动 → Express 重装 → 再切 `--rdp`。

### 9.4 License 认证失败

- 确认宿主上 `curl -sk https://192.168.30.127/-/leases` 里有本 VM 的 MAC/UUID。
- **时区**：guest 和 host 必须同时区。用 `Set-TimeZone -Id 'China Standard Time'` + `w32tm /resync /force`。
- 重启 `NVDisplay.ContainerLocalSystem` 服务：
  ```powershell
  Restart-Service NVDisplay.ContainerLocalSystem
  ```

### 9.5 RDP 连不上

- `Test-NetConnection <VM_IP> -Port 3389` 看 VM 端口是否开
- VNC 里确认 Windows 网络类型是"专用网络" (Private)，不是"公用网络"
- 检查 `TermService` / `UmRdpService` 是否在跑：`Get-Service TermService, UmRdpService`
- 换成明确密码：RDP 不允许空密码 (组策略可改但不建议)

### 9.6 DNF TP 弹虚拟机警告

1. `Get-CimInstance Win32_ComputerSystem | % HypervisorPresent` 必须是 `False`。如是 True → 确认 `x-hv-stealth=on` 在 QEMU 命令行里：
   ```bash
   ps aux | grep qemu-system | grep -o 'x-hv-stealth=[a-z]*'
   ```
2. 检查 brand string：`Get-CimInstance Win32_Processor | % Name` 必须是真 i5-6500 等。
3. SMBIOS：`wmic csproduct get vendor,name` 不能有 "QEMU"/"VirtualBox"/"VMware" 字样。
4. 显卡名：`dxdiag` 里必须显示 GTX 1050 / GT 1030。
5. MAC 前缀：`Get-NetAdapter | % MacAddress` 不能是 `52:54:00:*`（是真 Intel OUI）。
6. DDR 类型：`Get-CimInstance Win32_PhysicalMemory | % SMBIOSMemoryType` 不能是 0 或 2（是 24=DDR3 或 26=DDR4）。

都正确仍挡？查 `docs/DETECTION.md` 更深层的检测面（ACPI / MSR / RDTSC jitter）。

---

## 10. 手动监控 / 调试

```bash
# QMP 查看 CPU 寄存器状态
socat - unix-connect:deploy/run/vm1.qmp
{"execute":"qmp_capabilities"}
{"execute":"query-cpus-fast"}

# HMP monitor
socat - unix-connect:deploy/run/vm1.mon
(qemu) info cpus
(qemu) info pci
(qemu) info registers
(qemu) system_powerdown
(qemu) quit

# 宿主 KVM 统计
sudo perf kvm --host stat live       # vm-exit 分布
sudo journalctl -fu nvidia-vgpu-mgr  # vgpu-unlock hook 日志
docker logs -f $(docker ps -q --filter name=fastapi-dls)
```

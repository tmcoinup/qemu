# 使用手册

## 入口脚本

```
./deploy/start-vm.sh   <vm_id>           # 一条龙：起 VM + (按需)setup-guest + SDL2 viewer
./deploy/stop-vm.sh    <vm_id>           # 关 VM (Ctrl+C 也行)
./deploy/service.sh    <vm_id> <action>  # NvDisplayContainer 服务控制
                                         #   action = stop | start | status | restart
```

`start-vm.sh 1` 干的事（默认 rdp 模式）：

1. QEMU 后台跑（`tail -f /tmp/vm1.log` 看 stderr）
2. 后台 setup-task：等 guest WinRM → 拿 5 个状态信号 (svc/sys/ver/err/lic) → 状态机分支
3. 前台 SDL2 viewer 立刻弹（splash spinner + 计时器，等 ring 第一帧）
4. 退出：`Ctrl+C` / 关 SDL2 窗口 / 另一终端 `./stop-vm.sh 1`，三条都会兜底关 QEMU + 释放 mdev

GNOME/Ubuntu 桌面下，`start-vm.sh` 会启用 viewer 侧的动态宿主快捷键保护：只有当鼠标在 VM 窗口内时，才临时关闭宿主侧 `Super`/`Meta` 和 `Alt+Tab` 类 GNOME/IBus 快捷键；鼠标移出、最小化、隐藏或退出都会立即恢复宿主按键。需要完全保留宿主快捷键行为时加 `--no-tame-gnome`。

### setup-task 决策矩阵

| 检测到的 guest 状态 | 动作 |
|---|---|
| `nvlddmkm.sys` 缺 / driver 版本 ≠ `31.0.15.5324` | SPOOF_MODE=A: 警告"用 --no-spoof 重启装 driver"；B/off: 跑 `setup-guest` 装 |
| driver 完整但 `Win32_VideoController` Error 43 + 未 Licensed | 跑 `install-vgpu-license.sh` 装 token + 重启 license daemon |
| service 装着但 stopped | `Start-Service NvDisplayContainer` |
| service 没装 | 跑 `setup-guest --skip-vgpu --skip-ivshmem --skip-stealth --skip-monitor` |
| 全 OK (sys+ver+lic+svc) | 跳过 |

## SPOOF_MODE：方案 A / B / off

```bash
./deploy/start-vm.sh 1                       # 默认 A
./deploy/start-vm.sh 1 --spoof-name-only     # B
./deploy/start-vm.sh 1 --no-spoof            # off
./deploy/start-vm.sh 1 --spoof-mode A|B|off  # 显式指定

# 永久 per-VM：在 $VM_ROOT/configs/vm1.conf 加一行
echo 'SPOOF_MODE=B' >> /home/ubuntu/images/vms/configs/vm1.conf
```

| 方案 | PCI vendor/device/subsys | 注册表 Name | driver 工作？ | 反虚拟化效果 |
|---|---|---|---|---|
| **A** | 改成 GT 1030 (`DEV_1D01` 等) | "GeForce GT 1030" | 看 license + grid INF 是否扛得住 | 最彻底 |
| **B** | 真 RTX 6000 (`DEV_1E30`) | "GeForce GT 1030" | 最稳 | GPU-Z 等查 PCI ID 会暴露 |
| **off** | 真 RTX 6000 | 真 "NVIDIA GRID RTX6000-2Q" | 最稳 | 完全不隐身（装 driver 阶段必用） |

**装 driver 阶段必须 `--no-spoof` (off)**——A 模式下 vfio 把 PCI 改成 `DEV_1D01`，GRID 553.24 的 INF 不匹配消费卡 ID，installer 直接返 `-436207360`。

## setup-guest 6 步详情（自动调用，也能单跑）

```bash
./deploy/setup-guest.sh <vm_id>
```

| 步 | 干啥 | 跳过 flag |
|---|---|---|
| 1 | vGPU 17.4 GRID 553.24 driver（卸 NVIDIA INF + 拷文件 + 装 + 写注册表 block WU 替换） | `--skip-vgpu` |
| 2 | License token (从 host fastapi-dls 拉 + 推到 guest token 路径 + Restart NVDisplay daemon) | `--skip-license` |
| 3 | ivshmem.sys driver | `--skip-ivshmem` |
| 4 | NvDisplayContainer 服务 + nv_stream_relay + AudioSvcHost；注册表 `DesktopWidth/Height=1920/1080` + `FrameRate=60` | `--skip-service` |
| 5 | GPU 名字 spoof → `GeForce GT 1030`（含 RefreshGridNames Scheduled Task） | `--skip-stealth` |
| 6 | Monitor EDID spoof → `SAMSUNG S24F350` | `--skip-monitor` |

可选自定义：
```bash
./deploy/setup-guest.sh 1 --gpu-name "GeForce GTX 1050"
./deploy/setup-guest.sh 1 --monitor dell-p2419h           # 或 lg-27uk850 / generic-1080p
./deploy/setup-guest.sh 1 --skip-vgpu --skip-ivshmem      # 重跑只刷 service + spoof
```

> **注意**：装完 vGPU 驱动后会重启 guest，setup 自动等 WinRM 重连。

## 日常工作流

```bash
./deploy/start-vm.sh 1                  # 起 + 自动检测/装 + viewer
# ... 用 ...
# Ctrl+C  或  另一终端 ./deploy/stop-vm.sh 1
```

### 玩反作弊敏感游戏（DNF）前
```bash
./deploy/service.sh 1 stop              # stream 服务停掉，0 GPU 0 网络 0 设备 listener
# ... 玩游戏 ...
./deploy/service.sh 1 start             # 玩完恢复
```

## 调试

| 现象 | 看哪 / 怎么 |
|---|---|
| 黑屏不显示 | `./deploy/service.sh 1 status` 看进程 + 服务状态 |
| 键盘不工作 | `STREAM_DEBUG=1 ./deploy/connect.sh 1` 把每个 SDL keysym + RFB keysym trace 到 stderr |
| Super 仍被宿主吃掉 | 确认鼠标在 VM 窗口内；动态 guard 会临时关闭宿主 `Super`/`Meta` 绑定 |
| Alt+Tab 仍被宿主吃掉 | 确认鼠标在 VM 窗口内；动态 guard 会临时关闭宿主 `switch-windows` 绑定 |
| 想看 ring 状态 | `./deploy/nv-shmem/nv_shmem_probe /dev/shm/nv-shmem-vm1` |
| 服务/relay 日志 | guest 内 `Get-Content C:\nv\nv-svc.log` 和 `C:\nv\nv-stream-relay.log` |
| ivshmem 没数据 (writer_seq=reader_seq) | `./deploy/service.sh 1 restart` |

## 数据通路

```
guest:
  vGPU desktop ─DDA→ D3D11 staging ─Map→ BGRA bytes
                                          │
                                          ▼ FNV-1a tile hash 与上一帧对比
                                          │
                                          ▼ dirty 32×32 tiles → ivshmem video ring
                                          │
host:                                     │ (KVM 直接 page mapping，纯 RAM-to-RAM)
                                          │
  /dev/shm/nv-shmem-vmN ◄─────────────────┘
       │
       └─ stream_client_dda (SDL2): SDL_UpdateTexture per dirty tile + present
       └─ X11 input events (key + mouse) ─→ ivshmem input ring
                                                    │
                                                    ▼ guest
                                                AudioSvcHost (local 127.0.0.1)
                                                    │
                                                    ▼ Win32 SendInput
                                                guest desktop
```

零 mpv / ffmpeg / NVENC / 编解码库 / TCP listener (除 service 内部 127.0.0.1 短连)。

## 其它工具

| 命令 | 用途 |
|---|---|
| `./deploy/install-vgpu-driver.sh 1` | 单独重装 vGPU 驱动 |
| `./deploy/install-ivshmem-driver.sh 1` | 单独装 ivshmem driver |
| `./deploy/install-nv-service.sh 1` | 单独刷 service binary |
| `./deploy/create-vm.sh <vm_id>` | 生成 $VM_ROOT/configs/vmN.conf（一次性，VM_ROOT 默认 /home/ubuntu/images/vms） |

## 常见坑

- **vGPU 显示 Error 43**：8/14/2024 之后的 GeForce DCH driver 在 vGPU passthrough 上拒绝工作。`./deploy/install-vgpu-driver.sh 1` 能完成 wipe + 重装 GRID 553.24。
- **vGPU mdev 分配失败** (`mdev_allocate failed`)：多半 sudo 没暖。`SUDO_PASSWORD=123456 ./deploy/start-vm.sh 1`。
- **磁盘满** (`/dev/nvme0n1p3 100%`)：guest qcow2 写阻塞 → boot 卡。检查 `/home/ubuntu/images/vms/` 有没有遗留的 `*.bak-*` / `*.broken-*` / `win10-ok.qcow2`（旧版本 down.sh 自动备份留下的，现已废弃）。
- **ivshmem 已被占** (relay 反复 `REQUEST_MMAP failed: 548`)：旧 relay 孤儿没退。NvDisplayContainer 启动会自动 kill 同名孤儿；手动可 `./deploy/service.sh 1 restart`。

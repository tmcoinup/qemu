#!/bin/bash
# ---------------------------------------------------------------------------
# start-vm.sh ——— 一键启动隐身 QEMU/KVM Windows 客机
#
# 客机伪装成裸金属：随机 AM4 主板（ASRock/MSI/ASUS 池）+ AMD Ryzen 3 + 8GB
# DDR4 双通道 + Samsung 970 PRO 512GB NVMe + virtio-gpu 改名 GTX 1050。
#
# 用法（最简）：
#     ./start-vm.sh 1                       # 启动 instance 1，桥接 br0
#                                           # 默认 SDL 窗口 + fb-shm 推流并存
#                                           # 推流 socket: /tmp/qemu-stealth-1.fb
#     ./start-vm.sh 2 --iso=/path/x.iso     # instance 2 从 ISO 装系统
#     ./start-vm.sh 1 --no-sdl              # 后台 daemon：关 SDL，仅推流
#     ./start-vm.sh 1 --headless            # VNC 远程 + fb-shm（无本地窗口）
#     ./start-vm.sh 1 --no-fb-shm           # 关推流，仅 SDL（回历史行为）
#     ./start-vm.sh 1 --no-bridge           # 用 user-mode NAT 而不是 br0
#     ./start-vm.sh 1 --reroll              # 重新随机硬件身份
#     ./start-vm.sh 1 --fb-shm-roi=0,0,1920,1080 --fb-shm-rate=60
#     ./start-vm.sh 1 --proxy               # 启用 QEMU 原生 QMP multi-client
#                                           # 兼容别名: /tmp/qemu-stealth-1.qmp.proxy
#     ./start-vm.sh 1 --no-host-tune        # 跳过起前的 host 调优(默认会自动跑)
#     ./start-vm.sh 1 --hotkey-capture      # SDL 窗口里按 F4 -> fb-shm 抓 PNG
#                                           # 存 $VM_DIR/captures；--hotkey-capture=F2 改键
#
# 边玩边拉流到 ffmpeg / NVENC：
#     ./start-vm.sh 1                       # SDL 窗口照常出现，可直接玩
#     scripts/qemu-fb-shm-stream.py --sock /tmp/qemu-stealth-1.fb \\
#         --output 'rtmp://ingest/live/vm1' --encoder h264_nvenc --bitrate 6M
#
# 默认值（90% 情况都不用改）：
#     BRIDGE=br0           桥接 br0（不存在自动回退到 user-mode NAT）
#     STABLE_DISPLAY=1     virtio-vga（无 GL，规避 virgl BSOD；ACE/腾讯反作弊友好）
#     GPU_SELFSIGNED=0     PCI 主 ID 留 1AF4:1050 + subsys 改 NVIDIA 1C8110DE
#                          (子系统级 NVIDIA 改名，搭配 stock virtio-win 0.1.266
#                          + apply-gpu-spoof.ps1 注册表覆盖 = 通过 ACE 13-131106-0)
#     CPU_MODEL            读 profile，首次生成默认 Ryzen3-1200
#
# 硬件身份只在首次启动时随机一次，写到
#     /home/ubuntu/images/vms/<N>/profile
# 之后所有启动复用，让 Windows / 反作弊看见永远同一台机器。
# 想换身份: deploy/scripts/reroll-identity.sh <N>  或者直接删 profile 文件。
#
# 显示后端 — 两条独立通道，默认全开：
#     SDL 窗口（默认开）   本地交互窗口；DNF 等需要直接玩游戏的场景用。
#                          --no-sdl 关；--headless 自动关并启 VNC 替代。
#     fb-shm 推流（默认开）零拷贝共享内存推流，guest 完全不可见。
#                          外部进程连 unix socket 拿 memfd+eventfd，配合
#                          scripts/qemu-fb-shm-stream.py → ffmpeg/NVENC
#                          推 RTMP / UDP / SRT / 本地 mp4。--no-fb-shm 关。
#     --headless           关 SDL，开 VNC（fb-shm 仍照常）。
#
# 环境变量（不常用，默认就好）：
#     RAM=8192             客机内存 MiB（默认 8192）
#     CPUS=4               vCPU 数量（默认 4，cores=4 threads=1 sockets=1）
#     SDL=1                SDL 窗口开关（默认 1） (flag: --sdl / --no-sdl)
#     HEADLESS=1           关 SDL 启 VNC                          (flag: --headless)
#     BRIDGE=br0           桥接网卡名字                          (flag: --bridge=br0)
#     ISO=<path>           安装 ISO 路径                         (flag: --iso=<path>)
#     DISK=<path>          qcow2 磁盘路径                        (flag: --disk=<path>)
#     QEMU=<path>          qemu-system-x86_64 二进制路径         (flag: --qemu=<path>)
#     EXTRA_ISO=<path>     副 CDROM（autounattend.xml / 驱动盘 等）
#     STABLE_DISPLAY=0     SDL 模式下允许 virtio-vga-gl + virgl 3D（fb-shm 模式
#                          用不到此项；fb-shm 始终走 stable virtio-vga）
#     GPU_SELFSIGNED=1     PCI 主 ID 改成 NVIDIA 10DE:1C81。 ⚠️ 需要 patched
#                          viogpudo + 伪 NVIDIA CA 链；ACE/腾讯反作弊判异常
#                          (13-131106-0)。只用于轻反作弊场景。
#     CPU_MODEL=Ryzen3-2300X  覆盖 profile 写入的 CPU 型号（一般不用）
#     FB_SHM_SOCK=<path>   fb-shm 控制 socket 路径
#                          默认 /tmp/qemu-stealth-<N>.fb
#                          (flag: --fb-shm-sock=<path>)
#     FB_SHM_RATE=60       fb-shm 目标帧率 Hz，clamp [1,240]
#                          (flag: --fb-shm-rate=<hz>)
#     FB_SHM_ROI=x,y,w,h   只截 ROI 推流（省 CPU/带宽）。空 = 全屏
#                          (flag: --fb-shm-roi=x,y,w,h)
#     PROXY=1              启用 QEMU 原生 QMP multi-client（默认 0）
#                          (flag: --proxy / --no-proxy)
#                          ${QMP_SOCK} 可多客户端并发；同时创建
#                          ${QMP_SOCK}.proxy 兼容旧工具配置
#     HOST_TUNE=1          起 VM 前自动跑 host-performance.sh 压计时抖动（默认 1）
#                          (flag: --host-tune / --no-host-tune)
#                          governor=performance + halt_poll=500000 + THP defrag=never，
#                          缓解 ACE「游戏计时异常」(13-131130-8)。只动 host 侧，零反检测
#                          影响；已调优自动跳过(免每次 sudo)；DRY_RUN 下 no-op。
#     CPU_FREQ_CAP=1       把 host scaling_max_freq 封顶到本实例伪装 CPU 的上限
#                          (CPU_MAX_MHZ=SMBIOS Type4 max-speed)（默认 1，需 HOST_TUNE=1）
#                          (flag: --freq-cap / --no-freq-cap)
#                          防 guest 实测吞吐超出该型号规格(超规格=变速器/计时异常 tell)。
#                          只降不升：多 VM 并发收敛到运行中最小，绝不让任一 VM 超自身规格。
#     HOTKEY_CAPTURE=1     SDL 窗口里按 HOTKEY_KEY 时从 fb-shm 抓 PNG（默认 0）
#                          (flag: --hotkey-capture[=KEY] / --no-hotkey-capture)
#     HOTKEY_KEY=F4        触发键名（X keysym），默认 F4
#                          PNG 存 $VM_DIR/captures；日志 ${HOTKEY_LOG}
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# When running from deploy/scripts/, the QEMU repo root is two levels up.
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/stealth-lib.sh"

_usage() {
    sed -n '2,/^# --*$/p' "$0" | sed -e 's/^# *//' -e 's/^#$//' >&2
    exit "${1:-2}"
}

# ------------------------------------------------------------------
# 重构 P1#5：主体按职责拆入 lib/sv-*.sh，按原执行顺序 source（同一 shell、
# 共享 $@ 与全局变量，与单文件版逐字节等价；DRY_RUN argv harness 校验）。
# ------------------------------------------------------------------
source "$HERE/lib/sv-cli.sh"        # CLI 解析 + 默认值 + 目录 / RANDOM 种子
source "$HERE/lib/sv-portability.sh" # 迁移 host 预检：路径/QEMU 能力，不做隐身降级
source "$HERE/lib/sv-identity.sh"   # 启动源 + 硬件身份 profile + OVMF + ACPI 表
source "$HERE/lib/sv-hosttune.sh"   # (可选,默认开) host 压抖动 + 按伪装 CPU 封顶频率
                                    #   ↑ 必须在 identity 之后: 频率封顶要用 CPU_MAX_MHZ
source "$HERE/lib/sv-tpm-mem.sh"    # TPM(swtpm) + DIMM 拓扑 / 内存 / SMBIOS / AMD DF
source "$HERE/lib/sv-devices.sh"    # 平台 PCI ID + 显示/EDID + 启动序 + CDROM + 网络 + USB + 音频
source "$HERE/lib/sv-dock.sh"       # GNOME dash-to-dock 集成：每实例独立可固定/可排序图标(SDL 窗口)
source "$HERE/lib/sv-assemble.sh"   # 组装 QEMU argv + (DRY_RUN 出参) + 守护进程 + exec

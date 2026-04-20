# QEMU 9.2.0 深度反虚拟化部署包

本部署包给 QEMU 9.2.0 打一组补丁，让 Win10 客机看起来像一台 AMD Ryzen 3 1200 裸机工作站，专门针对 DNF 反作弊（XignCode3）的 0x403 检测。

## 伪造身份

| 部件            | 伪造值                                                  |
|-----------------|----------------------------------------------------------|
| CPU             | AMD Ryzen 3 1200（Zen 1 Summit Ridge，4 核 4 线程）      |
| CPUID 厂商      | AuthenticAMD，family 23 model 1 stepping 1               |
| Hypervisor bit  | 清零（kvm=off、hypervisor=off）                          |
| KVM/HV 叶       | `0x40000000..0x400000ff` 从 CPUID 扫掉                   |
| 主板            | 随机 ASUS / MSI / Gigabyte / ASRock 的 AM4 板            |
| BIOS            | American Megatrends Inc.（版本号、日期随机）             |
| 内存            | 8 GiB 合计，2×4 GiB Kingston HyperX Fury DDR4-2666（A/B 通道） |
| NVMe            | Samsung SSD 970 PRO 512GB，固件 `1B2QEXM7`（PCIe 3.0 x4）|
| 网卡            | e1000e（Intel 82574L），MAC 随机                         |
| ACPI OEM ID     | `ALASKA` / `A M I   `                                    |
| 显示            | virtio-vga-gl（Mesa / VirGL 3D 加速）                    |

## 目录结构

```
deploy/
├── docs/
│   ├── README.md          # 当前文件
│   ├── USAGE.md           # 中文使用手册（前置依赖 / 启动 / QMP / 排错）
│   ├── NOTES-GPU.md       # 客机侧 GPU 改名方案说明
│   └── VERIFY.md          # DNF 检测面清单
├── patches/
│   ├── 0001-cpu-add-ryzen3-1200.patch
│   ├── 0002-kvm-strip-hypervisor.patch
│   ├── 0003-acpi-oem-spoof.patch
│   ├── 0004-nvme-samsung-id.patch
│   ├── 0005-pci-ids.patch
│   ├── 0006-smbios-dual-channel-bank.patch
│   └── combined-stealth.patch   # 以上六个合并成一份
├── scripts/
│   ├── stealth-lib.sh            # SMBIOS / MAC / OEM 字符串的随机池
│   ├── win10-ryzen3-stealth.sh   # 主启动器（支持多实例）
│   ├── host-performance.sh       # 每次开机跑一次的主机调优
│   ├── setup-bridge.sh           # 一次性桥接配置（br0 + bridge.conf ACL）
│   ├── reroll-identity.sh        # 删除 .profile，让硬件身份重新随机
│   ├── qmp-frame.sh              # QMP 客户端：截图 / 发按键 / savevm
│   ├── verify-stealth.sh         # 离线检查 CPUID / 字符串是否符合预期
│   ├── guest-gpu-spoof.reg       # 客机注册表：GPU 改名（legacy，不推荐）
│   └── apply-gpu-spoof.ps1       # 推荐：改注册表 + 装开机任务计划
└── tools/
    ├── apply-patches.sh          # 幂等打补丁，然后 exec build.sh
    └── build.sh                  # configure + ninja；支持 --clean/--reconfig/--debug/--verify
```

## 快速上手

```bash
# 1. （每次开机一次）主机性能调优 + 大页
sudo deploy/scripts/host-performance.sh

# 2. （每台主机一次）桥接网络，让客机拿到上游路由器的真实 LAN IP
sudo deploy/scripts/setup-bridge.sh                # 隔离 br0，或
sudo UPLINK=enp5s0 deploy/scripts/setup-bridge.sh  # 把 enp5s0 接到 br0

# 3. 首次装系统：从 ISO 启动，硬件身份随机生成并落盘保存
deploy/scripts/win10-ryzen3-stealth.sh 1 --iso=/home/ubuntu/images/win10.iso

# 4. 后续启动（硬件身份从 stealth-inst1.profile 加载，保证每次一致）
deploy/scripts/win10-ryzen3-stealth.sh 1
deploy/scripts/win10-ryzen3-stealth.sh 2

# 5. 重新随机硬件身份（例如被封后换一套身份，可选）
deploy/scripts/reroll-identity.sh 1
#   或单次：deploy/scripts/win10-ryzen3-stealth.sh 1 --reroll

# 6. 通过 QMP 对实例 1 截图
deploy/scripts/qmp-frame.sh 1 screenshot /tmp/vm1.png

# 7. 提交配置前的离线自检
deploy/scripts/verify-stealth.sh
```

## 每实例资源

| 实例 | QMP socket                | HMP socket                | VNC 端口   | Spice 端口 | SSH 转发          |
|------|---------------------------|---------------------------|------------|------------|--------------------|
| 1    | /tmp/qemu-stealth-1.qmp   | /tmp/qemu-stealth-1.mon   | 5900       | 5931       | 127.0.0.1:10023   |
| 2    | /tmp/qemu-stealth-2.qmp   | /tmp/qemu-stealth-2.mon   | 5901       | 5932       | 127.0.0.1:10024   |
| N    | /tmp/qemu-stealth-N.qmp   | /tmp/qemu-stealth-N.mon   | 5900+N−1   | 5930+N     | 127.0.0.1:10022+N |

每个实例都有独立的 OVMF_VARS 副本、独立的 qcow2 overlay，**以及独立的 `stealth-instN.profile`**——这是一个纯文本文件，把随机生成的硬件身份（主板序列号、MAC、UUID、NVMe 序列号……）固化下来，保证 Windows 和 DNF 每次重启看到同一台"PC"。删除这个文件（或跑 `reroll-identity.sh N`）即可强制换一套身份。

## 已知限制 / 注意事项

* DNF 的 0x403 拒绝来自 CPUID、WMI（`Win32_BaseBoard` / `Win32_VideoController`）以及驱动层探测的混合检查。本包里的 QEMU 补丁封堵了 CPUID、SMBIOS、ACPI 和 NVMe 这几面；**客机侧 GPU 描述字段伪造仍需在 Windows 里单独做**（没有真实 NVIDIA 硬件可以直通），细节见 `NOTES-GPU.md`。
* 本包基于 `v9.2.0` tag。对 master 打补丁大概率会在 `target/i386/cpu.c` 冲突（那个区域改动很频繁）。
* CPUID 里抹掉 hypervisor 叶只在 `expose_kvm=false` 时生效——永远在 `-cpu` 行里加 `kvm=off`。启动器已经帮你加好。

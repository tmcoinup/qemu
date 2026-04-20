# GTX 1050 外观一致性方案（virtio-gpu + virtio-win 联合改造）

本文件是 NOTES-GPU.md 的工程实现篇。NOTES 回答 "为什么"；本文件回答
"改哪些源码 / INF / 注册表，以及验证它真的变成了 GTX 1050"。

目标：

* QEMU 侧：virtio-vga(-gl) 的 PCI 配置头暴露 10DE:1C81 作为 subsystem，
  revision = 0xA1（和真 GP107 一致），VEN/DEV 保持 1AF4:1050。
* Windows 侧：`viogpudo.sys` 正常绑定，设备管理器 / DxDiag /
  `Get-CimInstance Win32_VideoController` 全部显示 **NVIDIA GeForce GTX 1050**。
* 不引入任何会破坏 virtio 规范的改动；去掉全部定制后客机仍是一块
  标准 virtio-gpu。

---

## 第一部分：可行性结论

1. **virtio-gpu 能真的变成 GTX 1050 吗？** —— 只能在"名字 / subsystem /
   revision"这三层变。GPU 行为（CUDA、NvEnc、Optimus）做不到，因为我们没有
   NVIDIA 内核驱动、也没有 GP107 的 MMIO 行为。
2. **能做**：
   * PCI SUBSYS_VENDOR / SUBSYS_DEVICE 伪装（本补丁实现）
   * PCI REVISION_ID 伪装（本补丁实现）
   * EDID 里的显示器 vendor/name 伪装（已由 0007 补丁实现）
   * INF 里的 DeviceDesc / ProviderName / HardwareInformation 字串
   * Windows 注册表 Class + Enum 节点的 FriendlyName / DeviceDesc
   * DxDiag / WMI / 任务管理器读到的字符串
3. **做不到**：
   * 用 NVIDIA 原生驱动 — NVIDIA 驱动会走 VBIOS / MMIO 探测并拒绝
   * NvAPI / nvml.dll / CUDA / NvEnc — 这些调用会失败
   * 任何走 PCI_COMMON_CONFIG 自己重算 BAR 大小的内核态枚举
4. **如果把 PCI VEN/DEV 改成 10DE:1C81 会怎样？** —— virtio-win 的
   INF 里 Hardware ID 是 `PCI\VEN_1AF4&DEV_1050`，不匹配 → 驱动不加载 →
   Windows 回落到 BasicDisplay → 分辨率 1024x768 + 无 3D。NVIDIA 官方
   INF 同时会拒绝绑定（因为设备不是真的 NVIDIA 硬件，后续 IOCTL 全部
   返回错）。**所以 VEN/DEV 必须保持 1AF4:1050**。
5. **最可落地的方案**：**不改 VEN/DEV，改 subsys + revision + INF + 注册表**。
   本文件描述的就是这一条。

---

## 第二部分：QEMU 源码调用链（v9.2.0）

关键结构：

* `VirtIOPCIProxy` (`include/hw/virtio/virtio-pci.h:135`)
  virtio PCI 代理。本补丁新增 `x_subsys_vendor_id / x_subsys_device_id /
  x_pci_revision`（UINT32_MAX 表示未覆盖）。
* `PCIDeviceClass` (`include/hw/pci/pci_device.h:37`)
  PCI 设备类默认值：`subsystem_vendor_id / subsystem_id` — 类级默认。
* `VirtIOGPUBase` (`include/hw/virtio/virtio-gpu.h:139`) — scanouts / EDID /
  virtio_config。
* `VirtIOVGABase` / `VirtIOGPUPCIBase` — VGA 包装层与纯 virtio-gpu-pci。

实例化链 (virtio-vga 示例)：

```
qemu_type_init("virtio-vga")
 -> virtio_pci_types_register()
 -> .class_init = virtio_vga_base_class_init()
    -> pcidev_k->class_id = PCI_CLASS_DISPLAY_VGA  (0x0300)
    -> pcidev_k->romfile  = "vgabios-virtio.bin"
 -> device_add virtio-vga
    -> virtio_pci_realize()                 (hw/virtio/virtio-pci.c:1943)
       -> if (legacy):  pci_set_word(SUBSYSTEM_ID, vdev_id = 16)
       -> else:         pci_set_word(VENDOR, 0x1AF4)
                        pci_set_word(DEVICE, 0x1050)
                        pci_config_set_revision(1)
       -> ** 本补丁：UINT32_MAX 哨兵检查，覆盖 SUBSYS_* + REVISION **
       -> virtio_pci_bus_new() ; k->realize (= virtio_vga_base_realize)
          -> vga_common_init()
          -> pci_register_bar(#0 = framebuffer)
          -> qdev_realize(VirtIODevice)
             -> virtio_gpu_base_device_realize()
                -> virtio_init(VIRTIO_ID_GPU, sizeof(virtio_gpu_config))
                -> virtio_add_queue(ctrl_vq, 64 or 256)
                -> graphic_console_init()
          -> pci_std_vga_mmio_region_init()
```

客机读这些字段的路径：

* **VEN/DEV/SUBSYS/REV**：guest 走 PCI 配置空间 (`0xCF8/0xCFC` 或 MMCFG)，
  从 PCI root port 路由到 virtio-vga 的 BDF。Windows PnP 管理器读
  DEV/VEN 后拼 Hardware ID (`PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8110DE&REV_A1`)。
* **Class code**：`pci_config_set_class(config, PCI_CLASS_DISPLAY_VGA)`，
  guest lspci / SetupAPI 读出来的类别是 VGA (0x03).
* **framebuffer**：BAR0 的 prefetchable memory，vga_init + pci_register_bar
  在 guest 侧就是显存。
* **virtio 队列**：BAR2 / BAR4 中的 modern common / isr / notify / device 区。

哪些字段**绝不能改**（否则 virtio-win 驱动失配）：

| 字段                | 值          | 备注                       |
|---------------------|-------------|----------------------------|
| `PCI_VENDOR_ID`     | `0x1AF4`    | INF 的 VEN_*             |
| `PCI_DEVICE_ID`     | `0x1050`    | INF 的 DEV_*             |
| `PCI_CLASS_DEVICE`  | `0x0300`    | Class=Display            |
| virtio config 结构 | 保持        | 队列布局、特性位         |

哪些可改（本补丁把它们变成参数）：

| 字段                   | 默认值     | 建议伪装值              |
|------------------------|------------|--------------------------|
| `PCI_SUBSYSTEM_VENDOR_ID` | `0x1AF4`   | `0x10DE` (NVIDIA)       |
| `PCI_SUBSYSTEM_ID`     | `0x0010`   | `0x1C81` (GTX 1050 ref) |
| `PCI_REVISION_ID`      | `0x01`     | `0xA1` (GP107 A1)       |

---

## 第三部分：virtio-win 驱动链

virtio-win.iso（Red Hat 官方/Fedora spin）里图形相关有两套：

* `viogpudo/` — **DOD** (Display-Only Driver)，Windows 10/11 用。
  文件：`viogpudo.inf` / `viogpudo.cat` / `viogpudo.sys`。
* `vioserial/`、`NetKVM/`、`viostor/`、`vioscsi/` … 这些与 GPU 无关。

`viogpudo.inf` 的关键段（原版）：

```ini
[Manufacturer]
%VENDOR% = VioGpuDod,NT$ARCH$.10.0...17134

[VioGpuDod.NT$ARCH$.10.0...17134]
%VIOGPUDOD.DeviceDesc% = VioGpuDod_Install, PCI\VEN_1AF4&DEV_1050

[Strings]
VENDOR = "Red Hat"
VIOGPUDOD.DeviceDesc = "VirtIO GPU DOD Device"
```

Windows PnP 加载顺序：

1. PCI 枚举 → `PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8110DE&REV_A1` / …&SUBSYS…/ …（从最具体到最通用依次尝试）。
2. INF 仓库索引命中 `viogpudo-nvidia.inf` 的 Models section。
3. 驱动 Service (`VioGpuDod`) 启动，`viogpudo.sys` 加载。
4. WDDM 初始化，与 virtio-gpu 的 virtqueue 建立连接。
5. 注册 Display Adapter → 写 `Enum\PCI\VEN_1AF4&DEV_1050\<instance>\` 的
   `DeviceDesc` / `FriendlyName`（**这两个值来自 INF 的 DeviceDesc 字符串**）。
6. 写 `HKLM\SYSTEM\CCS\Control\Class\{4d36e968-...}\NNNN` 的
   `DriverDesc` / `MatchingDeviceId` / `HardwareInformation.*`。

显卡名字最终来源：

| 消费者                         | 读的字段                                        |
|--------------------------------|--------------------------------------------------|
| 设备管理器                     | `Enum\PCI\...\FriendlyName` → `DeviceDesc`      |
| `Win32_VideoController.Name`   | `Enum\PCI\...\DeviceDesc`                       |
| DxDiag / `DXGI_ADAPTER_DESC`   | `Class\{4d36e968-...}\NNNN\DriverDesc`          |
| Task Manager / Performance     | DXGI                                             |
| CPU-Z / GPU-Z                  | DXGI + `HardwareInformation.ChipType` / `AdapterString` |

可以修改的三个入口：

1. **改 INF**（最干净）：`viogpudo-nvidia.inf`，重建 CAT，测试签名安装。
2. **改 guest 注册表**：`apply-gpu-spoof.ps1` 把 Class 子键 + Enum 节点双写，
   再用计划任务持久化。这个不碰 INF，不要求测试签名模式。
3. **改驱动源码**：需要完整 virtio-win 源码树，改 `viogpudo/EDID.cpp` /
   `viogpudo/driver.c` 里的 friendly name 调用 + 整个 WDK 重编。工程量最大。

---

## 第四部分：三层联合改造

### A. QEMU 层（本补丁 0008）

* 不新增 `gpu-name` 字符串属性——因为 guest 拿不到它（没有这种 virtio
  message），只会在 QMP 里多一个没用的元数据。用 QOM property 直接改
  PCI 配置头更实用。
* 新增三个属性到 `virtio_pci_properties`（所有 virtio-pci 派生设备都会
  继承），用 UINT32_MAX 表示"未设置"：
  * `x-pci-sub-vendor-id`
  * `x-pci-sub-device-id`
  * `x-pci-revision`
* `VirtIOPCIProxy` 结构体加 3 个 uint32_t 字段。
* `virtio_pci_realize()` 在 legacy + modern 两条路径 stamp 完 config 之后
  的位置（`config[PCI_INTERRUPT_PIN] = 1;` 之后）检查哨兵，若非 UINT32_MAX
  则覆写。
* 不破坏 virtio 规范：vid/pid/class/队列/特性位完全没动，virtio-win 和
  Linux virtio_gpu 都能正常绑定。

启动脚本里的接入：

```sh
GPU_SUBSYS_VEN=${GPU_SUBSYS_VEN:-0x10DE}
GPU_SUBSYS_DEV=${GPU_SUBSYS_DEV:-0x1C81}
GPU_REV=${GPU_REV:-0xA1}
-device "virtio-vga-gl,edid=on,xres=1920,yres=1080,\
x-pci-sub-vendor-id=${GPU_SUBSYS_VEN},\
x-pci-sub-device-id=${GPU_SUBSYS_DEV},\
x-pci-revision=${GPU_REV}"
```

### B. virtio-win 层

两条路可选：

**B1. 注册表路径（推荐，无需改 INF）**

1. 在干净 Win10 guest 上先用**原版** `virtio-win.iso` 的 `viogpudo.inf`
   正常安装（设备管理器能看见一块 "VirtIO GPU DOD Device"）。
2. 运行 `apply-gpu-spoof.ps1`（deploy/scripts/），它会：
   * 扫 `HKLM\SYSTEM\CCS\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}`，
     匹配 virtio / Red Hat / Basic 字串的那个子键，改 DriverDesc +
     HardwareInformation.*；
   * 扫 `HKLM\SYSTEM\CCS\Enum\PCI\VEN_1AF4&DEV_1050\*\`，改 FriendlyName /
     DeviceDesc；
   * 写 `C:\ProgramData\StealthGPU\refresh-gpu-name.ps1` + 任务计划
     `StealthGPU-RefreshName`（AtStartup + AtLogOn，SYSTEM），开机自动重刷。
3. 重启一次，`Get-CimInstance Win32_VideoController | select Name` 应该
   输出 "NVIDIA GeForce GTX 1050"。

**B2. INF 路径（更彻底，但需要测试签名）**

1. 把 `deploy/virtio-win/viogpudo-nvidia.inf` 和 `virtio-win.iso` 里的
   `viogpudo.sys` 放到同一目录，运行：
   ```
   makecat viogpudo.cdf        # 生成新的 .cat
   signtool sign /v /fd SHA256 /a viogpudo.cat
   ```
   （需要本机或测试证书；没有真 WHQL 证书，客机必须开测试签名。）
2. 在 guest 里：
   ```
   bcdedit /set testsigning on
   shutdown /r /t 0
   pnputil /add-driver viogpudo-nvidia.inf /install
   ```
3. 重启，设备管理器 / DxDiag 直接显示 NVIDIA GeForce GTX 1050，不需要
   注册表刷脚本。

### C. Windows 展示层

* 只有 **B1** 需要任务计划持久化（因为 BasicDisplay 回落会清 Enum 节点）。
* **B2** 不需要——驱动自己就叫 NVIDIA，Windows 不会回落。
* 两条路都不用碰 nvml.dll / NvAPI，那些是真 NVIDIA 驱动的东西；任何走它们
  的检测仍会失败。

---

## 第五部分：QEMU Patch 设计

**文件变更列表**：

| 文件                                | 增量 | 说明                           |
|-------------------------------------|------|--------------------------------|
| `include/hw/virtio/virtio-pci.h`    | +4   | VirtIOPCIProxy 加 3 个字段     |
| `hw/virtio/virtio-pci.c`            | +25  | realize 覆写 + 3 条 DEFINE_PROP |

**核心伪代码（已经实装在 0008 补丁里）**：

```c
/* include/hw/virtio/virtio-pci.h */
struct VirtIOPCIProxy {
    ...
    uint32_t x_subsys_vendor_id;  /* UINT32_MAX = unset */
    uint32_t x_subsys_device_id;
    uint32_t x_pci_revision;
    ...
};

/* hw/virtio/virtio-pci.c in virtio_pci_realize() */
config[PCI_INTERRUPT_PIN] = 1;

if (proxy->x_subsys_vendor_id != UINT32_MAX) {
    pci_set_word(config + PCI_SUBSYSTEM_VENDOR_ID,
                 (uint16_t)proxy->x_subsys_vendor_id);
}
if (proxy->x_subsys_device_id != UINT32_MAX) {
    pci_set_word(config + PCI_SUBSYSTEM_ID,
                 (uint16_t)proxy->x_subsys_device_id);
}
if (proxy->x_pci_revision != UINT32_MAX) {
    pci_config_set_revision(config, (uint8_t)proxy->x_pci_revision);
}

/* virtio_pci_properties[] */
DEFINE_PROP_UINT32("x-pci-sub-vendor-id", VirtIOPCIProxy,
                   x_subsys_vendor_id, UINT32_MAX),
DEFINE_PROP_UINT32("x-pci-sub-device-id", VirtIOPCIProxy,
                   x_subsys_device_id, UINT32_MAX),
DEFINE_PROP_UINT32("x-pci-revision", VirtIOPCIProxy,
                   x_pci_revision, UINT32_MAX),
```

**作用 + 风险**：

* **作用**：让 `-device virtio-vga,x-pci-sub-vendor-id=0x10DE,…` 能直接
  在 PCI 配置头里写 NVIDIA 的 subsystem + A1 revision。
* **兼容性**：默认 UINT32_MAX → 代码路径短路，与未打补丁的 9.2.0 表现
  一致。migrate 不涉及（subsystem 不在 vmstate 里）。
* **风险**：
  * 极少数客机驱动会 CRC 检查 subsys （NVIDIA 自家驱动会；virtio-win
    不会）。本方案不装 NVIDIA 驱动，不会踩。
  * 如果用户误把 `x-pci-sub-vendor-id` 设成 `0x1AF4`（与默认同值），什么
    都不会变，没有副作用。

---

## 第六部分：virtio-win 修改与安装链（B2 路径）

```
# 1. 准备
mkdir viogpudo-nvidia && cd viogpudo-nvidia
cp /mnt/virtio-win/amd64/2k19/viogpudo.sys .
cp .../deploy/virtio-win/viogpudo-nvidia.inf .

# 2. 生成 CAT  (inf2cat 或 makecat)
inf2cat /driver:. /os:10_X64

# 3. 签名 (测试签名 / 自签证书)
makecert -r -pe -ss PrivateCertStore -n "CN=StealthTestCA" test.cer
signtool sign /v /fd SHA256 /s PrivateCertStore /n "StealthTestCA" \
         /t http://timestamp.digicert.com viogpudo.cat

# 4. guest 里
bcdedit /set testsigning on
shutdown /r /t 0
# 把证书导入 Root + TrustedPublisher
certutil -addstore Root test.cer
certutil -addstore TrustedPublisher test.cer
# 装驱动
pnputil /add-driver viogpudo-nvidia.inf /install
```

验证驱动加载：

```
pnputil /enum-drivers | findstr /i "viogpudo-nvidia"
driverquery /v | findstr /i "viogpudo"
Get-PnpDevice -Class Display | fl
```

---

## 第七部分：驱动稳定性分析

| 症状                    | 根因                              | 避免方法                           |
|-------------------------|-----------------------------------|-----------------------------------|
| 驱动加载失败 (代码 39)  | CAT 签名链不完整 / 测试证书未信任 | `certutil -addstore` + `bcdedit testsigning on` |
| 黄叹号 (代码 28)        | INF Models 不匹配                 | 保留 `PCI\VEN_1AF4&DEV_1050` 匹配项 |
| 黑屏                    | BAR0 framebuffer 没给 guest        | 保持 `-device virtio-vga[-gl]`，不要用纯 `virtio-gpu-pci` |
| 3D 失效                 | 没有 `gl=on` 或没有 virgl          | SDL 路径 `-display sdl,gl=on` 搭配 `virtio-vga-gl` |
| 分辨率锁 1024x768       | EDID 未生成                       | `edid=on,xres=...,yres=...`         |
| DxDiag 仍显示原名       | 只改了 Class，没刷 Enum + 计划任务| 跑 `apply-gpu-spoof.ps1` 不加 `-SkipTask` |

为什么改 VEN/DEV 一定会失配：

* Windows PnP 做的是 **Hardware ID → INF Models** 精确匹配，最后回落到
  Compatible ID。改成 10DE:1C81 后我们没有装 NVIDIA 原生驱动，PnP 找不到
  任何 `PCI\VEN_10DE&DEV_1C81` 的 INF 候选，回落到 BasicDisplay。
* virtio-win 的 INF 永远只认 1AF4，改它也要保留主匹配项；所以"既要又要"
  的唯一办法就是 **仅在 subsys/rev 上做文章**。

---

## 第八部分：验证链

### 主机侧（QEMU 运行中）

```
# QMP 读 PCI 配置头（vm1 的 QMP socket）
socat - UNIX-CONNECT:/tmp/qemu-stealth-1.qmp <<EOF
{ "execute": "qmp_capabilities" }
{ "execute": "query-pci" }
EOF
# 期望在 virtio-vga(-gl) 那个设备看到：
#   "vendor_id": 0x1af4
#   "device_id": 0x1050
#   "subsys_vendor_id": 0x10de
#   "subsys_id": 0x1c81
#   "revision_id": 0xa1
#   "class_info.class": 0x0300     (VGA)

# 监控栈：build/qemu-system-x86_64 冒烟
build/qemu-system-x86_64 -device virtio-vga,help | grep x-pci
```

### Linux 客机侧（用 live CD 启一次做交叉验证）

```
lspci -nn   # 期望: 01:00.0 VGA ...: Red Hat 1af4:1050 (rev a1)
lspci -vvv -s 01:00.0 | grep -i Subsys   # 期望: NVIDIA 10de:1c81
dmesg | grep -i virtio_gpu   # 驱动绑定日志
glxinfo | grep -i renderer   # 期望: virgl 或 llvmpipe，不是 NVIDIA（真实）
```

### Windows 客机侧

```powershell
# 名字层
Get-CimInstance Win32_VideoController | ft Name, VideoProcessor, AdapterRAM
dxdiag /t %TEMP%\dx.txt ; type %TEMP%\dx.txt | findstr /i "Card name"
# 驱动层
pnputil /enum-drivers | findstr /i "viogpudo"
Get-PnpDevice -Class Display | fl FriendlyName, Service, InstanceId
# 注册表层
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000" /v DriverDesc
reg query "HKLM\SYSTEM\CurrentControlSet\Enum\PCI\VEN_1AF4&DEV_1050" /s
# 功能层
dxdiag /t   # 确认 DDI 版本 / 3D 加速未被禁用
```

验证三件事必须同时为真：

| ✔ | 含义                                                     |
|---|----------------------------------------------------------|
| 名字改成功 | `Win32_VideoController.Name` = "NVIDIA GeForce GTX 1050" |
| 驱动正常   | `pnputil /enum-drivers` 里 viogpudo 状态 Published, 设备管理器无叹号 |
| 功能正常   | DxDiag 三项 DDI 绿勾，Windows 分辨率切换正常，2D 和 virgl 3D 无异常 |

---

## 第九部分：最终推荐架构

```
QEMU 9.2.0 (本 deploy bundle)
   │  -device virtio-vga-gl
   │    edid=on,xres=1920,yres=1080
   │    x-pci-sub-vendor-id=0x10DE
   │    x-pci-sub-device-id=0x1C81
   │    x-pci-revision=0xA1
   ▼
PCI 配置头:
   VEN=1AF4 DEV=1050 CLASS=0300  (virtio 驱动匹配点)
   SUBSYS=10DE:1C81 REV=A1       (NVIDIA 味道)
   │
   ▼
virtio-win viogpudo.sys  (原版或 INF rebrand 版)
   │
   ▼
Class\{4d36e968-...}\0000 + Enum\PCI\VEN_1AF4&DEV_1050\<inst>
   │
   ▼
Win32_VideoController.Name = "NVIDIA GeForce GTX 1050"
Device Manager / DxDiag / Task Manager 全部一致
```

### 为什么这是最稳的方案

* **零 INF 匹配风险**：保留 `PCI\VEN_1AF4&DEV_1050`，虚拟机开机即出图。
* **零 NVIDIA 驱动路径**：不装 NVIDIA 用户态驱动，就不会触发
  VBIOS/MMIO 探测，也不会出现"绿屏后驱动崩"。
* **可回退**：去掉 `x-pci-sub-*` 和 `apply-gpu-spoof.ps1` 就恢复默认。
* **可叠加**：搭配 0001-0007 的 CPU / ACPI / NVMe / EDID 伪装，整机身份
  自洽。

### 与真 GTX 1050 的差异（仍会留下痕迹的点）

* `nvml.dll` / `NvAPI_Initialize` → 失败，因为没有真驱动。
* `PresentMon` / DCH 路径 → 看不到 NVIDIA 硬件计数器。
* DXGI `DXGI_ADAPTER_DESC1.VendorId` → **是** 0x10DE（来自 INF
  MatchingDeviceId 或 Class subkey，能骗过 `Win32_VideoController`，但
  `IDXGIFactory::EnumAdapters` 读的 VendorId 实际来自 PCI VEN_1AF4，有些
  代码会读到 0x1AF4）。
* CUDA / NVENC / OptiX / RTX → 完全不可用。

### 性能与兼容性

* 2D 桌面：和原版 virtio-gpu 一致。
* 3D（virgl / Mesa d3d-on-gl）：与原版一致，约等于 GT 730 水平的 OpenGL。
* DirectX 9/10/11 基础功能可用（Mesa 的 d3d10/11 GoMat 层），DX12 支持有限。
* VR / CUDA / RTX 光追：不支持。

---

## 附：一键更新步骤

```sh
cd ~/projects/qemu
deploy/tools/apply-patches.sh   # 自动带上 0008
# 启动 VM1（保持原有脚本）
deploy/scripts/win10-ryzen3-stealth.sh 1
# 首次进 Win10 桌面后
#   导入 virtio-win.iso, 装 viogpudo，然后
#   以管理员 PowerShell 跑 apply-gpu-spoof.ps1
# 重启客机，按第八部分校验
```

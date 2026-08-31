# G-11 vGPU 傻瓜教程：基础镜像一次封装，任意 VM 克隆

本页和当前 DGame 部署只适用于 **G-11/vGPU 分支**；已退役分支不参与运行时发现、
窗口标题或故障回退。

新建整机已恢复原 G3220/Core i3/i5/i7 + H81，并保留 4C/8T、6C/12T X79 扩展；
硬件选择、归档 6G、PCIe 3.0 NVMe
优先和共享 CPU 并发请先看
[`G11-HARDWARE-POOL.md`](G11-HARDWARE-POOL.md) 与
[`G11-PERFORMANCE-QUICKSTART.md`](G11-PERFORMANCE-QUICKSTART.md)。本文后部若仍以
H81/4+2G（6G）举例，只适用于 archived 旧 VM；H81 的 4G/8G 可正常新建。

宿主底层 GPU 名称、显存类型/位宽的通用安装、多工具重新扫描验收、安全边界和
回滚见 [`G11-BOTTOM-GPU-IDENTITY.md`](G11-BOTTOM-GPU-IDENTITY.md)。
所有主板误显 ICH9、旧显卡误显“光线追踪”的统一修复见
[`G11-HARDWARE-COHERENCE.md`](G11-HARDWARE-COHERENCE.md)。

## 先记住

1. guest 不开启 `testsigning`、`nointegritychecks`，软件也不会修改 BCD。
2. 不安装测试签名/自签名内核驱动。显示驱动必须是未修改的 NVIDIA GRID
   538.33，并由正常 NVIDIA/Microsoft 生产链验证；使用这种驱动不需要自行买驱动
   签名证书。
3. 无 VM 绑定的 `VgpuPortable.exe` 继续负责基础盘/授权、app-local 兼容和推荐
   guest 性能优化；它不内嵌 GPU-Z。要让普通 32/64 位硬件程序都看到同一板卡、显存厂家，并持久恢复
   显示器名称，成品 VM 再运行一次 VM/UUID 绑定的
   `package-system-nvapi-projection.sh` 系统包。
4. 新 VM 始终保持 B/native。PnP、DXGI/D3D 和生产签名 GRID 538.33 使用唯一的
   原生 `DEV_1E30` vGPU；系统包只合并静态 NVAPI/Subsystem 身份，不创建第二块
   显卡，也不改变 3D scheduler。
5. 只有历史 A → B 生产驱动迁移仍需要 guest 自动关机后的一次宿主 commit；
   已证实不稳定的 desktop 537.58 consumer 路径已经生产隔离。
6. `start-vm.sh` 默认根据 Windows USB 键盘 LED 回报幂等保持 NumLock 开启；不再
   依赖登录用户注册表。确需关闭本次策略时加 `--no-numlock`。
7. DGame 只按 G-11 的端点、窗口标题和 vGPU 显示合同运行，不再枚举旧分支标题。

> UAC 可能把本地构建的 portable 外层 EXE 显示为“未知发布者”。它是用户态
> 封装器，不是显示驱动或自签名内核文件。设备属性中实际驱动的数字签名者应为
> `Microsoft Windows Hardware Compatibility Publisher`。

## DGame 黑画面、GPU 预览与 SDL 窗口

启动 VM 后另开一个宿主终端（以 VM9 为例）：

```bash
./deploy/scripts/vmctl.sh display 9 status
./deploy/scripts/vmctl.sh display 9 preview-on   # 旧的运行中 VM 可无重启补帧源
./deploy/scripts/vmctl.sh display 9 window-hide
./deploy/scripts/vmctl.sh display 9 window-show
./deploy/scripts/vmctl.sh wake 9         # 仅当 Windows 主动进入 S3 后使用
```

native 新启动默认已有独立 DGame preview；它会创建
`/tmp/qemu-stealth-9.fb`，唯一 SDL 操作窗口标题固定为 `win10-9`。启动器使用
`single-console=on`，不会再创建 `win10-9-console-I` 辅助窗口；QMP/进程名仍为
`vm9`。窗口显回时按 guest 当前完整分辨率恢复，SDL 客户区最大值也限制为该
分辨率。默认优先把 SDL/GTK
在亮机卡上的 ROI texture 导成 dma-buf，失败自动回退 SHM；当前是 RX570，以后换
RX550 不需要改 PCI 地址或脚本。16 窗口上线前运行：

```bash
./deploy/scripts/vmctl.sh preview-capacity --instances 16 --rate 60
```

它默认同时核算 `800x600`、`1067x600`。若 60 Hz 实压抖动，先降到 30 Hz。
默认 guest 源按 `1920x1080`；其它源分辨率追加 `--source-size WxH`。
当前旧 VM 热加 preview 后可立即显示 SHM 帧；GPU 路径、稳定标题和职业名等 QEMU
内存读取授权，需要下次用新 binary 正常启动后生效。

正常冷启动在没有 consumer 时会显示 `rate=1Hz`，连接 DGame 后才切到请求帧率；这
不是配置丢失。`BAR 0: dma-buf unavailable, using mmap fallback` 只描述 NVIDIA
mdev REGION 边界，也不等于 RX570/RX550 的 DGame GPU 导出失败。若出现连续
`EGL_BAD_ACCESS`，说明仍在运行旧 QEMU：先完整停止 VM、重新构建，再正常启动。
新版会在每次 SDL 绘制后归还 native EGL context，异常最多报告一次。维护期间需
临时绕开 GPU 预览时使用 `--no-dgame-preview-gpu`，DGame 会走每客户端 SHM。

要输出网络视频，仍必须启动时提供明确的 `--stream URL`；它使用第二个 fb-shm
对象，不会被 DGame 的 ROI/帧率修改。之后可执行 `stream-only`，恢复本地窗口用
`window-only`。封装会先核对 QMP 中的 VM 名称，并在 fb-shm 不可用时保持唯一窗口
可见。该窗口热切换针对默认 SDL；`--gtk` 仍没有对等的 hide/show hook。

## 刚装好 Windows 的单台 VM：统一收尾

这一流程对 GTX 750 Ti、GT 1030、GTX 1050 完全相同，不再按型号调用
`finish-vgpu-install.sh`。以下以 VM9 为例。

如果当前启动先报告 `Windows is hibernated`，先在宿主执行：

```bash
cd /home/ubuntu/projects/qemu
sudo -v
./deploy/scripts/recover-hibernated-vm.sh 9
```

在弹出的本地标准 VGA Windows 窗口中，以管理员身份打开 CMD，逐行执行：

```bat
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f
shutdown.exe /s /f /t 0
```

等窗口自然退出。这个恢复封装只处理“磁盘已休眠、正常 vGPU 启动被门禁阻止”的
既有状态；它不安装驱动、token 或身份组件。新装系统尚未缓存 NVIDIA 显示器时，
最后的离线 EDID 同步可能提示 defer，这是驱动尚未安装时的正常边界。

然后使用隔离 NVIDIA console 的统一入口安装驱动：

```bash
./deploy/scripts/vmctl.sh driver-install 9
```

封装自动在标准 VGA 窗口中安装未经修改、生产签名的 GRID 538.33，并在收据通过后
完整关机、离线认证模式表。再次在宿主构建私有通用收尾包并正常启动：

```bash
chmod 600 /home/ubuntu/images/staging/client_configuration_token.tok
./deploy/package-vgpu-one-click.sh --with-license-token
./deploy/scripts/start-vm.sh 9
```

这次普通启动会同时启用新的 NumLock LED 状态机。若 VM 已在旧 QEMU 中运行，必须
先完整关机；重编宿主二进制不会热更新现有进程。首次桌面右键仍慢时按
[`G11-NUMLOCK-FIRST-BOOT.md`](G11-NUMLOCK-FIRST-BOOT.md) 区分 Explorer 后台初始化、
driver、license 与 FRL。

把下面这个文件安全复制到 VM9，再双击并接受 UAC：

```text
/home/ubuntu/images/staging/VgpuPortableLicensed/VgpuPortable.exe
```

只有窗口同时显示 `[vGPU identity] INSTALL PASS`、`License: Licensed` 和
`Power: hibernation/Fast Startup disabled` 才算成功。随后让 Windows 完整关机，
窗口自然退出，再执行一次普通冷启动：

```bash
./deploy/scripts/start-vm.sh 9
```

私有 EXE 对 25 个 profile 自动读取固件 claim，不包含 VM ID/UUID；同一个文件可逐台
用于受信任 VM。它包含 DLS 凭据，宿主权限为 `0600`，不要放进公共基础盘、仓库或
公开下载位置。默认不带参数构建的 `VgpuPortable/VgpuPortable.exe` 仍是无 token 的
基础盘安全版。

## 新主流程：已有 base 时只需三条宿主命令

先让所有 VM 完整关机。如果目前只有已经装好并验收通过的模板 VM（例如 VM1），
先执行一次：

```bash
BASE_NAME=win10-ltsc-v1
./deploy/scripts/vmctl.sh seal 1 "$BASE_NAME"
```

它采用 G-11 统一入口 `seal-base.sh`，默认先清理模板盘中的
WeGame/Tencent QIMEI、登录态、SSO/SDK/设备缓存、D3DSCache 与注册表键，再发布
standalone base；清理失败不会产出 base。然后执行：

```bash
cd /home/ubuntu/projects/qemu
BASE_NAME=win10-ltsc-v1
./deploy/package-vgpu-one-click.sh
sudo ./deploy/install-vgpu-portable-to-base.sh --base-name "$BASE_NAME"
./deploy/scripts/vmctl.sh clone "$BASE_NAME" 456 --start
```

若第一条提示现有 public catalog/format 较旧，改为执行一次
`./deploy/package-vgpu-one-click.sh --replace-public`；旧产物会进入仓库外
`package-backups`，不会直接删除。

三条命令分别完成：

1. 构建
   `/home/ubuntu/images/staging/VgpuPortable/VgpuPortable.exe`。EXE 内有全部已审计
   profile，但没有 VM ID/UUID，也没有 GPU-Z 程序字节。
2. 默认只将 `C:\Users\Public\Desktop\VgpuPortable.exe` 写入 Windows base；
   base schema-5 回执明确记录 `gpuZIncluded=false` 和
   `guestPerformance=embedded-recommended-native-v1`。这一步只需为每个 base 做一次。
3. 创建 VM456 的独立 B/native 配置和 UUID，从 base 建立 V-11 式增量盘；
   `disk.qcow2` 刚创建通常只有几百 KB，隐藏的 `.base.qcow2` hard-link 固定母盘
   inode。未指定显卡时按 `VGPU_HOST_FB_TIER_MB` 从对应单档新建层随机，显示器从
   审核新建池随机，结果分别写入 `vm.conf`，克隆后自动同步，然后启动。

`BASE_NAME` 是基础镜像的永久选择键，不是装饰性备注。它只能包含字母、数字、
`_`、`-`，不写 `.qcow2`。推荐格式是 `<系统>-<版本或用途>-v<代号>`，例如
`win10-ltsc2021-game-v1`；内容换代就改为 `v2`，不要命名为 `latest`。上述命令
产生并绑定：

```text
_base/win10-ltsc-v1.qcow2
_base/win10-ltsc-v1.qcow2.vgpu-portable.json
```

以后做第二个基础镜像时换名即可，第一代不会被覆盖：

```bash
BASE_NAME=win11-vgpu-v2
./deploy/scripts/vmctl.sh seal 2 "$BASE_NAME"
./deploy/package-vgpu-one-click.sh
sudo ./deploy/install-vgpu-portable-to-base.sh --base-name "$BASE_NAME"
./deploy/scripts/vmctl.sh clone "$BASE_NAME" 457 --start
./deploy/scripts/clone-from-base.sh --list-bases
```

每个 base 都要单独执行一次 portable 注入。clone 会校验所选 base 自己的证明，
不能拿 A 的证明配 B，也不会因为目录中有多个镜像而猜“最新”的一个。

`--start` 只控制是否立即开机，不控制显示器配置。克隆但不启动也会自动同步；以后
每次 `start-vm.sh` 都会按 marker 复核，不需要另跑 `vmctl monitor`。只有切换型号或
强制清旧缓存时才使用关机态的 `vmctl monitor ... --force`。

默认克隆不会再复制一份几十 GB 的母盘。查看真正新增空间：

```bash
du -h /home/ubuntu/images/vms/456/disk.qcow2
qemu-img info /home/ubuntu/images/vms/456/disk.qcow2
```

第二条应显示 `backing file: .base.qcow2`。只有明确需要可脱离母盘单独搬走的 VM
时才给 clone 增加 `--full-copy`。母盘换代必须原子发布新 inode；已有 VM 使用自己
的 pin 保持旧版本，新克隆才使用新版，禁止原地改写母盘让旧增量盘“跟着更新”。

进入 Windows 后只双击公共桌面的 `VgpuPortable.exe`，UAC 点“是”，等待：

```text
APPLY PASS: recommended native-display tuning is installed.
[vGPU identity] INSTALL PASS
```

这一次运行已经同时完成显卡身份/授权和登录启动性能优化；不再运行
`guest-performance.sh`、`01-Audit.cmd` 或 `02-Apply-Recommended.cmd`。从开始菜单
完整关机并正常冷启动。需要核对身份时再双击公共桌面的 `vGPU Identity Query`，
必须看到配置选中的
`Projected profile`、`Board identity`、`VRAM identity`，并以 `VERIFY PASS`
结束。这个查询器会同时显示原生 `DEV_1E30` 传输层，避免把系统 PCI 真身与
受保护的身份/NVAPI 投影层混为一谈。

不需要再手工复制 ZIP、PowerShell 或 DLL，也不需要 GPU-Z。运行时不依赖 HTTP、
映射盘、WinRM 或 guest 下载；正常 portable clone 安装后也不需要关机回宿主
提交。默认运行即使同目录存在 `GPU-Z.exe` 也不会读取它。

以后确实需要 GPU-Z 时，从官网取得经过审计的 2.70 x86，精确命名为
`GPU-Z.exe` 放在 portable 同目录，再显式运行：

```bat
VgpuPortable.exe /with-gpuz
```

选装路径会在写入 profile 前复验大小、哈希、版本、签名和 ABI；错误文件会
fail-closed，不会污染默认身份安装。

第一次部署还可先做一次完全只读的硬件池检查：

```bash
./deploy/scripts/check-hardware-pool.sh
# 只看数量、品牌、序列策略和固定例外：
./deploy/scripts/check-hardware-pool.sh --machine-readable
```

普通新建池包含恢复的六款 mainstream CPU/H81 与五款 Core i7/X79，覆盖
2C2T、2C4T、4C4T、4C8T、6C12T，以及 4G/8G/12G/16G 四档 DDR3。
434 条可见组合全部是 CPU、主板、逐槽 DIMM 共同审核的原子白名单；内存默认 8G，
性能优先时选择 i7-4960X + DDR3-1866。五种规格的复制粘贴步骤见
[家用 CPU 池傻瓜教程](G11-HOME-CPU-POOL-QUICKSTART.md)。完整目录共 13 CPU、
16 主板、45 内存、524 整机，其中 87 条旧 6G 组合为 archived，另有 3 条
legacy compatibility。归档项即使打开兜底也不能新建，宿主能力探测不确定时仍
fail-closed。另有 3 款优先 Gen3 x4 NVMe 和 7 款平台回退 SATA，容量均为精确
`512110190592` 字节；还有 3 个 1GB + 3 个
2GB GPU 芯片型号（25 条板卡/显存原子 profile：2GB 默认 12 条、1GB Maxwell
新建 4 条、显式 1 条、Kepler legacy 8 条），以及 35 款全部为
1920×1080@60 的显示器（其中 28 款可新建）。4G 是 2×2G 双通道，8G 是 2×4G
双通道，12G 是 3×4G 三通道，16G 是 4×4G 四通道；12/16G 只允许至少四个
DIMM 插槽的主板。审计器会标出哪些组合可用于
新 VM、哪些只保留旧平台身份。完整明细和报错处理见
[G-11 vGPU 硬件池教程](G11-HARDWARE-POOL.md)。

普通新建的品牌覆盖为：主板 5、内存 6、SSD 5、GPU 系统用户态板卡 metadata 9、
active 键盘 3、可选相对鼠标 3。显示器因保留 35 款 FHD 目录而明确例外为新建
8 品牌/完整 11 品牌；默认绝对指针只有诚实的 QEMU 通用 profile。CPU/芯片组实现、
Intel e1000e、Intel HDA、swtpm 和安装期临时介质也都是固定合同，不为凑品牌数
只改字符串。普通启动不创建光驱；安装或手动热插时可使用
`HL-DT-ST DVDRAM GH24NS50 / XP02` 审核身份，但不伪造序列。
主板目录现在只把 00:1f.0 的 LPC inventory identity 映射为
X79/H81/H97/B150/B360；`q35`/ICH9 行为、ICH9-AHCI、`qemu-xhci`、QEMU `nvme` controller、
安装/救援 `std-vga` 和 legacy `ivshmem` 是实现/兼容边界，也不进入品牌随机。

新 VM 使用硬件合同 v3：system/baseboard/chassis 三个标签延续 ASUS、MSI、
Gigabyte 主板语法且互不重复；只有 baseboard serial 天然归主板厂，system/chassis
是现有合同中的整机/资产标签。`MEM_SN` 是非保留 JEDEC 4-byte 序列，第二槽
稳定派生出不同值；新配置还持久化完整 `MEM_SERIAL_LIST`，两个最终槽值在统一
`MEMORY_SERIAL` 命名空间跨 VM 查重。DDR3 的逐槽容量、Rank、颗粒宽度、模组/DRAM JEP106、序列和
料号会同时进入 SMBIOS 与 SPD。Micron 目录 SKU 在 18-byte SPD part 字段使用
对应的 `-1G6`（1600）或 `-1G4`（1333）基础 part。两套 legacy DDR4 仍是
256-byte page 0-only，厂商/料号/序列由 SMBIOS Type 17 提供，不伪造 EE1004
page 1。SSD 按十款型号使用严格序列格式；显示器只有 Samsung S24F350 与 Redmi
RMMNT238NF 是型号专属格式，其余 33 款为 `generic-prefix-hash`。GPU 板卡序列为
`not-exposed`，USB 输入为 `none`/`iSerialNumber=0`。创建器在 fleet 锁下查重并对
撞号重抽，启动器再次复核；缺少列表的 v1/v2/v3 旧配置只在内存中稳定派生，
不会在启动时被静默改写。

## 空盘安装 Windows（含键盘自动捕获）

首次启动前在宿主本地控制台按
[G-11 宿主桥接傻瓜教程](G11-NETWORK-BRIDGE-VLAN.md)
只运行 `./deploy/scripts/setup-bridge.sh`。它会自动识别上联、配置 VLAN-aware `br0`
并在人工确认前保持独立回滚。启动器会拒绝没有物理上联的空 `br0`；
Windows 已识别 Intel 网卡但只有 `fe80::`、没有 IPv4 时，不要重装 guest 驱动，
先修宿主桥接。

第一次拉取本修复后先增量重编一次；之后仍只使用 `start-vm.sh` 封装：

```bash
cd /home/ubuntu/projects/qemu
./deploy/host/build-qemu.sh
```

下面是一套可直接照抄的 VM8 安装命令。组件只能筛选审核过的整机白名单，不会
任意笛卡尔组合；不指定平台时，创建器先从 434 条可见组合中按性能级别选择，
默认仍优先 X79：

```bash
cd /home/ubuntu/projects/qemu

VM_ID=8
ISO=/home/ubuntu/images/iso/win10.iso

./deploy/scripts/create-vm.sh --list-cpu-profiles
./deploy/scripts/create-vm.sh --list-board-profiles
./deploy/scripts/create-vm.sh --list-memory-profiles
./deploy/scripts/create-vm.sh --list-platforms
./deploy/scripts/create-vm.sh --list-ssd-profiles
./deploy/scripts/create-vm.sh --list-gpu-profiles
./deploy/scripts/create-vm.sh --list-monitor-profiles
./deploy/scripts/create-vm.sh --list-input-profiles
# 日常列表只显示正常型号；只有明确需要旧平台时才看：
./deploy/scripts/create-vm.sh --include-fallback --list-platforms

./deploy/scripts/create-vm.sh "$VM_ID" \
  --platform i7-4820k-x79-up4-elpida-12g \
  --gpu-vram 2048 \
  --monitor-profile philips-243v7

# 二选一：不带 VLAN 参数就是默认 LAN
./deploy/scripts/start-vm.sh "$VM_ID" --install "$ISO"
# 业务网络需要且宿主白名单已允许时，改为：
# ./deploy/scripts/start-vm.sh "$VM_ID" --install "$ISO" --vlan-id 11
```

安装 ISO 默认由只在安装期出现的 UEFI helper 引导到 xHCI USB BOT 高速读取；看到
`Press any key` 时只按一次，Windows 重启后不要再按。安装完成并完整关机后使用不带
`--install` 的正式启动命令，helper、Windows ISO 和应答 ISO 会全部消失。只有默认
路径异常时才加 `--install-media ide` 做慢速回退。照抄命令、校验和原理见
[高速安装介质教程](G11-INSTALL-MEDIA.md)。

4G/8G/12G/16G 都在正常 X79 池。要固定 16G 四通道，可执行
`./deploy/scripts/create-vm.sh 10 --platform i7-4820k-p9x79-micron-16g`；硬盘不指定
时会先尝试适配该平台的 Gen3 x4 NVMe。也可用
`--cpu-profile`、`--board-profile`、`--memory-profile` 筛选白名单，完整示例见
[硬件池教程](G11-HARDWARE-POOL.md)。

安装窗口默认是 GTK。鼠标移入窗口并让窗口获得焦点后，启动器自动捕获键盘；
`Ctrl+Alt+Del`、`Super`、`Alt+Tab` 会发给 guest。鼠标移出或窗口失焦后立即恢复
宿主快捷键，不需要永久修改 GNOME 设置。只有明确传入 `--no-tame-gnome` 才会
关闭这层保护。

若安装阶段看到 `PAGE_FAULT_IN_NONPAGED_AREA` 且
`What failed: USBXHCI.SYS`，不要删除已建的 VM8 磁盘，也不要改 BCD 或
安装测试签名驱动。直接按
[G-11 USBXHCI 蓝屏恢复教程](USBXHCI-INSTALL-RECOVERY.md)
增量重编、运行门禁，再用原 `./deploy/scripts/start-vm.sh --install` 命令续装。

## 为什么不再绑定 VM

portable EXE 内嵌的是 profile catalog，而不是 GPU-Z 程序或某台 VM 的选择
结果。每次
`start-vm.sh` 以 B/native 启动时，会自动把下面信息作为只读 SMBIOS Type 11
声明提供给 guest：

- 当前 `GPU_PROFILE`；
- 当前 SMBIOS `VM_UUID`；
- portable profile catalog 哈希；
- 原生 `10DE:1E30` PnP tuple；
- 允许的驱动版本 `31.0.15.3833`。

EXE 必须同时核对恰好一条声明、当前 UUID、单 Display、Code 0、驱动版本、
DriverStore catalog、已加载 `nvlddmkm.sys` 的生产签名和 BCD 安全状态。这样同一
EXE 可跨 VM 使用，但不能在 guest 内任意选择/伪造另一个型号。A/off 启动没有该
声明，旧启动进程也不会凭空获得它。

这里“宿主自动注入”属于正常 `start-vm.sh` 启动流程，不是用户每克隆一台 VM
还要运行一次的提交命令。

## 支持的显卡 profile

先运行 `./deploy/package-vgpu-portable.sh --list-gpu-profiles` 可读取当前唯一目录。

| `GPU_PROFILE` | 目标名称 | 板卡 | 显存 |
|---|---|---|---|
| `gtx750ti_2gb` | GTX 750 Ti | NVIDIA Reference | Samsung |
| `gtx750ti_asus_2gb` | GTX 750 Ti | ASUS OC | Samsung |
| `gtx750ti_msi_2gb` | GTX 750 Ti | MSI OC | SK hynix |
| `gtx750ti_gigabyte_2gb` | GTX 750 Ti | Gigabyte OC | Micron |
| `gt1030_2gb` | GT 1030 | ASUS OEM 85F9 | Samsung |
| `gt1030_galax_2gb` | GT 1030 | GALAX EXOC White | Samsung |
| `gt1030_asus_2gb` | GT 1030 | ASUS Silent | SK hynix |
| `gt1030_msi_2gb` | GT 1030 | MSI LP OCV1 | Micron |
| `gtx1050_2gb` | GTX 1050 | Dell OEM | Samsung |
| `gtx1050_colorful_2gb` | GTX 1050 | Colorful GTX1050 Gaming 2G V5 | Samsung |
| `gtx1050_msi_2gb` | GTX 1050 | MSI Gaming X | Micron |
| `gtx1050_gigabyte_2gb` | GTX 1050 | Gigabyte OC | SK hynix |

每行都固定 2 GB GDDR5，并把型号、subsystem、VBIOS、时钟、板卡和显存厂家一起
锁定；不能只改 `GPU_BOARD_BRAND` 或 `GPU_MEMORY_MAKER` 拼出目录外组合。

最省事的克隆命令无需指定显卡；宿主固定为
`VGPU_HOST_FB_TIER_MB=2048` 时，它会从上面 12 行等概率随机一行，并把结果永久
写进该 VM 的 `vm.conf`。宿主固定为 1024MB 时则只从 4 条 Maxwell 1GB 新建行
选择；两个档位不会互混，显式行和 Kepler legacy 行也不进入无参数随机：

```bash
./deploy/scripts/vmctl.sh clone win10-ltsc-v1 457 --start
```

需要固定型号时再选择 profile，例如：

```bash
./deploy/scripts/vmctl.sh clone win10-ltsc-v1 457 --gpu-profile gt1030_msi_2gb
./deploy/scripts/start-vm.sh 457
```

`VM_ID` 支持 launcher 允许范围内的正整数，不区分 1、2、3、4、5、6、456。
新增显卡型号必须先进入唯一 catalog 并完成实际驱动/GPU-Z/NVAPI 审计；不要按 VM
编号创建文件或只改显卡名称。

## 制作 base 前的安全条件

base 必须是 standalone qcow2，Windows 已完整关机，NTFS 干净且未休眠。基础
Windows 中应已经有：

- B/native `DEV_1E30` 上正常绑定的原始 GRID 538.33；
- Code 0 和可用的正常分辨率；
- NVIDIA/Microsoft 生产签名 catalog 与加载中的内核驱动；
- `testsigning=No`、`nointegritychecks=No` 或未设置；
- 不含 patched driver、自签 catalog、私有测试根证书。

从模板 VM 封装基础镜像的傻瓜入口是：

```bash
./deploy/scripts/vmctl.sh seal 1 win10-ltsc-v1
```

默认 WeGame/Tencent 清理会写入模板 VM 的源盘，使后续 clone 不共享 QIMEI、登录态
和设备缓存；它不删除 ACE 程序。若确实要把这些状态原样固化，才显式使用
`./deploy/scripts/vmctl.sh seal 1 win10-ltsc-v1 --no-clean`。清理同样拒绝 dirty/hibernated NTFS，
不执行 `ntfsfix`、`remove_hiberfile`，也不修改 BCD 或驱动。

运行 base 注入脚本前必须停止**所有** VM，而不只是模板 VM。脚本获取独占存储
锁，拒绝正在使用、带 backing/data-file、被其他 qcow2 依赖或校验失败的 base。
它只挂载私有临时副本；遇到 dirty/hibernated NTFS 会停止，不会强制删除休眠文件。
临时副本完成写入、哈希复核、卸载和 `qemu-img check` 后，旧 base 才归档并原子
替换。

因此不要在 VM 运行时手工 NBD 挂载 base，也不要为了通过门禁使用
`remove_hiberfile`、强制 NTFS 写挂载或手改 portable attestation。

## 常用变体

只准备 package，不更新 base：

```bash
./deploy/package-vgpu-one-click.sh
```

为实际 VM 构建包含仓库外 token 的私有统一收尾包：

```bash
./deploy/package-vgpu-one-click.sh --with-license-token
# 或：
./deploy/package-vgpu-one-click.sh \
  --token-file /安全路径/client_configuration_token.tok
```

不要把这个私有产物交给 `install-vgpu-portable-to-base.sh`；通用 base 只使用上面的
默认无 token 版本。

自定义 portable 输出，并注入指定的具名 base：

```bash
./deploy/package-vgpu-one-click.sh --portable \
  --output-exe /srv/private/VgpuPortable.exe

sudo ./deploy/install-vgpu-portable-to-base.sh \
  --base-name win10-ltsc-v1 \
  --exe /srv/private/VgpuPortable.exe
```

只有明确要让所有克隆预置 GPU-Z 时，再加
`--gpuz-source /srv/private/GPU-Z.2.70.0.exe`；该参数自动表示
`--with-gpuz`。

克隆但暂不启动：

```bash
./deploy/scripts/vmctl.sh clone win10-ltsc-v1 458 --gpu-profile gtx750ti_2gb
```

之后正常启动即可：

```bash
./deploy/scripts/start-vm.sh 458
```

`vmctl clone` 封装 `clone-from-base.sh`，还可传递 `--platform`、
`--ssd-profile` 和 `--monitor-profile`。不传显示器参数时自动生成并固定一个；目标
VM 配置或磁盘已经存在时会拒绝，不会覆盖。

## 成品 VM 的通用系统身份包

确认目标 VM 在原生 GRID 538.33 上只有一个 Code-0 Display 后，在宿主执行：

```bash
cd /home/ubuntu/projects/qemu
VM_ID=456
./deploy/package-system-nvapi-projection.sh "$VM_ID"
```

默认目录是
`/home/ubuntu/images/vms/$VM_ID/packages/SystemNvapiProjection/`，因此删除该 VM
时包和 ISO 会随完整 VM bundle 一起清理。不要为了日常安装传 `--output-root`；该
选项只用于明确需要保留在 VM 外部的导出副本。

打包器结尾会打印带完整 ISO 路径的一键命令，直接照抄：

```bash
./deploy/scripts/vmctl.sh cdrom "$VM_ID" mount /absolute/path/from-packager.iso
```

在 Windows 双击 `Run-As-Administrator.cmd` 并确认 UAC。它会在任何写入之前
直接审计签名显卡驱动的 x86/x64 D3D12 OPTIONS5；两条路径都能枚举/查询 NVIDIA
adapter 后便安装并自动重启。查询失败时会拒绝安装、不重启；原生 DXR tier 高于
目标旧卡时会明确警告并继续，因为该值属于签名 vGPU transport。日志在
`C:\Windows\Temp\G11-System-NVAPI-Install.log`。

只有 `Run` 成功并重启后才双击 `Verify-As-Administrator.cmd`；必须同时看到
x86/x64 两个 `SYSTEM_NVAPI_VERIFY PASS`、x86/x64 两个
`D3D12_NATIVE_VERIFY PASS` 和最终 PASS。

此包从当前 `vm.conf` 原子读取所选 GPU/板卡/显存 profile 与显示器 profile，
并绑定 VM UUID、唯一 Display PnP、驱动版本、payload 哈希和 EDID。它不包含
VM456、某个检测程序或某个品牌的特例。当前回归同时覆盖 GTX 750 Ti、GT 1030、
GTX 1050，ASUS/MSI/Gigabyte，Samsung/Micron/SK hynix 和三款不同显示器。

32 位与 64 位 DLL 只是兼容两类调用程序；Windows 设备管理器和 DXGI/D3D 仍只有
一块原生 `10DE:1E30` vGPU。系统 NVAPI 保留同一 transport vendor/device，只把
profile 的板卡 Subsystem 和静态规格合入，因此硬件程序不会再拆成“两块显卡”。
完整原理、收据位置、黑屏判断和一键回滚见
[`G11-BOTTOM-GPU-IDENTITY.md`](G11-BOTTOM-GPU-IDENTITY.md)。
默认零光驱、手动热插/换盘/整机热拔和盘符不刷新的处理见
[`G11-OPTICAL-DRIVE.md`](G11-OPTICAL-DRIVE.md)。

SystemNvapiProjection schema 4 把当前六个旧显卡 device ID 的 NVAPI 能力合同绑定进
包内；x86/x64 系统探针必须同时显示 `RT=0 Tensor=0`。x86/x64 原生 D3D12 探针
必须都能完成 OPTIONS5 查询，但其 tier 由签名 transport 如实返回。这一处理对所有调用者一致，不接收
应用路径，也没有鲁大师进程或 VM 编号特例。

鲁大师、GPU-Z、HWiNFO 等只用于重新扫描和交叉验收。当前 RTX 2080 宿主上的
`DEV_1E30` 生产 transport 和隔离 M60-1Q 候选都已实测为 x64 tier 11，
因此严格 D3D12 现实一致性审计仍会失败，但这不再阻断授权和 NVAPI 系统投影。
不要放置 app-local
`d3d12.dll`，也不要替换系统 `d3d12.dll`。完整实机记录、公共层流程和签名
transport 边界见
[配置现实一致性教程](G11-HARDWARE-COHERENCE.md)。

## 最终验收

请使用本地 QEMU SDL/GTK 或 fb-shm 画面。活动 RDP 可能创建 Remote Display
Adapter，导致严格的单 Display 检查拒绝。

### 设备管理器

- “显示适配器”下只有一张目标 NVIDIA 显卡；
- 设备状态 Code 0，没有 Code 43；
- 驱动版本为 `31.0.15.3833`；
- 数字签名者为
  `Microsoft Windows Hardware Compatibility Publisher`，不是
  `VM3 vGPU Test Driver Signing`；
- 分辨率符合
  [正常 FHD/1K 白名单与已有 VM 刷新步骤](G11-MONITOR-POOL.md#正常-1kfhd-分辨率合同)。

PCI bridge 是显卡父设备，不是第二张显卡。底层系统 PnP 仍是 vGPU 原生
`DEV_1E30`，以便加载未经修改的正式签名 GRID 驱动；设备管理器 marketing name
和 `vGPU Identity Query` 显示配置的消费卡型号。

### 系统身份与 3D 验收

系统包安装后，先运行包内 `Verify-As-Administrator.cmd`：

- x86 与 x64 NVAPI probe 都输出 `SYSTEM_NVAPI_VERIFY PASS`；
- x86 与 x64 D3D12 probe 都输出 `D3D12_NATIVE_VERIFY PASS`；
- 两个 probe 都断言 NVAPI physical GPU 数量为 1；
- device 保持原生 transport，Subsystem、显存类型/厂家和位宽匹配同一 profile；
- 最终 validated 收据记录 VM UUID、Display instance、驱动和 payload 哈希。

再打开 `dxdiag` 的“显示”页：只能有一个 Display Devices，Direct3D DDI、Feature
Levels 和 WDDM 状态正常。DXGI/D3D 继续使用唯一的原生 vGPU；32/64 位 NVAPI DLL
只是调用者兼容层，不是两块显卡。

任意硬件工具需先执行自己的“重新扫描”清理旧缓存，然后确认板卡、显存厂家、
GDDR5、位宽、带宽和时钟来自该 profile。工具若同时读取未投影的内核/执行资源，
可以显示原生 vGPU 的动态拓扑；这不应增加第二个 PnP Display，也不能作为修改
内核驱动的理由。

GPU-Z 的 WHQL 文本不是签名链本身。实际签名结论来自 DriverStore catalog、
当前加载的 `nvlddmkm.sys` 以及 Windows Authenticode/WHCP 验证。

管理员 PowerShell 只读复核：

```powershell
Get-CimInstance Win32_VideoController |
  Format-List Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode,
    CurrentHorizontalResolution,CurrentVerticalResolution

Get-CimInstance Win32_PnPSignedDriver |
  Where-Object DeviceClass -eq DISPLAY |
  Format-List DeviceName,InfName,DriverVersion,Signer,IsSigned

bcdedit /enum all | Select-String 'testsigning|nointegritychecks'
```

Windows 的 published INF 是动态分配的 `oemN.inf`，每个 clone 可能不同。软件会
自动反查，教程不会固定 VM3 当时的编号。

## 交叉查询工具怎么看

HWiNFO 等 64 位程序现在也会经过同一系统 NVAPI 投影，不需要程序名适配。但这类
工具还可能读取 PCI config、WMI、DXGI、驱动私有数据和实时执行资源；未属于静态
profile 合同的字段应保留原生真值。判断是否“一块卡”只看 present Display、
NVAPI physical GPU 数量和 DXGI adapter 数量，不能把一个工具页面中的多个数据源
误算成多个设备。

不要手工复制或替换 System32/SysWOW64 DLL。系统包会验证 PE 位数、payload 哈希、
旧 validated 收据和相邻 NVIDIA 正式签名原件；未知旧文件会失败关闭，并提供包内
一键回滚。

## 历史 A VM：仍然是按 VM 迁移

历史 `SPOOF_MODE=A` 使用过修改 INF/自签 catalog，不能靠 portable 身份层直接
变成合规驱动。它继续使用 VM/UUID 绑定的兼容流程：

```bash
cd /home/ubuntu/projects/qemu
VM_ID=3
./deploy/package-vgpu-one-click.sh "$VM_ID"
```

只把输出的 `VgpuProductionMigration.exe` 复制到对应 Windows 本地磁盘并运行。
它暂存原始生产驱动、写一次性回执并自动完整关机。确认 QEMU 已退出后：

```bash
sudo ./deploy/commit-vgpu-production-migration.sh "$VM_ID"
./deploy/scripts/start-vm.sh "$VM_ID"
```

commit 只读核验停止磁盘中的 staged 回执，成功后才把该 VM 配置原子提交为
B/native；失败不会修改 host 配置。后续受保护任务完成 538.33 绑定、Code 0、
生产签名和 GPU-Z 验收。

带 `VM_ID` 的 `package-vgpu-one-click.sh` 仅为 legacy 兼容。它对 A 选择完整
迁移包，对旧 B 选择原来的 VM 绑定 GPU-Z 包。新建/克隆 B VM 应使用**不带参数**
的 portable 主入口；不要给 portable clone 运行 legacy commit。

VM3 已完成这条历史 A → B/native 迁移，可作为 Code 0、生产签名和 GPU-Z 结果
参考。它不是测试签名目标，也不应再次运行旧迁移包。

## 常见错误

| 现象 | 原因与处理 |
|---|---|
| portable 报 firmware claim 缺失 | 用正常 B 配置重新冷启动；确认不是 A/off、旧 QEMU 进程或手工绕过 `start-vm.sh` |
| Code 43，分辨率变小 | host/guest vGPU branch 或原始驱动绑定有问题；先修 538.33/Code 0，GPU-Z 包不能掩盖 |
| 检出两张 Display | 退出 RDP并从本地画面复核；PCI bridge 不算显卡，Remote Display Adapter 才算 Display |
| base 注入报存储锁 | 停止所有 VM 和存储操作后重试 |
| seal 报 WeGame/Tencent 清理失败 | 先让模板 Windows 完整关机并关闭 Fast Startup，按第一条错误修复后重跑；不要用 `--no-clean` 掩盖异常 |
| base 注入报 dirty/hibernated | 正常启动 Windows、关闭 Fast Startup、执行完整关机后重试 |
| 正常启动直接报 Windows hibernated/Fast Startup | 运行 `./deploy/scripts/recover-hibernated-vm.sh N`，在本地标准 VGA 中执行页面给出的两条内置命令并等待自然关机 |
| 私有版拒绝 token 权限 | token 必须在仓库外且权限不宽于 `0600`；不要为了省事放宽权限 |
| 私有版授权未变成 `Licensed` | 检查 Windows 时间/时区、guest 到 token 内 DLS 地址的 HTTPS 连通性和 DLS lease；安装器会回滚失败的 token，不要伪造成功回执 |
| clone 报 base changed/no attestation | base 在注入后被改动；重新执行安全注入，不要手改 portable 或 attestation |
| 默认双击仍提示缺少 `GPU-Z.exe` | 仍在使用旧 portable；重新构建并确认当前 V4/1.4.0 包 |
| `/with-gpuz` 报缺少文件或 SHA-256 不匹配 | 选装只接受同目录、精确命名的已审计官方 GPU-Z 2.70 x86；不要绕过 |
| 两个 GPU-Z 窗口结果不同 | 只有 `GPU-Z (vGPU profile)` 加载 app-local shim；原始图标不会继承它 |
| profile 快捷方式仍显示 TU102 | 该底层字段未被当前 shim 覆盖；不要全局替换 NVAPI 或注入 DLL |
| 仍在用旧内嵌版 `VgpuPortable.exe` | 重新封装并替换 guest/base 中的旧 EXE；旧版不会自动升级 |
| UAC“未知发布者” | portable 外层是未签名用户态文件；驱动本身仍必须为正常 WHCP 签名 |
| HWiNFO 仍显示 `[FAKE]`/TU104 | 当前不在 portable 的正式适配范围；不要全局替换 NVAPI |
| legacy commit 报 mismatch | EXE、回执、VM UUID 或配置不属于同一次迁移；停止并保留原件，不要改 JSON/marker |

出现失败时记录第一条 `FAIL:`。不要安装自签驱动、导入私有根、手改 BCD、回执或
firmware claim。

详细边界：

- [通用显卡身份、GPU-Z 选装、基础镜像和克隆](GPUZ-ONE-CLICK.md)
- [HWiNFO64 app-local 实验适配与不能保证的字段](HWINFO-APP-LOCAL-EXPERIMENT.md)
- [旧 A → B 原始生产签名驱动迁移](VGPU-PRODUCTION-MIGRATION.md)
- [Code 43、黑屏与分辨率排障](DEBUG.md)
- [Windows/base/VM 新建完整流程](VGPU-VM-CREATION.md)

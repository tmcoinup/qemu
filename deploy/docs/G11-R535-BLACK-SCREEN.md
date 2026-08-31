# G-11 / R535 SDL 黑屏：定位、修复与母盘防复发

本页只适用于 G-11/NVIDIA mdev。这里处理的特征是：VM 能启动、Windows 可能仍在
运行，但本地 SDL、QMP 截图和 VFIO console 同时是纯黑。它不是宿主息屏，也不是
Guest Lite 版本问题。

## 已确认的根因

VM8 的四层证据能闭合为同一条链：

1. Windows 当前 `GraphicsDrivers` 缓存保留了旧显示器的 `1680x1050`；GRID
   538.33 的原始 `NV_Modes` 也会重新发布这个模式。
2. R535 以 32 bpp 输出，并把一行 pitch 对齐到 128 字节。`1680x1050` 因此实际
   使用 `6784 * 1050 = 0x6cb100` 字节，相当于 console 报出的 `1696x1050`。
3. `nvidia-vgpu-mgr` 又把消息缓冲补到 4 KiB，得到 `0x6cc000`，随后因长度不等
   拒绝投递 display head。宿主日志原样出现：

   ```text
   mismatch on pixel length (expected 0x6cb100 received 0x6cc000)
   Failed to deliver display head 0 message buffer with error 1
   ```

4. 现场调试确认 NVIDIA VFIO REGION 的源映射与 QEMU staging 都是同一份全零
   `0x6cb100` 缓冲。因此 SDL/EGL 没有把正常画面涂黑；它收到画面前，上游显示头
   已经投递失败。

原 10 项模式中的 `1600x900` 和 `800x600` 也不满足同一页对齐条件。只删除
`1680x1050` 会留下两个复发入口，所以当前合同统一使用：

```text
pitch = align_up(width * 4, 128)
safe  = (pitch * height) % 4096 == 0
```

审核通过的 8 项为 `1920x1080`、`1360x768`、`1280x1024`、`1280x960`、
`1280x768`、`1280x720`、`1024x768`、`640x480`。

这也解释了“偶发但概率很高”：只要旧缓存、显示驱动重枚举或同版本驱动修复再次
选中一个不安全模式，下一次 R535 接管本地 console 就可能全黑。Windows 本身无需
重装，旧 Guest Lite 也无需仅为此问题重做。

## 傻瓜恢复：只运行这一条

从仓库根目录执行，把 `8` 换成实例号：

```bash
cd /home/ubuntu/projects/qemu
sudo -v
./deploy/scripts/vmctl.sh repair-display 8
```

封装会按固定顺序执行：

1. VM 若在运行，只请求 ACPI 正常关机；绝不自动升级为强杀。
2. 关机态认证 GRID 538.33、已发布 INF 和当前 NVIDIA 设备绑定。
3. 写入 page-safe EDID/`NV_Modes`，清掉 `GraphicsDrivers` 的旧分辨率缓存。
4. 正常冷启动。

要修好后保持关机、直接准备母盘，使用：

```bash
./deploy/scripts/vmctl.sh repair-display 8 --no-start
```

若同步器明确报告 Windows 休眠或 Fast Startup，不要强挂 NTFS，也不要强杀 QEMU。
先执行：

```bash
./deploy/scripts/recover-hibernated-vm.sh 8
```

在标准 VGA 救援窗口完成完整关机后，再运行 `repair-display`。

## 新镜像首次安装或修复 GRID 驱动

不要先以普通 vGPU SDL 启动再双击 NVIDIA 安装器，也不要使用旧的 session-0
`--no-reboot` 路径。新装 Windows、旧镜像升级和同版本修复统一只运行这一条：

```bash
cd /home/ubuntu/projects/qemu
./deploy/scripts/vmctl.sh driver-install 8
```

封装会自动完成：

0. 若 VMate 已完成宿主修复，CLI 自动使用
   `/etc/vmate/g11-vgpu-host.conf` 的权威档位和包内
   `/opt/vmate/qemu-edid.g11`；因此即使源码工作区尚未构建或残留旧的 gitignore
   本机配置，也不会误回退到另一档位。调用者显式传入的路径仍优先。
1. 关机态先预置 page-safe EDID 并清理旧 `GraphicsDrivers` 缓存；驱动尚不存在时
   只写“预驱动”标记，不冒充完整收敛。
2. 用临时标准 VGA 打开本地窗口；真实 NVIDIA mdev 保持 native PnP，但固定
   `display=off`、`rombar=0`、无 ramfb、无 PCI spoof。R535 安装过程中不会成为
   QEMU console 来源。
3. 在活动 Windows 桌面清理损坏/半安装包并安装未经修改的生产签名 GRID 538.33。
   SDL/GTK 模式继续实时守护 1920×1080；`--headless` 必须先由 host 从 QEMU
   `/proc` 证明标准 VGA + `-display none` + NVIDIA `display=off`，此时不要求
   不存在的 user32 console，而把 page-safe 验收延后到完整关机后的离线步骤。
4. 收据通过后自动让 Windows 完整关机；宿主认证 DriverVersion、已发布 INF 哈希和
   当前 PnP，再写 8 项安全 `NV_Modes`。
5. 默认保持关机，便于继续制作母盘。需要立刻正常冷启动可加 `--start`。

SDL/GTK 只有收到以下安装收据，并且后续离线认证也通过，命令才返回成功：

```text
installer=0
display=1920x1080
console_bytes=8294400
console_safe=1
```

无图形宿主使用 `--headless` 时，受信收据改为
`display=0x0 / console_required=0 / console_safe=1`；这里的 `safe=1` 只表示
NVIDIA console 已被 host 拓扑隔离，绝不表示跳过最终显示合同。封装随后仍必须完成
正式签名与运行时代码完整性复检、完整关机，以及离线 8 项 page-safe
EDID/`NV_Modes` 收敛，缺一步都返回失败。

安装后复检沿用 `--install-timeout`（默认 600 秒），以覆盖 Windows Update 或
Modules Installer 占用 WinRM 的冷启动。复检会按真实的单反斜杠 NVIDIA PnP ID
匹配设备，并保留 PowerShell 错误流；因此超时会报告具体签名、PnP、服务或代码
完整性失败，不会再把“设备匹配为 0”压成空白错误。
若 Windows 忙导致 WSMan 客户端重连，AutoLogon、临时文件和策略键清理均按幂等
操作处理；上一条远程命令延迟完成时，不会因重复删除同一注册表值而误判驱动失败。

V100/R535 的已验证 1Q 组合虽然也使用 `nvidia-256` host alias，但 Guest 的正式
签名 transport 是 `PCI\VEN_10DE&DEV_1DB1&SUBSYS_125A10DE`，不是 RTX6000-1Q
的 `1E30/1325`。离线同步从 VMate 托管 host policy 中读取精确 `V100X-1Q`
进行区分；V100X-2Q 不属于 R535 合同。它已在独立的 R570.172.07 + 573.48 合同中
完成实测，不能跨版本推断。

`install-vgpu-driver.sh` 现在是上述封装内部的第二阶段，也会从实际 `/proc` QEMU
参数验证安全拓扑；在普通 `display=on` VM 中直接调用会在任何 guest 写入前拒绝。
普通启动若发现 Windows 没有认证 GRID，或虽有驱动但尚未生成显示器缓存，也会停止
并提示使用 `driver-install`；首次 PnP/显示器枚举只能在 NVIDIA console 隔离状态下
完成，因此后续新镜像不再依赖操作者记住启动参数。

## 如何确认不是另一种黑屏

先看本次启动后的宿主日志：

```bash
journalctl -u nvidia-vgpu-mgr --since "10 minutes ago" --no-pager |
  grep -E 'mismatch on pixel length|Failed to deliver display head|Xid'
```

- 出现 `expected ... received ...`：就是本页的 R535 页长度故障，使用
  `repair-display`。
- 没有长度错配但出现 Xid/TDR：按驱动/宿主 GPU 故障调查，不要用本页结论替代。
- 只有物理显示器睡眠后黑、QMP/preview 仍有画面：看
  [G11-SDL-NO-SLEEP.md](G11-SDL-NO-SLEEP.md)。
- VM 停在 UEFI/Windows 启动画面且磁盘不再前进：另查磁盘、TPM和 Windows 启动，
  不能仅凭黑色窗口判定是本故障。

修复后的运行时验收应同时满足：Windows 本地输出为 `1920x1080`；SDL/QMP 截图
不是全零；本次启动后没有新的 pixel-length mismatch。准备基础镜像时，至少完成
一次完整冷启动和完整关机，再执行封装。

## 已加入的四道防线

- 离线/在线显示器同步只发布上述 8 个 page-safe 模式，并可迁移旧 INF、15 项和
  10 项审核值；未知 `NV_Modes` 仍失败关闭。
- 首装/重装期间用标准 VGA 承担唯一 host console，NVIDIA mdev 固定
  `display=off`；普通 vGPU 启动发现无驱动时会失败关闭并指向统一入口。
- GRID 安装仍在活动桌面守护 `1920x1080` 并写结构化收据，随后必须完整关机、
  离线认证并写入 `NV_Modes`，不允许半完成状态成为母盘。
- QEMU 的 NVIDIA VFIO REGION 路径会识别非整页帧，保留 ramfb/上一帧并输出带
  分辨率和长度的明确诊断，避免无提示地用已知坏的全零 surface 覆盖画面。

整个恢复和预防路径不修改 BCD，不改变签名校验策略，不修改或重签
INF/CAT/SYS，也不安装测试签名或自签名内核驱动。宿主凭据只走当前终端的标准
sudo/运行时安全渠道，不写入仓库。

# G-11 通用底层 GPU/显示器身份：傻瓜安装与验收

本页只适用于 **G-11/vGPU**。当前正式方案不是针对鲁大师、GPU-Z 或某个 VM 的
补丁，而是 Windows 系统搜索路径中的统一用户态 NVAPI 投影；任何 32 位或 64 位
程序都读取同一份 VM 合同。内核 PnP、驱动绑定、DXGI/D3D 和 vGPU 调度仍保持
原生、生产签名的 NVIDIA GRID 538.33 路径。

## 最终结构

```text
一块真实的 guest Display adapter
  ├─ PnP / DXGI / D3D / WDDM
  │    10DE:1E30 + GRID 31.0.15.3833 + Code 0 + WHCP 签名
  ├─ 系统 NVAPI（32 位和 64 位调用者）
  │    保留 transport vendor/device = 10DE:1E30
  │    合并 profile 的板卡 Subsystem、VBIOS、时钟、GDDR5、位宽、显存厂家
  │    RT cores = 0，Tensor cores = 0（六个旧卡 device ID 的闭合能力目录）
  └─ Monitor PnP
       按同一 VM 的 MONITOR_PROFILE 发布 FriendlyName + EDID_OVERRIDE
```

这里始终只有一块逻辑显卡。`nvapi.dll` 与 `nvapi64.dll` 分别服务 32 位和 64 位
程序，它们不是两种 GPU 架构，也不会各创建一块显卡。系统投影故意保留原生
`10DE:1E30` device，只有板卡 Subsystem 等静态 profile 字段来自目录；这样硬件
工具能把 PnP 与 NVAPI 合并为同一个 adapter，不再出现“两块显卡”。

来宾 3D 也不会选错卡：Windows 只有一个 present Display，D3D/DXGI 仍打开这张
由 `nvlddmkm.sys` 驱动的原生 vGPU endpoint。身份 DLL 不创建显示设备、不实现
D3D 驱动，也不改变物理 GPU、mdev scheduler 或执行资源。

## 当前通用范围

唯一目录有 25 条原子 profile，覆盖三款 1GB 和三款 2GB GDDR5 显卡；默认随机层
仍保留原 24 条，新增项只在用户手动选择时使用：

| 型号 | 已收录板卡/显存组合 |
|---|---|
| GT 730 1GB | ASUS/Samsung、MSI/SK hynix、Gigabyte/Samsung、ZOTAC/SK hynix |
| GT 740 1GB | MSI/Samsung、ASUS/SK hynix、Gigabyte/Samsung、ZOTAC/Micron |
| GTX 750 1GB | ASUS/Samsung、MSI/SK hynix、Gigabyte/Elpida、ZOTAC/Samsung |
| GTX 750 Ti | NVIDIA/Samsung、ASUS/Samsung、MSI/SK hynix、Gigabyte/Micron、EVGA/Samsung |
| GT 1030 | ASUS/Samsung、GALAX/Samsung、ASUS/SK hynix、MSI/Micron |
| GTX 1050 | Dell/Samsung、Colorful/Samsung、MSI/Micron、Gigabyte/SK hynix |

每一行把型号、PCI Subsystem、板卡品牌、VBIOS、时钟、位宽、带宽、显存类型、
显存厂家 enum 和核心字段一起锁定。安装器不允许从不同 profile 拼字段，也没有
VM 编号、进程名或某个品牌的 fallback。查看机器当前可选值：

1GB 厂商正式型号、P/N、公开商品码和实体 S/N 边界见
[`G11-1GB-GPU-EXPANSION.md`](G11-1GB-GPU-EXPANSION.md)。

```bash
cd /home/ubuntu/projects/qemu
./deploy/package-system-nvapi-projection.sh --list-profiles
```

## 安装前提

目标 VM 必须使用普通 G-11 `B/name-only` 配置，并先在未修改的 GRID 538.33 上
达到以下状态：

- 设备管理器只有一个 present NVIDIA Display；
- PnP 以 `PCI\VEN_10DE&DEV_1E30` 开头；
- 驱动版本 `31.0.15.3833`，设备 Code 0；
- 驱动是 NVIDIA/Microsoft 正式签名；
- `testsigning`、`nointegritychecks` 均未启用。

若这些前提不满足，先修驱动或 vGPU transport；身份包会失败关闭，不能掩盖
Code 43、第二个 Display 或签名问题。

## 傻瓜安装

在宿主构建一个只绑定目标 VM UUID、GPU profile、显示器 profile 和驱动事实的
私有包：

```bash
cd /home/ubuntu/projects/qemu
VM_ID=9
./deploy/package-system-nvapi-projection.sh "$VM_ID"
```

命令成功后会打印一个目录、一个只读 ISO 和 ISO SHA-256。默认位置是：

```text
/home/ubuntu/images/vms/<VM_ID>/packages/SystemNvapiProjection/
```

包与该 VM 的磁盘、NVRAM 放在同一个数字 VM bundle 内；执行
`./deploy/scripts/vmctl.sh delete <VM_ID>` 时会一起删除，不会在全局 staging 留下
孤儿目录。只有显式传入 `--output-root` 才会导出到外部目录，外部导出不属于
`delete-vm` 的清理范围。

接下来只做三件事：

1. 将刚生成的 ISO 只读挂到它绑定的 VM，或把同名输出目录完整复制进该 VM；
2. 在 Windows 双击 `Run-As-Administrator.cmd`，确认一次 UAC；
3. 原生 x86/x64 D3D12 门禁都通过后，等 Windows 自动重启，再等待约
   1～2 分钟让 SYSTEM 完成验证。

若任一 D3D12 探针报非零 ray-tracing tier，第 2 步会在任何系统投影写入前
失败并且不重启。这是所选旧卡与签名驱动 transport 不一致，不是光盘故障。

安装器会保存 NVIDIA 原件、安装 32/64 位系统转发 DLL、写入完整原子合同、发布
显示器 EDID，并注册启动/登录后的持久收敛任务。旧基础盘若残留
`RefreshGridNames`，新任务会在设备枚举后重新发布整份当前合同，因此旧任务不能
把 `IdentityPciProjectionMode` 或显存厂家覆盖掉。

升级已有系统投影时，旧 DLL 只有同时满足以下条件才会被接受：旧 validated
收据与当前 VM UUID/driver/PnP 匹配、旧 payload manifest 精确锁定 DLL 哈希、PE
位数正确，并且相邻的 NVIDIA 正式签名原件可验证。仅有 marker 或未知 DLL 会
失败关闭。

## 验收

成功安装并重启后，双击 `Verify-As-Administrator.cmd`。窗口必须同时看到
两次 `SYSTEM_NVAPI_VERIFY PASS`（每行均含 `RT=0 Tensor=0`）与两次
`D3D12_NATIVE_VERIFY PASS`（每行均含 `native_raytracing_nonzero=no`）；
最后显示目标显存类型、显存厂家和显示器的 `PASS`。
受保护收据位于：

```text
C:\ProgramData\G11\SystemNvapiProjection\receipts\<contract>-validated.json
```

管理员 PowerShell 可再只读复核：

```powershell
Get-PnpDevice -Class Display -PresentOnly |
  Format-List FriendlyName,InstanceId,Status

Get-CimInstance Win32_VideoController |
  Format-List Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode

Get-PnpDevice -Class Monitor -PresentOnly |
  Format-List FriendlyName,InstanceId,Status

Get-ChildItem "$env:ProgramData\G11\SystemNvapiProjection\receipts\*-validated.json"
```

验收标准：

- Display 数量恰好为 1，Code 0，驱动 `31.0.15.3833`；
- `dxdiag` 只有一个 Display Devices 条目，Direct3D feature levels 正常；
- Monitor 显示 VM 配置的型号，例如 `AOC 2470W`，不再是“通用即插即用监视器”；
- 硬件工具先执行其“重新扫描”，再看显卡页；板卡、显存厂家、GDDR5、位宽、
  带宽和时钟应与该 profile 同一行一致；
- 不再出现“本机共有 2 块显卡”。

硬件工具自己的旧缓存不会因注册表已更新而自动丢弃，所以必须重新扫描；这只是
验收动作，不是实现依赖。换成其他查询程序、32/64 位程序或其他 VM，底层合同仍是
同一个。

## 黑屏结论

本机对照验收中，desktop 537.58（guest `31.0.15.3758`）在当前宿主栈触发过
host `Xid 43` 和 guest TDR/驱动卸载，表现为偶发或持续黑屏。原生 GRID 538.33
（guest `31.0.15.3833`）对照路径没有该 Xid/TDR，因此 537.58 的两条已审计记录
现已标记 `quarantined-runtime-instability`：

- 可删除克隆仍可显式复现实验，保留证据；
- `stage/commit/finalize`、正常 VM 启动、显示器同步和系统身份打包全部拒绝把它
  当作生产路径；
- 不能因原版 WHQL 或曾经 Code 0 就解除隔离。

驱动枚举时画面瞬间闪一下可以观察；持续黑屏、Xid、TDR、Code 非 0 或 Display
消失都属于失败。不要靠重试、睡眠唤醒或关闭完整性检查掩盖。

## 回滚

在原包内双击 `Rollback-As-Administrator.cmd` 并确认 UAC。Windows 会恢复保存的
NVIDIA 正式签名原件、删除持久任务并自动重启。重启后会生成 `rolled-back`
收据。若自动回滚失败，保留以下日志，不要手工覆盖 DLL：

```text
C:\Windows\Temp\G11-System-NVAPI-Rollback.log
```

## 开发回归

```bash
cd /home/ubuntu/projects/qemu
./deploy/tests/vgpu/test_nvapi_identity_shim_static.sh
./deploy/tests/vgpu/test_system_nvapi_projection_package.sh
./deploy/tests/vgpu/test_signed_consumer_probe_gate.sh
./deploy/tests/vgpu/test_signed_consumer_production.sh
```

第二项实际生成 GTX 750 Ti、GT 1030、GTX 1050 三个互不相关的 VM 包，同时覆盖
ASUS/MSI/Gigabyte、Samsung/Micron/SK hynix 和三款显示器，并检查合同、EDID、
ISO、x86/x64 payload 及无内核驱动资产。

整个流程不修改 BCD，不开启 `testsigning`/`nointegritychecks`，不修改或安装
INF/CAT/SYS，不导入证书，也不安装测试签名/自签名内核驱动。宿主凭据不写入包、
日志或仓库。

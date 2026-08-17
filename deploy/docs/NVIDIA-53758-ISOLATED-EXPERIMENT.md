# NVIDIA 537.58 隔离兼容性实验

这不是正式安装器，只用于证明原版 NVIDIA desktop 537.58 WHQL 能否在 G-11
`mdev` 上以 catalog 选中的真实 consumer PCI/Subsystem 身份初始化。当前验证器
支持 Dell GTX 1050 和 ASUS GTX 750 Ti 两条独立审核行；任何正式 VM 和基础镜像
都不得直接运行，必须使用有独立磁盘、可直接丢弃的克隆，不按 VM 编号做例外。

实验始终遵守以下边界：

- 不修改 `nvddig.inf`、`nv_disp.cat`、`nvlddmkm.sys` 的任何字节；
- 不导入证书，不生成或安装测试签名/自签名内核驱动；
- 不写 BCD，不开启 `testsigning` 或 `nointegritychecks`；
- 第一阶段只执行 `pnputil /add-driver`，不带 `/install`，不改变当前设备绑定；
- 不解除 `start-vm.sh` 的 strict-A 门禁。

脚本对 BCD 的唯一操作是只读执行 `bcdedit /enum all`：进入阶段时检查两个完整性
开关未启用并保存规范化输出的 SHA-256，退出阶段时再次读取；哈希不同即失败。脚本
没有 `/set`、`/deletevalue`、`/bootsequence` 或其他 BCD 写入路径。

锁定候选按 `driverKey` 选择，不能跨行拼接：

| driver key | canonical profile | 精确目标 PnP | 原版 INF 审核行 | INF SHA-256 |
|---|---|---|---|---|
| `nvidia-53758-dch-whql-gtx1050-dell` | `gtx1050_2gb` | `PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028` | `nvddig.inf` / `Section029` / 精确 Dell Subsystem | `C2860E03D30F7BA610F9726765354E75CABB624791AECEA61478066D9EAD50F1` |
| `nvidia-53758-dch-whql-gtx750ti-asus` | `gtx750ti_asus_2gb` | `PCI\VEN_10DE&DEV_1380&SUBSYS_84BB1043` | `nv_dispig.inf` / `Section010` / 正式 `VEN_10DE&DEV_1380` 行 | `1B7B9F3A5A13A4FEC0074BCEA8A1DD64336CEF228041B1124B8E31D41CDED957` |

ASUS 的原版 INF 行按 device 匹配，不含 Subsystem；这不降低目标约束。合同、QEMU
外层投影和 SYSTEM 验收仍必须精确一致到 `SUBSYS_84BB1043`，更换任何 Subsystem
都会得到不同 profile/qualification，并失败关闭。

两条共享的原版包与签名锁为：

```text
Driver:        31.0.15.3758 / desktop 537.58
Installer SHA: D6345ABE590E151796ABC424D6661508735AB86CFF58FB644F23D270E89DCB93
CAT SHA:       08AD09F3B13E78D40B674914178B51090EABF99DF3FD1571C7DCBB367D8B430B
SYS SHA:       19DBE8ED10DA6052EBFF22B70F51B710C8233ABB237BD544163025B1313EB5F2
CAT signer (Microsoft WHCP):
               B878D8EB696CF3D4505E2F6641C57AF9062EC51A
SYS embedded signer (NVIDIA):
               01DF5BFEFA251B27AC1933E4E4CB61F21C44D57B
```

签名显示有一个容易误判、但不放宽信任边界的 Windows 行为：从原包目录直接检查
上述固定哈希的 `nvlddmkm.sys` 时，`Get-AuthenticodeSignature` 返回 NVIDIA
Corporation 的 PE 内嵌生产签名（`01DF...D57B`）；同一份 SYS 进入 DriverStore
后，Windows 可能通过同目录的 `nv_disp.cat` 解析签名，因此返回 Microsoft Windows
Hardware Compatibility Publisher（`B878...C51A`）。验收器会先核对 SYS 的完整
SHA-256，然后只接受以下两组精确的“主体 + thumbprint”组合：

- `nvidia-embedded`：NVIDIA Corporation + `01DF...D57B`；
- `microsoft-whcp-catalog`：Microsoft Windows Hardware Compatibility Publisher +
  `B878...C51A`。

这不是“任意 NVIDIA/Microsoft 签名均可”。状态不是 `Valid`、主体或 thumbprint
不同、自签名，或者 SYS 哈希不同，都会直接失败；工具不会导入或信任替代证书。

## 一键打包

先确认目标 VM 是独立可丢弃克隆，并且当前仍以 B/native 启动，只有一张
`DEV_1E30` Display，GRID 538.33 为 Code 0。VM 的 canonical `GPU_PROFILE` 会
自动选择唯一 driver row；若没有或不唯一就拒绝打包。然后在宿主运行：

```bash
./deploy/package-nvidia-53758-experiment.sh VM_ID \
  --confirm-disposable-clone
```

脚本从已审计的原版厂商 EXE 重新解出完整 `Display.Driver`，逐文件生成 SHA-256
清单，并同时输出 VM UUID 绑定目录和 `.iso`。目录用于宿主审计；ISO 供 Windows
只读挂载。打包过程不接触 VM 磁盘或配置。

## 阶段 1：B/native add-only

1. 把打包器输出的 `.iso` 作为只读 CD 挂到对应 Windows 克隆。
2. 打开光盘，右键 `Run-Phase1.cmd`，选择“以管理员身份运行”。
3. 工具核对 VM UUID、完整 payload、原始 INF/CAT/SYS、WHCP/NVIDIA 生产签名，
   并确认当前是 `DEV_1E30`、538.33、Code 0。
4. 工具只把原包加入 DriverStore；随后再次确认 Display InstanceId 和活动
   `oemN.inf` 没有变化。
5. staged 回执落盘后，Windows 通过原生关机 API 完整关机。

回执目录：

```text
C:\ProgramData\QemuNvidia53758Experiment\receipts
```

只有 staged 回执同时满足以下字段，宿主侧才可进入 PCI 切换实验：

```text
phase = staged
result = pass
baselinePnpId = PCI\VEN_10DE&DEV_1E30...
baselineDriverVersion = 31.0.15.3833
activeInfBefore = activeInfAfter
activeDriverChanged = false
testsigning = false
nointegritychecks = false
bcdChanged = false
```

## 阶段 2：目标身份启动验收

宿主在克隆完全停止后才切换实验 PCI 身份。下次开机时，阶段 1 安装的 SYSTEM
启动任务自动运行，不需要再次双击文件。

验收要求全部满足：

- 只有一张 present Display；
- `HardwareIds` 精确包含合同选择的完整 PnP；当前允许值只有
  `PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028` 或
  `PCI\VEN_10DE&DEV_1380&SUBSYS_84BB1043`；
- 设备名称与所选 canonical profile 精确一致（GTX 1050 或 GTX 750 Ti）；
- `ConfigManagerErrorCode=0`，版本为 `31.0.15.3758`；
- 活动 DriverStore INF/CAT/SYS 是上述固定哈希；
- catalog 为锁定的 Microsoft WHCP 签名；固定哈希的 DriverStore/加载中
  `nvlddmkm.sys` 必须解析为上面两条锁定签名路径之一，任何其他 signer 均失败；
- BCD 全部 entry 中 `testsigning`、`nointegritychecks` 都未开启，而且前后快照
  没有变化。

成功写 `validated/pass` 回执；失败（包括 Code 28、Code 43、Basic Display、签名或
版本不符）写 `validated/fail` 回执。两种结果都会注销一次性任务并完整关机，避免
失败克隆反复启动。若误以 B/native 再开机，任务只等待下一次启动，不改设备、不关机。

537.58 只有在本实验得到 pass、多次冷启动仍为 Code 0、1920×1080、host vGPU
授权和帧率状态也正常后，才证明“驱动兼容性候选”成立。单独看到 INF 包含目标 ID，
或只看到生产签名，均不代表问题已经解决。

# G-11 signed-consumer 路径：537.58 已隔离

## 当前结论

desktop 537.58（guest `31.0.15.3758`）不再是 G-11 生产路径。它的原版 WHQL
文件和两条审计记录仍保留，便于在明确可删除的克隆上复现实验，但目录状态固定为：

```text
quarantined-runtime-instability
```

原因是本机真实对照验收发现该路径会触发 host `Xid 43`，随后 guest 出现 TDR、
`nvlddmkm` 卸载及黑屏；原生 GRID 538.33（guest `31.0.15.3833`）对照路径稳定。
“原版 WHQL”“曾经 Code 0”只能证明签名与某一时刻的枚举成功，不能证明长期 vGPU
运行稳定。

当前正式架构改为：

```text
原生 10DE:1E30 + GRID 538.33 + Code 0
  └─ 通用系统 NVAPI 单-adapter 合并投影
       ├─ 保留 transport vendor/device，D3D/DXGI 继续用原生 vGPU
       ├─ 投影 profile 的板卡 Subsystem 与静态 GPU/显存字段
       └─ 同步 VM 的 monitor EDID/FriendlyName
```

安装和验收见
[`G11-BOTTOM-GPU-IDENTITY.md`](G11-BOTTOM-GPU-IDENTITY.md)。

## 保留的审计行

| driver key | canonical profile | 原版 INF 事实 | 当前生产状态 |
|---|---|---|---|
| `nvidia-53758-dch-whql-gtx1050-dell` | `gtx1050_2gb` | Dell `10DE:1C81 / 1028:11C0` | quarantined |
| `nvidia-53758-dch-whql-gtx750ti-asus` | `gtx750ti_asus_2gb` | 通用 `VEN_10DE&DEV_1380` 行，目标锁定 ASUS `1043:84BB` | quarantined |

这些行继续锁定 installer、INF、CAT、SYS、签名者、builder 和 guest validator 的
哈希。保留它们不等于允许生产启用；未来若出现另一个稳定版本，应新增独立 driver
key 并重新完成运行时资格，而不是把 537.58 状态改回去复用旧证明。

## 生产门禁

以下所有入口都会调用同一个 `production-enabled` 断言并失败关闭：

- `signed-consumer-production.sh record-proof/stage/commit/finalize`；
- 带已有 `signed-consumer-v2` 合同的正常 `start-vm.sh`；
- `package-system-nvapi-projection.sh`；
- `sync-monitor-profile.sh`。

显式传 `--driver-key` 不能绕过隔离。root 持有的旧 qualification、validated 回执
或 VM UUID 匹配也不能绕过，因为稳定性状态在读取证明之前检查。

查看某台 VM 是否还残留旧合同：

```bash
cd /home/ubuntu/projects/qemu
VM_ID=456
./deploy/signed-consumer-production.sh status "$VM_ID"
```

若显示 `pending-validation` 或 `validated`，先完整关闭 VM，再恢复提交前的原生
`B/name-only` 配置：

```bash
sudo ./deploy/signed-consumer-production.sh rollback "$VM_ID"
./deploy/signed-consumer-production.sh status "$VM_ID"
```

只有看到 `B/name-only（无 signed-consumer production 合同）` 后，才按新系统身份
教程重新打包。rollback 校验原配置备份 SHA 并原子恢复，不修改 Windows 磁盘。

## 仅供可删除克隆复现实验

审计工具仍使用与生产默认选择分离的
`signed_consumer_driver_audited_default_for_profile`。这只允许以下显式隔离流程保留
证据，不会生成可启动的生产合同：

```bash
cd /home/ubuntu/projects/qemu
PROOF_VM_ID=123

./deploy/package-nvidia-53758-experiment.sh "$PROOF_VM_ID" \
  --confirm-disposable-clone

./deploy/probe-signed-consumer-vgpu.sh "$PROOF_VM_ID" \
  --attest-disposable-clone --stage outer-only
./deploy/probe-signed-consumer-vgpu.sh "$PROOF_VM_ID" \
  --stage outer-only
```

目标必须是停机时可直接删除的克隆；一次性 attestation 与 VM UUID、磁盘 inode、
配置哈希、QEMU、宿主驱动栈及 stage 绑定。不要在业务 VM 上运行，不要把实验结果
`record-proof` 或提交为生产。

## 黑屏判定

短暂的显示重枚举闪烁与持续黑屏不是一回事。以下任一项出现即判定失败：

- `journalctl`/内核日志出现新的 NVIDIA `Xid 43`；
- Windows 事件中出现新的 Display 4101、TDR 或 `nvlddmkm` 卸载；
- present Display 消失、Code 非 0、分辨率不能恢复；
- QEMU 仍为 running，但 SDL/GTK 长时间保持全黑。

不要通过睡眠唤醒、反复重试、安装自签驱动或降低代码完整性来“通过”验收。

## 安全边界

- 不开启 `testsigning`、`nointegritychecks`，不改 BCD；
- 不修改 INF/CAT/SYS，不导入证书，不安装测试签名/自签名内核驱动；
- 不启用 legacy A/internal PCI identity 或 per-mdev FRL；
- 宿主凭据不进入仓库、包、回执或日志；
- 正式身份只使用原生 538.33 transport 与内容绑定的系统用户态投影。

回归门禁：

```bash
./deploy/tests/vgpu/test_signed_consumer_probe_gate.sh
./deploy/tests/vgpu/test_signed_consumer_production.sh
```

第一项证明隔离实验仍然是可删除克隆/tuple/一次性 FD/stage 绑定；第二项证明两条
537.58 行可审计复现，但不会成为任何生产默认，且所有生产入口都含隔离断言。

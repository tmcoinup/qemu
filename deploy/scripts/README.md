# G-11 统一脚本入口

从仓库根目录操作时，日常命令统一使用 `./deploy/scripts/`。这与 V-11 的入口目录
一致；G-11 的 NVIDIA mdev/vGPU 实现、参数和验收边界仍保持独立。

## V-11 / G-11 可共用的路径习惯

| 操作 | 统一命令 |
|---|---|
| 启动 | `./deploy/scripts/start-vm.sh ID [options]` |
| 停止 | `./deploy/scripts/stop-vm.sh ID [options]` |
| 运行中显示控制 | `./deploy/scripts/ctl-vm.sh ID ACTION` |
| 初始化宿主 bridge | `./deploy/scripts/setup-bridge.sh` |
| 可选 NVMe APST 管理 | `./deploy/scripts/host-nvme-apst.sh ACTION` |

`deploy/scripts/` 同时是公开入口和唯一实现位置。旧的 `deploy/*.sh` 生命周期入口及
`deploy/host/setup-bridge.sh` 已删除；脚本、教程和 `vmctl.sh` 都只使用这里，不再保留
两套同名文件。

## G-11 专用 VM 生命周期操作也放在同一目录

```bash
./deploy/scripts/create-vm.sh ID
./deploy/scripts/create-disk.sh ID --blank
./deploy/scripts/clone-vgpu-base.sh ID --start
./deploy/scripts/promote-base.sh ID
./deploy/scripts/delete-vm.sh ID
./deploy/scripts/sync-monitor-profile.sh ID --force
./deploy/scripts/recover-hibernated-vm.sh ID
./deploy/scripts/report-vm-boot-timing.sh ID
./deploy/scripts/migrate-g11-layout.sh --check
./deploy/scripts/vmctl.sh start ID
```

这些文件就是唯一实现，共用 `deploy/lib/` 中的内部库。宿主凭据仍只能通过批准的
运行时安全渠道或环境变量提供，脚本不会保存凭据。

## 不强行统一的名称

- V-11 的 `clone-from-base.sh` 允许选择 VirtIO 分支的 base；G-11 克隆必须验证
  portable attestation 和固定 standalone base，因此保留 `clone-vgpu-base.sh`。
- V-11 的 raw QMP `savevm/loadvm` 不能当作 NVIDIA mdev/vGPU 安全快照，G-11
  不提供同名伪兼容入口。
- `--headless`、VirtIO GPU/驱动及 G-11 vGPU/授权参数仍属于各自分支，不能仅因
  脚本路径相同就混用。

最省心的 G-11 日常入口仍是：

```bash
./deploy/scripts/vmctl.sh start 11
./deploy/scripts/vmctl.sh display 11 status
./deploy/scripts/vmctl.sh stop 11
```

这些变化不启用 `testsigning` 或 `nointegritychecks`，不修改 BCD，也不安装测试签名
或自签名内核驱动。

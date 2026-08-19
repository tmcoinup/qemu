# G-11 统一脚本入口

从仓库根目录操作时，G-11 日常命令统一使用 `./deploy/scripts/`。当前运行时只维护
NVIDIA mdev/vGPU 路径，不枚举已退役分支的标题、端点或参数。

## G-11 统一路径

| 操作 | 统一命令 |
|---|---|
| 启动 | `./deploy/scripts/start-vm.sh ID [options]` |
| 停止 | `./deploy/scripts/stop-vm.sh ID [options]` |
| 运行中显示控制 | `./deploy/scripts/ctl-vm.sh ID ACTION` |
| 初始化宿主 bridge | `./deploy/scripts/setup-bridge.sh` |
| 可选 NVMe APST 管理 | `./deploy/scripts/host-nvme-apst.sh ACTION` |
| 封装基础镜像 | `./deploy/scripts/seal-base.sh SOURCE_ID BASE_NAME` |
| 克隆基础镜像 | `./deploy/scripts/clone-from-base.sh BASE_NAME NEW_ID [options]` |

`deploy/scripts/` 同时是公开入口和唯一实现位置。旧的 `deploy/*.sh` 生命周期入口及
`deploy/host/setup-bridge.sh` 已删除；脚本、教程和 `vmctl.sh` 都只使用这里，不再保留
两套同名文件。

## G-11 专用 VM 生命周期操作也放在同一目录

```bash
./deploy/scripts/create-vm.sh ID
./deploy/scripts/create-disk.sh ID --blank
./deploy/scripts/seal-base.sh 1 win10-ltsc-v1
./deploy/scripts/clone-from-base.sh win10-ltsc-v1 11 --start
./deploy/scripts/delete-vm.sh ID
./deploy/scripts/sync-monitor-profile.sh ID --force
./deploy/scripts/recover-hibernated-vm.sh ID
./deploy/scripts/report-vm-boot-timing.sh ID
./deploy/scripts/migrate-g11-layout.sh --check
./deploy/scripts/vmctl.sh start ID
./deploy/scripts/vmctl.sh display ID preview-on
./deploy/scripts/vmctl.sh preview-capacity --instances 16 --rate 60
./deploy/scripts/vmctl.sh cdrom ID mount /absolute/file.iso
./deploy/scripts/vmctl.sh cdrom ID eject
./deploy/scripts/shared-usb.sh ID mount
./deploy/scripts/shared-usb.sh ID eject
./deploy/scripts/usb-directory.sh ID mount /absolute/host/directory
./deploy/scripts/guest-lite.sh ID usb-mount
# 仅旧版 VgpuPortable/诊断兼容：
./deploy/scripts/guest-performance.sh ID mount
./deploy/scripts/guest-performance.sh ID eject
```

这些文件就是唯一实现，共用 `deploy/lib/` 中的内部库。宿主凭据仍只能通过批准的
运行时安全渠道或环境变量提供，脚本不会保存凭据。
普通启动默认不创建光驱；上面的 `mount` 会热插只读光驱，`eject`
会删除整台设备。只有 `start-vm.sh ID --install [ISO]` 会在启动时挂光驱。
公共工具 U 盘固定映射 `shared/usb/`，每个工具只管理自己的子目录；Windows 中的
真实 FAT 卷标固定为 `U盘`（CP936），不使用 `autorun.inf` 覆盖名称。它和任意
host 目录 U 盘均为只读 VVFAT/USB Mass Storage，不需要 Windows 额外驱动。详见
[`../docs/G11-USB-DIRECTORY.md`](../docs/G11-USB-DIRECTORY.md)。
新版 `VgpuPortable.exe` 已在同一次双击中应用可回滚的登录启动优化。只有仍使用
旧版 EXE 或支持人员需要独立诊断时，才运行 `guest-performance.sh ID mount`，详见
[`../docs/G11-GUEST-PERFORMANCE.md`](../docs/G11-GUEST-PERFORMANCE.md)。

native 启动默认创建与网络编码分离的 DGame preview，发布
`/tmp/qemu-stealth-ID.{fb,qmp,mon}`，SDL 标题统一为 `win10-ID`。QMP/进程身份仍为
`vmID`。`preview-on` 可给旧的运行中 VM 无重启补帧源；GPU/title/逐进程内存授权
在下次用新 QEMU 正常启动后完整生效。

## 基础镜像名称和方法

- 公开文件名使用 `seal-base.sh` 和 `clone-from-base.sh`。
- 参数顺序固定为 `seal-base.sh SOURCE_ID BASE_NAME` 和
  `clone-from-base.sh BASE_NAME NEW_ID`。`BASE_NAME` 只写字母、数字、`_`、`-`，
  不写 `.qcow2`。
- 推荐名称为 `<系统>-<版本或用途>-v<代号>`，例如
  `win10-ltsc2021-game-v1`。镜像内容换代就使用 `v2`，不要使用含义会漂移的
  `latest`；同名受控替换虽然会归档旧代，但不应代替版本命名。
- G-11 每个名称独立发布为 `shared/bases/<BASE_NAME>.qcow2`，证明文件为
  `shared/bases/<BASE_NAME>.qcow2.vgpu-portable.json`。例如 `win10-ltsc-v1`
  与 `win11-vgpu-v2` 可以同时存在，clone 必须点名选择。
- G-11 的 `seal-base.sh` 默认先离线
  清理源盘里的 WeGame/Tencent QIMEI、登录态、SDK/设备缓存与注册表键。清理失败
  不发布 base；只有明确要原样保留这些身份时才传 `--no-clean`。
- G-11 的 `clone-from-base.sh` 只接受托管的具名 standalone base，并强制校验该
  名称自己的 portable attestation。
- 旧的 `promote-base.sh`、`clone-vgpu-base.sh` 只保留为转发兼容入口；教程、
  `vmctl.sh` 和新自动化不再使用旧名称。兼容入口固定映射历史名称
  `win10-base`，新 base 必须使用 canonical 命令显式命名。
- raw QMP `savevm/loadvm` 不能当作 NVIDIA mdev/vGPU 安全快照，G-11 不提供同名
  伪兼容入口。

最省心的 G-11 日常入口仍是：

```bash
BASE_NAME=win10-ltsc-v1
./deploy/scripts/vmctl.sh seal 1 "$BASE_NAME"
./deploy/package-vgpu-one-click.sh
sudo ./deploy/install-vgpu-portable-to-base.sh --base-name "$BASE_NAME"
./deploy/scripts/vmctl.sh clone "$BASE_NAME" 11 --start
./deploy/scripts/vmctl.sh start 11
./deploy/scripts/vmctl.sh display 11 status
./deploy/scripts/vmctl.sh stop 11
```

前四条分别完成“清理并封装 base → 构建无凭据 portable → 安全注入并生成证明 →
克隆”。宿主凭据不会写入仓库；`sudo` 只通过运行时安全渠道取得授权。

以后增加第二个基础镜像时换一个名字即可，不需要覆盖第一代：

```bash
BASE_NAME=win11-vgpu-v2
./deploy/scripts/vmctl.sh seal 2 "$BASE_NAME"
./deploy/package-vgpu-one-click.sh
sudo ./deploy/install-vgpu-portable-to-base.sh --base-name "$BASE_NAME"
./deploy/scripts/vmctl.sh clone "$BASE_NAME" 12 --start
./deploy/scripts/clone-from-base.sh --list-bases
```

这些变化不启用 `testsigning` 或 `nointegritychecks`，不修改 BCD，也不安装测试签名
或自签名内核驱动。

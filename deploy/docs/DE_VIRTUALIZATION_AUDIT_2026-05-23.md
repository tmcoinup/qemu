# QEMU 去虚拟化复审报告（2026-05-23）

> **处理状态（2026-05-23 收尾）**：本文为第三轮 GPT 复审快照。其中所列 **P0（NBD busy
> 失败路径误断外部连接）与全部 P1（DRY_RUN 边界副作用、NBD 默认固定 nbd0）均已修复并验证**，
> 详见 `deploy/docs/REFACTOR_2026-05-23.md`（D/E 节 + 迭代说明）。
> 仅保留两个 P2：`apply-gpu-spoof.ps1` 拆分（需 pwsh + 测试 VM）、平台 machine-type 层
> 改造（长期）。本快照保留作历史评审记录。

## 范围与结论

审计对象是当前工作树 `/home/ubuntu/projects/qemu`。本轮是在上一版复审之后再次检查，重点核对：profile 安全解析、DRY_RUN 副作用、NBD 离线挂载安全、USB HID、平台 PCI ID、验证脚本 warning、文档同步和测试结果。

总体判断：上轮剩余风险里，profile 读取路径已经明显改善，`host-fix-gpu-devpkey.sh` 和 `host-fix-display-cache.sh` 不再直接 `source/eval` profile；`DRY_RUN=1` 对新实例的 profile、磁盘、OVMF VARS、TPM state/daemon 已经做到不落盘；`verify-stealth.sh`、HID smoke、stop-vm smoke 均通过。当前仍不建议按“无残余风险”验收，主要阻断是 NBD busy 检查和 cleanup trap 的组合会在失败路径反向断开外部 NBD；另外 DRY_RUN 在旧布局迁移和已有 socket 清理上仍有边界副作用。

## 已确认修复

| 项目 | 当前状态 | 证据 |
| --- | --- | --- |
| USB HID 崩溃 | 已修复 | `hw/usb/dev-hid.c:790` 仅在 `iSerialNumber != 0` 时调用 `usb_desc_create_serial()`；kbd/mouse/tablet smoke 不再断言 |
| 关机脚本匹配 | 已修复 | `deploy/scripts/stop-vm.sh:42` 兼容 `win10-N` 和旧 `win10-ryzen3-N`；QMP-only 路径实测可停 |
| root-port/xHCI 平台 ID | 已改善 | `gen_pcie_root_port.c` 和 `hcd-xhci-pci.c` 支持 `x-pci-vendor-id/device-id/revision`，`verify-stealth.sh` step 15 通过 |
| verify warning | 已修复 | `verify-stealth.sh` 15 项通过，未再出现原 TCG feature warning |
| profile 主解析 | 已改善 | `stealth_load_profile()` 改为白名单解析，不再 `source/eval` profile |
| 单字段 profile 读取 | 已改善 | `stealth_profile_get()` 新增，`host-fix-gpu-devpkey.sh`、`host-fix-display-cache.sh` 已使用 |
| DRY_RUN 新实例 | 大部分修复 | 新实例 `DRY_RUN=1` 实测不创建 VM_DIR/profile/disk/OVMF VARS，不启动 swtpm |
| 文档同步 | 部分修复 | `USAGE.md` 已补 `STRICT_STEALTH`、`ALLOW_NAT_FALLBACK`、`DRY_RUN` |

## 当前阻断与风险

### P0. NBD busy 失败路径仍可能断开外部连接

证据：

| 位置 | 问题 |
| --- | --- |
| `deploy/scripts/lib/nbd-lock.sh:34..45` | `nbd_assert_device_free "$NBD"` 发现 busy 后 `exit 1`，设计意图是不强断 |
| `deploy/scripts/host-fix-gpu-devpkey.sh:149..155` | `trap cleanup EXIT` 在 busy 检查前已安装 |
| `deploy/scripts/host-fix-gpu-devpkey.sh:151..152` | cleanup 无条件执行 `qemu-nbd --disconnect "$NBD"` |
| `host-fix-display-cache.sh`、`host-clean-tencent.sh` 等 | 同类模式：trap 先安装，cleanup 无条件 disconnect |

影响：如果 `/dev/nbd0` 被外部进程或另一套工具占用，`nbd_assert_device_free` 会触发退出，但 EXIT trap 随后运行，仍会 `qemu-nbd --disconnect "$NBD"`，这正好违背“不强断外部连接”的目标，可能造成外部挂载中断或数据风险。

改进方法：

- 增加 `NBD_CONNECTED=0`，只有 `qemu-nbd --connect` 成功后设置为 `1`。
- cleanup 改成 `[[ "$NBD_CONNECTED" == "1" ]] && qemu-nbd --disconnect "$NBD"`。
- 或者把 `trap cleanup EXIT` 放到 `nbd_assert_device_free` 之后，并在 connect 成功后再启用 disconnect 清理。
- 所有 host NBD 工具统一套同一个 helper，避免每个脚本复制 cleanup 模式。

### P1. DRY_RUN 仍有两个边界副作用

证据：

| 位置 | 问题 |
| --- | --- |
| `deploy/scripts/lib/sv-cli.sh:142..154` | 兼容旧布局迁移仍会在 `DRY_RUN=1` 时 `mv` 老 qcow2/profile/OVMF VARS |
| `deploy/scripts/lib/sv-identity.sh:111` | `DRY_RUN=1` 仍会 `rm -f "$QMP_SOCK" "$MON_SOCK"` |

影响：新实例 dry-run 已经干净，但如果实例存在旧布局文件，dry-run 可能移动真实文件；如果实例正在运行，dry-run 可能删除它的 QMP/HMP socket，影响控制面。

改进方法：

- `DRY_RUN=1` 时旧布局迁移只打印计划，不执行 `mv`。
- `DRY_RUN=1` 时禁止删除 QMP/MON socket，只在 argv 里展示目标路径。
- 增加测试：存在 legacy 文件、存在 dummy unix socket 时运行 dry-run，验证文件和 socket 保持不变。

### P1. NBD 默认仍固定 `/dev/nbd0`

证据：

| 位置 | 当前状态 |
| --- | --- |
| `deploy/scripts/lib/nbd-lock.sh:19..29` | 已有 `nbd_pick_free()` |
| 多个 `host-*.sh` | 默认仍是 `NBD=/dev/nbd0`，没有在默认路径调用 `nbd_pick_free()` |

影响：虽然 busy 现在能被发现，但默认总撞 `/dev/nbd0`，操作体验和自动化可靠性仍差。一旦配合上面的 cleanup bug，还会扩大风险。

改进方法：

- 如果用户没有显式传 `NBD=...`，统一 `NBD="$(nbd_pick_free)"`。
- 显式传 `NBD` 时再执行 busy fail-fast。
- 把默认值说明从各脚本文档里同步为“自动选择空闲 NBD”。

### P2. 平台画像仍是局部一致，不是完整 chipset 仿真

| 面 | 当前状态 |
| --- | --- |
| root-port/xHCI | 已按 AMD/Intel 注入 ID |
| machine type | 仍为 `q35`，基础 host bridge/ICH9 语义偏 Intel |
| audio | `deploy/scripts/lib/sv-assemble.sh` 固定 `intel-hda` |
| AMD profile | 有 AMD DF stub，但南桥/音频/ACPI/PCI capability 仍未完整 AMD 化 |

影响：当前更准确的定位是“降低明显静态冲突”，不是完整 AMD/Intel 平台模拟。跨表检查仍可能发现混合平台。

改进方法：

- 短期明确支持矩阵：q35 兼容外观 + 局部 ID 去 QEMU 化。
- 中期只支持一条平台画像，避免 CPU/board/chipset 跨厂商随机。
- 长期再考虑 machine/chipset 层改造，而不是只覆盖单个 PCI ID。

### P2. 超 500 行文件仍需归档说明

| 文件 | 状态 |
| --- | --- |
| `deploy/scripts/apply-gpu-spoof.ps1` | 684 行，仍超过约束；`REFACTOR_2026-05-23.md` 已说明无 `pwsh` 和测试 VM 前暂不拆 |
| `deploy/docs/DE_VIRTUALIZATION_ASSESSMENT.md` | 537 行旧评估，内容过期，建议归档或拆分 |
| QEMU 上游大文件 | `hw/usb/dev-hid.c`、`ui/sdl2.c` 等超过 500 行；属于上游文件局部 patch，不建议强拆 |

## 安全解析复核

`stealth_profile_get()` 已用于两个上轮指出的高风险路径。临时恶意 profile 测试结果：

- 安全值能按 `%q` 反转义读取。
- `GPU_NAME=$(touch /tmp/qemu_profile_pwn2)` 被拒绝。
- payload 文件未创建，说明没有执行命令替换。

剩余建议：把这种恶意 profile 测试固化为脚本测试，覆盖所有 root/host 工具。

## 验证结果

已执行：

```bash
git diff --check
find deploy/scripts -maxdepth 2 \( -name '*.sh' -o -name 'start-vm.sh' -o -name 'stop-vm.sh' \) -print0 | xargs -0 -n1 bash -n
python3 -m py_compile deploy/scripts/lib/devpkey-prefixup.py deploy/scripts/lib/devpkey-patch.py deploy/scripts/qmp-proxy.py
ninja -C build qemu-system-x86_64 qemu-edid
deploy/scripts/verify-stealth.sh
DRY_RUN=1 TPM=1 BRIDGE= INSTANCE=9876 deploy/scripts/start-vm.sh --no-sdl --no-fb-shm
timeout 5 build/qemu-system-x86_64 -machine q35,accel=tcg -nodefaults -display none -S -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0
timeout 5 build/qemu-system-x86_64 -machine q35,accel=tcg -nodefaults -display none -S -device qemu-xhci,id=xhci -device usb-mouse,bus=xhci.0
timeout 5 build/qemu-system-x86_64 -machine q35,accel=tcg -nodefaults -display none -S -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0
```

结果：

| 检查 | 结果 |
| --- | --- |
| `git diff --check` | 通过 |
| Bash 语法检查 | 通过 |
| Python `py_compile` | 通过 |
| 构建 `qemu-system-x86_64 qemu-edid` | 通过 |
| `verify-stealth.sh` | 15 项通过，无原 TCG feature warning |
| DRY_RUN 新实例 | 未创建 VM_DIR/profile/disk/OVMF VARS，未留下 socket |
| USB HID smoke | kbd/mouse/tablet 均未断言崩溃；最终由 timeout 终止，符合 `-S` 预期 |
| `stop-vm.sh` 新名路径 | 最小 QEMU `win10-88` 通过 QMP hard quit 停止 |
| `stop-vm.sh` QMP-only 路径 | 最小 QEMU `custom-89` 无 PID 匹配时通过 QMP 停止 |
| `shellcheck` | 本机未安装，未执行 |
| `unwrap` | 本轮改动路径未新增；仓库上游 Rust 目录仍有既存 `unwrap` |

## 建议路线

| 优先级 | 建议 | 验收方式 |
| --- | --- | --- |
| P0 | 修复 NBD cleanup 只断开本脚本成功连接的设备 | 模拟 busy `/dev/nbdN` 时脚本失败但不调用 disconnect |
| P1 | DRY_RUN 跳过 legacy `mv` 和 socket `rm -f` | legacy 文件、dummy socket 在 dry-run 后保持不变 |
| P1 | 默认 NBD 改为自动选择空闲设备 | 外部占用 `/dev/nbd0` 时脚本自动选 `/dev/nbd1+` 或清晰 fail-fast |
| P1 | 固化 profile 注入测试 | CI/本地测试验证 `source/eval` 不会回归 |
| P2 | 收敛平台画像支持范围 | 明确 Intel/q35 或 AMD/AM4 其中一条，并做客机内 PCI/ACPI/SMBIOS 对照 |
| P2 | 处理超 500 行 PowerShell 和旧评估文档 | 有 `pwsh` 与测试 VM 后拆分；旧文档归档或拆成多篇 |

结论：本轮比上一轮更接近可验收，尤其 profile 读取和新实例 DRY_RUN 已有实际改善。当前最需要先修的是 NBD cleanup 失败路径，因为它会把“发现 busy 后不强断”的保护变成实际 disconnect 风险。

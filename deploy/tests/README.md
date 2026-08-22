# vGPU deployment tests

- `vgpu/` tests the NVIDIA mdev/vGPU lifecycle, storage, profiles, licensing,
  and host helpers.
- `qemu/` contains source-level checks for QEMU changes used by the vGPU path.

Run all deployment tests from the repository root:

```bash
./deploy/tests/run-g11.sh
```

The runner rebuilds the G-11 QEMU/streamer targets, executes every deployment
test, and then runs the compiled input/SDL/streamer unit tests plus the USB HID
qtest. For a focused
iteration use `--filter TEXT`; use `--no-build` only when the build directory
is already current.

最新 V-11 通用能力在 G-11 的聚焦回归：

```bash
bash deploy/tests/vgpu/test_canonical_entrypoints.sh
bash deploy/tests/vgpu/test_vmctl_storage.sh
bash deploy/tests/vgpu/test_display_control.sh
bash deploy/tests/vgpu/test_disk_headroom.sh
bash deploy/tests/vgpu/test_storage_aio.sh
bash deploy/tests/vgpu/test_cpu_isolation.sh
bash deploy/tests/vgpu/test_host_oom_protection.sh
bash deploy/tests/vgpu/test_host_nvme_apst.sh
bash deploy/tests/vgpu/test_host_performance.sh
bash deploy/tests/vgpu/test_tsc_policy.sh
```

前两项验证 `deploy/scripts/` 是唯一入口、旧 deploy-root 文件已删除、旧 G-11
基础镜像名称只做兼容转发，以及 `vmctl` 的路径分发；
这些测试使用只读查询、伪 QMP、伪 cgroup 和临时文件，不启动或修改真实
VM/宿主；AIO 测试还会用已构建 QEMU 读取其自身 4 KiB，既不创建临时盘，
也不接触 VM 磁盘。性能/TSC 两项另用伪 sysfs 验证动态全频段、回滚和 KVM
能力分支，不写真实 cpufreq、THP、KVM 或 NVMe 节点。

傻瓜封装入口的快速行为回归：

```bash
bash deploy/tests/vgpu/test_vgpu_one_click_package.sh
bash deploy/tests/qemu/test_sdl_no_sleep_static.sh
./deploy/tests/run-g11-sdl.sh --static-only
```

它使用隔离配置验证任意 VM ID、A/B 分发、off/动态/重复配置拒绝和配置竞态绑定，
不会启动或修改真实 VM。

无 VM 绑定 portable、GPU-Z 显式选装、基础镜像注入与克隆的聚焦回归：

```bash
bash deploy/tests/vgpu/test_vgpu_portable_package.sh
bash deploy/tests/vgpu/test_gpuz_profile_launcher_static.sh
bash deploy/tests/vgpu/test_gpuz_profile_package.sh
bash deploy/tests/vgpu/test_gpuz_registry_absence_static.sh
bash deploy/tests/vgpu/test_vgpu_base_installer_static.sh
bash deploy/tests/vgpu/test_vgpu_base_clone.sh
bash deploy/tests/vgpu/test_wegame_base_cleanup_static.sh
```

这些测试使用静态门禁或隔离 fixture，要求 portable PE 资源中不含 GPU-Z，默认
安装既不读取也不要求 sidecar；只有 `/with-gpuz` 才把同目录外置
`GPU-Z.exe` 按固定大小/哈希导入受保护快照，同时保证 legacy VM-bound 包仍保留
原有合同。它们还覆盖默认身份查询与 guest 性能优化、显式选装的错误 sidecar 拒绝、
`/verify-only`、全新 Windows 尚无 NvAPI 注册表键的首次运行、base schema-5
`guestPerformance` 及 `gpuZIncluded=false/true` 两种证明，以及全部 25 条 profile
的通用克隆绑定。
最后一项还验证 `seal-base.sh` 默认保留 V-11 的 WeGame/Tencent 跨克隆身份清理、
`--no-clean` 显式例外，以及 G-11 禁止强修 NTFS/改 BCD/改驱动的边界。存储 fixture
另行验证多个 `BASE_NAME` 并存、精确选择、逐镜像证明与同名归档。不会挂载、修改
真实基础镜像，也不会启动真实 VM。

通用系统 NVAPI/monitor 单-adapter 投影与 537.58 隔离门禁：

```bash
bash deploy/tests/vgpu/test_d3d12_capability_probe.sh
bash deploy/tests/vgpu/test_nvapi_identity_shim_static.sh
bash deploy/tests/vgpu/test_system_nvapi_projection_package.sh
bash deploy/tests/vgpu/test_signed_consumer_probe_gate.sh
bash deploy/tests/vgpu/test_signed_consumer_production.sh
```

原生 D3D12 测试会可重复构建 x86/x64 OPTIONS5 探针，检查它们不含
应用特例、不跨越 BCD/驱动边界，且原生查询审计位于首次持久写入之前；自动克隆
只在 adapter/OPTIONS5 无法查询时失败，签名 transport 的 DXR 差异会明确警告。
系统包测试会实际生成 1GB/2GB、GTX 750/750 Ti、GT 1030、GTX 1050 隔离
fixture，覆盖 ASUS/MSI/Gigabyte、Samsung/Micron/SK hynix 和三款 monitor，并
验证 schema-4 合同、EDID、x86/x64 NVAPI/D3D12 payload 与 ISO。它还要求默认产物只进入数字 VM 的
`packages/SystemNvapiProjection/`、成功后不留 `.build-vm*`，并拒绝会逃出 VM
bundle 的 `packages` 符号链接。signed-consumer 两项保证 537.58 仍可在明确可删除克隆中
审计复现，但所有生产默认和启动/打包入口失败关闭。测试不接触真实 VM 或 guest
磁盘。

USB 高速安装 helper 的源码、FAT 内容、哈希和可重复构建聚焦回归：

```bash
bash deploy/tests/vgpu/test_usb_install_boot_helper.sh
```

它只读取仓库资产；本机已有 MinGW/EDK2 头文件时还会连续构建两次并逐字节比较，
不会创建或启动 VM。

默认零光驱与只读 ISO 热插生命周期聚焦回归：

```bash
bash deploy/tests/vgpu/test_optical_media.sh
bash deploy/tests/vgpu/test_guest_performance_package.sh
```

它使用已构建 QEMU 在临时目录启动一台暂停的 TCG fixture，先确认
`absent`，再核对热插后 GH24NS50/XP02/空序列的 QOM 属性、只读介质、
幂等 mount、`--replace`、符号链接拒绝，最后验证 eject 删除整台设备与后端。
所有介质都在 `mktemp` 目录，不连接真实 VM。
guest performance 测试另行构建并解包无凭据 ISO，核对 CRLF launcher、SHA256、
回滚入口、旧 relay 精确归属规则，以及不改 BCD/签名/驱动和不触碰 NVIDIA 官方
服务的静态门禁。

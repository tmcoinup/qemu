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
```

前两项验证 `deploy/scripts/` 是唯一入口、旧同名文件已删除以及 `vmctl` 的路径分发；
这些测试使用只读查询、伪 QMP、伪 cgroup 和临时文件，不启动或修改真实
VM/宿主；AIO 测试还会用已构建 QEMU 读取其自身 4 KiB，既不创建临时盘，
也不接触 VM 磁盘。

傻瓜封装入口的快速行为回归：

```bash
bash deploy/tests/vgpu/test_vgpu_one_click_package.sh
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
```

这些测试使用静态门禁或隔离 fixture，要求 portable PE 资源中不含 GPU-Z，默认
安装既不读取也不要求 sidecar；只有 `/with-gpuz` 才把同目录外置
`GPU-Z.exe` 按固定大小/哈希导入受保护快照，同时保证 legacy VM-bound 包仍保留
原有合同。它们还覆盖默认身份查询、显式选装的错误 sidecar 拒绝、
`/verify-only`、全新 Windows 尚无 NvAPI 注册表键的首次运行、base schema-4
`gpuZIncluded=false/true` 两种证明，以及全部 12 条 profile 的通用克隆绑定。
不会挂载、修改真实基础镜像，也不会启动真实 VM。

通用系统 NVAPI/monitor 单-adapter 投影与 537.58 隔离门禁：

```bash
bash deploy/tests/vgpu/test_nvapi_identity_shim_static.sh
bash deploy/tests/vgpu/test_system_nvapi_projection_package.sh
bash deploy/tests/vgpu/test_signed_consumer_probe_gate.sh
bash deploy/tests/vgpu/test_signed_consumer_production.sh
```

系统包测试会实际生成 GTX 750 Ti、GT 1030、GTX 1050 三个隔离 fixture，覆盖
ASUS/MSI/Gigabyte、Samsung/Micron/SK hynix 和三款 monitor，并验证合同、EDID、
x86/x64 payload 与 ISO。signed-consumer 两项保证 537.58 仍可在明确可删除克隆中
审计复现，但所有生产默认和启动/打包入口失败关闭。测试不接触真实 VM 或 guest
磁盘。

USB 高速安装 helper 的源码、FAT 内容、哈希和可重复构建聚焦回归：

```bash
bash deploy/tests/vgpu/test_usb_install_boot_helper.sh
```

它只读取仓库资产；本机已有 MinGW/EDK2 头文件时还会连续构建两次并逐字节比较，
不会创建或启动 VM。

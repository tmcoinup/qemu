# vGPU deployment tests

- `vgpu/` tests the NVIDIA mdev/vGPU lifecycle, storage, profiles, licensing,
  and host helpers.
- `qemu/` contains source-level checks for QEMU changes used by the vGPU path.

Run all deployment tests from the repository root:

```bash
./deploy/tests/run-g11.sh
```

The runner rebuilds the G-11 QEMU/streamer targets, executes every deployment
test, and then runs the compiled `fb-shm-stream` unit tests.  For a focused
iteration use `--filter TEXT`; use `--no-build` only when the build directory
is already current.

傻瓜封装入口的快速行为回归：

```bash
bash deploy/tests/vgpu/test_vgpu_one_click_package.sh
```

它使用隔离配置验证任意 VM ID、A/B 分发、off/动态/重复配置拒绝和配置竞态绑定，
不会启动或修改真实 VM。

通用离线 EXE、基础镜像注入与克隆的聚焦回归：

```bash
bash deploy/tests/vgpu/test_vgpu_portable_package.sh
bash deploy/tests/vgpu/test_vgpu_base_installer_static.sh
bash deploy/tests/vgpu/test_vgpu_base_clone.sh
```

后两个测试使用静态门禁或隔离 fixture，不会挂载、修改真实基础镜像，也不会启动
真实 VM。

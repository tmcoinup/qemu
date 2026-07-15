# vGPU deployment tests

- `vgpu/` tests the NVIDIA mdev/vGPU lifecycle, storage, profiles, licensing,
  and host helpers.
- `qemu/` contains source-level checks for QEMU changes used by the vGPU path.

Run all deployment tests from the repository root:

```bash
find deploy/tests/vgpu deploy/tests/qemu -name 'test_*.sh' -print0 \
  | sort -z \
  | xargs -0 -n1 bash
```

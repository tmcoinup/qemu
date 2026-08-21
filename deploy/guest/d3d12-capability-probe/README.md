# G-11 原生 D3D12 能力探针

这个工具不读鲁大师、GPU-Z 或其他检测程序，不修改注册表、驱动、BCD
或任何应用文件。它通过 DXGI 枚举实际 NVIDIA adapter，创建 D3D12 device，
然后直接调用：

```text
ID3D12Device::CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS5)
```

`raytracing_tier=0` 表示不支持 DXR，`10` 表示 DXR 1.0，`11` 表示
DXR 1.1。当前 G-11 目录中六个旧卡 device ID 都要求 tier 0。

## 开发者构建

在仓库根目录执行：

```bash
./deploy/guest/d3d12-capability-probe/build.sh
./deploy/tests/vgpu/test_d3d12_capability_probe.sh
```

构建同时产生 `D3D12CapabilityProbe32.exe` 和
`D3D12CapabilityProbe64.exe`，关闭 PE 时间戳以保持可重复构建。两个文件都会被
`package-system-nvapi-projection.sh` 绑定到 schema-4 合同与 manifest 摘要。

## Windows 傻瓜复核

日常不需要单独执行探针；新版 SystemNvapiProjection ISO 的
`Run-As-Administrator.cmd` 会在任何写入前自动运行 x86/x64 两个版本，
`Verify-As-Administrator.cmd` 会在最终验收时再运行一次。自动克隆流程要求两条
原生路径都能枚举 NVIDIA adapter 并查询 OPTIONS5；签名 vGPU transport 若暴露
高于目标旧卡的 DXR 能力，会显示警告但不会阻断 NVAPI 投影。

只做严格 transport 一致性诊断时，把本目录三个 Windows 文件放在同一目录，双击
`Run-Native-D3D12-Probe.cmd`。它会带 `--require-tier-zero` 运行，并在桌面生成
`G11-D3D12-Native-Probe.txt`，不需要管理员权限。两段都必须包含：

```text
D3D12_NATIVE_VERIFY PASS ... native_raytracing_nonzero=no
EXIT_CODE=0
```

若任一段返回 `FAIL`、`raytracing_tier=10/11` 或非零 exit code，该 transport
不符合所选旧卡的原生 D3D12 能力；这不等于 x86/x64 NVAPI 投影或授权失败。
不要用 app-local/system `d3d12.dll` 替换、进程注入或测试签名驱动把结果伪装成
通过。

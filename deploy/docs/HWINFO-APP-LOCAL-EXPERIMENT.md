# HWiNFO64 app-local 实验适配

这个适配是独立实验项，不属于 `VgpuPortable.exe` 的验收范围，也不会被自动
安装到任意 HWiNFO 目录。它的目标很窄：把已经审计的 64 位 NVAPI 用户态
shim 放在用户明确指定的、官方签名的 `HWiNFO64.exe` 旁边。

它不会下载或捆绑 HWiNFO，不会替换 Windows 目录中的 NVAPI，不会修改 BCD，
也不会安装测试签名或自签名内核驱动。

## 使用前提

1. 先运行主 `VgpuPortable.exe`，确认选中的显卡 profile 已经成功写入完整的
   NVAPI identity contract。
2. 使用 HWiNFO 官方的 x64 可执行文件，文件名必须是 `HWiNFO64.exe`，PE
   架构必须是 x64，Authenticode 状态必须有效，发布者和版本信息必须属于
   REALiX。
3. 准备同一目录中的三个离线文件：

   - `install-hwinfo64-app-local.ps1`
   - `install-nvapi-shim.ps1`
   - `nvapi64.dll`

helper 对后两个仓库产物使用固定 SHA-256；文件内容变化会直接失败，不会退回
HTTP 或系统级安装。

## 安装

先完全退出 HWiNFO，然后在管理员 PowerShell 中执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\install-hwinfo64-app-local.ps1 `
  -ApplicationExe 'C:\Program Files\HWiNFO64\HWiNFO64.exe'
```

helper 只会在这个明确指定的 EXE 所在目录创建：

- `nvapi64.dll`：app-local 用户态 shim；
- `nvapi64_orig.dll`：从 Windows 系统目录复制并再次验证过的 NVIDIA/WHCP
  正版原始 NVAPI。

如果目标目录已经有不完整、来源不明或校验不通过的同名 DLL，操作会关闭失败，
不会覆盖。

卸载命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\install-hwinfo64-app-local.ps1 `
  -ApplicationExe 'C:\Program Files\HWiNFO64\HWiNFO64.exe' `
  -Uninstall
```

## 能覆盖与不能保证的部分

现有 x64 shim 拦截的 NVAPI 项包括产品名、NVAPI PCI 标识、VBIOS 字符串、
架构/实现、CUDA 核心、shader subpipe、ROP、TMU、显存类型/厂商/位宽、
基础/Boost/显存时钟、PCIe 类型/宽度以及 RT/Tensor 数量。如果 HWiNFO 通过
这些已验证 ABI 调用 app-local `nvapi64.dll`，对应显示有机会与所选 profile
一致。

但截图中的内容不能全部据此承诺：

| 截图内容 | app-local x64 shim 的边界 |
|---|---|
| `[FAKE]` | HWiNFO 自己的假卡/跨数据源一致性判断，不是一个可直接改写的 NVAPI 字段；不能保证消失。 |
| `GRID Quadro RTX6000-2Q` | 如果来源是 NVAPI FullName 可覆盖；如果来自 Windows PnP、驱动或 HWiNFO 自己的设备表则仍是原生信息。 |
| `Quadro RTX 8000/6000`、`TU104` | NVAPI PCI/架构查询在覆盖范围内；直接 PCI、ROM、内核驱动或其他私有接口不在范围内。 |
| GDDR6、256-bit、2944/46/368、64/184 | 多个 NVAPI 字段已有 hook，但 HWiNFO 的实际取值调用链尚未逐项抓取，不能把 GPU-Z 的验证直接外推。 |

HWiNFO 可能使用自己的内核驱动和直接硬件读取。用户态 app-local DLL 不会、也
不应改变原生 B 模式的 `DEV_1E30` PCI 配置空间、PnP 硬件 ID、真实 vGPU
端点、扩展 ROM、生产驱动文件或签名链。

因此，“helper 安装成功”只证明两个 DLL 被安全放到指定应用目录，不能证明
HWiNFO 实际加载了 shim。验收必须关闭并重新启动 HWiNFO 后看最终界面；若
仍显示 `[FAKE]` 或 `TU104`，应先抓取该版本 HWiNFO 的 DLL 加载路径和 NVAPI
QueryInterface 调用，再决定是否能增加经过 ABI 验证的 hook，不能做全局
NVAPI 替换或猜测私有接口。

HWiNFO 从 5.90 起加入了 NVIDIA 假卡检测，官方作者也确认过该检测存在误报并
通过后续版本修复；所以 `[FAKE]` 本身是 HWiNFO 的判断结果，不等于驱动签名
状态。参考：

- <https://www.hwinfo.com/forum/threads/hwinfo-v5-90-released.5298/>
- <https://www.hwinfo.com/forum/threads/i-think-hwinfo-detects-my-nvidia-graphics-card-falsely-as-fake.6969/>

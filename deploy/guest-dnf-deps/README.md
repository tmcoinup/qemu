# dnf-fix-deps 独立安装器

`dnf-fix-deps.exe` 是独立的 Windows PE64 程序，内嵌主流程、
Microsoft 安装包验证模块和 DirectX 完整包安装模块三个
PowerShell 文件。它不依赖、也不会调用 `respawn-stealth.exe`。

运行时会按需安装 VC++，并复验 DirectX legacy 组件：

- Visual C++ 2010 SP1（x86、x64）
- Visual C++ 2013（x86、x64）
- Visual C++ 2015-2022（x86、x64）
- DirectX End-User Runtimes (June 2010 legacy 组件)

## 构建与发布

```bash
deploy/guest-dnf-deps/build-exe.sh
deploy/guest-dnf-deps/package.sh
```

正式发布物固定为：

```text
deploy/guest-dnf-deps/dist/dnf-fix-deps.exe
```

`package.sh` 会清理发布目录，并保证其中只有这一个 EXE。
已有 host 一键入口也会先打包当前源码，再上传并运行这个 EXE：

```bash
deploy/scripts/dnf-fix-deps.sh 8 --dry-run
```

## Windows 使用

双击 EXE 后确认即可。命令行支持：

```text
dnf-fix-deps.exe --dry-run
dnf-fix-deps.exe --no-confirm
dnf-fix-deps.exe --dry-run --no-confirm
```

`--dry-run` 只检测，不下载或安装；`--no-confirm` 仅用于明确需要无人值守
运行的场景。其它参数会被拒绝，不能覆盖缓存、日志或脚本路径。
内嵌 PowerShell 主脚本还会核对启动器标记和三条固定路径，不能作为独立脚本
从其它目录运行。

运行目录固定在 `%ProgramData%\VMateDnfDeps`：

- `payload\dnf-fix-deps.ps1`：从 EXE 原子释放的内嵌脚本
- `payload\dnf-fix-installers.ps1`：下载、签名/身份校验与 VC++ 执行逻辑
- `payload\dnf-fix-directx.ps1`：DirectX 完整包解包、执行与日志采集
- `cache\`：已验签的 Microsoft 安装器缓存
- `install.log`：检测和安装日志

启动器请求管理员权限，固定调用 System32 PowerShell，并为 ProgramData 运行
目录设置受保护的 Owner/DACL。下载先写入唯一临时文件，只有 Authenticode
签名有效、签发给 `Microsoft Corporation` 且 PE 原始文件名或固定哈希
符合对应产品时，
才会发布到缓存；安装前会再次验证。已安装项还会逐个检查 DLL 的 PE 架构和
最低文件版本，避免把错架构或过旧文件误判为可用。
VC++ 2015-2022 的 x86 清单按官方 x86 包检查 `vcruntime140.dll`、
`msvcp140.dll`、`concrt140.dll`；仅 x64 清单检查架构专属的
`vcruntime140_1.dll`，避免把 x86 正常安装永久误判为缺失。

## 联网边界与退出码

这是“单 EXE 启动器”，不是离线运行库合集。PowerShell 脚本包含在 EXE 内，
VC++ 与 DirectX 安装器仍在运行时从 Microsoft 官方地址下载。DirectX 不再使用
0.3 MB 的旧 `dxwebsetup.exe`，而是下载约 95.6 MB 的 June 2010 完整包，固定
SHA-256 并验签后隔离解包，再执行 `DXSETUP.exe /silent`。完整包命中缓存后
不需要 DirectSetup 再次联网下载 CAB。DirectSetup 每次都会运行，由它自行判断
是否需要更新，这样也能修复“文件存在但已损坏”的情况。

- `0`：检测或安装成功
- `1`：至少一项下载、安装或复检失败
- `2`：缺少管理员权限
- `87`：命令行参数无效
- `1223`：用户取消 UAC 或确认框
- `1618`：另一个实例正在运行
- `3010`：安装成功，但 Windows 需要重启

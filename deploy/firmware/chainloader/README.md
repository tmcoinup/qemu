# G-11 USB 安装介质引导器

`ChainLauncher.c` 是一个无交互 x86_64 UEFI 应用。它只做三件事：

1. 枚举固件已经识别的文件系统；
2. 跳过带有 `HELPER.MARK` 的自身小盘；
3. 从另一张介质执行 `\\EFI\\BOOT\\BOOTX64.EFI`。

G-11 用它解决 OVMF 对 USB 光盘只能读取、首次却不会自动建立启动项的问题。Windows ISO
的数据始终通过 xHCI USB Mass Storage 读取；helper 不包含 Windows 文件，也不会安装到客户机。

运行时使用仓库内由源码生成的 `../g11-usb-install-boot.img`。重新生成：

```bash
./deploy/host/build-usb-install-boot-helper.sh
```

构建器需要 `x86_64-w64-mingw32-gcc`、`mkfs.vfat` 和 mtools；UEFI 类型头文件默认取自
`deploy/host/ovmf-build/edk2-2024.02`，也可通过 `EDK2_DIR=/path/to/edk2` 指定。

校验仓库随附产物：

```bash
./deploy/host/verify-usb-install-boot-helper.sh
# 或只核对顶层镜像哈希：
(cd deploy/firmware/chainloader && sha256sum -c SHA256SUMS)
```

源码来源与历史 V-11 工件的隔离说明见 `PROVENANCE.md`。异常宿主可显式使用
`--install-media ide`，该回退路径完全不挂载 helper。

该 helper 只允许由 `start-vm.sh --install` 临时挂载。正常启动不得暴露它、Windows ISO
或应答 ISO。

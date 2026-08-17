# ChainLauncher provenance

G-11 的 `ChainLauncher.c` 是 2026-08-04 为 USB 安装高速路径编写的独立实现，
不是从 V-11 二进制反编译或恢复的源码。它使用 Debian edk2 2024.02 的公开 UEFI
类型头文件和 MinGW-w64 GCC 13 构建；完整命令固定在
`deploy/host/build-usb-install-boot-helper.sh`。

当前受审核产物：

- `g11-usb-install-boot.img`：16 MiB FAT16，SHA-256
  `6c5201c7429874b83462f2694f7545dc4e625c8f7271df3a434d103c3525a96c`；
- 镜像内 `EFI/BOOT/BOOTX64.EFI`：6,836 字节，SHA-256
  `846e7c7534a420fc72cfde4b3e3bd9bffd8980e1e34faaa5d0ee659c5d0017b8`；
- FAT 中其余内容只有目录和零字节 `HELPER.MARK`。

构建器固定 PE/FAT 时间、PE image base 和 FAT volume ID；同一源码连续构建必须
逐字节一致。`verify-usb-install-boot-helper.sh` 校验镜像大小、完整哈希、文件清单、
内嵌 EFI 哈希和 PE subsystem。

V-11 历史 helper 仅作为行为参考，没有被复制到 G-11：历史 FAT 镜像 SHA-256 为
`5822bff764f892f37eaf370dcf4da4e6d450083a9cbfceb99debf436d7c92494`，
其中无签名 1,984 字节 EFI 的 SHA-256 为
`73e770f0a384ce467553f32ee2fd5d4fa7f9e00c2116f971f1d8c9fb2b4f5ebf`。
Git 历史没有它的 C/INF 源码、编译记录或可验证许可证，因此 G-11 不使用该工件。

安全边界：新 helper 只读、只在 `--install` 默认 USB 路径临时挂载，只会从同时
含有 `\\EFI\\BOOT\\BOOTX64.EFI` 和 `\\sources\\boot.wim` 的另一介质启动。
它不写客户机磁盘、不修改 BCD、不安装驱动，也不改变 Windows 签名策略。正式启动
不挂载 helper、Windows ISO 或应答 ISO。

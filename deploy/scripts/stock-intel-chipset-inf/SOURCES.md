# Intel 芯片组识别 INF 来源

本目录只保存两个已启用 Intel 平台所需的原始 INF/CAT。它们是 Microsoft
WHCP 签名的 Intel `NO_DRV`（null-driver）设备识别包：用于清除设备管理器
Code 28 并显示正确名称，不包含 `.sys`，也不会把 QEMU ICH9 SMBus 变成真实
Sunrise Point/Cannon Lake 控制器。

文件必须保持上游原字节。`build-exe.sh` 与来宾安装器会分别校验 SHA-256；
不要改换行、大小写或重新生成 CAT。

## H310 / `PCI\VEN_8086&DEV_A323`

- Microsoft Update Catalog Update ID:
  `886c410e-42e7-4204-871c-14e56c410e51`
- 目录详情:
  <https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=886c410e-42e7-4204-871c-14e56c410e51>
- 原始 CAB:
  <https://catalog.s.download.windowsupdate.com/d/msdownload/update/driver/drvs/2018/07/2b982cde-27b5-4677-889a-63832c6062a9_3e956da490f3e8541d1bb0ef10373e877c21bb03.cab>
- CAB SHA-256:
  `9500a6fa0eb825722b317a39e0b918dae06cd6dd9762ab80242d9f329dc97aee`
- `CannonLake-HSystem.inf`:
  `0793ffcb29ba4dd13e62ec1c406884193cbf893d95e0b49840da609d8447a123`
- `cannonlake-h.cat`:
  `9e457455e44a4215610c1160c6b3cbe345a4ee8e2af621e51ef6d1079870dba2`
- INF 版本: `10.1.16.5`

## H110 / `PCI\VEN_8086&DEV_A123`

- Microsoft Update Catalog Update ID:
  `582e46d7-e3ec-43bb-b5fb-008998789730`
- 目录详情:
  <https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=582e46d7-e3ec-43bb-b5fb-008998789730>
- 原始 CAB:
  <https://catalog.s.download.windowsupdate.com/d/msdownload/update/driver/drvs/2020/08/9972fce6-371c-4c3b-9d4c-07b35e1e339a_5c9187451b6c2ff2a499957a8be234c8c115e64e.cab>
- CAB SHA-256:
  `58c20c583469de0edb5ece58cbae5d5e263b2db01862d8b3692fbc41c7117419`
- `SunrisePoint-HSystem.inf`:
  `4d931028bc5d6f1d28ec05f80e1b365d42a3d0ff00b0aeebe582c07dc83a1f70`
- `sunrisepoint-h.cat`:
  `d22cdfa1018a00aa0b61172017f7bfb8f58382bfa80545e56b2b7a16c0242b9b`
- INF 版本: `10.1.1.44`

Microsoft 签名只证明包的完整性与 Windows 信任状态，不自动授予第三方再分发
权利。对外发布内嵌这些文件的 EXE 前，应由发布方确认 Intel、OEM 与 Microsoft
Update Catalog 的适用许可条款。

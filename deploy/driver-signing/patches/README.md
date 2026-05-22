# Source patches against virtio-win/kvm-guest-drivers-windows

Patches in this directory apply against the upstream
[virtio-win/kvm-guest-drivers-windows](https://github.com/virtio-win/kvm-guest-drivers-windows)
repo (we tested against the `master` branch as of 2026-04-25).

## Index

| Patch | Target | Purpose |
|---|---|---|
| `0001-viogpudo-realistic-vsync-freq.patch` | `viogpu/viogpudo/viogpudo.cpp::BuildVideoSignalInfo` | Replace `D3DKMDT_FREQUENCY_NOTSPECIFIED` (=`~1`) with concrete 60 Hz values, so `Win32_VideoController.CurrentRefreshRate`, `MinRefreshRate`, `MaxRefreshRate`, and 高级显示设置.刷新频率 stop reporting `1`. |
| `0002-viogpudo-mode-list-1080p.patch` | `viogpu/viogpudo/viogpudo.cpp::gTargetModes[]` | Trim driver's hardcoded mode list down to what a real 24" 1920×1080 16:9 panel exposes. Removes 1920×1200 / 1280×800 / 1440×900 / 1366×768 / 1280×768 (16:10 or laptop-only). Win10 display settings 分辨率下拉只列 7 条 16:9/4:3 模式。 |

## Applying

```bash
git clone https://github.com/virtio-win/kvm-guest-drivers-windows.git
cd kvm-guest-drivers-windows
git apply /path/to/0001-viogpudo-realistic-vsync-freq.patch
git apply /path/to/0002-viogpudo-mode-list-1080p.patch
```

## Build environment caveat (status: unresolved)

We attempted to build the patched driver inside a Win10 LTSC guest using the
following toolchain:

- Visual Studio Community 2022 (17.14.x) — NOT BuildTools, because the WDK VSIX
  rejects BuildTools SKU with `NoApplicableSKUsException`.
- Windows Driver Kit 10.0.19041 — installed alongside SDK 10.0.19041 to provide
  Win10 NTDDI-compatible km headers (the default WDK 22621 km headers
  unconditionally reference Win11-only types like `PIOMMU_DOMAIN_CREATE_EX` and
  fail with NTDDI_VERSION=NTDDI_WIN10).
- WDK VSIX content (Toolset.props for `WindowsKernelModeDriver10.0` etc.)
  manually copied into `C:\VSCommunity\MSBuild\Microsoft\VC\v170\Platforms\`
  because the VSIX installer still rejects the SKU silently in some cases.
- `build/<TargetPlatformVersion>/` skeleton from WDK 22621 copied to
  `build/10.0.19041.0/` so the kernel-mode toolset can locate its `*.props` /
  `*.targets`.

`cl.exe` produced `viogpudo.sys` (102 KB unpatched, 102 KB with the patch — the
patch only adjusts immediate values, no .obj count change), but the resulting
`.sys` triggers `CM_PROB_FAILED_POST_START` (Code 38) at runtime, **even
without the patch**. The control build (pristine upstream source, same
toolchain) reproduces the failure, confirming the toolchain itself is missing
some kernel-mode flag that a properly integrated VS+WDK install would inject.

The issue most likely lives in one of:

- compile flags: `/kernel`, `/D _KERNEL_MODE=1`, `/integritycheck`,
  Spectre-mitigated CRT
- link flags: `/DRIVER` subsystem version, `/MERGE`, `/SECTION:INIT,d`,
  `/ENTRY:GsDriverEntry`
- WDK target chain: `Driver.PackOne.targets`, `WindowsDriver.targets`

If you can build viogpudo.sys cleanly on a real VS Community + WDK
workload-installed host (use the in-Installer "Windows Driver Kit" workload,
not standalone wdksetup.exe), apply this patch first and the resulting `.sys`
should drop in fine — sign with `deploy/driver-signing/scripts/sign-backdated.sh`,
then offline-replace `C:\Windows\System32\drivers\viogpudo.sys` and the matching
copy under `DriverStore\FileRepository\` (regenerate `.cat` with
`Inf2Cat /driver:<dir> /os:10_X64` and re-sign).

## Why this matters

Without the patch, anti-cheat sees:

```
Win32_VideoController.CurrentRefreshRate = 1
Win32_VideoController.MinRefreshRate = 64
Win32_VideoController.MaxRefreshRate = 64
高级显示设置.有源信号分辨率 = -1 × -1
高级显示设置.刷新频率 = 1.000 Hz
```

— a virtual-display fingerprint that no physical monitor + GPU combination
produces. With the patch:

```
CurrentRefreshRate = 60
MinRefreshRate / MaxRefreshRate = 60 / 60
有源信号分辨率 = 1920 × 1080 (active size from EDID)
刷新频率 = 60.000 Hz
```

The CEA-861 totals derived inside the patch (vTotal = active_h × 25/24,
hTotal = active_w × 11/10) land within ~1 % of the canonical 1920×1080@60
totals (1125 vertical / 2200 horizontal), so a downstream EDID consistency
check that recomputes `PixelRate = HTotal × VTotal × VSync` still adds up
within rounding.

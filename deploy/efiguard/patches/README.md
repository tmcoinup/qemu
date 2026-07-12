# EfiGuard custom-build patches

Two changes vs upstream `Mattiwatti/EfiGuard@master` HEAD:

1. **`Application/Loader/Loader.c`** — add hardcoded fallback to load
   `\EFI\Microsoft\Boot\bootmgfw.efi.original` directly via file path when no
   other usable Boot#### entry exists. This is needed when Loader.efi has
   replaced `\EFI\Microsoft\Boot\bootmgfw.efi` AND the firmware's only
   Boot#### entry points at that same path: the existing logic skips the
   current boot option as "self" and finds nothing else. Without the
   fallback, boot ends with "Failed to boot anything".

2. **`EfiGuardDxe/EfiGuardDxe.c`** — change `gDriverConfig` defaults from
   `DSE_DISABLE_SETVARIABLE_HOOK / WaitForKeyPress=FALSE` to
   `DSE_DISABLE_AT_BOOT / WaitForKeyPress=FALSE`. We need full DSE patch at
   boot so unsigned drivers (our backdated viogpudo.sys) load with
   `bcdedit /set testsigning No`. Default SetVariable-hook mode would
   require running `EfiDSEFix.exe -d` from userland post-boot, which is
   too late for a boot-start display driver.

## Rebuild

Verified working with EDK2 head at commit `fbe0805b` (Apr 2024-ish) +
GCC5 toolchain on Ubuntu 24.04.

```bash
git clone --recursive https://github.com/Mattiwatti/EfiGuard.git /tmp/EfiGuard
cd /tmp/EfiGuard
git apply /path/to/0001-default-config-and-loader-fallback.patch

# Symlink so DSC's EfiGuardPkg/ prefix resolves
ln -sf /tmp/EfiGuard /tmp/EfiGuardPkg

cd /home/ubuntu/src/edk2     # any recent EDK2 checkout
export PACKAGES_PATH=/tmp:$WORKSPACE
source edksetup.sh BaseTools
build -t GCC5 -a X64 -b RELEASE -p EfiGuardPkg/EfiGuardPkg.dsc

# Output:
# Build/EfiGuard/RELEASE_GCC5/X64/Loader.efi
# Build/EfiGuard/RELEASE_GCC5/X64/EfiGuardDxe.efi
```

The pre-built artifacts ship in `deploy/efiguard/custom-build/`.

## Why we need DSE_DISABLE_AT_BOOT

Tested on Win10 22H2 (build 19041.6456) and LTSC 2021 (build 19041.1288):
- `DSE_DISABLE_SETVARIABLE_HOOK` (default upstream): drivers signed by
  certs not chained to a Microsoft root will not load at boot.
  `EfiDSEFix.exe -d` works post-boot but viogpudo has already failed.
- `DSE_DISABLE_AT_BOOT`: patches `CipImageProtectFromUserImage` and
  `SepInitializeCodeIntegrity` directly. Driver loads at boot.
  Side effect: ci.dll's `.text` section is modified, which a determined
  anti-cheat could detect via integrity scan. Trade-off accepted for now.

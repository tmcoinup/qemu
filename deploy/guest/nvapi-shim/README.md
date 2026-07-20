# NVAPI identity shim

This forwarding DLL keeps NVAPI's static GPU identity consistent with the
per-VM profile while leaving unrecognized calls with NVIDIA's original DLL.
The x64 shim loads `nvapi64_orig.dll`; the x86 shim loads `nvapi_orig.dll`.
Neither image supplies a PCI expansion ROM or changes the physical vGPU.

## Registry contract

Values are read once from the 64-bit registry view at:

`HKLM\SOFTWARE\NVIDIA Corporation\Global\NvAPI`

| Value | Type | NVAPI result |
|---|---|---|
| `IdentityContractVersion` | `REG_DWORD` | Completion marker; must be exactly `1` |
| `IdentityProfileKey` | `REG_SZ` | Audited catalog key bound to the PCI tuple |
| `IdentityGpuName` | `REG_SZ` | Full product name |
| `IdentityVbiosVersion` | `REG_SZ` | VBIOS version string |
| `IdentityVramMB` | `REG_DWORD` | Complete-contract VRAM gate (`2048`) |
| `IdentityPciVendorId` | `REG_DWORD` | App-local PCI vendor component |
| `IdentityPciDeviceId` | `REG_DWORD` | App-local PCI device and external-device component |
| `IdentityPciSubVendorId` | `REG_DWORD` | App-local subsystem-vendor component |
| `IdentityPciSubDeviceId` | `REG_DWORD` | App-local subsystem-device component |
| `IdentityPciRevisionId` | `REG_DWORD` | App-local PCI revision component |
| `IdentityCoreClockKHz` | `REG_DWORD` | Current/base graphics clock |
| `IdentityBoostClockKHz` | `REG_DWORD` | Boost graphics clock |
| `IdentityMemoryClockNVAPIKHz` | `REG_DWORD` | Preferred raw NVAPI memory clock |
| `IdentityMemoryClockKHz` | `REG_DWORD` | Legacy name for the same raw NVAPI clock |
| `IdentityMemoryBusBits` | `REG_DWORD` | RAM/FB bus width |
| `IdentityMemoryBandwidthMBps` | `REG_DWORD` | Clock/bus coherence check |
| `IdentityMemoryType` | `REG_DWORD` | NVIDIA RAM type enum (`8` is GDDR5) |
| `IdentityMemoryMaker` | `REG_DWORD` | NVIDIA RAM maker enum (`1` is Samsung) |
| `IdentityCudaCores` | `REG_DWORD` | CUDA/shader core count |
| `IdentityShaderSubPipes` | `REG_DWORD` | SM/subpipe count |
| `IdentityRopCount` | `REG_DWORD` | ROP count |
| `IdentityTmuCount` | `REG_DWORD` | GPU-Z 2.70 TMU/partition count |
| `IdentityArchitecture` | `REG_DWORD` | NVIDIA architecture ID |
| `IdentityImplementation` | `REG_DWORD` | NVIDIA implementation/chip ID |
| `IdentityChipRevision` | `REG_DWORD` | NVIDIA chip revision |
| `IdentityPcieWidth` | `REG_DWORD` | Current downstream PCIe lane width |
| `IdentityRayTracingCores` | `REG_DWORD` | RT core count; defaults to zero |
| `IdentityTensorCores` | `REG_DWORD` | Tensor core count; defaults to zero |
| `IdentityTraceQueryInterface` | `REG_DWORD` | Set to `1` for QI tracing |

`IdentityContractVersion` is deliberately a commit marker, not a default.
The registry writer deletes it before changing any identity value, verifies
every string/DWORD and writes version `1` last. The shim re-reads the marker
and profile key around its snapshot and enables overrides only when every
required value is present with the correct registry type, the profile key
matches its consumer PCI tuple, and the clocks, bandwidth, memory type, TMU
count, PCIe width, VBIOS and pre-RT/Tensor fields are coherent. Missing,
legacy, partial or malformed state makes every hook return the original
NVIDIA result unchanged. There is no model fallback.

The deployed and guest-verified GDDR5 contract returns twice the frequency
rendered by GPU-Z-like consumers: a profile value of 1752 MHz is stored and
returned as 3504000 raw NVAPI kHz. The NVIDIA SDK exposes no verified API that
directly returns theoretical RAM bandwidth, so GPU-Z derives it from memory
clock, RAM type, and bus width. Relative to that raw GDDR5 clock, the transfer
factor is two: `3504000 * 2 * 128 / 8000 = 112128 MB/s`. The configured
bandwidth supplies a missing clock and repairs a value that differs by more
than one percent; catalog rounding such as 112000 versus 112128 MB/s retains
the advertised 1752 MHz rendered clock. The current catalog contains only the
three audited GDDR5 profiles (GTX 750 Ti, GT 1030, GTX 1050). Profile staging
and the registry writer reject other RAM-type enums until their raw-clock
representation has its own verified implementation; the math helper returns
zero for an unsupported enum.

## Hook safety and ABI evidence

All hooks call the real DLL first. They replace output only after `NVAPI_OK`, or
after `NVAPI_NOT_SUPPORTED` when the real DLL has already validated a simple
static-attribute request. Other errors and unknown QueryInterface IDs are
returned unchanged.

Function IDs and layouts for clocks, core/subpipe counts, RAM bus width,
architecture, bus type, PCIe width, VBIOS string, and GPU info come from
NVIDIA's public NVAPI headers. The private RAM type/maker, FB width/location,
ROP count, and partition/TMU count signatures were checked against both local
538.33 driver dispatch tables and their x86/x64 wrapper code. For the private
partition ID (`0x86F05D7A`), GPU-Z 2.70's x86 call path was also verified to
pass one `NvU32 *`, consume that DWORD as the TMU count, and use it for Texture
Fillrate. This hook is therefore version-locked to 538.33 + GPU-Z 2.70 and must
be revalidated before either version changes. GPU-Z 2.70 additionally queries private
`GetPerfClocks` (`0x1EA54A3B`) and public `GetPstates20` (`0x6FF81213`).
The private handler was verified end-to-end in the local 538.33 x86 DLL and is
registered only in the x86 shim, used only by `GPU-Z.exe` (plus the x86 test
probe), only with its exact V1 `0x2a74` layout, and only for the one published
level (`-1`/`0` selectors). The x64 shim always forwards this private ID.
P-States 2.0 accepts only NVIDIA's documented V1/V2/V3 structures. Historical
guessed clock, bandwidth, and bus-width IDs are intentionally not intercepted.
The public `NvAPI_GPU_GetPCIIdentifiers` hook returns the catalog's consumer
vendor/device/subsystem/revision tuple to this app-local process. It does not
change PCI configuration space, the Windows PnP hardware ID, driver binding,
catalog, kernel image, or signer. In B mode those system-level facts remain the
native `DEV_1E30` production-driver facts.

The accepted standard TechPowerUp GPU-Z 2.70.0 executable is pinned to SHA-256
`6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29`
and the exact basename `GPU-Z.exe`. A static audit of that exact executable,
after unpacking its UPX image, found seven little-endian references to
`0x2DDFB66E`; disassembly of its NVAPI setup path shows the ID being passed
directly to `nvapi_QueryInterface`. This proves that the locked GPU-Z build
queries the public PCI-identifiers entry point intercepted above. A live
post-migration UI check is still required to prove the complete rendered
result on each guest.

Set `IdentityTraceQueryInterface=1` and capture `OutputDebugString` output with
a debugger or DebugView to record calls as `nvapi-shim: QI 0xXXXXXXXX`. This is
the supported way to investigate a future GPU-Z release before adding another
private hook.

## Build and test

Run `./build.sh` to reproducibly rebuild both checked-in DLLs, import
libraries, and the test-only `nvapi_profile_probe32.exe` and
`nvapi_profile_probe64.exe`. The repository contract test also compiles and
runs `test_profile_math.c` on the host:

```sh
deploy/tests/vgpu/test_nvapi_identity_shim_static.sh
```

For GPU-Z 2.70.0, use the x86 probe: place
`nvapi_profile_probe32.exe` beside the app-local `nvapi.dll` shim and its
required `nvapi_orig.dll` sibling. Use `nvapi_profile_probe64.exe` beside
`nvapi64.dll` and `nvapi64_orig.dll` to validate a 64-bit client. Each probe
derives its own executable directory and loads that directory's matching NVAPI
DLL by absolute path. It prints the name, VBIOS, core/subpipe/ROP/TMU counts,
memory type/width, modern and compatibility-interface raw clocks, rendered
clocks, derived bandwidth, architecture, PCIe identity, and RT/Tensor counts.
The build and setup flow does not install either probe.

## Known limits

- VBIOS interception changes the NVAPI string only. It does not create a ROM
  BAR, so software that parses the PCI expansion ROM can still show an unknown
  BIOS.
- Driver signature/WHQL status is not an NVAPI identity field and is never
  overridden. GPU-Z continues to derive it from the installed driver package;
  this shim cannot turn a self-signed or beta package into a production-signed
  one.
- PCIe generation and link state also depend on the QEMU PCIe topology and
  config-space capabilities; the shim can only correct NVAPI bus type/width.
  In particular, a root port does not add a missing PCI Express capability to
  a conventional-PCI endpoint, and synthesizing one changes the guest hardware
  ABI.
- The locked GPU-Z 2.70 NVAPI TMU/Texture Fillrate path is covered. Its
  Ray Tracing/DirectML capability boxes may instead use DXGI/D3D12 feature
  checks; those runtime paths remain native and are outside this DLL's ABI.
- A changed registry profile is visible only in processes started after the
  shim is reloaded because identity values are intentionally read once.

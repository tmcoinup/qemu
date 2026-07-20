# G-11 compatibility and capability matrix

This matrix describes the **G-11 product lifecycle**, not every host and guest
combination supported by upstream QEMU.  A source file compiling on another
platform is not, by itself, a supported G-11 deployment.

Status meanings:

- **Supported**: exercised by the G-11 launcher, shutdown path, and deployment
  tests.
- **Experimental**: implementation exists, but the complete hardware/runtime
  combination is not part of the production acceptance baseline.
- **Unsupported**: no G-11 lifecycle, or a required kernel/driver interface is
  unavailable.

## Host and guest operating systems

| Host | Guest | G-11 status | Boundary |
|---|---|---|---|
| Linux (Ubuntu-like) | Windows 10 | **Supported** | Primary NVIDIA mdev/VFIO/KVM lifecycle. |
| Linux (Ubuntu-like) | Windows 11 | **Experimental** | Only B/name-only with an unmodified NVIDIA/Microsoft production-signed driver is accepted; do not disable Secure Boot or HVCI/Memory Integrity, and do not use the disabled test/self-signed strict path. |
| Other Linux distributions | Windows | **Experimental** | QEMU/KVM may work, but the supplied host bootstrap and package checks use `apt`, `dpkg`, systemd, Linux bridge, and the local NVIDIA vGPU layout. |
| Linux | Linux | **Experimental** | Upstream QEMU supports Linux guests; G-11 does not ship a Linux guest profile, vGPU driver bootstrap, or product regression suite. |
| Windows | Windows or Linux | **Unsupported** | WHPX/TCG and the cross-compilable generic `fb-shm` Windows source are upstream/code capabilities.  They do not replace Linux KVM, VFIO/mdev sysfs, `memory-backend-memfd`, or the G-11 NVIDIA vGPU lifecycle. |
| macOS/FreeBSD | Any | **Unsupported** | No G-11 launcher, NVIDIA mdev/VFIO lifecycle, packaging, or runtime tests. |

## NVIDIA host/guest baseline

| Component | Accepted baseline | Other versions |
|---|---|---|
| Host vGPU manager | `535.161.05` | **Experimental**; revalidate mdev type discovery, console REGION cadence, licensing, and guest compatibility. |
| Windows guest driver | Unmodified, NVIDIA/Microsoft production-signed GRID `538.33` | **Experimental**; revalidate branch/profile, PnP matching, and production signature chain. |
| Display interface | VFIO display REGION, `display=on,ramfb=on` | DMA-BUF scanout is not exposed by the accepted R535 stack. |
| Guest identity | B/name-only for all three currently audited profiles | The legacy GTX 1050 strict-A self-signed transition is disabled; no strict consumer-ID package is currently accepted. |
| Maximum advertised mode | 1920x1080 at 60 Hz | 2K/4K, HDR, and multi-head are not accepted. |

## Runtime capability levels

| Capability | G-11 product status | Notes |
|---|---|---|
| Native local display | **Supported** | NVIDIA REGION to QEMU SDL/GTK. |
| Host CPU isolation | **Experimental; implemented; required by default** | Launcher/QMP and mock-cgroup rollback tests pass. Missing Ubuntu packages/helper/sudoers are installed automatically before launch; target-host cgroup v2 partition behavior still requires acceptance. `--cpu-isolate-auto` is an explicit opt-down. |
| Fixed ROI capture | **Experimental; implemented** | The TCG-to-SHM-to-libx264 end-to-end test passes, including a runtime ROI change.  A real R535 vGPU dynamic-frame soak remains outstanding. |
| Network video output | **Experimental; implemented** | Explicit destinations, lifecycle and validation are tested; a production ingest/TLS/authentication soak is not yet recorded.  The launcher never creates a listener. |
| Dirty-region local display updates | **Supported** | REGION row comparison reduces local GL uploads and presents. |
| Dirty-region video encoding | **Unsupported** | The shared-memory path publishes a complete ROI frame. |
| Generic QEMU GPU handle export | **Experimental; outside the R535 G-11 path** | The producer protocol can publish DMA-BUF when its Linux display path supplies one.  Windows named-D3D11 transport is cross-compile checked only and currently lacks the keyed-mutex/fence synchronization required for safe asynchronous consumption. |
| Native GPU-handle encoding | **Unsupported** | No native DMA-BUF/D3D11 import-and-encode backend is implemented.  The current consumer reports `gpu.zero-copy=no` and `GPU_E_BACKEND_NOT_BUILT`, regardless of which optional library headers Meson discovers. |
| R535 vGPU end-to-end zero-copy | **Unsupported** | The accepted NVIDIA mdev console exposes a system-memory REGION, not DMA-BUF. |
| SHM/rawvideo to libx264 | **Exercised** | Automated TCG → dynamic ROI → SHM → ffmpeg → H.264 file test passes. |
| SHM/rawvideo to NVENC or QSV | **Experimental; not zero-copy** | The architecture performs a later GPU upload.  The launcher checks encoder enumeration and a one-frame runtime encode before starting QEMU, but a production session soak is still required; this host's advertised NVENC currently cannot load `libcuda.so.1`. |
| Live migration | **Unsupported** | G-11 launches NVIDIA mdev with `enable-migration=off`. |
| Audio in the `fb-shm` stream | **Unsupported** | The current sidecar transports video only. |
| Remote input/session control | **Unsupported in the network streamer** | Native SDL/GTK input and the legacy local ivshmem viewer remain separate paths. |
| Multi-region/edge orchestration | **Unsupported** | No CDN routing, ABR controller, origin/edge failover, or session scheduler is included. |

## Zero-copy terminology

G-11 uses three separate checks:

1. **GPU export**: QEMU publishes a DMA-BUF or synchronized D3D11 shared
   texture.
2. **Encoder import**: the consumer imports that handle directly into a
   hardware encoder without reading the pixels through CPU memory.
3. **End-to-end zero-copy**: the original guest/vGPU scanout reaches the
   encoder without a system-memory capture or GPU upload anywhere in the
   path.

Passing level 1 does not imply level 2 or 3.  The generic producer protocol can
represent level 1 on a suitable DMA-BUF display path, but the current consumer
does not implement level 2.  The G-11 R535 path does not start at level 1:
it captures a system-memory VFIO display REGION, publishes complete BGR0
frames through SHM, copies them into ffmpeg's `rawvideo` stdin, and may then
upload them for NVENC/QSV.  Selecting a hardware encoder therefore does not
make the G-11 stream zero-copy.

## Current streamer capability contract

For the current `qemu-fb-shm-stream` implementation:

- `--print-capabilities` reports `gpu.zero-copy=no`,
  `gpu.backend=none`, `gpu.native-handle-import=no`, and
  `gpu.status=GPU_E_BACKEND_NOT_BUILT`.
- `--mode gpu` is strict and exits with status **3** before connecting.  It
  never silently substitutes the SHM/rawvideo path.
- `--mode auto` does not request GPU notifications while the native backend
  probe is unavailable; it uses the same full-frame SHM path as
  `--mode shm`.
- Build-discovery fields such as `build.libdrm`, `build.libavcodec`, or
  `build.cuda` are diagnostic only.  A `yes` value does not turn the current
  consumer into a native GPU-handle encoder.
- Windows source is cross-compile checked, not accepted as a G-11 host.
  Opening a named D3D11 texture without a keyed mutex or fence is rejected as
  synchronization-unsafe.

## Acceptance policy

A new host OS, guest OS, NVIDIA branch, display mode, or encoder backend becomes
**Supported** only after all of the following are recorded:

1. reproducible build and package instructions;
2. launcher and shutdown lifecycle tests;
3. a real-hardware boot, display, input, and clean-release run;
4. a 60-minute dynamic-frame soak with frame cadence and CPU/GPU usage;
5. failure tests for process crash, stale socket/PID files, and forced stop;
6. explicit security settings (Secure Boot, HVCI, signing, transport
   authentication, and exposed network listeners).

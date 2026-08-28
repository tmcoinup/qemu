============================================================================
``-display fb-shm`` — shared-memory streaming and optional GPU handle export
============================================================================

The ``fb-shm`` display backend exports the (optionally cropped) guest
framebuffer through host shared memory plus a doorbell event.  The generic
QEMU producer can also publish a GPU-resident scanout handle when the
underlying display path supplies one and a client explicitly requests it.
On Linux, the SHM path uses ``memfd`` + ``eventfd`` and the optional GPU
transport uses a ``dma-buf`` fd.  Windows source code provides named file
mapping/event transport and a named-D3D11-texture notification, but that
code is cross-compile validated only.  The current D3D11 notification has
no keyed-mutex or fence protocol and is not safe for asynchronous native
encoding.

It was designed for three workloads that don't fit the existing
backends well:

* **Real-time encoding to NVENC / QSV / x264** (RTMP, RTP, UDP, SRT or
  local file) where the encoder lives in a *different* process than
  QEMU.  The current reference consumer feeds ffmpeg a CPU ``rawvideo``
  stream; selecting NVENC or QSV changes the encoding stage but does not
  make that transport zero-copy.
* **Multi-VM fan-out** where one host streams several guests and each
  guest needs its own deterministic CPU/GPU budget.
* **Anti-cheat sensitive guests** where in-guest detection of a
  capture path (Spice, dbus-display, VNC) is unacceptable and the
  guest must believe it has a normal local display.  No QMP/HMP
  channel is opened on the guest, no extra PCI device is added.

.. contents::
   :local:

Scope and G-11 product boundary
===============================

This document describes the generic QEMU backend and its wire protocol.
That protocol capability is broader than the supported G-11 product:

* G-11 is a **Linux-host / Windows-guest** NVIDIA vGPU product.  A Windows
  host is not a supported G-11 deployment.
* The accepted R535 vGPU stack exposes its console through a system-memory
  VFIO display ``REGION``.  It does not provide an original DMA-BUF scanout
  to ``fb-shm``; the NVIDIA-vGPU-to-host boundary is therefore not zero-copy.
* SDL/GTK nevertheless uploads that ``DisplaySurface`` to the active local
  display GPU.  When DGame asks for GPU frames, G-11 performs a GPU-only ROI
  blit and exports the resulting texture as a DMA-BUF.  This avoids a second
  CPU preview copy after the unavoidable REGION materialisation.  The active
  DRM/EGL provider is selected by the desktop, not by a hard-coded RX570 PCI
  address, so an RX550 replacement follows the same ``amdgpu`` path.
* Texture export/import failure is not fatal.  DGame first tries strict GPU
  delivery, then reconnects the same per-VM object in SHM-only mode.  One VM
  falling back does not change another VM's transport, ROI, or frame rate.
* The separate network-encoding stream remains a complete BGR0 frame (or a
  configured ROI) in SHM, copied by the consumer and written to ffmpeg's
  ``rawvideo`` stdin.  A later NVENC upload and hardware encode do not make
  this path GPU zero-copy.
* The current ``qemu-fb-shm-stream`` binary has no native DMA-BUF/D3D11
  import-and-encode backend.  ``--print-capabilities`` reports
  ``gpu.zero-copy=no`` and ``gpu.status=GPU_E_BACKEND_NOT_BUILT``.
  ``--mode gpu`` is strict and exits with status 3 before connecting;
  it never silently falls back to SHM.
* With the current binary, ``--mode auto`` and ``--mode shm`` both use the
  full-frame SHM path.  ``auto`` does not subscribe to GPU notifications
  when the native backend probe fails.

Architecture
============

::

    +------------------- QEMU process ------------------+
    |                                                   |
    |  guest GPU / display device                       |
    |              |                                    |
    |              v                                    |
    |       DisplaySurface or GL/dma-buf/D3D scanout    |
    |              |                                    |
    |              v                                    |
    |     fb-shm DisplayChangeListener                  |
    |        |                       |                  |
    |        | SHM fallback          | GPU export       |
    |        v                       v                  |
    |   shm [hdr|buf0|buf1]     dma-buf / D3D11 name    |
    |   event [doorbell]        NOTIFY_GPU_FRAME        |
    +-------|----------------------|--------------------+
            |  AF_UNIX control      |
            |  socket               |
            v                       v
    +-- current reference consumer (per VM) --+
    |  receive SHM mapping/event              |
    |  mmap / MapViewOfFile                   |
    |  poll, then seqlock-read and memcpy     |
    |                                         |
    |  ffmpeg rawvideo stdin                  |
    |    -f rawvideo -pix_fmt bgr0 -i -        |
    |    -c:v h264_nvenc ...  (GPU upload)    |
    +-----------------------------------------+

The GPU-export branch in this diagram is consumed directly by DGame's local
EGL preview.  The reference *encoding* consumer validates its descriptors
but does not yet have the native import-and-encode backend needed to consume
them.

Producer side (QEMU) work per frame depends on the subscriber:

1. ``graphic_hw_update()`` to materialise the guest surface (already
   done by every other backend on every refresh tick).
2. SHM subscribers use **one**
   ``pixman_image_composite32(PIXMAN_OP_SRC, ...)`` call that crops to ROI
   and converts to BGR0 in a single pass.
3. A DGame GPU subscriber reuses the SDL/GTK surface texture, blits only the
   requested ROI into a private texture, then exports that texture as a
   DMA-BUF.  It does not read the texture back to CPU memory.
4. SHM publication uses two atomic stores (``active_idx``, ``frame_seq``)
   and one doorbell signal (``eventfd`` on Linux, ``SetEvent`` on Windows).

There is no host-side encoding inside QEMU.  When a generic producer
receives a suitable GPU scanout, its GPU notification describes that
backing object without performing a GL readback.  The G-11 path still starts
from the system-memory VFIO display REGION; its local GPU export begins only
after SDL/GTK's existing upload.  A consumer without native handle import can
ignore ``NOTIFY_GPU_FRAME`` and keep using SHM, but that fallback is explicitly
not GPU zero-copy.

Data flow & ABI
===============

Every backend instance owns:

* a host shared-memory object of ``256 + N * (W * H * 4)`` bytes, where
  ``N`` is the buffer count (currently 2);
* a doorbell event that pulses once per committed frame;
* a ``SOCK_STREAM`` ``AF_UNIX`` listener at
  ``/run/qemu/fb-${id}.sock``.

The on-disk layout, request/reply structs, and atomicity rules are
documented in `<../include/ui/fb-shm-abi.h>`_.  Consumers in any
language replicate that header.  The native ``qemu-fb-shm-stream``
consumer uses the same packed C structures as QEMU.

Wire-format summary:

::

    offset 0           : FbShmHeader (256 bytes)
    offset hdr.buf_offset[0] .. +hdr.buf_size : pixel slot 0
    offset hdr.buf_offset[1] .. +hdr.buf_size : pixel slot 1

Producer commit sequence (refresh tick):

1. Pick ``next_idx = (active_idx + 1) % buf_count``.
2. Composite ROI into ``slot[next_idx]``.
3. ``store_release(active_idx, next_idx)``.
4. ``store_release(frame_seq, frame_seq + 1)``.
5. Signal the per-host doorbell.

Consumer read sequence (seqlock):

::

    do {
        s0  = load_acquire(frame_seq);
        idx = load_acquire(active_idx);
        memcpy(local, buf[idx], buf_size);
        s1  = load_acquire(frame_seq);
    } while (s0 != s1);

A torn read can happen only if the producer wraps around buffers while
the consumer is mid-``memcpy``.  With ``buf_count=2`` and a 60 Hz
producer, the consumer has roughly 16 ms to copy 8 MB (1080p) — which
is comfortable on every host since 2014.  ``buf_count`` can be
extended to 3 in a future ABI minor version if a slow consumer ever
becomes a real concern.

Invocation
==========

Minimum::

    qemu-system-x86_64 \
        -display fb-shm \
        -device virtio-vga -m 4G \
        -drive file=disk.qcow2

This publishes ``/run/qemu/fb-qemu-${pid}.sock`` at 30 Hz tracking the
full guest surface.

All sub-options::

    -display fb-shm[,id=name][,path=sock]
                   [,x=N][,y=N][,width=W][,height=H]
                   [,rate=Hz][,keepalive=on|off]

* ``id=name`` — short name used to derive defaults; defaults to
  ``qemu-${pid}``.
* ``path=sock`` — control socket path; defaults to
  ``/run/qemu/fb-${id}.sock``.
* ``x``, ``y``, ``width``, ``height`` — region of interest in source
  pixels.  Either dimension being 0 means "track the full guest
  surface" (so an unspecified ROI follows guest mode changes).
* ``rate=Hz`` — fixed publication rate, clamped to ``[1, 240]``;
  defaults to 30.  QEMU converts it directly to a nanosecond period and
  advances the GUI timer from absolute deadlines, so 60 Hz is
  ``16,666,667 ns`` rather than a millisecond-quantised 16 ms loop.  Every
  due tick publishes: when no new damage exists, QEMU repeats the latest
  cached GPU texture or SHM slot without redoing the ROI copy/blit.
* ``keepalive=on|off`` — wake a guest that stopped refreshing its display
  output; defaults to ``on``.  See `Display keep-alive`_.

Display keep-alive
------------------

``rate`` is a publication cadence, not a damage ceiling: a due tick republishes
the active slot even when nothing changed.  That is deliberate, but it means
``frame_seq`` alone cannot tell a live stream from a frozen one.

After a long stretch without input a guest may stop refreshing its display
output entirely -- on Windows the idle power policy blanks the output and the
compositor stops composing.  The guest keeps rendering, but the console handed
to QEMU stops changing, so the damage compare finds nothing dirty.  Consumers
then receive a perfectly steady frame rate over a picture frozen on its last
frame; one that drives decisions off the picture will keep reading that stale
frame as if it were live state.

Two mechanisms address this, and consumers can rely on either:

* ``content_seq`` in ``FbShmHeader`` advances only when the guest actually
  redrew, giving consumers an exact "is the picture moving?" predicate that is
  independent of ``frame_seq``.  It lives in the reserved tail of the 256-byte
  header, so producers that predate it leave it at 0 and consumers must read 0
  as "unsupported" rather than "frozen".
* With ``keepalive=on`` QEMU injects a Scroll Lock press once the guest has not
  redrawn for roughly ten seconds and at least one consumer is attached, then
  backs off before trying again.  Neither the desktop nor a fullscreen
  application acts on that key, while the guest still counts it as user input
  activity.  Press duration and intervals are jittered.  Nothing is injected
  before the guest has been seen to draw at least once, so a console that never
  reports damage is never poked.

Fixing the guest's own idle policy remains the cleaner cure; the keep-alive is
the backstop for guests that cannot be reconfigured.

Runtime control
---------------

The control socket also accepts ``SET_ROI`` and ``SET_RATE`` messages
(see ``FB_SHM_CTL_*`` in the ABI header).  The native consumer exposes
them via ``--roi x,y,w,h`` and ``--rate Hz``.

``SET_RATE`` is idempotent and also revalidates the current display source.
A preview consumer may therefore resend its already configured rate if the
fixed stream goes silent: QEMU invalidates the hardware console and replays
one frame.  If no frame follows, the consumer reconnects without relying on
an operator to show/hide the SDL window.

Resize notification (``NOTIFY_RESIZED``)
----------------------------------------

A ``SET_ROI`` (or any guest-driven resolution change) makes QEMU
re-allocate the backing shared-memory object, which leaves every
previously-handed-out mapping pointing at frozen pixels.  The ABI v1
protocol therefore includes a server-initiated message —
``FB_SHM_CTL_NOTIFY_RESIZED`` (op code 5) — that re-broadcasts fresh
Linux fds via ``SCM_RIGHTS`` or fresh Windows object names to every
consumer that opted in.

Opt-in is encoded in the ``flags`` field of the ``HELLO`` request
(formerly ``reserved``):

* ``FB_SHM_HELLO_F_RESIZE_NOTIFY (1<<0)`` — "I will react to
  ``NOTIFY_RESIZED`` by re-mapping the new shared memory and replacing
  my doorbell watch."
* ``FB_SHM_HELLO_F_WIN32_NAMES (1<<1)`` — Windows-only: "send Win32
  mapping/event names after the ack payload."

A consumer that does **not** set the flag preserves the legacy
behaviour (frozen frames after a ROI change until it reconnects) and
remains wire-compatible with QEMU builds that pre-date this message.

On the Linux client side, after a ``NOTIFY_RESIZED`` arrives:

1. ``recvmsg`` the 32-byte ack plus the two ``SCM_RIGHTS`` fds.
2. ``mmap(new_memfd, ack.shm_size)`` and replace the previous
   mapping.
3. Replace the old eventfd watch with the new fd; the old eventfd
   stops firing (QEMU keeps re-using a single ``wake_eventfd``
   per backend, but every consumer holds its own dup).
4. Reset any local "last consumed ``frame_seq``" to 0 — the new
   memfd starts a fresh seqlock at 0.

On the Windows client side, the ack is followed by ``FbShmWin32Names``.
The consumer opens the new mapping with ``OpenFileMappingA``, opens the
new event with ``OpenEventA``, then replaces the previous
``MapViewOfFile`` view.

The reference Rust consumer in ``dgame``
(``adapters/capture/fb_shm/control.rs``) does this in a background
``tokio`` task that multiplexes the control socket: synchronous
``SET_ROI`` / ``SET_RATE`` acks are routed via ``oneshot`` channels
while ``NOTIFY_RESIZED`` lands on a separate ``mpsc`` and triggers an
in-place mmap / eventfd swap without dropping the session.

GPU-frame payload negotiation
-----------------------------

GPU subscribers set ``FB_SHM_HELLO_F_GPU_FRAMES (1<<2)``.  A subscriber
that can consume the extended source geometry also sets
``FB_SHM_HELLO_F_GPU_SOURCE_SIZE (1<<5)``.  QEMU then sends the 344-byte
``FbShmGpuFrame`` v2 payload after the ``NOTIFY_GPU_FRAME`` ack; the ack's
``shm_size`` field is the payload length.  Version 2 keeps every v1 field at
the same offset and appends ``source_width`` / ``source_height``.

The distinction matters for a private ROI texture.  For example, an
``800x600`` exported texture may still describe a ``1920x1080`` guest
source.  DGame imports the smaller texture for preview, but uses the source
dimensions for SDL restore/max-size policy and for mapping memory-discovered
game coordinates into the stream ROI.

Compatibility is negotiated in both directions:

* A new QEMU sends the legacy 336-byte v1 payload to a client that does not
  advertise ``GPU_SOURCE_SIZE``.
* A new DGame client accepts both sizes.  With an older QEMU, it treats the
  v1 backing dimensions as the source dimensions.

Consumers must therefore read exactly ``ack.shm_size`` bytes and validate
the payload's ``version`` and ``size`` instead of assuming a compile-time
length.

Reference consumer
==================

``qemu-fb-shm-stream`` implements the full handshake and
seqlock reader, then pipes raw frames into ffmpeg.  It accepts
``--mode auto|gpu|shm``:

* ``auto`` (default) uses the SHM rawvideo path in the current build.  It
  subscribes to GPU notifications only when a native handle-import encoder
  probe succeeds; the current probe does not.
* ``shm`` explicitly selects the same full-frame SHM path and disables GPU
  notifications.
* ``gpu`` is strict: because no native DMA-BUF/D3D11 import-and-encode
  backend is implemented, it reports ``GPU_E_BACKEND_NOT_BUILT`` and exits
  with status 3 before opening the control socket.  It never treats ffmpeg's
  CPU ``rawvideo`` pipe as a zero-copy fallback.

Run ``qemu-fb-shm-stream --print-capabilities`` before selecting strict
GPU mode.  For the current consumer the decisive output is::

    gpu.zero-copy=no
    gpu.backend=none
    gpu.native-handle-import=no
    gpu.status=GPU_E_BACKEND_NOT_BUILT

The optional dependency lines in that output describe libraries discovered
at build time; their presence does not enable a native GPU encoder in the
current implementation.

ffmpeg encoders usable after the SHM/rawvideo transport include:

``libx264`` with the ``veryfast`` preset is the safe default.  Hardware
encoders must be selected explicitly and validated against the host driver.

* ``h264_nvenc`` / ``hevc_nvenc`` — raw frames are still copied through
  CPU memory and uploaded before hardware encoding.
* ``h264_qsv`` / ``hevc_qsv`` — likewise requires an upload from the
  SHM/rawvideo input.
* ``libx264`` — CPU encoding (use ``--preset veryfast`` and budget CPU
  capacity per VM).

Encoder availability and session limits depend on the host ffmpeg build,
driver and hardware.  Hardware encoding alone is not evidence of zero-copy.

Examples::

    # SHM/rawvideo -> NVENC upload -> UDP output
    qemu-fb-shm-stream --sock /run/qemu/fb-qemu-12345.sock \
        --output 'udp://127.0.0.1:5000?pkt_size=1316' \
        --encoder h264_nvenc --bitrate 8M --mode auto

    # local capture to mp4 (no network)
    qemu-fb-shm-stream --sock /run/qemu/fb-vm1.sock \
        --output /tmp/vm1.mp4 --encoder libx264 --preset veryfast

    # crop a 1280x720 ROI on a 4K guest
    qemu-fb-shm-stream --sock /run/qemu/fb-vm1.sock \
        --roi 320,180,1280,720 --rate 60 \
        --encoder h264_nvenc --bitrate 6M \
        --output 'rtmp://ingest/live/vm1'

Runtime control via QMP
=======================

The G-11 launcher gives DGame its own hot-pluggable object and keeps the
network encoder on a second object.  Operators normally use the identity-
checked wrapper instead of hand-written QMP::

    # Add preview to an already-running pre-upgrade VM
    ./deploy/scripts/vmctl.sh display 8 preview-on

    # Verify canonical and DGame discovery endpoints
    ./deploy/scripts/vmctl.sh display 8 status

    # Remove DGame preview only; a stream-vm8 encoder object is untouched
    ./deploy/scripts/vmctl.sh display 8 preview-off

Native starts publish ``/tmp/qemu-stealth-N.fb`` as a safe symlink to the
per-instance socket.  They also publish raw QMP/HMP discovery paths, use
``win10-N`` for the one primary SDL operator window, and keep ``vmN`` as the
QMP/process identity.  The launcher selects SDL ``single-console=on`` so
firmware/text consoles do not create additional host windows; those consoles
remain available to other QEMU display listeners.  QMP multi-client mode is
enabled whenever the default DGame preview is active.

Two pieces, composable:

1. ``object-add`` / ``object-del`` (built-in, with the ``-object fb-shm``
   form) hot-plugs the entire backend.  ``object-del`` tears down the
   socket, eventfd and memfd; ``object-add`` rebuilds with possibly
   different ROI/rate.  Useful when the consumer needs to renegotiate
   geometry without restarting the guest.

2. ``display-pause`` / ``display-resume`` (Since 9.2) freezes a
   listener's refresh callback without unregistering it.  Cheaper than
   teardown, matches by ``dpy_name`` prefix, and triggers any backend's
   ``dpy_set_paused`` hook (SDL hides its window; fb-shm just stops
   incrementing ``frame_seq``).

::

    # stop the SDL window without quitting the VM, keep fb-shm streaming
    -> { "execute": "display-pause", "arguments": { "name": "sdl2" } }
    <- { "return": {} }

    # bring it back
    -> { "execute": "display-resume", "arguments": { "name": "sdl2" } }
    <- { "return": {} }

    # pause the recorder, keep the SDL window
    -> { "execute": "display-pause", "arguments": { "name": "fb-shm" } }
    <- { "return": {} }

The ``name`` argument is matched as a prefix, so ``sdl2`` covers both
``sdl2-2d`` and ``sdl2-gl`` listeners that the SDL backend installs
depending on whether OpenGL is enabled.  An unknown name returns a
``GenericError``.  Per listener CPU savings on a 1080p60 setup:

* ``display-pause sdl2``  — ~3-7% of one host core, plus a GPU driver
  wake-up.  The biggest single saving.
* ``display-pause fb-shm`` — ~1-2% of one host core (the pixman copy +
  the eventfd write).
* ``object-del fb-shm`` — same as the pause above plus releases the
  memfd / socket / eventfd.  Use when the consumer is fully done.

Multiple subscribers per backend
================================

A single ``fb-shm`` instance handles N concurrent consumers out of the
box.  The control socket's accept queue is sized at 16; each connecting
consumer receives its own ``SCM_RIGHTS`` copy of the (refcounted) memfd
and eventfd, so:

* All consumers ``mmap`` the **same physical SHM pages**, so QEMU does not
  allocate another producer buffer per subscriber.  Individual consumers
  may still allocate their own frame copy and encoder buffers.
* The eventfd doorbell is shared.  Every ``select`` / ``poll`` fires on
  every QEMU commit; the first reader drains the counter and the rest
  see ``EAGAIN`` but have already woken up.  Correctness comes from the
  seqlock (compare ``frame_seq``), not from the eventfd value.
* Slow consumers cannot back-pressure QEMU or the other consumers — a
  consumer that misses a tick simply re-reads the latest ``active_idx``
  on the next wake.

Example: live RTMP push *and* local archival recording in parallel::

    # QEMU started with -object fb-shm,id=cap,path=/run/qemu/fb-vm1.sock

    # consumer A: SHM/rawvideo -> NVENC upload -> RTMP
    qemu-fb-shm-stream --sock /run/qemu/fb-vm1.sock \
        --output 'rtmp://ingest/live/vm1' --encoder h264_nvenc &

    # consumer B: x264 -> local mp4
    qemu-fb-shm-stream --sock /run/qemu/fb-vm1.sock \
        --output /tmp/vm1.mp4 --encoder libx264 --preset veryfast &

    # consumer C: a custom Rust analyser that just inspects pixels
    ./my-analyser --sock /run/qemu/fb-vm1.sock &

Caveats:

* ``listen(fd, 16)`` — 17+ consumers racing to connect at the exact
  same instant get ``ECONNREFUSED`` and must retry.  Not normally a
  problem; consumers connect at human time scales.
* The eventfd's "exact wake count" is lost when sharing.  If your
  consumer relies on the eventfd value rather than the seqlock, switch
  to per-client eventfds (a future ABI extension; not implemented in
  v1).
* Each consumer is responsible for its own framerate / decode.  If
  consumer A wants 60 Hz and consumer B wants 30 Hz, B simply skips
  every other ``frame_seq`` advance.  fb-shm publishes at the configured
  ``rate`` and repeats the newest cached frame when the source is unchanged.

Multi-VM fan-out
================

``scripts/qemu-fb-shm-multivm.py`` reads a YAML/JSON spec and spawns
one consumer per VM with optional CPU pinning.  Each consumer is a
separate process so a slow encoder on one VM cannot back-pressure
another::

    vms:
      - id: vm1
        sock: /run/qemu/fb-vm1.sock
        output: rtmp://ingest/live/vm1
        encoder: h264_nvenc
        cpus: "0-3"
        roi: "0,0,1920,1080"
      - id: vm2
        sock: /run/qemu/fb-vm2.sock
        output: udp://127.0.0.1:5002?pkt_size=1316
        encoder: h264_nvenc
        cpus: "4-7"

Hardware budget
---------------

============================================  =============================================
Encoder                                       Sessions per chip
============================================  =============================================
NVENC, GA10x+                                 unlimited (consumer cards: 5; lifted by `nvidia-patch <https://github.com/keylase/nvidia-patch>`_)
NVENC, Pascal                                 2
QSV (Intel)                                   ~16, single shared ring
AMF (AMD)                                     ~16, single shared ring
libx264                                       ~1 core per 1080p30 stream
============================================  =============================================

Performance tips
================

For a 16-window RX550/RX570-class local preview deployment, run the read-only
sizing check before and after replacing the display card::

    ./deploy/scripts/vmctl.sh preview-capacity --instances 16 --rate 60

The default report uses a ``1920x1080`` guest DisplaySurface and covers both
``800x600`` and ``1067x600`` preview ROIs.  It checks the DRM provider without
binding business logic to an AMD device ID, then reports the full-surface
upload, ROI payload, combined upper bound, and conservative texture residency.
Use ``--source-size WxH`` when the guest source differs.  Runtime EGL export
remains the authoritative test; a failed export triggers the per-VM SHM
fallback rather than a black preview.

* Pin each consumer to an isolated CPU core (``--cpu-affinity``); the
  kernel will keep ``memcpy`` close to QEMU's vCPU thread.
* Set ``rate`` only as high as the encoder can sustain.  60 Hz is
  fine on Ada; 30 Hz is safer for shared GPUs.
* For static screens (kiosks), drop to ``rate=10`` and let the
  encoder's GOP do the rest.  A 1080p10 NVENC session uses roughly
  60 MB/s of host RAM bandwidth for the SHM writes.
* Use a ROI smaller than the guest surface whenever the consumer
  doesn't need full resolution.  Cropping happens during the pixman
  composite, so the saved bytes are real (both RAM bandwidth and
  encoder work).
* Avoid ``rate=240``.  The DCL refresh cadence is shared with the
  rest of QEMU's GUI machinery and very high values starve other
  timers.  60-90 Hz is the sweet spot.

Guest-side stealth
==================

``fb-shm`` does not introduce any guest-visible artifact:

* No additional virtual PCI device or MMIO region.
* No extra ACPI table entry, vendor/device IDs unchanged.
* No QGA/Spice/dbus channel opened in the guest.
* No GPU command stream interception (the producer copies the same
  ``DisplaySurface`` ``-display sdl`` would composite to a window).

When combined with the project's anti-detect bundle (NVIDIA-spoofed
virtio-gpu, devirt P0/P1 patches, EfiGuard), the guest sees a normal
GPU with a real local display whose framebuffer happens to be readable
from the host.

GPU passthrough alternative
===========================

If the guest is configured with **VFIO GPU passthrough** then the
framebuffer never touches host RAM and ``fb-shm`` has nothing to
publish (``DisplaySurface`` is a placeholder).  The two viable
alternatives in that mode:

* `Looking Glass <https://looking-glass.io>`_ — an in-guest user-mode
  helper writes the GPU's scanout into an IVSHMEM region; the host
  reads from there.  Requires ``ivshmem-plain`` plus the guest helper.
* NVIDIA NVFBC + a guest-side capture daemon — works on RTX and
  Quadro/Tesla parts (consumer cards need ``nvidia-patch``); strict
  vendor coupling and can keep capture/encode on the GPU only when paired
  with appropriate native encoder interop.  It is not a G-11 accepted path.

``fb-shm`` is the right choice when the guest uses an emulated
display device (``virtio-gpu``, ``-vga std/qxl``).  Looking Glass is
the usual choice when the guest exclusively owns a fully passed-through GPU.
That full-passthrough case differs from the G-11 R535 mdev console, which
does expose the system-memory VFIO display REGION used by G-11.

Limitations & roadmap
=====================

Known gaps in the v9.2 implementation:

* ``cursor=on`` is parsed but not yet honoured; the cursor is not
  blended into the SHM frames.  Consumers can read ``QEMUCursor`` via
  the existing ``query-mice`` / ``input-send-event`` paths if needed.
* Only the primary graphic console (index 0) is exported.  Multi-head
  guests need one ``fb-shm`` instance per head.
* The ABI v1 SHM plane always publishes full ``BGR0`` frames.  Optional
  GPU-handle notifications are a negotiated control-plane path with v1/v2
  payloads; the current reference encoding consumer does not encode those
  handles.
* The generic Linux implementation is exercised.  The Windows producer and
  consumer sources are cross-compile checked only, and the current D3D11
  shared-texture notification lacks safe keyed-mutex/fence synchronization.
  Windows host operation is therefore not claimed as supported.
* G-11 specifically supports a Linux host and Windows guest; it does not
  support a Windows host.  FreeBSD/macOS would need another shared-memory
  transport and have no G-11 lifecycle.

See also
========

* `<../include/ui/fb-shm-abi.h>`_ — wire format reference.
* ``qemu-fb-shm-stream`` — reference consumer; Linux is exercised and
  Windows is cross-compile checked only.
* ``scripts/qemu-fb-shm-multivm.py`` — multi-VM orchestrator.
* ``scripts/qemu-fb-shm-spawn.sh`` — example QEMU launcher.

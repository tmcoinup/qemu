/*
 * QEMU framebuffer shared-memory ABI (host <-> external consumer).
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Wire-stable layout used by the `-display fb-shm` backend.
 * Consumers (Python / Rust / C) mirror this struct verbatim.
 *
 * Memory map (single memfd, sealed against grow/shrink):
 *
 *   [0 .. FB_SHM_HEADER_SIZE)     : FbShmHeader (256 bytes)
 *   [hdr.buf_offset[0] .. +len)   : pixel buffer slot 0 (BGR0/BGRA)
 *   [hdr.buf_offset[1] .. +len)   : pixel buffer slot 1
 *
 * hdr.buf_size is the current visible frame size.  The physical distance
 * between buf_offset entries may be larger, allowing producers to keep a
 * fixed backing map while ROI dimensions change.
 *
 * The producer (QEMU) commits a frame by:
 *   1. Writing the inactive slot completely.
 *   2. qatomic_store_release(active_idx, next).
 *   3. qatomic_store_release(frame_seq, prev_seq + 1).
 *   4. write(eventfd, u64=1) to wake consumers.
 *
 * Consumer reads with a seqlock pattern:
 *   do {
 *       s0  = atomic_load_acquire(frame_seq);
 *       idx = atomic_load_acquire(active_idx);
 *       memcpy(local, buf[idx], len);
 *       s1  = atomic_load_acquire(frame_seq);
 *   } while (s0 != s1);
 */

#ifndef QEMU_UI_FB_SHM_ABI_H
#define QEMU_UI_FB_SHM_ABI_H

#include <stdint.h>

#define FB_SHM_MAGIC        0x46425348u   /* "FBSH" little-endian      */
#define FB_SHM_VERSION      1u
#define FB_SHM_HEADER_SIZE  256u
#define FB_SHM_BUF_COUNT    2u

/* fourcc values for the @fourcc field (DRM-compatible). */
#define FB_SHM_FOURCC_BGR0  0x30524742u   /* "BGR0" - x8r8g8b8 LE      */
#define FB_SHM_FOURCC_BGRA  0x41524742u   /* "BGRA" - a8r8g8b8 LE      */

/* @flags bit masks. */
#define FB_SHM_FLAG_RUNNING        (1u << 0)
#define FB_SHM_FLAG_CURSOR_BAKED   (1u << 1)
#define FB_SHM_FLAG_RESIZED        (1u << 2)

/*
 * Control socket protocol (one stream socket per backend).
 *
 *   client -> server : FbShmCtlReq (32 bytes, host byte order).
 *
 * Linux / POSIX:
 *   server -> client : FbShmCtlAck (32 bytes) + ancillary SCM_RIGHTS
 *                      { memfd, eventfd } on HELLO ack.
 *   server -> client : FbShmCtlAck (32 bytes) + FbShmGpuFrame +
 *                      ancillary SCM_RIGHTS { dmabuf_fd } for legacy GPU
 *                      clients.  A client that also negotiated GPU_SYNC gets
 *                      the ordered pair { dmabuf_fd, acquire_sync_file_fd }
 *                      and must return GPU_FRAME_DONE before reuse.
 *
 * Windows:
 *   client sets FB_SHM_HELLO_F_WIN32_NAMES in HELLO.flags.
 *   server -> client : FbShmCtlAck (32 bytes) + FbShmWin32Names.
 *   The client opens @mapping_name with OpenFileMappingA() and @event_name
 *   with OpenEventA().  QEMU sets a per-client event on every published
 *   frame, so multiple consumers get independent wakeups while sharing the
 *   same frame mapping.
 *   server -> client : FbShmCtlAck (32 bytes) + FbShmGpuFrame when the
 *                      client requested FB_SHM_HELLO_F_GPU_FRAMES and QEMU
 *                      has a D3D11 shared texture.  The client opens
 *                      @handle_name with ID3D11Device1::OpenSharedResourceByName.
 *
 * NOTIFY_RESIZED is the only server-initiated message: when QEMU re-allocates
 * the backing store (resolution change, ROI update), it pushes a fresh
 * Linux fd pair or Windows object-name payload to every client that opted into
 * resize notifications via FB_SHM_HELLO_F_RESIZE_NOTIFY.  Clients that did
 * not set the flag observe the legacy behaviour (frozen frames after resize).
 */
#define FB_SHM_CTL_HELLO          1u
#define FB_SHM_CTL_SET_ROI        2u
#define FB_SHM_CTL_SET_RATE       3u
#define FB_SHM_CTL_BYE            4u
#define FB_SHM_CTL_NOTIFY_RESIZED   5u /* server -> client; SCM_RIGHTS {memfd,evfd} */
#define FB_SHM_CTL_NOTIFY_GPU_FRAME 6u /* server -> client; optional GPU handle */
/* GPU_SYNC release: w=sequence low 32 bits, h=sequence high 32 bits. */
#define FB_SHM_CTL_GPU_FRAME_DONE   7u

#define FB_SHM_CTL_OK           0u
#define FB_SHM_CTL_EINVAL       1u
#define FB_SHM_CTL_EBUSY        2u
#define FB_SHM_CTL_EUNSUPPORTED 3u

/* HELLO request flag bits (FbShmCtlReq.flags). */
#define FB_SHM_HELLO_F_RESIZE_NOTIFY (1u << 0)
#define FB_SHM_HELLO_F_WIN32_NAMES   (1u << 1)
#define FB_SHM_HELLO_F_GPU_FRAMES    (1u << 2)
#define FB_SHM_HELLO_F_GPU_REQUIRED  (1u << 3)
/* Linux NOTIFY carries {dma-buf, acquire sync_file} and requires DONE. */
#define FB_SHM_HELLO_F_GPU_SYNC      (1u << 4)
/* Client accepts FbShmGpuFrame v2 with full guest source dimensions. */
#define FB_SHM_HELLO_F_GPU_SOURCE_SIZE (1u << 5)

#define FB_SHM_WIN32_NAME_MAX 260u
#define FB_SHM_GPU_NAME_MAX   260u

/* FbShmGpuFrame.handle_type values. */
#define FB_SHM_GPU_HANDLE_NONE          0u
#define FB_SHM_GPU_HANDLE_DMA_BUF       1u
#define FB_SHM_GPU_HANDLE_D3D11_TEXTURE 2u

/* FbShmGpuFrame.flags bit masks. */
#define FB_SHM_GPU_FRAME_F_Y0_TOP       (1u << 0)
#define FB_SHM_GPU_FRAME_F_KEYED_MUTEX  (1u << 1)
/* Linux SCM_RIGHTS is exactly {dma-buf fd, producer acquire-fence fd}. */
#define FB_SHM_GPU_FRAME_F_SYNC_FILE    (1u << 2)

#define FB_SHM_GPU_FRAME_VERSION_V1 1u
#define FB_SHM_GPU_FRAME_VERSION    2u

typedef struct FbShmCtlReq {
    uint32_t magic;
    uint32_t op;
    int32_t  x, y;
    uint32_t w, h;
    uint32_t rate_hz;
    uint32_t flags;          /* HELLO: FB_SHM_HELLO_F_*; otherwise reserved 0 */
} FbShmCtlReq;

typedef struct FbShmCtlAck {
    uint32_t magic;
    uint32_t op;
    uint32_t status;
    uint32_t shm_size;
    uint32_t width, height;
    uint32_t fourcc;
    uint32_t bpp;
} FbShmCtlAck;

/*
 * Windows-only payload sent immediately after FbShmCtlAck when the client
 * requested FB_SHM_HELLO_F_WIN32_NAMES and the ack status is FB_SHM_CTL_OK.
 * The strings are UTF-8 / ANSI Win32 object names, NUL-terminated when shorter
 * than FB_SHM_WIN32_NAME_MAX.
 */
typedef struct FbShmWin32Names {
    uint32_t magic;
    uint32_t version;
    uint32_t size;
    uint32_t flags;
    char mapping_name[FB_SHM_WIN32_NAME_MAX];
    char event_name[FB_SHM_WIN32_NAME_MAX];
} FbShmWin32Names;

/*
 * Optional GPU frame payload.
 *
 * This is a control-plane description of a GPU-resident scanout.  It is sent
 * only to clients that set FB_SHM_HELLO_F_GPU_FRAMES.  Linux carries the
 * actual dma-buf handle as an SCM_RIGHTS fd attached to the same socket
 * message.  Windows carries a named D3D11 shared texture in @handle_name.
 *
 * The shared-memory BGR0 ABI remains the compatibility path.  GPU consumers
 * use this payload when their encoder can import dma-buf / D3D11 directly;
 * otherwise they can ignore it and keep reading FbShmHeader slots.
 */
/* Legacy payload retained for clients that did not negotiate v2. */
typedef struct FbShmGpuFrameV1 {
    uint32_t magic;
    uint32_t version;
    uint32_t size;
    uint32_t handle_type;
    uint32_t flags;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t fourcc;
    uint32_t x;
    uint32_t y;
    uint32_t backing_width;
    uint32_t backing_height;
    uint64_t modifier;
    uint64_t frame_seq;
    char handle_name[FB_SHM_GPU_NAME_MAX];
} FbShmGpuFrameV1;

typedef struct FbShmGpuFrame {
    uint32_t magic;
    uint32_t version;
    uint32_t size;
    uint32_t handle_type;
    uint32_t flags;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t fourcc;
    uint32_t x;
    uint32_t y;
    uint32_t backing_width;
    uint32_t backing_height;
    uint64_t modifier;
    uint64_t frame_seq;
    char handle_name[FB_SHM_GPU_NAME_MAX];
    /* Full guest coordinate space; width/height may be a private ROI texture. */
    uint32_t source_width;
    uint32_t source_height;
} FbShmGpuFrame;

/*
 * Header that lives at offset 0 in the memfd / POSIX shm.
 *
 * sizeof(FbShmHeader) is checked at compile time to be <= 256.  The buffer
 * region always begins at FB_SHM_HEADER_SIZE so that adding new tail fields
 * (within the budget) never moves the pixel data.
 */
typedef struct FbShmHeader {
    /* --- layout (immutable after init) --------------------------- */
    uint32_t magic;
    uint32_t version;
    uint32_t header_size;
    uint32_t buf_count;
    uint64_t buf_size;
    uint64_t buf_offset[FB_SHM_BUF_COUNT];
    uint64_t map_size;

    /* --- geometry (changes on resize / ROI update) --------------- */
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t fourcc;
    uint32_t bpp;
    uint32_t target_fps;
    uint32_t src_width;
    uint32_t src_height;
    int32_t  roi_x;
    int32_t  roi_y;

    /* --- damage rectangle within ROI ----------------------------- */
    int32_t  damage_x;
    int32_t  damage_y;
    int32_t  damage_w;
    int32_t  damage_h;

    /* --- live state, atomic ------------------------------------- */
    uint64_t frame_seq;
    uint64_t ts_ns;
    uint32_t active_idx;
    uint32_t flags;

    /* --- content liveness (appended; older producers leave it 0) -- */
    /*
     * Counts frames whose PIXELS actually changed, as opposed to @frame_seq
     * which counts publications.
     *
     * @target_fps is a publication cadence, not a damage ceiling: when the
     * guest stops refreshing its display output (Windows idle screen-off,
     * DWM halting composition) the producer keeps re-publishing the active
     * slot at the target rate, so @frame_seq advances at 60 Hz while not a
     * single pixel moves.  Consumers that trust @frame_seq alone therefore
     * report a healthy "60 fps" over a frozen picture -- and any OCR built on
     * those frames silently re-reads one stale image.
     *
     * @content_seq only advances when the guest actually redrew, giving
     * consumers an exact "is the picture moving?" predicate.
     *
     * Compatibility: the field lives in the reserved tail of the 256-byte
     * header, so its offset is additive and @header_size is unchanged.
     * Producers that do not maintain it leave it at 0 for the lifetime of the
     * mapping; a consumer must treat 0 as "not supported" and fall back to its
     * own content comparison rather than concluding the picture is frozen.
     */
    uint64_t content_seq;
} FbShmHeader;

#endif /* QEMU_UI_FB_SHM_ABI_H */

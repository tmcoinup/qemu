/*
 * QEMU framebuffer shared-memory ABI (host <-> external consumer).
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Wire-stable layout used by the `-display fb-shm` backend (Linux only).
 * Consumers (Python / Rust / C) mirror this struct verbatim.
 *
 * Memory map (single memfd, sealed against grow/shrink):
 *
 *   [0 .. FB_SHM_HEADER_SIZE)     : FbShmHeader (256 bytes)
 *   [hdr.buf_offset[0] .. +len)   : pixel buffer slot 0 (BGR0/BGRA, ROI sized)
 *   [hdr.buf_offset[1] .. +len)   : pixel buffer slot 1
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
 * Control socket protocol (one Unix-domain stream socket per backend).
 *
 *   client -> server : FbShmCtlReq (32 bytes, host byte order).
 *   server -> client : FbShmCtlAck (32 bytes) + ancillary SCM_RIGHTS
 *                      { memfd, eventfd } on HELLO ack.
 */
#define FB_SHM_CTL_HELLO        1u
#define FB_SHM_CTL_SET_ROI      2u
#define FB_SHM_CTL_SET_RATE     3u
#define FB_SHM_CTL_BYE          4u

#define FB_SHM_CTL_OK           0u
#define FB_SHM_CTL_EINVAL       1u
#define FB_SHM_CTL_EBUSY        2u
#define FB_SHM_CTL_EUNSUPPORTED 3u

typedef struct FbShmCtlReq {
    uint32_t magic;
    uint32_t op;
    int32_t  x, y;
    uint32_t w, h;
    uint32_t rate_hz;
    uint32_t reserved;
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
} FbShmHeader;

#endif /* QEMU_UI_FB_SHM_ABI_H */

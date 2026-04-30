/*
 * nv_shmem_proto.h — shared header for the host ↔ guest data channel
 * carried over an ivshmem-plain BAR.
 *
 * Layout
 * ──────
 *   The QEMU ivshmem-plain device exposes one contiguous region of
 *   host RAM as the guest's BAR2. Both sides mmap the same physical
 *   pages (kvm sets up the page tables to point at the host backing
 *   file), so every byte written by one side is visible to the other
 *   with cache-line latency, no copies, no syscalls.
 *
 *   We use it as two independent SPSC (single-producer single-consumer)
 *   ring buffers + a small control header:
 *
 *       offset 0          : NvShmemHdr (4 KiB, page-aligned)
 *       offset video_off  : video ring (host ← guest)
 *       offset input_off  : input ring (host → guest)
 *
 *   Each ring stores variable-sized framed records. A record is:
 *       u32 size_le           // payload size, 0 means "wrap to ring start"
 *       u8  payload[size]
 *
 *   Producer atomically advances writer_seq AFTER writing the record.
 *   Consumer atomically advances reader_seq AFTER reading.
 *
 * Concurrency
 * ───────────
 *   Single producer, single consumer per ring. No locks. Memory ordering:
 *   producer writes payload, then releases writer_seq (store-release).
 *   Consumer acquires writer_seq (load-acquire), then reads payload.
 *
 *   On x86 the only fence we need is a compiler barrier — both CPUs
 *   observe writes in program order. On weaker archs (ARM) we'd need
 *   __atomic_thread_fence(__ATOMIC_RELEASE/ACQUIRE).
 *
 * Sizing (defaults)
 * ─────────────────
 *   Total BAR  = 64 MiB (matches start-vm.sh IVSHMEM_SIZE_MB)
 *   header     = 4 KiB
 *   video ring = 60 MiB     (room for ~1.5 sec of 320 Mb/s burst at 30 fps)
 *   input ring = 1 MiB      (RFB messages are 4-12 bytes; this fits ~80 K
 *                            queued events even at sustained kbd spam)
 *   slack      = ~3 MiB     (alignment + future growth)
 */

#ifndef NV_SHMEM_PROTO_H
#define NV_SHMEM_PROTO_H

#include <stdint.h>
#include <string.h>

#define NV_SHMEM_MAGIC      0x4D484E56u  /* "NVHM" little-endian */
#define NV_SHMEM_VERSION    1u

#define NV_SHMEM_TOTAL_BYTES (64u * 1024u * 1024u)
#define NV_SHMEM_HDR_BYTES   (4u   * 1024u)
#define NV_SHMEM_VIDEO_BYTES (60u  * 1024u * 1024u)
#define NV_SHMEM_INPUT_BYTES (1u   * 1024u * 1024u)

#define NV_SHMEM_VIDEO_OFF   (NV_SHMEM_HDR_BYTES)
#define NV_SHMEM_INPUT_OFF   (NV_SHMEM_VIDEO_OFF + NV_SHMEM_VIDEO_BYTES)

/* Sanity */
#if (NV_SHMEM_HDR_BYTES + NV_SHMEM_VIDEO_BYTES + NV_SHMEM_INPUT_BYTES) > NV_SHMEM_TOTAL_BYTES
#error "shmem layout exceeds total"
#endif

/* Record header — every framed message in either ring starts with this.
 * size==0 is a wrap marker: skip to the start of the ring on the next
 * read. Producer emits a wrap marker if the record wouldn't fit before
 * the ring tail. */
typedef struct {
    uint32_t size;     /* payload bytes that follow; 0 = wrap-around */
} NvShmemRecHdr;

/* Per-ring control fields. writer_seq / reader_seq monotonically count
 * BYTES emitted/consumed, modulo the ring's byte capacity. (Counting
 * bytes makes "is there data?" trivial: writer_seq != reader_seq.)
 *
 * Both sides treat these as atomic uint32 with release/acquire semantics.
 * We pad to 64 bytes to land each on its own cache line and avoid false
 * sharing between writer/reader. */
typedef struct {
    volatile uint32_t writer_seq;
    uint8_t  _pad_w[60];
    volatile uint32_t reader_seq;
    uint8_t  _pad_r[60];
} NvShmemRingCtrl;

/* The control header at offset 0. Fixed total of 4 KiB (page) so we
 * have room to grow without bumping the protocol version. */
typedef struct {
    uint32_t magic;        /* NV_SHMEM_MAGIC */
    uint32_t version;      /* NV_SHMEM_VERSION */
    uint32_t total_bytes;
    uint32_t hdr_bytes;
    uint32_t video_off;
    uint32_t video_bytes;
    uint32_t input_off;
    uint32_t input_bytes;

    /* Side liveness (host writes host_alive, guest writes guest_alive,
     * each side polls the other; lets either end detect the peer dying
     * without relying on TCP RST). 0 = dead, monotonic tick = alive. */
    volatile uint32_t host_alive_tick;
    volatile uint32_t guest_alive_tick;

    /* Guest desktop dimensions, written by guest at startup so the host
     * client knows what coordinate space input events should map into.
     * 0 means "not yet known" — host should wait. */
    volatile uint32_t guest_width;
    volatile uint32_t guest_height;

    uint8_t _pad_to_512[512 - 11*4];

    NvShmemRingCtrl video;   /* host ← guest */
    NvShmemRingCtrl input;   /* host → guest */

    /* remaining bytes of the page reserved */
} NvShmemHdr;

/* ───── Ring helpers (header-only, inline) ──────────────────────────
 *
 * Sequence numbers are monotonic uint32 byte counters. They wrap at
 * 4 GiB written, but since (writer_seq - reader_seq) ≤ ring capacity
 * (at most 60 MiB) the unsigned-difference math is always correct.
 *
 * Records can straddle the ring boundary via an explicit wrap marker
 * (a record with size==0): if the producer can't fit {hdr+payload}
 * in the contiguous bytes left until the ring's end, it writes a
 * wrap marker at the current position and advances writer_seq to the
 * next ring-start, then writes the actual record there. The consumer
 * sees size==0 and does the symmetric advance.
 */

/* In-ring offset from a byte sequence number. */
static inline uint32_t nv_shmem_ring_pos(uint32_t seq, uint32_t cap) {
    return seq % cap;
}

/* How many bytes are currently waiting to be read in this ring? */
static inline uint32_t nv_shmem_ring_used(uint32_t writer_seq, uint32_t reader_seq) {
    return writer_seq - reader_seq;
}

/* Bytes producer can still write before catching the consumer. We
 * keep one slot free so writer_seq == reader_seq unambiguously means
 * EMPTY (never FULL). */
static inline uint32_t nv_shmem_ring_free(uint32_t writer_seq,
                                          uint32_t reader_seq,
                                          uint32_t cap) {
    return cap - (writer_seq - reader_seq) - 1;
}

/* Compiler barriers (no CPU fence needed on x86_64, both sides x86). */
#if defined(__GNUC__) || defined(__clang__)
#  define NV_SHMEM_BARRIER() __atomic_thread_fence(__ATOMIC_SEQ_CST)
#  define NV_SHMEM_LOAD_ACQ(p)  __atomic_load_n((p), __ATOMIC_ACQUIRE)
#  define NV_SHMEM_STORE_REL(p, v) __atomic_store_n((p), (v), __ATOMIC_RELEASE)
#elif defined(_MSC_VER)
#  include <intrin.h>
#  define NV_SHMEM_BARRIER() _ReadWriteBarrier()
#  define NV_SHMEM_LOAD_ACQ(p)  (*(volatile uint32_t*)(p))
#  define NV_SHMEM_STORE_REL(p, v) do { _ReadWriteBarrier(); *(volatile uint32_t*)(p) = (v); } while(0)
#endif

/* Write one record (size + payload bytes) into the ring. ring_base
 * is the contiguous byte region of length cap. ctrl points at the
 * NvShmemRingCtrl for this ring. Returns 0 on success, -1 if there
 * isn't enough free space (caller can drop or retry). */
static inline int nv_shmem_write(uint8_t *ring_base, uint32_t cap,
                                 NvShmemRingCtrl *ctrl,
                                 const void *data, uint32_t size)
{
    if (size > cap - 8) return -1;  /* would never fit even on a fresh ring */

    uint32_t w = NV_SHMEM_LOAD_ACQ(&ctrl->writer_seq);
    uint32_t r = NV_SHMEM_LOAD_ACQ(&ctrl->reader_seq);
    uint32_t need = 4 + size;
    uint32_t pos = nv_shmem_ring_pos(w, cap);

    /* If the record + its header crosses the ring tail, emit a wrap
     * marker first, then place the actual record at offset 0. */
    uint32_t tail = cap - pos;
    uint32_t advance = 0;
    int wrap = 0;
    if (tail < need) {
        /* will need wrap marker at pos, payload at 0 */
        if (nv_shmem_ring_free(w, r, cap) < tail + need) return -1;
        wrap = 1;
        advance = tail;  /* skip rest of ring */
    } else {
        if (nv_shmem_ring_free(w, r, cap) < need) return -1;
    }

    if (wrap) {
        uint32_t zero = 0;
        memcpy(ring_base + pos, &zero, 4);
        pos = 0;
        w += advance;
    }
    memcpy(ring_base + pos, &size, 4);
    memcpy(ring_base + pos + 4, data, size);

    NV_SHMEM_STORE_REL(&ctrl->writer_seq, w + need);
    return 0;
}

/* Read one record. *out_size is set to record size, the bytes are
 * copied into out (max out_cap). Returns:
 *    1   = record returned
 *    0   = ring empty (no advance)
 *   -1   = out_cap too small (caller should grow buffer; reader_seq
 *          is NOT advanced so a retry with bigger buffer works)
 */
static inline int nv_shmem_read(uint8_t *ring_base, uint32_t cap,
                                NvShmemRingCtrl *ctrl,
                                void *out, uint32_t out_cap,
                                uint32_t *out_size)
{
    uint32_t r = NV_SHMEM_LOAD_ACQ(&ctrl->reader_seq);
    uint32_t w = NV_SHMEM_LOAD_ACQ(&ctrl->writer_seq);
    if (r == w) return 0;  /* empty */

    uint32_t pos = nv_shmem_ring_pos(r, cap);
    uint32_t size;
    memcpy(&size, ring_base + pos, 4);

    if (size == 0) {
        /* wrap marker — skip to start of ring */
        uint32_t advance = cap - pos;
        NV_SHMEM_STORE_REL(&ctrl->reader_seq, r + advance);
        /* recurse once at the wrapped position */
        return nv_shmem_read(ring_base, cap, ctrl, out, out_cap, out_size);
    }
    if (size > out_cap) {
        *out_size = size;
        return -1;
    }
    memcpy(out, ring_base + pos + 4, size);
    *out_size = size;
    NV_SHMEM_STORE_REL(&ctrl->reader_seq, r + 4 + size);
    return 1;
}

/* ───── Frame / dirty-tile protocol ────────────────────────────────
 *
 * Each video-ring record carries one FRAME message, which is a small
 * header followed by a flat array of NvFrameTile entries; each tile
 * is its own header followed by w*h*4 BGRA bytes (DXGI native).
 *
 *   record_size = sizeof(NvFrameHdr) + sum_i (sizeof(NvFrameTile) + w_i*h_i*4)
 *
 * The receiver iterates tile_count times: read tile header, read
 * tile_w*tile_h*4 bytes, blit into local framebuffer at (x, y).
 *
 * Producer hashes each TILE_SIZE×TILE_SIZE region of the new frame
 * and compares to the previous frame's hash table; only changed
 * tiles enter the message. Static desktop → tile_count=0, message
 * size = sizeof(NvFrameHdr) = 12 bytes.
 *
 * First frame after attach should be a "full keyframe" with all
 * tiles included so the receiver can paint a complete picture
 * regardless of when it joined.
 */
#define NV_TILE_SIZE          32u
#define NV_FRAME_MAGIC        0x4D415246u   /* "FRAM" */
#define NV_CURSOR_MAGIC       0x53525543u   /* "CURS" */

typedef struct {
    uint32_t magic;        /* NV_FRAME_MAGIC */
    uint32_t frame_seq;    /* monotonic; receiver may use to detect drops */
    uint16_t fb_width;     /* full framebuffer width  (px) */
    uint16_t fb_height;    /* full framebuffer height (px) */
    uint16_t tile_count;   /* number of NvFrameTile entries that follow */
    uint16_t flags;        /* bit 0 = keyframe (full-screen redraw) */
} NvFrameHdr;

#define NV_FRAME_FLAG_KEYFRAME  0x0001

typedef struct {
    uint16_t x;            /* tile origin X (px), aligned to NV_TILE_SIZE */
    uint16_t y;            /* tile origin Y (px), aligned to NV_TILE_SIZE */
    uint16_t w;            /* actual tile width  (≤ NV_TILE_SIZE) */
    uint16_t h;            /* actual tile height (≤ NV_TILE_SIZE) */
    /* followed by w*h*4 bytes of BGRA pixel data, row-major top-down */
} NvFrameTile;

#define NV_CURSOR_FLAG_VISIBLE  0x0001u
#define NV_CURSOR_FLAG_SHAPE    0x0002u

typedef struct {
    uint32_t magic;        /* NV_CURSOR_MAGIC */
    uint32_t cursor_seq;   /* monotonic; receiver may drop stale updates */
    uint16_t width;        /* cursor bitmap width; 0 for visibility-only */
    uint16_t height;       /* cursor bitmap height; 0 for visibility-only */
    uint16_t hot_x;        /* cursor hotspot X */
    uint16_t hot_y;        /* cursor hotspot Y */
    uint16_t flags;        /* bit 0 = visible, bit 1 = shape payload present */
    uint16_t reserved;
    /* followed by width*height*4 bytes of 32-bit ARGB8888 cursor pixels */
} NvCursorHdr;

#endif /* NV_SHMEM_PROTO_H */

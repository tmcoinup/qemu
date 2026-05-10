/*
 * QEMU framebuffer shared-memory display backend.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Linux-only `-display fb-shm[,id=...]` backend.  Exposes the guest
 * framebuffer to external processes through a single memfd plus an
 * eventfd doorbell, with optional rectangular region-of-interest
 * cropping.  See include/ui/fb-shm-abi.h for the wire format.
 *
 * Pipeline overview:
 *
 *   guest GPU device --> DisplaySurface (pixman_image_t)
 *           |
 *           v
 *      this backend                        +---------- consumer ----------+
 *      (DisplayChangeListener)             |  recvmsg() SCM_RIGHTS        |
 *           |                              |   memfd, eventfd             |
 *           |  pixman_image_composite()    |  mmap(memfd)                 |
 *           |  (ROI crop + format convert) |  poll(eventfd)               |
 *           v                              |  seqlock read of buf[i]      |
 *      memfd[buf[i]]  <-- atomic seqlock --|  pipe -> ffmpeg / NVENC      |
 *      eventfd kick   ---------------------+  (RTMP / UDP / RTP / file)   |
 *                                          +------------------------------+
 *
 * The DCL is refresh-driven: graphic_hw_update() is invoked at the
 * configured rate, then a single pixman composite copies the (possibly
 * cropped) frame into the inactive SHM slot.  No host-side encoding is
 * performed - we deliberately keep CPU cost in QEMU minimal so anti-cheat
 * sensitive workloads do not see a jitter spike from this hook.
 */

#include "qemu/osdep.h"
#include "qemu/atomic.h"
#include "qemu/error-report.h"
#include "qemu/main-loop.h"
#include "qemu/module.h"
#include "qemu/notify.h"
#include "qemu/sockets.h"
#include "qemu/timer.h"
#include "qapi/error.h"
#include "qom/object.h"
#include "qom/object_interfaces.h"
#include "sysemu/sysemu.h"
#include "ui/console.h"
#include "ui/fb-shm-abi.h"

#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <linux/memfd.h>

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC      0x0001U
#endif
#ifndef MFD_ALLOW_SEALING
#define MFD_ALLOW_SEALING 0x0002U
#endif

#ifndef F_ADD_SEALS
#define F_ADD_SEALS     1033
#define F_SEAL_SHRINK   0x0002
#define F_SEAL_GROW     0x0004
#endif

/* Compile-time guards on the wire format. */
QEMU_BUILD_BUG_ON(sizeof(FbShmHeader) > FB_SHM_HEADER_SIZE);
QEMU_BUILD_BUG_ON(FB_SHM_BUF_COUNT < 2);

#define FB_SHM_DEFAULT_RATE   30u
#define FB_SHM_MAX_RATE       240u
#define FB_SHM_MIN_RATE       1u
#define FB_SHM_MAX_DIM        16384u
#define FB_SHM_DEFAULT_RUNDIR "/run/qemu"

typedef struct FbShmClient FbShmClient;
typedef struct FbShmDisplay FbShmDisplay;

struct FbShmClient {
    FbShmDisplay *owner;
    int fd;
    bool hello_done;            /* HELLO seen → eligible for broadcasts   */
    bool wants_resize_notify;   /* HELLO opted into NOTIFY_RESIZED        */
    QLIST_ENTRY(FbShmClient) next;
};

struct FbShmDisplay {
    /* DCL bits */
    DisplayChangeListener dcl;
    QemuConsole *con;

    /* configuration */
    char *id;
    char *sock_path;
    uint32_t cfg_x, cfg_y;
    uint32_t cfg_w, cfg_h;       /* 0 means "track source dim" */
    uint32_t target_fps;
    bool blend_cursor;            /* reserved for future use     */

    /* SHM state */
    int memfd;
    int wake_eventfd;
    void *shm;
    size_t map_size;
    FbShmHeader *hdr;
    uint8_t *slot[FB_SHM_BUF_COUNT];
    pixman_image_t *slot_img[FB_SHM_BUF_COUNT];
    uint32_t cur_w, cur_h;
    uint32_t cur_src_w, cur_src_h;
    int32_t cur_roi_x, cur_roi_y;
    uint64_t frame_seq;
    bool surface_present;

    /* control socket */
    int listen_fd;
    QLIST_HEAD(, FbShmClient) clients;
};

/* ------------------------------------------------------------------ */
/* helpers                                                             */
/* ------------------------------------------------------------------ */

static void fb_shm_broadcast_resize(FbShmDisplay *d);

static uint64_t fb_shm_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void fb_shm_resolve_roi(FbShmDisplay *d, uint32_t sw, uint32_t sh,
                               uint32_t *out_w, uint32_t *out_h,
                               int32_t *out_x, int32_t *out_y)
{
    uint32_t rx = d->cfg_x;
    uint32_t ry = d->cfg_y;
    uint32_t rw = d->cfg_w ? d->cfg_w : sw;
    uint32_t rh = d->cfg_h ? d->cfg_h : sh;

    if (rx >= sw) rx = sw ? sw - 1 : 0;
    if (ry >= sh) ry = sh ? sh - 1 : 0;
    if (rx + rw > sw) rw = sw - rx;
    if (ry + rh > sh) rh = sh - ry;
    if (!rw) rw = 1;
    if (!rh) rh = 1;

    *out_x = (int32_t)rx;
    *out_y = (int32_t)ry;
    *out_w = rw;
    *out_h = rh;
}

static void fb_shm_release_mapping(FbShmDisplay *d)
{
    for (uint32_t i = 0; i < FB_SHM_BUF_COUNT; i++) {
        if (d->slot_img[i]) {
            pixman_image_unref(d->slot_img[i]);
            d->slot_img[i] = NULL;
        }
        d->slot[i] = NULL;
    }
    if (d->shm && d->shm != MAP_FAILED) {
        munmap(d->shm, d->map_size);
    }
    d->shm = NULL;
    d->hdr = NULL;
    d->map_size = 0;
    if (d->memfd >= 0) {
        close(d->memfd);
        d->memfd = -1;
    }
}

/* (Re)allocate the memfd backing store for ROI dimensions w x h. */
static int fb_shm_allocate(FbShmDisplay *d, uint32_t w, uint32_t h,
                           uint32_t sw, uint32_t sh,
                           int32_t roi_x, int32_t roi_y, Error **errp)
{
    if (w == 0 || h == 0 || w > FB_SHM_MAX_DIM || h > FB_SHM_MAX_DIM) {
        error_setg(errp, "fb-shm: invalid ROI %ux%u", w, h);
        return -1;
    }

    fb_shm_release_mapping(d);

    size_t buf_size = (size_t)w * h * 4;
    size_t map_size = FB_SHM_HEADER_SIZE + (size_t)FB_SHM_BUF_COUNT * buf_size;

    int fd = memfd_create("qemu-fb-shm", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) {
        error_setg_errno(errp, errno, "fb-shm: memfd_create failed");
        return -1;
    }
    if (ftruncate(fd, map_size) < 0) {
        error_setg_errno(errp, errno, "fb-shm: ftruncate failed");
        close(fd);
        return -1;
    }
    /* Lock the size: external consumer can mmap() with confidence. */
    (void)fcntl(fd, F_ADD_SEALS, F_SEAL_GROW | F_SEAL_SHRINK);

    void *p = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        error_setg_errno(errp, errno, "fb-shm: mmap failed");
        close(fd);
        return -1;
    }
    memset(p, 0, FB_SHM_HEADER_SIZE);

    d->memfd = fd;
    d->shm = p;
    d->map_size = map_size;
    d->hdr = (FbShmHeader *)p;
    d->cur_w = w;
    d->cur_h = h;
    d->cur_src_w = sw;
    d->cur_src_h = sh;
    d->cur_roi_x = roi_x;
    d->cur_roi_y = roi_y;

    /* Header init (visible to consumer once we publish frame_seq>=1). */
    FbShmHeader *hdr = d->hdr;
    hdr->magic = FB_SHM_MAGIC;
    hdr->version = FB_SHM_VERSION;
    hdr->header_size = FB_SHM_HEADER_SIZE;
    hdr->buf_count = FB_SHM_BUF_COUNT;
    hdr->buf_size = buf_size;
    hdr->map_size = map_size;
    for (uint32_t i = 0; i < FB_SHM_BUF_COUNT; i++) {
        hdr->buf_offset[i] = FB_SHM_HEADER_SIZE + (uint64_t)i * buf_size;
        d->slot[i] = (uint8_t *)p + hdr->buf_offset[i];
        d->slot_img[i] = pixman_image_create_bits_no_clear(
            PIXMAN_x8r8g8b8, w, h, (uint32_t *)d->slot[i], (int)(w * 4));
        if (!d->slot_img[i]) {
            error_setg(errp, "fb-shm: pixman dest image alloc failed");
            fb_shm_release_mapping(d);
            return -1;
        }
    }
    hdr->width = w;
    hdr->height = h;
    hdr->stride = w * 4;
    hdr->fourcc = FB_SHM_FOURCC_BGR0;
    hdr->bpp = 32;
    hdr->target_fps = d->target_fps;
    hdr->src_width = sw;
    hdr->src_height = sh;
    hdr->roi_x = roi_x;
    hdr->roi_y = roi_y;
    hdr->damage_x = 0;
    hdr->damage_y = 0;
    hdr->damage_w = (int32_t)w;
    hdr->damage_h = (int32_t)h;
    hdr->active_idx = 0;
    hdr->flags = FB_SHM_FLAG_RUNNING | FB_SHM_FLAG_RESIZED;
    hdr->frame_seq = 0;
    hdr->ts_ns = fb_shm_now_ns();

    /* Push the new memfd / eventfd to every opted-in client; without this,
     * existing consumers keep their old mapping and observe a frozen
     * frame_seq even though we are now writing to a different memfd. */
    fb_shm_broadcast_resize(d);
    return 0;
}

/* ------------------------------------------------------------------ */
/* control socket                                                      */
/* ------------------------------------------------------------------ */

static void fb_shm_client_drop(FbShmClient *c)
{
    qemu_set_fd_handler(c->fd, NULL, NULL, NULL);
    close(c->fd);
    QLIST_REMOVE(c, next);
    g_free(c);
}

static int fb_shm_send_fds(int fd, const FbShmCtlAck *ack,
                           const int *fds, int nfds)
{
    struct iovec iov = { .iov_base = (void *)ack, .iov_len = sizeof(*ack) };
    char cbuf[CMSG_SPACE(sizeof(int) * 2)];
    struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
    };
    if (fds && nfds > 0) {
        msg.msg_control = cbuf;
        msg.msg_controllen = CMSG_SPACE(sizeof(int) * nfds);
        struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
        cm->cmsg_level = SOL_SOCKET;
        cm->cmsg_type = SCM_RIGHTS;
        cm->cmsg_len = CMSG_LEN(sizeof(int) * nfds);
        memcpy(CMSG_DATA(cm), fds, sizeof(int) * nfds);
    }
    ssize_t r;
    do {
        r = sendmsg(fd, &msg, MSG_NOSIGNAL);
    } while (r < 0 && errno == EINTR);
    return (r == (ssize_t)sizeof(*ack)) ? 0 : -1;
}

static void fb_shm_handle_hello(FbShmDisplay *d, FbShmClient *c,
                                const FbShmCtlReq *req)
{
    /* Mark the client eligible for broadcasts BEFORE we send the ack: a
     * concurrent reallocate from the refresh tick is fine, the client will
     * just see the HELLO ack followed by a NOTIFY_RESIZED carrying the same
     * (or newer) fds. */
    c->hello_done = true;
    c->wants_resize_notify =
        (req->flags & FB_SHM_HELLO_F_RESIZE_NOTIFY) != 0;

    FbShmCtlAck ack = {
        .magic  = FB_SHM_MAGIC,
        .op     = FB_SHM_CTL_HELLO,
        .status = d->shm ? FB_SHM_CTL_OK : FB_SHM_CTL_EBUSY,
        .shm_size = (uint32_t)d->map_size,
        .width  = d->cur_w,
        .height = d->cur_h,
        .fourcc = FB_SHM_FOURCC_BGR0,
        .bpp    = 32,
    };
    int fds[2] = { d->memfd, d->wake_eventfd };
    int nfds = (d->memfd >= 0 && d->wake_eventfd >= 0) ? 2 : 0;
    if (fb_shm_send_fds(c->fd, &ack, fds, nfds) < 0) {
        fb_shm_client_drop(c);
    }
}

/* Push the current { memfd, wake_eventfd } pair to every HELLO-completed
 * client that opted into resize notifications.  Called from fb_shm_allocate
 * after the new mapping is fully published.  Failed sends drop the client. */
static void fb_shm_broadcast_resize(FbShmDisplay *d)
{
    if (d->memfd < 0 || d->wake_eventfd < 0) {
        return;
    }
    FbShmCtlAck ack = {
        .magic  = FB_SHM_MAGIC,
        .op     = FB_SHM_CTL_NOTIFY_RESIZED,
        .status = FB_SHM_CTL_OK,
        .shm_size = (uint32_t)d->map_size,
        .width  = d->cur_w,
        .height = d->cur_h,
        .fourcc = FB_SHM_FOURCC_BGR0,
        .bpp    = 32,
    };
    int fds[2] = { d->memfd, d->wake_eventfd };
    int recipients = 0;
    FbShmClient *c, *cn;
    QLIST_FOREACH_SAFE(c, &d->clients, next, cn) {
        if (!c->hello_done || !c->wants_resize_notify) {
            continue;
        }
        if (fb_shm_send_fds(c->fd, &ack, fds, 2) < 0) {
            warn_report("fb-shm: NOTIFY_RESIZED send failed (errno=%d %s); "
                        "dropping client fd=%d",
                        errno, strerror(errno), c->fd);
            fb_shm_client_drop(c);
        } else {
            recipients++;
        }
    }
    if (recipients > 0) {
        info_report("fb-shm: broadcast NOTIFY_RESIZED to %d client(s) "
                    "(%ux%u, shm_size=%zu)",
                    recipients, d->cur_w, d->cur_h, d->map_size);
    }
}

static void fb_shm_handle_set_roi(FbShmDisplay *d, FbShmClient *c,
                                  const FbShmCtlReq *req)
{
    if (req->w > FB_SHM_MAX_DIM || req->h > FB_SHM_MAX_DIM) {
        FbShmCtlAck ack = { .magic = FB_SHM_MAGIC, .op = req->op,
                            .status = FB_SHM_CTL_EINVAL };
        fb_shm_send_fds(c->fd, &ack, NULL, 0);
        return;
    }
    d->cfg_x = (uint32_t)(req->x < 0 ? 0 : req->x);
    d->cfg_y = (uint32_t)(req->y < 0 ? 0 : req->y);
    d->cfg_w = req->w;
    d->cfg_h = req->h;

    FbShmCtlAck ack = { .magic = FB_SHM_MAGIC, .op = req->op,
                        .status = FB_SHM_CTL_OK,
                        .shm_size = (uint32_t)d->map_size,
                        .width = d->cur_w, .height = d->cur_h,
                        .fourcc = FB_SHM_FOURCC_BGR0, .bpp = 32 };
    fb_shm_send_fds(c->fd, &ack, NULL, 0);
}

static void fb_shm_handle_set_rate(FbShmDisplay *d, FbShmClient *c,
                                   const FbShmCtlReq *req)
{
    uint32_t r = req->rate_hz;
    if (r < FB_SHM_MIN_RATE) r = FB_SHM_MIN_RATE;
    if (r > FB_SHM_MAX_RATE) r = FB_SHM_MAX_RATE;
    d->target_fps = r;
    if (d->hdr) {
        d->hdr->target_fps = r;
    }
    update_displaychangelistener(&d->dcl, 1000 / r);

    FbShmCtlAck ack = { .magic = FB_SHM_MAGIC, .op = req->op,
                        .status = FB_SHM_CTL_OK };
    fb_shm_send_fds(c->fd, &ack, NULL, 0);
}

static void fb_shm_client_read(void *opaque)
{
    FbShmClient *c = opaque;
    FbShmDisplay *d = c->owner;
    FbShmCtlReq req;
    ssize_t r;
    do {
        r = recv(c->fd, &req, sizeof(req), MSG_DONTWAIT);
    } while (r < 0 && errno == EINTR);
    if (r == 0 || (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
        fb_shm_client_drop(c);
        return;
    }
    if (r != (ssize_t)sizeof(req) || req.magic != FB_SHM_MAGIC) {
        FbShmCtlAck ack = { .magic = FB_SHM_MAGIC, .op = 0,
                            .status = FB_SHM_CTL_EINVAL };
        fb_shm_send_fds(c->fd, &ack, NULL, 0);
        return;
    }

    switch (req.op) {
    case FB_SHM_CTL_HELLO:
        fb_shm_handle_hello(d, c, &req);
        break;
    case FB_SHM_CTL_SET_ROI:
        fb_shm_handle_set_roi(d, c, &req);
        break;
    case FB_SHM_CTL_SET_RATE:
        fb_shm_handle_set_rate(d, c, &req);
        break;
    case FB_SHM_CTL_BYE:
        fb_shm_client_drop(c);
        break;
    default: {
        FbShmCtlAck ack = { .magic = FB_SHM_MAGIC, .op = req.op,
                            .status = FB_SHM_CTL_EUNSUPPORTED };
        fb_shm_send_fds(c->fd, &ack, NULL, 0);
        break;
    }
    }
}

static void fb_shm_listener_accept(void *opaque)
{
    FbShmDisplay *d = opaque;
    int cfd;
    do {
        cfd = accept4(d->listen_fd, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
    } while (cfd < 0 && errno == EINTR);
    if (cfd < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            warn_report("fb-shm: accept failed: %s", strerror(errno));
        }
        return;
    }
    FbShmClient *c = g_new0(FbShmClient, 1);
    c->owner = d;
    c->fd = cfd;
    QLIST_INSERT_HEAD(&d->clients, c, next);
    qemu_set_fd_handler(cfd, fb_shm_client_read, NULL, c);
}

static int fb_shm_open_listener(FbShmDisplay *d, Error **errp)
{
    /* Make sure /run/qemu exists when using the default path. */
    g_autofree char *parent = g_path_get_dirname(d->sock_path);
    if (g_mkdir_with_parents(parent, 0750) < 0 && errno != EEXIST) {
        warn_report("fb-shm: cannot create %s: %s", parent, strerror(errno));
    }

    struct sockaddr_un sa = { .sun_family = AF_UNIX };
    if (strlen(d->sock_path) >= sizeof(sa.sun_path)) {
        error_setg(errp, "fb-shm: socket path too long: %s", d->sock_path);
        return -1;
    }
    g_strlcpy(sa.sun_path, d->sock_path, sizeof(sa.sun_path));
    unlink(sa.sun_path);

    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) {
        error_setg_errno(errp, errno, "fb-shm: socket() failed");
        return -1;
    }
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        error_setg_errno(errp, errno, "fb-shm: bind(%s) failed", sa.sun_path);
        close(fd);
        return -1;
    }
    /* World-readable so non-root consumers can connect; tighten if needed. */
    chmod(sa.sun_path, 0660);
    if (listen(fd, 16) < 0) {
        error_setg_errno(errp, errno, "fb-shm: listen() failed");
        close(fd);
        unlink(sa.sun_path);
        return -1;
    }
    d->listen_fd = fd;
    qemu_set_fd_handler(fd, fb_shm_listener_accept, NULL, d);
    return 0;
}

/* ------------------------------------------------------------------ */
/* DisplayChangeListener ops                                           */
/* ------------------------------------------------------------------ */

static void fb_shm_gfx_switch(DisplayChangeListener *dcl,
                              DisplaySurface *new_surface)
{
    FbShmDisplay *d = container_of(dcl, FbShmDisplay, dcl);
    if (!new_surface) {
        d->surface_present = false;
        return;
    }
    d->surface_present = !surface_is_placeholder(new_surface);
    /* Defer real allocation until next refresh tick where we have the
     * source dimensions stable.  We just remember them here. */
    uint32_t sw = surface_width(new_surface);
    uint32_t sh = surface_height(new_surface);
    if (sw == 0 || sh == 0) {
        return;
    }
    uint32_t rw, rh;
    int32_t rx, ry;
    fb_shm_resolve_roi(d, sw, sh, &rw, &rh, &rx, &ry);
    if (rw != d->cur_w || rh != d->cur_h ||
        sw != d->cur_src_w || sh != d->cur_src_h ||
        rx != d->cur_roi_x || ry != d->cur_roi_y) {
        Error *err = NULL;
        if (fb_shm_allocate(d, rw, rh, sw, sh, rx, ry, &err) < 0) {
            warn_report_err(err);
            return;
        }
    }
}

static void fb_shm_gfx_update(DisplayChangeListener *dcl,
                              int x, int y, int w, int h)
{
    /* No-op: we are refresh-driven and re-grab the whole ROI on tick.
     * Tracking dirty rects would only matter for partial-frame encoders,
     * and the consumer reads the damage_* fields directly. */
    (void)dcl; (void)x; (void)y; (void)w; (void)h;
}

static void fb_shm_commit_frame(FbShmDisplay *d, DisplaySurface *surface)
{
    uint32_t sw = surface_width(surface);
    uint32_t sh = surface_height(surface);

    uint32_t rw, rh;
    int32_t rx, ry;
    fb_shm_resolve_roi(d, sw, sh, &rw, &rh, &rx, &ry);

    if (!d->shm || rw != d->cur_w || rh != d->cur_h ||
        sw != d->cur_src_w || sh != d->cur_src_h ||
        rx != d->cur_roi_x || ry != d->cur_roi_y) {
        Error *err = NULL;
        if (fb_shm_allocate(d, rw, rh, sw, sh, rx, ry, &err) < 0) {
            warn_report_err(err);
            return;
        }
    }

    FbShmHeader *hdr = d->hdr;
    uint32_t cur_idx = qatomic_load_acquire(&hdr->active_idx);
    uint32_t next_idx = (cur_idx + 1) % FB_SHM_BUF_COUNT;

    /*
     * pixman_image_composite32 covers every pixel format QEMU can hand us
     * (x8r8g8b8, r5g6b5, ...) and clips to ROI in one call.  The destination
     * is always BGR0 (= pixman_x8r8g8b8 on little-endian).
     */
    pixman_image_composite32(PIXMAN_OP_SRC,
                             surface->image, NULL, d->slot_img[next_idx],
                             rx, ry,        /* src offset (= ROI origin) */
                             0, 0,          /* mask (unused)             */
                             0, 0,          /* dst offset                */
                             (int)rw, (int)rh);

    hdr->damage_x = 0;
    hdr->damage_y = 0;
    hdr->damage_w = (int32_t)rw;
    hdr->damage_h = (int32_t)rh;
    hdr->ts_ns = fb_shm_now_ns();
    qatomic_store_release(&hdr->active_idx, next_idx);

    d->frame_seq++;
    qatomic_store_release(&hdr->frame_seq, d->frame_seq);

    /* doorbell */
    if (d->wake_eventfd >= 0) {
        uint64_t v = 1;
        ssize_t r;
        do {
            r = write(d->wake_eventfd, &v, sizeof(v));
        } while (r < 0 && errno == EINTR);
        (void)r;   /* full ringbuffer just means consumer hasn't drained */
    }
}

static void fb_shm_refresh(DisplayChangeListener *dcl)
{
    FbShmDisplay *d = container_of(dcl, FbShmDisplay, dcl);
    graphic_hw_update(dcl->con);
    if (!d->surface_present) {
        return;
    }
    DisplaySurface *surface = qemu_console_surface(dcl->con);
    if (!surface || surface_is_placeholder(surface)) {
        return;
    }
    fb_shm_commit_frame(d, surface);
}

static const DisplayChangeListenerOps fb_shm_ops = {
    .dpy_name        = "fb-shm",
    .dpy_refresh     = fb_shm_refresh,
    .dpy_gfx_update  = fb_shm_gfx_update,
    .dpy_gfx_switch  = fb_shm_gfx_switch,
};

/* ------------------------------------------------------------------ */
/* shared create / destroy                                             */
/* ------------------------------------------------------------------ */

typedef struct FbShmConfig {
    const char *id;          /* must outlive the call (caller-owned)    */
    const char *sock_path;   /* may be NULL -> derived from id          */
    uint32_t x, y, w, h;     /* ROI; 0 = track full surface             */
    uint32_t rate;           /* target Hz                               */
    bool blend_cursor;
} FbShmConfig;

static char *fb_shm_default_id(void)
{
    return g_strdup_printf("qemu-%d", (int)getpid());
}

static char *fb_shm_default_sock_path(const char *id)
{
    return g_strdup_printf("%s/fb-%s.sock", FB_SHM_DEFAULT_RUNDIR, id);
}

/* Allocates an FbShmDisplay attached to the primary graphic console,
 * opens the control socket, registers the DCL.  On error returns NULL
 * and sets *errp; the half-built object is freed.  Caller owns the
 * returned pointer (no global registry kept here). */
static FbShmDisplay *fb_shm_create(const FbShmConfig *cfg, Error **errp)
{
    QemuConsole *con = qemu_console_lookup_by_index(0);
    if (!con || !qemu_console_is_graphic(con)) {
        error_setg(errp, "fb-shm: no graphic console available");
        return NULL;
    }

    FbShmDisplay *d = g_new0(FbShmDisplay, 1);
    QLIST_INIT(&d->clients);
    d->memfd = -1;
    d->wake_eventfd = -1;
    d->listen_fd = -1;
    d->con = con;
    d->dcl.con = con;
    d->dcl.ops = &fb_shm_ops;

    d->id = cfg->id ? g_strdup(cfg->id) : fb_shm_default_id();
    d->sock_path = cfg->sock_path ? g_strdup(cfg->sock_path)
                                  : fb_shm_default_sock_path(d->id);
    d->cfg_x = cfg->x;
    d->cfg_y = cfg->y;
    d->cfg_w = cfg->w;
    d->cfg_h = cfg->h;
    d->target_fps = cfg->rate ? cfg->rate : FB_SHM_DEFAULT_RATE;
    if (d->target_fps < FB_SHM_MIN_RATE) d->target_fps = FB_SHM_MIN_RATE;
    if (d->target_fps > FB_SHM_MAX_RATE) d->target_fps = FB_SHM_MAX_RATE;
    d->blend_cursor = cfg->blend_cursor;

    d->wake_eventfd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (d->wake_eventfd < 0) {
        error_setg_errno(errp, errno, "fb-shm: eventfd() failed");
        goto err;
    }

    if (fb_shm_open_listener(d, errp) < 0) {
        goto err;
    }

    d->dcl.update_interval = 1000 / d->target_fps;
    register_displaychangelistener(&d->dcl);

    info_report("fb-shm: id=%s sock=%s rate=%uHz roi=%ux%u@%d,%d",
                d->id, d->sock_path, d->target_fps,
                d->cfg_w, d->cfg_h, d->cfg_x, d->cfg_y);
    return d;

err:
    if (d->wake_eventfd >= 0) close(d->wake_eventfd);
    g_free(d->id);
    g_free(d->sock_path);
    g_free(d);
    return NULL;
}

static void fb_shm_destroy(FbShmDisplay *d)
{
    if (!d) return;
    /* drop clients first */
    FbShmClient *c, *cn;
    QLIST_FOREACH_SAFE(c, &d->clients, next, cn) {
        fb_shm_client_drop(c);
    }
    if (d->listen_fd >= 0) {
        qemu_set_fd_handler(d->listen_fd, NULL, NULL, NULL);
        close(d->listen_fd);
        if (d->sock_path) unlink(d->sock_path);
    }
    if (d->dcl.ds) {
        unregister_displaychangelistener(&d->dcl);
    }
    fb_shm_release_mapping(d);
    if (d->wake_eventfd >= 0) close(d->wake_eventfd);
    g_free(d->id);
    g_free(d->sock_path);
    g_free(d);
}

/* ------------------------------------------------------------------ */
/* QemuDisplay registration  (-display fb-shm,...)                     */
/* ------------------------------------------------------------------ */

static void fb_shm_init(DisplayState *ds, DisplayOptions *opts)
{
    (void)ds;
    const DisplayFbShm *o = &opts->u.fb_shm;
    FbShmConfig cfg = {
        .id          = o->id,
        .sock_path   = o->path,
        .x           = o->has_x      ? o->x      : 0,
        .y           = o->has_y      ? o->y      : 0,
        .w           = o->has_width  ? o->width  : 0,
        .h           = o->has_height ? o->height : 0,
        .rate        = o->has_rate   ? o->rate   : 0,
        .blend_cursor = o->has_cursor && o->cursor,
    };
    Error *err = NULL;
    if (!fb_shm_create(&cfg, &err)) {
        error_reportf_err(err, "fb-shm: ");
        exit(1);
    }
}

static QemuDisplay qemu_display_fb_shm = {
    .type = DISPLAY_TYPE_FB_SHM,
    .init = fb_shm_init,
};

static void register_fb_shm(void)
{
    qemu_display_register(&qemu_display_fb_shm);
}

type_init(register_fb_shm);

/* ------------------------------------------------------------------ */
/* user-creatable QOM object  (-object fb-shm,id=...,...)              */
/*                                                                     */
/* Coexists with any -display backend (sdl/gtk/none/vnc).  Whereas the */
/* DisplayType path consumes the -display slot, this path is purely    */
/* additive: it registers a second DCL on the same primary console, so */
/* SDL can render to a window AND fb-shm exports raw frames.           */
/* ------------------------------------------------------------------ */

#define TYPE_FB_SHM_EXPORT "fb-shm"
OBJECT_DECLARE_SIMPLE_TYPE(FbShmExport, FB_SHM_EXPORT)

struct FbShmExport {
    Object parent;
    /* properties (set before complete()) */
    char *path;
    uint32_t x, y, width, height;
    uint32_t rate;
    bool cursor;
    /* runtime */
    Notifier machine_done_notifier;
    bool deferred_pending;
    FbShmDisplay *display;
};

static void fb_shm_export_get_path(Object *obj, Visitor *v,
                                   const char *name, void *opaque,
                                   Error **errp)
{
    FbShmExport *o = FB_SHM_EXPORT(obj);
    visit_type_str(v, name, &o->path, errp);
}

static void fb_shm_export_set_path(Object *obj, Visitor *v,
                                   const char *name, void *opaque,
                                   Error **errp)
{
    FbShmExport *o = FB_SHM_EXPORT(obj);
    char *s = NULL;
    if (!visit_type_str(v, name, &s, errp)) return;
    g_free(o->path);
    o->path = s;
}

static void fb_shm_export_machine_done(Notifier *n, void *unused)
{
    FbShmExport *o = container_of(n, FbShmExport, machine_done_notifier);
    if (!o->deferred_pending) {
        return;
    }
    o->deferred_pending = false;
    const char *id = object_get_canonical_path_component(OBJECT(o));
    FbShmConfig cfg = {
        .id          = id,
        .sock_path   = o->path,
        .x           = o->x,
        .y           = o->y,
        .w           = o->width,
        .h           = o->height,
        .rate        = o->rate,
        .blend_cursor = o->cursor,
    };
    Error *err = NULL;
    o->display = fb_shm_create(&cfg, &err);
    if (err) {
        /* machine_init_done notifiers can't propagate errors back to the
         * user, so warn loudly and let QEMU keep running. */
        warn_report_err(err);
    }
}

static void fb_shm_export_complete(UserCreatable *uc, Error **errp)
{
    /* Defer real registration until the machine has finished initialising,
     * because -object is parsed before VGA / virtio-gpu create their
     * consoles. */
    FbShmExport *o = FB_SHM_EXPORT(uc);
    if (o->deferred_pending || o->display) {
        error_setg(errp, "fb-shm: already realised");
        return;
    }
    o->machine_done_notifier.notify = fb_shm_export_machine_done;
    o->deferred_pending = true;
    qemu_add_machine_init_done_notifier(&o->machine_done_notifier);
}

static void fb_shm_export_instance_finalize(Object *obj)
{
    FbShmExport *o = FB_SHM_EXPORT(obj);
    if (o->deferred_pending) {
        notifier_remove(&o->machine_done_notifier);
        o->deferred_pending = false;
    }
    fb_shm_destroy(o->display);
    o->display = NULL;
    g_free(o->path);
}

/* per-field uint32 visitors - QEMU 9.2 has no offset-based uint32 prop helper
 * so we generate trivial accessors via macro. */

#define FB_SHM_UINT32_PROP(NAME, FIELD)                                       \
static void fb_shm_export_get_##FIELD(Object *obj, Visitor *v,                \
                                      const char *name, void *opaque,        \
                                      Error **errp) {                         \
    FbShmExport *o = FB_SHM_EXPORT(obj);                                       \
    visit_type_uint32(v, name, &o->FIELD, errp);                               \
}                                                                              \
static void fb_shm_export_set_##FIELD(Object *obj, Visitor *v,                \
                                      const char *name, void *opaque,        \
                                      Error **errp) {                         \
    FbShmExport *o = FB_SHM_EXPORT(obj);                                       \
    visit_type_uint32(v, name, &o->FIELD, errp);                               \
}

FB_SHM_UINT32_PROP("x",      x)
FB_SHM_UINT32_PROP("y",      y)
FB_SHM_UINT32_PROP("width",  width)
FB_SHM_UINT32_PROP("height", height)
FB_SHM_UINT32_PROP("rate",   rate)

static void fb_shm_export_get_cursor(Object *obj, Visitor *v,
                                     const char *name, void *opaque,
                                     Error **errp)
{
    FbShmExport *o = FB_SHM_EXPORT(obj);
    visit_type_bool(v, name, &o->cursor, errp);
}
static void fb_shm_export_set_cursor(Object *obj, Visitor *v,
                                     const char *name, void *opaque,
                                     Error **errp)
{
    FbShmExport *o = FB_SHM_EXPORT(obj);
    visit_type_bool(v, name, &o->cursor, errp);
}

static void fb_shm_export_class_init(ObjectClass *oc, void *data)
{
    UserCreatableClass *ucc = USER_CREATABLE_CLASS(oc);
    ucc->complete = fb_shm_export_complete;

    object_class_property_add(oc, "path", "string",
                              fb_shm_export_get_path,
                              fb_shm_export_set_path, NULL, NULL);
    object_class_property_add(oc, "x", "uint32",
                              fb_shm_export_get_x,
                              fb_shm_export_set_x, NULL, NULL);
    object_class_property_add(oc, "y", "uint32",
                              fb_shm_export_get_y,
                              fb_shm_export_set_y, NULL, NULL);
    object_class_property_add(oc, "width", "uint32",
                              fb_shm_export_get_width,
                              fb_shm_export_set_width, NULL, NULL);
    object_class_property_add(oc, "height", "uint32",
                              fb_shm_export_get_height,
                              fb_shm_export_set_height, NULL, NULL);
    object_class_property_add(oc, "rate", "uint32",
                              fb_shm_export_get_rate,
                              fb_shm_export_set_rate, NULL, NULL);
    object_class_property_add(oc, "cursor", "bool",
                              fb_shm_export_get_cursor,
                              fb_shm_export_set_cursor, NULL, NULL);
}

static const TypeInfo fb_shm_export_info = {
    .name = TYPE_FB_SHM_EXPORT,
    .parent = TYPE_OBJECT,
    .class_init = fb_shm_export_class_init,
    .instance_size = sizeof(FbShmExport),
    .instance_finalize = fb_shm_export_instance_finalize,
    .interfaces = (InterfaceInfo[]) {
        { TYPE_USER_CREATABLE },
        { }
    }
};

static void fb_shm_export_register_types(void)
{
    type_register_static(&fb_shm_export_info);
}

type_init(fb_shm_export_register_types)

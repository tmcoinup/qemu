/*
 * QEMU framebuffer shared-memory display backend.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Cross-host `-display fb-shm[,id=...]` backend.  Exposes the guest
 * framebuffer to external processes through shared memory plus a host-native
 * wakeup primitive, with optional rectangular region-of-interest cropping.
 * See include/ui/fb-shm-abi.h for the wire format.
 *
 * Pipeline overview:
 *
 *   guest GPU device --> DisplaySurface (pixman_image_t)
 *           |
 *           v
 *      this backend                        +---------- consumer ----------+
 *      (DisplayChangeListener)             |  Linux: SCM_RIGHTS fds       |
 *           |                              |  Win32: mapping/event names  |
 *           |  pixman_image_composite()    |  mmap(memfd)                 |
 *           |  (ROI crop + format convert) |  poll(eventfd)               |
 *           v                              |  seqlock read of buf[i]      |
 *      shm[buf[i]]    <-- atomic seqlock --|  pipe -> ffmpeg / NVENC      |
 *      doorbell       ---------------------+  (RTMP / UDP / RTP / file)   |
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
#ifdef CONFIG_OPENGL
#include "ui/egl-helpers.h"
#endif

#ifndef _WIN32
# include <sys/eventfd.h>
# include <sys/mman.h>
# include <sys/socket.h>
# include <sys/un.h>
# include <linux/memfd.h>
#else
# include <windows.h>
# ifdef CONFIG_OPENGL
#  include <d3d11.h>
#  include <dxgi1_2.h>
# endif
#endif

#ifdef CONFIG_OPENGL
#define FB_SHM_GL_PBO_COUNT 3

typedef struct FbShmGlPbo {
    GLuint id;
    GLsync fence;
    size_t bytes;
    uint32_t w;
    uint32_t h;
    bool pending;
} FbShmGlPbo;
#endif

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
#ifndef _WIN32
# define FB_SHM_DEFAULT_RUNDIR "/run/qemu"
#else
# define FB_SHM_DEFAULT_RUNDIR "."
#endif

typedef struct FbShmClient FbShmClient;
typedef struct FbShmDisplay FbShmDisplay;

struct FbShmClient {
    FbShmDisplay *owner;
    int fd;
    bool hello_done;            /* HELLO seen → eligible for broadcasts   */
    bool wants_resize_notify;   /* HELLO opted into NOTIFY_RESIZED        */
    bool wants_win32_names;      /* HELLO requested Win32 name payload     */
    bool wants_gpu_frames;       /* HELLO 订阅 GPU resident frame 通知      */
    bool gpu_required;           /* 客户端要求 GPU 路径，不接受 SHM 回退    */
    bool linked;                /* present in owner->clients              */
    bool dropping;              /* fd removed; waiting for deferred free  */
#ifdef _WIN32
    HANDLE wake_event;           /* 每个客户端独立事件，避免多消费者抢同一 doorbell */
    char *wake_event_name;
#endif
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
    uint32_t target_fps;         /* effective DCL tick rate       */
    uint32_t shm_target_fps;     /* SHM/CPU readback publish rate */
    uint32_t gpu_target_fps;     /* GPU metadata publish rate     */
    bool blend_cursor;            /* reserved for future use     */

    /* SHM state */
    void *shm;
    size_t map_size;
    FbShmHeader *hdr;
    uint8_t *slot[FB_SHM_BUF_COUNT];
    pixman_image_t *slot_img[FB_SHM_BUF_COUNT];
    uint32_t cap_w, cap_h;       /* backing-slot capacity, never ROI-only  */
    size_t cap_buf_size;
    uint32_t cur_w, cur_h;
    uint32_t cur_src_w, cur_src_h;
    int32_t cur_roi_x, cur_roi_y;
    uint64_t frame_seq;
    bool surface_present;

#ifndef _WIN32
    int memfd;
    int wake_eventfd;
#else
    HANDLE map_handle;
    char *map_name;
    uint32_t map_generation;
#endif

#ifdef CONFIG_OPENGL
    /*
     * GL scanout 兼容路径：
     *
     * virtio-vga-gl/virgl 不再把画面先落到 CPU 可见 DisplaySurface，
     * 而是把 texture 直接交给 GL 前端。fb-shm 的消费者仍然需要 BGR0
     * memfd，所以这里为 fb-shm 自己创建一个共享 GL context，把 texture
     * blit 到私有 FBO，再 glReadPixels 到当前 inactive SHM slot。
     *
     * 这条路径只在收到 dpy_gl_scanout_texture() 后启用；普通 virtio-vga
     * 仍然走原来的 pixman/DisplaySurface 路径。
     */
    bool gl_scanout;
    bool gl_y0_top;
    bool gl_warned_context;
    uint32_t gl_backing_id;
    uint32_t gl_backing_w, gl_backing_h;
    uint32_t gl_x, gl_y, gl_w, gl_h;
    uint64_t gl_last_frame_ns;
    uint64_t shm_last_frame_ns;
    uint64_t gpu_frame_seq;
    QEMUGLContext gl_ctx;
    egl_fb gl_guest_fb;
    egl_fb gl_blit_fb;
    QemuDmaBuf *gl_dmabuf;
    DisplaySurface *gl_slot_surface[FB_SHM_BUF_COUNT];
    bool gl_pbo_checked;
    bool gl_pbo_supported;
    bool gl_warned_pbo;
    bool gl_warned_texture_export;
    bool gl_logged_texture_scanout;
    bool gl_logged_dmabuf_scanout;
    uint32_t gl_pbo_head;
    uint32_t gl_pbo_tail;
    FbShmGlPbo gl_pbo[FB_SHM_GL_PBO_COUNT];
#ifdef _WIN32
    void *gl_d3d_tex2d;
    HANDLE gl_d3d_share_handle;
    char *gl_d3d_name;
    uint32_t gl_d3d_generation;
#endif
#endif

    /* control socket */
    int listen_fd;
    QLIST_HEAD(, FbShmClient) clients;
};

/* ------------------------------------------------------------------ */
/* helpers                                                             */
/* ------------------------------------------------------------------ */

static void fb_shm_broadcast_resize(FbShmDisplay *d);
static void fb_shm_client_free_bh(void *opaque);
static void fb_shm_publish_frame(FbShmDisplay *d, uint32_t next_idx,
                                 uint32_t w, uint32_t h);
static void fb_shm_update_effective_rate(FbShmDisplay *d);
static bool fb_shm_rate_due(uint32_t rate_hz, uint64_t *last_ns,
                            uint64_t now_ns);
#ifdef CONFIG_OPENGL
static void fb_shm_broadcast_current_gpu_frame(FbShmDisplay *d,
                                               uint32_t w, uint32_t h,
                                               int32_t roi_x, int32_t roi_y);
#endif

static size_t fb_shm_frame_bytes(uint32_t w, uint32_t h)
{
    return (size_t)w * h * 4;
}

static uint64_t fb_shm_now_ns(void)
{
    struct timespec ts;

    /*
     * 帧率节流只关心相邻帧间隔，必须使用单调时钟。CLOCK_REALTIME 被 NTP、
     * 手工改时或宿主休眠恢复扰动时，会让 deadline 判断突然提前/落后，从而
     * 造成推流端一段时间快进或停顿。
     */
    clock_gettime(CLOCK_MONOTONIC, &ts);
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

static void fb_shm_release_slot_images(FbShmDisplay *d)
{
    for (uint32_t i = 0; i < FB_SHM_BUF_COUNT; i++) {
        if (d->slot_img[i]) {
            pixman_image_unref(d->slot_img[i]);
            d->slot_img[i] = NULL;
        }
#ifdef CONFIG_OPENGL
        g_clear_pointer(&d->gl_slot_surface[i], qemu_free_displaysurface);
#endif
    }
}

#ifdef CONFIG_OPENGL
static bool fb_shm_gl_make_current(FbShmDisplay *d)
{
    if (!console_has_gl(d->con)) {
        if (!d->gl_warned_context) {
            warn_report("fb-shm: GL scanout has no display GL context; "
                        "GL frames will not be exported");
            d->gl_warned_context = true;
        }
        return false;
    }

    if (!d->gl_ctx) {
        /*
         * SDL/EGL 已经给 console 安装了主 GL provider。这里再创建一个
         * 共享 context，避免依赖其它 DCL 的当前 context 顺序；否则 fb-shm
         * 在 listener 链表中排在 SDL 前面时会读不到 virgl texture。
         */
        QEMUGLParams params = {
            .major_ver = 3,
            .minor_ver = 0,
        };

        d->gl_ctx = dpy_gl_ctx_create(d->con, &params);
        if (!d->gl_ctx) {
            if (!d->gl_warned_context) {
                warn_report("fb-shm: cannot create shared GL context; "
                            "GL frames will not be exported");
                d->gl_warned_context = true;
            }
            return false;
        }
    }

    if (dpy_gl_ctx_make_current(d->con, d->gl_ctx) != 0) {
        if (!d->gl_warned_context) {
            warn_report("fb-shm: cannot make shared GL context current; "
                        "GL frames will not be exported");
            d->gl_warned_context = true;
        }
        return false;
    }

    return true;
}

static bool fb_shm_gl_pbo_can_use(FbShmDisplay *d)
{
    int gl_version;
    bool is_desktop;
    bool has_pbo;
    bool has_sync;

    if (d->gl_pbo_checked) {
        return d->gl_pbo_supported;
    }

    /*
     * PBO 把 glReadPixels 变成“先排队、后取结果”，但没有 fence 就无法
     * 非阻塞判断结果是否已经完成。这里要求 PBO + sync 同时可用，否则
     * 回落到同步读回，保证 SDL 窗口和推流链路仍然可用。
     */
    gl_version = epoxy_gl_version();
    is_desktop = epoxy_is_desktop_gl();
    has_pbo = gl_version >= 30 ||
              (is_desktop && epoxy_has_gl_extension("GL_ARB_pixel_buffer_object"));
    has_sync = (!is_desktop && gl_version >= 30) ||
               (is_desktop && (gl_version >= 32 ||
                               epoxy_has_gl_extension("GL_ARB_sync")));

    d->gl_pbo_supported = has_pbo && has_sync;
    d->gl_pbo_checked = true;
    return d->gl_pbo_supported;
}

static void fb_shm_gl_pbo_forget(FbShmGlPbo *pbo, bool delete_buffer)
{
    if (pbo->fence) {
        glDeleteSync(pbo->fence);
        pbo->fence = NULL;
    }

    if (delete_buffer && pbo->id) {
        glDeleteBuffers(1, &pbo->id);
        pbo->id = 0;
    }

    pbo->pending = false;
    if (delete_buffer) {
        pbo->bytes = 0;
    }
    pbo->w = 0;
    pbo->h = 0;
}

static void fb_shm_gl_pbo_discard(FbShmDisplay *d, bool delete_buffers)
{
    for (uint32_t i = 0; i < FB_SHM_GL_PBO_COUNT; i++) {
        fb_shm_gl_pbo_forget(&d->gl_pbo[i], delete_buffers);
    }
    d->gl_pbo_head = 0;
    d->gl_pbo_tail = 0;
}

#ifdef _WIN32
static void fb_shm_gl_forget_d3d_share(FbShmDisplay *d)
{
    if (d->gl_d3d_share_handle) {
        CloseHandle(d->gl_d3d_share_handle);
        d->gl_d3d_share_handle = NULL;
    }
    g_clear_pointer(&d->gl_d3d_name, g_free);
    d->gl_d3d_tex2d = NULL;
}
#endif

static bool fb_shm_gl_pbo_finish_one(FbShmDisplay *d, FbShmGlPbo *pbo)
{
    GLenum wait_status;
    void *pixels;
    uint32_t cur_idx;
    uint32_t next_idx;
    size_t frame_bytes;

    if (!pbo->pending) {
        return true;
    }

    wait_status = glClientWaitSync(pbo->fence, 0, 0);
    if (wait_status == GL_TIMEOUT_EXPIRED) {
        return false;
    }

    if (wait_status == GL_WAIT_FAILED) {
        if (!d->gl_warned_pbo) {
            warn_report("fb-shm: async GL PBO fence wait failed; "
                        "dropping one readback frame");
            d->gl_warned_pbo = true;
        }
        fb_shm_gl_pbo_forget(pbo, false);
        return true;
    }

    if (!d->hdr || !d->slot[0]) {
        fb_shm_gl_pbo_forget(pbo, false);
        return true;
    }

    frame_bytes = fb_shm_frame_bytes(d->cur_w, d->cur_h);
    if (pbo->bytes != frame_bytes || pbo->w != d->cur_w || pbo->h != d->cur_h) {
        fb_shm_gl_pbo_forget(pbo, false);
        return true;
    }

    glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo->id);
    pixels = glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, pbo->bytes,
                              GL_MAP_READ_BIT);
    if (!pixels) {
        if (!d->gl_warned_pbo) {
            warn_report("fb-shm: async GL PBO map failed; "
                        "dropping one readback frame");
            d->gl_warned_pbo = true;
        }
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        fb_shm_gl_pbo_forget(pbo, false);
        return true;
    }

    cur_idx = qatomic_load_acquire(&d->hdr->active_idx);
    next_idx = (cur_idx + 1) % FB_SHM_BUF_COUNT;
    memcpy(d->slot[next_idx], pixels, pbo->bytes);
    glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);

    fb_shm_publish_frame(d, next_idx, pbo->w, pbo->h);
    fb_shm_gl_pbo_forget(pbo, false);
    return true;
}

static void fb_shm_gl_pbo_drain(FbShmDisplay *d)
{
    FbShmGlPbo *pbo;

    while (true) {
        pbo = &d->gl_pbo[d->gl_pbo_tail];
        if (!pbo->pending) {
            return;
        }
        if (!fb_shm_gl_pbo_finish_one(d, pbo)) {
            return;
        }
        d->gl_pbo_tail = (d->gl_pbo_tail + 1) % FB_SHM_GL_PBO_COUNT;
    }
}

static int fb_shm_gl_pbo_issue(FbShmDisplay *d, uint32_t rw, uint32_t rh,
                               int sx1, int sy1, int sx2, int sy2)
{
    FbShmGlPbo *pbo;
    size_t bytes = fb_shm_frame_bytes(rw, rh);

    if (!fb_shm_gl_pbo_can_use(d)) {
        return -1;
    }

    fb_shm_gl_pbo_drain(d);
    pbo = &d->gl_pbo[d->gl_pbo_head];
    if (pbo->pending) {
        /*
         * 三个 PBO 都还没完成时直接丢本次采样。这里选择稳帧而不是
         * fallback 到同步 glReadPixels，否则最慢帧会再次卡住 SDL/main loop。
         */
        return 0;
    }

    if (!pbo->id) {
        glGenBuffers(1, &pbo->id);
        if (!pbo->id) {
            if (!d->gl_warned_pbo) {
                warn_report("fb-shm: cannot allocate GL PBO; "
                            "using sync readback");
                d->gl_warned_pbo = true;
            }
            return -1;
        }
    }

    glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo->id);
    if (pbo->bytes != bytes) {
        glBufferData(GL_PIXEL_PACK_BUFFER, bytes, NULL, GL_STREAM_READ);
    }

    glBindFramebuffer(GL_READ_FRAMEBUFFER, d->gl_guest_fb.framebuffer);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, d->gl_blit_fb.framebuffer);
    glViewport(0, 0, rw, rh);
    glBlitFramebuffer(sx1, sy1, sx2, sy2,
                      0, 0, rw, rh,
                      GL_COLOR_BUFFER_BIT, GL_NEAREST);

    glBindFramebuffer(GL_READ_FRAMEBUFFER, d->gl_blit_fb.framebuffer);
    glReadBuffer(GL_COLOR_ATTACHMENT0_EXT);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glReadPixels(0, 0, rw, rh, GL_BGRA, GL_UNSIGNED_BYTE, 0);

    pbo->fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    pbo->bytes = bytes;
    pbo->w = rw;
    pbo->h = rh;
    pbo->pending = true;
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    glFlush();

    d->gl_pbo_head = (d->gl_pbo_head + 1) % FB_SHM_GL_PBO_COUNT;
    return 1;
}

static void fb_shm_gl_release_fbos(FbShmDisplay *d)
{
    d->gl_dmabuf = NULL;
#ifdef _WIN32
    fb_shm_gl_forget_d3d_share(d);
#endif

    if (!d->gl_ctx || !fb_shm_gl_make_current(d)) {
        return;
    }

    fb_shm_gl_pbo_discard(d, true);
    egl_fb_destroy(&d->gl_guest_fb);
    egl_fb_destroy(&d->gl_blit_fb);
}

static void fb_shm_gl_release(FbShmDisplay *d)
{
    fb_shm_gl_release_fbos(d);

    if (d->gl_ctx) {
        dpy_gl_ctx_destroy(d->con, d->gl_ctx);
        d->gl_ctx = NULL;
    }
}
#endif

static void fb_shm_release_mapping(FbShmDisplay *d)
{
    fb_shm_release_slot_images(d);
    for (uint32_t i = 0; i < FB_SHM_BUF_COUNT; i++) {
        d->slot[i] = NULL;
    }
#ifndef _WIN32
    if (d->shm && d->shm != MAP_FAILED) {
        munmap(d->shm, d->map_size);
    }
#else
    if (d->shm) {
        UnmapViewOfFile(d->shm);
    }
#endif
    d->shm = NULL;
    d->hdr = NULL;
    d->map_size = 0;
    d->cap_w = 0;
    d->cap_h = 0;
    d->cap_buf_size = 0;
#ifndef _WIN32
    if (d->memfd >= 0) {
        close(d->memfd);
        d->memfd = -1;
    }
#else
    if (d->map_handle) {
        CloseHandle(d->map_handle);
        d->map_handle = NULL;
    }
    g_clear_pointer(&d->map_name, g_free);
#endif
}

static int fb_shm_apply_geometry(FbShmDisplay *d, uint32_t w, uint32_t h,
                                 uint32_t sw, uint32_t sh,
                                 int32_t roi_x, int32_t roi_y, Error **errp)
{
    uint32_t old_w = d->cur_w;
    uint32_t old_h = d->cur_h;
    uint32_t old_sw = d->cur_src_w;
    uint32_t old_sh = d->cur_src_h;
    int32_t old_roi_x = d->cur_roi_x;
    int32_t old_roi_y = d->cur_roi_y;

    if (w == 0 || h == 0 || w > FB_SHM_MAX_DIM || h > FB_SHM_MAX_DIM) {
        error_setg(errp, "fb-shm: invalid ROI %ux%u", w, h);
        return -1;
    }
    if (!d->shm || !d->hdr || fb_shm_frame_bytes(w, h) > d->cap_buf_size) {
        error_setg(errp, "fb-shm: ROI %ux%u exceeds backing capacity %ux%u",
                   w, h, d->cap_w, d->cap_h);
        return -1;
    }

    fb_shm_release_slot_images(d);
    for (uint32_t i = 0; i < FB_SHM_BUF_COUNT; i++) {
        d->slot[i] = (uint8_t *)d->shm + d->hdr->buf_offset[i];
        d->slot_img[i] = pixman_image_create_bits_no_clear(
            PIXMAN_x8r8g8b8, w, h, (uint32_t *)d->slot[i], (int)(w * 4));
        if (!d->slot_img[i]) {
            error_setg(errp, "fb-shm: pixman dest image alloc failed");
            fb_shm_release_slot_images(d);
            return -1;
        }
#ifdef CONFIG_OPENGL
        /*
         * GL 读回直接写入同一个 SHM slot。为每个 slot 建一个不拥有内存的
         * DisplaySurface 包装层，这样可以复用 QEMU 已有的 egl_fb_read()
         * BGR0 读回逻辑，而不会额外分配帧缓冲。
         */
        d->gl_slot_surface[i] = qemu_create_displaysurface_from(
            w, h, PIXMAN_x8r8g8b8, (int)(w * 4), d->slot[i]);
#endif
    }

    size_t buf_size = (size_t)w * h * 4;
    d->cur_w = w;
    d->cur_h = h;
    d->cur_src_w = sw;
    d->cur_src_h = sh;
    d->cur_roi_x = roi_x;
    d->cur_roi_y = roi_y;

    FbShmHeader *hdr = d->hdr;
    hdr->buf_size = buf_size;
    hdr->width = w;
    hdr->height = h;
    hdr->stride = w * 4;
    hdr->target_fps = d->shm_target_fps;
    hdr->src_width = sw;
    hdr->src_height = sh;
    hdr->roi_x = roi_x;
    hdr->roi_y = roi_y;
    hdr->damage_x = 0;
    hdr->damage_y = 0;
    hdr->damage_w = (int32_t)w;
    hdr->damage_h = (int32_t)h;
    hdr->flags = FB_SHM_FLAG_RUNNING | FB_SHM_FLAG_RESIZED;
    hdr->ts_ns = fb_shm_now_ns();

    /*
     * 这里记录实际推流几何，而不是只记录 memfd 重建。
     * 现在 ROI 变小/变大且仍落在既有 backing capacity 内时只会更新
     * header 和 pixman view，不会触发 NOTIFY_RESIZED 广播；这条日志用于
     * 恢复“推流尺寸发生调整时一定可见”的诊断信号。
     */
    if (old_w != 0 || old_h != 0) {
        info_report("fb-shm: geometry updated %ux%u@%d,%d/%ux%u -> "
                    "%ux%u@%d,%d/%ux%u (cap=%ux%u, shm_size=%zu)",
                    old_w, old_h, old_roi_x, old_roi_y, old_sw, old_sh,
                    w, h, roi_x, roi_y, sw, sh,
                    d->cap_w, d->cap_h, d->map_size);
    }
    return 0;
}

/* Allocate a backing store sized for the full source surface, not the ROI.
 * ROI changes can then update only the header and local pixman views. */
#ifdef _WIN32
static char *fb_shm_win32_safe_id(const char *id)
{
    GString *s = g_string_new(NULL);

    /*
     * Win32 内核对象名把反斜杠当命名空间分隔符。这里把 id 收窄到
     * ASCII 安全集合，保证 profile/实例名来自外部输入时也不会越过
     * Local\qemu-fb-shm-* 这个命名空间。
     */
    for (const char *p = id && *id ? id : "default"; *p; p++) {
        if (g_ascii_isalnum(*p) || *p == '-' || *p == '_') {
            g_string_append_c(s, *p);
        } else {
            g_string_append_c(s, '_');
        }
    }
    return g_string_free(s, FALSE);
}

static char *fb_shm_win32_mapping_name(FbShmDisplay *d)
{
    g_autofree char *safe_id = fb_shm_win32_safe_id(d->id);

    d->map_generation++;
    return g_strdup_printf("Local\\qemu-fb-shm-%s-map-%u",
                           safe_id, d->map_generation);
}
#endif

static int fb_shm_allocate_mapping(FbShmDisplay *d, uint32_t cap_w,
                                   uint32_t cap_h, Error **errp)
{
    if (cap_w == 0 || cap_h == 0 ||
        cap_w > FB_SHM_MAX_DIM || cap_h > FB_SHM_MAX_DIM) {
        error_setg(errp, "fb-shm: invalid backing capacity %ux%u",
                   cap_w, cap_h);
        return -1;
    }

    fb_shm_release_mapping(d);

    size_t buf_size = fb_shm_frame_bytes(cap_w, cap_h);
    size_t map_size = FB_SHM_HEADER_SIZE + (size_t)FB_SHM_BUF_COUNT * buf_size;

#ifndef _WIN32
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
#else
    g_autofree char *map_name = fb_shm_win32_mapping_name(d);
    HANDLE map_handle = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL,
                                           PAGE_READWRITE,
                                           (DWORD)(map_size >> 32),
                                           (DWORD)(map_size & 0xffffffffu),
                                           map_name);
    if (!map_handle) {
        error_setg_win32(errp, GetLastError(),
                         "fb-shm: CreateFileMappingA failed");
        return -1;
    }
    void *p = MapViewOfFile(map_handle, FILE_MAP_ALL_ACCESS, 0, 0, map_size);
    if (!p) {
        error_setg_win32(errp, GetLastError(),
                         "fb-shm: MapViewOfFile failed");
        CloseHandle(map_handle);
        return -1;
    }
#endif
    memset(p, 0, FB_SHM_HEADER_SIZE);

#ifndef _WIN32
    d->memfd = fd;
#else
    d->map_handle = map_handle;
    d->map_name = g_steal_pointer(&map_name);
#endif
    d->shm = p;
    d->map_size = map_size;
    d->hdr = (FbShmHeader *)p;
    d->cap_w = cap_w;
    d->cap_h = cap_h;
    d->cap_buf_size = buf_size;

    /* Header init.  Geometry fields are filled by fb_shm_apply_geometry(). */
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
    }
    hdr->fourcc = FB_SHM_FOURCC_BGR0;
    hdr->bpp = 32;
    hdr->target_fps = d->shm_target_fps;
    hdr->active_idx = 0;
    hdr->flags = FB_SHM_FLAG_RUNNING | FB_SHM_FLAG_RESIZED;
    hdr->frame_seq = 0;
    hdr->ts_ns = fb_shm_now_ns();
    return 0;
}

static int fb_shm_ensure_geometry(FbShmDisplay *d, uint32_t w, uint32_t h,
                                  uint32_t sw, uint32_t sh,
                                  int32_t roi_x, int32_t roi_y, Error **errp)
{
    bool needs_mapping = !d->shm || w > d->cap_w || h > d->cap_h;
    uint32_t cap_w = d->cap_w;
    uint32_t cap_h = d->cap_h;

    if (needs_mapping) {
        cap_w = sw > cap_w ? sw : cap_w;
        cap_h = sh > cap_h ? sh : cap_h;
        cap_w = w > cap_w ? w : cap_w;
        cap_h = h > cap_h ? h : cap_h;
        if (fb_shm_allocate_mapping(d, cap_w, cap_h, errp) < 0) {
            return -1;
        }
    }

    if (w != d->cur_w || h != d->cur_h ||
        sw != d->cur_src_w || sh != d->cur_src_h ||
        roi_x != d->cur_roi_x || roi_y != d->cur_roi_y) {
        if (fb_shm_apply_geometry(d, w, h, sw, sh, roi_x, roi_y, errp) < 0) {
            return -1;
        }
    }

    if (needs_mapping) {
        /* Only a real memfd replacement needs an out-of-band fd update. */
        fb_shm_broadcast_resize(d);
        /*
         * 中文注释：启动时为了让首个普通 SHM 客户端能拿到 memfd/eventfd，
         * fb-shm 会先按配置帧率驱动一次 DCL。mapping 建好后如果没有消费者，
         * 必须立刻重算有效帧率，把旁路监听器降到 1Hz；否则即使没人推流，
         * GL/SDL 主显示路径也会被每秒 60 次 graphic_hw_update() 拖慢。
         */
        fb_shm_update_effective_rate(d);
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* control socket                                                      */
/* ------------------------------------------------------------------ */

static void fb_shm_client_drop(FbShmClient *c)
{
    int fd;

    if (!c || c->dropping) {
        return;
    }

    c->dropping = true;
    fd = c->fd;
    c->fd = -1;
    if (fd >= 0) {
        qemu_set_fd_handler(fd, NULL, NULL, NULL);
        close(fd);
    }
#ifdef _WIN32
    if (c->wake_event) {
        CloseHandle(c->wake_event);
        c->wake_event = NULL;
    }
    g_clear_pointer(&c->wake_event_name, g_free);
#endif
    if (c->linked) {
        QLIST_REMOVE(c, next);
        c->linked = false;
    }
    fb_shm_update_effective_rate(c->owner);
    c->owner = NULL;
    aio_bh_schedule_oneshot(qemu_get_aio_context(), fb_shm_client_free_bh, c);
}

static void fb_shm_client_free_bh(void *opaque)
{
    FbShmClient *c = opaque;

    g_free(c);
}

static uint32_t fb_shm_clamp_rate(uint32_t rate)
{
    if (rate < FB_SHM_MIN_RATE) {
        rate = FB_SHM_MIN_RATE;
    }
    if (rate > FB_SHM_MAX_RATE) {
        rate = FB_SHM_MAX_RATE;
    }
    return rate;
}

static uint32_t fb_shm_rate_interval_ms(uint32_t rate)
{
    /*
     * DisplayChangeListener 的刷新间隔只能传毫秒整数。这里和 DCL 使用同一套
     * 量化周期，避免 60Hz 时 DCL 每 16ms 调一次，而后面的纳秒级节流又按
     * 16.666ms 判定“太早”，导致实际每隔一帧才发布一次 GPU frame。
     */
    rate = fb_shm_clamp_rate(rate);
    return MAX(1, 1000 / rate);
}

#ifndef _WIN32
static int fb_shm_send_ack(FbShmDisplay *d, FbShmClient *c,
                           const FbShmCtlAck *ack, bool include_handles)
{
    struct iovec iov = { .iov_base = (void *)ack, .iov_len = sizeof(*ack) };
    char cbuf[CMSG_SPACE(sizeof(int) * 2)];
    struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
    };
    int fds[2] = { d->memfd, d->wake_eventfd };
    int nfds = (include_handles && d->memfd >= 0 && d->wake_eventfd >= 0) ? 2 : 0;

    if (nfds > 0) {
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
        r = sendmsg(c->fd, &msg, MSG_NOSIGNAL);
    } while (r < 0 && errno == EINTR);
    return (r == (ssize_t)sizeof(*ack)) ? 0 : -1;
}
#else
static int fb_shm_send_bytes(int fd, const void *buf, size_t len)
{
    const uint8_t *p = buf;

    while (len > 0) {
        ssize_t r;

        do {
            r = send(fd, (const char *)p, len, 0);
        } while (r < 0 && errno == EINTR);
        if (r <= 0) {
            return -1;
        }
        p += r;
        len -= r;
    }
    return 0;
}

static char *fb_shm_win32_event_name(FbShmDisplay *d, FbShmClient *c)
{
    g_autofree char *safe_id = fb_shm_win32_safe_id(d->id);

    return g_strdup_printf("Local\\qemu-fb-shm-%s-client-%p", safe_id, c);
}

static bool fb_shm_win32_ensure_client_event(FbShmDisplay *d, FbShmClient *c,
                                             Error **errp)
{
    if (c->wake_event) {
        return true;
    }

    c->wake_event_name = fb_shm_win32_event_name(d, c);
    c->wake_event = CreateEventA(NULL, FALSE, FALSE, c->wake_event_name);
    if (!c->wake_event) {
        error_setg_win32(errp, GetLastError(),
                         "fb-shm: CreateEventA failed");
        g_clear_pointer(&c->wake_event_name, g_free);
        return false;
    }
    return true;
}

static int fb_shm_send_ack(FbShmDisplay *d, FbShmClient *c,
                           const FbShmCtlAck *ack, bool include_handles)
{
    if (fb_shm_send_bytes(c->fd, ack, sizeof(*ack)) < 0) {
        return -1;
    }

    if (!include_handles || !c->wants_win32_names || !d->map_name ||
        !c->wake_event_name || ack->status != FB_SHM_CTL_OK) {
        return 0;
    }

    FbShmWin32Names names = {
        .magic = FB_SHM_MAGIC,
        .version = FB_SHM_VERSION,
        .size = sizeof(names),
    };

    /*
     * 固定宽度 payload 让原生消费端不需要 JSON/PowerShell/Python。名称过长
     * 直接截断会导致 OpenFileMapping/OpenEvent 失败，因此这里显式检查。
     */
    if (g_strlcpy(names.mapping_name, d->map_name,
                  sizeof(names.mapping_name)) >= sizeof(names.mapping_name) ||
        g_strlcpy(names.event_name, c->wake_event_name,
                  sizeof(names.event_name)) >= sizeof(names.event_name)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return fb_shm_send_bytes(c->fd, &names, sizeof(names));
}
#endif

static bool fb_shm_client_accepts_gpu(const FbShmClient *c)
{
    return c->hello_done && c->wants_gpu_frames &&
           !c->dropping && c->fd >= 0;
}

static bool fb_shm_has_gpu_clients(FbShmDisplay *d)
{
    FbShmClient *c;

    QLIST_FOREACH(c, &d->clients, next) {
        if (fb_shm_client_accepts_gpu(c)) {
            return true;
        }
    }
    return false;
}

static bool fb_shm_has_shm_consumers(FbShmDisplay *d)
{
    FbShmClient *c;

    QLIST_FOREACH(c, &d->clients, next) {
        if (c->hello_done && !c->gpu_required &&
            !c->dropping && c->fd >= 0) {
            return true;
        }
    }
    return false;
}

static uint32_t fb_shm_effective_rate(FbShmDisplay *d)
{
    uint32_t rate = 0;

    if (fb_shm_has_gpu_clients(d)) {
        rate = d->gpu_target_fps;
    }
    /*
     * !d->shm 时保留一次低频 SHM bootstrap：普通 SHM consumer 需要 HELLO
     * 时拿到 memfd/eventfd；映射建好且没有 SHM consumer 后，GL 路径会跳过
     * CPU readback。
     */
    if (fb_shm_has_shm_consumers(d) || !d->shm) {
        rate = MAX(rate, d->shm_target_fps);
    }
    if (!rate) {
        rate = FB_SHM_MIN_RATE;
    }
    return fb_shm_clamp_rate(rate);
}

static void fb_shm_update_effective_rate(FbShmDisplay *d)
{
    uint32_t rate = fb_shm_effective_rate(d);

    d->target_fps = rate;
    if (d->hdr) {
        d->hdr->target_fps = d->shm_target_fps;
    }
    update_displaychangelistener(&d->dcl, fb_shm_rate_interval_ms(rate));
}

#ifndef _WIN32
static int fb_shm_send_gpu_frame(FbShmClient *c,
                                 const FbShmGpuFrame *frame, int gpu_fd)
{
    FbShmCtlAck ack = {
        .magic = FB_SHM_MAGIC,
        .op = FB_SHM_CTL_NOTIFY_GPU_FRAME,
        .status = FB_SHM_CTL_OK,
        .shm_size = sizeof(*frame),
        .width = frame->width,
        .height = frame->height,
        .fourcc = frame->fourcc,
    };
    struct iovec iov[2] = {
        { .iov_base = &ack, .iov_len = sizeof(ack) },
        { .iov_base = (void *)frame, .iov_len = sizeof(*frame) },
    };
    char cbuf[CMSG_SPACE(sizeof(int))];
    struct msghdr msg = {
        .msg_iov = iov,
        .msg_iovlen = G_N_ELEMENTS(iov),
    };
    ssize_t r;

    if (gpu_fd >= 0) {
        memset(cbuf, 0, sizeof(cbuf));
        msg.msg_control = cbuf;
        msg.msg_controllen = CMSG_SPACE(sizeof(int));

        struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
        cm->cmsg_level = SOL_SOCKET;
        cm->cmsg_type = SCM_RIGHTS;
        cm->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(cm), &gpu_fd, sizeof(gpu_fd));
    }

    do {
        r = sendmsg(c->fd, &msg, MSG_NOSIGNAL);
    } while (r < 0 && errno == EINTR);

    return r == (ssize_t)(sizeof(ack) + sizeof(*frame)) ? 0 : -1;
}
#else
static int fb_shm_send_gpu_frame(FbShmClient *c,
                                 const FbShmGpuFrame *frame, int gpu_fd)
{
    FbShmCtlAck ack = {
        .magic = FB_SHM_MAGIC,
        .op = FB_SHM_CTL_NOTIFY_GPU_FRAME,
        .status = FB_SHM_CTL_OK,
        .shm_size = sizeof(*frame),
        .width = frame->width,
        .height = frame->height,
        .fourcc = frame->fourcc,
    };

    (void)gpu_fd;
    if (fb_shm_send_bytes(c->fd, &ack, sizeof(ack)) < 0) {
        return -1;
    }
    return fb_shm_send_bytes(c->fd, frame, sizeof(*frame));
}
#endif

static bool fb_shm_client_disconnect_errno(int err)
{
    return err == EPIPE || err == ECONNRESET || err == ENOTCONN;
}

static void fb_shm_broadcast_gpu_frame(FbShmDisplay *d,
                                       const FbShmGpuFrame *frame,
                                       int gpu_fd)
{
    FbShmClient *c, *cn;
    int recipients = 0;

    QLIST_FOREACH_SAFE(c, &d->clients, next, cn) {
        if (!fb_shm_client_accepts_gpu(c)) {
            continue;
        }
        if (fb_shm_send_gpu_frame(c, frame, gpu_fd) < 0) {
            if (!fb_shm_client_disconnect_errno(errno)) {
                warn_report("fb-shm: NOTIFY_GPU_FRAME send failed "
                            "(errno=%d %s); dropping client fd=%d",
                            errno, strerror(errno), c->fd);
            }
            fb_shm_client_drop(c);
        } else {
            recipients++;
        }
    }

    (void)recipients;
}

static void fb_shm_handle_hello(FbShmDisplay *d, FbShmClient *c,
                                const FbShmCtlReq *req)
{
    bool gpu_only;

    if (c->dropping || c->fd < 0) {
        return;
    }

    /* Mark the client eligible for broadcasts BEFORE we send the ack: a
     * concurrent reallocate from the refresh tick is fine, the client will
     * just see the HELLO ack followed by a NOTIFY_RESIZED carrying the same
     * (or newer) fds. */
    c->hello_done = true;
    c->wants_resize_notify =
        (req->flags & FB_SHM_HELLO_F_RESIZE_NOTIFY) != 0;
    c->wants_win32_names =
        (req->flags & FB_SHM_HELLO_F_WIN32_NAMES) != 0;
    c->wants_gpu_frames =
        (req->flags & FB_SHM_HELLO_F_GPU_FRAMES) != 0;
    c->gpu_required =
        (req->flags & FB_SHM_HELLO_F_GPU_REQUIRED) != 0;
    gpu_only = c->wants_gpu_frames && c->gpu_required;
    fb_shm_update_effective_rate(d);

    FbShmCtlAck ack = {
        .magic  = FB_SHM_MAGIC,
        .op     = FB_SHM_CTL_HELLO,
        .status = (d->shm || gpu_only) ? FB_SHM_CTL_OK : FB_SHM_CTL_EBUSY,
        .shm_size = (uint32_t)d->map_size,
        .width  = d->cur_w,
        .height = d->cur_h,
        .fourcc = FB_SHM_FOURCC_BGR0,
        .bpp    = 32,
    };
#ifdef _WIN32
    if (ack.status == FB_SHM_CTL_OK && d->shm) {
        Error *err = NULL;

        if (!fb_shm_win32_ensure_client_event(d, c, &err)) {
            warn_report_err(err);
            ack.status = FB_SHM_CTL_EBUSY;
        }
    }
#endif
    if (fb_shm_send_ack(d, c, &ack, true) < 0) {
        fb_shm_client_drop(c);
    }
}

/* Push the current backing-store descriptor/name to every HELLO-completed
 * client that opted into resize notifications.  Called from fb_shm_allocate
 * after the new mapping is fully published.  Failed sends drop the client. */
static void fb_shm_broadcast_resize(FbShmDisplay *d)
{
#ifndef _WIN32
    if (d->memfd < 0 || d->wake_eventfd < 0) {
        return;
    }
#else
    if (!d->map_name) {
        return;
    }
#endif
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
    int recipients = 0;
    FbShmClient *c, *cn;
    QLIST_FOREACH_SAFE(c, &d->clients, next, cn) {
        if (c->dropping || c->fd < 0 ||
            !c->hello_done || !c->wants_resize_notify) {
            continue;
        }
#ifdef _WIN32
        if (!c->wake_event_name) {
            continue;
        }
#endif
        if (fb_shm_send_ack(d, c, &ack, true) < 0) {
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
    if (c->dropping || c->fd < 0) {
        return;
    }

    if (req->w > FB_SHM_MAX_DIM || req->h > FB_SHM_MAX_DIM) {
        FbShmCtlAck ack = { .magic = FB_SHM_MAGIC, .op = req->op,
                            .status = FB_SHM_CTL_EINVAL };
        if (fb_shm_send_ack(d, c, &ack, false) < 0) {
            fb_shm_client_drop(c);
        }
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
    if (fb_shm_send_ack(d, c, &ack, false) < 0) {
        fb_shm_client_drop(c);
    }
}

static void fb_shm_handle_set_rate(FbShmDisplay *d, FbShmClient *c,
                                   const FbShmCtlReq *req)
{
    if (c->dropping || c->fd < 0) {
        return;
    }

    uint32_t r = fb_shm_clamp_rate(req->rate_hz);
    if (c->wants_gpu_frames && c->gpu_required) {
        d->gpu_target_fps = r;
    } else {
        d->shm_target_fps = r;
    }
    fb_shm_update_effective_rate(d);

    FbShmCtlAck ack = { .magic = FB_SHM_MAGIC, .op = req->op,
                        .status = FB_SHM_CTL_OK };
    if (fb_shm_send_ack(d, c, &ack, false) < 0) {
        fb_shm_client_drop(c);
    }
}

static void fb_shm_client_read(void *opaque)
{
    FbShmClient *c = opaque;
    FbShmDisplay *d = c->owner;
    FbShmCtlReq req;
    ssize_t r;

    if (c->dropping || c->fd < 0 || !d) {
        return;
    }

    do {
        r = recv(c->fd, (char *)&req, sizeof(req), 0);
    } while (r < 0 && errno == EINTR);
    if (r == 0 || (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
        fb_shm_client_drop(c);
        return;
    }
    if (r != (ssize_t)sizeof(req) || req.magic != FB_SHM_MAGIC) {
        FbShmCtlAck ack = { .magic = FB_SHM_MAGIC, .op = 0,
                            .status = FB_SHM_CTL_EINVAL };
        if (fb_shm_send_ack(d, c, &ack, false) < 0) {
            fb_shm_client_drop(c);
        }
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
        if (fb_shm_send_ack(d, c, &ack, false) < 0) {
            fb_shm_client_drop(c);
        }
        break;
    }
    }
}

static void fb_shm_listener_accept(void *opaque)
{
    FbShmDisplay *d = opaque;
    int cfd;
    do {
        cfd = qemu_accept(d->listen_fd, NULL, NULL);
    } while (cfd < 0 && errno == EINTR);
    if (cfd < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            warn_report("fb-shm: accept failed: %s", strerror(errno));
        }
        return;
    }
    qemu_socket_set_nonblock(cfd);
    FbShmClient *c = g_new0(FbShmClient, 1);
    c->owner = d;
    c->fd = cfd;
    c->linked = true;
    QLIST_INSERT_HEAD(&d->clients, c, next);
    qemu_set_fd_handler(cfd, fb_shm_client_read, NULL, c);
}

static int fb_shm_open_listener(FbShmDisplay *d, Error **errp)
{
    /* Make sure the parent directory exists when using a pathname socket. */
    g_autofree char *parent = g_path_get_dirname(d->sock_path);
    if (g_mkdir_with_parents(parent, 0750) < 0 && errno != EEXIST) {
        warn_report("fb-shm: cannot create %s: %s", parent, strerror(errno));
    }

    int fd = unix_listen(d->sock_path, errp);
    if (fd < 0) {
        return -1;
    }
    qemu_socket_set_nonblock(fd);
#ifndef _WIN32
    /* World-readable so non-root consumers can connect; tighten if needed. */
    chmod(d->sock_path, 0660);
#endif
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
        if (fb_shm_ensure_geometry(d, rw, rh, sw, sh, rx, ry, &err) < 0) {
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
    uint64_t now_ns = fb_shm_now_ns();

    uint32_t rw, rh;
    int32_t rx, ry;
    fb_shm_resolve_roi(d, sw, sh, &rw, &rh, &rx, &ry);

    if (d->shm && !fb_shm_has_shm_consumers(d)) {
        return;
    }
    if (!fb_shm_rate_due(d->shm_target_fps, &d->shm_last_frame_ns, now_ns)) {
        return;
    }

    if (!d->shm || rw != d->cur_w || rh != d->cur_h ||
        sw != d->cur_src_w || sh != d->cur_src_h ||
        rx != d->cur_roi_x || ry != d->cur_roi_y) {
        Error *err = NULL;
        if (fb_shm_ensure_geometry(d, rw, rh, sw, sh, rx, ry, &err) < 0) {
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

    fb_shm_publish_frame(d, next_idx, rw, rh);
}

static void fb_shm_publish_frame(FbShmDisplay *d, uint32_t next_idx,
                                 uint32_t w, uint32_t h)
{
    FbShmHeader *hdr = d->hdr;

    hdr->damage_x = 0;
    hdr->damage_y = 0;
    hdr->damage_w = (int32_t)w;
    hdr->damage_h = (int32_t)h;
    hdr->ts_ns = fb_shm_now_ns();
    qatomic_store_release(&hdr->active_idx, next_idx);

    d->frame_seq++;
    qatomic_store_release(&hdr->frame_seq, d->frame_seq);

#ifndef _WIN32
    /* Linux doorbell：eventfd 计数器，慢消费端只会跳帧，不会反压 QEMU。 */
    if (d->wake_eventfd >= 0) {
        uint64_t v = 1;
        ssize_t r;
        do {
            r = write(d->wake_eventfd, &v, sizeof(v));
        } while (r < 0 && errno == EINTR);
        (void)r;   /* full ringbuffer just means consumer hasn't drained */
    }
#else
    /*
     * Win32 doorbell：每个客户端独立 auto-reset event。共享内存仍是同一块，
     * 但唤醒不共享，保证多路 RTMP/本地归档同时挂载时互不抢信号。
     */
    FbShmClient *c;
    QLIST_FOREACH(c, &d->clients, next) {
        if (!c->dropping && c->hello_done && c->wake_event) {
            SetEvent(c->wake_event);
        }
    }
#endif
}

#ifdef CONFIG_OPENGL
static void fb_shm_gpu_frame_init(FbShmDisplay *d, FbShmGpuFrame *frame,
                                  uint32_t handle_type, uint32_t flags,
                                  uint32_t w, uint32_t h, uint32_t stride,
                                  uint32_t fourcc, uint32_t x, uint32_t y,
                                  uint32_t backing_w, uint32_t backing_h,
                                  uint64_t modifier)
{
    memset(frame, 0, sizeof(*frame));
    frame->magic = FB_SHM_MAGIC;
    frame->version = FB_SHM_VERSION;
    frame->size = sizeof(*frame);
    frame->handle_type = handle_type;
    frame->flags = flags;
    frame->width = w;
    frame->height = h;
    frame->stride = stride;
    frame->fourcc = fourcc;
    frame->x = x;
    frame->y = y;
    frame->backing_width = backing_w;
    frame->backing_height = backing_h;
    frame->modifier = modifier;

    /*
     * GPU 帧有自己的序列号：SHM consumer 看 FbShmHeader.frame_seq，
     * GPU consumer 看 FbShmGpuFrame.frame_seq。两条路径可以独立降级，
     * 也方便 consumer 发现 GPU 通知是否停滞。
     */
    d->gpu_frame_seq++;
    frame->frame_seq = d->gpu_frame_seq;
}

static void fb_shm_broadcast_dmabuf_frame(FbShmDisplay *d,
                                          QemuDmaBuf *dmabuf,
                                          uint32_t w, uint32_t h,
                                          int32_t roi_x, int32_t roi_y)
{
#ifndef _WIN32
    FbShmGpuFrame frame;
    int fd;
    uint32_t flags = 0;
    uint32_t x;
    uint32_t y;

    if (!dmabuf || !fb_shm_has_gpu_clients(d)) {
        return;
    }

    fd = qemu_dmabuf_dup_fd(dmabuf);
    if (fd < 0) {
        return;
    }

    if (qemu_dmabuf_get_y0_top(dmabuf)) {
        flags |= FB_SHM_GPU_FRAME_F_Y0_TOP;
    }
    x = qemu_dmabuf_get_x(dmabuf) + (uint32_t)roi_x;
    y = qemu_dmabuf_get_y(dmabuf) + (uint32_t)roi_y;
    fb_shm_gpu_frame_init(d, &frame, FB_SHM_GPU_HANDLE_DMA_BUF, flags,
                          w, h, qemu_dmabuf_get_stride(dmabuf),
                          qemu_dmabuf_get_fourcc(dmabuf), x, y,
                          qemu_dmabuf_get_backing_width(dmabuf),
                          qemu_dmabuf_get_backing_height(dmabuf),
                          qemu_dmabuf_get_modifier(dmabuf));
    fb_shm_broadcast_gpu_frame(d, &frame, fd);
    close(fd);
#else
    (void)d;
    (void)dmabuf;
    (void)w;
    (void)h;
    (void)roi_x;
    (void)roi_y;
#endif
}

#if defined(CONFIG_GBM) && !defined(_WIN32)
static void fb_shm_broadcast_texture_dmabuf_frame(FbShmDisplay *d,
                                                  uint32_t w, uint32_t h,
                                                  int32_t roi_x,
                                                  int32_t roi_y)
{
    FbShmGpuFrame frame;
    EGLint stride = 0;
    EGLint fourcc = 0;
    EGLuint64KHR modifier = 0;
    uint32_t flags = 0;
    int fd;

    if (!fb_shm_has_gpu_clients(d) || !d->gl_backing_id) {
        return;
    }

    /*
     * EGL_MESA_image_dma_buf_export 把当前 GL texture 导出成 dma-buf fd。
     * fd 只描述 GPU backing，不做 CPU readback；consumer 负责导入到
     * VAAPI/CUDA/DRM 等它自己的硬件编码栈。
     */
    fd = egl_get_fd_for_texture(d->gl_backing_id, &stride, &fourcc, &modifier);
    if (fd < 0) {
        if (!d->gl_warned_texture_export) {
            warn_report("fb-shm: GL scanout is texture-only and texture "
                        "dma-buf export is unavailable; using SHM fallback. "
                        "Start virtio-vga-gl with blob=true,hostmem=SIZE or "
                        "use an EGL stack with EGL_KHR_image and "
                        "EGL_MESA_image_dma_buf_export");
            d->gl_warned_texture_export = true;
        }
        return;
    }

    if (d->gl_y0_top) {
        flags |= FB_SHM_GPU_FRAME_F_Y0_TOP;
    }
    fb_shm_gpu_frame_init(d, &frame, FB_SHM_GPU_HANDLE_DMA_BUF, flags,
                          w, h, (uint32_t)stride, (uint32_t)fourcc,
                          d->gl_x + (uint32_t)roi_x,
                          d->gl_y + (uint32_t)roi_y,
                          d->gl_backing_w, d->gl_backing_h,
                          (uint64_t)modifier);
    fb_shm_broadcast_gpu_frame(d, &frame, fd);
    close(fd);
}
#else
static void fb_shm_broadcast_texture_dmabuf_frame(FbShmDisplay *d,
                                                  uint32_t w, uint32_t h,
                                                  int32_t roi_x,
                                                  int32_t roi_y)
{
    (void)d;
    (void)w;
    (void)h;
    (void)roi_x;
    (void)roi_y;
}
#endif

#ifdef _WIN32
static char *fb_shm_win32_d3d_name(FbShmDisplay *d)
{
    g_autofree char *safe_id = fb_shm_win32_safe_id(d->id);

    d->gl_d3d_generation++;
    return g_strdup_printf("Local\\qemu-fb-shm-%s-d3d-%u",
                           safe_id, d->gl_d3d_generation);
}

static bool fb_shm_d3d_texture_share_named(ID3D11Texture2D *texture,
                                           const char *name,
                                           HANDLE *handle, Error **errp)
{
    IDXGIResource1 *resource = NULL;
    g_autofree gunichar2 *wide_name = NULL;
    HRESULT hr;

    wide_name = g_utf8_to_utf16(name, -1, NULL, NULL, NULL);
    if (!wide_name) {
        error_setg(errp, "fb-shm: invalid D3D shared texture name");
        return false;
    }

    hr = texture->lpVtbl->QueryInterface(texture, &IID_IDXGIResource1,
                                         (void **)&resource);
    if (FAILED(hr)) {
        error_setg(errp, "fb-shm: IDXGIResource1 query failed: 0x%08lx",
                   (unsigned long)hr);
        return false;
    }

    hr = resource->lpVtbl->CreateSharedHandle(
        resource, NULL,
        DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
        (LPCWSTR)wide_name, handle);
    resource->lpVtbl->Release(resource);

    if (FAILED(hr)) {
        error_setg(errp, "fb-shm: CreateSharedHandle failed: 0x%08lx",
                   (unsigned long)hr);
        return false;
    }
    return true;
}

static bool fb_shm_d3d_prepare_share(FbShmDisplay *d, void *d3d_tex2d)
{
    ID3D11Texture2D *texture = d3d_tex2d;
    g_autofree char *name = NULL;
    HANDLE handle = NULL;
    Error *err = NULL;

    if (!texture) {
        fb_shm_gl_forget_d3d_share(d);
        return false;
    }
    if (d->gl_d3d_tex2d == d3d_tex2d && d->gl_d3d_name) {
        return true;
    }

    fb_shm_gl_forget_d3d_share(d);
    name = fb_shm_win32_d3d_name(d);
    if (!fb_shm_d3d_texture_share_named(texture, name, &handle, &err)) {
        warn_report_err(err);
        return false;
    }

    /*
     * 共享句柄由 QEMU 持有到 scanout 切换，consumer 通过名称打开同一份
     * D3D11 texture。这里不创建 staging texture，因此没有 GPU->CPU 拷贝。
     */
    d->gl_d3d_tex2d = d3d_tex2d;
    d->gl_d3d_name = g_steal_pointer(&name);
    d->gl_d3d_share_handle = handle;
    return true;
}

static void fb_shm_broadcast_d3d_frame(FbShmDisplay *d,
                                       uint32_t w, uint32_t h,
                                       int32_t roi_x, int32_t roi_y)
{
    FbShmGpuFrame frame;
    uint32_t flags = 0;

    if (!fb_shm_has_gpu_clients(d) || !d->gl_d3d_name) {
        return;
    }
    if (d->gl_y0_top) {
        flags |= FB_SHM_GPU_FRAME_F_Y0_TOP;
    }

    fb_shm_gpu_frame_init(d, &frame, FB_SHM_GPU_HANDLE_D3D11_TEXTURE,
                          flags, w, h, d->gl_backing_w * 4,
                          FB_SHM_FOURCC_BGRA,
                          d->gl_x + (uint32_t)roi_x,
                          d->gl_y + (uint32_t)roi_y,
                          d->gl_backing_w, d->gl_backing_h, 0);
    if (g_strlcpy(frame.handle_name, d->gl_d3d_name,
                  sizeof(frame.handle_name)) >= sizeof(frame.handle_name)) {
        return;
    }
    fb_shm_broadcast_gpu_frame(d, &frame, -1);
}
#endif

static void fb_shm_broadcast_current_gpu_frame(FbShmDisplay *d,
                                               uint32_t w, uint32_t h,
                                               int32_t roi_x, int32_t roi_y)
{
    if (!fb_shm_has_gpu_clients(d)) {
        return;
    }

    if (d->gl_dmabuf) {
        fb_shm_broadcast_dmabuf_frame(d, d->gl_dmabuf, w, h, roi_x, roi_y);
        return;
    }
#ifdef _WIN32
    if (d->gl_d3d_name) {
        fb_shm_broadcast_d3d_frame(d, w, h, roi_x, roi_y);
        return;
    }
#endif
    fb_shm_broadcast_texture_dmabuf_frame(d, w, h, roi_x, roi_y);
}

static bool fb_shm_rate_due(uint32_t rate_hz, uint64_t *last_ns,
                            uint64_t now_ns)
{
    const uint64_t slack_ns = 1000000ull;
    uint64_t interval_ns;

    rate_hz = fb_shm_clamp_rate(rate_hz);
    /*
     * DisplayChangeListener 的 update_interval 只能表达整数毫秒。这里使用同一
     * 个量化周期来做节流，避免 60Hz 被 16ms tick 驱动时又按 16.666ms 判断，
     * 周期性跳成 16/32ms；真实目标 fps 由外部 streamer 的稳定节拍保证。
     */
    interval_ns = (uint64_t)fb_shm_rate_interval_ms(rate_hz) * 1000000ull;
    if (!*last_ns) {
        *last_ns = now_ns;
        return true;
    }

    /*
     * QEMU 只发布“当前 tick 的最新帧”。如果宿主被调度走或 GL 读回慢了，
     * 不在这里补多个 deadline；消费端会重复上一帧或丢帧，避免视觉快进。
     */
    if (now_ns + slack_ns < *last_ns + interval_ns) {
        return false;
    }

    *last_ns = now_ns;
    return true;
}

static void fb_shm_commit_gl_frame(FbShmDisplay *d)
{
    uint32_t sw = d->gl_w;
    uint32_t sh = d->gl_h;
    uint32_t rw, rh;
    int32_t rx, ry;
    uint64_t now_ns;
    bool geometry_changed;
    bool has_gpu_clients;
    bool has_shm_consumers;
    bool need_shm_frame;
    Error *err = NULL;

    if (!d->gl_scanout || !sw || !sh) {
        return;
    }

    has_gpu_clients = fb_shm_has_gpu_clients(d);
    has_shm_consumers = fb_shm_has_shm_consumers(d);
    need_shm_frame = has_shm_consumers || !d->shm;
    /*
     * 中文注释：没有任何消费者时不要进入 GL current / PBO drain 热路径。
     * 这是零拷贝实验后保留的优化；但一旦普通 SHM consumer 存在，下面必须
     * 恢复旧版顺序，先及时 drain 已完成 PBO，再按目标帧率发起下一次采样。
     */
    if (!has_gpu_clients && !need_shm_frame) {
        return;
    }
    if (!d->gl_guest_fb.texture) {
        return;
    }
    if (!fb_shm_gl_make_current(d)) {
        return;
    }

    fb_shm_resolve_roi(d, sw, sh, &rw, &rh, &rx, &ry);
    geometry_changed = !d->shm || rw != d->cur_w || rh != d->cur_h ||
                       sw != d->cur_src_w || sh != d->cur_src_h ||
                       rx != d->cur_roi_x || ry != d->cur_roi_y;
    if (geometry_changed) {
        /*
         * 旧 PBO 的尺寸对应旧 memfd/ROI。几何变化时直接丢掉未发布帧，
         * 避免异步完成后写进已经替换过的 SHM view。
         */
        fb_shm_gl_pbo_discard(d, false);
        if (fb_shm_ensure_geometry(d, rw, rh, sw, sh, rx, ry, &err) < 0) {
            warn_report_err(err);
            return;
        }
    } else {
        fb_shm_gl_pbo_drain(d);
    }

    now_ns = fb_shm_now_ns();
    if (has_gpu_clients &&
        fb_shm_rate_due(d->gpu_target_fps, &d->gl_last_frame_ns, now_ns)) {
        fb_shm_broadcast_current_gpu_frame(d, rw, rh, rx, ry);
    }
    if (!need_shm_frame ||
        !fb_shm_rate_due(d->shm_target_fps, &d->shm_last_frame_ns, now_ns)) {
        return;
    }

    if (d->gl_blit_fb.width != rw || d->gl_blit_fb.height != rh) {
        egl_fb_destroy(&d->gl_blit_fb);
        egl_fb_setup_new_tex(&d->gl_blit_fb, rw, rh);
    }

    /*
     * virgl 给出的 texture 可能是 y0_top，也可能是传统 GL bottom-up。
     * fb-shm 对外固定输出 BGR0、top-left 语义；这里先用 blit 把 ROI
     * 归一化到 fb-shm 私有 FBO，再通过 PBO 异步读回。驱动不支持 PBO
     * 时回落到同步 glReadPixels，保证功能可用优先。
     */
    int sx1 = (int)d->gl_x + rx;
    int sx2 = sx1 + (int)rw;
    int sy1 = (int)d->gl_y + ry;
    int sy2 = sy1 + (int)rh;
    if (d->gl_y0_top) {
        /*
         * 上原点纹理：源 Y 必须绕 backing 高度做镜像，而不能只交换 sy1/sy2。
         * 简单交换仅在“整高 ROI（gl_y+ry==0 且 rh==backing_h）”时恰好成立；
         * 对任意带 y 偏移的裁剪 ROI，交换会读到偏移 2*(gl_y+ry) 的错误条带，
         * 使裁剪结果底部残留 (backing_h - 2*(gl_y+ry) - rh) 像素的过期桌面。
         * 反射后 dst 顶行对应 ROI 顶行、dst 底行对应 ROI 底行；对整高 ROI 与旧
         * 交换逐字节等价（(BH,0)），因此不改变既有正确路径的画面朝向。
         */
        int bh = (int)d->gl_backing_h;
        sy1 = bh - ((int)d->gl_y + ry);
        sy2 = bh - ((int)d->gl_y + ry + (int)rh);
    }

    int pbo_status = fb_shm_gl_pbo_issue(d, rw, rh, sx1, sy1, sx2, sy2);
    if (pbo_status >= 0) {
        return;
    }

    uint32_t cur_idx = qatomic_load_acquire(&d->hdr->active_idx);
    uint32_t next_idx = (cur_idx + 1) % FB_SHM_BUF_COUNT;

    glBindFramebuffer(GL_READ_FRAMEBUFFER, d->gl_guest_fb.framebuffer);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, d->gl_blit_fb.framebuffer);
    glViewport(0, 0, rw, rh);
    glBlitFramebuffer(sx1, sy1, sx2, sy2,
                      0, 0, rw, rh,
                      GL_COLOR_BUFFER_BIT, GL_NEAREST);

    egl_fb_read(d->gl_slot_surface[next_idx], &d->gl_blit_fb);
    fb_shm_publish_frame(d, next_idx, rw, rh);
}

static void fb_shm_gl_scanout_disable(DisplayChangeListener *dcl)
{
    FbShmDisplay *d = container_of(dcl, FbShmDisplay, dcl);

    d->gl_scanout = false;
    d->gl_last_frame_ns = 0;
    d->gl_dmabuf = NULL;
    fb_shm_gl_release_fbos(d);
}

static void fb_shm_gl_scanout_texture(DisplayChangeListener *dcl,
                                      uint32_t backing_id,
                                      bool backing_y_0_top,
                                      uint32_t backing_width,
                                      uint32_t backing_height,
                                      uint32_t x, uint32_t y,
                                      uint32_t w, uint32_t h,
                                      void *d3d_tex2d)
{
    FbShmDisplay *d = container_of(dcl, FbShmDisplay, dcl);

    if (!backing_id || !backing_width || !backing_height ||
        x >= backing_width || y >= backing_height) {
        d->gl_scanout = false;
        d->gl_dmabuf = NULL;
#ifdef _WIN32
        fb_shm_gl_forget_d3d_share(d);
#endif
        return;
    }

    d->gl_scanout = true;
    d->gl_dmabuf = NULL;
    d->gl_y0_top = backing_y_0_top;
    d->gl_backing_id = backing_id;
    d->gl_backing_w = backing_width;
    d->gl_backing_h = backing_height;
    d->gl_x = x;
    d->gl_y = y;
    d->gl_w = MIN(w, backing_width - x);
    d->gl_h = MIN(h, backing_height - y);

    if (!d->gl_logged_texture_scanout) {
        info_report("fb-shm: GL texture scanout active "
                    "(%ux%u@%u,%u backing=%ux%u y0_top=%d)",
                    d->gl_w, d->gl_h, d->gl_x, d->gl_y,
                    d->gl_backing_w, d->gl_backing_h,
                    d->gl_y0_top);
        d->gl_logged_texture_scanout = true;
    }

#ifdef _WIN32
    if (!fb_shm_d3d_prepare_share(d, d3d_tex2d)) {
        /*
         * ANGLE 没给 D3D texture 或共享句柄创建失败时，只禁用 GPU
         * metadata；后面的 GL texture -> PBO/SHM 回退仍然照常工作。
         */
        (void)0;
    }
#else
    (void)d3d_tex2d;
#endif

    if (!fb_shm_gl_make_current(d)) {
        return;
    }

    egl_fb_setup_for_tex(&d->gl_guest_fb,
                         backing_width, backing_height, backing_id, false);
}

#ifdef CONFIG_GBM
static void fb_shm_gl_scanout_dmabuf(DisplayChangeListener *dcl,
                                     QemuDmaBuf *dmabuf)
{
    FbShmDisplay *d = container_of(dcl, FbShmDisplay, dcl);
    uint32_t texture;

    if (!dmabuf) {
        d->gl_scanout = false;
        d->gl_dmabuf = NULL;
        return;
    }

    d->gl_scanout = true;
    d->gl_dmabuf = dmabuf;
    d->gl_y0_top = qemu_dmabuf_get_y0_top(dmabuf);
    d->gl_backing_w = qemu_dmabuf_get_backing_width(dmabuf);
    d->gl_backing_h = qemu_dmabuf_get_backing_height(dmabuf);
    d->gl_x = qemu_dmabuf_get_x(dmabuf);
    d->gl_y = qemu_dmabuf_get_y(dmabuf);
    d->gl_w = qemu_dmabuf_get_width(dmabuf);
    d->gl_h = qemu_dmabuf_get_height(dmabuf);

    if (!d->gl_logged_dmabuf_scanout) {
        info_report("fb-shm: dma-buf scanout active "
                    "(%ux%u backing=%ux%u stride=%u fd=%d)",
                    d->gl_w, d->gl_h,
                    d->gl_backing_w, d->gl_backing_h,
                    qemu_dmabuf_get_stride(dmabuf),
                    qemu_dmabuf_get_fd(dmabuf));
        d->gl_logged_dmabuf_scanout = true;
    }

    /*
     * Linux dma-buf 是真正的 GPU 零拷贝来源：GPU consumer 可以直接使用
     * fd，不需要 QEMU 先导入 GL texture。只有 SHM 兼容读回才需要导入；
     * SDL_GL/GLX 路径下 EGL 导入可能不可用，此时仍然保留 GPU metadata。
     */
    if (!fb_shm_gl_make_current(d)) {
        return;
    }
    egl_dmabuf_import_texture(dmabuf);
    texture = qemu_dmabuf_get_texture(dmabuf);
    if (!texture) {
        egl_fb_destroy(&d->gl_guest_fb);
        d->gl_backing_id = 0;
        return;
    }

    d->gl_backing_id = texture;
    egl_fb_setup_for_tex(&d->gl_guest_fb, d->gl_backing_w,
                         d->gl_backing_h, texture, false);
}

static void fb_shm_gl_release_dmabuf(DisplayChangeListener *dcl,
                                     QemuDmaBuf *dmabuf)
{
    FbShmDisplay *d = container_of(dcl, FbShmDisplay, dcl);

    if (d->gl_dmabuf == dmabuf) {
        d->gl_dmabuf = NULL;
    }
    egl_dmabuf_release_texture(dmabuf);
}
#endif

static void fb_shm_gl_update(DisplayChangeListener *dcl,
                             uint32_t x, uint32_t y,
                             uint32_t w, uint32_t h)
{
    FbShmDisplay *d = container_of(dcl, FbShmDisplay, dcl);

    (void)x; (void)y; (void)w; (void)h;
    fb_shm_commit_gl_frame(d);
}
#endif

static void fb_shm_refresh(DisplayChangeListener *dcl)
{
    FbShmDisplay *d = container_of(dcl, FbShmDisplay, dcl);

#ifdef CONFIG_OPENGL
    /*
     * fb-shm 对 GL console 是旁路 consumer，不能在 SDL/GTK 等主显示还没安装
     * GL provider 时先调用 graphic_hw_update()。否则 virtio-gpu/virgl 会在无
     * current context 的线程上进入 epoxy。普通 CPU surface 设备 flags=0，不走
     * 这个等待分支。
     */
    if ((qemu_console_get_graphic_flags(dcl->con) & GRAPHIC_FLAGS_GL) &&
        !console_has_gl(dcl->con)) {
        return;
    }
#endif

    graphic_hw_update(dcl->con);
#ifdef CONFIG_OPENGL
    if (d->gl_scanout) {
        fb_shm_commit_gl_frame(d);
        return;
    }
#endif
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
#ifdef CONFIG_OPENGL
    .dpy_gl_scanout_disable = fb_shm_gl_scanout_disable,
    .dpy_gl_scanout_texture = fb_shm_gl_scanout_texture,
    .dpy_gl_update          = fb_shm_gl_update,
#ifdef CONFIG_GBM
    .dpy_gl_scanout_dmabuf  = fb_shm_gl_scanout_dmabuf,
    .dpy_gl_scanout_dmabuf_update =
        fb_shm_gl_scanout_dmabuf,
    .dpy_gl_release_dmabuf  = fb_shm_gl_release_dmabuf,
#endif
#endif
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
#ifndef _WIN32
    d->memfd = -1;
    d->wake_eventfd = -1;
#endif
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
    d->target_fps = fb_shm_clamp_rate(cfg->rate ? cfg->rate : FB_SHM_DEFAULT_RATE);
    d->shm_target_fps = d->target_fps;
    d->gpu_target_fps = d->target_fps;
    d->blend_cursor = cfg->blend_cursor;

#ifndef _WIN32
    d->wake_eventfd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (d->wake_eventfd < 0) {
        error_setg_errno(errp, errno, "fb-shm: eventfd() failed");
        goto err;
    }
#endif

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
#ifndef _WIN32
    if (d->wake_eventfd >= 0) close(d->wake_eventfd);
#endif
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
#ifdef CONFIG_OPENGL
    fb_shm_gl_release(d);
#endif
    fb_shm_release_mapping(d);
#ifndef _WIN32
    if (d->wake_eventfd >= 0) close(d->wake_eventfd);
#endif
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

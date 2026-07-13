/*
 * fb-shm 显示后端私有接口。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * 本头文件只在 ui/fb-shm-*.c 之间共享生命周期状态和内部函数。
 * 公开线协议仍由 include/ui/fb-shm-abi.h 定义，不扩大公开 ABI。
 * 所有对象均归 QEMU 主线程所有；BH/timer 只延后工作，
 * 不转移所有权，因此无需额外加锁。
 */

#ifndef UI_FB_SHM_INTERNAL_H
#define UI_FB_SHM_INTERNAL_H

#include "qemu/atomic.h"
#include "qemu/main-loop.h"
#include "qemu/notify.h"
#include "qemu/timer.h"
#include "qapi/error.h"
#include "ui/console.h"
#include "ui/fb-shm-abi.h"
#include "ui/fb-shm-gpu.h"
#ifdef CONFIG_OPENGL
#include "ui/egl-helpers.h"
#endif

#ifndef _WIN32
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <linux/memfd.h>
#else
#include <windows.h>
#endif

#define FB_SHM_DEFAULT_RATE        30u
#define FB_SHM_MAX_RATE            240u
#define FB_SHM_MIN_RATE            1u
#define FB_SHM_MAX_DIM             16384u
#define FB_SHM_MAX_REQS_PER_TICK   64u

#ifndef _WIN32
#define FB_SHM_DEFAULT_RUNDIR "/run/qemu"
#else
#define FB_SHM_DEFAULT_RUNDIR "."
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

typedef struct FbShmClient FbShmClient;
typedef struct FbShmDisplay FbShmDisplay;

struct FbShmClient {
    /* 进入 dropping 状态后立即清空 owner，BH 只负责最终释放。 */
    FbShmDisplay *owner;
    int fd;
    /* HELLO 成功后才写入能力，失败协商不改变连接状态。 */
    bool hello_done;
    bool wants_resize_notify;
    bool wants_win32_names;
    bool wants_gpu_frames;
    bool gpu_required;
    bool wants_gpu_sync;
    bool linked;
    bool dropping;
#ifndef _WIN32
    /* 每客户端独享 eventfd，避免多个 reader 竞争同一计数器。 */
    int wake_eventfd;
#else
    /* 每客户端独享 auto-reset event；名称随 ACK 一并传递。 */
    HANDLE wake_event;
    char *wake_event_name;
#endif
    uint8_t request_buf[sizeof(FbShmCtlReq)];
    size_t request_len;
    QLIST_ENTRY(FbShmClient) next;
};

struct FbShmDisplay {
    /* DCL 与配置由 QEMU 主线程串行访问。 */
    DisplayChangeListener dcl;
    QemuConsole *con;

    char *id;
    char *sock_path;
    uint32_t cfg_x;
    uint32_t cfg_y;
    uint32_t cfg_w;
    uint32_t cfg_h;
    uint32_t target_fps;
    uint32_t shm_target_fps;
    uint32_t gpu_target_fps;
    bool blend_cursor;

    /* mapping 容量按完整源画面增长；ROI 只重建 pixman view。 */
    void *shm;
    size_t map_size;
    FbShmHeader *hdr;
    uint8_t *slot[FB_SHM_BUF_COUNT];
    pixman_image_t *slot_img[FB_SHM_BUF_COUNT];
    uint32_t cap_w;
    uint32_t cap_h;
    size_t cap_buf_size;
    uint32_t cur_w;
    uint32_t cur_h;
    uint32_t cur_src_w;
    uint32_t cur_src_h;
    int32_t cur_roi_x;
    int32_t cur_roi_y;
    /* producer 私有真值，绝不从 consumer 可写 header 回读。 */
    uint32_t active_idx;
    uint64_t frame_seq;
    bool surface_present;
    uint64_t shm_last_frame_ns;

#ifndef _WIN32
    int memfd;
#else
    HANDLE map_handle;
    char *map_name;
    uint32_t map_generation;
#endif

#ifdef CONFIG_OPENGL
    /* GL scanout metadata 与私有共享 context/FBO。 */
    bool gl_scanout;
    bool gl_y0_top;
    bool gl_warned_context;
    bool gl_ctx_unusable;
    uint32_t gl_backing_id;
    uint32_t gl_backing_w;
    uint32_t gl_backing_h;
    uint32_t gl_x;
    uint32_t gl_y;
    uint32_t gl_w;
    uint32_t gl_h;
    uint64_t gl_last_frame_ns;
    QEMUGLContext gl_ctx;
    egl_fb gl_guest_fb;
    egl_fb gl_blit_fb;
    QemuDmaBuf *gl_dmabuf;
    FbShmGpuBackend *gl_gpu_backend;
#ifdef _WIN32
    /* keyed-mutex handoff 同时只允许一个同步 consumer 持有。 */
    FbShmClient *d3d_sync_client;
    FbShmGpuPendingFrame d3d_pending;
    bool d3d_gl_blocked;
    QEMUBH *d3d_handoff_bh;
    bool d3d_handoff_scheduled;
    FbShmGpuFrameLayout d3d_handoff_layout;
    QEMUTimer *d3d_reclaim_timer;
    bool d3d_retiring;
    bool d3d_destroying;
#endif
    DisplaySurface *gl_slot_surface[FB_SHM_BUF_COUNT];
    /* 三槽 PBO 环只在主线程推进；队列满时丢样本而不阻塞。 */
    bool gl_pbo_checked;
    bool gl_pbo_supported;
    bool gl_warned_pbo;
    bool gl_logged_texture_scanout;
    bool gl_logged_dmabuf_scanout;
    uint32_t gl_pbo_head;
    uint32_t gl_pbo_tail;
    FbShmGlPbo gl_pbo[FB_SHM_GL_PBO_COUNT];
#endif

    int listen_fd;
    /* handler 用 SAFE 遍历删除节点，真正释放统一延后到 BH。 */
    QLIST_HEAD(, FbShmClient) clients;
};

typedef struct FbShmConfig {
    const char *id;
    const char *sock_path;
    uint32_t x;
    uint32_t y;
    uint32_t w;
    uint32_t h;
    uint32_t rate;
    bool blend_cursor;
} FbShmConfig;

/* 映射、几何和帧布局。 */
size_t fb_shm_frame_bytes(uint32_t w, uint32_t h);
uint64_t fb_shm_now_ns(void);
void fb_shm_resolve_roi(FbShmDisplay *d, uint32_t sw, uint32_t sh,
                        uint32_t *out_w, uint32_t *out_h,
                        int32_t *out_x, int32_t *out_y);
void fb_shm_release_slot_images(FbShmDisplay *d);
void fb_shm_release_mapping(FbShmDisplay *d);
int fb_shm_ensure_geometry(FbShmDisplay *d, uint32_t w, uint32_t h,
                           uint32_t sw, uint32_t sh,
                           int32_t roi_x, int32_t roi_y, Error **errp);
#ifdef _WIN32
char *fb_shm_win32_safe_id(const char *id);
#endif

/* 控制协议和连接生命周期。 */
void fb_shm_client_drop(FbShmClient *c);
uint32_t fb_shm_clamp_rate(uint32_t rate);
uint32_t fb_shm_rate_interval_ms(uint32_t rate);
bool fb_shm_rate_due(uint32_t rate_hz, uint64_t *last_ns,
                     uint64_t now_ns);
bool fb_shm_client_accepts_gpu(const FbShmClient *c);
bool fb_shm_has_gpu_clients(FbShmDisplay *d);
bool fb_shm_has_shm_consumers(FbShmDisplay *d);
void fb_shm_update_effective_rate(FbShmDisplay *d);
int fb_shm_send_ack(FbShmDisplay *d, FbShmClient *c,
                    const FbShmCtlAck *ack, bool include_handles);
int fb_shm_send_gpu_frame(FbShmClient *c,
                          const FbShmGpuFrame *frame, int gpu_fd);
bool fb_shm_client_disconnect_errno(int err);
void fb_shm_broadcast_gpu_frame(FbShmDisplay *d,
                                const FbShmGpuFrame *frame, int gpu_fd);
void fb_shm_broadcast_resize(FbShmDisplay *d);
void fb_shm_dispatch_request(FbShmDisplay *d, FbShmClient *c,
                             const FbShmCtlReq *req);
int fb_shm_open_listener(FbShmDisplay *d, Error **errp);

/* DisplayChangeListener 的 CPU surface 路径。 */
void fb_shm_publish_frame(FbShmDisplay *d, uint32_t next_idx,
                          uint32_t w, uint32_t h);
extern const DisplayChangeListenerOps fb_shm_ops;

#ifdef CONFIG_OPENGL
typedef struct FbShmGlContextGuard {
    FbShmDisplay *display;
    QEMUGLContextState previous;
    bool active;
} FbShmGlContextGuard;

void fb_shm_gl_context_leave(FbShmGlContextGuard *guard);
bool fb_shm_gl_context_enter(FbShmDisplay *d, FbShmGlContextGuard *guard);
void fb_shm_gl_pbo_discard(FbShmDisplay *d, bool delete_buffers);
void fb_shm_gl_pbo_drain(FbShmDisplay *d);
int fb_shm_gl_pbo_issue(FbShmDisplay *d, uint32_t rw, uint32_t rh,
                        int sx1, int sy1, int sx2, int sy2);
void fb_shm_gl_release_fbos(FbShmDisplay *d);
void fb_shm_gl_release(FbShmDisplay *d);
void fb_shm_commit_gl_frame(FbShmDisplay *d);
bool fb_shm_broadcast_direct_gpu_frame(FbShmDisplay *d,
                                       uint32_t w, uint32_t h,
                                       int32_t roi_x, int32_t roi_y);
bool fb_shm_broadcast_context_texture_frame(FbShmDisplay *d,
                                            uint32_t w, uint32_t h,
                                            int32_t roi_x, int32_t roi_y);
void fb_shm_gl_scanout_disable(DisplayChangeListener *dcl);
void fb_shm_gl_scanout_texture(DisplayChangeListener *dcl,
                               uint32_t backing_id,
                               bool backing_y_0_top,
                               uint32_t backing_width,
                               uint32_t backing_height,
                               uint32_t x, uint32_t y,
                               uint32_t w, uint32_t h,
                               void *d3d_tex2d);
#ifdef CONFIG_GBM
void fb_shm_gl_scanout_dmabuf(DisplayChangeListener *dcl,
                              QemuDmaBuf *dmabuf);
void fb_shm_gl_release_dmabuf(DisplayChangeListener *dcl,
                              QemuDmaBuf *dmabuf);
#endif
void fb_shm_gl_update(DisplayChangeListener *dcl,
                      uint32_t x, uint32_t y, uint32_t w, uint32_t h);

#ifdef _WIN32
bool fb_shm_d3d_console_available(FbShmDisplay *d);
bool fb_shm_d3d_console_reserve(FbShmDisplay *d);
void fb_shm_d3d_console_release(FbShmDisplay *d);
void fb_shm_d3d_set_gl_blocked(FbShmDisplay *d, bool blocked);
bool fb_shm_d3d_cancel_pending(FbShmDisplay *d);
void fb_shm_d3d_reclaim_timer_cb(void *opaque);
void fb_shm_d3d_handoff_bh(void *opaque);
#endif

G_DEFINE_AUTO_CLEANUP_CLEAR_FUNC(FbShmGlContextGuard,
                                 fb_shm_gl_context_leave)
#endif

/* QOM 与 -display 两条入口共用同一创建/销毁函数。 */
FbShmDisplay *fb_shm_create(const FbShmConfig *cfg, Error **errp);
void fb_shm_destroy(FbShmDisplay *d);

#endif /* UI_FB_SHM_INTERNAL_H */

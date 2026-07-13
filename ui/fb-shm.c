/*
 * QEMU framebuffer shared-memory display backend.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * 此编译单元只保留实例生命周期和 -display 注册。
 * 映射、控制通道、DCL、OpenGL/GPU 与 QOM 分属私有模块，
 * 公开线协议 ABI 保持不变。
 *
 * 数据路径：guest GPU -> DCL -> ROI/格式转换 -> 非活动 SHM 槽
 * -> 原子发布。控制路径通过 socket 传递 mapping 与唤醒对象。
 * GL sidecar 优先发布 dma-buf/D3D11 元数据；能力不足时回落 SHM。
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qemu/module.h"
#include "fb-shm-internal.h"

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
FbShmDisplay *fb_shm_create(const FbShmConfig *cfg, Error **errp)
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
#endif
    d->listen_fd = -1;
    d->con = con;
    d->dcl.con = con;
    d->dcl.ops = &fb_shm_ops;

    d->id = cfg->id ? g_strdup(cfg->id) : fb_shm_default_id();
#ifdef CONFIG_OPENGL
    d->gl_gpu_backend = fb_shm_gpu_backend_new(d->id);
#ifdef _WIN32
    d->d3d_handoff_bh = qemu_bh_new(fb_shm_d3d_handoff_bh, d);
    d->d3d_reclaim_timer = timer_new_ms(QEMU_CLOCK_REALTIME,
                                        fb_shm_d3d_reclaim_timer_cb, d);
#endif
#endif
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
#ifdef CONFIG_OPENGL
#ifdef _WIN32
    qemu_bh_delete(d->d3d_handoff_bh);
    timer_free(d->d3d_reclaim_timer);
#endif
    fb_shm_gpu_backend_free(d->gl_gpu_backend);
#endif
    g_free(d->id);
    g_free(d->sock_path);
    g_free(d);
    return NULL;
}

void fb_shm_destroy(FbShmDisplay *d)
{
    if (!d) return;
#if defined(_WIN32) && defined(CONFIG_OPENGL)
    d->d3d_destroying = true;
    if (d->d3d_handoff_bh) {
        qemu_bh_delete(d->d3d_handoff_bh);
        d->d3d_handoff_bh = NULL;
        d->d3d_handoff_scheduled = false;
    }
#endif
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
#ifdef _WIN32
    fb_shm_d3d_console_release(d);
#endif
    fb_shm_gpu_backend_free(d->gl_gpu_backend);
#ifdef _WIN32
    timer_free(d->d3d_reclaim_timer);
    d->d3d_reclaim_timer = NULL;
#endif
#endif
    fb_shm_release_mapping(d);
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

/*
 * fb-shm 控制连接、应答与广播基础设施。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * 每个 consumer 独享唤醒对象；连接释放通过一次性 BH 延后，
 * 避免在 QLIST 或 fd handler 回调中回收当前节点。
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "fb-shm-internal.h"

static void fb_shm_client_free_bh(void *opaque);

void fb_shm_client_drop(FbShmClient *c)
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
#ifndef _WIN32
    if (c->wake_eventfd >= 0) {
        close(c->wake_eventfd);
        c->wake_eventfd = -1;
    }
#else
    if (c->wake_event) {
        CloseHandle(c->wake_event);
        c->wake_event = NULL;
    }
    g_clear_pointer(&c->wake_event_name, g_free);
#endif
#if defined(_WIN32) && defined(CONFIG_OPENGL)
    if (c->owner && c->owner->d3d_sync_client == c) {
        /*
         * fd 已关闭，consumer 不会再发送 DONE。
         * 先撤销客户端指针，再非阻塞收回纹理。
         * mutex 未归还时，timer 保留 owner 与 block，
         * 直到跨进程读写竞态消失。
         */
        c->owner->d3d_sync_client = NULL;
        (void)fb_shm_d3d_cancel_pending(c->owner);
    }
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

uint32_t fb_shm_clamp_rate(uint32_t rate)
{
    if (rate < FB_SHM_MIN_RATE) {
        rate = FB_SHM_MIN_RATE;
    }
    if (rate > FB_SHM_MAX_RATE) {
        rate = FB_SHM_MAX_RATE;
    }
    return rate;
}

uint32_t fb_shm_rate_interval_ms(uint32_t rate)
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
int fb_shm_send_ack(FbShmDisplay *d, FbShmClient *c,
                           const FbShmCtlAck *ack, bool include_handles)
{
    struct iovec iov = { .iov_base = (void *)ack, .iov_len = sizeof(*ack) };
    char cbuf[CMSG_SPACE(sizeof(int) * 2)];
    struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
    };
    int fds[2] = { d->memfd, c->wake_eventfd };
    int nfds = (include_handles && d->memfd >= 0 && c->wake_eventfd >= 0) ? 2 : 0;

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

bool fb_shm_win32_ensure_client_event(FbShmDisplay *d, FbShmClient *c,
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

int fb_shm_send_ack(FbShmDisplay *d, FbShmClient *c,
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

bool fb_shm_client_accepts_gpu(const FbShmClient *c)
{
    bool accepts = c->hello_done && c->wants_gpu_frames &&
                   !c->dropping && c->fd >= 0;

#ifdef _WIN32
    /*
     * Windows 原始 D3D11 texture 必须配合 keyed-mutex DONE 协议。
     * 未声明能力的旧 streamer 不接收 GPU handle，仍走 SHM。
     */
    accepts = accepts && c->wants_gpu_sync;
#endif
    return accepts;
}

bool fb_shm_has_gpu_clients(FbShmDisplay *d)
{
    FbShmClient *c;

    QLIST_FOREACH(c, &d->clients, next) {
        if (fb_shm_client_accepts_gpu(c)) {
            return true;
        }
    }
    return false;
}

bool fb_shm_has_shm_consumers(FbShmDisplay *d)
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

void fb_shm_update_effective_rate(FbShmDisplay *d)
{
    uint32_t rate = fb_shm_effective_rate(d);

    d->target_fps = rate;
    if (d->hdr) {
        d->hdr->target_fps = d->shm_target_fps;
    }
    update_displaychangelistener(&d->dcl, fb_shm_rate_interval_ms(rate));
}

#ifndef _WIN32
int fb_shm_send_gpu_frame(FbShmClient *c,
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
int fb_shm_send_gpu_frame(FbShmClient *c,
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

bool fb_shm_client_disconnect_errno(int err)
{
    return err == EPIPE || err == ECONNRESET || err == ENOTCONN;
}

void fb_shm_broadcast_gpu_frame(FbShmDisplay *d,
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

void fb_shm_broadcast_resize(FbShmDisplay *d)
{
#ifndef _WIN32
    if (d->memfd < 0) {
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
#ifndef _WIN32
        if (c->wake_eventfd < 0) {
            continue;
        }
#else
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

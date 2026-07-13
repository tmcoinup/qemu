/*
 * fb-shm 非阻塞监听器与流式请求接收。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * SOCK_STREAM 不保留消息边界；每客户端缓存半包并限制单 tick
 * 请求数，防止慢连接长期占用 QEMU 主事件循环。
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qemu/sockets.h"
#include "fb-shm-internal.h"

static void fb_shm_client_read(void *opaque)
{
    FbShmClient *c = opaque;
    unsigned int handled = 0;

    /*
     * 中文注释：SOCK_STREAM 不保留消息边界，一份 32 字节请求可能被拆成任意
     * 多次 recv，也可能与后续请求粘在一起。每客户端缓存未完成尾部，并持续
     * 读取到 EAGAIN；每轮限制处理数量，防止恶意连接长期占住主事件循环。
     */
    while (!c->dropping && c->fd >= 0 && c->owner &&
           handled < FB_SHM_MAX_REQS_PER_TICK) {
        size_t remaining = sizeof(c->request_buf) - c->request_len;
        ssize_t r;

        do {
            r = recv(c->fd, (char *)c->request_buf + c->request_len,
                     remaining, 0);
        } while (r < 0 && errno == EINTR);

        if (r == 0) {
            fb_shm_client_drop(c);
            return;
        }
        if (r < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                return;
            }
            fb_shm_client_drop(c);
            return;
        }

        c->request_len += r;
        if (c->request_len < sizeof(c->request_buf)) {
            continue;
        }

        FbShmCtlReq req;
        memcpy(&req, c->request_buf, sizeof(req));
        c->request_len = 0;
        handled++;
        fb_shm_dispatch_request(c->owner, c, &req);
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
    /*
     * QEMU 11 统一通过 qemu_set_blocking() 修改描述符状态；若切换失败，
     * 立即关闭新连接，避免把阻塞套接字注册到主事件循环后卡住虚拟机。
     */
    Error *local_err = NULL;
    if (!qemu_set_blocking(cfd, false, &local_err)) {
        warn_report_err(local_err);
        qemu_close(cfd);
        return;
    }
    FbShmClient *c = g_new0(FbShmClient, 1);
    c->owner = d;
    c->fd = cfd;
#ifndef _WIN32
    /* 每个客户端独占 eventfd counter；不能从 display 级 eventfd dup。 */
    c->wake_eventfd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (c->wake_eventfd < 0) {
        warn_report("fb-shm: client eventfd() failed: %s", strerror(errno));
        qemu_close(cfd);
        g_free(c);
        return;
    }
#endif
    c->linked = true;
    QLIST_INSERT_HEAD(&d->clients, c, next);
    qemu_set_fd_handler(cfd, fb_shm_client_read, NULL, c);
}

int fb_shm_open_listener(FbShmDisplay *d, Error **errp)
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
    /* 监听套接字必须非阻塞，否则一次伪唤醒就可能阻塞主事件循环。 */
    if (!qemu_set_blocking(fd, false, errp)) {
        qemu_close(fd);
        return -1;
    }
#ifndef _WIN32
    /* World-readable so non-root consumers can connect; tighten if needed. */
    chmod(d->sock_path, 0660);
#endif
    d->listen_fd = fd;
    qemu_set_fd_handler(fd, fb_shm_listener_accept, NULL, d);
    return 0;
}

/*
 * QMP multi-client listener.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"

#include "chardev/char-socket.h"
#include "monitor/monitor.h"
#include "qapi/error.h"
#include "qapi/qapi-types-char.h"
#include "qemu/error-report.h"

typedef struct QMPMultiServer {
    Chardev *listener;
    bool pretty;
    unsigned int next_client;
} QMPMultiServer;

static Chardev *qmp_multi_new_client_chardev(QMPMultiServer *server,
                                             Error **errp)
{
    g_autofree char *id = NULL;
    ChardevBackend backend = { .type = CHARDEV_BACKEND_KIND_SOCKET };
    ChardevSocket sock = { 0 };
    SocketAddressLegacy addr = { 0 };
    char empty_fd[] = "";
    FdSocketAddress fd = { .str = empty_fd };

    /*
     * 每个下游连接都包装成一个“已断开、等待 qemu_chr_add_client() 填 fd”的
     * 普通 socket chardev。这样后面的 QMP monitor 可以复用现有
     * monitor_init_qmp()、请求队列、OOB、事件广播等路径，不需要另写一套
     * JSON RPC 调度器，也不会和单连接 QMP 的行为分叉。
     */
    addr.type = SOCKET_ADDRESS_TYPE_FD;
    addr.u.fd.data = &fd;
    sock.addr = &addr;
    sock.has_server = true;
    sock.server = true;
    sock.has_wait = true;
    sock.wait = false;
    backend.u.socket.data = &sock;

    id = g_strdup_printf("qmp-multi-%s-%u",
                         server->listener->label ? server->listener->label
                                                 : "listener",
                         server->next_client++);

    return qemu_chardev_new(id, TYPE_CHARDEV_SOCKET, &backend, NULL, errp);
}

static void qmp_multi_accept(QIONetListener *listener,
                             QIOChannelSocket *sioc,
                             gpointer opaque)
{
    QMPMultiServer *server = opaque;
    Error *local_err = NULL;
    Chardev *chr;
    int fd;

    /*
     * QIONetListener 在回调返回后会释放 sioc；复制 fd 后交给 child chardev，
     * 连接生命周期就完全由 child chardev/monitor 管理。
     */
    fd = qemu_dup(sioc->fd);
    if (fd < 0) {
        error_report("QMP multi-client: failed to duplicate accepted fd: %s",
                     strerror(errno));
        return;
    }

    chr = qmp_multi_new_client_chardev(server, &local_err);
    if (!chr) {
        error_report_err(local_err);
        close(fd);
        return;
    }

    if (qemu_chr_add_client(chr, fd) < 0) {
        error_report("QMP multi-client: failed to attach accepted fd");
        object_unparent(OBJECT(chr));
        close(fd);
        return;
    }

    monitor_init_qmp(chr, server->pretty, &local_err);
    if (local_err) {
        error_report_err(local_err);
        object_unparent(OBJECT(chr));
    }
}

void monitor_init_qmp_multi(Chardev *chr, bool pretty, Error **errp)
{
    QMPMultiServer *server;

    if (!qemu_chr_socket_is_multi(chr)) {
        error_setg(errp, "QMP multi-client monitor requires a "
                   "socket chardev with multi=on");
        return;
    }

    /*
     * listener chardev 自己不绑定 monitor frontend；它只负责持续 accept。
     * accepted fd 会被拆成独立 QMP monitor，所以并发 client 之间天然隔离：
     * 每个 client 单独 capabilities 握手、单独响应自己的 id，QAPI 事件则沿用
     * 现有 monitor_qapi_event_emit() 广播给所有已完成握手的 QMP monitor。
     */
    server = g_new0(QMPMultiServer, 1);
    server->listener = chr;
    server->pretty = pretty;

    qemu_chr_socket_set_multi_client_func(chr, qmp_multi_accept, server,
                                          g_free, NULL);
}

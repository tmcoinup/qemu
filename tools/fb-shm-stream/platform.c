/*
 * Native fb-shm platform transport.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Linux 侧使用 Unix socket + SCM_RIGHTS 传递 memfd/eventfd；Windows 侧
 * 使用 AF_UNIX 控制连接传递命名对象，再用 OpenFileMapping/OpenEvent
 * 打开共享内存和帧通知事件。主程序只依赖这里暴露的统一接口。
 */

#include "common.h"

void fb_shm_stream_die(const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

int fb_shm_stream_send_all(FbShmStreamSocket fd, const void *buf, size_t len)
{
    const uint8_t *p = buf;

    while (len) {
#ifdef _WIN32
        int n = send(fd, (const char *)p, (int)len, 0);
#else
        ssize_t n = send(fd, p, len, 0);
#endif
        if (n <= 0) {
            return -1;
        }
        p += n;
        len -= n;
    }
    return 0;
}

int fb_shm_stream_recv_all(FbShmStreamSocket fd, void *buf, size_t len)
{
    uint8_t *p = buf;

    while (len) {
#ifdef _WIN32
        int n = recv(fd, (char *)p, (int)len, 0);
#else
        ssize_t n = recv(fd, p, len, 0);
#endif
        if (n <= 0) {
            return -1;
        }
        p += n;
        len -= n;
    }
    return 0;
}

FbShmCtlReq fb_shm_stream_ctl_req(uint32_t op)
{
    FbShmCtlReq req;

    memset(&req, 0, sizeof(req));
    req.magic = FB_SHM_MAGIC;
    req.op = op;
    return req;
}

void fb_shm_stream_ctl_expect_ok(FbShmStreamSocket fd, uint32_t op)
{
    FbShmCtlAck ack;

    if (fb_shm_stream_recv_all(fd, &ack, sizeof(ack)) < 0 ||
        ack.magic != FB_SHM_MAGIC || ack.op != op ||
        ack.status != FB_SHM_CTL_OK) {
        fb_shm_stream_die("fb-shm control op %u failed", op);
    }
}

void fb_shm_stream_close_mapping(Mapping *m)
{
    if (!m->base) {
        return;
    }
#ifdef _WIN32
    UnmapViewOfFile(m->base);
    CloseHandle(m->map_handle);
    CloseHandle(m->event_handle);
#else
    munmap(m->base, m->size);
    close(m->memfd);
    close(m->eventfd);
#endif
    memset(m, 0, sizeof(*m));
#ifndef _WIN32
    m->memfd = -1;
    m->eventfd = -1;
#endif
}

#ifdef _WIN32
static void fb_shm_stream_map_from_names(Mapping *m,
                                         const FbShmWin32Names *names,
                                         size_t sz)
{
    fb_shm_stream_close_mapping(m);
    m->map_handle = OpenFileMappingA(FILE_MAP_READ, FALSE,
                                     names->mapping_name);
    if (!m->map_handle) {
        fb_shm_stream_die("OpenFileMappingA failed for %s",
                          names->mapping_name);
    }
    m->event_handle = OpenEventA(SYNCHRONIZE, FALSE, names->event_name);
    if (!m->event_handle) {
        fb_shm_stream_die("OpenEventA failed for %s", names->event_name);
    }
    m->base = MapViewOfFile(m->map_handle, FILE_MAP_READ, 0, 0, sz);
    if (!m->base) {
        fb_shm_stream_die("MapViewOfFile failed");
    }
    m->size = sz;
}
#else
static void fb_shm_stream_map_from_fds(Mapping *m, int memfd, int eventfd,
                                       size_t sz)
{
    fb_shm_stream_close_mapping(m);
    m->base = mmap(NULL, sz, PROT_READ, MAP_SHARED, memfd, 0);
    if (m->base == MAP_FAILED) {
        fb_shm_stream_die("mmap fb-shm failed: %s", strerror(errno));
    }
    m->size = sz;
    m->memfd = memfd;
    m->eventfd = eventfd;
}
#endif

FbShmStreamSocket fb_shm_stream_connect_unix_socket(const char *path)
{
    FbShmStreamSocket fd;
    struct sockaddr_un sa;

#ifdef _WIN32
    WSADATA data;

    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
        fb_shm_stream_die("WSAStartup failed");
    }
#endif
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd == FB_SHM_STREAM_INVALID_SOCKET) {
        fb_shm_stream_die("socket(AF_UNIX) failed");
    }
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(sa.sun_path)) {
        fb_shm_stream_die("socket path too long: %s", path);
    }
    strcpy(sa.sun_path, path);
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        fb_shm_stream_die("connect %s failed", path);
    }
    return fd;
}

static void fb_shm_stream_set_sock_blocking(FbShmStreamSocket fd, bool blocking)
{
#ifdef _WIN32
    u_long mode = blocking ? 0 : 1;

    ioctlsocket(fd, FIONBIO, &mode);
#else
    int flags = fcntl(fd, F_GETFL, 0);

    if (flags >= 0) {
        if (blocking) {
            flags &= ~O_NONBLOCK;
        } else {
            flags |= O_NONBLOCK;
        }
        fcntl(fd, F_SETFL, flags);
    }
#endif
}

void fb_shm_stream_set_sock_nonblock(FbShmStreamSocket fd)
{
    fb_shm_stream_set_sock_blocking(fd, false);
}

void fb_shm_stream_close_socket(FbShmStreamSocket fd)
{
    if (fd == FB_SHM_STREAM_INVALID_SOCKET) {
        return;
    }
#ifdef _WIN32
    closesocket(fd);
#else
    close(fd);
#endif
}

void fb_shm_stream_cleanup_network(void)
{
#ifdef _WIN32
    WSACleanup();
#endif
}

#ifndef _WIN32
static void fb_shm_stream_hello_posix(Session *s)
{
    FbShmCtlReq req = fb_shm_stream_ctl_req(FB_SHM_CTL_HELLO);
    FbShmCtlAck ack;
    char cbuf[CMSG_SPACE(sizeof(int) * 2)];
    struct iovec iov = { .iov_base = &ack, .iov_len = sizeof(ack) };
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1,
                          .msg_control = cbuf,
                          .msg_controllen = sizeof(cbuf) };
    int fds[2] = { -1, -1 };

    req.flags = FB_SHM_HELLO_F_RESIZE_NOTIFY;
    if (fb_shm_stream_send_all(s->sock, &req, sizeof(req)) < 0 ||
        recvmsg(s->sock, &msg, 0) != sizeof(ack) ||
        ack.magic != FB_SHM_MAGIC || ack.status != FB_SHM_CTL_OK) {
        fb_shm_stream_die("fb-shm HELLO failed");
    }
    for (struct cmsghdr *cm = CMSG_FIRSTHDR(&msg); cm;
         cm = CMSG_NXTHDR(&msg, cm)) {
        if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS) {
            memcpy(fds, CMSG_DATA(cm), sizeof(fds));
        }
    }
    if (fds[0] < 0 || fds[1] < 0) {
        fb_shm_stream_die("fb-shm HELLO missing fds");
    }
    fb_shm_stream_map_from_fds(&s->map, fds[0], fds[1], ack.shm_size);
}

static bool fb_shm_stream_try_resize_posix(Session *s)
{
    FbShmCtlAck ack;
    char cbuf[CMSG_SPACE(sizeof(int) * 2)];
    struct iovec iov = { .iov_base = &ack, .iov_len = sizeof(ack) };
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1,
                          .msg_control = cbuf,
                          .msg_controllen = sizeof(cbuf) };
    int fds[2] = { -1, -1 };
    ssize_t n = recvmsg(s->sock, &msg, MSG_DONTWAIT);

    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        return false;
    }
    if (n != sizeof(ack) || ack.magic != FB_SHM_MAGIC ||
        ack.op != FB_SHM_CTL_NOTIFY_RESIZED || ack.status != FB_SHM_CTL_OK) {
        return false;
    }
    for (struct cmsghdr *cm = CMSG_FIRSTHDR(&msg); cm;
         cm = CMSG_NXTHDR(&msg, cm)) {
        if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS) {
            memcpy(fds, CMSG_DATA(cm), sizeof(fds));
        }
    }
    if (fds[0] >= 0 && fds[1] >= 0) {
        fb_shm_stream_map_from_fds(&s->map, fds[0], fds[1], ack.shm_size);
        s->last_seq = 0;
        return true;
    }
    return false;
}
#else
static void fb_shm_stream_hello_win32(Session *s)
{
    FbShmCtlReq req = fb_shm_stream_ctl_req(FB_SHM_CTL_HELLO);
    FbShmCtlAck ack;
    FbShmWin32Names names;

    req.flags = FB_SHM_HELLO_F_RESIZE_NOTIFY | FB_SHM_HELLO_F_WIN32_NAMES;
    if (fb_shm_stream_send_all(s->sock, &req, sizeof(req)) < 0 ||
        fb_shm_stream_recv_all(s->sock, &ack, sizeof(ack)) < 0 ||
        ack.magic != FB_SHM_MAGIC || ack.status != FB_SHM_CTL_OK ||
        fb_shm_stream_recv_all(s->sock, &names, sizeof(names)) < 0 ||
        names.magic != FB_SHM_MAGIC) {
        fb_shm_stream_die("fb-shm HELLO failed");
    }
    fb_shm_stream_map_from_names(&s->map, &names, ack.shm_size);
}

static bool fb_shm_stream_try_resize_win32(Session *s)
{
    FbShmCtlAck ack;
    FbShmWin32Names names;
    fd_set rfds;
    struct timeval tv = { 0, 0 };
    int rc;

    FD_ZERO(&rfds);
    FD_SET(s->sock, &rfds);
    rc = select(0, &rfds, NULL, NULL, &tv);
    if (rc <= 0) {
        return false;
    }

    /*
     * 控制 socket 平时是 non-blocking，检测到可读后临时切回 blocking，
     * 保证 ack 与固定长度名称 payload 都完整读到，避免 stream 分片。
     */
    fb_shm_stream_set_sock_blocking(s->sock, true);
    if (fb_shm_stream_recv_all(s->sock, &ack, sizeof(ack)) < 0 ||
        ack.magic != FB_SHM_MAGIC ||
        ack.op != FB_SHM_CTL_NOTIFY_RESIZED ||
        ack.status != FB_SHM_CTL_OK ||
        fb_shm_stream_recv_all(s->sock, &names, sizeof(names)) < 0 ||
        names.magic != FB_SHM_MAGIC) {
        fb_shm_stream_set_sock_nonblock(s->sock);
        return false;
    }
    fb_shm_stream_set_sock_nonblock(s->sock);
    fb_shm_stream_map_from_names(&s->map, &names, ack.shm_size);
    s->last_seq = 0;
    return true;
}
#endif

void fb_shm_stream_hello(Session *s)
{
#ifdef _WIN32
    fb_shm_stream_hello_win32(s);
#else
    fb_shm_stream_hello_posix(s);
#endif
}

bool fb_shm_stream_try_resize(Session *s)
{
#ifdef _WIN32
    return fb_shm_stream_try_resize_win32(s);
#else
    return fb_shm_stream_try_resize_posix(s);
#endif
}

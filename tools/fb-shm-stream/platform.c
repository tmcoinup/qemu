/*
 * Native fb-shm platform transport.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Linux uses AF_UNIX plus SCM_RIGHTS for memfd/eventfd/dma-buf.  Windows
 * uses AF_UNIX control records plus named mappings, events and D3D textures.
 * Both transports are byte streams: the incremental decoder below never
 * assumes that one send/sendmsg maps to one recv/recvmsg.
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

static bool fb_shm_stream_interrupted(void)
{
#ifdef _WIN32
    return WSAGetLastError() == WSAEINTR;
#else
    return errno == EINTR;
#endif
}

static bool fb_shm_stream_would_block(void)
{
#ifdef _WIN32
    int err = WSAGetLastError();

    return err == WSAEWOULDBLOCK;
#else
    return errno == EAGAIN || errno == EWOULDBLOCK;
#endif
}

int fb_shm_stream_send_all(FbShmStreamSocket fd, const void *buf, size_t len)
{
    const uint8_t *p = buf;

    while (len) {
#ifdef _WIN32
        int n = send(fd, (const char *)p, (int)len, 0);
#else
        ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
#endif
        if (n < 0 && fb_shm_stream_interrupted()) {
            continue;
        }
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
        if (n < 0 && fb_shm_stream_interrupted()) {
            continue;
        }
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

void fb_shm_stream_close_mapping(Mapping *m)
{
#ifdef _WIN32
    if (m->base) {
        UnmapViewOfFile(m->base);
    }
    if (m->map_handle) {
        CloseHandle(m->map_handle);
    }
    if (m->event_handle) {
        CloseHandle(m->event_handle);
    }
#else
    if (m->base) {
        munmap(m->base, m->size);
    }
    if (m->memfd >= 0) {
        close(m->memfd);
    }
    if (m->eventfd >= 0) {
        close(m->eventfd);
    }
#endif
    memset(m, 0, sizeof(*m));
#ifndef _WIN32
    m->memfd = -1;
    m->eventfd = -1;
#endif
}

void fb_shm_stream_close_gpu_frame(Session *s)
{
#ifndef _WIN32
    if (s->gpu_fd >= 0) {
        close(s->gpu_fd);
        s->gpu_fd = -1;
    }
#endif
    memset(&s->gpu_frame, 0, sizeof(s->gpu_frame));
    s->gpu_frame_ready = false;
}

#ifdef _WIN32
static bool fb_shm_stream_win32_name_valid(const char *name)
{
    return name[0] && memchr(name, '\0', FB_SHM_WIN32_NAME_MAX);
}

static void fb_shm_stream_map_from_names(Mapping *m,
                                         const FbShmWin32Names *names,
                                         size_t sz)
{
    Mapping next = { 0 };

    if (!sz || names->magic != FB_SHM_MAGIC ||
        names->version != FB_SHM_VERSION ||
        names->size != sizeof(*names) ||
        !fb_shm_stream_win32_name_valid(names->mapping_name) ||
        !fb_shm_stream_win32_name_valid(names->event_name)) {
        fb_shm_stream_die("invalid fb-shm Win32 mapping descriptor");
    }

    next.map_handle = OpenFileMappingA(FILE_MAP_READ, FALSE,
                                       names->mapping_name);
    if (!next.map_handle) {
        fb_shm_stream_die("OpenFileMappingA failed for %s",
                          names->mapping_name);
    }
    next.event_handle = OpenEventA(SYNCHRONIZE, FALSE, names->event_name);
    if (!next.event_handle) {
        CloseHandle(next.map_handle);
        fb_shm_stream_die("OpenEventA failed for %s", names->event_name);
    }
    next.base = MapViewOfFile(next.map_handle, FILE_MAP_READ, 0, 0, sz);
    if (!next.base) {
        CloseHandle(next.event_handle);
        CloseHandle(next.map_handle);
        fb_shm_stream_die("MapViewOfFile failed");
    }
    next.size = sz;
    fb_shm_stream_close_mapping(m);
    *m = next;
}
#else
static void fb_shm_stream_map_from_fds(Mapping *m, int memfd, int eventfd,
                                       size_t sz)
{
    Mapping next = {
        .size = sz,
        .memfd = memfd,
        .eventfd = eventfd,
    };

    if (!sz || memfd < 0 || eventfd < 0) {
        fb_shm_stream_die("invalid fb-shm POSIX mapping descriptor");
    }
    next.base = mmap(NULL, sz, PROT_READ, MAP_SHARED, memfd, 0);
    if (next.base == MAP_FAILED) {
        close(memfd);
        close(eventfd);
        fb_shm_stream_die("mmap fb-shm failed: %s", strerror(errno));
    }
    fb_shm_stream_close_mapping(m);
    *m = next;
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
#ifdef _WIN32
    if (!SetHandleInformation((HANDLE)fd, HANDLE_FLAG_INHERIT, 0)) {
        fb_shm_stream_close_socket(fd);
        fb_shm_stream_die("failed to make AF_UNIX socket non-inheritable");
    }
#else
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
        close(fd);
        fb_shm_stream_die("fcntl(FD_CLOEXEC) failed: %s", strerror(errno));
    }
#endif
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

    if (ioctlsocket(fd, FIONBIO, &mode) != 0) {
        fb_shm_stream_die("ioctlsocket(FIONBIO) failed");
    }
#else
    int flags = fcntl(fd, F_GETFL, 0);

    if (flags < 0) {
        fb_shm_stream_die("fcntl(F_GETFL) failed: %s", strerror(errno));
    }
    if (blocking) {
        flags &= ~O_NONBLOCK;
    } else {
        flags |= O_NONBLOCK;
    }
    if (fcntl(fd, F_SETFL, flags) < 0) {
        fb_shm_stream_die("fcntl(F_SETFL) failed: %s", strerror(errno));
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

static void fb_shm_stream_control_close_fds(ControlRx *rx)
{
#ifndef _WIN32
    for (size_t i = 0; i < rx->nfds; i++) {
        if (rx->fds[i] >= 0) {
            close(rx->fds[i]);
        }
    }
    rx->nfds = 0;
    rx->fds[0] = -1;
    rx->fds[1] = -1;
#else
    (void)rx;
#endif
}

void fb_shm_stream_control_init(Session *s)
{
    ControlRx *rx = &s->control_rx;

    if (rx->initialized) {
        fb_shm_stream_control_close_fds(rx);
    }
    memset(rx, 0, sizeof(*rx));
    rx->initialized = true;
#ifndef _WIN32
    rx->fds[0] = -1;
    rx->fds[1] = -1;
#endif
}

static void fb_shm_stream_control_reset(Session *s)
{
    fb_shm_stream_control_init(s);
}

static size_t
fb_shm_stream_control_payload_size(const FbShmCtlAck *ack)
{
    if (ack->magic != FB_SHM_MAGIC) {
        fb_shm_stream_die("invalid fb-shm control magic");
    }
    switch (ack->op) {
    case FB_SHM_CTL_HELLO:
    case FB_SHM_CTL_NOTIFY_RESIZED:
#ifdef _WIN32
        return ack->status == FB_SHM_CTL_OK && ack->shm_size ?
               sizeof(FbShmWin32Names) : 0;
#else
        return 0;
#endif
    case FB_SHM_CTL_NOTIFY_GPU_FRAME:
        return ack->status == FB_SHM_CTL_OK ? sizeof(FbShmGpuFrame) : 0;
    case FB_SHM_CTL_SET_ROI:
    case FB_SHM_CTL_SET_RATE:
    case FB_SHM_CTL_BYE:
        return 0;
    default:
        fb_shm_stream_die("unknown fb-shm control op %u", ack->op);
    }
    return 0;
}

#ifndef _WIN32
static void fb_shm_stream_control_collect_fds(ControlRx *rx,
                                               struct msghdr *msg)
{
    struct cmsghdr *cm;

    if (msg->msg_flags & MSG_CTRUNC) {
        fb_shm_stream_die("fb-shm control SCM_RIGHTS was truncated");
    }
    for (cm = CMSG_FIRSTHDR(msg); cm; cm = CMSG_NXTHDR(msg, cm)) {
        size_t bytes;
        size_t count;
        int *fds;

        if (cm->cmsg_level != SOL_SOCKET || cm->cmsg_type != SCM_RIGHTS) {
            continue;
        }
        if (cm->cmsg_len < CMSG_LEN(0)) {
            fb_shm_stream_die("invalid fb-shm SCM_RIGHTS header");
        }
        bytes = cm->cmsg_len - CMSG_LEN(0);
        count = bytes / sizeof(int);
        fds = (int *)CMSG_DATA(cm);
        for (size_t i = 0; i < count; i++) {
            if (rx->nfds >= 2) {
                close(fds[i]);
                fb_shm_stream_die("too many fds in fb-shm control record");
            }
            rx->fds[rx->nfds++] = fds[i];
            (void)fcntl(fds[i], F_SETFD, FD_CLOEXEC);
        }
    }
}
#endif

/*
 * Return one complete control record, or false when a nonblocking socket has
 * no more bytes.  Reads are capped at the remaining ACK/payload size, so a
 * following ACK can never be swallowed into the current record's payload.
 */
static bool fb_shm_stream_control_read(Session *s, bool blocking)
{
    ControlRx *rx = &s->control_rx;

    if (!rx->initialized) {
        fb_shm_stream_control_init(s);
    }
    for (;;) {
        uint8_t *dst;
        size_t remaining;
        ssize_t n;

        if (rx->ack_bytes < sizeof(rx->ack)) {
            dst = (uint8_t *)&rx->ack + rx->ack_bytes;
            remaining = sizeof(rx->ack) - rx->ack_bytes;
        } else if (rx->payload_bytes < rx->payload_size) {
            dst = (uint8_t *)&rx->payload + rx->payload_bytes;
            remaining = rx->payload_size - rx->payload_bytes;
        } else {
            return true;
        }

#ifdef _WIN32
        n = recv(s->sock, (char *)dst, (int)remaining, 0);
#else
        {
            char cbuf[CMSG_SPACE(sizeof(int) * 2)] = { 0 };
            struct iovec iov = {
                .iov_base = dst,
                .iov_len = remaining,
            };
            struct msghdr msg = {
                .msg_iov = &iov,
                .msg_iovlen = 1,
                .msg_control = cbuf,
                .msg_controllen = sizeof(cbuf),
            };
            int flags = 0;

#ifdef MSG_CMSG_CLOEXEC
            flags |= MSG_CMSG_CLOEXEC;
#endif
            n = recvmsg(s->sock, &msg, flags);
            if (n > 0) {
                fb_shm_stream_control_collect_fds(rx, &msg);
            }
        }
#endif
        if (n < 0 && fb_shm_stream_interrupted()) {
            continue;
        }
        if (n < 0 && fb_shm_stream_would_block()) {
            if (!blocking) {
                return false;
            }
#ifdef _WIN32
            {
                fd_set rfds;

                FD_ZERO(&rfds);
                FD_SET(s->sock, &rfds);
                if (select(0, &rfds, NULL, NULL, NULL) <= 0) {
                    fb_shm_stream_die("fb-shm control wait failed");
                }
            }
#else
            {
                struct pollfd pfd = {
                    .fd = s->sock,
                    .events = POLLIN,
                };

                if (poll(&pfd, 1, -1) <= 0) {
                    fb_shm_stream_die("fb-shm control wait failed");
                }
            }
#endif
            continue;
        }
        if (n == 0) {
            fb_shm_stream_die("fb-shm control socket closed");
        }
        if (n < 0) {
            fb_shm_stream_die("fb-shm control receive failed");
        }

        if (rx->ack_bytes < sizeof(rx->ack)) {
            rx->ack_bytes += (size_t)n;
            if (rx->ack_bytes == sizeof(rx->ack)) {
                rx->payload_size =
                    fb_shm_stream_control_payload_size(&rx->ack);
            }
        } else {
            rx->payload_bytes += (size_t)n;
        }
    }
}

static void fb_shm_stream_apply_mapping(Session *s,
                                        const FbShmCtlAck *ack)
{
    ControlRx *rx = &s->control_rx;

#ifdef _WIN32
    if (!ack->shm_size ||
        rx->payload_size != sizeof(FbShmWin32Names) ||
        rx->payload_bytes != sizeof(FbShmWin32Names)) {
        fb_shm_stream_die("fb-shm mapping record is missing Win32 names");
    }
    fb_shm_stream_map_from_names(&s->map, &rx->payload.names,
                                 ack->shm_size);
#else
    if (!ack->shm_size || rx->nfds != 2) {
        fb_shm_stream_die("fb-shm mapping record requires memfd and eventfd");
    }
    {
        int memfd = rx->fds[0];
        int eventfd = rx->fds[1];

        rx->fds[0] = -1;
        rx->fds[1] = -1;
        rx->nfds = 0;
        fb_shm_stream_map_from_fds(&s->map, memfd, eventfd,
                                   ack->shm_size);
    }
#endif
    s->last_seq = 0;
    s->shm_ready = true;
}

static void fb_shm_stream_apply_gpu_frame(Session *s,
                                          const FbShmCtlAck *ack)
{
    ControlRx *rx = &s->control_rx;
    FbShmGpuFrame *gpu = &rx->payload.gpu;
    FbShmStreamGpuStatus status;
    bool has_handle = false;

    if (ack->shm_size != sizeof(*gpu) ||
        rx->payload_size != sizeof(*gpu) ||
        rx->payload_bytes != sizeof(*gpu)) {
        s->gpu_error = FB_SHM_STREAM_GPU_E_WIRE;
        s->gpu_error_logged = false;
        return;
    }
#ifndef _WIN32
    has_handle = rx->nfds == 1;
#endif
    status = fb_shm_stream_gpu_validate_frame(gpu, has_handle);
    if (status != FB_SHM_STREAM_GPU_OK) {
        s->gpu_error = status;
        s->gpu_error_logged = false;
        return;
    }

    fb_shm_stream_close_gpu_frame(s);
    s->gpu_frame = *gpu;
#ifndef _WIN32
    s->gpu_fd = rx->fds[0];
    rx->fds[0] = -1;
    rx->nfds = 0;
#endif
    s->gpu_frame_ready = true;
    s->gpu_error = FB_SHM_STREAM_GPU_OK;
}

static void fb_shm_stream_control_apply(Session *s)
{
    ControlRx *rx = &s->control_rx;
    const FbShmCtlAck *ack = &rx->ack;

    switch (ack->op) {
    case FB_SHM_CTL_HELLO:
        if (ack->shm_size) {
            fb_shm_stream_apply_mapping(s, ack);
        }
        break;
    case FB_SHM_CTL_NOTIFY_RESIZED:
        fb_shm_stream_apply_mapping(s, ack);
        break;
    case FB_SHM_CTL_NOTIFY_GPU_FRAME:
        fb_shm_stream_apply_gpu_frame(s, ack);
        break;
    case FB_SHM_CTL_SET_ROI:
    case FB_SHM_CTL_SET_RATE:
    case FB_SHM_CTL_BYE:
        break;
    default:
        fb_shm_stream_die("unknown fb-shm control op %u", ack->op);
    }
}

void fb_shm_stream_ctl_expect_ok(Session *s, uint32_t op)
{
    for (;;) {
        uint32_t received_op;
        uint32_t status;

        (void)fb_shm_stream_control_read(s, true);
        received_op = s->control_rx.ack.op;
        status = s->control_rx.ack.status;

        if (status != FB_SHM_CTL_OK) {
            fb_shm_stream_die("fb-shm control op %u failed: status=%u",
                              received_op, status);
        }
        if (received_op == FB_SHM_CTL_NOTIFY_RESIZED ||
            received_op == FB_SHM_CTL_NOTIFY_GPU_FRAME) {
            fb_shm_stream_control_apply(s);
            fb_shm_stream_control_reset(s);
            continue;
        }
        if (received_op != op) {
            fb_shm_stream_die("fb-shm control framing error: expected op %u, "
                              "received op %u", op, received_op);
        }
        fb_shm_stream_control_apply(s);
        fb_shm_stream_control_reset(s);
        return;
    }
}

static uint32_t fb_shm_stream_hello_flags(StreamMode mode)
{
    uint32_t flags = FB_SHM_HELLO_F_RESIZE_NOTIFY;

    /*
     * AUTO only subscribes when this binary can consume GPU handles.  Merely
     * finding an NVENC-capable ffmpeg CLI does not make its rawvideo stdin a
     * native handle-import path.
     */
    if (mode == STREAM_MODE_GPU ||
        (mode == STREAM_MODE_AUTO &&
         fb_shm_stream_gpu_backend_available())) {
        flags |= FB_SHM_HELLO_F_GPU_FRAMES;
    }
    if (mode == STREAM_MODE_GPU) {
        flags |= FB_SHM_HELLO_F_GPU_REQUIRED;
    }
#ifdef _WIN32
    flags |= FB_SHM_HELLO_F_WIN32_NAMES;
#endif
    return flags;
}

void fb_shm_stream_hello(Session *s, StreamMode mode)
{
    FbShmCtlReq req = fb_shm_stream_ctl_req(FB_SHM_CTL_HELLO);

    req.flags = fb_shm_stream_hello_flags(mode);
    if (fb_shm_stream_send_all(s->sock, &req, sizeof(req)) < 0) {
        fb_shm_stream_die("fb-shm HELLO send failed");
    }
    fb_shm_stream_ctl_expect_ok(s, FB_SHM_CTL_HELLO);
    if (!s->shm_ready && mode != STREAM_MODE_GPU) {
        fb_shm_stream_die("fb-shm HELLO missing shared-memory mapping");
    }
}

bool fb_shm_stream_try_control(Session *s)
{
    uint32_t op;
    uint32_t status;

    if (!fb_shm_stream_control_read(s, false)) {
        return false;
    }
    op = s->control_rx.ack.op;
    status = s->control_rx.ack.status;
    if (status != FB_SHM_CTL_OK) {
        fb_shm_stream_die("fb-shm asynchronous op %u failed: status=%u",
                          op, status);
    }
    if (op != FB_SHM_CTL_NOTIFY_RESIZED &&
        op != FB_SHM_CTL_NOTIFY_GPU_FRAME) {
        fb_shm_stream_die("unexpected fb-shm asynchronous op %u", op);
    }
    fb_shm_stream_control_apply(s);
    fb_shm_stream_control_reset(s);
    return true;
}

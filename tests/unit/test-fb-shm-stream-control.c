/*
 * fb-shm consumer control-stream framing tests.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "tools/fb-shm-stream/common.h"

#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/wait.h>

static int make_mapping_fd(size_t size)
{
    int fd = memfd_create("fb-shm-stream-control-test", MFD_CLOEXEC);

    g_assert_cmpint(fd, >=, 0);
    g_assert_cmpint(ftruncate(fd, size), ==, 0);
    return fd;
}

static void send_fragment_with_fds(int sock, const void *buf, size_t size,
                                   int fd0, int fd1)
{
    int fds[2] = { fd0, fd1 };
    char cbuf[CMSG_SPACE(sizeof(fds))] = { 0 };
    struct iovec iov = {
        .iov_base = (void *)buf,
        .iov_len = size,
    };
    struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = cbuf,
        .msg_controllen = sizeof(cbuf),
    };
    struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);

    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type = SCM_RIGHTS;
    cm->cmsg_len = CMSG_LEN(sizeof(fds));
    memcpy(CMSG_DATA(cm), fds, sizeof(fds));
    g_assert_cmpint(sendmsg(sock, &msg, 0), ==, size);
}

static void send_fragmented_ack(int sock, const FbShmCtlAck *ack,
                                size_t first, int fd0, int fd1)
{
    g_assert_cmpuint(first, <, sizeof(*ack));
    send_fragment_with_fds(sock, ack, first, fd0, fd1);
    g_assert_cmpint(write(sock, (const uint8_t *)ack + first,
                          sizeof(*ack) - first), ==, sizeof(*ack) - first);
}

static void fake_server(int sock, size_t first_size, size_t second_size)
{
    FbShmCtlReq req;
    FbShmCtlAck hello = {
        .magic = FB_SHM_MAGIC,
        .op = FB_SHM_CTL_HELLO,
        .status = FB_SHM_CTL_OK,
        .shm_size = first_size,
        .width = 640,
        .height = 360,
        .fourcc = FB_SHM_FOURCC_BGR0,
        .bpp = 32,
    };
    FbShmCtlAck resized = {
        .magic = FB_SHM_MAGIC,
        .op = FB_SHM_CTL_NOTIFY_RESIZED,
        .status = FB_SHM_CTL_OK,
        .shm_size = second_size,
        .width = 320,
        .height = 180,
        .fourcc = FB_SHM_FOURCC_BGR0,
        .bpp = 32,
    };
    FbShmCtlAck roi = {
        .magic = FB_SHM_MAGIC,
        .op = FB_SHM_CTL_SET_ROI,
        .status = FB_SHM_CTL_OK,
    };
    int map0 = make_mapping_fd(first_size);
    int event0 = eventfd(0, EFD_CLOEXEC);
    int map1 = make_mapping_fd(second_size);
    int event1 = eventfd(0, EFD_CLOEXEC);

    g_assert_cmpint(event0, >=, 0);
    g_assert_cmpint(event1, >=, 0);
    g_assert_cmpint(fb_shm_stream_recv_all(sock, &req, sizeof(req)), ==, 0);
    g_assert_cmpuint(req.op, ==, FB_SHM_CTL_HELLO);

    /* SCM_RIGHTS accompanies a 3-byte ACK prefix; the rest arrives later. */
    send_fragmented_ack(sock, &hello, 3, map0, event0);

    g_assert_cmpint(fb_shm_stream_recv_all(sock, &req, sizeof(req)), ==, 0);
    g_assert_cmpuint(req.op, ==, FB_SHM_CTL_SET_ROI);

    /*
     * An async resize is fragmented and deliberately precedes the solicited
     * ROI ACK.  A byte-stream consumer must dispatch it without consuming any
     * bytes from the following ACK as payload.
     */
    send_fragmented_ack(sock, &resized, 5, map1, event1);
    g_assert_cmpint(write(sock, &roi, sizeof(roi)), ==, sizeof(roi));

    close(map0);
    close(event0);
    close(map1);
    close(event1);
    close(sock);
    _exit(0);
}

static void test_fragmented_control_records(void)
{
    const size_t first_size = 16384;
    const size_t second_size = 32768;
    int pair[2];
    pid_t child;
    Session s = { 0 };
    FbShmCtlReq roi = fb_shm_stream_ctl_req(FB_SHM_CTL_SET_ROI);
    int status;

    g_assert_cmpint(socketpair(AF_UNIX, SOCK_STREAM, 0, pair), ==, 0);
    child = fork();
    g_assert_cmpint(child, >=, 0);
    if (child == 0) {
        close(pair[0]);
        fake_server(pair[1], first_size, second_size);
    }
    close(pair[1]);

    s.sock = pair[0];
    s.map.memfd = -1;
    s.map.eventfd = -1;
    s.gpu_fd = -1;
    fb_shm_stream_control_init(&s);

    fb_shm_stream_hello(&s, STREAM_MODE_SHM);
    g_assert_true(s.shm_ready);
    g_assert_cmpuint(s.map.size, ==, first_size);

    roi.w = 320;
    roi.h = 180;
    g_assert_cmpint(fb_shm_stream_send_all(s.sock, &roi, sizeof(roi)), ==, 0);
    fb_shm_stream_ctl_expect_ok(&s, FB_SHM_CTL_SET_ROI);
    g_assert_cmpuint(s.map.size, ==, second_size);

    fb_shm_stream_close_mapping(&s.map);
    fb_shm_stream_close_socket(s.sock);
    g_assert_cmpint(waitpid(child, &status, 0), ==, child);
    g_assert_true(WIFEXITED(status));
    g_assert_cmpint(WEXITSTATUS(status), ==, 0);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/fb-shm-stream/control/fragmented-records",
                    test_fragmented_control_records);
    return g_test_run();
}

/*
 * Native fb-shm consumer shared declarations.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * 该工具是 Python 推流脚本的原生替代：Linux 继续接收 memfd/eventfd，
 * Windows 通过命名 file mapping + event 获得同一份帧 ABI。公共头只放
 * 跨文件共享的数据结构和函数声明，避免平台细节泄漏到主循环。
 */

#ifndef QEMU_TOOLS_FB_SHM_STREAM_COMMON_H
#define QEMU_TOOLS_FB_SHM_STREAM_COMMON_H

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <windows.h>
#include <afunix.h>
#include <io.h>
typedef SOCKET FbShmStreamSocket;
#define FB_SHM_STREAM_INVALID_SOCKET INVALID_SOCKET
#else
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
typedef int FbShmStreamSocket;
#define FB_SHM_STREAM_INVALID_SOCKET (-1)
#endif

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

#include "ui/fb-shm-abi.h"

typedef enum StreamMode {
    STREAM_MODE_AUTO,
    STREAM_MODE_GPU,
    STREAM_MODE_SHM,
} StreamMode;

typedef struct Options {
    const char *sock;
    const char *output;
    const char *encoder;
    const char *preset;
    const char *bitrate;
    const char *container;
    StreamMode mode;
    int gop;
    int rate;
    int max_frames;
    bool has_roi;
    int roi_x;
    int roi_y;
    uint32_t roi_w;
    uint32_t roi_h;
} Options;

typedef struct Mapping {
    void *base;
    size_t size;
#ifdef _WIN32
    HANDLE map_handle;
    HANDLE event_handle;
#else
    int memfd;
    int eventfd;
#endif
} Mapping;

typedef struct Session {
    FbShmStreamSocket sock;
    Mapping map;
    FILE *ffmpeg;
    uint8_t *frame;
    size_t frame_cap;
    uint64_t last_seq;
    FbShmGpuFrame gpu_frame;
    bool gpu_frame_ready;
    bool gpu_logged;
    bool shm_ready;
#ifndef _WIN32
    int gpu_fd;
#endif
    uint32_t ff_w;
    uint32_t ff_h;
    uint32_t ff_fps;
    uint32_t ff_fourcc;
} Session;

#if defined(__GNUC__)
void fb_shm_stream_die(const char *fmt, ...)
    __attribute__((format(printf, 1, 2)));
#else
void fb_shm_stream_die(const char *fmt, ...);
#endif

int fb_shm_stream_send_all(FbShmStreamSocket fd, const void *buf, size_t len);
int fb_shm_stream_recv_all(FbShmStreamSocket fd, void *buf, size_t len);
FbShmCtlReq fb_shm_stream_ctl_req(uint32_t op);
void fb_shm_stream_ctl_expect_ok(FbShmStreamSocket fd, uint32_t op);

void fb_shm_stream_close_mapping(Mapping *m);
FbShmStreamSocket fb_shm_stream_connect_unix_socket(const char *path);
void fb_shm_stream_set_sock_nonblock(FbShmStreamSocket fd);
void fb_shm_stream_close_socket(FbShmStreamSocket fd);
void fb_shm_stream_cleanup_network(void);
void fb_shm_stream_hello(Session *s, StreamMode mode);
bool fb_shm_stream_try_control(Session *s);
void fb_shm_stream_close_gpu_frame(Session *s);

FILE *fb_shm_stream_open_ffmpeg(const Options *o, const FbShmHeader *hdr);
void fb_shm_stream_close_ffmpeg(FILE *ffmpeg);

#endif /* QEMU_TOOLS_FB_SHM_STREAM_COMMON_H */

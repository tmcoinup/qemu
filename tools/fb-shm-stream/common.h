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

/*
 * Stable GPU capability/error classes.  Keep these independent from a
 * particular encoder library so callers and tests can distinguish an invalid
 * producer frame from a consumer that was built without a native import path.
 */
typedef enum FbShmStreamGpuStatus {
    FB_SHM_STREAM_GPU_OK = 0,
    FB_SHM_STREAM_GPU_E_BACKEND_NOT_BUILT,
    FB_SHM_STREAM_GPU_E_WIRE,
    FB_SHM_STREAM_GPU_E_GEOMETRY,
    FB_SHM_STREAM_GPU_E_LAYOUT,
    FB_SHM_STREAM_GPU_E_FLAGS,
    FB_SHM_STREAM_GPU_E_HANDLE_TYPE,
    FB_SHM_STREAM_GPU_E_HANDLE_MISSING,
    FB_SHM_STREAM_GPU_E_PLATFORM_HANDLE,
    FB_SHM_STREAM_GPU_E_HANDLE_NAME,
    FB_SHM_STREAM_GPU_E_SYNC_UNSAFE,
} FbShmStreamGpuStatus;

#define FB_SHM_STREAM_EXIT_GPU_UNAVAILABLE 3

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
    bool print_capabilities;
    int roi_x;
    int roi_y;
    uint32_t roi_w;
    uint32_t roi_h;
} Options;

typedef struct StreamPacer {
    uint64_t interval_ns;
    uint64_t next_frame_ns;
    bool started;
} StreamPacer;

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

typedef union ControlPayload {
    FbShmWin32Names names;
    FbShmGpuFrame gpu;
} ControlPayload;

/*
 * AF_UNIX is a byte stream even when the producer uses one sendmsg() per
 * record.  Preserve partial ACK/payload reads and SCM_RIGHTS until one whole
 * control record has been assembled.
 */
typedef struct ControlRx {
    FbShmCtlAck ack;
    size_t ack_bytes;
    ControlPayload payload;
    size_t payload_size;
    size_t payload_bytes;
    bool initialized;
#ifndef _WIN32
    int fds[2];
    size_t nfds;
#endif
} ControlRx;

typedef struct FfmpegProcess {
    FILE *input;
#ifdef _WIN32
    HANDLE process;
#else
    int pid;
#endif
} FfmpegProcess;

typedef struct Session {
    FbShmStreamSocket sock;
    Mapping map;
    ControlRx control_rx;
    FfmpegProcess *ffmpeg;
    uint8_t *frame;
    size_t frame_cap;
    uint64_t last_seq;
    FbShmGpuFrame gpu_frame;
    bool gpu_frame_ready;
    bool gpu_logged;
    bool gpu_error_logged;
    bool shm_ready;
    FbShmStreamGpuStatus gpu_error;
#ifndef _WIN32
    int gpu_fd;
#endif
    uint32_t ff_w;
    uint32_t ff_h;
    uint32_t ff_fps;
    uint32_t ff_fourcc;
} Session;

#if defined(__GNUC__)
/*
 * MinGW 的 `printf` 属性默认按微软格式检查，而函数实现调用的是遵循 GNU
 * 语义的 vfprintf()。显式使用 gnu_printf，确保 Linux 与 Windows 交叉编译
 * 都能检查格式串，并避免 -Wsuggest-attribute=format 产生误报。
 */
void fb_shm_stream_die(const char *fmt, ...)
    __attribute__((format(gnu_printf, 1, 2)));
#else
void fb_shm_stream_die(const char *fmt, ...);
#endif

int fb_shm_stream_send_all(FbShmStreamSocket fd, const void *buf, size_t len);
int fb_shm_stream_recv_all(FbShmStreamSocket fd, void *buf, size_t len);
FbShmCtlReq fb_shm_stream_ctl_req(uint32_t op);
void fb_shm_stream_ctl_expect_ok(Session *s, uint32_t op);

void fb_shm_stream_close_mapping(Mapping *m);
FbShmStreamSocket fb_shm_stream_connect_unix_socket(const char *path);
void fb_shm_stream_set_sock_nonblock(FbShmStreamSocket fd);
void fb_shm_stream_close_socket(FbShmStreamSocket fd);
void fb_shm_stream_cleanup_network(void);
void fb_shm_stream_control_init(Session *s);
void fb_shm_stream_hello(Session *s, StreamMode mode);
bool fb_shm_stream_try_control(Session *s);
void fb_shm_stream_close_gpu_frame(Session *s);

FbShmStreamGpuStatus fb_shm_stream_gpu_backend_probe(void);
bool fb_shm_stream_gpu_backend_available(void);
FbShmStreamGpuStatus
fb_shm_stream_gpu_validate_frame(const FbShmGpuFrame *frame,
                                 bool has_native_handle);
const char *fb_shm_stream_gpu_status_code(FbShmStreamGpuStatus status);
const char *fb_shm_stream_gpu_status_message(FbShmStreamGpuStatus status);
void fb_shm_stream_gpu_print_capabilities(FILE *stream);

bool fb_shm_stream_ffmpeg_options_valid(const Options *o);
const char *fb_shm_stream_ffmpeg_output_kind(const char *output);
FfmpegProcess *fb_shm_stream_open_ffmpeg(const Options *o,
                                         const FbShmHeader *hdr);
void fb_shm_stream_close_ffmpeg(FfmpegProcess *ffmpeg);

uint64_t fb_shm_stream_monotonic_ns(void);
void fb_shm_stream_pacer_reset(StreamPacer *p, uint32_t fps);
void fb_shm_stream_pacer_start(StreamPacer *p, uint64_t now_ns);
int fb_shm_stream_pacer_wait_ms(const StreamPacer *p, uint64_t now_ns);
void fb_shm_stream_pacer_finish_frame(StreamPacer *p, uint64_t now_ns);

#endif /* QEMU_TOOLS_FB_SHM_STREAM_COMMON_H */

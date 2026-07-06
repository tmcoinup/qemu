/*
 * Native fb-shm stream tool.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * 主循环保持很薄：解析参数、连接 fb-shm、等待帧通知、按 seqlock 语义复制
 * 当前帧，然后写入 ffmpeg stdin。GPU 模式的控制面同样在这里调度，但平台
 * fd/name 细节都在 platform.c 中。
 */

#include "common.h"

static void fb_shm_stream_usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s --sock PATH --output URL [--encoder h264_nvenc]\n"
            "          [--preset p1] [--bitrate 6M] [--gop 60]\n"
            "          [--roi x,y,w,h] [--rate Hz] [--container muxer]\n"
            "          [--mode auto|gpu|shm]\n",
            argv0);
    exit(2);
}

static StreamMode fb_shm_stream_parse_mode(const char *value)
{
    if (!strcmp(value, "auto")) {
        return STREAM_MODE_AUTO;
    }
    if (!strcmp(value, "gpu")) {
        return STREAM_MODE_GPU;
    }
    if (!strcmp(value, "shm")) {
        return STREAM_MODE_SHM;
    }
    fb_shm_stream_die("--mode must be auto, gpu or shm");
    return STREAM_MODE_AUTO;
}

static Options fb_shm_stream_parse_args(int argc, char **argv)
{
    Options o = {
        .encoder = "h264_nvenc",
        .preset = "p1",
        .bitrate = "6M",
        .mode = STREAM_MODE_AUTO,
        .gop = 60,
    };

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : NULL;

        if (!strcmp(a, "--sock") && v) {
            o.sock = argv[++i];
        } else if (!strcmp(a, "--output") && v) {
            o.output = argv[++i];
        } else if (!strcmp(a, "--encoder") && v) {
            o.encoder = argv[++i];
        } else if (!strcmp(a, "--preset") && v) {
            o.preset = argv[++i];
        } else if (!strcmp(a, "--bitrate") && v) {
            o.bitrate = argv[++i];
        } else if (!strcmp(a, "--container") && v) {
            o.container = argv[++i];
        } else if (!strcmp(a, "--mode") && v) {
            o.mode = fb_shm_stream_parse_mode(argv[++i]);
        } else if (!strcmp(a, "--gop") && v) {
            o.gop = atoi(argv[++i]);
        } else if (!strcmp(a, "--rate") && v) {
            o.rate = atoi(argv[++i]);
        } else if (!strcmp(a, "--max-frames") && v) {
            o.max_frames = atoi(argv[++i]);
        } else if (!strcmp(a, "--roi") && v) {
            if (sscanf(argv[++i], "%d,%d,%u,%u", &o.roi_x, &o.roi_y,
                       &o.roi_w, &o.roi_h) != 4) {
                fb_shm_stream_die("--roi must be x,y,w,h");
            }
            o.has_roi = true;
        } else {
            fb_shm_stream_usage(argv[0]);
        }
    }
    if (!o.sock || !o.output) {
        fb_shm_stream_usage(argv[0]);
    }
    return o;
}

static void fb_shm_stream_request_roi_rate(const Options *o,
                                           FbShmStreamSocket fd)
{
    if (o->has_roi) {
        FbShmCtlReq req = fb_shm_stream_ctl_req(FB_SHM_CTL_SET_ROI);

        req.x = o->roi_x;
        req.y = o->roi_y;
        req.w = o->roi_w;
        req.h = o->roi_h;
        if (fb_shm_stream_send_all(fd, &req, sizeof(req)) < 0) {
            fb_shm_stream_die("SET_ROI send failed");
        }
        fb_shm_stream_ctl_expect_ok(fd, FB_SHM_CTL_SET_ROI);
    }
    if (o->rate > 0) {
        FbShmCtlReq req = fb_shm_stream_ctl_req(FB_SHM_CTL_SET_RATE);

        req.rate_hz = (uint32_t)o->rate;
        if (fb_shm_stream_send_all(fd, &req, sizeof(req)) < 0) {
            fb_shm_stream_die("SET_RATE send failed");
        }
        fb_shm_stream_ctl_expect_ok(fd, FB_SHM_CTL_SET_RATE);
    }
}

static const FbShmHeader *fb_shm_stream_header(Session *s)
{
    const FbShmHeader *hdr = (const FbShmHeader *)s->map.base;

    if (!s->shm_ready) {
        fb_shm_stream_die("fb-shm shared-memory path is not available");
    }
    if (!hdr || hdr->magic != FB_SHM_MAGIC || hdr->version != FB_SHM_VERSION) {
        fb_shm_stream_die("invalid fb-shm header");
    }
    return hdr;
}

static bool fb_shm_stream_ensure_ffmpeg(Session *s, const Options *o,
                                        const FbShmHeader *hdr)
{
    uint32_t fps = hdr->target_fps ? hdr->target_fps : 30;

    if (s->ffmpeg && s->ff_w == hdr->width && s->ff_h == hdr->height &&
        s->ff_fps == fps && s->ff_fourcc == hdr->fourcc) {
        return false;
    }
    fb_shm_stream_close_ffmpeg(s->ffmpeg);
    s->ffmpeg = fb_shm_stream_open_ffmpeg(o, hdr);
    if (!s->ffmpeg) {
        fb_shm_stream_die("failed to start ffmpeg");
    }
    s->ff_w = hdr->width;
    s->ff_h = hdr->height;
    s->ff_fps = fps;
    s->ff_fourcc = hdr->fourcc;
    return true;
}

static size_t fb_shm_stream_read_frame(Session *s, const FbShmHeader *hdr)
{
    for (int i = 0; i < 8; i++) {
        uint64_t seq0 = hdr->frame_seq;
        uint32_t idx = hdr->active_idx;
        uint64_t off = idx < hdr->buf_count ? hdr->buf_offset[idx] : 0;
        size_t len = (size_t)hdr->buf_size;

        if (seq0 == s->last_seq || off + len > s->map.size) {
            return 0;
        }
        if (len > s->frame_cap) {
            uint8_t *p = realloc(s->frame, len);

            if (!p) {
                fb_shm_stream_die("out of memory");
            }
            s->frame = p;
            s->frame_cap = len;
        }
        memcpy(s->frame, (uint8_t *)s->map.base + off, len);
        if (seq0 == hdr->frame_seq) {
            s->last_seq = seq0;
            return len;
        }
    }
    return 0;
}

static bool fb_shm_stream_wait_frame(Session *s, int timeout_ms)
{
#ifdef _WIN32
    DWORD rc;
    DWORD timeout = timeout_ms < 0 ? INFINITE : (DWORD)timeout_ms;

    (void)fb_shm_stream_try_control(s);
    if (!s->map.event_handle) {
        Sleep(timeout_ms > 0 ? (DWORD)timeout_ms : 0);
        return false;
    }
    rc = WaitForSingleObject(s->map.event_handle, timeout);
    (void)fb_shm_stream_try_control(s);
    return rc == WAIT_OBJECT_0;
#else
    struct pollfd pfd[2] = {
        { .fd = s->map.eventfd, .events = POLLIN },
        { .fd = s->sock, .events = POLLIN },
    };
    uint64_t v;
    int rc = poll(pfd, 2, timeout_ms);

    if (rc <= 0) {
        return false;
    }
    if (pfd[1].revents & POLLIN) {
        (void)fb_shm_stream_try_control(s);
    }
    if (!(pfd[0].revents & POLLIN)) {
        return false;
    }
    if (read(s->map.eventfd, &v, sizeof(v)) < 0) {
        return false;
    }
    return true;
#endif
}

static void fb_shm_stream_drain_control(Session *s)
{
    while (fb_shm_stream_try_control(s)) {
        /* 控制面消息很短，循环读空，避免 resize/GPU 通知滞留到下一帧节拍。 */
    }
}

static void fb_shm_stream_init_session(Session *s)
{
    memset(s, 0, sizeof(*s));
    s->sock = FB_SHM_STREAM_INVALID_SOCKET;
#ifndef _WIN32
    s->map.memfd = -1;
    s->map.eventfd = -1;
    s->gpu_fd = -1;
#endif
}

static void fb_shm_stream_log_gpu_frame(Session *s)
{
    const FbShmGpuFrame *g = &s->gpu_frame;

    if (!s->gpu_frame_ready || s->gpu_logged) {
        return;
    }
    fprintf(stderr,
            "[fb-shm] gpu-frame: type=%u %ux%u stride=%u fourcc=0x%08x "
            "seq=%" PRIu64 "\n",
            g->handle_type, g->width, g->height, g->stride,
            g->fourcc, g->frame_seq);
    s->gpu_logged = true;
}

static void fb_shm_stream_update_latest_frame(Session *s, const Options *o,
                                              StreamPacer *pacer,
                                              bool *have_frame,
                                              size_t *frame_len)
{
    const FbShmHeader *hdr = fb_shm_stream_header(s);
    size_t len;

    if (fb_shm_stream_ensure_ffmpeg(s, o, hdr)) {
        /*
         * 分辨率、像素格式或 fps 变化会重启 ffmpeg；旧帧尺寸/时间基都不再
         * 匹配，必须等新 mapping 的第一帧，而不能继续重复上一帧。
         */
        *have_frame = false;
        *frame_len = 0;
        fb_shm_stream_pacer_reset(pacer, s->ff_fps);
    }

    len = fb_shm_stream_read_frame(s, hdr);
    if (len) {
        *have_frame = true;
        *frame_len = len;
        if (!pacer->started) {
            fb_shm_stream_pacer_start(pacer,
                                      fb_shm_stream_monotonic_ns());
        }
    }
}

int main(int argc, char **argv)
{
    Options o = fb_shm_stream_parse_args(argc, argv);
    Session s;
    StreamPacer pacer;
    bool have_frame = false;
    size_t frame_len = 0;
    int frames = 0;

    fb_shm_stream_init_session(&s);
    fb_shm_stream_pacer_reset(&pacer, 30);
    s.sock = fb_shm_stream_connect_unix_socket(o.sock);
    fb_shm_stream_hello(&s, o.mode);
    fb_shm_stream_request_roi_rate(&o, s.sock);
    fb_shm_stream_set_sock_nonblock(s.sock);

    if (s.shm_ready) {
        fprintf(stderr, "[fb-shm] connected: %ux%u shm=%zuB\n",
                fb_shm_stream_header(&s)->width,
                fb_shm_stream_header(&s)->height, s.map.size);
    } else {
        fprintf(stderr, "[fb-shm] connected: waiting for GPU frames\n");
    }

    while (!o.max_frames || frames < o.max_frames) {
        int wait_ms;
        uint64_t now_ns;

        fb_shm_stream_drain_control(&s);
        fb_shm_stream_log_gpu_frame(&s);
        if (o.mode == STREAM_MODE_GPU && !s.gpu_frame_ready) {
#ifdef _WIN32
            Sleep(10);
#else
            usleep(10000);
#endif
            continue;
        }
        if (o.mode == STREAM_MODE_GPU) {
            /*
             * 这里故意不静默降级到 SHM：GPU strict 模式用于验证 QEMU
             * 是否真的发布了 dma-buf/D3D 共享纹理。当前 ffmpeg stdin
             * 后端不能导入这些句柄，真正编码应由后续 libav/NVENC/AMF
             * GPU backend 接管。
             */
            fb_shm_stream_die("GPU frame export is available, but this "
                              "streamer build has no native GPU encoder");
        }
        if (s.shm_ready) {
            fb_shm_stream_update_latest_frame(&s, &o, &pacer, &have_frame,
                                              &frame_len);
        }
        if (!have_frame) {
            (void)fb_shm_stream_wait_frame(&s, 1000);
            continue;
        }

        now_ns = fb_shm_stream_monotonic_ns();
        wait_ms = fb_shm_stream_pacer_wait_ms(&pacer, now_ns);
        if (wait_ms > 0) {
            (void)fb_shm_stream_wait_frame(&s, wait_ms);
            continue;
        }

        if (fwrite(s.frame, 1, frame_len, s.ffmpeg) != frame_len) {
            break;
        }
        frames++;
        fb_shm_stream_pacer_finish_frame(&pacer,
                                         fb_shm_stream_monotonic_ns());
    }

    fb_shm_stream_close_ffmpeg(s.ffmpeg);
    fb_shm_stream_close_gpu_frame(&s);
    free(s.frame);
    fb_shm_stream_close_mapping(&s.map);
    if (s.sock != FB_SHM_STREAM_INVALID_SOCKET) {
        FbShmCtlReq bye = fb_shm_stream_ctl_req(FB_SHM_CTL_BYE);

        (void)fb_shm_stream_send_all(s.sock, &bye, sizeof(bye));
        fb_shm_stream_close_socket(s.sock);
    }
    fb_shm_stream_cleanup_network();
    fprintf(stderr, "[fb-shm] done: %d frames\n", frames);
    return 0;
}

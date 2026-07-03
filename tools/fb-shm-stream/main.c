/*
 * Native fb-shm stream tool.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * 主循环保持很薄：解析参数、连接 fb-shm、等待帧通知、按 seqlock 语义复制
 * 当前帧，然后写入 ffmpeg stdin。平台差异都在 platform.c 中。
 */

#include "common.h"

static void fb_shm_stream_usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s --sock PATH --output URL [--encoder h264_nvenc]\n"
            "          [--preset p1] [--bitrate 6M] [--gop 60]\n"
            "          [--roi x,y,w,h] [--rate Hz] [--container muxer]\n",
            argv0);
    exit(2);
}

static Options fb_shm_stream_parse_args(int argc, char **argv)
{
    Options o = {
        .encoder = "h264_nvenc",
        .preset = "p1",
        .bitrate = "6M",
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

    if (!hdr || hdr->magic != FB_SHM_MAGIC || hdr->version != FB_SHM_VERSION) {
        fb_shm_stream_die("invalid fb-shm header");
    }
    return hdr;
}

static void fb_shm_stream_ensure_ffmpeg(Session *s, const Options *o,
                                        const FbShmHeader *hdr)
{
    uint32_t fps = hdr->target_fps ? hdr->target_fps : 30;

    if (s->ffmpeg && s->ff_w == hdr->width && s->ff_h == hdr->height &&
        s->ff_fps == fps && s->ff_fourcc == hdr->fourcc) {
        return;
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

static bool fb_shm_stream_wait_frame(Session *s)
{
#ifdef _WIN32
    DWORD rc = WaitForSingleObject(s->map.event_handle, 1000);

    (void)fb_shm_stream_try_resize(s);
    return rc == WAIT_OBJECT_0;
#else
    struct pollfd pfd[2] = {
        { .fd = s->map.eventfd, .events = POLLIN },
        { .fd = s->sock, .events = POLLIN },
    };
    uint64_t v;
    int rc = poll(pfd, 2, 1000);

    if (rc <= 0) {
        return false;
    }
    if (pfd[1].revents & POLLIN) {
        (void)fb_shm_stream_try_resize(s);
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

static void fb_shm_stream_init_session(Session *s)
{
    memset(s, 0, sizeof(*s));
    s->sock = FB_SHM_STREAM_INVALID_SOCKET;
#ifndef _WIN32
    s->map.memfd = -1;
    s->map.eventfd = -1;
#endif
}

int main(int argc, char **argv)
{
    Options o = fb_shm_stream_parse_args(argc, argv);
    Session s;
    int frames = 0;

    fb_shm_stream_init_session(&s);
    s.sock = fb_shm_stream_connect_unix_socket(o.sock);
    fb_shm_stream_hello(&s);
    fb_shm_stream_request_roi_rate(&o, s.sock);
    fb_shm_stream_set_sock_nonblock(s.sock);

    fprintf(stderr, "[fb-shm] connected: %ux%u shm=%zuB\n",
            fb_shm_stream_header(&s)->width,
            fb_shm_stream_header(&s)->height, s.map.size);

    while (!o.max_frames || frames < o.max_frames) {
        const FbShmHeader *hdr;
        size_t len;

        if (!fb_shm_stream_wait_frame(&s)) {
            continue;
        }
        hdr = fb_shm_stream_header(&s);
        fb_shm_stream_ensure_ffmpeg(&s, &o, hdr);
        len = fb_shm_stream_read_frame(&s, hdr);
        if (!len) {
            continue;
        }
        if (fwrite(s.frame, 1, len, s.ffmpeg) != len) {
            break;
        }
        frames++;
    }

    fb_shm_stream_close_ffmpeg(s.ffmpeg);
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

/*
 * Native fb-shm ffmpeg pipe.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * 推流工具只负责输出 rawvideo 给 ffmpeg，编码器选择、封装格式和远端 URL
 * 仍由 ffmpeg 处理。这样 Windows/Linux 共享同一套参数，不需要 Python。
 */

#include "common.h"

#ifdef _WIN32
#define FB_SHM_STREAM_POPEN _popen
#define FB_SHM_STREAM_PCLOSE _pclose
#define FB_SHM_STREAM_POPEN_MODE "wb"
#else
#define FB_SHM_STREAM_POPEN popen
#define FB_SHM_STREAM_PCLOSE pclose
#define FB_SHM_STREAM_POPEN_MODE "w"
#endif

static const char *fb_shm_stream_fourcc_name(uint32_t fourcc)
{
    return fourcc == FB_SHM_FOURCC_BGRA ? "bgra" : "bgr0";
}

static void fb_shm_stream_quote_arg(char *dst, size_t dst_len,
                                    const char *src)
{
    size_t pos = 0;

    if (dst_len == 0) {
        return;
    }
    dst[pos++] = '"';
    for (const char *p = src; *p && pos + 3 < dst_len; p++) {
        if (*p == '"') {
            dst[pos++] = '\\';
        }
        dst[pos++] = *p;
    }
    if (pos + 1 < dst_len) {
        dst[pos++] = '"';
    }
    dst[pos] = 0;
}

static const char *fb_shm_stream_guess_container(const Options *o)
{
    const char *out = o->output;
    size_t n;

    if (o->container && *o->container) {
        return o->container;
    }
    if (!strncmp(out, "rtmp://", 7) || !strncmp(out, "rtmps://", 8)) {
        return "flv";
    }
    if (!strncmp(out, "udp://", 6) || !strncmp(out, "rtp://", 6) ||
        !strncmp(out, "srt://", 6)) {
        return "mpegts";
    }
    n = strlen(out);
    if (n >= 4 && !strcmp(out + n - 4, ".mp4")) {
        return "mp4";
    }
    if (n >= 4 && !strcmp(out + n - 4, ".mkv")) {
        return "matroska";
    }
    return "";
}

FILE *fb_shm_stream_open_ffmpeg(const Options *o, const FbShmHeader *hdr)
{
    char out_q[1024];
    char cmd[4096];
    const char *container = fb_shm_stream_guess_container(o);
    uint32_t fps = hdr->target_fps ? hdr->target_fps : 30;

    fb_shm_stream_quote_arg(out_q, sizeof(out_q), o->output);
    snprintf(cmd, sizeof(cmd),
             "ffmpeg -hide_banner -loglevel warning "
             "-f rawvideo -pix_fmt %s -video_size %ux%u -framerate %u -i - "
             "-c:v %s -b:v %s -g %d -pix_fmt yuv420p -preset %s %s%s%s",
             fb_shm_stream_fourcc_name(hdr->fourcc), hdr->width,
             hdr->height, fps, o->encoder, o->bitrate, o->gop, o->preset,
             container[0] ? "-f " : "", container[0] ? container : "",
             container[0] ? " " : "");
    strncat(cmd, out_q, sizeof(cmd) - strlen(cmd) - 1);

    fprintf(stderr, "[fb-shm] ffmpeg: %s\n", cmd);
    return FB_SHM_STREAM_POPEN(cmd, FB_SHM_STREAM_POPEN_MODE);
}

void fb_shm_stream_close_ffmpeg(FILE *ffmpeg)
{
    if (ffmpeg) {
        FB_SHM_STREAM_PCLOSE(ffmpeg);
    }
}

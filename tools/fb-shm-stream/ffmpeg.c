/*
 * Native fb-shm ffmpeg process.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Frames still use ffmpeg's CPU rawvideo input.  Launch ffmpeg directly with
 * an argv vector (or CreateProcess on Windows); never interpolate user
 * options or an output URL into a shell command.
 */

#include "common.h"

#ifdef _WIN32
#include <fcntl.h>
#else
#include <signal.h>
#include <sys/wait.h>
#endif

static const char *fb_shm_stream_fourcc_name(uint32_t fourcc)
{
    return fourcc == FB_SHM_FOURCC_BGRA ? "bgra" : "bgr0";
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

static bool fb_shm_stream_name_safe(const char *value)
{
    const unsigned char *p = (const unsigned char *)value;

    if (!p || !*p || *p == '-') {
        return false;
    }
    for (; *p; p++) {
        if (!((*p >= 'a' && *p <= 'z') ||
              (*p >= 'A' && *p <= 'Z') ||
              (*p >= '0' && *p <= '9') ||
              *p == '_' || *p == '-' || *p == '.')) {
            return false;
        }
    }
    return true;
}

static bool fb_shm_stream_bitrate_safe(const char *value)
{
    const unsigned char *p = (const unsigned char *)value;

    if (!p || !(*p >= '1' && *p <= '9')) {
        return false;
    }
    while (*p >= '0' && *p <= '9') {
        p++;
    }
    if (*p == 'k' || *p == 'K' || *p == 'm' || *p == 'M' ||
        *p == 'g' || *p == 'G') {
        p++;
    }
    return *p == '\0';
}

bool fb_shm_stream_ffmpeg_options_valid(const Options *o)
{
    const unsigned char *p;

    if (!o || !o->output || !*o->output || o->output[0] == '-' ||
        !fb_shm_stream_name_safe(o->encoder) ||
        !fb_shm_stream_name_safe(o->preset) ||
        !fb_shm_stream_bitrate_safe(o->bitrate) ||
        o->gop <= 0 || o->gop > 1000 ||
        (o->container && *o->container &&
         !fb_shm_stream_name_safe(o->container))) {
        return false;
    }
    for (p = (const unsigned char *)o->output; *p; p++) {
        if (*p < 0x20 || *p == 0x7f) {
            return false;
        }
    }
    return true;
}

const char *fb_shm_stream_ffmpeg_output_kind(const char *output)
{
    if (!output) {
        return "invalid";
    }
    if (!strncmp(output, "rtmps://", 8)) {
        return "rtmps";
    }
    if (!strncmp(output, "rtmp://", 7)) {
        return "rtmp";
    }
    if (!strncmp(output, "udp://", 6)) {
        return "udp";
    }
    if (!strncmp(output, "rtp://", 6)) {
        return "rtp";
    }
    if (!strncmp(output, "srt://", 6)) {
        return "srt";
    }
    return "file";
}

static size_t fb_shm_stream_ffmpeg_argv(const Options *o,
                                        const FbShmHeader *hdr,
                                        const char **argv,
                                        char dims[32],
                                        char fps_buf[16],
                                        char gop_buf[16])
{
    const char *container = fb_shm_stream_guess_container(o);
    uint32_t fps = hdr->target_fps ? hdr->target_fps : 30;
    size_t n = 0;

    snprintf(dims, 32, "%ux%u", hdr->width, hdr->height);
    snprintf(fps_buf, 16, "%u", fps);
    snprintf(gop_buf, 16, "%d", o->gop);

    argv[n++] = "ffmpeg";
    argv[n++] = "-hide_banner";
    argv[n++] = "-loglevel";
    argv[n++] = "warning";
    argv[n++] = "-nostdin";
    argv[n++] = "-f";
    argv[n++] = "rawvideo";
    argv[n++] = "-pix_fmt";
    argv[n++] = fb_shm_stream_fourcc_name(hdr->fourcc);
    argv[n++] = "-video_size";
    argv[n++] = dims;
    argv[n++] = "-framerate";
    argv[n++] = fps_buf;
    argv[n++] = "-i";
    argv[n++] = "-";
    argv[n++] = "-c:v";
    argv[n++] = o->encoder;
    argv[n++] = "-b:v";
    argv[n++] = o->bitrate;
    argv[n++] = "-g";
    argv[n++] = gop_buf;
    argv[n++] = "-pix_fmt";
    argv[n++] = "yuv420p";
    argv[n++] = "-preset";
    argv[n++] = o->preset;
    if (container[0]) {
        argv[n++] = "-f";
        argv[n++] = container;
    }
    argv[n++] = o->output;
    argv[n] = NULL;
    return n;
}

#ifdef _WIN32
typedef struct FbShmStreamString {
    char *data;
    size_t len;
    size_t cap;
} FbShmStreamString;

static bool fb_shm_stream_string_append(FbShmStreamString *s,
                                         char ch, size_t count)
{
    size_t need = s->len + count + 1;

    if (need > s->cap) {
        size_t cap = s->cap ? s->cap : 256;
        char *next;

        while (cap < need) {
            if (cap > SIZE_MAX / 2) {
                return false;
            }
            cap *= 2;
        }
        next = realloc(s->data, cap);
        if (!next) {
            return false;
        }
        s->data = next;
        s->cap = cap;
    }
    memset(s->data + s->len, ch, count);
    s->len += count;
    s->data[s->len] = '\0';
    return true;
}

/*
 * Quote one argument according to the Microsoft C runtime parsing rules.
 * CreateProcess does not invoke cmd.exe, so shell metacharacters remain data.
 */
static bool fb_shm_stream_windows_quote(FbShmStreamString *s,
                                         const char *arg)
{
    const char *p = arg;

    if (s->len && !fb_shm_stream_string_append(s, ' ', 1)) {
        return false;
    }
    if (!fb_shm_stream_string_append(s, '"', 1)) {
        return false;
    }
    while (*p) {
        size_t slashes = 0;

        while (*p == '\\') {
            slashes++;
            p++;
        }
        if (*p == '"') {
            if (!fb_shm_stream_string_append(s, '\\', slashes * 2 + 1) ||
                !fb_shm_stream_string_append(s, '"', 1)) {
                return false;
            }
            p++;
        } else if (!*p) {
            if (!fb_shm_stream_string_append(s, '\\', slashes * 2)) {
                return false;
            }
        } else {
            if (!fb_shm_stream_string_append(s, '\\', slashes) ||
                !fb_shm_stream_string_append(s, *p++, 1)) {
                return false;
            }
        }
    }
    return fb_shm_stream_string_append(s, '"', 1);
}

static FfmpegProcess *fb_shm_stream_spawn_ffmpeg(const char *const *argv)
{
    SECURITY_ATTRIBUTES security = {
        .nLength = sizeof(security),
        .bInheritHandle = TRUE,
    };
    STARTUPINFOA startup = {
        .cb = sizeof(startup),
        .dwFlags = STARTF_USESTDHANDLES,
        .hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE),
        .hStdError = GetStdHandle(STD_ERROR_HANDLE),
    };
    PROCESS_INFORMATION process = { 0 };
    FbShmStreamString command = { 0 };
    FfmpegProcess *ffmpeg = NULL;
    HANDLE input_read = NULL;
    HANDLE input_write = NULL;
    int input_fd = -1;

    for (size_t i = 0; argv[i]; i++) {
        if (!fb_shm_stream_windows_quote(&command, argv[i])) {
            goto fail;
        }
    }
    if (!CreatePipe(&input_read, &input_write, &security, 0) ||
        !SetHandleInformation(input_write, HANDLE_FLAG_INHERIT, 0)) {
        goto fail;
    }
    startup.hStdInput = input_read;
    if (!CreateProcessA(NULL, command.data, NULL, NULL, TRUE,
                        CREATE_NO_WINDOW, NULL, NULL, &startup, &process)) {
        goto fail;
    }
    CloseHandle(input_read);
    input_read = NULL;
    CloseHandle(process.hThread);

    input_fd = _open_osfhandle((intptr_t)input_write, _O_BINARY);
    if (input_fd < 0) {
        TerminateProcess(process.hProcess, 1);
        CloseHandle(process.hProcess);
        goto fail;
    }
    input_write = NULL;
    ffmpeg = calloc(1, sizeof(*ffmpeg));
    if (!ffmpeg) {
        _close(input_fd);
        TerminateProcess(process.hProcess, 1);
        CloseHandle(process.hProcess);
        goto fail;
    }
    ffmpeg->input = _fdopen(input_fd, "wb");
    if (!ffmpeg->input) {
        _close(input_fd);
        TerminateProcess(process.hProcess, 1);
        CloseHandle(process.hProcess);
        free(ffmpeg);
        ffmpeg = NULL;
        goto fail;
    }
    ffmpeg->process = process.hProcess;

fail:
    if (input_read) {
        CloseHandle(input_read);
    }
    if (input_write) {
        CloseHandle(input_write);
    }
    free(command.data);
    return ffmpeg;
}
#else
static FfmpegProcess *fb_shm_stream_spawn_ffmpeg(const char *const *argv)
{
    FfmpegProcess *ffmpeg;
    int input_pipe[2];
    pid_t pid;

    if (pipe(input_pipe) < 0) {
        return NULL;
    }
    (void)fcntl(input_pipe[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(input_pipe[1], F_SETFD, FD_CLOEXEC);

    pid = fork();
    if (pid < 0) {
        close(input_pipe[0]);
        close(input_pipe[1]);
        return NULL;
    }
    if (pid == 0) {
        if (input_pipe[0] != STDIN_FILENO) {
            if (dup2(input_pipe[0], STDIN_FILENO) < 0) {
                _exit(126);
            }
            close(input_pipe[0]);
        } else if (fcntl(STDIN_FILENO, F_SETFD, 0) < 0) {
            _exit(126);
        }
        close(input_pipe[1]);
        execvp(argv[0], (char *const *)argv);
        _exit(127);
    }

    close(input_pipe[0]);
    ffmpeg = calloc(1, sizeof(*ffmpeg));
    if (!ffmpeg) {
        close(input_pipe[1]);
        kill(pid, SIGTERM);
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {
        }
        return NULL;
    }
    ffmpeg->input = fdopen(input_pipe[1], "w");
    if (!ffmpeg->input) {
        close(input_pipe[1]);
        kill(pid, SIGTERM);
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {
        }
        free(ffmpeg);
        return NULL;
    }
    ffmpeg->pid = pid;
    return ffmpeg;
}
#endif

FfmpegProcess *fb_shm_stream_open_ffmpeg(const Options *o,
                                         const FbShmHeader *hdr)
{
    const char *argv[32];
    const char *container;
    char dims[32];
    char fps[16];
    char gop[16];

    if (!fb_shm_stream_ffmpeg_options_valid(o)) {
        fprintf(stderr, "[fb-shm] invalid ffmpeg option\n");
        return NULL;
    }
    container = fb_shm_stream_guess_container(o);
    (void)fb_shm_stream_ffmpeg_argv(o, hdr, argv, dims, fps, gop);
    fprintf(stderr,
            "[fb-shm] ffmpeg: encoder=%s container=%s output=%s\n",
            o->encoder, container[0] ? container : "auto",
            fb_shm_stream_ffmpeg_output_kind(o->output));
    return fb_shm_stream_spawn_ffmpeg(argv);
}

void fb_shm_stream_close_ffmpeg(FfmpegProcess *ffmpeg)
{
    if (!ffmpeg) {
        return;
    }
    if (ffmpeg->input) {
        fclose(ffmpeg->input);
    }
#ifdef _WIN32
    WaitForSingleObject(ffmpeg->process, INFINITE);
    CloseHandle(ffmpeg->process);
#else
    while (waitpid((pid_t)ffmpeg->pid, NULL, 0) < 0 && errno == EINTR) {
    }
#endif
    free(ffmpeg);
}

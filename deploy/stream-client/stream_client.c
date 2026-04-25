/*
 * stream_client.c — host-side C client for the H.264 streaming stack.
 *
 * What it does
 * ────────────
 *   1. Connects TCP <ip>:<iport> to AudioSvcHost (RFB 3.8 + VncAuth) for
 *      the input channel. Reads ServerInit, learns the guest desktop
 *      W × H, sends an empty SetEncodings (we never ask for FB updates).
 *   2. Opens an X11 window of W × H.
 *   3. fork+exec's mpv with --wid=<our window>, playing the H.264
 *      MPEG-TS at tcp://<ip>:<vport> (ddagrab + nvenc on guest).
 *   4. Pumps X11 events: KeyPress, MotionNotify, ButtonPress/Release,
 *      translated and shipped on the input socket as MSG_KEYEVENT (4)
 *      and MSG_POINTEREVENT (5). 4 ms motion-coalesce keeps the wire
 *      responsive without flooding.
 *
 * Why C
 * ─────
 *   The earlier Python version did the same thing but ate ~30–50 µs of
 *   dispatch overhead per X event (python-xlib parses every reply into
 *   Python objects, GIL, allocator). At 1000 Hz mouse polling that's
 *   visible lag. C dispatch is sub-microsecond, no GIL, no allocations
 *   on the hot path. Single source file, links libX11 only.
 *
 * Build
 * ─────
 *   cc -O2 -Wall -o stream_client stream_client.c -lX11
 */

#define _POSIX_C_SOURCE 200809L
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <stdarg.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <sys/select.h>
#include <sys/wait.h>

/* ───────── DES (mirror of vnc_server.c — VncAuth) ─────────────── */
static const uint8_t DES_S[8][64] = {
    {14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,
     4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13},
    {15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,14,12,0,1,10,6,9,11,5,
     0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9},
    {10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,
     13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12},
    {7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,
     10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,1,13,8,9,4,5,11,12,7,2,14},
    {2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,
     4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3},
    {12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,
     9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13},
    {4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,
     1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12},
    {13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,
     7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11}
};
static const uint8_t DES_P[32] = {
    16,7,20,21,29,12,28,17, 1,15,23,26, 5,18,31,10,
     2, 8,24,14,32,27, 3, 9,19,13,30, 6,22,11, 4,25
};
static const uint8_t DES_IP[64] = {
    58,50,42,34,26,18,10, 2,60,52,44,36,28,20,12, 4,
    62,54,46,38,30,22,14, 6,64,56,48,40,32,24,16, 8,
    57,49,41,33,25,17, 9, 1,59,51,43,35,27,19,11, 3,
    61,53,45,37,29,21,13, 5,63,55,47,39,31,23,15, 7
};
static const uint8_t DES_FP[64] = {
    40, 8,48,16,56,24,64,32,39, 7,47,15,55,23,63,31,
    38, 6,46,14,54,22,62,30,37, 5,45,13,53,21,61,29,
    36, 4,44,12,52,20,60,28,35, 3,43,11,51,19,59,27,
    34, 2,42,10,50,18,58,26,33, 1,41, 9,49,17,57,25
};
static const uint8_t DES_E[48] = {
    32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9,10,11,
    12,13,12,13,14,15,16,17,16,17,18,19,20,21,20,21,
    22,23,24,25,24,25,26,27,28,29,28,29,30,31,32, 1
};
static const uint8_t DES_PC1[56] = {
    57,49,41,33,25,17, 9, 1,58,50,42,34,26,18,10, 2,
    59,51,43,35,27,19,11, 3,60,52,44,36,63,55,47,39,
    31,23,15, 7,62,54,46,38,30,22,14, 6,61,53,45,37,
    29,21,13, 5,28,20,12, 4
};
static const uint8_t DES_PC2[48] = {
    14,17,11,24, 1, 5, 3,28,15, 6,21,10,23,19,12, 4,
    26, 8,16, 7,27,20,13, 2,41,52,31,37,47,55,30,40,
    51,45,33,48,44,49,39,56,34,53,46,42,50,36,29,32
};
static const uint8_t DES_ROT[16] = {1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1};

static uint64_t bitperm(uint64_t src, const uint8_t *perm, int n, int src_size) {
    uint64_t r = 0;
    for (int i = 0; i < n; i++) {
        uint64_t bit = (src >> (src_size - perm[i])) & 1;
        r |= bit << (n - 1 - i);
    }
    return r;
}
static void des_crypt(const uint8_t key[8], const uint8_t in[8], uint8_t out[8]) {
    uint64_t k = 0, m = 0;
    for (int i = 0; i < 8; i++) { k = (k<<8)|key[i]; m = (m<<8)|in[i]; }
    uint64_t key56 = bitperm(k, DES_PC1, 56, 64);
    uint32_t c = (key56 >> 28) & 0xFFFFFFF;
    uint32_t d =  key56        & 0xFFFFFFF;
    uint64_t subkeys[16];
    for (int i = 0; i < 16; i++) {
        c = ((c << DES_ROT[i]) | (c >> (28 - DES_ROT[i]))) & 0xFFFFFFF;
        d = ((d << DES_ROT[i]) | (d >> (28 - DES_ROT[i]))) & 0xFFFFFFF;
        uint64_t cd = ((uint64_t)c << 28) | d;
        subkeys[i] = bitperm(cd, DES_PC2, 48, 56);
    }
    uint64_t ip = bitperm(m, DES_IP, 64, 64);
    uint32_t L = (uint32_t)(ip >> 32);
    uint32_t R = (uint32_t)(ip & 0xFFFFFFFF);
    for (int round = 0; round < 16; round++) {
        uint64_t expR = bitperm(R, DES_E, 48, 32);
        uint64_t x = expR ^ subkeys[round];
        uint32_t s_out = 0;
        for (int i = 0; i < 8; i++) {
            uint8_t six = (x >> (42 - 6*i)) & 0x3F;
            uint8_t row = ((six & 0x20) >> 4) | (six & 1);
            uint8_t col = (six >> 1) & 0xF;
            s_out = (s_out << 4) | DES_S[i][row*16 + col];
        }
        uint32_t f = (uint32_t)bitperm(s_out, DES_P, 32, 32);
        uint32_t newL = R;
        R = L ^ f;
        L = newL;
    }
    uint64_t pre = ((uint64_t)R << 32) | L;
    uint64_t fp = bitperm(pre, DES_FP, 64, 64);
    for (int i = 0; i < 8; i++) out[i] = (fp >> (56 - 8*i)) & 0xFF;
}
static void vnc_flip_bits(uint8_t k[8]) {
    for (int i = 0; i < 8; i++) {
        uint8_t v = k[i], r = 0;
        for (int b = 0; b < 8; b++) if (v & (1<<b)) r |= 1 << (7-b);
        k[i] = r;
    }
}

/* ───────── socket helpers ─────────────────────────────────────── */
static int read_n(int s, void *p, int n) {
    char *b = p;
    while (n > 0) {
        ssize_t r = recv(s, b, n, 0);
        if (r <= 0) return -1;
        b += r; n -= r;
    }
    return 0;
}
static int write_n(int s, const void *p, int n) {
    const char *b = p;
    while (n > 0) {
        ssize_t r = send(s, b, n, MSG_NOSIGNAL);
        if (r <= 0) return -1;
        b += r; n -= r;
    }
    return 0;
}

/* ───────── RFB input client ───────────────────────────────────── */
static int rfb_handshake(int s, const char *password) {
    char ver[12];
    if (read_n(s, ver, 12) < 0) return -1;
    if (write_n(s, "RFB 003.008\n", 12) < 0) return -1;

    uint8_t n;
    if (read_n(s, &n, 1) < 0) return -1;
    if (n == 0) { fprintf(stderr, "server offered no security types\n"); return -1; }
    uint8_t types[256];
    if (read_n(s, types, n) < 0) return -1;
    int has_vncauth = 0;
    for (int i = 0; i < n; i++) if (types[i] == 2) { has_vncauth = 1; break; }
    if (!has_vncauth) { fprintf(stderr, "server does not offer VncAuth\n"); return -1; }
    uint8_t two = 2;
    if (write_n(s, &two, 1) < 0) return -1;

    uint8_t challenge[16];
    if (read_n(s, challenge, 16) < 0) return -1;
    uint8_t key[8] = {0};
    strncpy((char*)key, password, 8);
    vnc_flip_bits(key);
    uint8_t resp[16];
    des_crypt(key, challenge,     resp);
    des_crypt(key, challenge + 8, resp + 8);
    if (write_n(s, resp, 16) < 0) return -1;

    uint8_t result[4];
    if (read_n(s, result, 4) < 0) return -1;
    if (result[3] != 0) {
        fprintf(stderr, "VncAuth failed (result=%u)\n", result[3]);
        return -1;
    }

    /* ClientInit shared=1 */
    uint8_t shared = 1;
    if (write_n(s, &shared, 1) < 0) return -1;
    return 0;
}

static int rfb_read_serverinit(int s, int *out_w, int *out_h) {
    uint8_t init[24];
    if (read_n(s, init, 24) < 0) return -1;
    *out_w = (init[0] << 8) | init[1];
    *out_h = (init[2] << 8) | init[3];
    uint32_t namelen = ((uint32_t)init[20] << 24) | ((uint32_t)init[21] << 16) |
                       ((uint32_t)init[22] << 8)  | init[23];
    char tmp[256];
    while (namelen > 0) {
        uint32_t chunk = namelen > sizeof(tmp) ? sizeof(tmp) : namelen;
        if (read_n(s, tmp, chunk) < 0) return -1;
        namelen -= chunk;
    }
    return 0;
}

/* MSG_POINTEREVENT (type=5) — 6 bytes total. We use send() with
 * MSG_NOSIGNAL and don't loop on short writes: a short write means
 * the socket is unusable, and short writes on TCP for 6/8-byte
 * messages essentially never happen anyway. If the socket dies the
 * next read on it will fail and we exit cleanly.
 *
 * No allocations, no copies — these run thousands of times per second. */
static inline void rfb_send_pointer(int s, uint8_t mask, int x, int y) {
    if (x < 0) x = 0; else if (x > 0xFFFF) x = 0xFFFF;
    if (y < 0) y = 0; else if (y > 0xFFFF) y = 0xFFFF;
    uint8_t buf[6] = {
        5, mask,
        (uint8_t)(x >> 8), (uint8_t)x,
        (uint8_t)(y >> 8), (uint8_t)y,
    };
    (void)send(s, buf, 6, MSG_NOSIGNAL);
}
static inline void rfb_send_key(int s, int down, uint32_t keysym) {
    uint8_t buf[8] = {
        4, (uint8_t)(down ? 1 : 0), 0, 0,
        (uint8_t)(keysym >> 24), (uint8_t)(keysym >> 16),
        (uint8_t)(keysym >> 8),  (uint8_t)keysym,
    };
    (void)send(s, buf, 8, MSG_NOSIGNAL);
}
static inline void rfb_send_setencodings_empty(int s) {
    uint8_t buf[4] = { 2, 0, 0, 0 };
    (void)send(s, buf, 4, MSG_NOSIGNAL);
}

/* ───────── connect helper ─────────────────────────────────────── */
static int connect_tcp(const char *ip, int port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); return -1; }
    int on = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    if (inet_pton(AF_INET, ip, &a.sin_addr) <= 0) {
        fprintf(stderr, "bad ip %s\n", ip); close(s); return -1;
    }
    if (connect(s, (struct sockaddr*)&a, sizeof(a)) < 0) {
        fprintf(stderr, "connect %s:%d: %s\n", ip, port, strerror(errno));
        close(s); return -1;
    }
    return s;
}

/* ───────── mpv subprocess ─────────────────────────────────────── */
static pid_t mpv_pid = 0;

static void spawn_mpv(Window xwin, const char *ip, int vport,
                      int win_w, int win_h)
{
    char wid_arg[64], geom_arg[64], autofit_arg[64], hwdec_arg[64], vo_arg[64];
    char url[160];
    snprintf(wid_arg,     sizeof(wid_arg),     "--wid=%lu", (unsigned long)xwin);
    snprintf(geom_arg,    sizeof(geom_arg),    "--geometry=%dx%d+0+0", win_w, win_h);
    snprintf(autofit_arg, sizeof(autofit_arg), "--autofit=%dx%d", win_w, win_h);

    const char *vo_env    = getenv("STREAM_VO");
    const char *hwdec_env = getenv("STREAM_HWDEC");
    snprintf(vo_arg,    sizeof(vo_arg),    "--vo=%s",
             (vo_env    && *vo_env)    ? vo_env    : "xv");
    snprintf(hwdec_arg, sizeof(hwdec_arg), "--hwdec=%s",
             (hwdec_env && *hwdec_env) ? hwdec_env : "auto-safe");

    snprintf(url, sizeof(url), "tcp://%s:%d", ip, vport);

    /* mpv low-latency cocktail.
     *
     * --demuxer-lavf-format=h264 — tell mpv the wire is bare H.264 Annex-B
     *     (the server now uses `-f h264` instead of `-f mpegts`; raw NAL
     *     units have no container overhead and no demuxer-side packet
     *     accumulation, saves ~100 ms vs MPEG-TS).
     * --untimed                  — render frames as soon as decoded, no
     *     av-sync waiting for a wallclock timestamp (~16 ms saved per
     *     frame at 60 Hz).
     * --no-correct-pts           — don't reorder by PTS, just first-in-
     *     first-out display order. Our encoder is `bf=0`, no B-frames,
     *     so PTS == DTS == arrival order anyway.
     * --vd-lavc-threads=1        — single-threaded decode is lower
     *     latency than parallel slice/frame decoding for low-bitrate
     *     720p; threading adds buffering.
     */
    char *argv[] = {
        (char*)"mpv",
        wid_arg,
        (char*)"--profile=low-latency",
        (char*)"--no-osc",
        (char*)"--no-osd-bar",
        (char*)"--no-input-default-bindings",
        (char*)"--no-input-cursor",
        (char*)"--input-conf=/dev/null",
        (char*)"--cursor-autohide=no",
        (char*)"--cache=no",
        (char*)"--demuxer-readahead-secs=0",
        (char*)"--demuxer-lavf-format=h264",
        (char*)"--demuxer-lavf-o-set=fflags=+nobuffer+flush_packets+discardcorrupt",
        (char*)"--demuxer-lavf-probesize=32",
        (char*)"--demuxer-lavf-analyzeduration=0",
        (char*)"--vd-lavc-threads=1",
        (char*)"--vd-lavc-show-all=yes",
        (char*)"--no-correct-pts",
        (char*)"--untimed",
        (char*)"--no-audio",
        (char*)"--keepaspect=yes",
        (char*)"--no-border",
        (char*)"--ontop=no",
        geom_arg,
        autofit_arg,
        hwdec_arg,
        vo_arg,
        url,
        NULL,
    };

    pid_t pid = fork();
    if (pid < 0) { perror("fork"); exit(1); }
    if (pid == 0) {
        int log_fd = open("/tmp/stream-mpv.log",
                          O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (log_fd >= 0) {
            dup2(log_fd, STDOUT_FILENO);
            dup2(log_fd, STDERR_FILENO);
            close(log_fd);
        }
        execvp("mpv", argv);
        perror("execvp mpv");
        _exit(127);
    }
    mpv_pid = pid;
}

/* ───────── main ──────────────────────────────────────────────── */
struct args {
    const char *ip;
    int vport, iport;
    const char *password;
    int width, height;
};

static void usage(const char *p) {
    fprintf(stderr,
        "usage: %s --ip <guest> [--vport 56790] [--iport 56789]\n"
        "          [--password <pw>] [--width N] [--height N]\n"
        "  env STREAM_VO=<xv|gpu|vaapi|...>      mpv video output\n"
        "  env STREAM_HWDEC=<auto-safe|cuda|...> mpv hwdec\n", p);
}

static volatile sig_atomic_t want_quit = 0;
static void on_quit(int sig) { (void)sig; want_quit = 1; }

int main(int argc, char **argv) {
    struct args a = {
        .ip = NULL, .vport = 56790, .iport = 56789,
        .password = "123456", .width = 0, .height = 0,
    };
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--ip") && i+1 < argc)         a.ip = argv[++i];
        else if (!strcmp(argv[i], "--vport") && i+1 < argc) a.vport = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--iport") && i+1 < argc) a.iport = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--password") && i+1 < argc) a.password = argv[++i];
        else if (!strcmp(argv[i], "--width") && i+1 < argc)  a.width  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--height") && i+1 < argc) a.height = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]); return 0;
        } else {
            fprintf(stderr, "unknown arg %s\n", argv[i]);
            usage(argv[0]); return 2;
        }
    }
    if (!a.ip) { usage(argv[0]); return 2; }

    /* 1) input channel + RFB handshake */
    fprintf(stderr, "[stream] connecting input %s:%d\n", a.ip, a.iport);
    int isock = connect_tcp(a.ip, a.iport);
    if (isock < 0) return 1;
    if (rfb_handshake(isock, a.password) < 0) { close(isock); return 1; }
    int srv_w, srv_h;
    if (rfb_read_serverinit(isock, &srv_w, &srv_h) < 0) { close(isock); return 1; }
    fprintf(stderr, "[stream] guest desktop %dx%d\n", srv_w, srv_h);
    rfb_send_setencodings_empty(isock);

    /* 2) X11 setup */
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "XOpenDisplay failed (DISPLAY=%s)\n", getenv("DISPLAY")); return 1; }
    int scr = DefaultScreen(dpy);
    int max_w = DisplayWidth(dpy, scr) - 50;
    int max_h = DisplayHeight(dpy, scr) - 100;
    int win_w = a.width  ? a.width  : srv_w;
    int win_h = a.height ? a.height : srv_h;
    if (win_w > max_w) win_w = max_w;
    if (win_h > max_h) win_h = max_h;
    fprintf(stderr, "[stream] window %dx%d (max %dx%d)\n", win_w, win_h, max_w, max_h);

    Window root = RootWindow(dpy, scr);
    XSetWindowAttributes wa = {
        .background_pixel = BlackPixel(dpy, scr),
        .event_mask = KeyPressMask | KeyReleaseMask |
                      ButtonPressMask | ButtonReleaseMask |
                      PointerMotionMask | EnterWindowMask | LeaveWindowMask |
                      FocusChangeMask | StructureNotifyMask | ExposureMask,
    };
    Window win = XCreateWindow(dpy, root, 0, 0, win_w, win_h, 0,
                               CopyFromParent, InputOutput, CopyFromParent,
                               CWBackPixel | CWEventMask, &wa);
    char title[160];
    snprintf(title, sizeof(title), "Audio Stream - %s", a.ip);
    XStoreName(dpy, win, title);
    XClassHint ch = { (char*)"audiostream", (char*)"AudioStream" };
    XSetClassHint(dpy, win, &ch);
    XSizeHints sh;
    sh.flags = PMinSize | PMaxSize;
    sh.min_width  = sh.max_width  = win_w;
    sh.min_height = sh.max_height = win_h;
    XSetWMNormalHints(dpy, win, &sh);
    Atom WM_DELETE = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &WM_DELETE, 1);
    XMapWindow(dpy, win);
    XSync(dpy, False);

    XEvent xev;
    while (1) {
        XNextEvent(dpy, &xev);
        if (xev.type == MapNotify) break;
    }
    fprintf(stderr, "[stream] window 0x%lx mapped\n", (unsigned long)win);

    /* 3) spawn mpv */
    /* Auto-reap zombies; we just `kill(mpv_pid, 0)` to test liveness. */
    signal(SIGCHLD, SIG_IGN);
    spawn_mpv(win, a.ip, a.vport, win_w, win_h);

    /* Force keyboard focus on our window AND hide the host pointer.
     *
     * mpv creates a child X window inside ours (via --wid) and X11
     * routes KeyPress to the focus window. The mpv child fully covers
     * our interior, so EnterNotify / FocusIn don't reach us — the
     * earlier "grab on EnterNotify" hook never fired. Grab the keyboard
     * unconditionally and immediately; owner_events=False routes EVERY
     * KeyPress/KeyRelease to our window regardless of focus.
     *
     * The host X cursor would otherwise draw on top of the rendered
     * video, which when paired with the guest's own cursor (encoded
     * into the video frame and arriving ~30 ms later) creates a
     * "double cursor / trail" artifact. XDefineCursor with a 1×1
     * transparent pixmap suppresses the host cursor whenever the
     * pointer is over our window — the user sees only the guest
     * cursor coming from the video stream.
     */
    XSetInputFocus(dpy, win, RevertToParent, CurrentTime);
    {
        Pixmap p = XCreatePixmap(dpy, win, 1, 1, 1);
        XColor c = {0};
        Cursor blank = XCreatePixmapCursor(dpy, p, p, &c, &c, 0, 0);
        XDefineCursor(dpy, win, blank);
        XFreePixmap(dpy, p);
        XFreeCursor(dpy, blank);
    }
    {
        int rc = XGrabKeyboard(dpy, win, False,
                               GrabModeAsync, GrabModeAsync, CurrentTime);
        if (rc == GrabSuccess) {
            fprintf(stderr, "[stream] keyboard grabbed (rc=0)\n");
        } else {
            fprintf(stderr, "[stream] keyboard grab failed rc=%d\n", rc);
        }
    }
    XSync(dpy, False);

    signal(SIGINT,  on_quit);
    signal(SIGTERM, on_quit);
    signal(SIGPIPE, SIG_IGN);

    /* 4) Event loop.
     *   - select on the X11 fd with a 4 ms timeout. The timeout flushes
     *     pending pointer-motion (we coalesce: only the latest position
     *     within a 4 ms window goes on the wire).
     *   - All button/key events go immediately, no coalesce.
     */
    int xfd = ConnectionNumber(dpy);
    uint8_t button_mask = 0;
    int pending_x = 0, pending_y = 0;
    int dirty_pos = 0;
    int kbd_grabbed = 1;  /* grabbed unconditionally above */

    while (!want_quit) {
        if (kill(mpv_pid, 0) < 0 && errno == ESRCH) {
            fprintf(stderr, "[stream] mpv exited\n");
            break;
        }

        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(xfd, &rfds);
        struct timeval tv = { 0, 4 * 1000 };  /* 4 ms */
        select(xfd + 1, &rfds, NULL, NULL, &tv);

        while (XPending(dpy)) {
            XNextEvent(dpy, &xev);
            if (getenv("STREAM_DEBUG")) {
                fprintf(stderr, "[stream-dbg] xev type=%d\n", xev.type);
            }
            switch (xev.type) {
            case KeyPress:
            case KeyRelease: {
                KeyCode kc = xev.xkey.keycode;
                KeySym ks = XkbKeycodeToKeysym(dpy, kc, 0, 0);
                if (xev.xkey.state & ShiftMask) {
                    KeySym shifted = XkbKeycodeToKeysym(dpy, kc, 0, 1);
                    if (shifted != NoSymbol) ks = shifted;
                }
                if (getenv("STREAM_DEBUG")) {
                    fprintf(stderr, "[stream-dbg]   key %s kc=%u ks=0x%lx\n",
                            xev.type == KeyPress ? "DN" : "UP",
                            (unsigned)kc, (unsigned long)ks);
                }
                if (ks != NoSymbol) {
                    rfb_send_key(isock, xev.type == KeyPress, (uint32_t)ks);
                }
                break;
            }
            case MotionNotify:
                pending_x = (int)((int64_t)xev.xmotion.x * srv_w / win_w);
                pending_y = (int)((int64_t)xev.xmotion.y * srv_h / win_h);
                dirty_pos = 1;
                break;
            case ButtonPress:
            case ButtonRelease: {
                uint8_t bit = 0;
                switch (xev.xbutton.button) {
                case 1: bit = 1; break;
                case 2: bit = 2; break;
                case 3: bit = 4; break;
                case 4: bit = 8; break;
                case 5: bit = 16; break;
                }
                int x = (int)((int64_t)xev.xbutton.x * srv_w / win_w);
                int y = (int)((int64_t)xev.xbutton.y * srv_h / win_h);
                if (xev.type == ButtonPress) {
                    button_mask |= bit;
                } else {
                    if (bit < 8) button_mask &= ~bit;  /* wheels are edge-only */
                }
                rfb_send_pointer(isock, button_mask, x, y);
                if (xev.type == ButtonPress && bit >= 8) {
                    /* wheel pulse: send release immediately */
                    button_mask &= ~bit;
                    rfb_send_pointer(isock, button_mask, x, y);
                }
                pending_x = x; pending_y = y;
                dirty_pos = 0;
                break;
            }
            case EnterNotify:
                /* Filter out synthetic Enter/Leave events that XGrabKeyboard
                 * itself produces (mode=NotifyGrab/NotifyUngrab) — we only
                 * want to react to real pointer crossings caused by the
                 * user moving the mouse. Without this filter the very act
                 * of XGrabKeyboard fires a synthetic Leave and we'd
                 * immediately ungrab the keyboard we just grabbed. */
                if (xev.xcrossing.mode == NotifyNormal && !kbd_grabbed) {
                    int rc = XGrabKeyboard(dpy, win, False,
                                           GrabModeAsync, GrabModeAsync,
                                           CurrentTime);
                    if (rc == GrabSuccess) {
                        kbd_grabbed = 1;
                    } else {
                        fprintf(stderr, "[stream] XGrabKeyboard rc=%d\n", rc);
                    }
                }
                break;
            case LeaveNotify:
                /* Release the keyboard so the user can switch to other
                 * apps with Alt+Tab etc. without us hogging keys. Only
                 * on real pointer-out (mode=NotifyNormal); ignore the
                 * NotifyGrab/Ungrab synthetics. */
                if (xev.xcrossing.mode == NotifyNormal && kbd_grabbed) {
                    XUngrabKeyboard(dpy, CurrentTime);
                    kbd_grabbed = 0;
                }
                break;
            case ClientMessage:
                if ((Atom)xev.xclient.data.l[0] == WM_DELETE) {
                    want_quit = 1;
                }
                break;
            }
        }

        /* coalesce flush */
        if (dirty_pos) {
            rfb_send_pointer(isock, button_mask, pending_x, pending_y);
            dirty_pos = 0;
        }
    }

    fprintf(stderr, "[stream] shutting down\n");
    if (mpv_pid > 0) kill(mpv_pid, SIGTERM);
    close(isock);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    /* mpv reaps via SIGCHLD=SIG_IGN */
    return 0;
}

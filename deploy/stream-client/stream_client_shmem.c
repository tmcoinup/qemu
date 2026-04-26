/*
 * stream_client_shmem.c — host-side streaming client over the
 * ivshmem shared-memory transport. Sister to stream_client.c (TCP).
 *
 * Differences vs stream_client.c
 * ──────────────────────────────
 *   - No TCP socket, no RFB/VncAuth: video bytes come from the video
 *     ring of the shmem region, input events go into the input ring.
 *     The relay process (nv_stream_relay.exe) inside the guest does
 *     the encoding + RFB handshake to AudioSvcHost on the guest side.
 *   - mpv's input is now a stdin pipe (we feed it raw H.264 from the
 *     video ring) instead of `tcp://guest:56790`.
 *   - Coordinates are still scaled to guest_width/guest_height which
 *     the relay writes into the shmem header at startup.
 *
 * Usage:
 *   stream_client_shmem --vm 1                 # /dev/shm/nv-shmem-vm1
 *   stream_client_shmem --shmem /path/to/file
 *
 * Build:
 *   cc -O2 -Wall -pthread -o stream_client_shmem stream_client_shmem.c -lX11
 */

#define _POSIX_C_SOURCE 200809L
#include "../nv-shmem/nv_shmem_proto.h"

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <time.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <sys/wait.h>

/* ──────────────────────── shmem attach ─────────────────────────── */
struct args {
    int   vm_id;
    const char *shmem_path;   /* override: /path/to/file */
    int   width, height;      /* override window size */
};

static const char *DEFAULT_PATH_FMT = "/dev/shm/nv-shmem-vm%d";
static char path_buf[64];

static void *g_shmem = NULL;
static size_t g_shmem_size = 0;

static int shmem_attach(const char *path) {
    int fd = open(path, O_RDWR);
    if (fd < 0) { perror(path); return -1; }
    struct stat st;
    if (fstat(fd, &st) < 0) { perror("fstat"); close(fd); return -1; }
    g_shmem = mmap(NULL, st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (g_shmem == MAP_FAILED) { perror("mmap"); return -1; }
    g_shmem_size = st.st_size;
    return 0;
}

/* Spin up to deadline_ms waiting for the guest relay to flip
 * magic + guest_width fields. */
static int shmem_wait_ready(int deadline_ms) {
    NvShmemHdr *hdr = (NvShmemHdr *)g_shmem;
    int waited = 0;
    while (waited < deadline_ms) {
        if (NV_SHMEM_LOAD_ACQ(&hdr->magic)        == NV_SHMEM_MAGIC &&
            NV_SHMEM_LOAD_ACQ(&hdr->guest_width)  != 0 &&
            NV_SHMEM_LOAD_ACQ(&hdr->guest_height) != 0) return 0;
        struct timespec ts = {0, 50 * 1000 * 1000};  /* 50 ms */
        nanosleep(&ts, NULL);
        waited += 50;
    }
    return -1;
}

/* ──────────────────────── input write helpers ──────────────────── */
static inline void shmem_send_pointer(uint8_t mask, int x, int y) {
    if (x < 0) x = 0; else if (x > 0xFFFF) x = 0xFFFF;
    if (y < 0) y = 0; else if (y > 0xFFFF) y = 0xFFFF;
    uint8_t buf[6] = {
        5, mask,
        (uint8_t)(x >> 8), (uint8_t)x,
        (uint8_t)(y >> 8), (uint8_t)y,
    };
    NvShmemHdr *hdr = (NvShmemHdr *)g_shmem;
    nv_shmem_write((uint8_t *)g_shmem + hdr->input_off,
                   NV_SHMEM_INPUT_BYTES, &hdr->input, buf, 6);
}
static inline void shmem_send_key(int down, uint32_t keysym) {
    uint8_t buf[8] = {
        4, (uint8_t)(down ? 1 : 0), 0, 0,
        (uint8_t)(keysym >> 24), (uint8_t)(keysym >> 16),
        (uint8_t)(keysym >> 8),  (uint8_t)keysym,
    };
    NvShmemHdr *hdr = (NvShmemHdr *)g_shmem;
    nv_shmem_write((uint8_t *)g_shmem + hdr->input_off,
                   NV_SHMEM_INPUT_BYTES, &hdr->input, buf, 8);
}

/* ──────────────────────── video pump thread ────────────────────── */
static int   g_mpv_stdin_w = -1;
static pid_t g_mpv_pid     = 0;
static volatile sig_atomic_t want_quit = 0;

static void *video_pump(void *arg) {
    (void)arg;
    NvShmemHdr *hdr = (NvShmemHdr *)g_shmem;
    uint8_t *ring = (uint8_t *)g_shmem + hdr->video_off;
    uint8_t buf[256 * 1024];
    uint32_t out_size = 0;

    while (!want_quit) {
        int rc = nv_shmem_read(ring, NV_SHMEM_VIDEO_BYTES, &hdr->video,
                               buf, sizeof(buf), &out_size);
        if (rc == 0) {
            struct timespec ts = {0, 1 * 1000 * 1000}; /* 1 ms */
            nanosleep(&ts, NULL);
            continue;
        }
        if (rc < 0) continue;  /* oversize - drop, shouldn't happen */
        ssize_t w = write(g_mpv_stdin_w, buf, out_size);
        if (w <= 0) {
            fprintf(stderr, "[stream-shmem] mpv stdin write fail: %s\n", strerror(errno));
            want_quit = 1;
            break;
        }
    }
    return NULL;
}

/* ──────────────────────── X11 + mpv glue ───────────────────────── */
static void on_quit(int sig) { (void)sig; want_quit = 1; }

static void spawn_mpv_stdin(Window xwin, int win_w, int win_h, int *out_pipe_w) {
    int p[2];
    if (pipe(p) < 0) { perror("pipe"); exit(1); }

    char wid_arg[64], geom_arg[64], autofit_arg[64], hwdec_arg[64], vo_arg[64];
    snprintf(wid_arg,     sizeof(wid_arg),     "--wid=%lu", (unsigned long)xwin);
    snprintf(geom_arg,    sizeof(geom_arg),    "--geometry=%dx%d+0+0", win_w, win_h);
    snprintf(autofit_arg, sizeof(autofit_arg), "--autofit=%dx%d", win_w, win_h);
    const char *vo_env    = getenv("STREAM_VO");
    const char *hwdec_env = getenv("STREAM_HWDEC");
    snprintf(vo_arg,    sizeof(vo_arg),    "--vo=%s",
             (vo_env    && *vo_env)    ? vo_env    : "xv");
    snprintf(hwdec_arg, sizeof(hwdec_arg), "--hwdec=%s",
             (hwdec_env && *hwdec_env) ? hwdec_env : "auto-safe");

    char *argv[] = {
        (char*)"mpv",
        wid_arg,
        (char*)"--profile=low-latency",
        (char*)"--no-osc", (char*)"--no-osd-bar",
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
        geom_arg, autofit_arg, hwdec_arg, vo_arg,
        (char*)"-",   /* read from stdin */
        NULL,
    };

    pid_t pid = fork();
    if (pid < 0) { perror("fork"); exit(1); }
    if (pid == 0) {
        dup2(p[0], STDIN_FILENO);
        close(p[0]); close(p[1]);
        int log_fd = open("/tmp/stream-mpv.log", O_WRONLY|O_CREAT|O_TRUNC, 0644);
        if (log_fd >= 0) { dup2(log_fd, 1); dup2(log_fd, 2); close(log_fd); }
        execvp("mpv", argv);
        perror("execvp mpv"); _exit(127);
    }
    close(p[0]);
    *out_pipe_w = p[1];
    g_mpv_pid = pid;
}

static void parse_args(int argc, char **argv, struct args *a) {
    a->vm_id = 1; a->shmem_path = NULL; a->width = 0; a->height = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--vm") && i+1 < argc) a->vm_id = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--shmem") && i+1 < argc) a->shmem_path = argv[++i];
        else if (!strcmp(argv[i], "--width")  && i+1 < argc) a->width = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--height") && i+1 < argc) a->height = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            fprintf(stderr,
              "usage: %s [--vm N | --shmem /path/to/file] [--width N --height N]\n",
              argv[0]); exit(0);
        } else { fprintf(stderr, "unknown arg %s\n", argv[i]); exit(2); }
    }
    if (!a->shmem_path) {
        snprintf(path_buf, sizeof(path_buf), DEFAULT_PATH_FMT, a->vm_id);
        a->shmem_path = path_buf;
    }
}

int main(int argc, char **argv) {
    struct args a;
    parse_args(argc, argv, &a);

    fprintf(stderr, "[stream-shmem] attaching %s\n", a.shmem_path);
    if (shmem_attach(a.shmem_path) < 0) return 1;

    fprintf(stderr, "[stream-shmem] waiting for guest relay (magic+size)\n");
    if (shmem_wait_ready(15000) < 0) {
        fprintf(stderr, "[stream-shmem] timeout — is nv_stream_relay running in guest?\n");
        return 1;
    }
    NvShmemHdr *hdr = (NvShmemHdr *)g_shmem;
    int srv_w = hdr->guest_width, srv_h = hdr->guest_height;
    fprintf(stderr, "[stream-shmem] guest desktop %dx%d\n", srv_w, srv_h);

    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "XOpenDisplay failed\n"); return 1; }
    int scr = DefaultScreen(dpy);
    int max_w = DisplayWidth(dpy, scr) - 50;
    int max_h = DisplayHeight(dpy, scr) - 100;
    int win_w = a.width  ? a.width  : srv_w;
    int win_h = a.height ? a.height : srv_h;
    if (win_w > max_w) win_w = max_w;
    if (win_h > max_h) win_h = max_h;

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
    snprintf(title, sizeof(title), "Audio Stream (shmem) - vm%d", a.vm_id);
    XStoreName(dpy, win, title);
    XClassHint ch = { (char*)"audiostream", (char*)"AudioStream" };
    XSetClassHint(dpy, win, &ch);
    XSizeHints sh;
    sh.flags = PMinSize | PMaxSize;
    sh.min_width = sh.max_width = win_w;
    sh.min_height = sh.max_height = win_h;
    XSetWMNormalHints(dpy, win, &sh);
    Atom WM_DELETE = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &WM_DELETE, 1);
    XMapWindow(dpy, win);
    XSync(dpy, False);
    XEvent xev;
    while (1) { XNextEvent(dpy, &xev); if (xev.type == MapNotify) break; }
    fprintf(stderr, "[stream-shmem] window 0x%lx mapped\n", (unsigned long)win);

    signal(SIGCHLD, SIG_IGN);
    spawn_mpv_stdin(win, win_w, win_h, &g_mpv_stdin_w);
    fprintf(stderr, "[stream-shmem] mpv pid %d spawned, stdin fd %d\n",
            (int)g_mpv_pid, g_mpv_stdin_w);

    XSetInputFocus(dpy, win, RevertToParent, CurrentTime);
    XGrabKeyboard(dpy, win, False, GrabModeAsync, GrabModeAsync, CurrentTime);
    XSync(dpy, False);

    signal(SIGINT,  on_quit);
    signal(SIGTERM, on_quit);
    signal(SIGPIPE, SIG_IGN);

    pthread_t pump_t;
    pthread_create(&pump_t, NULL, video_pump, NULL);

    int xfd = ConnectionNumber(dpy);
    uint8_t button_mask = 0;
    int pending_x = 0, pending_y = 0;
    int dirty_pos = 0;

    while (!want_quit) {
        if (g_mpv_pid > 0 && kill(g_mpv_pid, 0) < 0 && errno == ESRCH) {
            fprintf(stderr, "[stream-shmem] mpv exited\n"); break;
        }
        fd_set rfds; FD_ZERO(&rfds); FD_SET(xfd, &rfds);
        struct timeval tv = { 0, 4 * 1000 };
        select(xfd + 1, &rfds, NULL, NULL, &tv);

        while (XPending(dpy)) {
            XNextEvent(dpy, &xev);
            switch (xev.type) {
            case KeyPress:
            case KeyRelease: {
                KeyCode kc = xev.xkey.keycode;
                KeySym ks = XkbKeycodeToKeysym(dpy, kc, 0, 0);
                if (xev.xkey.state & ShiftMask) {
                    KeySym shifted = XkbKeycodeToKeysym(dpy, kc, 0, 1);
                    if (shifted != NoSymbol) ks = shifted;
                }
                if (ks != NoSymbol) shmem_send_key(xev.type == KeyPress, (uint32_t)ks);
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
                case 1: bit = 1; break;  case 2: bit = 2; break;
                case 3: bit = 4; break;  case 4: bit = 8; break; case 5: bit = 16; break;
                }
                int x = (int)((int64_t)xev.xbutton.x * srv_w / win_w);
                int y = (int)((int64_t)xev.xbutton.y * srv_h / win_h);
                if (xev.type == ButtonPress) button_mask |= bit;
                else if (bit < 8) button_mask &= ~bit;
                shmem_send_pointer(button_mask, x, y);
                if (xev.type == ButtonPress && bit >= 8) {
                    button_mask &= ~bit;
                    shmem_send_pointer(button_mask, x, y);
                }
                pending_x = x; pending_y = y; dirty_pos = 0;
                break;
            }
            case ClientMessage:
                if ((Atom)xev.xclient.data.l[0] == WM_DELETE) want_quit = 1;
                break;
            }
        }
        if (dirty_pos) {
            shmem_send_pointer(button_mask, pending_x, pending_y);
            dirty_pos = 0;
        }
    }

    fprintf(stderr, "[stream-shmem] shutting down\n");
    if (g_mpv_pid > 0) kill(g_mpv_pid, SIGTERM);
    if (g_mpv_stdin_w >= 0) close(g_mpv_stdin_w);
    pthread_join(pump_t, NULL);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}

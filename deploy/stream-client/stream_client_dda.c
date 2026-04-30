/*
 * stream_client_dda.c — host-side viewer for the dirty-tile / raw-BGRA
 * ivshmem transport written by NvStreamSvc.exe in the guest.
 *
 * No mpv, no ffmpeg, no codec at all on the host. The guest streams
 * raw 32x32 tiles of BGRA pixels into the video ring; this client
 * mmaps the same RAM, parses the FRAM messages, and uploads each
 * dirty tile straight into an SDL2 texture, then presents.
 *
 * Input goes the other direction — SDL keyboard/mouse events get
 * encoded as RFB pointer/key messages and pushed into the input ring,
 * which the relay forwards to AudioSvcHost over local TCP inside the
 * guest.
 *
 * Build:
 *   cc -O2 -Wall -pthread -o stream_client_dda stream_client_dda.c \
 *      $(pkg-config --cflags sdl2) $(pkg-config --libs sdl2)
 */

#define _POSIX_C_SOURCE 200809L
#include "../nv-shmem/nv_shmem_proto.h"

#include <SDL2/SDL.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <sys/stat.h>

/* ──────────────────────── shmem attach ─────────────────────────── */
static void *g_shmem = NULL;
static size_t g_shmem_size = 0;

static int shmem_attach(const char *path) {
    int fd = open(path, O_RDWR);
    if (fd < 0) { perror(path); return -1; }
    struct stat st; fstat(fd, &st);
    g_shmem = mmap(NULL, st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (g_shmem == MAP_FAILED) { perror("mmap"); return -1; }
    g_shmem_size = st.st_size;
    return 0;
}

/* ──────────────────────── waiting splash drawing ───────────────
 * No SDL2_ttf dep — render a 7-segment elapsed-seconds counter and
 * a 4-quadrant rotating spinner using only SDL_RenderFillRect. */

/* Segment layout per digit:
 *
 *      0
 *    ┌───┐
 *    │1  │2
 *    ├─3─┤
 *    │4  │5
 *    └───┘
 *      6
 *
 * Bit i in digit_segments[d] = segment i is on for digit d. */
static const uint8_t digit_segments[10] = {
    0x77, /* 0: 0,1,2,4,5,6 */
    0x24, /* 1: 2,5         */
    0x5D, /* 2: 0,2,3,4,6   */
    0x6D, /* 3: 0,2,3,5,6   */
    0x2E, /* 4: 1,2,3,5     */
    0x6B, /* 5: 0,1,3,5,6   */
    0x7B, /* 6: 0,1,3,4,5,6 */
    0x25, /* 7: 0,2,5       */
    0x7F, /* 8: all         */
    0x6F, /* 9: 0,1,2,3,5,6 */
};

static void draw_7seg_digit(SDL_Renderer *r, int x, int y, int w, int h, int d) {
    if (d < 0 || d > 9) return;
    int t = h / 12; if (t < 2) t = 2;          /* segment thickness */
    int half_h = h / 2;
    uint8_t seg = digit_segments[d];
    SDL_Rect rc;
    if (seg & 0x01) { rc=(SDL_Rect){x,         y,                w, t};      SDL_RenderFillRect(r,&rc); } /* top   */
    if (seg & 0x02) { rc=(SDL_Rect){x,         y,                t, half_h}; SDL_RenderFillRect(r,&rc); } /* TL    */
    if (seg & 0x04) { rc=(SDL_Rect){x + w - t, y,                t, half_h}; SDL_RenderFillRect(r,&rc); } /* TR    */
    if (seg & 0x08) { rc=(SDL_Rect){x,         y + half_h - t/2, w, t};      SDL_RenderFillRect(r,&rc); } /* mid   */
    if (seg & 0x10) { rc=(SDL_Rect){x,         y + half_h,       t, half_h}; SDL_RenderFillRect(r,&rc); } /* BL    */
    if (seg & 0x20) { rc=(SDL_Rect){x + w - t, y + half_h,       t, half_h}; SDL_RenderFillRect(r,&rc); } /* BR    */
    if (seg & 0x40) { rc=(SDL_Rect){x,         y + h - t,        w, t};      SDL_RenderFillRect(r,&rc); } /* btm   */
}

/* Draw "Ns" centered, where N is the elapsed seconds. The trailing
 * 's' label is drawn as a half-height 7-seg-style block (we don't
 * have a real font, so it's just a small filled bar to mark units). */
static void draw_seconds(SDL_Renderer *r, int win_w, int win_h, int secs) {
    char buf[16];
    snprintf(buf, sizeof(buf), "%d", secs);
    int n = (int)strlen(buf);
    int digit_h = win_h / 3;        if (digit_h < 40) digit_h = 40;
    int digit_w = digit_h * 3 / 5;
    int gap     = digit_h / 10;     if (gap < 4) gap = 4;
    int total_w = n * digit_w + (n - 1) * gap;
    int x0 = (win_w - total_w) / 2;
    int y0 = (win_h - digit_h) / 2;
    for (int i = 0; i < n; i++) {
        draw_7seg_digit(r, x0 + i * (digit_w + gap), y0, digit_w, digit_h, buf[i] - '0');
    }
}

/* 4-quadrant rotating spinner: one quadrant lit per frame, rotates clockwise. */
static void draw_spinner(SDL_Renderer *r, int cx, int cy, int size, int frame) {
    int half = size / 2;
    int gap  = size / 16; if (gap < 2) gap = 2;
    SDL_Rect quads[4] = {
        { cx - half,         cy - half,         half - gap, half - gap }, /* TL */
        { cx + gap,          cy - half,         half - gap, half - gap }, /* TR */
        { cx + gap,          cy + gap,          half - gap, half - gap }, /* BR */
        { cx - half,         cy + gap,          half - gap, half - gap }, /* BL */
    };
    int active = ((unsigned)frame) % 4;
    SDL_RenderFillRect(r, &quads[active]);
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
    NvShmemHdr *hdr = (NvShmemHdr*)g_shmem;
    nv_shmem_write((uint8_t*)g_shmem + hdr->input_off,
                   NV_SHMEM_INPUT_BYTES, &hdr->input, buf, 6);
}
static inline void shmem_send_key(int down, uint32_t keysym) {
    uint8_t buf[8] = {
        4, (uint8_t)(down ? 1 : 0), 0, 0,
        (uint8_t)(keysym >> 24), (uint8_t)(keysym >> 16),
        (uint8_t)(keysym >> 8),  (uint8_t)keysym,
    };
    NvShmemHdr *hdr = (NvShmemHdr*)g_shmem;
    nv_shmem_write((uint8_t*)g_shmem + hdr->input_off,
                   NV_SHMEM_INPUT_BYTES, &hdr->input, buf, 8);
}

/* ──────────────────────── SDL → RFB keysym table ────────────────
 * SDL keysyms are not the same as X11 keysyms, but the RFB protocol
 * speaks X11 keysyms (Xlib KeySym values). For the printable ASCII
 * range and common control keys we have direct equivalents; map the
 * rest case-by-case. */
static uint32_t sdl_to_rfb_keysym(SDL_Keysym k) {
    SDL_Keycode kc = k.sym;
    /* Windows/Super shortcuts are virtual-key style shortcuts.  Use the
     * physical QWERTY letter for Super+A..Z so host IME/layout translation
     * cannot turn Win+L into a different letter before it reaches Windows. */
    if ((k.mod & KMOD_GUI) &&
        k.scancode >= SDL_SCANCODE_A && k.scancode <= SDL_SCANCODE_Z) {
        return (uint32_t)('a' + (k.scancode - SDL_SCANCODE_A));
    }
    /* Printable ASCII fits directly */
    if (kc >= 0x20 && kc <= 0x7E) {
        if (k.mod & KMOD_SHIFT) {
            /* SDL gives the unshifted keycode; produce the shifted
             * symbol so the guest sees uppercase / symbols correctly. */
            switch (kc) {
            case 'a': case 'b': case 'c': case 'd': case 'e':
            case 'f': case 'g': case 'h': case 'i': case 'j':
            case 'k': case 'l': case 'm': case 'n': case 'o':
            case 'p': case 'q': case 'r': case 's': case 't':
            case 'u': case 'v': case 'w': case 'x': case 'y':
            case 'z': return (uint32_t)(kc - 0x20);
            case '1': return '!'; case '2': return '@';
            case '3': return '#'; case '4': return '$';
            case '5': return '%'; case '6': return '^';
            case '7': return '&'; case '8': return '*';
            case '9': return '('; case '0': return ')';
            case '-': return '_'; case '=': return '+';
            case '[': return '{'; case ']': return '}';
            case '\\': return '|'; case ';': return ':';
            case '\'': return '"'; case ',': return '<';
            case '.': return '>'; case '/': return '?';
            case '`': return '~';
            }
        }
        return (uint32_t)kc;
    }
    /* SDL_Keycode → X11 keysym map for non-printable keys */
    switch (kc) {
    case SDLK_BACKSPACE:    return 0xFF08;
    case SDLK_TAB:          return 0xFF09;
    case SDLK_RETURN:       return 0xFF0D;
    case SDLK_ESCAPE:       return 0xFF1B;
    case SDLK_HOME:         return 0xFF50;
    case SDLK_LEFT:         return 0xFF51;
    case SDLK_UP:           return 0xFF52;
    case SDLK_RIGHT:        return 0xFF53;
    case SDLK_DOWN:         return 0xFF54;
    case SDLK_PAGEUP:       return 0xFF55;
    case SDLK_PAGEDOWN:     return 0xFF56;
    case SDLK_END:          return 0xFF57;
    case SDLK_INSERT:       return 0xFF63;
    case SDLK_DELETE:       return 0xFFFF;
    case SDLK_F1:  return 0xFFBE;  case SDLK_F2:  return 0xFFBF;
    case SDLK_F3:  return 0xFFC0;  case SDLK_F4:  return 0xFFC1;
    case SDLK_F5:  return 0xFFC2;  case SDLK_F6:  return 0xFFC3;
    case SDLK_F7:  return 0xFFC4;  case SDLK_F8:  return 0xFFC5;
    case SDLK_F9:  return 0xFFC6;  case SDLK_F10: return 0xFFC7;
    case SDLK_F11: return 0xFFC8;  case SDLK_F12: return 0xFFC9;
    case SDLK_LSHIFT: case SDLK_RSHIFT:   return 0xFFE1;
    case SDLK_LCTRL:  case SDLK_RCTRL:    return 0xFFE3;
    case SDLK_LALT:                       return 0xFFE9;
    case SDLK_RALT:                       return 0xFFEA;
    case SDLK_LGUI:                       return 0xFFEB;  /* XK_Super_L = Win key */
    case SDLK_RGUI:                       return 0xFFEC;  /* XK_Super_R */
    case SDLK_CAPSLOCK:   return 0xFFE5;
    case SDLK_NUMLOCKCLEAR: return 0xFF7F;
    case SDLK_KP_ENTER:   return 0xFF8D;
    case SDLK_KP_MULTIPLY:return 0xFFAA;
    case SDLK_KP_PLUS:    return 0xFFAB;
    case SDLK_KP_MINUS:   return 0xFFAD;
    case SDLK_KP_PERIOD:  return 0xFFAE;
    case SDLK_KP_DIVIDE:  return 0xFFAF;
    case SDLK_KP_0: return 0xFFB0;  case SDLK_KP_1: return 0xFFB1;
    case SDLK_KP_2: return 0xFFB2;  case SDLK_KP_3: return 0xFFB3;
    case SDLK_KP_4: return 0xFFB4;  case SDLK_KP_5: return 0xFFB5;
    case SDLK_KP_6: return 0xFFB6;  case SDLK_KP_7: return 0xFFB7;
    case SDLK_KP_8: return 0xFFB8;  case SDLK_KP_9: return 0xFFB9;
    }
    return 0;  /* unknown */
}

/* ──────────────────────── render loop ──────────────────────────── */
struct args {
    int   vm_id;
    const char *shmem_path;
    int   width, height;        /* override window size (else fb size) */
    int   fullscreen;
    int   tame_gnome;
};

static const char *DEFAULT_PATH_FMT = "/dev/shm/nv-shmem-vm%d";
static char path_buf[64];
static volatile sig_atomic_t want_quit = 0;
static void on_quit(int s) { (void)s; want_quit = 1; }

static const char *gnome_guard_script = NULL;
static char gnome_guard_state[256];
static int gnome_guard_active = 0;

static void gnome_guard_run(const char *action)
{
    if (!gnome_guard_script || !gnome_guard_state[0]) {
        return;
    }

    pid_t pid = fork();
    if (pid == 0) {
        execl("/bin/bash", "bash", gnome_guard_script, action,
              gnome_guard_state, (char *)NULL);
        _exit(127);
    }
    if (pid > 0) {
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
        }
    }
}

static void gnome_guard_restore(void)
{
    if (gnome_guard_active) {
        gnome_guard_run("restore");
        gnome_guard_active = 0;
    }
}

static void gnome_guard_set(int want)
{
    if (want && !gnome_guard_active) {
        gnome_guard_run("tame");
        gnome_guard_active = 1;
    } else if (!want && gnome_guard_active) {
        gnome_guard_restore();
    }
}

static void update_gnome_guard(const struct args *a, int mouse_inside)
{
    gnome_guard_set(a->tame_gnome && mouse_inside);
}

/* Cursor visibility helper — 鼠标在 viewer 内时使用 guest 通过 DDA
 * pointer-shape 发来的真实光标；guest 报告隐藏光标时 SDL 也隐藏
 * 本地光标，让游戏自己画在 framebuffer 里的 software cursor 显示。
 * 移出 / 最小化时显回宿主光标。**不**触碰任何 grab API：Wayland XWayland 下 SDL/X grab 抢
 * 不了 mutter 的系统快捷键，反而引入状态机抖动 (frequent ON/OFF)
 * 和 focus race (截图 / 切窗时键盘事件丢)。键盘路由完全靠 SDL 自然
 * focus dispatch — viewer 在 input focus 时 SDL 收 KEYDOWN，否则
 * 系统把键发给别的窗口。GNOME Super/Alt+Tab/锁屏类宿主快捷键只在
 * 鼠标位于 viewer 窗口内时动态关闭，鼠标离开、最小化、隐藏或退出
 * 时恢复宿主。这样宿主快捷键恢复跟随 pointer crossing，不依赖焦点。 */
static void update_cursor_vis(int *visible, int want)
{
    if (want == *visible) return;
    SDL_ShowCursor(want ? SDL_ENABLE : SDL_DISABLE);
    *visible = want;
}

static SDL_Rect framebuffer_rect(int win_w, int win_h, int fb_w, int fb_h)
{
    SDL_Rect r;
    r.w = fb_w;
    r.h = fb_h;
    r.x = (win_w - fb_w) / 2;
    r.y = (win_h - fb_h) / 2;
    return r;
}

static void window_to_guest(int wx, int wy, int win_w, int win_h,
                            int fb_w, int fb_h, int *gx, int *gy)
{
    SDL_Rect r = framebuffer_rect(win_w, win_h, fb_w, fb_h);
    int x = wx - r.x;
    int y = wy - r.y;
    if (x < 0) x = 0; else if (x >= fb_w) x = fb_w - 1;
    if (y < 0) y = 0; else if (y >= fb_h) y = fb_h - 1;
    *gx = x;
    *gy = y;
}

static void apply_cursor_state(SDL_Cursor *default_cursor,
                               SDL_Cursor *guest_cursor,
                               int guest_cursor_visible,
                               int mouse_inside,
                               int *cursor_visible)
{
    if (!mouse_inside) {
        SDL_SetCursor(default_cursor);
        update_cursor_vis(cursor_visible, 1);
        return;
    }

    SDL_SetCursor(guest_cursor ? guest_cursor : default_cursor);
    update_cursor_vis(cursor_visible, guest_cursor_visible ? 1 : 0);
}

static SDL_Cursor *create_guest_cursor(const NvCursorHdr *ch,
                                       const uint8_t *payload,
                                       uint32_t payload_bytes)
{
    if (!(ch->flags & NV_CURSOR_FLAG_SHAPE)) return NULL;
    if (ch->width == 0 || ch->height == 0 ||
        ch->width > 1024 || ch->height > 1024) {
        return NULL;
    }
    uint32_t need = (uint32_t)ch->width * ch->height * 4;
    if (payload_bytes < need) return NULL;

    SDL_Surface *surf = SDL_CreateRGBSurfaceWithFormatFrom(
        (void*)payload, ch->width, ch->height, 32, ch->width * 4,
        SDL_PIXELFORMAT_ARGB8888);
    if (!surf) return NULL;
    SDL_Cursor *cursor = SDL_CreateColorCursor(surf, ch->hot_x, ch->hot_y);
    SDL_FreeSurface(surf);
    return cursor;
}

static void parse_args(int argc, char **argv, struct args *a) {
    a->vm_id = 1; a->shmem_path = NULL; a->width = 0; a->height = 0;
    a->tame_gnome = 0;
    /* Default windowed. Fullscreen + Wayland-native 上一版被证明会
     * 模糊 + 卡死，回滚为默认窗口模式；用户可 --fullscreen 显式
     * 进入（不推荐 Wayland 下用）。 */
    a->fullscreen = 0;
    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--vm")     && i+1 < argc) a->vm_id = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--shmem")  && i+1 < argc) a->shmem_path = argv[++i];
        else if (!strcmp(argv[i], "--width")  && i+1 < argc) a->width = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--height") && i+1 < argc) a->height = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--fullscreen")) a->fullscreen = 1;
        else if (!strcmp(argv[i], "--windowed"))   a->fullscreen = 0;
        else if (!strcmp(argv[i], "--tame-gnome")) a->tame_gnome = 1;
        else if (!strcmp(argv[i], "--no-tame-gnome")) a->tame_gnome = 0;
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            fprintf(stderr,
              "usage: %s [--vm N | --shmem /path] [--width N --height N]\n"
              "          [--fullscreen | --windowed] [--tame-gnome]\n"
              "all focused keyboard input is forwarded to the guest\n",
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

    if (a.tame_gnome) {
        gnome_guard_script = getenv("GNOME_SUPER_GUARD");
        if (gnome_guard_script && gnome_guard_script[0]) {
            snprintf(gnome_guard_state, sizeof(gnome_guard_state),
                     "/tmp/qemu-stream-client-%u-%ld.gnome-super",
                     (unsigned)getuid(), (long)getpid());
            atexit(gnome_guard_restore);
        } else {
            fprintf(stderr, "[stream-dda] --tame-gnome ignored: GNOME_SUPER_GUARD not set\n");
            a.tame_gnome = 0;
        }
    }

    fprintf(stderr, "[stream-dda] attaching %s\n", a.shmem_path);
    if (shmem_attach(a.shmem_path) < 0) return 1;
    /* Don't block here — SDL window comes up immediately with a
     * "waiting for guest" placeholder, and we lazy-init the texture
     * once the guest's ring header has magic+size. This way the user
     * sees a window even during fresh-boot / setup-guest. */
    NvShmemHdr *hdr = (NvShmemHdr*)g_shmem;
    int srv_w = a.width  ? a.width  : 1280;
    int srv_h = a.height ? a.height : 720;
    int win_w = srv_w, win_h = srv_h;
    int guest_ready = 0;

    /* Hints must be set before SDL_Init. 我们**故意不设** GRAB_KEYBOARD —
     * Wayland XWayland 下 mutter 不让客户端抢系统快捷键，强行 grab
     * 反而带来 focus 抖动 (frequent ENTER/LEAVE) 和 race。键盘路由
     * 完全靠 SDL 默认 focus dispatch，简洁可靠。 */
    SDL_SetHint(SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "1");

    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError()); return 1;
    }
    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");  /* nearest, fast */

    Uint32 wflags = SDL_WINDOW_RESIZABLE;
    if (a.fullscreen) wflags |= SDL_WINDOW_FULLSCREEN_DESKTOP;
    char title[160];
    snprintf(title, sizeof(title), "vm%d - waiting for guest...", a.vm_id);
    SDL_Window *win = SDL_CreateWindow(title,
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        win_w, win_h, wflags);
    if (!win) { fprintf(stderr, "CreateWindow: %s\n", SDL_GetError()); return 1; }
    /* 去掉 PRESENTVSYNC — Wayland (XWayland) 下窗口 occluded/minimized 时
     * X server 不发 frame done event，SDL_RenderPresent 会 block forever
     * 在 poll fd=5（X socket）→ 整个 viewer 主 loop 卡死。我们的视频流
     * 自己有 60 fps cadence（guest relay frame_us），不需要 SDL vsync 二次
     * 节流。 */
    SDL_SetHint(SDL_HINT_RENDER_VSYNC, "0");
    SDL_Renderer *ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    if (!ren) {
        ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
    }
    if (!ren) { fprintf(stderr, "CreateRenderer: %s\n", SDL_GetError()); return 1; }
    /* Texture is lazy — we don't know the real guest dimensions yet.
     * Allocated/recreated when the ring header reports them, and again
     * any time the guest desktop is resized. */
    SDL_Texture *tex = NULL;

    /* 默认显宿主光标。鼠标进窗时切到隐藏 + 自绘
     * Windows-style 光标；移出时再显回来。 */
    SDL_ShowCursor(SDL_ENABLE);
    SDL_SetRelativeMouseMode(SDL_FALSE);

    /* SDL 自然 focus 路由 — 不调任何 grab API。鼠标光标按 ENTER/LEAVE
     * 简单切显隐；GNOME 宿主快捷键按鼠标是否在窗口内动态开关。 */
    SDL_PumpEvents();
    SDL_FlushEvents(SDL_FIRSTEVENT, SDL_LASTEVENT);
    int cursor_visible = 1;   /* SDL 默认 enable，跟 SDL_ShowCursor 同步 */
    SDL_Cursor *default_cursor = SDL_GetDefaultCursor();
    SDL_Cursor *guest_cursor = NULL;
    int guest_cursor_visible = 1;
    Uint32 wfl0  = SDL_GetWindowFlags(win);
    int mouse_inside = !!(wfl0 & SDL_WINDOW_MOUSE_FOCUS);
    /* 鼠标若启动时已在窗内（SDL 不发 ENTER），立即套用 guest cursor 状态。 */
    apply_cursor_state(default_cursor, guest_cursor, guest_cursor_visible,
                       mouse_inside, &cursor_visible);
    update_gnome_guard(&a, mouse_inside);

    signal(SIGINT,  on_quit);
    signal(SIGTERM, on_quit);

    uint8_t  *ring = NULL;          /* set when guest_ready */
    /* Worst-case keyframe at 1080p ≈ 8.4 MiB. Default Linux thread
     * stack is 8 MiB so this MUST be heap-allocated, not on stack. */
    const uint32_t recbuf_cap = 16 * 1024 * 1024;
    uint8_t  *recbuf = malloc(recbuf_cap);
    if (!recbuf) { fprintf(stderr, "malloc recbuf failed\n"); return 1; }
    uint32_t  rec_size = 0;
    uint8_t   button_mask = 0;
    int last_pos_x = 0, last_pos_y = 0;
    int dirty_pos = 0;

    int debug_keys = getenv("STREAM_DEBUG") != NULL;

    Uint32 start_ticks = SDL_GetTicks();

    /* Guest 心跳超时：guest 内 NvStreamSvc 每 100ms 给
     * hdr->guest_alive_tick +1。8 秒看不到变化 = relay 死了 / VM 关机
     * / QEMU 异常 → viewer 主动 want_quit=1 自我了断，避免出现
     * "guest 关机但 viewer 窗口还在" 这种悬挂。Splash 阶段 (guest
     * 还没起) 不算 — 那时 alive 本来就是 0；要 guest_ready 后才计时。 */
    uint32_t  alive_last_seen   = 0;
    Uint32    alive_last_change = SDL_GetTicks();
    int       alive_armed       = 0;
    const Uint32 ALIVE_TIMEOUT_MS = 4000;

    /* On every iteration: maybe transition to guest_ready, drain 1 ring
     * record, drain SDL events, present a frame. */
    while (!want_quit) {
        /* ── 0. lazy guest-ready transition ────────────────────────
         * While the guest's nv_stream_relay isn't running yet (cold
         * boot / setup-guest in progress) we just paint black and
         * pump SDL events so the window stays responsive. As soon as
         * the ring header carries magic+size we create the texture,
         * resize the window to the guest desktop, and bump the
         * host_alive_tick so the relay forces a keyframe immediately. */
        if (!guest_ready) {
            if (NV_SHMEM_LOAD_ACQ(&hdr->magic)        == NV_SHMEM_MAGIC &&
                NV_SHMEM_LOAD_ACQ(&hdr->guest_width)  != 0 &&
                NV_SHMEM_LOAD_ACQ(&hdr->guest_height) != 0) {
                srv_w = hdr->guest_width;
                srv_h = hdr->guest_height;
                ring  = (uint8_t*)g_shmem + hdr->video_off;
                /* 上次 viewer 留下的 reader_seq 跟当前 writer_seq 不同步
                 * (尤其旧 viewer 卡死后留下的旧值)。从 ring 中间读会拿到
                 * record 中间字节，size 字段是 garbage → nv_shmem_read 返
                 * -1 永远卡。把 reader_seq 拉到 writer_seq 丢老帧从最新开始。
                 * 同样把 input ring 也归零（旧的 input event 不要 replay）。 */
                NV_SHMEM_STORE_REL(&hdr->video.reader_seq,
                                   NV_SHMEM_LOAD_ACQ(&hdr->video.writer_seq));
                NV_SHMEM_STORE_REL(&hdr->input.reader_seq,
                                   NV_SHMEM_LOAD_ACQ(&hdr->input.writer_seq));
                alive_last_seen = NV_SHMEM_LOAD_ACQ(&hdr->guest_alive_tick);
                alive_last_change = SDL_GetTicks();
                alive_armed = alive_last_seen != 0;
                tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888,
                    SDL_TEXTUREACCESS_STREAMING, srv_w, srv_h);
                if (!tex) {
                    fprintf(stderr, "CreateTexture: %s\n", SDL_GetError());
                    return 1;
                }
                if (!a.fullscreen && (!a.width || !a.height)) {
                    SDL_SetWindowSize(win, srv_w, srv_h);
                    SDL_SetWindowPosition(win,
                        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED);
                }
                snprintf(title, sizeof(title),
                    "vm%d - %dx%d", a.vm_id, srv_w, srv_h);
                SDL_SetWindowTitle(win, title);
                NV_SHMEM_STORE_REL(&hdr->host_alive_tick, 1);
                guest_ready = 1;
                fprintf(stderr, "[stream-dda] guest desktop %dx%d\n", srv_w, srv_h);
            } else {
                /* Not ready yet — splash screen with a spinner + an
                 * elapsed-seconds counter so the user knows the
                 * viewer is alive while the guest boots / setup-guest
                 * runs. Pump SDL events + sleep 100 ms so we don't
                 * spin. */
                Uint32 now = SDL_GetTicks();
                int    elapsed_sec = (int)((now - start_ticks) / 1000);
                int    spin_frame  = (int)((now - start_ticks) / 200);

                int cur_w, cur_h;
                SDL_GetWindowSize(win, &cur_w, &cur_h);

                SDL_SetRenderDrawColor(ren, 18, 22, 32, 255);   /* dark slate bg */
                SDL_RenderClear(ren);

                /* Spinner above the number, ~1/8 of window height in size. */
                int spin_size = cur_h / 8;
                if (spin_size < 32) spin_size = 32;
                int spin_y    = cur_h / 2 - cur_h / 3;
                SDL_SetRenderDrawColor(ren, 90, 140, 220, 255); /* spinner: muted blue */
                draw_spinner(ren, cur_w / 2, spin_y, spin_size, spin_frame);

                /* Big 7-seg seconds counter, centered. */
                SDL_SetRenderDrawColor(ren, 200, 220, 255, 255); /* counter: light blue-white */
                draw_seconds(ren, cur_w, cur_h, elapsed_sec);

                SDL_RenderPresent(ren);

                /* Splash 期间：响应 close + 光标显隐；键盘按键不在本地拦截。 */
                SDL_Event ev;
                while (SDL_PollEvent(&ev)) {
                    if (ev.type == SDL_QUIT) want_quit = 1;
                    else if (ev.type == SDL_WINDOWEVENT) {
                        switch (ev.window.event) {
                        case SDL_WINDOWEVENT_ENTER:
                            mouse_inside = 1;
                            apply_cursor_state(default_cursor, guest_cursor,
                                               guest_cursor_visible, mouse_inside,
                                               &cursor_visible);
                            update_gnome_guard(&a, mouse_inside);
                            break;
                        case SDL_WINDOWEVENT_LEAVE:
                            mouse_inside = 0;
                            apply_cursor_state(default_cursor, guest_cursor,
                                               guest_cursor_visible, mouse_inside,
                                               &cursor_visible);
                            update_gnome_guard(&a, mouse_inside);
                            break;
                        case SDL_WINDOWEVENT_FOCUS_LOST:
                            if (!mouse_inside) {
                                apply_cursor_state(default_cursor, guest_cursor,
                                                   guest_cursor_visible, mouse_inside,
                                                   &cursor_visible);
                            }
                            break;
                        case SDL_WINDOWEVENT_MINIMIZED:
                        case SDL_WINDOWEVENT_HIDDEN:
                            mouse_inside = 0;
                            apply_cursor_state(default_cursor, guest_cursor,
                                               guest_cursor_visible, mouse_inside,
                                               &cursor_visible);
                            update_gnome_guard(&a, mouse_inside);
                            break;
                        case SDL_WINDOWEVENT_CLOSE: want_quit = 1; break;
                        }
                    }
                    else if (ev.type == SDL_MOUSEMOTION ||
                             ev.type == SDL_MOUSEBUTTONDOWN ||
                             ev.type == SDL_MOUSEBUTTONUP) {
                        if (!mouse_inside) {
                            mouse_inside = 1;
                            update_gnome_guard(&a, mouse_inside);
                        }
                        apply_cursor_state(default_cursor, guest_cursor,
                                           guest_cursor_visible, mouse_inside,
                                           &cursor_visible);
                    }
                }
                struct timespec ts = {0, 100 * 1000 * 1000};
                nanosleep(&ts, NULL);
                continue;
            }
        }

        /* ── 0.5. pump SDL events FIRST so big video drain below
         * doesn't starve mouse/keyboard. SDL_PollEvent 不会 implicit
         * pump — 必须显式 SDL_PumpEvents 让 X events 流入 SDL queue。 */
        SDL_PumpEvents();

        /* ── 1. drain video ring ───────────────────────────── */
        Uint32 drain_start = SDL_GetTicks();
        for (int drained = 0; drained < 64; drained++) {
            uint32_t vw = NV_SHMEM_LOAD_ACQ(&hdr->video.writer_seq);
            uint32_t vr = NV_SHMEM_LOAD_ACQ(&hdr->video.reader_seq);
            uint32_t used = vw - vr;
            if (used > NV_SHMEM_VIDEO_BYTES * 3 / 4) {
                fprintf(stderr,
                    "[stream-dda] video backlog %u bytes, dropping to latest and requesting keyframe\n",
                    used);
                NV_SHMEM_STORE_REL(&hdr->video.reader_seq, vw);
                NV_SHMEM_STORE_REL(&hdr->host_alive_tick, 0);
                break;
            }

            int rc = nv_shmem_read(ring, NV_SHMEM_VIDEO_BYTES, &hdr->video,
                                   recbuf, recbuf_cap, &rec_size);
            if (rc < 0) {
                fprintf(stderr,
                    "[stream-dda] ring read returned -1 (size=%u > cap=%u), resetting to writer and requesting keyframe\n",
                    rec_size, recbuf_cap);
                NV_SHMEM_STORE_REL(&hdr->video.reader_seq,
                                   NV_SHMEM_LOAD_ACQ(&hdr->video.writer_seq));
                NV_SHMEM_STORE_REL(&hdr->host_alive_tick, 0);
                break;
            }
            if (rc == 0) {
                break;
            }
            if (rec_size >= sizeof(uint32_t)) {
                uint32_t magic = *(uint32_t*)recbuf;
                if (magic == NV_FRAME_MAGIC && rec_size >= sizeof(NvFrameHdr)) {
                    NvFrameHdr *fh = (NvFrameHdr*)recbuf;
                    if (!fh->fb_width || !fh->fb_height) {
                        continue;
                    }
                    if (fh->fb_width != srv_w || fh->fb_height != srv_h) {
                        srv_w = fh->fb_width; srv_h = fh->fb_height;
                        SDL_DestroyTexture(tex);
                        tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888,
                            SDL_TEXTUREACCESS_STREAMING, srv_w, srv_h);
                        fprintf(stderr, "[stream-dda] guest fb resized → %dx%d\n", srv_w, srv_h);
                    }
                    uint8_t *cur = recbuf + sizeof(NvFrameHdr);
                    uint8_t *end = recbuf + rec_size;
                    for (uint16_t i = 0; i < fh->tile_count && cur + sizeof(NvFrameTile) <= end; i++) {
                        NvFrameTile *t = (NvFrameTile*)cur;
                        cur += sizeof(*t);
                        uint32_t bytes = (uint32_t)t->w * t->h * 4;
                        if (cur + bytes > end) break;
                        SDL_Rect r = { t->x, t->y, t->w, t->h };
                        SDL_UpdateTexture(tex, &r, cur, t->w * 4);
                        cur += bytes;
                    }
                } else if (magic == NV_CURSOR_MAGIC && rec_size >= sizeof(NvCursorHdr)) {
                    NvCursorHdr *ch = (NvCursorHdr*)recbuf;
                    guest_cursor_visible = (ch->flags & NV_CURSOR_FLAG_VISIBLE) ? 1 : 0;
                    if (ch->flags & NV_CURSOR_FLAG_SHAPE) {
                        SDL_Cursor *next = create_guest_cursor(
                            ch, recbuf + sizeof(*ch), rec_size - (uint32_t)sizeof(*ch));
                        if (next) {
                            if (guest_cursor) SDL_FreeCursor(guest_cursor);
                            guest_cursor = next;
                        }
                    }
                    apply_cursor_state(default_cursor, guest_cursor,
                                       guest_cursor_visible, mouse_inside,
                                       &cursor_visible);
                }
            }
            if (SDL_GetTicks() - drain_start > 8) {
                break;
            }
        }

        /* ── 2. drain SDL events → input ring ───────────────── */
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            switch (ev.type) {
            case SDL_QUIT: want_quit = 1; break;

            case SDL_WINDOWEVENT:
                switch (ev.window.event) {
                case SDL_WINDOWEVENT_ENTER:
                    mouse_inside = 1;
                    apply_cursor_state(default_cursor, guest_cursor,
                                       guest_cursor_visible, mouse_inside,
                                       &cursor_visible);
                    update_gnome_guard(&a, mouse_inside);
                    break;
                case SDL_WINDOWEVENT_LEAVE:
                    mouse_inside = 0;
                    apply_cursor_state(default_cursor, guest_cursor,
                                       guest_cursor_visible, mouse_inside,
                                       &cursor_visible);
                    update_gnome_guard(&a, mouse_inside);
                    break;
                case SDL_WINDOWEVENT_FOCUS_LOST:
                    if (!mouse_inside) {
                        apply_cursor_state(default_cursor, guest_cursor,
                                           guest_cursor_visible, mouse_inside,
                                           &cursor_visible);
                    }
                    break;
                case SDL_WINDOWEVENT_MINIMIZED:
                case SDL_WINDOWEVENT_HIDDEN:
                    mouse_inside = 0;
                    apply_cursor_state(default_cursor, guest_cursor,
                                       guest_cursor_visible, mouse_inside,
                                       &cursor_visible);
                    update_gnome_guard(&a, mouse_inside);
                    break;
                case SDL_WINDOWEVENT_CLOSE: want_quit = 1; break;
                default: break;
                }
                break;

            case SDL_KEYDOWN:
            case SDL_KEYUP: {
                uint32_t ks = sdl_to_rfb_keysym(ev.key.keysym);
                if (debug_keys) {
                    fprintf(stderr, "[stream-dda] %s sdl=0x%x mod=0x%x → ks=0x%x %s\n",
                        ev.type == SDL_KEYDOWN ? "DN" : "UP",
                        (unsigned)ev.key.keysym.sym,
                        (unsigned)ev.key.keysym.mod,
                        (unsigned)ks,
                        ks ? "" : "(unmapped, dropped)");
                }
                if (ks) shmem_send_key(ev.type == SDL_KEYDOWN, ks);
                break;
            }

            case SDL_MOUSEMOTION: {
                if (!mouse_inside) {
                    mouse_inside = 1;
                    update_gnome_guard(&a, mouse_inside);
                }
                apply_cursor_state(default_cursor, guest_cursor,
                                   guest_cursor_visible, mouse_inside,
                                   &cursor_visible);
                int rw, rh; SDL_GetWindowSize(win, &rw, &rh);
                window_to_guest(ev.motion.x, ev.motion.y, rw, rh,
                                srv_w, srv_h, &last_pos_x, &last_pos_y);
                dirty_pos = 1;
                break;
            }
            case SDL_MOUSEBUTTONDOWN:
            case SDL_MOUSEBUTTONUP: {
                if (!mouse_inside) {
                    mouse_inside = 1;
                    update_gnome_guard(&a, mouse_inside);
                }
                apply_cursor_state(default_cursor, guest_cursor,
                                   guest_cursor_visible, mouse_inside,
                                   &cursor_visible);
                int rw, rh; SDL_GetWindowSize(win, &rw, &rh);
                int x, y;
                window_to_guest(ev.button.x, ev.button.y, rw, rh,
                                srv_w, srv_h, &x, &y);
                uint8_t bit = 0;
                switch (ev.button.button) {
                case SDL_BUTTON_LEFT:   bit = 1; break;
                case SDL_BUTTON_MIDDLE: bit = 2; break;
                case SDL_BUTTON_RIGHT:  bit = 4; break;
                }
                if (ev.type == SDL_MOUSEBUTTONDOWN) button_mask |= bit;
                else                                button_mask &= ~bit;
                shmem_send_pointer(button_mask, x, y);
                last_pos_x = x; last_pos_y = y; dirty_pos = 0;
                break;
            }
            case SDL_MOUSEWHEEL: {
                /* RFB encodes wheel as a one-shot button: bit 8 = up,
                 * bit 16 = down. Send press + release together. */
                int rw, rh; SDL_GetWindowSize(win, &rw, &rh);
                int x = (int)((int64_t)last_pos_x);
                int y = (int)((int64_t)last_pos_y);
                (void)rw; (void)rh;
                uint8_t bit = (ev.wheel.y > 0) ? 8 : 16;
                shmem_send_pointer(button_mask | bit, x, y);
                shmem_send_pointer(button_mask, x, y);
                break;
            }
            }
        }
        if (dirty_pos) {
            shmem_send_pointer(button_mask, last_pos_x, last_pos_y);
            dirty_pos = 0;
        }

        /* ── 3. render ─────────────────────────────────────── */
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        SDL_RenderClear(ren);
        if (srv_w > 0 && srv_h > 0) {
            int rw, rh; SDL_GetWindowSize(win, &rw, &rh);
            SDL_Rect dst = framebuffer_rect(rw, rh, srv_w, srv_h);
            SDL_RenderCopy(ren, tex, NULL, &dst);
        }
        SDL_RenderPresent(ren);

        /* ── 4. heartbeat ──────────────────────────────────── */
        /* InterlockedIncrement equivalent — store-release with +1.
         * Relay polls this once per loop and forces a keyframe on a
         * rising edge from 0 (i.e., new host attach). */
        NV_SHMEM_STORE_REL(&hdr->host_alive_tick,
                           hdr->host_alive_tick + 1);

        /* ── 5. guest 心跳：fast path (relay 主动写 0) + 兜底超时 ──
         * relay 在 SetConsoleCtrlHandler 收到 CTRL_SHUTDOWN_EVENT /
         * CTRL_LOGOFF_EVENT 时会同步把 guest_alive_tick 写 0；这条
         * 路径正常工作时 viewer 在 ~100ms 内退出，不用等 4 秒。 */
        if (guest_ready) {
            uint32_t alive_now = NV_SHMEM_LOAD_ACQ(&hdr->guest_alive_tick);
            if (!alive_armed && alive_now != 0) {
                alive_armed = 1;
                alive_last_seen = alive_now;
                alive_last_change = SDL_GetTicks();
            } else if (alive_armed && alive_now == 0 && alive_last_seen != 0) {
                fprintf(stderr,
                    "[stream-dda] guest_alive_tick=0 — guest 主动通告关机，立即退出\n");
                want_quit = 1;
            } else if (alive_armed && alive_now != alive_last_seen) {
                alive_last_seen   = alive_now;
                alive_last_change = SDL_GetTicks();
            } else if (alive_armed && SDL_GetTicks() - alive_last_change > ALIVE_TIMEOUT_MS) {
                fprintf(stderr,
                    "[stream-dda] guest heartbeat stalled %u ms — exiting "
                    "(VM 异常 / relay 崩了 / TerminateProcess 抢在 ctrl handler 之前)\n",
                    SDL_GetTicks() - alive_last_change);
                want_quit = 1;
            }
        }
    }

    fprintf(stderr, "[stream-dda] shutting down\n");
    gnome_guard_restore();
    /* Tell the relay we're gone — it will reset its rising-edge
     * detector and force a keyframe for the next viewer. */
    NV_SHMEM_STORE_REL(&hdr->host_alive_tick, 0);
    free(recbuf);
    if (guest_cursor) SDL_FreeCursor(guest_cursor);
    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}

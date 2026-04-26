/*
 * stream_client_dda.c — host-side viewer for the dirty-tile / raw-BGRA
 * ivshmem transport written by nv_stream_relay.exe in the guest.
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
#include <SDL2/SDL_syswm.h>

/* Used for the explicit XGrabKeyboard fallback. SDL's own
 * SDL_HINT_GRAB_KEYBOARD doesn't always defeat WM-level grabs of
 * Super+X / Super+L on some desktops (gnome-shell, KWin, i3 with
 * mod=$mod4). We do a direct Xlib grab too. */
#include <X11/Xlib.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <time.h>
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

static int shmem_wait_ready(int deadline_ms) {
    NvShmemHdr *hdr = (NvShmemHdr*)g_shmem;
    int waited = 0;
    while (waited < deadline_ms) {
        if (NV_SHMEM_LOAD_ACQ(&hdr->magic)        == NV_SHMEM_MAGIC &&
            NV_SHMEM_LOAD_ACQ(&hdr->guest_width)  != 0 &&
            NV_SHMEM_LOAD_ACQ(&hdr->guest_height) != 0) return 0;
        struct timespec ts = {0, 50 * 1000 * 1000};
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
};

static const char *DEFAULT_PATH_FMT = "/dev/shm/nv-shmem-vm%d";
static char path_buf[64];
static volatile sig_atomic_t want_quit = 0;
static void on_quit(int s) { (void)s; want_quit = 1; }

static void parse_args(int argc, char **argv, struct args *a) {
    a->vm_id = 1; a->shmem_path = NULL; a->width = 0; a->height = 0;
    a->fullscreen = 0;
    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--vm")     && i+1 < argc) a->vm_id = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--shmem")  && i+1 < argc) a->shmem_path = argv[++i];
        else if (!strcmp(argv[i], "--width")  && i+1 < argc) a->width = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--height") && i+1 < argc) a->height = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--fullscreen")) a->fullscreen = 1;
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            fprintf(stderr,
              "usage: %s [--vm N | --shmem /path] [--width N --height N] [--fullscreen]\n",
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

    fprintf(stderr, "[stream-dda] attaching %s\n", a.shmem_path);
    if (shmem_attach(a.shmem_path) < 0) return 1;
    fprintf(stderr, "[stream-dda] waiting for guest relay (magic+size)\n");
    if (shmem_wait_ready(15000) < 0) {
        fprintf(stderr, "[stream-dda] timeout — is nv_stream_relay running in guest?\n");
        return 1;
    }
    NvShmemHdr *hdr = (NvShmemHdr*)g_shmem;
    int srv_w = hdr->guest_width, srv_h = hdr->guest_height;
    fprintf(stderr, "[stream-dda] guest desktop %dx%d\n", srv_w, srv_h);

    int win_w = a.width  ? a.width  : srv_w;
    int win_h = a.height ? a.height : srv_h;

    /* Hints must be set before SDL_Init.
     *   GRAB_KEYBOARD = "1": XGrabKeyboard on focus, so the WM doesn't
     *     swallow Win+X / Alt+Tab / Super+L etc. and they reach us.
     *   X11_NET_WM_BYPASS_COMPOSITOR: avoid 1-frame compositor lag. */
    SDL_SetHint(SDL_HINT_GRAB_KEYBOARD, "1");
    SDL_SetHint(SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "1");

    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError()); return 1;
    }
    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");  /* nearest, fast */

    Uint32 wflags = SDL_WINDOW_RESIZABLE;
    if (a.fullscreen) wflags |= SDL_WINDOW_FULLSCREEN_DESKTOP;
    char title[160];
    snprintf(title, sizeof(title), "Audio Stream (DDA) - vm%d", a.vm_id);
    SDL_Window *win = SDL_CreateWindow(title,
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        win_w, win_h, wflags);
    if (!win) { fprintf(stderr, "CreateWindow: %s\n", SDL_GetError()); return 1; }
    SDL_Renderer *ren = SDL_CreateRenderer(win, -1,
        SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!ren) {
        ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
    }
    if (!ren) { fprintf(stderr, "CreateRenderer: %s\n", SDL_GetError()); return 1; }
    SDL_Texture *tex = SDL_CreateTexture(ren,
        SDL_PIXELFORMAT_ARGB8888,             /* BGRA on little-endian */
        SDL_TEXTUREACCESS_STREAMING,
        srv_w, srv_h);
    if (!tex) { fprintf(stderr, "CreateTexture: %s\n", SDL_GetError()); return 1; }

    SDL_ShowCursor(SDL_ENABLE);
    SDL_SetRelativeMouseMode(SDL_FALSE);

    /* SDL's grab hint + per-window keyboard grab is the polite version. */
#if SDL_VERSION_ATLEAST(2, 0, 16)
    SDL_SetWindowKeyboardGrab(win, SDL_TRUE);
#else
    SDL_SetWindowGrab(win, SDL_TRUE);
#endif

    /* Belt + suspenders: also do a direct Xlib XGrabKeyboard. SDL's
     * grab path on X11 doesn't always defeat WM-level grabs (gnome-
     * shell, KWin, i3-style $mod4 bindings) for keys like Super+X /
     * Super+L. owner_events=False forces ALL keypresses, including
     * those the WM would otherwise capture, into our window. */
    Display *xdpy = NULL;
    Window xwin_handle = 0;
    {
        SDL_SysWMinfo wm;
        SDL_VERSION(&wm.version);
        if (SDL_GetWindowWMInfo(win, &wm) && wm.subsystem == SDL_SYSWM_X11) {
            xdpy = wm.info.x11.display;
            xwin_handle = wm.info.x11.window;
            int rc = XGrabKeyboard(xdpy, xwin_handle,
                                   False, GrabModeAsync, GrabModeAsync,
                                   CurrentTime);
            fprintf(stderr, "[stream-dda] XGrabKeyboard rc=%d (0=GrabSuccess)\n", rc);
        }
    }

    signal(SIGINT,  on_quit);
    signal(SIGTERM, on_quit);

    uint8_t  *ring = (uint8_t*)g_shmem + hdr->video_off;
    /* Worst-case keyframe at 1080p ≈ 8.4 MiB. Default Linux thread
     * stack is 8 MiB so this MUST be heap-allocated, not on stack. */
    const uint32_t recbuf_cap = 16 * 1024 * 1024;
    uint8_t  *recbuf = malloc(recbuf_cap);
    if (!recbuf) { fprintf(stderr, "malloc recbuf failed\n"); return 1; }
    uint32_t  rec_size = 0;
    uint8_t   button_mask = 0;
    int last_pos_x = 0, last_pos_y = 0;
    int dirty_pos = 0;

    /* Bump host_alive_tick on attach so the relay sees a rising edge
     * and forces a keyframe — viewer doesn't have to wait for the
     * next 5 second periodic refresh to see a non-black screen. */
    NV_SHMEM_STORE_REL(&hdr->host_alive_tick, 1);
    int debug_keys = getenv("STREAM_DEBUG") != NULL;

    /* On every iteration: drain 1 ring record, drain SDL events,
     * present a frame. RENDERER_PRESENTVSYNC paces the loop to the
     * monitor refresh rate. */
    while (!want_quit) {
        /* ── 1. drain video ring ───────────────────────────── */
        int rc = nv_shmem_read(ring, NV_SHMEM_VIDEO_BYTES, &hdr->video,
                               recbuf, recbuf_cap, &rec_size);
        if (rc > 0 && rec_size >= sizeof(NvFrameHdr)) {
            NvFrameHdr *fh = (NvFrameHdr*)recbuf;
            if (fh->magic == NV_FRAME_MAGIC && fh->fb_width && fh->fb_height) {
                /* If guest re-sized desktop, recreate the texture. */
                if (fh->fb_width != srv_w || fh->fb_height != srv_h) {
                    srv_w = fh->fb_width; srv_h = fh->fb_height;
                    SDL_DestroyTexture(tex);
                    tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888,
                        SDL_TEXTUREACCESS_STREAMING, srv_w, srv_h);
                    fprintf(stderr, "[stream-dda] guest fb resized → %dx%d\n", srv_w, srv_h);
                }
                /* Apply each tile to the texture */
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
            }
        }

        /* ── 2. drain SDL events → input ring ───────────────── */
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            switch (ev.type) {
            case SDL_QUIT: want_quit = 1; break;

            case SDL_KEYDOWN:
            case SDL_KEYUP: {
                /* Avoid auto-repeat — RFB convention is that Windows
                 * key auto-repeat is generated by the OS on the guest. */
                if (ev.key.repeat) break;
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
                int rw, rh; SDL_GetWindowSize(win, &rw, &rh);
                last_pos_x = (int)((int64_t)ev.motion.x * srv_w / rw);
                last_pos_y = (int)((int64_t)ev.motion.y * srv_h / rh);
                dirty_pos = 1;
                break;
            }
            case SDL_MOUSEBUTTONDOWN:
            case SDL_MOUSEBUTTONUP: {
                int rw, rh; SDL_GetWindowSize(win, &rw, &rh);
                int x = (int)((int64_t)ev.button.x * srv_w / rw);
                int y = (int)((int64_t)ev.button.y * srv_h / rh);
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
        SDL_RenderClear(ren);
        SDL_RenderCopy(ren, tex, NULL, NULL);
        SDL_RenderPresent(ren);

        /* ── 4. heartbeat ──────────────────────────────────── */
        /* InterlockedIncrement equivalent — store-release with +1.
         * Relay polls this once per loop and forces a keyframe on a
         * rising edge from 0 (i.e., new host attach). */
        NV_SHMEM_STORE_REL(&hdr->host_alive_tick,
                           hdr->host_alive_tick + 1);
    }

    fprintf(stderr, "[stream-dda] shutting down\n");
    /* Tell the relay we're gone — it will reset its rising-edge
     * detector and force a keyframe for the next viewer. */
    NV_SHMEM_STORE_REL(&hdr->host_alive_tick, 0);
    if (xdpy && xwin_handle) {
        XUngrabKeyboard(xdpy, CurrentTime);
    }
    free(recbuf);
    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}

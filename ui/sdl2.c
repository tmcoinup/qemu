/*
 * QEMU SDL display driver
 *
 * Copyright (c) 2003 Fabrice Bellard
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
/* Ported SDL 1.2 code to 2.0 by Dave Airlie. */

#include "qemu/osdep.h"
#include "qemu/module.h"
#include "qemu/cutils.h"
#include "ui/console.h"
#include "ui/input.h"
#include "ui/sdl2.h"
#include "system/runstate.h"
#include "system/runstate-action.h"
#include "system/system.h"
#include "ui/win32-kbd-hook.h"
#include "qemu/error-report.h"
#include "qemu/log.h"
#include "qemu/timer.h"
#include "qemu-main.h"

#ifdef CONFIG_X11
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#endif

static int sdl2_num_outputs;
static struct sdl2_console *sdl2_console;

static struct sdl2_console *grabbed_scon;
static bool alt_grab;
static bool ctrl_grab;

static int gui_saved_grab;
static int gui_fullscreen;
static int gui_grab_code = KMOD_LALT | KMOD_LCTRL;
static SDL_Cursor *sdl_cursor_normal;
static SDL_Cursor *sdl_cursor_hidden;
static SDL_Cursor *sdl_cursor_windows;
static bool sdl2_framebuffer_cursor;
static bool sdl2_screen_saver_inhibited;
static Notifier mouse_mode_notifier;
static QEMUTimer *sdl2_input_timer;
static uint32_t sdl_button_map[INPUT_BUTTON__MAX] = {
    [INPUT_BUTTON_LEFT]       = SDL_BUTTON(SDL_BUTTON_LEFT),
    [INPUT_BUTTON_MIDDLE]     = SDL_BUTTON(SDL_BUTTON_MIDDLE),
    [INPUT_BUTTON_RIGHT]      = SDL_BUTTON(SDL_BUTTON_RIGHT),
    [INPUT_BUTTON_SIDE]       = SDL_BUTTON(SDL_BUTTON_X1),
    [INPUT_BUTTON_EXTRA]      = SDL_BUTTON(SDL_BUTTON_X2),
};

static bool sdl_console_is_grabbed(const struct sdl2_console *scon)
{
    return scon && grabbed_scon == scon;
}

static bool sdl_cursor_is_active(const struct sdl2_console *scon)
{
    return scon && scon->real_window && !scon->hidden &&
           scon->has_input_focus &&
           (scon->has_mouse_focus || sdl_console_is_grabbed(scon));
}

/* Optional project-local GNOME/Wayland shortcut guard.  XWayland cannot
 * inhibit compositor shortcuts such as Super and Alt+Tab itself, so the
 * launcher supplies a helper that temporarily disables those bindings while
 * this SDL window owns both keyboard and mouse focus. */
static const char *sdl2_gnome_guard_script;
static char *sdl2_gnome_guard_state;
static bool sdl2_gnome_guard_active;

static bool sdl2_env_enabled(const char *name)
{
    const char *value = g_getenv(name);

    return value &&
           (g_ascii_strcasecmp(value, "1") == 0 ||
            g_ascii_strcasecmp(value, "yes") == 0 ||
            g_ascii_strcasecmp(value, "true") == 0 ||
            g_ascii_strcasecmp(value, "on") == 0);
}

static void sdl2_apply_host_display_sleep_policy(void)
{
    /*
     * SDL video initialization inhibits the host screen saver by default,
     * while upstream QEMU explicitly re-enables it.  A G-11 SDL console is a
     * locally watched display, so keep the monitor awake unless the operator
     * explicitly opts back into the upstream laptop-friendly behaviour.
     * This affects only host screen blanking/DPMS, never guest power policy.
     */
    if (sdl2_env_enabled("QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP")) {
        SDL_EnableScreenSaver();
        sdl2_screen_saver_inhibited = false;
    } else {
        SDL_DisableScreenSaver();
        sdl2_screen_saver_inhibited = true;
    }
}

static bool sdl2_gnome_guard_run(const char *action)
{
    gchar *argv[] = {
        (gchar *)sdl2_gnome_guard_script,
        (gchar *)action,
        sdl2_gnome_guard_state,
        NULL,
    };
    GError *err = NULL;
    gint status = 0;
    bool ok;

    if (!sdl2_gnome_guard_script || !sdl2_gnome_guard_state) {
        return false;
    }
    ok = g_spawn_sync(NULL, argv, NULL,
                      G_SPAWN_STDOUT_TO_DEV_NULL |
                      G_SPAWN_STDERR_TO_DEV_NULL,
                      NULL, NULL, NULL, NULL, &status, &err);
    if (ok) {
        ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    }
    if (!ok) {
        warn_report("sdl2: GNOME shortcut guard %s failed: %s",
                    action, err ? err->message : "unknown error");
    }
    g_clear_error(&err);
    return ok;
}

static void sdl2_gnome_guard_restore(void)
{
    if (sdl2_gnome_guard_active && sdl2_gnome_guard_run("restore")) {
        sdl2_gnome_guard_active = false;
    }
}

static void sdl2_gnome_guard_set(bool want)
{
    if (want && !sdl2_gnome_guard_active) {
        if (sdl2_gnome_guard_run("tame")) {
            sdl2_gnome_guard_active = true;
        }
    } else if (!want) {
        sdl2_gnome_guard_restore();
    }
}

static void sdl2_gnome_guard_update(struct sdl2_console *scon)
{
    sdl2_gnome_guard_set(scon && scon->has_input_focus &&
                         (scon->has_mouse_focus ||
                          sdl_console_is_grabbed(scon)) &&
                         !scon->hidden);
}

/* 60 Hz expressed exactly enough for the nanosecond absolute GUI timer. */
#define SDL2_REFRESH_INTERVAL_ACTIVE_NS 16666667ULL
/* Input polling is independent from guest rendering and remains responsive
 * while the window is minimized or its display listener is paused. */
#define SDL2_REFRESH_INTERVAL_MINIMIZED_MS 100
#define SDL2_INPUT_POLL_INTERVAL_ACTIVE_MS 8
#define SDL2_INPUT_POLL_INTERVAL_BACKGROUND_MS 32
#define SDL2_FPS_STABLE_MIN_FRAMES 30
#define SDL2_FPS_LOW_WARMUP_WINDOWS 2

/* introduced in SDL 2.0.10 */
#ifndef SDL_HINT_RENDER_BATCHING
#define SDL_HINT_RENDER_BATCHING "SDL_RENDER_BATCHING"
#endif
#ifdef CONFIG_OPENGL
static bool sdl2_native_egl_disabled;

static bool sdl2_should_use_native_egl(void)
{
    const char *enabled = g_getenv("QEMU_SDL_NATIVE_EGL");

    /*
     * 中文注释：SDL/GLX 是稳定默认路径；native EGL 仍处于 SDL 后端内的
     * 实验路径，只在显式环境开关下启用。这样可以继续修 SDL+EGL+dmbuf，
     * 同时避免普通本地窗口被不成熟路径影响。
     */
    return !sdl2_native_egl_disabled &&
           (g_strcmp0(enabled, "1") == 0 ||
           g_strcmp0(enabled, "true") == 0 ||
           g_strcmp0(enabled, "on") == 0);
}

static void sdl2_window_destroy_native_egl(struct sdl2_console *scon)
{
#ifdef CONFIG_X11
    if (qemu_egl_display != EGL_NO_DISPLAY &&
        scon->ectx != EGL_NO_CONTEXT &&
        eglGetCurrentContext() == scon->ectx) {
        if (!eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE,
                            EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
            warn_report("sdl2-egl: cannot release current context before "
                        "window teardown: %s", qemu_egl_get_error_string());
        } else {
            scon->native_egl_owner_tid = 0;
        }
    }
    if (scon->esurface) {
        eglDestroySurface(qemu_egl_display, scon->esurface);
        scon->esurface = EGL_NO_SURFACE;
    }
    if (scon->ectx) {
        eglDestroyContext(qemu_egl_display, scon->ectx);
        scon->ectx = EGL_NO_CONTEXT;
    }
    if (scon->native_egl_window || scon->native_egl_colormap) {
        SDL_SysWMinfo info;

        memset(&info, 0, sizeof(info));
        SDL_VERSION(&info.version);
        if (SDL_GetWindowWMInfo(scon->real_window, &info) &&
            info.info.x11.display) {
            Display *dpy = info.info.x11.display;

            if (scon->native_egl_window) {
                XDestroyWindow(dpy, (Window)scon->native_egl_window);
                scon->native_egl_window = 0;
            }
            if (scon->native_egl_colormap) {
                XFreeColormap(dpy, (Colormap)scon->native_egl_colormap);
                scon->native_egl_colormap = 0;
            }
            XFlush(dpy);
        }
    }
    scon->native_egl = false;
#endif
}

static bool sdl2_window_init_native_egl(struct sdl2_console *scon)
{
#ifdef CONFIG_X11
    SDL_SysWMinfo info;
    EGLint visual_id = 0;
    Display *dpy;
    Window parent;
    Window child;
    Colormap colormap;
    XVisualInfo tmpl;
    XVisualInfo *visuals;
    XSetWindowAttributes attrs;
    int nvisuals = 0;
    int ww;
    int wh;

    memset(&info, 0, sizeof(info));
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(scon->real_window, &info)) {
        error_report("sdl2-egl: SDL_GetWindowWMInfo failed: %s",
                     SDL_GetError());
        return false;
    }
    if (!info.info.x11.display || !info.info.x11.window) {
        error_report("sdl2-egl: SDL window is not an X11 window; "
                     "native EGL requires SDL_VIDEODRIVER=x11/DISPLAY");
        return false;
    }
    dpy = info.info.x11.display;
    parent = info.info.x11.window;
    if (qemu_egl_init_dpy_x11(dpy, scon->opts->gl) < 0) {
        return false;
    }
    if (!eglGetConfigAttrib(qemu_egl_display, qemu_egl_config,
                            EGL_NATIVE_VISUAL_ID, &visual_id) ||
        !visual_id) {
        error_report("sdl2-egl: EGL config has no X11 native visual");
        return false;
    }

    memset(&tmpl, 0, sizeof(tmpl));
    tmpl.visualid = visual_id;
    tmpl.screen = DefaultScreen(dpy);
    visuals = XGetVisualInfo(dpy, VisualIDMask | VisualScreenMask,
                             &tmpl, &nvisuals);
    if (!visuals || nvisuals < 1) {
        error_report("sdl2-egl: no X visual for EGL visual 0x%x", visual_id);
        return false;
    }

    SDL_GetWindowSize(scon->real_window, &ww, &wh);
    colormap = XCreateColormap(dpy, parent, visuals[0].visual, AllocNone);
    memset(&attrs, 0, sizeof(attrs));
    attrs.colormap = colormap;
    attrs.border_pixel = 0;
    attrs.event_mask = 0;
    /*
     * 中文注释：EGL window surface 必须绑定到与 EGLConfig visual 完全匹配
     * 的 X11 窗口。SDL 父窗口继续负责窗口管理和输入；这个子窗口只负责
     * 承载 EGL 绘制面，避免 parent visual 不匹配导致 swap 后仍全黑。
     */
    child = XCreateWindow(dpy, parent, 0, 0, ww, wh, 0,
                          visuals[0].depth, InputOutput, visuals[0].visual,
                          CWBorderPixel | CWColormap | CWEventMask, &attrs);
    XMapWindow(dpy, child);
    XInstallColormap(dpy, colormap);
    XRaiseWindow(dpy, child);
    XFlush(dpy);
    XSync(dpy, False);
    XFree(visuals);
    scon->native_egl_window = (uintptr_t)child;
    scon->native_egl_colormap = (uintptr_t)colormap;

    scon->ectx = qemu_egl_init_ctx();
    if (!scon->ectx) {
        return false;
    }
    scon->esurface = qemu_egl_init_surface_x11(
        scon->ectx, (EGLNativeWindowType)child);
    if (!scon->esurface) {
        sdl2_window_destroy_native_egl(scon);
        return false;
    }

    /*
     * qemu_egl_init_surface_x11() leaves the new window context current.
     * SDL setup can run before the GUI refresh timer starts (and GL display
     * callbacks are allowed to use another thread), so never carry that
     * ownership across the initialization boundary.  Every rendering entry
     * point acquires the context for its own bounded operation.
     */
    if (!eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE,
                        EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
        error_report("sdl2-egl: cannot release context after window init: %s",
                     qemu_egl_get_error_string());
        sdl2_window_destroy_native_egl(scon);
        return false;
    }
    scon->native_egl_owner_tid = 0;

    /*
     * Linux/X11 下 SDL 只负责窗口和输入；GL context/surface 由 QEMU EGL
     * helpers 创建。这样本地 SDL 窗口保留，同时 fb-shm 的 texture→dma-buf
     * 导出和 direct dma-buf import 都使用同一个可控 EGL provider。
     */
    scon->native_egl = true;
    if (!scon->logged_native_egl_visual) {
        info_report("sdl2: native EGL context active for SDL window "
                    "(parent=0x%lx child=0x%lx egl_visual=0x%x)",
                    (unsigned long)parent, (unsigned long)child, visual_id);
        scon->logged_native_egl_visual = true;
    }
    return true;
#else
    return false;
#endif
}

static void sdl2_window_sync_native_egl_child(struct sdl2_console *scon)
{
#ifdef CONFIG_X11
    SDL_SysWMinfo info;
    int ww;
    int wh;

    if (!scon->native_egl || !scon->native_egl_window ||
        !sdl2_window_is_renderable(scon)) {
        return;
    }

    memset(&info, 0, sizeof(info));
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(scon->real_window, &info) ||
        !info.info.x11.display) {
        return;
    }

    SDL_GetWindowSize(scon->real_window, &ww, &wh);
    /*
     * 中文注释：native EGL 实际绘制在 SDL 父窗口里的 X11 子窗口上。
     * 用户拖拽/缩放的是 SDL 父窗口，子窗口必须同步尺寸并重新 map 到父窗口
     * 内部，否则本地窗口会出现旧尺寸残影、黑边或“SDL 有窗口但无画面”。
     */
    XMoveResizeWindow(info.info.x11.display, (Window)scon->native_egl_window,
                      0, 0, ww, wh);
    XMapRaised(info.info.x11.display, (Window)scon->native_egl_window);
    XFlush(info.info.x11.display);
#endif
}
#endif

static void sdl_update_caption(struct sdl2_console *scon);
static void sdl_grab_end(struct sdl2_console *scon);

#ifdef CONFIG_SDL_IMAGE
static uint16_t sdl2_cursor_le16(const uint8_t *p)
{
    return p[0] | (p[1] << 8);
}

static uint32_t sdl2_cursor_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static SDL_Cursor *sdl2_load_windows_cursor(const char *path)
{
    gchar *contents = NULL;
    gsize size = 0;
    const uint8_t *entry = NULL;
    uint8_t *single = NULL;
    SDL_RWops *rw = NULL;
    SDL_Surface *surface = NULL;
    SDL_Cursor *cursor = NULL;
    uint16_t count, hot_x = 0, hot_y = 0;
    int best_score = INT_MAX;
    int i;

    if (!path || !g_file_get_contents(path, &contents, &size, NULL) ||
        size < 22 || size > INT_MAX) {
        goto out;
    }
    if (sdl2_cursor_le16((uint8_t *)contents) != 0 ||
        sdl2_cursor_le16((uint8_t *)contents + 2) != 2) {
        goto out;
    }
    count = sdl2_cursor_le16((uint8_t *)contents + 4);
    if (!count || count > (size - 6) / 16) {
        goto out;
    }

    for (i = 0; i < count; i++) {
        const uint8_t *candidate = (uint8_t *)contents + 6 + i * 16;
        uint32_t bytes = sdl2_cursor_le32(candidate + 8);
        uint32_t offset = sdl2_cursor_le32(candidate + 12);
        int width = candidate[0] ? candidate[0] : 256;
        int height = candidate[1] ? candidate[1] : 256;
        int score = ABS(width - 32) + ABS(height - 32);

        if (offset > size || bytes > size - offset) {
            continue;
        }
        if (score < best_score) {
            entry = candidate;
            best_score = score;
        }
    }
    if (!entry) {
        goto out;
    }

    hot_x = sdl2_cursor_le16(entry + 4);
    hot_y = sdl2_cursor_le16(entry + 6);
    single = g_malloc(size);
    memcpy(single, contents, size);
    single[4] = 1;
    single[5] = 0;
    memcpy(single + 6, entry, 16);
    rw = SDL_RWFromConstMem(single, size);
    if (!rw) {
        goto out;
    }
    surface = IMG_LoadCUR_RW(rw);
    if (surface && surface->w == 32 && surface->h == 32) {
        cursor = SDL_CreateColorCursor(surface, hot_x, hot_y);
    }

out:
    if (surface) {
        SDL_FreeSurface(surface);
    }
    if (rw) {
        SDL_RWclose(rw);
    }
    g_free(single);
    g_free(contents);
    return cursor;
}
#endif

/* REGION-based NVIDIA mdev display does not expose a separate hardware
 * cursor plane.  Use the 32x32 Windows default aero arrow while the absolute
 * pointer is inside the guest instead of leaking the Ubuntu cursor theme.
 * The simple bitmap below remains only as a no-SDL_image/decode fallback. */
static SDL_Cursor *sdl2_create_windows_cursor(void)
{
#ifdef CONFIG_SDL_IMAGE
    SDL_Cursor *aero_cursor = sdl2_load_windows_cursor(
        g_getenv("QEMU_SDL_WINDOWS_CURSOR"));

    if (aero_cursor) {
        info_report("sdl2: loaded 32x32 Windows cursor from %s",
                    g_getenv("QEMU_SDL_WINDOWS_CURSOR"));
        return aero_cursor;
    }
#endif

    static const char *shape[] = {
        "X",
        "XX",
        "XOX",
        "XOOX",
        "XOOOX",
        "XOOOOX",
        "XOOOOOX",
        "XOOOOOOX",
        "XOOOOOOOX",
        "XOOOOOOOOX",
        "XOOOOOOOOOX",
        "XOOOOOOOOOOX",
        "XOOOOOXXXXXXX",
        "XOOOXOX",
        "XOOX XOX",
        "XOX  XOX",
        "XX   XOX",
        "X     XOX",
        "      XOX",
        "      XOX",
        "      XOX",
        "      XXX",
    };
    SDL_Surface *surface;
    SDL_Cursor *cursor;
    Uint32 black, white, transparent;
    int x, y;

    surface = SDL_CreateRGBSurfaceWithFormat(0, 24, 32, 32,
                                              SDL_PIXELFORMAT_ARGB8888);
    if (!surface) {
        return NULL;
    }
    transparent = SDL_MapRGBA(surface->format, 0, 0, 0, 0);
    black = SDL_MapRGBA(surface->format, 0, 0, 0, 255);
    white = SDL_MapRGBA(surface->format, 255, 255, 255, 255);
    SDL_FillRect(surface, NULL, transparent);
    if (SDL_LockSurface(surface) == 0) {
        for (y = 0; y < ARRAY_SIZE(shape); y++) {
            Uint32 *row = (Uint32 *)((uint8_t *)surface->pixels +
                                     y * surface->pitch);
            for (x = 0; shape[y][x] != '\0'; x++) {
                if (shape[y][x] == 'X') {
                    row[x] = black;
                } else if (shape[y][x] == 'O') {
                    row[x] = white;
                }
            }
        }
        SDL_UnlockSurface(surface);
    }
    cursor = SDL_CreateColorCursor(surface, 0, 0);
    SDL_FreeSurface(surface);
    return cursor;
}

static struct sdl2_console *get_scon_from_window(uint32_t window_id)
{
    int i;
    for (i = 0; i < sdl2_num_outputs; i++) {
        if (sdl2_console[i].real_window == SDL_GetWindowFromID(window_id)) {
            return &sdl2_console[i];
        }
    }
    return NULL;
}

void sdl2_window_create(struct sdl2_console *scon)
{
    int flags = 0;
#ifdef CONFIG_OPENGL
    bool native_egl = false;
#endif

    if (!scon->surface) {
        return;
    }
    assert(!scon->real_window);

    if (gui_fullscreen) {
        flags |= SDL_WINDOW_FULLSCREEN_DESKTOP;
    } else {
        flags |= SDL_WINDOW_RESIZABLE;
    }
    if (scon->hidden) {
        flags |= SDL_WINDOW_HIDDEN;
    }
#ifdef CONFIG_OPENGL
    if (scon->opengl) {
        native_egl = sdl2_should_use_native_egl();
        if (!native_egl) {
            flags |= SDL_WINDOW_OPENGL;
            if (scon->opts->gl == DISPLAY_GL_MODE_ON ||
                scon->opts->gl == DISPLAY_GL_MODE_CORE) {
                SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,
                                    SDL_GL_CONTEXT_PROFILE_CORE);
            } else if (scon->opts->gl == DISPLAY_GL_MODE_ES) {
                SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,
                                    SDL_GL_CONTEXT_PROFILE_ES);
            }
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
        }
    }
#endif

    scon->real_window = SDL_CreateWindow("", SDL_WINDOWPOS_UNDEFINED,
                                         SDL_WINDOWPOS_UNDEFINED,
                                         surface_width(scon->surface),
                                         surface_height(scon->surface),
                                         flags);
    if (!scon->real_window) {
        fprintf(stderr, "Failed to create SDL window: %s\n", SDL_GetError());
        return;
    }
    /*
     * 窗口刚创建时, SDL 不一定补发 FOCUS_GAINED/ENTER (取决于 WM 和指针位置),
     * 直接拿 SDL 当前 flag 做初值, 避免冷启动后 sdl2_input_allowed 永远 false.
     */
    if (scon->real_window) {
        Uint32 wflags = SDL_GetWindowFlags(scon->real_window);
        scon->has_input_focus = !!(wflags & SDL_WINDOW_INPUT_FOCUS);
        scon->has_mouse_focus = !!(wflags & SDL_WINDOW_MOUSE_FOCUS);
    }
    if (scon->opengl) {
        const char *driver = "opengl";

        if (scon->opts->gl == DISPLAY_GL_MODE_ES) {
            driver = "opengles2";
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,
                                SDL_GL_CONTEXT_PROFILE_ES);
        }

        SDL_SetHint(SDL_HINT_RENDER_DRIVER, driver);
        SDL_SetHint(SDL_HINT_RENDER_BATCHING, "1");

        if (native_egl) {
            if (!sdl2_window_init_native_egl(scon)) {
                warn_report("sdl2-egl: native EGL init failed; "
                            "falling back to SDL GLX for this process");
                sdl2_window_destroy_native_egl(scon);
                SDL_DestroyWindow(scon->real_window);
                scon->real_window = NULL;
                /*
                 * 中文注释：native EGL 失败时必须退回 SDL/GLX 并重建窗口。
                 * 当前窗口创建时没有 SDL_WINDOW_OPENGL flag，继续刷新会让
                 * libepoxy 在没有 current GL/EGL context 时断言退出。
                 */
                sdl2_native_egl_disabled = true;
                sdl2_window_create(scon);
                return;
            }
        } else {
            scon->winctx = SDL_GL_CreateContext(scon->real_window);
            if (!scon->winctx && scon->opts->gl == DISPLAY_GL_MODE_ON) {
                SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,
                                    SDL_GL_CONTEXT_PROFILE_ES);
                scon->winctx = SDL_GL_CreateContext(scon->real_window);
            }
            if (!scon->winctx) {
                fprintf(stderr, "Failed to create SDL GL context: %s\n",
                        SDL_GetError());
                SDL_DestroyWindow(scon->real_window);
                scon->real_window = NULL;
                return;
            }
            if (SDL_GL_MakeCurrent(scon->real_window, scon->winctx) != 0) {
                fprintf(stderr, "Failed to make SDL GL context current: %s\n",
                        SDL_GetError());
                SDL_GL_DeleteContext(scon->winctx);
                scon->winctx = NULL;
                SDL_DestroyWindow(scon->real_window);
                scon->real_window = NULL;
                return;
            }
            SDL_GL_SetSwapInterval(0);
        }
        if (!native_egl && !scon->winctx) {
            SDL_DestroyWindow(scon->real_window);
            scon->real_window = NULL;
            return;
        }
#ifdef CONFIG_OPENGL
        if (!native_egl) {
            qemu_egl_display = eglGetCurrentDisplay();
        }
#endif
    } else {
        /* The SDL renderer is only used by sdl2-2D, when OpenGL is disabled */
        scon->real_renderer = SDL_CreateRenderer(scon->real_window, -1, 0);
    }

    sdl2_window_update_size_limits(scon);
    sdl_update_caption(scon);
}

void sdl2_window_destroy(struct sdl2_console *scon)
{
    if (!scon->real_window) {
        return;
    }

    if (scon->native_egl) {
        sdl2_window_destroy_native_egl(scon);
    }
    if (scon->winctx) {
        SDL_GL_DeleteContext(scon->winctx);
        scon->winctx = NULL;
    }
    if (scon->real_renderer) {
        SDL_DestroyRenderer(scon->real_renderer);
        scon->real_renderer = NULL;
    }
    SDL_DestroyWindow(scon->real_window);
    scon->real_window = NULL;
    scon->window_resize_pending = false;
    scon->window_maximum = (SDL2Size) { 0 };
}

void sdl2_window_update_size_limits(struct sdl2_console *scon)
{
    SDL2Size window;
    SDL2Size render;
    SDL2Size guest;
    SDL2Size maximum;
    bool embedded_render_child = false;

    if (!scon->real_window ||
        !sdl2_current_render_size(scon, &render) ||
        !sdl2_current_guest_size(scon, &guest)) {
        return;
    }

    SDL_GetWindowSize(scon->real_window, &window.width, &window.height);
#ifdef CONFIG_OPENGL
    embedded_render_child = scon->native_egl;
#endif
    /*
     * A native EGL child is synchronized after SDL drains resize events.
     * During that short interval eglQuerySurface() still reports its old
     * size.  Treating that mismatch as a DPI ratio would shrink the maximum
     * to an externally requested ROI and prevent the SHOWN handler from
     * restoring the full guest mode.
     */
    if (!sdl2_window_max_size(window, render, guest,
                              embedded_render_child, &maximum) ||
        (maximum.width == scon->window_maximum.width &&
         maximum.height == scon->window_maximum.height)) {
        return;
    }

    /*
     * SDL size hints use logical window units.  The policy helper accounts
     * for the current monitor's drawable/window DPI ratio, so maximizing or
     * dragging cannot enlarge the client area beyond the guest's native mode.
     */
    SDL_SetWindowMaximumSize(scon->real_window,
                             maximum.width, maximum.height);
    scon->window_maximum = maximum;
}

void sdl2_window_resize(struct sdl2_console *scon)
{
    SDL2Size guest;

    if (!scon->real_window) {
        return;
    }

    /*
     * Guest 在宿主窗口最小化/隐藏期间仍可以切换显示模式。
     * 此时不调 SDL 父窗口和 native-EGL 子窗口；窗口恢复后
     * 再按最新 surface 尺寸一次性应用，
     * 避免最小化动画变成真实 resize。
     */
    if (!sdl2_window_is_renderable(scon)) {
        scon->window_resize_pending = true;
        return;
    }
    if (!sdl2_current_guest_size(scon, &guest)) {
        return;
    }
    scon->window_resize_pending = false;

    sdl2_window_update_size_limits(scon);
    if (!gui_fullscreen) {
        SDL_SetWindowSize(scon->real_window, guest.width, guest.height);
    }
#ifdef CONFIG_OPENGL
#ifdef CONFIG_X11
    sdl2_window_sync_native_egl_child(scon);
#endif
#endif
}

static void sdl2_redraw(struct sdl2_console *scon)
{
    if (scon->opengl) {
#ifdef CONFIG_OPENGL
        sdl2_gl_redraw(scon);
#endif
    } else {
        sdl2_2d_redraw(scon);
    }
}

static void sdl_update_caption(struct sdl2_console *scon)
{
    char win_title[1024];
    char icon_title[1024];
    const char *status = "";
    const char *title_name = qemu_name;
    bool title_is_explicit = false;
    const char *cursor_status = sdl2_framebuffer_cursor ?
                                " | Cursor: framebuffer (host hidden)" : "";

    if (scon->opts->u.sdl.title && scon->opts->u.sdl.title[0]) {
        title_name = scon->opts->u.sdl.title;
        title_is_explicit = true;
    }

    if (!runstate_is_running()) {
        status = " [Stopped]";
    } else if (sdl_console_is_grabbed(scon)) {
        if (alt_grab) {
#ifdef CONFIG_DARWIN
            status = " - Press ⌃⌥⇧G to exit grab";
#else
            status = " - Press Ctrl-Alt-Shift-G to exit grab";
#endif
        } else if (ctrl_grab) {
            status = " - Press Right-Ctrl-G to exit grab";
        } else {
#ifdef CONFIG_DARWIN
            status = " - Press ⌃⌥G to exit grab";
#else
            status = " - Press Ctrl-Alt-G to exit grab";
#endif
        }
    }

    if (title_is_explicit && scon->idx == 0) {
        /*
         * The launcher supplies a stable per-instance title such as
         * "win10-8".  Treat it as the complete base title: appending the SDL
         * console index turned the first display into an invented "-0" VM.
         */
        if (scon->present_fps_valid) {
            snprintf(win_title, sizeof(win_title),
                     "%s | SDL Present %.1f FPS%s%s", title_name,
                     scon->present_fps, cursor_status, status);
        } else {
            snprintf(win_title, sizeof(win_title), "%s%s%s",
                     title_name, cursor_status, status);
        }
        snprintf(icon_title, sizeof(icon_title), "%s", title_name);
    } else if (title_is_explicit) {
        /*
         * QEMU can expose hidden firmware/text consoles in the same SDL
         * process.  Keep their names outside the primary instance contract,
         * otherwise an exact `win10-N` lookup would map every console.
         */
        if (scon->present_fps_valid) {
            snprintf(win_title, sizeof(win_title),
                     "%s-console-%d | SDL Present %.1f FPS%s%s", title_name,
                     scon->idx, scon->present_fps, cursor_status, status);
        } else {
            snprintf(win_title, sizeof(win_title), "%s-console-%d%s%s",
                     title_name, scon->idx, cursor_status, status);
        }
        snprintf(icon_title, sizeof(icon_title), "%s-console-%d",
                 title_name, scon->idx);
    } else if (title_name) {
        if (scon->present_fps_valid) {
            snprintf(win_title, sizeof(win_title),
                     "QEMU (%s-%d) | SDL Present %.1f FPS%s%s", title_name,
                     scon->idx, scon->present_fps, cursor_status, status);
        } else {
            snprintf(win_title, sizeof(win_title), "QEMU (%s-%d)%s%s",
                     title_name, scon->idx, cursor_status, status);
        }
        snprintf(icon_title, sizeof(icon_title), "QEMU (%s)", title_name);
    } else {
        if (scon->present_fps_valid) {
            snprintf(win_title, sizeof(win_title),
                     "QEMU | SDL Present %.1f FPS%s%s",
                     scon->present_fps, cursor_status, status);
        } else {
            snprintf(win_title, sizeof(win_title), "QEMU%s%s",
                     cursor_status, status);
        }
        snprintf(icon_title, sizeof(icon_title), "QEMU");
    }

    if (scon->real_window) {
        SDL_SetWindowTitle(scon->real_window, win_title);
    }
}

static void sdl2_present_rate_tick(struct sdl2_console *scon)
{
    int64_t now_us = g_get_monotonic_time();
    int64_t elapsed_us;

    if (!scon->fps_window_start_us) {
        scon->fps_window_start_us = now_us;
        return;
    }
    elapsed_us = now_us - scon->fps_window_start_us;
    if (elapsed_us >= G_USEC_PER_SEC) {
        if (!scon->present_fps_valid && scon->fps_low_warmup_windows &&
            scon->fps_frame_count < SDL2_FPS_STABLE_MIN_FRAMES) {
            /*
             * SHOWN can still drain one or two minimized-cadence timer
             * windows.  Do not advertise their 0.8/1.8 FPS as the active
             * rate.  The budget is bounded, so a genuinely slow renderer is
             * still reported after warm-up instead of being hidden forever.
             */
            scon->fps_low_warmup_windows--;
            scon->fps_frame_count = 0;
            scon->fps_window_start_us = now_us;
            return;
        }
        scon->fps_low_warmup_windows = 0;
        scon->present_fps = (double)scon->fps_frame_count * G_USEC_PER_SEC /
                            elapsed_us;
        scon->fps_frame_count = 0;
        scon->fps_window_start_us = now_us;
        scon->present_fps_valid = true;
        sdl_update_caption(scon);
    }
}

static void sdl2_present_rate_reset(struct sdl2_console *scon)
{
    scon->fps_window_start_us = 0;
    scon->fps_frame_count = 0;
    scon->present_fps = 0.0;
    scon->present_fps_valid = false;
    scon->fps_low_warmup_windows = SDL2_FPS_LOW_WARMUP_WINDOWS;
    sdl_update_caption(scon);
}

void sdl2_note_present(struct sdl2_console *scon)
{
    if (!scon->fps_window_start_us) {
        scon->fps_window_start_us = g_get_monotonic_time();
    }
    scon->fps_frame_count++;
    scon->presented_since_refresh = true;
    sdl2_present_rate_tick(scon);
}

/* Apply the cursor policy while the pointer is active inside the guest. */
static void sdl_apply_active_cursor(struct sdl2_console *scon)
{
    bool grabbed;
    bool current_absolute;
    bool absolute_available;
    bool absolute;

    if (!sdl_cursor_is_active(scon)) {
        return;
    }

    grabbed = sdl_console_is_grabbed(scon);
    current_absolute = qemu_input_is_absolute(scon->dcl.con);
    absolute_available = qemu_input_has_absolute(scon->dcl.con);
    absolute = current_absolute || (!grabbed && absolute_available);

    if (scon->opts->has_show_cursor && scon->opts->show_cursor) {
        SDL_SetRelativeMouseMode(!absolute && grabbed ?
                                 SDL_TRUE : SDL_FALSE);
        return;
    }

    /*
     * NVIDIA's VFIO REGION ABI exposes only the primary XRGB surface, not
     * the Windows hardware-cursor plane.  The normal absolute/tablet mode
     * therefore needs the host-side arrow below.  Some games instead draw
     * their own cursor into that primary framebuffer; in that mode hide all
     * SDL cursor sprites so the game's original shape is not covered.
     */
    if (sdl2_framebuffer_cursor) {
        SDL_SetRelativeMouseMode(!absolute && grabbed ?
                                 SDL_TRUE : SDL_FALSE);
        SDL_SetCursor(sdl_cursor_hidden);
        SDL_ShowCursor(SDL_DISABLE);
        return;
    }

    if (scon->guest_cursor && scon->guest_sprite) {
        SDL_SetRelativeMouseMode(SDL_FALSE);
        SDL_SetCursor(scon->guest_sprite);
        SDL_ShowCursor(SDL_ENABLE);
        return;
    }

    if (absolute) {
        SDL_SetRelativeMouseMode(SDL_FALSE);
        SDL_SetCursor(sdl_cursor_windows ? sdl_cursor_windows
                                         : sdl_cursor_normal);
        SDL_ShowCursor(SDL_ENABLE);
        return;
    }

    if (grabbed) {
        SDL_ShowCursor(SDL_DISABLE);
        SDL_SetCursor(sdl_cursor_hidden);
        SDL_SetRelativeMouseMode(SDL_TRUE);
    } else {
        SDL_SetRelativeMouseMode(SDL_FALSE);
        SDL_SetCursor(sdl_cursor_normal);
        SDL_ShowCursor(SDL_ENABLE);
    }
}

static void sdl_show_cursor(struct sdl2_console *scon)
{
    SDL_SetRelativeMouseMode(SDL_FALSE);
    if (scon->opts->has_show_cursor && scon->opts->show_cursor) {
        return;
    }

    SDL_SetCursor(sdl_cursor_normal);
    SDL_ShowCursor(SDL_ENABLE);
}

static void sdl_set_mouse_grab(struct sdl2_console *scon, SDL_bool grabbed)
{
#if SDL_VERSION_ATLEAST(2, 0, 16)
    SDL_SetWindowMouseGrab(scon->real_window, grabbed);
#else
    SDL_SetWindowGrab(scon->real_window, grabbed);
#endif
}

/* Absolute tablet windows capture shortcuts without constraining the mouse. */
static void sdl_sync_keyboard_grab(struct sdl2_console *scon)
{
    bool grabbed = scon && scon->real_window && !scon->hidden &&
                   scon->has_input_focus &&
                   (scon->has_mouse_focus ||
                    sdl_console_is_grabbed(scon)) &&
                   !(SDL_GetWindowFlags(scon->real_window) &
                     SDL_WINDOW_MINIMIZED);
    bool win32_grabbed = grabbed;
    int i;

#if SDL_VERSION_ATLEAST(2, 0, 16)
    if (scon && scon->real_window) {
        SDL_SetWindowKeyboardGrab(scon->real_window,
                                  grabbed ? SDL_TRUE : SDL_FALSE);
    }
#endif
    /*
     * The Win32 hook is process-wide; a delayed old-window event must not
     * release the hook already owned by another focused SDL console.
     */
    for (i = 0; !win32_grabbed && i < sdl2_num_outputs; i++) {
        struct sdl2_console *candidate = &sdl2_console[i];

        win32_grabbed = candidate->real_window && !candidate->hidden &&
            candidate->has_input_focus &&
            (candidate->has_mouse_focus ||
             sdl_console_is_grabbed(candidate)) &&
            !(SDL_GetWindowFlags(candidate->real_window) &
              SDL_WINDOW_MINIMIZED);
    }
    win32_kbd_set_grab(win32_grabbed);
}

static void sdl_reset_relative_motion(struct sdl2_console *scon)
{
    scon->window_to_render_x = (SDL2AxisScale) { 0 };
    scon->window_to_render_y = (SDL2AxisScale) { 0 };
    scon->render_to_guest_x = (SDL2AxisScale) { 0 };
    scon->render_to_guest_y = (SDL2AxisScale) { 0 };
}

static void sdl_release_mouse_buttons(struct sdl2_console *scon)
{
    if (!scon || !scon->mouse_button_state) {
        return;
    }

    qemu_input_update_buttons(scon->dcl.con, sdl_button_map,
                              scon->mouse_button_state, 0);
    scon->mouse_button_state = 0;
    qemu_input_event_sync();
}

static bool sdl_pointer_geometry(struct sdl2_console *scon,
                                 SDL2Size *window, SDL2Size *render,
                                 SDL2Size *guest, SDL2Rect *dst)
{
    SDL_GetWindowSize(scon->real_window,
                      &window->width, &window->height);
    if (window->width <= 0 || window->height <= 0 ||
        !sdl2_current_render_size(scon, render) ||
        !sdl2_current_guest_size(scon, guest)) {
        return false;
    }

    *dst = sdl2_guest_dst_rect(*render, *guest);
    return dst->width > 0 && dst->height > 0;
}

static void sdl_warp_guest_cursor(struct sdl2_console *scon)
{
    SDL2Size window;
    SDL2Size render;
    SDL2Size guest;
    SDL2Rect dst;
    SDL2Point render_point;
    SDL2Point window_point;
    SDL2Point quantized_render;
    SDL2Point quantized_guest;

    if (!sdl_pointer_geometry(scon, &window, &render, &guest, &dst)) {
        return;
    }
    if (!sdl2_guest_to_window(
            dst, guest,
            (SDL2Point) { scon->guest_x, scon->guest_y }, &render_point) ||
        !sdl2_map_point(render, window, render_point, &window_point)) {
        return;
    }

    /* Record the guest pixel represented by the quantized SDL warp. */
    if (sdl2_map_point(window, render, window_point, &quantized_render) &&
        sdl2_window_to_guest(dst, guest, quantized_render,
                             &quantized_guest)) {
        scon->guest_x = quantized_guest.x;
        scon->guest_y = quantized_guest.y;
    }
    SDL_WarpMouseInWindow(scon->real_window, window_point.x, window_point.y);
}

static void sdl_grab_start(struct sdl2_console *scon)
{
    QemuConsole *con = scon ? scon->dcl.con : NULL;

    if (!con || !qemu_console_is_graphic(con)) {
        return;
    }
    /*
     * If the application is not active, do not try to enter grab state. This
     * prevents 'SDL_WM_GrabInput(SDL_GRAB_ON)' from blocking all the
     * application (SDL bug).
     */
    if (!(SDL_GetWindowFlags(scon->real_window) & SDL_WINDOW_INPUT_FOCUS)) {
        return;
    }
    if (grabbed_scon && grabbed_scon != scon) {
        sdl_grab_end(grabbed_scon);
    }
    sdl_reset_relative_motion(scon);
    sdl_set_mouse_grab(scon, SDL_TRUE);
    grabbed_scon = scon;
    sdl_sync_keyboard_grab(scon);
    sdl_apply_active_cursor(scon);
    if (!sdl2_framebuffer_cursor && scon->guest_cursor &&
        !qemu_input_is_absolute(scon->dcl.con)) {
        sdl_warp_guest_cursor(scon);
    }
    sdl_update_caption(scon);
}

static void sdl_grab_end(struct sdl2_console *scon)
{
    scon = grabbed_scon ? grabbed_scon : scon;
    if (!scon) {
        return;
    }

    sdl_release_mouse_buttons(scon);
    sdl_reset_relative_motion(scon);
    SDL_SetRelativeMouseMode(SDL_FALSE);
    sdl_set_mouse_grab(scon, SDL_FALSE);
    grabbed_scon = NULL;
    sdl_sync_keyboard_grab(scon);
    if (scon->has_input_focus && scon->has_mouse_focus &&
        qemu_input_has_absolute(scon->dcl.con)) {
        sdl_apply_active_cursor(scon);
    } else {
        sdl_show_cursor(scon);
    }
    sdl_update_caption(scon);
}

static void sdl_mouse_mode_change(Notifier *notify, void *data)
{
    int i;

    for (i = 0; i < sdl2_num_outputs; i++) {
        struct sdl2_console *scon = &sdl2_console[i];
        bool absolute = qemu_input_is_absolute(scon->dcl.con);
        bool available = qemu_input_has_absolute(scon->dcl.con);
        bool grabbed = sdl_console_is_grabbed(scon);
        SDL2PointerPolicy policy;

        if (absolute == scon->absolute_enabled &&
            available == scon->absolute_available) {
            continue;
        }

        sdl_release_mouse_buttons(scon);
        sdl_reset_relative_motion(scon);
        scon->absolute_enabled = absolute;
        scon->absolute_available = available;
        policy = sdl2_pointer_policy(grabbed, absolute, available);
        if (policy.release_grab && !gui_fullscreen) {
            sdl_grab_end(scon);
        } else if (sdl_cursor_is_active(scon)) {
            if (grabbed || available) {
                sdl_apply_active_cursor(scon);
            } else if (!grabbed_scon) {
                sdl_show_cursor(scon);
            }
        }
    }
}

static void sdl_send_mouse_event(struct sdl2_console *scon,
                                 int window_dx, int window_dy,
                                 int window_x, int window_y, uint32_t state)
{
    SDL2Size guest;
    SDL2Size window;
    SDL2Size render;
    SDL2Rect dst;
    SDL2Point render_point;
    SDL2Point guest_point;
    int render_dx;
    int render_dy;
    int dx;
    int dy;

    if (scon->mouse_button_state != state) {
        qemu_input_update_buttons(scon->dcl.con, sdl_button_map,
                                  scon->mouse_button_state, state);
        scon->mouse_button_state = state;
    }

    if (!sdl_pointer_geometry(scon, &window, &render, &guest, &dst) ||
        !sdl2_map_point(window, render,
                        (SDL2Point) { window_x, window_y }, &render_point) ||
        !sdl2_window_to_guest(dst, guest, render_point, &guest_point)) {
        qemu_input_event_sync();
        return;
    }

    if (qemu_input_is_absolute(scon->dcl.con)) {
        qemu_input_queue_abs(scon->dcl.con, INPUT_AXIS_X, guest_point.x,
                             0, guest.width - 1);
        qemu_input_queue_abs(scon->dcl.con, INPUT_AXIS_Y, guest_point.y,
                             0, guest.height - 1);
    } else {
        if (scon->guest_cursor) {
            dx = guest_point.x - scon->guest_x;
            dy = guest_point.y - scon->guest_y;
            scon->guest_x = guest_point.x;
            scon->guest_y = guest_point.y;
        } else {
            render_dx = sdl2_scale_relative_motion(
                window_dx, window.width, render.width,
                &scon->window_to_render_x);
            render_dy = sdl2_scale_relative_motion(
                window_dy, window.height, render.height,
                &scon->window_to_render_y);
            dx = sdl2_scale_relative_motion(
                render_dx, dst.width, guest.width,
                &scon->render_to_guest_x);
            dy = sdl2_scale_relative_motion(
                render_dy, dst.height, guest.height,
                &scon->render_to_guest_y);
        }
        qemu_input_queue_rel(scon->dcl.con, INPUT_AXIS_X, dx);
        qemu_input_queue_rel(scon->dcl.con, INPUT_AXIS_Y, dy);
    }
    qemu_input_event_sync();
}

static void toggle_full_screen(struct sdl2_console *scon)
{
    gui_fullscreen = !gui_fullscreen;
    if (gui_fullscreen) {
        SDL_SetWindowFullscreen(scon->real_window,
                                SDL_WINDOW_FULLSCREEN_DESKTOP);
        gui_saved_grab = sdl_console_is_grabbed(scon);
        sdl_grab_start(scon);
    } else {
        if (!gui_saved_grab) {
            sdl_grab_end(scon);
        }
        SDL_SetWindowFullscreen(scon->real_window, 0);
    }
    sdl2_redraw(scon);
}

static int get_mod_state(void)
{
    SDL_Keymod mod = SDL_GetModState();

    if (alt_grab) {
        return (mod & (gui_grab_code | KMOD_LSHIFT)) ==
            (gui_grab_code | KMOD_LSHIFT);
    } else if (ctrl_grab) {
        return (mod & KMOD_RCTRL) == KMOD_RCTRL;
    } else {
        return (mod & gui_grab_code) == gui_grab_code;
    }
}

static void *sdl2_win32_get_hwnd(struct sdl2_console *scon)
{
#ifdef CONFIG_WIN32
    SDL_SysWMinfo info;

    SDL_VERSION(&info.version);
    if (SDL_GetWindowWMInfo(scon->real_window, &info)) {
        return info.info.win.window;
    }
#endif
    return NULL;
}

/*
 * Keyboard focus and pointer focus are independent in SDL/XWayland.  In
 * particular, a focused window may receive key events without a preceding
 * SDL_WINDOWEVENT_ENTER, so requiring SDL_WINDOW_MOUSE_FOCUS here can make a
 * perfectly focused QEMU window silently discard every key press.
 */
static bool sdl2_keyboard_input_allowed(struct sdl2_console *scon)
{
    return scon && scon->has_input_focus;
}

static bool sdl2_pointer_input_allowed(struct sdl2_console *scon)
{
    return scon && scon->has_input_focus &&
           (scon->has_mouse_focus || sdl_console_is_grabbed(scon));
}
static void handle_keydown(SDL_Event *ev)
{
    int win;
    struct sdl2_console *scon = get_scon_from_window(ev->key.windowID);
    int gui_key_modifier_pressed = get_mod_state();

    if (!scon) {
        return;
    }
    /* Keyboard input follows the window's input focus.  KEYUP always reaches
     * qkbd_state below so focus transitions cannot leave a guest key stuck. */
    if (!sdl2_keyboard_input_allowed(scon)) {
        return;
    }

    scon->gui_keysym = false;

    if (!scon->ignore_hotkeys && gui_key_modifier_pressed && !ev->key.repeat) {
        switch (ev->key.keysym.scancode) {
        case SDL_SCANCODE_2:
        case SDL_SCANCODE_3:
        case SDL_SCANCODE_4:
        case SDL_SCANCODE_5:
        case SDL_SCANCODE_6:
        case SDL_SCANCODE_7:
        case SDL_SCANCODE_8:
        case SDL_SCANCODE_9:
            if (grabbed_scon) {
                sdl_grab_end(scon);
            }

            win = ev->key.keysym.scancode - SDL_SCANCODE_1;
            if (win < sdl2_num_outputs) {
                sdl2_console[win].hidden = !sdl2_console[win].hidden;
                if (sdl2_console[win].real_window) {
                    if (sdl2_console[win].hidden) {
                        SDL_HideWindow(sdl2_console[win].real_window);
                    } else {
                        SDL_ShowWindow(sdl2_console[win].real_window);
                    }
                }
                sdl2_release_modifiers(scon);
                scon->gui_keysym = true;
            }
            break;
        case SDL_SCANCODE_F:
            toggle_full_screen(scon);
            scon->gui_keysym = true;
            break;
        case SDL_SCANCODE_G:
            scon->gui_keysym = true;
            if (!sdl_console_is_grabbed(scon)) {
                sdl_grab_start(scon);
            } else if (!gui_fullscreen) {
                sdl_grab_end(scon);
            }
            break;
        case SDL_SCANCODE_C:
            sdl2_framebuffer_cursor = !sdl2_framebuffer_cursor;
            if (sdl_console_is_grabbed(scon) ||
                (scon->has_input_focus && scon->has_mouse_focus &&
                 qemu_input_has_absolute(scon->dcl.con))) {
                sdl_apply_active_cursor(scon);
            } else if (!grabbed_scon) {
                sdl_show_cursor(scon);
            }
            info_report("sdl2: framebuffer cursor mode %s",
                        sdl2_framebuffer_cursor ? "enabled" : "disabled");
            sdl_update_caption(scon);
            scon->gui_keysym = true;
            break;
        case SDL_SCANCODE_0:
            sdl2_window_resize(scon);
            if (!scon->opengl) {
                /* re-create scon->texture */
                sdl2_2d_switch(&scon->dcl, scon->surface);
            }
            scon->gui_keysym = true;
            break;
#if 0
        case SDL_SCANCODE_KP_PLUS:
        case SDL_SCANCODE_KP_MINUS:
            if (!gui_fullscreen) {
                int scr_w, scr_h;
                int width, height;
                SDL_GetWindowSize(scon->real_window, &scr_w, &scr_h);

                width = MAX(scr_w + (ev->key.keysym.scancode ==
                                     SDL_SCANCODE_KP_PLUS ? 50 : -50),
                            160);
                height = (surface_height(scon->surface) * width) /
                    surface_width(scon->surface);
                fprintf(stderr, "%s: scale to %dx%d\n",
                        __func__, width, height);
                sdl_scale(scon, width, height);
                sdl2_redraw(scon);
                scon->gui_keysym = true;
            }
#endif
        default:
            break;
        }
    }
    if (!scon->gui_keysym) {
        sdl2_process_key(scon, &ev->key);
    }
}

static void handle_keyup(SDL_Event *ev)
{
    struct sdl2_console *scon = get_scon_from_window(ev->key.windowID);

    if (!scon) {
        return;
    }

    scon->ignore_hotkeys = false;
    /*
     * KEYUP 不走 sdl2_input_allowed 早退 —— 焦点丢失时 handle_windowevent
     * 已经 lift 过全键, qkbd_state_key_event() 的 suspicious-keyup 兜底过滤
     * 重复的 up; 但若在 allowed=true 期间按下、allowed=false 期间松开,
     * 这里照常把 up 送给 qkbd_state 才能保持位图一致 (虽然此时通常已被
     * lift 抬过, 仍属安全冗余).
     */
    sdl2_process_key(scon, &ev->key);
}

static void handle_textinput(SDL_Event *ev)
{
    struct sdl2_console *scon = get_scon_from_window(ev->text.windowID);
    QemuConsole *con = scon ? scon->dcl.con : NULL;

    if (!con) {
        return;
    }
    if (!sdl2_keyboard_input_allowed(scon)) {
        return;
    }

    if (!scon->gui_keysym && QEMU_IS_TEXT_CONSOLE(con)) {
        qemu_text_console_put_string(QEMU_TEXT_CONSOLE(con), ev->text.text, strlen(ev->text.text));
    }
}

static void handle_mousemotion(SDL_Event *ev)
{
    struct sdl2_console *scon = get_scon_from_window(ev->motion.windowID);
    SDL2PointerPolicy policy;

    if (!scon || !qemu_console_is_graphic(scon->dcl.con)) {
        return;
    }
    /* grab=on 时 SDL 把指针锁在窗内, pointer gate 自然为真;
     * grab=off 且指针在窗外/无焦点时, 不把鼠标位置写进 guest. */
    if (!sdl2_pointer_input_allowed(scon)) {
        return;
    }

    policy = sdl2_pointer_policy(
        sdl_console_is_grabbed(scon),
        qemu_input_is_absolute(scon->dcl.con),
        qemu_input_has_absolute(scon->dcl.con));
    if (policy.accept_motion) {
        /* Keep SDL logical-window coordinates raw until the unified mapper. */
        sdl_send_mouse_event(scon,
                             ev->motion.xrel, ev->motion.yrel,
                             ev->motion.x, ev->motion.y,
                             scon->mouse_button_state);
    }
}

static void handle_mousebutton(SDL_Event *ev)
{
    uint32_t buttonstate;
    SDL_MouseButtonEvent *bev;
    struct sdl2_console *scon = get_scon_from_window(ev->button.windowID);
    SDL2PointerPolicy policy;

    if (!scon || !qemu_console_is_graphic(scon->dcl.con)) {
        return;
    }
    if (!sdl2_pointer_input_allowed(scon)) {
        return;
    }

    bev = &ev->button;
    buttonstate = scon->mouse_button_state;
    policy = sdl2_pointer_policy(
        sdl_console_is_grabbed(scon),
        qemu_input_is_absolute(scon->dcl.con),
        qemu_input_has_absolute(scon->dcl.con));

    if (policy.auto_grab_on_click) {
        if (ev->type == SDL_MOUSEBUTTONUP && bev->button == SDL_BUTTON_LEFT) {
            /* start grabbing all events */
            sdl_grab_start(scon);
        }
    } else {
        if (ev->type == SDL_MOUSEBUTTONDOWN) {
            buttonstate |= SDL_BUTTON(bev->button);
        } else {
            buttonstate &= ~SDL_BUTTON(bev->button);
        }
        sdl_send_mouse_event(scon, 0, 0, bev->x, bev->y, buttonstate);
    }
}

static void handle_mousewheel(SDL_Event *ev)
{
    struct sdl2_console *scon = get_scon_from_window(ev->wheel.windowID);
    SDL_MouseWheelEvent *wev = &ev->wheel;
    InputButton btn;

    if (!scon || !qemu_console_is_graphic(scon->dcl.con)) {
        return;
    }
    if (!sdl2_pointer_input_allowed(scon)) {
        return;
    }

    if (wev->y > 0) {
        btn = INPUT_BUTTON_WHEEL_UP;
    } else if (wev->y < 0) {
        btn = INPUT_BUTTON_WHEEL_DOWN;
    } else if (wev->x < 0) {
        btn = INPUT_BUTTON_WHEEL_RIGHT;
    } else if (wev->x > 0) {
        btn = INPUT_BUTTON_WHEEL_LEFT;
    } else {
        return;
    }

    qemu_input_queue_btn(scon->dcl.con, btn, true);
    qemu_input_event_sync();
    qemu_input_queue_btn(scon->dcl.con, btn, false);
    qemu_input_event_sync();
}

static bool sdl2_confirm_close(struct sdl2_console *scon)
{
    /*
     * X 关闭一次会同时派 SDL_WINDOWEVENT_CLOSE + SDL_QUIT，多 console 的
     * poll 路径还可能再走一次；用 1.5s 时间窗复用上一次结果，避免连弹。
     */
    static Uint32 last_ticks;
    static bool last_answer;
    Uint32 now = SDL_GetTicks();
    Uint32 flags;
    bool was_grabbed;
    if (last_ticks && now - last_ticks < 1500) {
        return last_answer;
    }

    const SDL_MessageBoxButtonData buttons[] = {
        { SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, 0, "取消 / Cancel" },
        { SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, 1, "关机 / Shutdown" },
    };
    const SDL_MessageBoxData mbox = {
        SDL_MESSAGEBOX_WARNING,
        scon->real_window,
        "QEMU",
        "确认关闭虚拟机吗？\n点击 Shutdown 将向 guest 发出关机请求。",
        SDL_arraysize(buttons),
        buttons,
        NULL,
    };
    int btn = -1;

    /* SDL's native dialog blocks this main thread.  Release guest input and
     * the host grab before entering it so a missing KEYUP cannot stick. */
    was_grabbed = sdl_console_is_grabbed(scon);
    sdl2_release_modifiers(scon);
    if (was_grabbed) {
        sdl_grab_end(scon);
    } else {
        sdl_release_mouse_buttons(scon);
        sdl_reset_relative_motion(scon);
        sdl_sync_keyboard_grab(scon);
    }
    if (SDL_ShowMessageBox(&mbox, &btn) < 0) {
        last_answer = true;
    } else {
        last_answer = (btn == 1);
    }
    flags = SDL_GetWindowFlags(scon->real_window);
    scon->has_input_focus = !!(flags & SDL_WINDOW_INPUT_FOCUS);
    scon->has_mouse_focus = !!(flags & SDL_WINDOW_MOUSE_FOCUS);
    if (was_grabbed && scon->has_input_focus) {
        sdl_grab_start(scon);
    } else {
        sdl_sync_keyboard_grab(scon);
    }
    sdl2_gnome_guard_update(scon);
    scon->ignore_hotkeys = get_mod_state();
    last_ticks = SDL_GetTicks();
    /* 把对话框期间堆积的 QUIT/CLOSE 事件清掉，下一轮 poll 不会再问一遍 */
    SDL_FlushEvent(SDL_QUIT);
    return last_answer;
}

static void handle_windowevent(SDL_Event *ev)
{
    struct sdl2_console *scon = get_scon_from_window(ev->window.windowID);
    bool allow_close = true;

    if (!scon) {
        return;
    }

    switch (ev->window.event) {
    case SDL_WINDOWEVENT_RESIZED:
    case SDL_WINDOWEVENT_SIZE_CHANGED:
        /*
         * 宿主窗口只是 Guest scanout 的显示画布。不再把
         * RESIZED 通过 display-info 回写 Guest：否则最小化途中的
         * 中间尺寸会被当成新分辨率，
         * 形成“先缩成一点再消失”
         * 的反馈环。SDL_SetWindowSize() 也会产生 SIZE_CHANGED，
         * 所以两类事件统一只重绘。
         */
        sdl2_window_update_size_limits(scon);
        scon->window_redraw_pending = true;
        sdl_reset_relative_motion(scon);
        break;
    case SDL_WINDOWEVENT_EXPOSED:
        scon->window_redraw_pending = true;
        break;
#if SDL_VERSION_ATLEAST(2, 0, 18)
    case SDL_WINDOWEVENT_DISPLAY_CHANGED:
        sdl2_window_update_size_limits(scon);
        scon->window_redraw_pending = true;
        break;
#endif
    case SDL_WINDOWEVENT_FOCUS_GAINED:
        scon->has_input_focus = true;
        scon->has_mouse_focus = !!(SDL_GetWindowFlags(scon->real_window) &
                                   SDL_WINDOW_MOUSE_FOCUS);
        if (sdl_console_is_grabbed(scon)) {
            sdl_set_mouse_grab(scon, SDL_TRUE);
        }
        sdl_sync_keyboard_grab(scon);
        if (qemu_console_is_graphic(scon->dcl.con)) {
            win32_kbd_set_window(sdl2_win32_get_hwnd(scon));
        }
        /*
         * 中文注释：GL scanout 的窗口 back buffer 在最小化、隐藏或被窗口管理器
         * 重新合成后可能被清成黑色。guest 若此时没有提交新帧，普通
         * graphic_hw_update() 不会触发 dpy_gl_update()，窗口就会一直黑到下一帧。
         * 焦点回来时主动 replay 当前 scanout，保证 idle 桌面也能恢复显示。
         */
        scon->window_redraw_pending = true;
        if (sdl_cursor_is_active(scon) &&
            (sdl_console_is_grabbed(scon) ||
             qemu_input_has_absolute(scon->dcl.con))) {
            sdl_apply_active_cursor(scon);
        }
        /* fall through */
    case SDL_WINDOWEVENT_ENTER:
        if (ev->window.event == SDL_WINDOWEVENT_ENTER) {
            scon->has_mouse_focus = true;
        }
        sdl_sync_keyboard_grab(scon);
        if ((sdl_console_is_grabbed(scon) ||
             (scon->has_mouse_focus &&
              qemu_input_has_absolute(scon->dcl.con))) &&
            scon->has_input_focus) {
            sdl_apply_active_cursor(scon);
        }
        /* If a new console window opened using a hotkey receives the
         * focus, SDL sends another KEYDOWN event to the new window,
         * closing the console window immediately after.
         *
         * Work around this by ignoring further hotkey events until a
         * key is released.
         */
        scon->ignore_hotkeys = get_mod_state();
        sdl2_gnome_guard_update(scon);
        break;
    case SDL_WINDOWEVENT_FOCUS_LOST:
        /* X11 输入焦点丢失 (alt-tab / WM 切窗 / 无 WM 时其他 client grab):
         * 抬掉所有按下的键, 防止 guest 卡在 "W 一直按住" 之类状态. */
        scon->has_input_focus = false;
        sdl2_release_modifiers(scon);
        sdl_release_mouse_buttons(scon);
        sdl_reset_relative_motion(scon);
        sdl_sync_keyboard_grab(scon);
        if (qemu_console_is_graphic(scon->dcl.con)) {
            win32_kbd_set_window(NULL);
        }
        if (sdl_console_is_grabbed(scon) && !gui_fullscreen) {
            sdl_grab_end(scon);
        } else if (!grabbed_scon || sdl_console_is_grabbed(scon)) {
            sdl_show_cursor(scon);
        }
        sdl2_gnome_guard_update(scon);
        break;
    case SDL_WINDOWEVENT_LEAVE:
        /*
         * 鼠标离开窗口: 用户要求"窗外按键不进 guest",
         * 同样抬掉按下的键. 不动显式 grab
         * (grab 状态下指针锁在窗内, 不会触发 LEAVE).
         */
        scon->has_mouse_focus = false;
        sdl2_release_modifiers(scon);
        sdl_release_mouse_buttons(scon);
        sdl_reset_relative_motion(scon);
        sdl_sync_keyboard_grab(scon);
        if (!grabbed_scon) {
            sdl_show_cursor(scon);
        }
        sdl2_gnome_guard_update(scon);
        break;
    case SDL_WINDOWEVENT_MAXIMIZED:
    case SDL_WINDOWEVENT_RESTORED:
        /* Both maximize and unminimize replace the compositor buffer. */
        sdl_sync_keyboard_grab(scon);
        if (scon->window_resize_pending) {
            sdl2_window_resize(scon);
        }
        scon->window_redraw_pending = true;
        update_displaychangelistener_ns(
            &scon->dcl, SDL2_REFRESH_INTERVAL_ACTIVE_NS);
        if (sdl_cursor_is_active(scon) &&
            (sdl_console_is_grabbed(scon) ||
             qemu_input_has_absolute(scon->dcl.con))) {
            sdl_apply_active_cursor(scon);
        }
        break;
    case SDL_WINDOWEVENT_MINIMIZED:
        /*
         * 丢弃最小化前排队的 resize/redraw；
         * RESTORED 会补一次整帧。
         */
        scon->window_redraw_pending = false;
        scon->window_resize_pending = true;
        sdl2_present_rate_reset(scon);
        sdl_release_mouse_buttons(scon);
        sdl_reset_relative_motion(scon);
        if (!grabbed_scon || sdl_console_is_grabbed(scon)) {
            SDL_SetRelativeMouseMode(SDL_FALSE);
        }
        sdl_sync_keyboard_grab(scon);
        update_displaychangelistener(
            &scon->dcl, SDL2_REFRESH_INTERVAL_MINIMIZED_MS);
        if (!grabbed_scon || sdl_console_is_grabbed(scon)) {
            sdl_show_cursor(scon);
        }
        sdl2_gnome_guard_set(false);
        break;
    case SDL_WINDOWEVENT_CLOSE:
        if (qemu_console_is_graphic(scon->dcl.con)) {
            if (scon->opts->has_window_close && !scon->opts->window_close) {
                allow_close = false;
            }
            if (allow_close && !sdl2_confirm_close(scon)) {
                allow_close = false;
            }
            if (allow_close) {
                shutdown_action = SHUTDOWN_ACTION_POWEROFF;
                qemu_system_shutdown_request(SHUTDOWN_CAUSE_HOST_UI);
            }
        } else {
            sdl_release_mouse_buttons(scon);
            sdl_reset_relative_motion(scon);
            SDL_HideWindow(scon->real_window);
            scon->hidden = true;
            sdl_sync_keyboard_grab(scon);
        }
        break;
    case SDL_WINDOWEVENT_SHOWN:
        scon->hidden = false;
        sdl_sync_keyboard_grab(scon);
        update_displaychangelistener_ns(
            &scon->dcl, SDL2_REFRESH_INTERVAL_ACTIVE_NS);
        sdl2_window_resize(scon);
        graphic_hw_invalidate(scon->dcl.con);
        scon->window_redraw_pending = true;
        if (sdl_cursor_is_active(scon) &&
            (sdl_console_is_grabbed(scon) ||
             qemu_input_has_absolute(scon->dcl.con))) {
            sdl_apply_active_cursor(scon);
        }
        break;
    case SDL_WINDOWEVENT_HIDDEN:
        scon->hidden = true;
        /* SHOWN 会重新同步窗口并补一次整帧。 */
        scon->window_redraw_pending = false;
        scon->window_resize_pending = true;
        sdl2_present_rate_reset(scon);
        sdl_release_mouse_buttons(scon);
        sdl_reset_relative_motion(scon);
        if (!grabbed_scon || sdl_console_is_grabbed(scon)) {
            SDL_SetRelativeMouseMode(SDL_FALSE);
        }
        sdl_sync_keyboard_grab(scon);
        update_displaychangelistener(
            &scon->dcl, SDL2_REFRESH_INTERVAL_MINIMIZED_MS);
        if (!grabbed_scon || sdl_console_is_grabbed(scon)) {
            sdl_show_cursor(scon);
        }
        sdl2_gnome_guard_set(false);
        break;
    }
}

void sdl2_flush_window_updates(void)
{
    int i;

    /*
     * A resize drag can queue dozens of RESIZED/SIZE_CHANGED/EXPOSED events.
     * Once the SDL queue is drained, redraw each visible window once and drop
     * animation updates belonging to a minimized or hidden window.
     */
    for (i = 0; i < sdl2_num_outputs; i++) {
        struct sdl2_console *target = &sdl2_console[i];

        if (!sdl2_window_is_renderable(target)) {
            target->window_redraw_pending = false;
            continue;
        }
        if (target->window_resize_pending) {
            sdl2_window_resize(target);
        }
        if (target->window_redraw_pending) {
            target->window_redraw_pending = false;
#ifdef CONFIG_OPENGL
            sdl2_window_sync_native_egl_child(target);
#endif
            if (target->opengl) {
                sdl2_redraw(target);
            } else if (target->texture) {
                /* The 2D refresh path will present this texture once after
                 * graphic_hw_update(), together with any dirty rectangles. */
                target->updates = MAX(target->updates, 1);
            }
        }
    }
}

static void sdl2_recover_2d_renderers(bool recreate_textures)
{
    int i;

    /* Renderer reset is process-wide and carries no window ID.  Recover only
     * SDL's 2D consoles; G-11's GL/native-EGL contexts have a separate
     * lifecycle and must never be rebuilt through SDL_Renderer APIs. */
    for (i = 0; i < sdl2_num_outputs; i++) {
        struct sdl2_console *target = &sdl2_console[i];

        if (target->opengl || !target->real_renderer || !target->surface) {
            continue;
        }
        graphic_hw_invalidate(target->dcl.con);
        if (recreate_textures) {
            sdl2_2d_switch(&target->dcl, target->surface);
        } else {
            sdl2_2d_redraw(target);
        }
        if (recreate_textures && !target->texture) {
            warn_report("SDL: failed to recreate renderer texture: %s",
                        SDL_GetError());
        }
    }
}

void sdl2_poll_events(struct sdl2_console *scon)
{
    SDL_Event ev1, *ev = &ev1;
    bool allow_close = true;
    int idle = 1;

    /* Keep the title truthful when REGION frame dedup suppresses every swap. */
    sdl2_present_rate_tick(scon);

    if (scon->last_vm_running != runstate_is_running()) {
        scon->last_vm_running = runstate_is_running();
        sdl_update_caption(scon);
    }

    while (SDL_PollEvent(ev)) {
        switch (ev->type) {
        case SDL_KEYDOWN:
            idle = 0;
            handle_keydown(ev);
            break;
        case SDL_KEYUP:
            idle = 0;
            handle_keyup(ev);
            break;
        case SDL_TEXTINPUT:
            idle = 0;
            handle_textinput(ev);
            break;
        case SDL_QUIT:
            if (scon->opts->has_window_close && !scon->opts->window_close) {
                allow_close = false;
            }
            if (allow_close && !sdl2_confirm_close(scon)) {
                allow_close = false;
            }
            if (allow_close) {
                shutdown_action = SHUTDOWN_ACTION_POWEROFF;
                qemu_system_shutdown_request(SHUTDOWN_CAUSE_HOST_UI);
            }
            break;
        case SDL_MOUSEMOTION:
            idle = 0;
            sdl2_coalesce_mouse_motion(ev);
            handle_mousemotion(ev);
            break;
        case SDL_MOUSEBUTTONDOWN:
        case SDL_MOUSEBUTTONUP:
            idle = 0;
            handle_mousebutton(ev);
            break;
        case SDL_MOUSEWHEEL:
            idle = 0;
            handle_mousewheel(ev);
            break;
        case SDL_WINDOWEVENT:
            handle_windowevent(ev);
            break;
        case SDL_RENDER_TARGETS_RESET:
            sdl2_recover_2d_renderers(false);
            break;
        case SDL_RENDER_DEVICE_RESET:
            sdl2_recover_2d_renderers(true);
            break;
        default:
            break;
        }
    }

    if (!idle) {
        scon->idle_counter = 0;
    }
    if (!scon->hidden && scon->real_window &&
        !(SDL_GetWindowFlags(scon->real_window) & SDL_WINDOW_MINIMIZED)) {
        scon->dcl.update_interval = 0;
        scon->dcl.update_interval_ns = SDL2_REFRESH_INTERVAL_ACTIVE_NS;
    }
}

static uint32_t sdl2_input_poll_interval_ms(void)
{
    bool has_mapped_window = false;
    int i;

    for (i = 0; i < sdl2_num_outputs; i++) {
        struct sdl2_console *scon = &sdl2_console[i];
        Uint32 flags;

        if (!scon->real_window || scon->hidden) {
            continue;
        }
        has_mapped_window = true;
        flags = SDL_GetWindowFlags(scon->real_window);
        if (!(flags & SDL_WINDOW_MINIMIZED) &&
            (scon->has_input_focus || scon->has_mouse_focus ||
             sdl_console_is_grabbed(scon))) {
            return SDL2_INPUT_POLL_INTERVAL_ACTIVE_MS;
        }
    }
    return has_mapped_window ? SDL2_INPUT_POLL_INTERVAL_BACKGROUND_MS :
                               SDL2_REFRESH_INTERVAL_MINIMIZED_MS;
}

static void sdl2_input_timer_cb(void *opaque)
{
    (void)opaque;

    if (sdl2_console && sdl2_num_outputs > 0) {
        /* Pump input only; guest rendering stays on its 60 Hz display tick. */
        sdl2_poll_events(&sdl2_console[0]);
    }
    if (sdl2_input_timer) {
        timer_mod(sdl2_input_timer,
                  qemu_clock_get_ms(QEMU_CLOCK_REALTIME) +
                  sdl2_input_poll_interval_ms());
    }
}

static void sdl_mouse_warp(DisplayChangeListener *dcl,
                           int x, int y, bool on)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);

    if (!qemu_console_is_graphic(scon->dcl.con)) {
        return;
    }

    scon->guest_cursor = on;
    scon->guest_x = x;
    scon->guest_y = y;

    if (!sdl_cursor_is_active(scon)) {
        return;
    }

    sdl_apply_active_cursor(scon);
    if (on && !sdl2_framebuffer_cursor &&
        sdl_console_is_grabbed(scon) &&
        !qemu_input_is_absolute(scon->dcl.con)) {
        sdl_warp_guest_cursor(scon);
    }
}

static void sdl_mouse_define(DisplayChangeListener *dcl,
                             QEMUCursor *c)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);

    if (scon->guest_sprite) {
        if (SDL_GetCursor() == scon->guest_sprite) {
            SDL_SetCursor(sdl_cursor_hidden);
        }
        SDL_FreeCursor(scon->guest_sprite);
        scon->guest_sprite = NULL;
    }

    if (scon->guest_sprite_surface) {
        SDL_FreeSurface(scon->guest_sprite_surface);
        scon->guest_sprite_surface = NULL;
    }

    scon->guest_sprite_surface =
        SDL_CreateRGBSurfaceFrom(c->data, c->width, c->height, 32, c->width * 4,
                                 0xff0000, 0x00ff00, 0xff, 0xff000000);

    if (!scon->guest_sprite_surface) {
        fprintf(stderr, "Failed to make rgb surface from %p\n", c);
        return;
    }
    scon->guest_sprite = SDL_CreateColorCursor(scon->guest_sprite_surface,
                                               c->hot_x, c->hot_y);
    if (!scon->guest_sprite) {
        fprintf(stderr, "Failed to make color cursor from %p\n", c);
        return;
    }
    if (scon->guest_cursor && sdl_cursor_is_active(scon)) {
        sdl_apply_active_cursor(scon);
    }
}

static void sdl_cleanup(void)
{
    int i;

    if (sdl2_input_timer) {
        timer_free(sdl2_input_timer);
        sdl2_input_timer = NULL;
    }

    for (i = 0; i < sdl2_num_outputs; i++) {
        if (sdl2_console[i].guest_sprite) {
            SDL_FreeCursor(sdl2_console[i].guest_sprite);
        }
        if (sdl2_console[i].guest_sprite_surface) {
            SDL_FreeSurface(sdl2_console[i].guest_sprite_surface);
        }
    }
    if (sdl_cursor_windows) {
        SDL_FreeCursor(sdl_cursor_windows);
        sdl_cursor_windows = NULL;
    }
    sdl2_gnome_guard_restore();
    g_clear_pointer(&sdl2_gnome_guard_state, g_free);
    if (sdl2_screen_saver_inhibited) {
        /* Do not leave a process-global inhibitor behind during SDL teardown. */
        SDL_EnableScreenSaver();
        sdl2_screen_saver_inhibited = false;
    }
    SDL_QuitSubSystem(SDL_INIT_VIDEO);
}

/*
 * QMP @display-pause hook.  Hides the SDL window so the user sees
 * neither the host-side stale frame nor a CPU-burning redraw loop;
 * resume re-shows the window and forces a redraw to refill it from
 * the (now possibly very different) guest surface.
 */
static void sdl2_set_paused(DisplayChangeListener *dcl, bool paused)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);
    if (!scon->real_window) {
        return;
    }
    if (paused) {
        scon->hidden = true;
        scon->window_resize_pending = true;
        sdl2_present_rate_reset(scon);
        sdl_release_mouse_buttons(scon);
        sdl_reset_relative_motion(scon);
        if (!grabbed_scon || sdl_console_is_grabbed(scon)) {
            SDL_SetRelativeMouseMode(SDL_FALSE);
        }
        sdl_sync_keyboard_grab(scon);
        if (!grabbed_scon || sdl_console_is_grabbed(scon)) {
            sdl_show_cursor(scon);
        }
        SDL_HideWindow(scon->real_window);
    } else {
        scon->hidden = false;
        update_displaychangelistener_ns(
            &scon->dcl, SDL2_REFRESH_INTERVAL_ACTIVE_NS);
        SDL_ShowWindow(scon->real_window);
        sdl2_window_resize(scon);
        graphic_hw_invalidate(dcl->con);
        /*
         * 中文注释：display-resume 可能发生在 guest 桌面完全静止时。对
         * virtio-gpu-gl/virgl 来说，当前画面在 texture scanout 里，不在传统
         * DisplaySurface 里；只 invalidate 不一定马上产生新的 GL flush。
         * 这里直接重绘一次已缓存的 scanout，避免 SDL 窗口恢复后停在黑色
         * back buffer。
         */
        scon->window_redraw_pending = true;
        sdl2_redraw(scon);
    }
}

static const DisplayChangeListenerOps dcl_2d_ops = {
    .dpy_name             = "sdl2-2d",
    .dpy_gfx_update       = sdl2_2d_update,
    .dpy_gfx_switch       = sdl2_2d_switch,
    .dpy_gfx_check_format = sdl2_2d_check_format,
    .dpy_refresh          = sdl2_2d_refresh,
    .dpy_mouse_set        = sdl_mouse_warp,
    .dpy_cursor_define    = sdl_mouse_define,
    .dpy_set_paused       = sdl2_set_paused,
};

#ifdef CONFIG_OPENGL
#ifdef CONFIG_GBM
static bool sdl2_gl_has_dmabuf(DisplayChangeListener *dcl)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);

    /*
     * 中文注释：只有 native EGL 窗口 context 才能通过 EGL import dma-buf。
     * 默认 SDL_GL/GLX 路径不能安全导入/导出 dma-buf，因此必须报告 false，
     * 避免 console 层把 dmabuf scanout 误投给不支持的本地窗口。
     */
    return scon->native_egl && qemu_egl_has_dmabuf();
}
#endif

static const DisplayChangeListenerOps dcl_gl_ops = {
    .dpy_name                = "sdl2-gl",
    .dpy_gfx_update          = sdl2_gl_update,
    .dpy_gfx_switch          = sdl2_gl_switch,
    .dpy_gfx_check_format    = console_gl_check_format,
    .dpy_refresh             = sdl2_gl_refresh,
    .dpy_mouse_set           = sdl_mouse_warp,
    .dpy_cursor_define       = sdl_mouse_define,
    .dpy_set_paused          = sdl2_set_paused,

    .dpy_gl_scanout_disable  = sdl2_gl_scanout_disable,
    .dpy_gl_scanout_texture  = sdl2_gl_scanout_texture,
    .dpy_gl_update           = sdl2_gl_scanout_flush,
#ifdef CONFIG_GBM
    .dpy_gl_scanout_dmabuf   = sdl2_gl_scanout_dmabuf,
    .dpy_gl_release_dmabuf   = sdl2_gl_release_dmabuf,
    .dpy_has_dmabuf          = sdl2_gl_has_dmabuf,
#endif
};

static bool
sdl2_gl_is_compatible_dcl(DisplayGLCtx *dgc,
                          DisplayChangeListener *dcl)
{
    /*
     * SDL 拥有实际窗口 GL context。普通 GL scanout 必须走 sdl2-gl DCL；
     * fb-shm 是例外：它会创建一个与 SDL window context 共享的私有 GL
     * context，只做 texture->memfd 读回，不参与窗口绘制。
     */
    if (dcl->ops == &dcl_gl_ops) {
        return true;
    }

    return g_strcmp0(dcl->ops->dpy_name, "fb-shm") == 0 &&
           dcl->ops->dpy_gl_scanout_texture &&
           dcl->ops->dpy_gl_update;
}

static const DisplayGLCtxOps gl_ctx_ops = {
    .dpy_gl_ctx_is_compatible_dcl = sdl2_gl_is_compatible_dcl,
    .dpy_gl_ctx_create       = sdl2_gl_create_context,
    .dpy_gl_ctx_destroy      = sdl2_gl_destroy_context,
    .dpy_gl_ctx_make_current = sdl2_gl_make_context_current,
};
#endif

static void sdl2_display_early_init(DisplayOptions *o)
{
    assert(o->type == DISPLAY_TYPE_SDL);
    if (o->has_gl && o->gl) {
#ifdef CONFIG_OPENGL
        display_opengl = 1;
#endif
    }
}

static void sdl2_set_hint_x11_force_egl(void)
{
#if defined(SDL_HINT_VIDEO_X11_FORCE_EGL) && defined(CONFIG_OPENGL) && \
    defined(CONFIG_X11)
    Display *x_disp = XOpenDisplay(NULL);
    EGLDisplay egl_display;

    if (!x_disp) {
        return;
    }

    /* Prefer EGL over GLX to get dma-buf support. */
    egl_display = qemu_egl_get_display((EGLNativeDisplayType)x_disp,
                                       EGL_PLATFORM_X11_KHR);

    if (egl_display != EGL_NO_DISPLAY) {
        /*
         * Setting X11_FORCE_EGL hint doesn't make SDL to prefer X11 over
         * Wayland. SDL will use Wayland driver even if XWayland presents.
         * It's always safe to set the hint even if X11 is not used by SDL.
         * SDL will work regardless of the hint.
         */
        SDL_SetHint(SDL_HINT_VIDEO_X11_FORCE_EGL, "1");
        eglTerminate(egl_display);
    }

    XCloseDisplay(x_disp);
#endif
}

static void sdl2_display_init(DisplayState *ds, DisplayOptions *o)
{
    uint8_t data = 0;
    int i;
    SDL_SysWMinfo info;
    SDL_Surface *icon = NULL;
    char *dir;

    assert(o->type == DISPLAY_TYPE_SDL);

    if (sdl2_env_enabled("QEMU_SDL_TAME_GNOME")) {
        sdl2_gnome_guard_script = g_getenv("GNOME_SUPER_GUARD");
        if (sdl2_gnome_guard_script &&
            g_file_test(sdl2_gnome_guard_script, G_FILE_TEST_IS_EXECUTABLE)) {
            sdl2_gnome_guard_state = g_strdup_printf(
                "%s/qemu-sdl-%u-%ld.gnome-super", g_get_tmp_dir(),
                (unsigned)getuid(), (long)getpid());
        } else {
            warn_report("sdl2: QEMU_SDL_TAME_GNOME requested but "
                        "GNOME_SUPER_GUARD is not executable");
            sdl2_gnome_guard_script = NULL;
        }
    }

    if (SDL_GetHintBoolean("QEMU_ENABLE_SDL_LOGGING", SDL_FALSE)) {
        SDL_LogSetAllPriority(SDL_LOG_PRIORITY_VERBOSE);
    }

#ifdef SDL_HINT_WINDOWS_DPI_AWARENESS
    /* Must be set before SDL video initialization.  Environment hints keep
     * higher priority, so an administrator can still override this policy. */
    SDL_SetHint(SDL_HINT_WINDOWS_DPI_AWARENESS, "permonitorv2");
#endif
#ifdef CONFIG_X11
    /*
     * SDL otherwise derives WM_CLASS from argv[0] (qemu-system-x86_64),
     * which does not match the distro's qemu.desktop application id.  A
     * stable class lets GNOME/Dock group the window and calculate the proper
     * minimize target instead of using its top-left fallback.  Preserve an
     * explicit administrator override.
     */
    if (!g_getenv("SDL_VIDEO_X11_WMCLASS")) {
        g_setenv("SDL_VIDEO_X11_WMCLASS", "qemu", false);
    }
#endif
    if (SDL_Init(SDL_INIT_VIDEO)) {
        fprintf(stderr, "Could not initialize SDL(%s) - exiting\n",
                SDL_GetError());
        exit(1);
    }
    /*
     * SDL2 enables desktop text input during video initialization.  That is
     * correct for a native text field, but wrong for a graphic VM console:
     * IBus/Fcitx/host IMEs may consume key down/up events before QEMU can
     * forward their physical scancodes to the guest.  QEMU's SDL graphic and
     * built-in text consoles both have scancode/qcode paths, so keep SDL text
     * composition disabled for the lifetime of this backend.  Guest language
     * input remains entirely inside the guest OS.
     */
    sdl2_disable_host_text_input();
#ifdef SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR /* only available since SDL 2.0.8 */
    SDL_SetHint(SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0");
#endif
    SDL_SetHint(SDL_HINT_GRAB_KEYBOARD, "1");
#ifdef SDL_HINT_ALLOW_ALT_TAB_WHILE_GRABBED
    SDL_SetHint(SDL_HINT_ALLOW_ALT_TAB_WHILE_GRABBED, "0");
#endif
    SDL_SetHint(SDL_HINT_WINDOWS_NO_CLOSE_ON_ALT_F4, "1");
    sdl2_set_hint_x11_force_egl();
    memset(&info, 0, sizeof(info));
    SDL_VERSION(&info.version);

    gui_fullscreen = o->has_full_screen && o->full_screen;

    if (o->u.sdl.has_grab_mod) {
        if (o->u.sdl.grab_mod == HOT_KEY_MOD_LSHIFT_LCTRL_LALT) {
            alt_grab = true;
        } else if (o->u.sdl.grab_mod == HOT_KEY_MOD_RCTRL) {
            ctrl_grab = true;
        }
    }

    for (i = 0;; i++) {
        QemuConsole *con = qemu_console_lookup_by_index(i);
        if (!con) {
            break;
        }
    }
    if (o->u.sdl.has_single_console && o->u.sdl.single_console && i > 1) {
        info_report("sdl2: single-console mode keeps console 0 and skips "
                    "%d auxiliary consoles", i - 1);
        i = 1;
    }
    sdl2_num_outputs = i;
    if (sdl2_num_outputs == 0) {
        return;
    }
    sdl2_apply_host_display_sleep_policy();
    sdl2_console = g_new0(struct sdl2_console, sdl2_num_outputs);

    /* Listener registration may immediately replay a guest cursor. */
    sdl_cursor_hidden = SDL_CreateCursor(&data, &data, 8, 1, 0, 0);
    sdl_cursor_normal = SDL_GetCursor();
    sdl_cursor_windows = sdl2_create_windows_cursor();

    for (i = 0; i < sdl2_num_outputs; i++) {
        QemuConsole *con = qemu_console_lookup_by_index(i);
        assert(con != NULL);
        if (!qemu_console_is_graphic(con) &&
            qemu_console_get_index(con) != 0) {
            sdl2_console[i].hidden = true;
        }
        sdl2_console[i].idx = i;
        sdl2_console[i].opts = o;
        /*
         * fixed is the launcher/default policy: keep the visible SDL swap
         * cadence at 60 Hz even when the guest framebuffer is unchanged.
         * dynamic preserves the old damage-driven Present behaviour for
         * later optimisation and A/B comparison.
         */
        sdl2_console[i].fixed_present =
            g_strcmp0(g_getenv("QEMU_SDL_PRESENT_MODE"), "dynamic") != 0;
#ifdef CONFIG_OPENGL
        sdl2_console[i].opengl = display_opengl;
        sdl2_console[i].dcl.ops = display_opengl ? &dcl_gl_ops : &dcl_2d_ops;
        sdl2_console[i].dgc.ops = display_opengl ? &gl_ctx_ops : NULL;
#else
        sdl2_console[i].opengl = 0;
        sdl2_console[i].dcl.ops = &dcl_2d_ops;
#endif
        sdl2_console[i].dcl.con = con;
        sdl2_console[i].absolute_enabled = qemu_input_is_absolute(con);
        sdl2_console[i].absolute_available = qemu_input_has_absolute(con);
        sdl2_console[i].kbd = qkbd_state_init(con);
#ifdef CONFIG_OPENGL
        if (display_opengl) {
            qemu_console_set_display_gl_ctx(con, &sdl2_console[i].dgc);
            sdl2_gl_console_init(&sdl2_console[i]);
        }
#endif
        sdl2_console[i].dcl.update_interval_ns =
            SDL2_REFRESH_INTERVAL_ACTIVE_NS;
        register_displaychangelistener(&sdl2_console[i].dcl);

#if defined(SDL_VIDEO_DRIVER_WINDOWS) || defined(SDL_VIDEO_DRIVER_X11)
        if (SDL_GetWindowWMInfo(sdl2_console[i].real_window, &info)) {
#if defined(SDL_VIDEO_DRIVER_WINDOWS)
            qemu_console_set_window_id(con, (uintptr_t)info.info.win.window);
#elif defined(SDL_VIDEO_DRIVER_X11)
            qemu_console_set_window_id(con, info.info.x11.window);
#endif
        }
#endif
    }

#ifdef CONFIG_SDL_IMAGE
    dir = get_relocated_path(CONFIG_QEMU_ICONDIR "/hicolor/128x128/apps/qemu.png");
    icon = IMG_Load(dir);
#else
    /* Load a 32x32x4 image. White pixels are transparent. */
    dir = get_relocated_path(CONFIG_QEMU_ICONDIR "/hicolor/32x32/apps/qemu.bmp");
    icon = SDL_LoadBMP(dir);
    if (icon) {
        uint32_t colorkey = SDL_MapRGB(icon->format, 255, 255, 255);
        SDL_SetColorKey(icon, SDL_TRUE, colorkey);
    }
#endif
    g_free(dir);
    if (icon) {
        SDL_SetWindowIcon(sdl2_console[0].real_window, icon);
    }

    mouse_mode_notifier.notify = sdl_mouse_mode_change;
    qemu_add_mouse_mode_change_notifier(&mouse_mode_notifier);

    for (i = 0; i < sdl2_num_outputs; i++) {
        if (sdl_cursor_is_active(&sdl2_console[i]) &&
            sdl2_console[i].absolute_available) {
            sdl_apply_active_cursor(&sdl2_console[i]);
        }
        sdl_sync_keyboard_grab(&sdl2_console[i]);
    }

    if (sdl2_num_outputs > 0) {
        sdl2_gnome_guard_update(&sdl2_console[0]);
    }

    if (gui_fullscreen) {
        sdl_grab_start(&sdl2_console[0]);
    }

    atexit(sdl_cleanup);

    /* SDL polling must stay on the main thread, but it must not wait behind a
     * heavy guest display refresh.  This timer only drains SDL events. */
    sdl2_input_timer = timer_new_ms(QEMU_CLOCK_REALTIME,
                                    sdl2_input_timer_cb, NULL);
    timer_mod(sdl2_input_timer,
              qemu_clock_get_ms(QEMU_CLOCK_REALTIME) +
              SDL2_INPUT_POLL_INTERVAL_ACTIVE_MS);
    qemu_main = NULL;
}

static QemuDisplay qemu_display_sdl2 = {
    .type       = DISPLAY_TYPE_SDL,
    .early_init = sdl2_display_early_init,
    .init       = sdl2_display_init,
};

static void register_sdl1(void)
{
    qemu_display_register(&qemu_display_sdl2);
}

type_init(register_sdl1);

#ifdef CONFIG_OPENGL
module_dep("ui-opengl");
#endif

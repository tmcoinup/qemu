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
/*
 * Direct QEMU invocation defaults to host.  The G-11 launcher opts into auto,
 * which hides the host fallback only after an exact, host-side confirmation
 * that the configured Windows arrow was composited into the REGION primary
 * framebuffer near a recent left-button pointer position.
 */
typedef enum SDL2CursorMode {
    SDL2_CURSOR_MODE_HOST,
    SDL2_CURSOR_MODE_GUEST,
    SDL2_CURSOR_MODE_AUTO,
} SDL2CursorMode;

static SDL2CursorMode sdl2_cursor_mode;
static SDL2CursorTemplate sdl2_framebuffer_cursor_template;
static bool sdl2_framebuffer_cursor_template_valid;
#define SDL2_CURSOR_FRAME_MAX_AGE_US (500 * 1000)
#define SDL2_CURSOR_FRAME_SEARCH_RADIUS 2
#define SDL2_CURSOR_FRAME_MISS_LIMIT 2
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
static bool sdl2_gnome_guard_desired;
static bool sdl2_gnome_guard_running;
static bool sdl2_gnome_guard_child_tame;
static GPid sdl2_gnome_guard_pid;
static guint sdl2_gnome_guard_watch_id;
static guint sdl2_gnome_guard_timeout_id;
static uint64_t sdl2_gnome_guard_serial;
static uint64_t sdl2_gnome_guard_started_serial;
static bool sdl2_live_title_fps;

static bool sdl2_env_enabled(const char *name)
{
    const char *value = g_getenv(name);

    return value &&
           (g_ascii_strcasecmp(value, "1") == 0 ||
            g_ascii_strcasecmp(value, "yes") == 0 ||
            g_ascii_strcasecmp(value, "true") == 0 ||
            g_ascii_strcasecmp(value, "on") == 0);
}

static const char *sdl2_cursor_mode_name(void)
{
    switch (sdl2_cursor_mode) {
    case SDL2_CURSOR_MODE_AUTO:
        return "auto-framebuffer-confirmed";
    case SDL2_CURSOR_MODE_GUEST:
        return "guest-preferred";
    case SDL2_CURSOR_MODE_HOST:
    default:
        return "host";
    }
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

static void sdl2_gnome_guard_start(void);

static gboolean sdl2_gnome_guard_timeout(gpointer opaque)
{
    (void)opaque;
    sdl2_gnome_guard_timeout_id = 0;
    if (sdl2_gnome_guard_running && sdl2_gnome_guard_pid) {
        warn_report("sdl2: GNOME shortcut guard exceeded 5 seconds; "
                    "terminating helper without blocking input");
        kill(sdl2_gnome_guard_pid, SIGKILL);
    }
    return G_SOURCE_REMOVE;
}

static void sdl2_gnome_guard_child_watch(GPid pid, gint status,
                                         gpointer opaque)
{
    const char *action = sdl2_gnome_guard_child_tame ? "tame" : "restore";
    bool ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;

    (void)opaque;
    if (sdl2_gnome_guard_timeout_id) {
        g_source_remove(sdl2_gnome_guard_timeout_id);
        sdl2_gnome_guard_timeout_id = 0;
    }
    g_spawn_close_pid(pid);
    sdl2_gnome_guard_pid = 0;
    sdl2_gnome_guard_watch_id = 0;
    sdl2_gnome_guard_running = false;

    if (ok) {
        sdl2_gnome_guard_active = sdl2_gnome_guard_child_tame;
    } else {
        /*
         * A failed tame may already have changed a subset of settings.  Mark
         * it active so the next focus loss/shutdown always attempts restore.
         */
        sdl2_gnome_guard_active |= sdl2_gnome_guard_child_tame;
        warn_report("sdl2: GNOME shortcut guard %s failed with status %d",
                    action, status);
    }

    /*
     * Focus may have changed while the helper was running.  Serialize the
     * opposite action after it; never let stale tame/restore work win.
     */
    if (sdl2_gnome_guard_active != sdl2_gnome_guard_desired &&
        sdl2_gnome_guard_started_serial != sdl2_gnome_guard_serial) {
        sdl2_gnome_guard_start();
    }
}

static void sdl2_gnome_guard_start(void)
{
    const char *action;
    gchar *argv[4];
    GError *err = NULL;

    if (sdl2_gnome_guard_running ||
        sdl2_gnome_guard_active == sdl2_gnome_guard_desired ||
        !sdl2_gnome_guard_script || !sdl2_gnome_guard_state) {
        return;
    }

    sdl2_gnome_guard_child_tame = sdl2_gnome_guard_desired;
    action = sdl2_gnome_guard_child_tame ? "tame" : "restore";
    sdl2_gnome_guard_started_serial = sdl2_gnome_guard_serial;
    argv[0] = (gchar *)sdl2_gnome_guard_script;
    argv[1] = (gchar *)action;
    argv[2] = sdl2_gnome_guard_state;
    argv[3] = NULL;

    /*
     * gsettings/GIO can take seconds when the session bus is unhealthy.  It
     * must never run synchronously from SDL's focus/input event path.
     */
    if (!g_spawn_async(NULL, argv, NULL,
                       G_SPAWN_DO_NOT_REAP_CHILD |
                       G_SPAWN_STDOUT_TO_DEV_NULL |
                       G_SPAWN_STDERR_TO_DEV_NULL,
                       NULL, NULL, &sdl2_gnome_guard_pid, &err)) {
        warn_report("sdl2: cannot start GNOME shortcut guard %s: %s",
                    action, err ? err->message : "unknown error");
        g_clear_error(&err);
        sdl2_gnome_guard_pid = 0;
        return;
    }
    sdl2_gnome_guard_running = true;
    sdl2_gnome_guard_watch_id = g_child_watch_add(
        sdl2_gnome_guard_pid, sdl2_gnome_guard_child_watch, NULL);
    sdl2_gnome_guard_timeout_id = g_timeout_add_seconds(
        5, sdl2_gnome_guard_timeout, NULL);
}

static void sdl2_gnome_guard_set(bool want)
{
    if (want != sdl2_gnome_guard_desired) {
        sdl2_gnome_guard_desired = want;
        sdl2_gnome_guard_serial++;
    }
    if (!sdl2_gnome_guard_running &&
        sdl2_gnome_guard_active != sdl2_gnome_guard_desired &&
        sdl2_gnome_guard_started_serial != sdl2_gnome_guard_serial) {
        sdl2_gnome_guard_start();
    }
}

static void sdl2_gnome_guard_shutdown(void)
{
    gchar *argv[4];
    GError *err = NULL;
    int status;

    sdl2_gnome_guard_desired = false;
    if (sdl2_gnome_guard_watch_id) {
        g_source_remove(sdl2_gnome_guard_watch_id);
        sdl2_gnome_guard_watch_id = 0;
    }
    if (sdl2_gnome_guard_timeout_id) {
        g_source_remove(sdl2_gnome_guard_timeout_id);
        sdl2_gnome_guard_timeout_id = 0;
    }
    if (sdl2_gnome_guard_running && sdl2_gnome_guard_pid) {
        kill(sdl2_gnome_guard_pid, SIGKILL);
        while (waitpid(sdl2_gnome_guard_pid, &status, 0) < 0 &&
               errno == EINTR) {
            /* retry */
        }
        g_spawn_close_pid(sdl2_gnome_guard_pid);
        sdl2_gnome_guard_pid = 0;
        sdl2_gnome_guard_running = false;
    }

    /*
     * Never turn a normal QEMU exit into an unbounded DBus/GSettings wait.
     * Fire an idempotent restore helper and let the launcher trap provide a
     * second restore-stale layer after the QEMU process exits.
     */
    if (sdl2_gnome_guard_script && sdl2_gnome_guard_state) {
        argv[0] = (gchar *)sdl2_gnome_guard_script;
        argv[1] = (gchar *)"restore";
        argv[2] = sdl2_gnome_guard_state;
        argv[3] = NULL;
        if (!g_spawn_async(NULL, argv, NULL,
                           G_SPAWN_STDOUT_TO_DEV_NULL |
                           G_SPAWN_STDERR_TO_DEV_NULL,
                           NULL, NULL, NULL, &err)) {
            warn_report("sdl2: cannot start final GNOME shortcut restore: %s",
                        err ? err->message : "unknown error");
            g_clear_error(&err);
        }
        sdl2_gnome_guard_active = false;
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
#define SDL2_INPUT_POLL_INTERVAL_ACTIVE_MS 2
#define SDL2_INPUT_POLL_INTERVAL_BACKGROUND_MS 32
#define SDL2_EVENT_POLL_MAX 1024
#define SDL2_EVENT_POLL_BUDGET_US 2000
#define SDL2_FPS_STABLE_MIN_FRAMES 30
#define SDL2_FPS_LOW_WARMUP_WINDOWS 2
#define SDL2_WINDOW_RETRY_FAST_US 100000
#define SDL2_WINDOW_RETRY_SLOW_US 1000000
#define SDL2_WINDOW_RETRY_FAST_ATTEMPTS 5

static uint64_t sdl2_refresh_interval_active_ns =
    SDL2_REFRESH_INTERVAL_ACTIVE_NS;
static uint32_t sdl2_input_poll_interval_active_ms =
    SDL2_INPUT_POLL_INTERVAL_ACTIVE_MS;

static uint32_t sdl2_parse_timing_env(const char *name, uint32_t fallback,
                                      uint32_t minimum, uint32_t maximum)
{
    const char *value = g_getenv(name);
    unsigned int parsed;

    if (!value || !*value) {
        return fallback;
    }
    if (qemu_strtoui(value, NULL, 10, &parsed) < 0 ||
        parsed < minimum || parsed > maximum) {
        warn_report("sdl2: ignoring invalid %s=%s (expected %u..%u)",
                    name, value, minimum, maximum);
        return fallback;
    }
    return parsed;
}

static void sdl2_init_timing_policy(void)
{
    uint32_t target_fps = sdl2_parse_timing_env(
        "QEMU_SDL_TARGET_FPS", 60, 30, 240);

    sdl2_input_poll_interval_active_ms = sdl2_parse_timing_env(
        "QEMU_SDL_INPUT_POLL_MS", SDL2_INPUT_POLL_INTERVAL_ACTIVE_MS, 1, 16);
    sdl2_refresh_interval_active_ns = DIV_ROUND_UP(
        (uint64_t)NANOSECONDS_PER_SECOND, target_fps);
    info_report("sdl2: timing profile target=%u FPS input-poll=%u ms",
                target_fps, sdl2_input_poll_interval_active_ms);
}

static void sdl2_init_cursor_policy(void)
{
    const char *mode = g_getenv("QEMU_SDL_CURSOR_MODE");

    if (!mode || !*mode || g_ascii_strcasecmp(mode, "host") == 0) {
        sdl2_cursor_mode = SDL2_CURSOR_MODE_HOST;
    } else if (g_ascii_strcasecmp(mode, "guest") == 0) {
        sdl2_cursor_mode = SDL2_CURSOR_MODE_GUEST;
    } else if (g_ascii_strcasecmp(mode, "auto") == 0) {
        sdl2_cursor_mode = SDL2_CURSOR_MODE_AUTO;
    } else {
        warn_report("sdl2: ignoring invalid QEMU_SDL_CURSOR_MODE=%s "
                    "(expected host, guest or auto); using host", mode);
        sdl2_cursor_mode = SDL2_CURSOR_MODE_HOST;
    }
    info_report("sdl2: cursor policy %s", sdl2_cursor_mode_name());
}

static void sdl2_init_title_fps_policy(const char *video_driver)
{
    const char *mode = g_getenv("QEMU_SDL_TITLE_FPS");
    bool wayland = g_strcmp0(video_driver, "wayland") == 0;

    if (!mode || !*mode || g_ascii_strcasecmp(mode, "auto") == 0) {
        /*
         * SDL's Wayland backend normally uses libdecor-gtk on GNOME.  That
         * plugin destroys and rebuilds an offscreen GtkHeaderBar whenever
         * SDL_SetWindowTitle() changes the title.  GTK 3 can then query a
         * monitor that has already been detached and emit dozens of
         * GDK_IS_MONITOR assertions for one title change.  The FPS sample is
         * refreshed once per second, turning the otherwise benign GTK bug
         * into an unbounded QEMU log storm.  Keep the stable VM title unless
         * the launcher selected the Cairo libdecor plugin explicitly.
         */
        sdl2_live_title_fps = !wayland;
    } else if (g_ascii_strcasecmp(mode, "1") == 0 ||
               g_ascii_strcasecmp(mode, "yes") == 0 ||
               g_ascii_strcasecmp(mode, "true") == 0 ||
               g_ascii_strcasecmp(mode, "on") == 0) {
        sdl2_live_title_fps = true;
    } else if (g_ascii_strcasecmp(mode, "0") == 0 ||
               g_ascii_strcasecmp(mode, "no") == 0 ||
               g_ascii_strcasecmp(mode, "false") == 0 ||
               g_ascii_strcasecmp(mode, "off") == 0) {
        sdl2_live_title_fps = false;
    } else {
        warn_report("sdl2: ignoring invalid QEMU_SDL_TITLE_FPS=%s "
                    "(expected auto or 0/1)", mode);
        sdl2_live_title_fps = !wayland;
    }

    info_report("sdl2: live Content/Present title %s%s",
                sdl2_live_title_fps ? "enabled" : "disabled",
                wayland && !sdl2_live_title_fps ?
                " (Wayland libdecor-gtk safety fallback)" : "");
}

/* introduced in SDL 2.0.10 */
#ifndef SDL_HINT_RENDER_BATCHING
#define SDL_HINT_RENDER_BATCHING "SDL_RENDER_BATCHING"
#endif
#ifdef CONFIG_OPENGL
static bool sdl2_native_egl_disabled;
static bool sdl2_native_egl_committed;
static bool sdl2_native_egl_poisoned;
#ifdef CONFIG_X11
static Display *sdl2_native_egl_x_display;
#endif

static bool sdl2_native_egl_provider_locked(void)
{
    return sdl2_native_egl_committed || sdl2_native_egl_poisoned;
}

static bool sdl2_native_egl_provider_error(EGLint error)
{
    return error == EGL_CONTEXT_LOST || error == EGL_BAD_CONTEXT ||
           error == EGL_BAD_DISPLAY || error == EGL_NOT_INITIALIZED;
}

static bool sdl2_native_egl_window_error(EGLint error)
{
    return sdl2_native_egl_provider_error(error) ||
           error == EGL_BAD_SURFACE ||
           error == EGL_BAD_CURRENT_SURFACE ||
           error == EGL_BAD_NATIVE_WINDOW ||
           error == EGL_BAD_MATCH || error == EGL_BAD_CONFIG;
}

static bool sdl2_should_use_native_egl(void)
{
    const char *enabled = g_getenv("QEMU_SDL_NATIVE_EGL");

    /*
     * 中文注释：SDL/GLX 是稳定默认路径；native EGL 仍处于 SDL 后端内的
     * 实验路径，只在显式环境开关下启用。这样可以继续修 SDL+EGL+dmbuf，
     * 同时避免普通本地窗口被不成熟路径影响。
     */
    return sdl2_native_egl_provider_locked() ||
           (!sdl2_native_egl_disabled &&
           (g_strcmp0(enabled, "1") == 0 ||
           g_strcmp0(enabled, "true") == 0 ||
           g_strcmp0(enabled, "on") == 0));
}

static bool sdl2_window_destroy_native_egl(struct sdl2_console *scon,
                                           bool keep_context)
{
#ifdef CONFIG_X11
    SDL_SysWMinfo info;
    Display *dpy = NULL;
    EGLint error;

    if (scon->native_egl_ui_tid &&
        scon->native_egl_ui_tid != qemu_get_thread_id()) {
        warn_report("sdl2-egl: refusing window teardown outside UI thread %d",
                    scon->native_egl_ui_tid);
        return false;
    }
    if (scon->native_egl_owner_tid &&
        scon->native_egl_owner_tid != qemu_get_thread_id()) {
        warn_report("sdl2-egl: refusing window teardown while context is "
                    "owned by thread %d", scon->native_egl_owner_tid);
        return false;
    }
    if ((scon->ectx != EGL_NO_CONTEXT ||
         scon->esurface != EGL_NO_SURFACE) &&
        qemu_egl_display == EGL_NO_DISPLAY) {
        warn_report("sdl2-egl: refusing window teardown without EGL display");
        return false;
    }
    if (scon->native_egl_window || scon->native_egl_colormap) {
        memset(&info, 0, sizeof(info));
        SDL_VERSION(&info.version);
        if (!SDL_GetWindowWMInfo(scon->real_window, &info)) {
            warn_report("sdl2-egl: cannot resolve X11 display for teardown");
            return false;
        }
        if (info.subsystem != SDL_SYSWM_X11) {
            warn_report("sdl2-egl: refusing X11 teardown for a non-X11 "
                        "SDL window");
            return false;
        }
        if (!info.info.x11.display) {
            warn_report("sdl2-egl: cannot resolve X11 display for teardown");
            return false;
        }
        dpy = info.info.x11.display;
    }
    if (qemu_egl_display != EGL_NO_DISPLAY &&
        scon->ectx != EGL_NO_CONTEXT &&
        eglGetCurrentContext() == scon->ectx) {
        if (!eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE,
                            EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
            error = eglGetError();
            warn_report("sdl2-egl: cannot release current context before "
                        "window teardown (EGL=0x%x)", error);
            return false;
        } else {
            scon->native_egl_owner_tid = 0;
        }
    }
    if (scon->esurface != EGL_NO_SURFACE) {
        if (!eglDestroySurface(qemu_egl_display, scon->esurface)) {
            error = eglGetError();
            warn_report("sdl2-egl: cannot destroy window surface "
                        "(EGL=0x%x)", error);
            return false;
        }
        scon->esurface = EGL_NO_SURFACE;
    }
    if (!keep_context && scon->ectx != EGL_NO_CONTEXT) {
        if (!eglDestroyContext(qemu_egl_display, scon->ectx)) {
            error = eglGetError();
            warn_report("sdl2-egl: cannot destroy window context "
                        "(EGL=0x%x)", error);
            return false;
        }
        scon->ectx = EGL_NO_CONTEXT;
    }
    if (dpy) {
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
    scon->native_egl_owner_tid = 0;
    scon->native_egl = false;
    if (!keep_context) {
        scon->native_egl_ui_tid = 0;
    }
#endif
    return true;
}

static bool sdl2_window_init_native_egl(struct sdl2_console *scon,
                                        EGLint *error)
{
#ifdef CONFIG_X11
    SDL_SysWMinfo info;
    EGLint visual_id = 0;
    Display *dpy = NULL;
    Window parent;
    Window child;
    Colormap colormap;
    XVisualInfo tmpl;
    XVisualInfo *visuals;
    XSetWindowAttributes attrs;
    int nvisuals = 0;
    int ww;
    int wh;
    bool created_context = false;

    *error = EGL_SUCCESS;
    if (scon->ectx != EGL_NO_CONTEXT && scon->native_egl_ui_tid &&
        scon->native_egl_ui_tid != qemu_get_thread_id()) {
        error_report("sdl2-egl: window initialization must run on UI thread "
                     "%d", scon->native_egl_ui_tid);
        *error = EGL_BAD_ACCESS;
        return false;
    }

    memset(&info, 0, sizeof(info));
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(scon->real_window, &info)) {
        error_report("sdl2-egl: SDL_GetWindowWMInfo failed: %s",
                     SDL_GetError());
        *error = EGL_BAD_NATIVE_WINDOW;
        return false;
    }
    if (info.subsystem != SDL_SYSWM_X11) {
        error_report("sdl2-egl: native EGL requires an X11 SDL window");
        *error = EGL_BAD_NATIVE_WINDOW;
        return false;
    }
    if (!info.info.x11.display || !info.info.x11.window) {
        error_report("sdl2-egl: SDL window is not an X11 window; "
                     "native EGL requires SDL_VIDEODRIVER=x11/DISPLAY");
        *error = EGL_BAD_NATIVE_WINDOW;
        return false;
    }
    dpy = info.info.x11.display;
    parent = info.info.x11.window;
    if (sdl2_native_egl_provider_locked() &&
        (dpy != sdl2_native_egl_x_display ||
         (scon->opts->gl != qemu_egl_mode &&
          !(scon->opts->gl == DISPLAY_GL_MODE_ON &&
            (qemu_egl_mode == DISPLAY_GL_MODE_CORE ||
             qemu_egl_mode == DISPLAY_GL_MODE_ES))))) {
        error_report("sdl2-egl: SDL consoles cannot mix EGL displays, "
                     "configs, or client APIs");
        *error = EGL_BAD_MATCH;
        return false;
    }
    if (scon->ectx == EGL_NO_CONTEXT &&
        !sdl2_native_egl_provider_locked()) {
        if (qemu_egl_init_dpy_x11(dpy, scon->opts->gl) < 0) {
            *error = eglGetError();
            if (*error == EGL_SUCCESS) {
                *error = EGL_NOT_INITIALIZED;
            }
            return false;
        }
        sdl2_native_egl_x_display = dpy;
    }
    if (!eglGetConfigAttrib(qemu_egl_display, qemu_egl_config,
                            EGL_NATIVE_VISUAL_ID, &visual_id)) {
        error_report("sdl2-egl: EGL config has no X11 native visual");
        *error = eglGetError();
        if (*error == EGL_SUCCESS) {
            *error = EGL_BAD_MATCH;
        }
        return false;
    }
    if (!visual_id) {
        error_report("sdl2-egl: EGL config has no X11 native visual");
        *error = EGL_BAD_MATCH;
        return false;
    }

    memset(&tmpl, 0, sizeof(tmpl));
    tmpl.visualid = visual_id;
    tmpl.screen = DefaultScreen(dpy);
    visuals = XGetVisualInfo(dpy, VisualIDMask | VisualScreenMask,
                             &tmpl, &nvisuals);
    if (!visuals || nvisuals < 1) {
        error_report("sdl2-egl: no X visual for EGL visual 0x%x", visual_id);
        *error = EGL_BAD_MATCH;
        return false;
    }

    SDL_GetWindowSize(scon->real_window, &ww, &wh);
    ww = MAX(ww, 1);
    wh = MAX(wh, 1);
    colormap = XCreateColormap(dpy, parent, visuals[0].visual, AllocNone);
    if (!colormap) {
        error_report("sdl2-egl: cannot create X11 colormap");
        *error = EGL_BAD_ALLOC;
        XFree(visuals);
        return false;
    }
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
    if (!child) {
        error_report("sdl2-egl: cannot create X11 child window");
        *error = EGL_BAD_NATIVE_WINDOW;
        XFreeColormap(dpy, colormap);
        XFree(visuals);
        return false;
    }
    XMapWindow(dpy, child);
    XRaiseWindow(dpy, child);
    XFlush(dpy);
    XSync(dpy, False);
    XFree(visuals);
    scon->native_egl_window = (uintptr_t)child;
    scon->native_egl_colormap = (uintptr_t)colormap;

    if (scon->ectx == EGL_NO_CONTEXT) {
        scon->ectx = qemu_egl_init_ctx();
        if (!scon->ectx) {
            *error = eglGetError();
            if (*error == EGL_SUCCESS) {
                *error = EGL_BAD_CONTEXT;
            }
            return false;
        }
        created_context = true;
    }
    scon->esurface = qemu_egl_init_surface_x11(
        scon->ectx, (EGLNativeWindowType)child);
    if (!scon->esurface) {
        *error = eglGetError();
        if (*error == EGL_SUCCESS) {
            *error = EGL_BAD_SURFACE;
        }
        sdl2_window_destroy_native_egl(scon, !created_context);
        return false;
    }

    /*
     * The GUI timer is the only frame pacer.  A driver-default interval of
     * one can block the QEMU main loop at eglSwapBuffers(), delaying display,
     * keyboard and mouse processing together (and can phase-lock near 30Hz).
     */
    if (!eglSwapInterval(qemu_egl_display, 0)) {
        EGLint swap_error = eglGetError();

        warn_report("sdl2-egl: cannot disable swap interval; input latency "
                    "may increase (EGL=0x%x)", swap_error);
        if (sdl2_native_egl_window_error(swap_error)) {
            *error = swap_error;
            sdl2_window_destroy_native_egl(scon, !created_context);
            return false;
        }
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
        *error = eglGetError();
        error_report("sdl2-egl: cannot release context after window init "
                     "(EGL=0x%x)", *error);
        sdl2_window_destroy_native_egl(scon, !created_context);
        return false;
    }
    scon->native_egl_owner_tid = 0;
    scon->native_egl_ui_tid = qemu_get_thread_id();

    /*
     * Linux/X11 下 SDL 只负责窗口和输入；GL context/surface 由 QEMU EGL
     * helpers 创建。这样本地 SDL 窗口保留，同时 fb-shm 的 texture→dma-buf
     * 导出和 direct dma-buf import 都使用同一个可控 EGL provider。
    */
    scon->native_egl = true;
    if (created_context && !scon->native_egl_context_api) {
        scon->native_egl_context_lost = false;
    }
    scon->native_egl_recovery_pending = false;
    scon->native_egl_recovery_after_us = 0;
    scon->native_egl_recovery_attempts = 0;
    scon->native_egl_last_error = EGL_SUCCESS;
    scon->native_egl_context_api = true;
    sdl2_native_egl_committed = true;
    sdl2_native_egl_x_display = dpy;
    if (!scon->logged_native_egl_visual) {
        info_report("sdl2: native EGL context active for SDL window "
                    "(parent=0x%lx child=0x%lx egl_visual=0x%x)",
                    (unsigned long)parent, (unsigned long)child, visual_id);
        scon->logged_native_egl_visual = true;
    }
    return true;
#else
    *error = EGL_BAD_NATIVE_WINDOW;
    return false;
#endif
}

bool sdl2_window_recreate_native_egl_surface(struct sdl2_console *scon,
                                             EGLint *error)
{
#ifdef CONFIG_X11
    SDL_SysWMinfo info;
    EGLSurface candidate = EGL_NO_SURFACE;
    EGLSurface old_surface;
    EGLint visual_id = 0;
    XVisualInfo tmpl;
    XVisualInfo *visuals = NULL;
    XSetWindowAttributes attrs;
    Display *dpy = NULL;
    Window parent;
    Window child = 0;
    Window old_child;
    Colormap colormap = 0;
    Colormap old_colormap;
    bool released;
    bool old_surface_destroyed = true;
    EGLint candidate_error = EGL_SUCCESS;
    int nvisuals = 0;
    int ww;
    int wh;

    *error = EGL_SUCCESS;
    if (!scon->native_egl || !scon->real_window ||
        scon->ectx == EGL_NO_CONTEXT ||
        scon->native_egl_ui_tid != qemu_get_thread_id() ||
        (scon->native_egl_owner_tid &&
         scon->native_egl_owner_tid != qemu_get_thread_id())) {
        *error = EGL_BAD_ACCESS;
        return false;
    }

    memset(&info, 0, sizeof(info));
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(scon->real_window, &info)) {
        *error = EGL_BAD_NATIVE_WINDOW;
        return false;
    }
    if (info.subsystem != SDL_SYSWM_X11) {
        *error = EGL_BAD_NATIVE_WINDOW;
        return false;
    }
    if (!info.info.x11.display || !info.info.x11.window) {
        *error = EGL_BAD_NATIVE_WINDOW;
        return false;
    }
    dpy = info.info.x11.display;
    parent = info.info.x11.window;
    if (!eglGetConfigAttrib(qemu_egl_display, qemu_egl_config,
                            EGL_NATIVE_VISUAL_ID, &visual_id)) {
        *error = eglGetError();
        return false;
    }
    if (!visual_id) {
        *error = EGL_BAD_MATCH;
        return false;
    }

    memset(&tmpl, 0, sizeof(tmpl));
    tmpl.visualid = visual_id;
    tmpl.screen = DefaultScreen(dpy);
    visuals = XGetVisualInfo(dpy, VisualIDMask | VisualScreenMask,
                             &tmpl, &nvisuals);
    if (!visuals || nvisuals < 1) {
        *error = EGL_BAD_MATCH;
        goto fail;
    }

    SDL_GetWindowSize(scon->real_window, &ww, &wh);
    ww = MAX(ww, 1);
    wh = MAX(wh, 1);
    colormap = XCreateColormap(dpy, parent, visuals[0].visual, AllocNone);
    if (!colormap) {
        *error = EGL_BAD_ALLOC;
        goto fail;
    }
    memset(&attrs, 0, sizeof(attrs));
    attrs.colormap = colormap;
    attrs.border_pixel = 0;
    attrs.event_mask = 0;
    child = XCreateWindow(dpy, parent, 0, 0, ww, wh, 0,
                          visuals[0].depth, InputOutput, visuals[0].visual,
                          CWBorderPixel | CWColormap | CWEventMask, &attrs);
    XFree(visuals);
    visuals = NULL;
    if (!child) {
        *error = EGL_BAD_NATIVE_WINDOW;
        goto fail;
    }
    candidate = eglCreateWindowSurface(qemu_egl_display, qemu_egl_config,
                                       (EGLNativeWindowType)child, NULL);
    if (candidate == EGL_NO_SURFACE) {
        *error = eglGetError();
        goto fail;
    }
    if (!eglMakeCurrent(qemu_egl_display, candidate, candidate, scon->ectx)) {
        *error = eglGetError();
        goto fail;
    }
    scon->native_egl_owner_tid = qemu_get_thread_id();
    if (!eglSwapInterval(qemu_egl_display, 0)) {
        EGLint swap_error = eglGetError();

        warn_report("sdl2-egl: cannot disable swap interval after recovery; "
                    "input latency may increase (EGL=0x%x)", swap_error);
        if (sdl2_native_egl_window_error(swap_error)) {
            candidate_error = swap_error;
        }
    }
    released = eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE,
                              EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (!released) {
        /*
         * The candidate is current and therefore cannot be rolled back by
         * destroying its X window.  Adopt it, retain explicit ownership, and
         * return the unbind error so the caller can back off or fail safe.
         */
        *error = eglGetError();
    } else if (candidate_error != EGL_SUCCESS) {
        *error = candidate_error;
    }

    old_surface = scon->esurface;
    old_child = (Window)scon->native_egl_window;
    old_colormap = (Colormap)scon->native_egl_colormap;
    scon->esurface = candidate;
    scon->native_egl_window = (uintptr_t)child;
    scon->native_egl_colormap = (uintptr_t)colormap;
    scon->native_egl_owner_tid = released ? 0 : qemu_get_thread_id();
    if (old_surface != EGL_NO_SURFACE &&
        !eglDestroySurface(qemu_egl_display, old_surface)) {
        EGLint destroy_error = eglGetError();

        old_surface_destroyed = false;
        warn_report("sdl2-egl: retired surface cleanup failed; retaining "
                    "its X11 resources (EGL=0x%x)", destroy_error);
        if (sdl2_native_egl_provider_error(destroy_error) &&
            *error == EGL_SUCCESS) {
            *error = destroy_error;
        }
    }
    if (old_surface_destroyed && old_child) {
        XDestroyWindow(dpy, old_child);
    }
    if (old_surface_destroyed && old_colormap) {
        XFreeColormap(dpy, old_colormap);
    }
    XMapWindow(dpy, child);
    XRaiseWindow(dpy, child);
    XFlush(dpy);
    sdl2_pointer_geometry_changed(scon);
    return released && *error == EGL_SUCCESS;

fail:
    if (candidate != EGL_NO_SURFACE) {
        eglDestroySurface(qemu_egl_display, candidate);
    }
    if (child) {
        XDestroyWindow(dpy, child);
    }
    if (colormap) {
        XFreeColormap(dpy, colormap);
    }
    if (visuals) {
        XFree(visuals);
    }
    if (dpy) {
        XFlush(dpy);
    }
    return false;
#else
    *error = EGL_BAD_NATIVE_WINDOW;
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
    if (!SDL_GetWindowWMInfo(scon->real_window, &info)) {
        return;
    }
    if (info.subsystem != SDL_SYSWM_X11) {
        return;
    }
    if (!info.info.x11.display) {
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
    sdl2_pointer_geometry_changed(scon);
#endif
}
#endif

static void sdl_update_caption(struct sdl2_console *scon);
static void sdl_grab_end(struct sdl2_console *scon);
static void sdl_show_cursor(struct sdl2_console *scon);
static void sdl2_deactivate_input(struct sdl2_console *scon);

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

static void sdl2_init_framebuffer_cursor_template(SDL_Surface *surface,
                                                  int hot_x, int hot_y)
{
    SDL_Surface *rgba;
    bool locked = false;

    memset(&sdl2_framebuffer_cursor_template, 0,
           sizeof(sdl2_framebuffer_cursor_template));
    sdl2_framebuffer_cursor_template_valid = false;

    rgba = SDL_ConvertSurfaceFormat(surface, SDL_PIXELFORMAT_RGBA32, 0);
    if (!rgba) {
        warn_report("sdl2: cannot prepare framebuffer cursor template: %s",
                    SDL_GetError());
        return;
    }
    if (SDL_MUSTLOCK(rgba)) {
        if (SDL_LockSurface(rgba) != 0) {
            warn_report("sdl2: cannot lock framebuffer cursor template: %s",
                        SDL_GetError());
            SDL_FreeSurface(rgba);
            return;
        }
        locked = true;
    }

    sdl2_framebuffer_cursor_template_valid =
        sdl2_cursor_template_init_rgba(
            &sdl2_framebuffer_cursor_template, rgba->pixels,
            rgba->w, rgba->h, rgba->pitch, hot_x, hot_y);
    if (locked) {
        SDL_UnlockSurface(rgba);
    }
    SDL_FreeSurface(rgba);

    if (sdl2_framebuffer_cursor_template_valid) {
        info_report("sdl2: framebuffer cursor template ready "
                    "(%u dark, %u light samples)",
                    sdl2_framebuffer_cursor_template.dark_count,
                    sdl2_framebuffer_cursor_template.light_count);
    } else if (sdl2_cursor_mode == SDL2_CURSOR_MODE_AUTO) {
        warn_report("sdl2: cursor auto mode unavailable: configured cursor "
                    "does not provide a safe 32x32 arrow template; "
                    "using host fallback");
    }
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
        sdl2_init_framebuffer_cursor_template(surface, hot_x, hot_y);
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
    SDL_Window *window = SDL_GetWindowFromID(window_id);
    int i;

    /*
     * A stale event may refer to a window that SDL already destroyed.  Do
     * not let its NULL lookup match an uncreated console.
     */
    if (!window) {
        return NULL;
    }

    for (i = 0; i < sdl2_num_outputs; i++) {
        if (sdl2_console[i].real_window == window) {
            return &sdl2_console[i];
        }
    }
    return NULL;
}

static void sdl2_sync_focus_from_window(struct sdl2_console *scon)
{
    Uint32 flags;

    if (!scon->real_window) {
        scon->has_input_focus = false;
        scon->has_mouse_focus = false;
        return;
    }
    flags = SDL_GetWindowFlags(scon->real_window);
    scon->has_input_focus = !!(flags & SDL_WINDOW_INPUT_FOCUS);
    scon->has_mouse_focus = !!(flags & SDL_WINDOW_MOUSE_FOCUS);
}

static void sdl2_window_create_failed(struct sdl2_console *scon,
                                      const char *operation)
{
    if (!scon->warned_window_create) {
        warn_report("sdl2: %s failed; retrying with bounded backoff: %s",
                    operation, SDL_GetError());
        scon->warned_window_create = true;
    }
    if (scon->window_create_attempts != UINT8_MAX) {
        scon->window_create_attempts++;
    }
    scon->window_create_retry_pending = true;
    scon->window_create_after_us =
        g_get_monotonic_time() +
        (scon->window_create_attempts <= SDL2_WINDOW_RETRY_FAST_ATTEMPTS ?
         SDL2_WINDOW_RETRY_FAST_US : SDL2_WINDOW_RETRY_SLOW_US);
    scon->window_redraw_pending = true;
}

static void sdl2_window_create_recovered(struct sdl2_console *scon)
{
    if (scon->warned_window_create) {
        info_report("sdl2: window/renderer creation recovered");
    }
    scon->window_create_retry_pending = false;
    scon->window_create_after_us = 0;
    scon->window_create_attempts = 0;
    scon->warned_window_create = false;
}

void sdl2_window_create(struct sdl2_console *scon)
{
    int flags = 0;
#ifdef CONFIG_OPENGL
    bool native_egl = false;
    EGLint native_egl_error = EGL_SUCCESS;
#endif

#ifdef CONFIG_OPENGL
    if (scon->opengl && sdl2_gl_native_egl_provider_failed()) {
        scon->native_egl_context_lost = true;
        return;
    }
    if (scon->opengl && scon->native_egl_context_lost) {
        return;
    }
    if (scon->opengl && scon->native_egl_recovery_pending) {
        if (g_get_monotonic_time() < scon->native_egl_recovery_after_us) {
            return;
        }
        scon->native_egl_recovery_pending = false;
        scon->native_egl_recovery_after_us = 0;
    }
#endif
    if (scon->window_create_retry_pending) {
        if (g_get_monotonic_time() < scon->window_create_after_us) {
            return;
        }
        scon->window_create_retry_pending = false;
        scon->window_create_after_us = 0;
    }
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
        native_egl = scon->native_egl_context_api ||
                     sdl2_should_use_native_egl();
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

    g_clear_pointer(&scon->last_window_title, g_free);
    scon->real_window = SDL_CreateWindow("", SDL_WINDOWPOS_UNDEFINED,
                                         SDL_WINDOWPOS_UNDEFINED,
                                         surface_width(scon->surface),
                                         surface_height(scon->surface),
                                         flags);
    if (!scon->real_window) {
        sdl2_window_create_failed(scon, "SDL window creation");
        return;
    }
    /*
     * 窗口刚创建时, SDL 不一定补发 FOCUS_GAINED/ENTER (取决于 WM 和指针位置),
     * 直接拿 SDL 当前 flag 做初值, 避免冷启动后 sdl2_input_allowed 永远 false.
     */
    sdl2_sync_focus_from_window(scon);
#ifdef CONFIG_OPENGL
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
            if (!sdl2_window_init_native_egl(scon, &native_egl_error)) {
                bool cleaned = sdl2_window_destroy_native_egl(
                    scon, scon->native_egl_context_api);

                if (!cleaned) {
                    sdl2_native_egl_poisoned = true;
                    sdl2_gl_native_egl_init_failed(
                        scon,
                        sdl2_native_egl_provider_error(native_egl_error) ?
                        native_egl_error : EGL_CONTEXT_LOST);
                    error_report("sdl2-egl: native EGL init failed and its "
                                 "context could not be safely released");
                    return;
                }
                SDL_DestroyWindow(scon->real_window);
                scon->real_window = NULL;
                if (scon->native_egl_context_api ||
                    sdl2_native_egl_provider_locked()) {
                    sdl2_gl_native_egl_init_failed(scon, native_egl_error);
                    warn_report("sdl2-egl: native EGL reinitialization "
                                "failed (EGL=0x%x); retaining the process "
                                "EGL provider without an unsafe GLX switch",
                                native_egl_error);
                    scon->window_redraw_pending = true;
                    return;
                }
                warn_report("sdl2-egl: native EGL init failed; "
                            "falling back to SDL GLX for this process");
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
                sdl2_window_create_failed(scon,
                                          "SDL GL context creation");
                SDL_DestroyWindow(scon->real_window);
                scon->real_window = NULL;
                return;
            }
            if (SDL_GL_MakeCurrent(scon->real_window, scon->winctx) != 0) {
                sdl2_window_create_failed(scon,
                                          "SDL GL context activation");
                SDL_GL_DeleteContext(scon->winctx);
                scon->winctx = NULL;
                SDL_DestroyWindow(scon->real_window);
                scon->real_window = NULL;
                return;
            }
            if (SDL_GL_SetSwapInterval(0) != 0) {
                warn_report("sdl2: cannot disable GL swap interval: %s; "
                            "input latency may increase", SDL_GetError());
            }
        }
        if (!native_egl && !scon->winctx) {
            sdl2_window_create_failed(scon,
                                      "SDL GL context validation");
            SDL_DestroyWindow(scon->real_window);
            scon->real_window = NULL;
            return;
        }
#ifdef CONFIG_OPENGL
        if (!native_egl) {
            qemu_egl_display = eglGetCurrentDisplay();
        }
#endif
    } else
#endif
    {
        /* The SDL renderer is only used by sdl2-2D, when OpenGL is disabled */
        scon->real_renderer = SDL_CreateRenderer(
            scon->real_window, -1, SDL_RENDERER_ACCELERATED);
        if (!scon->real_renderer) {
            scon->real_renderer = SDL_CreateRenderer(
                scon->real_window, -1, SDL_RENDERER_SOFTWARE);
        }
        if (!scon->real_renderer) {
            sdl2_window_create_failed(scon, "SDL 2D renderer creation");
            SDL_DestroyWindow(scon->real_window);
            scon->real_window = NULL;
            return;
        }
    }

    sdl2_window_create_recovered(scon);
    sdl2_pointer_geometry_changed(scon);
    sdl2_window_update_size_limits(scon);
    sdl_update_caption(scon);
}

void sdl2_window_destroy(struct sdl2_console *scon)
{
#ifdef CONFIG_OPENGL
    bool has_native_provider;
#endif
    bool was_grabbed;

    if (!scon->real_window) {
        return;
    }

#ifdef CONFIG_OPENGL
    has_native_provider = scon->native_egl_context_api ||
                          scon->ectx != EGL_NO_CONTEXT ||
                          scon->esurface != EGL_NO_SURFACE ||
                          scon->native_egl_window ||
                          scon->native_egl_colormap;
    if (has_native_provider) {
        /*
         * Keep the root EGL context as a provider-lifetime share-group
         * anchor.  virgl/fb-shm contexts and cached dma-buf textures may
         * outlive this SDL window and cannot be migrated to a new share group.
         */
        if (!sdl2_window_destroy_native_egl(
                scon, scon->native_egl_context_api)) {
            error_report("sdl2-egl: keeping the SDL window because its EGL "
                         "context could not be safely released");
            return;
        }
    } else {
        if (scon->opengl) {
            sdl2_gl_window_context_destroying(scon);
        }
    }
#endif
    was_grabbed = sdl_console_is_grabbed(scon);
    sdl2_deactivate_input(scon);
    if (was_grabbed) {
        sdl_grab_end(scon);
    } else if (!grabbed_scon) {
        /*
         * SDL cursor visibility is process-global; never destroy its active
         * owner while leaving the host pointer hidden for another window.
         */
        sdl_show_cursor(scon);
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
    g_clear_pointer(&scon->last_window_title, g_free);
    scon->window_resize_pending = false;
    scon->window_maximum = (SDL2Size) { 0 };
    sdl2_pointer_geometry_changed(scon);
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
    sdl2_pointer_geometry_changed(scon);
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
    char fps_status[128] = "";
    const char *status = "";
    const char *title_name = qemu_name;
    bool title_is_explicit = false;
    const char *cursor_status = "";

    if (sdl2_cursor_mode == SDL2_CURSOR_MODE_AUTO) {
        cursor_status = sdl2_framebuffer_cursor_template_valid ?
            " | Cursor: auto" :
            " | Cursor: auto unavailable (host fallback)";
    } else if (sdl2_cursor_mode == SDL2_CURSOR_MODE_GUEST) {
        cursor_status = scon->guest_cursor && scon->guest_sprite ?
            " | Cursor: guest-only (guest sprite)" :
            " | Cursor: guest unavailable (host fallback)";
    }

    if (scon->present_fps_valid && sdl2_live_title_fps) {
        snprintf(fps_status, sizeof(fps_status),
                 " | Content %.1f/s | Present %.1f/s (%s)",
                 scon->content_fps, scon->present_fps,
                 scon->fixed_present ? "fixed" : "dynamic");
    }

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
        snprintf(win_title, sizeof(win_title), "%s%s%s%s",
                 title_name, fps_status, cursor_status, status);
        snprintf(icon_title, sizeof(icon_title), "%s", title_name);
    } else if (title_is_explicit) {
        /*
         * QEMU can expose hidden firmware/text consoles in the same SDL
         * process.  Keep their names outside the primary instance contract,
         * otherwise an exact `win10-N` lookup would map every console.
         */
        snprintf(win_title, sizeof(win_title), "%s-console-%d%s%s%s",
                 title_name, scon->idx, fps_status, cursor_status, status);
        snprintf(icon_title, sizeof(icon_title), "%s-console-%d",
                 title_name, scon->idx);
    } else if (title_name) {
        snprintf(win_title, sizeof(win_title), "QEMU (%s-%d)%s%s%s",
                 title_name, scon->idx, fps_status, cursor_status, status);
        snprintf(icon_title, sizeof(icon_title), "QEMU (%s)", title_name);
    } else {
        snprintf(win_title, sizeof(win_title), "QEMU%s%s%s",
                 fps_status, cursor_status, status);
        snprintf(icon_title, sizeof(icon_title), "QEMU");
    }

    if (scon->real_window &&
        g_strcmp0(scon->last_window_title, win_title) != 0) {
        SDL_SetWindowTitle(scon->real_window, win_title);
        g_free(scon->last_window_title);
        scon->last_window_title = g_strdup(win_title);
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
            scon->content_frame_count = 0;
            scon->fps_window_start_us = now_us;
            return;
        }
        scon->fps_low_warmup_windows = 0;
        scon->present_fps = (double)scon->fps_frame_count * G_USEC_PER_SEC /
                            elapsed_us;
        scon->content_fps =
            (double)scon->content_frame_count * G_USEC_PER_SEC / elapsed_us;
        scon->fps_frame_count = 0;
        scon->content_frame_count = 0;
        scon->fps_window_start_us = now_us;
        scon->present_fps_valid = true;
        if (sdl2_live_title_fps) {
            sdl_update_caption(scon);
        }
    }
}

static void sdl2_present_rate_reset(struct sdl2_console *scon)
{
    scon->fps_window_start_us = 0;
    scon->fps_frame_count = 0;
    scon->content_frame_count = 0;
    scon->present_fps = 0.0;
    scon->content_fps = 0.0;
    scon->present_fps_valid = false;
    scon->presented_since_refresh = false;
    scon->content_update_pending = false;
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

void sdl2_note_content_update(struct sdl2_console *scon)
{
    if (scon->manual_redraw || scon->content_update_pending) {
        return;
    }
    if (!scon->fps_window_start_us) {
        scon->fps_window_start_us = g_get_monotonic_time();
    }
    scon->content_frame_count++;
    scon->content_update_pending = true;
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

    /* An authoritative QEMU cursor shape is the only safe guest-only path. */
    if (scon->guest_cursor && scon->guest_sprite) {
        SDL_SetRelativeMouseMode(SDL_FALSE);
        SDL_SetCursor(scon->guest_sprite);
        SDL_ShowCursor(SDL_ENABLE);
        return;
    }

    if (sdl2_cursor_mode == SDL2_CURSOR_MODE_AUTO &&
        scon->framebuffer_cursor_visible) {
        SDL_SetRelativeMouseMode(SDL_FALSE);
        SDL_SetCursor(sdl_cursor_hidden);
        SDL_ShowCursor(SDL_DISABLE);
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

void sdl2_framebuffer_cursor_reset(struct sdl2_console *scon)
{
    bool was_visible;

    if (!scon) {
        return;
    }
    was_visible = scon->framebuffer_cursor_visible;
    sdl2_cursor_history_reset(&scon->framebuffer_cursor_history);
    scon->framebuffer_cursor_visible = false;
    scon->framebuffer_cursor_miss_frames = 0;
    if (was_visible && sdl_cursor_is_active(scon)) {
        sdl_apply_active_cursor(scon);
    }
}

void sdl2_framebuffer_cursor_update(struct sdl2_console *scon)
{
    DisplaySurface *surface;
    bool matched;
    int matched_x = 0;
    int matched_y = 0;

    if (!scon) {
        return;
    }
    surface = scon->surface;
    if (sdl2_cursor_mode != SDL2_CURSOR_MODE_AUTO ||
        !sdl2_framebuffer_cursor_template_valid ||
        !sdl_cursor_is_active(scon) ||
        !qemu_input_has_absolute(scon->dcl.con) ||
        !(scon->mouse_button_state & SDL_BUTTON_LMASK) ||
        (scon->guest_cursor && scon->guest_sprite) || !surface ||
        (surface_format(surface) != PIXMAN_x8r8g8b8 &&
         surface_format(surface) != PIXMAN_a8r8g8b8)) {
        sdl2_framebuffer_cursor_reset(scon);
        return;
    }

    matched = sdl2_cursor_history_match_xrgb8888(
        &sdl2_framebuffer_cursor_template,
        &scon->framebuffer_cursor_history,
        surface_data(surface), surface_width(surface), surface_height(surface),
        surface_stride(surface), g_get_monotonic_time(),
        SDL2_CURSOR_FRAME_MAX_AGE_US, SDL2_CURSOR_FRAME_SEARCH_RADIUS,
        &matched_x, &matched_y);
    if (matched) {
        scon->framebuffer_cursor_miss_frames = 0;
        if (!scon->framebuffer_cursor_visible) {
            scon->framebuffer_cursor_visible = true;
            if (!scon->logged_framebuffer_cursor_match) {
                info_report("sdl2: confirmed composited REGION cursor at "
                            "%d,%d; suppressing host fallback while held",
                            matched_x, matched_y);
                scon->logged_framebuffer_cursor_match = true;
            }
            if (sdl_cursor_is_active(scon)) {
                sdl_apply_active_cursor(scon);
            }
        }
        return;
    }

    if (scon->framebuffer_cursor_visible &&
        ++scon->framebuffer_cursor_miss_frames >=
            SDL2_CURSOR_FRAME_MISS_LIMIT) {
        sdl2_framebuffer_cursor_reset(scon);
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

void sdl2_pointer_geometry_changed(struct sdl2_console *scon)
{
    if (!scon) {
        return;
    }
    scon->pointer_geometry_valid = false;
    sdl_reset_relative_motion(scon);
}

static void sdl_release_mouse_buttons(struct sdl2_console *scon)
{
    if (!scon) {
        return;
    }

    sdl2_framebuffer_cursor_reset(scon);
    if (!scon->mouse_button_state) {
        return;
    }

    qemu_input_update_buttons(scon->dcl.con, sdl_button_map,
                              scon->mouse_button_state, 0);
    scon->mouse_button_state = 0;
    qemu_input_event_sync();
}

static void sdl2_deactivate_input(struct sdl2_console *scon)
{
    if (!scon) {
        return;
    }

    scon->has_input_focus = false;
    scon->has_mouse_focus = false;
    sdl2_release_modifiers(scon);
    sdl_release_mouse_buttons(scon);
    sdl_reset_relative_motion(scon);
    sdl_sync_keyboard_grab(scon);
}

static bool sdl_pointer_geometry(struct sdl2_console *scon,
                                 SDL2Size *window, SDL2Size *render,
                                 SDL2Size *guest, SDL2Rect *dst)
{
    if (!scon->pointer_geometry_valid) {
        SDL_GetWindowSize(scon->real_window,
                          &scon->pointer_window.width,
                          &scon->pointer_window.height);
        if (scon->pointer_window.width <= 0 ||
            scon->pointer_window.height <= 0 ||
            !sdl2_current_render_size(scon, &scon->pointer_render) ||
            !sdl2_current_guest_size(scon, &scon->pointer_guest)) {
            return false;
        }

        scon->pointer_dst = sdl2_guest_dst_rect(scon->pointer_render,
                                                scon->pointer_guest);
        if (scon->pointer_dst.width <= 0 || scon->pointer_dst.height <= 0) {
            return false;
        }
        scon->pointer_geometry_valid = true;
    }

    *window = scon->pointer_window;
    *render = scon->pointer_render;
    *guest = scon->pointer_guest;
    *dst = scon->pointer_dst;
    return true;
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
    if (scon->guest_cursor &&
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
    if (sdl2_cursor_mode == SDL2_CURSOR_MODE_AUTO &&
        (state & SDL_BUTTON_LMASK)) {
        sdl2_cursor_history_record(&scon->framebuffer_cursor_history,
                                   guest_point.x, guest_point.y,
                                   g_get_monotonic_time());
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
    sdl2_pointer_geometry_changed(scon);
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
    return scon && scon->real_window && scon->has_input_focus &&
           sdl2_window_updates_allowed(
               SDL_GetWindowFlags(scon->real_window), scon->hidden);
}

static bool sdl2_pointer_input_allowed(struct sdl2_console *scon)
{
    return sdl2_keyboard_input_allowed(scon) &&
           (scon->has_mouse_focus || sdl_console_is_grabbed(scon));
}
static void handle_keydown(SDL_Event *ev)
{
    int i;
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
            if (sdl2_cursor_mode == SDL2_CURSOR_MODE_AUTO) {
                sdl2_cursor_mode = SDL2_CURSOR_MODE_HOST;
            } else if (sdl2_cursor_mode == SDL2_CURSOR_MODE_HOST) {
                sdl2_cursor_mode = SDL2_CURSOR_MODE_GUEST;
            } else {
                sdl2_cursor_mode = SDL2_CURSOR_MODE_AUTO;
            }
            for (i = 0; i < sdl2_num_outputs; i++) {
                struct sdl2_console *candidate = &sdl2_console[i];

                sdl2_framebuffer_cursor_reset(candidate);
                if (sdl_cursor_is_active(candidate)) {
                    sdl_apply_active_cursor(candidate);
                }
                sdl_update_caption(candidate);
            }
            info_report("sdl2: cursor policy %s (runtime toggle)",
                        sdl2_cursor_mode_name());
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
            if (bev->button == SDL_BUTTON_LEFT) {
                sdl2_framebuffer_cursor_reset(scon);
            }
        } else {
            buttonstate &= ~SDL_BUTTON(bev->button);
        }
        sdl_send_mouse_event(scon, 0, 0, bev->x, bev->y, buttonstate);
        if (ev->type == SDL_MOUSEBUTTONUP &&
            bev->button == SDL_BUTTON_LEFT) {
            sdl2_framebuffer_cursor_reset(scon);
        }
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
        sdl2_pointer_geometry_changed(scon);
        scon->window_redraw_pending = true;
        break;
    case SDL_WINDOWEVENT_EXPOSED:
        scon->window_redraw_pending = true;
        break;
#if SDL_VERSION_ATLEAST(2, 0, 18)
    case SDL_WINDOWEVENT_DISPLAY_CHANGED:
        sdl2_window_update_size_limits(scon);
        sdl2_pointer_geometry_changed(scon);
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
        sdl2_deactivate_input(scon);
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
         * Pointer leave does not imply keyboard focus loss.  Release pointer
         * state here; FOCUS_LOST or a visibility change lifts held keys.
         */
        scon->has_mouse_focus = false;
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
        if (ev->window.event == SDL_WINDOWEVENT_RESTORED) {
            sdl2_sync_focus_from_window(scon);
        }
        sdl_sync_keyboard_grab(scon);
        if (scon->window_resize_pending) {
            sdl2_window_resize(scon);
        }
        scon->window_redraw_pending = true;
        update_displaychangelistener_ns(
            &scon->dcl, sdl2_refresh_interval_active_ns);
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
        sdl2_deactivate_input(scon);
        if (!grabbed_scon || sdl_console_is_grabbed(scon)) {
            SDL_SetRelativeMouseMode(SDL_FALSE);
        }
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
            scon->hidden = true;
            sdl2_deactivate_input(scon);
            SDL_HideWindow(scon->real_window);
        }
        break;
    case SDL_WINDOWEVENT_SHOWN:
        scon->hidden = false;
        sdl2_sync_focus_from_window(scon);
        sdl_sync_keyboard_grab(scon);
        update_displaychangelistener_ns(
            &scon->dcl, sdl2_refresh_interval_active_ns);
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
        sdl2_deactivate_input(scon);
        if (!grabbed_scon || sdl_console_is_grabbed(scon)) {
            SDL_SetRelativeMouseMode(SDL_FALSE);
        }
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
            /*
             * SDL may deliver SHOWN/RESTORED before its window flags expose
             * the new mapped state.  Preserve the redraw latch for the next
             * tick; explicit HIDDEN/MINIMIZED events already discard it.
             */
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
    int64_t poll_started_us = g_get_monotonic_time();
    int64_t poll_deadline_us = poll_started_us + SDL2_EVENT_POLL_BUDGET_US;
    unsigned int event_count = 0;
    int idle = 1;

    /* Keep the title truthful when REGION frame dedup suppresses every swap. */
    sdl2_present_rate_tick(scon);

    if (scon->last_vm_running != runstate_is_running()) {
        scon->last_vm_running = runstate_is_running();
        sdl_update_caption(scon);
    }

    /*
     * A mouse/resize event storm must not monopolize QEMU's main loop and
     * starve VFIO display refreshes for seconds.  Drain a large but bounded
     * batch, then let the 2 ms input timer pick up the remaining events.
     */
    while (event_count < SDL2_EVENT_POLL_MAX && SDL_PollEvent(ev)) {
        event_count++;
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
            event_count += sdl2_coalesce_mouse_motion(
                ev, SDL2_EVENT_POLL_MAX - event_count, poll_deadline_us);
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
        if (g_get_monotonic_time() >= poll_deadline_us) {
            break;
        }
    }

    if (!idle) {
        scon->idle_counter = 0;
    }
    if (!scon->hidden && scon->real_window &&
        !(SDL_GetWindowFlags(scon->real_window) & SDL_WINDOW_MINIMIZED)) {
        if (scon->dcl.update_interval_ns !=
            sdl2_refresh_interval_active_ns) {
            update_displaychangelistener_ns(
                &scon->dcl, sdl2_refresh_interval_active_ns);
        }
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
            return sdl2_input_poll_interval_active_ms;
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

    if (sdl2_cursor_mode == SDL2_CURSOR_MODE_AUTO) {
        sdl2_framebuffer_cursor_reset(scon);
    }
    scon->guest_cursor = on;
    scon->guest_x = x;
    scon->guest_y = y;

    if (sdl2_cursor_mode == SDL2_CURSOR_MODE_GUEST) {
        sdl_update_caption(scon);
    }

    if (!sdl_cursor_is_active(scon)) {
        return;
    }

    sdl_apply_active_cursor(scon);
    if (on && sdl_console_is_grabbed(scon) &&
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
        if (sdl_cursor_is_active(scon)) {
            sdl_apply_active_cursor(scon);
        }
        if (sdl2_cursor_mode == SDL2_CURSOR_MODE_GUEST) {
            sdl_update_caption(scon);
        }
        return;
    }
    scon->guest_sprite = SDL_CreateColorCursor(scon->guest_sprite_surface,
                                               c->hot_x, c->hot_y);
    if (!scon->guest_sprite) {
        fprintf(stderr, "Failed to make color cursor from %p\n", c);
        if (sdl_cursor_is_active(scon)) {
            sdl_apply_active_cursor(scon);
        }
        if (sdl2_cursor_mode == SDL2_CURSOR_MODE_GUEST) {
            sdl_update_caption(scon);
        }
        return;
    }
    if (sdl_cursor_is_active(scon)) {
        sdl_apply_active_cursor(scon);
    }
    if (sdl2_cursor_mode == SDL2_CURSOR_MODE_GUEST) {
        sdl_update_caption(scon);
    }
}

static void sdl_cleanup(void)
{
    int i;

    if (sdl2_input_timer) {
        timer_free(sdl2_input_timer);
        sdl2_input_timer = NULL;
    }

    /*
     * Restore the desktop pointer before freeing a possibly-current guest
     * sprite or shutting down SDL.
     */
    SDL_SetRelativeMouseMode(SDL_FALSE);
    if (sdl_cursor_normal) {
        SDL_SetCursor(sdl_cursor_normal);
    }
    SDL_ShowCursor(SDL_ENABLE);

    for (i = 0; i < sdl2_num_outputs; i++) {
        if (sdl2_console[i].guest_sprite) {
            SDL_FreeCursor(sdl2_console[i].guest_sprite);
        }
        if (sdl2_console[i].guest_sprite_surface) {
            SDL_FreeSurface(sdl2_console[i].guest_sprite_surface);
        }
        g_clear_pointer(&sdl2_console[i].last_window_title, g_free);
    }
    if (sdl_cursor_windows) {
        SDL_FreeCursor(sdl_cursor_windows);
        sdl_cursor_windows = NULL;
    }
    sdl2_gnome_guard_shutdown();
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
        sdl2_deactivate_input(scon);
        if (!grabbed_scon || sdl_console_is_grabbed(scon)) {
            SDL_SetRelativeMouseMode(SDL_FALSE);
        }
        if (!grabbed_scon || sdl_console_is_grabbed(scon)) {
            sdl_show_cursor(scon);
        }
        SDL_HideWindow(scon->real_window);
    } else {
        scon->hidden = false;
        update_displaychangelistener_ns(
            &scon->dcl, sdl2_refresh_interval_active_ns);
        SDL_ShowWindow(scon->real_window);
        sdl2_sync_focus_from_window(scon);
        sdl_sync_keyboard_grab(scon);
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
     * Only a successfully probed native EGL provider can import dma-buf.
     * The dummy probe destroys its window but retains the share-group anchor,
     * so capability cannot depend on the transient native_egl/window state.
     * The default SDL_GL/GLX path must still report false.
     */
    return scon->native_egl_context_api && scon->has_dmabuf &&
           !scon->native_egl_context_lost &&
           !sdl2_gl_native_egl_provider_failed();
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
    const char *video_driver;
    SDL_SysWMinfo info;
    SDL_Surface *icon = NULL;
    char *dir;

    assert(o->type == DISPLAY_TYPE_SDL);

    sdl2_init_timing_policy();
    sdl2_init_cursor_policy();

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
    video_driver = SDL_GetCurrentVideoDriver();
    info_report("sdl2: SDL video driver=%s",
                video_driver ? video_driver : "unknown");
    sdl2_init_title_fps_policy(video_driver);
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
            sdl2_refresh_interval_active_ns;
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
              sdl2_input_poll_interval_active_ms);
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

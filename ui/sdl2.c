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
#include "sysemu/runstate.h"
#include "sysemu/runstate-action.h"
#include "sysemu/sysemu.h"
#include "ui/win32-kbd-hook.h"
#include "qemu/error-report.h"
#include "qemu/log.h"
#ifdef CONFIG_X11
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#endif

static int sdl2_num_outputs;
static struct sdl2_console *sdl2_console;

static SDL_Surface *guest_sprite_surface;
static int gui_grab; /* if true, all keyboard/mouse events are grabbed */
static bool alt_grab;
static bool ctrl_grab;

static int gui_saved_grab;
static int gui_fullscreen;
static int gui_grab_code = KMOD_LALT | KMOD_LCTRL;
static SDL_Cursor *sdl_cursor_normal;
static SDL_Cursor *sdl_cursor_hidden;
static int absolute_enabled;
static bool guest_cursor;
static int guest_x, guest_y;
static SDL_Cursor *guest_sprite;
static Notifier mouse_mode_notifier;

#define SDL2_REFRESH_INTERVAL_BUSY 10
#define SDL2_MAX_IDLE_COUNT (2 * GUI_REFRESH_INTERVAL_DEFAULT \
                             / SDL2_REFRESH_INTERVAL_BUSY + 1)

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

    if (!scon->native_egl || !scon->native_egl_window || !scon->real_window) {
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
    } else {
        /* The SDL renderer is only used by sdl2-2D, when OpenGL is disabled */
        scon->real_renderer = SDL_CreateRenderer(scon->real_window, -1, 0);
    }
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
}

void sdl2_window_resize(struct sdl2_console *scon)
{
    if (!scon->real_window) {
        return;
    }

    SDL_SetWindowSize(scon->real_window,
                      surface_width(scon->surface),
                      surface_height(scon->surface));
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

    if (!runstate_is_running()) {
        status = " [Stopped]";
    } else if (gui_grab) {
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

    if (qemu_name) {
        snprintf(win_title, sizeof(win_title), "QEMU (%s-%d)%s", qemu_name,
                 scon->idx, status);
        snprintf(icon_title, sizeof(icon_title), "QEMU (%s)", qemu_name);
    } else {
        snprintf(win_title, sizeof(win_title), "QEMU%s", status);
        snprintf(icon_title, sizeof(icon_title), "QEMU");
    }

    if (scon->real_window) {
        SDL_SetWindowTitle(scon->real_window, win_title);
    }
}

static void sdl_hide_cursor(struct sdl2_console *scon)
{
    if (scon->opts->has_show_cursor && scon->opts->show_cursor) {
        return;
    }

    SDL_ShowCursor(SDL_DISABLE);
    SDL_SetCursor(sdl_cursor_hidden);

    if (!qemu_input_is_absolute(scon->dcl.con)) {
        SDL_SetRelativeMouseMode(SDL_TRUE);
    }
}

static void sdl_show_cursor(struct sdl2_console *scon)
{
    if (scon->opts->has_show_cursor && scon->opts->show_cursor) {
        return;
    }

    if (!qemu_input_is_absolute(scon->dcl.con)) {
        SDL_SetRelativeMouseMode(SDL_FALSE);
    }

    if (guest_cursor &&
        (gui_grab || qemu_input_is_absolute(scon->dcl.con) || absolute_enabled)) {
        SDL_SetCursor(guest_sprite);
    } else {
        SDL_SetCursor(sdl_cursor_normal);
    }

    SDL_ShowCursor(SDL_ENABLE);
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
    if (guest_cursor) {
        SDL_SetCursor(guest_sprite);
        if (!qemu_input_is_absolute(scon->dcl.con) && !absolute_enabled) {
            SDL_WarpMouseInWindow(scon->real_window, guest_x, guest_y);
        }
    } else {
        sdl_hide_cursor(scon);
    }
    SDL_SetWindowGrab(scon->real_window, SDL_TRUE);
    gui_grab = 1;
    win32_kbd_set_grab(true);
    sdl_update_caption(scon);
}

static void sdl_grab_end(struct sdl2_console *scon)
{
    SDL_SetWindowGrab(scon->real_window, SDL_FALSE);
    gui_grab = 0;
    win32_kbd_set_grab(false);
    sdl_show_cursor(scon);
    sdl_update_caption(scon);
}

static void absolute_mouse_grab(struct sdl2_console *scon)
{
    int mouse_x, mouse_y;
    int scr_w, scr_h;
    SDL_GetMouseState(&mouse_x, &mouse_y);
    SDL_GetWindowSize(scon->real_window, &scr_w, &scr_h);
    if (mouse_x > 0 && mouse_x < scr_w - 1 &&
        mouse_y > 0 && mouse_y < scr_h - 1) {
        sdl_grab_start(scon);
    }
}

static void sdl_mouse_mode_change(Notifier *notify, void *data)
{
    if (qemu_input_is_absolute(sdl2_console[0].dcl.con)) {
        if (!absolute_enabled) {
            absolute_enabled = 1;
            SDL_SetRelativeMouseMode(SDL_FALSE);
            absolute_mouse_grab(&sdl2_console[0]);
        }
    } else if (absolute_enabled) {
        if (!gui_fullscreen) {
            sdl_grab_end(&sdl2_console[0]);
        }
        absolute_enabled = 0;
    }
}

static void sdl_send_mouse_event(struct sdl2_console *scon, int dx, int dy,
                                 int x, int y, int state)
{
    static uint32_t bmap[INPUT_BUTTON__MAX] = {
        [INPUT_BUTTON_LEFT]       = SDL_BUTTON(SDL_BUTTON_LEFT),
        [INPUT_BUTTON_MIDDLE]     = SDL_BUTTON(SDL_BUTTON_MIDDLE),
        [INPUT_BUTTON_RIGHT]      = SDL_BUTTON(SDL_BUTTON_RIGHT),
        [INPUT_BUTTON_SIDE]       = SDL_BUTTON(SDL_BUTTON_X1),
        [INPUT_BUTTON_EXTRA]      = SDL_BUTTON(SDL_BUTTON_X2)
    };
    static uint32_t prev_state;

    if (prev_state != state) {
        qemu_input_update_buttons(scon->dcl.con, bmap, prev_state, state);
        prev_state = state;
    }

    if (qemu_input_is_absolute(scon->dcl.con)) {
        /*
         * Both display paths letterbox the guest 1:1 inside the window
         * (sdl2_gfx_dst_rect(); the 2D path no longer sets an SDL logical
         * size, so x/y are window pixels in both cases).  Map the pointer
         * through the same centred rectangle and clamp it to the image so the
         * guest cursor tracks the visible picture and stops at the black
         * border.
         */
        int ww, wh, rx, ry, rw, rh;

        SDL_GetWindowSize(scon->real_window, &ww, &wh);
        sdl2_gfx_dst_rect(ww, wh,
                          surface_width(scon->surface),
                          surface_height(scon->surface),
                          &rx, &ry, &rw, &rh);
        x = MAX(rx, MIN(x, rx + rw));
        y = MAX(ry, MIN(y, ry + rh));
        qemu_input_queue_abs(scon->dcl.con, INPUT_AXIS_X, x, rx, rx + rw);
        qemu_input_queue_abs(scon->dcl.con, INPUT_AXIS_Y, y, ry, ry + rh);
    } else {
        if (guest_cursor) {
            x -= guest_x;
            y -= guest_y;
            guest_x += x;
            guest_y += y;
            dx = x;
            dy = y;
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
        gui_saved_grab = gui_grab;
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
 * 输入门控：键鼠事件只在窗口同时拥有 X11 输入焦点和鼠标焦点(指针在窗内)
 * 时才允许下发到 guest。任一条件失守, 上层 handle_xxx 直接丢事件。
 * 焦点状态在 handle_windowevent() 里随 FOCUS_GAINED/LOST 和 ENTER/LEAVE 维护,
 * 丢失瞬间统一调 sdl2_release_modifiers() 抬起全键, 避免 guest 卡键。
 */
static bool sdl2_input_allowed(struct sdl2_console *scon)
{
    return scon && scon->has_input_focus && scon->has_mouse_focus;
}

static void handle_keydown(SDL_Event *ev)
{
    int win;
    struct sdl2_console *scon = get_scon_from_window(ev->key.windowID);
    int gui_key_modifier_pressed = get_mod_state();

    if (!scon) {
        return;
    }
    /* 焦点 / 指针不在窗内时, KEYDOWN 一律丢. KEYUP 走 handle_keyup,
     * 由 qkbd_state_key_event 的 suspicious-keyup 过滤天然抹掉. */
    if (!sdl2_input_allowed(scon)) {
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
            if (gui_grab) {
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
            if (!gui_grab) {
                sdl_grab_start(scon);
            } else if (!gui_fullscreen) {
                sdl_grab_end(scon);
            }
            break;
        case SDL_SCANCODE_U:
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
    if (!sdl2_input_allowed(scon)) {
        return;
    }

    if (!scon->gui_keysym && QEMU_IS_TEXT_CONSOLE(con)) {
        qemu_text_console_put_string(QEMU_TEXT_CONSOLE(con), ev->text.text, strlen(ev->text.text));
    }
}

static void handle_mousemotion(SDL_Event *ev)
{
    int max_x, max_y;
    struct sdl2_console *scon = get_scon_from_window(ev->motion.windowID);

    if (!scon || !qemu_console_is_graphic(scon->dcl.con)) {
        return;
    }
    /* grab=on 时 SDL 把指针锁在窗内, sdl2_input_allowed 自然为真;
     * grab=off 且指针在窗外/无焦点时, 不把鼠标位置写进 guest. */
    if (!sdl2_input_allowed(scon)) {
        return;
    }

    if (qemu_input_is_absolute(scon->dcl.con) || absolute_enabled) {
        int scr_w, scr_h;
        SDL_GetWindowSize(scon->real_window, &scr_w, &scr_h);
        max_x = scr_w - 1;
        max_y = scr_h - 1;
        if (gui_grab && !gui_fullscreen
            && (ev->motion.x == 0 || ev->motion.y == 0 ||
                ev->motion.x == max_x || ev->motion.y == max_y)) {
            sdl_grab_end(scon);
        }
        if (!gui_grab &&
            (ev->motion.x > 0 && ev->motion.x < max_x &&
             ev->motion.y > 0 && ev->motion.y < max_y)) {
            sdl_grab_start(scon);
        }
    }
    if (gui_grab || qemu_input_is_absolute(scon->dcl.con) || absolute_enabled) {
        sdl_send_mouse_event(scon, ev->motion.xrel, ev->motion.yrel,
                             ev->motion.x, ev->motion.y, ev->motion.state);
    }
}

static void handle_mousebutton(SDL_Event *ev)
{
    int buttonstate = SDL_GetMouseState(NULL, NULL);
    SDL_MouseButtonEvent *bev;
    struct sdl2_console *scon = get_scon_from_window(ev->button.windowID);

    if (!scon || !qemu_console_is_graphic(scon->dcl.con)) {
        return;
    }
    if (!sdl2_input_allowed(scon)) {
        return;
    }

    bev = &ev->button;
    if (!gui_grab && !qemu_input_is_absolute(scon->dcl.con)) {
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
    if (!sdl2_input_allowed(scon)) {
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

static bool sdl2_confirm_close(SDL_Window *parent)
{
    /*
     * X 关闭一次会同时派 SDL_WINDOWEVENT_CLOSE + SDL_QUIT，多 console 的
     * poll 路径还可能再走一次；用 1.5s 时间窗复用上一次结果，避免连弹。
     */
    static Uint32 last_ticks;
    static bool last_answer;
    Uint32 now = SDL_GetTicks();
    if (last_ticks && now - last_ticks < 1500) {
        return last_answer;
    }

    const SDL_MessageBoxButtonData buttons[] = {
        { SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, 0, "取消 / Cancel" },
        { SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, 1, "关机 / Shutdown" },
    };
    const SDL_MessageBoxData mbox = {
        SDL_MESSAGEBOX_WARNING,
        parent,
        "QEMU",
        "确认关闭虚拟机吗？\n点击 Shutdown 将向 guest 发出关机请求。",
        SDL_arraysize(buttons),
        buttons,
        NULL,
    };
    int btn = -1;
    if (SDL_ShowMessageBox(&mbox, &btn) < 0) {
        last_answer = true;
    } else {
        last_answer = (btn == 1);
    }
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
        {
            QemuUIInfo info;
            memset(&info, 0, sizeof(info));
            info.width = ev->window.data1;
            info.height = ev->window.data2;
            dpy_set_ui_info(scon->dcl.con, &info, true);
        }
#ifdef CONFIG_OPENGL
        sdl2_window_sync_native_egl_child(scon);
#endif
        sdl2_redraw(scon);
        break;
    case SDL_WINDOWEVENT_EXPOSED:
        sdl2_redraw(scon);
        break;
    case SDL_WINDOWEVENT_FOCUS_GAINED:
        scon->has_input_focus = true;
        win32_kbd_set_grab(gui_grab);
        if (qemu_console_is_graphic(scon->dcl.con)) {
            win32_kbd_set_window(sdl2_win32_get_hwnd(scon));
        }
        /* fall through */
    case SDL_WINDOWEVENT_ENTER:
        if (ev->window.event == SDL_WINDOWEVENT_ENTER) {
            scon->has_mouse_focus = true;
        }
        if (!gui_grab && (qemu_input_is_absolute(scon->dcl.con) || absolute_enabled)) {
            absolute_mouse_grab(scon);
        }
        /* If a new console window opened using a hotkey receives the
         * focus, SDL sends another KEYDOWN event to the new window,
         * closing the console window immediately after.
         *
         * Work around this by ignoring further hotkey events until a
         * key is released.
         */
        scon->ignore_hotkeys = get_mod_state();
        break;
    case SDL_WINDOWEVENT_FOCUS_LOST:
        /* X11 输入焦点丢失 (alt-tab / WM 切窗 / 无 WM 时其他 client grab):
         * 抬掉所有按下的键, 防止 guest 卡在 "W 一直按住" 之类状态. */
        scon->has_input_focus = false;
        sdl2_release_modifiers(scon);
        if (qemu_console_is_graphic(scon->dcl.con)) {
            win32_kbd_set_window(NULL);
        }
        if (gui_grab && !gui_fullscreen) {
            sdl_grab_end(scon);
        }
        break;
    case SDL_WINDOWEVENT_LEAVE:
        /* 鼠标离开窗口: 用户要求"窗外按键不进 guest", 同样抬掉按下的键.
         * 不动 gui_grab (grab 状态下指针锁在窗内, 不会触发 LEAVE). */
        scon->has_mouse_focus = false;
        sdl2_release_modifiers(scon);
        break;
    case SDL_WINDOWEVENT_RESTORED:
#ifdef CONFIG_OPENGL
        sdl2_window_sync_native_egl_child(scon);
#endif
        sdl2_redraw(scon);
        update_displaychangelistener(&scon->dcl, GUI_REFRESH_INTERVAL_DEFAULT);
        break;
    case SDL_WINDOWEVENT_MINIMIZED:
        update_displaychangelistener(&scon->dcl, 500);
        break;
    case SDL_WINDOWEVENT_CLOSE:
        if (qemu_console_is_graphic(scon->dcl.con)) {
            if (scon->opts->has_window_close && !scon->opts->window_close) {
                allow_close = false;
            }
            if (allow_close && !sdl2_confirm_close(scon->real_window)) {
                allow_close = false;
            }
            if (allow_close) {
                shutdown_action = SHUTDOWN_ACTION_POWEROFF;
                qemu_system_shutdown_request(SHUTDOWN_CAUSE_HOST_UI);
            }
        } else {
            SDL_HideWindow(scon->real_window);
            scon->hidden = true;
        }
        break;
    case SDL_WINDOWEVENT_SHOWN:
        scon->hidden = false;
#ifdef CONFIG_OPENGL
        sdl2_window_sync_native_egl_child(scon);
#endif
        sdl2_redraw(scon);
        break;
    case SDL_WINDOWEVENT_HIDDEN:
        scon->hidden = true;
        break;
    }
}

void sdl2_poll_events(struct sdl2_console *scon)
{
    SDL_Event ev1, *ev = &ev1;
    bool allow_close = true;
    int idle = 1;

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
            if (allow_close && !sdl2_confirm_close(scon->real_window)) {
                allow_close = false;
            }
            if (allow_close) {
                shutdown_action = SHUTDOWN_ACTION_POWEROFF;
                qemu_system_shutdown_request(SHUTDOWN_CAUSE_HOST_UI);
            }
            break;
        case SDL_MOUSEMOTION:
            idle = 0;
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
        default:
            break;
        }
    }

    if (idle) {
        if (scon->idle_counter < SDL2_MAX_IDLE_COUNT) {
            scon->idle_counter++;
            if (scon->idle_counter >= SDL2_MAX_IDLE_COUNT) {
                scon->dcl.update_interval = GUI_REFRESH_INTERVAL_DEFAULT;
            }
        }
    } else {
        scon->idle_counter = 0;
        scon->dcl.update_interval = SDL2_REFRESH_INTERVAL_BUSY;
    }
}

static void sdl_mouse_warp(DisplayChangeListener *dcl,
                           int x, int y, bool on)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);

    if (!qemu_console_is_graphic(scon->dcl.con)) {
        return;
    }

    if (on) {
        if (!guest_cursor) {
            sdl_show_cursor(scon);
        }
        if (gui_grab || qemu_input_is_absolute(scon->dcl.con) || absolute_enabled) {
            SDL_SetCursor(guest_sprite);
            if (!qemu_input_is_absolute(scon->dcl.con) && !absolute_enabled) {
                SDL_WarpMouseInWindow(scon->real_window, x, y);
            }
        }
    } else if (gui_grab) {
        sdl_hide_cursor(scon);
    }
    guest_cursor = on;
    guest_x = x, guest_y = y;
}

static void sdl_mouse_define(DisplayChangeListener *dcl,
                             QEMUCursor *c)
{

    if (guest_sprite) {
        SDL_FreeCursor(guest_sprite);
    }

    if (guest_sprite_surface) {
        SDL_FreeSurface(guest_sprite_surface);
    }

    guest_sprite_surface =
        SDL_CreateRGBSurfaceFrom(c->data, c->width, c->height, 32, c->width * 4,
                                 0xff0000, 0x00ff00, 0xff, 0xff000000);

    if (!guest_sprite_surface) {
        fprintf(stderr, "Failed to make rgb surface from %p\n", c);
        return;
    }
    guest_sprite = SDL_CreateColorCursor(guest_sprite_surface,
                                         c->hot_x, c->hot_y);
    if (!guest_sprite) {
        fprintf(stderr, "Failed to make color cursor from %p\n", c);
        return;
    }
    if (guest_cursor &&
        (gui_grab || qemu_input_is_absolute(dcl->con) || absolute_enabled)) {
        SDL_SetCursor(guest_sprite);
    }
}

static void sdl_cleanup(void)
{
    if (guest_sprite) {
        SDL_FreeCursor(guest_sprite);
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
        SDL_HideWindow(scon->real_window);
    } else {
        SDL_ShowWindow(scon->real_window);
        graphic_hw_invalidate(dcl->con);
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

static void sdl2_display_init(DisplayState *ds, DisplayOptions *o)
{
    uint8_t data = 0;
    int i;
    SDL_SysWMinfo info;
    SDL_Surface *icon = NULL;
    char *dir;

    assert(o->type == DISPLAY_TYPE_SDL);

    if (SDL_GetHintBoolean("QEMU_ENABLE_SDL_LOGGING", SDL_FALSE)) {
        SDL_LogSetAllPriority(SDL_LOG_PRIORITY_VERBOSE);
    }

    if (SDL_Init(SDL_INIT_VIDEO)) {
        fprintf(stderr, "Could not initialize SDL(%s) - exiting\n",
                SDL_GetError());
        exit(1);
    }
#ifdef SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR /* only available since SDL 2.0.8 */
    SDL_SetHint(SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0");
#endif
#ifndef CONFIG_WIN32
    /* QEMU uses its own low level keyboard hook procedure on Windows */
    SDL_SetHint(SDL_HINT_GRAB_KEYBOARD, "1");
#endif
#ifdef SDL_HINT_ALLOW_ALT_TAB_WHILE_GRABBED
    SDL_SetHint(SDL_HINT_ALLOW_ALT_TAB_WHILE_GRABBED, "0");
#endif
    SDL_SetHint(SDL_HINT_WINDOWS_NO_CLOSE_ON_ALT_F4, "1");
    SDL_EnableScreenSaver();
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
    sdl2_num_outputs = i;
    if (sdl2_num_outputs == 0) {
        return;
    }
    sdl2_console = g_new0(struct sdl2_console, sdl2_num_outputs);
    for (i = 0; i < sdl2_num_outputs; i++) {
        QemuConsole *con = qemu_console_lookup_by_index(i);
        assert(con != NULL);
        if (!qemu_console_is_graphic(con) &&
            qemu_console_get_index(con) != 0) {
            sdl2_console[i].hidden = true;
        }
        sdl2_console[i].idx = i;
        sdl2_console[i].opts = o;
#ifdef CONFIG_OPENGL
        sdl2_console[i].opengl = display_opengl;
        sdl2_console[i].dcl.ops = display_opengl ? &dcl_gl_ops : &dcl_2d_ops;
        sdl2_console[i].dgc.ops = display_opengl ? &gl_ctx_ops : NULL;
#else
        sdl2_console[i].opengl = 0;
        sdl2_console[i].dcl.ops = &dcl_2d_ops;
#endif
        sdl2_console[i].dcl.con = con;
        sdl2_console[i].kbd = qkbd_state_init(con);
        if (display_opengl) {
            qemu_console_set_display_gl_ctx(con, &sdl2_console[i].dgc);
        }
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

    sdl_cursor_hidden = SDL_CreateCursor(&data, &data, 8, 1, 0, 0);
    sdl_cursor_normal = SDL_GetCursor();

    if (gui_fullscreen) {
        sdl_grab_start(&sdl2_console[0]);
    }

    atexit(sdl_cleanup);
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

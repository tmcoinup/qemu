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

/*
 * 文件规模说明：SDL backend 同时承载窗口生命周期、
 * 输入事件、抓取策略、多 console 注册和平台相关初始化。
 * 该历史文件已经超过 500 行。
 * OpenGL provider 的探测、提交和 EGL->GLX 降级已拆到
 * sdl2-egl.c；后续若继续拆分，应以
 * window/input/display 三个状态机为边界。
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qemu/module.h"
#include "qemu/cutils.h"
#include "ui/console.h"
#include "ui/input.h"
#include "ui/sdl2.h"
#include "ui/sdl2-display-policy.h"
#include "ui/sdl2-egl.h"
#include "ui/sdl2-x11.h"
#include "system/runstate.h"
#include "system/runstate-action.h"
#include "system/system.h"
#include "qemu/log.h"
#include "qemu-main.h"

static int sdl2_num_outputs;
static struct sdl2_console *sdl2_console;

static struct sdl2_console *grabbed_scon;
static bool alt_grab;
static bool ctrl_grab;

static int gui_grab_code = KMOD_LALT | KMOD_LCTRL;
static SDL_Cursor *sdl_cursor_normal;
static SDL_Cursor *sdl_cursor_hidden;
static Notifier mouse_mode_notifier;

static uint32_t sdl_button_map[INPUT_BUTTON__MAX] = {
    [INPUT_BUTTON_LEFT]       = SDL_BUTTON(SDL_BUTTON_LEFT),
    [INPUT_BUTTON_MIDDLE]     = SDL_BUTTON(SDL_BUTTON_MIDDLE),
    [INPUT_BUTTON_RIGHT]      = SDL_BUTTON(SDL_BUTTON_RIGHT),
    [INPUT_BUTTON_SIDE]       = SDL_BUTTON(SDL_BUTTON_X1),
    [INPUT_BUTTON_EXTRA]      = SDL_BUTTON(SDL_BUTTON_X2),
};

#define SDL2_REFRESH_INTERVAL_MINIMIZED 500

/* introduced in SDL 2.0.10 */
#ifndef SDL_HINT_RENDER_BATCHING
#define SDL_HINT_RENDER_BATCHING "SDL_RENDER_BATCHING"
#endif

static void sdl_update_caption(struct sdl2_console *scon);
static void sdl_release_mouse_buttons(struct sdl2_console *scon);
static void sdl_sync_cursor(struct sdl2_console *scon);
static void sdl_sync_keyboard_grab(struct sdl2_console *scon);
static void sdl_refresh_window_focus(struct sdl2_console *scon);
static void sdl_grab_start(struct sdl2_console *scon);
static void sdl_grab_end(struct sdl2_console *scon);
static void sdl_deactivate_window(struct sdl2_console *scon,
                                  bool clear_mouse_focus,
                                  bool preserve_fullscreen_grab);

static SDL2WindowMode
sdl2_desired_window_mode(const struct sdl2_console *scon)
{
    SDL_DisplayMode mode;
    SDL2Size guest;
    int display_index = 0;

    if (!sdl2_current_guest_size(scon, &guest)) {
        return SDL2_WINDOW_MODE_INVALID;
    }
    if (scon->real_window) {
        display_index = SDL_GetWindowDisplayIndex(scon->real_window);
        if (display_index < 0) {
            display_index = 0;
        }
    }
    if (SDL_GetDesktopDisplayMode(display_index, &mode) != 0) {
        return SDL2_WINDOW_MODE_INVALID;
    }

    /*
     * Windows/X11 的 SDL display mode 对应像素，
     * 可以直接与 guest framebuffer 比较。
     * native Wayland 可能返回缩放后的 screen coordinates；
     * 此时策略会保守地更早进入 desktop fullscreen，
     * 仍优先保证 guest 不落入过小的有边框客户区。
     * 不使用 usable bounds：
     * 任务栏会让普通窗口装不下原生客户区。
     * 命中边界时进入 desktop fullscreen，避免再次缩小 guest。
     */
    return sdl2_select_window_mode(
        guest, (SDL2Size) { mode.w, mode.h });
}

static bool sdl2_window_create_once(struct sdl2_console *scon, Uint32 flags,
                                    char **error_message)
{
    Uint32 wflags;

    *error_message = NULL;
    SDL_ClearError();

    if (scon->opengl) {
        const char *driver = "opengl";

        /*
         * SDL 在 SDL_CreateWindow(SDL_WINDOW_OPENGL) 内就会加载
         * provider、选择 EGLConfig/GLXFBConfig，并创建 window surface。
         * 所以 profile 与 renderer hint 必须在创建窗口前设置。
         * 放在 SDL_GL_CreateContext 前才设置已经太晚，
         * 会让 ES 模式按桌面 GL config 创建窗口。
         */
        if (scon->opts->gl == DISPLAY_GL_MODE_ES) {
            driver = "opengles2";
        }
        if (sdl2_gl_provider_configure_window(scon->opts->gl) < 0) {
            *error_message = g_strdup(SDL_GetError());
            return false;
        }

        SDL_SetHint(SDL_HINT_RENDER_DRIVER, driver);
        SDL_SetHint(SDL_HINT_RENDER_BATCHING, "1");
    }

    scon->real_window = SDL_CreateWindow("", SDL_WINDOWPOS_UNDEFINED,
                                         SDL_WINDOWPOS_UNDEFINED,
                                         surface_width(scon->surface),
                                         surface_height(scon->surface),
                                         flags);
    if (!scon->real_window) {
        *error_message = g_strdup(SDL_GetError());
        return false;
    }

    /*
     * 窗口刚创建时，SDL 不一定补发 FOCUS_GAINED/ENTER（取决于 WM 和
     * 指针位置）；直接读取当前 flag，避免冷启动后输入门控一直为 false。
     */
    wflags = SDL_GetWindowFlags(scon->real_window);
    scon->has_input_focus = !!(wflags & SDL_WINDOW_INPUT_FOCUS);
    scon->has_mouse_focus = !!(wflags & SDL_WINDOW_MOUSE_FOCUS);

    if (scon->opengl) {
        scon->winctx = SDL_GL_CreateContext(scon->real_window);
        if (!scon->winctx ||
            SDL_GL_MakeCurrent(scon->real_window, scon->winctx) != 0) {
            *error_message = g_strdup(SDL_GetError());
            if (scon->winctx) {
                SDL_GL_DeleteContext(scon->winctx);
                scon->winctx = NULL;
            }
            SDL_DestroyWindow(scon->real_window);
            scon->real_window = NULL;
            return false;
        }
        SDL_GL_SetSwapInterval(0);

#ifdef CONFIG_OPENGL
        sdl2_gl_provider_context_ready();
#endif
    } else {
        /* The SDL renderer is only used by sdl2-2D, when OpenGL is disabled */
        scon->real_renderer = SDL_CreateRenderer(scon->real_window, -1, 0);
        if (!scon->real_renderer) {
            *error_message = g_strdup(SDL_GetError());
            SDL_DestroyWindow(scon->real_window);
            scon->real_window = NULL;
            return false;
        }
    }

    sdl_sync_keyboard_grab(scon);
    sdl2_sync_text_input(sdl2_console, sdl2_num_outputs);
    sdl_update_caption(scon);
    return true;
}

static struct sdl2_console *get_scon_from_window(uint32_t window_id)
{
    SDL_Window *window = SDL_GetWindowFromID(window_id);
    int i;

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

void sdl2_window_create(struct sdl2_console *scon)
{
    g_autofree char *first_error = NULL;
    g_autofree char *fallback_error = NULL;
    Uint32 flags = SDL_WINDOW_ALLOW_HIGHDPI;

    if (!scon->surface) {
        return;
    }
    assert(!scon->real_window);

    /*
     * 1920x1080 guest 无法放进同尺寸桌面的有边框客户区。
     * 创建前直接选择 desktop fullscreen，
     * 避免窗口管理器先压缩客户区，
     * 再由 SDL 做非整数比例采样。
     */
    if (scon->idx == 0 &&
        !scon->fullscreen &&
        sdl2_desired_window_mode(scon) ==
            SDL2_WINDOW_MODE_DESKTOP_FULLSCREEN) {
        scon->fullscreen = true;
        scon->auto_fullscreen = true;
    }

    if (scon->fullscreen) {
        flags |= SDL_WINDOW_FULLSCREEN_DESKTOP;
        if (scon->auto_fullscreen) {
            /*
             * 初始自动全屏退出后仍是普通可调窗口。
             * 显式 -full-screen 保持原有窗口属性。
             */
            flags |= SDL_WINDOW_RESIZABLE;
        }
    } else {
        flags |= SDL_WINDOW_RESIZABLE;
    }
    if (scon->hidden) {
        flags |= SDL_WINDOW_HIDDEN;
    }
#ifdef CONFIG_OPENGL
    if (scon->opengl) {
        flags |= SDL_WINDOW_OPENGL;
    }
#endif

    if (sdl2_window_create_once(scon, flags, &first_error)) {
        return;
    }

#ifdef CONFIG_OPENGL
    if (scon->opengl && sdl2_gl_provider_retry_native()) {
        /*
         * 保留 QEMU 11 的 EGL 优先策略：
         * 只有 EGL window/context 已经真实创建失败后，
         * 才关闭强制 hint，并用同一套 SDL window 参数
         * 重试平台原生 provider。重试成功后 qemu_egl_display
         * 为 EGL_NO_DISPLAY，dma-buf 探测自然返回 false，
         * texture scanout 和 fb-shm 则继续使用 SDL 的
         * 原生 GL context。
         */
        /*
         * 这是已支持的能力降级而非启动告警：
         * 宿主 EGL display 可见但 window surface 不兼容时，
         * GLX/WGL 是 SDL 的正常备用 provider。用 info 让诊断日志
         * 保留首个失败原因，同时避免成功启动产生 warning。
         */
        info_report("SDL: EGL initialization failed (%s); falling back to %s",
                    first_error && *first_error ? first_error :
                    "unknown error", sdl2_gl_provider_native_name());
        if (sdl2_window_create_once(scon, flags, &fallback_error)) {
            return;
        }

        error_report("SDL: %s fallback failed after EGL failure: %s",
                     sdl2_gl_provider_native_name(),
                     fallback_error && *fallback_error ? fallback_error :
                     "unknown error");
    } else if (scon->opengl && sdl2_gl_provider_egl_committed()) {
        error_report("SDL: EGL window/context creation failed after the "
                     "process-wide EGL provider was committed: %s",
                     first_error && *first_error ? first_error :
                     "unknown error");
    } else
#endif
    {
        error_report("SDL: window/context creation failed: %s",
                     first_error && *first_error ? first_error :
                     "unknown error");
    }

    /*
     * 所有调用者紧接着都会创建 shader、texture 或 renderer；此时继续执行只会
     * 把一个可诊断的 SDL 错误升级成 libepoxy assert/NULL 解引用。SDL 是用户
     * 显式选择的 display backend，两条路径都失败时按显示初始化失败退出。
     */
    exit(1);
}

void sdl2_window_destroy(struct sdl2_console *scon)
{
    bool reset_auto_fullscreen;

    if (!scon->real_window) {
        return;
    }

    reset_auto_fullscreen = scon->auto_fullscreen;
    sdl_deactivate_window(scon, true, false);
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

    /*
     * 显式 fullscreen 是用户配置，窗口重建后仍应保留。
     * 自动 fullscreen 只属于旧 surface/desktop 的比较结果。
     * placeholder 销毁窗口后清除自动状态，
     * 下一次创建才能按新 surface 重新计算。
     * saved_grab 也不能跨越已销毁的 SDL 窗口继续生效。
     */
    if (reset_auto_fullscreen) {
        scon->fullscreen = false;
        scon->auto_fullscreen = false;
        scon->saved_grab = false;
    }
}

void sdl2_window_resize(struct sdl2_console *scon)
{
    SDL2WindowMode desired;

    if (!scon->real_window) {
        return;
    }

    desired = sdl2_desired_window_mode(scon);

    /*
     * 自动全屏只跟随 guest/desktop 的原生像素边界。
     * 显式全屏不受分辨率切换影响。
     * 用户通过热键退出后，
     * 不会在同一次 resize 中被立即拉回。
     */
    if (scon->auto_fullscreen &&
        desired != SDL2_WINDOW_MODE_DESKTOP_FULLSCREEN) {
        if (SDL_SetWindowFullscreen(scon->real_window, 0) != 0) {
            warn_report("SDL: failed to leave automatic fullscreen: %s",
                        SDL_GetError());
            return;
        }
        scon->fullscreen = false;
        scon->auto_fullscreen = false;
        if (!scon->saved_grab && grabbed_scon == scon) {
            sdl_grab_end(scon);
        }
        scon->saved_grab = false;
    } else if (scon->idx == 0 &&
               !scon->fullscreen &&
               desired == SDL2_WINDOW_MODE_DESKTOP_FULLSCREEN) {
        if (SDL_SetWindowFullscreen(scon->real_window,
                                    SDL_WINDOW_FULLSCREEN_DESKTOP) == 0) {
            scon->saved_grab = grabbed_scon == scon;
            scon->fullscreen = true;
            scon->auto_fullscreen = true;
            sdl_refresh_window_focus(scon);
            return;
        }
        warn_report("SDL: failed to enter native-resolution fullscreen: %s",
                    SDL_GetError());
    }

    if (scon->fullscreen) {
        return;
    }
    SDL_SetWindowSize(scon->real_window,
                      surface_width(scon->surface),
                      surface_height(scon->surface));
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
    } else if (grabbed_scon == scon) {
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
    SDL2PointerPolicy policy;

    if (scon->opts->has_show_cursor && scon->opts->show_cursor) {
        return;
    }

    SDL_ShowCursor(SDL_DISABLE);
    SDL_SetCursor(sdl_cursor_hidden);

    /*
     * SDL relative mode is process-wide and constrains the host pointer by
     * itself.  Merely clearing SDL_WINDOW_MOUSE_GRABBED is not enough.
     * Always write the desired state so a PS/2 -> USB tablet transition
     * cannot leave the pointer trapped after QEMU has ended its logical grab.
     */
    policy = sdl2_pointer_policy(
        grabbed_scon == scon,
        qemu_input_is_absolute(scon->dcl.con),
        qemu_input_has_absolute(scon->dcl.con));
    SDL_SetRelativeMouseMode(policy.relative_mode ? SDL_TRUE : SDL_FALSE);
}

static bool sdl_console_uses_absolute_pointer(struct sdl2_console *scon)
{
    return qemu_console_is_graphic(scon->dcl.con) &&
        (qemu_input_is_absolute(scon->dcl.con) || scon->absolute_enabled);
}

/*
 * SDL relative mode and the current cursor are process-wide even though QEMU
 * can expose several SDL windows.  Re-select the effective owner on every
 * transition so a stale, unfocused grab cannot block another console.
 */
static struct sdl2_console *
sdl_active_cursor_owner(struct sdl2_console *preferred)
{
    int i;

    if (grabbed_scon && grabbed_scon->real_window &&
        !grabbed_scon->hidden && grabbed_scon->has_input_focus) {
        return grabbed_scon;
    }
    if (preferred && sdl2_input_allowed(preferred) &&
        sdl_console_uses_absolute_pointer(preferred)) {
        return preferred;
    }

    for (i = 0; i < sdl2_num_outputs; i++) {
        struct sdl2_console *candidate = &sdl2_console[i];

        if (sdl2_input_allowed(candidate) &&
            sdl_console_uses_absolute_pointer(candidate)) {
            return candidate;
        }
    }
    return NULL;
}

/*
 * 窗口模式下的绝对指针不需要 SDL grab。
 * 指针进入窗口时显示 guest cursor（或隐藏 host cursor），
 * 离开窗口时恢复 host cursor。
 * 这样用户可以从任意边缘自然移出，
 * 而不会触发 XWayland 的约束/解除约束坐标跳变。
 */
static void sdl_sync_cursor(struct sdl2_console *scon)
{
    struct sdl2_console *owner = sdl_active_cursor_owner(scon);

    if (!owner ||
        (owner->opts->has_show_cursor && owner->opts->show_cursor)) {
        SDL_SetRelativeMouseMode(SDL_FALSE);
        SDL_SetCursor(sdl_cursor_normal);
        SDL_ShowCursor(SDL_ENABLE);
        return;
    }

    if (owner->guest_cursor && owner->guest_sprite) {
        SDL_SetRelativeMouseMode(SDL_FALSE);
        SDL_SetCursor(owner->guest_sprite);
        SDL_ShowCursor(SDL_ENABLE);
        return;
    }

    sdl_hide_cursor(owner);
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
            (SDL2Point) { scon->guest_x, scon->guest_y },
            &render_point) ||
        !sdl2_map_point(render, window, render_point, &window_point)) {
        return;
    }

    /*
     * A guest pixel is not always exactly representable after downscaling.
     * Store the pixel reached by the warp so SDL's synthetic motion event
     * produces a zero delta instead of feeding a one-pixel jump back to QEMU.
     */
    if (sdl2_map_point(window, render, window_point, &quantized_render) &&
        sdl2_window_to_guest(dst, guest, quantized_render,
                             &quantized_guest)) {
        scon->guest_x = quantized_guest.x;
        scon->guest_y = quantized_guest.y;
    }
    SDL_WarpMouseInWindow(scon->real_window,
                          window_point.x, window_point.y);
}

/*
 * SDL 2.0.16 起，鼠标约束和键盘快捷键抑制是独立状态。
 * 绝对指针窗口只抓键盘；
 * 显式进入相对鼠标模式时才约束鼠标，
 * 避免再次引入窗口边缘跳变。
 */
static void sdl_set_mouse_grab(struct sdl2_console *scon, SDL_bool grabbed)
{
#if SDL_VERSION_ATLEAST(2, 0, 16)
    SDL_SetWindowMouseGrab(scon->real_window, grabbed);
#else
    SDL_SetWindowGrab(scon->real_window, grabbed);
#endif
}

static void sdl_reset_relative_motion(struct sdl2_console *scon)
{
    scon->window_to_render_x = (SDL2AxisScale) { 0 };
    scon->window_to_render_y = (SDL2AxisScale) { 0 };
    scon->render_to_guest_x = (SDL2AxisScale) { 0 };
    scon->render_to_guest_y = (SDL2AxisScale) { 0 };
}

/*
 * Synchronous hide/pause paths can stop display polling before SDL delivers a
 * focus event.  Close the input state here so keys and buttons cannot remain
 * pressed in the guest while the listener is inactive.
 */
static void sdl_deactivate_window(struct sdl2_console *scon,
                                  bool clear_mouse_focus,
                                  bool preserve_fullscreen_grab)
{
    sdl2_release_modifiers(scon);
    sdl_release_mouse_buttons(scon);
    scon->has_input_focus = false;
    if (clear_mouse_focus) {
        scon->has_mouse_focus = false;
    }
    sdl_reset_relative_motion(scon);
    sdl_sync_keyboard_grab(scon);
    sdl2_sync_text_input(sdl2_console, sdl2_num_outputs);

    if (grabbed_scon == scon) {
        if (preserve_fullscreen_grab && scon->fullscreen) {
            sdl_set_mouse_grab(scon, SDL_FALSE);
            sdl_sync_cursor(scon);
        } else {
            sdl_grab_end(scon);
        }
    } else {
        sdl_sync_cursor(scon);
    }
}

static void sdl_refresh_window_focus(struct sdl2_console *scon)
{
    Uint32 flags = SDL_GetWindowFlags(scon->real_window);

    scon->has_input_focus = !!(flags & SDL_WINDOW_INPUT_FOCUS);
    scon->has_mouse_focus = !!(flags & SDL_WINDOW_MOUSE_FOCUS);
    if (scon->fullscreen && !scon->hidden && scon->has_input_focus) {
        /*
         * Fullscreen is the durable grab request.  Startup, ShowWindow and a
         * recreated GL window can all gain focus after the first grab attempt;
         * rebuild the effective grab when SDL reports the real focus state.
         */
        sdl_grab_start(scon);
    } else if (grabbed_scon == scon && scon->has_input_focus) {
        sdl_set_mouse_grab(scon, SDL_TRUE);
    }
    sdl_sync_keyboard_grab(scon);
    sdl2_sync_text_input(sdl2_console, sdl2_num_outputs);
    sdl_sync_cursor(scon);
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
    sdl_sync_cursor(scon);
    if (scon->guest_cursor && !qemu_input_is_absolute(scon->dcl.con) &&
        !scon->absolute_enabled) {
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
    sdl_set_mouse_grab(scon, SDL_FALSE);
    grabbed_scon = NULL;
    sdl_sync_cursor(scon);
    sdl_update_caption(scon);
}

static void sdl_mouse_mode_change(Notifier *notify, void *data)
{
    int i;

    for (i = 0; i < sdl2_num_outputs; i++) {
        struct sdl2_console *scon = &sdl2_console[i];
        bool absolute = qemu_input_is_absolute(scon->dcl.con);
        bool available = qemu_input_has_absolute(scon->dcl.con);
        SDL2PointerPolicy policy;

        if (absolute == scon->absolute_enabled &&
            available == scon->absolute_available) {
            continue;
        }

        sdl_release_mouse_buttons(scon);
        sdl_reset_relative_motion(scon);
        scon->absolute_enabled = absolute;
        scon->absolute_available = available;
        policy = sdl2_pointer_policy(
            grabbed_scon == scon, absolute, available);
        if (policy.release_grab && !scon->fullscreen) {
            sdl_grab_end(scon);
        } else {
            sdl_sync_cursor(scon);
        }
    }
}

static void sdl_release_mouse_buttons(struct sdl2_console *scon)
{
    if (!scon->mouse_button_state) {
        return;
    }

    qemu_input_update_buttons(scon->dcl.con, sdl_button_map,
                              scon->mouse_button_state, 0);
    scon->mouse_button_state = 0;
    qemu_input_event_sync();
}

/*
 * dx/dy/x/y 保持 SDL logical-window 语义。高 DPI 下先转换到实际
 * renderer/drawable 像素，
 * 再使用与渲染相同的目标矩形映射到 guest。
 * 相对位移的两段有理数缩放分别保留余数，
 * 连续小步不会因逐事件取整而丢失。
 */
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

    if (!sdl_pointer_geometry(scon, &window, &render, &guest, &dst)) {
        qemu_input_event_sync();
        return;
    }

    if (!sdl2_map_point(window, render,
                        (SDL2Point) { window_x, window_y },
                        &render_point) ||
        !sdl2_window_to_guest(dst, guest, render_point,
                              &guest_point)) {
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
    bool entering = !scon->fullscreen;
    bool was_auto_fullscreen = scon->auto_fullscreen;
    Uint32 flags = entering ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0;

    if (SDL_SetWindowFullscreen(scon->real_window, flags) != 0) {
        warn_report("SDL: failed to change fullscreen mode: %s",
                    SDL_GetError());
        return;
    }

    scon->fullscreen = entering;
    scon->auto_fullscreen = false;
    if (entering) {
        scon->saved_grab = grabbed_scon == scon;
        sdl_grab_start(scon);
    } else {
        if (!scon->saved_grab && grabbed_scon == scon) {
            sdl_grab_end(scon);
        }
        scon->saved_grab = false;
        if (was_auto_fullscreen && scon->surface) {
            /*
             * 自动全屏可能从固件的较小启动窗口进入。
             * 用户显式退出后，
             * 把客户区恢复到当前 guest 尺寸，
             * 不使用 SDL 保存的旧尺寸。
             * 窗口管理器仍可按工作区约束它，
             * 但退出意图优先。
             */
            SDL_SetWindowSize(scon->real_window,
                              surface_width(scon->surface),
                              surface_height(scon->surface));
        }
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

/*
 * 指针在窗口内且窗口拥有输入焦点时，
 * guest 独占键盘快捷键。
 * 这样 Super、Alt+Tab 等组合键只送入虚拟机；
 * 指针离开或窗口失焦后立即归还宿主。
 *
 * 旧 SDL 没有“只抓键盘”的 API，
 * 继续保留可编译性，
 * 但不以重新约束绝对鼠标为代价做退化模拟。
 * 当前部署使用 SDL 2.32，
 * 实际路径始终走独立键盘抓取。
 */
static void sdl_sync_keyboard_grab(struct sdl2_console *scon)
{
#if SDL_VERSION_ATLEAST(2, 0, 16)
    bool should_grab = sdl2_input_allowed(scon) &&
        qemu_console_is_graphic(scon->dcl.con);
    bool needs_regrab;
    int i;

    /*
     * SDL 的物理键盘 grab 属于整个 X11 client，
     * 但 mouse/keyboard 请求标志属于各个窗口。
     * 旧窗口延迟处理 FOCUS_LOST 时，
     * 任一请求标志的变化都会让 SDL X11 backend
     * 执行 client 级 XUngrabKeyboard，
     * 从而误伤刚抓取的新 console。
     *
     * 获取前先清空其他窗口的残留请求，
     * 必要时再规范化并重抓当前窗口。
     * fullscreen 的持久意图保存在 scon->fullscreen，
     * 后续真实 FOCUS_GAINED 会由 sdl_refresh_window_focus()
     * 重新建立其 mouse grab。
     */
    if (!should_grab) {
        SDL_SetWindowKeyboardGrab(scon->real_window, SDL_FALSE);
        return;
    }
    needs_regrab = SDL_GetWindowKeyboardGrab(scon->real_window) != SDL_TRUE;
    for (i = 0; i < sdl2_num_outputs; i++) {
        struct sdl2_console *other = &sdl2_console[i];
        Uint32 other_flags;

        if (other == scon || !other->real_window) {
            continue;
        }
        other_flags = SDL_GetWindowFlags(other->real_window);
        if (other_flags & SDL_WINDOW_KEYBOARD_GRABBED) {
            SDL_SetWindowKeyboardGrab(other->real_window, SDL_FALSE);
            needs_regrab = true;
        }
        /*
         * SDL_UpdateWindowGrab() 会在 mouse request 变化时同时调用 keyboard
         * backend；最终重抓前必须清理旧 mouse request，
         * 让之后到达的旧窗口释放事件成为无操作。
         */
        if (other_flags & SDL_WINDOW_MOUSE_GRABBED) {
            if (grabbed_scon == other) {
                sdl_grab_end(other);
            } else {
                sdl_set_mouse_grab(other, SDL_FALSE);
            }
            needs_regrab = true;
        }
    }
    if (!needs_regrab) {
        return;
    }
    SDL_SetWindowKeyboardGrab(scon->real_window, SDL_FALSE);
    sdl2_x11_request_keyboard_grab_permission(scon->real_window);
    SDL_SetWindowKeyboardGrab(scon->real_window, SDL_TRUE);
#else
    (void)scon;
#endif
}

static void handle_keydown(SDL_Event *ev)
{
    int win;
    struct sdl2_console *scon = get_scon_from_window(ev->key.windowID);
    struct sdl2_console *target;
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
            win = ev->key.keysym.scancode - SDL_SCANCODE_1;
            if (win < sdl2_num_outputs) {
                target = &sdl2_console[win];
                target->hidden = !target->hidden;
                if (target->real_window) {
                    if (target->hidden) {
                        sdl_deactivate_window(target, true, true);
                        SDL_HideWindow(target->real_window);
                    } else {
                        /*
                         * ShowWindow 不会同步刷新 SDL focus flags。
                         * 保持 deactivate 后的 false，
                         * 等 SHOWN/FOCUS_GAINED/ENTER 事件再重抓。
                         */
                        SDL_ShowWindow(target->real_window);
                        sdl2_redraw(target);
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
            if (grabbed_scon != scon) {
                sdl_grab_start(scon);
            } else if (!scon->fullscreen) {
                sdl_grab_end(scon);
            }
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
            if (!scon->fullscreen) {
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
    struct sdl2_console *scon = get_scon_from_window(ev->motion.windowID);
    SDL2PointerPolicy policy;

    if (!scon || !qemu_console_is_graphic(scon->dcl.con)) {
        return;
    }
    /* grab=on 时 SDL 把指针锁在窗内, sdl2_input_allowed 自然为真;
     * grab=off 且指针在窗外/无焦点时, 不把鼠标位置写进 guest. */
    if (!sdl2_input_allowed(scon)) {
        return;
    }

    policy = sdl2_pointer_policy(
        grabbed_scon == scon,
        qemu_input_is_absolute(scon->dcl.con),
        qemu_input_has_absolute(scon->dcl.con));
    if (policy.accept_motion) {
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
    if (!sdl2_input_allowed(scon)) {
        return;
    }

    bev = &ev->button;
    buttonstate = scon->mouse_button_state;
    policy = sdl2_pointer_policy(
        grabbed_scon == scon,
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
        /* fall through */
    case SDL_WINDOWEVENT_SIZE_CHANGED:
        sdl2_redraw(scon);
        break;
#if SDL_VERSION_ATLEAST(2, 0, 18)
    case SDL_WINDOWEVENT_DISPLAY_CHANGED:
        sdl2_redraw(scon);
        break;
#endif
    case SDL_WINDOWEVENT_EXPOSED:
        sdl2_redraw(scon);
        break;
    case SDL_WINDOWEVENT_FOCUS_GAINED:
        update_displaychangelistener(
            &scon->dcl, SDL2_ACTIVE_REFRESH_INTERVAL_MS);
        sdl_refresh_window_focus(scon);
        /*
         * 中文注释：GL scanout 的窗口 back buffer 在最小化、隐藏或被窗口管理器
         * 重新合成后可能被清成黑色。guest 若此时没有提交新帧，普通
         * graphic_hw_update() 不会触发 dpy_gl_update()，窗口就会一直黑到下一帧。
         * 焦点回来时主动 replay 当前 scanout，保证 idle 桌面也能恢复显示。
         */
        sdl2_redraw(scon);
        scon->ignore_hotkeys = get_mod_state();
        break;
    case SDL_WINDOWEVENT_ENTER:
        scon->has_mouse_focus = true;
        sdl_sync_keyboard_grab(scon);
        sdl2_sync_text_input(sdl2_console, sdl2_num_outputs);
        sdl_sync_cursor(scon);
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
        sdl_deactivate_window(scon, false, true);
        break;
    case SDL_WINDOWEVENT_LEAVE:
        /*
         * 鼠标离开窗口：
         * 同样抬掉按下的键，
         * 但不改变显式 grab。
         */
        scon->has_mouse_focus = false;
        sdl2_release_modifiers(scon);
        sdl_release_mouse_buttons(scon);
        sdl_reset_relative_motion(scon);
        sdl_sync_keyboard_grab(scon);
        sdl2_sync_text_input(sdl2_console, sdl2_num_outputs);
        sdl_sync_cursor(scon);
        break;
    case SDL_WINDOWEVENT_RESTORED:
        update_displaychangelistener(
            &scon->dcl, SDL2_ACTIVE_REFRESH_INTERVAL_MS);
        sdl_refresh_window_focus(scon);
        sdl2_redraw(scon);
        break;
    case SDL_WINDOWEVENT_MINIMIZED:
        sdl_deactivate_window(scon, true, true);
        update_displaychangelistener(
            &scon->dcl, SDL2_REFRESH_INTERVAL_MINIMIZED);
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
            scon->hidden = true;
            sdl_deactivate_window(scon, true, false);
            SDL_HideWindow(scon->real_window);
        }
        break;
    case SDL_WINDOWEVENT_SHOWN:
        scon->hidden = false;
        update_displaychangelistener(
            &scon->dcl, SDL2_ACTIVE_REFRESH_INTERVAL_MS);
        sdl_refresh_window_focus(scon);
        sdl2_redraw(scon);
        break;
    case SDL_WINDOWEVENT_HIDDEN:
        scon->hidden = true;
        sdl_deactivate_window(scon, true, true);
        break;
    }
}

static void sdl2_recover_2d_renderers(bool recreate_textures)
{
    int i;

    /*
     * 两类 renderer reset 都是进程级事件，不携带 windowID。
     * DEVICE_RESET 后 SDL 明确要求重建全部 texture。
     * TARGETS_RESET 只要求重新填充 render target；
     * streaming texture 本身仍可复用并整帧上传。
     *
     * 这里遍历所有 2D console，
     * 不只修复当前执行 dpy_refresh 的窗口。
     * device reset 通过 sdl2_2d_switch() 销毁并重建 streaming texture；
     * target reset 则用 sdl2_2d_redraw() 重新上传当前 DisplaySurface。
     * 两条路径都会立即 Present，guest 桌面静止时也能恢复。
     * OpenGL console 拥有独立 context/texture 生命周期，
     * 不能混入 SDL_Renderer 的 reset 恢复路径。
     */
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

    if (scon->last_vm_running != runstate_is_running()) {
        scon->last_vm_running = runstate_is_running();
        sdl_update_caption(scon);
    }

    while (SDL_PollEvent(ev)) {
        switch (ev->type) {
        case SDL_KEYDOWN:
            handle_keydown(ev);
            break;
        case SDL_KEYUP:
            handle_keyup(ev);
            break;
        case SDL_TEXTINPUT:
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
            handle_mousemotion(ev);
            break;
        case SDL_MOUSEBUTTONDOWN:
        case SDL_MOUSEBUTTONUP:
            handle_mousebutton(ev);
            break;
        case SDL_MOUSEWHEEL:
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

    if (!scon->real_window || scon->hidden ||
        (SDL_GetWindowFlags(scon->real_window) & SDL_WINDOW_MINIMIZED)) {
        scon->dcl.update_interval = SDL2_REFRESH_INTERVAL_MINIMIZED;
    } else {
        /*
         * 30 ms 的上游 idle interval 只够约 33 次/秒。
         * 窗口可见时持续按 16 ms 轮询；
         * 默认仍只在 guest 有 damage 时 Present，
         * 不做无意义的 software renderer 整帧复制。
         */
        scon->dcl.update_interval = SDL2_ACTIVE_REFRESH_INTERVAL_MS;
    }
}

static void sdl_mouse_warp(DisplayChangeListener *dcl,
                           int x, int y, bool on)
{
    struct sdl2_console *scon = container_of(dcl, struct sdl2_console, dcl);

    if (!qemu_console_is_graphic(scon->dcl.con)) {
        return;
    }

    if (scon->guest_cursor != on) {
        sdl_reset_relative_motion(scon);
    }
    scon->guest_cursor = on;
    scon->guest_x = x;
    scon->guest_y = y;
    sdl_sync_cursor(scon);

    if (on && grabbed_scon == scon &&
        !qemu_input_is_absolute(scon->dcl.con) &&
        !scon->absolute_enabled) {
        sdl_warp_guest_cursor(scon);
    }
}

static void sdl_mouse_define(DisplayChangeListener *dcl,
                             QEMUCursor *c)
{
    struct sdl2_console *scon =
        container_of(dcl, struct sdl2_console, dcl);
    SDL_Surface *new_surface;
    SDL_Cursor *new_sprite;

    new_surface =
        SDL_CreateRGBSurfaceFrom(c->data, c->width, c->height, 32, c->width * 4,
                                 0xff0000, 0x00ff00, 0xff, 0xff000000);

    if (!new_surface) {
        fprintf(stderr, "Failed to make rgb surface from %p\n", c);
        return;
    }
    new_sprite = SDL_CreateColorCursor(new_surface, c->hot_x, c->hot_y);
    if (!new_sprite) {
        fprintf(stderr, "Failed to make color cursor from %p\n", c);
        SDL_FreeSurface(new_surface);
        return;
    }

    if (scon->guest_sprite) {
        if (SDL_GetCursor() == scon->guest_sprite) {
            SDL_SetCursor(sdl_cursor_normal);
        }
        SDL_FreeCursor(scon->guest_sprite);
    }
    if (scon->guest_sprite_surface) {
        SDL_FreeSurface(scon->guest_sprite_surface);
    }
    scon->guest_sprite_surface = new_surface;
    scon->guest_sprite = new_sprite;
    sdl_sync_cursor(scon);
}

static void sdl_cleanup(void)
{
    int i;

    /*
     * 这里仅由 atexit 调用。X11/XWayland 在退出瞬间可能已通过 RandR
     * 移除了最后一个 display；SDL2 的 X11_HideWindow 会在这种状态下
     * 直接解引用空 display。此时也没有任何仍可安全调用的窗口/光标清理
     * API，直接交给进程退出回收资源。
     */
    if (!(SDL_WasInit(SDL_INIT_VIDEO) & SDL_INIT_VIDEO) ||
        SDL_GetNumVideoDisplays() <= 0) {
        return;
    }

    SDL_SetCursor(sdl_cursor_normal);
    for (i = 0; i < sdl2_num_outputs; i++) {
        if (sdl2_console[i].guest_sprite) {
            SDL_FreeCursor(sdl2_console[i].guest_sprite);
        }
        if (sdl2_console[i].guest_sprite_surface) {
            SDL_FreeSurface(sdl2_console[i].guest_sprite_surface);
        }
    }
    if (sdl_cursor_hidden) {
        SDL_FreeCursor(sdl_cursor_hidden);
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
        sdl_deactivate_window(scon, true, true);
        SDL_HideWindow(scon->real_window);
    } else {
        scon->hidden = false;
        /*
         * QMP pause 期间可能没有 pump SDL 事件。
         * Show 后立即读 flags 会拿到 hide 前的旧焦点，
         * 从而误抓宿主键盘；
         * 必须等待后续 SDL window event。
         */
        SDL_ShowWindow(scon->real_window);
        graphic_hw_invalidate(dcl->con);
        /*
         * 中文注释：display-resume 可能发生在 guest 桌面完全静止时。对
         * virtio-gpu-gl/virgl 来说，当前画面在 texture scanout 里，不在传统
         * DisplaySurface 里；只 invalidate 不一定马上产生新的 GL flush。
         * 这里直接重绘一次已缓存的 scanout，避免 SDL 窗口恢复后停在黑色
         * back buffer。
         */
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

    return dcl->ops->dpy_gl_sidecar &&
           dcl->ops->dpy_gl_scanout_texture &&
           dcl->ops->dpy_gl_update;
}

static const DisplayGLCtxOps gl_ctx_ops = {
    .dpy_gl_ctx_is_compatible_dcl = sdl2_gl_is_compatible_dcl,
    .dpy_gl_ctx_save_current = sdl2_gl_save_current_context,
    .dpy_gl_ctx_restore_current = sdl2_gl_restore_current_context,
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
    bool start_fullscreen;

    assert(o->type == DISPLAY_TYPE_SDL);

    if (SDL_GetHintBoolean("QEMU_ENABLE_SDL_LOGGING", SDL_FALSE)) {
        SDL_LogSetAllPriority(SDL_LOG_PRIORITY_VERBOSE);
    }

#ifdef SDL_HINT_WINDOWS_DPI_AWARENESS
    /*
     * 必须在 SDL_Init(VIDEO) 前声明 DPI awareness，
     * 否则 Windows 可能先把整个 SDL 窗口当位图缩放。
     * 环境变量具有更高 hint priority，调用者仍可显式覆盖。
     * 默认使用跨显示器最稳定的 per-monitor v2。
     */
    SDL_SetHint(SDL_HINT_WINDOWS_DPI_AWARENESS, "permonitorv2");
#endif
    if (SDL_Init(SDL_INIT_VIDEO)) {
        fprintf(stderr, "Could not initialize SDL(%s) - exiting\n",
                SDL_GetError());
        exit(1);
    }
    /*
     * SDL_Init(VIDEO) 会隐式调用 SDL_StartTextInput。窗口尚未建立时先关闭，
     * 防止 X11/Wayland 输入法在首个图形窗口事件到达前获得处理按键的机会。
     * 后续由 sdl2_sync_text_input() 仅为获得有效焦点的文本 console 重开。
     */
    SDL_StopTextInput();
#ifdef SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR /* only available since SDL 2.0.8 */
    SDL_SetHint(SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0");
#endif
    SDL_SetHint(SDL_HINT_GRAB_KEYBOARD, "1");
#ifdef SDL_HINT_ALLOW_ALT_TAB_WHILE_GRABBED
    SDL_SetHint(SDL_HINT_ALLOW_ALT_TAB_WHILE_GRABBED, "0");
#endif
    SDL_SetHint(SDL_HINT_WINDOWS_NO_CLOSE_ON_ALT_F4, "1");
#ifdef CONFIG_OPENGL
    if (display_opengl) {
        sdl2_gl_provider_prepare(o->gl);
    }
#endif
    SDL_EnableScreenSaver();
    memset(&info, 0, sizeof(info));
    SDL_VERSION(&info.version);

    start_fullscreen = o->has_full_screen && o->full_screen;

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
    /*
     * Display listener registration can immediately define or show a guest
     * cursor.  Create the host cursors first so those callbacks never observe
     * partially initialized cursor state.
     */
    sdl_cursor_normal = SDL_GetCursor();
    sdl_cursor_hidden = SDL_CreateCursor(&data, &data, 8, 1, 0, 0);

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
        sdl2_console[i].fullscreen = start_fullscreen;
        sdl2_console[i].dcl.update_interval =
            SDL2_ACTIVE_REFRESH_INTERVAL_MS;
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
#ifdef CONFIG_OPENGL
        if (display_opengl) {
            qemu_console_set_display_gl_ctx(con, &sdl2_console[i].dgc);
            sdl2_gl_console_init(&sdl2_console[i]);
        }
#endif
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
        sdl2_console[i].absolute_enabled =
            qemu_input_is_absolute(sdl2_console[i].dcl.con);
        sdl2_console[i].absolute_available =
            qemu_input_has_absolute(sdl2_console[i].dcl.con);
    }
    for (i = 0; i < sdl2_num_outputs; i++) {
        if (sdl2_input_allowed(&sdl2_console[i])) {
            sdl_sync_cursor(&sdl2_console[i]);
            break;
        }
    }
    if (i == sdl2_num_outputs) {
        sdl_sync_cursor(&sdl2_console[0]);
    }
    sdl2_sync_text_input(sdl2_console, sdl2_num_outputs);

    if (sdl2_console[0].fullscreen) {
        sdl_grab_start(&sdl2_console[0]);
    }

    atexit(sdl_cleanup);

    /* SDL's event polling (in dpy_refresh) must happen on the main thread. */
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

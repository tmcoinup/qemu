/*
 * QEMU SDL display -- OpenGL provider selection
 *
 * Copyright (c) 2026 The QEMU Project developers
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
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "ui/sdl2.h"
#include "ui/sdl2-egl.h"

#ifdef CONFIG_X11
#include <X11/Xlib.h>
#endif

/*
 * provider 是 SDL 进程级状态：SDL_VIDEO_X11_FORCE_EGL、GL loader 以及
 * qemu_egl_display 都不是单窗口私有数据。
 * 首个成功 context 提交后，
 * 后续 console 必须沿用同一 provider，
 * 不能在 EGL 和 GLX/WGL 之间混用。
 */
typedef enum Sdl2GLProviderState {
    SDL2_GL_PROVIDER_UNDECIDED,
    SDL2_GL_PROVIDER_EGL_PREFERRED,
    SDL2_GL_PROVIDER_NATIVE_SELECTED,
    SDL2_GL_PROVIDER_EGL_COMMITTED,
    SDL2_GL_PROVIDER_NATIVE_COMMITTED,
} Sdl2GLProviderState;

static Sdl2GLProviderState sdl2_gl_provider_state;
static DisplayGLMode sdl2_gl_requested_mode = DISPLAY_GL_MODE_ON;

#ifdef WIN32
/* gl=on 在 Windows 上优先转换成 ANGLE 支持的 GLES provider。 */
static bool sdl2_windows_angle_preferred;
#endif

#if defined(SDL_HINT_VIDEO_X11_FORCE_EGL) && defined(CONFIG_X11)

#define SDL2_EGL_PRESENT_OPAQUE_EXT "EGL_EXT_present_opaque"

/*
 * 只把“能取得 EGLDisplay”当作可用会产生假阳性。
 * SDL 随后还需要绑定正确 API，
 * 并为窗口选到 EGL_WINDOW_BIT config；
 * 因此探测必须覆盖初始化、profile 和 config 三个阶段。
 * 真正的 X11 Window 仍由 SDL 创建，失败时由状态机回退。
 */
static bool sdl2_x11_egl_config_available(EGLDisplay display, bool gles)
{
    const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, gles ? EGL_OPENGL_ES2_BIT : EGL_OPENGL_BIT,
        EGL_RED_SIZE, 5,
        EGL_GREEN_SIZE, 5,
        EGL_BLUE_SIZE, 5,
        EGL_DEPTH_SIZE, 16,
        EGL_NONE,
    };
    EGLConfig config;
    EGLint count = 0;
    EGLenum api = gles ? EGL_OPENGL_ES_API : EGL_OPENGL_API;

    if (eglBindAPI(api) == EGL_FALSE) {
        return false;
    }

    return eglChooseConfig(display, config_attributes, &config, 1, &count) &&
           count == 1;
}

/*
 * NVIDIA 580 的 X11 EGL 会发布 EGL_EXT_present_opaque，但对 SDL 2.30
 * 传入的 EGL_PRESENT_OPAQUE_EXT 属性返回 EGL_BAD_ATTRIBUTE。
 * SDL 支持用同名环境变量的 bit 0 屏蔽 display extension；
 * QEMU 窗口本来就是不透明窗口，
 * 因此省略这个可选提示不会改变画面语义，
 * 却能让 EGLWindowSurface 正常创建。
 *
 * 用户显式设置过同名变量时保持用户选择；
 * 其他 EGL vendor 也不受影响。
 */
static void sdl2_x11_mask_broken_nvidia_present_opaque(EGLDisplay display)
{
    const char *vendor = eglQueryString(display, EGL_VENDOR);

    if (!vendor || !g_str_has_prefix(vendor, "NVIDIA") ||
        !epoxy_has_egl_extension(display, SDL2_EGL_PRESENT_OPAQUE_EXT) ||
        g_getenv(SDL2_EGL_PRESENT_OPAQUE_EXT)) {
        return;
    }

    g_setenv(SDL2_EGL_PRESENT_OPAQUE_EXT, "1", false);
}

static bool sdl2_current_video_driver_is_x11(void)
{
    return g_strcmp0(SDL_GetCurrentVideoDriver(), "x11") == 0;
}

#endif

void sdl2_gl_provider_prepare(DisplayGLMode mode)
{
    bool gles = mode == DISPLAY_GL_MODE_ES;

    sdl2_gl_requested_mode = mode;

#ifdef WIN32
    /*
     * Windows 的 SDL 默认先走 WGL。
     * fb-shm 需要 ANGLE 暴露的 EGLDisplay 和 D3D11 texture，
     * 因此 gl=on/es 优先要求 GLES driver；
     * 显式 gl=core 仍尊重用户选择，并保留 WGL。
     * 若 ANGLE 初始化失败，retry_native() 会撤销 hint。
     */
    sdl2_windows_angle_preferred = mode != DISPLAY_GL_MODE_CORE;
    if (sdl2_windows_angle_preferred) {
        SDL_SetHint(SDL_HINT_OPENGL_ES_DRIVER, "1");
        sdl2_windows_angle_preferred =
            SDL_GetHintBoolean(SDL_HINT_OPENGL_ES_DRIVER, SDL_FALSE);
        if (sdl2_windows_angle_preferred) {
            sdl2_gl_provider_state = SDL2_GL_PROVIDER_EGL_PREFERRED;
        }
    }
#endif

#if defined(SDL_HINT_VIDEO_X11_FORCE_EGL) && defined(CONFIG_X11)
    Display *x_display;
    EGLDisplay egl_display;
    EGLint major;
    EGLint minor;

    if (sdl2_gl_provider_state != SDL2_GL_PROVIDER_UNDECIDED ||
        !sdl2_current_video_driver_is_x11()) {
        return;
    }

    x_display = XOpenDisplay(NULL);
    if (!x_display) {
        return;
    }

    /*
     * 显式使用 X11 platform，
     * 避免 GLVND 同时安装多个 provider 时，
     * 把原生指针解释成 Wayland/GBM 平台对象。
     */
    egl_display = qemu_egl_get_display((EGLNativeDisplayType)x_display,
                                       EGL_PLATFORM_X11_KHR);
    if (egl_display == EGL_NO_DISPLAY ||
        eglInitialize(egl_display, &major, &minor) == EGL_FALSE) {
        XCloseDisplay(x_display);
        return;
    }

    if (sdl2_x11_egl_config_available(egl_display, gles)) {
        sdl2_x11_mask_broken_nvidia_present_opaque(egl_display);

        /*
         * 环境变量 hint 的优先级高于 SDL_SetHint。
         * 设置后重新读取最终值，从而尊重用户显式设置的
         * SDL_VIDEO_X11_FORCE_EGL=0。
         */
        SDL_SetHint(SDL_HINT_VIDEO_X11_FORCE_EGL, "1");
        if (SDL_GetHintBoolean(SDL_HINT_VIDEO_X11_FORCE_EGL, SDL_FALSE)) {
            sdl2_gl_provider_state = SDL2_GL_PROVIDER_EGL_PREFERRED;
        }
    }

    eglTerminate(egl_display);
    XCloseDisplay(x_display);
#else
    /* 非 X11 平台不执行 X Display 探测。 */
    (void)gles;
#endif
}

int sdl2_gl_provider_configure_window(DisplayGLMode mode)
{
    bool gles = mode == DISPLAY_GL_MODE_ES;
    int major = 2;
    int minor = 1;
    int profile = 0;

#ifdef WIN32
    if (sdl2_windows_angle_preferred &&
        sdl2_gl_provider_state != SDL2_GL_PROVIDER_NATIVE_SELECTED) {
        /*
         * ANGLE 的稳定基线是 GLES 3.0，
         * 且窗口/FBO 路径需要 glBlitFramebuffer。
         */
        gles = true;
    }
#endif

    if (gles) {
        profile = SDL_GL_CONTEXT_PROFILE_ES;
        major = 3;
        minor = 0;
    }

    /*
     * 这些属性参与 SDL_CreateWindow 内部的
     * EGLConfig/GLXFBConfig 选择，
     * 必须在每次尝试前完整重设。尤其 ANGLE 失败转 WGL 时，
     * 不能遗留 ES profile。
     */
    if (SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, profile) < 0 ||
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, major) < 0 ||
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, minor) < 0) {
        return -1;
    }

    return 0;
}

bool sdl2_gl_provider_retry_native(void)
{
#if defined(SDL_HINT_VIDEO_X11_FORCE_EGL) && defined(CONFIG_X11)
    if (sdl2_gl_provider_state == SDL2_GL_PROVIDER_EGL_COMMITTED ||
        !sdl2_current_video_driver_is_x11() ||
        !SDL_GetHintBoolean(SDL_HINT_VIDEO_X11_FORCE_EGL, SDL_FALSE)) {
        return false;
    }

    /*
     * 首次 EGL window/context 已经失败。
     * 必须用 OVERRIDE 压过环境变量级 hint，
     * 否则第二次 SDL_CreateWindow 仍会进入失败的 EGL loader。
     */
    if (SDL_SetHintWithPriority(SDL_HINT_VIDEO_X11_FORCE_EGL, "0",
                                SDL_HINT_OVERRIDE) != SDL_TRUE) {
        return false;
    }

    qemu_egl_display = EGL_NO_DISPLAY;
    sdl2_gl_provider_state = SDL2_GL_PROVIDER_NATIVE_SELECTED;
    return true;
#endif

#ifdef WIN32
    if (sdl2_gl_provider_state == SDL2_GL_PROVIDER_EGL_COMMITTED ||
        !sdl2_windows_angle_preferred) {
        return false;
    }

    /*
     * ANGLE/EGL 创建失败后切回桌面 WGL。
     * OVERRIDE 同样用于压过外部环境 hint，
     * 否则第二次创建 context 时，
     * 仍会切到 WIN_GLES provider。
     */
    if (SDL_SetHintWithPriority(SDL_HINT_OPENGL_ES_DRIVER, "0",
                                SDL_HINT_OVERRIDE) != SDL_TRUE) {
        return false;
    }

    qemu_egl_display = EGL_NO_DISPLAY;
    qemu_egl_angle_d3d = false;
    sdl2_gl_provider_state = SDL2_GL_PROVIDER_NATIVE_SELECTED;
    return true;
#endif

#if !(defined(SDL_HINT_VIDEO_X11_FORCE_EGL) && defined(CONFIG_X11)) && \
    !defined(WIN32)
    return false;
#endif
}

bool sdl2_gl_provider_egl_committed(void)
{
    return sdl2_gl_provider_state == SDL2_GL_PROVIDER_EGL_COMMITTED;
}

bool sdl2_gl_provider_uses_gles(void)
{
    return sdl2_gl_provider_state == SDL2_GL_PROVIDER_EGL_COMMITTED &&
           qemu_egl_mode == DISPLAY_GL_MODE_ES;
}

const char *sdl2_gl_provider_native_name(void)
{
#if defined(CONFIG_X11)
    if (g_strcmp0(SDL_GetCurrentVideoDriver(), "x11") == 0) {
        return "GLX";
    }
#endif
#ifdef WIN32
    return "WGL";
#else
    return "native OpenGL";
#endif
}

#ifdef WIN32
static void sdl2_gl_provider_detect_angle_d3d11(void)
{
    qemu_egl_angle_d3d = false;

#ifdef EGL_D3D11_DEVICE_ANGLE
    if (epoxy_has_egl_extension(qemu_egl_display,
                                "EGL_EXT_device_query")) {
        EGLDeviceEXT device;
        void *d3d11_device;

        if (eglQueryDisplayAttribEXT(qemu_egl_display, EGL_DEVICE_EXT,
                                     (EGLAttrib *)&device) &&
            eglQueryDeviceAttribEXT(device, EGL_D3D11_DEVICE_ANGLE,
                                    (EGLAttrib *)&d3d11_device)) {
            qemu_egl_angle_d3d = d3d11_device != NULL;
        }
    }
#endif
}
#endif

void sdl2_gl_provider_context_ready(void)
{
    EGLDisplay display = eglGetCurrentDisplay();
    bool first_commit;

    /*
     * 不按操作系统猜 provider。
     * SDL 在 Windows 上可能选择 WGL，也可能选择 EGL/ANGLE；
     * eglGetCurrentDisplay() 只有在当前 context 属于 EGL 时，
     * 才返回有效句柄，
     * 因此同一判断同时覆盖 X11 EGL 和 Windows ANGLE。
     */
    if (display != EGL_NO_DISPLAY) {
        first_commit =
            sdl2_gl_provider_state != SDL2_GL_PROVIDER_EGL_COMMITTED;
        qemu_egl_display = display;

        /*
         * Windows 的 gl=on 已转为 GLES；
         * 其它平台沿用用户请求的 API。
         */
#ifdef WIN32
        qemu_egl_mode = sdl2_windows_angle_preferred ?
                        DISPLAY_GL_MODE_ES : sdl2_gl_requested_mode;
        sdl2_gl_provider_detect_angle_d3d11();
#else
        qemu_egl_mode = sdl2_gl_requested_mode == DISPLAY_GL_MODE_ES ?
                        DISPLAY_GL_MODE_ES : DISPLAY_GL_MODE_CORE;
#endif
        sdl2_gl_provider_state = SDL2_GL_PROVIDER_EGL_COMMITTED;
        if (first_commit) {
#ifdef WIN32
            info_report("SDL: EGL provider active (ANGLE D3D11=%s)",
                        qemu_egl_angle_d3d ? "yes" : "no");
#else
            info_report("SDL: EGL provider active");
#endif
        }
    } else if (sdl2_gl_provider_state != SDL2_GL_PROVIDER_EGL_COMMITTED) {
        first_commit =
            sdl2_gl_provider_state != SDL2_GL_PROVIDER_NATIVE_COMMITTED;
        qemu_egl_display = EGL_NO_DISPLAY;
        qemu_egl_angle_d3d = false;
        sdl2_gl_provider_state = SDL2_GL_PROVIDER_NATIVE_COMMITTED;
        if (first_commit) {
            info_report("SDL: %s provider active",
                        sdl2_gl_provider_native_name());
        }
    }
}

#ifndef QEMU_UI_SDL2_EGL_H
#define QEMU_UI_SDL2_EGL_H

#include <stdbool.h>
#include "ui/console.h"

/*
 * SDL OpenGL provider 的进程级状态机。
 *
 * SDL 的 X11 EGL/GLX 选择由全局 hint 和全局 GL loader 控制，
 * 不能让每个 console 独立决定 provider。
 * 这里把探测、提交和失败回退收口，
 * 避免窗口生命周期代码直接操作
 * SDL hint 或 QEMU 的全局 EGLDisplay。
 */
void sdl2_gl_provider_prepare(DisplayGLMode mode);
int sdl2_gl_provider_configure_window(DisplayGLMode mode);
bool sdl2_gl_provider_retry_native(void);
bool sdl2_gl_provider_egl_committed(void);
bool sdl2_gl_provider_uses_gles(void);
const char *sdl2_gl_provider_native_name(void);
void sdl2_gl_provider_context_ready(void);

#endif /* QEMU_UI_SDL2_EGL_H */

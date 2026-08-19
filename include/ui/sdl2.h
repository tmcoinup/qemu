#ifndef SDL2_H
#define SDL2_H

/* Avoid compiler warning because macro is redefined in SDL_syswm.h. */
#undef WIN32_LEAN_AND_MEAN

#include <SDL.h>

/* with Alpine / muslc SDL headers pull in directfb headers
 * which in turn trigger warning about redundant decls for
 * direct_waitqueue_deinit.
 */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wredundant-decls"

#include <SDL_syswm.h>

#pragma GCC diagnostic pop

#ifdef CONFIG_SDL_IMAGE
# include <SDL_image.h>
#endif

#include "ui/kbd-state.h"
#include "ui/sdl2-display-policy.h"
#include "ui/sdl2-event.h"
#include "ui/sdl2-pointer.h"
#ifdef CONFIG_OPENGL
# include "ui/egl-helpers.h"
#endif

struct sdl2_console {
    DisplayGLCtx dgc;
    DisplayChangeListener dcl;
    DisplaySurface *surface;
    DisplayOptions *opts;
    SDL_Texture *texture;
    SDL_Window *real_window;
    SDL_Renderer *real_renderer;
    int idx;
    int last_vm_running; /* per console for caption reasons */
    int x, y, w, h;
    int hidden;
    int opengl;
    int updates;
    int idle_counter;
    int ignore_hotkeys;
    bool window_redraw_pending;
    bool window_resize_pending;
    SDL2Size window_maximum;
    int64_t fps_window_start_us;
    uint32_t fps_frame_count;
    double present_fps;
    bool present_fps_valid;
    uint8_t fps_low_warmup_windows;
    bool fixed_present;
    bool presented_since_refresh;
    bool gui_keysym;
    /* Keyboard follows input focus.  Pointer events additionally require
     * mouse focus (or an active grab); SDL/XWayland does not guarantee that
     * keyboard focus and mouse-enter events arrive together. */
    bool has_input_focus;
    bool has_mouse_focus;
    bool absolute_enabled;
    bool absolute_available;
    uint32_t mouse_button_state;
    bool guest_cursor;
    int guest_x;
    int guest_y;
    SDL_Surface *guest_sprite_surface;
    SDL_Cursor *guest_sprite;
    SDL2AxisScale window_to_render_x;
    SDL2AxisScale window_to_render_y;
    SDL2AxisScale render_to_guest_x;
    SDL2AxisScale render_to_guest_y;
    SDL_GLContext winctx;
    QKbdState *kbd;
    bool has_dmabuf;
#ifdef CONFIG_OPENGL
    QemuGLShader *gls;
    egl_fb guest_fb;
    egl_fb win_fb;
    bool y0_top;
    bool scanout_mode;
    bool native_egl;
    uintptr_t native_egl_window;
    uintptr_t native_egl_colormap;
    EGLContext ectx;
    EGLSurface esurface;
    int native_egl_owner_tid;
    bool logged_native_egl_visual;
    bool logged_scanout_texture;
    bool logged_scanout_flush;
    bool warned_missing_scanout_fb;
    bool warned_native_egl_blit;
    bool warned_native_egl_make_current;
    bool warned_native_egl_release;
#endif
};

/*
 * 统一 2D、GL 和 native-EGL 的可见性判定。
 * 最小化或显式隐藏时保留最后一帧和待处理更新，
 * 但不再 resize/map/swap 宿主窗口。
 */
static inline bool
sdl2_window_is_renderable(const struct sdl2_console *scon)
{
    return scon && scon->real_window &&
           sdl2_window_updates_allowed(
               SDL_GetWindowFlags(scon->real_window), scon->hidden);
}

/* Dimensions of the image that the current SDL path actually renders. */
static inline bool sdl2_current_guest_size(const struct sdl2_console *scon,
                                           SDL2Size *guest)
{
    SDL2Size surface = { 0 };
    SDL2Size scanout = { 0 };
    bool scanout_mode = false;

    if (!scon || !guest) {
        return false;
    }
    if (scon->surface) {
        surface.width = surface_width(scon->surface);
        surface.height = surface_height(scon->surface);
    }
#ifdef CONFIG_OPENGL
    if (scon->opengl && scon->scanout_mode) {
        scanout_mode = true;
        /* G-11 currently renders the complete scanout backing framebuffer. */
        scanout.width = scon->guest_fb.width;
        scanout.height = scon->guest_fb.height;
    }
#endif
    return sdl2_select_guest_size(scanout_mode, surface, scanout, guest);
}

/*
 * SDL mouse events use logical window pixels.  Rendering may use a larger
 * SDL drawable/renderer output on high-DPI displays, or a native EGL child.
 */
static inline bool sdl2_current_render_size(const struct sdl2_console *scon,
                                            SDL2Size *render)
{
    if (!scon || !scon->real_window || !render) {
        return false;
    }

    *render = (SDL2Size) { 0 };
    if (scon->opengl) {
#ifdef CONFIG_OPENGL
        if (scon->native_egl && scon->esurface != EGL_NO_SURFACE &&
            qemu_egl_display) {
            EGLint width = 0;
            EGLint height = 0;

            if (eglQuerySurface(qemu_egl_display, scon->esurface,
                                EGL_WIDTH, &width) &&
                eglQuerySurface(qemu_egl_display, scon->esurface,
                                EGL_HEIGHT, &height)) {
                render->width = width;
                render->height = height;
            }
        } else {
            SDL_GL_GetDrawableSize(scon->real_window,
                                   &render->width, &render->height);
        }
#endif
    } else if (scon->real_renderer &&
               SDL_GetRendererOutputSize(scon->real_renderer,
                                         &render->width,
                                         &render->height) != 0) {
        *render = (SDL2Size) { 0 };
    }

    if (render->width <= 0 || render->height <= 0) {
        SDL_GetWindowSize(scon->real_window,
                          &render->width, &render->height);
    }
    return render->width > 0 && render->height > 0;
}

/*
 * Centred destination rectangle for a gw*gh guest surface inside a ww*wh
 * window.  The guest is shown at its native resolution and is never magnified
 * beyond 1:1: a larger window is letterboxed / pillarboxed (black borders)
 * instead of upscaling, while a smaller window shrinks the image to fit,
 * preserving the aspect ratio (so nothing is ever clipped).  Used for both the
 * GL viewport and the absolute-pointer mapping so the guest cursor stays
 * aligned with the visible picture.
 */
static inline void sdl2_gfx_dst_rect(int ww, int wh, int gw, int gh,
                                     int *px, int *py, int *pw, int *ph)
{
    SDL2Rect dst = sdl2_guest_dst_rect(
        (SDL2Size) { ww, wh }, (SDL2Size) { gw, gh });

    *px = dst.x;
    *py = dst.y;
    *pw = dst.width;
    *ph = dst.height;
}

void sdl2_window_create(struct sdl2_console *scon);
void sdl2_window_destroy(struct sdl2_console *scon);
void sdl2_window_update_size_limits(struct sdl2_console *scon);
void sdl2_window_resize(struct sdl2_console *scon);
void sdl2_poll_events(struct sdl2_console *scon);
void sdl2_flush_window_updates(void);
void sdl2_note_present(struct sdl2_console *scon);

void sdl2_process_key(struct sdl2_console *scon,
                      SDL_KeyboardEvent *ev);
void sdl2_release_modifiers(struct sdl2_console *scon);

void sdl2_2d_update(DisplayChangeListener *dcl,
                    int x, int y, int w, int h);
void sdl2_2d_switch(DisplayChangeListener *dcl,
                    DisplaySurface *new_surface);
void sdl2_2d_refresh(DisplayChangeListener *dcl);
void sdl2_2d_redraw(struct sdl2_console *scon);
bool sdl2_2d_check_format(DisplayChangeListener *dcl,
                          pixman_format_code_t format);

void sdl2_gl_update(DisplayChangeListener *dcl,
                    int x, int y, int w, int h);
void sdl2_gl_switch(DisplayChangeListener *dcl,
                    DisplaySurface *new_surface);
void sdl2_gl_refresh(DisplayChangeListener *dcl);
void sdl2_gl_redraw(struct sdl2_console *scon);

QEMUGLContext sdl2_gl_create_context(DisplayGLCtx *dgc,
                                     QEMUGLParams *params);
void sdl2_gl_destroy_context(DisplayGLCtx *dgc, QEMUGLContext ctx);
int sdl2_gl_make_context_current(DisplayGLCtx *dgc,
                                 QEMUGLContext ctx);

void sdl2_gl_scanout_disable(DisplayChangeListener *dcl);
void sdl2_gl_scanout_texture(DisplayChangeListener *dcl,
                             uint32_t backing_id,
                             bool backing_y_0_top,
                             uint32_t backing_width,
                             uint32_t backing_height,
                             uint32_t x, uint32_t y,
                             uint32_t w, uint32_t h,
                             void *d3d_tex2d);
#ifdef CONFIG_GBM
void sdl2_gl_scanout_dmabuf(DisplayChangeListener *dcl,
                            QemuDmaBuf *dmabuf);
void sdl2_gl_release_dmabuf(DisplayChangeListener *dcl,
                            QemuDmaBuf *dmabuf);
#endif
void sdl2_gl_scanout_flush(DisplayChangeListener *dcl,
                           uint32_t x, uint32_t y, uint32_t w, uint32_t h);
void sdl2_gl_console_init(struct sdl2_console *scon);

#endif /* SDL2_H */

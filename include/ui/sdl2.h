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
    int ignore_hotkeys;
    bool window_redraw_pending;
    bool ui_info_pending;
    bool gui_keysym;
    /*
     * 输入门控：键鼠事件只在窗口同时拥有 X11 输入焦点(FOCUS_GAINED)
     * 和鼠标焦点(ENTER, 即指针在窗内) 时才下发给 guest。
     * 任一条件失守 -> 把当前所有按下的键 lift 掉, 后续事件丢弃,
     * 防止"窗外按键打到 guest"以及焦点切换时 guest 卡键。
     */
    bool has_input_focus;
    bool has_mouse_focus;
    bool fullscreen;
    bool auto_fullscreen;
    bool saved_grab;
    bool absolute_enabled;
    bool absolute_available;
    uint32_t mouse_button_state;
    bool guest_cursor;
    int guest_x;
    int guest_y;
    SDL2AxisScale window_to_render_x;
    SDL2AxisScale window_to_render_y;
    SDL2AxisScale render_to_guest_x;
    SDL2AxisScale render_to_guest_y;
    SDL_Surface *guest_sprite_surface;
    SDL_Cursor *guest_sprite;
    SDL_GLContext winctx;
    QKbdState *kbd;
    bool has_dmabuf;
#ifdef CONFIG_OPENGL
    QemuGLShader *gls;
    egl_fb guest_fb;
    bool y0_top;
    bool scanout_mode;
    bool scanout_redraw_pending;
#endif
};

/*
 * Keep pointer mapping on the same dimensions as the active SDL renderer.
 * GL scanout can expose a sub-rectangle of a larger backing texture, so input
 * follows the visible scanout dimensions rather than the backing allocation.
 * Surface mode and the 2D renderer use the DisplaySurface dimensions.
 */
static inline bool sdl2_current_guest_size(const struct sdl2_console *scon,
                                           SDL2Size *guest)
{
    SDL2Size surface = { 0 };
    SDL2Size scanout = { 0 };
    bool scanout_mode = false;

    if (scon->surface) {
        surface.width = surface_width(scon->surface);
        surface.height = surface_height(scon->surface);
    }
#ifdef CONFIG_OPENGL
    if (scon->opengl && scon->scanout_mode) {
        scanout_mode = true;
        scanout.width = scon->w;
        scanout.height = scon->h;
    }
#endif
    return sdl2_select_guest_size(scanout_mode, surface, scanout, guest);
}

/*
 * Return the pixel dimensions of the active rendering target.  SDL mouse
 * events use logical window coordinates, while a high-DPI renderer or GL
 * drawable can contain more pixels; callers explicitly bridge the two spaces.
 */
static inline bool sdl2_current_render_size(const struct sdl2_console *scon,
                                            SDL2Size *render)
{
    if (!scon || !scon->real_window || !render) {
        return false;
    }

    *render = (SDL2Size) { 0 };
    if (scon->opengl) {
        SDL_GL_GetDrawableSize(scon->real_window,
                               &render->width, &render->height);
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

void sdl2_window_create(struct sdl2_console *scon);
void sdl2_window_destroy(struct sdl2_console *scon);
void sdl2_window_resize(struct sdl2_console *scon);
void sdl2_poll_events(struct sdl2_console *scon);
void sdl2_flush_window_updates(void);

bool sdl2_input_allowed(const struct sdl2_console *scon);
void sdl2_sync_text_input(struct sdl2_console *consoles, int num_outputs);
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
void sdl2_gl_save_current_context(DisplayGLCtx *dgc,
                                  QEMUGLContextState *state);
int sdl2_gl_restore_current_context(DisplayGLCtx *dgc,
                                    const QEMUGLContextState *state);
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
void sdl2_gl_scanout_flush(DisplayChangeListener *dcl,
                           uint32_t x, uint32_t y, uint32_t w, uint32_t h);
void sdl2_gl_scanout_dmabuf(DisplayChangeListener *dcl,
                            QemuDmaBuf *dmabuf);
void sdl2_gl_release_dmabuf(DisplayChangeListener *dcl,
                            QemuDmaBuf *dmabuf);
bool sdl2_gl_has_dmabuf(DisplayChangeListener *dcl);
void sdl2_gl_console_init(struct sdl2_console *scon);

#endif /* SDL2_H */

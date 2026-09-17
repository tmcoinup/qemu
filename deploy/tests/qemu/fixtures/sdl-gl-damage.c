/*
 * SDL display control-flow harness. Production functions are inserted by
 * test_sdl_gl_damage_batch.sh; only external GL/window/producer/refresh-clock
 * boundaries are replaced with deterministic controls and counters.
 * No copied scheduling logic.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>

#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define container_of(ptr, type, member) \
    ((type *)((char *)(ptr) - offsetof(type, member)))
#define SDL2_GL_RECOVERY_RETRY_US 100000
#define GL_NO_ERROR 0
#define EGL_SUCCESS 0
#define GL_READ_FRAMEBUFFER 1
#define GL_DRAW_FRAMEBUFFER 2
#define GL_BACK 3
#define GL_FALSE false
#define GL_TRUE true
#define GL_COLOR_BUFFER_BIT 4
#define qatomic_read(ptr) (*(ptr))

typedef unsigned int GLenum;
typedef int EGLint;
typedef struct SDL2Size { int width, height; } SDL2Size;
typedef struct SDL2Rect { int x, y, width, height; } SDL2Rect;
typedef struct DisplaySurface {
    unsigned int texture;
    int width, height;
    unsigned int version;
    bool placeholder;
} DisplaySurface;
typedef struct DisplayChangeListener { void *con; } DisplayChangeListener;
typedef struct Framebuffer { unsigned int framebuffer; } Framebuffer;
struct sdl2_console {
    DisplayChangeListener dcl;
    DisplaySurface *surface;
    void *gls;
    void *real_window;
    Framebuffer guest_fb;
    SDL2Rect surface_damage;
    int updates, w, h;
    bool opengl, visible, native_egl, native_egl_context_api;
    bool native_egl_context_lost, scanout_mode;
    bool scanout_replay_pending, scanout_replay_in_progress;
    bool surface_upload_pending, texture_recreate_pending;
    bool warned_gl_surface_texture, window_redraw_pending;
    bool window_resize_pending, fixed_present, presented_since_refresh;
    bool content_update_pending;
    int64_t texture_recreate_after_us, scanout_replay_after_us;
};

static struct sdl2_console console;
static DisplaySurface surface;
static int sdl2_native_egl_async_terminal_error;
static int64_t now_us;
static bool context_available, fail_upload, fail_create, refresh_due;
static unsigned int creates, uploads, draws, presents, context_entries;
static unsigned int content_updates, pulled, texture_version;
static unsigned int events_polled, refresh_checks;
static GLenum current_error;
static SDL2Rect last_upload;
static void (*producer_update)(void);

/* PRODUCTION PROTOTYPES */

static void mock_log(const char *format, ...) { (void)format; }
#define info_report(...) mock_log(__VA_ARGS__)
#define warn_report(...) mock_log(__VA_ARGS__)
static int surface_width(DisplaySurface *s) { return s->width; }
static int surface_height(DisplaySurface *s) { return s->height; }
static bool surface_is_placeholder(DisplaySurface *s) { return s->placeholder; }
static int qemu_console_get_index(void *con) { (void)con; return 0; }
static int64_t g_get_monotonic_time(void) { return now_us; }
static bool sdl2_window_is_renderable(const struct sdl2_console *s)
{
    return s->real_window && s->visible;
}
static void sdl2_pointer_geometry_changed(struct sdl2_console *s) { (void)s; }
static void sdl2_framebuffer_cursor_reset(struct sdl2_console *s) { (void)s; }
static void sdl2_framebuffer_cursor_update(struct sdl2_console *s) { (void)s; }
static void egl_fb_destroy(Framebuffer *fb) { fb->framebuffer = 0; }
static void surface_gl_destroy_texture(void *shader, DisplaySurface *s)
{
    (void)shader;
    if (s) {
        s->texture = 0;
    }
}
static void surface_gl_create_texture(void *shader, DisplaySurface *s)
{
    (void)shader;
    creates++;
    s->texture = fail_create ? 0 : creates + 100;
    current_error = fail_create ? 0x505 : GL_NO_ERROR;
    texture_version = s->version;
}
static bool surface_gl_update_texture(void *shader, DisplaySurface *s,
                                       int x, int y, int w, int h)
{
    (void)shader;
    assert(s->texture && sdl2_window_is_renderable(&console));
    uploads++;
    last_upload = (SDL2Rect) { x, y, w, h };
    texture_version = s->version;
    return !fail_upload;
}
static GLenum glGetError(void)
{
    GLenum result = current_error;
    current_error = GL_NO_ERROR;
    return result;
}
static void sdl2_gl_clear_errors(void) { current_error = GL_NO_ERROR; }
static int sdl2_gl_make_window_current(struct sdl2_console *s)
{
    (void)s;
    context_entries++;
    return context_available ? 0 : -1;
}
static void sdl2_gl_release_window_current(struct sdl2_console *s) { (void)s; }
static bool sdl2_gl_window_ready(struct sdl2_console *s)
{
    return s->real_window && context_available;
}
static bool sdl2_gl_recover_native_egl_surface(struct sdl2_console *s)
{
    (void)s;
    return context_available;
}
static DisplaySurface *qemu_console_surface(void *con)
{
    return ((struct sdl2_console *)con)->surface;
}
static void sdl2_window_create(struct sdl2_console *s) { s->real_window = s; }
static void sdl2_window_destroy(struct sdl2_console *s) { s->real_window = NULL; }
static void sdl2_window_resize(struct sdl2_console *s)
{
    s->window_resize_pending = !sdl2_window_is_renderable(s);
}
static void *qemu_gl_init_shader(void) { return &console; }
static bool sdl2_current_render_size(struct sdl2_console *s, SDL2Size *size)
{
    *size = (SDL2Size) { s->surface->width, s->surface->height };
    return true;
}
static SDL2Rect sdl2_guest_dst_rect(SDL2Size output, SDL2Size guest)
{
    (void)output;
    return (SDL2Rect) { 0, 0, guest.width, guest.height };
}
static SDL2Rect sdl2_gl_viewport(SDL2Size output, SDL2Rect dst)
{
    (void)output;
    return dst;
}
static void glBindFramebuffer(GLenum target, unsigned int id)
{
    (void)target; (void)id;
}
static void glDrawBuffer(GLenum buffer) { (void)buffer; }
static void glReadBuffer(GLenum buffer) { (void)buffer; }
static void glViewport(int x, int y, int w, int h)
{
    (void)x; (void)y; (void)w; (void)h;
}
static void glColorMask(bool r, bool g, bool b, bool a)
{
    (void)r; (void)g; (void)b; (void)a;
}
static void glClearColor(float r, float g, float b, float a)
{
    (void)r; (void)g; (void)b; (void)a;
}
static void glClear(GLenum mask) { (void)mask; }
static void surface_gl_render_texture(void *shader, DisplaySurface *s)
{
    (void)shader;
    assert(s->texture && sdl2_window_is_renderable(&console));
    draws++;
}
static bool sdl2_gl_swap_window(struct sdl2_console *s)
{
    presents++;
    s->presented_since_refresh = true;
    return true;
}
static void sdl2_note_content_update(struct sdl2_console *s)
{
    if (!s->content_update_pending) {
        content_updates++;
        s->content_update_pending = true;
    }
}
static void sdl2_poll_events(struct sdl2_console *s)
{
    (void)s;
    events_polled++;
}
static bool sdl2_refresh_due(struct sdl2_console *s)
{
    (void)s;
    refresh_checks++;
    return refresh_due;
}
static void sdl2_gl_note_egl_failure(struct sdl2_console *s,
                                     const char *operation, EGLint error)
{
    (void)s; (void)operation; (void)error;
    assert(false);
}
static void dpy_gl_replay_current_scanout(DisplayChangeListener *dcl)
{
    (void)dcl;
    assert(false);
}
static void graphic_hw_update(void *con)
{
    (void)con;
    pulled++;
    if (producer_update) {
        producer_update();
    }
}
static void sdl2_flush_window_updates(void)
{
    if (console.window_redraw_pending &&
        sdl2_window_is_renderable(&console)) {
        console.window_redraw_pending = false;
        sdl2_gl_redraw(&console);
    }
}
static void sdl2_gl_scanout_flush(DisplayChangeListener *dcl,
                                  unsigned int x, unsigned int y,
                                  unsigned int w, unsigned int h)
{
    (void)dcl; (void)x; (void)y; (void)w; (void)h;
}

/* PRODUCTION DEFINITIONS */

static void reset_fixture(void)
{
    console = (struct sdl2_console) {
        .surface = &surface, .gls = &console, .real_window = &console,
        .opengl = true, .visible = true, .fixed_present = true,
    };
    console.dcl.con = &console;
    surface = (DisplaySurface) { .texture = 42, .width = 600, .height = 400 };
    now_us = 1000000;
    context_available = refresh_due = true;
    fail_create = fail_upload = false;
    creates = uploads = draws = presents = context_entries = 0;
    content_updates = pulled = events_polled = refresh_checks = 0;
    current_error = texture_version = 0;
    last_upload = (SDL2Rect) { 0 };
    producer_update = NULL;
}

static void assert_box(SDL2Rect box, int x, int y, int w, int h)
{
    assert(box.x == x && box.y == y && box.width == w && box.height == h);
}

static void test_batched_upload_and_fixed_redraw(void)
{
    reset_fixture();
    sdl2_gl_update(&console.dcl, 10, 20, 20, 30);
    sdl2_gl_update(&console.dcl, 40, 10, 30, 20);
    sdl2_gl_update(&console.dcl, 20, 40, 10, 30);
    surface.version = 3;
    assert(uploads == 0 && creates == 0 && context_entries == 0);
    assert(content_updates == 1 && console.updates == 1);
    assert_box(console.surface_damage, 10, 10, 60, 60);
    sdl2_gl_refresh(&console.dcl);
    assert(uploads == 1 && creates == 0 && presents == 1);
    assert(texture_version == 3 && console.updates == 0);
    assert_box(last_upload, 10, 10, 60, 60);
    assert_box(console.surface_damage, 0, 0, 0, 0);
    sdl2_gl_refresh(&console.dcl);
    assert(uploads == 1 && creates == 0 && presents == 2);
    assert(content_updates == 1);
}

static void test_new_surface_uploads_latest_once(void)
{
    DisplaySurface next = { .width = 800, .height = 600, .version = 1 };
    reset_fixture();
    sdl2_gl_update(&console.dcl, 100, 100, 50, 50);
    sdl2_gl_switch(&console.dcl, &next);
    assert(uploads == 0 && creates == 0);
    assert_box(console.surface_damage, 0, 0, 0, 0);
    next.version = 4;
    sdl2_gl_update(&console.dcl, 10, 20, 30, 40);
    sdl2_gl_refresh(&console.dcl);
    assert(creates == 1 && uploads == 0 && presents == 1);
    assert(texture_version == 4 && console.updates == 0);
    assert(!console.surface_upload_pending);
    assert_box(console.surface_damage, 0, 0, 0, 0);
    sdl2_gl_refresh(&console.dcl);
    assert(creates == 1 && uploads == 0 && presents == 2);
}

static void test_upload_failure_retains_damage(void)
{
    reset_fixture();
    sdl2_gl_update(&console.dcl, 10, 20, 30, 40);
    fail_upload = true;
    sdl2_gl_refresh(&console.dcl);
    assert(uploads == 1 && creates == 0 && presents == 0);
    assert(console.texture_recreate_pending && console.updates == 1);
    assert_box(console.surface_damage, 10, 20, 30, 40);
    sdl2_gl_refresh(&console.dcl);
    assert(uploads == 1 && creates == 0 && presents == 0);
    fail_upload = false;
    now_us += SDL2_GL_RECOVERY_RETRY_US;
    sdl2_gl_refresh(&console.dcl);
    assert(uploads == 1 && creates == 1 && presents == 1);
    assert(!console.texture_recreate_pending && console.updates == 0);
    assert_box(console.surface_damage, 0, 0, 0, 0);
    assert(content_updates == 1);
}

static void test_creation_failure_retains_damage(void)
{
    reset_fixture();
    surface.texture = 0;
    sdl2_gl_update(&console.dcl, 10, 20, 30, 40);
    fail_create = true;
    sdl2_gl_refresh(&console.dcl);
    assert(creates == 1 && uploads == 0 && presents == 0);
    assert_box(console.surface_damage, 10, 20, 30, 40);
    fail_create = false;
    now_us += SDL2_GL_RECOVERY_RETRY_US;
    sdl2_gl_refresh(&console.dcl);
    assert(creates == 2 && uploads == 0 && presents == 1);
    assert_box(console.surface_damage, 0, 0, 0, 0);
}

static void test_hidden_restore_uploads_once(void)
{
    reset_fixture();
    console.visible = false;
    for (int i = 0; i < 1000; i++) {
        sdl2_gl_update(&console.dcl, 10, 20, 30, 40);
    }
    assert(uploads == 0 && creates == 0 && context_entries == 0);
    sdl2_gl_refresh(&console.dcl);
    assert(console.surface_upload_pending && console.updates == 1);
    assert(uploads == 0 && creates == 0 && presents == 0);
    console.visible = true;
    sdl2_gl_refresh(&console.dcl);
    assert(uploads == 1 && creates == 0 && presents == 1);
    assert_box(last_upload, 0, 0, 600, 400);
    assert(!console.surface_upload_pending);
    assert_box(console.surface_damage, 0, 0, 0, 0);
    assert(content_updates == 0);
}

static void test_context_failure_retains_damage(void)
{
    reset_fixture();
    context_available = false;
    sdl2_gl_update(&console.dcl, 10, 20, 30, 40);
    sdl2_gl_refresh(&console.dcl);
    assert(uploads == 0 && creates == 0 && presents == 0);
    assert_box(console.surface_damage, 10, 20, 30, 40);
    context_available = true;
    sdl2_gl_refresh(&console.dcl);
    assert(uploads == 1 && creates == 0 && presents == 1);
    assert_box(last_upload, 10, 20, 30, 40);
}

static void test_scanout_return_defers_surface_upload(void)
{
    reset_fixture();
    sdl2_gl_update(&console.dcl, 10, 20, 30, 40);
    sdl2_set_scanout_mode(&console, true);
    assert_box(console.surface_damage, 0, 0, 0, 0);
    sdl2_gl_scanout_disable(&console.dcl);
    assert(creates == 0 && uploads == 0);
    assert(console.surface_upload_pending && console.texture_recreate_pending);
    sdl2_gl_refresh(&console.dcl);
    assert(creates == 1 && uploads == 0 && presents == 1);
    assert_box(console.surface_damage, 0, 0, 0, 0);
}

static void test_scanout_return_without_context(void)
{
    reset_fixture();
    sdl2_set_scanout_mode(&console, true);
    context_available = false;
    sdl2_gl_scanout_disable(&console.dcl);
    assert(!console.scanout_mode && console.surface_upload_pending);
    assert(console.texture_recreate_pending);
    assert(creates == 0 && uploads == 0);
    context_available = true;
    sdl2_gl_refresh(&console.dcl);
    assert(creates == 1 && uploads == 0 && presents == 1);
    assert(!console.surface_upload_pending);
}

static void publish_latest_damage(void)
{
    surface.version = 8;
    sdl2_gl_update(&console.dcl, 10, 20, 30, 40);
}

static void test_refresh_not_due_preserves_damage(void)
{
    reset_fixture();
    surface.version = 4;
    sdl2_gl_update(&console.dcl, 10, 20, 30, 40);
    producer_update = publish_latest_damage;
    refresh_due = false;

    sdl2_gl_refresh(&console.dcl);
    sdl2_gl_refresh(&console.dcl);
    assert(events_polled == 2 && refresh_checks == 2);
    assert(pulled == 0 && context_entries == 0);
    assert(creates == 0 && uploads == 0 && draws == 0 && presents == 0);
    assert(surface.version == 4 && console.updates == 1);
    assert(console.content_update_pending && content_updates == 1);
    assert_box(console.surface_damage, 10, 20, 30, 40);

    refresh_due = true;
    sdl2_gl_refresh(&console.dcl);
    assert(events_polled == 3 && refresh_checks == 3);
    assert(pulled == 1 && uploads == 1 && creates == 0);
    assert(draws == 1 && presents == 1 && texture_version == 8);
    assert(console.updates == 0 && !console.content_update_pending);
    assert_box(last_upload, 10, 20, 30, 40);
    assert_box(console.surface_damage, 0, 0, 0, 0);

    /* Fixed presentation must also wait when the existing texture is clean. */
    refresh_due = false;
    sdl2_gl_refresh(&console.dcl);
    assert(events_polled == 4 && refresh_checks == 4);
    assert(pulled == 1 && uploads == 1 && draws == 1 && presents == 1);
}

static void test_window_redraw_waits_for_producer(void)
{
    reset_fixture();
    console.window_redraw_pending = true;
    producer_update = publish_latest_damage;
    sdl2_gl_refresh(&console.dcl);
    assert(pulled == 1 && uploads == 1 && creates == 0 && presents == 1);
    assert(texture_version == 8 && console.updates == 0);
    assert(!console.window_redraw_pending);
    assert_box(console.surface_damage, 0, 0, 0, 0);
}

int main(void)
{
    test_batched_upload_and_fixed_redraw();
    test_new_surface_uploads_latest_once();
    test_upload_failure_retains_damage();
    test_creation_failure_retains_damage();
    test_hidden_restore_uploads_once();
    test_context_failure_retains_damage();
    test_scanout_return_defers_surface_upload();
    test_scanout_return_without_context();
    test_refresh_not_due_preserves_damage();
    test_window_redraw_waits_for_producer();
    puts("OK: 10 SDL damage/update/render production-flow regressions passed");
    return 0;
}

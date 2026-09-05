/*
 * Real offscreen GL regressions for surface upload and rendering.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include <epoxy/egl.h>
#include "ui/console.h"
#include "ui/sdl2-display-policy.h"

#ifdef CONFIG_GBM
#include <gbm.h>
#endif

static EGLDisplay test_display = EGL_NO_DISPLAY;
static EGLContext test_context = EGL_NO_CONTEXT;
static QemuGLShader *test_shader;
static GLuint test_framebuffer;
static GLuint test_color_texture;
static const char *unavailable;
static int render_fd = -1;
#ifdef CONFIG_GBM
static struct gbm_device *test_gbm;
#endif

static bool init_offscreen(void)
{
    const char *render_node = g_getenv("QEMU_TEST_GL_RENDER_NODE");
    const char *extensions = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
    const EGLint config_attrs[] = {
        EGL_SURFACE_TYPE, 0,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
        EGL_NONE,
    };
    const EGLint context_attrs[] = {
        EGL_CONTEXT_MAJOR_VERSION, 3,
        EGL_CONTEXT_MINOR_VERSION, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        EGL_NONE,
    };
    EGLConfig config;
    EGLint count;

    if (!extensions || !strstr(extensions, "EGL_EXT_platform_base")) {
        unavailable = "EGL_EXT_platform_base is unavailable";
        return false;
    }
    if (render_node && *render_node) {
#ifdef CONFIG_GBM
        render_fd = open(render_node, O_RDWR | O_CLOEXEC);
        if (render_fd >= 0) {
            test_gbm = gbm_create_device(render_fd);
        }
        if (!test_gbm) {
            unavailable = "the requested GBM render node is unavailable";
            return false;
        }
        test_display = eglGetPlatformDisplayEXT(EGL_PLATFORM_GBM_KHR,
                                                 test_gbm, NULL);
#else
        unavailable = "GBM support was not built";
        return false;
#endif
    } else if (strstr(extensions, "EGL_MESA_platform_surfaceless")) {
        test_display = eglGetPlatformDisplayEXT(EGL_PLATFORM_SURFACELESS_MESA,
                                                 EGL_DEFAULT_DISPLAY, NULL);
    } else {
        unavailable = "surfaceless EGL is unavailable";
        return false;
    }

    if (test_display == EGL_NO_DISPLAY ||
        !eglInitialize(test_display, NULL, NULL) ||
        !eglBindAPI(EGL_OPENGL_API) ||
        !eglChooseConfig(test_display, config_attrs, &config, 1, &count) ||
        !count) {
        unavailable = "an offscreen OpenGL EGL config is unavailable";
        return false;
    }
    test_context = eglCreateContext(test_display, config, EGL_NO_CONTEXT,
                                     context_attrs);
    if (test_context == EGL_NO_CONTEXT ||
        !eglMakeCurrent(test_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                         test_context)) {
        unavailable = "an offscreen OpenGL 3.3 context is unavailable";
        return false;
    }

    g_test_message("GL renderer: %s", glGetString(GL_RENDERER));
    test_shader = qemu_gl_init_shader();
    glGenTextures(1, &test_color_texture);
    glBindTexture(GL_TEXTURE_2D, test_color_texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 4, 4, 0,
                  GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &test_framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, test_framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                            GL_TEXTURE_2D, test_color_texture, 0);
    g_assert_cmphex(glCheckFramebufferStatus(GL_FRAMEBUFFER), ==,
                    GL_FRAMEBUFFER_COMPLETE);
    g_assert_cmphex(glGetError(), ==, GL_NO_ERROR);
    return true;
}

static void cleanup_offscreen(void)
{
    if (test_shader) {
        glDeleteFramebuffers(1, &test_framebuffer);
        glDeleteTextures(1, &test_color_texture);
        qemu_gl_fini_shader(test_shader);
    }
    if (test_display != EGL_NO_DISPLAY) {
        eglMakeCurrent(test_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                         EGL_NO_CONTEXT);
        if (test_context != EGL_NO_CONTEXT) {
            eglDestroyContext(test_display, test_context);
        }
        eglTerminate(test_display);
    }
#ifdef CONFIG_GBM
    if (test_gbm) {
        gbm_device_destroy(test_gbm);
    }
#endif
    if (render_fd >= 0) {
        close(render_fd);
    }
}

static DisplaySurface red_surface(void)
{
    DisplaySurface surface = {
        .image = pixman_image_create_bits(PIXMAN_x8r8g8b8, 2, 2, NULL, 0),
    };
    uint32_t *pixels;
    int x, y;

    g_assert_nonnull(surface.image);
    pixels = pixman_image_get_data(surface.image);
    for (y = 0; y < 2; y++) {
        for (x = 0; x < 2; x++) {
            pixels[y * surface_stride(&surface) / 4 + x] = 0x00ff0000;
        }
    }
    glActiveTexture(GL_TEXTURE0);
    surface_gl_create_texture(test_shader, &surface);
    g_assert_cmphex(glGetError(), ==, GL_NO_ERROR);
    return surface;
}

static void assert_renders_red(DisplaySurface *surface)
{
    uint8_t pixel[4];

    glBindFramebuffer(GL_FRAMEBUFFER, test_framebuffer);
    glViewport(0, 0, 4, 4);
    surface_gl_render_texture(test_shader, surface);
    glReadPixels(2, 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    g_assert_cmphex(glGetError(), ==, GL_NO_ERROR);
    g_assert_cmpuint(pixel[0], ==, 255);
    g_assert_cmpuint(pixel[1], ==, 0);
    g_assert_cmpuint(pixel[2], ==, 0);
}

static void test_render_ignores_previous_binding(void)
{
    DisplaySurface surface;
    GLuint wrong_texture;
    const uint8_t green[] = { 0, 255, 0, 255 };

    if (unavailable) {
        g_test_skip(unavailable);
        return;
    }
    surface = red_surface();
    glGenTextures(1, &wrong_texture);
    glBindTexture(GL_TEXTURE_2D, wrong_texture);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0,
                  GL_RGBA, GL_UNSIGNED_BYTE, green);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

    /* A successful upload must not make rendering depend on its binding. */
    g_assert_true(surface_gl_update_texture(test_shader, &surface, 0, 0, 2, 2));
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, wrong_texture);
    assert_renders_red(&surface);

    glDeleteTextures(1, &wrong_texture);
    surface_gl_destroy_texture(test_shader, &surface);
    pixman_image_unref(surface.image);
}

static void test_upload_failure_and_recovery(void)
{
    DisplaySurface surface;

    if (unavailable) {
        g_test_skip(unavailable);
        return;
    }
    surface = red_surface();

    /* Clipped empty damage is a successful no-op, not a recovery request. */
    g_assert_true(surface_gl_update_texture(test_shader, &surface, 2, 0, 0, 2));
    g_assert_true(surface_gl_update_texture(test_shader, &surface, 0, 2, 2, 0));

    /* Simulate a stale backing: the 2x2 surface cannot fit a 1x1 texture. */
    glBindTexture(GL_TEXTURE_2D, surface.texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, 1, 1, 0,
                  GL_RGB, GL_UNSIGNED_BYTE, NULL);
    g_assert_cmphex(glGetError(), ==, GL_NO_ERROR);
    g_assert_false(surface_gl_update_texture(test_shader, &surface,
                                             0, 0, 2, 2));
    /* The caller must inspect the returned bool: the GL error was consumed. */
    g_assert_cmphex(glGetError(), ==, GL_NO_ERROR);

    surface_gl_destroy_texture(test_shader, &surface);
    g_assert_false(surface_gl_update_texture(test_shader, &surface,
                                             0, 0, 2, 2));
    surface_gl_create_texture(test_shader, &surface);
    g_assert_true(surface_gl_update_texture(test_shader, &surface, 0, 0, 2, 2));
    assert_renders_red(&surface);

    surface_gl_destroy_texture(test_shader, &surface);
    pixman_image_unref(surface.image);
}

static void assert_texture_matches_surface(DisplaySurface *surface)
{
    uint8_t actual[8 * 8 * 4];
    uint32_t *expected = surface_data(surface);
    int stride = surface_stride(surface) / sizeof(*expected);

    glBindTexture(GL_TEXTURE_2D, surface->texture);
    glPixelStorei(GL_PACK_ROW_LENGTH, 0);
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, actual);
    g_assert_cmphex(glGetError(), ==, GL_NO_ERROR);
    for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
            uint8_t *pixel = &actual[(y * 8 + x) * 4];
            uint32_t rgb = pixel[0] << 16 | pixel[1] << 8 | pixel[2];

            g_assert_cmphex(rgb, ==, expected[y * stride + x] & 0xffffff);
        }
    }
}

static void test_coalesced_upload_preserves_pixels(void)
{
    DisplaySurface surface = { 0 };
    SDL2Size size = { 8, 8 };
    SDL2Rect damage = { 0 };
    const SDL2Rect updates[] = {
        { 1, 1, 2, 2 }, { 5, 4, 1, 2 }, { 2, 2, 2, 2 },
    };
    uint32_t *pixels;
    int stride;

    if (unavailable) {
        g_test_skip(unavailable);
        return;
    }
    surface.image = pixman_image_create_bits(PIXMAN_x8r8g8b8, 8, 8, NULL, 0);
    g_assert_nonnull(surface.image);
    pixels = surface_data(&surface);
    stride = surface_stride(&surface) / sizeof(*pixels);
    for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
            pixels[y * stride + x] = 0x00102030 + y * 8 + x;
        }
    }
    glActiveTexture(GL_TEXTURE0);
    surface_gl_create_texture(test_shader, &surface);
    g_assert_cmphex(glGetError(), ==, GL_NO_ERROR);

    /* Disjoint/overlapping updates must preserve holes and the old border. */
    for (int i = 0; i < ARRAY_SIZE(updates); i++) {
        SDL2Rect r = updates[i];

        for (int y = r.y; y < r.y + r.height; y++) {
            for (int x = r.x; x < r.x + r.width; x++) {
                pixels[y * stride + x] = 0x00ff0000 + i;
            }
        }
        g_assert_true(sdl2_surface_damage_add(&damage, size, r));
    }
    g_assert_true(surface_gl_update_texture(test_shader, &surface,
                                           damage.x, damage.y,
                                           damage.width, damage.height));
    assert_texture_matches_surface(&surface);
    damage = (SDL2Rect) { 0 };

    /* A black transition plus a small update retains the latest frame. */
    memset(pixels, 0, surface_stride(&surface) * 8);
    g_assert_true(sdl2_surface_damage_add(
        &damage, size, (SDL2Rect) { 0, 0, 8, 8 }));
    pixels[7 * stride + 7] = 0x0000ff00;
    g_assert_true(sdl2_surface_damage_add(
        &damage, size, (SDL2Rect) { 7, 7, 1, 1 }));
    g_assert_true(surface_gl_update_texture(test_shader, &surface,
                                           damage.x, damage.y,
                                           damage.width, damage.height));
    assert_texture_matches_surface(&surface);
    surface_gl_destroy_texture(test_shader, &surface);
    pixman_image_unref(surface.image);
}

int main(int argc, char **argv)
{
    int result;

    g_test_init(&argc, &argv, NULL);
    if (!init_offscreen() && g_getenv("QEMU_TEST_GL_RENDER_NODE")) {
        g_error("Explicit GPU validation failed: %s (EGL 0x%x)",
                unavailable, eglGetError());
    }
    g_test_add_func("/console-gl/surface/render-binding",
                    test_render_ignores_previous_binding);
    g_test_add_func("/console-gl/surface/upload-failure-recovery",
                    test_upload_failure_and_recovery);
    g_test_add_func("/console-gl/surface/coalesced-upload",
                    test_coalesced_upload_preserves_pixels);
    result = g_test_run();
    cleanup_offscreen();
    return result;
}

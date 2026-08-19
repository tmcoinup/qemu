/*
 * SDL display sizing policy tests
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "ui/sdl2-display-policy.h"

static void assert_size(SDL2Size actual, int width, int height)
{
    g_assert_cmpint(actual.width, ==, width);
    g_assert_cmpint(actual.height, ==, height);
}

static void test_window_maximum_tracks_guest_pixels(void)
{
    SDL2Size maximum = { -1, -1 };

    g_assert_true(sdl2_window_max_size(
        (SDL2Size) { 800, 600 }, (SDL2Size) { 800, 600 },
        (SDL2Size) { 1920, 1080 }, false, &maximum));
    assert_size(maximum, 1920, 1080);

    /* 2x HiDPI: 960x540 logical units render exactly 1920x1080 pixels. */
    g_assert_true(sdl2_window_max_size(
        (SDL2Size) { 1280, 720 }, (SDL2Size) { 2560, 1440 },
        (SDL2Size) { 1920, 1080 }, false, &maximum));
    assert_size(maximum, 960, 540);

    /*
     * The window manager resized the SDL parent while its embedded EGL child
     * still reports the old guest size.  This is not a HiDPI scale change.
     */
    g_assert_true(sdl2_window_max_size(
        (SDL2Size) { 1067, 600 }, (SDL2Size) { 1920, 1080 },
        (SDL2Size) { 1920, 1080 }, true, &maximum));
    assert_size(maximum, 1920, 1080);
}

static void test_invalid_window_maximum_is_rejected(void)
{
    SDL2Size maximum = { -1, -1 };

    g_assert_false(sdl2_window_max_size(
        (SDL2Size) { 0, 720 }, (SDL2Size) { 1280, 720 },
        (SDL2Size) { 1920, 1080 }, false, &maximum));
    assert_size(maximum, 0, 0);
    g_assert_false(sdl2_window_max_size(
        (SDL2Size) { 1280, 720 }, (SDL2Size) { 1280, 720 },
        (SDL2Size) { 1920, 1080 }, false, NULL));
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/sdl2-display-policy/window-maximum",
                    test_window_maximum_tracks_guest_pixels);
    g_test_add_func("/sdl2-display-policy/invalid-window-maximum",
                    test_invalid_window_maximum_is_rejected);
    return g_test_run();
}

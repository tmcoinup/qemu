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

static void assert_damage(SDL2Rect actual, int x, int y, int width, int height)
{
    g_assert_cmpint(actual.x, ==, x);
    g_assert_cmpint(actual.y, ==, y);
    g_assert_cmpint(actual.width, ==, width);
    g_assert_cmpint(actual.height, ==, height);
}

static void test_surface_damage_coalesces_frame(void)
{
    SDL2Size surface = { 1920, 1080 };
    SDL2Rect damage = { 0 };

    g_assert_true(sdl2_surface_damage_add(
        &damage, surface, (SDL2Rect) { 100, 200, 200, 100 }));
    g_assert_true(sdl2_surface_damage_add(
        &damage, surface, (SDL2Rect) { 250, 150, 100, 200 }));
    g_assert_true(sdl2_surface_damage_add(
        &damage, surface, (SDL2Rect) { 50, 600, 200, 50 }));
    assert_damage(damage, 50, 150, 300, 500);

    /* Repeated notifications do not grow storage or queue more uploads. */
    for (int i = 0; i < 10000; i++) {
        g_assert_true(sdl2_surface_damage_add(
            &damage, surface, (SDL2Rect) { 100, 200, 200, 100 }));
    }
    assert_damage(damage, 50, 150, 300, 500);

    /* A full restore supersedes old damage until its upload succeeds. */
    g_assert_true(sdl2_surface_damage_add(
        &damage, surface, (SDL2Rect) { 0, 0, 1920, 1080 }));
    assert_damage(damage, 0, 0, 1920, 1080);

    /* Successful upload or surface replacement starts a fresh damage box. */
    damage = (SDL2Rect) { 0 };
    g_assert_true(sdl2_surface_damage_add(
        &damage, (SDL2Size) { 800, 600 }, (SDL2Rect) { 1, 2, 3, 4 }));
    assert_damage(damage, 1, 2, 3, 4);
}

static void test_surface_damage_empty_preserves_pending(void)
{
    SDL2Size surface = { 100, 100 };
    SDL2Rect damage = { 10, 20, 30, 40 };
    const SDL2Rect empty[] = {
        { 5, 5, 0, 10 }, { 5, 5, 10, 0 }, { 5, 5, -1, 10 },
        { 100, 0, 1, 1 }, { 0, 100, 1, 1 }, { -2, -2, 1, 1 },
    };

    for (int i = 0; i < ARRAY_SIZE(empty); i++) {
        g_assert_false(sdl2_surface_damage_add(&damage, surface, empty[i]));
        assert_damage(damage, 10, 20, 30, 40);
    }
    g_assert_false(sdl2_surface_damage_add(
        &damage, (SDL2Size) { 0, 100 }, (SDL2Rect) { 0, 0, 1, 1 }));
    assert_damage(damage, 10, 20, 30, 40);
    g_assert_false(sdl2_surface_damage_add(
        NULL, surface, (SDL2Rect) { 0, 0, 1, 1 }));
}

static void test_surface_damage_clips_without_overflow(void)
{
    SDL2Size surface = { 100, 80 };
    SDL2Rect damage = { 0 };

    g_assert_true(sdl2_surface_damage_add(
        &damage, surface, (SDL2Rect) { -10, -20, 30, 40 }));
    assert_damage(damage, 0, 0, 20, 20);
    damage = (SDL2Rect) { 0 };
    g_assert_true(sdl2_surface_damage_add(
        &damage, surface, (SDL2Rect) { 90, 70, INT_MAX, INT_MAX }));
    assert_damage(damage, 90, 70, 10, 10);
    g_assert_false(sdl2_surface_damage_add(
        &damage, surface, (SDL2Rect) { INT_MIN, 0, INT_MAX, 10 }));
    assert_damage(damage, 90, 70, 10, 10);
    g_assert_false(sdl2_surface_damage_add(
        &damage, surface, (SDL2Rect) { INT_MAX, 0, INT_MAX, 10 }));
    assert_damage(damage, 90, 70, 10, 10);

    damage = (SDL2Rect) { 0 };
    g_assert_true(sdl2_surface_damage_add(
        &damage, (SDL2Size) { INT_MAX, INT_MAX },
        (SDL2Rect) { 0, 0, INT_MAX, INT_MAX }));
    assert_damage(damage, 0, 0, INT_MAX, INT_MAX);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/sdl2-display-policy/window-maximum",
                    test_window_maximum_tracks_guest_pixels);
    g_test_add_func("/sdl2-display-policy/invalid-window-maximum",
                    test_invalid_window_maximum_is_rejected);
    g_test_add_func("/sdl2-display-policy/surface-damage/frame",
                    test_surface_damage_coalesces_frame);
    g_test_add_func("/sdl2-display-policy/surface-damage/empty",
                    test_surface_damage_empty_preserves_pending);
    g_test_add_func("/sdl2-display-policy/surface-damage/clipping",
                    test_surface_damage_clips_without_overflow);
    return g_test_run();
}

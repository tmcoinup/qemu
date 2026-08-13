/*
 * SDL display policy tests
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "ui/sdl2-display-policy.h"

static void test_native_guest_uses_desktop_fullscreen(void)
{
    g_assert_cmpint(
        sdl2_select_window_mode(
            (SDL2Size) { 1920, 1080 },
            (SDL2Size) { 1920, 1080 }),
        ==, SDL2_WINDOW_MODE_DESKTOP_FULLSCREEN);

    /*
     * 只要任一轴已经没有边框余量，
     * 就不能继续申请同尺寸的有边框客户区。
     * 两个断言分别覆盖宽度和高度边界。
     */
    g_assert_cmpint(
        sdl2_select_window_mode(
            (SDL2Size) { 1920, 900 },
            (SDL2Size) { 1920, 1080 }),
        ==, SDL2_WINDOW_MODE_DESKTOP_FULLSCREEN);
    g_assert_cmpint(
        sdl2_select_window_mode(
            (SDL2Size) { 1600, 1080 },
            (SDL2Size) { 1920, 1080 }),
        ==, SDL2_WINDOW_MODE_DESKTOP_FULLSCREEN);
}

static void test_oversized_guest_uses_desktop_fullscreen(void)
{
    g_assert_cmpint(
        sdl2_select_window_mode(
            (SDL2Size) { 2560, 1440 },
            (SDL2Size) { 1920, 1080 }),
        ==, SDL2_WINDOW_MODE_DESKTOP_FULLSCREEN);
}

static void test_smaller_guest_stays_windowed(void)
{
    g_assert_cmpint(
        sdl2_select_window_mode(
            (SDL2Size) { 1280, 720 },
            (SDL2Size) { 1920, 1080 }),
        ==, SDL2_WINDOW_MODE_WINDOWED);
}

static void test_invalid_size_is_rejected(void)
{
    g_assert_cmpint(
        sdl2_select_window_mode(
            (SDL2Size) { 0, 1080 },
            (SDL2Size) { 1920, 1080 }),
        ==, SDL2_WINDOW_MODE_INVALID);
    g_assert_cmpint(
        sdl2_select_window_mode(
            (SDL2Size) { 1920, 1080 },
            (SDL2Size) { -1, 1080 }),
        ==, SDL2_WINDOW_MODE_INVALID);
}

static void assert_size(SDL2Size actual, int width, int height)
{
    g_assert_cmpint(actual.width, ==, width);
    g_assert_cmpint(actual.height, ==, height);
}

static void test_window_maximum_tracks_guest_pixels(void)
{
    SDL2Size maximum = { -1, -1 };

    g_assert_true(sdl2_window_max_size(
        (SDL2Size) { 2092, 1216 },
        (SDL2Size) { 2092, 1216 },
        (SDL2Size) { 1920, 1080 }, &maximum));
    assert_size(maximum, 1920, 1080);

    /* 2x HiDPI 下 960x540 logical 正好对应 1920x1080 像素。 */
    g_assert_true(sdl2_window_max_size(
        (SDL2Size) { 1280, 720 },
        (SDL2Size) { 2560, 1440 },
        (SDL2Size) { 1920, 1080 }, &maximum));
    assert_size(maximum, 960, 540);

    /* 小窗口仍可以放大到 Guest 原生尺寸。 */
    g_assert_true(sdl2_window_max_size(
        (SDL2Size) { 800, 600 },
        (SDL2Size) { 800, 600 },
        (SDL2Size) { 1920, 1080 }, &maximum));
    assert_size(maximum, 1920, 1080);
}

static void test_invalid_window_maximum_is_rejected(void)
{
    SDL2Size maximum = { -1, -1 };

    g_assert_false(sdl2_window_max_size(
        (SDL2Size) { 0, 720 },
        (SDL2Size) { 1280, 720 },
        (SDL2Size) { 1920, 1080 }, &maximum));
    assert_size(maximum, 0, 0);
    g_assert_false(sdl2_window_max_size(
        (SDL2Size) { 1280, 720 },
        (SDL2Size) { 1280, 720 },
        (SDL2Size) { 1920, 1080 }, NULL));
}

static void test_active_refresh_budget(void)
{
    g_assert_cmpuint(SDL2_ACTIVE_REFRESH_HZ, ==, 60);
    g_assert_cmpuint(SDL2_ACTIVE_REFRESH_INTERVAL_MS, ==, 16);

    /*
     * 整数毫秒不能用 17 ms：
     * 它只能提供 58.8 次/秒的更新机会。
     * 16 ms 略快于 60 Hz，
     * 由实际 guest 更新和 Present 决定是否出帧。
     */
    g_assert_cmpuint(1000 / SDL2_ACTIVE_REFRESH_INTERVAL_MS, >=,
                     SDL2_ACTIVE_REFRESH_HZ);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);

    g_test_add_func("/sdl2-display-policy/native-fullscreen",
                    test_native_guest_uses_desktop_fullscreen);
    g_test_add_func("/sdl2-display-policy/oversized-fullscreen",
                    test_oversized_guest_uses_desktop_fullscreen);
    g_test_add_func("/sdl2-display-policy/smaller-windowed",
                    test_smaller_guest_stays_windowed);
    g_test_add_func("/sdl2-display-policy/invalid-size",
                    test_invalid_size_is_rejected);
    g_test_add_func("/sdl2-display-policy/window-maximum",
                    test_window_maximum_tracks_guest_pixels);
    g_test_add_func("/sdl2-display-policy/invalid-window-maximum",
                    test_invalid_window_maximum_is_rejected);
    g_test_add_func("/sdl2-display-policy/active-refresh-budget",
                    test_active_refresh_budget);

    return g_test_run();
}

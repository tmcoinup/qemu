/*
 * SDL pointer geometry helper tests
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "ui/sdl2-pointer.h"

static void assert_rect(SDL2Rect actual, int x, int y, int width, int height)
{
    g_assert_cmpint(actual.x, ==, x);
    g_assert_cmpint(actual.y, ==, y);
    g_assert_cmpint(actual.width, ==, width);
    g_assert_cmpint(actual.height, ==, height);
}

static void assert_point(SDL2Point actual, int x, int y)
{
    g_assert_cmpint(actual.x, ==, x);
    g_assert_cmpint(actual.y, ==, y);
}

static SDL2Point window_to_guest(SDL2Rect dst, SDL2Size guest, int x, int y)
{
    SDL2Point mapped = { -1, -1 };

    g_assert_true(sdl2_window_to_guest(
        dst, guest, (SDL2Point) { x, y }, &mapped));
    return mapped;
}

static SDL2Point guest_to_window(SDL2Rect dst, SDL2Size guest, int x, int y)
{
    SDL2Point mapped = { -1, -1 };

    g_assert_true(sdl2_guest_to_window(
        dst, guest, (SDL2Point) { x, y }, &mapped));
    return mapped;
}

static void test_destination_rect(void)
{
    assert_rect(sdl2_guest_dst_rect(
                    (SDL2Size) { 1920, 1080 },
                    (SDL2Size) { 1920, 1080 }),
                0, 0, 1920, 1080);
    assert_rect(sdl2_guest_dst_rect(
                    (SDL2Size) { 2560, 1440 },
                    (SDL2Size) { 1920, 1080 }),
                320, 180, 1920, 1080);
    assert_rect(sdl2_guest_dst_rect(
                    (SDL2Size) { 1280, 720 },
                    (SDL2Size) { 1920, 1080 }),
                0, 0, 1280, 720);
    assert_rect(sdl2_guest_dst_rect(
                    (SDL2Size) { 1600, 1200 },
                    (SDL2Size) { 1920, 1080 }),
                0, 150, 1600, 900);
    assert_rect(sdl2_guest_dst_rect(
                    (SDL2Size) { 0, 720 },
                    (SDL2Size) { 1920, 1080 }),
                0, 0, 0, 0);
}

static void test_black_borders_and_endpoints(void)
{
    SDL2Size guest = { 1920, 1080 };
    SDL2Rect dst = sdl2_guest_dst_rect((SDL2Size) { 2560, 1440 }, guest);

    /* Side borders clamp X only; Y continues to track the visible picture. */
    assert_point(window_to_guest(dst, guest, 0, 180), 0, 0);
    assert_point(window_to_guest(dst, guest, 0, 720), 0, 540);
    assert_point(window_to_guest(dst, guest, 2559, 720), 1919, 540);
    assert_point(window_to_guest(dst, guest, dst.x, dst.y), 0, 0);
    assert_point(window_to_guest(dst, guest,
                                 dst.x + dst.width - 1,
                                 dst.y + dst.height - 1),
                 1919, 1079);
}

static void test_downscaled_mapping(void)
{
    SDL2Size guest = { 1920, 1080 };
    SDL2Rect dst = sdl2_guest_dst_rect((SDL2Size) { 1280, 720 }, guest);
    SDL2Point window;
    SDL2Point round_trip;

    assert_point(window_to_guest(dst, guest, 0, 0), 0, 0);
    assert_point(window_to_guest(dst, guest, 640, 360), 960, 540);
    assert_point(window_to_guest(dst, guest, 1279, 719), 1919, 1079);
    assert_point(guest_to_window(dst, guest, 0, 0), 0, 0);
    assert_point(guest_to_window(dst, guest, 1919, 1079), 1279, 719);

    window = guest_to_window(dst, guest, 960, 540);
    round_trip = window_to_guest(dst, guest, window.x, window.y);
    assert_point(round_trip, 960, 540);
}

static void test_hidpi_mapping_once(void)
{
    SDL2Size logical = { 1280, 720 };
    SDL2Size drawable = { 2560, 1440 };
    SDL2Size guest = { 1920, 1080 };
    SDL2Rect dst = sdl2_guest_dst_rect(drawable, guest);
    SDL2Point render = { -1, -1 };

    g_assert_true(sdl2_map_point(
        logical, drawable, (SDL2Point) { 0, 0 }, &render));
    assert_point(render, 0, 0);
    assert_point(window_to_guest(dst, guest, render.x, render.y), 0, 0);

    g_assert_true(sdl2_map_point(
        logical, drawable, (SDL2Point) { 1279, 719 }, &render));
    assert_point(render, 2559, 1439);
    assert_point(window_to_guest(dst, guest, render.x, render.y),
                 1919, 1079);
}

static void test_gl_viewport(void)
{
    SDL2Size output = { 1001, 701 };
    SDL2Rect top_left = sdl2_guest_dst_rect(
        output, (SDL2Size) { 640, 480 });

    assert_rect(top_left, 180, 110, 640, 480);
    assert_rect(sdl2_gl_viewport(output, top_left),
                180, 111, 640, 480);
}

static void test_relative_scaling(void)
{
    SDL2AxisScale state = { 0 };
    int total = 0;
    int i;

    g_assert_cmpint(
        sdl2_scale_relative_motion(1, 3, 2, &state), ==, 0);
    g_assert_cmpint(
        sdl2_scale_relative_motion(1, 3, 2, &state), ==, 1);
    g_assert_cmpint(
        sdl2_scale_relative_motion(1, 3, 2, &state), ==, 1);
    g_assert_cmpint(state.remainder, ==, 0);

    state = (SDL2AxisScale) { 0 };
    g_assert_cmpint(
        sdl2_scale_relative_motion(-1, 3, 2, &state), ==, 0);
    g_assert_cmpint(
        sdl2_scale_relative_motion(-1, 3, 2, &state), ==, -1);
    g_assert_cmpint(
        sdl2_scale_relative_motion(-1, 3, 2, &state), ==, -1);

    state = (SDL2AxisScale) { 0 };
    for (i = 0; i < 1280; i++) {
        total += sdl2_scale_relative_motion(1, 1280, 1920, &state);
    }
    g_assert_cmpint(total, ==, 1920);
    g_assert_cmpint(state.remainder, ==, 0);
}

static void test_guest_size_selection(void)
{
    SDL2Size selected = { -1, -1 };

    g_assert_true(sdl2_select_guest_size(
        false, (SDL2Size) { 800, 600 }, (SDL2Size) { 1920, 1080 },
        &selected));
    assert_point((SDL2Point) { selected.width, selected.height }, 800, 600);

    g_assert_true(sdl2_select_guest_size(
        true, (SDL2Size) { 800, 600 }, (SDL2Size) { 1920, 1080 },
        &selected));
    assert_point((SDL2Point) { selected.width, selected.height }, 1920, 1080);
}

static void test_tablet_capability_policy(void)
{
    SDL2PointerPolicy policy;

    /* Tablet exists even if PS/2 temporarily remains the current handler. */
    policy = sdl2_pointer_policy(false, false, true);
    g_assert_true(policy.accept_motion);
    g_assert_false(policy.auto_grab_on_click);
    g_assert_false(policy.relative_mode);
    g_assert_false(policy.release_grab);

    /*
     * Availability requests release of a stale windowed grab.  Until the
     * caller releases it (or while fullscreen preserves it), the current REL
     * handler still requires SDL relative mode.
     */
    policy = sdl2_pointer_policy(true, false, true);
    g_assert_true(policy.accept_motion);
    g_assert_true(policy.relative_mode);
    g_assert_true(policy.release_grab);

    policy = sdl2_pointer_policy(true, true, true);
    g_assert_false(policy.relative_mode);
    g_assert_true(policy.release_grab);

    /* A pure relative mouse retains click-to-grab and relative mode. */
    policy = sdl2_pointer_policy(false, false, false);
    g_assert_false(policy.accept_motion);
    g_assert_true(policy.auto_grab_on_click);
    policy = sdl2_pointer_policy(true, false, false);
    g_assert_true(policy.accept_motion);
    g_assert_true(policy.relative_mode);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);

    g_test_add_func("/sdl2-pointer/destination-rect",
                    test_destination_rect);
    g_test_add_func("/sdl2-pointer/black-borders-endpoints",
                    test_black_borders_and_endpoints);
    g_test_add_func("/sdl2-pointer/downscaled-mapping",
                    test_downscaled_mapping);
    g_test_add_func("/sdl2-pointer/hidpi-mapped-once",
                    test_hidpi_mapping_once);
    g_test_add_func("/sdl2-pointer/gl-viewport", test_gl_viewport);
    g_test_add_func("/sdl2-pointer/relative-scaling",
                    test_relative_scaling);
    g_test_add_func("/sdl2-pointer/guest-size-selection",
                    test_guest_size_selection);
    g_test_add_func("/sdl2-pointer/tablet-capability-policy",
                    test_tablet_capability_policy);

    return g_test_run();
}

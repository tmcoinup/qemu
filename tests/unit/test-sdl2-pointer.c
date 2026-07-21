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

static SDL2Point map_point(SDL2Rect dst, SDL2Size guest, int x, int y)
{
    SDL2Point mapped = { -1, -1 };

    g_assert_true(sdl2_window_to_guest(
        dst, guest, (SDL2Point) { x, y }, &mapped));
    return mapped;
}

static SDL2Point map_guest_point(SDL2Rect dst, SDL2Size guest, int x, int y)
{
    SDL2Point mapped = { -1, -1 };

    g_assert_true(sdl2_guest_to_window(
        dst, guest, (SDL2Point) { x, y }, &mapped));
    return mapped;
}

static void assert_point(SDL2Point actual, int x, int y)
{
    g_assert_cmpint(actual.x, ==, x);
    g_assert_cmpint(actual.y, ==, y);
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
                    (SDL2Size) { 1001, 700 },
                    (SDL2Size) { 1920, 1080 }),
                0, 68, 1001, 563);
    assert_rect(sdl2_guest_dst_rect(
                    (SDL2Size) { 0, 700 },
                    (SDL2Size) { 1920, 1080 }),
                0, 0, 0, 0);
    assert_rect(sdl2_guest_dst_rect(
                    (SDL2Size) { 800, 600 },
                    (SDL2Size) { -1, 1080 }),
                0, 0, 800, 600);
    assert_rect(sdl2_guest_dst_rect(
                    (SDL2Size) { INT_MAX, 1 },
                    (SDL2Size) { 1, INT_MAX }),
                (INT_MAX - 1) / 2, 0, 1, 1);
}

static void test_side_edges_do_not_change_y(void)
{
    SDL2Size guest = { 1920, 1080 };
    SDL2Rect dst = sdl2_guest_dst_rect((SDL2Size) { 2560, 1440 }, guest);

    /*
     * 左右黑边只应钳制 X；Y 必须保持对应位置。
     * 这个断言直接覆盖“碰到左/右边缘后
     * guest 指针跳到底部”的回归。
     */
    assert_point(map_point(dst, guest, 0, 180), 0, 0);
    assert_point(map_point(dst, guest, 0, 720), 0, 540);
    assert_point(map_point(dst, guest, 0, 1259), 0, 1079);
    assert_point(map_point(dst, guest, 2559, 180), 1919, 0);
    assert_point(map_point(dst, guest, 2559, 720), 1919, 540);
    assert_point(map_point(dst, guest, 2559, 1259), 1919, 1079);
}

static void test_black_border_and_endpoints(void)
{
    SDL2Size guest = { 1920, 1080 };
    SDL2Rect dst = sdl2_guest_dst_rect((SDL2Size) { 2560, 1440 }, guest);

    assert_point(map_point(dst, guest, 0, 0), 0, 0);
    assert_point(map_point(dst, guest, 2559, 1439), 1919, 1079);
    assert_point(map_point(dst, guest, dst.x, dst.y), 0, 0);
    assert_point(map_point(dst, guest,
                           dst.x + dst.width - 1,
                           dst.y + dst.height - 1),
                 1919, 1079);
}

static void test_downscaled_mapping(void)
{
    SDL2Size guest = { 1920, 1080 };
    SDL2Rect dst = sdl2_guest_dst_rect((SDL2Size) { 1280, 720 }, guest);

    assert_point(map_point(dst, guest, 0, 0), 0, 0);
    assert_point(map_point(dst, guest, 640, 360), 960, 540);
    assert_point(map_point(dst, guest, 1279, 719), 1919, 1079);
}

static void test_single_pixel_mapping(void)
{
    assert_point(map_point(
                     (SDL2Rect) { 0, 0, 1, 1 },
                     (SDL2Size) { 1920, 1080 }, 0, 0),
                 959, 539);
    assert_point(map_point(
                     (SDL2Rect) { 0, 0, 10, 10 },
                     (SDL2Size) { 1, 1 }, 9, 9),
                 0, 0);
}

static void test_guest_to_window_mapping(void)
{
    SDL2Size guest = { 1920, 1080 };
    SDL2Rect native =
        sdl2_guest_dst_rect((SDL2Size) { 2560, 1440 }, guest);
    SDL2Rect scaled =
        sdl2_guest_dst_rect((SDL2Size) { 1280, 720 }, guest);
    SDL2Point window_point;
    SDL2Point round_trip;

    assert_point(map_guest_point(native, guest, 0, 0), 320, 180);
    assert_point(map_guest_point(native, guest, 1919, 1079), 2239, 1259);
    assert_point(map_guest_point(scaled, guest, 0, 0), 0, 0);
    assert_point(map_guest_point(scaled, guest, 960, 540), 640, 360);
    assert_point(map_guest_point(scaled, guest, 1919, 1079), 1279, 719);

    window_point = map_guest_point(scaled, guest, 960, 540);
    round_trip = map_point(scaled, guest, window_point.x, window_point.y);
    assert_point(round_trip, 960, 540);

    assert_point(map_guest_point(
                     (SDL2Rect) { 10, 20, 1, 1 },
                     guest, 1919, 1079),
                 10, 20);
}

static void test_invalid_mapping(void)
{
    SDL2Point mapped = { 7, 9 };

    g_assert_false(sdl2_window_to_guest(
        (SDL2Rect) { 0 }, (SDL2Size) { 1920, 1080 },
        (SDL2Point) { 10, 20 }, &mapped));
    g_assert_false(sdl2_window_to_guest(
        (SDL2Rect) { 0, 0, 10, 10 }, (SDL2Size) { 0, 1080 },
        (SDL2Point) { 10, 20 }, &mapped));
    g_assert_false(sdl2_window_to_guest(
        (SDL2Rect) { 0, 0, 10, 10 }, (SDL2Size) { 10, 10 },
        (SDL2Point) { 10, 20 }, NULL));
    g_assert_false(sdl2_guest_to_window(
        (SDL2Rect) { 0 }, (SDL2Size) { 10, 10 },
        (SDL2Point) { 10, 20 }, &mapped));
    g_assert_false(sdl2_guest_to_window(
        (SDL2Rect) { 0, 0, 10, 10 }, (SDL2Size) { 0, 10 },
        (SDL2Point) { 10, 20 }, &mapped));
    g_assert_false(sdl2_guest_to_window(
        (SDL2Rect) { 0, 0, 10, 10 }, (SDL2Size) { 10, 10 },
        (SDL2Point) { 10, 20 }, NULL));
}

static void test_coordinate_space_mapping(void)
{
    SDL2Size logical = { 1280, 720 };
    SDL2Size drawable = { 2560, 1440 };
    SDL2Point mapped = { -1, -1 };

    g_assert_true(sdl2_map_point(
        logical, drawable, (SDL2Point) { 0, 0 }, &mapped));
    assert_point(mapped, 0, 0);
    g_assert_true(sdl2_map_point(
        logical, drawable, (SDL2Point) { 1279, 719 }, &mapped));
    assert_point(mapped, 2559, 1439);
    g_assert_true(sdl2_map_point(
        logical, drawable, (SDL2Point) { -100, INT_MAX }, &mapped));
    assert_point(mapped, 0, 1439);

    g_assert_true(sdl2_map_point(
        (SDL2Size) { 1, 1 }, drawable,
        (SDL2Point) { 0, 0 }, &mapped));
    assert_point(mapped, 1279, 719);
    g_assert_false(sdl2_map_point(
        (SDL2Size) { 0, 1 }, drawable,
        (SDL2Point) { 0, 0 }, &mapped));
    g_assert_false(sdl2_map_point(
        logical, drawable, (SDL2Point) { 0, 0 }, NULL));
}

static void test_extreme_mapping_is_saturated(void)
{
    SDL2Point mapped = { 0 };

    g_assert_true(sdl2_window_to_guest(
        (SDL2Rect) { INT_MAX, INT_MAX, INT_MAX, INT_MAX },
        (SDL2Size) { INT_MAX, INT_MAX },
        (SDL2Point) { INT_MIN, INT_MIN }, &mapped));
    assert_point(mapped, 0, 0);

    g_assert_true(sdl2_guest_to_window(
        (SDL2Rect) { INT_MAX, INT_MAX, INT_MAX, INT_MAX },
        (SDL2Size) { INT_MAX, INT_MAX },
        (SDL2Point) { INT_MAX, INT_MAX }, &mapped));
    assert_point(mapped, INT_MAX, INT_MAX);
}

static void test_gl_viewport(void)
{
    SDL2Size output = { 1001, 701 };
    SDL2Rect top_left = sdl2_guest_dst_rect(
        output, (SDL2Size) { 640, 480 });

    assert_rect(top_left, 180, 110, 640, 480);
    assert_rect(sdl2_gl_viewport(output, top_left),
                180, 111, 640, 480);
    assert_rect(sdl2_gl_viewport(
                    (SDL2Size) { 0, 701 }, top_left),
                0, 0, 0, 0);
}

static void test_gl_scanout_source_rect(void)
{
    SDL2Size backing = { 1920, 1200 };
    SDL2Rect scanout = { 64, 100, 1280, 720 };

    /*
     * y0_top 的 y=100 是距 backing 顶部 100 像素，
     * 对应 OpenGL 底部原点的 [380, 1100] 条带。
     * bottom-up 路径选择 [100, 820]，并用负高度保持既有翻转。
     */
    assert_rect(sdl2_gl_scanout_source_rect(backing, scanout, true),
                64, 380, 1280, 720);
    assert_rect(sdl2_gl_scanout_source_rect(backing, scanout, false),
                64, 820, 1280, -720);

    assert_rect(sdl2_gl_scanout_source_rect(
                    backing, (SDL2Rect) { 0, 0, 1920, 1200 }, true),
                0, 0, 1920, 1200);
    assert_rect(sdl2_gl_scanout_source_rect(
                    backing, (SDL2Rect) { 0, 0, 1920, 1200 }, false),
                0, 1200, 1920, -1200);
    assert_rect(sdl2_gl_scanout_source_rect(
                    backing, (SDL2Rect) { 0, 600, 1920, 601 }, true),
                0, 0, 0, 0);
}

static void test_relative_scaling(void)
{
    SDL2AxisScale state = { 0 };
    int total = 0;
    int i;

    g_assert_cmpint(
        sdl2_scale_relative_motion(10, 960, 1920, &state), ==, 20);
    g_assert_cmpint(
        sdl2_scale_relative_motion(-10, 960, 1920, &state), ==, -20);
    g_assert_cmpint(
        sdl2_scale_relative_motion(7, 1920, 1920, &state), ==, 7);

    state = (SDL2AxisScale) { 0 };
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
    g_assert_cmpint(state.remainder, ==, 0);

    g_assert_cmpint(
        sdl2_scale_relative_motion(7, 0, 1920, &state), ==, 0);
    g_assert_cmpint(state.source_extent, ==, 0);
    g_assert_cmpint(
        sdl2_scale_relative_motion(7, 1920, 0, &state), ==, 0);
    g_assert_cmpint(state.target_extent, ==, 0);

    state = (SDL2AxisScale) { 0 };
    for (i = 0; i < 1280; i++) {
        total += sdl2_scale_relative_motion(1, 1280, 1920, &state);
    }
    g_assert_cmpint(total, ==, 1920);
    g_assert_cmpint(state.remainder, ==, 0);

    state = (SDL2AxisScale) { 0 };
    g_assert_cmpint(
        sdl2_scale_relative_motion(1, 3, 2, &state), ==, 0);
    g_assert_cmpint(
        sdl2_scale_relative_motion(1, 2, 3, &state), ==, 1);
    g_assert_cmpint(state.source_extent, ==, 2);
    g_assert_cmpint(state.target_extent, ==, 3);
    g_assert_cmpint(
        sdl2_scale_relative_motion(1, 2, 3, NULL), ==, 0);
}

static void test_guest_size_selection(void)
{
    SDL2Size surface = { 800, 600 };
    SDL2Size scanout = { 1920, 1080 };
    SDL2Size selected = { -1, -1 };

    g_assert_true(sdl2_select_guest_size(false, surface, scanout, &selected));
    g_assert_cmpint(selected.width, ==, 800);
    g_assert_cmpint(selected.height, ==, 600);

    g_assert_true(sdl2_select_guest_size(true, surface, scanout, &selected));
    g_assert_cmpint(selected.width, ==, 1920);
    g_assert_cmpint(selected.height, ==, 1080);

    g_assert_true(sdl2_select_guest_size(
        true, surface, (SDL2Size) { 0 }, &selected));
    g_assert_cmpint(selected.width, ==, 800);
    g_assert_cmpint(selected.height, ==, 600);

    g_assert_false(sdl2_select_guest_size(
        true, (SDL2Size) { 0 }, (SDL2Size) { 0 }, &selected));
    g_assert_cmpint(selected.width, ==, 0);
    g_assert_cmpint(selected.height, ==, 0);

    selected = (SDL2Size) { -1, -1 };
    g_assert_false(sdl2_select_guest_size(
        false, (SDL2Size) { 0 }, scanout, &selected));
    g_assert_cmpint(selected.width, ==, 0);
    g_assert_cmpint(selected.height, ==, 0);

    g_assert_false(sdl2_select_guest_size(
        false, surface, scanout, NULL));
}

static void test_pointer_policy_before_tablet_activation(void)
{
    SDL2PointerPolicy policy;

    /*
     * 冷启动或 OOBE 首次启用 USB HID 前，
     * PS/2 可能仍是 current handler。
     * 只要 usb-tablet 仍然存在，
     * 就继续接收位移且不能因点击自动抓鼠标。
     */
    policy = sdl2_pointer_policy(false, false, true);
    g_assert_true(policy.accept_motion);
    g_assert_false(policy.auto_grab_on_click);
    g_assert_false(policy.relative_mode);
    g_assert_false(policy.release_grab);

    /*
     * 覆盖旧故障状态：
     * 启动画面已经抓取，随后 tablet 恢复。
     * notifier 必须撤销逻辑 grab，
     * SDL 相对模式也必须明确关闭。
     */
    policy = sdl2_pointer_policy(true, true, true);
    g_assert_true(policy.accept_motion);
    g_assert_false(policy.auto_grab_on_click);
    g_assert_false(policy.relative_mode);
    g_assert_true(policy.release_grab);

    /*
     * Tablet 已存在但尚未成为 current 时，
     * 旧版本也可能已经抓住 PS/2。
     * notifier 先要求释放 grab；
     * 释放后的同步必须关闭 relative mode。
     */
    policy = sdl2_pointer_policy(true, false, true);
    g_assert_true(policy.release_grab);
    policy = sdl2_pointer_policy(false, false, true);
    g_assert_false(policy.relative_mode);
    g_assert_false(policy.release_grab);

    /*
     * 纯相对鼠标仍保持原来的“点击抓取、
     * 抓取后使用 relative mode”。
     */
    policy = sdl2_pointer_policy(false, false, false);
    g_assert_false(policy.accept_motion);
    g_assert_true(policy.auto_grab_on_click);
    g_assert_false(policy.relative_mode);
    g_assert_false(policy.release_grab);

    policy = sdl2_pointer_policy(true, false, false);
    g_assert_true(policy.accept_motion);
    g_assert_false(policy.auto_grab_on_click);
    g_assert_true(policy.relative_mode);
    g_assert_false(policy.release_grab);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);

    g_test_add_func("/sdl2-pointer/destination-rect",
                    test_destination_rect);
    g_test_add_func("/sdl2-pointer/side-edges",
                    test_side_edges_do_not_change_y);
    g_test_add_func("/sdl2-pointer/black-border-endpoints",
                    test_black_border_and_endpoints);
    g_test_add_func("/sdl2-pointer/downscaled-mapping",
                    test_downscaled_mapping);
    g_test_add_func("/sdl2-pointer/single-pixel-mapping",
                    test_single_pixel_mapping);
    g_test_add_func("/sdl2-pointer/guest-to-window-mapping",
                    test_guest_to_window_mapping);
    g_test_add_func("/sdl2-pointer/invalid-mapping",
                    test_invalid_mapping);
    g_test_add_func("/sdl2-pointer/coordinate-space-mapping",
                    test_coordinate_space_mapping);
    g_test_add_func("/sdl2-pointer/extreme-mapping",
                    test_extreme_mapping_is_saturated);
    g_test_add_func("/sdl2-pointer/gl-viewport",
                    test_gl_viewport);
    g_test_add_func("/sdl2-pointer/gl-scanout-source-rect",
                    test_gl_scanout_source_rect);
    g_test_add_func("/sdl2-pointer/relative-scaling",
                    test_relative_scaling);
    g_test_add_func("/sdl2-pointer/guest-size-selection",
                    test_guest_size_selection);
    g_test_add_func("/sdl2-pointer/policy-before-tablet-activation",
                    test_pointer_policy_before_tablet_activation);

    return g_test_run();
}

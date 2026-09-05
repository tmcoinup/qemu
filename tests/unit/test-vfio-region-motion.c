/*
 * Real pixel streams through the production VFIO REGION staging policy.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "hw/vfio/display-region-motion.h"

#define TEST_HEIGHT 8
#define TEST_ROW_BYTES 12
#define TEST_STRIDE 16

typedef struct TestRegion {
    uint8_t source[TEST_STRIDE * TEST_HEIGHT];
    uint8_t staging[TEST_STRIDE * TEST_HEIGHT];
    uint32_t motion_streak;
    uint32_t bypass_frames;
    VFIORegionDirtyRun runs[VFIO_REGION_MAX_DIRTY_RUNS];
    uint32_t run_count;
    uint32_t dirty_rows;
    bool too_many_runs;
} TestRegion;

static bool update(TestRegion *region)
{
    return vfio_region_update_staging(
        region->staging, region->source, sizeof(region->staging),
        TEST_ROW_BYTES, TEST_STRIDE, TEST_HEIGHT,
        &region->motion_streak, &region->bypass_frames,
        region->runs, &region->run_count, &region->dirty_rows,
        &region->too_many_runs);
}

static void set_visible(TestRegion *region, uint8_t value)
{
    for (unsigned y = 0; y < TEST_HEIGHT; y++) {
        memset(region->source + y * TEST_STRIDE, value, TEST_ROW_BYTES);
    }
}

static void assert_visible_equal(TestRegion *region)
{
    for (unsigned y = 0; y < TEST_HEIGHT; y++) {
        g_assert_cmpmem(region->source + y * TEST_STRIDE, TEST_ROW_BYTES,
                        region->staging + y * TEST_STRIDE, TEST_ROW_BYTES);
    }
}

static void enter_high_motion(TestRegion *region)
{
    for (unsigned i = 1; i <= 8; i++) {
        set_visible(region, i);
        g_assert_true(update(region));
        assert_visible_equal(region);
    }
    g_assert_cmpuint(region->motion_streak, ==, 8);
    g_assert_cmpuint(region->bypass_frames, ==, 7);
}

static void test_motion_to_still(void)
{
    for (unsigned phase = 0; phase < 8; phase++) {
        TestRegion region = { 0 };
        unsigned redundant_updates = 0;

        enter_high_motion(&region);
        for (unsigned i = 0; i < phase; i++) {
            set_visible(&region, 20 + i);
            g_assert_true(update(&region));
        }
        for (unsigned i = 0; i < 8; i++) {
            redundant_updates += update(&region);
            assert_visible_equal(&region);
        }
        g_assert_cmpuint(redundant_updates, ==, 7 - phase);
        g_assert_cmpuint(region.bypass_frames, ==, 0);
        g_assert_cmpuint(region.motion_streak, ==, 0);
        for (unsigned i = 0; i < 16; i++) {
            g_assert_false(update(&region));
        }
    }
}

static void test_motion_to_black(void)
{
    for (unsigned phase = 0; phase < 8; phase++) {
        TestRegion region = { 0 };
        unsigned redundant_updates = 0;

        enter_high_motion(&region);
        for (unsigned i = 0; i < phase; i++) {
            set_visible(&region, 20 + i);
            g_assert_true(update(&region));
        }
        set_visible(&region, 0);
        /* Include black arriving on the exact-comparison tick (phase 7). */
        g_assert_true(update(&region));
        assert_visible_equal(&region);
        for (unsigned i = 0; i < 8; i++) {
            redundant_updates += update(&region);
            assert_visible_equal(&region);
        }
        g_assert_cmpuint(redundant_updates, <=, 7);
        g_assert_cmpuint(region.motion_streak, ==, 0);
        g_assert_false(update(&region));
    }
}

static void test_single_pixel_on_comparison_and_bypass_ticks(void)
{
    TestRegion region = { 0 };

    /* Exact comparison finds a one-byte pixel change in one visible row. */
    region.source[3 * TEST_STRIDE + 5] = 0x7f;
    g_assert_true(update(&region));
    g_assert_cmpuint(region.dirty_rows, ==, 1);
    g_assert_cmpuint(region.run_count, ==, 1);
    g_assert_cmpuint(region.runs[0].y, ==, 3);
    g_assert_cmpuint(region.runs[0].height, ==, 1);
    assert_visible_equal(&region);
    g_assert_false(update(&region));

    enter_high_motion(&region);
    region.source[2 * TEST_STRIDE + 7] ^= 0x80;
    g_assert_true(update(&region));
    assert_visible_equal(&region);
    /* Skipping comparisons still copies new content on every tick. */
    region.source[6 * TEST_STRIDE + 1] ^= 0x40;
    g_assert_true(update(&region));
    assert_visible_equal(&region);
}

static void test_continuing_motion_keeps_bounded_bypass(void)
{
    TestRegion region = { 0 };

    enter_high_motion(&region);
    for (unsigned i = 0; i < 128; i++) {
        set_visible(&region, 20 + i);
        g_assert_true(update(&region));
        assert_visible_equal(&region);
        g_assert_cmpuint(region.motion_streak, ==, 8);
        g_assert_cmpuint(region.bypass_frames, ==, 7 - ((i + 1) % 8));
    }
}

static void test_low_motion_exits_bypass(void)
{
    TestRegion region = { 0 };

    enter_high_motion(&region);
    for (unsigned i = 0; i < 7; i++) {
        g_assert_true(update(&region));
    }
    /* The next exact checkpoint sees low motion and abandons the bypass. */
    region.source[5 * TEST_STRIDE + 2] ^= 1;
    g_assert_true(update(&region));
    g_assert_cmpuint(region.dirty_rows, ==, 1);
    g_assert_cmpuint(region.motion_streak, ==, 0);
    g_assert_cmpuint(region.bypass_frames, ==, 0);
    assert_visible_equal(&region);
    g_assert_false(update(&region));
}

static void test_padding_is_not_visible_damage(void)
{
    TestRegion region = { 0 };

    for (unsigned y = 0; y < TEST_HEIGHT; y++) {
        memset(region.source + y * TEST_STRIDE + TEST_ROW_BYTES, 0xa5,
               TEST_STRIDE - TEST_ROW_BYTES);
    }
    g_assert_false(update(&region));
    g_assert_cmpuint(region.dirty_rows, ==, 0);
    g_assert_cmpuint(region.motion_streak, ==, 0);
    assert_visible_equal(&region);
}

static void test_layout_reset_discards_old_motion(void)
{
    TestRegion region = { 0 };
    uint8_t source[24 * 3];
    uint8_t staging[sizeof(source)];

    enter_high_motion(&region);
    /* Production surface install/reset uses this same reset function. */
    vfio_region_motion_reset(&region.motion_streak, &region.bypass_frames);
    memset(source, 0x51, sizeof(source));
    memcpy(staging, source, sizeof(staging));
    g_assert_false(vfio_region_update_staging(
        staging, source, sizeof(staging), 20, 24, 3,
        &region.motion_streak, &region.bypass_frames,
        region.runs, &region.run_count, &region.dirty_rows,
        &region.too_many_runs));
    source[24 + 7] ^= 1;
    g_assert_true(vfio_region_update_staging(
        staging, source, sizeof(staging), 20, 24, 3,
        &region.motion_streak, &region.bypass_frames,
        region.runs, &region.run_count, &region.dirty_rows,
        &region.too_many_runs));
    g_assert_cmpuint(region.dirty_rows, ==, 1);
    g_assert_cmpuint(region.runs[0].y, ==, 1);
    g_assert_cmpmem(staging, sizeof(staging), source, sizeof(source));
}

static void test_fragmented_damage_preserves_all_pixels(void)
{
    uint8_t source[4 * 66] = { 0 };
    uint8_t staging[sizeof(source)] = { 0 };
    TestRegion region = { 0 };

    for (unsigned y = 0; y < 66; y += 2) {
        source[4 * y] = 1;
    }
    g_assert_true(vfio_region_update_staging(
        staging, source, sizeof(staging), 4, 4, 66,
        &region.motion_streak, &region.bypass_frames,
        region.runs, &region.run_count, &region.dirty_rows,
        &region.too_many_runs));
    g_assert_cmpuint(region.dirty_rows, ==, 33);
    g_assert_cmpuint(region.run_count, ==, 32);
    g_assert_true(region.too_many_runs);
    g_assert_cmpmem(staging, sizeof(staging), source, sizeof(source));
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/vfio-region/motion-to-still", test_motion_to_still);
    g_test_add_func("/vfio-region/motion-to-black", test_motion_to_black);
    g_test_add_func("/vfio-region/single-pixel",
                    test_single_pixel_on_comparison_and_bypass_ticks);
    g_test_add_func("/vfio-region/continuous-motion",
                    test_continuing_motion_keeps_bounded_bypass);
    g_test_add_func("/vfio-region/low-motion-exit",
                    test_low_motion_exits_bypass);
    g_test_add_func("/vfio-region/ignore-padding",
                    test_padding_is_not_visible_damage);
    g_test_add_func("/vfio-region/layout-reset",
                    test_layout_reset_discards_old_motion);
    g_test_add_func("/vfio-region/fragmented-damage",
                    test_fragmented_damage_preserves_all_pixels);
    return g_test_run();
}

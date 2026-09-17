/*
 * Exact-pixel observation timing for optional VFIO REGION idle reports.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "hw/vfio/display-region-idle.h"

static void assert_event(VFIORegionIdleEvent event, unsigned level,
                         bool recovered, int64_t unchanged_us)
{
    g_assert_cmpuint(event.level, ==, level);
    g_assert_cmpint(event.recovered, ==, recovered);
    g_assert_cmpint(event.unchanged_us, ==, unchanged_us);
}

static void test_thresholds_report_once(void)
{
    VFIORegionIdleState state = { 0 };
    const int64_t start_us = 7000000;

    assert_event(vfio_region_idle_sample(&state, start_us, false), 0, false, 0);
    assert_event(vfio_region_idle_sample(&state, start_us + 1999999, false),
                 0, false, 1999999);
    assert_event(vfio_region_idle_sample(&state, start_us + 2000000, false),
                 1, false, 2000000);
    assert_event(vfio_region_idle_sample(&state, start_us + 9999999, false),
                 0, false, 9999999);
    assert_event(vfio_region_idle_sample(&state, start_us + 10000000, false),
                 2, false, 10000000);
    assert_event(vfio_region_idle_sample(&state, start_us + 29999999, false),
                 0, false, 29999999);
    assert_event(vfio_region_idle_sample(&state, start_us + 30000000, false),
                 3, false, 30000000);
    assert_event(vfio_region_idle_sample(&state, start_us + 90000000, false),
                 0, false, 90000000);
}

static void test_sampling_gap_reports_highest_only(void)
{
    VFIORegionIdleState state = { 0 };

    /* Zero is a valid first timestamp, not an uninitialized sentinel. */
    assert_event(vfio_region_idle_sample(&state, 0, false), 0, false, 0);
    assert_event(vfio_region_idle_sample(&state, 60000000, false),
                 3, false, 60000000);
    assert_event(vfio_region_idle_sample(&state, 60000001, false),
                 0, false, 60000001);

    vfio_region_idle_reset(&state);
    assert_event(vfio_region_idle_sample(&state, 0, false), 0, false, 0);
    assert_event(vfio_region_idle_sample(&state, 15000000, false),
                 2, false, 15000000);
    assert_event(vfio_region_idle_sample(&state, 15000001, false),
                 0, false, 15000001);
    assert_event(vfio_region_idle_sample(&state, 30000000, false),
                 3, false, 30000000);
}

static void test_confirmed_change_recovers_once(void)
{
    VFIORegionIdleState state = { 0 };

    assert_event(vfio_region_idle_sample(&state, 0, false), 0, false, 0);
    /* A change before any report must not claim a recovery. */
    assert_event(vfio_region_idle_sample(&state, 1000000, true),
                 0, false, 1000000);
    assert_event(vfio_region_idle_sample(&state, 2999999, false),
                 0, false, 1999999);
    assert_event(vfio_region_idle_sample(&state, 3000000, false),
                 1, false, 2000000);
    assert_event(vfio_region_idle_sample(&state, 4000000, true),
                 0, true, 3000000);
    assert_event(vfio_region_idle_sample(&state, 4500000, true),
                 0, false, 500000);
    assert_event(vfio_region_idle_sample(&state, 6500000, false),
                 1, false, 2000000);
}

static void test_reset_discards_previous_observations(void)
{
    VFIORegionIdleState state = { 0 };

    assert_event(vfio_region_idle_sample(&state, 0, false), 0, false, 0);
    assert_event(vfio_region_idle_sample(&state, 30000000, false),
                 3, false, 30000000);
    vfio_region_idle_reset(&state);
    assert_event(vfio_region_idle_sample(&state, 60000000, true),
                 0, false, 0);
    assert_event(vfio_region_idle_sample(&state, 61999999, false),
                 0, false, 1999999);
    assert_event(vfio_region_idle_sample(&state, 62000000, false),
                 1, false, 2000000);
}

static void test_clock_reversal_restarts_observation(void)
{
    VFIORegionIdleState state = { 0 };

    assert_event(vfio_region_idle_sample(&state, 5000000, false),
                 0, false, 0);
    assert_event(vfio_region_idle_sample(&state, 7000000, false),
                 1, false, 2000000);
    assert_event(vfio_region_idle_sample(&state, 0, true), 0, false, 0);
    assert_event(vfio_region_idle_sample(&state, 2000000, false),
                 1, false, 2000000);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/vfio-region/idle/thresholds",
                    test_thresholds_report_once);
    g_test_add_func("/vfio-region/idle/sampling-gap",
                    test_sampling_gap_reports_highest_only);
    g_test_add_func("/vfio-region/idle/recovery",
                    test_confirmed_change_recovers_once);
    g_test_add_func("/vfio-region/idle/reset",
                    test_reset_discards_previous_observations);
    g_test_add_func("/vfio-region/idle/clock-reversal",
                    test_clock_reversal_restarts_observation);
    return g_test_run();
}

/*
 * Exact VFIO REGION staging updates with bounded high-motion comparison gaps.
 * SPDX-License-Identifier: GPL-2.0-only
 */
#ifndef HW_VFIO_DISPLAY_REGION_MOTION_H
#define HW_VFIO_DISPLAY_REGION_MOTION_H

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#define VFIO_REGION_MAX_DIRTY_RUNS        32
#define VFIO_REGION_FULL_MOTION_PERCENT   75
#define VFIO_REGION_FULL_MOTION_STREAK     8
#define VFIO_REGION_COMPARE_BYPASS_FRAMES  8

typedef struct VFIORegionDirtyRun {
    uint32_t y;
    uint32_t height;
} VFIORegionDirtyRun;

static inline void vfio_region_motion_reset(uint32_t *full_motion_streak,
                                            uint32_t *compare_bypass_frames)
{
    *full_motion_streak = 0;
    *compare_bypass_frames = 0;
}

/*
 * The caller has validated the layout and installed a stable staging surface.
 * Copy every bypassed frame, but recheck visible pixels on each eighth update.
 * A still source therefore produces at most seven redundant full updates;
 * continuing high motion retains the bypass without another warm-up streak.
 * Padding is copied on full updates, but never used to infer visible damage.
 */
static inline bool vfio_region_update_staging(
    uint8_t *staging_base, const uint8_t *source, size_t staging_size,
    size_t row_bytes, uint32_t stride, uint32_t height,
    uint32_t *full_motion_streak, uint32_t *compare_bypass_frames,
    VFIORegionDirtyRun runs[VFIO_REGION_MAX_DIRTY_RUNS],
    uint32_t *run_count, uint32_t *dirty_rows, bool *too_many_runs)
{
    uint32_t y;
    uint32_t run_start = 0;
    bool in_run = false;

    *run_count = 0;
    *dirty_rows = 0;
    *too_many_runs = false;

    if (*compare_bypass_frames) {
        /* Consumers see only staging, including during the comparison gap. */
        memcpy(staging_base, source, staging_size);
        (*compare_bypass_frames)--;
        runs[0].y = 0;
        runs[0].height = height;
        *run_count = 1;
        *dirty_rows = height;
        return true;
    }

    for (y = 0; y < height; y++) {
        const uint8_t *src = source + (size_t)y * stride;
        uint8_t *staging = staging_base + (size_t)y * stride;
        bool changed = memcmp(src, staging, row_bytes) != 0;

        if (changed) {
            memcpy(staging, src, row_bytes);
            (*dirty_rows)++;
            if (!in_run) {
                run_start = y;
                in_run = true;
            }
        } else if (in_run) {
            if (*run_count < VFIO_REGION_MAX_DIRTY_RUNS) {
                runs[*run_count].y = run_start;
                runs[*run_count].height = y - run_start;
                (*run_count)++;
            } else {
                *too_many_runs = true;
            }
            in_run = false;
        }
    }
    if (in_run) {
        if (*run_count < VFIO_REGION_MAX_DIRTY_RUNS) {
            runs[*run_count].y = run_start;
            runs[*run_count].height = y - run_start;
            (*run_count)++;
        } else {
            *too_many_runs = true;
        }
    }

    if (!*dirty_rows) {
        vfio_region_motion_reset(full_motion_streak, compare_bypass_frames);
        return false;
    }
    if ((uint64_t)*dirty_rows * 100 >=
        (uint64_t)height * VFIO_REGION_FULL_MOTION_PERCENT) {
        if (*full_motion_streak < VFIO_REGION_FULL_MOTION_STREAK) {
            (*full_motion_streak)++;
        }
        if (*full_motion_streak >= VFIO_REGION_FULL_MOTION_STREAK) {
            *compare_bypass_frames = VFIO_REGION_COMPARE_BYPASS_FRAMES - 1;
        }
    } else {
        vfio_region_motion_reset(full_motion_streak, compare_bypass_frames);
    }
    return true;
}

#endif /* HW_VFIO_DISPLAY_REGION_MOTION_H */

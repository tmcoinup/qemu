/*
 * Optional elapsed-time reporting for exact VFIO REGION pixel observations.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef HW_VFIO_DISPLAY_REGION_IDLE_H
#define HW_VFIO_DISPLAY_REGION_IDLE_H

#include <stdbool.h>
#include <stdint.h>

typedef struct VFIORegionIdleState {
    bool started;
    int64_t unchanged_since_us;
    unsigned reported_level;
} VFIORegionIdleState;

typedef struct VFIORegionIdleEvent {
    /* 0: no new threshold, 1: 2 seconds, 2: 10 seconds, 3: 30 seconds. */
    unsigned level;
    bool recovered;
    int64_t unchanged_us;
} VFIORegionIdleEvent;

static inline void vfio_region_idle_reset(VFIORegionIdleState *state)
{
    *state = (VFIORegionIdleState) { 0 };
}

/*
 * Call only after an exact visible-pixel comparison.  A copied frame whose
 * comparison was bypassed is neither an unchanged nor a changed observation.
 * Reset instead on failures, missing planes, and source or layout changes.
 *
 * Elapsed time describes observations, not proof that the producer was idle
 * between samples.  In particular, a long sampling gap emits only its highest
 * reached threshold; it must not produce a burst of stale lower-level reports.
 * A recovery event means confirmed pixel changes resumed after a report, not
 * that an upstream fault was identified or repaired.
 */
static inline VFIORegionIdleEvent vfio_region_idle_sample(
    VFIORegionIdleState *state, int64_t now_us, bool changed)
{
    VFIORegionIdleEvent event = { 0 };
    unsigned level;

    if (!state->started || now_us < state->unchanged_since_us) {
        state->started = true;
        state->unchanged_since_us = now_us;
        state->reported_level = 0;
        return event;
    }

    event.unchanged_us = now_us - state->unchanged_since_us;
    if (changed) {
        event.recovered = state->reported_level != 0;
        state->unchanged_since_us = now_us;
        state->reported_level = 0;
        return event;
    }

    if (event.unchanged_us >= 30000000) {
        level = 3;
    } else if (event.unchanged_us >= 10000000) {
        level = 2;
    } else if (event.unchanged_us >= 2000000) {
        level = 1;
    } else {
        level = 0;
    }
    if (level > state->reported_level) {
        state->reported_level = level;
        event.level = level;
    }
    return event;
}

#endif /* HW_VFIO_DISPLAY_REGION_IDLE_H */

/* SPDX-License-Identifier: MIT */

#ifndef QEMU_UI_SDL2_POINTER_H
#define QEMU_UI_SDL2_POINTER_H

#include <stdbool.h>
#include <stdint.h>

typedef struct SDL2Point {
    int x;
    int y;
} SDL2Point;

typedef struct SDL2Rect {
    int x;
    int y;
    int width;
    int height;
} SDL2Rect;

typedef struct SDL2Size {
    int width;
    int height;
} SDL2Size;

/* Fractional state retained between relative-motion events. */
typedef struct SDL2AxisScale {
    int source_extent;
    int target_extent;
    int64_t remainder;
} SDL2AxisScale;

/* Keep the current handler separate from the available device capability. */
typedef struct SDL2PointerPolicy {
    bool accept_motion;
    bool auto_grab_on_click;
    bool relative_mode;
    bool release_grab;
} SDL2PointerPolicy;

SDL2PointerPolicy sdl2_pointer_policy(bool grabbed,
                                      bool current_absolute,
                                      bool absolute_available);
SDL2Rect sdl2_guest_dst_rect(SDL2Size window, SDL2Size guest);
bool sdl2_window_to_guest(SDL2Rect dst, SDL2Size guest,
                          SDL2Point window_point, SDL2Point *guest_point);
bool sdl2_guest_to_window(SDL2Rect dst, SDL2Size guest,
                          SDL2Point guest_point, SDL2Point *window_point);
bool sdl2_map_point(SDL2Size source, SDL2Size target,
                    SDL2Point source_point, SDL2Point *target_point);
SDL2Rect sdl2_gl_viewport(SDL2Size output, SDL2Rect top_left);
int sdl2_scale_relative_motion(int delta,
                               int source_extent, int target_extent,
                               SDL2AxisScale *state);
bool sdl2_select_guest_size(bool scanout_mode,
                            SDL2Size surface, SDL2Size scanout,
                            SDL2Size *guest);

#endif /* QEMU_UI_SDL2_POINTER_H */

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

/*
 * Keep the fractional part of one relative-motion axis between SDL events.
 * The extents are part of the state so a resize automatically starts a new
 * conversion instead of applying an old remainder to a different ratio.
 */
typedef struct SDL2AxisScale {
    int source_extent;
    int target_extent;
    int64_t remainder;
} SDL2AxisScale;

/*
 * Return the centered destination rectangle used to display a guest surface.
 * The guest is never enlarged past its native size.  A smaller window scales
 * the guest down while preserving its aspect ratio.
 */
SDL2Rect sdl2_guest_dst_rect(SDL2Size window, SDL2Size guest);

/*
 * Map an SDL window point through the visible guest rectangle.  Coordinates
 * outside the rectangle are clamped on each axis independently.
 */
bool sdl2_window_to_guest(SDL2Rect dst, SDL2Size guest,
                          SDL2Point window_point, SDL2Point *guest_point);

/*
 * Map a guest point back into the visible SDL window rectangle.  This is used
 * when a relative pointing device asks SDL to warp its software cursor.
 */
bool sdl2_guest_to_window(SDL2Rect dst, SDL2Size guest,
                          SDL2Point guest_point, SDL2Point *window_point);

/*
 * Map a point between two pixel coordinate spaces while preserving both
 * endpoints.  This is used for logical-window to drawable/output conversion
 * on high-DPI displays.
 */
bool sdl2_map_point(SDL2Size source, SDL2Size target,
                    SDL2Point source_point, SDL2Point *target_point);

/*
 * Convert a top-left SDL rectangle to an OpenGL bottom-left viewport.
 * The asymmetric pixel of an odd-sized border remains on the same visual side.
 */
SDL2Rect sdl2_gl_viewport(SDL2Size output, SDL2Rect top_left);

/*
 * Convert a scanout rectangle into OpenGL framebuffer coordinates.
 * A negative returned height deliberately reverses the source orientation.
 * Top-origin scanouts also need their Y offset reflected around the backing
 * texture height; merely swapping the two endpoints selects the wrong strip.
 */
SDL2Rect sdl2_gl_scanout_source_rect(SDL2Size backing, SDL2Rect scanout,
                                     bool y0_top);

/*
 * Scale a relative-motion delta and retain its fractional remainder.  Keeping
 * the state per console prevents small movements from being lost forever at
 * ratios such as 3:2.
 */
int sdl2_scale_relative_motion(int delta,
                               int source_extent, int target_extent,
                               SDL2AxisScale *state);

/*
 * Select the dimensions currently rendered by SDL.  GL scanout dimensions
 * take precedence only while scanout mode is active and valid.
 */
bool sdl2_select_guest_size(bool scanout_mode,
                            SDL2Size surface, SDL2Size scanout,
                            SDL2Size *guest);

#endif /* QEMU_UI_SDL2_POINTER_H */

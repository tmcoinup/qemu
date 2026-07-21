/*
 * QEMU SDL pointer geometry helpers
 *
 * SPDX-License-Identifier: MIT
 */

#include "qemu/osdep.h"
#include "ui/sdl2-pointer.h"

static bool sdl2_size_is_valid(SDL2Size size)
{
    return size.width > 0 && size.height > 0;
}

static int64_t sdl2_clamp_i64(int64_t value,
                              int64_t minimum, int64_t maximum)
{
    if (value < minimum) {
        return minimum;
    }
    if (value > maximum) {
        return maximum;
    }
    return value;
}

static int sdl2_saturate_int(int64_t value)
{
    return sdl2_clamp_i64(value, INT_MIN, INT_MAX);
}

SDL2PointerPolicy sdl2_pointer_policy(bool grabbed,
                                      bool current_absolute,
                                      bool absolute_available)
{
    return (SDL2PointerPolicy) {
        .accept_motion = grabbed || absolute_available,
        .auto_grab_on_click = !grabbed && !absolute_available,
        .relative_mode = grabbed && !current_absolute,
        .release_grab = grabbed && absolute_available,
    };
}

/*
 * Pixel coordinates describe inclusive endpoints.  Mapping extent - 1 keeps
 * the first and last pixel aligned in both directions; rounding avoids a
 * systematic bias towards the top-left corner.
 */
static int sdl2_map_axis(int64_t value, int source_extent, int target_extent)
{
    int64_t clamped;

    if (target_extent == 1) {
        return 0;
    }
    if (source_extent == 1) {
        return (target_extent - 1) / 2;
    }

    clamped = sdl2_clamp_i64(value, 0, source_extent - 1);
    return ((clamped * (target_extent - 1)) + (source_extent - 1) / 2) /
        (source_extent - 1);
}

SDL2Rect sdl2_guest_dst_rect(SDL2Size window, SDL2Size guest)
{
    SDL2Rect rect = { 0 };

    if (!sdl2_size_is_valid(window)) {
        return rect;
    }
    if (!sdl2_size_is_valid(guest)) {
        rect.width = window.width;
        rect.height = window.height;
        return rect;
    }

    if (window.width >= guest.width && window.height >= guest.height) {
        rect.width = guest.width;
        rect.height = guest.height;
    } else if ((int64_t)window.width * guest.height <=
               (int64_t)window.height * guest.width) {
        rect.width = window.width;
        rect.height = MAX(((int64_t)guest.height * rect.width +
                           guest.width / 2) / guest.width, 1);
    } else {
        rect.height = window.height;
        rect.width = MAX(((int64_t)guest.width * rect.height +
                          guest.height / 2) / guest.height, 1);
    }
    rect.x = (window.width - rect.width) / 2;
    rect.y = (window.height - rect.height) / 2;
    return rect;
}

bool sdl2_window_to_guest(SDL2Rect dst, SDL2Size guest,
                          SDL2Point window_point, SDL2Point *guest_point)
{
    int64_t local_x;
    int64_t local_y;

    if (!guest_point || dst.width <= 0 || dst.height <= 0 ||
        !sdl2_size_is_valid(guest)) {
        return false;
    }

    local_x = (int64_t)window_point.x - dst.x;
    local_y = (int64_t)window_point.y - dst.y;
    guest_point->x = sdl2_map_axis(local_x, dst.width, guest.width);
    guest_point->y = sdl2_map_axis(local_y, dst.height, guest.height);
    return true;
}

bool sdl2_guest_to_window(SDL2Rect dst, SDL2Size guest,
                          SDL2Point guest_point, SDL2Point *window_point)
{
    if (!window_point || dst.width <= 0 || dst.height <= 0 ||
        !sdl2_size_is_valid(guest)) {
        return false;
    }

    window_point->x = sdl2_saturate_int(
        (int64_t)dst.x +
        sdl2_map_axis(guest_point.x, guest.width, dst.width));
    window_point->y = sdl2_saturate_int(
        (int64_t)dst.y +
        sdl2_map_axis(guest_point.y, guest.height, dst.height));
    return true;
}

bool sdl2_map_point(SDL2Size source, SDL2Size target,
                    SDL2Point source_point, SDL2Point *target_point)
{
    if (!target_point ||
        !sdl2_size_is_valid(source) || !sdl2_size_is_valid(target)) {
        return false;
    }

    target_point->x = sdl2_map_axis(source_point.x,
                                    source.width, target.width);
    target_point->y = sdl2_map_axis(source_point.y,
                                    source.height, target.height);
    return true;
}

SDL2Rect sdl2_gl_viewport(SDL2Size output, SDL2Rect top_left)
{
    SDL2Rect viewport = { 0 };

    if (!sdl2_size_is_valid(output) ||
        top_left.width <= 0 || top_left.height <= 0) {
        return viewport;
    }

    viewport = top_left;
    viewport.y = sdl2_saturate_int(
        (int64_t)output.height - top_left.y - top_left.height);
    return viewport;
}

SDL2Rect sdl2_gl_scanout_source_rect(SDL2Size backing, SDL2Rect scanout,
                                     bool y0_top)
{
    SDL2Rect source = { 0 };

    if (!sdl2_size_is_valid(backing) ||
        scanout.x < 0 || scanout.y < 0 ||
        scanout.width <= 0 || scanout.height <= 0 ||
        (int64_t)scanout.x + scanout.width > backing.width ||
        (int64_t)scanout.y + scanout.height > backing.height) {
        return source;
    }

    source.x = scanout.x;
    source.width = scanout.width;
    if (y0_top) {
        /*
         * OpenGL addresses a framebuffer from the bottom.  The scanout Y value
         * is measured from the top when y0_top is set, so select the reflected
         * strip while retaining the established, upright display orientation.
         */
        source.y = backing.height - scanout.y - scanout.height;
        source.height = scanout.height;
    } else {
        /*
         * A conventional bottom-up texture needs its selected strip reversed
         * when copied into the upright window framebuffer.
         */
        source.y = scanout.y + scanout.height;
        source.height = -scanout.height;
    }
    return source;
}

int sdl2_scale_relative_motion(int delta,
                               int source_extent, int target_extent,
                               SDL2AxisScale *state)
{
    int64_t numerator;
    int64_t scaled;

    if (!state || source_extent <= 0 || target_extent <= 0) {
        if (state) {
            *state = (SDL2AxisScale) { 0 };
        }
        return 0;
    }

    if (state->source_extent != source_extent ||
        state->target_extent != target_extent) {
        *state = (SDL2AxisScale) {
            .source_extent = source_extent,
            .target_extent = target_extent,
        };
    }

    numerator = (int64_t)delta * target_extent + state->remainder;
    scaled = numerator / source_extent;
    state->remainder = numerator % source_extent;
    return sdl2_saturate_int(scaled);
}

bool sdl2_select_guest_size(bool scanout_mode,
                            SDL2Size surface, SDL2Size scanout,
                            SDL2Size *guest)
{
    if (!guest) {
        return false;
    }
    if (scanout_mode && sdl2_size_is_valid(scanout)) {
        *guest = scanout;
        return true;
    }
    if (sdl2_size_is_valid(surface)) {
        *guest = surface;
        return true;
    }

    *guest = (SDL2Size) { 0 };
    return false;
}

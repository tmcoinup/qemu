/*
 * Host-side composited cursor matcher for the SDL VFIO REGION fallback.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "ui/sdl2-cursor.h"

#define SDL2_CURSOR_DARK_ALPHA_MIN 180
#define SDL2_CURSOR_DARK_CHANNEL_MAX 32
#define SDL2_CURSOR_DARK_TOLERANCE 12
#define SDL2_CURSOR_LIGHT_CHANNEL_MIN 176
#define SDL2_CURSOR_DARK_REQUIRED_PERCENT 85
#define SDL2_CURSOR_LIGHT_REQUIRED_PERCENT 90
#define SDL2_CURSOR_MIN_CLASS_SAMPLES 12

static uint8_t sdl2_cursor_dark_output_limit(uint8_t foreground,
                                             uint8_t alpha)
{
    unsigned int maximum =
        ((unsigned int)alpha * foreground +
         (unsigned int)(255 - alpha) * 255 + 127) / 255;

    return MIN(maximum + SDL2_CURSOR_DARK_TOLERANCE, 255);
}

bool sdl2_cursor_template_init_rgba(SDL2CursorTemplate *cursor,
                                    const uint8_t *rgba,
                                    int width, int height, int stride,
                                    int hot_x, int hot_y)
{
    int x;
    int y;

    if (!cursor) {
        return false;
    }
    memset(cursor, 0, sizeof(*cursor));
    if (!rgba || width <= 0 || height <= 0 || width > UINT16_MAX ||
        height > UINT16_MAX || stride < width * 4 || hot_x < 0 || hot_y < 0 ||
        hot_x >= width || hot_y >= height ||
        (size_t)width * height > SDL2_CURSOR_TEMPLATE_MAX_SAMPLES) {
        return false;
    }

    cursor->width = width;
    cursor->height = height;
    cursor->hot_x = hot_x;
    cursor->hot_y = hot_y;
    for (y = 0; y < height; y++) {
        const uint8_t *row = rgba + (size_t)y * stride;

        for (x = 0; x < width; x++) {
            const uint8_t *pixel = row + x * 4;
            uint8_t red = pixel[0];
            uint8_t green = pixel[1];
            uint8_t blue = pixel[2];
            uint8_t alpha = pixel[3];

            if (alpha >= SDL2_CURSOR_DARK_ALPHA_MIN &&
                MAX(red, MAX(green, blue)) <=
                    SDL2_CURSOR_DARK_CHANNEL_MAX) {
                SDL2CursorSample *sample =
                    &cursor->dark[cursor->dark_count++];

                sample->x = x;
                sample->y = y;
                /*
                 * With an unknown background, alpha blending can never make
                 * these channels brighter than compositing over white.
                 */
                sample->red = sdl2_cursor_dark_output_limit(red, alpha);
                sample->green = sdl2_cursor_dark_output_limit(green, alpha);
                sample->blue = sdl2_cursor_dark_output_limit(blue, alpha);
            } else if (alpha == 255 &&
                       MIN(red, MIN(green, blue)) >=
                           SDL2_CURSOR_LIGHT_CHANNEL_MIN) {
                SDL2CursorSample *sample =
                    &cursor->light[cursor->light_count++];

                sample->x = x;
                sample->y = y;
                sample->red = red;
                sample->green = green;
                sample->blue = blue;
            }
        }
    }

    if (cursor->dark_count < SDL2_CURSOR_MIN_CLASS_SAMPLES ||
        cursor->light_count < SDL2_CURSOR_MIN_CLASS_SAMPLES) {
        memset(cursor, 0, sizeof(*cursor));
        return false;
    }
    return true;
}

static void sdl2_cursor_read_xrgb8888(const uint8_t *address,
                                      uint8_t *red, uint8_t *green,
                                      uint8_t *blue)
{
    uint32_t pixel;

    memcpy(&pixel, address, sizeof(pixel));
    *red = pixel >> 16;
    *green = pixel >> 8;
    *blue = pixel;
}

static bool sdl2_cursor_match_at(const SDL2CursorTemplate *cursor,
                                 const uint8_t *frame, int stride,
                                 int left, int top)
{
    unsigned int dark_hits = 0;
    unsigned int light_hits = 0;
    unsigned int index;

    for (index = 0; index < cursor->dark_count; index++) {
        const SDL2CursorSample *sample = &cursor->dark[index];
        const uint8_t *pixel = frame + (size_t)(top + sample->y) * stride +
                               (size_t)(left + sample->x) * 4;
        uint8_t red;
        uint8_t green;
        uint8_t blue;

        sdl2_cursor_read_xrgb8888(pixel, &red, &green, &blue);
        if (red <= sample->red && green <= sample->green &&
            blue <= sample->blue) {
            dark_hits++;
        }
    }
    if (dark_hits * 100 <
        cursor->dark_count * SDL2_CURSOR_DARK_REQUIRED_PERCENT) {
        return false;
    }

    for (index = 0; index < cursor->light_count; index++) {
        const SDL2CursorSample *sample = &cursor->light[index];
        const uint8_t *pixel = frame + (size_t)(top + sample->y) * stride +
                               (size_t)(left + sample->x) * 4;
        uint8_t red;
        uint8_t green;
        uint8_t blue;

        sdl2_cursor_read_xrgb8888(pixel, &red, &green, &blue);
        if (ABS((int)red - sample->red) <= 8 &&
            ABS((int)green - sample->green) <= 8 &&
            ABS((int)blue - sample->blue) <= 8) {
            light_hits++;
        }
    }
    return light_hits * 100 >=
           cursor->light_count * SDL2_CURSOR_LIGHT_REQUIRED_PERCENT;
}

bool sdl2_cursor_match_xrgb8888(const SDL2CursorTemplate *cursor,
                                const uint8_t *frame,
                                int width, int height, int stride,
                                int pointer_x, int pointer_y,
                                int search_radius)
{
    int nominal_left;
    int nominal_top;
    int dx;
    int dy;

    if (!cursor || !cursor->dark_count || !cursor->light_count || !frame ||
        width <= 0 || height <= 0 || stride < width * 4 ||
        search_radius < 0 || search_radius > 16) {
        return false;
    }
    nominal_left = pointer_x - cursor->hot_x;
    nominal_top = pointer_y - cursor->hot_y;
    for (dy = -search_radius; dy <= search_radius; dy++) {
        int top = nominal_top + dy;

        if (top < 0 || top + cursor->height > height) {
            continue;
        }
        for (dx = -search_radius; dx <= search_radius; dx++) {
            int left = nominal_left + dx;

            if (left < 0 || left + cursor->width > width) {
                continue;
            }
            if (sdl2_cursor_match_at(cursor, frame, stride, left, top)) {
                return true;
            }
        }
    }
    return false;
}

void sdl2_cursor_history_reset(SDL2CursorHistory *history)
{
    if (history) {
        memset(history, 0, sizeof(*history));
    }
}

void sdl2_cursor_history_record(SDL2CursorHistory *history,
                                int x, int y, int64_t time_us)
{
    unsigned int latest;

    if (!history) {
        return;
    }
    if (history->count) {
        latest = (history->next + SDL2_CURSOR_HISTORY_CAPACITY - 1) %
                 SDL2_CURSOR_HISTORY_CAPACITY;
        if (history->entries[latest].x == x &&
            history->entries[latest].y == y) {
            history->entries[latest].time_us = time_us;
            return;
        }
    }
    history->entries[history->next] = (SDL2CursorHistoryEntry) {
        .x = x,
        .y = y,
        .time_us = time_us,
    };
    history->next = (history->next + 1) % SDL2_CURSOR_HISTORY_CAPACITY;
    history->count = MIN(history->count + 1,
                         SDL2_CURSOR_HISTORY_CAPACITY);
}

bool sdl2_cursor_history_match_xrgb8888(
    const SDL2CursorTemplate *cursor,
    const SDL2CursorHistory *history,
    const uint8_t *frame, int width, int height, int stride,
    int64_t now_us, int64_t max_age_us, int search_radius,
    int *matched_x, int *matched_y)
{
    unsigned int offset;
    int previous_x = INT_MIN;
    int previous_y = INT_MIN;

    if (!history || !history->count || max_age_us < 0) {
        return false;
    }
    for (offset = 0; offset < history->count; offset++) {
        unsigned int index =
            (history->next + SDL2_CURSOR_HISTORY_CAPACITY - 1 - offset) %
            SDL2_CURSOR_HISTORY_CAPACITY;
        const SDL2CursorHistoryEntry *entry = &history->entries[index];

        if (entry->time_us > now_us ||
            now_us - entry->time_us > max_age_us) {
            continue;
        }
        if (entry->x == previous_x && entry->y == previous_y) {
            continue;
        }
        previous_x = entry->x;
        previous_y = entry->y;
        if (sdl2_cursor_match_xrgb8888(cursor, frame, width, height, stride,
                                       entry->x, entry->y,
                                       search_radius)) {
            if (matched_x) {
                *matched_x = entry->x;
            }
            if (matched_y) {
                *matched_y = entry->y;
            }
            return true;
        }
    }
    return false;
}

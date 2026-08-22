/* SPDX-License-Identifier: GPL-2.0-or-later */

#ifndef QEMU_UI_SDL2_CURSOR_H
#define QEMU_UI_SDL2_CURSOR_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define SDL2_CURSOR_TEMPLATE_MAX_SAMPLES 1024
#define SDL2_CURSOR_HISTORY_CAPACITY 128

typedef struct SDL2CursorSample {
    uint16_t x;
    uint16_t y;
    uint8_t red;
    uint8_t green;
    uint8_t blue;
} SDL2CursorSample;

typedef struct SDL2CursorTemplate {
    uint16_t width;
    uint16_t height;
    uint16_t hot_x;
    uint16_t hot_y;
    uint16_t dark_count;
    uint16_t light_count;
    /*
     * Dark samples store the maximum allowed output channel.  Fully opaque
     * light samples store the exact source colour.
     */
    SDL2CursorSample dark[SDL2_CURSOR_TEMPLATE_MAX_SAMPLES];
    SDL2CursorSample light[SDL2_CURSOR_TEMPLATE_MAX_SAMPLES];
} SDL2CursorTemplate;

typedef struct SDL2CursorHistoryEntry {
    int x;
    int y;
    int64_t time_us;
} SDL2CursorHistoryEntry;

typedef struct SDL2CursorHistory {
    SDL2CursorHistoryEntry entries[SDL2_CURSOR_HISTORY_CAPACITY];
    unsigned int next;
    unsigned int count;
} SDL2CursorHistory;

/* Template pixels are byte-ordered RGBA. */
bool sdl2_cursor_template_init_rgba(SDL2CursorTemplate *cursor,
                                    const uint8_t *rgba,
                                    int width, int height, int stride,
                                    int hot_x, int hot_y);

/* The REGION staging surface is PIXMAN_[ax]8r8g8b8. */
bool sdl2_cursor_match_xrgb8888(const SDL2CursorTemplate *cursor,
                                const uint8_t *frame,
                                int width, int height, int stride,
                                int pointer_x, int pointer_y,
                                int search_radius);

void sdl2_cursor_history_reset(SDL2CursorHistory *history);
void sdl2_cursor_history_record(SDL2CursorHistory *history,
                                int x, int y, int64_t time_us);
bool sdl2_cursor_history_match_xrgb8888(
    const SDL2CursorTemplate *cursor,
    const SDL2CursorHistory *history,
    const uint8_t *frame, int width, int height, int stride,
    int64_t now_us, int64_t max_age_us, int search_radius,
    int *matched_x, int *matched_y);

#endif /* QEMU_UI_SDL2_CURSOR_H */

/*
 * SDL composited cursor matcher tests
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "ui/sdl2-cursor.h"

#define TEMPLATE_WIDTH 16
#define TEMPLATE_HEIGHT 16
#define FRAME_WIDTH 80
#define FRAME_HEIGHT 60

static uint8_t template_rgba[TEMPLATE_WIDTH * TEMPLATE_HEIGHT * 4];
static uint32_t frame[FRAME_WIDTH * FRAME_HEIGHT];

static uint8_t blend(uint8_t foreground, uint8_t background, uint8_t alpha)
{
    return ((unsigned int)foreground * alpha +
            (unsigned int)background * (255 - alpha) + 127) / 255;
}

static void template_pixel(int x, int y,
                           uint8_t red, uint8_t green, uint8_t blue,
                           uint8_t alpha)
{
    uint8_t *pixel = template_rgba + (y * TEMPLATE_WIDTH + x) * 4;

    pixel[0] = red;
    pixel[1] = green;
    pixel[2] = blue;
    pixel[3] = alpha;
}

static void make_template(SDL2CursorTemplate *cursor)
{
    int x;
    int y;

    memset(template_rgba, 0, sizeof(template_rgba));
    /*
     * Two independent classes prevent a plain light or dark patch from
     * looking like a cursor.
     */
    for (y = 0; y < 4; y++) {
        for (x = 0; x < 4; x++) {
            template_pixel(x, y, 0, 1, 14, 231);
            template_pixel(x + 5, y + 5, 255, 255, 255, 255);
        }
    }
    g_assert_true(sdl2_cursor_template_init_rgba(
        cursor, template_rgba, TEMPLATE_WIDTH, TEMPLATE_HEIGHT,
        TEMPLATE_WIDTH * 4, 1, 1));
    g_assert_cmpuint(cursor->dark_count, ==, 16);
    g_assert_cmpuint(cursor->light_count, ==, 16);
}

static void fill_frame(uint8_t red, uint8_t green, uint8_t blue)
{
    uint32_t pixel = ((uint32_t)red << 16) |
                     ((uint32_t)green << 8) | blue;
    size_t index;

    for (index = 0; index < G_N_ELEMENTS(frame); index++) {
        frame[index] = pixel;
    }
}

static void composite_template(int left, int top)
{
    int x;
    int y;

    for (y = 0; y < TEMPLATE_HEIGHT; y++) {
        for (x = 0; x < TEMPLATE_WIDTH; x++) {
            const uint8_t *source =
                template_rgba + (y * TEMPLATE_WIDTH + x) * 4;
            uint32_t *destination =
                &frame[(top + y) * FRAME_WIDTH + left + x];
            uint8_t alpha = source[3];
            uint8_t red = *destination >> 16;
            uint8_t green = *destination >> 8;
            uint8_t blue = *destination;

            red = blend(source[0], red, alpha);
            green = blend(source[1], green, alpha);
            blue = blend(source[2], blue, alpha);
            *destination = ((uint32_t)red << 16) |
                           ((uint32_t)green << 8) | blue;
        }
    }
}

static void test_match_backgrounds(void)
{
    SDL2CursorTemplate cursor;

    make_template(&cursor);

    fill_frame(255, 255, 255);
    composite_template(30, 20);
    g_assert_true(sdl2_cursor_match_xrgb8888(
        &cursor, (uint8_t *)frame, FRAME_WIDTH, FRAME_HEIGHT,
        FRAME_WIDTH * 4, 31, 21, 0));

    fill_frame(8, 12, 20);
    composite_template(30, 20);
    g_assert_true(sdl2_cursor_match_xrgb8888(
        &cursor, (uint8_t *)frame, FRAME_WIDTH, FRAME_HEIGHT,
        FRAME_WIDTH * 4, 31, 21, 0));

    fill_frame(90, 140, 210);
    composite_template(30, 20);
    g_assert_true(sdl2_cursor_match_xrgb8888(
        &cursor, (uint8_t *)frame, FRAME_WIDTH, FRAME_HEIGHT,
        FRAME_WIDTH * 4, 31, 21, 0));
}

static void test_fail_safe_plain_frames(void)
{
    SDL2CursorTemplate cursor;

    make_template(&cursor);
    fill_frame(255, 255, 255);
    g_assert_false(sdl2_cursor_match_xrgb8888(
        &cursor, (uint8_t *)frame, FRAME_WIDTH, FRAME_HEIGHT,
        FRAME_WIDTH * 4, 31, 21, 2));
    fill_frame(0, 0, 0);
    g_assert_false(sdl2_cursor_match_xrgb8888(
        &cursor, (uint8_t *)frame, FRAME_WIDTH, FRAME_HEIGHT,
        FRAME_WIDTH * 4, 31, 21, 2));
}

static void test_search_and_corruption(void)
{
    SDL2CursorTemplate cursor;
    int x;
    int y;

    make_template(&cursor);
    fill_frame(255, 255, 255);
    composite_template(32, 19);
    g_assert_true(sdl2_cursor_match_xrgb8888(
        &cursor, (uint8_t *)frame, FRAME_WIDTH, FRAME_HEIGHT,
        FRAME_WIDTH * 4, 31, 21, 2));
    g_assert_false(sdl2_cursor_match_xrgb8888(
        &cursor, (uint8_t *)frame, FRAME_WIDTH, FRAME_HEIGHT,
        FRAME_WIDTH * 4, 31, 21, 1));

    for (y = 19; y < 23; y++) {
        for (x = 32; x < 36; x++) {
            frame[y * FRAME_WIDTH + x] = 0x00ffffff;
        }
    }
    g_assert_false(sdl2_cursor_match_xrgb8888(
        &cursor, (uint8_t *)frame, FRAME_WIDTH, FRAME_HEIGHT,
        FRAME_WIDTH * 4, 33, 20, 0));
}

static void test_history(void)
{
    SDL2CursorTemplate cursor;
    SDL2CursorHistory history = { 0 };
    int matched_x = -1;
    int matched_y = -1;

    make_template(&cursor);
    fill_frame(255, 255, 255);
    composite_template(30, 20);
    sdl2_cursor_history_record(&history, 10, 10, 1000);
    sdl2_cursor_history_record(&history, 31, 21, 2000);
    sdl2_cursor_history_record(&history, 50, 40, 3000);
    g_assert_true(sdl2_cursor_history_match_xrgb8888(
        &cursor, &history, (uint8_t *)frame,
        FRAME_WIDTH, FRAME_HEIGHT, FRAME_WIDTH * 4,
        3500, 2000, 0, &matched_x, &matched_y));
    g_assert_cmpint(matched_x, ==, 31);
    g_assert_cmpint(matched_y, ==, 21);
    g_assert_false(sdl2_cursor_history_match_xrgb8888(
        &cursor, &history, (uint8_t *)frame,
        FRAME_WIDTH, FRAME_HEIGHT, FRAME_WIDTH * 4,
        5000, 1000, 0, NULL, NULL));
    sdl2_cursor_history_reset(&history);
    g_assert_false(sdl2_cursor_history_match_xrgb8888(
        &cursor, &history, (uint8_t *)frame,
        FRAME_WIDTH, FRAME_HEIGHT, FRAME_WIDTH * 4,
        5000, 5000, 0, NULL, NULL));
}

static void test_invalid_template(void)
{
    SDL2CursorTemplate cursor;

    memset(template_rgba, 0, sizeof(template_rgba));
    g_assert_false(sdl2_cursor_template_init_rgba(
        &cursor, template_rgba, TEMPLATE_WIDTH, TEMPLATE_HEIGHT,
        TEMPLATE_WIDTH * 4, 0, 0));
    g_assert_cmpuint(cursor.dark_count, ==, 0);
    g_assert_cmpuint(cursor.light_count, ==, 0);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/sdl2-cursor/backgrounds", test_match_backgrounds);
    g_test_add_func("/sdl2-cursor/plain-fail-safe",
                    test_fail_safe_plain_frames);
    g_test_add_func("/sdl2-cursor/search-corruption",
                    test_search_and_corruption);
    g_test_add_func("/sdl2-cursor/history", test_history);
    g_test_add_func("/sdl2-cursor/invalid-template",
                    test_invalid_template);
    return g_test_run();
}

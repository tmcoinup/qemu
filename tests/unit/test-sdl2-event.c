/* SDL event queue coalescing tests. */

#include "qemu/osdep.h"
#include "ui/sdl2-event.h"

static SDL_Event motion(uint32_t window, uint32_t which, uint32_t state,
                        int x, int y, int xrel, int yrel)
{
    SDL_Event event = { 0 };

    event.type = SDL_MOUSEMOTION;
    event.motion.windowID = window;
    event.motion.which = which;
    event.motion.state = state;
    event.motion.x = x;
    event.motion.y = y;
    event.motion.xrel = xrel;
    event.motion.yrel = yrel;

    return event;
}

static void push(SDL_Event *event)
{
    g_assert_cmpint(SDL_PushEvent(event), ==, 1);
}

static void test_motion_stops_before_keyup(void)
{
    SDL_Event first = motion(7, 3, SDL_BUTTON_LMASK, 10, 11, 3, -1);
    SDL_Event next = motion(7, 3, SDL_BUTTON_LMASK, 20, 21, 4, 2);
    SDL_Event last = motion(7, 3, SDL_BUTTON_LMASK, 30, 31, -1, 5);
    SDL_Event keyup = { .type = SDL_KEYUP };
    SDL_Event tail = motion(7, 3, SDL_BUTTON_LMASK, 40, 41, 9, 10);
    SDL_Event event;

    SDL_FlushEvents(SDL_FIRSTEVENT, SDL_LASTEVENT);
    push(&first);
    push(&next);
    push(&last);
    push(&keyup);
    push(&tail);

    g_assert_cmpint(SDL_PollEvent(&event), ==, 1);
    sdl2_coalesce_mouse_motion(&event);
    g_assert_cmpuint(event.type, ==, SDL_MOUSEMOTION);
    g_assert_cmpint(event.motion.xrel, ==, 6);
    g_assert_cmpint(event.motion.yrel, ==, 6);
    g_assert_cmpint(event.motion.x, ==, 30);
    g_assert_cmpint(event.motion.y, ==, 31);

    g_assert_cmpint(SDL_PollEvent(&event), ==, 1);
    g_assert_cmpuint(event.type, ==, SDL_KEYUP);
    g_assert_cmpint(SDL_PollEvent(&event), ==, 1);
    g_assert_cmpint(event.motion.xrel, ==, 9);
    g_assert_cmpint(SDL_PollEvent(&event), ==, 0);
}

static void test_motion_keeps_sources_separate(void)
{
    SDL_Event first = motion(1, 2, 0, 10, 11, 1, 2);
    SDL_Event other_device = motion(1, 3, 0, 20, 21, 3, 4);
    SDL_Event event;

    SDL_FlushEvents(SDL_FIRSTEVENT, SDL_LASTEVENT);
    push(&first);
    push(&other_device);
    g_assert_cmpint(SDL_PollEvent(&event), ==, 1);
    sdl2_coalesce_mouse_motion(&event);
    g_assert_cmpint(event.motion.xrel, ==, 1);
    g_assert_cmpint(SDL_PollEvent(&event), ==, 1);
    g_assert_cmpuint(event.motion.which, ==, 3);
}

static void test_motion_delta_saturates(void)
{
    SDL_Event first = motion(1, 2, 0, 0, 0, INT32_MAX, INT32_MIN);
    SDL_Event next = motion(1, 2, 0, 1, 1, 1, -1);
    SDL_Event event;

    SDL_FlushEvents(SDL_FIRSTEVENT, SDL_LASTEVENT);
    push(&first);
    push(&next);
    g_assert_cmpint(SDL_PollEvent(&event), ==, 1);
    sdl2_coalesce_mouse_motion(&event);
    g_assert_cmpint(event.motion.xrel, ==, INT32_MAX);
    g_assert_cmpint(event.motion.yrel, ==, INT32_MIN);
}

int main(int argc, char **argv)
{
    int result;

    g_test_init(&argc, &argv, NULL);
    g_assert_cmpint(SDL_Init(SDL_INIT_EVENTS), ==, 0);
    SDL_EventState(SDL_MOUSEMOTION, SDL_ENABLE);
    SDL_EventState(SDL_KEYUP, SDL_ENABLE);
    g_test_add_func("/sdl2-event/motion-keyup-order",
                    test_motion_stops_before_keyup);
    g_test_add_func("/sdl2-event/motion-source",
                    test_motion_keeps_sources_separate);
    g_test_add_func("/sdl2-event/motion-saturation",
                    test_motion_delta_saturates);
    result = g_test_run();

    SDL_Quit();
    return result;
}

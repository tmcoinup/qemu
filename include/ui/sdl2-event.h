#ifndef UI_SDL2_EVENT_H
#define UI_SDL2_EVENT_H

#include <SDL.h>

/* 合并队首连续且同来源的鼠标移动，不跨越其他事件。 */
void sdl2_coalesce_mouse_motion(SDL_Event *event);

#endif /* UI_SDL2_EVENT_H */

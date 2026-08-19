#ifndef UI_SDL2_EVENT_H
#define UI_SDL2_EVENT_H

#include <SDL.h>

/* 合并队首连续且同来源的鼠标移动，不跨越其他事件。 */
void sdl2_coalesce_mouse_motion(SDL_Event *event);

/*
 * SDL2 桌面端默认打开 TEXTINPUT；宿主 IME 因而可以吃掉
 * 本应送给 graphic guest 的 KEYDOWN/KEYUP。
 * VM 窗口只使用物理 scancode，
 * 初始化后必须显式关掉 SDL 文本输入。
 */
void sdl2_disable_host_text_input(void);

/*
 * 只有真正可见的窗口才能调整绘制面或 Present。
 * hidden 是 QEMU 的显式隐藏状态，
 * flags 是 SDL/窗口管理器的实时状态。
 */
bool sdl2_window_updates_allowed(Uint32 flags, bool hidden);

#endif /* UI_SDL2_EVENT_H */

/*
 * QEMU SDL display sizing policy
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef QEMU_UI_SDL2_DISPLAY_POLICY_H
#define QEMU_UI_SDL2_DISPLAY_POLICY_H

#include "ui/sdl2-pointer.h"

/*
 * Convert guest pixels to SDL logical-window units using the current
 * drawable/window DPI ratio.  An embedded native render child follows its
 * SDL parent 1:1, even while the window manager has resized the parent and
 * EGL still reports the child's previous size.  The resulting client-area
 * maximum never renders more pixels than the guest's current native mode.
 */
bool sdl2_window_max_size(SDL2Size window, SDL2Size render,
                          SDL2Size guest, bool embedded_render_child,
                          SDL2Size *maximum);

#endif /* QEMU_UI_SDL2_DISPLAY_POLICY_H */

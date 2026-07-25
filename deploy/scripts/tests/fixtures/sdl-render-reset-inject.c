/*
 * SDL renderer reset injector for the runtime regression test.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#define _GNU_SOURCE

#include <SDL.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int (*next_poll_event)(SDL_Event *event);
static int (*next_update_texture)(SDL_Texture *texture, const SDL_Rect *rect,
                                  const void *pixels, int pitch);
static SDL_Texture *(*next_create_texture)(SDL_Renderer *renderer,
                                           Uint32 format, int access,
                                           int width, int height);
static void (*next_render_present)(SDL_Renderer *renderer);

static unsigned int empty_poll_count;
static bool target_pending;
static bool target_uploaded;
static bool device_pending;
static bool device_created;
static bool device_uploaded;

static void resolve_symbol(void **target, const char *name)
{
    if (!*target) {
        *target = dlsym(RTLD_NEXT, name);
    }
}

static void append_marker(const char *marker)
{
    const char *path = getenv("VMATE_SDL_RESET_MARKER");
    int fd;

    if (!path || !*path) {
        return;
    }
    fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd < 0) {
        return;
    }
    (void)write(fd, marker, strlen(marker));
    (void)close(fd);
}

int SDL_PollEvent(SDL_Event *event)
{
    int result;

    resolve_symbol((void **)&next_poll_event, "SDL_PollEvent");
    if (!next_poll_event) {
        return 0;
    }

    result = next_poll_event(event);
    if (result || !event || !getenv("VMATE_SDL_RESET_MARKER")) {
        return result;
    }

    empty_poll_count++;
    if (empty_poll_count == 5) {
        memset(event, 0, sizeof(*event));
        event->type = SDL_RENDER_TARGETS_RESET;
        target_pending = true;
        append_marker("target-event\n");
        return 1;
    }
    if (empty_poll_count == 10) {
        memset(event, 0, sizeof(*event));
        event->type = SDL_RENDER_DEVICE_RESET;
        device_pending = true;
        append_marker("device-event\n");
        return 1;
    }
    return 0;
}

int SDL_UpdateTexture(SDL_Texture *texture, const SDL_Rect *rect,
                      const void *pixels, int pitch)
{
    int result;

    resolve_symbol((void **)&next_update_texture, "SDL_UpdateTexture");
    if (!next_update_texture) {
        return -1;
    }
    result = next_update_texture(texture, rect, pixels, pitch);
    if (result != 0) {
        return result;
    }

    if (target_pending && !target_uploaded) {
        target_uploaded = true;
        append_marker("target-upload\n");
    }
    if (device_pending && !device_uploaded) {
        device_uploaded = true;
        append_marker("device-upload\n");
    }
    return result;
}

SDL_Texture *SDL_CreateTexture(SDL_Renderer *renderer, Uint32 format,
                               int access, int width, int height)
{
    SDL_Texture *texture;

    resolve_symbol((void **)&next_create_texture, "SDL_CreateTexture");
    if (!next_create_texture) {
        return NULL;
    }
    texture = next_create_texture(renderer, format, access, width, height);
    if (texture && device_pending && !device_created) {
        device_created = true;
        append_marker("device-create\n");
    }
    return texture;
}

void SDL_RenderPresent(SDL_Renderer *renderer)
{
    resolve_symbol((void **)&next_render_present, "SDL_RenderPresent");
    if (!next_render_present) {
        return;
    }
    next_render_present(renderer);

    if (target_pending && target_uploaded) {
        target_pending = false;
        append_marker("target-present\n");
    }
    if (device_pending && device_created && device_uploaded) {
        device_pending = false;
        append_marker("device-present\n");
    }
}

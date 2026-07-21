#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 验证 context 与异步 fence 失效路径不会误操作其它 GL 状态。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SDL_GL="$REPO_ROOT/ui/sdl2-gl.c"
FB_SHM_GL="$REPO_ROOT/ui/fb-shm-gl-context.c"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

test_sdl_gl_callbacks_bind_window_context() {
    local direct_bindings

    # SDL texture/FBO 操作统一经过 context 成功门禁。
    direct_bindings="$(grep -c \
        'SDL_GL_MakeCurrent(scon->real_window, scon->winctx)' "$SDL_GL")"
    [[ "$direct_bindings" -eq 1 ]] \
        || fail "SDL window context binding must be centralized"

    awk '
        /^void sdl2_gl_scanout_disable/ { in_func = 1 }
        in_func && /sdl2_gl_make_window_current/ { saw_bind = 1 }
        in_func && /sdl2_set_scanout_mode/ {
            exit saw_bind ? 0 : 1
        }
        in_func && /^}/ { exit 1 }
    ' "$SDL_GL" \
        || fail "scanout disable must bind SDL context before FBO cleanup"

    awk '
        /^void sdl2_gl_release_dmabuf/ { in_func = 1 }
        in_func && /sdl2_gl_make_window_current/ { saw_bind = 1 }
        in_func && /egl_dmabuf_release_texture/ {
            exit saw_bind ? 0 : 1
        }
        in_func && /^}/ { exit 1 }
    ' "$SDL_GL" \
        || fail "dma-buf release must bind SDL context before texture cleanup"
}

test_null_pbo_fence_drops_without_waiting() {
    # glFenceSync 可以返回 NULL。该帧必须在 pending 前丢弃，
    # 不能等待空句柄，也不能退化成阻塞主循环的同步 readback。
    awk '
        /^int fb_shm_gl_pbo_issue/ { in_func = 1 }
        in_func && /pbo->fence = glFenceSync/ { stage = 1 }
        in_func && stage == 1 && /if \(!pbo->fence\)/ { stage = 2 }
        in_func && stage == 2 && /fb_shm_gl_pbo_forget/ { stage = 3 }
        in_func && stage == 3 && /return 0;/ { stage = 4 }
        in_func && /pbo->pending = true/ { exit stage == 4 ? 0 : 1 }
        in_func && /^}/ { exit 1 }
    ' "$FB_SHM_GL" \
        || fail "NULL PBO fence must be dropped before pending"
}

test_sdl_gl_callbacks_bind_window_context
test_null_pbo_fence_drops_without_waiting

echo "OK: GL context and fence lifecycle static checks passed"

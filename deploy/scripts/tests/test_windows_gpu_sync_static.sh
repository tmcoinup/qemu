#!/usr/bin/env bash
# 静态回归 Windows D3D11 keyed-mutex GPU 帧协议的安全边界。
#
# 该测试不需要 Windows 运行环境：它检查 ABI、HELLO 能力协商、异步 BH
# 交接、DONE 状态机和 SDL 延迟重绘的关键结构与调用顺序。这样 Linux CI 也能
# 在代码评审前发现“窗口仍在读 consumer 持有的纹理”一类跨进程竞态。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

FB_SHM="$REPO_ROOT/ui/fb-shm.c"
FB_SHM_CONTROL="$REPO_ROOT/ui/fb-shm-control.c"
FB_SHM_REQUEST="$REPO_ROOT/ui/fb-shm-control-request.c"
FB_SHM_DISPLAY="$REPO_ROOT/ui/fb-shm-display.c"
FB_SHM_GL_EXPORT="$REPO_ROOT/ui/fb-shm-gl-export.c"
FB_SHM_GL_FRAME="$REPO_ROOT/ui/fb-shm-gl-frame.c"
FB_SHM_QOM="$REPO_ROOT/ui/fb-shm-qom.c"
FB_SHM_INTERNAL="$REPO_ROOT/ui/fb-shm-internal.h"
GPU_BACKEND="$REPO_ROOT/ui/fb-shm-gpu.c"
GPU_HEADER="$REPO_ROOT/include/ui/fb-shm-gpu.h"
ABI_HEADER="$REPO_ROOT/include/ui/fb-shm-abi.h"
SDL_GL="$REPO_ROOT/ui/sdl2-gl.c"
SDL_HEADER="$REPO_ROOT/include/ui/sdl2.h"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle="$1"
    local file="$2"

    grep -F -- "$needle" "$file" >/dev/null \
        || fail "missing '$needle' in $file"
}

reject_text() {
    local needle="$1"
    local file="$2"

    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "unexpected '$needle' in $file"
    fi
}

reject_regex() {
    local pattern="$1"
    local file="$2"

    if grep -E -- "$pattern" "$file" >/dev/null; then
        fail "unexpected pattern '$pattern' in $file"
    fi
}

require_count() {
    local needle="$1"
    local expected="$2"
    local file="$3"
    local actual

    actual="$(grep -cF -- "$needle" "$file" || true)"
    [[ "$actual" -eq "$expected" ]] \
        || fail "expected $expected occurrences of '$needle' in $file, got $actual"
}

extract_function() {
    local file="$1"
    local function_name="$2"

    # 中文注释：QEMU 顶层函数的右花括号位于行首。先排除带分号的调用/声明，
    # 再读到首个顶层右花括号，可处理签名跨行而不误截断内部 if/else 块。
    awk -v fn="$function_name" '
        !inside && index($0, fn "(") && $0 !~ /;/ {
            inside = 1
        }
        inside {
            print
            if (opened && $0 ~ /^}/) {
                exit
            }
            if (index($0, "{")) {
                opened = 1
            }
        }
    ' "$file"
}

require_function_text() {
    local file="$1"
    local function_name="$2"
    local needle="$3"
    local body

    body="$(extract_function "$file" "$function_name")"
    [[ -n "$body" ]] || fail "function '$function_name' not found in $file"
    grep -F -- "$needle" <<<"$body" >/dev/null \
        || fail "missing '$needle' in function $function_name"
}

reject_function_text() {
    local file="$1"
    local function_name="$2"
    local needle="$3"
    local body

    body="$(extract_function "$file" "$function_name")"
    [[ -n "$body" ]] || fail "function '$function_name' not found in $file"
    if grep -F -- "$needle" <<<"$body" >/dev/null; then
        fail "unexpected '$needle' in function $function_name"
    fi
}

require_function_order() {
    local file="$1"
    local function_name="$2"
    shift 2
    local body
    local needle
    local relative_line
    local absolute_line
    local last_line=0

    body="$(extract_function "$file" "$function_name")"
    [[ -n "$body" ]] || fail "function '$function_name' not found in $file"

    # 中文注释：每次只在上一个命中点之后查找，既允许相同状态码在多个分支中
    # 出现，也能真正约束调用先后，而不是只验证若干字符串恰好存在。
    for needle in "$@"; do
        relative_line="$(tail -n "+$((last_line + 1))" <<<"$body" |
            grep -nF -m1 -- "$needle" | cut -d: -f1 || true)"
        [[ "$relative_line" =~ ^[0-9]+$ ]] \
            || fail "'$needle' is missing after line $last_line in $function_name"
        absolute_line=$((last_line + relative_line))
        last_line="$absolute_line"
    done
}

test_abi_declares_keyed_mutex_round_trip() {
    # GPU_SYNC 是显式 opt-in；DONE 用原请求结构的 w/h 无损回传 64 位序列号。
    require_text "#define FB_SHM_CTL_GPU_FRAME_DONE   7u" "$ABI_HEADER"
    require_text "#define FB_SHM_HELLO_F_GPU_SYNC      (1u << 4)" "$ABI_HEADER"
    require_text "#define FB_SHM_GPU_FRAME_F_KEYED_MUTEX  (1u << 1)" "$ABI_HEADER"
    require_text "GPU_FRAME_DONE 用 w/h 携带 frame_seq 的低/高 32 位" "$ABI_HEADER"
    require_text "FB_SHM_GPU_FRAME_F_KEYED_MUTEX, backend->d3d_stride" \
        "$GPU_BACKEND"
}

test_hello_rejects_unsafe_or_competing_clients() {
    # GPU_SYNC/GPU_REQUIRED 没有 GPU_FRAMES 属于非法组合；Windows strict GPU
    # 客户端若不实现 DONE 同步则必须拒绝，不能悄悄交付无保护的 D3D handle。
    require_function_order "$FB_SHM_REQUEST" "fb_shm_handle_hello" \
        "(wants_gpu_sync || gpu_required) && !wants_gpu" \
        "status = FB_SHM_CTL_EINVAL"
    require_function_order "$FB_SHM_REQUEST" "fb_shm_handle_hello" \
        "gpu_only && !wants_gpu_sync" \
        "status = FB_SHM_CTL_EUNSUPPORTED"
    require_function_text "$FB_SHM_CONTROL" "fb_shm_client_accepts_gpu" \
        "accepts = accepts && c->wants_gpu_sync"

    # keyed mutex 属于 QemuConsole 的 scanout，不属于单个 sidecar。全局表以
    # d->con 为键，保证同一 console 即使热添加多个 fb-shm 也只有一个 owner。
    require_text "static GHashTable *fb_shm_d3d_console_owners" "$FB_SHM_GL_EXPORT"
    require_text "g_hash_table_lookup(fb_shm_d3d_console_owners, d->con)" "$FB_SHM_GL_EXPORT"
    require_text "g_hash_table_insert(fb_shm_d3d_console_owners, d->con, d)" "$FB_SHM_GL_EXPORT"
    require_function_text "$FB_SHM_REQUEST" "fb_shm_handle_hello" \
        "!fb_shm_d3d_console_available(d)"
    require_function_order "$FB_SHM_REQUEST" "fb_shm_handle_hello" \
        "fb_shm_d3d_console_reserve(d)" \
        "c->hello_done = true" \
        "d->d3d_sync_client = c"
}

test_handoff_uses_persistent_bh_after_dcl_work() {
    # 持久 BH 的 opaque 指向 display；它由 display 创建/销毁，不能使用 oneshot
    # 携带可能在断连时释放的临时 client 指针。
    require_text "QEMUBH *d3d_handoff_bh" "$FB_SHM_INTERNAL"
    require_text "qemu_bh_new(fb_shm_d3d_handoff_bh, d)" "$FB_SHM"
    require_text "qemu_bh_schedule(d->d3d_handoff_bh)" "$FB_SHM_GL_EXPORT"
    require_text "qemu_bh_cancel(d->d3d_handoff_bh)" "$FB_SHM_GL_EXPORT"
    require_count "qemu_bh_delete(d->d3d_handoff_bh)" 2 "$FB_SHM"
    reject_text "aio_bh_schedule_oneshot(qemu_get_aio_context(), fb_shm_d3d_handoff_bh" \
        "$FB_SHM_GL_EXPORT"

    # DCL 回调只提交 metadata 并 schedule；真正 ReleaseSync 只能在 BH 中出现。
    require_text ".dpy_gl_update          = fb_shm_gl_update" "$FB_SHM_DISPLAY"
    require_function_text "$FB_SHM_GL_FRAME" "fb_shm_gl_update" \
        "fb_shm_commit_gl_frame(d)"
    require_function_order "$FB_SHM_GL_EXPORT" \
        "fb_shm_broadcast_texture_dmabuf_frame" \
        "d->d3d_handoff_layout = layout" \
        "d->d3d_handoff_scheduled = true" \
        "qemu_bh_schedule(d->d3d_handoff_bh)"
    require_count "fb_shm_gpu_backend_d3d_release0(d->gl_gpu_backend)" 1 \
        "$FB_SHM_GL_EXPORT"
    require_function_text "$FB_SHM_GL_EXPORT" "fb_shm_d3d_handoff_bh" \
        "fb_shm_gpu_backend_d3d_release0(d->gl_gpu_backend)"

    # Windows 的 schedule 点必须位于本轮 PBO/SHM 工作之后；BH 会在当前 DCL
    # listener 遍历返回后运行，使 SDL 窗口先完成对同一纹理的本帧读取。
    require_function_order "$FB_SHM_GL_FRAME" "fb_shm_commit_gl_frame" \
        "fb_shm_gl_pbo_issue" \
        "fb_shm_broadcast_direct_gpu_frame(d, rw, rh, rx, ry)"
}

test_release_pending_and_send_order_is_atomic() {
    # 先 block renderer，再 Flush immediate context 并 ReleaseSync；只有成功交出
    # key=0 后才登记 pending，登记完成后才允许把 frame_seq 发给 consumer。
    require_function_order "$FB_SHM_GL_EXPORT" "fb_shm_d3d_handoff_bh" \
        "fb_shm_d3d_set_gl_blocked(d, true)" \
        "fb_shm_gpu_backend_d3d_release0(d->gl_gpu_backend)" \
        "fb_shm_gpu_pending_begin(&d->d3d_pending" \
        "fb_shm_send_gpu_frame(c, &exported.frame, exported.fd)"
    require_function_order "$GPU_BACKEND" "fb_shm_gpu_backend_d3d_release0" \
        "context->lpVtbl->Flush(context)" \
        "ReleaseSync(backend->d3d_mutex, 0)" \
        "backend->d3d_key0_owned = false"
}

test_done_requires_exact_sequence_and_nonblocking_acquire() {
    # DONE 只能由唯一 owner 完成当前精确 sequence；错误/过期 ACK 不得误完成
    # 新帧。AcquireSync(0, 0) 尚未成功时回复 EBUSY，让同一序列稍后重试。
    require_function_text "$FB_SHM_REQUEST" "fb_shm_handle_gpu_frame_done" \
        "uint64_t sequence = ((uint64_t)req->h << 32) | req->w"
    require_function_order "$FB_SHM_REQUEST" "fb_shm_handle_gpu_frame_done" \
        "sequence != pending_sequence" \
        "status = FB_SHM_CTL_EINVAL" \
        "fb_shm_gpu_backend_d3d_acquire0(d->gl_gpu_backend)" \
        "status = FB_SHM_CTL_EBUSY" \
        "fb_shm_gpu_pending_complete(&d->d3d_pending, sequence)" \
        "fb_shm_d3d_set_gl_blocked(d, false)" \
        "status = FB_SHM_CTL_OK"
    require_text "case FB_SHM_CTL_GPU_FRAME_DONE:" "$FB_SHM_REQUEST"
    require_text "AcquireSync(backend->d3d_mutex, 0, 0)" "$GPU_BACKEND"
    reject_text "AcquireSync(backend->d3d_mutex, 0, INFINITE)" "$GPU_BACKEND"
}

test_pending_frame_stops_all_texture_access() {
    # consumer 持有 keyed mutex 时，下一次 commit 必须在进入 GL context/PBO
    # 之前退出；否则 SHM fallback 自身也可能读取正在跨进程使用的 texture。
    require_function_order "$FB_SHM_GL_FRAME" "fb_shm_commit_gl_frame" \
        "fb_shm_gpu_pending_active(&d->d3d_pending, NULL)" \
        "return;" \
        "fb_shm_gl_context_enter(d, &guard)"
    require_function_text "$FB_SHM_GL_FRAME" "fb_shm_commit_gl_frame" \
        "d->d3d_handoff_scheduled"
}

test_disconnect_reclaims_with_timer_without_unsafe_unblock() {
    # WAIT_TIMEOUT 只表示 consumer 还没 ReleaseSync；后端必须保留 D3D backing，
    # display 必须保留 pending + renderer block，并由短定时器非阻塞重试。
    require_function_order "$GPU_BACKEND" "fb_shm_gpu_backend_d3d_acquire0" \
        "AcquireSync(backend->d3d_mutex, 0, 0)" \
        "if (hr != WAIT_TIMEOUT)" \
        "fb_shm_gpu_backend_reset(backend)"
    require_function_order "$FB_SHM_GL_EXPORT" "fb_shm_d3d_cancel_pending" \
        "fb_shm_gpu_backend_d3d_acquire0(d->gl_gpu_backend)" \
        "timer_mod(d->d3d_reclaim_timer" \
        "return false;" \
        "fb_shm_gpu_backend_reset(d->gl_gpu_backend)" \
        "fb_shm_gpu_pending_cancel(&d->d3d_pending, sequence)" \
        "fb_shm_d3d_set_gl_blocked(d, false)"
    require_function_order "$FB_SHM_CONTROL" "fb_shm_client_drop" \
        "c->owner->d3d_sync_client = NULL" \
        "fb_shm_d3d_cancel_pending(c->owner)"
    reject_function_text "$FB_SHM_CONTROL" "fb_shm_client_drop" \
        "fb_shm_gpu_backend_reset"
    reject_function_text "$FB_SHM_CONTROL" "fb_shm_client_drop" \
        "fb_shm_d3d_set_gl_blocked"
    require_function_text "$FB_SHM_GL_EXPORT" "fb_shm_d3d_reclaim_timer_cb" \
        "fb_shm_d3d_cancel_pending(d)"
    require_text "timer_new_ms(QEMU_CLOCK_REALTIME" "$FB_SHM"
    require_text "timer_free(d->d3d_reclaim_timer)" "$FB_SHM"
}

test_sdl_defers_redraw_but_keeps_polling() {
    # block 期间 EXPOSE/focus/resize 只置 deferred 标志；refresh 仍轮询 SDL 事件，
    # mutex 归还后再补一次 redraw，既保留窗口响应性也不触碰外部持有的纹理。
    require_text "bool scanout_redraw_pending" "$SDL_HEADER"
    require_function_order "$SDL_GL" "sdl2_gl_redraw" \
        "qemu_console_is_gl_blocked(scon->dcl.con)" \
        "scon->scanout_redraw_pending = true" \
        "return;"
    require_function_order "$SDL_GL" "sdl2_gl_refresh" \
        "scon->scanout_redraw_pending &&" \
        "!qemu_console_is_gl_blocked(dcl->con)" \
        "scon->scanout_redraw_pending = false" \
        "sdl2_gl_redraw(scon)" \
        "sdl2_poll_events(scon)"
}

test_object_delete_waits_for_safe_reclaim() {
    # object-del 不能在 BH、timer、pending 或 renderer block 仍活跃时释放 display。
    require_function_order "$FB_SHM_QOM" "fb_shm_export_can_be_deleted" \
        "o->display->d3d_handoff_scheduled" \
        "o->display->d3d_retiring || o->display->d3d_gl_blocked" \
        "fb_shm_gpu_pending_active(&o->display->d3d_pending, NULL)" \
        "return false;" \
        "return true;"
    require_text "ucc->can_be_deleted = fb_shm_export_can_be_deleted" "$FB_SHM_QOM"
}

test_win32_event_helper_is_shared_internally() {
    require_text "bool fb_shm_win32_ensure_client_event(" "$FB_SHM_INTERNAL"
    require_text "bool fb_shm_win32_ensure_client_event(" "$FB_SHM_CONTROL"
    reject_text "static bool fb_shm_win32_ensure_client_event(" "$FB_SHM_CONTROL"
    require_text "fb_shm_win32_ensure_client_event(d, c, &err)" "$FB_SHM_REQUEST"
}

test_sources_do_not_use_unwrap() {
    local file
    local unwrap_pattern='(^|[^[:alnum:]_])unwrap[[:space:]]*\('

    # 当前实现全部是 C，但仍钉住项目约束：后续若替换平台胶水，不得引入会在
    # 错误路径直接终止进程的 unwrap() 风格调用。
    for file in "$REPO_ROOT"/ui/fb-shm*.c "$FB_SHM_INTERNAL" "$GPU_HEADER" \
        "$ABI_HEADER" "$SDL_GL"; do
        reject_regex "$unwrap_pattern" "$file"
    done
}

test_script_stays_small() {
    local lines

    lines="$(wc -l < "$SCRIPT_DIR/test_windows_gpu_sync_static.sh")"
    [[ "$lines" -le 500 ]] || fail "GPU sync static test exceeds 500 lines: $lines"
}

test_abi_declares_keyed_mutex_round_trip
test_hello_rejects_unsafe_or_competing_clients
test_handoff_uses_persistent_bh_after_dcl_work
test_release_pending_and_send_order_is_atomic
test_done_requires_exact_sequence_and_nonblocking_acquire
test_pending_frame_stops_all_texture_access
test_disconnect_reclaims_with_timer_without_unsafe_unblock
test_sdl_defers_redraw_but_keeps_polling
test_object_delete_waits_for_safe_reclaim
test_win32_event_helper_is_shared_internally
test_sources_do_not_use_unwrap
test_script_stays_small

echo "OK: Windows D3D11 keyed-mutex GPU sync static checks passed"

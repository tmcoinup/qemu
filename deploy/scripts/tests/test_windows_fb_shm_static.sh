#!/usr/bin/env bash
# 静态验证 Windows fb-shm 方案的关键开关，避免后续改动把 Windows 路径拆断。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

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

reject_text_ci() {
    local needle="$1"
    local file="$2"

    if grep -iF -- "$needle" "$file" >/dev/null; then
        fail "unexpected '$needle' in $file"
    fi
}

test_abi_has_win32_names() {
    require_text "FB_SHM_HELLO_F_WIN32_NAMES" "$REPO_ROOT/include/ui/fb-shm-abi.h"
    require_text "FB_SHM_HELLO_F_GPU_FRAMES" "$REPO_ROOT/include/ui/fb-shm-abi.h"
    require_text "FB_SHM_HELLO_F_GPU_REQUIRED" "$REPO_ROOT/include/ui/fb-shm-abi.h"
    require_text "FB_SHM_CTL_NOTIFY_GPU_FRAME" "$REPO_ROOT/include/ui/fb-shm-abi.h"
    require_text "FbShmWin32Names" "$REPO_ROOT/include/ui/fb-shm-abi.h"
    require_text "FbShmGpuFrame" "$REPO_ROOT/include/ui/fb-shm-abi.h"
    require_text "FB_SHM_WIN32_NAME_MAX" "$REPO_ROOT/include/ui/fb-shm-abi.h"
}

test_qapi_and_meson_enable_windows() {
    require_text "CONFIG_WIN32" "$REPO_ROOT/qapi/ui.json"
    require_text "CONFIG_WIN32" "$REPO_ROOT/qapi/qom.json"
    require_text "host_os in ['linux', 'windows']" "$REPO_ROOT/ui/meson.build"
    require_text "tools/fb-shm-stream/main.c" "$REPO_ROOT/meson.build"
    require_text "tools/fb-shm-stream/platform.c" "$REPO_ROOT/meson.build"
    require_text "tools/fb-shm-stream/ffmpeg.c" "$REPO_ROOT/meson.build"
}

test_qemu_backend_has_win32_mapping() {
    require_text "CreateFileMappingA" "$REPO_ROOT/ui/fb-shm.c"
    require_text "MapViewOfFile" "$REPO_ROOT/ui/fb-shm.c"
    require_text "SetEvent" "$REPO_ROOT/ui/fb-shm.c"
    require_text "CreateSharedHandle" "$REPO_ROOT/ui/fb-shm.c"
    require_text "dpy_gl_scanout_dmabuf" "$REPO_ROOT/ui/fb-shm.c"
    require_text "FB_SHM_CTL_NOTIFY_GPU_FRAME" "$REPO_ROOT/ui/fb-shm.c"
    require_text "SCM_RIGHTS" "$REPO_ROOT/ui/fb-shm.c"
}

test_backend_drops_idle_listener_rate() {
    # 中文注释：没有消费者时 fb-shm 只需要低频保活。第一次 mapping 建好后
    # 若不重算 DCL rate，GL/SDL 主显示路径会继续被 60Hz graphic_hw_update()
    # 旁路拖慢，游戏帧率会从 58/59 掉到 30 多。
    awk '
        /static int fb_shm_ensure_geometry/ { in_func = 1 }
        in_func && /fb_shm_broadcast_resize\(d\)/ { saw_resize = 1 }
        in_func && saw_resize && /fb_shm_update_effective_rate\(d\)/ { saw_rate = 1 }
        in_func && /^}/ { exit saw_rate ? 0 : 1 }
    ' "$REPO_ROOT/ui/fb-shm.c" \
        || fail "fb_shm_ensure_geometry must recompute idle listener rate after mapping"
}

test_gl_readback_drains_pbo_before_rate_gate() {
    # 中文注释：普通 SHM consumer 依赖 PBO 异步读回。必须先 drain 已完成的
    # PBO，再按目标 FPS 判断是否发起下一次采样；如果先按 rate return，
    # 完成帧只会在 60Hz tick 上被处理，容易把 SDL/virgl 热路径拖回 100fps。
    awk '
        /static void fb_shm_commit_gl_frame/ { in_func = 1 }
        in_func && /fb_shm_gl_pbo_drain\(d\)/ { saw_drain = 1 }
        in_func && /fb_shm_rate_due\(d->shm_target_fps/ {
            exit saw_drain ? 0 : 1
        }
        in_func && /^}/ { exit 1 }
    ' "$REPO_ROOT/ui/fb-shm.c" \
        || fail "fb_shm_commit_gl_frame must drain GL PBO before SHM rate gate"
}

test_texture_export_warning_is_strict_only() {
    # 中文注释：texture-only scanout 在稳定路径下回落 SHM 是预期行为，不能用
    # warning 误导操作者去打开 blob/native EGL；只有 strict GPU consumer 才警告。
    awk '
        /static void fb_shm_broadcast_texture_dmabuf_frame/ { in_func = 1 }
        in_func && /fb_shm_has_required_gpu_clients\(d\)/ { strict_gate = 1 }
        in_func && strict_gate && /warn_report/ { strict_warn = 1 }
        in_func && /else if \(!d->gl_logged_texture_export\)/ { fallback_branch = 1 }
        in_func && fallback_branch && /info_report/ { fallback_info = 1 }
        in_func && /^}/ {
            exit strict_gate && strict_warn && fallback_info ? 0 : 1
        }
    ' "$REPO_ROOT/ui/fb-shm.c" \
        || fail "texture dma-buf export fallback must warn only for strict GPU clients"
}

test_native_streamer_has_both_platforms() {
    require_text "OpenFileMappingA" "$REPO_ROOT/tools/fb-shm-stream/platform.c"
    require_text "OpenEventA" "$REPO_ROOT/tools/fb-shm-stream/platform.c"
    require_text "recvmsg" "$REPO_ROOT/tools/fb-shm-stream/platform.c"
    require_text "SCM_RIGHTS" "$REPO_ROOT/tools/fb-shm-stream/platform.c"
    require_text "STREAM_MODE_GPU" "$REPO_ROOT/tools/fb-shm-stream/common.h"
    require_text "--mode auto|gpu|shm" "$REPO_ROOT/tools/fb-shm-stream/main.c"
    require_text "FB_SHM_CTL_NOTIFY_GPU_FRAME" "$REPO_ROOT/tools/fb-shm-stream/platform.c"
    require_text "qemu-fb-shm-stream" "$REPO_ROOT/meson.build"
}

test_windows_scripts_are_native() {
    require_text "-object" "$REPO_ROOT/deploy/windows/start-vm.ps1"
    require_text "fb-shm" "$REPO_ROOT/deploy/windows/start-vm.ps1"
    require_text "-accel', 'whpx" "$REPO_ROOT/deploy/windows/start-vm.ps1"
    require_text "qemu-fb-shm-stream.exe" "$REPO_ROOT/deploy/windows/stream-fb-shm.ps1"
    require_text "[ValidateSet('auto', 'gpu', 'shm')]" "$REPO_ROOT/deploy/windows/stream-fb-shm.ps1"
    require_text "BeginConnect" "$REPO_ROOT/deploy/windows/stop-vm.ps1"
    reject_text_ci "python.exe" "$REPO_ROOT/deploy/windows/start-vm.ps1"
    reject_text_ci "python3" "$REPO_ROOT/deploy/windows/start-vm.ps1"
    reject_text_ci "py.exe" "$REPO_ROOT/deploy/windows/start-vm.ps1"
    reject_text_ci "python.exe" "$REPO_ROOT/deploy/windows/stream-fb-shm.ps1"
    reject_text_ci "python3" "$REPO_ROOT/deploy/windows/stream-fb-shm.ps1"
    reject_text_ci "py.exe" "$REPO_ROOT/deploy/windows/stream-fb-shm.ps1"
    reject_text_ci "python.exe" "$REPO_ROOT/deploy/windows/stop-vm.ps1"
    reject_text_ci "python3" "$REPO_ROOT/deploy/windows/stop-vm.ps1"
    reject_text_ci "py.exe" "$REPO_ROOT/deploy/windows/stop-vm.ps1"
}

test_docs_cover_windows_packaging() {
    require_text "Windows 10 / Windows 11" "$REPO_ROOT/deploy/docs/WINDOWS-PACKAGING.md"
    require_text "qemu-fb-shm-stream.exe" "$REPO_ROOT/deploy/docs/WINDOWS-PACKAGING.md"
    require_text "NOTIFY_GPU_FRAME" "$REPO_ROOT/deploy/docs/WINDOWS-PACKAGING.md"
    require_text "ninja installer" "$REPO_ROOT/deploy/docs/WINDOWS-PACKAGING.md"
    require_text "WINDOWS-PACKAGING.md" "$REPO_ROOT/deploy/docs/README.md"
    require_text "FB-SHM-GPU-ZEROCOPY.md" "$REPO_ROOT/deploy/docs/README.md"
    require_text "NOTIFY_GPU_FRAME" "$REPO_ROOT/deploy/docs/FB-SHM-GPU-ZEROCOPY.md"
    require_text "Linux/Windows" "$REPO_ROOT/docs/system/fb-shm.rst"
}

test_new_files_stay_small() {
    local file
    for file in \
        "$REPO_ROOT/tools/fb-shm-stream/common.h" \
        "$REPO_ROOT/tools/fb-shm-stream/platform.c" \
        "$REPO_ROOT/tools/fb-shm-stream/ffmpeg.c" \
        "$REPO_ROOT/tools/fb-shm-stream/main.c" \
        "$REPO_ROOT/deploy/windows/start-vm.ps1" \
        "$REPO_ROOT/deploy/windows/stream-fb-shm.ps1" \
        "$REPO_ROOT/deploy/windows/stop-vm.ps1" \
        "$REPO_ROOT/deploy/docs/FB-SHM-GPU-ZEROCOPY.md" \
        "$REPO_ROOT/deploy/docs/WINDOWS-PACKAGING.md"; do
        local lines

        lines="$(wc -l < "$file")"
        [[ "$lines" -le 500 ]] || fail "$file exceeds 500 lines: $lines"
    done
}

test_optional_mingw_streamer_syntax() {
    local cc

    cc="$(command -v x86_64-w64-mingw32-gcc || true)"
    if [[ -z "$cc" ]]; then
        echo "SKIP: x86_64-w64-mingw32-gcc not found"
        return
    fi

    "$cc" -I"$REPO_ROOT/include" -I"$REPO_ROOT/tools/fb-shm-stream" \
        -D_WIN32 -Wall -Wextra -Werror -fsyntax-only \
        "$REPO_ROOT/tools/fb-shm-stream/main.c"
    "$cc" -I"$REPO_ROOT/include" -I"$REPO_ROOT/tools/fb-shm-stream" \
        -D_WIN32 -Wall -Wextra -Werror -fsyntax-only \
        "$REPO_ROOT/tools/fb-shm-stream/platform.c"
    "$cc" -I"$REPO_ROOT/include" -I"$REPO_ROOT/tools/fb-shm-stream" \
        -D_WIN32 -Wall -Wextra -Werror -fsyntax-only \
        "$REPO_ROOT/tools/fb-shm-stream/ffmpeg.c"
}

test_abi_has_win32_names
test_qapi_and_meson_enable_windows
test_qemu_backend_has_win32_mapping
test_backend_drops_idle_listener_rate
test_gl_readback_drains_pbo_before_rate_gate
test_texture_export_warning_is_strict_only
test_native_streamer_has_both_platforms
test_windows_scripts_are_native
test_docs_cover_windows_packaging
test_new_files_stay_small
test_optional_mingw_streamer_syntax

echo "OK: windows fb-shm static checks passed"

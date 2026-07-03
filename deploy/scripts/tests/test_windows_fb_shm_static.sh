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
    require_text "FbShmWin32Names" "$REPO_ROOT/include/ui/fb-shm-abi.h"
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
    require_text "SCM_RIGHTS" "$REPO_ROOT/ui/fb-shm.c"
}

test_native_streamer_has_both_platforms() {
    require_text "OpenFileMappingA" "$REPO_ROOT/tools/fb-shm-stream/platform.c"
    require_text "OpenEventA" "$REPO_ROOT/tools/fb-shm-stream/platform.c"
    require_text "recvmsg" "$REPO_ROOT/tools/fb-shm-stream/platform.c"
    require_text "SCM_RIGHTS" "$REPO_ROOT/tools/fb-shm-stream/platform.c"
    require_text "qemu-fb-shm-stream" "$REPO_ROOT/meson.build"
}

test_windows_scripts_are_native() {
    require_text "-object" "$REPO_ROOT/deploy/windows/start-vm.ps1"
    require_text "fb-shm" "$REPO_ROOT/deploy/windows/start-vm.ps1"
    require_text "-accel', 'whpx" "$REPO_ROOT/deploy/windows/start-vm.ps1"
    require_text "qemu-fb-shm-stream.exe" "$REPO_ROOT/deploy/windows/stream-fb-shm.ps1"
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
    require_text "ninja installer" "$REPO_ROOT/deploy/docs/WINDOWS-PACKAGING.md"
    require_text "WINDOWS-PACKAGING.md" "$REPO_ROOT/deploy/docs/README.md"
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
test_native_streamer_has_both_platforms
test_windows_scripts_are_native
test_docs_cover_windows_packaging
test_new_files_stay_small
test_optional_mingw_streamer_syntax

echo "OK: windows fb-shm static checks passed"

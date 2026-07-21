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

reject_text() {
    local needle="$1"
    local file="$2"

    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "unexpected '$needle' in $file"
    fi
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
    local gpu_backend="$REPO_ROOT/ui/fb-shm-gpu.c"

    require_text "CreateFileMappingA" "$REPO_ROOT/ui/fb-shm-mapping.c"
    require_text "MapViewOfFile" "$REPO_ROOT/ui/fb-shm-mapping.c"
    require_text "SetEvent" "$REPO_ROOT/ui/fb-shm-display.c"
    require_text "CreateSharedHandle" "$gpu_backend"
    require_text "DXGI_SHARED_RESOURCE_READ" "$gpu_backend"
    require_text "DXGI_SHARED_RESOURCE_WRITE" "$gpu_backend"
    require_text "D3D11_RESOURCE_MISC_SHARED_NTHANDLE" "$gpu_backend"
    require_text "D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX" "$gpu_backend"
    require_text "IID_IDXGIKeyedMutex" "$gpu_backend"
    require_text "GetDevice(backend->d3d_texture, &device)" "$gpu_backend"
    require_text "GetImmediateContext(device, &context)" "$gpu_backend"
    require_text "context->lpVtbl->Flush(context)" "$gpu_backend"
    require_text "context->lpVtbl->Release(context)" "$gpu_backend"
    require_text "device->lpVtbl->Release(device)" "$gpu_backend"
    require_text "ReleaseSync(backend->d3d_mutex, 0)" "$gpu_backend"
    require_text "AcquireSync(backend->d3d_mutex, 0, 0)" "$gpu_backend"
    reject_text "AcquireSync(backend->d3d_mutex, 0, INFINITE)" "$gpu_backend"
    require_text "GetCurrentProcessId" "$gpu_backend"
    require_text "FB_SHM_GPU_FRAME_F_KEYED_MUTEX" "$gpu_backend"
    require_text "fb_shm_gpu_backend_has_d3d_texture" \
        "$REPO_ROOT/include/ui/fb-shm-gpu.h"
    require_text "lpVtbl->AddRef" "$gpu_backend"
    require_text "lpVtbl->Release" "$gpu_backend"
    require_text "dpy_gl_scanout_dmabuf" "$REPO_ROOT/ui/fb-shm-display.c"
    require_text "FB_SHM_CTL_NOTIFY_GPU_FRAME" "$REPO_ROOT/ui/fb-shm-control.c"
    require_text "SCM_RIGHTS" "$REPO_ROOT/ui/fb-shm-control.c"
    require_text "fb-shm-gpu.c" "$REPO_ROOT/ui/meson.build"
    require_text "fb-shm-gpu-common.c" "$REPO_ROOT/ui/meson.build"
}

test_backend_drops_idle_listener_rate() {
    # 中文注释：没有消费者时 fb-shm 只需要低频保活。第一次 mapping 建好后
    # 若不重算 DCL rate，GL/SDL 主显示路径会继续被 60Hz graphic_hw_update()
    # 旁路拖慢，游戏帧率会从 58/59 掉到 30 多。
    awk '
        /^int fb_shm_ensure_geometry/ { in_func = 1 }
        in_func && /fb_shm_broadcast_resize\(d\)/ { saw_resize = 1 }
        in_func && saw_resize && /fb_shm_update_effective_rate\(d\)/ { saw_rate = 1 }
        in_func && /^}/ { exit saw_rate ? 0 : 1 }
    ' "$REPO_ROOT/ui/fb-shm-mapping.c" \
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
    ' "$REPO_ROOT/ui/fb-shm-gl-frame.c" \
        || fail "fb_shm_commit_gl_frame must drain GL PBO before SHM rate gate"
}

test_direct_gpu_publish_is_independent_of_gl_context() {
    local backend="$REPO_ROOT/ui/fb-shm-gl-frame.c"

    # 中文注释：QemuDmaBuf fd 和 Windows named D3D11 texture 已经是可直接
    # 交给 consumer 的 backing。它们必须在 gl_guest_fb.texture 检查和共享
    # GL context 进入之前发布；只有 Linux 普通 texture->dma-buf 可以留在
    # current-context 阶段。顺序写反会让 GL import 失败连带禁用真正的直通句柄。
    require_text "fb_shm_broadcast_direct_gpu_frame" "$backend"
    require_text "fb_shm_gpu_backend_has_d3d_texture" \
        "$REPO_ROOT/ui/fb-shm-gl-export.c"
    require_text "fb_shm_broadcast_context_texture_frame" "$backend"
    awk '
        /static void fb_shm_commit_gl_frame/ { in_func = 1 }
        in_func && /fb_shm_broadcast_direct_gpu_frame/ { saw_direct = 1 }
        in_func && /!d->gl_guest_fb.texture/ {
            saw_texture_gate = 1
            if (!saw_direct) {
                exit 1
            }
        }
        in_func && /fb_shm_gl_context_enter/ {
            saw_context = 1
            if (!saw_direct) {
                exit 1
            }
        }
        in_func && /fb_shm_broadcast_context_texture_frame/ {
            saw_context_export = 1
            if (!saw_context) {
                exit 1
            }
        }
        in_func && /^}/ {
            exit saw_direct && saw_texture_gate && saw_context &&
                 saw_context_export ? 0 : 1
        }
    ' "$backend" || fail "direct GPU publish must precede all GL context gates"
}

test_gpu_export_failure_is_silent() {
    local gpu_backend="$REPO_ROOT/ui/fb-shm-gpu.c"
    local gpu_common="$REPO_ROOT/ui/fb-shm-gpu-common.c"

    # 中文注释：GPU 导出是可选能力。EGL 不支持 texture dma-buf、
    # dma-buf 多平面/非零 offset，或 ANGLE texture 无法共享时，后端必须
    # 安静返回 false，让普通 consumer 继续 SHM，不能刷 warning/info。
    reject_text "warn_report" "$gpu_backend"
    reject_text "error_report" "$gpu_backend"
    reject_text "info_report" "$gpu_backend"
    reject_text "warn_report" "$gpu_common"
    reject_text "error_report" "$gpu_common"
    reject_text "info_report" "$gpu_common"
    require_text "num_planes != 1" "$gpu_backend"
    require_text "offsets[0] != 0" "$gpu_backend"
    require_text "fb_shm_gpu_export_cleanup" "$REPO_ROOT/ui/fb-shm-gl-export.c"
    require_text "fb_shm_gpu_pending_begin" "$gpu_common"
    require_text "frame_sequence <= state->last_sequence" "$gpu_common"
    require_text "state->pending_sequence != frame_sequence" "$gpu_common"
}

test_launcher_uses_qemu11_sdl_egl() {
    # Linux 启动器与 Windows streamer 共用 fb-shm ABI；这里钉住 Linux 入口只用
    # QEMU 11 官方 SDL/GL 参数，避免私有环境钩子再次污染跨平台 GPU 帧路径。
    require_text 'DISP_ARGS+=(-display sdl,gl=on,show-cursor=off)' \
        "$REPO_ROOT/deploy/scripts/lib/sv-devices.sh"
    reject_text_ci "SDL_NATIVE_EGL" "$REPO_ROOT/deploy/scripts/lib/sv-devices.sh"
    reject_text_ci "SDL_NATIVE_EGL" "$REPO_ROOT/deploy/scripts/lib/sv-assemble.sh"
}

test_launchers_keep_gpu_export_as_explicit_capability() {
    local linux_cli="$REPO_ROOT/deploy/scripts/lib/sv-cli.sh"
    local linux_devices="$REPO_ROOT/deploy/scripts/lib/sv-devices.sh"
    local windows_launcher="$REPO_ROOT/deploy/windows/start-vm.ps1"

    # 中文注释：Linux 默认稳定 SDL；显式 GL 和 Windows 能力探测仍可选择
    # blob/hostmem，失败由 QEMU 回退 SHM。关闭属性偏好不能顺带关闭 renderer
    # texture export，也不能把 Linux 的默认路径悄悄改回 virgl。
    require_text ': "${STABLE_DISPLAY:=1}"' "$linux_cli"
    require_text '--no-gpu-zerocopy' "$linux_cli"
    require_text 'blob=true,hostmem=${GPU_HOSTMEM:-256M}' "$linux_devices"

    require_text '[switch]$NoGpuZeroCopy' "$windows_launcher"
    require_text "[string]\$GpuHostmem = '256M'" "$windows_launcher"
    require_text "[ValidateSet('Auto', 'Available', 'Unavailable')]" "$windows_launcher"
    require_text "'-device' 'virtio-vga-gl,help'" "$windows_launcher"
    require_text "'sdl,gl=on,show-cursor=off'" "$windows_launcher"
    require_text "'sdl,show-cursor=off'" "$windows_launcher"
    require_text "'virtio-vga-gl,edid=on" "$windows_launcher"
    require_text "'virtio-vga,edid=on" "$windows_launcher"
    require_text 'if (-not $NoGpuZeroCopy)' "$windows_launcher"
    require_text '",blob=true,hostmem=$GpuHostmem"' "$windows_launcher"
    require_text "'SDL + virtio-vga + SHM'" "$windows_launcher"
    require_text 'virtio-vga-gl 不可用；自动选择' "$windows_launcher"
    reject_text "Write-Warning '当前 QEMU 未提供 virtio-vga-gl" "$windows_launcher"
}

test_scanout_disable_releases_dmabuf() {
    # 中文注释：export_blob 的 fd 由 scanout dmabuf 对象持有。资源被 guest
    # 关闭时必须先 clear，再通知 display disable，否则 BO/fd 会跨帧泄漏。
    require_text "virtio_gpu_virgl_disable_scanout(g, ss.scanout_id)" \
        "$REPO_ROOT/hw/display/virtio-gpu-virgl.c"
}

test_fb_shm_notifier_is_unregistered_before_free() {
    # 中文注释：machine ready 回调可能在 object-add 内同步执行；无论回调是否
    # 已执行，finalize 都必须依据独立注册标志摘掉全局 notifier 节点。
    require_text "bool notifier_registered;" "$REPO_ROOT/ui/fb-shm-qom.c"
    require_text "if (o->notifier_registered)" "$REPO_ROOT/ui/fb-shm-qom.c"
    require_text "qemu_remove_machine_init_done_notifier" "$REPO_ROOT/ui/fb-shm-qom.c"
}

test_fb_shm_treats_shared_header_as_untrusted() {
    # producer 的 slot 指针和 active index 必须来自私有状态；共享 header 只
    # 是对 consumer 的输出，不能反向参与 QEMU 宿主地址计算。
    require_text "fb_shm_restore_private_layout" "$REPO_ROOT/ui/fb-shm-mapping.c"
    require_text "uint32_t active_idx;" "$REPO_ROOT/ui/fb-shm-internal.h"
    reject_text "d->hdr->buf_offset" "$REPO_ROOT/ui/fb-shm-mapping.c"
    reject_text "qatomic_load_acquire(&d->hdr->active_idx)" \
        "$REPO_ROOT/ui/fb-shm-mapping.c"
}

test_fb_shm_buffers_stream_requests() {
    # SOCK_STREAM 的合法短读必须累计到完整控制帧；每轮上限避免 flood 饿死
    # QEMU 主事件循环。
    require_text "request_buf[sizeof(FbShmCtlReq)]" "$REPO_ROOT/ui/fb-shm-internal.h"
    require_text "FB_SHM_MAX_REQS_PER_TICK" "$REPO_ROOT/ui/fb-shm-internal.h"
    require_text "fb_shm_dispatch_request" "$REPO_ROOT/ui/fb-shm-listener.c"
}

test_gl_context_failure_does_not_destroy_bad_context() {
    require_text "gl_ctx_unusable" "$REPO_ROOT/ui/fb-shm-gl-context.c"
    require_text "GLXBadContext" "$REPO_ROOT/ui/fb-shm-gl-context.c"
    awk '
        /^static void fb_shm_gl_release\(FbShmDisplay \*d\)/ { in_func = 1 }
        in_func && /d->gl_ctx && !d->gl_ctx_unusable/ { guarded_destroy = 1 }
        in_func && /dpy_gl_ctx_destroy/ { saw_destroy = 1 }
        in_func && /^}/ {
            exit guarded_destroy && saw_destroy ? 0 : 1
        }
    ' "$REPO_ROOT/ui/fb-shm-gl-context.c" \
        || fail "fb-shm must not destroy a GL context after make-current failure"
}

test_gl_sidecar_restores_provider_context() {
    local failure_restores

    # 中文注释：QEMU 11 的 virglrenderer 会缓存 current-context 状态。fb-shm
    # 可以临时进入共享 context 做异步读回，但每个提前返回也必须恢复 provider
    # 的精确 context；仅靠 listener 排序无法保护下一条异步 virgl 命令。
    require_text "bool dpy_gl_sidecar;" "$REPO_ROOT/include/ui/console.h"
    require_text "QEMUGLContextState" "$REPO_ROOT/include/ui/console.h"
    require_text "dpy_gl_ctx_save_current" "$REPO_ROOT/include/ui/console.h"
    require_text "dpy_gl_ctx_restore_current" "$REPO_ROOT/include/ui/console.h"
    require_text "FbShmGlContextGuard" "$REPO_ROOT/ui/fb-shm-internal.h"
    require_text "g_auto(FbShmGlContextGuard)" "$REPO_ROOT/ui/fb-shm-gl-frame.c"
    require_text "dpy_gl_ctx_restore_current(d->con, &guard->previous)" \
        "$REPO_ROOT/ui/fb-shm-gl-context.c"
    require_text "SDL_GL_GetCurrentWindow" "$REPO_ROOT/ui/sdl2-gl.c"
    require_text "state->draw" "$REPO_ROOT/ui/sdl2-gl.c"
    # context create 与 make-current 两个失败出口都必须恢复外层完整快照。
    failure_restores="$(grep -c \
        '(void)dpy_gl_ctx_restore_current(d->con, &previous)' \
        "$REPO_ROOT/ui/fb-shm-gl-context.c")"
    [[ "$failure_restores" -ge 2 ]] \
        || fail "fb-shm GL create/make failure paths must restore provider binding"
    reject_text_ci "egl_provider_make_current" \
        "$REPO_ROOT/ui/egl-headless.c"
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
    require_text "'-accel', (Get-VMateWhpxAccelerator" "$REPO_ROOT/deploy/windows/start-vm.ps1"
    require_text "return 'whpx,hyperv=off,kernel-irqchip=off'" \
        "$REPO_ROOT/deploy/windows/lib/VMate.Preflight.ps1"
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

test_optional_powershell_syntax() {
    local pwsh_bin
    local script

    pwsh_bin="$(command -v pwsh || command -v powershell || true)"
    if [[ -z "$pwsh_bin" ]]; then
        echo "SKIP: PowerShell not found"
        return
    fi

    # 使用 PowerShell AST parser 做纯静态语法检查，不执行启动器中的文件操作。
    for script in \
        "$REPO_ROOT/deploy/windows/start-vm.ps1" \
        "$REPO_ROOT/deploy/windows/stream-fb-shm.ps1" \
        "$REPO_ROOT/deploy/windows/stop-vm.ps1" \
        "$REPO_ROOT/deploy/windows/collect-hardware-snapshot.ps1" \
        "$REPO_ROOT"/deploy/windows/lib/*.ps1; do
        PS_SCRIPT_PATH="$script" "$pwsh_bin" -NoLogo -NoProfile -NonInteractive \
            -Command '
                $tokens = $null
                $errors = $null
                [void][System.Management.Automation.Language.Parser]::ParseFile(
                    $env:PS_SCRIPT_PATH, [ref]$tokens, [ref]$errors)
                if ($errors.Count -gt 0) {
                    $errors | ForEach-Object { [Console]::Error.WriteLine($_) }
                    exit 1
                }
            '
    done
}

test_optional_windows_launcher_dry_run() {
    local pwsh_bin
    local tmp
    local out
    local vga

    pwsh_bin="$(command -v pwsh || command -v powershell || true)"
    if [[ -z "$pwsh_bin" ]]; then
        echo "SKIP: PowerShell not found for Windows launcher DRY_RUN"
        return
    fi

    tmp="$(mktemp -d)"
    out="$tmp/out.txt"
    mkdir -p "$tmp/user"
    touch "$tmp/disk.qcow2"
    printf 'firmware-code' >"$tmp/code.fd"
    printf 'firmware-vars' >"$tmp/vars.fd"

    # 中文注释：GpuGlProbe 是 DryRun/CI 的确定性注入点。测试不依赖当前宿主
    # 是否真的有 Windows virglrenderer，也不会执行作为占位符传入的 /bin/true。
    USERPROFILE="$tmp/user" "$pwsh_bin" -NoLogo -NoProfile -NonInteractive \
        -File "$REPO_ROOT/deploy/windows/start-vm.ps1" \
        -Qemu /bin/true -VmRoot "$tmp/vm" -Disk "$tmp/disk.qcow2" \
        -OvmfCode "$tmp/code.fd" -OvmfVarsTemplate "$tmp/vars.fd" \
        -FbShmPath "$tmp/fb.sock" -GpuGlProbe Available \
        -DryRunHostCpuName 'Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz' \
        -DryRun > "$out"
    grep -Fx -- 'sdl,gl=on,show-cursor=off' "$out" >/dev/null \
        || fail "Windows available probe must enable SDL/GL"
    vga="$(grep -E '^virtio-vga(-gl)?,' "$out" | head -n 1)"
    [[ "$vga" == virtio-vga-gl,* && "$vga" == *"blob=true"* && "$vga" == *"hostmem=256M"* ]] \
        || fail "Windows available probe must enable virtio-vga-gl blob/hostmem"

    USERPROFILE="$tmp/user" "$pwsh_bin" -NoLogo -NoProfile -NonInteractive \
        -File "$REPO_ROOT/deploy/windows/start-vm.ps1" \
        -Qemu /bin/true -VmRoot "$tmp/vm" -Disk "$tmp/disk.qcow2" \
        -OvmfCode "$tmp/code.fd" -OvmfVarsTemplate "$tmp/vars.fd" \
        -FbShmPath "$tmp/fb.sock" -GpuGlProbe Available \
        -NoGpuZeroCopy \
        -DryRunHostCpuName 'Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz' \
        -DryRun > "$out"
    vga="$(grep -E '^virtio-vga(-gl)?,' "$out" | head -n 1)"
    [[ "$vga" == virtio-vga-gl,* && "$vga" != *"blob=true"* && "$vga" != *"hostmem="* ]] \
        || fail "Windows -NoGpuZeroCopy must retain GL but remove blob/hostmem preference"
    USERPROFILE="$tmp/user" "$pwsh_bin" -NoLogo -NoProfile -NonInteractive \
        -File "$REPO_ROOT/deploy/windows/start-vm.ps1" \
        -Qemu /bin/true -VmRoot "$tmp/vm" -Disk "$tmp/disk.qcow2" \
        -OvmfCode "$tmp/code.fd" -OvmfVarsTemplate "$tmp/vars.fd" \
        -FbShmPath "$tmp/fb.sock" -GpuGlProbe Unavailable -DryRun \
        -DryRunHostCpuName 'Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz' \
        > "$out" 2>&1
    grep -Fx -- 'sdl,show-cursor=off' "$out" >/dev/null \
        || fail "Windows unavailable probe must retain non-GL SDL"
    vga="$(grep -E '^virtio-vga(-gl)?,' "$out" | head -n 1)"
    [[ "$vga" == virtio-vga,* && "$vga" != *"blob=true"* ]] \
        || fail "Windows unavailable probe must fall back to virtio-vga"
    grep -F -- '自动选择 SDL + virtio-vga + SHM' "$out" >/dev/null \
        || fail "Windows unavailable probe must explain SHM fallback"

    rm -rf "$tmp"
}

test_docs_cover_windows_packaging() {
    require_text "Windows 10 / Windows 11" "$REPO_ROOT/deploy/docs/WINDOWS-PACKAGING.md"
    require_text "qemu-fb-shm-stream.exe" "$REPO_ROOT/deploy/docs/WINDOWS-PACKAGING.md"
    require_text "NOTIFY_GPU_FRAME" "$REPO_ROOT/deploy/docs/WINDOWS-PACKAGING.md"
    require_text "make -j4 installer" "$REPO_ROOT/deploy/docs/WINDOWS-PACKAGING.md"
    require_text "WINDOWS-PACKAGING.md" "$REPO_ROOT/deploy/docs/README.md"
    require_text "FB-SHM-GPU-ZEROCOPY.md" "$REPO_ROOT/deploy/docs/README.md"
    require_text "NOTIFY_GPU_FRAME" "$REPO_ROOT/deploy/docs/FB-SHM-GPU-ZEROCOPY.md"
    require_text "virglrenderer not found" "$REPO_ROOT/deploy/docs/WINDOWS-PACKAGING.md"
    require_text "ANGLE/libEGL" "$REPO_ROOT/deploy/docs/WINDOWS-PACKAGING.md"
    require_text "Linux/Windows" "$REPO_ROOT/docs/system/fb-shm.rst"
}

test_new_files_stay_small() {
    local file
    for file in \
        "$REPO_ROOT/tools/fb-shm-stream/common.h" \
        "$REPO_ROOT/tools/fb-shm-stream/platform.c" \
        "$REPO_ROOT/tools/fb-shm-stream/ffmpeg.c" \
        "$REPO_ROOT/tools/fb-shm-stream/main.c" \
        "$REPO_ROOT/include/ui/fb-shm-gpu.h" \
        "$REPO_ROOT"/ui/fb-shm*.c \
        "$REPO_ROOT/ui/fb-shm-internal.h" \
        "$REPO_ROOT/tests/unit/test-fb-shm-gpu-frame.c" \
        "$REPO_ROOT/deploy/windows/start-vm.ps1" \
        "$REPO_ROOT/deploy/windows/stream-fb-shm.ps1" \
        "$REPO_ROOT/deploy/windows/stop-vm.ps1" \
        "$REPO_ROOT/deploy/windows/collect-hardware-snapshot.ps1" \
        "$REPO_ROOT"/deploy/windows/lib/*.ps1 \
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
test_direct_gpu_publish_is_independent_of_gl_context
test_gpu_export_failure_is_silent
test_launcher_uses_qemu11_sdl_egl
test_launchers_keep_gpu_export_as_explicit_capability
test_scanout_disable_releases_dmabuf
test_fb_shm_notifier_is_unregistered_before_free
test_fb_shm_treats_shared_header_as_untrusted
test_fb_shm_buffers_stream_requests
test_gl_context_failure_does_not_destroy_bad_context
test_gl_sidecar_restores_provider_context
test_native_streamer_has_both_platforms
test_windows_scripts_are_native
test_optional_powershell_syntax
test_optional_windows_launcher_dry_run
test_docs_cover_windows_packaging
test_new_files_stay_small
test_optional_mingw_streamer_syntax
bash "$SCRIPT_DIR/test_windows_gpu_sync_static.sh"

echo "OK: windows fb-shm static checks passed"

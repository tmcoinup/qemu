#!/usr/bin/env bash
# G-11 SDL low-latency operator wrapper.  This file only delegates VM launch
# to start-vm.sh; it never writes vm.conf or stores credentials.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$deploy_root/.." && pwd)"
start_vm="$script_dir/start-vm.sh"
qemu_bin="${QEMU_BIN:-$repo_root/build/qemu-system-x86_64}"

readonly SDL_PROFILE_BALANCED=low-latency-v1
readonly SDL_PROFILE_ULTRA=ultra-responsive-v1
readonly SDL_PROFILE_EXPERIMENTAL_120=experimental-120hz-v1
readonly SDL_PRESENT_MODE=fixed
readonly SDL_CURSOR_MODE=host
readonly SDL_ALLOW_HOST_SLEEP=0

# Mutable only while parsing this wrapper's profile selector.  The values are
# passed to one start-vm process; nothing is persisted in vm.conf.
SDL_PROFILE=$SDL_PROFILE_BALANCED
SDL_TARGET_FPS=60
SDL_INPUT_POLL_MS=2
VGPU_CONSOLE_US=16667
SDL_SERVICE_CPUS=0
SDL_USB_LOW_LATENCY=0

usage() {
    cat <<'EOF'
用法：
  ./deploy/scripts/g11-sdl-performance.sh audit [--ultra-responsive|--experimental-120hz]
  ./deploy/scripts/g11-sdl-performance.sh profile [balanced|ultra|experimental-120]
  ./deploy/scripts/g11-sdl-performance.sh start  VM编号 [响应档位] [--native-wayland] [start-vm 其他参数]
  ./deploy/scripts/g11-sdl-performance.sh verify VM编号

说明：
  audit   只读检查源码、当前 QEMU build 和所选参数，不启动 VM。
  profile 只打印封装值；所有档位都只影响本次启动，不写入 VM 配置。
  start   默认 balanced；--ultra-responsive 使用 60Hz/1ms/服务核/1ms 键盘。
          --experimental-120hz 才把 REGION/Present 提到 120Hz，须实测后使用。
          --native-wayland 是非默认 A/B；仅真实 Wayland 会话可用，
          会禁用 X11-only native EGL/GPU-first 启动，保留 DGame SHM fallback。
          切换窗口模式前后都必须让 Windows 完整关机，不支持热切换。
  verify  只读核对运行中 QEMU 的 PID、SDL argv 和环境；不虚构新帧遥测。
EOF
}

select_profile() {
    case "${1:-balanced}" in
        balanced|low-latency-v1)
            SDL_PROFILE=$SDL_PROFILE_BALANCED
            SDL_TARGET_FPS=60
            SDL_INPUT_POLL_MS=2
            VGPU_CONSOLE_US=16667
            SDL_SERVICE_CPUS=0
            SDL_USB_LOW_LATENCY=0
            ;;
        ultra|ultra-responsive-v1|--ultra-responsive)
            SDL_PROFILE=$SDL_PROFILE_ULTRA
            SDL_TARGET_FPS=60
            SDL_INPUT_POLL_MS=1
            VGPU_CONSOLE_US=16667
            SDL_SERVICE_CPUS=auto
            SDL_USB_LOW_LATENCY=1
            ;;
        experimental-120|experimental-120hz-v1|--experimental-120hz)
            SDL_PROFILE=$SDL_PROFILE_EXPERIMENTAL_120
            SDL_TARGET_FPS=120
            SDL_INPUT_POLL_MS=1
            VGPU_CONSOLE_US=8333
            SDL_SERVICE_CPUS=auto
            SDL_USB_LOW_LATENCY=1
            ;;
        *)
            echo "[g11-sdl] 未知响应档位：$1（balanced|ultra|experimental-120）" >&2
            return 2
            ;;
    esac
}

print_profile() {
    cat <<EOF
G11_SDL_PROFILE=$SDL_PROFILE
QEMU_SDL_TARGET_FPS=$SDL_TARGET_FPS
QEMU_SDL_INPUT_POLL_MS=$SDL_INPUT_POLL_MS
QEMU_SDL_PRESENT_MODE=$SDL_PRESENT_MODE
QEMU_SDL_CURSOR_MODE=$SDL_CURSOR_MODE
VGPU_CONSOLE_INTERVAL_US=$VGPU_CONSOLE_US
QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP=$SDL_ALLOW_HOST_SLEEP
QEMU_SERVICE_CPUS=$SDL_SERVICE_CPUS
G11_USB_HID_LOW_LATENCY=$SDL_USB_LOW_LATENCY
EOF
}

source_has() {
    local file=$1 needle=$2
    [[ -r "$file" ]] && grep -Fq -- "$needle" "$file"
}

binary_has() {
    local needle=$1
    [[ -r "$qemu_bin" ]] && LC_ALL=C grep -aFqm1 -- "$needle" "$qemu_bin"
}

audit_build_freshness() {
    local qemu_real build_dir target dry_run meaningful
    local object
    local -a contract_objects=(
        libsystem.a.p/ui_console.c.o
        libsystem.a.p/ui_egl-context.c.o
        libsystem.a.p/ui_egl-helpers.c.o
        libsystem.a.p/ui_shader.c.o
        libsystem.a.p/ui_sdl2.c.o
        libsystem.a.p/ui_sdl2-2d.c.o
        libsystem.a.p/ui_sdl2-event.c.o
        libsystem.a.p/ui_sdl2-gl.c.o
        libsystem.a.p/hw_usb_dev-hid.c.o
        libsystem.a.p/hw_vfio_display.c.o
    )

    qemu_real=$(readlink -f -- "$qemu_bin" 2>/dev/null || true)
    [[ -n "$qemu_real" ]] || qemu_real=$qemu_bin
    build_dir=$(dirname -- "$qemu_real")
    target=$(basename -- "$qemu_real")

    if [[ ! -f "$build_dir/build.ninja" ]]; then
        if [[ "$build_dir" == "$repo_root/build" ]]; then
            echo "[g11-sdl] QEMU_BUILD_FRESH=unknown (缺少 build.ninja)" >&2
            return 1
        fi
        echo "[g11-sdl] QEMU_BUILD_FRESH=not-checkable (外部 QEMU build)"
        return 0
    fi
    if ! command -v ninja >/dev/null 2>&1; then
        echo "[g11-sdl] QEMU_BUILD_FRESH=unknown (找不到 ninja)" >&2
        return 1
    fi
    if ! dry_run=$(LC_ALL=C ninja -C "$build_dir" -n "$target" 2>&1); then
        echo "[g11-sdl] QEMU_BUILD_FRESH=error" >&2
        printf '%s\n' "$dry_run" | sed 's/^/[g11-sdl]   /' >&2
        return 1
    fi
    # qemu-version.h is deliberately always dirty in this tree.  Its dry-run
    # cascade recompiles two version consumers and relinks QEMU even after a
    # completed build; ignore only those exact actions, never other work.
    meaningful=$(sed -E \
        -e '/^ninja: Entering directory /d' \
        -e '/^\[[0-9]+\/[0-9]+\] Generating qemu-version\.h /d' \
        -e '/^\[[0-9]+\/[0-9]+\] Compiling C object libqmp\.a\.p\/monitor_qmp-cmds-control\.c\.o$/d' \
        -e '/^\[[0-9]+\/[0-9]+\] Compiling C object libsystem\.a\.p\/system_vl\.c\.o$/d' \
        -e '/^\[[0-9]+\/[0-9]+\] Linking target qemu-system-x86_64$/d' \
        -e '/^[[:space:]]*$/d' <<<"$dry_run")
    if [[ -n "$meaningful" ]]; then
        echo "[g11-sdl] QEMU_BUILD_FRESH=no"
        echo "[g11-sdl] 源码或构建配置比当前 QEMU 新；请先重新编译。" >&2
        printf '%s\n' "$meaningful" | head -n 8 | sed 's/^/[g11-sdl]   /' >&2
        return 1
    fi

    for object in "${contract_objects[@]}"; do
        if [[ ! -e "$build_dir/$object" ||
              "$build_dir/$object" -nt "$qemu_real" ]]; then
            echo "[g11-sdl] QEMU_BUILD_FRESH=no ($object)" >&2
            return 1
        fi
    done
    echo "[g11-sdl] QEMU_BUILD_FRESH=yes"
}

audit() {
    local failures=0 display_help=""
    local sdl_source="$repo_root/ui/sdl2.c"

    echo "[g11-sdl] 推荐配置（start 子命令会强制使用）："
    print_profile | sed 's/^/  /'
    echo "[g11-sdl] 会话：XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-unknown} DISPLAY=$([[ -n "${DISPLAY:-}" ]] && echo set || echo unset) WAYLAND_DISPLAY=$([[ -n "${WAYLAND_DISPLAY:-}" ]] && echo set || echo unset) SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-auto}"
    echo "[g11-sdl] 启动器：$start_vm"
    echo "[g11-sdl] QEMU：$qemu_bin"

    if [[ ! -x "$start_vm" ]]; then
        echo "[g11-sdl] FAIL: start-vm.sh 不存在或不可执行" >&2
        failures=$((failures + 1))
    fi

    for source_contract in \
            QEMU_SDL_TARGET_FPS \
            QEMU_SDL_INPUT_POLL_MS \
            QEMU_SDL_PRESENT_MODE \
            QEMU_SDL_TITLE_FPS \
            QEMU_SDL_CURSOR_MODE \
            QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP; do
        if source_has "$sdl_source" "$source_contract"; then
            echo "[g11-sdl] source $source_contract=yes"
        else
            echo "[g11-sdl] source $source_contract=no"
            failures=$((failures + 1))
        fi
    done
    if source_has "$start_vm" VGPU_CONSOLE_INTERVAL_US; then
        echo "[g11-sdl] source VGPU_CONSOLE_INTERVAL_US=yes"
    else
        echo "[g11-sdl] source VGPU_CONSOLE_INTERVAL_US=no"
        failures=$((failures + 1))
    fi

    if [[ ! -x "$qemu_bin" ]]; then
        echo "[g11-sdl] QEMU_BUILD=missing"
        echo "[g11-sdl] 先运行 ./deploy/host/build-qemu.sh；当前只能完成源码审计。" >&2
        failures=$((failures + 1))
    else
        for binary_contract in \
                QEMU_SDL_TARGET_FPS \
                QEMU_SDL_INPUT_POLL_MS \
                QEMU_SDL_PRESENT_MODE \
                QEMU_SDL_TITLE_FPS \
                QEMU_SDL_CURSOR_MODE \
                QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP; do
            if binary_has "$binary_contract"; then
                echo "[g11-sdl] binary $binary_contract=yes"
            else
                echo "[g11-sdl] binary $binary_contract=no"
                failures=$((failures + 1))
            fi
        done
        display_help=$("$qemu_bin" -display help 2>&1 || true)
        if grep -Eq '(^|[[:space:]])sdl([[:space:]]|$)' <<<"$display_help"; then
            echo "[g11-sdl] QEMU_SDL_BACKEND=yes"
        else
            echo "[g11-sdl] QEMU_SDL_BACKEND=no"
            failures=$((failures + 1))
        fi
        if ! audit_build_freshness; then
            failures=$((failures + 1))
        fi
    fi

    if ((failures)); then
        echo "[g11-sdl] AUDIT_RESULT=not-ready failures=$failures"
        return 1
    fi
    echo "[g11-sdl] AUDIT_RESULT=ready"
}

reject_conflicting_start_modes() {
    local arg

    for arg in "$@"; do
        case "$arg" in
            --install|--native|--gtk|--vgpu-gtk|--sdl|--vgpu-sdl|\
            --rdp|--legacy-shmem|--rescue|--rescue-sdl|--rescue-gtk|--no-gpu)
                echo "[g11-sdl] 不接受会切换显示模式的参数：$arg" >&2
                echo "[g11-sdl] 安装、救援、GTK 或旧 relay 请直接使用 start-vm.sh。" >&2
                return 2
                ;;
        esac
    done
}

require_native_wayland_session() {
    local session_type=${XDG_SESSION_TYPE:-}
    local wayland_display=${WAYLAND_DISPLAY:-}
    local runtime_dir=${XDG_RUNTIME_DIR:-}
    local wayland_socket

    if [[ "${session_type,,}" != wayland ]]; then
        echo "[g11-sdl] --native-wayland 仅允许在真实 Wayland 会话中使用：XDG_SESSION_TYPE=${session_type:-<unset>}" >&2
        return 2
    fi
    if [[ -z "$wayland_display" || -z "$runtime_dir" ||
          "$runtime_dir" != /* || ! -d "$runtime_dir" ]]; then
        echo "[g11-sdl] --native-wayland 缺少可用的 WAYLAND_DISPLAY/XDG_RUNTIME_DIR" >&2
        return 2
    fi
    case "$wayland_display" in
        /*) wayland_socket=$wayland_display ;;
        */*)
            echo "[g11-sdl] WAYLAND_DISPLAY 必须是 socket 名或绝对路径：$wayland_display" >&2
            return 2
            ;;
        *) wayland_socket="${runtime_dir%/}/$wayland_display" ;;
    esac
    if [[ ! -S "$wayland_socket" ]]; then
        echo "[g11-sdl] --native-wayland 未找到真实 Wayland socket：$wayland_socket" >&2
        return 2
    fi
}

start_vm_low_latency() {
    local vm_id=${1:-}
    local arg profile_seen=0 native_wayland=0 native_wayland_seen=0
    local -a forwarded=() window_env=() window_args=()
    shift || true

    [[ "$vm_id" =~ ^[1-9][0-9]*$ ]] || {
        echo "[g11-sdl] VM编号必须是正整数：${vm_id:-<empty>}" >&2
        return 2
    }
    for arg in "$@"; do
        case "$arg" in
            --ultra-responsive)
                if ((profile_seen)); then
                    echo "[g11-sdl] 响应档位只能指定一次" >&2
                    return 2
                fi
                select_profile ultra
                profile_seen=1
                ;;
            --experimental-120hz)
                if ((profile_seen)); then
                    echo "[g11-sdl] 响应档位只能指定一次" >&2
                    return 2
                fi
                select_profile experimental-120
                profile_seen=1
                ;;
            --balanced)
                if ((profile_seen)); then
                    echo "[g11-sdl] 响应档位只能指定一次" >&2
                    return 2
                fi
                select_profile balanced
                profile_seen=1
                ;;
            --native-wayland)
                if ((native_wayland_seen)); then
                    echo "[g11-sdl] --native-wayland 只能指定一次" >&2
                    return 2
                fi
                native_wayland=1
                native_wayland_seen=1
                ;;
            *)
                forwarded+=("$arg")
                ;;
        esac
    done
    reject_conflicting_start_modes "${forwarded[@]}"
    if ((native_wayland)); then
        for arg in "${forwarded[@]}"; do
            if [[ "$arg" == --dgame-preview-gpu ]]; then
                echo "[g11-sdl] --native-wayland 与 --dgame-preview-gpu 冲突；当前 GPU-first/native EGL 仅支持 X11" >&2
                return 2
            fi
        done
        if [[ -n "${SDL_VIDEODRIVER:-}" &&
              "${SDL_VIDEODRIVER}" != wayland ]]; then
            echo "[g11-sdl] --native-wayland 与当前 SDL_VIDEODRIVER=${SDL_VIDEODRIVER} 冲突" >&2
            return 2
        fi
        if ! require_native_wayland_session; then
            return 2
        fi
        window_env+=(
            SDL_VIDEODRIVER=wayland
            QEMU_SDL_NATIVE_EGL=0
            G11_SDL_WINDOW_MODE=native-wayland-v1
        )
        window_args+=(--no-dgame-preview-gpu)
    fi
    if [[ "$SDL_USB_LOW_LATENCY" == 1 ]]; then
        for arg in "${forwarded[@]}"; do
            if [[ "$arg" == --no-low-latency-input ]]; then
                echo "[g11-sdl] 所选响应档位与 --no-low-latency-input 冲突" >&2
                return 2
            fi
        done
    fi
    [[ -x "$start_vm" ]] || {
        echo "[g11-sdl] start-vm.sh 不存在或不可执行：$start_vm" >&2
        return 1
    }

    echo "[g11-sdl] 启动前只读预检源码与当前 QEMU build..."
    if ! audit; then
        echo "[g11-sdl] 当前 build 未满足 $SDL_PROFILE；VM 未启动。" >&2
        echo "[g11-sdl] 先运行 ./deploy/host/build-qemu.sh，再重试。" >&2
        return 1
    fi

    echo "[g11-sdl] 启动 VM $vm_id，应用 $SDL_PROFILE："
    print_profile | sed 's/^/  /'
    if ((native_wayland)); then
        echo "[g11-sdl] 窗口 A/B：native-wayland-v1（SDL Wayland / X11 native EGL、GPU-first 启动已禁用 / 保留 DGame SHM fallback）"
    fi
    echo "[g11-sdl] 本封装不写 vm.conf、不读取或保存宿主凭据。"

    local -a latency_args=()
    [[ "$SDL_USB_LOW_LATENCY" == 0 ]] || latency_args+=(--low-latency-input)

    exec env \
        G11_SDL_PROFILE="$SDL_PROFILE" \
        QEMU_SDL_TARGET_FPS="$SDL_TARGET_FPS" \
        QEMU_SDL_INPUT_POLL_MS="$SDL_INPUT_POLL_MS" \
        QEMU_SDL_PRESENT_MODE="$SDL_PRESENT_MODE" \
        QEMU_SDL_CURSOR_MODE="$SDL_CURSOR_MODE" \
        VGPU_CONSOLE_INTERVAL_US="$VGPU_CONSOLE_US" \
        QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP="$SDL_ALLOW_HOST_SLEEP" \
        QEMU_SERVICE_CPUS="$SDL_SERVICE_CPUS" \
        "${window_env[@]}" \
        "$start_vm" "$vm_id" "${latency_args[@]}" "${window_args[@]}" \
        "${forwarded[@]}" --sdl
}

find_vm_pids() {
    local vm_id=$1 proc pid exe i
    local wanted="vm${vm_id}"
    local -a argv=()

    for proc in /proc/[0-9]*; do
        [[ -r "$proc/cmdline" ]] || continue
        pid=${proc##*/}
        exe=$(readlink -f "$proc/exe" 2>/dev/null || true)
        [[ "${exe##*/}" == qemu-system-* ]] || continue
        argv=()
        mapfile -d '' -t argv <"$proc/cmdline" 2>/dev/null || true
        for ((i = 0; i + 1 < ${#argv[@]}; i += 1)); do
            if [[ "${argv[i]}" == -name &&
                  ( "${argv[i + 1]}" == "$wanted" ||
                    "${argv[i + 1]}" == "$wanted,"* ) ]]; then
                printf '%s\n' "$pid"
                break
            fi
        done
    done
}

process_env_value() {
    local pid=$1 wanted=$2 entry

    while IFS= read -r -d '' entry; do
        if [[ "$entry" == "$wanted="* ]]; then
            printf '%s\n' "${entry#*=}"
            return 0
        fi
    done <"/proc/$pid/environ"
    return 1
}

read_mdev_console_intervals() {
    local uuid=$1 field value interval="" vga_interval=""
    local params="/sys/bus/mdev/devices/$uuid/nvidia/vgpu_params"
    local content
    local -a fields=()

    [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
        || return 2
    [[ -r "$params" ]] || return 1
    content=$(<"$params")
    IFS=',' read -r -a fields <<<"$content"
    for field in "${fields[@]}"; do
        field=${field//$'\n'/}
        case "$field" in
            intervaltime=*)
                value=${field#intervaltime=}
                [[ "$value" =~ ^[0-9]+$ ]] && interval=$value
                ;;
            vgaintervaltime=*)
                value=${field#vgaintervaltime=}
                [[ "$value" =~ ^[0-9]+$ ]] && vga_interval=$value
                ;;
        esac
    done
    [[ -n "$interval" && -n "$vga_interval" ]] || return 1
    printf '%s %s\n' "$interval" "$vga_interval"
}

verify_running_vm() {
    local vm_id=${1:-} audit_status=0 pid display_arg="" vfio_display=""
    local exe_path=""
    local mdev_uuid="" interval_actual="" vga_interval_actual=""
    local detected_profile="" declared_profile="" usb_low_latency=0
    local window_mode="" sdl_video_driver="" native_egl=""
    local env_readable=1
    local failures=0 partial=0 i actual expected key
    local -a pids=() argv=()
    local -a env_keys=(
        QEMU_SDL_TARGET_FPS
        QEMU_SDL_INPUT_POLL_MS
        QEMU_SDL_PRESENT_MODE
        QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP
        QEMU_SERVICE_CPUS
    )
    local -a env_expected=()

    [[ "$vm_id" =~ ^[1-9][0-9]*$ ]] || {
        echo "[g11-sdl] VM编号必须是正整数：${vm_id:-<empty>}" >&2
        return 2
    }

    audit || audit_status=$?
    mapfile -t pids < <(find_vm_pids "$vm_id")
    if ((${#pids[@]} == 0)); then
        echo "[g11-sdl] VERIFY_RESULT=not-running VM=$vm_id" >&2
        echo "[g11-sdl] 当前没有可观测的 vm${vm_id} QEMU 进程；无法验证运行时 SDL 参数或画面响应。" >&2
        echo "[g11-sdl] 先执行 start $vm_id，窗口进入 Windows 后再运行 verify。" >&2
        return 3
    fi
    if ((${#pids[@]} != 1)); then
        echo "[g11-sdl] VERIFY_RESULT=ambiguous VM=$vm_id PIDS=${pids[*]}" >&2
        echo "[g11-sdl] 同一 VM 名称出现多个 QEMU，拒绝猜测目标进程。" >&2
        return 4
    fi
    pid=${pids[0]}
    mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null || true
    for ((i = 0; i + 1 < ${#argv[@]}; i += 1)); do
        if [[ "${argv[i]}" == -display ]]; then
            display_arg=${argv[i + 1]}
        elif [[ "${argv[i]}" == -device &&
                "${argv[i + 1]}" == vfio-pci*display=on* ]]; then
            vfio_display=${argv[i + 1]}
            if [[ "$vfio_display" =~ sysfsdev=/sys/bus/mdev/devices/([0-9a-fA-F-]+)(,|$) ]]; then
                mdev_uuid=${BASH_REMATCH[1]}
            fi
        elif [[ "${argv[i]}" == -device &&
                "${argv[i + 1]}" == usb-kbd* &&
                "${argv[i + 1]}" == *x-low-latency=on* ]]; then
            usb_low_latency=1
        fi
    done

    exe_path=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
    echo "[g11-sdl] VM=$vm_id PID=$pid EXE=${exe_path:-unknown}"
    if [[ "$exe_path" == *" (deleted)" ]]; then
        echo "[g11-sdl] FAIL: 运行中的 QEMU 是重编译前已被替换的旧映像；请完整关闭 Windows 后重新启动" >&2
        failures=$((failures + 1))
    fi
    ps -o pid=,stat=,etime=,pcpu=,pmem=,nlwp= -p "$pid" 2>/dev/null |
        sed 's/^/[g11-sdl] PROCESS /' || true
    echo "[g11-sdl] DISPLAY_ARG=${display_arg:-<missing>}"
    echo "[g11-sdl] VFIO_DISPLAY=$([[ -n "$vfio_display" ]] && echo on || echo missing)"
    if [[ "$display_arg" != sdl,* ]]; then
        echo "[g11-sdl] FAIL: 运行中的 VM 不是 SDL display backend" >&2
        failures=$((failures + 1))
    fi
    if [[ -z "$vfio_display" ]]; then
        echo "[g11-sdl] FAIL: argv 中未发现 native vGPU display=on" >&2
        failures=$((failures + 1))
    fi

    if [[ ! -r "/proc/$pid/environ" ]]; then
        echo "[g11-sdl] WARN: 当前用户无权读取 /proc/$pid/environ，运行时环境无法核对。" >&2
        env_readable=0
        partial=1
    else
        declared_profile=$(process_env_value "$pid" G11_SDL_PROFILE 2>/dev/null || true)
        if [[ "$declared_profile" == "$SDL_PROFILE_EXPERIMENTAL_120" ]]; then
            select_profile experimental-120
            detected_profile=$SDL_PROFILE_EXPERIMENTAL_120
        elif [[ "$declared_profile" == "$SDL_PROFILE_ULTRA" ]]; then
            select_profile ultra
            detected_profile=$SDL_PROFILE_ULTRA
        elif [[ "$declared_profile" == "$SDL_PROFILE_BALANCED" ]]; then
            select_profile balanced
            detected_profile=$SDL_PROFILE_BALANCED
        else
            actual=$(process_env_value "$pid" QEMU_SDL_TARGET_FPS 2>/dev/null || true)
            expected=$(process_env_value "$pid" QEMU_SDL_INPUT_POLL_MS 2>/dev/null || true)
            if [[ "$actual" == 120 && "$expected" == 1 ]]; then
                select_profile experimental-120
                detected_profile="$SDL_PROFILE_EXPERIMENTAL_120 (inferred)"
            elif [[ "$actual" == 60 && "$expected" == 1 ]]; then
                select_profile ultra
                detected_profile="$SDL_PROFILE_ULTRA (inferred)"
            else
                select_profile balanced
                detected_profile="$SDL_PROFILE_BALANCED (inferred)"
            fi
        fi
        echo "[g11-sdl] PROFILE=${detected_profile} declared=${declared_profile:-<missing>}"
        env_expected=(
            "$SDL_TARGET_FPS"
            "$SDL_INPUT_POLL_MS"
            "$SDL_PRESENT_MODE"
            "$SDL_ALLOW_HOST_SLEEP"
            "$SDL_SERVICE_CPUS"
        )
        for ((i = 0; i < ${#env_keys[@]}; i += 1)); do
            key=${env_keys[i]}
            expected=${env_expected[i]}
            actual=$(process_env_value "$pid" "$key" 2>/dev/null || true)
            if [[ "$key" == QEMU_SERVICE_CPUS && -z "$actual" ]]; then
                actual=0
            fi
            printf '[g11-sdl] ENV %s=%s (expected %s)\n' \
                "$key" "${actual:-<missing>}" "$expected"
            if [[ "$actual" != "$expected" ]]; then
                failures=$((failures + 1))
            fi
        done
        for key in SDL_VIDEODRIVER QEMU_SDL_NATIVE_EGL \
                G11_SDL_WINDOW_MODE QEMU_SDL_CURSOR_MODE \
                QEMU_SDL_TITLE_FPS LIBDECOR_PLUGIN_DIR; do
            actual=$(process_env_value "$pid" "$key" 2>/dev/null || true)
            printf '[g11-sdl] ENV %s=%s\n' "$key" "${actual:-<auto-or-unset>}"
        done
        window_mode=$(process_env_value "$pid" G11_SDL_WINDOW_MODE 2>/dev/null || true)
        sdl_video_driver=$(process_env_value "$pid" SDL_VIDEODRIVER 2>/dev/null || true)
        native_egl=$(process_env_value "$pid" QEMU_SDL_NATIVE_EGL 2>/dev/null || true)
        case "$window_mode" in
            native-wayland-v1)
                echo "[g11-sdl] WINDOW_CONTRACT=native-wayland-v1 driver=${sdl_video_driver:-<missing>} native-egl=${native_egl:-<missing>}"
                if [[ "$sdl_video_driver" != wayland ]]; then
                    echo "[g11-sdl] FAIL: native-wayland-v1 必须使用 SDL_VIDEODRIVER=wayland" >&2
                    failures=$((failures + 1))
                fi
                if [[ "$native_egl" != 0 ]]; then
                    echo "[g11-sdl] FAIL: native-wayland-v1 必须禁用 X11-only QEMU_SDL_NATIVE_EGL" >&2
                    failures=$((failures + 1))
                fi
                ;;
            '')
                echo "[g11-sdl] WINDOW_CONTRACT=launcher-default driver=${sdl_video_driver:-auto} native-egl=${native_egl:-auto}"
                ;;
            *)
                echo "[g11-sdl] FAIL: 未知 G11_SDL_WINDOW_MODE=$window_mode" >&2
                failures=$((failures + 1))
                ;;
        esac
    fi

    echo "[g11-sdl] USB_KEYBOARD_1MS=$usb_low_latency"
    if ((env_readable)) && [[ "$SDL_USB_LOW_LATENCY" == 1 &&
                              "$usb_low_latency" != 1 ]]; then
        echo "[g11-sdl] FAIL: 响应 profile 未在 usb-kbd argv 启用 1ms endpoint" >&2
        failures=$((failures + 1))
    fi

    if [[ -z "$mdev_uuid" ]]; then
        echo "[g11-sdl] FAIL: 无法从受限 vfio-pci argv 解析 mdev UUID" >&2
        failures=$((failures + 1))
    elif read -r interval_actual vga_interval_actual \
            < <(read_mdev_console_intervals "$mdev_uuid"); then
        if ((env_readable)); then
            printf '[g11-sdl] MDEV %s intervaltime=%s vgaintervaltime=%s (expected %s)\n' \
                "$mdev_uuid" "$interval_actual" "$vga_interval_actual" \
                "$VGPU_CONSOLE_US"
            if [[ "$interval_actual" != "$VGPU_CONSOLE_US" ||
                  "$vga_interval_actual" != "$VGPU_CONSOLE_US" ]]; then
                failures=$((failures + 1))
            fi
        else
            printf '[g11-sdl] MDEV %s intervaltime=%s vgaintervaltime=%s (profile unavailable)\n' \
                "$mdev_uuid" "$interval_actual" "$vga_interval_actual"
        fi
    else
        echo "[g11-sdl] WARN: 无法读取 mdev $mdev_uuid 的已应用 console interval" >&2
        partial=1
    fi

    echo "[g11-sdl] SOURCE_FRAME_TELEMETRY=unavailable"
    echo "[g11-sdl] 说明：进程存活、CPU 占用和 SDL Present 都不能证明 vGPU REGION 产生了新画面；连续动态画面是否定格仍需按教程实机观察。"

    ((audit_status == 0)) || failures=$((failures + 1))
    if ((failures)); then
        echo "[g11-sdl] VERIFY_RESULT=failed failures=$failures"
        return 1
    fi
    if ((partial)); then
        echo "[g11-sdl] VERIFY_RESULT=partial"
        return 4
    fi
    echo "[g11-sdl] VERIFY_RESULT=process-contract-pass"
}

command_name=${1:-audit}
case "$command_name" in
    audit|status)
        shift || true
        if (($# == 1)) && [[ "$1" == --ultra-responsive ]]; then
            select_profile ultra
        elif (($# == 1)) && [[ "$1" == --experimental-120hz ]]; then
            select_profile experimental-120
        elif (($# != 0)); then
            usage >&2
            exit 2
        fi
        audit
        ;;
    profile)
        shift
        [[ $# -le 1 ]] || { usage >&2; exit 2; }
        select_profile "${1:-balanced}"
        print_profile
        ;;
    start)
        shift
        (($# >= 1)) || { usage >&2; exit 2; }
        start_vm_low_latency "$@"
        ;;
    verify)
        shift
        [[ $# == 1 ]] || { usage >&2; exit 2; }
        verify_running_vm "$1"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

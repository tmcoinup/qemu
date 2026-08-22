#!/usr/bin/env bash
# Launcher-side integration for the root-owned G-11 performance helper.

G11_HOST_PERFORMANCE_SYSTEM_HELPER="${G11_HOST_PERFORMANCE_SYSTEM_HELPER:-/usr/local/libexec/qemu-g11-performance}"
G11_HOST_PERFORMANCE_SOURCE_HELPER="${G11_HOST_PERFORMANCE_SOURCE_HELPER:-$here/host/g11-performance.sh}"
G11_HOST_PERFORMANCE_INSTALLER="${G11_HOST_PERFORMANCE_INSTALLER:-$here/host/install-g11-performance.sh}"
G11_HOST_PERFORMANCE_STATUS=not-checked

g11_host_performance_normalize_mode() {
    local value=${G11_HOST_PERFORMANCE:-auto}
    case "${value,,}" in
        auto|required|off) G11_HOST_PERFORMANCE=${value,,} ;;
        1|on|yes|true) G11_HOST_PERFORMANCE=required ;;
        0|off|no|false) G11_HOST_PERFORMANCE=off ;;
        *) return 2 ;;
    esac
    export G11_HOST_PERFORMANCE
}

g11_host_performance_helper_ready() {
    local helper=$G11_HOST_PERFORMANCE_SYSTEM_HELPER owner mode

    [[ -f "$helper" && ! -L "$helper" && -x "$helper" ]] || return 1
    owner=$(stat -Lc %u -- "$helper" 2>/dev/null) || return 1
    mode=$(stat -Lc %a -- "$helper" 2>/dev/null) || return 1
    [[ "$owner" == 0 && "$mode" == 755 ]] || return 1
    [[ -r "$G11_HOST_PERFORMANCE_SOURCE_HELPER" ]] || return 1
    cmp -s -- "$G11_HOST_PERFORMANCE_SOURCE_HELPER" "$helper"
}

g11_host_performance_run_installer() {
    local password=${SUDO_PASSWORD:-}

    [[ -x "$G11_HOST_PERFORMANCE_INSTALLER" ]] || {
        echo "[g11-performance] 安装器不存在或不可执行: $G11_HOST_PERFORMANCE_INSTALLER" >&2
        return 1
    }
    if ((EUID == 0)); then
        "$G11_HOST_PERFORMANCE_INSTALLER"
        return
    fi
    command -v sudo >/dev/null 2>&1 || return 1
    if sudo -n -- "$G11_HOST_PERFORMANCE_INSTALLER"; then
        return 0
    fi
    if [[ -n "$password" ]]; then
        printf '%s\n' "$password" |
            sudo -S -p '' -- "$G11_HOST_PERFORMANCE_INSTALLER"
        return
    fi
    if [[ "$G11_HOST_PERFORMANCE" == required && ( -t 0 || -t 1 ) ]]; then
        sudo -- "$G11_HOST_PERFORMANCE_INSTALLER"
        return
    fi
    return 1
}

g11_host_performance_privileged() {
    local command_name=$1 password=${SUDO_PASSWORD:-}
    local helper=$G11_HOST_PERFORMANCE_SYSTEM_HELPER

    if ((EUID == 0)); then
        "$helper" "$command_name"
        return
    fi
    if sudo -n -- "$helper" "$command_name"; then
        return 0
    fi
    if [[ -n "$password" ]]; then
        printf '%s\n' "$password" | sudo -S -p '' -- "$helper" "$command_name"
        return
    fi
    if [[ "$G11_HOST_PERFORMANCE" == required && ( -t 0 || -t 1 ) ]]; then
        sudo -- "$helper" "$command_name"
        return
    fi
    return 1
}

g11_host_performance_apply() {
    local mode=${G11_HOST_PERFORMANCE:-auto}

    if [[ "$mode" == off ]]; then
        G11_HOST_PERFORMANCE_STATUS=off
        return 0
    fi
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        G11_HOST_PERFORMANCE_STATUS=not-applied-dry-run
        return 0
    fi
    if ! g11_host_performance_helper_ready; then
        echo "[g11-performance] 缺少或需要更新 root helper，开始安全安装"
        if ! g11_host_performance_run_installer ||
                ! g11_host_performance_helper_ready; then
            G11_HOST_PERFORMANCE_STATUS=helper-unavailable
            if [[ "$mode" == required ]]; then
                echo "[g11-performance] required 模式无法安装可信 helper" >&2
                return 1
            fi
            echo "[g11-performance] WARN: 本次未改宿主性能策略；运行 ./deploy/scripts/g11-performance.sh apply" >&2
            return 0
        fi
    fi
    if "$G11_HOST_PERFORMANCE_SYSTEM_HELPER" check >/dev/null 2>&1; then
        G11_HOST_PERFORMANCE_STATUS=ready
        "$G11_HOST_PERFORMANCE_SYSTEM_HELPER" audit
        return 0
    fi
    if g11_host_performance_privileged apply; then
        G11_HOST_PERFORMANCE_STATUS=applied
        return 0
    fi
    G11_HOST_PERFORMANCE_STATUS=apply-failed
    if [[ "$mode" == required ]]; then
        echo "[g11-performance] required 模式应用失败" >&2
        return 1
    fi
    echo "[g11-performance] WARN: 性能策略应用失败，VM 继续启动" >&2
    return 0
}

g11_host_performance_restore() {
    g11_host_performance_helper_ready || return 1
    g11_host_performance_privileged restore
}

g11_host_performance_print_plan() {
    printf '  宿主性能: %s / %s（动态全频段、睿频开启、内存原生带宽）\n' \
        "${G11_HOST_PERFORMANCE:-auto}" "$G11_HOST_PERFORMANCE_STATUS"
}


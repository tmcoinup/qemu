#!/usr/bin/env bash
# G-11 explicit VLAN preflight/prepare/cleanup lifecycle.

_G11_VLAN_RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/vlan-network.sh
source "$_G11_VLAN_RUNTIME_DIR/../scripts/lib/vlan-network.sh"
unset _G11_VLAN_RUNTIME_DIR

readonly G11_VLAN_HELPER=/usr/local/libexec/qemu-g11-vlan-tap
readonly G11_VLAN_DOWNSCRIPT=/usr/local/libexec/qemu-g11-vlan-down

g11_vlan_marker_path() {
    local instance="$1" run_dir

    run_dir="$(vm_storage_instance_run_dir "$instance")" || return 1
    printf '%s/vlan-prepared\n' "$run_dir"
}

g11_vlan_marker_status() {
    local marker="$1"

    if [[ ! -e "$marker" && ! -L "$marker" ]]; then
        # The marker belongs to the unprivileged VM bundle, while the helper's
        # crash-intent state is root-only under /run.  SIGKILL can therefore
        # leave state without a marker or TAP.  Treat a trusted runtime-state
        # directory as a conservative cleanup hint; the privileged helper will
        # still validate the exact deterministic instance and state file.
        if [[ -e /run/qemu-g11-vlan || -L /run/qemu-g11-vlan ]]; then
            [[ -d /run/qemu-g11-vlan && ! -L /run/qemu-g11-vlan ]] \
                || return 2
            return 0
        fi
        return 1
    fi
    [[ -f "$marker" && ! -L "$marker" ]] || return 2
    return 0
}

g11_vlan_marker_write() {
    local marker="$1" instance="$2" vid="$3" tap="$4"
    local directory temporary

    directory=${marker%/*}
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    if g11_vlan_marker_status "$marker"; then
        :
    else
        case $? in
            1) ;;
            *)
                echo "[vlan] runtime marker 类型不安全: $marker" >&2
                return 1
                ;;
        esac
    fi
    temporary="$(mktemp "$directory/.vlan-prepared.XXXXXX")" || return 1
    chmod 0600 "$temporary"
    if ! printf 'VERSION=1\nINSTANCE=%s\nVLAN_ID=%s\nTAP=%s\n' \
            "$instance" "$vid" "$tap" >"$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    mv -fT -- "$temporary" "$marker"
}

g11_vlan_marker_clear() {
    local marker="$1"

    if g11_vlan_marker_status "$marker"; then
        rm -f -- "$marker"
        return
    fi
    case $? in
        1) return 0 ;;
        *)
            echo "[vlan] 拒绝删除类型不安全的 runtime marker: $marker" >&2
            return 1
            ;;
    esac
}

g11_vlan_trusted_executable() {
    local path="$1" owner mode

    [[ -f "$path" && -x "$path" && ! -L "$path" ]] || return 1
    owner="$(stat -c '%u' -- "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 1
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#022) == 0 ))
}

g11_vlan_helper_call() {
    if (( EUID == 0 )); then
        "$G11_VLAN_HELPER" "$@"
    else
        /usr/bin/sudo -n -- "$G11_VLAN_HELPER" "$@"
    fi
}

g11_vlan_preflight() {
    local instance="$1" vid="$2" expected_tap="$3" actual

    g11_vlan_trusted_executable "$G11_VLAN_HELPER" || {
        echo "[start-vm] VLAN helper 未安装或权限不安全: $G11_VLAN_HELPER" >&2
        echo "[start-vm] 先运行一键入口: ./deploy/scripts/setup-bridge.sh" >&2
        return 1
    }
    g11_vlan_trusted_executable "$G11_VLAN_DOWNSCRIPT" || {
        echo "[start-vm] VLAN downscript 未安装或权限不安全: $G11_VLAN_DOWNSCRIPT" >&2
        return 1
    }
    actual="$(g11_vlan_helper_call check "$instance" "$vid")" || {
        echo "[start-vm] VLAN $vid 宿主预检失败；VM 未启动" >&2
        return 1
    }
    [[ "$actual" == "$expected_tap" ]] || {
        echo "[start-vm] VLAN helper 返回 '$actual'，期望 '$expected_tap'" >&2
        return 1
    }
}

g11_vlan_prepare() {
    local instance="$1" vid="$2" expected_tap="$3" actual

    actual="$(g11_vlan_helper_call prepare "$instance" "$vid")" || {
        echo "[start-vm] 创建 vm${instance} VLAN $vid TAP 失败" >&2
        return 1
    }
    if [[ "$actual" != "$expected_tap" ]]; then
        echo "[start-vm] VLAN helper 创建 '$actual'，期望 '$expected_tap'" >&2
        g11_vlan_helper_call cleanup-instance "$instance" >/dev/null 2>&1 || true
        return 1
    fi
}

g11_vlan_cleanup_instance() {
    local instance="$1" known="${2:-0}" tap

    tap="$(vlan_tap_name "$instance")" || return 1
    if [[ "$known" != 1 ]] && ! ip link show dev "$tap" >/dev/null 2>&1; then
        # A SIGKILL can leave root-only intent state after the link vanished.
        # The state directory itself is a safe hint; the privileged helper still
        # validates the exact deterministic instance before doing anything.
        [[ -d /run/qemu-g11-vlan && ! -L /run/qemu-g11-vlan ]] || return 0
    fi
    g11_vlan_trusted_executable "$G11_VLAN_HELPER" || {
        echo "[vlan] 检测到 vm${instance} VLAN 状态，但 helper 缺失或权限不安全" >&2
        return 1
    }
    g11_vlan_helper_call cleanup-instance "$instance"
}

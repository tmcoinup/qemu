#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# host-vlan-down.sh —— QEMU TAP downscript 的最小权限包装器
#
# 安装目标：/usr/local/libexec/qemu-stealth-vlan-down（root:root 0755）。
# QEMU 退出时只会把 TAP 接口名作为唯一参数传入。普通 VM 用户不能直接修改
# root 网络，因此本脚本通过 sudo -n 调用固定安装的 helper cleanup-ifname；
# helper 会再次校验 root 配置、调用 UID/GID、TAP 命名和 root-only 状态。
# ---------------------------------------------------------------------------
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly HELPER="/usr/local/libexec/qemu-stealth-vlan-tap"

trusted_helper() {
    local owner mode permissions

    [[ -f "$HELPER" && -x "$HELPER" && ! -L "$HELPER" ]] || return 1
    owner="$(stat -c '%u' -- "$HELPER" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$HELPER" 2>/dev/null)" || return 1
    [[ "$owner" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    permissions=$((8#$mode))
    (( (permissions & 8#022) == 0 ))
}

log_cleanup_failure() {
    local message="$1"

    logger -t qemu-stealth-vlan-down -- "$message" 2>/dev/null || true
}

main() {
    local tap

    if (( $# != 1 )); then
        printf 'ERROR: downscript 只接受一个 TAP 接口名\n' >&2
        return 2
    fi
    tap="$1"
    if ! [[ "$tap" =~ ^svtap[0-9]{1,10}$ ]]; then
        printf 'ERROR: 拒绝清理非 svtap<实例号> 接口: %s\n' "$tap" >&2
        return 2
    fi
    if ! trusted_helper; then
        log_cleanup_failure "helper 未安装或权限不安全，watchdog/stop-vm 需重试清理 $tap"
        return 0
    fi

    if (( EUID == 0 )); then
        if ! "$HELPER" cleanup-ifname "$tap" >/dev/null 2>&1; then
            log_cleanup_failure "QEMU downscript 暂时无法清理 $tap，交由 watchdog 重试"
        fi
        return 0
    fi
    if [[ ! -x /usr/bin/sudo ]]; then
        log_cleanup_failure "缺少 sudo，watchdog/stop-vm 需重试清理 $tap"
        return 0
    fi
    if ! /usr/bin/sudo -n -- "$HELPER" cleanup-ifname "$tap" >/dev/null 2>&1; then
        log_cleanup_failure "QEMU downscript 暂时无法清理 $tap，交由 watchdog 重试"
    fi
    return 0
}

main "$@"

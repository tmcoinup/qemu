#!/usr/bin/env bash
# 验证启动器显式开启 QEMU usb-kbd NumLock 状态机，并彻底移除旧 guest 注册表路径。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CLI="$REPO_ROOT/deploy/scripts/lib/sv-cli.sh"
DEVICES="$REPO_ROOT/deploy/scripts/lib/sv-devices.sh"
PORTABILITY="$REPO_ROOT/deploy/scripts/lib/sv-portability.sh"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
USB_HID="$REPO_ROOT/hw/usb/dev-hid.c"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -F -- '--numlock)' "$CLI" >/dev/null \
    || fail "缺少 --numlock 开关"
grep -F -- '--no-numlock)' "$CLI" >/dev/null \
    || fail "缺少 --no-numlock 开关"
grep -F ': "${GUEST_NUMLOCK:=1}"' "$CLI" >/dev/null \
    || fail "guest NumLock 策略没有默认开启"
grep -F "KBD_NUMLOCK_PROP=',x-force-numlock-on=on'" "$DEVICES" >/dev/null \
    || fail "usb-kbd 参数没有接入 QEMU NumLock 属性"
grep -F '${KBD_NUMLOCK_PROP}' "$DEVICES" >/dev/null \
    || fail "KBD_NUMLOCK_PROP 没有进入最终 -device 参数"
grep -F "_sv_qemu_help_has_all \"\$help\" 'x-force-numlock-on='" \
        "$PORTABILITY" >/dev/null \
    || fail "启动前没有拒绝缺少 NumLock 属性的旧 QEMU"
grep -F "'x-numlock-on-confirmed'" "$PORTABILITY" >/dev/null \
    || fail "启动前没有拒绝仍使用一次性 NumLock 锁存的旧 QEMU"
grep -F 'DEFINE_PROP_BOOL("x-force-numlock-on"' "$USB_HID" >/dev/null \
    || fail "QEMU usb-kbd 缺少 opt-in NumLock 属性"
grep -F '"x-numlock-on-confirmed"' "$USB_HID" >/dev/null \
    || fail "QEMU usb-kbd 缺少持续收敛能力标记"
grep -F 'qemu_bh_new_guarded' "$USB_HID" >/dev/null \
    || fail "NumLock 注入没有使用 guarded BH 避免 USB 重入"

# 旧方案会污染所有用户注册表，或只修改 Linux XKB 而无法影响 VM。两个入口都必须
# 彻底消失；真正的状态判断现在来自 guest HID SET_REPORT。
[[ ! -e "$REPO_ROOT/deploy/scripts/host-fix-numlock.sh" ]] \
    || fail "旧离线注册表 NumLock 修复尚未退休"
[[ ! -e "$REPO_ROOT/deploy/scripts/lib/sv-host-numlock.sh" ]] \
    || fail "无效的 host XKB NumLock 模块尚未移除"
if grep -nEi 'InitialKeyboardIndicators|keybd_event|VK_NUMLOCK' \
        "$REPO_ROOT/deploy/scripts/vm-prep.ps1" \
        "$REPO_ROOT/deploy/scripts/vm-bootstrap.ps1" >&2; then
    fail "guest NumLock 注册表/WinAPI 逻辑尚未移除"
fi
if grep -nF 'host-fix-numlock.sh' \
        "$REPO_ROOT/deploy/scripts/clone-from-base.sh" >&2; then
    fail "克隆流程仍调用旧离线 NumLock 修复"
fi
if grep -nEi 'HOST_NUMLOCK|sv_host_numlock|host-numlock' \
        "$START_VM" "$CLI" "$DEVICES" >&2; then
    fail "启动链仍残留无效的 host XKB NumLock 接线"
fi

echo "OK: QEMU guest NumLock launcher wiring checks passed"

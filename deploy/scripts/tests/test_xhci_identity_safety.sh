#!/usr/bin/env bash
# 验证 qemu-xhci 保持与虚拟寄存器模型匹配的上游 PCI 行为身份。
#
# Windows USBXHCI.SYS 会按 PCI 厂商/设备 ID 选择真实硬件 quirk。把 QEMU
# 控制器伪装成 Intel PCH 会让驱动启用与虚拟寄存器模型不匹配的 workaround。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
XHCI_C="$REPO_ROOT/hw/usb/hcd-xhci-pci.c"
XHCI_H="$REPO_ROOT/hw/usb/hcd-xhci-pci.h"
LINUX_ASSEMBLE="$REPO_ROOT/deploy/scripts/lib/sv-assemble.sh"
LINUX_PREFLIGHT="$REPO_ROOT/deploy/scripts/lib/sv-portability.sh"
WINDOWS_ARGS="$REPO_ROOT/deploy/windows/lib/VMate.Arguments.ps1"
WINDOWS_PREFLIGHT="$REPO_ROOT/deploy/windows/lib/VMate.Preflight.ps1"
QEMU="$REPO_ROOT/build/qemu-system-x86_64"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

reject_pattern() {
    local pattern="$1"
    local message="$2"
    local output status
    shift 2

    set +e
    output="$(rg -n -U "$pattern" "$@" 2>&1)"
    status=$?
    set -e
    case "$status" in
        0) echo "$output"; fail "$message" ;;
        1) return 0 ;;
        *) echo "$output" >&2; fail "rg 扫描失败" ;;
    esac
}

grep -E 'k->vendor_id[[:space:]]*=[[:space:]]*PCI_VENDOR_ID_REDHAT;' \
    "$XHCI_C" >/dev/null \
    || fail "qemu-xhci 没有使用上游 Red Hat vendor ID"
grep -E 'k->device_id[[:space:]]*=[[:space:]]*PCI_DEVICE_ID_REDHAT_XHCI;' \
    "$XHCI_C" >/dev/null \
    || fail "qemu-xhci 没有使用上游设备 ID"
grep -F 'k->revision            = 0x01;' "$XHCI_C" >/dev/null \
    || fail "qemu-xhci 没有使用上游 revision"
grep -F 'k->subsystem_vendor_id = PCI_SUBVENDOR_ID_REDHAT_QUMRANET;' \
    "$XHCI_C" >/dev/null || fail "qemu-xhci 没有固定上游 subsystem vendor"
grep -F 'k->subsystem_id        = PCI_SUBDEVICE_ID_QEMU;' "$XHCI_C" >/dev/null \
    || fail "qemu-xhci 没有固定上游 subsystem device"

reject_pattern \
    'stealth_(vendor|device|revision)|DEFINE_PROP_UINT32\("x-pci-' \
    "qemu-xhci 仍允许覆盖行为相关的 PCI ID" \
    "$XHCI_C" "$XHCI_H"

grep -F -- '-device "qemu-xhci,id=xhci,bus=rp3"' "$LINUX_ASSEMBLE" >/dev/null \
    || fail "Linux 启动器没有固定安全的 qemu-xhci 参数"
grep -F -- "'-device', 'qemu-xhci,id=xhci,bus=rp3'" "$WINDOWS_ARGS" >/dev/null \
    || fail "Windows 启动器没有固定安全的 qemu-xhci 参数"

reject_pattern \
    "qemu-xhci[^\\n]*(x-pci-vendor-id|x-pci-device-id|x-pci-revision)" \
    "启动或能力门禁仍会投影 xHCI 平台 PCI ID" \
    "$LINUX_ASSEMBLE" "$LINUX_PREFLIGHT" "$WINDOWS_ARGS" "$WINDOWS_PREFLIGHT"

[[ -x "$QEMU" ]] || fail "缺少已构建 QEMU: $QEMU"
help="$("$QEMU" -device qemu-xhci,help 2>&1)"
if grep -E 'x-pci-(vendor-id|device-id|revision)=' <<<"$help" >/dev/null; then
    fail "已构建 QEMU 仍暴露危险的 xHCI PCI ID 覆盖属性"
fi

# Linux 启动器会用环境变量改写没有自有 subsystem 的 PCI 默认值。直接给
# qemu-xhci 注入 ASUS 主板默认值并查询真实配置空间，验证它仍固定为上游
# 1B36:000D rev01 / SUBSYS 1AF4:1100，而不是只在源码文本中看起来正确。
python3 - "$QEMU" <<'PY'
import json
import os
import subprocess
import sys

qemu = sys.argv[1]
environment = os.environ.copy()
environment["QEMU_PCI_SUBSYS_VEN"] = "0x1043"
environment["QEMU_PCI_SUBSYS_DEV"] = "0x8694"
request = "\n".join([
    '{"execute":"qmp_capabilities"}',
    '{"execute":"query-pci"}',
    '{"execute":"quit"}',
    "",
])
result = subprocess.run(
    [
        qemu, "-machine", "q35,accel=tcg", "-display", "none",
        "-nodefaults", "-S", "-device",
        "qemu-xhci,id=xhci,bus=pcie.0,addr=0x4", "-qmp", "stdio",
    ],
    input=request,
    text=True,
    capture_output=True,
    timeout=15,
    check=False,
    env=environment,
)
if result.returncode != 0:
    raise SystemExit(f"qemu-xhci QMP 启动失败:\n{result.stderr}")

responses = []
for line in result.stdout.splitlines():
    try:
        responses.append(json.loads(line))
    except json.JSONDecodeError:
        continue
pci_reply = next(
    item["return"] for item in responses
    if isinstance(item.get("return"), list)
)
identity = next(
    device["id"]
    for bus in pci_reply
    for device in bus["devices"]
    if device.get("qdev_id") == "xhci"
)
actual = (
    identity["vendor"],
    identity["device"],
    identity["subsystem-vendor"],
    identity["subsystem"],
)
expected = (0x1B36, 0x000D, 0x1AF4, 0x1100)
if actual != expected:
    raise SystemExit(
        f"qemu-xhci 完整 PCI 身份错误: {actual!r} != {expected!r}"
    )
PY

echo "OK: qemu-xhci behavior identity is fixed to upstream 1B36:000D / SUBSYS 1AF4:1100"

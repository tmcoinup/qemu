#!/usr/bin/env bash
# 确保 respawn-stealth 不覆盖 Host/QEMU 已选择的多品牌显示器 EDID。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REFRESH="$REPO_ROOT/deploy/scripts/refresh-gpu-name.ps1"
APPLY="$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1"
BUILD="$REPO_ROOT/deploy/guest-stealth/build-exe.sh"
COMPONENTS="$REPO_ROOT/deploy/hardware/components.json"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for path in "$REFRESH" "$APPLY" "$BUILD" "$COMPONENTS"; do
    [[ -f "$path" ]] || fail "缺少测试输入: $path"
done

python3 - "$REFRESH" "$COMPONENTS" <<'PY'
import json
import sys
from pathlib import Path

refresh = Path(sys.argv[1]).read_text(encoding="utf-8-sig")
components = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
code = "\n".join(
    line for line in refresh.splitlines()
    if not line.lstrip().startswith("#")
)
for forbidden in (
    "Samsung S24F350F",
    "MONITOR\\SAM0F65",
    "Enum\\DISPLAY",
    "{4d36e96e-e325-11ce-bfc1-08002be10318}",
    "$monitorName",
    "$monitorMfg",
    "$monitorHwId",
):
    if forbidden in code:
        raise SystemExit(
            f"refresh-gpu-name.ps1 仍会接管显示器身份: {forbidden}"
        )

expected = {
    "samsung-s24f350",
    "aoc-24b2xh",
    "xiaomi-rmmnt238nf",
    "lenovo-l24e-30",
}
monitors = {
    item["id"]: item
    for item in components["monitors"]
    if item.get("enabled") is True
}
if set(monitors) != expected:
    raise SystemExit("受控显示器目录不是预期的四品牌集合")
for monitor in monitors.values():
    native = monitor.get("native_resolution", {})
    if native != {"x": 1920, "y": 1080, "aspect_ratio": "16:9"}:
        raise SystemExit(f"{monitor['id']} 不是 1920x1080、16:9")
PY

grep -F '显示器身份只能来自 Host profile 注入的 QEMU EDID' \
    "$REFRESH" >/dev/null ||
    fail "refresh helper 没有声明 EDID 单一事实源"
grep -F 'Host profile → QEMU EDID → Windows PnP 唯一负责' \
    "$APPLY" >/dev/null ||
    fail "apply 流程没有声明显示器身份所有权边界"
grep -F 'REFRESH_HELPER_SRC="$REPO_ROOT/deploy/scripts/refresh-gpu-name.ps1"' \
    "$BUILD" >/dev/null ||
    fail "respawn-stealth 构建没有绑定 refresh helper 真源"
grep -F 'payload_refresh_gpu_name_ps1' "$BUILD" >/dev/null ||
    fail "respawn-stealth 没有内嵌 refresh helper"

echo "PASS: respawn-stealth preserves Host/QEMU multi-brand monitor EDID"

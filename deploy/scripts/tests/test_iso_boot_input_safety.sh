#!/usr/bin/env bash
# 验证 ISO 启动链不会通过固定延时向 guest 盲注入按键。
#
# Windows Setup 会把空格解释为激活当前按钮或切换当前选项。启动器曾在开机后
# 连续发送空格来碰撞光盘启动提示；一旦 Setup 已经显示，这些按键就会让页面和
# 控件持续自动跳转。启动脚本只负责设备与启动顺序，交互输入必须来自用户。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

startup_files=("$SCRIPTS_DIR/start-vm.sh")
while IFS= read -r file; do
    startup_files+=("$file")
done < <(rg --files "$SCRIPTS_DIR/lib" -g 'sv-*.sh' | sort)

if rg -n -i \
    'sendkey[[:space:]]|send-key|input-send-event|_AUTO_KEY_PID' \
    "${startup_files[@]}"; then
    fail "启动链仍包含隐式 guest 按键注入"
fi

grep -F \
    'input safety: 不自动注入按键；看到光盘启动提示后手动按一次空格' \
    "$SCRIPTS_DIR/lib/sv-assemble.sh" >/dev/null \
    || fail "ISO 启动缺少输入安全提示"

echo "OK: ISO boot never injects delayed guest keyboard input"

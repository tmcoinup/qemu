#!/usr/bin/env bash
# 独立验证 host-performance 的 PPD 启动顺序与无 PPD 兼容路径，不写真实 sysfs。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOST_PERF="$REPO_ROOT/deploy/scripts/host-performance.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fake_bin="$tmp/fake-bin"
empty_bin="$tmp/empty-bin"
event_log="$tmp/events.log"
function_file="$tmp/ppd-function.sh"
mkdir -p "$fake_bin" "$empty_bin"

# 只提取生产脚本中的纯 PPD 协调函数。这样测试能模拟 systemctl/CLI 失败，而不会以
# root 身份触碰真实 /proc、/sys；函数结束的单独右花括号是稳定的提取边界。
awk '
    /^_vmate_set_ppd_performance\(\) \{/ { copying = 1 }
    copying { print }
    copying && /^}$/ { exit }
' "$HOST_PERF" > "$function_file"
grep -F '_vmate_set_ppd_performance() {' "$function_file" >/dev/null \
    || fail "无法提取 PPD 协调函数"
# shellcheck disable=SC1090 # 测试刻意 source 从生产脚本提取到临时目录的函数。
source "$function_file"

cat > "$fake_bin/systemctl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >> "${VMATE_PPD_TEST_LOG:?}"
case "${1:-}" in
    start) exit "${VMATE_PPD_START_RC:-0}" ;;
    is-active) exit "${VMATE_PPD_ACTIVE_RC:-0}" ;;
    *) exit 90 ;;
esac
EOF

cat > "$fake_bin/powerprofilesctl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'powerprofilesctl %s\n' "$*" >> "${VMATE_PPD_TEST_LOG:?}"
case "${1:-}" in
    set)
        [[ "${2:-}" == "performance" ]] || exit 91
        exit "${VMATE_PPD_SET_RC:-0}"
        ;;
    get)
        (( ${VMATE_PPD_GET_RC:-0} == 0 )) || exit "${VMATE_PPD_GET_RC}"
        printf '%s\n' "${VMATE_PPD_PROFILE:-performance}"
        ;;
    *) exit 92 ;;
esac
EOF
chmod 0755 "$fake_bin/systemctl" "$fake_bin/powerprofilesctl"

run_case() {
    local name="$1" path="$2" start_rc="$3" active_rc="$4" set_rc="$5"
    local get_rc="$6" profile="$7" output="$tmp/$name.out"

    : > "$event_log"
    if ! (
        set -euo pipefail
        PATH="$path"
        export PATH
        VMATE_PPD_TEST_LOG="$event_log"
        VMATE_PPD_START_RC="$start_rc"
        VMATE_PPD_ACTIVE_RC="$active_rc"
        VMATE_PPD_SET_RC="$set_rc"
        VMATE_PPD_GET_RC="$get_rc"
        VMATE_PPD_PROFILE="$profile"
        export VMATE_PPD_TEST_LOG VMATE_PPD_START_RC VMATE_PPD_ACTIVE_RC
        export VMATE_PPD_SET_RC VMATE_PPD_GET_RC VMATE_PPD_PROFILE
        _vmate_set_ppd_performance
    ) > "$output" 2>&1; then
        fail "$name 不应阻断后续 sysfs fallback"
    fi
}

run_case success "$fake_bin" 0 0 0 0 performance
expected_success=$'systemctl start power-profiles-daemon.service\nsystemctl is-active --quiet power-profiles-daemon.service\npowerprofilesctl set performance\npowerprofilesctl get'
[[ "$(<"$event_log")" == "$expected_success" ]] \
    || fail "成功路径没有按 start→active→set→get 执行"
grep -F 'performance（daemon 已同步）' "$tmp/success.out" >/dev/null \
    || fail "成功路径缺少 profile 确认"

run_case start_fail "$fake_bin" 23 0 0 0 performance
[[ "$(<"$event_log")" == 'systemctl start power-profiles-daemon.service' ]] \
    || fail "daemon 启动失败后仍调用了 profile CLI"
grep -F '无法启动 power-profiles-daemon' "$tmp/start_fail.out" >/dev/null \
    || fail "daemon 启动失败缺少明确告警"

run_case set_fail "$fake_bin" 0 0 24 0 performance
grep -F 'powerprofilesctl set performance' "$event_log" >/dev/null \
    || fail "未尝试设置 performance profile"
! grep -Fx 'powerprofilesctl get' "$event_log" >/dev/null \
    || fail "profile 设置失败后不应伪装成可复核"
grep -F '无法切换到 performance' "$tmp/set_fail.out" >/dev/null \
    || fail "profile 设置失败缺少明确告警"

run_case verify_mismatch "$fake_bin" 0 0 0 0 balanced
grep -F '切换后仍为 balanced' "$tmp/verify_mismatch.out" >/dev/null \
    || fail "profile 复核不一致缺少明确告警"

run_case no_ppd "$empty_bin" 0 0 0 0 performance
[[ ! -s "$event_log" ]] || fail "无 PPD 主机不应调用任何外部控制工具"
grep -F 'PPD 工具未安装' "$tmp/no_ppd.out" >/dev/null \
    || fail "无 PPD 兼容路径缺少状态说明"

# 除函数行为外，再锁定生产调用顺序：必须在任何 governor/frequency sysfs 操作之前。
ppd_call_line="$(grep -n '^_vmate_set_ppd_performance$' "$HOST_PERF" | cut -d: -f1)"
governor_line="$(grep -n '^_gov_changed=0$' "$HOST_PERF" | cut -d: -f1)"
[[ "$ppd_call_line" =~ ^[0-9]+$ && "$governor_line" =~ ^[0-9]+$ ]] \
    || fail "无法定位 PPD/governor 调用顺序"
(( ppd_call_line < governor_line )) \
    || fail "PPD profile 必须先于 sysfs governor 设置"

echo "PASS: host performance PPD ordering and fallback"

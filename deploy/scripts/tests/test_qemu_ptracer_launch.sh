#!/usr/bin/env bash
# 验证 DGame 内存授权始终紧贴 QEMU 叶节点，并保持带空格 argv 的逐项边界。
# shellcheck disable=SC1090,SC2016,SC2030,SC2031,SC2034,SC2329
# 动态 source、subshell 隔离、nameref 断言和生成脚本文本均为测试刻意行为。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PTRACER_MODULE="$REPO_ROOT/deploy/scripts/lib/sv-qemu-ptracer.sh"
DISPLAY_GUARD="$REPO_ROOT/deploy/scripts/lib/sv-display-guard.sh"
BUILTIN_WRAPPER="$REPO_ROOT/deploy/scripts/qemu-ptracer-wrapper.py"
TEST_WORK="$(mktemp -d)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cleanup() {
    rm -rf "$TEST_WORK"
}
trap cleanup EXIT

make_executable() {
    chmod +x "$@"
}

assert_array_equals() {
    local expected_name="$1" actual_name="$2" label="$3"
    local -n expected_ref="$expected_name"
    local -n actual_ref="$actual_name"
    local index

    (( ${#expected_ref[@]} == ${#actual_ref[@]} )) \
        || fail "$label 长度不符: expected=${#expected_ref[@]} actual=${#actual_ref[@]}"
    for index in "${!expected_ref[@]}"; do
        [[ "${expected_ref[$index]}" == "${actual_ref[$index]}" ]] \
            || fail "$label 第 $index 项不符: expected=${expected_ref[$index]} actual=${actual_ref[$index]}"
    done
}

read_nul_array() {
    local output_name="$1" path="$2"
    local -n output_ref="$output_name"
    mapfile -d '' -t output_ref <"$path"
}

test_explicit_wrapper_preserves_qemu_argv() {
    local case_dir="$TEST_WORK/explicit" wrapper
    local -a expected=()

    mkdir -p "$case_dir"
    wrapper="$case_dir/dgame ptracer"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$wrapper"
    make_executable "$wrapper"

    (
        HERE="$case_dir"
        DGAME_QEMU_PTRACER="$wrapper"
        source "$PTRACER_MODULE"
        sv_qemu_ptracer_build_leaf_command "/opt/QEMU build/qemu-system-x86_64" \
            -name "win10 instance 1" -m 8192
        printf '%s\0' "${QEMU_LEAF_CMD[@]}" >"$case_dir/argv"
    )

    local -a actual=()
    read_nul_array actual "$case_dir/argv"
    expected=("$wrapper" -- "/opt/QEMU build/qemu-system-x86_64" \
        -name "win10 instance 1" -m 8192)
    assert_array_equals expected actual "显式 wrapper 叶命令"
}

test_packaged_wrapper_is_automatic() {
    local case_dir="$TEST_WORK/package"
    local -a expected=() actual=()

    mkdir -p "$case_dir"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$case_dir/dgame_qemu_ptracer"
    make_executable "$case_dir/dgame_qemu_ptracer"

    (
        HERE="$case_dir"
        unset DGAME_QEMU_PTRACER
        source "$PTRACER_MODULE"
        sv_qemu_ptracer_build_leaf_command fake-qemu -name vm-2
        printf '%s\0' "${QEMU_LEAF_CMD[@]}" >"$case_dir/argv"
    )

    read_nul_array actual "$case_dir/argv"
    expected=("$case_dir/dgame_qemu_ptracer" -- fake-qemu -name vm-2)
    assert_array_equals expected actual "包内 wrapper 自动选择"
}

test_builtin_python_wrapper_is_zero_config_fallback() {
    local case_dir="$TEST_WORK/python-wrapper"
    local -a expected=() actual=()

    [[ -x /usr/bin/python3 ]] || fail "宿主依赖 /usr/bin/python3 不存在"
    [[ -f "$BUILTIN_WRAPPER" ]] || fail "内置 Python wrapper 不存在"
    mkdir -p "$case_dir"

    (
        HERE="$REPO_ROOT/deploy/scripts"
        PATH="/usr/bin:/bin"
        unset DGAME_QEMU_PTRACER
        source "$PTRACER_MODULE"
        sv_qemu_ptracer_build_leaf_command fake-qemu -name vm-3
        printf '%s\0' "${QEMU_LEAF_CMD[@]}" >"$case_dir/argv"
    )

    read_nul_array actual "$case_dir/argv"
    expected=(/usr/bin/python3 "$BUILTIN_WRAPPER" -- fake-qemu -name vm-3)
    assert_array_equals expected actual "内置 Python wrapper 零配置回退"
}

test_builtin_wrapper_exec_preserves_pid_and_argv() {
    local case_dir="$TEST_WORK/python-exec" wrapper_pid qemu_pid
    local fake_qemu="$TEST_WORK/python-exec/fake qemu"
    local -a actual=() expected=("argument with spaces" --literal)

    mkdir -p "$case_dir"
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf '\''%s\n'\'' "$$" >"$QEMU_PID_LOG"' \
        'printf '\''%s\0'\'' "$@" >"$QEMU_ARG_LOG"' >"$fake_qemu"
    make_executable "$fake_qemu"

    QEMU_PID_LOG="$case_dir/pid" QEMU_ARG_LOG="$case_dir/argv" \
        /usr/bin/python3 "$BUILTIN_WRAPPER" -- "$fake_qemu" \
        "argument with spaces" --literal &
    wrapper_pid=$!
    wait "$wrapper_pid"
    qemu_pid="$(<"$case_dir/pid")"
    [[ "$qemu_pid" == "$wrapper_pid" ]] \
        || fail "内置 wrapper 未原地 exec QEMU: wrapper=$wrapper_pid qemu=$qemu_pid"
    read_nul_array actual "$case_dir/argv"
    assert_array_equals expected actual "内置 wrapper exec argv"
}

test_yama_scope_policy_is_fail_closed() {
    (
        HERE="$TEST_WORK/yama"
        source "$PTRACER_MODULE"
        sv_qemu_ptracer_validate_yama_scope 0
        sv_qemu_ptracer_validate_yama_scope 1
        ! sv_qemu_ptracer_validate_yama_scope 2
        ! sv_qemu_ptracer_validate_yama_scope 3
        ! sv_qemu_ptracer_validate_yama_scope invalid
    ) >/dev/null 2>&1 || fail "Yama scope 0/1 允许、2/3/非法拒绝策略错误"
}

test_invalid_override_and_daemonize_fail_closed() {
    local case_dir="$TEST_WORK/fail-closed"
    mkdir -p "$case_dir"

    if (
        HERE="$case_dir"
        DGAME_QEMU_PTRACER="$case_dir/missing"
        source "$PTRACER_MODULE"
        sv_qemu_ptracer_build_leaf_command fake-qemu
    ) >/dev/null 2>&1; then
        fail "不可执行的显式 wrapper 未阻止启动"
    fi

    if (
        HERE="$case_dir"
        printf '#!/usr/bin/env bash\nexit 0\n' >"$case_dir/wrapper"
        chmod +x "$case_dir/wrapper"
        DGAME_QEMU_PTRACER="$case_dir/wrapper"
        source "$PTRACER_MODULE"
        sv_qemu_ptracer_build_leaf_command fake-qemu -name valid
        ! sv_qemu_ptracer_build_leaf_command fake-qemu -daemonize
        (( ${#QEMU_LEAF_CMD[@]} == 0 ))
        (( ${#SV_QEMU_PTRACER_PREFIX[@]} == 0 ))
        [[ "$SV_QEMU_PTRACER_READY" == "0" ]]
    ) >/dev/null 2>&1; then
        :
    else
        fail "-daemonize 未阻止启动或失败后保留了陈旧叶命令"
    fi
}

test_display_inhibitors_remain_outside_leaf_wrapper() {
    local case_dir="$TEST_WORK/integration" bin_dir="$TEST_WORK/integration/bin"
    local wrapper="$TEST_WORK/integration/bin/dgame_qemu_ptracer"
    local -a gnome_args=() inhibit_args=() wrapper_args=() qemu_args=() expected=()

    mkdir -p "$bin_dir"
    apply_test_fixtures "$bin_dir"

    (
        export PATH="$bin_dir:/usr/bin:/bin"
        export GNOME_LOG="$case_dir/gnome.args"
        export INHIBIT_LOG="$case_dir/inhibit.args"
        export WRAPPER_LOG="$case_dir/wrapper.args"
        export QEMU_LOG="$case_dir/qemu.args"
        export SDL=1 HEADLESS=0 DISPLAY=:test INSTANCE=7
        export XDG_CURRENT_DESKTOP=GNOME DBUS_SESSION_BUS_ADDRESS=mock-session
        export SV_CPU_STRICT_SUPERVISION_READY=0
        export CPU_ISOLATE=0 STRICT_HARDWARE=1 DGAME_QEMU_PTRACER="$wrapper"
        HERE="$case_dir"
        source "$PTRACER_MODULE"
        source "$DISPLAY_GUARD"
        sv_dock_integrate() { :; }
        sv_qemu_ptracer_build_leaf_command fake-qemu -name "win10 instance 7"
        sv_display_guard_launch "${QEMU_LEAF_CMD[@]}"
    )

    read_nul_array gnome_args "$case_dir/gnome.args"
    read_nul_array inhibit_args "$case_dir/inhibit.args"
    read_nul_array wrapper_args "$case_dir/wrapper.args"
    read_nul_array qemu_args "$case_dir/qemu.args"

    expected=(--app-id qemu-stealth-7 --reason "保持 guest 显示活性" \
        --inhibit idle:logout systemd-inhibit \
        --who=qemu-stealth-7 "--why=保持 guest 显示活性" \
        --what=idle:sleep:handle-lid-switch --mode=block -- \
        "$wrapper" -- fake-qemu -name "win10 instance 7")
    assert_array_equals expected gnome_args "GNOME inhibit 最外层顺序"
    expected=(--who=qemu-stealth-7 "--why=保持 guest 显示活性" \
        --what=idle:sleep:handle-lid-switch --mode=block -- \
        "$wrapper" -- fake-qemu -name "win10 instance 7")
    assert_array_equals expected inhibit_args "systemd inhibit 外层顺序"
    expected=(-- fake-qemu -name "win10 instance 7")
    assert_array_equals expected wrapper_args "wrapper 直接接收 QEMU"
    expected=(-name "win10 instance 7")
    assert_array_equals expected qemu_args "QEMU 原始参数"
}

apply_test_fixtures() {
    local bin_dir="$1"

    # xset 探测失败可避免测试修改真实桌面；display guard 仍会组装 inhibit 链。
    printf '#!/usr/bin/env bash\nexit 1\n' >"$bin_dir/xset"
    printf '%s\n' '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'printf '\''%s\0'\'' "$@" >"$GNOME_LOG"' \
        'while (( $# )) && [[ "$1" != "systemd-inhibit" ]]; do shift; done' \
        'exec "$@"' >"$bin_dir/gnome-session-inhibit"
    printf '%s\n' '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'printf '\''%s\0'\'' "$@" >"$INHIBIT_LOG"' \
        'while (( $# )) && [[ "$1" != "--" ]]; do shift; done' \
        '(( $# )) && shift' \
        'exec "$@"' >"$bin_dir/systemd-inhibit"
    printf '%s\n' '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'printf '\''%s\0'\'' "$@" >"$WRAPPER_LOG"' \
        '[[ "${1:-}" == "--" ]] && shift' \
        'exec "$@"' >"$bin_dir/dgame_qemu_ptracer"
    printf '%s\n' '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'printf '\''%s\0'\'' "$@" >"$QEMU_LOG"' >"$bin_dir/fake-qemu"
    make_executable "$bin_dir/xset" "$bin_dir/gnome-session-inhibit" \
        "$bin_dir/systemd-inhibit" \
        "$bin_dir/dgame_qemu_ptracer" "$bin_dir/fake-qemu"
}

test_preflight_is_before_runtime_side_effect_modules() {
    local launcher="$REPO_ROOT/deploy/scripts/start-vm.sh"
    local preflight_line host_helpers_line

    preflight_line="$(grep -n '^[[:space:]]*sv_qemu_ptracer_preflight' "$launcher" | cut -d: -f1)"
    host_helpers_line="$(grep -n 'source .*sv-host-helpers\.sh' "$launcher" | cut -d: -f1)"
    [[ "$preflight_line" =~ ^[0-9]+$ && "$host_helpers_line" =~ ^[0-9]+$ ]] \
        || fail "无法定位 ptracer preflight/host helper source 顺序"
    (( preflight_line < host_helpers_line )) \
        || fail "ptracer preflight 晚于会进入运行期副作用的模块"
}

test_explicit_wrapper_preserves_qemu_argv
test_packaged_wrapper_is_automatic
test_builtin_python_wrapper_is_zero_config_fallback
test_builtin_wrapper_exec_preserves_pid_and_argv
test_yama_scope_policy_is_fail_closed
test_invalid_override_and_daemonize_fail_closed
test_display_inhibitors_remain_outside_leaf_wrapper
test_preflight_is_before_runtime_side_effect_modules

echo "PASS: QEMU ptracer leaf launch"

#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
# SC2034: 全局契约变量由 source 的生产函数读取。
# SC2317: 同名函数是运行时覆写的 mock，由生产编排函数间接调用。
# ---------------------------------------------------------------------------
# start-vm VLAN 宿主交互式一次初始化回归测试。
#
# 测试只 source 预检库，并覆写其可测试边界函数：不调用 sudo、
# setup-bridge.sh 或真实网络命令。文件计数器代替全局变量，即使生产
# 实现在命令替换/子 shell 中调用 mock，调用次数也不会丢失。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RUNTIME_LIB="$REPO_ROOT/deploy/scripts/lib/sv-vlan-preflight.sh"
SELF="$SCRIPT_DIR/test_start_vm_vlan_autosetup.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_trace_contains() {
    local trace="$1" needle="$2" message="$3"

    grep -F -- "$needle" "$trace" >/dev/null || fail "$message（缺少: $needle）"
}

assert_trace_not_contains() {
    local trace="$1" needle="$2" message="$3"

    if grep -F -- "$needle" "$trace" >/dev/null; then
        fail "$message（不应出现: $needle）"
    fi
}

trace_count() {
    local trace="$1" prefix="$2"

    awk -v prefix="$prefix" 'index($0, prefix) == 1 { count++ }
        END { print count + 0 }' "$trace"
}

counter_next() {
    local counter="$1"
    local value=0

    [[ ! -s "$counter" ]] || read -r value <"$counter"
    value=$((value + 1))
    printf '%s\n' "$value" >"$counter"
    printf '%s\n' "$value"
}

# 独立子进程专用的 can_offer 探针。调用方可通过重定向或 pseudo-TTY
# 精确控制终端属性，并用 PROBE_CAN_OFFER_EXPECT 声明预期。
run_can_offer_probe() {
    local actual=denied

    HERE="$REPO_ROOT/deploy/scripts"
    INSTANCE=9980
    VLAN_ID=11
    VLAN_TAP_IF=svtap9980
    # shellcheck disable=SC1090
    source "$RUNTIME_LIB"

    sv_vlan_can_offer_setup && actual=allowed
    [[ "$actual" == "${PROBE_CAN_OFFER_EXPECT:-denied}" ]]
}

if [[ "${1:-}" == "--probe-can-offer" ]]; then
    run_can_offer_probe
    exit $?
fi

# 以文件记录 preflight_once 次数。第一次固定失败，第二次可由
# MOCK_RECHECK_RESULT 决定，用于验证 setup 后只复检一次。
mock_preflight_once() {
    local call

    call="$(counter_next "$CASE_COUNTER")"
    printf 'preflight_once %s\n' "$call" >>"$CASE_TRACE"
    if [[ "$call" == "1" ]]; then
        return 1
    fi
    [[ "${MOCK_RECHECK_RESULT:-success}" == "success" ]]
}

mock_setup_required() {
    printf 'setup_required\n' >>"$CASE_TRACE"
    return 0
}

mock_detect_uplink() {
    printf 'detect_uplink\n' >>"$CASE_TRACE"
    printf '%s\n' "${MOCK_UPLINK:-enp5s0}"
}

mock_read_answer() {
    printf 'read_answer %s\n' "${MOCK_ANSWER:-}" >>"$CASE_TRACE"
    [[ "${MOCK_ANSWER:-}" == "SETUP ${MOCK_UPLINK:-enp5s0}" ]]
}

mock_run_setup() {
    local uplink="${1:-}"

    printf 'run_setup %s\n' "$uplink" >>"$CASE_TRACE"
    return 0
}

test_real_noninteractive_gate() {
    local out="$1"

    # setsid 移除控制终端，确保即使人工在终端执行本测试，
    # 子进程也无法通过 /dev/tty 意外获得交互权限。
    command -v setsid >/dev/null 2>&1 || fail "非交互门禁测试需要 setsid"
    if ! PROBE_CAN_OFFER_EXPECT=denied DRY_RUN=0 \
        setsid -fw bash "$SELF" --probe-can-offer \
        </dev/null >"$out" 2>&1; then
        fail "非 TTY 环境仍允许自动执行 setup"
    fi
}

test_real_dry_run_gate() {
    local out="$1"
    local command_line

    command -v script >/dev/null 2>&1 \
        || fail "测试 DRY_RUN 交互门禁需要 util-linux script"
    printf -v command_line \
        'exec env PROBE_CAN_OFFER_EXPECT=denied DRY_RUN=1 bash %q --probe-can-offer' "$SELF"

    # pseudo-TTY 排除“因为非交互才拒绝”的假阳性；即使有终端，
    # DRY_RUN=1 也必须禁止会改宿主网络的初始化选项。
    if ! env -u CI -u SSH_CONNECTION -u SSH_CLIENT -u SSH_TTY \
        script -qefc "$command_line" /dev/null >"$out" 2>&1; then
        fail "DRY_RUN 在交互终端中仍允许自动 setup"
    fi
}

test_real_ssh_gate() {
    local out="$1"
    local command_line

    # SSH 会话默认拒绝网络迁移；只有管理员显式允许时才能进入
    # 同一个完整文本确认流程，仍不会无提示执行 setup。
    printf -v command_line \
        'exec env PROBE_CAN_OFFER_EXPECT=denied DRY_RUN=0 SSH_CONNECTION=198.51.100.10 bash %q --probe-can-offer' \
        "$SELF"
    if ! env -u CI -u VLAN_SETUP_ALLOW_SSH \
        script -qefc "$command_line" /dev/null >"$out" 2>&1; then
        fail "SSH 会话未显式允许时仍 offer setup"
    fi

    printf -v command_line \
        'exec env PROBE_CAN_OFFER_EXPECT=allowed DRY_RUN=0 SSH_CONNECTION=198.51.100.10 VLAN_SETUP_ALLOW_SSH=1 bash %q --probe-can-offer' \
        "$SELF"
    if ! env -u CI script -qefc "$command_line" /dev/null >"$out" 2>&1; then
        fail "VLAN_SETUP_ALLOW_SSH=1 未允许 SSH 进入确认流程"
    fi
}

test_malicious_uplink_names_are_rejected() {
    local candidate

    # 这些值在命令执行前就必须被纯校验拒绝：保留设备名、路径、
    # 换行注入、超过 IFNAMSIZ 的名称以及项目内部 TAP 前缀都不可用作上联。
    for candidate in "" lo br0 svtap1 tap9 vnet3 '../enp5s0' 'bad/name' \
        $'enp5s0\nUPLINK=x' 'interface-name-too-long'; do
        if sv_vlan_candidate_valid "$candidate" >/dev/null 2>&1; then
            fail "恶意/保留上联名被接受: '$candidate'"
        fi
    done
}

test_explicit_uplink_is_still_validated() {
    local actual

    actual="$(
        VLAN_SETUP_UPLINK=enp7s0
        sv_vlan_candidate_is_physical() { [[ "${1:-}" == "enp7s0" ]]; }
        sv_vlan_detect_uplink
    )" || fail "合法显式 VLAN_SETUP_UPLINK 被拒绝"
    [[ "$actual" == "enp7s0" ]] || fail "显式上联候选未原样返回"

    if (
        VLAN_SETUP_UPLINK='veth-unsafe'
        sv_vlan_candidate_is_physical() { return 1; }
        sv_vlan_detect_uplink >/dev/null 2>&1
    ); then
        fail "显式 VLAN_SETUP_UPLINK 绕过了安全校验"
    fi
}

test_noninteractive_preflight_does_not_setup() {
    local trace="$1" counter="$2"

    : >"$trace"
    : >"$counter"
    if (
        CASE_TRACE="$trace"
        CASE_COUNTER="$counter"
        DRY_RUN=0
        sv_vlan_preflight_once() { mock_preflight_once; }
        sv_vlan_setup_required() { mock_setup_required; }
        sv_vlan_can_offer_setup() { return 1; }
        sv_vlan_detect_uplink() { mock_detect_uplink; }
        sv_vlan_read_answer() { mock_read_answer; }
        sv_vlan_run_setup() { mock_run_setup "$@"; }
        sv_vlan_preflight >/dev/null 2>&1
    ); then
        fail "非交互且宿主未初始化时 preflight 不应成功"
    fi

    [[ "$(trace_count "$trace" "preflight_once ")" == "1" ]] \
        || fail "非交互分支不应额外复检"
    assert_trace_not_contains "$trace" "run_setup " \
        "非交互分支执行了 setup"
}

test_rejected_offer_does_not_setup() {
    local trace="$1" counter="$2"
    local answer

    # y/yes 与大小写不精确的指令都必须取消，避免误触物理网络迁移。
    for answer in y yes YES "setup enp5s0" "SETUP enp6s0"; do
        : >"$trace"
        : >"$counter"
        if (
            CASE_TRACE="$trace"
            CASE_COUNTER="$counter"
            DRY_RUN=0
            MOCK_ANSWER="$answer"
            sv_vlan_preflight_once() { mock_preflight_once; }
            sv_vlan_setup_required() { mock_setup_required; }
            sv_vlan_can_offer_setup() { return 0; }
            sv_vlan_detect_uplink() { mock_detect_uplink; }
            sv_vlan_uplink_has_native_conflict() { return 1; }
            sv_vlan_read_answer() { mock_read_answer; }
            sv_vlan_run_setup() { mock_run_setup "$@"; }
            sv_vlan_preflight >/dev/null 2>&1
        ); then
            fail "非精确确认 '$answer' 被错误接受"
        fi
        assert_trace_not_contains "$trace" "run_setup " \
            "非精确确认 '$answer' 仍执行 setup"
    done
}

test_confirm_runs_once_detects_uplink_and_rechecks() {
    local trace="$1" counter="$2"

    : >"$trace"
    : >"$counter"
    if ! (
        CASE_TRACE="$trace"
        CASE_COUNTER="$counter"
        DRY_RUN=0
        MOCK_RECHECK_RESULT=success
        MOCK_UPLINK=enp5s0
        MOCK_ANSWER="SETUP enp5s0"
        sv_vlan_preflight_once() { mock_preflight_once; }
        sv_vlan_setup_required() { mock_setup_required; }
        sv_vlan_can_offer_setup() { return 0; }
        sv_vlan_detect_uplink() { mock_detect_uplink; }
        sv_vlan_uplink_has_native_conflict() { return 1; }
        sv_vlan_read_answer() { mock_read_answer; }
        sv_vlan_run_setup() { mock_run_setup "$@"; }
        sv_vlan_preflight >/dev/null 2>&1
    ); then
        fail "确认 setup 且复检成功后 preflight 仍失败"
    fi

    [[ "$(trace_count "$trace" "run_setup ")" == "1" ]] \
        || fail "确认后 setup 不是恰好执行一次"
    [[ "$(trace_count "$trace" "preflight_once ")" == "2" ]] \
        || fail "setup 后未恰好复检一次"
    assert_trace_contains "$trace" "detect_uplink" "未执行自动上联探测"
    assert_trace_contains "$trace" "run_setup enp5s0" \
        "自动探测的上联未传入 setup"
}

test_failed_recheck_never_runs_setup_twice() {
    local trace="$1" counter="$2"

    : >"$trace"
    : >"$counter"
    if (
        CASE_TRACE="$trace"
        CASE_COUNTER="$counter"
        DRY_RUN=0
        MOCK_RECHECK_RESULT=failure
        MOCK_ANSWER="SETUP enp5s0"
        sv_vlan_preflight_once() { mock_preflight_once; }
        sv_vlan_setup_required() { mock_setup_required; }
        sv_vlan_can_offer_setup() { return 0; }
        sv_vlan_detect_uplink() { mock_detect_uplink; }
        sv_vlan_uplink_has_native_conflict() { return 1; }
        sv_vlan_read_answer() { mock_read_answer; }
        sv_vlan_run_setup() { mock_run_setup "$@"; }
        sv_vlan_preflight >/dev/null 2>&1
    ); then
        fail "setup 后复检失败却返回成功"
    fi

    [[ "$(trace_count "$trace" "run_setup ")" == "1" ]] \
        || fail "复检失败后重复执行了 setup"
    [[ "$(trace_count "$trace" "preflight_once ")" == "2" ]] \
        || fail "复检失败路径的 once 调用次数错误"
}

test_dry_run_orchestration_does_not_setup() {
    local trace="$1" counter="$2"

    : >"$trace"
    : >"$counter"
    if (
        CASE_TRACE="$trace"
        CASE_COUNTER="$counter"
        DRY_RUN=1
        sv_vlan_preflight_once() { mock_preflight_once; }
        sv_vlan_setup_required() { mock_setup_required; }
        # 这里保留生产 can_offer，由它的 DRY_RUN 门禁拒绝后续流程。
        sv_vlan_detect_uplink() { mock_detect_uplink; }
        sv_vlan_read_answer() { mock_read_answer; }
        sv_vlan_run_setup() { mock_run_setup "$@"; }
        sv_vlan_preflight >/dev/null 2>&1
    ); then
        fail "DRY_RUN 且宿主未初始化时 preflight 不应成功"
    fi

    assert_trace_not_contains "$trace" "run_setup " "DRY_RUN 执行了 setup"
}

main() {
    local temp_dir trace counter out

    [[ -f "$RUNTIME_LIB" ]] || fail "缺少 VLAN 预检库: $RUNTIME_LIB"
    HERE="$REPO_ROOT/deploy/scripts"
    INSTANCE=9981
    VLAN_ID=11
    VLAN_TAP_IF=svtap9981
    DRY_RUN=0
    # shellcheck disable=SC1090
    source "$RUNTIME_LIB"

    for function_name in sv_vlan_preflight_once sv_vlan_detect_uplink \
        sv_vlan_can_offer_setup sv_vlan_setup_required sv_vlan_read_answer \
        sv_vlan_run_setup sv_vlan_preflight; do
        declare -F "$function_name" >/dev/null \
            || fail "生产库缺少 autosetup 契约函数: $function_name"
    done

    temp_dir="$(mktemp -d)"
    trace="$temp_dir/trace"
    counter="$temp_dir/counter"
    out="$temp_dir/out"
    trap 'rm -rf "${temp_dir:-}"' EXIT

    test_real_noninteractive_gate "$out"
    test_real_dry_run_gate "$out"
    test_real_ssh_gate "$out"
    test_malicious_uplink_names_are_rejected
    test_explicit_uplink_is_still_validated
    test_noninteractive_preflight_does_not_setup "$trace" "$counter"
    test_rejected_offer_does_not_setup "$trace" "$counter"
    test_confirm_runs_once_detects_uplink_and_rechecks "$trace" "$counter"
    test_failed_recheck_never_runs_setup_twice "$trace" "$counter"
    test_dry_run_orchestration_does_not_setup "$trace" "$counter"
    echo "PASS: start-vm VLAN 交互式一次 setup/复检/安全门禁"
}

main "$@"

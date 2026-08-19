#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
DEPLOY_ROOT=$(cd "$TEST_DIR/../.." && pwd)
MODULE="$DEPLOY_ROOT/lib/dgame-qemu-ptracer.sh"
BUILTIN="$DEPLOY_ROOT/scripts/qemu-ptracer-wrapper.py"
TEST_ROOT=$(mktemp -d)

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_array() {
    local expected_name=$1 actual_name=$2
    local -n expected_ref=$expected_name actual_ref=$actual_name
    local index

    ((${#expected_ref[@]} == ${#actual_ref[@]})) || fail "array length differs"
    for index in "${!expected_ref[@]}"; do
        [[ "${expected_ref[$index]}" == "${actual_ref[$index]}" ]] ||
            fail "argv[$index] differs"
    done
}

test_explicit_wrapper_preserves_argv() {
    local wrapper="$TEST_ROOT/wrapper with spaces" here=$DEPLOY_ROOT
    local -a expected actual

    printf '#!/usr/bin/env bash\nexit 0\n' >"$wrapper"
    chmod +x "$wrapper"
    DGAME_QEMU_PTRACER=$wrapper
    DRY_RUN=0
    # shellcheck source=../../lib/dgame-qemu-ptracer.sh
    source "$MODULE"
    dgame_qemu_ptracer_build_leaf "/opt/QEMU build/qemu" \
        -name "vm with spaces" -m 8192
    actual=("${DGAME_QEMU_LEAF_CMD[@]}")
    expected=("$wrapper" -- "/opt/QEMU build/qemu" \
        -name "vm with spaces" -m 8192)
    assert_array expected actual
}

test_builtin_wrapper_execs_in_place() {
    local fake_qemu="$TEST_ROOT/fake qemu" wrapper_pid qemu_pid
    local -a expected actual

    printf '%s\n' '#!/usr/bin/env bash' \
        'printf '\''%s\n'\'' "$$" >"$TEST_QEMU_PID"' \
        'printf '\''%s\0'\'' "$@" >"$TEST_QEMU_ARGV"' >"$fake_qemu"
    chmod +x "$fake_qemu"
    TEST_QEMU_PID="$TEST_ROOT/pid" TEST_QEMU_ARGV="$TEST_ROOT/argv" \
        /usr/bin/python3 "$BUILTIN" -- "$fake_qemu" \
        "argument with spaces" --literal &
    wrapper_pid=$!
    wait "$wrapper_pid"
    qemu_pid=$(<"$TEST_ROOT/pid")
    [[ "$qemu_pid" == "$wrapper_pid" ]] || fail "wrapper did not exec in place"
    mapfile -d '' -t actual <"$TEST_ROOT/argv"
    expected=("argument with spaces" --literal)
    assert_array expected actual
}

test_scope_and_daemonize_fail_closed() {
    local here=$DEPLOY_ROOT

    unset DGAME_QEMU_PTRACER
    # shellcheck source=../../lib/dgame-qemu-ptracer.sh
    source "$MODULE"
    dgame_qemu_ptracer_validate_scope 0
    dgame_qemu_ptracer_validate_scope 1
    ! dgame_qemu_ptracer_validate_scope 2 >/dev/null 2>&1
    ! dgame_qemu_ptracer_validate_scope 3 >/dev/null 2>&1
    DGAME_QEMU_PTRACER_READY=1
    DGAME_QEMU_PTRACER_PREFIX=(wrapper --)
    ! dgame_qemu_ptracer_build_leaf qemu -daemonize >/dev/null 2>&1
    ((${#DGAME_QEMU_LEAF_CMD[@]} == 0)) || fail "stale leaf command remains"
}

test_start_path_uses_leaf_command() {
    grep -q 'dgame_qemu_ptracer_build_leaf "${QEMU_CMD\[@\]}"' \
        "$DEPLOY_ROOT/scripts/start-vm.sh" || fail "start path does not build leaf"
    if grep -q '"${QEMU_LAUNCH\[@\]}" "${QEMU_CMD\[@\]}"' \
            "$DEPLOY_ROOT/scripts/start-vm.sh"; then
        fail "a launch path bypasses the ptracer leaf"
    fi
}

test_explicit_wrapper_preserves_argv
test_builtin_wrapper_execs_in_place
test_scope_and_daemonize_fail_closed
test_start_path_uses_leaf_command
echo "PASS: DGame QEMU ptracer compatibility"

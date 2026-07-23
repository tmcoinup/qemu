#!/usr/bin/env bash
# 隔离验证 build.sh 在成功编译/验证后自动安装宿主 helper，不执行真实编译或 sudo。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SOURCE_BUILD="$REPO_ROOT/deploy/tools/build.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# 中文注释：路径刻意包含空格，确保 --qemu=<绝对路径> 在多层函数与 sudo
# 之间始终保持单一参数，不能依赖只在无空格工作区成立的错误拆词。
fake_repo="$tmp/fake repo"
fake_bin="$tmp/fake-bin"
fake_install_root="$tmp/install-root"
event_log="$tmp/events.log"
sudo_log="$tmp/sudo.log"
output_log="$tmp/output.log"
mkdir -p "$fake_repo/deploy/tools" "$fake_repo/deploy/scripts/lib" \
    "$fake_repo/target/i386" "$fake_repo/build" "$fake_bin"
cp "$SOURCE_BUILD" "$fake_repo/deploy/tools/build.sh"
chmod 0755 "$fake_repo/deploy/tools/build.sh"
printf '%s\n' '11.0.2' > "$fake_repo/VERSION"
printf '%s\n' 'Ryzen3-1200' > "$fake_repo/target/i386/cpu.c"
touch "$fake_repo/build/build.ninja"

cat > "$fake_bin/pkg-config" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$fake_bin/python3" <<'EOF'
#!/usr/bin/env bash
# build/helper 组合测试不验证宿主 Python wheel；对应契约由
# test_build_tooling_static.sh 覆盖。消费 heredoc 后返回成功，保持本用例隔离。
[[ "${1:-}" == "-" ]] || exec /usr/bin/python3 "$@"
cat >/dev/null
EOF

cat > "$fake_bin/ninja" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'ninja' >> "$FAKE_EVENT_LOG"
[[ "${FAKE_NINJA_FAIL:-0}" == "0" ]] || exit 31
if [[ "${FAKE_NO_BINARY:-0}" == "0" ]]; then
    if [[ "${FAKE_EMPTY_BINARY:-0}" == "1" ]]; then
        : > qemu-system-x86_64
    else
        printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > qemu-system-x86_64
    fi
    chmod 0755 qemu-system-x86_64
fi
EOF

cat > "$fake_bin/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
[[ "${FAKE_CONTAINER:-0}" == "1" && "$*" == *--container* ]]
EOF

cat > "$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# 中文注释：测试只模拟 sudo 的参数边界，绝不提升权限。build 必须在 sudo 前
# 清除三个部署环境变量，并让 sudo 直接看到固定 installer，而不是 /usr/bin/env。
mode=interactive
if [[ "${1:-}" == "-n" ]]; then mode=noninteractive; shift; fi
[[ "${1:-}" != "--" ]] || shift
[[ -z "${VMATE_INSTALL_ROOT+x}" && -z "${VMATE_QEMU_BINARY+x}" &&
   -z "${VMATE_TARGET_UID+x}" ]] || exit 61
[[ "${1:-}" == "$FAKE_EXPECTED_SETUP" ]] || exit 62
printf '%s\n' "$mode" >> "$FAKE_SUDO_LOG"
exec env VMATE_INSTALL_ROOT="$FAKE_INSTALL_ROOT" \
    VMATE_TARGET_UID="$(id -u)" "$@"
EOF

# wrapper 只记录 build→installer 的真实 argv 和注入失败；成功路径继续执行仓库中的
# 真安装器副本，因此 build CLI、事务落盘、信任清单和 check 是组合测试而非纯 mock。
cp "$REPO_ROOT/deploy/scripts/setup-host-helpers.sh" \
    "$fake_repo/deploy/scripts/setup-host-helpers-real.sh"
cp "$REPO_ROOT/deploy/scripts/host-performance.sh" \
    "$REPO_ROOT/deploy/scripts/host-cpu-isolate.sh" \
    "$REPO_ROOT/deploy/scripts/host-cpu-isolate-runtime.sh" \
    "$REPO_ROOT/deploy/scripts/host-cpu-isolate-cgroup.sh" \
    "$fake_repo/deploy/scripts/"
cp "$REPO_ROOT/deploy/scripts/lib/setup-host-cpu-install-guard.sh" \
    "$fake_repo/deploy/scripts/lib/"
cat > "$fake_repo/deploy/scripts/setup-host-helpers.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'setup' >> "$FAKE_EVENT_LOG"
printf '|%s' "$@" >> "$FAKE_EVENT_LOG"
printf '\n' >> "$FAKE_EVENT_LOG"
case "${1:-}" in
    install)
        [[ "${2:-}" == --qemu=* ]] || exit 41
        [[ "${FAKE_INSTALL_FAIL:-0}" == "0" ]] || exit 42
        ;;
    check)
        [[ "$#" == "1" ]] || exit 43
        [[ "${FAKE_CHECK_FAIL:-0}" == "0" ]] || exit 44
        ;;
    *) exit 45 ;;
esac
exec "$(cd "$(dirname "$0")" && pwd)/setup-host-helpers-real.sh" "$@"
EOF

cat > "$fake_repo/deploy/scripts/verify-stealth.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'verify' >> "$FAKE_EVENT_LOG"
[[ "${FAKE_VERIFY_FAIL:-0}" == "0" ]] || exit 51
EOF
cat > "$tmp/pty-runner.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${PTY_BACKGROUND:-0}" == "1" ]]; then
    # 打开 job control，保证后台 build 与终端前台进程组不同，复现 sudo SIGTTIN 风险。
    set -m
    "$FAKE_BUILD" &
    child=$!
    wait "$child"
else
    exec "$FAKE_BUILD"
fi
EOF
chmod 0755 "$fake_bin/pkg-config" "$fake_bin/python3" "$fake_bin/ninja" \
    "$fake_bin/systemd-detect-virt" "$fake_bin/sudo" \
    "$fake_repo/deploy/scripts/setup-host-helpers.sh" \
    "$fake_repo/deploy/scripts/setup-host-helpers-real.sh" \
    "$fake_repo/deploy/scripts/host-performance.sh" \
    "$fake_repo/deploy/scripts/host-cpu-isolate.sh" \
    "$fake_repo/deploy/scripts/host-cpu-isolate-runtime.sh" \
    "$fake_repo/deploy/scripts/host-cpu-isolate-cgroup.sh" \
    "$fake_repo/deploy/scripts/verify-stealth.sh" "$tmp/pty-runner.sh"

reset_case() {
    : > "$event_log"
    : > "$sudo_log"
    : > "$output_log"
    rm -f "$fake_repo/build/qemu-system-x86_64"
    rm -rf "$fake_install_root"
    mkdir -p "$fake_install_root"
}

run_build() {
    env PATH="$fake_bin:$PATH" FAKE_EVENT_LOG="$event_log" \
        FAKE_SUDO_LOG="$sudo_log" FAKE_INSTALL_ROOT="$fake_install_root" \
        FAKE_EXPECTED_SETUP="$fake_repo/deploy/scripts/setup-host-helpers.sh" \
        VMATE_INSTALL_ROOT="$tmp/poison-root" VMATE_QEMU_BINARY=/bin/false \
        VMATE_TARGET_UID=4242 \
        CI=1 INSTALL_HOST_HELPERS="${INSTALL_HOST_HELPERS:-auto}" \
        FAKE_NINJA_FAIL="${FAKE_NINJA_FAIL:-0}" \
        FAKE_NO_BINARY="${FAKE_NO_BINARY:-0}" \
        FAKE_EMPTY_BINARY="${FAKE_EMPTY_BINARY:-0}" \
        FAKE_VERIFY_FAIL="${FAKE_VERIFY_FAIL:-0}" \
        FAKE_INSTALL_FAIL="${FAKE_INSTALL_FAIL:-0}" \
        FAKE_CHECK_FAIL="${FAKE_CHECK_FAIL:-0}" \
        "$fake_repo/deploy/tools/build.sh" "$@" >"$output_log" 2>&1
}

run_build_pty() {
    local background="${1:-0}" container="${2:-0}"

    command -v script >/dev/null 2>&1 || fail "缺少 util-linux script，无法验证前后台 TTY"
    env -u CI PATH="$fake_bin:$PATH" FAKE_EVENT_LOG="$event_log" \
        FAKE_SUDO_LOG="$sudo_log" FAKE_INSTALL_ROOT="$fake_install_root" \
        FAKE_EXPECTED_SETUP="$fake_repo/deploy/scripts/setup-host-helpers.sh" \
        FAKE_BUILD="$fake_repo/deploy/tools/build.sh" \
        PTY_BACKGROUND="$background" FAKE_CONTAINER="$container" \
        VMATE_INSTALL_ROOT="$tmp/poison-root" VMATE_QEMU_BINARY=/bin/false \
        VMATE_TARGET_UID=4242 INSTALL_HOST_HELPERS=auto \
        FAKE_NINJA_FAIL=0 FAKE_NO_BINARY=0 FAKE_EMPTY_BINARY=0 FAKE_VERIFY_FAIL=0 \
        FAKE_INSTALL_FAIL=0 FAKE_CHECK_FAIL=0 \
        timeout 20 script -qefc "$tmp/pty-runner.sh" /dev/null \
        >"$output_log" 2>&1
}

assert_events() {
    local expected="$1" actual
    actual="$(<"$event_log")"
    [[ "$actual" == "$expected" ]] || {
        echo "实际事件:" >&2
        cat "$event_log" >&2
        fail "构建编排顺序不符"
    }
}

assert_not_complete() {
    ! grep -Fx '=== build complete ===' "$output_log" >/dev/null \
        || fail "失败流程不应报告整体构建完成"
}

qemu_arg="--qemu=$fake_repo/build/qemu-system-x86_64"

install_event() {
    local device inode digest
    read -r device inode < <(stat -Lc '%d %i' "$fake_repo/build/qemu-system-x86_64")
    digest="$(sha256sum "$fake_repo/build/qemu-system-x86_64")"
    printf 'setup|install|%s|--expect-device=%s|--expect-inode=%s|--expect-sha256=%s' \
        "$qemu_arg" "$device" "$inode" "${digest%% *}"
}

reset_case
run_build --install-host-helpers
assert_events "$(printf 'ninja\n%s\nsetup|check' "$(install_event)")"
[[ "$(<"$sudo_log")" == $'noninteractive\nnoninteractive' ]] \
    || fail "强制无终端安装没有使用两次 sudo -n"
grep -Fx "path=$(realpath -e "$fake_repo/build/qemu-system-x86_64")" \
    "$fake_install_root/usr/local/libexec/qemu-vmate-cpu-isolate-qemu.conf" >/dev/null \
    || fail "真实 installer 没有登记本次 build 产物"
grep -Fx '=== build complete ===' "$output_log" >/dev/null \
    || fail "成功安装后缺少整体完成标记"

reset_case
run_build --verify --install-host-helpers
assert_events "$(printf 'ninja\nverify\n%s\nsetup|check' "$(install_event)")"

reset_case
run_build
assert_events 'ninja'
grep -F 'CI/容器/非前台交互终端，跳过宿主 helper 安装' "$output_log" >/dev/null \
    || fail "auto 模式在 CI 中没有明确跳过提示"

reset_case
run_build_pty 0 0
assert_events "$(printf 'ninja\n%s\nsetup|check' "$(install_event)")"
[[ "$(<"$sudo_log")" == $'interactive\ninteractive' ]] \
    || fail "前台 PTY auto 模式没有走交互 sudo"

reset_case
run_build_pty 1 0
assert_events 'ninja'
grep -F '非前台交互终端，跳过宿主 helper 安装' "$output_log" >/dev/null \
    || fail "后台 PTY 构建没有跳过 sudo"

reset_case
run_build_pty 0 1
assert_events 'ninja'
grep -F 'CI/容器/非前台交互终端' "$output_log" >/dev/null \
    || fail "容器 auto 模式没有跳过宿主修改"

reset_case
run_build --no-install-host-helpers
assert_events 'ninja'
grep -F -- '--no-install-host-helpers' "$output_log" >/dev/null \
    || fail "显式跳过缺少提示"

reset_case
if FAKE_NINJA_FAIL=1 run_build --install-host-helpers; then
    fail "ninja 失败后 build.sh 仍返回成功"
fi
assert_events 'ninja'
assert_not_complete

reset_case
if FAKE_NO_BINARY=1 run_build --install-host-helpers; then
    fail "缺少 QEMU 二进制时 build.sh 仍返回成功"
fi
assert_events 'ninja'
assert_not_complete

reset_case
if FAKE_EMPTY_BINARY=1 run_build --install-host-helpers; then
    fail "空 QEMU 二进制时 build.sh 仍返回成功"
fi
assert_events 'ninja'
assert_not_complete

reset_case
if FAKE_VERIFY_FAIL=1 run_build --verify --install-host-helpers; then
    fail "verify 失败后 build.sh 仍返回成功"
fi
assert_events "$(printf 'ninja\nverify')"
assert_not_complete

reset_case
if FAKE_INSTALL_FAIL=1 run_build --install-host-helpers; then
    fail "helper 安装失败后 build.sh 仍返回成功"
fi
assert_events "$(printf 'ninja\n%s' "$(install_event)")"
assert_not_complete

reset_case
if FAKE_CHECK_FAIL=1 run_build --install-host-helpers; then
    fail "helper check 失败后 build.sh 仍返回成功"
fi
assert_events "$(printf 'ninja\n%s\nsetup|check' "$(install_event)")"
assert_not_complete

reset_case
if INSTALL_HOST_HELPERS=invalid run_build; then
    fail "非法 INSTALL_HOST_HELPERS 值应被拒绝"
fi
assert_events ''
assert_not_complete

bash -n "$SOURCE_BUILD" "$0"
echo "PASS: build.sh host helper integration"

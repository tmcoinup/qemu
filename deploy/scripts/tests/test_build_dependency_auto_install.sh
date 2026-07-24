#!/usr/bin/env bash
# 隔离验证构建依赖自动安装策略；所有 APT/sudo 都是函数或 PATH fixture。
# shellcheck disable=SC2034 # fixture 赋值由被 source 的生产 helper 消费。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/deploy/tools/lib/build-dependencies.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# shellcheck source=../../tools/lib/build-dependencies.sh
source "$HELPER"

seed_missing_then_complete() {
    DETECT_CALLS=0
    build_dependencies_detect() {
        ((DETECT_CALLS += 1))
        if (( DETECT_CALLS == 1 )); then
            BUILD_DEP_PACKAGES=(libaio-dev liburing-dev)
            BUILD_DEP_REASONS=("缺少 libaio" "缺少 liburing")
        else
            BUILD_DEP_PACKAGES=()
            BUILD_DEP_REASONS=()
        fi
    }
}

seed_always_missing() {
    build_dependencies_detect() {
        BUILD_DEP_PACKAGES=(liburing-dev)
        BUILD_DEP_REASONS=("缺少 liburing")
    }
}

run_root_log="$TMP_DIR/run-root.log"
mock_install_environment() {
    : >"$run_root_log"
    build_dependencies_is_debian() { return 0; }
    build_container_detected() { return 1; }
    build_terminal_foreground() { return 0; }
    build_dependencies_run_root() {
        printf '<%s>' "$@" >>"$run_root_log"
        printf '\n' >>"$run_root_log"
    }
}

(
    build_dependencies_detect() {
        BUILD_DEP_PACKAGES=()
        BUILD_DEP_REASONS=()
    }
    build_dependencies_install() {
        fail "依赖完整时不应调用安装器"
    }
    build_dependencies_ensure auto >/dev/null
)

(
    seed_missing_then_complete
    mock_install_environment
    build_dependencies_ensure auto >"$TMP_DIR/auto.out"
    [[ "$(wc -l <"$run_root_log")" == 2 ]] ||
        fail "auto 没有严格执行一次 update 和一次 install"
    grep -F '</usr/bin/apt-get><-o><DPkg::Lock::Timeout=120><update>' \
        "$run_root_log" >/dev/null || fail "auto 的 apt-get update 参数错误"
    grep -F '<install><--yes><--no-install-recommends><libaio-dev><liburing-dev>' \
        "$run_root_log" >/dev/null || fail "auto 没有只安装缺失包"
    grep -F 'installed and verified' "$TMP_DIR/auto.out" >/dev/null ||
        fail "安装后没有完整复检"
)

(
    seed_always_missing
    mock_install_environment
    if build_dependencies_ensure 0 >"$TMP_DIR/disabled.out" 2>&1; then
        fail "禁用自动安装时绕过了依赖门禁"
    fi
    [[ ! -s "$run_root_log" ]] || fail "禁用模式仍调用了 APT"
    grep -F 'sudo apt-get update && sudo apt-get install -y liburing-dev' \
        "$TMP_DIR/disabled.out" >/dev/null || fail "禁用模式缺少精确手动命令"
)

(
    seed_always_missing
    mock_install_environment
    export CI=1
    if build_dependencies_ensure auto >"$TMP_DIR/ci.out" 2>&1; then
        fail "CI auto 模式不应隐式安装"
    fi
    [[ ! -s "$run_root_log" ]] || fail "CI auto 模式调用了 APT"
    grep -F '不会在 CI、容器或后台任务中隐式修改宿主' \
        "$TMP_DIR/ci.out" >/dev/null || fail "CI auto 诊断不明确"
)

(
    seed_missing_then_complete
    mock_install_environment
    build_terminal_foreground() { return 1; }
    build_dependencies_ensure 1 >/dev/null ||
        fail "显式强制模式不支持无终端安装"
    [[ "$(wc -l <"$run_root_log")" == 2 ]] ||
        fail "显式强制模式没有执行 APT"
)

(
    seed_always_missing
    mock_install_environment
    build_dependencies_is_debian() { return 1; }
    if build_dependencies_ensure 1 >"$TMP_DIR/non-debian.out" 2>&1; then
        fail "非 Debian 系统不应猜测包管理器"
    fi
    [[ ! -s "$run_root_log" ]] || fail "非 Debian 系统仍调用了 APT"
    if grep -F 'apt-get' "$TMP_DIR/non-debian.out" >/dev/null; then
        fail "非 Debian 诊断不应猜测 APT 命令"
    fi
)

(
    BUILD_DEP_PACKAGES=()
    BUILD_DEP_REASONS=()
    python3() {
        printf '%s\n' 'attacker-selected-package|伪造 Python 检测输出'
    }
    build_dependencies_install() {
        fail "未知包名在进入 APT 前没有被拒绝"
    }
    build_dependencies_detect() {
        build_dependencies_detect_python
    }
    if build_dependencies_ensure 1 >"$TMP_DIR/untrusted-package.out" 2>&1; then
        fail "未知 Python 包映射没有 fail closed"
    fi
    grep -F '未授权的 APT 包名: attacker-selected-package' \
        "$TMP_DIR/untrusted-package.out" >/dev/null ||
        fail "未知包名拒绝诊断不明确"
)

(
    build_dependencies_detect() {
        BUILD_DEP_PACKAGES=(attacker-selected-package)
        BUILD_DEP_REASONS=("伪造最终数组")
    }
    build_dependencies_install() {
        fail "最终包数组未校验就在 sudo/APT 前被消费"
    }
    if build_dependencies_ensure 1 >"$TMP_DIR/untrusted-array.out" 2>&1; then
        fail "未知最终包数组没有 fail closed"
    fi
    grep -F '非固定 APT 包名: attacker-selected-package' \
        "$TMP_DIR/untrusted-array.out" >/dev/null ||
        fail "最终包数组 allowlist 诊断不明确"
)

(
    seed_always_missing
    mock_install_environment
    set +e
    build_dependencies_ensure invalid >"$TMP_DIR/invalid.out" 2>&1
    status=$?
    set -e
    [[ "$status" == 2 ]] || fail "非法安装模式没有返回 2"
)

(
    seed_always_missing
    mock_install_environment
    build_dependencies_run_root() { return 71; }
    if build_dependencies_ensure 1 >"$TMP_DIR/apt-fail.out" 2>&1; then
        fail "APT 失败后依赖保障仍返回成功"
    fi
    grep -F 'apt-get update 失败' "$TMP_DIR/apt-fail.out" >/dev/null ||
        fail "APT 失败诊断不明确"
)

(
    seed_always_missing
    mock_install_environment
    ROOT_CALLS=0
    build_dependencies_run_root() {
        ((ROOT_CALLS += 1))
        (( ROOT_CALLS == 1 ))
    }
    if build_dependencies_ensure 1 >"$TMP_DIR/install-fail.out" 2>&1; then
        fail "apt-get install 失败后依赖保障仍返回成功"
    fi
    grep -F 'apt-get install 失败' "$TMP_DIR/install-fail.out" >/dev/null ||
        fail "apt-get install 失败诊断不明确"
)

(
    seed_always_missing
    mock_install_environment
    if build_dependencies_ensure 1 >"$TMP_DIR/recheck-fail.out" 2>&1; then
        fail "安装后仍缺依赖时没有 fail closed"
    fi
    [[ "$(wc -l <"$run_root_log")" == 2 ]] ||
        fail "安装后复检失败不应重复执行 APT"
    grep -F 'APT 完成后构建依赖仍不完整' \
        "$TMP_DIR/recheck-fail.out" >/dev/null || fail "复检失败诊断不明确"
)

if (( EUID != 0 )); then
    fake_bin="$TMP_DIR/fake-bin"
    sudo_log="$TMP_DIR/sudo.log"
    mkdir -p "$fake_bin"
    cat >"$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '<%s>' "$@" >"$SUDO_LOG"
printf '\n' >>"$SUDO_LOG"
EOF
    chmod 0755 "$fake_bin/sudo"

    (
        export PATH="$fake_bin:$PATH" SUDO_LOG="$sudo_log"
        build_terminal_foreground() { return 1; }
        build_dependencies_run_root /usr/bin/apt-get update
    )
    grep -Fx '<-n><--></usr/bin/apt-get><update>' "$sudo_log" >/dev/null ||
        fail "无终端强制安装没有使用 sudo -n"

    (
        export PATH="$fake_bin:$PATH" SUDO_LOG="$sudo_log"
        build_terminal_foreground() { return 0; }
        build_dependencies_run_root /usr/bin/apt-get update
    )
    grep -Fx '<--></usr/bin/apt-get><update>' "$sudo_log" >/dev/null ||
        fail "前台安装没有使用交互 sudo"
fi

bash -n "$HELPER" "$0"
echo "PASS: build dependency auto-install policy"

#!/usr/bin/env bash
# 静态验证 QEMU 11.0.2 构建工具契约，不执行 configure、编译或补丁写入。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILD_SCRIPT="$REPO_ROOT/deploy/tools/build.sh"
PATCH_SCRIPT="$REPO_ROOT/deploy/tools/apply-patches.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle="$1"
    local file="$2"

    grep -F -- "$needle" "$file" >/dev/null \
        || fail "缺少 '$needle': $file"
}

reject_text() {
    local needle="$1"
    local file="$2"

    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "不应再出现 '$needle': $file"
    fi
}

test_shell_syntax() {
    bash -n "$BUILD_SCRIPT"
    bash -n "$PATCH_SCRIPT"
}

test_qemu_11_baseline_and_werror() {
    require_text 'EXPECTED_QEMU_VERSION="11.0.2"' "$BUILD_SCRIPT"
    require_text '--enable-werror' "$BUILD_SCRIPT"
    reject_text '--disable-werror' "$BUILD_SCRIPT"
    reject_text 'QEMU 9.2.0' "$BUILD_SCRIPT"
    reject_text 'qemu-9.2.0' "$BUILD_SCRIPT"
}

test_python_preflight_contract() {
    # 中文注释：只检查预检代码存在，不在静态测试中创建 pyvenv 或联网下载。
    require_text 'find_spec("venv")' "$BUILD_SCRIPT"
    require_text 'find_spec("ensurepip")' "$BUILD_SCRIPT"
    require_text '"setuptools": (44, 1, 1)' "$BUILD_SCRIPT"
    require_text '"wheel": (0, 34, 2)' "$BUILD_SCRIPT"
    require_text 'python3-setuptools python3-wheel' "$BUILD_SCRIPT"
}

test_cli_compatibility() {
    local help_output

    help_output="$("$BUILD_SCRIPT" --help)"
    for option in --clean --reconfig --debug --jobs --verify \
            --install-host-helpers --no-install-host-helpers; do
        grep -F -- "$option" <<<"$help_output" >/dev/null \
            || fail "--help 丢失既有选项 $option"
    done
}

test_host_helper_orchestration_contract() {
    # 中文注释：行为与失败顺序由独立隔离测试执行；这里保留关键安全字面门禁，
    # 防止后续重构重新依赖可由调用环境注入的测试安装根或隐式 QEMU 路径。
    require_text 'INSTALL_HOST_HELPERS="${INSTALL_HOST_HELPERS:-auto}"' "$BUILD_SCRIPT"
    require_text '"$setup" install "--qemu=$BIN"' "$BUILD_SCRIPT"
    require_text '"--expect-device=$QEMU_TRUST_DEVICE"' "$BUILD_SCRIPT"
    require_text '"--expect-inode=$QEMU_TRUST_INODE"' "$BUILD_SCRIPT"
    require_text '"--expect-sha256=$QEMU_TRUST_SHA256"' "$BUILD_SCRIPT"
    require_text '"$setup" check' "$BUILD_SCRIPT"
    require_text 'sudo -n -- "$@"' "$BUILD_SCRIPT"
    require_text 'host_helper_terminal_foreground' "$BUILD_SCRIPT"
    require_text 'host_helper_container_detected' "$BUILD_SCRIPT"
    reject_text 'sudo -n -- env ' "$BUILD_SCRIPT"
}

test_patch_script_validates_integrated_qemu11_features() {
    require_text 'shopt -s nullglob' "$PATCH_SCRIPT"
    require_text '[0-9][0-9][0-9][0-9]-*.patch' "$PATCH_SCRIPT"
    require_text 'check_integrated_feature "Samsung NVMe"' "$PATCH_SCRIPT"
    require_text 'check_integrated_feature "USB HID 身份属性"' "$PATCH_SCRIPT"
    # 中文注释：这里按字面检查 shell 变量，单引号是刻意的，不应展开。
    # shellcheck disable=SC2016
    require_text 'exec "$HERE/build.sh" "$@"' "$PATCH_SCRIPT"
    reject_text 'git apply "$p"' "$PATCH_SCRIPT"
    reject_text 'git checkout v9.2.0' "$PATCH_SCRIPT"
    # 中文注释：补丁文件本身仍是可审计的 QEMU 9.2.0 历史清单，因此脚本
    # 可以说明来源；测试禁止的是 checkout/git apply 等旧基线执行路径。
    require_text '以 QEMU 9.2.0 上下文保存，仅用于' "$PATCH_SCRIPT"
}

test_shell_syntax
test_qemu_11_baseline_and_werror
test_python_preflight_contract
test_cli_compatibility
test_host_helper_orchestration_contract
test_patch_script_validates_integrated_qemu11_features

echo "OK: QEMU 11.0.2 build tooling static checks passed"

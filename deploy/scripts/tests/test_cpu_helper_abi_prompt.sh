#!/usr/bin/env bash
# 验证旧 helper ABI/绑核策略门禁给出完整安装命令和可选验证命令。
# shellcheck disable=SC1090,SC2034,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
CPU_PIN_LIBRARY="$REPO_ROOT/deploy/scripts/lib/sv-cpupin.sh"
printf -v QUOTED_REPO_ROOT '%q' "$REPO_ROOT"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# 先关闭隔离来安全加载函数，再用 shell 函数模拟旧 helper 的 sudo -n preflight。
# 参数不符合真实调用契约时返回 97，避免错误的调用方式碰巧通过提示测试。
set +e
output="$({
    sudo() {
        [[ "$#" == "4" && "$1" == "-n" && "$2" == "/usr/bin/true" \
            && "$3" == "preflight" && "$4" == "--qemu=/usr/bin/true" ]] \
            || return 97
        echo "cpu-isolate preflight passed (abi=4)."
    }

    HERE="$REPO_ROOT/deploy/scripts"
    CPU_ISOLATE=0
    DRY_RUN=0
    STRICT_HARDWARE=0
    SV_CPU_ISO_HELPER=/usr/bin/true
    QEMU=/usr/bin/true
    source "$CPU_PIN_LIBRARY"
    CPU_ISOLATE=1
    sv_cpu_isolate_preflight
} 2>&1)"
status=$?
set -e

[[ "$status" == "1" ]] || fail "旧绑核策略门禁应返回 1，实际为 $status"
grep -F -- "ERROR: CPU 隔离 helper ABI/绑核策略过旧" <<<"$output" >/dev/null \
    || fail "缺少旧 ABI/绑核策略原因"
grep -F -- "安装命令: cd $QUOTED_REPO_ROOT && ./deploy/tools/build.sh --install-host-helpers" \
    <<<"$output" >/dev/null || fail "缺少可直接复制的完整安装命令"
grep -F -- "安装后验证（可选）: sudo -n /usr/bin/true preflight" \
    <<<"$output" >/dev/null || fail "缺少可选 preflight 验证命令"

echo "CPU helper ABI/policy prompt tests passed."

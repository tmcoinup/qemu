#!/usr/bin/env bash
# 验证 CPU asset tag 已纳入 profile，避免 SMBIOS Type 4 每次启动随机变化。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/fixtures/catalog-cpu-preflight-stub.sh"

# 单元测试不应依赖执行 CI 的物理 CPU 厂商。注入一个支持 TSC scaling 的 Intel
# 宿主视图，使正式选择器仍按 enabled manifest 生成完整 profile。
# 选择器通过全局变量名读取这些注入值，显式导出避免子进程视图漂移。
export STEALTH_HOST_CPU_VENDOR=GenuineIntel
export STEALTH_HOST_CPU_MAX_MHZ=5000
export STEALTH_REQUIRED_TSC_MHZ=
export CPUS=4

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

make_profile() {
    local path="$1"
    local omit_asset="${2:-0}"

    # 先走正式随机身份生成/保存路径，再覆盖待测 CPU 字段，保证 profile 结构完整。
    stealth_pick_profile
    # 这些全局变量由已 source 的函数按名称读取，ShellCheck 无法静态跟踪。
    # shellcheck disable=SC2034
    CPU_SERIAL=1642844234
    CPU_ASSET=6999
    # shellcheck disable=SC2034
    UUID=237c3804-420b-41bf-8155-1b8808de43a8
    # UUID 同时是当前 NVMe 标准 SubNQN 的持久身份源；测试覆盖 CPU 字段时也必须
    # 保持这组无关的原子身份自洽，不能依赖非严格模式绕过。
    NVME_SUBNQN="${NVME_SUBNQN_TEMPLATE//\{uuid\}/$UUID}"
    stealth_save_profile "$path"

    if [[ "$omit_asset" == "1" ]]; then
        grep -v '^CPU_ASSET=' "$path" > "${path}.tmp"
        mv -f "${path}.tmp" "$path"
        chmod 600 "$path"
    fi
}

type4_line() {
    MEM_PER_DIMM_MB=4096 stealth_smbios_args | grep '^type=4,'
}

test_explicit_cpu_asset_is_used() {
    local profile="$TMP_DIR/explicit.profile"
    local type4

    make_profile "$profile"
    unset CPU_ASSET
    stealth_load_profile "$profile"

    [[ "${CPU_ASSET:-}" == "6999" ]] \
        || fail "profile CPU_ASSET was not loaded"

    type4="$(type4_line)"
    [[ "$type4" == *",serial=1642844234,asset=6999,"* ]] \
        || fail "SMBIOS type=4 did not use profile CPU_ASSET: $type4"
}

test_missing_cpu_asset_is_rejected() {
    local profile="$TMP_DIR/missing.profile"

    make_profile "$profile" 1

    unset CPU_ASSET
    if STRICT_HARDWARE=0 stealth_load_profile "$profile" >/dev/null 2>&1; then
        fail "schema-1 profile 缺少 CPU_ASSET 时被静默修复"
    fi
}

test_invalid_cpu_asset_is_rejected() {
    local profile="$TMP_DIR/invalid.profile"

    make_profile "$profile"
    sed -i 's/^CPU_ASSET=.*/CPU_ASSET=bad-asset/' "$profile"

    unset CPU_ASSET
    if STRICT_HARDWARE=0 stealth_load_profile "$profile" >/dev/null 2>&1; then
        fail "schema-1 profile 的非法 CPU_ASSET 被静默修复"
    fi
}

test_explicit_cpu_asset_is_used
test_missing_cpu_asset_is_rejected
test_invalid_cpu_asset_is_rejected

echo "OK: CPU asset profile checks passed"

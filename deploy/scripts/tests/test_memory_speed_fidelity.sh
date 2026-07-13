#!/usr/bin/env bash
# 验证 DIMM 额定速率、平台配置速率和 Q35 SPD 输入不会再次混为一谈。
# shellcheck disable=SC2034  # 下列宿主约束由 source 后的选择函数按变量名读取。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../stealth-lib.sh
# shellcheck disable=SC1091  # 仓库可整体迁移，运行时按测试文件绝对目录加载。
source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# i5-6400T/H110 平台的 invariant TSC 为 2200MHz；精确约束可消除随机平台选择，
# 让每次测试都覆盖“2400/2666 额定 DIMM 降到 2133 运行”的关键场景。
STEALTH_HOST_CPU_VENDOR=GenuineIntel
STEALTH_HOST_CPU_MAX_MHZ=5000
STEALTH_REQUIRED_TSC_MHZ=2200
CPUS=4
stealth_pick_profile

[[ "$PLATFORM_ID" == "intel-lga1151-i5-6400t-asus-h110m-a-m2" ]] \
    || fail "未选中 H110/i5-6400T 固定测试平台"
[[ "$MEM_RATED_MTS" == "$MEM_RATED" ]] \
    || fail "额定速率没有绑定 DIMM 料号"
[[ "$MEM_CONFIGURED_MTS" == "2133" ]] \
    || fail "H110 配置速率应为 2133，实际 $MEM_CONFIGURED_MTS"

type17="$(MEM_PER_DIMM_MB=4096 stealth_smbios_args | grep '^type=17,')"
[[ "$type17" == *"speed=$MEM_RATED_MTS,configured-speed=2133"* ]] \
    || fail "Type17 未分离额定/配置速率: $type17"

profile="$TMP_DIR/hardware.profile"
stealth_save_profile "$profile"
grep -Fx -- "MEM_RATED_MTS=$MEM_RATED_MTS" "$profile" >/dev/null \
    || fail "profile 未持久化额定速率"
grep -Fx -- "MEM_CONFIGURED_MTS=2133" "$profile" >/dev/null \
    || fail "profile 未持久化配置速率"

saved_rated="$MEM_RATED_MTS"
for profile_var in "${_STEALTH_PROFILE_VARS[@]}"; do
    unset "$profile_var" || true
done
STRICT_HARDWARE=1 stealth_load_profile "$profile"
[[ "$MEM_RATED_MTS" == "$saved_rated" && "$MEM_CONFIGURED_MTS" == "2133" ]] \
    || fail "严格 profile 重载后额定/配置速率发生漂移"

# 严格 schema-1 profile 不允许缺字段后由兼容默认值补回，否则人工删掉配置速率
# 会被静默掩盖。旧 schema 仍可走非严格兼容读取，但不冒充已审计 profile。
incomplete="$TMP_DIR/incomplete.profile"
grep -Ev '^(MEM_RATED_MTS|MEM_CONFIGURED_MTS)=' "$profile" >"$incomplete"
for profile_var in "${_STEALTH_PROFILE_VARS[@]}"; do
    unset "$profile_var" || true
done
if STRICT_HARDWARE=1 stealth_load_profile "$incomplete" >/dev/null 2>&1; then
    fail "严格 profile 缺少速率字段时未拒绝"
fi

# 配置速率高于 DIMM 额定值在物理上不可能，参数生成器必须 fail-closed。
if MEM_RATED_MTS="$saved_rated" MEM_RATED="$saved_rated" \
   MEM_CONFIGURED_MTS=$(( saved_rated + 1 )) \
   MEM_PER_DIMM_MB=4096 stealth_smbios_args >/dev/null 2>&1; then
    fail "配置速率高于额定速率时未拒绝"
fi

echo "PASS: memory rated/configured speed fidelity"

#!/usr/bin/env bash
# profile 单字段读取与完整加载必须统一拒绝任一重复白名单 key。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# shellcheck source=/dev/null
source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"

DUPLICATE_PROFILE="$TMP_DIR/samsung-before-aoc.profile"
printf '%s\n' \
    'UUID=12345678-1234-4123-8123-123456789abc' \
    'EDID_COMPONENT_ID=samsung-s24f350' \
    'EDID_VENDOR=SAM' \
    'EDID_NAME=S24F350' \
    'EDID_COMPONENT_ID=aoc-24b2w1g5' \
    'EDID_VENDOR=AOC' \
    'EDID_NAME=24B2W1G5' >"$DUPLICATE_PROFILE"
chmod 0600 "$DUPLICATE_PROFILE"

GET_LOG="$TMP_DIR/get.log"
GET_VALUE=""
if GET_VALUE="$(
        stealth_profile_get EDID_COMPONENT_ID "$DUPLICATE_PROFILE" 2>"$GET_LOG"
    )"; then
    fail "单字段读取接受了前置 Samsung、尾部 AOC 的重复显示器事实"
fi
[[ -z "$GET_VALUE" ]] ||
    fail "重复 key 失败前泄漏了 first-wins 值: $GET_VALUE"
grep -F '重复白名单 key: EDID_COMPONENT_ID' "$GET_LOG" >/dev/null ||
    fail "单字段读取没有报告首个重复白名单 key"

# 即使请求的是未重复的 UUID，profile 中其它白名单 key 重复也必须整体失败。
if stealth_profile_get UUID "$DUPLICATE_PROFILE" >/dev/null 2>&1; then
    fail "单字段读取只检查请求 key，漏过了其它重复白名单 key"
fi

LOAD_LOG="$TMP_DIR/load.log"
EDID_COMPONENT_ID=unchanged-sentinel
if STRICT_HARDWARE=0 stealth_load_profile "$DUPLICATE_PROFILE" \
        >"$LOAD_LOG" 2>&1; then
    fail "完整 profile loader 接受了重复显示器 key"
fi
[[ "$EDID_COMPONENT_ID" == unchanged-sentinel ]] ||
    fail "完整 loader 在重复门禁前污染了全局 profile 变量"
grep -F '重复白名单 key: EDID_COMPONENT_ID' "$LOAD_LOG" >/dev/null ||
    fail "完整 loader 与单字段读取的重复 key 语义不一致"

# 危险值不能通过“先放命令构造、再放安全值”绕过重复门禁。
DANGEROUS_DUPLICATE="$TMP_DIR/dangerous-duplicate.profile"
# shellcheck disable=SC2016 # 必须写入危险构造的字面量，验证解析器不会展开它。
printf '%s\n' \
    'UUID=12345678-1234-4123-8123-123456789abc' \
    'EDID_NAME=$(printf injected)' \
    'EDID_NAME=24B2W1G5' >"$DANGEROUS_DUPLICATE"
chmod 0600 "$DANGEROUS_DUPLICATE"
if stealth_profile_get UUID "$DANGEROUS_DUPLICATE" >/dev/null 2>&1; then
    fail "危险前置值加安全尾值绕过了全文件重复门禁"
fi

# %q 的空字符串编码仍须与完整 loader 一致地解码为空。
EMPTY_PROFILE="$TMP_DIR/empty.profile"
printf '%s\n' "CPU_PART=''" >"$EMPTY_PROFILE"
[[ -z "$(stealth_profile_get CPU_PART "$EMPTY_PROFILE")" ]] ||
    fail "单字段读取没有按 loader 语义解码空字符串"

echo "PASS: duplicate profile keys fail closed"

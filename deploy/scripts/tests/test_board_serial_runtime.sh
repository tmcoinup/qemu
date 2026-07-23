#!/usr/bin/env bash
# 验证四个主板厂商的新序列号、MSI board code 和旧 profile 兼容边界。
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
source "$REPO_ROOT/deploy/scripts/lib/stealth-rng.sh"

assert_strict() {
    local manufacturer="$1" serial="$2"
    stealth_board_serial_is_strict "$manufacturer" "$serial" ||
        fail "$manufacturer 严格序列号不合法: $serial"
}

test_random_generators() {
    local serial asus_serial msi_serial gigabyte_serial asrock_serial

    BOARD_SUBSYS_DEV=0x7C08
    BOARD_PRODUCT="H310M PRO-M2 PLUS (MS-7C08)"
    PLATFORM_RELEASE_YEAR=2018
    for _ in $(seq 1 50); do
        serial="$(_serial_asus)"
        assert_strict "ASUSTeK COMPUTER INC." "$serial"
        asus_serial="$serial"

        serial="$(_serial_msi)"
        assert_strict "Micro-Star International Co., Ltd." "$serial"
        [[ "$serial" == 601-7C08-* ]] ||
            fail "MSI H310 序列号没有绑定 7C08 board code: $serial"
        msi_serial="$serial"

        serial="$(_serial_giga)"
        assert_strict "Gigabyte Technology Co., Ltd." "$serial"
        [[ "$serial" == SN18* ]] ||
            fail "GIGABYTE 序列号没有使用平台发布年份 YY: $serial"
        gigabyte_serial="$serial"

        serial="$(_serial_asr)"
        assert_strict "ASRock" "$serial"
        asrock_serial="$serial"
    done

    python3 - "$REPO_ROOT/deploy/hardware/board-vendors.json" \
        "$asus_serial" "$msi_serial" "$gigabyte_serial" "$asrock_serial" <<'PY' ||
import json
import re
import sys

registry = json.load(open(sys.argv[1], encoding="utf-8"))
for token, serial in zip(("asus", "msi", "gigabyte", "asrock"), sys.argv[2:]):
    pattern = registry["vendors"][token]["serial_policy"]["regex"]
    if re.fullmatch(pattern, serial, flags=re.ASCII) is None:
        raise SystemExit(f"{token} runtime serial does not match registry: {serial}")
PY
        fail "运行时序列号与 board-vendors.json 策略漂移"
}

test_policy_negative_cases() {
    if stealth_board_serial_is_strict \
        "Micro-Star International Co., Ltd." \
        "601-7979-01SB0123456789"; then
        fail "MSI 校验器接受了与 H310 7C08 不一致的 board code"
    fi
    if stealth_board_serial_is_strict \
        "Gigabyte Technology Co., Ltd." "SN180000000001"; then
        fail "GIGABYTE 校验器接受了第 00 周"
    fi
    if stealth_board_serial_is_strict \
        "Gigabyte Technology Co., Ltd." "SN185400000001"; then
        fail "GIGABYTE 校验器接受了第 54 周"
    fi
    if stealth_board_serial_is_compatible \
        "ASUSTeK COMPUTER INC." "MB123456789"; then
        fail "兼容校验器接受了非历史生成器格式"
    fi
    if stealth_board_serial_is_strict "QEMU" "MB000000000000"; then
        fail "QEMU generic 校验器接受了全零占位序列号"
    fi
    if stealth_board_serial_is_compatible "QEMU" "A1S2B3C4D5E6"; then
        fail "QEMU generic 校验器接受了物理 ASUS 序列格式"
    fi
}

test_legacy_profile_boundary() {
    local manufacturer serial
    while IFS='|' read -r manufacturer serial; do
        stealth_board_serial_is_legacy "$manufacturer" "$serial" ||
            fail "$manufacturer 历史序列号被拒绝: $serial"
        stealth_board_serial_is_compatible "$manufacturer" "$serial" ||
            fail "$manufacturer 历史序列号不能兼容加载: $serial"
        if stealth_board_serial_is_strict "$manufacturer" "$serial"; then
            fail "$manufacturer 历史序列号被误判为新严格格式: $serial"
        fi
    done <<'ROWS'
ASUSTeK COMPUTER INC.|MB-A1B2C312345
Micro-Star International Co., Ltd.|A1B2123456
Gigabyte Technology Co., Ltd.|SN12345678
ASRock|M80-A1B21234
ROWS
}

test_stable_fallback() {
    local first second

    _stealth_stable_hex() {
        local key="$1" width="$2" digest
        digest="$(printf '%s' "$key" | sha256sum)"
        printf '%s\n' "${digest:0:$width}" | tr '[:lower:]' '[:upper:]'
    }
    _stealth_stable_dec_range() {
        local key="$1" lo="$2" hi="$3" digest
        digest="$(printf '%s' "$key" | sha256sum)"
        printf '%s\n' "$((lo + 16#${digest:0:12} % (hi - lo + 1)))"
    }

    # shellcheck disable=SC2034 # 由 source 后的运行时 helper 读取。
    BOARD_SUBSYS_DEV=0x7C08
    # shellcheck disable=SC2034 # 由 source 后的运行时 helper 读取。
    BOARD_PRODUCT="H310M PRO-M2 PLUS (MS-7C08)"
    # shellcheck disable=SC2034 # 由 source 后的运行时 helper 读取。
    PLATFORM_RELEASE_YEAR=2018

    first="$(_stealth_stable_board_serial \
        "ASUSTeK COMPUTER INC." profile-key)"
    second="$(_stealth_stable_board_serial \
        "ASUSTeK COMPUTER INC." profile-key)"
    [[ "$first" == "$second" ]] ||
        fail "ASUS 稳定 fallback 在相同 key 下发生漂移"
    assert_strict "ASUSTeK COMPUTER INC." "$first"

    first="$(_stealth_stable_board_serial \
        "Micro-Star International Co., Ltd." profile-key)"
    second="$(_stealth_stable_board_serial \
        "Micro-Star International Co., Ltd." profile-key)"
    [[ "$first" == "$second" ]] ||
        fail "MSI 稳定 fallback 在相同 key 下发生漂移"
    assert_strict "Micro-Star International Co., Ltd." "$first"

    first="$(_stealth_stable_board_serial \
        "Gigabyte Technology Co., Ltd." profile-key)"
    second="$(_stealth_stable_board_serial \
        "Gigabyte Technology Co., Ltd." profile-key)"
    [[ "$first" == "$second" ]] ||
        fail "GIGABYTE 稳定 fallback 在相同 key 下发生漂移"
    assert_strict "Gigabyte Technology Co., Ltd." "$first"

    first="$(_stealth_stable_board_serial "ASRock" profile-key)"
    second="$(_stealth_stable_board_serial "ASRock" profile-key)"
    [[ "$first" == "$second" ]] ||
        fail "ASRock 稳定 fallback 在相同 key 下发生漂移"
    assert_strict "ASRock" "$first"

    first="$(_stealth_stable_board_serial "QEMU" profile-key)"
    second="$(_stealth_stable_board_serial "QEMU" profile-key)"
    [[ "$first" == "$second" ]] ||
        fail "QEMU generic 稳定 fallback 在相同 key 下发生漂移"
    assert_strict "QEMU" "$first"
    [[ "$first" =~ ^MB[0-9]{12}$ ]] ||
        fail "QEMU generic fallback 未使用 MB+12 位数字格式: $first"
}

test_qemu_generic_generator() {
    local first second

    # `_serial_qemu` 由 host compatibility 模块提供；只校验虚拟模板自己的
    # 唯一格式，不能借用任何物理主板厂商的标签规则。
    # shellcheck source=/dev/null
    source "$REPO_ROOT/deploy/scripts/lib/stealth-host-platform.sh"
    first="$(_serial_qemu)"
    second="$(_serial_qemu)"
    assert_strict "QEMU" "$first"
    assert_strict "QEMU" "$second"
    [[ "$first" =~ ^MB[0-9]{12}$ && "$second" =~ ^MB[0-9]{12}$ ]] ||
        fail "QEMU generic 随机生成器格式错误: $first / $second"
}

test_msi_profile_generation_and_legacy_reload() {
    local current="$TMP_DIR/msi-current.profile"
    local legacy="$TMP_DIR/msi-legacy.profile"
    local variable

    # shellcheck source=/dev/null
    source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/fixtures/catalog-cpu-preflight-stub.sh"
    export STEALTH_HOST_CPU_VENDOR=GenuineIntel
    export STEALTH_HOST_CPU_MAX_MHZ=5000
    export STEALTH_REQUIRED_TSC_MHZ=
    export STEALTH_PLATFORM_ID="intel-lga1151-i3-9100f-msi-h310m-pro-m2-plus-ms-7c08"
    export CPUS=4

    stealth_pick_profile
    [[ "$BOARD_SERIAL" == 601-7C08-* && ${#BOARD_SERIAL} -eq 23 ]] ||
        fail "MSI profile 没有生成 23 字符 7C08 序列号: $BOARD_SERIAL"
    assert_strict "$BOARD_MFR" "$BOARD_SERIAL"
    assert_strict "$SYSTEM_MFR" "$SYSTEM_SERIAL"
    assert_strict "$BOARD_MFR" "$CHASSIS_SERIAL"
    stealth_save_profile "$current"

    sed \
        -e 's/^BOARD_SERIAL=.*/BOARD_SERIAL=A1B2123456/' \
        -e 's/^SYSTEM_SERIAL=.*/SYSTEM_SERIAL=A1B2123457/' \
        -e 's/^CHASSIS_SERIAL=.*/CHASSIS_SERIAL=A1B2123458/' \
        "$current" >"$legacy"
    for variable in "${_STEALTH_PROFILE_VARS[@]}"; do
        unset "$variable" || true
    done
    STRICT_HARDWARE=1 stealth_load_profile "$legacy" ||
        fail "严格加载拒绝了项目历史 MSI 序列号"
    [[ "$BOARD_SERIAL|$SYSTEM_SERIAL|$CHASSIS_SERIAL" == \
       "A1B2123456|A1B2123457|A1B2123458" ]] ||
        fail "历史 MSI 序列号在加载时发生身份漂移"
}

test_random_generators
test_policy_negative_cases
test_legacy_profile_boundary
test_stable_fallback
test_qemu_generic_generator
test_msi_profile_generation_and_legacy_reload
echo "OK: board serial runtime vendor formats"

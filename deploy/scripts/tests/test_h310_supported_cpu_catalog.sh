#!/usr/bin/env bash
# 验证 PRIME H310M-A R2.0 正常 supported CPU bundle 及 QEMU feature 表面。
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MANIFEST="$REPO_ROOT/deploy/hardware/platforms.json"
QEMU="$REPO_ROOT/build/qemu-system-x86_64"
export PYTHONPATH="$REPO_ROOT/deploy/scripts${PYTHONPATH:+:$PYTHONPATH}"
# shellcheck source=../lib/stealth-platforms.sh
source "$REPO_ROOT/deploy/scripts/lib/stealth-platforms.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equal() {
    local actual="$1" expected="$2" message="$3"
    [[ "$actual" == "$expected" ]] \
        || fail "$message: actual='$actual' expected='$expected'"
}

test_catalog_exports() {
    local id
    stealth_platform_validate >/dev/null
    assert_equal "$(
        python3 - "$MANIFEST" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream)["catalog_revision"])
PY
    )" "2026-07-19.6" "platform catalog revision 错误"

    for id in \
        intel-lga1151-celeron-g4900-asus-prime-h310m-a-r2 \
        intel-lga1151-pentium-g5400-asus-prime-h310m-a-r2 \
        intel-lga1151-i3-9100f-asus-prime-h310m-a-r2; do
        stealth_platform_load "$id"
        assert_equal "$PLATFORM_STATUS" supported "$id 未进入正常 supported 池"
        assert_equal "$BOARD_PRODUCT" "PRIME H310M-A R2.0" "$id 主板错误"
        assert_equal "$CPU_SOCKET" LGA1151 "$id socket 错误"
        assert_equal "$MEM_TYPE:$MEM_MAX_MTS:$MEM_ALLOWED_MTS" \
            "DDR4:2400:2133,2400" "$id DDR4-2400 组合错误"
        [[ "$CPU_QEMU_ARG" == Skylake-Client-IBRS,* ]] \
            || fail "$id 未使用受控 Skylake 基型"
        [[ "$CPU_QEMU_ARG" == *",family=6,model=158,stepping=11,"* ]] \
            || fail "$id 未固定 Intel CPUID 906EB"
        [[ "$CPU_QEMU_ARG" == *",hle=off,rtm=off,"* ]] \
            || fail "$id 没有固定关闭 TSX"
    done

    stealth_platform_load intel-lga1151-celeron-g4900-asus-prime-h310m-a-r2
    assert_equal "$CPU_CORES:$CPU_THREADS:$CPU_PROC_FAMILY:$CPU_SMBIOS_CHARACTERISTICS" \
        "2:2:0x00C7:0x00EC" "G4900 拓扑/SMBIOS 错误"
    assert_equal "$CPU_IGPU_PRESENT:$CPU_IGPU_STATE:$CPU_IGPU_MODEL" \
        "1:disabled_in_bios:Intel UHD Graphics 610" "G4900 UHD 610 策略错误"

    stealth_platform_load intel-lga1151-pentium-g5400-asus-prime-h310m-a-r2
    assert_equal "$CPU_CORES:$CPU_THREADS:$CPU_PROC_FAMILY:$CPU_SMBIOS_CHARACTERISTICS" \
        "2:4:0x000B:0x00FC" "G5400 HT 拓扑/SMBIOS 错误"
    assert_equal "$CPU_IGPU_PRESENT:$CPU_IGPU_STATE:$CPU_IGPU_MODEL" \
        "1:disabled_in_bios:Intel UHD Graphics 610" "G5400 UHD 610 策略错误"

    stealth_platform_load intel-lga1151-i3-9100f-asus-prime-h310m-a-r2
    assert_equal "$CPU_CORES:$CPU_THREADS:$CPU_SMBIOS_CHARACTERISTICS" \
        "4:4:0x00EC" "i3-9100F 拓扑/SMBIOS 错误"
    assert_equal "$CPU_IGPU_PRESENT:$CPU_IGPU_STATE:$CPU_IGPU_MODEL" \
        "0:fused_off:none" "i3-9100F F 后缀核显状态错误"
}

test_strict_mutations() {
    python3 - "$MANIFEST" <<'PY'
import copy
import pathlib
import sys

from platform_manifest import load_manifest, validate_manifest

root = load_manifest(pathlib.Path(sys.argv[1]))


def candidate(data, platform_id):
    return next(item for item in data["platforms"] if item["id"] == platform_id)


def rejected(label, mutate):
    damaged = copy.deepcopy(root)
    mutate(damaged)
    try:
        validate_manifest(damaged)
    except ValueError:
        return
    raise SystemExit(f"FAIL: validator 放行损坏 H310 bundle: {label}")


def change_qemu_property(data, platform_id, old, new):
    cpu = candidate(data, platform_id)["cpu"]
    if old not in cpu["qemu_arg"]:
        raise SystemExit(f"FAIL: 测试前提缺少 {old}")
    cpu["qemu_arg"] = cpu["qemu_arg"].replace(old, new, 1)


celeron = "intel-lga1151-celeron-g4900-asus-prime-h310m-a-r2"
pentium = "intel-lga1151-pentium-g5400-asus-prime-h310m-a-r2"
core_i3 = "intel-lga1151-i3-9100f-asus-prime-h310m-a-r2"
rejected(
    "G4900 恢复 AVX",
    lambda data: change_qemu_property(data, celeron, ",avx=off", ",avx=on"),
)
rejected(
    "G5400 丢失 BMI2 屏蔽",
    lambda data: change_qemu_property(data, pentium, ",bmi2=off", ""),
)
rejected(
    "G5400 丢失 ADX 屏蔽",
    lambda data: change_qemu_property(data, pentium, ",adx=off", ""),
)
rejected(
    "i3-9100F 恢复 TSX",
    lambda data: change_qemu_property(data, core_i3, ",rtm=off", ",rtm=on"),
)
rejected(
    "G5400 缺 HT 位",
    lambda data: candidate(data, pentium)["cpu"]["smbios"].update(
        {"characteristics": "0x00EC"}
    ),
)
rejected(
    "G4900 核显未在 BIOS 禁用",
    lambda data: candidate(data, celeron)["cpu"]["integrated_gpu"].update(
        {"profile_state": "absent"}
    ),
)
rejected(
    "G4900 错配 DDR4-2666",
    lambda data: candidate(data, celeron)["memory"].update(
        {"max_mts": 2666, "allowed_mts": [2133, 2400, 2666]}
    ),
)
rejected(
    "G5400 缺 Intel SKU 来源",
    lambda data: candidate(data, pentium).update(
        {
            "source_refs": [
                ref
                for ref in candidate(data, pentium)["source_refs"]
                if "/sku/129951/" not in ref
            ]
        }
    ),
)
PY
}

test_qemu_realization() {
    local id cores threads encoded cpu_arg smp_arg output
    [[ -x "$QEMU" ]] || return 0
    while IFS=$'\t' read -r id cores threads encoded; do
        cpu_arg="$(printf '%s' "$encoded" | base64 --decode)"
        smp_arg="${threads},sockets=1,cores=${cores},threads=$((threads / cores))"
        output="$(
            printf '{"execute":"qmp_capabilities"}\n{"execute":"quit"}\n' |
                timeout 5 "$QEMU" -machine q35,accel=tcg -nodefaults \
                    -display none -qmp stdio -cpu "$cpu_arg" -smp "$smp_arg" 2>&1
        )" || fail "$id 无法由 QEMU 实例化: $output"
        grep -F '"return": {}' <<<"$output" >/dev/null \
            || fail "$id 未完成 QMP realize"
    done < <(
        python3 - "$MANIFEST" <<'PY'
import base64
import pathlib
import sys

from platform_manifest import load_manifest

root = load_manifest(pathlib.Path(sys.argv[1]))
for platform in root["platforms"]:
    if platform["board"]["product"] != "PRIME H310M-A R2.0":
        continue
    cpu = platform["cpu"]
    encoded = base64.b64encode(cpu["qemu_arg"].encode()).decode()
    print(f"{platform['id']}\t{cpu['cores']}\t{cpu['threads']}\t{encoded}")
PY
    )
}

test_catalog_exports
test_strict_mutations
test_qemu_realization
echo "OK: H310 supported CPU catalog checks passed"

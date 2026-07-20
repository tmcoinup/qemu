#!/usr/bin/env bash
# 验证 E5/AMD 宿主到家用 CPU 完整组合的严格兜底目录。
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MANIFEST="$REPO_ROOT/deploy/hardware/household-compatibility.json"
export PYTHONPATH="$REPO_ROOT/deploy/scripts${PYTHONPATH:+:$PYTHONPATH}"
# shellcheck source=../lib/stealth-household-compat.sh
source "$REPO_ROOT/deploy/scripts/lib/stealth-household-compat.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equal() {
    local actual="$1" expected="$2" message="$3"
    [[ "$actual" == "$expected" ]] \
        || fail "$message: actual='$actual' expected='$expected'"
}

line_count() {
    sed '/^[[:space:]]*$/d' | wc -l | tr -d ' '
}

test_policy_and_index() {
    local rows
    assert_equal "$(stealth_household_compat_validate)" "2026-07-19.6" \
        "catalog revision 错误"
    assert_equal "$(stealth_household_compat_status compat-haswell-i3-4130-h81)" \
        supported "E5 v3/v4 正常候选状态错误"
    stealth_household_compat_is_id compat-zen-athlon-200ge-b350 \
        || fail "合法 household compatibility ID 未被识别"
    if stealth_household_compat_is_id intel-lga1151-i3-9100f-asus-prime-h310m-a-r2; then
        fail "supported 整机 ID 被误识别为 household compatibility"
    fi

    assert_equal "$(stealth_household_compat_index | line_count)" 13 \
        "家用候选总数错误"
    assert_equal "$(stealth_household_compat_index '' '' supported | line_count)" 3 \
        "E5 v3/v4 默认正常候选数错误"
    assert_equal "$(stealth_household_compat_index '' '' compatibility | line_count)" 10 \
        "显式 compatibility 候选数错误"
    for host_class in e5-v1 e5-v2 e5-v3 e5-v4; do
        assert_equal "$(stealth_household_compat_index "$host_class" 2 | line_count)" 1 \
            "$host_class 缺少 2C2T"
        assert_equal "$(stealth_household_compat_index "$host_class" 4 | line_count)" 2 \
            "$host_class 缺少 2C4T/4C4T"
        rows="$(stealth_household_compat_index "$host_class" 6)"
        [[ -z "$rows" ]] || fail "$host_class 错误缩减大 SKU 来伪造 6 线程"
    done
    assert_equal "$(stealth_household_compat_index amd-k10 2 | line_count)" 1 \
        "AMD K10 缺少 2C2T"
    assert_equal "$(stealth_household_compat_index amd-k10 4 | line_count)" 1 \
        "AMD K10 缺少 4C4T"
    assert_equal "$(stealth_household_compat_index amd-zen 4 | line_count)" 2 \
        "AMD Zen 缺少 2C4T/4C4T"
    [[ -z "$(stealth_household_compat_index amd-zen 2)" ]] \
        || fail "AMD Zen 目录虚构了 2 线程型号"

    if stealth_household_compat_index unknown-host 4 >/dev/null 2>&1; then
        fail "未知宿主分类未 fail-closed"
    fi
}

test_classification_and_server_brand_gate() {
    assert_equal "$(stealth_household_compat_classify GenuineIntel 6 45)" e5-v1 \
        "E5 v1 CPUID 分类错误"
    assert_equal "$(stealth_household_compat_classify GenuineIntel 6 62)" e5-v2 \
        "E5 v2 CPUID 分类错误"
    assert_equal "$(stealth_household_compat_classify GenuineIntel 6 63)" e5-v3 \
        "E5 v3 CPUID 分类错误"
    assert_equal "$(stealth_household_compat_classify GenuineIntel 6 79)" e5-v4 \
        "E5 v4 CPUID 分类错误"
    assert_equal "$(stealth_household_compat_classify AuthenticAMD 16 4)" amd-k10 \
        "AMD K10 CPUID 分类错误"
    assert_equal "$(stealth_household_compat_classify AuthenticAMD 23 17)" amd-zen \
        "AMD Zen CPUID 分类错误"
    if stealth_household_compat_classify GenuineIntel 6 85 >/dev/null 2>&1; then
        fail "未知 Intel CPUID 被错误分类"
    fi

    stealth_household_compat_server_brand_forbidden \
        'Intel(R) Xeon(R) CPU E5-2696 v4 @ 2.20GHz' \
        || fail "Xeon host-passthrough 没有被禁用"
    stealth_household_compat_server_brand_forbidden \
        'AMD EPYC 7543 32-Core Processor' \
        || fail "EPYC host-passthrough 没有被禁用"
    stealth_household_compat_server_brand_forbidden \
        'AMD Ryzen Threadripper 1950X 16-Core Processor' \
        || fail "Threadripper host-passthrough 没有被禁用"
    stealth_household_compat_server_brand_forbidden \
        'AMD Opteron 6386 SE' \
        || fail "Opteron host-passthrough 没有被禁用"
    stealth_household_compat_server_brand_forbidden \
        'Intel(R) CPU E-2288G @ 3.70GHz' \
        || fail "去掉 Xeon 前缀的 E 系列没有被禁用"
    stealth_household_compat_host_passthrough_allowed \
        'AMD Ryzen 7 5700X 8-Core Processor' \
        || fail "家用宿主品牌被 server brand 门禁误伤"
}

test_complete_exports() {
    local id classes threads name required field
    while IFS='|' read -r id classes threads name; do
        stealth_household_compat_load "$id"
        assert_equal "$PLATFORM_ID" "$id" "加载后平台 ID 错误"
        if [[ "$classes" == "e5-v3,e5-v4" ]]; then
            assert_equal "$PLATFORM_STATUS" supported \
                "E5 v3/v4 正常池状态错误"
        else
            assert_equal "$PLATFORM_STATUS" compatibility \
                "兜底平台状态错误"
        fi
        assert_equal "$PLATFORM_CPU_SOURCE" named-household-compatibility \
            "CPU 来源标记错误"
        assert_equal "$CPU_THREADS" "$threads" "CPUS 未严格等于 SKU threads"
        assert_equal "$CPU_NAME" "$name" "CPU 名称投影错误"
        [[ "$CPU_NAME" != *Xeon* && "$CPU_NAME" != *EPYC* ]] \
            || fail "客体泄露服务器 CPU 品牌: $CPU_NAME"
        [[ "$CPU_QEMU_ARG" != host && "$CPU_QEMU_ARG" != EPYC* ]] \
            || fail "候选错误使用 host/EPYC CPU 基型: $CPU_QEMU_ARG"
        if [[ "$id" == compat-k10-* ]]; then
            assert_equal "$CPU_FEATURES" +invtsc \
                "K10 必须保留 invariant TSC 且不能伪造 topoext"
            [[ "$CPU_QEMU_ARG" != *"3dnow=off"* &&
               "$CPU_QEMU_ARG" != *"3dnowext=off"* ]] ||
                fail "K10 目录静态关闭了真实 3DNow 能力: $CPU_QEMU_ARG"
        fi
        case "$id" in
            compat-ivy-g2020-p8b75|compat-haswell-g3220-h81)
                assert_equal "$MEM_MAX_MTS:$MEM_ALLOWED_MTS" "1333:1333" \
                    "$id 的 CPU 内存控制器上限必须锁定为 DDR3-1333"
                ;;
            compat-zen-athlon-200ge-b350)
                assert_equal "$NVME_MAX_PCIE_GENERATION:$NVME_LANES" "3:2" \
                    "Athlon 200GE 的 B350 M.2 必须降为 PCIe 3.0 x2"
                ;;
            compat-zen-ryzen3-1200-b350)
                assert_equal "$NVME_MAX_PCIE_GENERATION:$NVME_LANES" "3:4" \
                    "Ryzen 3 1200 的 B350 M.2 应保持 PCIe 3.0 x4"
                ;;
        esac
        if [[ "$CPU_IGPU_PRESENT" == 1 ]]; then
            assert_equal "$CPU_IGPU_STATE" disabled_in_bios "核显未禁用"
        else
            assert_equal "$CPU_IGPU_STATE" absent "无核显状态错误"
            assert_equal "$CPU_IGPU_MODEL" none "无核显型号错误"
        fi
        required=(
            CPU_SMBIOS_UPGRADE CPU_SMBIOS_CHARACTERISTICS BOARD_MFR BOARD_PRODUCT
            BOARD_SUBSYS_VEN PCH_MODEL MEM_TYPE MEM_ALLOWED_MTS MCH_PCI_VEN
            LPC_PCI_DEV SMBUS_PCI_DEV AHCI_PCI_DEV ROOT_PORT_PCI_DEV XHCI_PCI_DEV
            PLATFORM_BOOT_STORAGE PLATFORM_BOOT_MODEL PLATFORM_BOOT_FIRMWARE
            PLATFORM_STORAGE_SWITCH_REQUIRED NVME_ROLE
            NVME_ATTACHMENT NIC_PCI_DEV AUDIO_CODEC_ID BIOS_VENDOR BIOS_VERSION
            BIOS_DATE SYSTEM_MFR SYSTEM_PRODUCT SYSTEM_VERSION CHASSIS_TYPE TPM_CAPABILITY
            TPM_SUPPORTED
        )
        for field in "${required[@]}"; do
            [[ -n "${!field+x}" && -n "${!field}" ]] \
                || fail "$id 未导出完整字段 $field"
        done
        if [[ "$classes" == e5-* || "$classes" == *e5-* ]]; then
            assert_equal "$MEM_TYPE" DDR3 "E5 v1-v4 household 组合必须使用 DDR3"
        fi
        if [[ "$NVME_BOOT_SUPPORTED" == 1 ]]; then
            assert_equal "$PLATFORM_BOOT_STORAGE" nvme "NVMe 启动能力未被使用"
            assert_equal "$PLATFORM_BOOT_MODEL" component "NVMe 型号未交给组件提供"
            assert_equal "$PLATFORM_BOOT_FIRMWARE" component "NVMe 固件未交给组件提供"
            assert_equal "$NVME_ROLE" boot "NVMe 启动角色错误"
        else
            assert_equal "$PLATFORM_BOOT_STORAGE" sata-ahci \
                "无 NVMe 启动能力的旧主板未切换 SATA"
            assert_equal "$PLATFORM_BOOT_MODEL" storage-compatibility-pool \
                "SATA 启动盘没有交给独立合法池"
            assert_equal "$PLATFORM_BOOT_FIRMWARE" storage-compatibility-pool \
                "SATA 固件没有交给独立合法池"
            assert_equal "$PLATFORM_STORAGE_SWITCH_REQUIRED" 1 \
                "旧主板没有要求运行时切换启动盘"
            assert_equal "$NVME_ROLE" data-only "旧主板错误从 NVMe 启动"
        fi
    done < <(stealth_household_compat_index)
}

test_strict_validator_mutations() {
    python3 - "$MANIFEST" <<'PY'
import copy
import json
import pathlib
import sys

from household_compat_manifest import duplicate_guard, load_manifest, validate_manifest

root = load_manifest(pathlib.Path(sys.argv[1]))


def rejected(label, mutate):
    damaged = copy.deepcopy(root)
    mutate(damaged)
    try:
        validate_manifest(damaged)
    except ValueError:
        return
    raise SystemExit(f"FAIL: validator 放行损坏清单: {label}")


def change_cpu_property(data, candidate_id, key, replacement):
    candidate = next(
        item for item in data["candidates"] if item["id"] == candidate_id
    )
    old = f",{key}=off"
    qemu_arg = candidate["cpu"]["qemu_arg"]
    if old not in qemu_arg:
        raise SystemExit(f"FAIL: 测试前提缺少 {candidate_id} 的 {key}=off")
    candidate["cpu"]["qemu_arg"] = qemu_arg.replace(old, replacement, 1)


def force_old_board_nvme_boot(data):
    profile = data["platform_profiles"][0]
    profile["devices"]["nvme"]["boot_supported"] = True
    profile["storage"].update(
        {
            "boot_bus": "nvme",
            "boot_model": "component",
            "boot_firmware": "component",
            "nvme_role": "boot",
            "runtime_switch_required": False,
        }
    )


rejected("未知根字段", lambda data: data.update({"typo": True}))
rejected(
    "静态整机优先级漂移",
    lambda data: data["selection_policy"].update({"priority": "before_supported"}),
)
rejected(
    "E5 v3/v4 正常池被降级",
    lambda data: data["candidates"][6].update({"status": "compatibility"}),
)
rejected(
    "E5 v2 未验证候选被提升",
    lambda data: data["candidates"][3].update({"status": "supported"}),
)
rejected(
    "Xeon 客体品牌",
    lambda data: data["candidates"][0]["cpu"].update(
        {
            "name": "Intel(R) Xeon(R) CPU E5-1603 v3",
            "qemu_arg": (
                "SandyBridge-IBRS,family=6,model=42,stepping=7,"
                "model-id=Intel(R) Xeon(R) CPU E5-1603 v3"
            ),
        }
    ),
)
rejected(
    "去掉 Xeon 前缀的 E 系列",
    lambda data: data["candidates"][0]["cpu"].update(
        {
            "name": "Intel(R) CPU E-2288G @ 3.70GHz",
            "qemu_arg": (
                "SandyBridge-IBRS,family=6,model=42,stepping=7,"
                "model-id=Intel(R) CPU E-2288G @ 3.70GHz"
            ),
        }
    ),
)
rejected(
    "跨厂商宿主类",
    lambda data: data["candidates"][0].update({"host_classes": ["amd-zen"]}),
)
rejected(
    "缩核 6 线程",
    lambda data: data["candidates"][2]["cpu"].update({"cores": 4, "threads": 6}),
)
rejected(
    "G3220 与 i5 合法拓扑互换",
    lambda data: data["candidates"][6]["cpu"].update({"cores": 4, "threads": 4}),
)
rejected(
    "G3220 频率整组漂移",
    lambda data: data["candidates"][6]["cpu"].update(
        {"max_mhz": 5000, "current_mhz": 5000, "tsc_mhz": 5000}
    ),
)
rejected(
    "Haswell 错配 DDR4",
    lambda data: data["platform_profiles"][2]["memory"].update(
        {"type": "DDR4", "voltage_mv": 1200}
    ),
)
rejected(
    "H81 LPC 型号漂移",
    lambda data: data["platform_profiles"][2]["devices"]["chipset"].update(
        {"lpc": ["0x8086", "0xFFFF", "0x05"]}
    ),
)
rejected(
    "H81 BIOS 版本漂移",
    lambda data: data["platform_profiles"][2]["bios"].update({"version": "9999"}),
)
rejected(
    "H81 内存容量与插槽成套漂移",
    lambda data: data["platform_profiles"][2]["board"].update(
        {"dimm_slots": 4, "max_memory_gib": 128}
    ),
)
rejected(
    "Athlon 200GE 错占 Ryzen 的 M.2 x4",
    lambda data: data["platform_profiles"][5]["devices"]["nvme"].update(
        {"lanes": 4}
    ),
)
rejected(
    "G2020 错用 B75 的 DDR3-1600 档",
    lambda data: data["candidates"][3].update({"profile_id": "asus-p8b75-m-ddr3"}),
)
rejected(
    "G3220 错用 H81 的 DDR3-1600 档",
    lambda data: data["candidates"][6].update({"profile_id": "asus-h81m-k-ddr3"}),
)
rejected(
    "核显状态未禁用",
    lambda data: data["candidates"][6]["cpu"]["integrated_gpu"].update(
        {"profile_state": "enabled"}
    ),
)
rejected(
    "2C4T 缺 hardware-threading 位",
    lambda data: data["candidates"][1]["cpu"]["smbios"].update(
        {"characteristics": "0x00EC"}
    ),
)
rejected(
    "旧主板错误声明 NVMe 启动",
    lambda data: data["platform_profiles"][0]["storage"].update(
        {"boot_bus": "nvme", "nvme_role": "boot", "runtime_switch_required": False}
    ),
)
rejected("旧主板成对伪造 NVMe 启动能力", force_old_board_nvme_boot)
rejected(
    "SATA 固件身份漂移",
    lambda data: data["platform_profiles"][0]["storage"].update(
        {"boot_firmware": "unknown"}
    ),
)
rejected(
    "Pentium G630 恢复 AVX",
    lambda data: change_cpu_property(
        data, "compat-sandy-g630-p8h61", "avx", ",avx=on"
    ),
)
rejected(
    "Pentium G2020 丢失 RDRAND 屏蔽",
    lambda data: change_cpu_property(
        data, "compat-ivy-g2020-p8b75", "rdrand", ""
    ),
)
rejected(
    "Pentium G3220 丢失 BMI2 屏蔽",
    lambda data: change_cpu_property(
        data, "compat-haswell-g3220-h81", "bmi2", ""
    ),
)
rejected(
    "K10 静态屏蔽真实 3DNow",
    lambda data: data["candidates"][9]["cpu"].update(
        {"qemu_arg": data["candidates"][9]["cpu"]["qemu_arg"] + ",3dnow=off"}
    ),
)
rejected(
    "K10 伪造 Zen topoext",
    lambda data: data["candidates"][9]["cpu"].update({"features": "+topoext"}),
)
rejected(
    "非官方来源",
    lambda data: data["candidates"][11].update(
        {"source_refs": ["https://example.com/fake"]}
    ),
)
rejected(
    "重复候选 ID",
    lambda data: data["candidates"][1].update({"id": data["candidates"][0]["id"]}),
)

try:
    json.loads('{"schema_version":1,"schema_version":2}', object_pairs_hook=duplicate_guard)
except ValueError:
    pass
else:
    raise SystemExit("FAIL: JSON 重复键未被拒绝")
PY
}

test_qemu_realization() {
    local qemu="$REPO_ROOT/build/qemu-system-x86_64"
    local id cores threads encoded cpu_arg smp_arg output
    [[ -x "$qemu" ]] || return 0
    while IFS=$'\t' read -r id cores threads encoded; do
        cpu_arg="$(printf '%s' "$encoded" | base64 --decode)"
        smp_arg="${threads},sockets=1,cores=${cores},threads=$((threads / cores))"
        # TCG 只验证模型/属性可实例化；真实 KVM 的 enforce=on 由启动预检负责。
        output="$(
            printf '{"execute":"qmp_capabilities"}\n{"execute":"quit"}\n' |
                timeout 5 "$qemu" -machine q35,accel=tcg -nodefaults \
                    -display none -qmp stdio -cpu "$cpu_arg" \
                    -smp "$smp_arg" \
                    2>&1
        )" || fail "$id 无法由 QEMU 实例化: $output"
        grep -F '"return": {}' <<<"$output" >/dev/null \
            || fail "$id 没有完成 QMP realize"
    done < <(
        python3 - "$MANIFEST" <<'PY'
import base64
import pathlib
import sys

from household_compat_manifest import load_manifest

root = load_manifest(pathlib.Path(sys.argv[1]))
for candidate in root["candidates"]:
    cpu = candidate["cpu"]
    # 同时 realize 目录声明的 feature 串；只测基型会漏掉 K10 topoext 这类
    # “JSON 合法但目标代际不存在”的 CPUID 组合。
    encoded = base64.b64encode(
        f"{cpu['qemu_arg']},{cpu['features']}".encode()
    ).decode()
    print(f"{candidate['id']}\t{cpu['cores']}\t{cpu['threads']}\t{encoded}")
PY
    )
}

test_policy_and_index
test_classification_and_server_brand_gate
test_complete_exports
test_strict_validator_mutations
test_qemu_realization
echo "OK: household compatibility catalog checks passed"

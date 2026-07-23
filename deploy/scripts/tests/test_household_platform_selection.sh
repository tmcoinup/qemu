#!/usr/bin/env bash
# 验证宿主感知的家用 CPU 兜底优先级、E5 代际约束和启动盘切换。
# shellcheck disable=SC1091,SC2030,SC2031,SC2054,SC2329
set -euo pipefail
export STEALTH_HOST_PROBE_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../stealth-lib.sh
source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
# shellcheck source=../lib/stealth-storage.sh
source "$REPO_ROOT/deploy/scripts/lib/stealth-storage.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local text="$1" wanted="$2" message="$3"
    [[ "$text" == *"$wanted"* ]] || fail "$message: missing '$wanted'"
}

# 选择器的职责是正确安排真实 KVM smoke；本测试用严格替身记录已加载的候选。
# CPU 模型自身的 TCG realize 与 feature override 由 catalog 专项逐 SKU 覆盖。
sv_validate_cpu_phys_bits() {
    [[ "${CPU_PHYS_BITS:-0}" =~ ^[0-9]+$ ]]
}

sv_validate_cpu_realize() {
    [[ "${CPU_NAME:-}" != *Xeon* &&
       "${CPU_NAME:-}" != *EPYC* &&
       "${CPU_QEMU_ARG:-}" != host ]]
}

set_e5_host() {
    local model="$1"
    export STEALTH_HOST_CPU_VENDOR=GenuineIntel
    export STEALTH_HOST_CPU_FAMILY=6
    export STEALTH_HOST_CPU_MODEL="$model"
    if [[ "$model" == 63 ]]; then
        export STEALTH_HOST_CPU_MODEL_NAME="Intel(R) Xeon(R) CPU E5-2690 v3 @ 2.60GHz"
    else
        export STEALTH_HOST_CPU_MODEL_NAME="Intel(R) Xeon(R) CPU E5-2696 v4 @ 2.20GHz"
    fi
    export STEALTH_HOST_CPU_MAX_MHZ=3700
    export STEALTH_HOST_CPU_CORES=22
    export STEALTH_HOST_CPU_ONLINE_THREADS=44
    export STEALTH_HOST_CPU_PHYS_BITS=46
    export STEALTH_KVM_TSC_CONTROL=0
    export STEALTH_KVM_TSC_KHZ=2194916
    export STEALTH_REQUIRED_TSC_MHZ=2195
    export STRICT_HARDWARE=1
    export STEALTH_TSC_POLICY=auto
    export ALLOW_PLATFORM_COMPATIBILITY=1
    export STEALTH_PLATFORM_ID=
    export STEALTH_SEED=19
    _rng_init
}

test_e5_v4_uses_haswell_household() (
    set_e5_host 79
    export CPUS=4
    export ALLOW_PLATFORM_COMPATIBILITY=0
    stealth_select_platform_bundle
    [[ "$PLATFORM_ID" == compat-haswell-* ]] \
        || fail "E5 v4 未锁定 Haswell 家用目录: $PLATFORM_ID"
    [[ "$CPU_NAME" == *"Core(TM)"* && "$CPU_NAME" != *Xeon* ]] \
        || fail "E5 v4 兜底没有导出家用 CPU: $CPU_NAME"
    [[ "$PLATFORM_CPU_SOURCE" == named-household-compatibility ]] \
        || fail "E5 v4 错误进入 host-passthrough"
    [[ "$PLATFORM_STATUS" == supported ]] \
        || fail "E5 v4 家用 CPU 未进入正常池"
    [[ "$MEM_TYPE" == DDR3 && "$PLATFORM_BOOT_STORAGE" == sata-ahci ]] \
        || fail "Haswell 家用完整组合没有使用 DDR3/SATA"
)

test_e5_v3_uses_default_haswell_household() (
    set_e5_host 63
    export CPUS=4
    export ALLOW_PLATFORM_COMPATIBILITY=0
    stealth_select_platform_bundle
    [[ "$PLATFORM_ID" == compat-haswell-* &&
       "$PLATFORM_STATUS" == supported &&
       "$CPU_NAME" != *Xeon* ]] ||
        fail "E5 v3 无参数正常池选择错误: $PLATFORM_ID"
)

test_e5_v4_two_threads_uses_exact_sku() (
    set_e5_host 79
    export CPUS=2
    export ALLOW_PLATFORM_COMPATIBILITY=0
    stealth_select_platform_bundle
    [[ "$PLATFORM_ID" == compat-haswell-g3220-h81 ]] \
        || fail "E5 v4 2 线程没有选择唯一 2C2T SKU: $PLATFORM_ID"
    [[ "$CPU_CORES" == 2 && "$CPU_THREADS" == 2 ]] \
        || fail "G3220 拓扑被缩放或扩张"
)

test_low_clock_e5_default_pool_is_not_empty() (
    set_e5_host 79
    export STEALTH_HOST_CPU_MAX_MHZ=1600
    export CPUS=4
    export ALLOW_PLATFORM_COMPATIBILITY=0
    stealth_select_platform_bundle
    [[ "$PLATFORM_ID" == compat-haswell-* &&
       "$PLATFORM_STATUS" == supported ]] \
        || fail "低频 E5 默认正常池仍出现空列表"
)

test_supported_platform_stays_first() (
    export STEALTH_HOST_CPU_VENDOR=GenuineIntel
    export STEALTH_HOST_CPU_FAMILY=6
    export STEALTH_HOST_CPU_MODEL=183
    export STEALTH_HOST_CPU_MAX_MHZ=5500
    export STEALTH_REQUIRED_TSC_MHZ=
    export CPUS=4
    export ALLOW_PLATFORM_COMPATIBILITY=1
    export STEALTH_PLATFORM_ID=
    export STRICT_HARDWARE=1
    export STEALTH_SEED=7
    _rng_init
    stealth_select_platform_bundle
    [[ "$PLATFORM_STATUS" == supported && "$PLATFORM_CPU_SOURCE" == manifest ]] \
        || fail "正常 supported 平台没有优先于 compatibility: $PLATFORM_ID"
)

test_allow_flag_is_mandatory() (
    set_e5_host 62
    export CPUS=4
    export ALLOW_PLATFORM_COMPATIBILITY=0
    local err
    err="$(mktemp)"
    if stealth_select_platform_bundle 2>"$err"; then
        rm -f -- "$err"
        fail "E5 v2 未授权时错误进入 compatibility 兜底"
    fi
    grep -F -- "--allow-platform-compatibility" "$err" >/dev/null \
        || fail "空列表错误没有给出显式兜底参数"
    rm -f -- "$err"
)

test_explicit_household_id_needs_allow() (
    set_e5_host 62
    export CPUS=4
    export STEALTH_PLATFORM_ID=compat-ivy-i5-3470-p8b75
    export ALLOW_PLATFORM_COMPATIBILITY=0
    if stealth_select_platform_bundle >/dev/null 2>&1; then
        fail "显式 household ID 未经 allow 被放行"
    fi
)

test_explicit_e5_v4_supported_id_needs_no_allow() (
    set_e5_host 79
    export CPUS=4
    export STEALTH_PLATFORM_ID=compat-haswell-i5-4570-h81
    export ALLOW_PLATFORM_COMPATIBILITY=0
    stealth_select_platform_bundle
    [[ "$PLATFORM_STATUS" == supported &&
       "$CPU_NAME" == *"i5-4570"* ]] ||
        fail "E5 v4 正常池显式 ID 仍错误要求 compatibility 参数"
)

test_e5_v4_supported_tsc_uses_host_clock() (
    set_e5_host 79
    export CPUS=4
    export STEALTH_PLATFORM_ID=compat-haswell-i5-4570-h81
    export ALLOW_PLATFORM_COMPATIBILITY=0
    export STEALTH_HOST_CPU_FLAGS="invtsc tsc_deadline_timer hle rtm"
    stealth_select_platform_bundle
    local cpu_arg
    cpu_arg="$(stealth_qemu_cpu_arg)"
    [[ "$cpu_arg" == *"model-id=Intel(R) Core(TM) i5-4570"* &&
       "$cpu_arg" == *"enforce=on"* &&
       "$cpu_arg" != *"tsc-freq="* &&
       "$cpu_arg" != *Xeon* ]] ||
        fail "E5 v4 正常池生成了虚假 TSC 或服务器 Guest CPU: $cpu_arg"
    export STEALTH_TSC_POLICY=profile
    if stealth_qemu_cpu_arg >/dev/null 2>&1; then
        fail "显式 profile TSC 策略借正常池绕过了无 scaling 门禁"
    fi
)

test_supported_household_rejects_wrong_host_class() (
    set_e5_host 62
    export CPUS=4
    export STEALTH_PLATFORM_ID=compat-haswell-i5-4570-h81
    export ALLOW_PLATFORM_COMPATIBILITY=0
    if stealth_select_platform_bundle >/dev/null 2>&1; then
        fail "E5 v2 错误获得了 E5 v3/v4 正常池"
    fi

    export STEALTH_HOST_CPU_MODEL=85
    if stealth_select_platform_bundle >/dev/null 2>&1; then
        fail "未知 Intel CPUID 错误获得了 E5 v3/v4 正常池"
    fi
)

test_production_host_class_ignores_test_overrides() (
    # 用函数替换模拟一台未收录 Intel 宿主；生产模式必须忽略伪造的 model=79。
    _stealth_household_kernel_cpu_field() {
        case "$1" in
            vendor_id) echo GenuineIntel ;;
            "cpu family") echo 6 ;;
            model) echo 85 ;;
        esac
    }
    export STEALTH_HOST_PROBE_TEST_MODE=0
    export STEALTH_HOST_CPU_VENDOR=GenuineIntel
    export STEALTH_HOST_CPU_FAMILY=6
    export STEALTH_HOST_CPU_MODEL=79
    if stealth_household_compat_current_host_class >/dev/null 2>&1; then
        fail "生产模式误信 STEALTH_HOST_CPU_MODEL=79"
    fi

    export STEALTH_HOST_PROBE_TEST_MODE=1
    [[ "$(stealth_household_compat_current_host_class)" == e5-v4 ]] ||
        fail "显式测试模式无法注入 E5 v4 宿主"
)

test_compatibility_profile_cross_generation_requires_allow() (
    set_e5_host 79
    export CPUS=4
    export STEALTH_KVM_TSC_CONTROL=1
    export STEALTH_REQUIRED_TSC_MHZ=
    export ALLOW_PLATFORM_COMPATIBILITY=1
    stealth_platform_registry_load compat-sandy-i5-2400-p8h61 4
    export ALLOW_PLATFORM_COMPATIBILITY=0
    if stealth_validate_platform_host_constraints >/dev/null 2>&1; then
        fail "E5 v1 compatibility profile 未经 allow 跨代迁移到 E5 v4"
    fi
    export ALLOW_PLATFORM_COMPATIBILITY=1
    stealth_validate_platform_host_constraints ||
        fail "已授权 E5 v1 家用 profile 无法作为 E5 v4 空池兜底"

    export STEALTH_HOST_CPU_VENDOR=AuthenticAMD
    export STEALTH_HOST_CPU_FAMILY=25
    export STEALTH_HOST_CPU_MODEL=1
    export STEALTH_HOST_CPU_MAX_MHZ=5000
    export STEALTH_REQUIRED_TSC_MHZ=
    stealth_platform_registry_load compat-k10-phenom-ii-x4-955-m5a78l 4
    stealth_validate_platform_host_constraints ||
        fail "已授权 AMD K10 家用 profile 无法作为 Zen 空池兜底"
)

test_unknown_host_keeps_explicit_compatibility_fallback() (
    set_e5_host 85
    export STEALTH_HOST_CPU_MODEL_NAME="Intel(R) Core(TM) Processor"
    export STEALTH_REQUIRED_TSC_MHZ=
    export CPUS=4
    export ALLOW_PLATFORM_COMPATIBILITY=1
    export STEALTH_PLATFORM_ID=compat-sandy-i5-2400-p8h61
    stealth_select_platform_bundle
    [[ "$PLATFORM_STATUS" == compatibility &&
       "$CPU_NAME" == *"i5-2400"* ]] ||
        fail "未知 Intel 家用宿主丢失显式 compatibility 兜底"
)

test_missing_runtime_preflight_fails_closed() (
    set_e5_host 79
    export CPUS=4
    export ALLOW_PLATFORM_COMPATIBILITY=0
    unset -f sv_validate_cpu_phys_bits sv_validate_cpu_realize
    local err
    err="$(mktemp)"
    if stealth_select_platform_bundle > /dev/null 2>"$err"; then
        rm -f -- "$err"
        fail "创建入口缺少 CPU/KVM 实现预检时仍选择了平台"
    fi
    grep -F "CPU/KVM 实现预检模块未加载" "$err" >/dev/null ||
        fail "缺少 CPU/KVM 预检的失败没有明确诊断"
    rm -f -- "$err"
)

test_k10_features_follow_physical_host() (
    export ALLOW_PLATFORM_COMPATIBILITY=1
    export STRICT_HARDWARE=1
    export STEALTH_TSC_POLICY=omit
    stealth_platform_registry_load compat-k10-phenom-ii-x4-955-m5a78l 4

    # Family 10h 真机具备 3DNow 时必须完整保留；目录不能用静态 =off 抵消
    # QEMU phenom 基型，最终 -cpu 参数也不能出现动态禁用项。
    export STEALTH_HOST_CPU_FLAGS="3dnow 3dnowext constant_tsc"
    local cpu_arg
    cpu_arg="$(stealth_qemu_cpu_arg)"
    [[ "$cpu_arg" == *"+invtsc"* &&
       "$cpu_arg" != *"+topoext"* &&
       "$cpu_arg" != *"3dnow=off"* &&
       "$cpu_arg" != *"-3dnow"* &&
       "$cpu_arg" != *"-3dnowext"* ]] ||
        fail "K10 真机特性被错误屏蔽或伪造: $cpu_arg"

    # 在已移除 3DNow 的较新宿主上，仍由运行时按实际 CPUID 动态关闭，避免
    # KVM warning；这个兼容动作不能反向污染 K10 目录事实。
    export STEALTH_HOST_CPU_FLAGS="constant_tsc"
    cpu_arg="$(stealth_qemu_cpu_arg)"
    [[ "$cpu_arg" == *",-3dnow,-3dnowext,"* &&
       "$cpu_arg" != *"3dnow=off"* ]] ||
        fail "缺少 3DNow 的宿主没有得到动态 KVM mask: $cpu_arg"
)

test_server_guest_and_bad_topology_are_rejected() (
    export CPU_NAME="Intel(R) Xeon(R) CPU E5-2696 v4 @ 2.20GHz"
    export CPU_QEMU_ARG=host
    export CPU_VENDOR=GenuineIntel
    export PLATFORM_CPU_SOURCE=host-passthrough
    export CPU_IGPU_PRESENT=0
    export CPU_IGPU_STATE=not_exposed
    if stealth_validate_guest_cpu_class >/dev/null 2>&1; then
        fail "服务器 CPU 品牌被 Guest 门禁放行"
    fi
    export CPU_NAME="AMD Ryzen Threadripper 1950X 16-Core Processor"
    export CPU_QEMU_ARG="host"
    export CPU_VENDOR=AuthenticAMD
    if stealth_validate_guest_cpu_class >/dev/null 2>&1; then
        fail "Threadripper 品牌被家用 Guest 门禁放行"
    fi
    export CPU_NAME="Intel(R) CPU E-2288G @ 3.70GHz"
    export CPU_QEMU_ARG="Skylake-Client-IBRS,model-id=Intel(R) CPU E-2288G @ 3.70GHz"
    export CPU_VENDOR=GenuineIntel
    if stealth_validate_guest_cpu_class >/dev/null 2>&1; then
        fail "去掉 Xeon 前缀的 E 系列被 Guest 门禁放行"
    fi
    export CPU_NAME="Intel(R) Core(TM) i3-6100 CPU @ 3.70GHz"
    export CPU_QEMU_ARG="host,model-id=Intel(R) Core(TM) i3-6100 CPU @ 3.70GHz"
    export PLATFORM_CPU_SOURCE=manifest
    if stealth_validate_guest_cpu_class >/dev/null 2>&1; then
        fail "带家用 model-id 的 host 基型绕过 Guest 门禁"
    fi
    export CPU_QEMU_ARG="max,model-id=Intel(R) Core(TM) i3-6100 CPU @ 3.70GHz"
    if stealth_validate_guest_cpu_class >/dev/null 2>&1; then
        fail "通用 max CPU 基型绕过 Guest 门禁"
    fi
    export CPU_QEMU_ARG="qemu64,model-id=Intel(R) Core(TM) i3-6100 CPU @ 3.70GHz"
    if stealth_validate_guest_cpu_class >/dev/null 2>&1; then
        fail "未审计通用 CPU 基型绕过家用 named-model 门禁"
    fi
    export CPU_QEMU_ARG=host
    export CPU_MODEL=host
    export PLATFORM_CPU_SOURCE=host-passthrough
    export PLATFORM_SCHEMA_VERSION=0
    export PLATFORM_STATUS=compatibility
    export ALLOW_PLATFORM_COMPATIBILITY=1
    export PLATFORM_ID=compat-host-intel-q35
    export PLATFORM_IDENTITY_SCOPE=generic_q35_host_passthrough_compatibility
    export PLATFORM_TEMPLATE_DIGEST=fake
    export CPU_HOST_FINGERPRINT=fake
    if stealth_validate_guest_cpu_class >/dev/null 2>&1; then
        fail "legacy profile 自填 host 来源绕过 schema-1 registry 绑定"
    fi

    # legacy 非严格加载也会走统一宿主约束；不能只验证线程数等于 CPUS，
    # 否则手工 profile 可用 3C3T 绕过家用拓扑白名单。
    export CPU_NAME="Intel(R) Core(TM) i3-4130 CPU @ 3.40GHz"
    export CPU_QEMU_ARG="Haswell-v4,model-id=Intel(R) Core(TM) i3-4130 CPU @ 3.40GHz"
    export CPU_VENDOR=GenuineIntel
    export CPU_CORES=3
    export CPU_THREADS=3
    export CPU_MAX_MHZ=3400
    export CPU_TSC_MHZ=3400
    export CPU_IGPU_PRESENT=1
    export CPU_IGPU_STATE=disabled_in_bios
    export CPU_IGPU_MODEL="Intel HD Graphics 4400"
    export CPUS=3
    export STEALTH_HOST_CPU_VENDOR=GenuineIntel
    export STEALTH_HOST_CPU_MAX_MHZ=4000
    export STEALTH_REQUIRED_TSC_MHZ=
    if stealth_validate_platform_host_constraints >/dev/null 2>&1; then
        fail "3C3T legacy/profile 拓扑绕过了统一启动门禁"
    fi

    export STEALTH_HOST_CPU_MODEL_NAME="Intel(R) Core(TM) i3 CPU"
    export STEALTH_HOST_CPU_CORES=3
    export STEALTH_HOST_CPU_ONLINE_THREADS=3
    if STEALTH_KVM_TSC_KHZ=3000000 \
       stealth_host_platform_load compat-host-intel-q35 3 >/dev/null 2>&1; then
        fail "3C3T host-passthrough 被拓扑门禁放行"
    fi
)

test_storage_bus_follows_bundle() (
    export DISK=/tmp/vmate-household-storage.qcow2
    export NVME_SERIAL=S123N1234567890
    export NVME_MODEL="Samsung SSD 970 PRO 512GB"
    export NVME_FIRMWARE=1B2QEXP7
    export NVME_SUBSYS_VEN=0x144D
    export NVME_SUBSYS_DEV=0xA801
    export NVME_SUBNQN=nqn.2014-08.org.nvmexpress:uuid:test
    export NVME_COMPONENT_ID=samsung-970-pro-512gb
    export NVME_SIZE_BYTES=512110190592

    stealth_platform_registry_load compat-haswell-i5-4570-h81 4
    stealth_storage_compat_load samsung-850-pro-512gb-sata
    export BOOT_STORAGE_SERIAL=S123456789ABCDE
    stealth_build_boot_storage_args
    assert_contains "${BOOT_STORAGE_ARGS[*]}" "ide-hd,bus=ide.2,unit=0" \
        "DDR3 平台没有切换到 SATA"
    [[ "${BOOT_STORAGE_ARGS[*]}" != *"nvmectl0"* ]] \
        || fail "DDR3 平台仍创建 NVMe 启动控制器"

    stealth_platform_registry_load compat-zen-ryzen3-1200-b350 4
    export BOOT_STORAGE_CATALOG_REVISION="$COMPONENT_CATALOG_REVISION"
    export BOOT_STORAGE_COMPONENT_ID="$NVME_COMPONENT_ID"
    export BOOT_STORAGE_MANUFACTURER=Samsung
    export BOOT_STORAGE_MODEL="$NVME_MODEL"
    export BOOT_STORAGE_PART_NUMBER=component-catalog
    export BOOT_STORAGE_FIRMWARE="$NVME_FIRMWARE"
    export BOOT_STORAGE_SIZE_BYTES="$NVME_SIZE_BYTES"
    export BOOT_STORAGE_INTERFACE=nvme
    export BOOT_STORAGE_SERIAL="$NVME_SERIAL"
    stealth_build_boot_storage_args
    assert_contains "${BOOT_STORAGE_ARGS[*]}" "nvme,id=nvmectl0" \
        "B350 原生 NVMe 启动路径丢失"
)

test_storage_devices_realize_in_qemu() (
    local qemu="$REPO_ROOT/build/qemu-system-x86_64"
    local qemu_img="$REPO_ROOT/build/qemu-img"
    [[ -x "$qemu" && -x "$qemu_img" ]] || return 0
    local disk output platform
    local -a command
    disk="$(mktemp /tmp/vmate-household-storage.XXXXXX.qcow2)"
    trap 'rm -f -- "$disk"' EXIT
    "$qemu_img" create -q -f qcow2 "$disk" 16M

    export DISK="$disk"
    export NVME_SERIAL=S123N1234567890
    export NVME_MODEL="Samsung SSD 970 PRO 512GB"
    export NVME_FIRMWARE=1B2QEXP7
    export NVME_SUBSYS_VEN=0x144D
    export NVME_SUBSYS_DEV=0xA801
    export NVME_SUBNQN=nqn.2014-08.org.nvmexpress:uuid:01234567-89ab-4cde-8f01-23456789abcd
    export NVME_COMPONENT_ID=samsung-970-pro-512gb
    export NVME_SIZE_BYTES=512110190592

    for platform in \
        compat-haswell-i5-4570-h81 \
        compat-zen-ryzen3-1200-b350; do
        stealth_platform_registry_load "$platform" 4
        if [[ "$PLATFORM_BOOT_STORAGE" == sata-ahci ]]; then
            stealth_storage_compat_load samsung-840-pro-512gb-sata
            export BOOT_STORAGE_SERIAL=S123456789ABCDE
        else
            export BOOT_STORAGE_CATALOG_REVISION="$COMPONENT_CATALOG_REVISION"
            export BOOT_STORAGE_COMPONENT_ID="$NVME_COMPONENT_ID"
            export BOOT_STORAGE_MANUFACTURER=Samsung
            export BOOT_STORAGE_MODEL="$NVME_MODEL"
            export BOOT_STORAGE_PART_NUMBER=component-catalog
            export BOOT_STORAGE_FIRMWARE="$NVME_FIRMWARE"
            export BOOT_STORAGE_SIZE_BYTES="$NVME_SIZE_BYTES"
            export BOOT_STORAGE_INTERFACE=nvme
            export BOOT_STORAGE_SERIAL="$NVME_SERIAL"
        fi
        stealth_build_boot_storage_args
        command=(
            "$qemu" -machine q35,accel=tcg -nodefaults -display none
            -qmp stdio
        )
        if [[ "$PLATFORM_BOOT_STORAGE" == nvme ]]; then
            command+=(-device pcie-root-port,id=rp1,bus=pcie.0)
        fi
        command+=("${BOOT_STORAGE_ARGS[@]}")
        output="$(
            printf '%s\n' \
                '{"execute":"qmp_capabilities"}' \
                '{"execute":"quit","id":"storage-done"}' |
                timeout 8 "${command[@]}" 2>&1
        )" || fail "$platform 启动盘设备无法实例化: $output"
        grep -F '"id": "storage-done"' <<<"$output" >/dev/null \
            || fail "$platform 启动盘没有完成 QMP realize"
    done
)

test_e5_v4_uses_haswell_household
test_e5_v3_uses_default_haswell_household
test_e5_v4_two_threads_uses_exact_sku
test_low_clock_e5_default_pool_is_not_empty
test_supported_platform_stays_first
test_allow_flag_is_mandatory
test_explicit_household_id_needs_allow
test_explicit_e5_v4_supported_id_needs_no_allow
test_e5_v4_supported_tsc_uses_host_clock
test_supported_household_rejects_wrong_host_class
test_production_host_class_ignores_test_overrides
test_compatibility_profile_cross_generation_requires_allow
test_unknown_host_keeps_explicit_compatibility_fallback
test_missing_runtime_preflight_fails_closed
test_k10_features_follow_physical_host
test_server_guest_and_bad_topology_are_rejected
test_storage_bus_follows_bundle
test_storage_devices_realize_in_qemu
echo "OK: household platform selection and storage checks passed"

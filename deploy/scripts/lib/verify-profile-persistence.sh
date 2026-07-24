#!/usr/bin/env bash
# verify-stealth.sh 的 profile 持久化专项检查。
# shellcheck disable=SC1091 # 路径由调用方的 deploy/scripts 根目录确定。

verify_profile_persistence() (
    set -euo pipefail

    local script_dir="$1"
    local temp_dir profile_file legacy_profile_file log_file
    local serial_in_file serial_load_1 serial_load_2 second_slot_serial
    local legacy_serial_1 legacy_serial_2

    source "$script_dir/stealth-lib.sh"

    load_profile_mem_serial() (
        local load_path="$1" allow_legacy="$2" field

        # 每次都模拟独立进程，避免上一次 profile 的全局变量掩盖输入缺失。
        for field in "${_STEALTH_PROFILE_VARS[@]}"; do
            unset "$field"
        done
        export ALLOW_LEGACY_PROFILE="$allow_legacy"
        stealth_load_profile "$load_path"
        printf '%s\n' "$MEM_SERIAL"
    )

    # 本项只验证 profile 序列化，固定已审计平台并显式加载目录预检替身，
    # 不让构建机的 /dev/kvm、CPU 型号、调用方环境或随机选择影响结果。
    source "$script_dir/tests/fixtures/catalog-cpu-preflight-stub.sh"
    export STEALTH_PLATFORM_ID=intel-lga1151-i3-9100f-asus-prime-h310m-a-r2
    export STEALTH_HOST_CPU_VENDOR=GenuineIntel STEALTH_HOST_CPU_MAX_MHZ=5000
    export STEALTH_REQUIRED_TSC_MHZ='' CPUS=4 MEM_TOTAL_MB=8192
    export ALLOW_PLATFORM_COMPATIBILITY=0 STRICT_HARDWARE=0

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/verify-stealth-profile.XXXXXX")"
    profile_file="$temp_dir/profile"
    legacy_profile_file="$temp_dir/legacy-profile"
    log_file="$temp_dir/pick.log"
    trap 'rm -f -- "$profile_file" "$legacy_profile_file" "$log_file"; rmdir -- "$temp_dir" 2>/dev/null || true' EXIT

    (
        stealth_pick_profile
        stealth_save_profile "$profile_file"
        echo "  pick 时 MEM_SERIAL = $MEM_SERIAL"
    ) >"$log_file"
    cat "$log_file"

    serial_in_file="$(grep '^MEM_SERIAL=' "$profile_file" | cut -d= -f2 | tr -d "'\"")"
    echo "  写入 profile 文件   = $serial_in_file"
    serial_load_1="$(load_profile_mem_serial "$profile_file" 0)"
    serial_load_2="$(load_profile_mem_serial "$profile_file" 0)"
    echo "  load 第 1 次        = $serial_load_1"
    echo "  load 第 2 次        = $serial_load_2"
    if [[ "$serial_in_file" != "$serial_load_1" ||
          "$serial_load_1" != "$serial_load_2" ]]; then
        echo "FAIL: DIMM SN 在 save→load→load 之间漂移"
        return 1
    fi
    echo "  ✓ DIMM SN 跨重启一致"

    second_slot_serial="$(_stealth_memory_slot_serial "$serial_in_file" 2)"
    if [[ -z "$second_slot_serial" || "$second_slot_serial" == "$serial_in_file" ]]; then
        echo "FAIL: 8GB 双通道 DIMM 序列号重复"
        return 1
    fi
    echo "  ✓ DIMM_A2/B2 序列号独立: $serial_in_file / $second_slot_serial"

    # 当前 schema-1 profile 缺身份字段必须拒绝；这里移除整套 schema 元数据，
    # 构造真正受 ALLOW_LEGACY_PROFILE 管控的 schema-0 历史输入来验证稳定回填。
    sed -E \
        '/^(MEM_SERIAL|PLATFORM_SCHEMA_VERSION|PLATFORM_CATALOG_REVISION|PLATFORM_ID|PLATFORM_STATUS|PLATFORM_RELEASE_YEAR)=/d' \
        "$profile_file" >"$legacy_profile_file"
    chmod 600 "$legacy_profile_file"
    legacy_serial_1="$(load_profile_mem_serial "$legacy_profile_file" 1)"
    legacy_serial_2="$(load_profile_mem_serial "$legacy_profile_file" 1)"
    if [[ -z "$legacy_serial_1" || "$legacy_serial_1" != "$legacy_serial_2" ]]; then
        echo "FAIL: 老 profile fallback 不稳定 ($legacy_serial_1 vs $legacy_serial_2)"
        return 1
    fi
    echo "  ✓ 老 profile fallback 派生稳定: $legacy_serial_1"
)

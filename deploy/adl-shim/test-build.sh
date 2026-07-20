#!/usr/bin/env bash
# 无需 Windows 客体即可执行的 ADL 双架构 ABI、身份契约与可复现构建验收。
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for tool in llvm-readobj sha256sum strings; do
    command -v "$tool" >/dev/null || fail "缺少测试工具: $tool"
done

LC_ALL=C sort -c adl-required-exports.txt \
    || fail "adl-required-exports.txt 未稳定排序"
[[ "$(wc -l < adl-required-exports.txt)" -eq \
   "$(LC_ALL=C sort -u adl-required-exports.txt | wc -l)" ]] \
    || fail "adl-required-exports.txt 存在重复项"

tmp_dir="$(mktemp -d --tmpdir adl-shim-test.XXXXXX)"
cleanup() {
    find "$tmp_dir" -type f -delete
    rmdir "$tmp_dir"
}
trap cleanup EXIT

# 锁定 GPU-Z 2.70 二进制通过 GetProcAddress 探测的 45 个名称。
while IFS= read -r symbol; do
    grep -Fx "$symbol" adl-required-exports.txt >/dev/null \
        || fail "GPU-Z 2.70 必需导出缺失: $symbol"
done <<'EOF'
ADL_Main_Control_Create
ADL2_Main_ControlX2_Create
ADL2_Main_Control_Create
ADL2_Main_Control_Destroy
ADL_Main_Control_Destroy
ADL_Adapter_NumberOfAdapters_Get
ADL_Adapter_AdapterInfo_Get
ADL_Adapter_Active_Get
ADL2_Adapter_Graphic_Core_Info_Get
ADL_Adapter_MemoryInfo_Get
ADL_Adapter_MemoryInfo3_Get
ADL_Overdrive5_CurrentActivity_Get
ADL_Display_WriteAndReadI2C
ADL_Adapter_Accessibility_Get
ADL_Overdrive5_FanSpeed_Get
ADL2_OverdriveN_FanControl_Get
ADL_Overdrive5_ODParameters_Get
ADL_Overdrive5_ODPerformanceLevels_Get
ADL_Overdrive5_ODPerformanceLevels_Set
ADL2_OverdriveN_SystemClocks_Get
ADL2_OverdriveN_MemoryClocks_Get
ADL2_OverdriveN_SystemClocksX2_Get
ADL2_OverdriveN_MemoryClocksX2_Get
ADL_Overdrive5_PowerControlInfo_Get
ADL_Overdrive5_PowerControl_Get
ADL_Overdrive5_Temperature_Get
ADL2_Adapter_VRAMUsage_Get
ADL_PowerXpress_Config_Caps
ADL_Overdrive_Caps
ADL2_OverdriveN_Capabilities_Get
ADL2_OverdriveN_CapabilitiesX2_Get
ADL2_OverdriveN_PerformanceStatus_Get
ADL2_OverdriveN_Temperature_Get
ADL2_Adapter_PMLog_Support_Get
ADL2_New_QueryPMLogData_Get
ADL2_Desktop_Device_Create
ADL2_Adapter_PMLog_Start
ADL2_Desktop_Device_Destroy
ADL2_Adapter_PMLog_Stop
ADL2_Overdrive8_Init_SettingX2_Get
ADL2_Overdrive8_Current_SettingX2_Get
ADL_Adapter_ObservedGameClockInfo_Get
ADL_Adapter_Crossfire_Caps
ADL_Adapter_Crossfire_Get
ADL_Adapter_VideoBiosInfo_Get
EOF

check_dll() {
    local dll=$1
    local expected_format=$2
    local objdump_tool=$3
    local actual_exports="$tmp_dir/$dll.exports"
    local headers imports

    [[ -s "$dll" ]] || fail "$dll 不存在或为空"
    headers="$(llvm-readobj --file-headers "$dll")"
    grep -F "Format: $expected_format" <<<"$headers" >/dev/null \
        || fail "$dll 架构不是 $expected_format"

    llvm-readobj --coff-exports "$dll" |
        awk '/^  Name: / { print $2 }' |
        LC_ALL=C sort >"$actual_exports"
    diff -u adl-required-exports.txt "$actual_exports" \
        || fail "$dll 导出集合与 manifest 不一致"

    imports="$($objdump_tool -p "$dll")"
    grep -E '^Time/Date stamp[[:space:]]+0$' <<<"$imports" >/dev/null \
        || fail "$dll 链接时间戳不为 0"
    grep -F 'DLL Name: ADVAPI32.dll' <<<"$imports" >/dev/null \
        || fail "$dll 缺少 64 位注册表读取所需 ADVAPI32"
    grep -F 'DLL Name: SETUPAPI.dll' <<<"$imports" >/dev/null \
        || fail "$dll 缺少实际 Display 实例枚举所需 SETUPAPI"
    grep -F 'CM_Get_Device_IDA' <<<"$imports" >/dev/null \
        || fail "$dll 未导入 Configuration Manager 的实际实例读取"
    grep -F 'CM_Get_DevNode_Registry_PropertyA' <<<"$imports" >/dev/null \
        || fail "$dll 未导入 Configuration Manager 的实际 BDF 读取"
    if grep -F 'DLL Name: libwinpthread-1.dll' <<<"$imports" >/dev/null; then
        fail "$dll 不应依赖额外 MinGW pthread 运行库"
    fi

    for value_name in CurrentIdentity IdentitySchemaVersion IdentityId \
        SpoofName SpoofVendor SpoofBios SourceInstanceId IdentityMode \
        SpoofPciVendorId SpoofPciDeviceId SpoofSubsystemVendorId \
        SpoofSubsystemDeviceId SpoofRevisionId SpoofPciBusId \
        SpoofPciSlotId SpoofPciFunctionId SpoofRamMb SpoofMemoryType \
        SpoofMemoryBusWidthBits SpoofBaseClockKHz SpoofBoostClockKHz \
        SpoofMemoryClockKHz SpoofSliSupported; do
        strings -a "$dll" | grep -Fx "$value_name" >/dev/null \
            || fail "$dll 缺少注册表契约字段: $value_name"
    done
}

check_dll atiadlxy.dll COFF-i386 i686-w64-mingw32-objdump
check_dll atiadlxx.dll COFF-x86-64 x86_64-w64-mingw32-objdump

contract_test="$tmp_dir/adl-contract-test"
"${HOST_CC:-cc}" -std=c11 -Wall -Wextra -Werror -Wformat=2 \
    -I../gpu-api-common -o "$contract_test" test-contract.c \
        adl_identity_contract.c adl_init_policy.c adl_profile.c
"$contract_test"
identity_cache_test="$tmp_dir/adl-identity-cache-test"
"${HOST_CC:-cc}" -std=c11 -Wall -Wextra -Werror -Wformat=2 \
    -I../gpu-api-common -o "$identity_cache_test" test-identity-cache.c \
        adl_identity_cache.c
"$identity_cache_test"
context_handle_test="$tmp_dir/adl-context-handle-test"
"${HOST_CC:-cc}" -std=c11 -Wall -Wextra -Werror -Wformat=2 \
    -o "$context_handle_test" test-context-handle.c adl_context_handle.c
"$context_handle_test"
carrier_contract_test="$tmp_dir/adl-carrier-contract-test"
"${HOST_CC:-cc}" -std=c11 -Wall -Wextra -Werror -Wformat=2 \
    -I../gpu-api-common -o "$carrier_contract_test" \
        ../gpu-api-common/test-carrier-validation.c \
        ../gpu-api-common/carrier_validation_contract.c
"$carrier_contract_test"

# 与 AMD 官方 public headers 对应的 bootstrap/core 函数指针 ABI 断言。
for compiler in i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc; do
    "$compiler" -std=c11 -Wall -Wextra -Werror -Wformat=2 -fno-ident \
        -c -o "$tmp_dir/$compiler-core-abi.o" test-core-abi.c
done

# 除 GPU-Z trace 外，锁定所有检测工具可依赖的官方最小 bootstrap/core 集。
while IFS= read -r symbol; do
    grep -Fx "$symbol" adl-required-exports.txt >/dev/null \
        || fail "官方 bootstrap/core 导出缺失: $symbol"
done <<'EOF'
ADL_Main_Control_Create
ADL_Main_ControlX2_Create
ADL_Main_Control_Refresh
ADL_Main_Control_Destroy
ADL_Main_Control_GetProcAddress
ADL2_Main_Control_Create
ADL2_Main_ControlX2_Create
ADL2_Main_ControlX3_Create
ADL2_Main_Control_Refresh
ADL2_Main_Control_Destroy
ADL2_Main_Control_GetProcAddress
ADL_Adapter_NumberOfAdapters_Get
ADL2_Adapter_NumberOfAdapters_Get
ADL_Adapter_AdapterInfo_Get
ADL2_Adapter_AdapterInfo_Get
ADL_Adapter_AdapterInfoX2_Get
ADL2_Adapter_AdapterInfoX2_Get
ADL2_Adapter_AdapterInfoX3_Get
ADL2_Adapter_AdapterInfoX4_Get
ADL_Graphics_Versions_Get
ADL2_Graphics_Versions_Get
ADL2_Graphics_VersionsX2_Get
ADL2_Graphics_VersionsX3_Get
EOF

# 并发提交期间只能按 pointer -> snapshot -> pointer/schema 顺序观察身份。
grep -F 'KEY_WOW64_64KEY' adl_identity_win.c >/dev/null \
    || fail "x86 reader 未固定 64 位注册表视图"
if grep -R -F '<stdatomic.h>' --include='*.c' --include='*.h' . >/dev/null; then
    fail "发布 DLL 不得依赖 C11 atomic 或 MinGW pthread 运行库"
fi
if grep -F 'InitOnceExecuteOnce' adl_identity_win.c >/dev/null; then
    fail "Refresh 不得固定到 InitOnce 的首次身份快照"
fi
grep -F 'adl_identity_cache_refresh' adl_identity_win.c >/dev/null \
    || fail "ADL refresh 未进入可重载身份缓存"
grep -F 'adl_identity_refresh()' adl_runtime.c >/dev/null \
    || fail "ADL runtime refresh 未重新读取身份 snapshot"
grep -F 'if (state != ADL_IDENTITY_INVALID)' adl_identity_cache.c >/dev/null \
    || fail "无效 refresh 不得覆盖已验证 snapshot"
initial_line="$(grep -n -F \
    'read_current_identity_pointer(root, initial_pointer)' \
    adl_identity_win.c | cut -d: -f1)"
snapshot_line="$(grep -n -F \
    'load_and_validate_identity(version_key, initial_pointer, candidate' \
    adl_identity_win.c | cut -d: -f1)"
final_line="$(grep -n -F \
    'read_current_identity_pointer(root, final_pointer)' \
    adl_identity_win.c | cut -d: -f1)"
schema_line="$(grep -n -F \
    'read_registry_dword(version_key, "IdentitySchemaVersion"' \
    adl_identity_win.c | tail -1 | cut -d: -f1)"
[[ -n "$initial_line" && -n "$snapshot_line" && -n "$final_line" &&
   -n "$schema_line" && "$initial_line" -lt "$snapshot_line" &&
   "$snapshot_line" -lt "$final_line" && "$final_line" -lt "$schema_line" ]] \
    || fail "reader 未遵守 pointer -> snapshot -> pointer/schema"
grep -F 'stealth_validate_virtio_gpu_carrier_windows' adl_identity_win.c >/dev/null \
    || fail "ADL reader 未绑定到实际 Windows virtio 实例"
for contract in SetupDiGetClassDevsA SetupDiEnumDeviceInfo \
    CM_Get_Device_IDA CM_DRP_BUSNUMBER CM_DRP_ADDRESS SPDRP_HARDWAREID \
    SPDRP_SERVICE SPDRP_DRIVER; do
    grep -F "$contract" ../gpu-api-common/carrier_validation_win.c >/dev/null \
        || fail "实际 carrier 验证缺少标准 Windows 契约: $contract"
done
grep -F 'VioGpuDod' ../gpu-api-common/carrier_validation_contract.c >/dev/null \
    || fail "实际 carrier 验证未限制 stock VioGpuDod 服务"
for field in carrier.instance_id carrier.hardware_id \
    carrier.driver_registry_path carrier.driver_key; do
    grep -F "$field" adl_core.c >/dev/null \
        || fail "ADL AdapterInfo 未传递已验证的真实 $field"
done

grep -F 'input->pci_vendor_id != AMD_PCI_VENDOR_ID' \
    adl_identity_contract.c >/dev/null \
    || fail "AMD vendor 1002 门禁缺失"
grep -F 'source_subsystem_vendor' adl_identity_contract.c >/dev/null \
    || fail "SourceInstance SUBSYS 未交叉校验"
grep -F 'source_revision' adl_identity_contract.c >/dev/null \
    || fail "SourceInstance REV 未交叉校验"
grep -F 'ADL_ERR_NOT_SUPPORTED' adl_unsupported.c >/dev/null \
    || fail "无来源遥测没有 fail-closed"
if grep -F 'HeapAlloc' adl_runtime.c >/dev/null; then
    fail "ADL context destroy 后不得保留永久 heap allocation"
fi
[[ "$(grep -F 'adl_init_threading_model_status(threading_model)' \
    adl_core.c adl_core_extended.c | wc -l)" -eq 3 ]] \
    || fail "所有 X2/X3 threading model 入口必须执行统一策略"
if grep -R -E 'GetModuleFileName|GetCommandLine|CreateToolhelp32Snapshot' \
        --include='*.c' --include='*.h' . >/dev/null; then
    fail "系统级 ADL shim 不得按检测进程名称特判"
fi

# 所有维护文件采用更严格的物理行数上限。
while IFS= read -r source; do
    lines="$(wc -l <"$source")"
    [[ "$lines" -le 500 ]] || fail "$source 共 $lines 行，超过 500 行"
done < <(find . -maxdepth 1 -type f \
    \( -name '*.c' -o -name '*.h' -o -name '*.sh' -o -name 'Makefile' \) \
    -printf '%f\n' | LC_ALL=C sort)
while IFS= read -r source; do
    lines="$(wc -l <"$source")"
    [[ "$lines" -le 500 ]] || fail "$source 共 $lines 行，超过 500 行"
done < <(find ../gpu-api-common -maxdepth 1 -type f \
    \( -name '*.c' -o -name '*.h' \) -printf '%p\n' | LC_ALL=C sort)

# 再构建一次并比较字节，锁定无 PE timestamp 的可复现输出。
sha256sum atiadlxy.dll atiadlxx.dll >"$tmp_dir/first.sha256"
make clean all >/dev/null
sha256sum atiadlxy.dll atiadlxx.dll >"$tmp_dir/second.sha256"
cmp -s "$tmp_dir/first.sha256" "$tmp_dir/second.sha256" \
    || fail "连续两次 ADL 构建的 SHA256 不一致"

echo "PASS: x86/x64 AMD ADL ABI、可刷新身份、可回收 context 与身份契约"

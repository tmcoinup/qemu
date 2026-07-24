#!/usr/bin/env bash
# 对双架构产物做无需 Windows 客体即可执行的 PE/ABI 静态验收。
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

check_dll() {
    local dll=$1
    local objdump=$2
    local expected_format=$3
    local headers exports

    [[ -s "$dll" ]] || fail "$dll 不存在或为空"
    headers="$($objdump -f "$dll")"
    grep -F "file format $expected_format" <<<"$headers" >/dev/null \
        || fail "$dll 机器架构不是 $expected_format"

    exports="$($objdump -p "$dll")"
    grep -F 'The Export Tables' <<<"$exports" >/dev/null \
        || fail "$dll 缺少 PE export table"
    # binutils 2.45 起会在名称前打印 “+base[ordinal] hint”，旧版只打印
    # “[index] name”。同时接受两种官方 objdump 布局，但仍锁定唯一无修饰名称。
    [[ "$(grep -Ec '^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]+(\+base\[[[:space:]]*[0-9]+\][[:space:]]+)?([[:xdigit:]]+[[:space:]]+)?nvapi_QueryInterface$' <<<"$exports")" -eq 1 ]] \
        || fail "$dll 没有且仅有一个无修饰 nvapi_QueryInterface 导出"
    grep -E '^\s*\[Name Pointer/Ordinal\] Table\s+0*1$' <<<"$exports" >/dev/null \
        || fail "$dll 导出名称数量不是 1"
    grep -E '^Time/Date stamp\s+0$' <<<"$exports" >/dev/null \
        || fail "$dll 链接时间戳不为 0，产物不可复现"
    grep -F 'DLL Name: ADVAPI32.dll' <<<"$exports" >/dev/null \
        || fail "$dll 未链接注册表所需 ADVAPI32.dll"
    grep -F 'DLL Name: SETUPAPI.dll' <<<"$exports" >/dev/null \
        || fail "$dll 未链接实际 Display 实例枚举所需 SETUPAPI"
    grep -F 'CM_Get_Device_IDA' <<<"$exports" >/dev/null \
        || fail "$dll 未导入 Configuration Manager 的实际实例读取"
    grep -F 'CM_Get_DevNode_Registry_PropertyA' <<<"$exports" >/dev/null \
        || fail "$dll 未导入 Configuration Manager 的实际 BDF 读取"
    grep -F 'DLL Name: libwinpthread-1.dll' <<<"$exports" >/dev/null \
        && fail "$dll 不应依赖额外的 MinGW pthread 运行库"
    [[ "$(LC_ALL=C grep -aob $'\xb1\xae\x3b\xc3' "$dll" | wc -l)" -eq 1 ]] \
        || fail "$dll 未精确包含 GetGPUType QueryInterface ID"
    [[ "$(LC_ALL=C grep -aob $'\x68\xb3\xf9\x07' "$dll" | wc -l)" -eq 1 ]] \
        || fail "$dll 未精确包含 GetMemoryInfo QueryInterface ID"
    [[ "$(LC_ALL=C grep -aob $'\x98\x94\x59\xc0' "$dll" | wc -l)" -eq 1 ]] \
        || fail "$dll 未精确包含 GetMemoryInfoEx QueryInterface ID"

    # 两个位数必须包含完全相同的配置契约，防止其中一个仍使用硬编码身份。
    for value_name in CurrentIdentity IdentitySchemaVersion IdentityId \
        SpoofName SpoofVendor SpoofBios SourceInstanceId IdentityMode \
        SpoofPciVendorId SpoofPciDeviceId SpoofSubsystemVendorId \
        SpoofSubsystemDeviceId SpoofRevisionId SpoofPciBusId \
        SpoofPciSlotId SpoofPciFunctionId SpoofRamMb SpoofMemoryType \
        SpoofMemoryBusWidthBits SpoofBaseClockKHz SpoofBoostClockKHz \
        SpoofMemoryClockKHz SpoofSliSupported; do
        LC_ALL=C grep -aF "$value_name" "$dll" >/dev/null \
            || fail "$dll 缺少注册表值 $value_name"
    done
}

check_dll nvapi.dll i686-w64-mingw32-objdump pei-i386
check_dll nvapi64.dll x86_64-w64-mingw32-objdump pei-x86-64

# 用宿主机编译器执行与 DLL 共用的 PCI 组合实现，并锁定官方状态码。
contract_test="$(mktemp --tmpdir nvapi-contract-test.XXXXXX)"
aib_contract_test="$(mktemp --tmpdir nvapi-aib-contract-test.XXXXXX)"
carrier_contract_test="$(mktemp --tmpdir nvapi-carrier-contract-test.XXXXXX)"
model_catalog_test="$(mktemp --tmpdir gpu-model-catalog-test.XXXXXX)"
gpu_name_test="$(mktemp --tmpdir nvapi-gpu-name-test.XXXXXX)"
driver_version_test="$(mktemp --tmpdir nvapi-driver-version-test.XXXXXX)"
gpu_type_test="$(mktemp --tmpdir nvapi-gpu-type-test.XXXXXX)"
memory_test="$(mktemp --tmpdir nvapi-memory-test.XXXXXX)"
trap 'rm -f "$contract_test" "$aib_contract_test" "$carrier_contract_test" "$model_catalog_test" "$gpu_name_test" "$driver_version_test" "$gpu_type_test" "$memory_test"' EXIT
"${HOST_CC:-cc}" -std=c11 -Wall -Wextra -Werror -I../gpu-api-common \
    -o "$contract_test" test-contract.c nvapi_pci.c nvapi_gpu_specs.c \
        nvapi_gpu_legacy_clocks_fill.c nvapi_gpu_pstates_fill.c \
        nvapi_identity_contract.c ../gpu-api-common/aib_identity_catalog.c
"$contract_test"
"${HOST_CC:-cc}" -std=c11 -Wall -Wextra -Werror -I../gpu-api-common \
    -o "$aib_contract_test" test-aib-carrier.c nvapi_pci.c nvapi_gpu_specs.c \
        nvapi_identity_contract.c ../gpu-api-common/aib_identity_catalog.c
"$aib_contract_test"
"${HOST_CC:-cc}" -std=c11 -Wall -Wextra -Werror -I../gpu-api-common \
    -o "$carrier_contract_test" ../gpu-api-common/test-carrier-validation.c \
        ../gpu-api-common/carrier_validation_contract.c
"$carrier_contract_test"
"${HOST_CC:-cc}" -std=c11 -Wall -Wextra -Werror -I../gpu-api-common \
    -o "$model_catalog_test" ../gpu-api-common/test-gpu-model-catalog.c \
        ../gpu-api-common/gpu_model_catalog.c \
        ../gpu-api-common/aib_identity_catalog.c
"$model_catalog_test"
"${HOST_CC:-cc}" -std=c11 -Wall -Wextra -Werror -I../gpu-api-common \
    -o "$gpu_name_test" test-gpu-name.c nvapi_gpu_name.c \
        ../gpu-api-common/gpu_model_catalog.c
"$gpu_name_test"
"${HOST_CC:-cc}" -std=c11 -Wall -Wextra -Werror \
    -o "$driver_version_test" test-driver-version.c nvapi_driver_version.c
"$driver_version_test"
"${HOST_CC:-cc}" -std=c11 -Wall -Wextra -Werror \
    -o "$gpu_type_test" test-gpu-type.c nvapi_gpu_type.c
"$gpu_type_test"
"${HOST_CC:-cc}" -std=c11 -Wall -Wextra -Werror -D__cdecl= \
    -o "$memory_test" test-memory.c nvapi_memory.c
"$memory_test"

# 锁定跨位数注册表视图、一次性初始化和原子引用计数三个并发契约。
grep -F 'KEY_WOW64_64KEY' nvapi_identity.c >/dev/null \
    || fail "身份读取未固定到 64 位注册表视图"
grep -F 'InitOnceExecuteOnce' nvapi_identity.c >/dev/null \
    || fail "身份读取不再使用 InitOnce"
grep -F 'nvapi_validate_identity_token' nvapi_identity.c >/dev/null \
    || fail "CurrentIdentity 子键名没有严格白名单校验"
grep -F 'STEALTH_GPU_IDENTITIES_PREFIX "Identities\\"' nvapi_identity.c >/dev/null \
    || fail "身份读取没有限定到版本化 Identities 子键"
initial_pointer_line="$(grep -n -F \
    'read_current_identity_pointer(root, initial_pointer)' nvapi_identity.c | cut -d: -f1)"
snapshot_line="$(grep -n -F \
    'load_and_validate_identity(version_key, initial_pointer, candidate' \
    nvapi_identity.c | cut -d: -f1)"
final_pointer_line="$(grep -n -F \
    'read_current_identity_pointer(root, final_pointer)' nvapi_identity.c | cut -d: -f1)"
final_schema_line="$(grep -n -F \
    'read_registry_dword(version_key, "IdentitySchemaVersion"' \
    nvapi_identity.c | tail -1 | cut -d: -f1)"
[[ -n "$initial_pointer_line" && -n "$snapshot_line" && \
    -n "$final_pointer_line" && -n "$final_schema_line" && \
    "$initial_pointer_line" -lt "$snapshot_line" && \
    "$snapshot_line" -lt "$final_pointer_line" && \
    "$final_pointer_line" -lt "$final_schema_line" ]] \
    || fail "读者没有遵守 pointer -> snapshot -> pointer/schema 复核顺序"
grep -F 'return FALSE;' nvapi_identity.c >/dev/null \
    || fail "瞬态 snapshot 失败仍会永久完成 InitOnce"
grep -F 'stealth_validate_virtio_gpu_carrier_windows' nvapi_identity.c >/dev/null \
    || fail "NVAPI reader 未绑定到实际 Windows virtio 实例"
for contract in SetupDiGetClassDevsA SetupDiEnumDeviceInfo \
    CM_Get_Device_IDA CM_DRP_BUSNUMBER CM_DRP_ADDRESS SPDRP_HARDWAREID \
    SPDRP_SERVICE SPDRP_DRIVER; do
    grep -F "$contract" ../gpu-api-common/carrier_validation_win.c >/dev/null \
        || fail "实际 carrier 验证缺少标准 Windows 契约: $contract"
done
grep -F 'char matched_instance_id[STEALTH_GPU_CARRIER_INSTANCE_CAPACITY];' \
    ../gpu-api-common/carrier_validation_win.c >/dev/null \
    || fail "Windows carrier 枚举没有为命中 InstanceId 保留独立快照"
grep -F 'observation.instance_id = matched_instance_id;' \
    ../gpu-api-common/carrier_validation_win.c >/dev/null \
    || fail "Windows carrier observation 仍指向循环复用的 InstanceId 缓冲"
grep -F 'VioGpuDod' ../gpu-api-common/carrier_validation_contract.c >/dev/null \
    || fail "实际 carrier 验证未限制 stock VioGpuDod 服务"

# schema-1 兼容不能靠“缺字段时随便补齐”。16 个公共字段必须全部在版本分支前
# 严格读取；只有六个 schema-2 扩展字段允许在 legacy 分支走受控 PCI 型号映射。
legacy_branch_line="$(grep -n -F \
    'if (schema == STEALTH_GPU_LEGACY_SCHEMA_VERSION)' nvapi_identity.c | cut -d: -f1)"
schema2_branch_line="$(grep -n -F \
    '} else if (schema == STEALTH_GPU_SCHEMA_VERSION)' nvapi_identity.c | cut -d: -f1)"
for common_value in IdentitySchemaVersion IdentityId SpoofName SpoofVendor SpoofBios \
        SpoofPciVendorId SpoofPciDeviceId SpoofSubsystemVendorId \
        SpoofSubsystemDeviceId SpoofRevisionId SpoofRamMb SourceInstanceId \
        IdentityMode SpoofPciBusId SpoofPciSlotId SpoofPciFunctionId; do
    value_line="$(grep -n -F "\"$common_value\"" nvapi_identity.c | head -1 | cut -d: -f1)"
    [[ -n "$value_line" && "$value_line" -lt "$legacy_branch_line" ]] \
        || fail "schema-1 公共字段未在版本分支前严格读取: $common_value"
done
for extension_value in SpoofMemoryType SpoofMemoryBusWidthBits \
        SpoofBaseClockKHz SpoofBoostClockKHz SpoofMemoryClockKHz SpoofSliSupported; do
    value_line="$(grep -n -F "\"$extension_value\"" nvapi_identity.c | head -1 | cut -d: -f1)"
    [[ -n "$value_line" && "$value_line" -gt "$schema2_branch_line" ]] \
        || fail "schema-2 扩展字段没有被限制在 schema-2 分支: $extension_value"
done
grep -F 'nvapi_get_legacy_extension_defaults' nvapi_identity.c >/dev/null \
    || fail "schema-1 没有使用受控 PCI 型号默认映射"
grep -F 'InterlockedCompareExchange' nvapi_shim.c >/dev/null \
    || fail "NVAPI 生命周期不再使用原子引用计数"
gpu_handle_body="$(sed -n \
    '/NvAPI_Status nvapi_validate_gpu_handle(/,/^}/p' nvapi_shim.c)"
grep -F 'if (handle == NULL)' <<<"$gpu_handle_body" >/dev/null &&
    grep -F 'return NVAPI_INVALID_ARGUMENT;' <<<"$gpu_handle_body" >/dev/null \
    || fail "NVAPI 空物理句柄没有返回 INVALID_ARGUMENT"
driver_version_body="$(sed -n '/static NvAPI_Status __cdecl NvAPI_SYS_GetDriverAndBranchVersion(/,/^}/p' nvapi_shim.c)"
grep -F 'return nvapi_fill_driver_and_branch_version(version, branch);' \
    <<<"$driver_version_body" >/dev/null \
    || fail "DriverAndBranchVersion 没有调用受测的兼容 helper"
if grep -Fq 'return NVAPI_NOT_SUPPORTED;' <<<"$driver_version_body"; then
    fail "DriverAndBranchVersion 仍会把 GPU-Z 2.70 导向空回退入口"
fi
grep -F '{ UINT32_C(0x2926AAAD), NvAPI_SYS_GetDriverAndBranchVersion }' \
    nvapi_shim.c >/dev/null \
    || fail "DriverAndBranchVersion QueryInterface ID 没有绑定到兼容实现"
grep -F '{ NVAPI_ID_GPU_GET_BUS_TYPE, NvAPI_GPU_GetBusType }' \
    nvapi_shim.c >/dev/null \
    || fail "GetBusType QueryInterface ID 没有绑定到 GetBusType"
grep -F '{ NVAPI_ID_GPU_GET_BUS_ID, NvAPI_GPU_GetBusId }' \
    nvapi_shim.c >/dev/null \
    || fail "GetBusId QueryInterface ID 没有绑定到 GetBusId"
gpu_type_body="$(sed -n \
    '/static NvAPI_Status __cdecl NvAPI_GPU_GetGPUType(/,/^}/p' \
    nvapi_shim.c)"
grep -F 'return nvapi_fill_gpu_type(gpu_type);' \
    <<<"$gpu_type_body" >/dev/null \
    || fail "GetGPUType 没有调用受测的 DGPU helper"
grep -F '{ NVAPI_ID_GPU_GET_GPU_TYPE, NvAPI_GPU_GetGPUType }' \
    nvapi_shim.c >/dev/null \
    || fail "GetGPUType QueryInterface ID 没有绑定到 DGPU 实现"
grep -F '{ NVAPI_ID_GPU_GET_MEMORY_INFO, nvapi_gpu_get_memory_info }' \
    nvapi_shim.c >/dev/null \
    || fail "legacy MemoryInfo QueryInterface ID 没有绑定"
grep -F '{ NVAPI_ID_GPU_GET_MEMORY_INFO_EX, nvapi_gpu_get_memory_info_ex }' \
    nvapi_shim.c >/dev/null \
    || fail "MemoryInfoEx QueryInterface ID 没有绑定"
for forbidden_binding in \
    'NVAPI_ID_ENUM_NVIDIA_DISPLAY_HANDLE' \
    'NVAPI_ID_PHYSICAL_GPUS_FROM_DISPLAY' \
    'NVAPI_ID_GET_DISPLAY_DRIVER_VERSION'; do
    if grep -F "{ $forbidden_binding," nvapi_shim.c >/dev/null; then
        fail "$forbidden_binding 会让 GPU-Z 进入未闭环的 display 拓扑"
    fi
done
full_name_body="$(sed -n \
    '/static NvAPI_Status __cdecl NvAPI_GPU_GetFullName(/,/^}/p' \
    nvapi_shim.c)"
grep -F 'nvapi_copy_standard_gpu_name(identity, output)' \
    <<<"$full_name_body" >/dev/null \
    || fail "GetFullName 没有调用受测的标准型号复制 helper"
if grep -F 'copy_short_string(output, identity->name)' \
        <<<"$full_name_body" >/dev/null; then
    fail "GetFullName 仍直接泄漏完整 AIB 标签"
fi
for binding in \
    'NVAPI_ID_GPU_GET_VBIOS_VERSION_STRING' \
    'NVAPI_ID_GPU_GET_RAM_TYPE' \
    'NVAPI_ID_GPU_GET_RAM_BUS_WIDTH' \
    'NVAPI_ID_GPU_GET_FB_WIDTH_LOCATION' \
    'NVAPI_ID_GPU_GET_PERF_CLOCKS' \
    'NVAPI_ID_GPU_GET_LEGACY_ALL_CLOCKS' \
    'NVAPI_ID_GPU_GET_PSTATES20' \
    'NVAPI_ID_GPU_GET_ALL_CLOCKS' \
    'NVAPI_ID_ENUM_LOGICAL_GPUS' \
    'NVAPI_ID_LOGICAL_FROM_PHYSICAL' \
    'NVAPI_ID_PHYSICAL_FROM_LOGICAL' \
    'NVAPI_ID_GPU_GET_CONNECTED_OUTPUTS' \
    'NVAPI_ID_GPU_GET_CONNECTED_SLI_OUTPUTS'; do
    grep -F "{ $binding," nvapi_shim.c >/dev/null \
        || fail "$binding 没有显式绑定到 ABI 实现"
done
grep -F 'source_matches_logical_identity' nvapi_identity_contract.c >/dev/null \
    || fail "SourceInstanceId 没有进入 legacy/AIB 原子映射校验"
for carrier in 0xa101 0xa102 0xa103 0xa104 0xa105 0xa106 0xa107 0xa108 \
        0xa109 0xa10a 0xa10b 0xa10c 0xa10d 0xa10e 0xa10f 0xa110 \
        0xa111 0xa112; do
    grep -F "UINT32_C($carrier)" \
        ../gpu-api-common/aib_identity_catalog.c >/dev/null \
        || fail "共享 AIB 目录缺少 carrier: $carrier"
done
if grep -R -F 'NVSHIM_FORCE_NAME' -- *.c *.h >/dev/null; then
    fail "环境变量名称覆盖会破坏注册表身份原子性"
fi

# 代码文件总行数也限制在 500 内；这比“忽略注释后 500 行”的约束更严格。
for source in nvapi_shim.c nvapi_identity.c nvapi_pci.c nvapi_types.h \
    nvapi_identity.h nvapi_gpu_specs.c nvapi_gpu_specs.h \
    nvapi_driver_version.c nvapi_driver_version.h test-driver-version.c \
    nvapi_gpu_name.c nvapi_gpu_name.h nvapi_gpu_type.c nvapi_gpu_type.h \
    nvapi_memory.c nvapi_memory.h test-memory.c \
    nvapi_gpu_details.c nvapi_gpu_details.h nvapi_gpu_pstates.c \
    nvapi_gpu_legacy_clocks.c nvapi_gpu_legacy_clocks_fill.c \
    nvapi_gpu_legacy_clocks.h nvapi_gpu_pstates_fill.c \
    nvapi_gpu_pstates.h nvapi_shim_internal.h \
    nvapi_identity_contract.c nvapi_identity_contract.h test-contract.c \
    test-aib-carrier.c test-gpu-name.c test-gpu-type.c; do
    lines="$(wc -l <"$source")"
    [[ "$lines" -le 500 ]] || fail "$source 共 $lines 行，超过 500 行"
done
for source in ../gpu-api-common/carrier_validation.h \
    ../gpu-api-common/aib_identity_catalog.h \
    ../gpu-api-common/aib_identity_catalog.c \
    ../gpu-api-common/gpu_model_catalog.h \
    ../gpu-api-common/gpu_model_catalog.c \
    ../gpu-api-common/test-gpu-model-catalog.c \
    ../gpu-api-common/carrier_validation_contract.c \
    ../gpu-api-common/carrier_validation_win.c \
    ../gpu-api-common/test-carrier-validation.c; do
    lines="$(wc -l <"$source")"
    [[ "$lines" -le 500 ]] || fail "$source 共 $lines 行，超过 500 行"
done

echo "PASS: x86/x64 NVAPI DLL 架构、导出和动态身份契约均通过"

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
    [[ "$(grep -Ec '^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]+nvapi_QueryInterface$' <<<"$exports")" -eq 1 ]] \
        || fail "$dll 没有且仅有一个无修饰 nvapi_QueryInterface 导出"
    grep -E '^\s*\[Name Pointer/Ordinal\] Table\s+0*1$' <<<"$exports" >/dev/null \
        || fail "$dll 导出名称数量不是 1"
    grep -E '^Time/Date stamp\s+0$' <<<"$exports" >/dev/null \
        || fail "$dll 链接时间戳不为 0，产物不可复现"
    grep -F 'DLL Name: ADVAPI32.dll' <<<"$exports" >/dev/null \
        || fail "$dll 未链接注册表所需 ADVAPI32.dll"
    grep -F 'DLL Name: libwinpthread-1.dll' <<<"$exports" >/dev/null \
        && fail "$dll 不应依赖额外的 MinGW pthread 运行库"

    # 两个位数必须包含完全相同的配置契约，防止其中一个仍使用硬编码身份。
    for value_name in CurrentIdentity IdentitySchemaVersion IdentityId \
        SpoofName SpoofVendor SpoofBios SourceInstanceId IdentityMode \
        SpoofPciVendorId SpoofPciDeviceId SpoofSubsystemVendorId \
        SpoofSubsystemDeviceId SpoofRevisionId SpoofPciBusId \
        SpoofPciSlotId SpoofPciFunctionId SpoofRamMb SpoofMemoryType \
        SpoofMemoryBusWidthBits SpoofBaseClockKHz SpoofBoostClockKHz \
        SpoofMemoryClockKHz SpoofSliSupported; do
        strings -a "$dll" | grep -Fx "$value_name" >/dev/null \
            || fail "$dll 缺少注册表值 $value_name"
    done
}

check_dll nvapi.dll i686-w64-mingw32-objdump pei-i386
check_dll nvapi64.dll x86_64-w64-mingw32-objdump pei-x86-64

# 用宿主机编译器执行与 DLL 共用的 PCI 组合实现，并锁定官方状态码。
contract_test="$(mktemp --tmpdir nvapi-contract-test.XXXXXX)"
trap 'rm -f "$contract_test"' EXIT
"${HOST_CC:-cc}" -std=c11 -Wall -Wextra -Werror \
    -o "$contract_test" test-contract.c nvapi_pci.c nvapi_gpu_specs.c \
        nvapi_gpu_legacy_clocks_fill.c nvapi_gpu_pstates_fill.c \
        nvapi_identity_contract.c
"$contract_test"

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
grep -F '{ NVAPI_ID_GPU_GET_BUS_TYPE, NvAPI_GPU_GetBusType }' \
    nvapi_shim.c >/dev/null \
    || fail "GetBusType QueryInterface ID 没有绑定到 GetBusType"
grep -F '{ NVAPI_ID_GPU_GET_BUS_ID, NvAPI_GPU_GetBusId }' \
    nvapi_shim.c >/dev/null \
    || fail "GetBusId QueryInterface ID 没有绑定到 GetBusId"
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
grep -F 'source_subsystem_vendor != input->subsystem_vendor_id' \
    nvapi_identity_contract.c >/dev/null \
    || fail "SourceInstanceId SUBSYS 厂商号没有与 schema 字段交叉校验"
grep -F 'source_subsystem_device != input->subsystem_device_id' \
    nvapi_identity_contract.c >/dev/null \
    || fail "SourceInstanceId SUBSYS 设备号没有与 schema 字段交叉校验"
grep -F 'source_revision != input->revision_id' nvapi_identity_contract.c >/dev/null \
    || fail "SourceInstanceId REV 没有与 schema 字段交叉校验"
if grep -R -F 'NVSHIM_FORCE_NAME' -- *.c *.h >/dev/null; then
    fail "环境变量名称覆盖会破坏注册表身份原子性"
fi

# 代码文件总行数也限制在 500 内；这比“忽略注释后 500 行”的约束更严格。
for source in nvapi_shim.c nvapi_identity.c nvapi_pci.c nvapi_types.h \
    nvapi_identity.h nvapi_gpu_specs.c nvapi_gpu_specs.h \
    nvapi_gpu_details.c nvapi_gpu_details.h nvapi_gpu_pstates.c \
    nvapi_gpu_legacy_clocks.c nvapi_gpu_legacy_clocks_fill.c \
    nvapi_gpu_legacy_clocks.h nvapi_gpu_pstates_fill.c \
    nvapi_gpu_pstates.h nvapi_shim_internal.h \
    nvapi_identity_contract.c nvapi_identity_contract.h test-contract.c; do
    lines="$(wc -l <"$source")"
    [[ "$lines" -le 500 ]] || fail "$source 共 $lines 行，超过 500 行"
done

echo "PASS: x86/x64 NVAPI DLL 架构、导出和动态身份契约均通过"

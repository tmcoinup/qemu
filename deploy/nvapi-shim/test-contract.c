/*
 * 可在 Linux 宿主机直接执行的最小 ABI 单元测试。
 *
 * 注册表与 InitOnce 由 PE 构建测试覆盖链接完整性；这里专门锁住最容易造成
 * GPU-Z 全空的纯协议常量和 PCI 高低字节顺序。
 */

#include <stdio.h>
#include <string.h>

#include "nvapi_identity.h"
#include "nvapi_identity_contract.h"
#include "nvapi_gpu_legacy_clocks.h"
#include "nvapi_gpu_pstates.h"
#include "nvapi_gpu_specs.h"
#include "nvapi_types.h"

static int expect_status(const char *name, NvAPI_Status actual,
                         NvAPI_Status expected)
{
    if (actual == expected) {
        return 1;
    }
    fprintf(stderr, "%s: actual=%d expected=%d\n", name, (int)actual,
            (int)expected);
    return 0;
}

static struct nvapi_identity_contract_input valid_identity_contract(void)
{
    struct nvapi_identity_contract_input input = {
        "0123456789ABCDEF0123456789ABCDEF",
        "0123456789ABCDEF0123456789ABCDEF",
        "NVIDIA GeForce GTX 1050 Ti", "NVIDIA", "Version 86.07.48.00.A0",
        "GDDR5", "PCI\\VEN_1AF4&DEV_1050&SUBSYS_1C8210DE&REV_A1\\00",
        "shallow-user-projection", STEALTH_GPU_SCHEMA_VERSION,
        0x10deu, 0x1c82u, 0x10deu, 0x1c82u, 0xa1u, 4096u,
        128u, 1290000u, 1392000u, 3504000u, 0u, 1u, 0u, 0u
    };
    return input;
}

int main(void)
{
    int valid = 1;
    size_t clock_index;
    char bios[NVAPI_SHORT_STRING_MAX];
    NvU32 bios_revision = 0;
    NvU32 bios_oem_revision = 0;
    struct nvapi_clock_frequencies clocks = { 0 };
    struct nvapi_perf_clocks_info_v1 perf_clocks = { 0 };
    struct nvapi_legacy_clocks_gpu_z_v1 legacy_clocks_gpu_z = { 0 };
    struct nvapi_legacy_clocks_extended_v1 legacy_clocks_extended = { 0 };
    struct nvapi_pstate20_info_v1 pstates_v1 = { 0 };
    struct nvapi_pstate20_info_v2 pstates_v2 = { 0 };
    struct nvapi_identity_contract_input contract;
    struct nvapi_gpu_identity identity;
    struct nvapi_legacy_extension_defaults legacy_defaults;

    valid &= expect_status("NVAPI_API_NOT_INITIALIZED",
                           NVAPI_API_NOT_INITIALIZED, -4);
    valid &= expect_status("NVAPI_NVIDIA_DEVICE_NOT_FOUND",
                           NVAPI_NVIDIA_DEVICE_NOT_FOUND, -6);
    valid &= expect_status("NVAPI_HANDLE_INVALIDATED",
                           NVAPI_HANDLE_INVALIDATED, -10);
    valid &= expect_status("NVAPI_INCOMPATIBLE_STRUCT_VERSION",
                           NVAPI_INCOMPATIBLE_STRUCT_VERSION, -9);
    valid &= expect_status("NVAPI_EXPECTED_LOGICAL_GPU_HANDLE",
                           NVAPI_EXPECTED_LOGICAL_GPU_HANDLE, -100);
    valid &= expect_status("NVAPI_NOT_SUPPORTED", NVAPI_NOT_SUPPORTED, -104);

    if (NVAPI_GPU_BUS_TYPE_PCI_EXPRESS != 3u) {
        fprintf(stderr, "PCI Express bus type 不是 3\n");
        valid = 0;
    }
    if (NVAPI_ID_GPU_GET_BUS_TYPE != UINT32_C(0x1BB18724) ||
        NVAPI_ID_GPU_GET_BUS_ID != UINT32_C(0x1BE0B8E5)) {
        fprintf(stderr, "GetBusType/GetBusId QueryInterface ID 错误或互换\n");
        valid = 0;
    }
    if (sizeof(struct nvapi_clock_frequencies) != 264u ||
        NVAPI_ID_GPU_GET_VBIOS_VERSION_STRING != UINT32_C(0xA561FD7D) ||
        NVAPI_ID_GPU_GET_RAM_TYPE != UINT32_C(0x57F7CAAC) ||
        NVAPI_ID_GPU_GET_RAM_BUS_WIDTH != UINT32_C(0x7975C581) ||
        NVAPI_ID_GPU_GET_PERF_CLOCKS != UINT32_C(0x1EA54A3B) ||
        NVAPI_ID_GPU_GET_LEGACY_ALL_CLOCKS != UINT32_C(0x1BD69F49) ||
        NVAPI_ID_GPU_GET_PSTATES20 != UINT32_C(0x6FF81213) ||
        NVAPI_ID_GPU_GET_ALL_CLOCKS != UINT32_C(0xDCB616C3) ||
        NVAPI_ID_GPU_GET_CONNECTED_OUTPUTS != UINT32_C(0x1730BFC9)) {
        fprintf(stderr, "型号细节 NVAPI ABI 大小或 QueryInterface ID 错误\n");
        valid = 0;
    }
    if (nvapi_pack_pci_identifier(0x1c82u, 0x10deu) != 0x1c8210deu) {
        fprintf(stderr, "GTX 1050 Ti DeviceId 高低字组合错误\n");
        valid = 0;
    }
    if (nvapi_pack_pci_identifier(0x85aau, 0x1043u) != 0x85aa1043u) {
        fprintf(stderr, "SubsystemId 高低字组合错误\n");
        valid = 0;
    }

    if (!nvapi_parse_vbios("Version 86.07.48.00.A0", bios,
                           &bios_revision, &bios_oem_revision) ||
        strcmp(bios, "86.07.48.00.A0") != 0 ||
        bios_revision != UINT32_C(0x86074800) || bios_oem_revision != 0xa0u) {
        fprintf(stderr, "GTX 1050 Ti VBIOS 解析错误\n");
        valid = 0;
    }
    if (nvapi_parse_vbios("86.07.48.00.A0", bios,
                          &bios_revision, &bios_oem_revision)) {
        fprintf(stderr, "缺少 Version 前缀的 VBIOS 未被拒绝\n");
        valid = 0;
    }
    if (nvapi_parse_vbios("Version 86", bios,
                          &bios_revision, &bios_oem_revision) ||
        nvapi_validate_identity_token("ABC")) {
        fprintf(stderr, "短 VBIOS/token 字符串未被安全拒绝\n");
        valid = 0;
    }

    contract = valid_identity_contract();
    if (!nvapi_build_validated_identity(&contract, &identity) ||
        strcmp(identity.name, "NVIDIA GeForce GTX 1050 Ti") != 0 ||
        identity.pci_device_id != 0x1c82u || identity.ram_type != 8u ||
        identity.ram_bus_width_bits != 128u ||
        identity.vbios_revision != UINT32_C(0x86074800)) {
        fprintf(stderr, "有效 schema-2 身份没有通过可执行契约\n");
        valid = 0;
    }
    contract = valid_identity_contract();
    contract.source_instance_id =
        "PCI\\VEN_1AF4&DEV_1050&SUBSYS_1C8110DE&REV_A1\\00";
    if (nvapi_build_validated_identity(&contract, &identity)) {
        fprintf(stderr, "SourceInstanceId 与逻辑设备号不一致未被拒绝\n");
        valid = 0;
    }
    contract = valid_identity_contract();
    contract.source_instance_id = "PCI";
    if (nvapi_build_validated_identity(&contract, &identity)) {
        fprintf(stderr, "短 SourceInstanceId 未被安全拒绝\n");
        valid = 0;
    }
    contract = valid_identity_contract();
    contract.vendor = "AMD";
    if (nvapi_build_validated_identity(&contract, &identity)) {
        fprintf(stderr, "AMD 身份被 NVIDIA NVAPI reader 错误接受\n");
        valid = 0;
    }
    contract = valid_identity_contract();
    contract.vendor = "nvidia";
    if (nvapi_build_validated_identity(&contract, &identity)) {
        fprintf(stderr, "非 canonical NVIDIA 厂商名未被拒绝\n");
        valid = 0;
    }
    contract = valid_identity_contract();
    contract.schema = 1u;
    if (!nvapi_build_validated_identity(&contract, &identity) ||
        identity.ram_bus_width_bits != 128u ||
        identity.base_clock_khz != 1290000u ||
        identity.boost_clock_khz != 1392000u ||
        identity.memory_clock_khz != 3504000u) {
        fprintf(stderr, "完整 schema-1 没有使用受控 1050 Ti 默认值\n");
        valid = 0;
    }
    if (!nvapi_get_legacy_extension_defaults(0x10deu, 0x1c81u,
                                              &legacy_defaults) ||
        legacy_defaults.memory_bus_width_bits != 128u ||
        legacy_defaults.base_clock_khz != 1354000u ||
        legacy_defaults.boost_clock_khz != 1455000u ||
        legacy_defaults.memory_clock_khz != 3504000u) {
        fprintf(stderr, "schema-1 GTX 1050 编译期映射错误\n");
        valid = 0;
    }
    contract = valid_identity_contract();
    contract.schema = 1u;
    contract.name = "NVIDIA GeForce GTX 1050";
    contract.bios = "Version 86.07.48.00.38";
    contract.pci_device_id = 0x1c81u;
    contract.subsystem_device_id = 0x1c81u;
    contract.ram_mb = 2048u;
    contract.base_clock_khz = 1354000u;
    contract.boost_clock_khz = 1455000u;
    contract.source_instance_id =
        "PCI\\VEN_1AF4&DEV_1050&SUBSYS_1C8110DE&REV_A1\\00";
    if (!nvapi_build_validated_identity(&contract, &identity) ||
        identity.pci_device_id != 0x1c81u ||
        identity.base_clock_khz != 1354000u) {
        fprintf(stderr, "完整 schema-1 GTX 1050 快照未通过 reader\n");
        valid = 0;
    }
    if (nvapi_get_legacy_extension_defaults(0x10deu, 0xffffu,
                                             &legacy_defaults) ||
        nvapi_get_legacy_extension_defaults(0x1002u, 0x699fu,
                                             &legacy_defaults)) {
        fprintf(stderr, "schema-1 未知/AMD 型号被 NVIDIA reader 映射\n");
        valid = 0;
    }
    contract = valid_identity_contract();
    contract.schema = 1u;
    contract.memory_clock_khz++;
    if (nvapi_build_validated_identity(&contract, &identity)) {
        fprintf(stderr, "schema-1 非编译期扩展值被错误接受\n");
        valid = 0;
    }
    contract = valid_identity_contract();
    contract.schema = 3u;
    if (nvapi_build_validated_identity(&contract, &identity)) {
        fprintf(stderr, "未知 schema 被 reader 错误接受\n");
        valid = 0;
    }
    contract = valid_identity_contract();
    contract.memory_bus_width_bits = 96u;
    if (nvapi_build_validated_identity(&contract, &identity)) {
        fprintf(stderr, "非二次幂显存位宽未被拒绝\n");
        valid = 0;
    }
    contract = valid_identity_contract();
    contract.ram_mb = 1048577u;
    if (nvapi_build_validated_identity(&contract, &identity)) {
        fprintf(stderr, "超过 PowerShell 契约的显存上限未被拒绝\n");
        valid = 0;
    }
    contract = valid_identity_contract();
    contract.sli_supported = 1u;
    if (nvapi_build_validated_identity(&contract, &identity)) {
        fprintf(stderr, "未实现的 SLI profile 被单卡 shim 错误接受\n");
        valid = 0;
    }
    contract = valid_identity_contract();
    contract.base_clock_khz = 99999u;
    if (nvapi_build_validated_identity(&contract, &identity)) {
        fprintf(stderr, "越界核心时钟未被拒绝\n");
        valid = 0;
    }
    contract = valid_identity_contract();
    contract.identity_id = "0123456789ABCDEF0123456789ABCDE0";
    if (nvapi_build_validated_identity(&contract, &identity)) {
        fprintf(stderr, "pointer 与 IdentityId 不一致未被拒绝\n");
        valid = 0;
    }

    clocks.version = NVAPI_CLOCK_FREQUENCIES_VERSION_3;
    clocks.clock_type_and_reserved = NVAPI_CLOCK_TYPE_BOOST;
    valid &= expect_status("boost clocks",
        nvapi_fill_clock_frequencies(&clocks, 1290000u, 1392000u, 3504000u),
        NVAPI_OK);
    if (clocks.domain[NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS].presence != 1u ||
        clocks.domain[NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS].frequency_khz != 1392000u ||
        clocks.domain[NVAPI_GPU_PUBLIC_CLOCK_MEMORY].frequency_khz != 3504000u ||
        clocks.domain[NVAPI_GPU_PUBLIC_CLOCK_PROCESSOR].frequency_khz != 1392000u) {
        fprintf(stderr, "GTX 1050 Ti boost/domain 时钟错误\n");
        valid = 0;
    }
    clocks.version = UINT32_C(0x00030008);
    valid &= expect_status("bad clock struct",
        nvapi_fill_clock_frequencies(&clocks, 1290000u, 1392000u, 3504000u),
        NVAPI_INCOMPATIBLE_STRUCT_VERSION);
    clocks.version = NVAPI_CLOCK_FREQUENCIES_VERSION_3;
    clocks.clock_type_and_reserved = UINT32_C(0x10);
    valid &= expect_status("reserved clock bits",
        nvapi_fill_clock_frequencies(&clocks, 1290000u, 1392000u, 3504000u),
        NVAPI_INVALID_ARGUMENT);

    /* GPU-Z 2.70 使用 V2 时钟结构，必须与独立 probe 的 V3 结果完全一致。 */
    memset(&clocks, 0, sizeof(clocks));
    clocks.version = NVAPI_CLOCK_FREQUENCIES_VERSION_2;
    clocks.clock_type_and_reserved = NVAPI_CLOCK_TYPE_BASE;
    valid &= expect_status("GPU-Z V2 base clocks",
        nvapi_fill_clock_frequencies(&clocks, 1290000u, 1392000u, 3504000u),
        NVAPI_OK);
    if (clocks.domain[NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS].frequency_khz !=
            1290000u ||
        clocks.domain[NVAPI_GPU_PUBLIC_CLOCK_MEMORY].presence != 1u ||
        clocks.domain[NVAPI_GPU_PUBLIC_CLOCK_MEMORY].frequency_khz !=
            3504000u) {
        fprintf(stderr, "GPU-Z V2 显存时钟结构错误\n");
        valid = 0;
    }

    /* GPU-Z 的实际显存字段来自私有 GetPerfClocks，而不是 modern API。 */
    perf_clocks.version = NVAPI_PERF_CLOCKS_VERSION_1;
    valid &= expect_status("GPU-Z GetPerfClocks base",
        nvapi_fill_perf_clocks(&perf_clocks, NVAPI_CLOCK_TYPE_BASE,
                               1290000u, 1392000u, 3504000u), NVAPI_OK);
    if (perf_clocks.profile_count != 1u ||
        perf_clocks.clock_count != 3u ||
        perf_clocks.profiles[0].clocks[0].domain_id !=
            NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS ||
        perf_clocks.profiles[0].clocks[0].frequency_khz != 1290000u ||
        perf_clocks.profiles[0].clocks[1].domain_id !=
            NVAPI_GPU_PUBLIC_CLOCK_MEMORY ||
        perf_clocks.profiles[0].clocks[1].present != 1u ||
        perf_clocks.profiles[0].clocks[1].frequency_khz != 3504000u ||
        perf_clocks.profiles[0].clocks[3].domain_id !=
            NVAPI_GPU_PUBLIC_CLOCK_UNDEFINED) {
        fprintf(stderr, "GPU-Z GetPerfClocks 显存 entry 错误\n");
        valid = 0;
    }
    for (clock_index = 3u; clock_index < NVAPI_PERF_CLOCK_ENTRY_COUNT;
         clock_index++) {
        if (perf_clocks.profiles[0].clocks[clock_index].domain_id !=
                NVAPI_GPU_PUBLIC_CLOCK_UNDEFINED) {
            fprintf(stderr, "GetPerfClocks 空 entry 会覆盖有效核心时钟\n");
            valid = 0;
            break;
        }
    }
    /* 3504 MHz 原始 GDDR5 时钟经 0.5 系数为 1752 MHz、128-bit 为 112.128 GB/s。 */
    if (perf_clocks.profiles[0].clocks[1].frequency_khz / 2u != 1752000u ||
        ((uint64_t)1752000u * 4u * 128u / 8u) != UINT64_C(112128000)) {
        fprintf(stderr, "GPU-Z 显存时钟或带宽换算契约错误\n");
        valid = 0;
    }
    perf_clocks.version = NVAPI_PERF_CLOCKS_VERSION_1;
    valid &= expect_status("GetPerfClocks boost",
        nvapi_fill_perf_clocks(&perf_clocks, NVAPI_CLOCK_TYPE_BOOST,
                               1290000u, 1392000u, 3504000u), NVAPI_OK);
    if (perf_clocks.profiles[0].clocks[0].frequency_khz != 1392000u) {
        fprintf(stderr, "GetPerfClocks boost 核心频率错误\n");
        valid = 0;
    }
    perf_clocks.version = UINT32_C(0x00012a70);
    valid &= expect_status("bad GetPerfClocks struct",
        nvapi_fill_perf_clocks(&perf_clocks, NVAPI_CLOCK_TYPE_BASE,
                               1290000u, 1392000u, 3504000u),
        NVAPI_INCOMPATIBLE_STRUCT_VERSION);

    /* 同时锁住 GPU-Z 的 64 槽旧结构和其他读者使用的 288 槽结构。 */
    legacy_clocks_gpu_z.version = NVAPI_LEGACY_CLOCKS_GPU_Z_VERSION_1;
    valid &= expect_status("GPU-Z legacy GetAllClocks",
        nvapi_fill_legacy_clocks(&legacy_clocks_gpu_z, 1290000u, 3504000u),
        NVAPI_OK);
    if (legacy_clocks_gpu_z.clocks[0] != 1290000u ||
        legacy_clocks_gpu_z.clocks[8] != 3504000u ||
        legacy_clocks_gpu_z.clocks[30] != 0u) {
        fprintf(stderr, "GPU-Z legacy clocks 槽位错误\n");
        valid = 0;
    }
    legacy_clocks_extended.version =
        NVAPI_LEGACY_CLOCKS_EXTENDED_VERSION_1;
    valid &= expect_status("extended legacy GetAllClocks",
        nvapi_fill_legacy_clocks(&legacy_clocks_extended,
                                 1290000u, 3504000u), NVAPI_OK);
    if (legacy_clocks_extended.clocks[8] != 3504000u ||
        legacy_clocks_extended.clocks[287] != 0u) {
        fprintf(stderr, "extended legacy clocks 槽位错误\n");
        valid = 0;
    }

    pstates_v1.version = NVAPI_PSTATE20_INFO_VERSION_1;
    valid &= expect_status("GPU-Z P-States V1",
        nvapi_fill_pstates20(&pstates_v1, 1290000u, 1392000u, 3504000u),
        NVAPI_OK);
    if (pstates_v1.pstate_count != 1u || pstates_v1.clock_count != 2u ||
        pstates_v1.pstates[0].pstate_id != NVAPI_GPU_PERF_PSTATE_P0 ||
        pstates_v1.pstates[0].clocks[0].clock_type !=
            NVAPI_GPU_PSTATE20_CLOCK_TYPE_RANGE ||
        pstates_v1.pstates[0].clocks[0].data.range.minimum_frequency_khz !=
            1290000u ||
        pstates_v1.pstates[0].clocks[0].data.range.maximum_frequency_khz !=
            1392000u ||
        pstates_v1.pstates[0].clocks[1].domain_id !=
            NVAPI_GPU_PUBLIC_CLOCK_MEMORY ||
        pstates_v1.pstates[0].clocks[1].data.single.frequency_khz !=
            3504000u) {
        fprintf(stderr, "GTX 1050 Ti P0 核心范围或显存时钟错误\n");
        valid = 0;
    }
    /* 锁住 GPU-Z 的门控条件：P0 range 的 min/max 必须均非零且不相等。 */
    if (pstates_v1.pstates[0].clocks[0].data.range.maximum_frequency_khz == 0u ||
        pstates_v1.pstates[0].clocks[0].data.range.minimum_frequency_khz ==
            pstates_v1.pstates[0].clocks[0].data.range.maximum_frequency_khz) {
        fprintf(stderr, "GPU-Z P-States 时钟回退门控不会生效\n");
        valid = 0;
    }

    pstates_v2.base.version = NVAPI_PSTATE20_INFO_VERSION_3;
    pstates_v2.overvoltage.voltage_count = 99u;
    valid &= expect_status("P-States V3",
        nvapi_fill_pstates20(&pstates_v2, 1290000u, 1392000u, 3504000u),
        NVAPI_OK);
    if (pstates_v2.overvoltage.voltage_count != 0u) {
        fprintf(stderr, "P-States V3 超压保留区未清零\n");
        valid = 0;
    }
    pstates_v1.version = UINT32_C(0x00011c90);
    valid &= expect_status("bad P-States struct",
        nvapi_fill_pstates20(&pstates_v1, 1290000u, 1392000u, 3504000u),
        NVAPI_INCOMPATIBLE_STRUCT_VERSION);

    return valid ? 0 : 1;
}

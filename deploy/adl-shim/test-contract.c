#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "adl_identity_contract.h"
#include "adl_init_policy.h"
#include "adl_profile.h"
#include "adl_types.h"

static int g_failures;

static void expect(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        ++g_failures;
    }
}

static struct adl_identity_contract_input rx560_input(void)
{
    struct adl_identity_contract_input input;

    memset(&input, 0, sizeof(input));
    input.expected_token = "0123456789ABCDEF0123456789ABCDEF";
    input.identity_id = "0123456789ABCDEF0123456789ABCDEF";
    input.name = "AMD Radeon RX 560";
    input.vendor = "AMD";
    input.bios = "016.011.000.029.000000";
    input.memory_type = "GDDR5";
    input.source_instance_id =
        "PCI\\VEN_1AF4&DEV_1050&SUBSYS_67FF1002&REV_CF\\4&ABC&0&00";
    input.identity_mode = "shallow-user-projection";
    input.schema = STEALTH_GPU_LEGACY_SCHEMA_VERSION;
    input.pci_vendor_id = UINT32_C(0x1002);
    input.pci_device_id = UINT32_C(0x67ff);
    input.subsystem_vendor_id = UINT32_C(0x1002);
    input.subsystem_device_id = UINT32_C(0x67ff);
    input.revision_id = UINT32_C(0xcf);
    input.ram_mb = 4096u;
    input.memory_bus_width_bits = 128u;
    input.base_clock_khz = 1175000u;
    input.boost_clock_khz = 1275000u;
    input.memory_clock_khz = 3500000u;
    input.sli_supported = 0u;
    input.bus_id = 1u;
    input.slot_id = 0u;
    input.function_id = 0u;
    return input;
}

static void test_rx560(void)
{
    struct adl_identity_contract_input input = rx560_input();
    struct adl_gpu_identity identity;
    enum adl_identity_state state =
        adl_build_validated_identity(&input, &identity);

    expect(state == ADL_IDENTITY_PRESENT, "RX 560 schema-1 应通过");
    expect(strcmp(identity.name, "AMD Radeon RX 560") == 0,
           "RX 560 名称");
    expect(identity.pci_vendor_id == UINT32_C(0x1002),
           "RX 560 PCI vendor");
    expect(identity.pci_device_id == UINT32_C(0x67ff),
           "RX 560 PCI device");
    expect(identity.ram_mb == 4096u, "RX 560 VRAM");
    expect(identity.compute_units == 16u, "RX 560 CU");
    expect(identity.processing_elements_per_cu == 64u, "GCN 每 CU PE");
    expect(identity.rops == 16u, "RX 560 ROP");
    expect(identity.base_clock_khz / 1000u == 1175u,
           "RX 560 core MHz");
    expect(identity.memory_clock_khz / 2000u == 1750u,
           "RX 560 ADL physical memory MHz");
    expect(ADL_VENDOR_ID_AMD == 1002,
           "AdapterInfo iVendorID 必须是十进制 1002");
    expect(sizeof(AdapterInfoX2) == sizeof(AdapterInfo) + 2u * sizeof(int),
           "AdapterInfoX2 必须仅扩展两个 capability 字段");
    expect(sizeof(ADLVersionsInfo) == 3u * ADL_MAX_PATH,
           "ADLVersionsInfo 官方 3 x ADL_MAX_PATH 布局");
    expect(sizeof(ADLVersionsInfoX2) == 4u * ADL_MAX_PATH,
           "ADLVersionsInfoX2 官方 4 x ADL_MAX_PATH 布局");
    expect(adl_profile_core_mhz(&identity) == 1175,
           "RX 560 ODN core 必须是 1175 MHz");
    expect(adl_profile_boost_mhz(&identity) == 1275,
           "RX 560 ODN boost 必须是 1275 MHz");
    expect(adl_profile_memory_mhz(&identity) == 1750,
           "RX 560 ODN memory 必须是 1750 MHz");
    expect(adl_profile_core_10khz(&identity) == 117500,
           "RX 560 OD5 core 必须是 117500 x 10kHz");
    expect(adl_profile_memory_10khz(&identity) == 175000,
           "RX 560 OD5 memory 必须是 175000 x 10kHz");
    expect(adl_profile_memory_bandwidth_mb(&identity) == 112000,
           "RX 560 memory bandwidth 必须是 112000 MB/s");
}

static void test_rx550(void)
{
    struct adl_identity_contract_input input = rx560_input();
    struct adl_gpu_identity identity;

    input.name = "AMD Radeon RX 550";
    input.source_instance_id =
        "PCI\\VEN_1AF4&DEV_1050&SUBSYS_699F1002&REV_CF\\4&ABC&0&00";
    input.pci_device_id = UINT32_C(0x699f);
    input.subsystem_device_id = UINT32_C(0x699f);
    input.ram_mb = 2048u;
    input.base_clock_khz = 1100000u;
    input.boost_clock_khz = 1183000u;
    expect(adl_build_validated_identity(&input, &identity) ==
               ADL_IDENTITY_PRESENT,
           "RX 550 schema-1 应通过");
    expect(identity.compute_units == 8u, "RX 550 CU");
    expect(identity.ram_mb == 2048u, "RX 550 VRAM");
}

static void test_legacy_snapshot(void)
{
    struct adl_identity_contract_input input = rx560_input();
    struct adl_gpu_identity identity;

    input.schema = STEALTH_GPU_LEGACY_SCHEMA_VERSION;
    input.memory_type = NULL;
    input.memory_bus_width_bits = 0u;
    input.base_clock_khz = 0u;
    input.boost_clock_khz = 0u;
    input.memory_clock_khz = 0u;
    expect(adl_build_validated_identity(&input, &identity) ==
               ADL_IDENTITY_PRESENT,
           "AMD schema-1 只可按已知 PCI 型号补受控默认");
    expect(identity.base_clock_khz == 1175000u,
           "schema-1 RX 560 base clock");
    expect(identity.memory_clock_khz == 3500000u,
           "schema-1 RX 560 memory clock");
}

static void test_nvidia_is_absent(void)
{
    struct adl_identity_contract_input input = rx560_input();
    struct adl_gpu_identity identity;

    input.name = "NVIDIA GeForce GTX 1050 Ti";
    input.vendor = "NVIDIA";
    input.source_instance_id =
        "PCI\\VEN_1AF4&DEV_1050&SUBSYS_1C8210DE&REV_A1\\4&ABC&0&00";
    input.pci_vendor_id = UINT32_C(0x10de);
    input.pci_device_id = UINT32_C(0x1c82);
    input.subsystem_vendor_id = UINT32_C(0x10de);
    input.subsystem_device_id = UINT32_C(0x1c82);
    input.revision_id = UINT32_C(0xa1);
    expect(adl_build_validated_identity(&input, &identity) ==
               ADL_IDENTITY_ABSENT,
           "正常 NVIDIA profile 必须表现为 0 个 AMD adapter");
    expect(identity.name[0] == '\0', "ABSENT 不得残留 AMD identity");
}

static void test_schema2_generic_is_rejected(void)
{
    struct adl_identity_contract_input input = rx560_input();
    struct adl_gpu_identity identity;

    input.schema = STEALTH_GPU_SCHEMA_VERSION;
    expect(adl_build_validated_identity(&input, &identity) ==
               ADL_IDENTITY_INVALID,
           "schema-2 generic 身份不得绕过共享 AIB 目录");
}

static void expect_rejected(struct adl_identity_contract_input *input,
                            const char *message)
{
    struct adl_gpu_identity identity;

    expect(adl_build_validated_identity(input, &identity) ==
               ADL_IDENTITY_INVALID,
           message);
    expect(identity.name[0] == '\0', "拒绝后 identity 必须清零");
}

static void test_fail_closed_profiles(void)
{
    struct adl_identity_contract_input input;

    input = rx560_input();
    input.name = "AMD Red Hat VirtIO GPU";
    expect_rejected(&input, "Red Hat 名称必须拒绝");

    input = rx560_input();
    input.name = "AMD Radeon VirtIO RX 560";
    expect_rejected(&input, "VirtIO 名称必须拒绝");

    input = rx560_input();
    input.pci_device_id = UINT32_C(0x73ff);
    input.subsystem_device_id = UINT32_C(0x73ff);
    input.source_instance_id =
        "PCI\\VEN_1AF4&DEV_1050&SUBSYS_73FF1002&REV_CF\\4&ABC&0&00";
    expect_rejected(&input, "未知 AMD PCI device 必须拒绝");

    input = rx560_input();
    input.subsystem_device_id = UINT32_C(0x699f);
    expect_rejected(&input, "schema/SUBSYS device 撕裂必须拒绝");

    input = rx560_input();
    input.revision_id = UINT32_C(0xce);
    expect_rejected(&input, "schema/Source REV 撕裂必须拒绝");

    input = rx560_input();
    input.ram_mb = 2048u;
    expect_rejected(&input, "schema-1 错误显存容量必须拒绝");

    input = rx560_input();
    input.bus_id = 256u;
    expect_rejected(&input, "越界 bus 必须拒绝");

    input = rx560_input();
    input.slot_id = 32u;
    expect_rejected(&input, "越界 slot 必须拒绝");

    input = rx560_input();
    input.function_id = 8u;
    expect_rejected(&input, "越界 function 必须拒绝");

    input = rx560_input();
    input.expected_token = "0123456789abcdef0123456789abcdef";
    expect_rejected(&input, "小写 identity token 必须拒绝");

    input = rx560_input();
    input.source_instance_id =
        "PCI\\VEN_1002&DEV_67FF&SUBSYS_67FF1002&REV_CF\\4&ABC&0&00";
    expect_rejected(&input, "SourceInstance 必须是唯一 1AF4:1050 承载设备");
}

static void test_initialization_policy(void)
{
    expect(adl_init_threading_model_status(ADL_THREADING_UNLOCKED) == ADL_OK,
           "unlocked threading model must be accepted");
    expect(adl_init_threading_model_status(ADL_THREADING_LOCKED) ==
               ADL_ERR_NOT_SUPPORTED,
           "locked threading model must be rejected until serialized");
    expect(adl_init_threading_model_status((ADLThreadingModel)2) ==
               ADL_ERR_INVALID_PARAM,
           "unknown threading model must be invalid");
    expect(adl_init_create_options_status(ADL_CREATE_OPTIONS_DEFAULT) ==
               ADL_OK,
           "default X3 create options must be accepted");
    expect(adl_init_create_options_status(
               ADL_CREATE_OPTIONS_INTERPRET_INCOMPATIBLE_DRIVER_VERSION_AS_SUPPORTED) ==
               ADL_OK,
           "documented X3 compatibility option must be accepted");
    expect(adl_init_create_options_status(1 << 1) == ADL_ERR_NOT_SUPPORTED,
           "undocumented X3 create option must be rejected");
}

int main(void)
{
    expect(adl_validate_identity_token(
               "0123456789ABCDEF0123456789ABCDEF"),
           "合法 token");
    expect(!adl_validate_identity_token("0123"), "短 token");
    expect(!adl_validate_identity_token(NULL), "NULL token");
    test_rx560();
    test_rx550();
    test_legacy_snapshot();
    test_nvidia_is_absent();
    test_schema2_generic_is_rejected();
    test_fail_closed_profiles();
    test_initialization_policy();

    if (g_failures != 0) {
        fprintf(stderr, "FAIL: %d 个 ADL contract 断言失败\n", g_failures);
        return EXIT_FAILURE;
    }
    puts("PASS: AMD ADL identity contract");
    return EXIT_SUCCESS;
}

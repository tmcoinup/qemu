#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "carrier_validation.h"

static const char g_source[] =
    "PCI\\VEN_1AF4&DEV_1050&SUBSYS_67FF1002&REV_CF\\4&ABC&0&00";
static const char g_hardware_ids[] =
    "PCI\\VEN_1002&DEV_67FF&SUBSYS_67FF1002&REV_CF\0"
    "PCI\\VEN_1af4&DEV_1050&SUBSYS_67FF1002&REV_CF\0\0";

static struct stealth_gpu_carrier_observation valid_observation(void)
{
    struct stealth_gpu_carrier_observation observation;

    memset(&observation, 0, sizeof(observation));
    observation.instance_id = g_source;
    observation.hardware_ids = g_hardware_ids;
    /* 去掉 C 字符串额外的终止符，留下 Windows REG_MULTI_SZ 的双 NUL。 */
    observation.hardware_ids_bytes = sizeof(g_hardware_ids) - 1u;
    observation.service = "VioGpuDod";
    observation.driver_key = "{4D36E968-E325-11CE-BFC1-08002BE10318}\\0001";
    observation.bus_id = 3u;
    observation.slot_id = 0u;
    observation.function_id = 0u;
    observation.matching_source_count = 1u;
    observation.virtio_display_count = 1u;
    return observation;
}

static int expect_valid(void)
{
    struct stealth_gpu_carrier_observation observation = valid_observation();
    struct stealth_gpu_carrier carrier;

    if (!stealth_validate_virtio_gpu_carrier_observation(
            g_source, 3u, 0u, 0u, &observation, &carrier) ||
        strcmp(carrier.instance_id, g_source) != 0 ||
        strcmp(carrier.hardware_id,
               "PCI\\VEN_1af4&DEV_1050&SUBSYS_67FF1002&REV_CF") != 0 ||
        strcmp(carrier.driver_key,
               "{4D36E968-E325-11CE-BFC1-08002BE10318}\\0001") != 0 ||
        carrier.pci_vendor_id != UINT32_C(0x1af4) ||
        carrier.pci_device_id != UINT32_C(0x1050)) {
        fputs("有效的真实 virtio carrier observation 未通过\n", stderr);
        return 0;
    }
    return 1;
}

static int expect_rejected(void)
{
    struct stealth_gpu_carrier_observation observation;
    struct stealth_gpu_carrier carrier;
    static const char logical_only[] =
        "PCI\\VEN_1002&DEV_67FF&SUBSYS_67FF1002&REV_CF\0\0";

    observation = valid_observation();
    observation.hardware_ids = logical_only;
    observation.hardware_ids_bytes = sizeof(logical_only) - 1u;
    if (stealth_validate_virtio_gpu_carrier_observation(
            g_source, 3u, 0u, 0u, &observation, &carrier)) {
        fputs("丢失物理 HardwareID 条目未拒绝\n", stderr);
        return 0;
    }
    observation = valid_observation();
    observation.bus_id = 4u;
    if (stealth_validate_virtio_gpu_carrier_observation(
            g_source, 3u, 0u, 0u, &observation, &carrier)) {
        fputs("schema BDF 与实际 BDF 不一致未拒绝\n", stderr);
        return 0;
    }
    observation = valid_observation();
    observation.matching_source_count = 2u;
    if (stealth_validate_virtio_gpu_carrier_observation(
            g_source, 3u, 0u, 0u, &observation, &carrier)) {
        fputs("重复 SourceInstanceId 未拒绝\n", stderr);
        return 0;
    }
    observation = valid_observation();
    observation.virtio_display_count = 2u;
    if (stealth_validate_virtio_gpu_carrier_observation(
            g_source, 3u, 0u, 0u, &observation, &carrier)) {
        fputs("第二个物理 virtio display 未拒绝\n", stderr);
        return 0;
    }
    observation = valid_observation();
    observation.service = "BasicDisplay";
    if (stealth_validate_virtio_gpu_carrier_observation(
            g_source, 3u, 0u, 0u, &observation, &carrier)) {
        fputs("非 VioGpuDod Driver 绑定未拒绝\n", stderr);
        return 0;
    }
    return 1;
}

int main(void)
{
    if (!expect_valid() || !expect_rejected()) {
        return 1;
    }
    puts("PASS: SourceInstanceId/BDF 实例交叉验证契约");
    return 0;
}

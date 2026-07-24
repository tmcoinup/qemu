#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "adl_core_internal.h"

static int expect(int condition, const char *message)
{
    if (condition) {
        return 1;
    }
    fprintf(stderr, "FAIL: %s\n", message);
    return 0;
}

static struct adl_gpu_identity valid_identity(void)
{
    struct adl_gpu_identity identity;

    memset(&identity, 0, sizeof(identity));
    (void)snprintf(identity.name, sizeof(identity.name),
                   "%s", "AMD Radeon RX 560 (Sapphire Pulse 16 CU)");
    identity.pci_vendor_id = UINT32_C(0x1002);
    identity.pci_device_id = UINT32_C(0x67ff);
    identity.carrier.bus_id = UINT32_C(1);
    identity.carrier.slot_id = UINT32_C(2);
    identity.carrier.function_id = UINT32_C(3);
    (void)snprintf(identity.carrier.instance_id,
                   sizeof(identity.carrier.instance_id),
                   "%s", "PCI\\VEN_1AF4&DEV_1050\\TEST");
    (void)snprintf(identity.carrier.hardware_id,
                   sizeof(identity.carrier.hardware_id),
                   "%s", "PCI\\VEN_1AF4&DEV_1050");
    (void)snprintf(identity.carrier.driver_registry_path,
                   sizeof(identity.carrier.driver_registry_path),
                   "%s", "\\Registry\\Machine\\System\\Display\\0000");
    (void)snprintf(identity.carrier.driver_key,
                   sizeof(identity.carrier.driver_key),
                   "%s", "{4d36e968-e325-11ce-bfc1-08002be10318}\\0000");
    return identity;
}

static int test_standard_adapter_name(void)
{
    struct adl_gpu_identity identity = valid_identity();
    AdapterInfo info;
    int valid = adl_core_build_adapter_info(&identity, &info);

    return expect(valid, "合法 AMD identity 未生成 AdapterInfo") &&
        expect(strcmp(info.strAdapterName, "AMD Radeon RX 560") == 0,
               "AdapterInfo 未返回标准型号名") &&
        expect(strcmp(identity.name,
                      "AMD Radeon RX 560 (Sapphire Pulse 16 CU)") == 0,
               "AdapterInfo 改写了内部完整 AIB 标签") &&
        expect(strcmp(info.strUDID, identity.carrier.instance_id) == 0,
               "AdapterInfo 未保留受验 carrier UDID") &&
        expect(strcmp(info.strPNPString, identity.carrier.hardware_id) == 0,
               "AdapterInfo 未保留受验 carrier PNP") &&
        expect(info.iBusNumber == 1 && info.iDeviceNumber == 2 &&
               info.iFunctionNumber == 3,
               "AdapterInfo 未保留受验 carrier BDF");
}

static int test_unknown_model(void)
{
    struct adl_gpu_identity identity = valid_identity();
    AdapterInfo info;

    memset(&info, 0xa5, sizeof(info));
    identity.pci_device_id = UINT32_C(0xffff);
    return expect(!adl_core_build_adapter_info(&identity, &info),
                  "未知 PCI 主 ID 未 fail-closed") &&
        expect(info.strAdapterName[0] == '\0',
               "未知 PCI 主 ID 留下了 adapter 名称");
}

static int test_null_arguments(void)
{
    struct adl_gpu_identity identity = valid_identity();
    AdapterInfo info;
    int valid = 1;

    memset(&info, 0xa5, sizeof(info));
    valid &= expect(!adl_core_build_adapter_info(NULL, &info),
                    "NULL identity 未 fail-closed");
    valid &= expect(info.strAdapterName[0] == '\0',
                    "NULL identity 未清空 AdapterInfo");
    valid &= expect(!adl_core_build_adapter_info(&identity, NULL),
                    "NULL AdapterInfo 未 fail-closed");
    valid &= expect(!adl_core_build_adapter_info(NULL, NULL),
                    "双 NULL 参数未 fail-closed");
    return valid;
}

int main(void)
{
    return test_standard_adapter_name() && test_unknown_model() &&
        test_null_arguments() ? 0 : 1;
}

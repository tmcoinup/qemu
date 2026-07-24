#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "nvapi_gpu_name.h"

_Static_assert(NVAPI_SHORT_STRING_MAX == 64,
               "NVAPI 短字符串 ABI 必须保持 64 字节");

static int expect(int condition, const char *message)
{
    if (condition) {
        return 1;
    }
    fprintf(stderr, "FAIL: %s\n", message);
    return 0;
}

static struct nvapi_gpu_identity valid_identity(void)
{
    struct nvapi_gpu_identity identity;

    memset(&identity, 0, sizeof(identity));
    (void)snprintf(identity.name, sizeof(identity.name), "%s",
                   "NVIDIA GeForce GTX 1050 Ti (Colorful iGame U)");
    identity.pci_vendor_id = UINT32_C(0x10de);
    identity.pci_device_id = UINT32_C(0x1c82);
    return identity;
}

static int test_valid_name(void)
{
    struct nvapi_gpu_identity identity = valid_identity();
    char output[NVAPI_SHORT_STRING_MAX];

    memset(output, 0xa5, sizeof(output));
    return expect(nvapi_copy_standard_gpu_name(&identity, output) == NVAPI_OK,
                  "合法 identity 未返回 NVAPI_OK") &&
        expect(strcmp(output, "NVIDIA GeForce GTX 1050 Ti") == 0,
               "NVAPI helper 未返回标准型号名") &&
        expect(strcmp(identity.name,
                      "NVIDIA GeForce GTX 1050 Ti (Colorful iGame U)") == 0,
               "NVAPI helper 改写了内部完整 AIB 标签");
}

static int test_unknown_and_null(void)
{
    struct nvapi_gpu_identity identity = valid_identity();
    char output[NVAPI_SHORT_STRING_MAX];
    int valid = 1;

    identity.pci_device_id = UINT32_C(0xffff);
    memset(output, 0xa5, sizeof(output));
    valid &= expect(nvapi_copy_standard_gpu_name(&identity, output) ==
                        NVAPI_NVIDIA_DEVICE_NOT_FOUND,
                    "未知 PCI 主 ID 未返回 DEVICE_NOT_FOUND");
    valid &= expect(output[0] == '\0', "未知 PCI 主 ID 未清空输出");

    memset(output, 0xa5, sizeof(output));
    valid &= expect(nvapi_copy_standard_gpu_name(NULL, output) ==
                        NVAPI_NVIDIA_DEVICE_NOT_FOUND,
                    "NULL identity 未返回 DEVICE_NOT_FOUND");
    valid &= expect(output[0] == '\0', "NULL identity 未清空输出");
    valid &= expect(nvapi_copy_standard_gpu_name(&identity, NULL) ==
                        NVAPI_INVALID_ARGUMENT,
                    "NULL 输出未返回 INVALID_ARGUMENT");
    return valid;
}

int main(void)
{
    return test_valid_name() && test_unknown_and_null() ? 0 : 1;
}

#include <stdio.h>
#include <string.h>

#include "nvapi_driver_version.h"

static int expect(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        return 0;
    }
    return 1;
}

int main(void)
{
    NvAPI_Status status;
    NvU32 version = UINT32_C(0xDEADBEEF);
    char branch[NVAPI_SHORT_STRING_MAX];
    size_t index;
    int valid = 1;

    memset(branch, 0xA5, sizeof(branch));
    status = nvapi_fill_driver_and_branch_version(&version, branch);
    valid &= expect(status == NVAPI_OK, "兼容版本查询没有返回 NVAPI_OK");
    valid &= expect(version == UINT32_C(54633), "驱动版本不是 54633");
    valid &= expect(strcmp(branch, "r545_99") == 0, "驱动 branch 不是 r545_99");

    /*
     * helper 必须完整初始化固定 64 字节 ABI 缓冲区，避免调用方读到先前栈内容。
     */
    for (index = sizeof("r545_99"); index < sizeof(branch); ++index) {
        if (branch[index] != '\0') {
            valid &= expect(0, "branch 尾部没有清零");
            break;
        }
    }

    version = UINT32_C(0x12345678);
    memset(branch, 0x5A, sizeof(branch));
    status = nvapi_fill_driver_and_branch_version(NULL, branch);
    valid &= expect(status == NVAPI_INVALID_ARGUMENT,
                    "空 version 没有返回 NVAPI_INVALID_ARGUMENT");
    valid &= expect((unsigned char)branch[0] == 0x5A,
                    "空 version 仍修改了 branch");

    status = nvapi_fill_driver_and_branch_version(&version, NULL);
    valid &= expect(status == NVAPI_INVALID_ARGUMENT,
                    "空 branch 没有返回 NVAPI_INVALID_ARGUMENT");
    valid &= expect(version == UINT32_C(0x12345678),
                    "空 branch 仍修改了 version");

    if (!valid) {
        return 1;
    }
    puts("PASS: driver version/branch 兼容 helper 契约通过");
    return 0;
}

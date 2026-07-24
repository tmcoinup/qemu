#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "aib_identity_catalog.h"
#include "gpu_model_catalog.h"

struct model_case {
    uint32_t vendor_id;
    uint32_t device_id;
    const char *expected_name;
};

/* NVIDIA NVAPI 公开短字符串 ABI 固定为 64 字节，末尾必须留给 NUL。 */
#define TEST_NVAPI_SHORT_STRING_MAX 64u

static int test_known_models(void)
{
    static const struct model_case cases[] = {
        { UINT32_C(0x10de), UINT32_C(0x1380),
          "NVIDIA GeForce GTX 750 Ti" },
        { UINT32_C(0x10de), UINT32_C(0x1d01),
          "NVIDIA GeForce GT 1030" },
        { UINT32_C(0x10de), UINT32_C(0x1c81),
          "NVIDIA GeForce GTX 1050" },
        { UINT32_C(0x10de), UINT32_C(0x1c82),
          "NVIDIA GeForce GTX 1050 Ti" },
        { UINT32_C(0x1002), UINT32_C(0x699f),
          "AMD Radeon RX 550" },
        { UINT32_C(0x1002), UINT32_C(0x67ff),
          "AMD Radeon RX 560" },
    };
    size_t index;

    for (index = 0u; index < sizeof(cases) / sizeof(cases[0]); ++index) {
        const char *actual = stealth_gpu_standard_model_name(
            cases[index].vendor_id, cases[index].device_id);
        if (actual == NULL || strcmp(actual, cases[index].expected_name) != 0 ||
            strchr(actual, '(') != NULL || strchr(actual, ')') != NULL) {
            fprintf(stderr, "FAIL: 标准型号映射错误: %04x:%04x\n",
                    (unsigned int)cases[index].vendor_id,
                    (unsigned int)cases[index].device_id);
            return 0;
        }
    }
    return 1;
}

static int test_unknown_models(void)
{
    return stealth_gpu_standard_model_name(UINT32_C(0x10de),
                                            UINT32_C(0xffff)) == NULL &&
        stealth_gpu_standard_model_name(UINT32_C(0xffff),
                                        UINT32_C(0x1c82)) == NULL &&
        stealth_gpu_standard_model_name(UINT32_C(0x1002),
                                        UINT32_C(0x1c82)) == NULL &&
        stealth_gpu_standard_model_name(UINT32_C(0x10de),
                                        UINT32_C(0x699f)) == NULL;
}

static int test_every_aib_board(void)
{
    size_t index;

    if (stealth_aib_identity_count() != 18u) {
        fprintf(stderr, "FAIL: 共享 AIB 目录数量不是 18\n");
        return 0;
    }
    for (index = 0u; index < stealth_aib_identity_count(); ++index) {
        const struct stealth_aib_identity *board =
            stealth_aib_identity_at(index);
        const char *standard_name;
        size_t board_length;
        size_t standard_length;

        if (board == NULL || board->name == NULL) {
            fprintf(stderr, "FAIL: AIB 目录存在空条目: %zu\n", index);
            return 0;
        }
        board_length = strlen(board->name);
        standard_name = stealth_gpu_standard_model_name(
            board->pci_vendor_id, board->pci_device_id);
        if (standard_name == NULL || strchr(standard_name, '(') != NULL ||
            strchr(standard_name, ')') != NULL) {
            fprintf(stderr, "FAIL: AIB 主 ID 没有标准型号: %s\n",
                    board->name);
            return 0;
        }
        standard_length = strlen(standard_name);
        /*
         * 先证明两个长度和 NVAPI 容量边界，再做偏移访问。完整 AIB 名必须至少
         * 比标准名多出“ (x)”四个字符，并以右括号结束。
         */
        if (standard_length == 0u ||
            standard_length >= TEST_NVAPI_SHORT_STRING_MAX ||
            board_length < standard_length + 4u ||
            board->name[board_length - 1u] != ')' ||
            strncmp(board->name, standard_name, standard_length) != 0 ||
            strncmp(board->name + standard_length, " (", 2u) != 0 ||
            strchr(board->name + standard_length + 2u, ')') == NULL) {
            fprintf(stderr, "FAIL: 完整 AIB 标签未保留板卡后缀: %s\n",
                    board->name);
            return 0;
        }
    }
    return 1;
}

int main(void)
{
    if (!test_known_models() || !test_unknown_models() ||
        !test_every_aib_board()) {
        fprintf(stderr, "FAIL: GPU 标准型号目录合同失败\n");
        return 1;
    }
    return 0;
}

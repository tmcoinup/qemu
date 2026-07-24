/*
 * schema-2 AIB 共享目录的 NVAPI 宿主机可执行测试。
 *
 * 每条共享板卡都必须经过与 DLL 相同的纯 C 校验器；NVIDIA 返回可发布身份，
 * 其他厂商必须被 NVAPI 拒绝。测试同时锁住未知 carrier 与整行串字段拒绝。
 */

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "aib_identity_catalog.h"
#include "nvapi_identity.h"
#include "nvapi_identity_contract.h"

static int format_source(char *output, size_t capacity,
                         uint32_t carrier_device_id, uint32_t revision_id)
{
    int length = snprintf(
        output, capacity,
        "PCI\\VEN_1AF4&DEV_1050&SUBSYS_%04" PRIX32
        "1AF4&REV_%02" PRIX32 "\\00",
        carrier_device_id, revision_id);

    return length > 0 && (size_t)length < capacity;
}

static struct nvapi_identity_contract_input make_input(
    const struct stealth_aib_identity *board, char *source, size_t capacity)
{
    struct nvapi_identity_contract_input input;

    memset(&input, 0, sizeof(input));
    if (!format_source(source, capacity, board->carrier_device_id,
                       board->revision_id)) {
        source[0] = '\0';
    }
    input.expected_token = "0123456789ABCDEF0123456789ABCDEF";
    input.identity_id = input.expected_token;
    input.name = board->name;
    input.vendor = board->vendor;
    input.bios = board->bios;
    input.memory_type = board->memory_type;
    input.source_instance_id = source;
    input.identity_mode = "shallow-user-projection";
    input.schema = STEALTH_GPU_SCHEMA_VERSION;
    input.pci_vendor_id = board->pci_vendor_id;
    input.pci_device_id = board->pci_device_id;
    input.subsystem_vendor_id = board->subsystem_vendor_id;
    input.subsystem_device_id = board->subsystem_device_id;
    input.revision_id = board->revision_id;
    input.ram_mb = board->ram_mb;
    input.memory_bus_width_bits = board->memory_bus_width_bits;
    input.base_clock_khz = board->base_clock_khz;
    input.boost_clock_khz = board->boost_clock_khz;
    input.memory_clock_khz = board->memory_clock_khz;
    input.sli_supported = board->sli_supported;
    input.bus_id = 1u;
    return input;
}

static int expect_rejected(
    const char *reason, const struct nvapi_identity_contract_input *input)
{
    struct nvapi_gpu_identity identity;

    memset(&identity, 0xa5, sizeof(identity));
    if (!nvapi_build_validated_identity(input, &identity) &&
        identity.name[0] == '\0') {
        return 1;
    }
    fprintf(stderr, "FAIL: %s 未被 NVAPI 拒绝\n", reason);
    return 0;
}

static int projected_pci_matches(
    const struct stealth_aib_identity *board,
    const struct nvapi_gpu_identity *identity)
{
    NvU32 device_id = 0u;
    NvU32 subsystem_id = 0u;
    NvU32 revision_id = 0u;
    NvU32 external_device_id = 0u;

    nvapi_build_carrier_pci_identifiers(
        identity, &device_id, &subsystem_id, &revision_id,
        &external_device_id);
    if (device_id == UINT32_C(0x10501af4) &&
        subsystem_id == nvapi_pack_pci_identifier(
            board->subsystem_device_id, board->subsystem_vendor_id) &&
        revision_id == board->revision_id &&
        external_device_id == board->pci_device_id) {
        return 1;
    }
    fprintf(stderr, "FAIL: NVIDIA AIB carrier/逻辑 PCI 输出错误: %s\n",
            board->name);
    return 0;
}

static int test_every_shared_board(void)
{
    size_t index;
    int valid = 1;

    for (index = 0u; index < stealth_aib_identity_count(); ++index) {
        const struct stealth_aib_identity *board =
            stealth_aib_identity_at(index);
        struct nvapi_identity_contract_input input;
        struct nvapi_gpu_identity identity;
        char source[96];

        if (board == NULL ||
            stealth_aib_identity_find_by_carrier(
                board->carrier_device_id) != board) {
            fprintf(stderr, "FAIL: 共享目录索引/carrier 不唯一: %zu\n",
                    index);
            valid = 0;
            continue;
        }
        input = make_input(board, source, sizeof(source));
        memset(&identity, 0xa5, sizeof(identity));
        if (board->pci_vendor_id == UINT32_C(0x10de)) {
            if (!nvapi_build_validated_identity(&input, &identity) ||
                strcmp(identity.name, board->name) != 0 ||
                identity.pci_device_id != board->pci_device_id ||
                identity.subsystem_vendor_id != board->subsystem_vendor_id ||
                identity.subsystem_device_id != board->subsystem_device_id ||
                identity.revision_id != board->revision_id ||
                identity.vram_kib != board->ram_mb * 1024u) {
                fprintf(stderr, "FAIL: NVIDIA AIB 未通过: %s\n",
                        board->name);
                valid = 0;
            } else if (!projected_pci_matches(board, &identity)) {
                valid = 0;
            }
        } else if (!expect_rejected("非 NVIDIA 共享板卡", &input)) {
            valid = 0;
        }
    }
    return valid;
}

static int test_fail_closed_mixes(void)
{
    const struct stealth_aib_identity *board = stealth_aib_identity_at(0u);
    struct nvapi_identity_contract_input input;
    char source[96];
    char crossed_source[96];
    int valid = 1;

    if (board == NULL) {
        fprintf(stderr, "FAIL: AIB 共享目录为空\n");
        return 0;
    }

    input = make_input(board, source, sizeof(source));
    if (!format_source(crossed_source, sizeof(crossed_source),
                       UINT32_C(0xa113), board->revision_id)) {
        fprintf(stderr, "FAIL: A113 测试来源格式化失败\n");
        return 0;
    }
    input.source_instance_id = crossed_source;
    valid &= expect_rejected("未知 carrier A113", &input);

    input = make_input(board, source, sizeof(source));
    input.name = "NVIDIA GeForce crossed AIB";
    valid &= expect_rejected("串入名称", &input);
    input = make_input(board, source, sizeof(source));
    input.bios = "Version 00.00.00.00.00";
    valid &= expect_rejected("串入 VBIOS", &input);
    input = make_input(board, source, sizeof(source));
    input.subsystem_device_id ^= 1u;
    valid &= expect_rejected("串入 subsystem", &input);
    input = make_input(board, source, sizeof(source));
    input.ram_mb += 1u;
    valid &= expect_rejected("串入显存容量", &input);
    input = make_input(board, source, sizeof(source));
    input.base_clock_khz += 1u;
    valid &= expect_rejected("串入核心时钟", &input);
    input = make_input(board, source, sizeof(source));
    input.memory_type = "GDDR6";
    valid &= expect_rejected("串入显存类型", &input);

    if (stealth_aib_identity_count() > 1u) {
        const struct stealth_aib_identity *other =
            stealth_aib_identity_at(1u);
        input = make_input(board, source, sizeof(source));
        if (other == NULL ||
            !format_source(crossed_source, sizeof(crossed_source),
                           other->carrier_device_id, other->revision_id)) {
            fprintf(stderr, "FAIL: 跨板 carrier 测试准备失败\n");
            return 0;
        }
        input.source_instance_id = crossed_source;
        valid &= expect_rejected("串入另一板卡 carrier", &input);
    }
    return valid;
}

int main(void)
{
    return test_every_shared_board() && test_fail_closed_mixes() ? 0 : 1;
}

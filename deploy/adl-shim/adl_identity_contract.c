#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "aib_identity_catalog.h"
#include "adl_identity_contract.h"

#define AMD_PCI_VENDOR_ID UINT32_C(0x1002)
#define NVIDIA_PCI_VENDOR_ID UINT32_C(0x10DE)
#define VIRTIO_PCI_VENDOR_ID UINT32_C(0x1AF4)

struct amd_model_spec {
    uint32_t device_id;
    uint32_t revision_id;
    uint32_t ram_mb;
    uint32_t bus_width;
    uint32_t base_clock_khz;
    uint32_t boost_clock_khz;
    uint32_t memory_clock_khz;
    uint32_t compute_units;
    const char *name;
};

static const struct amd_model_spec g_models[] = {
    { UINT32_C(0x699f), UINT32_C(0xcf), 2048u, 128u,
      1100000u, 1183000u, 3500000u, 8u, "AMD Radeon RX 550" },
    { UINT32_C(0x67ff), UINT32_C(0xcf), 4096u, 128u,
      1175000u, 1275000u, 3500000u, 16u, "AMD Radeon RX 560" }
};

static int is_upper_hex_digit(char value)
{
    return (value >= '0' && value <= '9') ||
           (value >= 'A' && value <= 'F');
}

static int hex_digit_value(char value)
{
    if (value >= '0' && value <= '9') {
        return value - '0';
    }
    if (value >= 'A' && value <= 'F') {
        return value - 'A' + 10;
    }
    return -1;
}

static int parse_fixed_hex(const char *text, size_t digits, uint32_t *output)
{
    size_t index;
    uint32_t parsed = 0u;

    if (text == NULL || output == NULL) {
        return 0;
    }
    for (index = 0u; index < digits; ++index) {
        int nibble = hex_digit_value(text[index]);
        if (nibble < 0) {
            return 0;
        }
        parsed = (parsed << 4) | (uint32_t)nibble;
    }
    *output = parsed;
    return 1;
}

int adl_validate_identity_token(const char *token)
{
    size_t index;

    if (token == NULL) {
        return 0;
    }
    for (index = 0u; index < STEALTH_GPU_IDENTITY_TOKEN_LENGTH; ++index) {
        if (token[index] == '\0' || !is_upper_hex_digit(token[index])) {
            return 0;
        }
    }
    return token[STEALTH_GPU_IDENTITY_TOKEN_LENGTH] == '\0';
}

static int parse_source_instance_id(const char *source,
                                    uint32_t *subsystem_device,
                                    uint32_t *subsystem_vendor,
                                    uint32_t *revision)
{
    static const char prefix[] = "PCI\\VEN_1AF4&DEV_1050&SUBSYS_";
    static const char revision_marker[] = "&REV_";
    size_t offset = sizeof(prefix) - 1u;
    const size_t minimum_length = (sizeof(prefix) - 1u) + 8u +
        (sizeof(revision_marker) - 1u) + 3u;
    uint32_t packed_subsystem;

    if (source == NULL || strlen(source) < minimum_length ||
        memcmp(source, prefix, offset) != 0 ||
        !parse_fixed_hex(source + offset, 8u, &packed_subsystem)) {
        return 0;
    }
    offset += 8u;
    if (memcmp(source + offset, revision_marker,
               sizeof(revision_marker) - 1u) != 0) {
        return 0;
    }
    offset += sizeof(revision_marker) - 1u;
    if (!parse_fixed_hex(source + offset, 2u, revision) ||
        (source[offset + 2u] != '&' && source[offset + 2u] != '\\')) {
        return 0;
    }
    *subsystem_device = (packed_subsystem >> 16) & UINT32_C(0xffff);
    *subsystem_vendor = packed_subsystem & UINT32_C(0xffff);
    return 1;
}

static int aib_bundle_matches(
    const struct adl_identity_contract_input *input,
    const struct stealth_aib_identity *identity)
{
    struct stealth_aib_identity_snapshot snapshot;

    /*
     * ADL 对目录中的 12 块 NVIDIA 最终返回 ABSENT，对 6 块 AMD 返回
     * PRESENT；两类都先执行相同的公共整行等式，不再复制品牌表。
     */
    snapshot.name = input->name;
    snapshot.vendor = input->vendor;
    snapshot.bios = input->bios;
    snapshot.memory_type = input->memory_type;
    snapshot.pci_vendor_id = input->pci_vendor_id;
    snapshot.pci_device_id = input->pci_device_id;
    snapshot.subsystem_vendor_id = input->subsystem_vendor_id;
    snapshot.subsystem_device_id = input->subsystem_device_id;
    snapshot.revision_id = input->revision_id;
    snapshot.ram_mb = input->ram_mb;
    snapshot.memory_bus_width_bits = input->memory_bus_width_bits;
    snapshot.base_clock_khz = input->base_clock_khz;
    snapshot.boost_clock_khz = input->boost_clock_khz;
    snapshot.memory_clock_khz = input->memory_clock_khz;
    snapshot.sli_supported = input->sli_supported;
    return input->schema == STEALTH_GPU_SCHEMA_VERSION &&
        stealth_aib_identity_snapshot_matches(identity, &snapshot);
}

static int source_matches_logical_identity(
    const struct adl_identity_contract_input *input,
    uint32_t source_subsystem_device, uint32_t source_subsystem_vendor,
    uint32_t source_revision,
    const struct stealth_aib_identity **matched_identity)
{
    const struct stealth_aib_identity *identity;

    if (matched_identity == NULL || source_revision != input->revision_id) {
        return 0;
    }
    *matched_identity = NULL;

    /*
     * schema-1 只允许 logical main/main；schema-2 只允许共享表中的
     * 1AF4:Axxx carrier。两条路径互斥，避免迁移快照混搭。
     */
    if (input->schema == STEALTH_GPU_LEGACY_SCHEMA_VERSION) {
        return input->subsystem_vendor_id == input->pci_vendor_id &&
            input->subsystem_device_id == input->pci_device_id &&
            source_subsystem_vendor == input->pci_vendor_id &&
            source_subsystem_device == input->pci_device_id;
    }
    if (source_subsystem_vendor != VIRTIO_PCI_VENDOR_ID) {
        return 0;
    }
    identity = stealth_aib_identity_find_by_carrier(
        source_subsystem_device);
    if (identity == NULL || source_revision != identity->revision_id ||
        !aib_bundle_matches(input, identity)) {
        return 0;
    }
    *matched_identity = identity;
    return 1;
}

static int copy_printable_ascii(char *output, size_t capacity,
                                const char *source)
{
    size_t length;
    size_t index;

    if (output == NULL || source == NULL || capacity < 2u) {
        return 0;
    }
    length = strlen(source);
    if (length == 0u || length >= capacity) {
        return 0;
    }
    for (index = 0u; index < length; ++index) {
        unsigned char value = (unsigned char)source[index];
        if (value < 0x20u || value > 0x7eu) {
            return 0;
        }
    }
    memcpy(output, source, length + 1u);
    return 1;
}

static int contains_ascii_case_insensitive(const char *text,
                                           const char *needle)
{
    size_t needle_length;
    const char *cursor;

    if (text == NULL || needle == NULL || needle[0] == '\0') {
        return 0;
    }
    needle_length = strlen(needle);
    for (cursor = text; *cursor != '\0'; ++cursor) {
        size_t index;
        for (index = 0u; index < needle_length; ++index) {
            unsigned char left = (unsigned char)cursor[index];
            unsigned char right = (unsigned char)needle[index];
            if (left == '\0') {
                return 0;
            }
            if (left >= 'A' && left <= 'Z') {
                left = (unsigned char)(left - 'A' + 'a');
            }
            if (right >= 'A' && right <= 'Z') {
                right = (unsigned char)(right - 'A' + 'a');
            }
            if (left != right) {
                break;
            }
        }
        if (index == needle_length) {
            return 1;
        }
    }
    return 0;
}

static const struct amd_model_spec *find_model(uint32_t device_id)
{
    size_t index;

    for (index = 0u; index < sizeof(g_models) / sizeof(g_models[0]); ++index) {
        if (g_models[index].device_id == device_id) {
            return &g_models[index];
        }
    }
    return NULL;
}

static int common_snapshot_is_valid(
    const struct adl_identity_contract_input *input,
    uint32_t *source_subsystem_device, uint32_t *source_subsystem_vendor,
    uint32_t *source_revision,
    const struct stealth_aib_identity **matched_identity)
{
    return input != NULL &&
        (input->schema == STEALTH_GPU_SCHEMA_VERSION ||
         input->schema == STEALTH_GPU_LEGACY_SCHEMA_VERSION) &&
        adl_validate_identity_token(input->expected_token) &&
        adl_validate_identity_token(input->identity_id) &&
        strcmp(input->expected_token, input->identity_id) == 0 &&
        input->identity_mode != NULL &&
        strcmp(input->identity_mode, "shallow-user-projection") == 0 &&
        parse_source_instance_id(input->source_instance_id,
                                 source_subsystem_device,
                                 source_subsystem_vendor, source_revision) &&
        source_matches_logical_identity(input, *source_subsystem_device,
                                        *source_subsystem_vendor,
                                        *source_revision,
                                        matched_identity) &&
        input->revision_id <= UINT32_C(0xff) &&
        input->bus_id <= UINT32_C(0xff) &&
        input->slot_id <= UINT32_C(0x1f) &&
        input->function_id <= UINT32_C(0x7);
}

static int is_normal_nvidia_profile(
    const struct adl_identity_contract_input *input)
{
    return input->vendor != NULL && strcmp(input->vendor, "NVIDIA") == 0 &&
        input->name != NULL && strncmp(input->name, "NVIDIA ", 7u) == 0 &&
        !contains_ascii_case_insensitive(input->name, "Red Hat") &&
        !contains_ascii_case_insensitive(input->name, "VirtIO") &&
        input->pci_vendor_id == NVIDIA_PCI_VENDOR_ID;
}

enum adl_identity_state adl_build_validated_identity(
    const struct adl_identity_contract_input *input,
    struct adl_gpu_identity *identity)
{
    const struct amd_model_spec *model;
    const struct stealth_aib_identity *aib_identity = NULL;
    uint32_t source_subsystem_device = 0u;
    uint32_t source_subsystem_vendor = 0u;
    uint32_t source_revision = 0u;

    if (identity == NULL) {
        return ADL_IDENTITY_INVALID;
    }
    memset(identity, 0, sizeof(*identity));
    if (!common_snapshot_is_valid(input, &source_subsystem_device,
                                  &source_subsystem_vendor,
                                  &source_revision, &aib_identity)) {
        return ADL_IDENTITY_INVALID;
    }

    model = find_model(input->pci_device_id);
    if (input->schema == STEALTH_GPU_SCHEMA_VERSION) {
        /*
         * schema-2 已由共享 AIB 表逐字段证明。合法 NVIDIA 板卡对 ADL
         * 表现为 ABSENT；合法 AMD 板卡使用同一整行数据生成 PRESENT。
         */
        if (aib_identity == NULL) {
            return ADL_IDENTITY_INVALID;
        }
        if (aib_identity->pci_vendor_id == NVIDIA_PCI_VENDOR_ID) {
            return ADL_IDENTITY_ABSENT;
        }
        if (aib_identity->pci_vendor_id != AMD_PCI_VENDOR_ID ||
            input->pci_vendor_id != AMD_PCI_VENDOR_ID || model == NULL) {
            return ADL_IDENTITY_INVALID;
        }
    } else {
        if (is_normal_nvidia_profile(input)) {
            return ADL_IDENTITY_ABSENT;
        }
        if (model == NULL || input->vendor == NULL ||
            strcmp(input->vendor, "AMD") != 0 || input->name == NULL ||
            strcmp(input->name, model->name) != 0 ||
            contains_ascii_case_insensitive(input->name, "Red Hat") ||
            contains_ascii_case_insensitive(input->name, "VirtIO") ||
            input->bios == NULL ||
            strcmp(input->bios, "016.011.000.029.000000") != 0 ||
            input->pci_vendor_id != AMD_PCI_VENDOR_ID ||
            input->subsystem_vendor_id != AMD_PCI_VENDOR_ID ||
            input->subsystem_device_id != model->device_id ||
            input->revision_id != model->revision_id ||
            input->ram_mb != model->ram_mb ||
            input->sli_supported != 0u) {
            return ADL_IDENTITY_INVALID;
        }
    }

    if (!copy_printable_ascii(identity->name, sizeof(identity->name),
                              input->name) ||
        !copy_printable_ascii(identity->vendor, sizeof(identity->vendor),
                              input->vendor) ||
        !copy_printable_ascii(identity->bios, sizeof(identity->bios),
                              input->bios)) {
        memset(identity, 0, sizeof(*identity));
        return ADL_IDENTITY_INVALID;
    }

    identity->pci_vendor_id = input->pci_vendor_id;
    identity->pci_device_id = input->pci_device_id;
    identity->subsystem_vendor_id = input->subsystem_vendor_id;
    identity->subsystem_device_id = input->subsystem_device_id;
    identity->revision_id = input->revision_id;
    identity->ram_mb = input->ram_mb;
    if (input->schema == STEALTH_GPU_SCHEMA_VERSION) {
        identity->memory_bus_width_bits = input->memory_bus_width_bits;
        identity->base_clock_khz = input->base_clock_khz;
        identity->boost_clock_khz = input->boost_clock_khz;
        identity->memory_clock_khz = input->memory_clock_khz;
    } else {
        identity->memory_bus_width_bits = model->bus_width;
        identity->base_clock_khz = model->base_clock_khz;
        identity->boost_clock_khz = model->boost_clock_khz;
        identity->memory_clock_khz = model->memory_clock_khz;
    }
    identity->bus_id = input->bus_id;
    identity->slot_id = input->slot_id;
    identity->function_id = input->function_id;
    identity->compute_units = model->compute_units;
    identity->processing_elements_per_cu = 64u;
    identity->rops = 16u;
    return ADL_IDENTITY_PRESENT;
}

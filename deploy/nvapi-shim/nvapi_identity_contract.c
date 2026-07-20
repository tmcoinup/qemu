#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "nvapi_gpu_specs.h"
#include "nvapi_identity_contract.h"

#define NVIDIA_PCI_VENDOR_ID UINT32_C(0x10DE)

/*
 * NVAPI 只能投影仓库 GPU_POOL 中完整的 NVIDIA 硬件 bundle。不能仅按
 * VEN/DEV 接受任意名称、显存或 VBIOS，否则一份被部分覆盖的 schema 快照
 * 会组合成现实中不存在的显卡。BDF 属于实际 virtio carrier 的证明，不在
 * 这里固定；其余型号规格必须逐项命中本表。
 */
struct nvapi_canonical_model {
    const char *name;
    const char *vendor;
    const char *bios;
    const char *memory_type;
    NvU32 pci_device_id;
    NvU32 revision_id;
    NvU32 ram_mb;
    NvU32 memory_bus_width_bits;
    NvU32 base_clock_khz;
    NvU32 boost_clock_khz;
    NvU32 memory_clock_khz;
    NvU32 sli_supported;
};

static const struct nvapi_canonical_model g_canonical_models[] = {
    { "NVIDIA GeForce GTX 750 Ti", "NVIDIA", "Version 82.07.41.00.32",
      "GDDR5", UINT32_C(0x1380), UINT32_C(0xa2), 2048u, 128u,
      1020000u, 1085000u, 2700000u, 0u },
    { "NVIDIA GeForce GT 1030", "NVIDIA", "Version 86.08.46.00.81",
      "GDDR5", UINT32_C(0x1d01), UINT32_C(0xa1), 2048u, 64u,
      1227000u, 1468000u, 3004000u, 0u },
    { "NVIDIA GeForce GTX 1050", "NVIDIA", "Version 86.07.48.00.38",
      "GDDR5", UINT32_C(0x1c81), UINT32_C(0xa1), 2048u, 128u,
      1354000u, 1455000u, 3504000u, 0u },
    { "NVIDIA GeForce GTX 1050 Ti", "NVIDIA", "Version 86.07.48.00.A0",
      "GDDR5", UINT32_C(0x1c82), UINT32_C(0xa1), 4096u, 128u,
      1290000u, 1392000u, 3504000u, 0u },
};

static const struct nvapi_canonical_model *find_canonical_model(
    NvU32 pci_vendor_id, NvU32 pci_device_id)
{
    size_t index;

    if (pci_vendor_id != NVIDIA_PCI_VENDOR_ID) {
        return NULL;
    }
    for (index = 0u; index < sizeof(g_canonical_models) /
             sizeof(g_canonical_models[0]); ++index) {
        if (g_canonical_models[index].pci_device_id == pci_device_id) {
            return &g_canonical_models[index];
        }
    }
    return NULL;
}

static int matches_canonical_model(
    const struct nvapi_identity_contract_input *input)
{
    const struct nvapi_canonical_model *model;

    if (input == NULL || input->name == NULL || input->vendor == NULL ||
        input->bios == NULL || input->memory_type == NULL) {
        return 0;
    }
    model = find_canonical_model(input->pci_vendor_id, input->pci_device_id);
    return model != NULL && strcmp(input->name, model->name) == 0 &&
        strcmp(input->vendor, model->vendor) == 0 &&
        strcmp(input->bios, model->bios) == 0 &&
        strcmp(input->memory_type, model->memory_type) == 0 &&
        input->revision_id == model->revision_id &&
        input->ram_mb == model->ram_mb &&
        input->memory_bus_width_bits == model->memory_bus_width_bits &&
        input->base_clock_khz == model->base_clock_khz &&
        input->boost_clock_khz == model->boost_clock_khz &&
        input->memory_clock_khz == model->memory_clock_khz &&
        input->sli_supported == model->sli_supported;
}

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

static int parse_fixed_hex(const char *text, size_t digits, NvU32 *output)
{
    size_t index;
    NvU32 parsed = 0u;

    for (index = 0; index < digits; ++index) {
        int nibble = hex_digit_value(text[index]);
        if (nibble < 0) {
            return 0;
        }
        parsed = (parsed << 4) | (NvU32)nibble;
    }
    *output = parsed;
    return 1;
}

int nvapi_validate_identity_token(const char *token)
{
    size_t index;

    if (token == NULL) {
        return 0;
    }
    for (index = 0; index < STEALTH_GPU_IDENTITY_TOKEN_LENGTH; ++index) {
        /* 先逐字节检查；短字符串会在自身 NUL 处停止，不先访问固定 offset。 */
        if (token[index] == '\0' || !is_upper_hex_digit(token[index])) {
            return 0;
        }
    }
    return token[STEALTH_GPU_IDENTITY_TOKEN_LENGTH] == '\0';
}

static int parse_source_instance_id(const char *source,
                                    NvU32 *subsystem_device,
                                    NvU32 *subsystem_vendor,
                                    NvU32 *revision)
{
    static const char prefix[] = "PCI\\VEN_1AF4&DEV_1050&SUBSYS_";
    static const char revision_marker[] = "&REV_";
    size_t offset = sizeof(prefix) - 1u;
    const size_t minimum_length = (sizeof(prefix) - 1u) + 8u +
        (sizeof(revision_marker) - 1u) + 3u;
    NvU32 packed_subsystem;

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
    /* SUBSYS 文本顺序固定为设备号在前、厂商号在后。 */
    *subsystem_device = (packed_subsystem >> 16) & UINT32_C(0xffff);
    *subsystem_vendor = packed_subsystem & UINT32_C(0xffff);
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
    for (index = 0; index < length; ++index) {
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
        for (index = 0; index < needle_length; ++index) {
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

int nvapi_get_legacy_extension_defaults(
    NvU32 pci_vendor_id, NvU32 pci_device_id,
    struct nvapi_legacy_extension_defaults *defaults)
{
    const struct nvapi_canonical_model *model;

    if (defaults == NULL) {
        return 0;
    }
    model = find_canonical_model(pci_vendor_id, pci_device_id);
    if (model == NULL) {
        return 0;
    }
    memset(defaults, 0, sizeof(*defaults));
    defaults->memory_bus_width_bits = model->memory_bus_width_bits;
    defaults->base_clock_khz = model->base_clock_khz;
    defaults->boost_clock_khz = model->boost_clock_khz;
    defaults->memory_clock_khz = model->memory_clock_khz;
    return 1;
}

int nvapi_build_validated_identity(
    const struct nvapi_identity_contract_input *input,
    struct nvapi_gpu_identity *identity)
{
    NvU32 source_subsystem_device;
    NvU32 source_subsystem_vendor;
    NvU32 source_revision;
    struct nvapi_legacy_extension_defaults legacy_defaults;

    if (input == NULL || identity == NULL) {
        return 0;
    }
    memset(identity, 0, sizeof(*identity));
    if ((input->schema != STEALTH_GPU_SCHEMA_VERSION &&
         input->schema != STEALTH_GPU_LEGACY_SCHEMA_VERSION) ||
        !nvapi_validate_identity_token(input->expected_token) ||
        !nvapi_validate_identity_token(input->identity_id) ||
        strcmp(input->expected_token, input->identity_id) != 0 ||
        !copy_printable_ascii(identity->name, sizeof(identity->name),
                              input->name) ||
        strncmp(input->name, "NVIDIA ", 7u) != 0 ||
        contains_ascii_case_insensitive(input->name, "Red Hat") ||
        contains_ascii_case_insensitive(input->name, "VirtIO") ||
        !copy_printable_ascii(identity->vendor, sizeof(identity->vendor),
                              input->vendor) ||
        strcmp(input->vendor, "NVIDIA") != 0 ||
        input->memory_type == NULL || strcmp(input->memory_type, "GDDR5") != 0 ||
        input->identity_mode == NULL ||
        strcmp(input->identity_mode, "shallow-user-projection") != 0 ||
        !parse_source_instance_id(input->source_instance_id,
                                  &source_subsystem_device,
                                  &source_subsystem_vendor,
                                  &source_revision) ||
        input->pci_vendor_id != NVIDIA_PCI_VENDOR_ID ||
        input->pci_device_id == 0u || input->pci_device_id > UINT32_C(0xffff) ||
        input->subsystem_vendor_id != input->pci_vendor_id ||
        input->subsystem_device_id != input->pci_device_id ||
        input->revision_id > UINT32_C(0xff) ||
        source_subsystem_vendor != input->subsystem_vendor_id ||
        source_subsystem_device != input->subsystem_device_id ||
        source_revision != input->revision_id ||
        input->ram_mb == 0u || input->ram_mb > UINT32_C(1048576) ||
        input->memory_bus_width_bits < 32u ||
        input->memory_bus_width_bits > 1024u ||
        (input->memory_bus_width_bits &
         (input->memory_bus_width_bits - 1u)) != 0u ||
        input->base_clock_khz < 100000u || input->base_clock_khz > 5000000u ||
        input->boost_clock_khz < input->base_clock_khz ||
        input->boost_clock_khz > 5000000u ||
        input->memory_clock_khz < 100000u ||
        input->memory_clock_khz > 10000000u ||
        !matches_canonical_model(input) ||
        (input->schema == STEALTH_GPU_LEGACY_SCHEMA_VERSION &&
         (!nvapi_get_legacy_extension_defaults(input->pci_vendor_id,
                                               input->pci_device_id,
                                               &legacy_defaults) ||
          input->memory_bus_width_bits != legacy_defaults.memory_bus_width_bits ||
          input->base_clock_khz != legacy_defaults.base_clock_khz ||
          input->boost_clock_khz != legacy_defaults.boost_clock_khz ||
          input->memory_clock_khz != legacy_defaults.memory_clock_khz ||
          input->sli_supported != 0u)) ||
        /* 当前 shim 只实现单卡非 SLI 拓扑，profile 必须明确声明 0。 */
        input->sli_supported != 0u || input->bus_id > UINT32_C(0xff) ||
        input->slot_id > UINT32_C(0x1f) || input->function_id > 7u ||
        !nvapi_parse_vbios(input->bios, identity->bios,
                           &identity->vbios_revision,
                           &identity->vbios_oem_revision)) {
        memset(identity, 0, sizeof(*identity));
        return 0;
    }

    identity->pci_vendor_id = input->pci_vendor_id;
    identity->pci_device_id = input->pci_device_id;
    identity->subsystem_vendor_id = input->subsystem_vendor_id;
    identity->subsystem_device_id = input->subsystem_device_id;
    identity->revision_id = input->revision_id;
    identity->vram_kib = input->ram_mb * 1024u;
    identity->ram_type = 8u; /* 历史 NV_GPU_RAM_GDDR5 枚举值。 */
    identity->ram_bus_width_bits = input->memory_bus_width_bits;
    identity->base_clock_khz = input->base_clock_khz;
    identity->boost_clock_khz = input->boost_clock_khz;
    identity->memory_clock_khz = input->memory_clock_khz;
    identity->bus_id = input->bus_id;
    identity->slot_id = input->slot_id;
    identity->has_bus_id = 1;
    identity->has_slot_id = 1;
    return 1;
}

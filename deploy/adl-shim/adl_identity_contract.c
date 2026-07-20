#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "adl_identity_contract.h"

#define AMD_PCI_VENDOR_ID UINT32_C(0x1002)
#define NVIDIA_PCI_VENDOR_ID UINT32_C(0x10DE)

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
    uint32_t *source_revision)
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
        input->subsystem_vendor_id == *source_subsystem_vendor &&
        input->subsystem_device_id == *source_subsystem_device &&
        input->revision_id == *source_revision &&
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
        input->pci_vendor_id == NVIDIA_PCI_VENDOR_ID &&
        input->subsystem_vendor_id == NVIDIA_PCI_VENDOR_ID &&
        input->pci_device_id == input->subsystem_device_id;
}

enum adl_identity_state adl_build_validated_identity(
    const struct adl_identity_contract_input *input,
    struct adl_gpu_identity *identity)
{
    const struct amd_model_spec *model;
    uint32_t source_subsystem_device = 0u;
    uint32_t source_subsystem_vendor = 0u;
    uint32_t source_revision = 0u;

    if (identity == NULL) {
        return ADL_IDENTITY_INVALID;
    }
    memset(identity, 0, sizeof(*identity));
    if (!common_snapshot_is_valid(input, &source_subsystem_device,
                                  &source_subsystem_vendor,
                                  &source_revision)) {
        return ADL_IDENTITY_INVALID;
    }
    if (is_normal_nvidia_profile(input)) {
        return ADL_IDENTITY_ABSENT;
    }

    model = find_model(input->pci_device_id);
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

    if (input->schema == STEALTH_GPU_SCHEMA_VERSION &&
        (input->memory_type == NULL ||
         strcmp(input->memory_type, "GDDR5") != 0 ||
         input->memory_bus_width_bits != model->bus_width ||
         input->base_clock_khz != model->base_clock_khz ||
         input->boost_clock_khz != model->boost_clock_khz ||
         input->memory_clock_khz != model->memory_clock_khz)) {
        return ADL_IDENTITY_INVALID;
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

    identity->pci_vendor_id = AMD_PCI_VENDOR_ID;
    identity->pci_device_id = model->device_id;
    identity->subsystem_vendor_id = AMD_PCI_VENDOR_ID;
    identity->subsystem_device_id = model->device_id;
    identity->revision_id = model->revision_id;
    identity->ram_mb = model->ram_mb;
    identity->memory_bus_width_bits = model->bus_width;
    identity->base_clock_khz = model->base_clock_khz;
    identity->boost_clock_khz = model->boost_clock_khz;
    identity->memory_clock_khz = model->memory_clock_khz;
    identity->bus_id = input->bus_id;
    identity->slot_id = input->slot_id;
    identity->function_id = input->function_id;
    identity->compute_units = model->compute_units;
    identity->processing_elements_per_cu = 64u;
    identity->rops = 16u;
    return ADL_IDENTITY_PRESENT;
}

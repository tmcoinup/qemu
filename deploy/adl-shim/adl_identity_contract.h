#ifndef STEALTH_ADL_IDENTITY_CONTRACT_H
#define STEALTH_ADL_IDENTITY_CONTRACT_H

#include <stdint.h>

#include "adl_identity.h"

#define STEALTH_GPU_SCHEMA_VERSION 2u
#define STEALTH_GPU_LEGACY_SCHEMA_VERSION 1u
#define STEALTH_GPU_IDENTITY_TOKEN_LENGTH 32u

struct adl_identity_contract_input {
    const char *expected_token;
    const char *identity_id;
    const char *name;
    const char *vendor;
    const char *bios;
    const char *memory_type;
    const char *source_instance_id;
    const char *identity_mode;
    uint32_t schema;
    uint32_t pci_vendor_id;
    uint32_t pci_device_id;
    uint32_t subsystem_vendor_id;
    uint32_t subsystem_device_id;
    uint32_t revision_id;
    uint32_t ram_mb;
    uint32_t memory_bus_width_bits;
    uint32_t base_clock_khz;
    uint32_t boost_clock_khz;
    uint32_t memory_clock_khz;
    uint32_t sli_supported;
    uint32_t bus_id;
    uint32_t slot_id;
    uint32_t function_id;
};

int adl_validate_identity_token(const char *token);
enum adl_identity_state adl_build_validated_identity(
    const struct adl_identity_contract_input *input,
    struct adl_gpu_identity *identity);

#endif

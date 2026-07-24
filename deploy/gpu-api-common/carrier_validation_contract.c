#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "carrier_validation.h"

#define VIRTIO_GPU_VENDOR_ID UINT32_C(0x1af4)
#define VIRTIO_GPU_DEVICE_ID UINT32_C(0x1050)

static unsigned char ascii_fold(unsigned char value)
{
    if (value >= 'A' && value <= 'Z') {
        return (unsigned char)(value - 'A' + 'a');
    }
    return value;
}

static int ascii_equals(const char *left, const char *right)
{
    size_t index;

    if (left == NULL || right == NULL) {
        return 0;
    }
    for (index = 0u; left[index] != '\0' && right[index] != '\0'; ++index) {
        if (ascii_fold((unsigned char)left[index]) !=
            ascii_fold((unsigned char)right[index])) {
            return 0;
        }
    }
    return left[index] == '\0' && right[index] == '\0';
}

static int ascii_equals_length(const char *left, const char *right,
                               size_t length)
{
    size_t index;

    if (left == NULL || right == NULL) {
        return 0;
    }
    for (index = 0u; index < length; ++index) {
        if (ascii_fold((unsigned char)left[index]) !=
            ascii_fold((unsigned char)right[index])) {
            return 0;
        }
    }
    return 1;
}

static int copy_printable_ascii(char *output, size_t capacity,
                                const char *input)
{
    size_t index;
    size_t length;

    if (output == NULL || input == NULL || capacity < 2u) {
        return 0;
    }
    length = strlen(input);
    if (length == 0u || length >= capacity) {
        return 0;
    }
    for (index = 0u; index < length; ++index) {
        unsigned char value = (unsigned char)input[index];
        if (value < 0x20u || value > 0x7eu) {
            return 0;
        }
    }
    memcpy(output, input, length + 1u);
    return 1;
}

/* SourceInstanceId 必须有 PCI 枚举器分隔符和实例后缀，不能接受 hardware ID。 */
static size_t source_hardware_id_length(const char *source)
{
    const char *first_separator;
    const char *instance_separator;

    if (source == NULL) {
        return 0u;
    }
    first_separator = strchr(source, '\\');
    if (first_separator == NULL) {
        return 0u;
    }
    instance_separator = strchr(first_separator + 1, '\\');
    if (instance_separator == NULL || instance_separator == source ||
        instance_separator[1] == '\0') {
        return 0u;
    }
    return (size_t)(instance_separator - source);
}

static int source_is_virtio_gpu(const char *source, size_t hardware_length)
{
    static const char prefix[] = "PCI\\VEN_1AF4&DEV_1050&";

    return hardware_length > sizeof(prefix) - 1u &&
        ascii_equals_length(source, prefix, sizeof(prefix) - 1u);
}

static int hardware_id_is_virtio_gpu(const char *value, size_t length)
{
    static const char prefix[] = "PCI\\VEN_1AF4&DEV_1050";
    const size_t prefix_length = sizeof(prefix) - 1u;

    return length >= prefix_length &&
        ascii_equals_length(value, prefix, prefix_length) &&
        (length == prefix_length || value[prefix_length] == '&');
}

/*
 * 合法终态只有两种：
 *   1. 驱动/PnP 操作窗口中的全物理 1AF4:1050 数组；
 *   2. 与当前不可变 identity 精确一致的唯一逻辑首项，后接完整物理数组。
 * 任意逻辑-only、逻辑项不在首位、第二个逻辑项或第三方前缀都 fail-closed。
 */
static const char *multisz_find_physical_hardware_id(
    const char *values, size_t bytes, const char *expected_logical)
{
    size_t offset = 0u;
    size_t item_index = 0u;
    size_t logical_length;
    const char *found = NULL;

    if (values == NULL || expected_logical == NULL || bytes < 2u) {
        return NULL;
    }
    logical_length = strlen(expected_logical);
    while (offset < bytes) {
        size_t length = 0u;

        while (offset + length < bytes && values[offset + length] != '\0') {
            ++length;
        }
        if (offset + length >= bytes) {
            return NULL;
        }
        if (length == 0u) {
            /* 只有结尾的第二个 NUL 合法，提前空项或尾随垃圾都拒绝。 */
            return offset + 1u == bytes ? found : NULL;
        }
        if (item_index == 0u && length == logical_length &&
            ascii_equals_length(values + offset, expected_logical,
                                logical_length)) {
            /* 精确逻辑首项必须由后续至少一个物理匹配项承载。 */
        } else if (!hardware_id_is_virtio_gpu(values + offset, length)) {
            return NULL;
        } else if (found == NULL) {
            found = values + offset;
        }
        offset += length + 1u;
        ++item_index;
    }
    return NULL;
}

static int build_expected_logical_hardware_id(
    const struct stealth_gpu_logical_pci_identity *identity,
    char *output, size_t capacity)
{
    int written;

    if (identity == NULL || output == NULL ||
        identity->vendor_id == 0u || identity->vendor_id > UINT32_C(0xffff) ||
        identity->device_id == 0u || identity->device_id > UINT32_C(0xffff) ||
        identity->subsystem_vendor_id == 0u ||
        identity->subsystem_vendor_id > UINT32_C(0xffff) ||
        identity->subsystem_device_id > UINT32_C(0xffff) ||
        identity->revision_id > UINT32_C(0xff) ||
        (identity->vendor_id == VIRTIO_GPU_VENDOR_ID &&
         identity->device_id == VIRTIO_GPU_DEVICE_ID)) {
        return 0;
    }
    written = snprintf(output, capacity,
                       "PCI\\VEN_%04X&DEV_%04X&SUBSYS_%04X%04X&REV_%02X",
                       (unsigned int)identity->vendor_id,
                       (unsigned int)identity->device_id,
                       (unsigned int)identity->subsystem_device_id,
                       (unsigned int)identity->subsystem_vendor_id,
                       (unsigned int)identity->revision_id);
    return written > 0 && (size_t)written < capacity;
}

/* SPDRP_DRIVER 在 Display class 中必须指向实际的 {GUID}\\NNNN 子键。 */
static int driver_key_is_display_class(const char *driver_key)
{
    static const char prefix[] =
        "{4D36E968-E325-11CE-BFC1-08002BE10318}\\";
    size_t prefix_length = sizeof(prefix) - 1u;
    size_t index;

    if (driver_key == NULL || strlen(driver_key) != prefix_length + 4u ||
        !ascii_equals_length(driver_key, prefix, prefix_length)) {
        return 0;
    }
    for (index = prefix_length; index < prefix_length + 4u; ++index) {
        if (driver_key[index] < '0' || driver_key[index] > '9') {
            return 0;
        }
    }
    return 1;
}

int stealth_validate_virtio_gpu_carrier_observation(
    const char *expected_source_instance_id, uint32_t expected_bus_id,
    uint32_t expected_slot_id, uint32_t expected_function_id,
    const struct stealth_gpu_logical_pci_identity *logical_identity,
    const struct stealth_gpu_carrier_observation *observation,
    struct stealth_gpu_carrier *carrier)
{
    struct stealth_gpu_carrier candidate;
    char expected_logical[64];
    size_t hardware_length;
    const char *actual_hardware_id;

    if (observation == NULL || carrier == NULL ||
        !build_expected_logical_hardware_id(
            logical_identity, expected_logical, sizeof(expected_logical)) ||
        expected_bus_id > UINT32_C(0xff) ||
        expected_slot_id > UINT32_C(0x1f) || expected_function_id > 7u ||
        observation->matching_source_count != 1u ||
        observation->virtio_display_count != 1u ||
        !ascii_equals(expected_source_instance_id, observation->instance_id)) {
        return 0;
    }
    hardware_length = source_hardware_id_length(expected_source_instance_id);
    actual_hardware_id = multisz_find_physical_hardware_id(
        observation->hardware_ids, observation->hardware_ids_bytes,
        expected_logical);
    if (!source_is_virtio_gpu(expected_source_instance_id, hardware_length) ||
        actual_hardware_id == NULL ||
        !ascii_equals(observation->service, "VioGpuDod") ||
        !driver_key_is_display_class(observation->driver_key) ||
        observation->bus_id != expected_bus_id ||
        observation->slot_id != expected_slot_id ||
        observation->function_id != expected_function_id) {
        return 0;
    }

    memset(&candidate, 0, sizeof(candidate));
    if (!copy_printable_ascii(candidate.instance_id,
                              sizeof(candidate.instance_id),
                              observation->instance_id) ||
        !copy_printable_ascii(candidate.hardware_id,
                              sizeof(candidate.hardware_id),
                              actual_hardware_id) ||
        !copy_printable_ascii(candidate.driver_key,
                              sizeof(candidate.driver_key),
                              observation->driver_key)) {
        return 0;
    }
    candidate.pci_vendor_id = VIRTIO_GPU_VENDOR_ID;
    candidate.pci_device_id = VIRTIO_GPU_DEVICE_ID;
    candidate.bus_id = observation->bus_id;
    candidate.slot_id = observation->slot_id;
    candidate.function_id = observation->function_id;
    *carrier = candidate;
    return 1;
}

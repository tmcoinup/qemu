#include <stddef.h>
#include <string.h>

#include "nvapi_gpu_specs.h"

static int hex_nibble(char value)
{
    if (value >= '0' && value <= '9') {
        return value - '0';
    }
    if (value >= 'A' && value <= 'F') {
        return value - 'A' + 10;
    }
    return -1;
}

static int parse_hex_byte(const char *text, NvU32 *value)
{
    int high = hex_nibble(text[0]);
    int low = hex_nibble(text[1]);

    if (high < 0 || low < 0) {
        return 0;
    }
    *value = (NvU32)((high << 4) | low);
    return 1;
}

int nvapi_parse_vbios(const char *source, char output[NVAPI_SHORT_STRING_MAX],
                      NvU32 *revision, NvU32 *oem_revision)
{
    static const char prefix[] = "Version ";
    NvU32 parts[5];
    size_t index;
    const char *version;

    if (source == NULL || output == NULL || revision == NULL ||
        oem_revision == NULL ||
        strlen(source) != (sizeof(prefix) - 1u) + 14u ||
        strncmp(source, prefix, sizeof(prefix) - 1u) != 0) {
        return 0;
    }
    version = source + sizeof(prefix) - 1u;
    for (index = 0; index < 5u; index++) {
        if (!parse_hex_byte(version + index * 3u, &parts[index]) ||
            (index < 4u && version[index * 3u + 2u] != '.')) {
            return 0;
        }
    }
    if (version[14] != '\0') {
        return 0;
    }
    memcpy(output, version, 15u);
    *revision = (parts[0] << 24) | (parts[1] << 16) |
                (parts[2] << 8) | parts[3];
    *oem_revision = parts[4];
    return 1;
}

NvAPI_Status nvapi_fill_clock_frequencies(
    struct nvapi_clock_frequencies *frequencies, NvU32 base_clock_khz,
    NvU32 boost_clock_khz, NvU32 memory_clock_khz)
{
    NvU32 version;
    NvU32 structure_revision;
    NvU32 clock_type;
    NvU32 graphics_clock;

    if (frequencies == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }
    version = frequencies->version;
    structure_revision = version >> 16;
    if ((version & UINT32_C(0xffff)) != sizeof(*frequencies) ||
        structure_revision < 1u || structure_revision > 3u) {
        return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
    }
    /* V1 的第二 DWORD 全部保留；V2/V3 只有低 4 位 ClockType 可由调用方设置。 */
    if ((structure_revision == 1u &&
         frequencies->clock_type_and_reserved != 0u) ||
        (structure_revision > 1u &&
         (frequencies->clock_type_and_reserved & ~UINT32_C(0xf)) != 0u)) {
        return NVAPI_INVALID_ARGUMENT;
    }
    clock_type = structure_revision == 1u ? NVAPI_CLOCK_TYPE_CURRENT :
        frequencies->clock_type_and_reserved & UINT32_C(0xf);
    if (clock_type > NVAPI_CLOCK_TYPE_BOOST) {
        return NVAPI_INVALID_ARGUMENT;
    }
    graphics_clock = clock_type == NVAPI_CLOCK_TYPE_BOOST ?
        boost_clock_khz : base_clock_khz;

    memset(frequencies, 0, sizeof(*frequencies));
    frequencies->version = version;
    if (structure_revision > 1u) {
        frequencies->clock_type_and_reserved = clock_type;
    }
    frequencies->domain[NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS].presence = 1u;
    frequencies->domain[NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS].frequency_khz =
        graphics_clock;
    frequencies->domain[NVAPI_GPU_PUBLIC_CLOCK_MEMORY].presence = 1u;
    frequencies->domain[NVAPI_GPU_PUBLIC_CLOCK_MEMORY].frequency_khz =
        memory_clock_khz;
    frequencies->domain[NVAPI_GPU_PUBLIC_CLOCK_PROCESSOR].presence = 1u;
    frequencies->domain[NVAPI_GPU_PUBLIC_CLOCK_PROCESSOR].frequency_khz =
        graphics_clock;
    return NVAPI_OK;
}

/*
 * 从统一 64 位注册表视图读取版本化 GPU 身份。
 *
 * x86 的 GPU-Z 会受到 WOW64 注册表重定向；显式 KEY_WOW64_64KEY 可确保
 * atiadlxy.dll 与 atiadlxx.dll 观察同一个提交。读取顺序严格为
 * pointer -> snapshot -> pointer/schema，任何撕裂或未知 profile 都拒绝发布。
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stddef.h>

#include "adl_identity.h"
#include "adl_identity_cache.h"
#include "adl_identity_contract.h"

#define STEALTH_GPU_REGISTRY_PATH "SOFTWARE\\StealthGPU"
#define STEALTH_GPU_IDENTITIES_PREFIX "Identities\\"
#define STEALTH_GPU_CURRENT_POINTER "CurrentIdentity"

static struct adl_identity_cache g_identity_cache =
    ADL_IDENTITY_CACHE_INITIALIZER;

static int read_registry_string(HKEY key, const char *value_name,
                                char *output, DWORD output_size)
{
    DWORD type = 0u;
    DWORD size = output_size;
    LONG result;

    if (output == NULL || output_size < 2u) {
        return 0;
    }
    ZeroMemory(output, output_size);
    result = RegQueryValueExA(key, value_name, NULL, &type,
                              (BYTE *)output, &size);
    if (result != ERROR_SUCCESS || type != REG_SZ || size < 2u ||
        size > output_size || output[0] == '\0' ||
        output[size - 1u] != '\0' ||
        (DWORD)lstrlenA(output) != size - 1u) {
        ZeroMemory(output, output_size);
        return 0;
    }
    return 1;
}

static int read_registry_dword(HKEY key, const char *value_name,
                               DWORD *output)
{
    DWORD type = 0u;
    DWORD size = (DWORD)sizeof(*output);
    DWORD value = 0u;
    LONG result;

    if (output == NULL) {
        return 0;
    }
    result = RegQueryValueExA(key, value_name, NULL, &type,
                              (BYTE *)&value, &size);
    if (result != ERROR_SUCCESS || type != REG_DWORD ||
        size != (DWORD)sizeof(value)) {
        return 0;
    }
    *output = value;
    return 1;
}

static int read_current_identity_pointer(
    HKEY root, char pointer[STEALTH_GPU_IDENTITY_TOKEN_LENGTH + 1u])
{
    return read_registry_string(root, STEALTH_GPU_CURRENT_POINTER, pointer,
                                STEALTH_GPU_IDENTITY_TOKEN_LENGTH + 1u) &&
           adl_validate_identity_token(pointer);
}

static void build_identity_subkey_path(
    const char token[STEALTH_GPU_IDENTITY_TOKEN_LENGTH + 1u],
    char path[sizeof(STEALTH_GPU_IDENTITIES_PREFIX) +
              STEALTH_GPU_IDENTITY_TOKEN_LENGTH])
{
    const size_t prefix_length = sizeof(STEALTH_GPU_IDENTITIES_PREFIX) - 1u;

    CopyMemory(path, STEALTH_GPU_IDENTITIES_PREFIX, prefix_length);
    CopyMemory(path + prefix_length, token,
               STEALTH_GPU_IDENTITY_TOKEN_LENGTH + 1u);
}

static enum adl_identity_state load_and_validate_identity(
    HKEY key, const char expected_token[STEALTH_GPU_IDENTITY_TOKEN_LENGTH + 1u],
    struct adl_gpu_identity *identity, DWORD *initial_schema)
{
    struct adl_identity_contract_input input;
    DWORD schema = 0u;
    DWORD pci_vendor = 0u;
    DWORD pci_device = 0u;
    DWORD subsystem_vendor = 0u;
    DWORD subsystem_device = 0u;
    DWORD revision = 0u;
    DWORD ram_mb = 0u;
    DWORD bus_width = 0u;
    DWORD base_clock = 0u;
    DWORD boost_clock = 0u;
    DWORD memory_clock = 0u;
    DWORD sli_supported = 0u;
    DWORD bus_id = 0u;
    DWORD slot_id = 0u;
    DWORD function_id = 0u;
    char identity_id[STEALTH_GPU_IDENTITY_TOKEN_LENGTH + 1u];
    char name[ADL_IDENTITY_NAME_CAPACITY];
    char vendor[ADL_IDENTITY_VENDOR_CAPACITY];
    char bios[ADL_IDENTITY_BIOS_CAPACITY];
    char memory_type[32];
    char source_instance[256];
    char identity_mode[32];
    struct stealth_gpu_carrier carrier;
    enum adl_identity_state state;

    ZeroMemory(&input, sizeof(input));
    ZeroMemory(memory_type, sizeof(memory_type));
    if (!read_registry_dword(key, "IdentitySchemaVersion", &schema) ||
        !read_registry_string(key, "IdentityId", identity_id,
                              (DWORD)sizeof(identity_id)) ||
        !read_registry_string(key, "SpoofName", name, (DWORD)sizeof(name)) ||
        !read_registry_string(key, "SpoofVendor", vendor,
                              (DWORD)sizeof(vendor)) ||
        !read_registry_string(key, "SpoofBios", bios,
                              (DWORD)sizeof(bios)) ||
        !read_registry_dword(key, "SpoofPciVendorId", &pci_vendor) ||
        !read_registry_dword(key, "SpoofPciDeviceId", &pci_device) ||
        !read_registry_dword(key, "SpoofSubsystemVendorId",
                             &subsystem_vendor) ||
        !read_registry_dword(key, "SpoofSubsystemDeviceId",
                             &subsystem_device) ||
        !read_registry_dword(key, "SpoofRevisionId", &revision) ||
        !read_registry_dword(key, "SpoofRamMb", &ram_mb) ||
        !read_registry_string(key, "SourceInstanceId", source_instance,
                              (DWORD)sizeof(source_instance)) ||
        !read_registry_string(key, "IdentityMode", identity_mode,
                              (DWORD)sizeof(identity_mode)) ||
        !read_registry_dword(key, "SpoofPciBusId", &bus_id) ||
        !read_registry_dword(key, "SpoofPciSlotId", &slot_id) ||
        !read_registry_dword(key, "SpoofPciFunctionId", &function_id)) {
        return ADL_IDENTITY_INVALID;
    }

    if (schema == STEALTH_GPU_SCHEMA_VERSION) {
        if (!read_registry_string(key, "SpoofMemoryType", memory_type,
                                  (DWORD)sizeof(memory_type)) ||
            !read_registry_dword(key, "SpoofMemoryBusWidthBits",
                                 &bus_width) ||
            !read_registry_dword(key, "SpoofBaseClockKHz", &base_clock) ||
            !read_registry_dword(key, "SpoofBoostClockKHz", &boost_clock) ||
            !read_registry_dword(key, "SpoofMemoryClockKHz", &memory_clock) ||
            !read_registry_dword(key, "SpoofSliSupported", &sli_supported)) {
            return ADL_IDENTITY_INVALID;
        }
    } else if (schema != STEALTH_GPU_LEGACY_SCHEMA_VERSION) {
        return ADL_IDENTITY_INVALID;
    }

    input.expected_token = expected_token;
    input.identity_id = identity_id;
    input.name = name;
    input.vendor = vendor;
    input.bios = bios;
    input.memory_type = memory_type;
    input.source_instance_id = source_instance;
    input.identity_mode = identity_mode;
    input.schema = (uint32_t)schema;
    input.pci_vendor_id = (uint32_t)pci_vendor;
    input.pci_device_id = (uint32_t)pci_device;
    input.subsystem_vendor_id = (uint32_t)subsystem_vendor;
    input.subsystem_device_id = (uint32_t)subsystem_device;
    input.revision_id = (uint32_t)revision;
    input.ram_mb = (uint32_t)ram_mb;
    input.memory_bus_width_bits = (uint32_t)bus_width;
    input.base_clock_khz = (uint32_t)base_clock;
    input.boost_clock_khz = (uint32_t)boost_clock;
    input.memory_clock_khz = (uint32_t)memory_clock;
    input.sli_supported = (uint32_t)sli_supported;
    input.bus_id = (uint32_t)bus_id;
    input.slot_id = (uint32_t)slot_id;
    input.function_id = (uint32_t)function_id;
    state = adl_build_validated_identity(&input, identity);
    if (state == ADL_IDENTITY_INVALID ||
        !stealth_validate_virtio_gpu_carrier_windows(
            source_instance, (uint32_t)bus_id, (uint32_t)slot_id,
            (uint32_t)function_id, &carrier)) {
        ZeroMemory(identity, sizeof(*identity));
        return ADL_IDENTITY_INVALID;
    }
    if (state == ADL_IDENTITY_PRESENT) {
        /* ADL 的 Windows 元数据只传播已被 CM 证明的承载设备事实。 */
        identity->carrier = carrier;
        identity->bus_id = carrier.bus_id;
        identity->slot_id = carrier.slot_id;
        identity->function_id = carrier.function_id;
    }
    *initial_schema = schema;
    return state;
}

static enum adl_identity_state try_load_current_identity(
    struct adl_gpu_identity *candidate)
{
    HKEY root = NULL;
    HKEY version_key = NULL;
    char initial_pointer[STEALTH_GPU_IDENTITY_TOKEN_LENGTH + 1u];
    char final_pointer[STEALTH_GPU_IDENTITY_TOKEN_LENGTH + 1u];
    char version_path[sizeof(STEALTH_GPU_IDENTITIES_PREFIX) +
                      STEALTH_GPU_IDENTITY_TOKEN_LENGTH];
    DWORD initial_schema = 0u;
    DWORD final_schema = 0u;
    LONG result;
    enum adl_identity_state state = ADL_IDENTITY_INVALID;

    result = RegOpenKeyExA(HKEY_LOCAL_MACHINE, STEALTH_GPU_REGISTRY_PATH, 0u,
                           KEY_QUERY_VALUE | KEY_ENUMERATE_SUB_KEYS |
                               KEY_WOW64_64KEY,
                           &root);
    if (result != ERROR_SUCCESS ||
        !read_current_identity_pointer(root, initial_pointer)) {
        goto cleanup;
    }
    build_identity_subkey_path(initial_pointer, version_path);
    result = RegOpenKeyExA(root, version_path, 0u,
                           KEY_QUERY_VALUE | KEY_WOW64_64KEY, &version_key);
    if (result != ERROR_SUCCESS) {
        goto cleanup;
    }

    state = load_and_validate_identity(version_key, initial_pointer, candidate,
                                       &initial_schema);
    if (state == ADL_IDENTITY_INVALID ||
        !read_current_identity_pointer(root, final_pointer) ||
        !read_registry_dword(version_key, "IdentitySchemaVersion",
                             &final_schema) ||
        lstrcmpA(initial_pointer, final_pointer) != 0 ||
        initial_schema != final_schema) {
        ZeroMemory(candidate, sizeof(*candidate));
        state = ADL_IDENTITY_INVALID;
    }

cleanup:
    if (version_key != NULL) {
        RegCloseKey(version_key);
    }
    if (root != NULL) {
        RegCloseKey(root);
    }
    return state;
}

static enum adl_identity_state load_identity_for_cache(
    void *context, struct adl_gpu_identity *candidate)
{
    (void)context;

    return try_load_current_identity(candidate);
}

enum adl_identity_state adl_identity_initialize(void)
{
    /* 初次事务撕裂不缓存，调用方可在提交完成后重试。 */
    return adl_identity_cache_initialize(&g_identity_cache,
                                         load_identity_for_cache, NULL);
}

enum adl_identity_state adl_identity_refresh(void)
{
    /* Refresh 总是重新走完整的 registry pointer/snapshot 一致性校验。 */
    return adl_identity_cache_refresh(&g_identity_cache,
                                      load_identity_for_cache, NULL);
}

enum adl_identity_state adl_identity_copy(struct adl_gpu_identity *identity)
{
    return adl_identity_cache_copy(&g_identity_cache, identity);
}

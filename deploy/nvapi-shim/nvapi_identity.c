/*
 * 从统一的 64 位注册表视图载入 GPU 身份。
 *
 * Windows 会把 32 位进程对 HKLM\SOFTWARE 的普通访问重定向到 WOW6432Node。
 * respawn/apply 脚本由 64 位 PowerShell 写入真实 SOFTWARE 视图，因此这里无论
 * 编译成 x86 还是 x64 都显式使用 KEY_WOW64_64KEY，保证两个 DLL 看到同一配置。
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stddef.h>
#include <stdint.h>

#include "carrier_validation.h"
#include "nvapi_identity.h"
#include "nvapi_identity_contract.h"

#define STEALTH_GPU_REGISTRY_PATH "SOFTWARE\\StealthGPU"
#define STEALTH_GPU_IDENTITIES_PREFIX "Identities\\"
#define STEALTH_GPU_CURRENT_POINTER "CurrentIdentity"

static INIT_ONCE g_identity_once = INIT_ONCE_STATIC_INIT;
static struct nvapi_gpu_identity g_identity;
static LONG g_identity_valid;

/*
 * 只接受 REG_SZ，拒绝 REG_EXPAND_SZ 和截断字符串。先清零整个目标缓冲区，既能
 * 为正常字符串补终止符，也能检测恶意或损坏的“恰好填满且无 NUL”注册表值。
 */
static int read_registry_string(HKEY key, const char *value_name,
                                char *output, DWORD output_size)
{
    DWORD type = 0;
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

/* root 只保存一个原子 pointer；旧版 root-only profile 有意 fail-closed。 */
static int read_current_identity_pointer(
    HKEY root, char pointer[STEALTH_GPU_IDENTITY_TOKEN_LENGTH + 1u])
{
    return read_registry_string(root, STEALTH_GPU_CURRENT_POINTER, pointer,
                                STEALTH_GPU_IDENTITY_TOKEN_LENGTH + 1u) &&
           nvapi_validate_identity_token(pointer);
}

/* token 已通过白名单；按固定前缀逐字节构造，禁止任何通用路径格式化。 */
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

/* DWORD 配置必须类型和长度都精确匹配，避免把字符串十六进制静默当成零。 */
static int read_registry_dword(HKEY key, const char *value_name,
                               DWORD *output)
{
    DWORD type = 0;
    DWORD size = (DWORD)sizeof(*output);
    DWORD value = 0;
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

/*
 * NVIDIA NVAPI 不能替 AMD profile 说话。两版都先完整读取 16 个公共字段；
 * schema-2 再严格读取六个扩展字段，schema-1 则只为历史中不存在的六字段使用
 * 编译期 1050 Ti 默认。公共字段只要缺一个或类型错误，仍整体判无效。
 */
static int load_and_validate_identity(
    HKEY key, const char expected_token[STEALTH_GPU_IDENTITY_TOKEN_LENGTH + 1u],
    struct nvapi_gpu_identity *identity, DWORD *initial_schema)
{
    struct nvapi_identity_contract_input input;
    DWORD schema;
    DWORD pci_vendor;
    DWORD pci_device;
    DWORD subsystem_vendor;
    DWORD subsystem_device;
    DWORD revision;
    DWORD ram_mb;
    DWORD ram_bus_width_bits;
    DWORD base_clock_khz;
    DWORD boost_clock_khz;
    DWORD memory_clock_khz;
    DWORD sli_supported;
    DWORD bus_id;
    DWORD slot_id;
    DWORD function_id;
    struct nvapi_legacy_extension_defaults legacy_defaults;
    char identity_id[STEALTH_GPU_IDENTITY_TOKEN_LENGTH + 1u];
    char name[NVAPI_SHORT_STRING_MAX];
    char vendor[32];
    char bios[64];
    char memory_type[32];
    char source_instance[256];
    char identity_mode[32];
    struct stealth_gpu_carrier carrier;

    ZeroMemory(&input, sizeof(input));
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
        return 0;
    }

    if (schema == STEALTH_GPU_LEGACY_SCHEMA_VERSION) {
        if (!nvapi_get_legacy_extension_defaults((NvU32)pci_vendor,
                                                 (NvU32)pci_device,
                                                 &legacy_defaults)) {
            return 0;
        }
        lstrcpyA(memory_type, "GDDR5");
        ram_bus_width_bits = (DWORD)legacy_defaults.memory_bus_width_bits;
        base_clock_khz = (DWORD)legacy_defaults.base_clock_khz;
        boost_clock_khz = (DWORD)legacy_defaults.boost_clock_khz;
        memory_clock_khz = (DWORD)legacy_defaults.memory_clock_khz;
        sli_supported = 0u;
    } else if (schema == STEALTH_GPU_SCHEMA_VERSION) {
        if (!read_registry_string(key, "SpoofMemoryType", memory_type,
                                  (DWORD)sizeof(memory_type)) ||
            !read_registry_dword(key, "SpoofMemoryBusWidthBits",
                                 &ram_bus_width_bits) ||
            !read_registry_dword(key, "SpoofBaseClockKHz", &base_clock_khz) ||
            !read_registry_dword(key, "SpoofBoostClockKHz", &boost_clock_khz) ||
            !read_registry_dword(key, "SpoofMemoryClockKHz",
                                 &memory_clock_khz) ||
            !read_registry_dword(key, "SpoofSliSupported", &sli_supported)) {
            return 0;
        }
    } else {
        return 0;
    }

    input.expected_token = expected_token;
    input.identity_id = identity_id;
    input.name = name;
    input.vendor = vendor;
    input.bios = bios;
    input.memory_type = memory_type;
    input.source_instance_id = source_instance;
    input.identity_mode = identity_mode;
    input.schema = (NvU32)schema;
    input.pci_vendor_id = (NvU32)pci_vendor;
    input.pci_device_id = (NvU32)pci_device;
    input.subsystem_vendor_id = (NvU32)subsystem_vendor;
    input.subsystem_device_id = (NvU32)subsystem_device;
    input.revision_id = (NvU32)revision;
    input.ram_mb = (NvU32)ram_mb;
    input.memory_bus_width_bits = (NvU32)ram_bus_width_bits;
    input.base_clock_khz = (NvU32)base_clock_khz;
    input.boost_clock_khz = (NvU32)boost_clock_khz;
    input.memory_clock_khz = (NvU32)memory_clock_khz;
    input.sli_supported = (NvU32)sli_supported;
    input.bus_id = (NvU32)bus_id;
    input.slot_id = (NvU32)slot_id;
    input.function_id = (NvU32)function_id;
    if (!nvapi_build_validated_identity(&input, identity) ||
        !stealth_validate_virtio_gpu_carrier_windows(
            source_instance, (uint32_t)bus_id, (uint32_t)slot_id,
            (uint32_t)function_id, &carrier)) {
        return 0;
    }

    /*
     * bus/slot 已与 CM 的实际 devnode 比对；回写已验证值，避免后续 NVAPI
     * 查询意外使用 profile 中未绑定到当前 Windows 实例的 BDF。
     */
    identity->bus_id = (NvU32)carrier.bus_id;
    identity->slot_id = (NvU32)carrier.slot_id;

    *initial_schema = schema;
    return 1;
}

/*
 * 一次读取的线性化协议：root pointer -> 不可变版本子键 -> root pointer/schema
 * 复核。写者只发布全新 GUID 子键且永不原位更新，因此两次 pointer 相同并且
 * schema 未变化，就能证明 candidate 完整来自同一快照；任一异常均 fail-closed。
 */
static int try_load_current_identity(struct nvapi_gpu_identity *candidate)
{
    HKEY root = NULL;
    HKEY version_key = NULL;
    char initial_pointer[STEALTH_GPU_IDENTITY_TOKEN_LENGTH + 1u];
    char final_pointer[STEALTH_GPU_IDENTITY_TOKEN_LENGTH + 1u];
    char version_path[sizeof(STEALTH_GPU_IDENTITIES_PREFIX) +
                      STEALTH_GPU_IDENTITY_TOKEN_LENGTH];
    DWORD initial_schema = 0;
    DWORD final_schema = 0;
    LONG result;
    int valid = 0;

    result = RegOpenKeyExA(HKEY_LOCAL_MACHINE, STEALTH_GPU_REGISTRY_PATH, 0,
                           KEY_QUERY_VALUE | KEY_ENUMERATE_SUB_KEYS |
                               KEY_WOW64_64KEY,
                           &root);
    if (result != ERROR_SUCCESS ||
        !read_current_identity_pointer(root, initial_pointer)) {
        goto cleanup;
    }

    build_identity_subkey_path(initial_pointer, version_path);
    result = RegOpenKeyExA(root, version_path, 0,
                           KEY_QUERY_VALUE | KEY_WOW64_64KEY, &version_key);
    if (result != ERROR_SUCCESS ||
        !load_and_validate_identity(version_key, initial_pointer, candidate,
                                    &initial_schema) ||
        !read_current_identity_pointer(root, final_pointer) ||
        !read_registry_dword(version_key, "IdentitySchemaVersion",
                             &final_schema) ||
        lstrcmpA(initial_pointer, final_pointer) != 0 ||
        initial_schema != final_schema) {
        ZeroMemory(candidate, sizeof(*candidate));
        goto cleanup;
    }
    valid = 1;

cleanup:
    if (version_key != NULL) {
        RegCloseKey(version_key);
    }
    if (root != NULL) {
        RegCloseKey(root);
    }
    return valid;
}

/* InitOnce 回调内只做注册表 I/O；它由 NvAPI_Initialize 触发，不在 loader lock 中。 */
static BOOL CALLBACK initialize_identity_once(PINIT_ONCE once,
                                              PVOID parameter,
                                              PVOID *context)
{
    struct nvapi_gpu_identity candidate;
    (void)once;
    (void)parameter;
    (void)context;

    if (!try_load_current_identity(&candidate)) {
        /*
         * FALSE 让 InitOnce 保持未完成；pointer 正在切换等瞬态失败可由后续
         * NvAPI_Initialize 重试，不会把一次竞态永久冻结成“无 NVIDIA 设备”。
         */
        return FALSE;
    }

    g_identity = candidate;
    InterlockedExchange(&g_identity_valid, 1);
    return TRUE;
}

int nvapi_identity_initialize(void)
{
    if (!InitOnceExecuteOnce(&g_identity_once, initialize_identity_once,
                             NULL, NULL)) {
        return 0;
    }
    return InterlockedCompareExchange(&g_identity_valid, 0, 0) != 0;
}

const struct nvapi_gpu_identity *nvapi_identity_get(void)
{
    if (InterlockedCompareExchange(&g_identity_valid, 0, 0) == 0) {
        return NULL;
    }
    return &g_identity;
}

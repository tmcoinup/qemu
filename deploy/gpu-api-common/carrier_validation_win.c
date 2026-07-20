#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cfgmgr32.h>
#include <initguid.h>
#include <devguid.h>
#include <setupapi.h>

#include <stdio.h>
#include <string.h>

#include "carrier_validation.h"

#define PROPERTY_BUFFER_CAPACITY 2048u

static int ascii_equals_case_insensitive(const char *left, const char *right)
{
    return left != NULL && right != NULL && lstrcmpiA(left, right) == 0;
}

static int is_virtio_gpu_instance_id(const char *instance_id)
{
    static const char prefix[] = "PCI\\VEN_1AF4&DEV_1050&";

    return instance_id != NULL &&
        _strnicmp(instance_id, prefix, sizeof(prefix) - 1u) == 0;
}

static int read_device_instance_id(HDEVINFO device_set,
                                   PSP_DEVINFO_DATA device_data,
                                   char output[STEALTH_GPU_CARRIER_INSTANCE_CAPACITY])
{
    DWORD required = 0u;

    ZeroMemory(output, STEALTH_GPU_CARRIER_INSTANCE_CAPACITY);
    if (!SetupDiGetDeviceInstanceIdA(device_set, device_data, output,
                                     STEALTH_GPU_CARRIER_INSTANCE_CAPACITY,
                                     &required) || required < 2u ||
        required > STEALTH_GPU_CARRIER_INSTANCE_CAPACITY ||
        output[required - 1u] != '\0' || output[0] == '\0') {
        ZeroMemory(output, STEALTH_GPU_CARRIER_INSTANCE_CAPACITY);
        return 0;
    }
    return 1;
}

static int read_registry_property(HDEVINFO device_set,
                                  PSP_DEVINFO_DATA device_data,
                                  DWORD property, DWORD expected_type,
                                  BYTE *output, DWORD capacity,
                                  DWORD *actual_size)
{
    DWORD type = 0u;
    DWORD size = 0u;

    if (output == NULL || actual_size == NULL || capacity == 0u) {
        return 0;
    }
    ZeroMemory(output, capacity);
    if (!SetupDiGetDeviceRegistryPropertyA(device_set, device_data, property,
                                            &type, output, capacity, &size) ||
        type != expected_type || size == 0u || size > capacity) {
        ZeroMemory(output, capacity);
        return 0;
    }
    *actual_size = size;
    return 1;
}

static int read_registry_string_property(HDEVINFO device_set,
                                         PSP_DEVINFO_DATA device_data,
                                         DWORD property, char *output,
                                         DWORD capacity)
{
    DWORD size = 0u;

    if (!read_registry_property(device_set, device_data, property, REG_SZ,
                                (BYTE *)output, capacity, &size) ||
        size < 2u || output[size - 1u] != '\0' || output[0] == '\0' ||
        (DWORD)lstrlenA(output) != size - 1u) {
        ZeroMemory(output, capacity);
        return 0;
    }
    return 1;
}

static int read_registry_hardware_ids(HDEVINFO device_set,
                                      PSP_DEVINFO_DATA device_data,
                                      char *output, DWORD capacity,
                                      DWORD *actual_size)
{
    if (!read_registry_property(device_set, device_data, SPDRP_HARDWAREID,
                                REG_MULTI_SZ, (BYTE *)output, capacity,
                                actual_size) || *actual_size < 2u ||
        output[*actual_size - 1u] != '\0' ||
        output[*actual_size - 2u] != '\0') {
        ZeroMemory(output, capacity);
        return 0;
    }
    return 1;
}

static int read_cm_dword(DEVINST device_instance, ULONG property,
                         uint32_t *output)
{
    ULONG type = 0u;
    ULONG size = (ULONG)sizeof(DWORD);
    DWORD value = 0u;

    if (output == NULL ||
        CM_Get_DevNode_Registry_PropertyA(device_instance, property, &type,
                                          &value, &size, 0u) != CR_SUCCESS ||
        type != REG_DWORD || size != (ULONG)sizeof(value)) {
        return 0;
    }
    *output = (uint32_t)value;
    return 1;
}

/* 先确认 Class 子键真的存在，再把同一实际 SPDRP_DRIVER 值编码成 ADL 原生路径。 */
static int build_driver_registry_path(struct stealth_gpu_carrier *carrier)
{
    char registry_subkey[STEALTH_GPU_CARRIER_DRIVER_PATH_CAPACITY];
    int written;
    HKEY key = NULL;
    LONG result;

    written = snprintf(registry_subkey, sizeof(registry_subkey),
                       "SYSTEM\\CurrentControlSet\\Control\\Class\\%s",
                       carrier->driver_key);
    if (written < 0 || (size_t)written >= sizeof(registry_subkey)) {
        return 0;
    }
    result = RegOpenKeyExA(HKEY_LOCAL_MACHINE, registry_subkey, 0u,
                           KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key);
    if (result != ERROR_SUCCESS) {
        return 0;
    }
    RegCloseKey(key);
    written = snprintf(carrier->driver_registry_path,
                       sizeof(carrier->driver_registry_path),
                       "\\Registry\\Machine\\%s", registry_subkey);
    return written >= 0 &&
        (size_t)written < sizeof(carrier->driver_registry_path);
}

int stealth_validate_virtio_gpu_carrier_windows(
    const char *expected_source_instance_id, uint32_t expected_bus_id,
    uint32_t expected_slot_id, uint32_t expected_function_id,
    struct stealth_gpu_carrier *carrier)
{
    HDEVINFO device_set;
    SP_DEVINFO_DATA device_data;
    struct stealth_gpu_carrier_observation observation;
    struct stealth_gpu_carrier candidate;
    char instance_id[STEALTH_GPU_CARRIER_INSTANCE_CAPACITY];
    char cm_instance_id[STEALTH_GPU_CARRIER_INSTANCE_CAPACITY];
    char service[64];
    char driver_key[STEALTH_GPU_CARRIER_DRIVER_KEY_CAPACITY];
    char hardware_ids[PROPERTY_BUFFER_CAPACITY];
    DWORD hardware_ids_size = 0u;
    DWORD index = 0u;
    uint32_t source_count = 0u;
    uint32_t virtio_count = 0u;
    int have_observation = 0;
    int valid = 0;

    if (carrier == NULL) {
        return 0;
    }
    ZeroMemory(&observation, sizeof(observation));
    ZeroMemory(&candidate, sizeof(candidate));
    device_set = SetupDiGetClassDevsA(&GUID_DEVCLASS_DISPLAY, NULL, NULL,
                                      DIGCF_PRESENT);
    if (device_set == INVALID_HANDLE_VALUE) {
        return 0;
    }

    for (;;) {
        ZeroMemory(&device_data, sizeof(device_data));
        device_data.cbSize = sizeof(device_data);
        if (!SetupDiEnumDeviceInfo(device_set, index, &device_data)) {
            if (GetLastError() == ERROR_NO_MORE_ITEMS) {
                break;
            }
            goto cleanup;
        }
        ++index;
        if (!read_device_instance_id(device_set, &device_data, instance_id)) {
            goto cleanup;
        }
        if (is_virtio_gpu_instance_id(instance_id)) {
            ++virtio_count;
        }
        if (!ascii_equals_case_insensitive(instance_id,
                                           expected_source_instance_id)) {
            continue;
        }
        ++source_count;
        ZeroMemory(cm_instance_id, sizeof(cm_instance_id));
        if (source_count != 1u ||
            CM_Get_Device_IDA(device_data.DevInst, cm_instance_id,
                              STEALTH_GPU_CARRIER_INSTANCE_CAPACITY, 0u) !=
                CR_SUCCESS ||
            !ascii_equals_case_insensitive(cm_instance_id, instance_id) ||
            !read_registry_hardware_ids(device_set, &device_data,
                                        hardware_ids, sizeof(hardware_ids),
                                        &hardware_ids_size) ||
            !read_registry_string_property(device_set, &device_data,
                                           SPDRP_SERVICE, service,
                                           sizeof(service)) ||
            !read_registry_string_property(device_set, &device_data,
                                           SPDRP_DRIVER, driver_key,
                                           sizeof(driver_key)) ||
            !read_cm_dword(device_data.DevInst, CM_DRP_BUSNUMBER,
                           &observation.bus_id) ||
            !read_cm_dword(device_data.DevInst, CM_DRP_ADDRESS,
                           &observation.slot_id)) {
            goto cleanup;
        }
        observation.function_id = observation.slot_id & UINT32_C(0xffff);
        observation.slot_id = (observation.slot_id >> 16) & UINT32_C(0xffff);
        observation.instance_id = instance_id;
        observation.hardware_ids = hardware_ids;
        observation.hardware_ids_bytes = hardware_ids_size;
        observation.service = service;
        observation.driver_key = driver_key;
        have_observation = 1;
    }

    if (!have_observation) {
        goto cleanup;
    }
    observation.matching_source_count = source_count;
    observation.virtio_display_count = virtio_count;
    if (!stealth_validate_virtio_gpu_carrier_observation(
            expected_source_instance_id, expected_bus_id, expected_slot_id,
            expected_function_id, &observation, &candidate) ||
        !build_driver_registry_path(&candidate)) {
        goto cleanup;
    }
    *carrier = candidate;
    valid = 1;

cleanup:
    SetupDiDestroyDeviceInfoList(device_set);
    return valid;
}

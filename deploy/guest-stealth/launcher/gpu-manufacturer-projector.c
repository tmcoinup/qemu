#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <cfgmgr32.h>
#include <initguid.h>
#include <devguid.h>
#include <devpropdef.h>
#include <setupapi.h>
#include <stdio.h>
#include <wchar.h>

/*
 * Minimal projector for the Device Manager General-tab manufacturer.
 *
 * The signed VioGpuDod package owns Enum\Mfg, so this program only tries the
 * modern DEVPKEY_Device_Manufacturer API.  It never edits INF/Class/Enum
 * installation fields.  A nonzero exit means Windows rejected the cosmetic
 * projection and callers must leave the signed installation unchanged.
 */

static const DEVPROPKEY k_device_manufacturer = {
    {0xa45c254e, 0xdf1c, 0x4efd,
     {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}},
    13
};

static BOOL is_target_instance(const wchar_t *instance_id)
{
    static const wchar_t prefix[] = L"PCI\\VEN_1AF4&DEV_1050";
    return _wcsnicmp(instance_id, prefix, ARRAYSIZE(prefix) - 1) == 0;
}

static CONFIGRET read_manufacturer(
    DEVINST devinst,
    wchar_t *buffer,
    ULONG buffer_bytes)
{
    DEVPROPTYPE type = 0;
    CONFIGRET status = CM_Get_DevNode_PropertyW(
        devinst,
        &k_device_manufacturer,
        &type,
        (PBYTE)buffer,
        &buffer_bytes,
        0
    );
    if (status != CR_SUCCESS) {
        return status;
    }
    if (type != DEVPROP_TYPE_STRING || buffer_bytes < sizeof(wchar_t)) {
        return CR_INVALID_DATA;
    }
    buffer[(buffer_bytes / sizeof(wchar_t)) - 1] = L'\0';
    return CR_SUCCESS;
}

static int find_target(DEVINST *target, wchar_t *target_id, DWORD capacity)
{
    HDEVINFO devices = SetupDiGetClassDevsW(
        &GUID_DEVCLASS_DISPLAY,
        NULL,
        NULL,
        DIGCF_PRESENT
    );
    DWORD index;
    unsigned int matches = 0;

    if (devices == INVALID_HANDLE_VALUE) {
        fwprintf(stderr, L"SetupDiGetClassDevsW failed: %lu\n", GetLastError());
        return 10;
    }

    for (index = 0;; ++index) {
        SP_DEVINFO_DATA info;
        wchar_t instance_id[MAX_DEVICE_ID_LEN];
        DWORD required = 0;

        ZeroMemory(&info, sizeof(info));
        info.cbSize = sizeof(info);
        if (!SetupDiEnumDeviceInfo(devices, index, &info)) {
            DWORD error = GetLastError();
            if (error != ERROR_NO_MORE_ITEMS) {
                fwprintf(stderr, L"SetupDiEnumDeviceInfo failed: %lu\n", error);
                SetupDiDestroyDeviceInfoList(devices);
                return 11;
            }
            break;
        }
        if (!SetupDiGetDeviceInstanceIdW(
                devices, &info, instance_id, capacity, &required)) {
            fwprintf(
                stderr,
                L"SetupDiGetDeviceInstanceIdW failed: %lu\n",
                GetLastError()
            );
            SetupDiDestroyDeviceInfoList(devices);
            return 12;
        }
        if (!is_target_instance(instance_id)) {
            continue;
        }
        if (wcslen(instance_id) + 1 > capacity) {
            SetupDiDestroyDeviceInfoList(devices);
            return 14;
        }
        wcscpy(target_id, instance_id);
        *target = info.DevInst;
        ++matches;
    }

    SetupDiDestroyDeviceInfoList(devices);
    if (matches != 1) {
        fwprintf(stderr, L"expected one present VioGpuDod display, got %u\n", matches);
        return 13;
    }
    return 0;
}

static BOOL valid_vendor(const wchar_t *vendor)
{
    return wcscmp(vendor, L"AMD") == 0 || wcscmp(vendor, L"NVIDIA") == 0;
}

int wmain(int argc, wchar_t **argv)
{
    DEVINST target = 0;
    wchar_t instance_id[MAX_DEVICE_ID_LEN];
    wchar_t current[256];
    const wchar_t *vendor;
    CONFIGRET status;
    int result;
    ULONG payload_bytes;

    if (argc != 2 || !valid_vendor(argv[1])) {
        fwprintf(stderr, L"usage: gpu-manufacturer-projector.exe AMD|NVIDIA\n");
        return 2;
    }
    vendor = argv[1];
    ZeroMemory(instance_id, sizeof(instance_id));
    result = find_target(&target, instance_id, ARRAYSIZE(instance_id));
    if (result != 0) {
        return result;
    }

    payload_bytes = ((ULONG)wcslen(vendor) + 1U) * sizeof(wchar_t);
    status = CM_Set_DevNode_PropertyW(
        target,
        &k_device_manufacturer,
        DEVPROP_TYPE_STRING,
        (const PBYTE)vendor,
        payload_bytes,
        0
    );
    if (status != CR_SUCCESS) {
        fwprintf(stderr, L"CM_Set_DevNode_PropertyW failed: 0x%08lx\n", status);
        return 20;
    }

    ZeroMemory(current, sizeof(current));
    status = read_manufacturer(target, current, sizeof(current));
    if (status != CR_SUCCESS) {
        fwprintf(stderr, L"manufacturer readback failed: 0x%08lx\n", status);
        return 21;
    }
    if (wcscmp(current, vendor) != 0) {
        fwprintf(stderr, L"manufacturer readback mismatch: %ls\n", current);
        return 22;
    }

    wprintf(L"instance=%ls\nmanufacturer=%ls\n", instance_id, current);
    return 0;
}

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
 * 只投影显示器的现代 FriendlyName 属性。
 *
 * EDID、HardwareID、Monitor Class、INF、monitor.sys 和色彩配置均由 Windows
 * 原有设备栈继续管理。本工具先按精确 InstanceId 找到唯一在线 Monitor devnode，
 * 再确认其 MONITOR\<EISA+产品码> HardwareID 与 InstanceId 一致，最后才调用
 * Config Manager 写 FriendlyName。任何前置或回读不一致都会失败且不碰其它设备。
 */

static const DEVPROPKEY k_device_friendly_name = {
    {0xa45c254e, 0xdf1c, 0x4efd,
     {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}},
    14
};

static BOOL valid_label(const wchar_t *label)
{
    size_t length;

    if (label == NULL) {
        return FALSE;
    }
    length = wcslen(label);
    if (length == 0 || length > 128) {
        return FALSE;
    }
    for (size_t index = 0; index < length; ++index) {
        if (label[index] < L' ' || label[index] == 0x7f) {
            return FALSE;
        }
    }
    return TRUE;
}

static BOOL expected_hardware_id(
    const wchar_t *instance_id,
    wchar_t *expected,
    size_t capacity)
{
    static const wchar_t prefix[] = L"DISPLAY\\";
    const wchar_t *separator;
    size_t code_length;

    if (_wcsnicmp(instance_id, prefix, ARRAYSIZE(prefix) - 1) != 0) {
        return FALSE;
    }
    separator = wcschr(instance_id + ARRAYSIZE(prefix) - 1, L'\\');
    if (separator == NULL) {
        return FALSE;
    }
    code_length = (size_t)(separator - (instance_id + ARRAYSIZE(prefix) - 1));
    if (code_length != 7 || capacity < 16) {
        return FALSE;
    }
    if (swprintf(
            expected,
            capacity,
            L"MONITOR\\%.*ls",
            (int)code_length,
            instance_id + ARRAYSIZE(prefix) - 1) < 0) {
        return FALSE;
    }
    return TRUE;
}

static BOOL hardware_id_matches(
    HDEVINFO devices,
    SP_DEVINFO_DATA *info,
    const wchar_t *expected)
{
    wchar_t values[1024];
    DWORD type = 0;
    DWORD required = 0;
    const wchar_t *cursor;

    ZeroMemory(values, sizeof(values));
    if (!SetupDiGetDeviceRegistryPropertyW(
            devices,
            info,
            SPDRP_HARDWAREID,
            &type,
            (PBYTE)values,
            sizeof(values),
            &required)) {
        fwprintf(
            stderr,
            L"读取 Monitor HardwareID 失败，错误=%lu\n",
            GetLastError());
        return FALSE;
    }
    if (type != REG_MULTI_SZ || required < 2 * sizeof(wchar_t) ||
        required > sizeof(values)) {
        fwprintf(stderr, L"Monitor HardwareID 类型或长度非法。\n");
        return FALSE;
    }
    values[ARRAYSIZE(values) - 1] = L'\0';
    for (cursor = values; *cursor != L'\0'; cursor += wcslen(cursor) + 1) {
        if (_wcsicmp(cursor, expected) == 0) {
            return TRUE;
        }
    }
    fwprintf(stderr, L"Monitor HardwareID 不包含预期值：%ls\n", expected);
    return FALSE;
}

static int find_target(
    const wchar_t *requested_id,
    DEVINST *target,
    wchar_t *hardware_id,
    size_t hardware_id_capacity)
{
    HDEVINFO devices;
    DWORD index;
    unsigned int matches = 0;

    if (!expected_hardware_id(
            requested_id, hardware_id, hardware_id_capacity)) {
        fwprintf(stderr, L"拒绝非 DISPLAY\\XXXNNNN\\... InstanceId。\n");
        return 10;
    }

    devices = SetupDiGetClassDevsW(
        &GUID_DEVCLASS_MONITOR,
        NULL,
        NULL,
        DIGCF_PRESENT);
    if (devices == INVALID_HANDLE_VALUE) {
        fwprintf(stderr, L"枚举在线 Monitor 失败，错误=%lu\n", GetLastError());
        return 11;
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
                fwprintf(stderr, L"枚举 Monitor devnode 失败，错误=%lu\n", error);
                SetupDiDestroyDeviceInfoList(devices);
                return 12;
            }
            break;
        }
        if (!SetupDiGetDeviceInstanceIdW(
                devices,
                &info,
                instance_id,
                ARRAYSIZE(instance_id),
                &required)) {
            fwprintf(stderr, L"读取 Monitor InstanceId 失败，错误=%lu\n",
                     GetLastError());
            SetupDiDestroyDeviceInfoList(devices);
            return 13;
        }
        if (_wcsicmp(instance_id, requested_id) != 0) {
            continue;
        }
        if (!hardware_id_matches(devices, &info, hardware_id)) {
            SetupDiDestroyDeviceInfoList(devices);
            return 14;
        }
        *target = info.DevInst;
        ++matches;
    }

    SetupDiDestroyDeviceInfoList(devices);
    if (matches != 1) {
        fwprintf(
            stderr,
            L"预期一个精确匹配的在线 Monitor，实际=%u\n",
            matches);
        return 15;
    }
    return 0;
}

static CONFIGRET read_friendly_name(
    DEVINST target,
    wchar_t *buffer,
    ULONG buffer_bytes)
{
    DEVPROPTYPE type = 0;
    CONFIGRET status = CM_Get_DevNode_PropertyW(
        target,
        &k_device_friendly_name,
        &type,
        (PBYTE)buffer,
        &buffer_bytes,
        0);

    if (status != CR_SUCCESS) {
        return status;
    }
    if (type != DEVPROP_TYPE_STRING || buffer_bytes < sizeof(wchar_t)) {
        return CR_INVALID_DATA;
    }
    buffer[(buffer_bytes / sizeof(wchar_t)) - 1] = L'\0';
    return CR_SUCCESS;
}

int wmain(int argc, wchar_t **argv)
{
    DEVINST target = 0;
    wchar_t hardware_id[64];
    wchar_t current[256];
    const wchar_t *label = NULL;
    BOOL clear_requested = FALSE;
    ULONG payload_bytes;
    CONFIGRET status;
    int result;

    if (argc == 3 && wcscmp(argv[2], L"--clear") == 0) {
        clear_requested = TRUE;
    } else if (argc == 4 && wcscmp(argv[2], L"--set") == 0 &&
               valid_label(argv[3])) {
        label = argv[3];
    } else {
        fwprintf(
            stderr,
            L"用法: monitor-friendly-name-projector.exe "
            L"<DISPLAY\\XXXNNNN\\实例> --set <显示名称>\n"
            L"  或: monitor-friendly-name-projector.exe "
            L"<DISPLAY\\XXXNNNN\\实例> --clear\n");
        return 2;
    }

    ZeroMemory(hardware_id, sizeof(hardware_id));
    result = find_target(
        argv[1], &target, hardware_id, ARRAYSIZE(hardware_id));
    if (result != 0) {
        return result;
    }

    if (clear_requested) {
        status = CM_Set_DevNode_PropertyW(
            target,
            &k_device_friendly_name,
            DEVPROP_TYPE_EMPTY,
            NULL,
            0,
            0);
        if (status != CR_SUCCESS && status != CR_NO_SUCH_VALUE) {
            fwprintf(
                stderr,
                L"清除 Monitor FriendlyName 失败，CONFIGRET=0x%08lx\n",
                status);
            return 20;
        }
        ZeroMemory(current, sizeof(current));
        status = read_friendly_name(target, current, sizeof(current));
        if (status != CR_NO_SUCH_VALUE) {
            fwprintf(
                stderr,
                L"Monitor FriendlyName 清除后仍可读，CONFIGRET=0x%08lx\n",
                status);
            return 21;
        }
        wprintf(
            L"instance=%ls\nhardware_id=%ls\nfriendly_name=<unset>\n",
            argv[1],
            hardware_id);
        return 0;
    }

    payload_bytes = ((ULONG)wcslen(label) + 1U) * sizeof(wchar_t);
    status = CM_Set_DevNode_PropertyW(
        target,
        &k_device_friendly_name,
        DEVPROP_TYPE_STRING,
        (const PBYTE)label,
        payload_bytes,
        0);
    if (status != CR_SUCCESS) {
        fwprintf(
            stderr,
            L"写入 Monitor FriendlyName 失败，CONFIGRET=0x%08lx\n",
            status);
        return 20;
    }
    ZeroMemory(current, sizeof(current));
    status = read_friendly_name(target, current, sizeof(current));
    if (status != CR_SUCCESS) {
        fwprintf(
            stderr,
            L"回读 Monitor FriendlyName 失败，CONFIGRET=0x%08lx\n",
            status);
        return 21;
    }
    if (wcscmp(current, label) != 0) {
        fwprintf(stderr, L"Monitor FriendlyName 回读不一致：%ls\n", current);
        return 22;
    }

    wprintf(
        L"instance=%ls\nhardware_id=%ls\nfriendly_name=%ls\n",
        argv[1],
        hardware_id,
        current);
    return 0;
}

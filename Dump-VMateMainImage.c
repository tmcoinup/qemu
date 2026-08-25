#define UNICODE
#define _UNICODE

#include <windows.h>
#include <psapi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void enable_debug_privilege(void)
{
    HANDLE token = NULL;
    TOKEN_PRIVILEGES privileges;
    LUID luid;

    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES |
                          TOKEN_QUERY, &token)) {
        return;
    }
    if (!LookupPrivilegeValueW(NULL, SE_DEBUG_NAME, &luid)) {
        CloseHandle(token);
        return;
    }
    ZeroMemory(&privileges, sizeof(privileges));
    privileges.PrivilegeCount = 1;
    privileges.Privileges[0].Luid = luid;
    privileges.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    AdjustTokenPrivileges(token, FALSE, &privileges, sizeof(privileges),
                          NULL, NULL);
    CloseHandle(token);
}

int wmain(int argc, wchar_t **argv)
{
    DWORD pid;
    HANDLE process;
    HMODULE module = NULL;
    DWORD needed = 0;
    MODULEINFO info;
    FILE *output;
    const SIZE_T page_size = 0x1000;
    unsigned char *buffer;
    SIZE_T offset;
    DWORD failures = 0;

    if (argc != 3) {
        fwprintf(stderr, L"usage: %ls PID OUTPUT\n", argv[0]);
        return 2;
    }
    pid = wcstoul(argv[1], NULL, 10);
    enable_debug_privilege();
    process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
                          FALSE, pid);
    if (process == NULL) {
        fwprintf(stderr, L"OpenProcess failed: %lu\n", GetLastError());
        return 1;
    }
    if (!EnumProcessModulesEx(process, &module, sizeof(module), &needed,
                              LIST_MODULES_ALL) || module == NULL ||
        !GetModuleInformation(process, module, &info, sizeof(info))) {
        fwprintf(stderr, L"main module query failed: %lu\n", GetLastError());
        CloseHandle(process);
        return 1;
    }
    output = _wfopen(argv[2], L"wb");
    if (output == NULL) {
        fwprintf(stderr, L"cannot open output\n");
        CloseHandle(process);
        return 1;
    }
    buffer = (unsigned char *)calloc(page_size, 1);
    if (buffer == NULL) {
        fclose(output);
        CloseHandle(process);
        return 3;
    }
    for (offset = 0; offset < info.SizeOfImage; offset += page_size) {
        SIZE_T wanted = info.SizeOfImage - offset;
        SIZE_T received = 0;

        if (wanted > page_size) {
            wanted = page_size;
        }
        ZeroMemory(buffer, page_size);
        if (!ReadProcessMemory(process,
                (const unsigned char *)info.lpBaseOfDll + offset,
                buffer, wanted, &received)) {
            ++failures;
        }
        if (fwrite(buffer, 1, wanted, output) != wanted) {
            free(buffer);
            fclose(output);
            CloseHandle(process);
            return 4;
        }
    }
    free(buffer);
    fclose(output);
    CloseHandle(process);
    wprintf(L"pid=%lu base=0x%llx size=0x%lx read_failures=%lu output=%ls\n",
            (unsigned long)pid,
            (unsigned long long)(uintptr_t)info.lpBaseOfDll,
            (unsigned long)info.SizeOfImage, (unsigned long)failures,
            argv[2]);
    return 0;
}

#define UNICODE
#define _UNICODE

#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

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
    uintptr_t address;
    SIZE_T size;
    HANDLE process;
    unsigned char *buffer;
    SIZE_T received = 0;
    FILE *output;

    if (argc != 5) {
        fwprintf(stderr, L"usage: %ls PID ADDRESS SIZE OUTPUT\n", argv[0]);
        return 2;
    }
    pid = wcstoul(argv[1], NULL, 0);
    address = (uintptr_t)wcstoull(argv[2], NULL, 0);
    size = (SIZE_T)wcstoull(argv[3], NULL, 0);
    if (size == 0 || size > 256 * 1024 * 1024) {
        fwprintf(stderr, L"invalid size\n");
        return 2;
    }
    enable_debug_privilege();
    process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
                          FALSE, pid);
    if (process == NULL) {
        fwprintf(stderr, L"OpenProcess failed: %lu\n", GetLastError());
        return 1;
    }
    buffer = (unsigned char *)calloc(size, 1);
    if (buffer == NULL) {
        CloseHandle(process);
        return 3;
    }
    if (!ReadProcessMemory(process, (LPCVOID)address, buffer, size,
                           &received) && received == 0) {
        fwprintf(stderr, L"ReadProcessMemory failed: %lu\n", GetLastError());
        free(buffer);
        CloseHandle(process);
        return 1;
    }
    output = _wfopen(argv[4], L"wb");
    if (output == NULL || fwrite(buffer, 1, received, output) != received) {
        fwprintf(stderr, L"output write failed\n");
        if (output != NULL) {
            fclose(output);
        }
        free(buffer);
        CloseHandle(process);
        return 4;
    }
    fclose(output);
    free(buffer);
    CloseHandle(process);
    wprintf(L"pid=%lu address=0x%llx requested=0x%llx received=0x%llx output=%ls\n",
            (unsigned long)pid, (unsigned long long)address,
            (unsigned long long)size, (unsigned long long)received, argv[4]);
    return 0;
}

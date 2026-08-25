#define UNICODE
#define _UNICODE

#include <windows.h>
#include <psapi.h>
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

static int executable(DWORD protect)
{
    DWORD base = protect & 0xff;

    if ((protect & (PAGE_GUARD | PAGE_NOACCESS)) != 0) {
        return 0;
    }
    return base == PAGE_EXECUTE || base == PAGE_EXECUTE_READ ||
           base == PAGE_EXECUTE_READWRITE ||
           base == PAGE_EXECUTE_WRITECOPY;
}

static const char *memory_type(DWORD type)
{
    if (type == MEM_IMAGE) {
        return "image";
    }
    if (type == MEM_MAPPED) {
        return "mapped";
    }
    if (type == MEM_PRIVATE) {
        return "private";
    }
    return "unknown";
}

static uint64_t hash_region(HANDLE process, uintptr_t start, SIZE_T size,
                            SIZE_T *bytes_read, DWORD *read_errors)
{
    const SIZE_T chunk_size = 1024 * 1024;
    unsigned char *buffer = (unsigned char *)malloc(chunk_size);
    uint64_t hash = UINT64_C(14695981039346656037);
    SIZE_T offset = 0;

    *bytes_read = 0;
    *read_errors = 0;
    if (buffer == NULL) {
        return 0;
    }
    while (offset < size) {
        SIZE_T wanted = size - offset;
        SIZE_T received = 0;
        SIZE_T index;

        if (wanted > chunk_size) {
            wanted = chunk_size;
        }
        if (!ReadProcessMemory(process, (LPCVOID)(start + offset), buffer,
                               wanted, &received)) {
            ++*read_errors;
        }
        for (index = 0; index < received; ++index) {
            hash ^= buffer[index];
            hash *= UINT64_C(1099511628211);
        }
        *bytes_read += received;
        offset += wanted;
    }
    free(buffer);
    return hash;
}

int wmain(int argc, wchar_t **argv)
{
    DWORD pid;
    HANDLE process;
    SYSTEM_INFO system_info;
    uintptr_t address;
    uintptr_t maximum;

    if (argc != 2) {
        fwprintf(stderr, L"usage: %ls PID\n", argv[0]);
        return 2;
    }
    pid = wcstoul(argv[1], NULL, 10);
    enable_debug_privilege();
    process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
                          FALSE, pid);
    if (process == NULL) {
        fwprintf(stderr, L"OpenProcess(%lu) failed: %lu\n",
                 (unsigned long)pid, (unsigned long)GetLastError());
        return 1;
    }

    puts("pid\tbase\tallocation\toffset\tsize\ttype\tprotect\thash_fnv1a64\tbytes_read\tread_errors\tmapped");
    GetNativeSystemInfo(&system_info);
    address = (uintptr_t)system_info.lpMinimumApplicationAddress;
    maximum = (uintptr_t)system_info.lpMaximumApplicationAddress;
    while (address < maximum) {
        MEMORY_BASIC_INFORMATION info;
        SIZE_T queried = VirtualQueryEx(process, (LPCVOID)address, &info,
                                        sizeof(info));
        uintptr_t region_start;
        uintptr_t region_end;
        WCHAR mapped[32768];
        DWORD mapped_count;
        SIZE_T bytes_read;
        DWORD read_errors;
        uint64_t hash;

        if (queried == 0) {
            address += 0x1000;
            continue;
        }
        region_start = (uintptr_t)info.BaseAddress;
        region_end = region_start + info.RegionSize;
        if (region_end <= address) {
            break;
        }
        address = region_end;
        if (info.State != MEM_COMMIT || !executable(info.Protect)) {
            continue;
        }
        mapped_count = GetMappedFileNameW(process, info.BaseAddress, mapped,
                                          ARRAYSIZE(mapped));
        if (mapped_count == 0) {
            mapped[0] = L'\0';
        } else {
            mapped[ARRAYSIZE(mapped) - 1] = L'\0';
        }
        hash = hash_region(process, region_start, info.RegionSize,
                           &bytes_read, &read_errors);
        wprintf(L"%lu\t0x%llx\t0x%llx\t0x%llx\t0x%llx\t%hs\t0x%lx\t%016llx\t0x%llx\t%lu\t%ls\n",
                (unsigned long)pid,
                (unsigned long long)region_start,
                (unsigned long long)(uintptr_t)info.AllocationBase,
                (unsigned long long)(region_start -
                    (uintptr_t)info.AllocationBase),
                (unsigned long long)info.RegionSize,
                memory_type(info.Type), (unsigned long)info.Protect,
                (unsigned long long)hash,
                (unsigned long long)bytes_read,
                (unsigned long)read_errors, mapped);
    }
    CloseHandle(process);
    return 0;
}

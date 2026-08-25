#define UNICODE
#define _UNICODE

#include <windows.h>
#include <psapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

static int readable(DWORD protect)
{
    DWORD base = protect & 0xff;
    if ((protect & (PAGE_GUARD | PAGE_NOACCESS)) != 0) {
        return 0;
    }
    return base == PAGE_READONLY || base == PAGE_READWRITE ||
           base == PAGE_WRITECOPY || base == PAGE_EXECUTE_READ ||
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

static void print_match(HANDLE process, DWORD pid, const char *encoding,
                        const char *needle, uintptr_t address,
                        const MEMORY_BASIC_INFORMATION *info)
{
    WCHAR mapped[MAX_PATH];
    DWORD count = GetMappedFileNameW(process, (LPCVOID)address, mapped,
                                     MAX_PATH);
    if (count == 0) {
        mapped[0] = L'\0';
    } else {
        mapped[MAX_PATH - 1] = L'\0';
    }
    printf("pid=%lu encoding=%s address=0x%llx region=0x%llx "
           "allocation=0x%llx type=%s protect=0x%lx needle=\"%s\"",
           (unsigned long)pid, encoding,
           (unsigned long long)address,
           (unsigned long long)(uintptr_t)info->BaseAddress,
           (unsigned long long)(uintptr_t)info->AllocationBase,
           memory_type(info->Type), (unsigned long)info->Protect, needle);
    if (mapped[0] != L'\0') {
        wprintf(L" mapped=\"%ls\"", mapped);
    }
    putchar('\n');
}

static void scan_bytes(HANDLE process, DWORD pid, const char *needle,
                       const unsigned char *pattern, SIZE_T pattern_size,
                       const char *encoding)
{
    SYSTEM_INFO system_info;
    uintptr_t address;
    uintptr_t maximum;
    const SIZE_T chunk_size = 1024 * 1024;
    unsigned char *buffer;

    GetNativeSystemInfo(&system_info);
    address = (uintptr_t)system_info.lpMinimumApplicationAddress;
    maximum = (uintptr_t)system_info.lpMaximumApplicationAddress;
    buffer = (unsigned char *)malloc(chunk_size + pattern_size);
    if (buffer == NULL) {
        fprintf(stderr, "allocation failed\n");
        exit(3);
    }

    while (address < maximum) {
        MEMORY_BASIC_INFORMATION info;
        SIZE_T queried = VirtualQueryEx(process, (LPCVOID)address, &info,
                                        sizeof(info));
        uintptr_t region_start;
        uintptr_t region_end;
        uintptr_t cursor;
        SIZE_T overlap = 0;

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
        if (info.State != MEM_COMMIT || !readable(info.Protect)) {
            continue;
        }

        cursor = region_start;
        while (cursor < region_end) {
            SIZE_T wanted = (SIZE_T)(region_end - cursor);
            SIZE_T received = 0;
            SIZE_T i;

            if (wanted > chunk_size) {
                wanted = chunk_size;
            }
            if (!ReadProcessMemory(process, (LPCVOID)cursor,
                                   buffer + overlap, wanted, &received) ||
                received == 0) {
                cursor += wanted;
                overlap = 0;
                continue;
            }
            received += overlap;
            if (received >= pattern_size) {
                for (i = 0; i + pattern_size <= received; ++i) {
                    if (memcmp(buffer + i, pattern, pattern_size) == 0) {
                        uintptr_t match = cursor - overlap + i;
                        print_match(process, pid, encoding, needle, match,
                                    &info);
                    }
                }
            }
            overlap = pattern_size > 1 ? pattern_size - 1 : 0;
            if (overlap > received) {
                overlap = received;
            }
            if (overlap != 0) {
                memmove(buffer, buffer + received - overlap, overlap);
            }
            cursor += wanted;
        }
    }
    free(buffer);
}

int main(int argc, char **argv)
{
    DWORD pid;
    HANDLE process;
    int index;

    if (argc < 3) {
        fprintf(stderr, "usage: %s PID STRING [STRING ...]\n", argv[0]);
        return 2;
    }
    pid = (DWORD)strtoul(argv[1], NULL, 10);
    enable_debug_privilege();
    process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
                          FALSE, pid);
    if (process == NULL) {
        fprintf(stderr, "OpenProcess(%lu) failed: %lu\n",
                (unsigned long)pid, (unsigned long)GetLastError());
        return 1;
    }

    for (index = 2; index < argc; ++index) {
        int wide_count;
        WCHAR *wide;
        SIZE_T ascii_size = strlen(argv[index]);

        scan_bytes(process, pid, argv[index],
                   (const unsigned char *)argv[index], ascii_size, "ascii");
        wide_count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         argv[index], -1, NULL, 0);
        if (wide_count <= 1) {
            continue;
        }
        wide = (WCHAR *)calloc((SIZE_T)wide_count, sizeof(WCHAR));
        if (wide == NULL) {
            CloseHandle(process);
            return 3;
        }
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[index], -1,
                            wide, wide_count);
        scan_bytes(process, pid, argv[index], (const unsigned char *)wide,
                   (SIZE_T)(wide_count - 1) * sizeof(WCHAR), "utf16le");
        free(wide);
    }
    CloseHandle(process);
    return 0;
}

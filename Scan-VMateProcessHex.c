#define UNICODE
#define _UNICODE

#include <windows.h>
#include <psapi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VMATE_CHUNK_SIZE (1024 * 1024)
#define VMATE_CONTEXT_BEFORE 128
#define VMATE_CONTEXT_AFTER 256
#define VMATE_MAX_MATCHES 128

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

static int hex_nibble(char character)
{
    if (character >= '0' && character <= '9') {
        return character - '0';
    }
    if (character >= 'a' && character <= 'f') {
        return character - 'a' + 10;
    }
    if (character >= 'A' && character <= 'F') {
        return character - 'A' + 10;
    }
    return -1;
}

static unsigned char *parse_hex(const char *text, SIZE_T *size)
{
    SIZE_T length = strlen(text);
    SIZE_T index;
    unsigned char *bytes;

    if (length == 0 || (length & 1) != 0 || length > 512) {
        return NULL;
    }
    bytes = (unsigned char *)malloc(length / 2);
    if (bytes == NULL) {
        return NULL;
    }
    for (index = 0; index < length; index += 2) {
        int high = hex_nibble(text[index]);
        int low = hex_nibble(text[index + 1]);
        if (high < 0 || low < 0) {
            free(bytes);
            return NULL;
        }
        bytes[index / 2] = (unsigned char)((high << 4) | low);
    }
    *size = length / 2;
    return bytes;
}

static void print_context(HANDLE process, uintptr_t match,
                          const MEMORY_BASIC_INFORMATION *info)
{
    uintptr_t region_start = (uintptr_t)info->BaseAddress;
    uintptr_t region_end = region_start + info->RegionSize;
    uintptr_t start = match > region_start + VMATE_CONTEXT_BEFORE ?
        match - VMATE_CONTEXT_BEFORE : region_start;
    SIZE_T wanted = VMATE_CONTEXT_BEFORE + VMATE_CONTEXT_AFTER;
    unsigned char context[VMATE_CONTEXT_BEFORE + VMATE_CONTEXT_AFTER];
    SIZE_T received = 0;
    SIZE_T index;

    if (start + wanted > region_end) {
        wanted = (SIZE_T)(region_end - start);
    }
    ZeroMemory(context, sizeof(context));
    ReadProcessMemory(process, (LPCVOID)start, context, wanted, &received);
    printf("0x%llx\t0x%llx\t0x%llx\t0x%llx\t%s\t0x%lx\t0x%llx\t",
           (unsigned long long)match,
           (unsigned long long)region_start,
           (unsigned long long)(uintptr_t)info->AllocationBase,
           (unsigned long long)info->RegionSize,
           memory_type(info->Type), (unsigned long)info->Protect,
           (unsigned long long)start);
    for (index = 0; index < received; ++index) {
        printf("%02X", context[index]);
    }
    putchar('\n');
}

int main(int argc, char **argv)
{
    DWORD pid;
    HANDLE process;
    unsigned char *pattern;
    SIZE_T pattern_size = 0;
    SYSTEM_INFO system_info;
    uintptr_t address;
    uintptr_t maximum;
    unsigned char *buffer;
    DWORD match_count = 0;
    uintptr_t last_match = 0;

    if (argc != 3) {
        fprintf(stderr, "usage: %s PID HEX_PATTERN\n", argv[0]);
        return 2;
    }
    pid = (DWORD)strtoul(argv[1], NULL, 10);
    pattern = parse_hex(argv[2], &pattern_size);
    if (pattern == NULL) {
        fprintf(stderr, "invalid hex pattern\n");
        return 2;
    }
    enable_debug_privilege();
    process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
                          FALSE, pid);
    if (process == NULL) {
        fprintf(stderr, "OpenProcess(%lu) failed: %lu\n",
                (unsigned long)pid, (unsigned long)GetLastError());
        free(pattern);
        return 1;
    }
    buffer = (unsigned char *)malloc(VMATE_CHUNK_SIZE + pattern_size);
    if (buffer == NULL) {
        CloseHandle(process);
        free(pattern);
        return 3;
    }

    printf("match\tregion\tallocation\tregion_size\ttype\tprotect\tcontext_start\tcontext_hex\n");
    GetNativeSystemInfo(&system_info);
    address = (uintptr_t)system_info.lpMinimumApplicationAddress;
    maximum = (uintptr_t)system_info.lpMaximumApplicationAddress;
    while (address < maximum && match_count < VMATE_MAX_MATCHES) {
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
        while (cursor < region_end && match_count < VMATE_MAX_MATCHES) {
            SIZE_T wanted = (SIZE_T)(region_end - cursor);
            SIZE_T received = 0;
            SIZE_T index;

            if (wanted > VMATE_CHUNK_SIZE) {
                wanted = VMATE_CHUNK_SIZE;
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
                for (index = 0; index + pattern_size <= received; ++index) {
                    uintptr_t match;
                    if (memcmp(buffer + index, pattern, pattern_size) != 0) {
                        continue;
                    }
                    match = cursor - overlap + index;
                    if (match != last_match) {
                        print_context(process, match, &info);
                        last_match = match;
                        ++match_count;
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
    fprintf(stderr, "matches=%lu\n", (unsigned long)match_count);
    free(buffer);
    CloseHandle(process);
    free(pattern);
    return 0;
}

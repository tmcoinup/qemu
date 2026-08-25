#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <windows.h>

typedef struct {
    uint64_t rax;
    uint64_t rcx;
    uint64_t rdx;
    uint64_t r8;
    uint64_t r9;
    uint64_t r10;
    uint64_t r11;
    uint64_t r12;
} vmate_bridge_request;

static uint32_t invoke_bridge(vmate_bridge_request *request,
                              uint32_t *out_ebx,
                              uint32_t *out_ecx,
                              uint32_t *out_edx)
{
    uint64_t rax = request->rax;
    uint64_t rcx = request->rcx;
    uint64_t rdx = request->rdx;
    uint32_t rbx;
    register uint64_t r8_value __asm__("r8") = request->r8;
    register uint64_t r9_value __asm__("r9") = request->r9;
    register uint64_t r10_value __asm__("r10") = request->r10;
    register uint64_t r11_value __asm__("r11") = request->r11;
    register uint64_t r12_value __asm__("r12") = request->r12;

    __asm__ volatile(
        "cpuid"
        : "+a"(rax), "=b"(rbx), "+c"(rcx), "+d"(rdx),
          "+r"(r8_value), "+r"(r9_value), "+r"(r10_value),
          "+r"(r11_value), "+r"(r12_value)
        :
        : "memory");
    *out_ebx = rbx;
    *out_ecx = (uint32_t)rcx;
    *out_edx = (uint32_t)rdx;
    return (uint32_t)rax;
}

int main(void)
{
    SYSTEM_INFO system_info;
    uint8_t *allocation;
    uint8_t *buffer;
    DWORD old_protect;
    vmate_bridge_request request;
    uint32_t eax;
    uint32_t ebx;
    uint32_t ecx;
    uint32_t edx;
    size_t index;
    size_t changed = 0;

    GetSystemInfo(&system_info);
    allocation = VirtualAlloc(NULL, system_info.dwPageSize * 3,
                              MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (allocation == NULL) {
        fprintf(stderr, "VirtualAlloc failed: %lu\n", GetLastError());
        return 2;
    }
    if (!VirtualProtect(allocation, system_info.dwPageSize,
                        PAGE_NOACCESS, &old_protect) ||
        !VirtualProtect(allocation + system_info.dwPageSize * 2,
                        system_info.dwPageSize, PAGE_NOACCESS,
                        &old_protect)) {
        fprintf(stderr, "VirtualProtect failed: %lu\n", GetLastError());
        VirtualFree(allocation, 0, MEM_RELEASE);
        return 3;
    }
    buffer = allocation + system_info.dwPageSize;
    memset(buffer, 0, system_info.dwPageSize);
    memset(&request, 0, sizeof(request));
    request.rax = 0x0051530dULL;
    request.rcx = 6;
    request.rdx = (uintptr_t)buffer;
    eax = invoke_bridge(&request, &ebx, &ecx, &edx);

    for (index = 0; index < 256; ++index) {
        if (buffer[index] != 0) {
            ++changed;
        }
    }
    printf("{\"SchemaVersion\":1,\"RequestEax\":\"0x%08X\","
           "\"Operation\":6,\"Result\":{\"Eax\":\"0x%08X\","
           "\"Ebx\":\"0x%08X\",\"Ecx\":\"0x%08X\","
           "\"Edx\":\"0x%08X\"},\"ChangedBytesFirst256\":%llu,"
           "\"First128Hex\":\"",
           0x0051530dU, eax, ebx, ecx, edx,
           (unsigned long long)changed);
    for (index = 0; index < 128; ++index) {
        printf("%02X", buffer[index]);
    }
    printf("\"}\n");
    VirtualFree(allocation, 0, MEM_RELEASE);
    return 0;
}

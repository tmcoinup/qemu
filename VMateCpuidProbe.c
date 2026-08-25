#include <cpuid.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void json_string(const char *value)
{
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)value; *p; ++p) {
        if (*p == '"' || *p == '\\') {
            putchar('\\');
        }
        if (*p >= 0x20) {
            putchar(*p);
        }
    }
    putchar('"');
}

int main(void)
{
    unsigned int eax = 0, ebx = 0, ecx = 0, edx = 0;
    char vendor[13] = {0};
    char brand[49] = {0};
    unsigned int maximum = __get_cpuid_max(0, NULL);
    unsigned int extended = __get_cpuid_max(0x80000000u, NULL);

    if (!__get_cpuid(0, &eax, &ebx, &ecx, &edx)) {
        return 2;
    }
    memcpy(vendor + 0, &ebx, 4);
    memcpy(vendor + 4, &edx, 4);
    memcpy(vendor + 8, &ecx, 4);

    unsigned int leaf1 = 0;
    if (__get_cpuid(1, &eax, &ebx, &ecx, &edx)) {
        leaf1 = eax;
    }
    if (extended >= 0x80000004u) {
        unsigned int *words = (unsigned int *)brand;
        for (unsigned int leaf = 0x80000002u; leaf <= 0x80000004u; ++leaf) {
            __cpuid(leaf, eax, ebx, ecx, edx);
            *words++ = eax;
            *words++ = ebx;
            *words++ = ecx;
            *words++ = edx;
        }
        brand[48] = '\0';
    }

    printf("{\"Vendor\":");
    json_string(vendor);
    printf(",\"Brand\":");
    json_string(brand);
    printf(",\"MaximumBasicLeaf\":%u,\"MaximumExtendedLeaf\":%u,"
           "\"Leaf1Eax\":%u}\n", maximum, extended, leaf1);
    return 0;
}

/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Direct, read-only x86 CPUID evidence helper used inside an authorized VM. */

#include <cpuid.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void
vmate_print_json_string(const char *value)
{
    const unsigned char *cursor;

    putchar('"');
    for (cursor = (const unsigned char *)value; *cursor != '\0'; cursor++) {
        if (*cursor == '"' || *cursor == '\\') {
            putchar('\\');
        }
        if (*cursor >= 0x20) {
            putchar(*cursor);
        }
    }
    putchar('"');
}

int
main(void)
{
    unsigned int eax = 0;
    unsigned int ebx = 0;
    unsigned int ecx = 0;
    unsigned int edx = 0;
    unsigned int maximum = __get_cpuid_max(0, NULL);
    unsigned int extended = __get_cpuid_max(0x80000000u, NULL);
    unsigned int leaf1 = 0;
    char vendor[13] = {0};
    char brand[49] = {0};

    if (!__get_cpuid(0, &eax, &ebx, &ecx, &edx)) {
        return 2;
    }
    memcpy(vendor + 0, &ebx, 4);
    memcpy(vendor + 4, &edx, 4);
    memcpy(vendor + 8, &ecx, 4);
    if (__get_cpuid(1, &eax, &ebx, &ecx, &edx)) {
        leaf1 = eax;
    }
    if (extended >= 0x80000004u) {
        unsigned int *words = (unsigned int *)brand;
        unsigned int leaf;

        for (leaf = 0x80000002u; leaf <= 0x80000004u; leaf++) {
            __cpuid(leaf, eax, ebx, ecx, edx);
            *words++ = eax;
            *words++ = ebx;
            *words++ = ecx;
            *words++ = edx;
        }
        brand[48] = '\0';
    }

    fputs("{\"Vendor\":", stdout);
    vmate_print_json_string(vendor);
    fputs(",\"Brand\":", stdout);
    vmate_print_json_string(brand);
    printf(",\"MaximumBasicLeaf\":%u,\"MaximumExtendedLeaf\":%u,"
           "\"Leaf1Eax\":%u}\n", maximum, extended, leaf1);
    return 0;
}

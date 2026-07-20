#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "adl_context_handle.h"

static int g_failures;

static void expect(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        ++g_failures;
    }
}

static void test_slot_boundaries(void)
{
    uintptr_t first_token = 0u;
    uintptr_t last_token = 0u;
    uintptr_t generation = 0u;
    size_t slot_index = 0u;

    expect(adl_context_handle_encode(0u, 1u, &first_token),
           "first context slot must encode");
    expect(adl_context_handle_encode(ADL_CONTEXT_SLOT_CAPACITY - 1u, 1u,
                                     &last_token),
           "last context slot must encode");
    expect(first_token != last_token,
           "first and last context slots must not collide");
    expect((last_token & ADL_CONTEXT_SLOT_MASK) ==
               (uintptr_t)ADL_CONTEXT_SLOT_CAPACITY,
           "last context slot must retain its nonzero code");
    expect(adl_context_handle_decode(last_token, &slot_index, &generation) &&
               slot_index == ADL_CONTEXT_SLOT_CAPACITY - 1u &&
               generation == 1u,
           "last context slot must round-trip");
    expect(!adl_context_handle_encode(ADL_CONTEXT_SLOT_CAPACITY, 1u,
                                      &last_token),
           "out-of-range context slot must fail");
}

static void test_generation_boundaries(void)
{
    uintptr_t token = 0u;
    uintptr_t generation = 0u;
    size_t slot_index = 0u;

    expect(!adl_context_handle_encode(0u, 0u, &token),
           "zero generation must be reserved");
    expect(adl_context_handle_encode(0u, ADL_CONTEXT_GENERATION_MAX, &token),
           "largest representable generation must encode");
    expect(adl_context_handle_decode(token, &slot_index, &generation) &&
               slot_index == 0u &&
               generation == ADL_CONTEXT_GENERATION_MAX,
           "largest generation must round-trip");
    expect(!adl_context_handle_encode(0u, ADL_CONTEXT_GENERATION_MAX + 1u,
                                      &token),
           "generation overflow must fail");
    expect(!adl_context_handle_decode((uintptr_t)1u << ADL_CONTEXT_SLOT_BITS,
                                      &slot_index, &generation),
           "zero slot code must remain invalid");
}

int main(void)
{
    test_slot_boundaries();
    test_generation_boundaries();
    if (g_failures != 0) {
        fprintf(stderr, "FAIL: %d context-handle assertions\n", g_failures);
        return EXIT_FAILURE;
    }
    puts("PASS: ADL context handle encoding");
    return EXIT_SUCCESS;
}

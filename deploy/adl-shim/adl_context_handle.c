#include "adl_context_handle.h"

int adl_context_handle_encode(size_t slot_index, uintptr_t generation,
                              uintptr_t *token)
{
    if (token == NULL || slot_index >= ADL_CONTEXT_SLOT_CAPACITY ||
        generation == 0u || generation > ADL_CONTEXT_GENERATION_MAX) {
        return 0;
    }
    *token = (generation << ADL_CONTEXT_SLOT_BITS) |
        ((uintptr_t)slot_index + (uintptr_t)1u);
    return 1;
}

int adl_context_handle_decode(uintptr_t token, size_t *slot_index,
                              uintptr_t *generation)
{
    uintptr_t slot_code;
    uintptr_t decoded_generation;

    if (slot_index == NULL || generation == NULL) {
        return 0;
    }
    *slot_index = 0u;
    *generation = 0u;
    slot_code = token & ADL_CONTEXT_SLOT_MASK;
    decoded_generation = token >> ADL_CONTEXT_SLOT_BITS;
    if (slot_code == 0u ||
        slot_code > (uintptr_t)ADL_CONTEXT_SLOT_CAPACITY ||
        decoded_generation == 0u) {
        return 0;
    }
    *slot_index = (size_t)(slot_code - (uintptr_t)1u);
    *generation = decoded_generation;
    return 1;
}

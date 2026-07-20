#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <limits.h>
#include <stdint.h>
#include <string.h>

#include "adl_context_handle.h"
#include "adl_runtime.h"

/*
 * ADL_CONTEXT_HANDLE 对外是不透明值，不能由调用方解引用。用 slot+generation
 * 编码避免销毁后重用同一 slot 令陈旧句柄重新有效，也无需永久堆分配。
 */
#if defined(_WIN64)
#define ADL_RUNTIME_CONTEXT_GENERATION_MAX LONG_MAX
#else
#define ADL_RUNTIME_CONTEXT_GENERATION_MAX \
    ((LONG)ADL_CONTEXT_GENERATION_MAX)
#endif

struct adl_context_slot {
    LONG active;
    LONG generation;
    ADL_MAIN_MALLOC_CALLBACK callback;
};

static LONG g_main_references;
static LONG g_context_references;
static ADL_MAIN_MALLOC_CALLBACK g_main_callback;
static struct adl_context_slot g_context_slots[ADL_CONTEXT_SLOT_CAPACITY];

static LONG read_reference(const LONG *references)
{
    return InterlockedCompareExchange((LONG volatile *)references, 0, 0);
}

static int increment_reference(LONG *references)
{
    LONG observed;
    LONG updated;

    do {
        observed = read_reference(references);
        if (observed < 0 || observed == LONG_MAX) {
            return 0;
        }
        updated = observed + 1;
    } while (InterlockedCompareExchange(references, updated, observed) !=
             observed);
    return 1;
}

static int decrement_reference(LONG *references)
{
    LONG observed;
    LONG updated;

    do {
        observed = read_reference(references);
        if (observed <= 0) {
            return 0;
        }
        updated = observed - 1;
    } while (InterlockedCompareExchange(references, updated, observed) !=
             observed);
    return 1;
}

static int runtime_is_ready(void)
{
    return read_reference(&g_main_references) > 0 ||
           read_reference(&g_context_references) > 0;
}

static ADL_CONTEXT_HANDLE encode_context(size_t slot_index, LONG generation)
{
    uintptr_t token = 0u;

    if (generation <= 0 ||
        !adl_context_handle_encode(slot_index,
                                   (uintptr_t)(unsigned long)generation,
                                   &token)) {
        return NULL;
    }
    return (ADL_CONTEXT_HANDLE)token;
}

static struct adl_context_slot *decode_context(ADL_CONTEXT_HANDLE context)
{
    uintptr_t token = (uintptr_t)context;
    uintptr_t generation;
    size_t slot_index;
    struct adl_context_slot *slot;

    if (!adl_context_handle_decode(token, &slot_index, &generation) ||
        generation > (uintptr_t)LONG_MAX) {
        return NULL;
    }
    slot = &g_context_slots[slot_index];
    if (read_reference(&slot->active) != 1 ||
        read_reference(&slot->generation) != (LONG)generation) {
        return NULL;
    }
    return slot;
}

static int valid_query_context(ADL_CONTEXT_HANDLE context)
{
    if (context == NULL) {
        return read_reference(&g_main_references) > 0;
    }
    return decode_context(context) != NULL;
}

static LONG next_slot_generation(struct adl_context_slot *slot)
{
    LONG observed;
    LONG updated;

    do {
        observed = read_reference(&slot->generation);
        if (observed < 0 || observed >= ADL_RUNTIME_CONTEXT_GENERATION_MAX) {
            return 0;
        }
        updated = observed + 1;
    } while (InterlockedCompareExchange(&slot->generation, updated,
                                         observed) != observed);
    return updated;
}

static int reserve_context(ADL_MAIN_MALLOC_CALLBACK callback,
                           ADL_CONTEXT_HANDLE *context)
{
    size_t index;

    for (index = 0u; index < ADL_CONTEXT_SLOT_CAPACITY; ++index) {
        struct adl_context_slot *slot = &g_context_slots[index];
        ADL_CONTEXT_HANDLE encoded_context;
        LONG generation;

        if (InterlockedCompareExchange(&slot->active, -1, 0) != 0) {
            continue;
        }
        generation = next_slot_generation(slot);
        if (generation == 0) {
            InterlockedExchange(&slot->active, 0);
            continue;
        }
        encoded_context = encode_context(index, generation);
        if (encoded_context == NULL) {
            InterlockedExchange(&slot->active, 0);
            continue;
        }
        slot->callback = callback;
        MemoryBarrier();
        InterlockedExchange(&slot->active, 1);
        *context = encoded_context;
        return 1;
    }
    return 0;
}

int adl_runtime_query_validate(ADL_CONTEXT_HANDLE context, int require_context)
{
    if (!runtime_is_ready()) {
        return ADL_ERR_NOT_INIT;
    }
    if (require_context && !valid_query_context(context)) {
        return ADL_ERR_INVALID_PARAM;
    }
    return ADL_OK;
}

static int allocation_callback(ADL_CONTEXT_HANDLE context, int require_context,
                               ADL_MAIN_MALLOC_CALLBACK *callback)
{
    struct adl_context_slot *slot;
    int status;

    if (callback == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    *callback = NULL;
    status = adl_runtime_query_validate(context, require_context);
    if (status != ADL_OK) {
        return status;
    }
    if (!require_context || context == NULL) {
        if (read_reference(&g_main_references) <= 0) {
            return require_context ? ADL_ERR_INVALID_PARAM : ADL_ERR_NOT_INIT;
        }
        *callback = g_main_callback;
    } else {
        slot = decode_context(context);
        if (slot == NULL) {
            return ADL_ERR_INVALID_PARAM;
        }
        *callback = slot->callback;
    }
    return *callback == NULL ? ADL_ERR_INVALID_CALLBACK : ADL_OK;
}

int adl_runtime_main_create(ADL_MAIN_MALLOC_CALLBACK callback)
{
    if (callback == NULL) {
        return ADL_ERR_INVALID_CALLBACK;
    }
    if (adl_identity_initialize() == ADL_IDENTITY_INVALID) {
        return ADL_ERR;
    }
    if (!increment_reference(&g_main_references)) {
        return ADL_ERR;
    }
    g_main_callback = callback;
    return ADL_OK;
}

int adl_runtime_main_destroy(void)
{
    return decrement_reference(&g_main_references) ? ADL_OK :
        ADL_ERR_NOT_INIT;
}

int adl_runtime_context_create(ADL_MAIN_MALLOC_CALLBACK callback,
                               ADL_CONTEXT_HANDLE *context)
{
    if (callback == NULL || context == NULL) {
        return callback == NULL ? ADL_ERR_INVALID_CALLBACK :
            ADL_ERR_NULL_POINTER;
    }
    *context = NULL;
    if (adl_identity_initialize() == ADL_IDENTITY_INVALID) {
        return ADL_ERR;
    }
    if (!increment_reference(&g_context_references)) {
        return ADL_ERR;
    }
    if (!reserve_context(callback, context)) {
        (void)decrement_reference(&g_context_references);
        return ADL_ERR;
    }
    return ADL_OK;
}

int adl_runtime_context_destroy(ADL_CONTEXT_HANDLE context)
{
    struct adl_context_slot *slot = decode_context(context);

    if (slot == NULL || InterlockedCompareExchange(&slot->active, 0, 1) != 1) {
        return ADL_ERR_INVALID_PARAM;
    }
    return decrement_reference(&g_context_references) ? ADL_OK :
        ADL_ERR_NOT_INIT;
}

int adl_runtime_refresh(ADL_CONTEXT_HANDLE context, int require_context)
{
    enum adl_identity_state state;
    int status = adl_runtime_query_validate(context, require_context);

    if (status != ADL_OK) {
        return status;
    }
    state = adl_identity_refresh();
    return state == ADL_IDENTITY_INVALID ? ADL_ERR : ADL_OK;
}

int adl_runtime_allocate(ADL_CONTEXT_HANDLE context, int require_context,
                         int size, void **allocation)
{
    ADL_MAIN_MALLOC_CALLBACK callback;
    int status;

    if (allocation == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    *allocation = NULL;
    if (size <= 0) {
        return ADL_ERR_INVALID_PARAM_SIZE;
    }
    status = allocation_callback(context, require_context, &callback);
    if (status != ADL_OK) {
        return status;
    }
    *allocation = callback(size);
    return *allocation == NULL ? ADL_ERR : ADL_OK;
}

int adl_runtime_adapter_count(ADL_CONTEXT_HANDLE context,
                              int require_context, int *count)
{
    enum adl_identity_state state;
    int status;

    if (count == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    *count = 0;
    status = adl_runtime_query_validate(context, require_context);
    if (status != ADL_OK) {
        return status;
    }
    state = adl_identity_initialize();
    if (state == ADL_IDENTITY_INVALID) {
        return ADL_ERR;
    }
    *count = state == ADL_IDENTITY_PRESENT ? 1 : 0;
    return ADL_OK;
}

int adl_runtime_adapter(ADL_CONTEXT_HANDLE context, int require_context,
                        int adapter_index,
                        struct adl_gpu_identity *identity)
{
    int count = 0;
    int status;

    if (identity == NULL) {
        return ADL_ERR_NULL_POINTER;
    }
    memset(identity, 0, sizeof(*identity));
    status = adl_runtime_adapter_count(context, require_context, &count);
    if (status != ADL_OK) {
        return status;
    }
    if (adapter_index != 0 || count != 1) {
        return ADL_ERR_INVALID_ADL_IDX;
    }
    if (adl_identity_copy(identity) != ADL_IDENTITY_PRESENT) {
        return ADL_ERR;
    }
    return ADL_OK;
}

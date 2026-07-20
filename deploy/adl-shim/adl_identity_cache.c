#include <string.h>

#include "adl_identity_cache.h"

static void cache_lock(struct adl_identity_cache *cache)
{
#ifdef _WIN32
    while (InterlockedCompareExchange(&cache->lock, 1, 0) != 0) {
    }
    MemoryBarrier();
#else
    while (__sync_lock_test_and_set(&cache->lock, 1) != 0) {
    }
    __sync_synchronize();
#endif
}

static void cache_unlock(struct adl_identity_cache *cache)
{
#ifdef _WIN32
    MemoryBarrier();
    InterlockedExchange(&cache->lock, 0);
#else
    __sync_synchronize();
    __sync_lock_release(&cache->lock);
#endif
}

static enum adl_identity_state cache_load(struct adl_identity_cache *cache,
                                          adl_identity_loader loader,
                                          void *context, int force_reload)
{
    struct adl_gpu_identity candidate;
    enum adl_identity_state state;

    if (cache == NULL || loader == NULL) {
        return ADL_IDENTITY_INVALID;
    }
    cache_lock(cache);
    if (!force_reload && cache->initialized) {
        state = cache->state;
        cache_unlock(cache);
        return state;
    }
    memset(&candidate, 0, sizeof(candidate));
    state = loader(context, &candidate);
    if (state != ADL_IDENTITY_INVALID) {
        memset(&cache->identity, 0, sizeof(cache->identity));
        if (state == ADL_IDENTITY_PRESENT) {
            cache->identity = candidate;
        }
        cache->state = state;
        cache->initialized = 1;
    }
    cache_unlock(cache);
    return state;
}

enum adl_identity_state adl_identity_cache_initialize(
    struct adl_identity_cache *cache, adl_identity_loader loader,
    void *context)
{
    return cache_load(cache, loader, context, 0);
}

enum adl_identity_state adl_identity_cache_refresh(
    struct adl_identity_cache *cache, adl_identity_loader loader,
    void *context)
{
    return cache_load(cache, loader, context, 1);
}

enum adl_identity_state adl_identity_cache_copy(
    struct adl_identity_cache *cache, struct adl_gpu_identity *identity)
{
    enum adl_identity_state state;

    if (cache == NULL || identity == NULL) {
        return ADL_IDENTITY_INVALID;
    }
    memset(identity, 0, sizeof(*identity));
    cache_lock(cache);
    if (!cache->initialized) {
        cache_unlock(cache);
        return ADL_IDENTITY_INVALID;
    }
    state = cache->state;
    if (state == ADL_IDENTITY_PRESENT) {
        *identity = cache->identity;
    }
    cache_unlock(cache);
    return state;
}

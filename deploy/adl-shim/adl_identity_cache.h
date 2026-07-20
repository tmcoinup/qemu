#ifndef STEALTH_ADL_IDENTITY_CACHE_H
#define STEALTH_ADL_IDENTITY_CACHE_H

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
typedef volatile LONG adl_identity_cache_lock;
#else
/* Linux host tests use GCC's lock builtins; the shipping DLL never needs it. */
typedef volatile int adl_identity_cache_lock;
#endif

#include "adl_identity.h"

/* 平台读取器把一个已完成 pointer -> snapshot -> pointer/schema 校验的结果交给缓存。 */
typedef enum adl_identity_state (*adl_identity_loader)(
    void *context, struct adl_gpu_identity *identity);

struct adl_identity_cache {
    adl_identity_cache_lock lock;
    int initialized;
    enum adl_identity_state state;
    struct adl_gpu_identity identity;
};

#define ADL_IDENTITY_CACHE_INITIALIZER \
    { .lock = 0, .initialized = 0, .state = ADL_IDENTITY_INVALID }

enum adl_identity_state adl_identity_cache_initialize(
    struct adl_identity_cache *cache, adl_identity_loader loader,
    void *context);
enum adl_identity_state adl_identity_cache_refresh(
    struct adl_identity_cache *cache, adl_identity_loader loader,
    void *context);
enum adl_identity_state adl_identity_cache_copy(
    struct adl_identity_cache *cache, struct adl_gpu_identity *identity);

#endif

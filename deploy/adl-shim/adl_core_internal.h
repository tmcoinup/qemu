#ifndef STEALTH_ADL_CORE_INTERNAL_H
#define STEALTH_ADL_CORE_INTERNAL_H

#include "adl_identity.h"
#include "adl_types.h"

/* 供同一 DLL 内的扩展入口复用，保证固定与动态 AdapterInfo 完全一致。 */
int adl_core_build_adapter_info(const struct adl_gpu_identity *identity,
                                AdapterInfo *info);

#endif

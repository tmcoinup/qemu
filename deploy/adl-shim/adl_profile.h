#ifndef STEALTH_ADL_PROFILE_H
#define STEALTH_ADL_PROFILE_H

#include <stdint.h>

#include "adl_identity.h"

/*
 * 统一 profile -> ADL 单位转换。GDDR5 字段沿用仓库 effective/NVAPI 口径，
 * 所以物理显存时钟先除以 2；OD5 再从 kHz 转成 10 kHz。
 */
int adl_profile_core_mhz(const struct adl_gpu_identity *identity);
int adl_profile_boost_mhz(const struct adl_gpu_identity *identity);
int adl_profile_memory_mhz(const struct adl_gpu_identity *identity);
int adl_profile_core_10khz(const struct adl_gpu_identity *identity);
int adl_profile_boost_10khz(const struct adl_gpu_identity *identity);
int adl_profile_memory_10khz(const struct adl_gpu_identity *identity);
int64_t adl_profile_memory_bandwidth_mb(
    const struct adl_gpu_identity *identity);

#endif

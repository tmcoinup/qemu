#include <stdint.h>

#include "adl_profile.h"

int adl_profile_core_mhz(const struct adl_gpu_identity *identity)
{
    return (int)(identity->base_clock_khz / 1000u);
}

int adl_profile_boost_mhz(const struct adl_gpu_identity *identity)
{
    return (int)(identity->boost_clock_khz / 1000u);
}

int adl_profile_memory_mhz(const struct adl_gpu_identity *identity)
{
    return (int)(identity->memory_clock_khz / 2000u);
}

int adl_profile_core_10khz(const struct adl_gpu_identity *identity)
{
    return (int)(identity->base_clock_khz / 10u);
}

int adl_profile_boost_10khz(const struct adl_gpu_identity *identity)
{
    return (int)(identity->boost_clock_khz / 10u);
}

int adl_profile_memory_10khz(const struct adl_gpu_identity *identity)
{
    return (int)(identity->memory_clock_khz / 20u);
}

int64_t adl_profile_memory_bandwidth_mb(
    const struct adl_gpu_identity *identity)
{
    const uint64_t value = (uint64_t)identity->memory_clock_khz * 2u *
        identity->memory_bus_width_bits;

    return (int64_t)(value / (8u * 1000u));
}

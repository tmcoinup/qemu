/*
 * Pure profile/clock helpers shared by the Windows shim and its native test.
 *
 * Keep this header independent of windows.h so the arithmetic can be exercised
 * on the build host.  The deployed, guest-verified NVAPI consumer contract for
 * GDDR5 returns a raw memory-domain value twice the clock rendered by GPU-Z and
 * similar tools.  For example, a displayed 1752 MHz is returned as 3504000 kHz.
 */
#ifndef NVAPI_PROFILE_MATH_H
#define NVAPI_PROFILE_MATH_H

#include <stdint.h>

#define NVAPI_RAM_TYPE_GDDR5 8u

static inline uint32_t
nvapi_rendered_memory_clock_khz(uint32_t raw_nvapi_khz)
{
    return (raw_nvapi_khz / 2u) + (raw_nvapi_khz & 1u);
}

static inline uint32_t
nvapi_memory_transfers_per_raw_clock(uint32_t memory_type)
{
    /* Only the GDDR5 contract used by the verified VM profiles is asserted. */
    return memory_type == NVAPI_RAM_TYPE_GDDR5 ? 2u : 0u;
}

/*
 * Convert a theoretical decimal MB/s profile value to the raw memory clock
 * returned through NVAPI.  For example, 112000 MB/s on a 128-bit GDDR5 bus is
 * 3500000 raw kHz.  Return zero for an unverified RAM-type representation.
 */
static inline uint32_t nvapi_memory_raw_clock_from_bandwidth_khz(
    uint32_t bandwidth_mbps, uint32_t bus_width_bits, uint32_t memory_type)
{
    uint32_t transfers = nvapi_memory_transfers_per_raw_clock(memory_type);
    uint64_t divisor;
    uint64_t numerator;
    uint64_t result;

    if (!bandwidth_mbps || !bus_width_bits || !transfers) {
        return 0u;
    }
    divisor = (uint64_t)bus_width_bits * transfers;
    numerator = (uint64_t)bandwidth_mbps * 8000u;
    result = (numerator + (divisor / 2u)) / divisor;
    return result <= UINT32_MAX ? (uint32_t)result : 0u;
}

static inline uint32_t nvapi_memory_bandwidth_from_raw_clock_mbps(
    uint32_t raw_nvapi_khz, uint32_t bus_width_bits, uint32_t memory_type)
{
    uint32_t transfers = nvapi_memory_transfers_per_raw_clock(memory_type);
    uint64_t result;

    if (!raw_nvapi_khz || !bus_width_bits || !transfers) {
        return 0u;
    }
    result = (uint64_t)raw_nvapi_khz * transfers * bus_width_bits / 8000u;
    return result <= UINT32_MAX ? (uint32_t)result : 0u;
}

/*
 * Prefer an explicitly configured raw clock.  The bandwidth-derived value is
 * a fallback and a coherence guard: it replaces a raw value only when the two
 * differ by more than one percent.  Thus the catalog pair 3504000 raw kHz and
 * 112000 MB/s retains the advertised 1752 MHz rendered clock.
 */
static inline uint32_t nvapi_choose_memory_raw_clock_khz(
    uint32_t fallback_raw_khz,
    uint32_t configured_raw_khz,
    uint32_t bandwidth_mbps,
    uint32_t bus_width_bits,
    uint32_t memory_type)
{
    uint32_t transfers = nvapi_memory_transfers_per_raw_clock(memory_type);
    uint32_t clock_khz = configured_raw_khz
        ? configured_raw_khz : fallback_raw_khz;
    uint32_t bandwidth_clock;

    if (!transfers) {
        return 0u;
    }
    bandwidth_clock = nvapi_memory_raw_clock_from_bandwidth_khz(
        bandwidth_mbps, bus_width_bits, memory_type);

    if (bandwidth_clock) {
        uint32_t difference = clock_khz > bandwidth_clock
            ? clock_khz - bandwidth_clock : bandwidth_clock - clock_khz;
        uint32_t tolerance = bandwidth_clock / 100u;

        if (!configured_raw_khz || difference > tolerance) {
            clock_khz = bandwidth_clock;
        }
    }
    return clock_khz;
}

#endif /* NVAPI_PROFILE_MATH_H */

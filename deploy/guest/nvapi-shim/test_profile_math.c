#include <assert.h>
#include <stdint.h>
#include <string.h>

#include "nvapi_profile_clocks.h"
#include "nvapi_profile_math.h"

int main(void)
{
    static const struct {
        uint32_t display_mhz;
        uint32_t bus_bits;
        uint32_t catalog_bandwidth_mbps;
        uint32_t expected_raw_khz;
    } catalog_profiles[] = {
        /* GTX 750 Ti, GT 1030, GTX 1050. */
        { 1350u, 128u,  86400u, 2700000u },
        { 1502u,  64u,  48100u, 3004000u },
        { 1752u, 128u, 112000u, 3504000u },
    };
    struct nvapi_profile_perf_clocks_v1 perf_clocks;
    struct nvapi_profile_pstate20_info_v1 pstates;
    unsigned int profile_index;

    assert(nvapi_rendered_memory_clock_khz(3504000u) == 1752000u);
    assert(nvapi_rendered_memory_clock_khz(3004001u) == 1502001u);

    assert(nvapi_memory_transfers_per_raw_clock(NVAPI_RAM_TYPE_GDDR5) == 2u);
    assert(nvapi_memory_transfers_per_raw_clock(0xffffffffu) == 0u);

    assert(nvapi_memory_raw_clock_from_bandwidth_khz(
        112000u, 128u, NVAPI_RAM_TYPE_GDDR5) == 3500000u);
    assert(nvapi_memory_raw_clock_from_bandwidth_khz(
        48100u, 64u, NVAPI_RAM_TYPE_GDDR5) == 3006250u);
    assert(nvapi_memory_raw_clock_from_bandwidth_khz(
        112000u, 0u, NVAPI_RAM_TYPE_GDDR5) == 0u);
    assert(nvapi_memory_bandwidth_from_raw_clock_mbps(
        3504000u, 128u, NVAPI_RAM_TYPE_GDDR5) == 112128u);

    for (profile_index = 0;
         profile_index < sizeof(catalog_profiles) / sizeof(catalog_profiles[0]);
         ++profile_index) {
        uint32_t raw_khz = catalog_profiles[profile_index].expected_raw_khz;
        uint32_t derived_mbps = nvapi_memory_bandwidth_from_raw_clock_mbps(
            raw_khz, catalog_profiles[profile_index].bus_bits,
            NVAPI_RAM_TYPE_GDDR5);
        uint32_t advertised_mbps =
            catalog_profiles[profile_index].catalog_bandwidth_mbps;
        uint32_t difference = derived_mbps > advertised_mbps
            ? derived_mbps - advertised_mbps
            : advertised_mbps - derived_mbps;

        assert(raw_khz == catalog_profiles[profile_index].display_mhz * 2000u);
        assert(nvapi_rendered_memory_clock_khz(raw_khz) ==
               catalog_profiles[profile_index].display_mhz * 1000u);
        assert((uint64_t)difference * 100u <= advertised_mbps);
        assert(nvapi_choose_memory_raw_clock_khz(
            1u, raw_khz, advertised_mbps,
            catalog_profiles[profile_index].bus_bits,
            NVAPI_RAM_TYPE_GDDR5) == raw_khz);
    }

    /* Preserve a close, explicitly advertised clock despite catalog rounding. */
    assert(nvapi_choose_memory_raw_clock_khz(
        3004000u, 3504000u, 112000u, 128u, NVAPI_RAM_TYPE_GDDR5)
        == 3504000u);
    /* A grossly inconsistent clock is repaired from bandwidth and bus width. */
    assert(nvapi_choose_memory_raw_clock_khz(
        3004000u, 1752000u, 112000u, 128u, NVAPI_RAM_TYPE_GDDR5)
        == 3500000u);
    /* Bandwidth supplies the clock when no explicit clock was configured. */
    assert(nvapi_choose_memory_raw_clock_khz(
        0u, 0u, 112000u, 128u, NVAPI_RAM_TYPE_GDDR5)
        == 3500000u);
    assert(nvapi_choose_memory_raw_clock_khz(
        3004000u, 3504000u, 112000u, 128u, 0xffffffffu) == 0u);

    memset(&perf_clocks, 0xa5, sizeof(perf_clocks));
    perf_clocks.version = NVAPI_PROFILE_PERF_CLOCKS_VER1;
    assert(nvapi_profile_fill_perf_clocks(
        &perf_clocks, -1, 1354000u, 1455000u, 3504000u));
    assert(perf_clocks.version == UINT32_C(0x00012a74));
    assert(perf_clocks.level_count == 1u);
    assert(perf_clocks.level == 0u);
    assert(perf_clocks.clock_count == 3u);
    assert(perf_clocks.levels[0].clocks[0].domain_id ==
           NVAPI_PROFILE_CLOCK_GRAPHICS);
    assert(perf_clocks.levels[0].clocks[0].current_frequency_khz ==
           1354000u);
    assert(perf_clocks.levels[0].clocks[0].default_frequency_khz ==
           1354000u);
    assert(perf_clocks.levels[0].clocks[0].minimum_frequency_khz ==
           1354000u);
    assert(perf_clocks.levels[0].clocks[0].maximum_frequency_khz ==
           1455000u);
    assert(perf_clocks.levels[0].clocks[1].domain_id ==
           NVAPI_PROFILE_CLOCK_MEMORY);
    assert(perf_clocks.levels[0].clocks[1].current_frequency_khz ==
           3504000u);
    assert(perf_clocks.levels[0].clocks[1].default_frequency_khz ==
           3504000u);
    assert(perf_clocks.levels[0].clocks[1].minimum_frequency_khz ==
           3504000u);
    assert(perf_clocks.levels[0].clocks[1].maximum_frequency_khz ==
           3504000u);
    assert(perf_clocks.levels[0].clocks[3].domain_id ==
           NVAPI_PROFILE_CLOCK_UNDEFINED);
    perf_clocks.version = NVAPI_PROFILE_PERF_CLOCKS_VER1;
    assert(!nvapi_profile_fill_perf_clocks(
        &perf_clocks, 1, 1354000u, 1455000u, 3504000u));
    perf_clocks.version = UINT32_C(0x00022a74);
    assert(!nvapi_profile_fill_perf_clocks(
        &perf_clocks, 0, 1354000u, 1455000u, 3504000u));

    memset(&pstates, 0xa5, sizeof(pstates));
    pstates.version = NVAPI_PROFILE_PSTATE20_INFO_VER1;
    assert(nvapi_profile_fill_pstates20(
        &pstates, 1354000u, 1455000u, 3504000u));
    assert(pstates.version == UINT32_C(0x00011c94));
    assert(pstates.pstate_count == 1u);
    assert(pstates.clock_count == 2u);
    assert(pstates.pstates[0].pstate_id == NVAPI_PROFILE_PSTATE_P0);
    assert(pstates.pstates[0].clocks[0].domain_id ==
           NVAPI_PROFILE_CLOCK_GRAPHICS);
    assert(pstates.pstates[0].clocks[0].clock_type == 1u);
    assert(pstates.pstates[0].clocks[0].data.range.minimum_frequency_khz ==
           1354000u);
    assert(pstates.pstates[0].clocks[0].data.range.maximum_frequency_khz ==
           1455000u);
    assert(pstates.pstates[0].clocks[1].domain_id ==
           NVAPI_PROFILE_CLOCK_MEMORY);
    assert(pstates.pstates[0].clocks[1].clock_type == 0u);
    assert(pstates.pstates[0].clocks[1].data.single.frequency_khz ==
           3504000u);
    pstates.version = UINT32_C(0x00041c94);
    assert(!nvapi_profile_fill_pstates20(
        &pstates, 1354000u, 1455000u, 3504000u));

    return 0;
}

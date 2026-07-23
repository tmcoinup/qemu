#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "aib_identity_catalog.h"

/*
 * 这里是 NVAPI 与 ADL 唯一共享的 schema-2 AIB 真值源。新增板卡时必须追加
 * 完整整行；严禁只添加 carrier 或仅按同一芯片 device ID 推断其他字段。
 */
static const struct stealth_aib_identity g_aib_identities[] = {
    { "NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)", "NVIDIA",
      "Version 86.07.42.00.96", "GDDR5", UINT32_C(0xa101),
      UINT32_C(0x10de), UINT32_C(0x1c82), UINT32_C(0x1043),
      UINT32_C(0x8613), UINT32_C(0xa1), 4096u, 128u, 1291000u,
      1392000u, 3504000u, 0u },
    { "NVIDIA GeForce GTX 1050 Ti (Colorful iGame U)", "NVIDIA",
      "Version 86.07.39.40.12", "GDDR5", UINT32_C(0xa102),
      UINT32_C(0x10de), UINT32_C(0x1c82), UINT32_C(0x7377),
      UINT32_C(0x0000), UINT32_C(0xa1), 4096u, 128u, 1380000u,
      1493000u, 3504000u, 0u },
    { "NVIDIA GeForce GT 1030 (GALAX EXOC White)", "NVIDIA",
      "Version 86.08.0C.00.2B", "GDDR5", UINT32_C(0xa103),
      UINT32_C(0x10de), UINT32_C(0x1d01), UINT32_C(0x10de),
      UINT32_C(0x11c7), UINT32_C(0xa1), 2048u, 64u, 1253000u,
      1506000u, 3004000u, 0u },
    { "NVIDIA GeForce GT 1030 (ASUS Silent)", "NVIDIA",
      "Version 86.08.0C.00.1A", "GDDR5", UINT32_C(0xa104),
      UINT32_C(0x10de), UINT32_C(0x1d01), UINT32_C(0x1043),
      UINT32_C(0x85f4), UINT32_C(0xa1), 2048u, 64u, 1228000u,
      1468000u, 3004000u, 0u },
    { "NVIDIA GeForce GT 1030 (MSI LP OCV1)", "NVIDIA",
      "Version 86.08.0C.00.18", "GDDR5", UINT32_C(0xa105),
      UINT32_C(0x10de), UINT32_C(0x1d01), UINT32_C(0x1462),
      UINT32_C(0x8c98), UINT32_C(0xa1), 2048u, 64u, 1266000u,
      1519000u, 3004000u, 0u },
    { "NVIDIA GeForce GTX 750 Ti (ASUS OC)", "NVIDIA",
      "Version 82.07.32.00.20", "GDDR5", UINT32_C(0xa106),
      UINT32_C(0x10de), UINT32_C(0x1380), UINT32_C(0x1043),
      UINT32_C(0x84bb), UINT32_C(0xa2), 2048u, 128u, 1072000u,
      1150000u, 2700000u, 0u },
    { "NVIDIA GeForce GTX 750 Ti (MSI OC)", "NVIDIA",
      "Version 82.07.25.00.1F", "GDDR5", UINT32_C(0xa107),
      UINT32_C(0x10de), UINT32_C(0x1380), UINT32_C(0x1462),
      UINT32_C(0x8a9b), UINT32_C(0xa2), 2048u, 128u, 1059000u,
      1137000u, 2700000u, 0u },
    { "NVIDIA GeForce GTX 750 Ti (Gigabyte OC)", "NVIDIA",
      "Version 82.07.55.00.05", "GDDR5", UINT32_C(0xa108),
      UINT32_C(0x10de), UINT32_C(0x1380), UINT32_C(0x1458),
      UINT32_C(0x362d), UINT32_C(0xa2), 2048u, 128u, 1033000u,
      1111000u, 2700000u, 0u },
    { "NVIDIA GeForce GTX 1050 (EVGA Gaming)", "NVIDIA",
      "Version 86.07.39.00.50", "GDDR5", UINT32_C(0xa109),
      UINT32_C(0x10de), UINT32_C(0x1c81), UINT32_C(0x3842),
      UINT32_C(0x6150), UINT32_C(0xa1), 2048u, 128u, 1354000u,
      1455000u, 3504000u, 0u },
    { "NVIDIA GeForce GTX 1050 (MSI Gaming X)", "NVIDIA",
      "Version 86.07.39.00.70", "GDDR5", UINT32_C(0xa10a),
      UINT32_C(0x10de), UINT32_C(0x1c81), UINT32_C(0x1462),
      UINT32_C(0x3354), UINT32_C(0xa1), 2048u, 128u, 1418000u,
      1531000u, 3504000u, 0u },
    { "NVIDIA GeForce GTX 1050 (Gigabyte OC)", "NVIDIA",
      "Version 86.07.39.00.72", "GDDR5", UINT32_C(0xa10b),
      UINT32_C(0x10de), UINT32_C(0x1c81), UINT32_C(0x1458),
      UINT32_C(0x372d), UINT32_C(0xa1), 2048u, 128u, 1380000u,
      1493000u, 3504000u, 0u },
    { "NVIDIA GeForce GTX 1050 Ti (Gigabyte OC)", "NVIDIA",
      "Version 86.07.39.40.99", "GDDR5", UINT32_C(0xa10c),
      UINT32_C(0x10de), UINT32_C(0x1c82), UINT32_C(0x1458),
      UINT32_C(0x3763), UINT32_C(0xa1), 4096u, 128u, 1316000u,
      1430000u, 3504000u, 0u },
    { "AMD Radeon RX 550 (ASUS 4G)", "AMD",
      "015.050.002.001.000000", "GDDR5", UINT32_C(0xa10d),
      UINT32_C(0x1002), UINT32_C(0x699f), UINT32_C(0x1043),
      UINT32_C(0x0513), UINT32_C(0xc7), 4096u, 128u, 1100000u,
      1183000u, 3500000u, 0u },
    { "AMD Radeon RX 550 (Gigabyte Gaming OC)", "AMD",
      "015.050.002.001.000000", "GDDR5", UINT32_C(0xa10e),
      UINT32_C(0x1002), UINT32_C(0x699f), UINT32_C(0x1458),
      UINT32_C(0x22f2), UINT32_C(0xc7), 2048u, 128u, 1100000u,
      1206000u, 3500000u, 0u },
    { "AMD Radeon RX 550 (MSI Aero ITX OC)", "AMD",
      "015.050.002.001.000000", "GDDR5", UINT32_C(0xa10f),
      UINT32_C(0x1002), UINT32_C(0x699f), UINT32_C(0x1462),
      UINT32_C(0x8a90), UINT32_C(0xc7), 2048u, 128u, 1100000u,
      1203000u, 3500000u, 0u },
    { "AMD Radeon RX 560 (ASUS ROG Strix Gaming)", "AMD",
      "015.050.002.001.000000", "GDDR5", UINT32_C(0xa110),
      UINT32_C(0x1002), UINT32_C(0x67ff), UINT32_C(0x1043),
      UINT32_C(0x04bc), UINT32_C(0xcf), 4096u, 128u, 1175000u,
      1275000u, 3500000u, 0u },
    { "AMD Radeon RX 560 (Gigabyte Gaming OC)", "AMD",
      "015.050.002.001.000000", "GDDR5", UINT32_C(0xa111),
      UINT32_C(0x1002), UINT32_C(0x67ff), UINT32_C(0x1458),
      UINT32_C(0x22ed), UINT32_C(0xcf), 4096u, 128u, 1175000u,
      1287000u, 3500000u, 0u },
    { "AMD Radeon RX 560 (Sapphire Pulse 16 CU)", "AMD",
      "015.050.002.001.000000", "GDDR5", UINT32_C(0xa112),
      UINT32_C(0x1002), UINT32_C(0x67ff), UINT32_C(0x1da2),
      UINT32_C(0xe348), UINT32_C(0xcf), 4096u, 128u, 1175000u,
      1300000u, 3500000u, 0u },
};

size_t stealth_aib_identity_count(void)
{
    return sizeof(g_aib_identities) / sizeof(g_aib_identities[0]);
}

const struct stealth_aib_identity *stealth_aib_identity_at(size_t index)
{
    if (index >= stealth_aib_identity_count()) {
        return NULL;
    }
    return &g_aib_identities[index];
}

const struct stealth_aib_identity *stealth_aib_identity_find_by_carrier(
    uint32_t carrier_device_id)
{
    size_t index;

    for (index = 0u; index < stealth_aib_identity_count(); ++index) {
        if (g_aib_identities[index].carrier_device_id == carrier_device_id) {
            return &g_aib_identities[index];
        }
    }
    return NULL;
}

int stealth_aib_identity_snapshot_matches(
    const struct stealth_aib_identity *identity,
    const struct stealth_aib_identity_snapshot *snapshot)
{
    if (identity == NULL || snapshot == NULL || snapshot->name == NULL ||
        snapshot->vendor == NULL || snapshot->bios == NULL ||
        snapshot->memory_type == NULL) {
        return 0;
    }
    return strcmp(snapshot->name, identity->name) == 0 &&
        strcmp(snapshot->vendor, identity->vendor) == 0 &&
        strcmp(snapshot->bios, identity->bios) == 0 &&
        strcmp(snapshot->memory_type, identity->memory_type) == 0 &&
        snapshot->pci_vendor_id == identity->pci_vendor_id &&
        snapshot->pci_device_id == identity->pci_device_id &&
        snapshot->subsystem_vendor_id == identity->subsystem_vendor_id &&
        snapshot->subsystem_device_id == identity->subsystem_device_id &&
        snapshot->revision_id == identity->revision_id &&
        snapshot->ram_mb == identity->ram_mb &&
        snapshot->memory_bus_width_bits == identity->memory_bus_width_bits &&
        snapshot->base_clock_khz == identity->base_clock_khz &&
        snapshot->boost_clock_khz == identity->boost_clock_khz &&
        snapshot->memory_clock_khz == identity->memory_clock_khz &&
        snapshot->sli_supported == identity->sli_supported;
}

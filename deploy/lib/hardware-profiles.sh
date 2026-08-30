#!/usr/bin/env bash
# Verified hardware identity catalog used by deploy/scripts/create-vm.sh.
# This file is deliberately side-effect free so tests and operators can source it.

# CPU, board and memory are independent audited catalogs.  They are never
# combined as a Cartesian product: HARDWARE_COMBINATIONS is the only allowlist
# from which a guest platform may be materialized.  PLATFORM remains the
# stable whole-machine key so all historical vm.conf files keep working.
#
# CPU fields:
# key|qemu-model|brand-string|tsc-hz|part|base-MHz|max-MHz|SMBIOS-family|
# socket-upgrade|processor-characteristics|cores|threads-per-core|L1-total-KiB|
# L2-total-KiB|L3-KiB|L2-assoc-enum|L3-assoc-enum|generation|socket|
# memory-family|max-memory-MT/s|GPU-root-port-device|GPU-root-port-revision|
# CPU-PCIe-generation
#
# Intel specifications (official):
#   https://www.intel.com/content/www/us/en/products/sku/77773/intel-pentium-processor-g3220-3m-cache-3-00-ghz/specifications.html
#   https://www.intel.com/content/www/us/en/products/sku/77480/intel-core-i34130-processor-3m-cache-3-40-ghz/specifications.html
#   https://www.intel.com/content/www/us/en/products/sku/80817/intel-core-i54460-processor-6m-cache-up-to-3-40-ghz/specifications.html
#   https://www.intel.com/content/www/us/en/products/sku/75043/intel-core-i54570-processor-6m-cache-up-to-3-60-ghz/specifications.html
#   https://www.intel.com/content/www/us/en/products/sku/80815/intel-core-i54590-processor-6m-cache-up-to-3-70-ghz/specifications.html
#   https://www.intel.com/content/www/us/en/products/sku/80806/intel-core-i74790-processor-8m-cache-up-to-4-00-ghz/specifications.html
#   https://www.intel.com/content/www/us/en/products/sku/63698/intel-core-i73820-processor-10m-cache-up-to-3-80-ghz/specifications.html
#   https://www.intel.com/content/www/us/en/products/sku/63697/intel-core-i73930k-processor-12m-cache-up-to-3-80-ghz/specifications.html
#   https://www.intel.com/content/www/us/en/products/sku/77781/intel-core-i74820k-processor-10m-cache-up-to-3-90-ghz/specifications.html
#   https://www.intel.com/content/www/us/en/products/sku/77780/intel-core-i74930k-processor-12m-cache-up-to-3-90-ghz/specifications.html
#   https://www.intel.com/content/www/us/en/products/sku/77779/intel-core-i74960x-processor-extreme-edition-15m-cache-up-to-4-00-ghz/specifications.html
# Retail i7-4930K CPUID/cache validation (12 MiB, 16-way LLC):
#   https://valid.x86.fr/7ehxl9
#
# The active consumer-desktop intersection is no-iGPU LGA2011 with
# quad-channel DDR3.  The normal pool contains two 4C/8T and three 6C/12T
# retail Core i7 parts, without admitting Xeon identities.
CPU_PROFILES=(
    "g3220|Intel-Pentium-G3220|Intel(R) Pentium(R) CPU G3220 @ 3.00GHz|3000000000|BX80646G3220|3000|3000|11|0x2D|0xEC|2|1|128|512|3072|7|9|4|LGA1150|DDR3|1333|0x0C01|0x06|3"
    "i3-4130|Core-i3-4130|Intel(R) Core(TM) i3-4130 CPU @ 3.40GHz|3400000000|BX80646I34130|3400|3400|206|0x2D|0xFC|2|2|128|512|3072|7|9|4|LGA1150|DDR3|1600|0x0C01|0x06|3"
    "i5-4460|Core-i5-4460|Intel(R) Core(TM) i5-4460 CPU @ 3.20GHz|3200000000|BX80646I54460|3200|3400|205|0x2D|0xEC|4|1|256|1024|6144|7|9|4|LGA1150|DDR3|1600|0x0C01|0x06|3"
    "i5-4570|Core-i5-4570|Intel(R) Core(TM) i5-4570 CPU @ 3.20GHz|3200000000|SR14E|3200|3600|205|0x2D|0xEC|4|1|256|1024|6144|7|9|4|LGA1150|DDR3|1600|0x0C01|0x06|3"
    "i5-4590|Core-i5-4590|Intel(R) Core(TM) i5-4590 CPU @ 3.30GHz|3300000000|SR1QJ|3300|3700|205|0x2D|0xEC|4|1|256|1024|6144|7|9|4|LGA1150|DDR3|1600|0x0C01|0x06|3"
    "i7-4790|Core-i7-4790|Intel(R) Core(TM) i7-4790 CPU @ 3.60GHz|3600000000|BX80646I74790|3600|4000|198|0x2D|0xFC|4|2|256|1024|8192|7|9|4|LGA1150|DDR3|1600|0x0C01|0x06|3"
    "i5-6500|Core-i5-6500|Intel(R) Core(TM) i5-6500 CPU @ 3.20GHz|3200000000|SR2L6|3200|3600|205|0x32|0xEC|4|1|256|1024|6144|5|9|6|LGA1151|DDR4|2133|0x1901|0x07|3"
    "i3-8100|Core-i3-8100|Intel(R) Core(TM) i3-8100 CPU @ 3.60GHz|3600000000|SR3N5|3600|3600|206|0x32|0xEC|4|1|256|1024|6144|5|9|8|LGA1151-300|DDR4|2400|0x1901|0x07|3"
    "i7-3820|Core-i7-3820|Intel(R) Core(TM) i7-3820 CPU @ 3.60GHz|3600000000|BX80619I73820|3600|3800|198|0x26|0xFC|4|2|256|1024|10240|7|14|2|LGA2011|DDR3|1600|0x3C02|0x07|2"
    "i7-3930k|Core-i7-3930K|Intel(R) Core(TM) i7-3930K CPU @ 3.20GHz|3200000000|BX80619I73930K|3200|3800|198|0x26|0xFC|6|2|384|1536|12288|7|8|2|LGA2011|DDR3|1600|0x3C02|0x07|2"
    "i7-4820k|Core-i7-4820K|Intel(R) Core(TM) i7-4820K CPU @ 3.70GHz|3700000000|BX80633I74820K|3700|3900|198|0x26|0xFC|4|2|256|1024|10240|7|14|3|LGA2011|DDR3|1866|0x0E02|0x04|3"
    "i7-4930k|Core-i7-4930K|Intel(R) Core(TM) i7-4930K CPU @ 3.40GHz|3400000000|BX80633I74930K|3400|3900|198|0x26|0xFC|6|2|384|1536|12288|7|8|3|LGA2011|DDR3|1866|0x0E02|0x04|3"
    "i7-4960x|Core-i7-4960X|Intel(R) Core(TM) i7-4960X CPU @ 3.60GHz|3600000000|BX80633I74960X|3600|4000|198|0x26|0xFC|6|2|384|1536|15360|7|14|3|LGA2011|DDR3|1866|0x0E02|0x04|3"
)

# CPU-side host bridge inventory for the active X79 CPUs.  These identities
# pair with the 0x3C02/0x0E02 CPU PCIe root-port identities above; q35 remains
# the behavior model.  Archived mainstream CPUs intentionally keep q35's
# default P35 MCH until an equally narrow, reviewed mapping exists for them.
# cpu-profile|QEMU-presentation-key|PCI-vendor|PCI-device|PCI-revision
CPU_HOST_BRIDGE_PRESENTATION_PROFILES=(
    "i7-3820|SandyBridge-E|0x8086|0x3C00|0x07"
    "i7-3930k|SandyBridge-E|0x8086|0x3C00|0x07"
    "i7-4820k|IvyBridge-E|0x8086|0x0E00|0x04"
    "i7-4930k|IvyBridge-E|0x8086|0x0E00|0x04"
    "i7-4960x|IvyBridge-E|0x8086|0x0E00|0x04"
)

# Board fields:
# key|brand|model|revision|chipset|BIOS|BIOS-date|TPM|DIMM-slots|max-GiB|
# native-M.2-gen|native-M.2-lanes|xHCI-vendor|xHCI-device|xHCI-revision|main-slot|
# auxiliary-slot|aux-type|aux-width|aux-length|socket|memory-family|max-MT/s|
# release-year|serial-policy
#
# Official board specifications, manuals and BIOS pages:
#   https://www.asus.com/motherboards-components/motherboards/business/h81mk/techspec/
#   https://www.asus.com/supportonly/h81m-k/helpdesk_bios/
#   https://www.asus.com/uk/supportonly/h81m-c/helpdesk_bios/
#   https://dlcdnet.asus.com/pub/ASUS/mb/LGA1150/H81M-C/E8447_H81M-C.pdf
#   https://dlcdnets.asus.com/pub/ASUS/mb/LGA1150/H81M-PLUS/E8448_H81M-PLUS.pdf
#   https://www.asus.com/supportonly/h81m-plus/helpdesk_bios/
#   https://dlcdnet.asus.com/pub/ASUS/mb/LGA1150/H81M-A/E8445_H81M-Series.pdf
#   https://www.asus.com/supportonly/h81m-a/helpdesk_bios/
#   https://www.gigabyte.com/Motherboard/GA-H81M-S1-rev-21/sp
#   https://www.gigabyte.com/Motherboard/GA-H81M-S1-rev-21/support
#   https://www.gigabyte.com/Motherboard/GA-H81M-DS2-rev-30/sp
#   https://www.gigabyte.com/Motherboard/GA-H81M-DS2-rev-30/support
#   https://storage-asset.msi.com/datasheet/original/mb/global/H81M-P33.pdf
#   https://nl.msi.com/Motherboard/H81M-P33/support
#   https://www.msi.com/Motherboard/H81M-E33/Specification
#   https://www.msi.com/faq/1502
#   https://www.asrock.com/mb/Intel/H81M-HDS/
#   https://download.asrock.com/Manual/H81M-HDS.pdf
#   https://campaign.ecs.com.tw/ECSWebSite/Product/Product_SPEC/EN/Motherboard/H81H3-M4%20-LL-V1-DO-0A-RR-/Socket%201150
#   https://campaign.ecs.com.tw/support/8series_haswell/haswell_ready.html
#   https://www.gigabyte.com/Motherboard/GA-H97-D3H-rev-10/support
#   https://www.gigabyte.com/Motherboard/GA-B150M-D3H-rev-10/support
#   https://www.asus.com/supportonly/prime%20b360m-a/helpdesk_bios/
#   https://dlcdnets.asus.com/pub/ASUS/mb/LGA2011/P9X79/E8038_P9X79.pdf
#   https://www.asus.com/us/supportonly/p9x79/helpdesk_bios/
#   https://www.gigabyte.com/us/Motherboard/GA-X79-UP4-rev-10/sp
#   https://www.gigabyte.com/us/Motherboard/GA-X79-UP4-rev-10/support
#   https://www.asrock.com/mb/Intel/X79%20Extreme4/
#   https://download.asrock.com/Manual/X79%20Extreme4.pdf
BOARD_PROFILES=(
    "asus-h81m-k|ASUSTeK COMPUTER INC.|H81M-K|Rev X.0x|H81|3802|01/23/2024|none|2|16|0|0|0x8086|0x8C31|0x05|PCIEX16|PCIEX1_1|171|8|3|LGA1150|DDR3|1600|2013|asus"
    "asus-h81m-c|ASUSTeK COMPUTER INC.|H81M-C|Rev X.0x|H81|3602|04/14/2018|none|2|16|0|0|0x8086|0x8C31|0x05|PCIEX16|PCIEX1_1|171|8|3|LGA1150|DDR3|1600|2013|asus"
    "gigabyte-h81m-s1|Gigabyte|GA-H81M-S1|2.1|H81|FH|08/13/2015|none|2|16|0|0|0x8086|0x8C31|0x05|PCIEX16|PCIEX1_1|171|8|3|LGA1150|DDR3|1600|2015|gigabyte"
    "msi-h81m-p33|MSI|H81M-P33 (MS-7817)|1.0|H81|1.A|07/17/2018|none|2|16|0|0|0x8086|0x8C31|0x05|PCI_E2|PCI_E1|171|8|3|LGA1150|DDR3|1600|2013|msi"
    "gigabyte-h97-d3h|Gigabyte|GA-H97-D3H|1.0|H97|F7|09/19/2015|1.2|4|32|2|2|0x8086|0x8CB1|0x01|PCIEX16|PCIEX1_1|171|8|3|LGA1150|DDR3|1600|2014|gigabyte"
    "gigabyte-b150m-d3h|Gigabyte|GA-B150M-D3H|1.0|B150|F21|12/12/2016|2.0|4|64|3|4|0x8086|0xA12F|0x01|PCIEX16|PCIEX4|177|10|4|LGA1151|DDR4|2133|2015|gigabyte"
    "asus-prime-b360m-a|ASUS|PRIME B360M-A|1.xx|B360|3202|07/24/2021|2.0|4|64|3|4|0x8086|0xA36D|0x01|PCIEX16|PCIEX1_1|177|8|3|LGA1151-300|DDR4|2666|2018|asus"
    # Append-only historical tier: existing keys retain their stable order;
    # the normalization pass below archives every non-X79 creation row.
    "asus-h81m-plus|ASUSTeK COMPUTER INC.|H81M-PLUS|Rev X.0x|H81|2205|06/18/2015|none|2|16|0|0|0x8086|0x8C31|0x05|PCIEX16_1|PCIEX1_1|171|8|3|LGA1150|DDR3|1600|2013|asus"
    "asus-h81m-a|ASUSTeK COMPUTER INC.|H81M-A|Rev X.0x|H81|2203|06/18/2015|none|2|16|0|0|0x8086|0x8C31|0x05|PCIEX16|PCIEX1_1|171|8|3|LGA1150|DDR3|1600|2013|asus"
    "gigabyte-h81m-ds2|Gigabyte|GA-H81M-DS2|3.0|H81|F3|08/21/2020|none|2|16|0|0|0x8086|0x8C31|0x05|PCIEX16|PCIEX1|171|8|3|LGA1150|DDR3|1600|2014|gigabyte"
    "msi-h81m-e33|MSI|H81M-E33 (MS-7817)|1.0|H81|6.7|11/27/2015|none|2|16|0|0|0x8086|0x8C31|0x05|PCI_E2|PCI_E1|171|8|3|LGA1150|DDR3|1600|2013|msi"
    "asrock-h81m-hds|ASRock|H81M-HDS|1.0|H81|2.20|03/09/2016|none|2|16|0|0|0x8086|0x8C31|0x05|PCIE1|PCIE2|171|8|3|LGA1150|DDR3|1600|2013|asrock"
    "ecs-h81h3-m4|ECS|H81H3-M4|1.0A|H81|5.04.10|04/10/2015|none|2|16|0|0|0x8086|0x8C31|0x05|PCIEX16|PCIEX1|171|8|3|LGA1150|DDR3|1600|2013|ecs"
    # Consumer X79 boards.  None has native M.2; Gen3 NVMe is supplied only by
    # the separately audited passive-adapter path below and Ivy Bridge-E CPUs.
    "asus-p9x79|ASUSTeK COMPUTER INC.|P9X79|Rev 1.xx|X79|4701|06/23/2014|1.2|8|64|0|0|0x1B21|0x1042|0x00|PCIEX16_1|PCIEX1_1|171|8|3|LGA2011|DDR3|1866|2011|asus"
    "gigabyte-x79-up4|Gigabyte|GA-X79-UP4|1.0|X79|F7|03/20/2014|1.2|8|64|0|0|0x1B73|0x1009|0x02|PCIEX16_1|PCIEX1_1|171|8|3|LGA2011|DDR3|1866|2012|gigabyte"
    "asrock-x79-extreme4|ASRock|X79 Extreme4|1.0|X79|P3.20|07/22/2013|none|4|32|0|0|0x1B21|0x1042|0x00|PCIE1|PCIE2|171|8|3|LGA2011|DDR3|1600|2011|asrock"
)

# Guest-visible LPC identity for every chipset used by BOARD_PROFILES.
#
# The q35 machine still implements ICH9 LPC/ACPI/interrupt-routing behavior;
# only the PCI identity at 00:1f.0 is selected from this closed catalog.  This
# is deliberately narrower than generic PCI-ID override properties: changing
# ICH9 AHCI or qemu-xhci identities can make Windows load hardware-specific
# storage/USB quirks that the virtual controller does not implement.
#
# chipset|QEMU-presentation-key|PCI-vendor|PCI-device|PCI-revision
CHIPSET_PRESENTATION_PROFILES=(
    "H81|H81|0x8086|0x8C5C|0x04"
    "H97|H97|0x8086|0x8CC6|0x00"
    "B150|B150|0x8086|0xA148|0x31"
    "B360|B360|0x8086|0xA308|0x10"
    "X79|X79|0x8086|0x1D41|0x06"
)

# Memory fields:
# key|brand|part-list|speed-MT/s|family|SMBIOS-type|bus-width|
# module-MiB-list|populated-slots|form-factor|rank-list|DRAM-device-width-list|
# voltage-mV|channel-mode|module-JEP106-list|DRAM-JEP106-list
#
# Official module sources:
#   https://www.kingston.com/datasheets/KVR13N9S6_2.pdf
#   https://www.kingston.com/datasheets/KVR13N9S8_4.pdf
#   https://www.kingston.com/datasheets/KVR16N11S6_2.pdf
#   https://www.kingston.com/datasheets/KVR16N11S8_4.pdf
#   https://download.semiconductor.samsung.com/resources/data-sheet/237561ds_ddr3_2gb_d-die_based_udimm_rev14.pdf
#   https://download.semiconductor.samsung.com/resources/data-sheet/DS_DDR3_4Gb_Q_die_UDIMM_Rev10-0.pdf
#   https://www.micron.com/products/obsolete/obsolete-udimm/part-catalog
#   https://product.skhynix.com/products/dram/module/module_info.jsp
#   https://www.crucial.com/memory/ddr3/ct51264bd160b
#   https://www.intel.com/content/dam/doc/platform-memory/ddr3-1600-udimm-n-ecc-sandy-bridge.pdf
#   https://www.intel.com/content/dam/www/public/us/en/documents/platform-memory/ddr3-1866-udimm-n-ecc-ivybridge-e-validation-results.pdf
# JEP106 byte pairs follow the audited V-11 memory catalog.  0000 means that
# the module assembler does not promise one fixed DRAM die vendor.
MEMORY_PROFILES=(
    "kvr13n9s6-2x2|Kingston|KVR13N9S6/2,KVR13N9S6/2|1333|DDR3|0x18|64|2048,2048|2|DIMM|1,1|16,16|1500|dual-channel|0198,0198|0000,0000"
    "kvr13n9-flex-4plus2|Kingston|KVR13N9S8/4,KVR13N9S6/2|1333|DDR3|0x18|64|4096,2048|2|DIMM|1,1|8,16|1500|flex|0198,0198|0000,0000"
    "kvr13n9s8-2x4|Kingston|KVR13N9S8/4,KVR13N9S8/4|1333|DDR3|0x18|64|4096,4096|2|DIMM|1,1|8,8|1500|dual-channel|0198,0198|0000,0000"
    "kvr16n11s6-2x2|Kingston|KVR16N11S6/2,KVR16N11S6/2|1600|DDR3|0x18|64|2048,2048|2|DIMM|1,1|16,16|1500|dual-channel|0198,0198|0000,0000"
    "kvr16n11-flex-4plus2|Kingston|KVR16N11S8/4,KVR16N11S6/2|1600|DDR3|0x18|64|4096,2048|2|DIMM|1,1|8,16|1500|flex|0198,0198|0000,0000"
    "kvr16n11s8-2x4|Kingston|KVR16N11S8/4,KVR16N11S8/4|1600|DDR3|0x18|64|4096,4096|2|DIMM|1,1|8,8|1500|dual-channel|0198,0198|0000,0000"
    "samsung-m378b5773dh0-2x2|Samsung|M378B5773DH0-CK0,M378B5773DH0-CK0|1600|DDR3|0x18|64|2048,2048|2|DIMM|1,1|8,8|1500|dual-channel|80CE,80CE|80CE,80CE"
    "samsung-m378b5-flex-4plus2|Samsung|M378B5273DH0-CK0,M378B5773DH0-CK0|1600|DDR3|0x18|64|4096,2048|2|DIMM|2,1|8,8|1500|flex|80CE,80CE|80CE,80CE"
    "samsung-m378b5273dh0-2x4|Samsung|M378B5273DH0-CK0,M378B5273DH0-CK0|1600|DDR3|0x18|64|4096,4096|2|DIMM|2,2|8,8|1500|dual-channel|80CE,80CE|80CE,80CE"
    "micron-mt4jtf25664az-2x2|Micron|MT4JTF25664AZ-1G6,MT4JTF25664AZ-1G6|1600|DDR3|0x18|64|2048,2048|2|DIMM|1,1|16,16|1500|dual-channel|802C,802C|802C,802C"
    "micron-mtjtf-flex-4plus2|Micron|MT8JTF51264AZ-1G6,MT4JTF25664AZ-1G6|1600|DDR3|0x18|64|4096,2048|2|DIMM|1,1|8,16|1500|flex|802C,802C|802C,802C"
    "micron-mt8jtf51264az-2x4|Micron|MT8JTF51264AZ-1G6,MT8JTF51264AZ-1G6|1600|DDR3|0x18|64|4096,4096|2|DIMM|1,1|8,8|1500|dual-channel|802C,802C|802C,802C"
    "hynix-hmt325u6cfr8c-2x2|SK hynix|HMT325U6CFR8C-PB,HMT325U6CFR8C-PB|1600|DDR3|0x18|64|2048,2048|2|DIMM|1,1|8,8|1500|dual-channel|80AD,80AD|80AD,80AD"
    "hynix-hmt3x5-flex-4plus2|SK hynix|HMT351U6CFR8C-PB,HMT325U6CFR8C-PB|1600|DDR3|0x18|64|4096,2048|2|DIMM|2,1|8,8|1500|flex|80AD,80AD|80AD,80AD"
    "hynix-hmt351u6cfr8c-2x4|SK hynix|HMT351U6CFR8C-PB,HMT351U6CFR8C-PB|1600|DDR3|0x18|64|4096,4096|2|DIMM|2,2|8,8|1500|dual-channel|80AD,80AD|80AD,80AD"
    # Native DDR3-1333 bins for the other three active brands.  These are
    # distinct CH9/-1G4/-H9 parts, not 1600 profiles with a relabeled speed.
    "samsung-m378b5773dh0-1333-2x2|Samsung|M378B5773DH0-CH9,M378B5773DH0-CH9|1333|DDR3|0x18|64|2048,2048|2|DIMM|1,1|8,8|1500|dual-channel|80CE,80CE|80CE,80CE"
    "samsung-m378b5-1333-flex-4plus2|Samsung|M378B5273DH0-CH9,M378B5773DH0-CH9|1333|DDR3|0x18|64|4096,2048|2|DIMM|2,1|8,8|1500|flex|80CE,80CE|80CE,80CE"
    "samsung-m378b5273dh0-1333-2x4|Samsung|M378B5273DH0-CH9,M378B5273DH0-CH9|1333|DDR3|0x18|64|4096,4096|2|DIMM|2,2|8,8|1500|dual-channel|80CE,80CE|80CE,80CE"
    "micron-mt8jtf25664az-1333-2x2|Micron|MT8JTF25664AZ-1G4,MT8JTF25664AZ-1G4|1333|DDR3|0x18|64|2048,2048|2|DIMM|1,1|8,8|1500|dual-channel|802C,802C|802C,802C"
    "micron-mtjtf-1333-flex-4plus2|Micron|MT8JTF51264AZ-1G4,MT8JTF25664AZ-1G4|1333|DDR3|0x18|64|4096,2048|2|DIMM|1,1|8,8|1500|flex|802C,802C|802C,802C"
    "micron-mt8jtf51264az-1333-2x4|Micron|MT8JTF51264AZ-1G4,MT8JTF51264AZ-1G4|1333|DDR3|0x18|64|4096,4096|2|DIMM|1,1|8,8|1500|dual-channel|802C,802C|802C,802C"
    "hynix-hmt325u6cfr8c-1333-2x2|SK hynix|HMT325U6CFR8C-H9,HMT325U6CFR8C-H9|1333|DDR3|0x18|64|2048,2048|2|DIMM|1,1|8,8|1500|dual-channel|80AD,80AD|80AD,80AD"
    "hynix-hmt3x5-1333-flex-4plus2|SK hynix|HMT351U6CFR8C-H9,HMT325U6CFR8C-H9|1333|DDR3|0x18|64|4096,2048|2|DIMM|2,1|8,8|1500|flex|80AD,80AD|80AD,80AD"
    "hynix-hmt351u6cfr8c-1333-2x4|SK hynix|HMT351U6CFR8C-H9,HMT351U6CFR8C-H9|1333|DDR3|0x18|64|4096,4096|2|DIMM|2,2|8,8|1500|dual-channel|80AD,80AD|80AD,80AD"
    # Four consumer/non-ECC UDIMM models for the LGA2011 expansion.  Three
    # populated 4 GiB modules are honestly exposed as triple-channel/12 GiB;
    # four matching modules are quad-channel/16 GiB.  The 1866 parts are from
    # Intel's Ivy Bridge-E non-ECC validation list, not relabeled 1600 bins.
    "kvr16n11s8-3x4|Kingston|KVR16N11S8/4,KVR16N11S8/4,KVR16N11S8/4|1600|DDR3|0x18|64|4096,4096,4096|3|DIMM|1,1,1|8,8,8|1500|triple-channel|0198,0198,0198|0000,0000,0000"
    "kvr16n11s8-4x4|Kingston|KVR16N11S8/4,KVR16N11S8/4,KVR16N11S8/4,KVR16N11S8/4|1600|DDR3|0x18|64|4096,4096,4096,4096|4|DIMM|1,1,1,1|8,8,8,8|1500|quad-channel|0198,0198,0198,0198|0000,0000,0000,0000"
    "samsung-m378b5273dh0-3x4|Samsung|M378B5273DH0-CK0,M378B5273DH0-CK0,M378B5273DH0-CK0|1600|DDR3|0x18|64|4096,4096,4096|3|DIMM|2,2,2|8,8,8|1500|triple-channel|80CE,80CE,80CE|80CE,80CE,80CE"
    "samsung-m378b5273dh0-4x4|Samsung|M378B5273DH0-CK0,M378B5273DH0-CK0,M378B5273DH0-CK0,M378B5273DH0-CK0|1600|DDR3|0x18|64|4096,4096,4096,4096|4|DIMM|2,2,2,2|8,8,8,8|1500|quad-channel|80CE,80CE,80CE,80CE|80CE,80CE,80CE,80CE"
    "micron-mt8jtf51264az-3x4|Micron|MT8JTF51264AZ-1G6,MT8JTF51264AZ-1G6,MT8JTF51264AZ-1G6|1600|DDR3|0x18|64|4096,4096,4096|3|DIMM|1,1,1|8,8,8|1500|triple-channel|802C,802C,802C|802C,802C,802C"
    "micron-mt8jtf51264az-4x4|Micron|MT8JTF51264AZ-1G6,MT8JTF51264AZ-1G6,MT8JTF51264AZ-1G6,MT8JTF51264AZ-1G6|1600|DDR3|0x18|64|4096,4096,4096,4096|4|DIMM|1,1,1,1|8,8,8,8|1500|quad-channel|802C,802C,802C,802C|802C,802C,802C,802C"
    "hynix-hmt351u6cfr8c-3x4|SK hynix|HMT351U6CFR8C-PB,HMT351U6CFR8C-PB,HMT351U6CFR8C-PB|1600|DDR3|0x18|64|4096,4096,4096|3|DIMM|2,2,2|8,8,8|1500|triple-channel|80AD,80AD,80AD|80AD,80AD,80AD"
    "hynix-hmt351u6cfr8c-4x4|SK hynix|HMT351U6CFR8C-PB,HMT351U6CFR8C-PB,HMT351U6CFR8C-PB,HMT351U6CFR8C-PB|1600|DDR3|0x18|64|4096,4096,4096,4096|4|DIMM|2,2,2,2|8,8,8,8|1500|quad-channel|80AD,80AD,80AD,80AD|80AD,80AD,80AD,80AD"
    "elpida-ebj40ug8bfw0-2x4|Elpida|EBJ40UG8BFW0-JS-F,EBJ40UG8BFW0-JS-F|1866|DDR3|0x18|64|4096,4096|2|DIMM|1,1|8,8|1500|dual-channel|02FE,02FE|02FE,02FE"
    "elpida-ebj40ug8bfw0-3x4|Elpida|EBJ40UG8BFW0-JS-F,EBJ40UG8BFW0-JS-F,EBJ40UG8BFW0-JS-F|1866|DDR3|0x18|64|4096,4096,4096|3|DIMM|1,1,1|8,8,8|1500|triple-channel|02FE,02FE,02FE|02FE,02FE,02FE"
    "elpida-ebj40ug8bfw0-4x4|Elpida|EBJ40UG8BFW0-JS-F,EBJ40UG8BFW0-JS-F,EBJ40UG8BFW0-JS-F,EBJ40UG8BFW0-JS-F|1866|DDR3|0x18|64|4096,4096,4096,4096|4|DIMM|1,1,1,1|8,8,8,8|1500|quad-channel|02FE,02FE,02FE,02FE|02FE,02FE,02FE,02FE"
    "micron-mt8ktf51264az-2x4|Micron|MT8KTF51264AZ-1G9,MT8KTF51264AZ-1G9|1866|DDR3|0x18|64|4096,4096|2|DIMM|1,1|8,8|1500|dual-channel|802C,802C|802C,802C"
    "micron-mt8ktf51264az-3x4|Micron|MT8KTF51264AZ-1G9,MT8KTF51264AZ-1G9,MT8KTF51264AZ-1G9|1866|DDR3|0x18|64|4096,4096,4096|3|DIMM|1,1,1|8,8,8|1500|triple-channel|802C,802C,802C|802C,802C,802C"
    "micron-mt8ktf51264az-4x4|Micron|MT8KTF51264AZ-1G9,MT8KTF51264AZ-1G9,MT8KTF51264AZ-1G9,MT8KTF51264AZ-1G9|1866|DDR3|0x18|64|4096,4096,4096,4096|4|DIMM|1,1,1,1|8,8,8,8|1500|quad-channel|802C,802C,802C,802C|802C,802C,802C,802C"
    # Samsung original JEDEC DDR3-1866 UDIMMs for the unified Ivy Bridge-E pool.
    # The 2 GiB CMA module is 1Rx8, allowing the minimum 4 GiB option to keep
    # the requested 1866 MT/s identity instead of silently down-binning.
    "samsung-m378b5773dh0-1866-2x2|Samsung|M378B5773DH0-CMA,M378B5773DH0-CMA|1866|DDR3|0x18|64|2048,2048|2|DIMM|1,1|8,8|1500|dual-channel|80CE,80CE|80CE,80CE"
    "samsung-m378b5173qh0-1866-2x4|Samsung|M378B5173QH0-CMA,M378B5173QH0-CMA|1866|DDR3|0x18|64|4096,4096|2|DIMM|1,1|8,8|1500|dual-channel|80CE,80CE|80CE,80CE"
    "samsung-m378b5173qh0-1866-3x4|Samsung|M378B5173QH0-CMA,M378B5173QH0-CMA,M378B5173QH0-CMA|1866|DDR3|0x18|64|4096,4096,4096|3|DIMM|1,1,1|8,8,8|1500|triple-channel|80CE,80CE,80CE|80CE,80CE,80CE"
    "samsung-m378b5173qh0-1866-4x4|Samsung|M378B5173QH0-CMA,M378B5173QH0-CMA,M378B5173QH0-CMA,M378B5173QH0-CMA|1866|DDR3|0x18|64|4096,4096,4096,4096|4|DIMM|1,1,1,1|8,8,8,8|1500|quad-channel|80CE,80CE,80CE,80CE|80CE,80CE,80CE,80CE"
    "kvr21n15s8-2x4|Kingston|KVR21N15S8/4,KVR21N15S8/4|2133|DDR4|0x1A|64|4096,4096|2|DIMM|1,1|8,8|1200|dual-channel|0198,0198|0000,0000"
    "kvr24n17s8-2x4|Kingston|KVR24N17S8/4,KVR24N17S8/4|2400|DDR4|0x1A|64|4096,4096|2|DIMM|1,1|8,8|1200|dual-channel|0198,0198|0000,0000"
    # Crucial is Micron's module brand; 802C is retained for both the module
    # assembler and DRAM maker.  H81 runs this dual-voltage DDR3L kit at 1.5 V.
    "crucial-ct51264bd160b-2x4|Crucial|CT51264BD160B,CT51264BD160B|1600|DDR3|0x18|64|4096,4096|2|DIMM|1,1|8,8|1500|dual-channel|802C,802C|802C,802C"
)

# platform|CPU-key|board-key|memory-key|lifecycle
# lifecycle=new participates in the normal performance-first pool; explicit-new
# is a reviewed manual tier; archived is existing-VM-only; legacy-compatibility
# is existing-VM/last-resort fallback only.  Historical literal lifecycle values
# below are normalized by _hardware_profile_archive_retired_combinations.
HARDWARE_COMBINATIONS=(
    "g3220-h81m-k-4g|g3220|asus-h81m-k|kvr13n9s6-2x2|new"
    "g3220-h81m-c-6g|g3220|asus-h81m-c|kvr13n9-flex-4plus2|new"
    "g3220-h81m-s1-8g|g3220|gigabyte-h81m-s1|kvr13n9s8-2x4|new"
    "i3-4130-h81m-c-4g|i3-4130|asus-h81m-c|kvr16n11s6-2x2|new"
    "i3-4130-h81m-s1-6g|i3-4130|gigabyte-h81m-s1|kvr16n11-flex-4plus2|new"
    "i3-4130-h81m-p33-8g|i3-4130|msi-h81m-p33|kvr16n11s8-2x4|new"
    "i5-4460-h81m-s1-4g|i5-4460|gigabyte-h81m-s1|kvr16n11s6-2x2|new"
    "i5-4460-h81m-p33-6g|i5-4460|msi-h81m-p33|kvr16n11-flex-4plus2|new"
    "i5-4460-h81m-k-8g|i5-4460|asus-h81m-k|kvr16n11s8-2x4|new"
    "i5-4570-h81m-p33-4g|i5-4570|msi-h81m-p33|kvr16n11s6-2x2|new"
    "i5-4570-h81m-k-6g|i5-4570|asus-h81m-k|kvr16n11-flex-4plus2|new"
    "i5-4570-h81m-c-8g|i5-4570|asus-h81m-c|kvr16n11s8-2x4|new"
    "i5-4590-h81m-k-4g|i5-4590|asus-h81m-k|kvr16n11s6-2x2|new"
    "i5-4590-h81m-c-6g|i5-4590|asus-h81m-c|kvr16n11-flex-4plus2|new"
    "i5-4590-h81m-s1-8g|i5-4590|gigabyte-h81m-s1|kvr16n11s8-2x4|new"
    "i3-4130-h81m-k-samsung-4g|i3-4130|asus-h81m-k|samsung-m378b5773dh0-2x2|new"
    "i3-4130-h81m-s1-samsung-6g|i3-4130|gigabyte-h81m-s1|samsung-m378b5-flex-4plus2|new"
    "i3-4130-h81m-p33-samsung-8g|i3-4130|msi-h81m-p33|samsung-m378b5273dh0-2x4|new"
    "i5-4460-h81m-c-micron-4g|i5-4460|asus-h81m-c|micron-mt4jtf25664az-2x2|new"
    "i5-4460-h81m-s1-micron-6g|i5-4460|gigabyte-h81m-s1|micron-mtjtf-flex-4plus2|new"
    "i5-4460-h81m-p33-micron-8g|i5-4460|msi-h81m-p33|micron-mt8jtf51264az-2x4|new"
    "i5-4570-h81m-k-hynix-4g|i5-4570|asus-h81m-k|hynix-hmt325u6cfr8c-2x2|new"
    "i5-4570-h81m-c-hynix-6g|i5-4570|asus-h81m-c|hynix-hmt3x5-flex-4plus2|new"
    "i5-4570-h81m-s1-hynix-8g|i5-4570|gigabyte-h81m-s1|hynix-hmt351u6cfr8c-2x4|new"
    "i7-4790-h81m-p33-8g|i7-4790|msi-h81m-p33|kvr16n11s8-2x4|explicit-new"
    "i5-4590|i5-4590|gigabyte-h97-d3h|kvr16n11s8-2x4|legacy-compatibility"
    "i5-6500|i5-6500|gigabyte-b150m-d3h|kvr21n15s8-2x4|legacy-compatibility"
    "i3-8100|i3-8100|asus-prime-b360m-a|kvr24n17s8-2x4|legacy-compatibility"
    # Append-only historical combinations.  Their stable IDs remain loadable,
    # but the normalization pass below removes them from all new-VM choices.
    "i3-4130-h81m-plus-crucial-8g|i3-4130|asus-h81m-plus|crucial-ct51264bd160b-2x4|explicit-new"
    "i5-4590-h81m-plus-6g|i5-4590|asus-h81m-plus|kvr16n11-flex-4plus2|explicit-new"
    "i3-4130-h81m-a-4g|i3-4130|asus-h81m-a|kvr16n11s6-2x2|explicit-new"
    "i3-4130-h81m-ds2-6g|i3-4130|gigabyte-h81m-ds2|kvr16n11-flex-4plus2|explicit-new"
    "i3-4130-h81m-e33-8g|i3-4130|msi-h81m-e33|kvr16n11s8-2x4|explicit-new"
    # Complete 4G/6G/8G choices on every i3-4130 board while retaining the
    # selected board.  Symmetric 4G/8G rows are dual-channel; 6G is reviewed
    # 4+2 GiB Flex.  Existing brands are completed where profiles already
    # exist, so a capacity change normally preserves both brand and speed.
    "i3-4130-h81m-c-6g|i3-4130|asus-h81m-c|kvr16n11-flex-4plus2|explicit-new"
    "i3-4130-h81m-c-8g|i3-4130|asus-h81m-c|kvr16n11s8-2x4|explicit-new"
    "i3-4130-h81m-s1-4g|i3-4130|gigabyte-h81m-s1|kvr16n11s6-2x2|explicit-new"
    "i3-4130-h81m-s1-8g|i3-4130|gigabyte-h81m-s1|kvr16n11s8-2x4|explicit-new"
    "i3-4130-h81m-s1-samsung-4g|i3-4130|gigabyte-h81m-s1|samsung-m378b5773dh0-2x2|explicit-new"
    "i3-4130-h81m-s1-samsung-8g|i3-4130|gigabyte-h81m-s1|samsung-m378b5273dh0-2x4|explicit-new"
    "i3-4130-h81m-p33-4g|i3-4130|msi-h81m-p33|kvr16n11s6-2x2|explicit-new"
    "i3-4130-h81m-p33-6g|i3-4130|msi-h81m-p33|kvr16n11-flex-4plus2|explicit-new"
    "i3-4130-h81m-p33-samsung-4g|i3-4130|msi-h81m-p33|samsung-m378b5773dh0-2x2|explicit-new"
    "i3-4130-h81m-p33-samsung-6g|i3-4130|msi-h81m-p33|samsung-m378b5-flex-4plus2|explicit-new"
    "i3-4130-h81m-k-samsung-6g|i3-4130|asus-h81m-k|samsung-m378b5-flex-4plus2|explicit-new"
    "i3-4130-h81m-k-samsung-8g|i3-4130|asus-h81m-k|samsung-m378b5273dh0-2x4|explicit-new"
    "i3-4130-h81m-plus-4g|i3-4130|asus-h81m-plus|kvr16n11s6-2x2|explicit-new"
    "i3-4130-h81m-plus-6g|i3-4130|asus-h81m-plus|kvr16n11-flex-4plus2|explicit-new"
    "i3-4130-h81m-plus-8g|i3-4130|asus-h81m-plus|kvr16n11s8-2x4|explicit-new"
    "i3-4130-h81m-a-6g|i3-4130|asus-h81m-a|kvr16n11-flex-4plus2|explicit-new"
    "i3-4130-h81m-a-8g|i3-4130|asus-h81m-a|kvr16n11s8-2x4|explicit-new"
    "i3-4130-h81m-ds2-4g|i3-4130|gigabyte-h81m-ds2|kvr16n11s6-2x2|explicit-new"
    "i3-4130-h81m-ds2-8g|i3-4130|gigabyte-h81m-ds2|kvr16n11s8-2x4|explicit-new"
    "i3-4130-h81m-e33-4g|i3-4130|msi-h81m-e33|kvr16n11s6-2x2|explicit-new"
    "i3-4130-h81m-e33-6g|i3-4130|msi-h81m-e33|kvr16n11-flex-4plus2|explicit-new"
    "i3-4130-h81m-hds-4g|i3-4130|asrock-h81m-hds|kvr16n11s6-2x2|explicit-new"
    "i3-4130-h81m-hds-6g|i3-4130|asrock-h81m-hds|kvr16n11-flex-4plus2|explicit-new"
    "i3-4130-h81m-hds-8g|i3-4130|asrock-h81m-hds|kvr16n11s8-2x4|explicit-new"
    "i3-4130-h81h3-m4-samsung-4g|i3-4130|ecs-h81h3-m4|samsung-m378b5773dh0-2x2|explicit-new"
    "i3-4130-h81h3-m4-samsung-6g|i3-4130|ecs-h81h3-m4|samsung-m378b5-flex-4plus2|explicit-new"
    "i3-4130-h81h3-m4-samsung-8g|i3-4130|ecs-h81h3-m4|samsung-m378b5273dh0-2x4|explicit-new"
    # LGA2011 consumer expansion.  Higher-frequency i7-4820K + DDR3-1866
    # combinations come first so no-argument creation can prefer them after
    # the host realization probe.  X79 Extreme4 is limited to its official
    # DDR3-1600 ceiling; i7-3820 is likewise limited to DDR3-1600.
    "i7-4820k-p9x79-elpida-12g|i7-4820k|asus-p9x79|elpida-ebj40ug8bfw0-3x4|new"
    "i7-4820k-p9x79-elpida-16g|i7-4820k|asus-p9x79|elpida-ebj40ug8bfw0-4x4|new"
    "i7-4820k-p9x79-micron-12g|i7-4820k|asus-p9x79|micron-mt8ktf51264az-3x4|new"
    "i7-4820k-p9x79-micron-16g|i7-4820k|asus-p9x79|micron-mt8ktf51264az-4x4|new"
    "i7-4820k-x79-up4-elpida-12g|i7-4820k|gigabyte-x79-up4|elpida-ebj40ug8bfw0-3x4|new"
    "i7-4820k-x79-up4-elpida-16g|i7-4820k|gigabyte-x79-up4|elpida-ebj40ug8bfw0-4x4|new"
    "i7-4820k-x79-up4-micron-12g|i7-4820k|gigabyte-x79-up4|micron-mt8ktf51264az-3x4|new"
    "i7-4820k-x79-up4-micron-16g|i7-4820k|gigabyte-x79-up4|micron-mt8ktf51264az-4x4|new"
    "i7-4820k-x79-extreme4-kingston-12g|i7-4820k|asrock-x79-extreme4|kvr16n11s8-3x4|new"
    "i7-4820k-x79-extreme4-kingston-16g|i7-4820k|asrock-x79-extreme4|kvr16n11s8-4x4|new"
    "i7-4820k-x79-extreme4-samsung-12g|i7-4820k|asrock-x79-extreme4|samsung-m378b5273dh0-3x4|new"
    "i7-4820k-x79-extreme4-samsung-16g|i7-4820k|asrock-x79-extreme4|samsung-m378b5273dh0-4x4|new"
    "i7-3820-p9x79-kingston-12g|i7-3820|asus-p9x79|kvr16n11s8-3x4|new"
    "i7-3820-p9x79-kingston-16g|i7-3820|asus-p9x79|kvr16n11s8-4x4|new"
    "i7-3820-p9x79-samsung-12g|i7-3820|asus-p9x79|samsung-m378b5273dh0-3x4|new"
    "i7-3820-p9x79-samsung-16g|i7-3820|asus-p9x79|samsung-m378b5273dh0-4x4|new"
    "i7-3820-x79-up4-kingston-12g|i7-3820|gigabyte-x79-up4|kvr16n11s8-3x4|new"
    "i7-3820-x79-up4-kingston-16g|i7-3820|gigabyte-x79-up4|kvr16n11s8-4x4|new"
    "i7-3820-x79-up4-samsung-12g|i7-3820|gigabyte-x79-up4|samsung-m378b5273dh0-3x4|new"
    "i7-3820-x79-up4-samsung-16g|i7-3820|gigabyte-x79-up4|samsung-m378b5273dh0-4x4|new"
    "i7-3820-x79-extreme4-kingston-12g|i7-3820|asrock-x79-extreme4|kvr16n11s8-3x4|new"
    "i7-3820-x79-extreme4-kingston-16g|i7-3820|asrock-x79-extreme4|kvr16n11s8-4x4|new"
    "i7-3820-x79-extreme4-samsung-12g|i7-3820|asrock-x79-extreme4|samsung-m378b5273dh0-3x4|new"
    "i7-3820-x79-extreme4-samsung-16g|i7-3820|asrock-x79-extreme4|samsung-m378b5273dh0-4x4|new"
    # The same three quad-capable boards cover the low capacities honestly:
    # two installed DIMMs use two channels; no empty channel is reported as
    # active.  i7-4820K receives validated DDR3-1866 8G pairs, while 4G uses
    # real 2G DDR3-1600 parts because the reviewed 1866 models are 4G modules.
    "i7-4820k-p9x79-kingston-4g|i7-4820k|asus-p9x79|kvr16n11s6-2x2|new"
    "i7-4820k-p9x79-samsung-4g|i7-4820k|asus-p9x79|samsung-m378b5773dh0-2x2|new"
    "i7-4820k-p9x79-elpida-8g|i7-4820k|asus-p9x79|elpida-ebj40ug8bfw0-2x4|new"
    "i7-4820k-p9x79-micron-8g|i7-4820k|asus-p9x79|micron-mt8ktf51264az-2x4|new"
    "i7-4820k-x79-up4-kingston-4g|i7-4820k|gigabyte-x79-up4|kvr16n11s6-2x2|new"
    "i7-4820k-x79-up4-samsung-4g|i7-4820k|gigabyte-x79-up4|samsung-m378b5773dh0-2x2|new"
    "i7-4820k-x79-up4-elpida-8g|i7-4820k|gigabyte-x79-up4|elpida-ebj40ug8bfw0-2x4|new"
    "i7-4820k-x79-up4-micron-8g|i7-4820k|gigabyte-x79-up4|micron-mt8ktf51264az-2x4|new"
    "i7-4820k-x79-extreme4-kingston-4g|i7-4820k|asrock-x79-extreme4|kvr16n11s6-2x2|new"
    "i7-4820k-x79-extreme4-samsung-4g|i7-4820k|asrock-x79-extreme4|samsung-m378b5773dh0-2x2|new"
    "i7-4820k-x79-extreme4-kingston-8g|i7-4820k|asrock-x79-extreme4|kvr16n11s8-2x4|new"
    "i7-4820k-x79-extreme4-samsung-8g|i7-4820k|asrock-x79-extreme4|samsung-m378b5273dh0-2x4|new"
    "i7-3820-p9x79-kingston-4g|i7-3820|asus-p9x79|kvr16n11s6-2x2|new"
    "i7-3820-p9x79-kingston-8g|i7-3820|asus-p9x79|kvr16n11s8-2x4|new"
    "i7-3820-p9x79-samsung-4g|i7-3820|asus-p9x79|samsung-m378b5773dh0-2x2|new"
    "i7-3820-p9x79-samsung-8g|i7-3820|asus-p9x79|samsung-m378b5273dh0-2x4|new"
    "i7-3820-x79-up4-kingston-4g|i7-3820|gigabyte-x79-up4|kvr16n11s6-2x2|new"
    "i7-3820-x79-up4-kingston-8g|i7-3820|gigabyte-x79-up4|kvr16n11s8-2x4|new"
    "i7-3820-x79-up4-samsung-4g|i7-3820|gigabyte-x79-up4|samsung-m378b5773dh0-2x2|new"
    "i7-3820-x79-up4-samsung-8g|i7-3820|gigabyte-x79-up4|samsung-m378b5273dh0-2x4|new"
    "i7-3820-x79-extreme4-kingston-4g|i7-3820|asrock-x79-extreme4|kvr16n11s6-2x2|new"
    "i7-3820-x79-extreme4-kingston-8g|i7-3820|asrock-x79-extreme4|kvr16n11s8-2x4|new"
    "i7-3820-x79-extreme4-samsung-4g|i7-3820|asrock-x79-extreme4|samsung-m378b5773dh0-2x2|new"
    "i7-3820-x79-extreme4-samsung-8g|i7-3820|asrock-x79-extreme4|samsung-m378b5273dh0-2x4|new"
)

# i3-4130 exposes the same reviewed two-DIMM memory matrix on every active H81
# board.  Existing rows retain their stable IDs/lifecycle; only missing
# CPU/board/memory triples are appended as explicit-new.  This keeps the
# no-argument random pool backward-stable while making the three UI attributes
# genuinely independent across unlocked boards.
I3_4130_REVIEWED_BOARD_MATRIX=(
    "asus-h81m-k|h81m-k"
    "asus-h81m-c|h81m-c"
    "gigabyte-h81m-s1|h81m-s1"
    "msi-h81m-p33|h81m-p33"
    "asus-h81m-plus|h81m-plus"
    "asus-h81m-a|h81m-a"
    "gigabyte-h81m-ds2|h81m-ds2"
    "msi-h81m-e33|h81m-e33"
    "asrock-h81m-hds|h81m-hds"
    "ecs-h81h3-m4|h81h3-m4"
)
I3_4130_REVIEWED_MEMORY_MATRIX=(
    "kvr13n9s6-2x2|kingston-1333-4g"
    "kvr13n9-flex-4plus2|kingston-1333-6g"
    "kvr13n9s8-2x4|kingston-1333-8g"
    "kvr16n11s6-2x2|kingston-1600-4g"
    "kvr16n11-flex-4plus2|kingston-1600-6g"
    "kvr16n11s8-2x4|kingston-1600-8g"
    "samsung-m378b5773dh0-2x2|samsung-1600-4g"
    "samsung-m378b5-flex-4plus2|samsung-1600-6g"
    "samsung-m378b5273dh0-2x4|samsung-1600-8g"
    "micron-mt4jtf25664az-2x2|micron-1600-4g"
    "micron-mtjtf-flex-4plus2|micron-1600-6g"
    "micron-mt8jtf51264az-2x4|micron-1600-8g"
    "hynix-hmt325u6cfr8c-2x2|hynix-1600-4g"
    "hynix-hmt3x5-flex-4plus2|hynix-1600-6g"
    "hynix-hmt351u6cfr8c-2x4|hynix-1600-8g"
    "samsung-m378b5773dh0-1333-2x2|samsung-1333-4g"
    "samsung-m378b5-1333-flex-4plus2|samsung-1333-6g"
    "samsung-m378b5273dh0-1333-2x4|samsung-1333-8g"
    "micron-mt8jtf25664az-1333-2x2|micron-1333-4g"
    "micron-mtjtf-1333-flex-4plus2|micron-1333-6g"
    "micron-mt8jtf51264az-1333-2x4|micron-1333-8g"
    "hynix-hmt325u6cfr8c-1333-2x2|hynix-1333-4g"
    "hynix-hmt3x5-1333-flex-4plus2|hynix-1333-6g"
    "hynix-hmt351u6cfr8c-1333-2x4|hynix-1333-8g"
)

_hardware_profile_append_i3_4130_memory_matrix() {
    local row platform cpu board memory lifecycle board_row board_alias
    local memory_row memory_alias key triple
    local -A seen_triples=() seen_keys=()

    for row in "${HARDWARE_COMBINATIONS[@]}"; do
        IFS='|' read -r platform cpu board memory lifecycle <<<"$row"
        seen_keys["$platform"]=1
        seen_triples["$cpu|$board|$memory"]=1
    done
    for board_row in "${I3_4130_REVIEWED_BOARD_MATRIX[@]}"; do
        IFS='|' read -r board board_alias <<<"$board_row"
        for memory_row in "${I3_4130_REVIEWED_MEMORY_MATRIX[@]}"; do
            IFS='|' read -r memory memory_alias <<<"$memory_row"
            triple="i3-4130|$board|$memory"
            [[ ! -v "seen_triples[$triple]" ]] || continue
            key="i3-4130-$board_alias-$memory_alias"
            [[ ! -v "seen_keys[$key]" ]] || {
                echo "i3-4130 审核矩阵生成了重复平台 ID: $key" >&2
                return 1
            }
            HARDWARE_COMBINATIONS+=("$key|$triple|explicit-new")
            seen_keys["$key"]=1
            seen_triples["$triple"]=1
        done
    done
}

_hardware_profile_append_i3_4130_memory_matrix

# The unified home-desktop X79 pool contains only retail 4C/8T and 6C/12T
# Core i7 parts.  Every CPU is paired with all three board brands and four or
# five major memory brands at every 4/8/12/16 GiB capacity.  Effective speed
# is the lower of the CPU and board ceilings: Ivy Bridge-E prefers native
# DDR3-1866 on ASUS/Gigabyte, while Sandy Bridge-E and ASRock's non-OC path
# retain honest DDR3-1600 identities.
X79_CONSUMER_CPU_KEYS=(
    i7-3820
    i7-3930k
    i7-4820k
    i7-4930k
    i7-4960x
)
X79_REVIEWED_BOARD_MATRIX=(
    "asus-p9x79|p9x79|1866"
    "gigabyte-x79-up4|x79-up4|1866"
    "asrock-x79-extreme4|x79-extreme4|1600"
)
X79_REVIEWED_MEMORY_MATRIX=(
    "samsung-m378b5773dh0-1866-2x2|samsung-4g|1866"
    "samsung-m378b5173qh0-1866-2x4|samsung-8g|1866"
    "samsung-m378b5173qh0-1866-3x4|samsung-12g|1866"
    "samsung-m378b5173qh0-1866-4x4|samsung-16g|1866"
    "samsung-m378b5773dh0-2x2|samsung-4g|1600"
    "samsung-m378b5273dh0-2x4|samsung-8g|1600"
    "samsung-m378b5273dh0-3x4|samsung-12g|1600"
    "samsung-m378b5273dh0-4x4|samsung-16g|1600"
    "micron-mt4jtf25664az-2x2|micron-4g|all"
    "micron-mt8ktf51264az-2x4|micron-8g|1866"
    "micron-mt8ktf51264az-3x4|micron-12g|1866"
    "micron-mt8ktf51264az-4x4|micron-16g|1866"
    "micron-mt8jtf51264az-2x4|micron-8g|1600"
    "micron-mt8jtf51264az-3x4|micron-12g|1600"
    "micron-mt8jtf51264az-4x4|micron-16g|1600"
    "elpida-ebj40ug8bfw0-2x4|elpida-8g|1866"
    "elpida-ebj40ug8bfw0-3x4|elpida-12g|1866"
    "elpida-ebj40ug8bfw0-4x4|elpida-16g|1866"
    "kvr16n11s6-2x2|kingston-4g|all"
    "kvr16n11s8-2x4|kingston-8g|all"
    "kvr16n11s8-3x4|kingston-12g|all"
    "kvr16n11s8-4x4|kingston-16g|all"
    "hynix-hmt325u6cfr8c-2x2|hynix-4g|all"
    "hynix-hmt351u6cfr8c-2x4|hynix-8g|all"
    "hynix-hmt351u6cfr8c-3x4|hynix-12g|all"
    "hynix-hmt351u6cfr8c-4x4|hynix-16g|all"
)

_hardware_profile_append_x79_consumer_pool() {
    local row platform cpu board memory lifecycle cpu_row cpu_speed
    local board_row board_alias board_speed effective_speed
    local memory_row memory_alias scope key triple
    local -A seen_triples=() seen_keys=()
    local -a cpu_fields=()

    for row in "${HARDWARE_COMBINATIONS[@]}"; do
        IFS='|' read -r platform cpu board memory lifecycle <<<"$row"
        seen_keys["$platform"]=1
        seen_triples["$cpu|$board|$memory"]=1
    done
    for cpu in "${X79_CONSUMER_CPU_KEYS[@]}"; do
        cpu_speed=
        for cpu_row in "${CPU_PROFILES[@]}"; do
            [[ "${cpu_row%%|*}" == "$cpu" ]] || continue
            IFS='|' read -r -a cpu_fields <<<"$cpu_row"
            cpu_speed=${cpu_fields[20]}
            break
        done
        [[ "$cpu_speed" =~ ^[1-9][0-9]*$ ]] || {
            echo "X79 家用 CPU 缺少内存频率上限: $cpu" >&2
            return 1
        }
        for board_row in "${X79_REVIEWED_BOARD_MATRIX[@]}"; do
            IFS='|' read -r board board_alias board_speed <<<"$board_row"
            effective_speed=$cpu_speed
            (( board_speed >= effective_speed )) || effective_speed=$board_speed
            for memory_row in "${X79_REVIEWED_MEMORY_MATRIX[@]}"; do
                IFS='|' read -r memory memory_alias scope <<<"$memory_row"
                case "$scope:$effective_speed" in
                    all:*|1866:1866|1600:1600) ;;
                    *) continue ;;
                esac
                triple="$cpu|$board|$memory"
                [[ ! -v "seen_triples[$triple]" ]] || continue
                key="$cpu-$board_alias-$memory_alias"
                if [[ -v "seen_keys[$key]" ]]; then
                    # A historical 1600 row may already own the stable
                    # unsuffixed key while the expanded Ivy Bridge-E pool
                    # adds the native 1866 DIMM with the same brand/capacity.
                    key+="-$scope"
                fi
                [[ ! -v "seen_keys[$key]" ]] || {
                    echo "X79 家用 CPU 审核矩阵生成了重复平台 ID: $key" >&2
                    return 1
                }
                HARDWARE_COMBINATIONS+=("$key|$triple|new")
                seen_keys["$key"]=1
                seen_triples["$triple"]=1
            done
        done
    done
}

_hardware_profile_append_x79_consumer_pool

# Keep every pre-X79 and historical 6 GiB key loadable for immutable existing
# vm.conf files, but remove it from every creation/component candidate path.
# This is an archive operation, not a deletion, so existing installations keep
# booting while every newly created 4/8/12/16G machine uses a quad-capable X79.
_hardware_profile_archive_retired_combinations() {
    local index row platform cpu board memory lifecycle memory_row module_list
    local module total
    local -a modules=()

    for ((index = 0; index < ${#HARDWARE_COMBINATIONS[@]}; index += 1)); do
        row=${HARDWARE_COMBINATIONS[index]}
        IFS='|' read -r platform cpu board memory lifecycle <<<"$row"
        memory_row=
        for memory_row in "${MEMORY_PROFILES[@]}"; do
            [[ "${memory_row%%|*}" == "$memory" ]] && break
        done
        [[ -n "$memory_row" && "${memory_row%%|*}" == "$memory" ]] || continue
        IFS='|' read -r _ _ _ _ _ _ _ module_list _ <<<"$memory_row"
        IFS=',' read -r -a modules <<<"$module_list"
        total=0
        for module in "${modules[@]}"; do
            total=$((total + module))
        done
        [[ "$lifecycle" != legacy-compatibility ]] || continue
        case "$board" in
            asus-p9x79|gigabyte-x79-up4|asrock-x79-extreme4)
                (( total != 6144 )) && continue
                ;;
        esac
        HARDWARE_COMBINATIONS[index]="$platform|$cpu|$board|$memory|archived"
    done
}

_hardware_profile_archive_retired_combinations

# Compatibility view consumed by the existing legality/start/test code.  It is
# generated from the normalized catalogs below; no hardware fact is duplicated.
HARDWARE_PROFILES=()
HARDWARE_NEW_PROFILE_KEYS=()
HARDWARE_EXPLICIT_NEW_PROFILE_KEYS=()
HARDWARE_ARCHIVED_PROFILE_KEYS=()
HARDWARE_LEGACY_COMPAT_PROFILE_KEYS=()

# Optional optical-drive identity fields:
# key|brand|ATA/SCSI model|firmware|interface|form-factor|serial-policy
#
# LG's product page and specification sheet identify GH24NS50 as an internal
# SATA DVD writer.  LG's support page publishes XP02 for this exact model.
# The Windows-facing string is the conventional HL-DT-ST INQUIRY identity:
# vendor "HL-DT-ST" (8 bytes), product "DVDRAM GH24NS50" (15 bytes).
#
#   https://www.lg.com/bd/support/product/lg-GH24NS50.AUAU10B
#   https://www.lg.com/us/products/documents/GH24NS50%20spec%20sheet.pdf
#
# One period-correct model is available to every current platform, but it is
# never attached by a normal start.  It appears only for the explicit IDE
# installer fallback, the private-clone one-shot USB-BOT/SCSI payload, or the
# manual USB-BOT/SCSI hotplug wrapper.  No serial is invented: QEMU receives
# an explicit empty serial so its QM0000x fallback cannot leak into VPD page
# 0x80.
OPTICAL_DRIVE_PROFILES=(
    "lg-gh24ns50|LG Electronics|HL-DT-ST DVDRAM GH24NS50|XP02|sata-atapi|5.25-inch|none"
)
OPTICAL_DRIVE_DEFAULT_PROFILE=lg-gh24ns50

# key|brand|ATA Identify model|interface|visible bytes|firmware|controller|
# form-factor|PCIe-generation|PCIe-lanes|logical-sector-bytes|physical-sector-bytes
#
# Samsung firmware source:
#   https://semiconductor.samsung.com/consumer-storage/support/tools/
# Samsung 960 PRO 512GB/M.2/PCIe Gen3 x4 specifications:
#   https://download.semiconductor.samsung.com/resources/data-sheet/Samsung_SSD_960_PRO_Data_Sheet_Rev_1_2.pdf
# Samsung 840/850 PRO specifications:
#   https://www.samsung.com/us/business/support/owners/product/840-pro-series-512gb/
#   https://download.semiconductor.samsung.com/resources/data-sheet/Samsung_SSD_850_PRO_Data_Sheet_Rev_3.pdf
# Non-Samsung 512 GB SATA specifications/firmware:
#   https://content.crucial.com/content/dam/crucial/ssd-products/mx100/flyer/crucial-mx100-ssd-product-flyer-en.pdf
#   https://www.crucial.com/support/ssd-support/mx100-support
#   https://www.kingston.com/datasheets/skc400s37_en.pdf
#   https://media.kingston.com/support/downloads/SAFM001B_KC400_SHSS_RN_121516.pdf
#   https://www.intel.com/content/dam/www/public/us/en/documents/product-briefs/ssd-545s-brief.pdf
#   https://www.solidigm.com/support-page/product-doc-cert/ka-00099.html
# Western Digital PC SA530 non-SED 2.5-inch specifications and ATA identity:
#   https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/product/internal-drives/pc-sa530-sata-ssd/product-brief-pc-sa530.pdf
#   https://www.ssd.group/wp-content/uploads/2022/07/Western-Digital-PC-SA530-3D-NAND-SSD-Product-Manual-GOEM-1-0-Disti.pdf
# Field capture for the exact model, firmware revision and LBA count:
#   https://forum.archlinuxcn.org/t/topic/13322
# Firmware 40101000 is a field-observed revision, not a claim that every build
# of this OEM model uses one canonical firmware revision.
# First-generation WD Black PCIe SSD specifications and observed identity:
#   https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/wd/product/internal-storage/wd_black/wd-black-pcie-ssd/data-sheet-wd-black-pcie-nvme-ssd.pdf
#   https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1746340?comments=all
#   https://linux-hardware.org/?probe=fa664dce82&log=smartctl
# G-11 exposes one exact visible capacity across the entire active SSD
# catalog.  Decimal marketing labels are not sufficient: every row and every
# default key must resolve to this exact byte count.
SSD_REQUIRED_SIZE_BYTES=512110190592
SSD_PROFILES=(
    "samsung-840-pro-512gb|Samsung|Samsung SSD 840 PRO Series|sata|512110190592|DXM06B0Q|ahci|2.5-inch|0|0|512|512"
    "samsung-850-pro-512gb|Samsung|Samsung SSD 850 PRO 512GB|sata|512110190592|EXM04B6Q|ahci|2.5-inch|0|0|512|512"
    "samsung-860-pro-512gb|Samsung|Samsung SSD 860 PRO 512GB|sata|512110190592|RVM02B6Q|ahci|2.5-inch|0|0|512|512"
    "crucial-mx100-512gb|Crucial|Crucial_CT512MX100SSD1|sata|512110190592|MU03|ahci|2.5-inch|0|0|512|4096"
    "kingston-kc400-512gb|Kingston|KINGSTON SKC400S37512G|sata|512110190592|SAFM001B|ahci|2.5-inch|0|0|512|512"
    "intel-545s-512gb|Intel|INTEL SSDSC2KW512G8|sata|512110190592|LHF004C|ahci|2.5-inch|0|0|512|512"
    "wd-pc-sa530-512gb|Western Digital|WDC PC SA530 SDASB8Y512G|sata|512110190592|40101000|ahci|2.5-inch|0|0|512|512"
    "wd-black-pcie-512gb|Western Digital|WDC WDS512G1X0C-00ENX0|nvme|512110190592|B35900WD|wd|m.2-2280|3|4|512|512"
    "samsung-970-pro-512gb|Samsung|Samsung SSD 970 PRO 512GB|nvme|512110190592|1B2QEXP7|samsung|m.2-2280|3|4|512|512"
    # Manual append-only expansion.  It is selectable but deliberately not
    # inserted into SSD_DEFAULT_PROFILE_KEYS, preserving existing auto picks.
    "samsung-960-pro-512gb|Samsung|Samsung SSD 960 PRO 512GB|nvme|512110190592|2B6QCXP7|samsung|m.2-2280|3|4|512|512"
)

# Every root-workflow profile is the same exact 512 GB visible capacity, so a
# shared 512 GB baseline never needs an unsafe shrink.  Keep the explicit
# default list to make additions a reviewed choice instead of silently random.
SSD_DEFAULT_PROFILE_KEYS=(
    samsung-840-pro-512gb
    samsung-850-pro-512gb
    samsung-860-pro-512gb
    crucial-mx100-512gb
    kingston-kc400-512gb
    intel-545s-512gb
    wd-pc-sa530-512gb
)

# This is the historical default/explicit audit partition, not the automatic
# order.  Automatic X79 selection may use these NVMe identities only through a
# reviewed passive adapter and compatible Gen3 CPU; older platforms are denied.
SSD_EXPLICIT_PROFILE_KEYS=(
    wd-black-pcie-512gb
    samsung-970-pro-512gb
    samsung-960-pro-512gb
)

# Automatic storage candidates are ordered independently from the historical
# default/explicit audit partition.  Gen3 x4 NVMe is considered first and is
# selected only when hardware_storage_combination_allowed proves the exact CPU
# and board path; SATA remains the compatible fallback for all older boards.
SSD_AUTO_PROFILE_KEYS=(
    wd-black-pcie-512gb
    samsung-970-pro-512gb
    samsung-960-pro-512gb
    samsung-840-pro-512gb
    samsung-850-pro-512gb
    samsung-860-pro-512gb
    crucial-mx100-512gb
    kingston-kc400-512gb
    intel-545s-512gb
    wd-pc-sa530-512gb
)

# Passive consumer M.2 NVMe adapters have no active protocol bridge and expose
# the drive directly on one reviewed X79 CPU lane group.  They do not make a
# Sandy Bridge-E CPU Gen3-capable: the CPU-side generation remains a hard cap.
# board-key|slot|PCIe-generation|lanes|form-factor|adapter-kind
PCIE_NVME_ADAPTER_PROFILES=(
    "asus-p9x79|PCIEX16_3|3|4|m.2-2280|passive"
    "gigabyte-x79-up4|PCIEX8_1|3|4|m.2-2280|passive"
    "asrock-x79-extreme4|PCIE4|3|4|m.2-2280|passive"
)

# IEEE registrations belonging to Intel Corporate.  e1000e must not borrow an
# OEM system vendor's OUI merely to look varied.
INTEL_OUIS=(
    "00:1B:21"
    "00:1E:67"
    "00:21:6A"
    "00:22:FA"
    "00:23:14"
    "00:24:D7"
)

# O(1) row indexes keep catalog loading proportional to the number of reviewed
# combinations.  The i3 memory matrix is intentionally broad, so repeatedly
# rescanning the full Bash arrays for every flattened row would otherwise make
# list/start commands quadratic.
declare -A _HARDWARE_CPU_ROW_BY_KEY=()
declare -A _HARDWARE_CPU_HOST_BRIDGE_ROW_BY_KEY=()
declare -A _HARDWARE_BOARD_ROW_BY_KEY=()
declare -A _HARDWARE_MEMORY_ROW_BY_KEY=()
declare -A _HARDWARE_COMBINATION_ROW_BY_KEY=()
declare -A _HARDWARE_CHIPSET_ROW_BY_KEY=()
declare -A _HARDWARE_OPTICAL_ROW_BY_KEY=()

_hardware_profile_build_indexes() {
    local row key

    _HARDWARE_CPU_ROW_BY_KEY=()
    _HARDWARE_CPU_HOST_BRIDGE_ROW_BY_KEY=()
    _HARDWARE_BOARD_ROW_BY_KEY=()
    _HARDWARE_MEMORY_ROW_BY_KEY=()
    _HARDWARE_COMBINATION_ROW_BY_KEY=()
    _HARDWARE_CHIPSET_ROW_BY_KEY=()
    _HARDWARE_OPTICAL_ROW_BY_KEY=()
    for row in "${CPU_PROFILES[@]}"; do
        key=${row%%|*}
        _HARDWARE_CPU_ROW_BY_KEY["$key"]=$row
    done
    for row in "${CPU_HOST_BRIDGE_PRESENTATION_PROFILES[@]}"; do
        key=${row%%|*}
        _HARDWARE_CPU_HOST_BRIDGE_ROW_BY_KEY["$key"]=$row
    done
    for row in "${BOARD_PROFILES[@]}"; do
        key=${row%%|*}
        _HARDWARE_BOARD_ROW_BY_KEY["$key"]=$row
    done
    for row in "${MEMORY_PROFILES[@]}"; do
        key=${row%%|*}
        _HARDWARE_MEMORY_ROW_BY_KEY["$key"]=$row
    done
    for row in "${HARDWARE_COMBINATIONS[@]}"; do
        key=${row%%|*}
        _HARDWARE_COMBINATION_ROW_BY_KEY["$key"]=$row
    done
    for row in "${CHIPSET_PRESENTATION_PROFILES[@]}"; do
        key=${row%%|*}
        _HARDWARE_CHIPSET_ROW_BY_KEY["$key"]=$row
    done
    for row in "${OPTICAL_DRIVE_PROFILES[@]}"; do
        key=${row%%|*}
        _HARDWARE_OPTICAL_ROW_BY_KEY["$key"]=$row
    done
}

_hardware_profile_build_indexes

hardware_profile_keys() {
    local row key
    for row in "${HARDWARE_COMBINATIONS[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        printf '%s\n' "$key"
    done
}

hardware_profile_new_keys() {
    if (( ${#HARDWARE_NEW_PROFILE_KEYS[@]} > 0 )); then
        printf '%s\n' "${HARDWARE_NEW_PROFILE_KEYS[@]}"
    fi
}

hardware_profile_explicit_new_keys() {
    if (( ${#HARDWARE_EXPLICIT_NEW_PROFILE_KEYS[@]} > 0 )); then
        printf '%s\n' "${HARDWARE_EXPLICIT_NEW_PROFILE_KEYS[@]}"
    fi
}

hardware_profile_legacy_compat_keys() {
    if (( ${#HARDWARE_LEGACY_COMPAT_PROFILE_KEYS[@]} > 0 )); then
        printf '%s\n' "${HARDWARE_LEGACY_COMPAT_PROFILE_KEYS[@]}"
    fi
}

hardware_profile_archived_keys() {
    if (( ${#HARDWARE_ARCHIVED_PROFILE_KEYS[@]} > 0 )); then
        printf '%s\n' "${HARDWARE_ARCHIVED_PROFILE_KEYS[@]}"
    fi
}

hardware_profile_lifecycle_class() {
    local requested=${1:-} matched= _key _cpu _board _memory lifecycle

    if [[ -n "$requested" ]]; then
        matched=${_HARDWARE_COMBINATION_ROW_BY_KEY["$requested"]-}
    fi
    [[ -n "$matched" ]] || return 1
    IFS='|' read -r _key _cpu _board _memory lifecycle <<<"$matched"
    printf '%s\n' "$lifecycle"
}

cpu_profile_keys() {
    local row key
    for row in "${CPU_PROFILES[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        printf '%s\n' "$key"
    done
}

board_profile_keys() {
    local row key
    for row in "${BOARD_PROFILES[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        printf '%s\n' "$key"
    done
}

memory_profile_keys() {
    local row key
    for row in "${MEMORY_PROFILES[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        printf '%s\n' "$key"
    done
}

cpu_profile_load() {
    local requested=${1:-} matched=
    if [[ -n "$requested" ]]; then
        matched=${_HARDWARE_CPU_ROW_BY_KEY["$requested"]-}
    fi
    [[ -n "$matched" ]] || {
        echo "未知 CPU profile: ${requested:-<empty>}" >&2
        return 2
    }
    IFS='|' read -r CPU_PROFILE CPU_MODEL CPU_BRAND_STRING TSC_FREQ \
        CPU_PART CPU_BASE_MHZ CPU_MAX_MHZ CPU_SMBIOS_FAMILY \
        CPU_SOCKET_UPGRADE CPU_PROCESSOR_CHARACTERISTICS CPU_CORES \
        CPU_THREADS_PER_CORE CPU_L1_CACHE_KB CPU_L2_CACHE_KB \
        CPU_L3_CACHE_KB CPU_L2_ASSOC CPU_L3_ASSOC CPU_GENERATION \
        CPU_SOCKET CPU_MEMORY_FAMILY CPU_MAX_MEMORY_SPEED \
        GPU_ROOT_PORT_DEVICE_ID GPU_ROOT_PORT_REVISION \
        CPU_PCIE_GENERATION <<<"$matched"
    CPU_VCPUS=$((CPU_CORES * CPU_THREADS_PER_CORE))
}

cpu_host_bridge_presentation_load() {
    local requested=${1:-} matched=

    CPU_HOST_BRIDGE_PRESENTATION_KEY=""
    CPU_HOST_BRIDGE_PCI_VENDOR_ID=""
    CPU_HOST_BRIDGE_PCI_DEVICE_ID=""
    CPU_HOST_BRIDGE_PCI_REVISION=""
    if [[ -n "$requested" ]]; then
        matched=${_HARDWARE_CPU_HOST_BRIDGE_ROW_BY_KEY["$requested"]-}
    fi
    [[ -n "$matched" ]] || return 1
    IFS='|' read -r _ CPU_HOST_BRIDGE_PRESENTATION_KEY \
        CPU_HOST_BRIDGE_PCI_VENDOR_ID CPU_HOST_BRIDGE_PCI_DEVICE_ID \
        CPU_HOST_BRIDGE_PCI_REVISION <<<"$matched"
}

hardware_cpu_host_bridge_identity_for_platform() {
    local requested=${1:-}

    (
        hardware_profile_load "$requested" || exit
        cpu_host_bridge_presentation_load "$CPU_PROFILE" || return 1
        printf '%s|%s|%s|%s\n' \
            "$CPU_HOST_BRIDGE_PRESENTATION_KEY" \
            "$CPU_HOST_BRIDGE_PCI_VENDOR_ID" \
            "$CPU_HOST_BRIDGE_PCI_DEVICE_ID" \
            "$CPU_HOST_BRIDGE_PCI_REVISION"
    )
}

chipset_presentation_load() {
    local requested=${1:-} matched=

    if [[ -n "$requested" ]]; then
        matched=${_HARDWARE_CHIPSET_ROW_BY_KEY["$requested"]-}
    fi
    [[ -n "$matched" ]] || {
        echo "芯片组没有已审核的 LPC identity: ${requested:-<empty>}" >&2
        return 2
    }
    IFS='|' read -r CHIPSET_PRESENTATION_NAME \
        CHIPSET_QEMU_PRESENTATION_KEY BOARD_LPC_PCI_VENDOR_ID \
        BOARD_LPC_PCI_DEVICE_ID BOARD_LPC_PCI_REVISION <<<"$matched"
}

hardware_chipset_identity_for_platform() {
    local requested=${1:-}

    (
        hardware_profile_load "$requested" || exit
        printf '%s|%s|%s|%s|%s\n' \
            "$CHIPSET_PRESENTATION_NAME" \
            "$CHIPSET_QEMU_PRESENTATION_KEY" \
            "$BOARD_LPC_PCI_VENDOR_ID" "$BOARD_LPC_PCI_DEVICE_ID" \
            "$BOARD_LPC_PCI_REVISION"
    )
}

board_profile_load() {
    local requested=${1:-} matched=
    if [[ -n "$requested" ]]; then
        matched=${_HARDWARE_BOARD_ROW_BY_KEY["$requested"]-}
    fi
    [[ -n "$matched" ]] || {
        echo "未知主板 profile: ${requested:-<empty>}" >&2
        return 2
    }
    IFS='|' read -r BOARD_PROFILE BOARD_BRAND BOARD_MODEL BOARD_REVISION \
        BOARD_CHIPSET BIOS_VER BIOS_DATE BOARD_TPM_VERSION MEM_BOARD_SLOTS \
        MEM_MAX_CAPACITY_GB BOARD_NVME_PCIE_GEN BOARD_NVME_PCIE_LANES \
        BOARD_XHCI_VENDOR_ID BOARD_XHCI_DEVICE_ID BOARD_XHCI_REVISION \
        PCIE_MAIN_SLOT \
        PCIE_AUX_SLOT PCIE_AUX_TYPE PCIE_AUX_WIDTH PCIE_AUX_LENGTH \
        BOARD_CPU_SOCKET BOARD_MEMORY_FAMILY BOARD_MAX_MEMORY_SPEED \
        BOARD_RELEASE_YEAR BOARD_SERIAL_POLICY \
        <<<"$matched"
    chipset_presentation_load "$BOARD_CHIPSET"
}

memory_profile_load() {
    local requested=${1:-} matched= module
    local -a modules
    if [[ -n "$requested" ]]; then
        matched=${_HARDWARE_MEMORY_ROW_BY_KEY["$requested"]-}
    fi
    [[ -n "$matched" ]] || {
        echo "未知内存 profile: ${requested:-<empty>}" >&2
        return 2
    }
    IFS='|' read -r MEMORY_PROFILE MEM_BRAND MEM_MODEL_LIST MEM_SPEED \
        MEM_FAMILY MEM_TYPE_BYTE MEM_WIDTH MEM_MODULE_MB_LIST MEM_SLOTS \
        MEM_FORM_FACTOR MEM_RANK_LIST MEM_DEVICE_WIDTH_LIST MEM_VOLTAGE_MV \
        MEM_CHANNEL_MODE MEM_MODULE_MFR_JEP106_LIST \
        MEM_DRAM_MFR_JEP106_LIST \
        <<<"$matched"
    # Scalar aliases keep immutable v1 vm.conf files readable.  Current v2
    # configs additionally persist the complete per-slot lists so a 4+2 GiB
    # Flex layout cannot be flattened into a fictitious pair of equal DIMMs.
    MEM_MODEL=${MEM_MODEL_LIST%%,*}
    MEM_MODULE_MB=${MEM_MODULE_MB_LIST%%,*}
    MEM_RANK=${MEM_RANK_LIST%%,*}
    MEM_DEVICE_WIDTH=${MEM_DEVICE_WIDTH_LIST%%,*}
    MEM_MODULE_MFR_JEP106=${MEM_MODULE_MFR_JEP106_LIST%%,*}
    MEM_DRAM_MFR_JEP106=${MEM_DRAM_MFR_JEP106_LIST%%,*}
    IFS=',' read -r -a modules <<<"$MEM_MODULE_MB_LIST"
    MEM_TOTAL_MB=0
    for module in "${modules[@]}"; do
        MEM_TOTAL_MB=$((MEM_TOTAL_MB + module))
    done
}

# V-11-style capacity selector used by the G-11 create/clone entry points.
# Physical DIMM details still come from an audited MEMORY_PROFILES row; this
# helper only normalizes the requested total and never manufactures a layout.
hardware_memory_size_mb_normalize() {
    local requested=${1:-}

    requested=${requested,,}
    requested=${requested//[[:space:]]/}
    case "$requested" in
        4|4g|4gb|4gib|4096|4096m|4096mb|4096mib)
            printf '%s\n' 4096
            ;;
        8|8g|8gb|8gib|8192|8192m|8192mb|8192mib)
            printf '%s\n' 8192
            ;;
        12|12g|12gb|12gib|12288|12288m|12288mb|12288mib)
            printf '%s\n' 12288
            ;;
        16|16g|16gb|16gib|16384|16384m|16384mb|16384mib)
            printf '%s\n' 16384
            ;;
        *)
            printf '内存档位只支持 4G、8G、12G 或 16G（6G 已归档），当前: %s\n' \
                "${1:-<empty>}" >&2
            return 2
            ;;
    esac
}

memory_profile_total_mb() {
    local requested=${1:-}

    (
        memory_profile_load "$requested" || exit
        printf '%s\n' "$MEM_TOTAL_MB"
    )
}

optical_drive_profile_keys() {
    local row key
    for row in "${OPTICAL_DRIVE_PROFILES[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        printf '%s\n' "$key"
    done
}

optical_drive_profile_load() {
    local requested=${1:-} matched=

    if [[ -n "$requested" ]]; then
        matched=${_HARDWARE_OPTICAL_ROW_BY_KEY["$requested"]-}
    fi
    [[ -n "$matched" ]] || {
        echo "未知光驱 profile: ${requested:-<empty>}" >&2
        return 2
    }
    IFS='|' read -r ODD_PROFILE ODD_BRAND ODD_MODEL ODD_FIRMWARE_REV \
        ODD_INTERFACE ODD_FORM_FACTOR ODD_SERIAL_POLICY <<<"$matched"
}

hardware_combination_load() {
    local requested=${1:-} matched=
    if [[ -n "$requested" ]]; then
        matched=${_HARDWARE_COMBINATION_ROW_BY_KEY["$requested"]-}
    fi
    [[ -n "$matched" ]] || {
        echo "未知平台: ${requested:-<empty>}" >&2
        return 2
    }
    IFS='|' read -r PLATFORM CPU_PROFILE BOARD_PROFILE MEMORY_PROFILE \
        PLATFORM_LIFECYCLE_CLASS <<<"$matched"
}

hardware_profile_load() {
    local requested=${1:-}

    hardware_combination_load "$requested" || return
    cpu_profile_load "$CPU_PROFILE" || return
    cpu_host_bridge_presentation_load "$CPU_PROFILE" || true
    board_profile_load "$BOARD_PROFILE" || return
    memory_profile_load "$MEMORY_PROFILE" || return
    optical_drive_profile_load "$OPTICAL_DRIVE_DEFAULT_PROFILE" || return
    PLATFORM_GENERATION=$CPU_GENERATION
    BOARD_VERSION=$BOARD_REVISION
}

hardware_profile_flat_row() {
    local requested=${1:-}
    (
        hardware_profile_load "$requested" || exit
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$PLATFORM" "$CPU_MODEL" "$TSC_FREQ" "$BOARD_BRAND" \
            "$BOARD_MODEL" "$BOARD_REVISION" "$BOARD_CHIPSET" \
            "$BIOS_VER" "$BIOS_DATE" "$BOARD_TPM_VERSION" \
            "$MEM_BRAND" "$MEM_MODEL" "$MEM_SPEED" "$MEM_FAMILY" \
            "$MEM_TYPE_BYTE" "$MEM_WIDTH" "$MEM_MODULE_MB" \
            "$MEM_SLOTS" "$MEM_FORM_FACTOR" "$MEM_BOARD_SLOTS" \
            "$MEM_MAX_CAPACITY_GB" "$BOARD_NVME_PCIE_GEN" \
            "$BOARD_NVME_PCIE_LANES"
    )
}

_hardware_profile_materialize_catalog() {
    local row platform _cpu _board _memory lifecycle flat

    HARDWARE_PROFILES=()
    HARDWARE_NEW_PROFILE_KEYS=()
    HARDWARE_EXPLICIT_NEW_PROFILE_KEYS=()
    HARDWARE_ARCHIVED_PROFILE_KEYS=()
    HARDWARE_LEGACY_COMPAT_PROFILE_KEYS=()
    for row in "${HARDWARE_COMBINATIONS[@]}"; do
        IFS='|' read -r platform _cpu _board _memory lifecycle <<<"$row"
        flat=$(hardware_profile_flat_row "$platform") || return
        HARDWARE_PROFILES+=("$flat")
        case "$lifecycle" in
            new) HARDWARE_NEW_PROFILE_KEYS+=("$platform") ;;
            explicit-new) HARDWARE_EXPLICIT_NEW_PROFILE_KEYS+=("$platform") ;;
            archived) HARDWARE_ARCHIVED_PROFILE_KEYS+=("$platform") ;;
            legacy-compatibility)
                HARDWARE_LEGACY_COMPAT_PROFILE_KEYS+=("$platform")
                ;;
            *)
                echo "平台生命周期无效: $platform/$lifecycle" >&2
                return 1
                ;;
        esac
    done
}

hardware_profile_matches_components() {
    local requested=${1:-} cpu_request=${2:-} board_request=${3:-}
    local memory_request=${4:-} memory_total_request=${5:-}
    local row= key cpu board memory lifecycle memory_total

    if [[ -n "$requested" ]]; then
        row=${_HARDWARE_COMBINATION_ROW_BY_KEY["$requested"]-}
    fi
    [[ -n "$row" ]] || return 1
    IFS='|' read -r key cpu board memory lifecycle <<<"$row"
    [[ "$lifecycle" == new || "$lifecycle" == explicit-new ]] || return 1
    [[ -z "$cpu_request" || "$cpu" == "$cpu_request" ]] || return 1
    [[ -z "$board_request" || "$board" == "$board_request" ]] || return 1
    [[ -z "$memory_request" || "$memory" == "$memory_request" ]] || return 1
    if [[ -n "$memory_total_request" ]]; then
        memory_total=$(memory_profile_total_mb "$memory") || return 1
        [[ "$memory_total" == "$memory_total_request" ]] || return 1
    fi
    return 0
}

# Lower number wins.  The normal consumer X79 pool prefers 6C/12T before
# 4C/8T and, within a CPU, native DDR3-1866 before DDR3-1600.  Every returned
# row still has to pass the KVM enforce=on realization gate.
hardware_profile_performance_priority() {
    local requested=${1:-}

    (
        local cpu_priority memory_priority
        hardware_profile_load "$requested" || exit
        case "$CPU_PROFILE:$MEM_SPEED" in
            i7-4960x:1866) cpu_priority=0 ;;
            i7-4960x:*) cpu_priority=10 ;;
            i7-4930k:1866) cpu_priority=20 ;;
            i7-4930k:*) cpu_priority=30 ;;
            i7-3930k:*) cpu_priority=40 ;;
            i7-4820k:1866) cpu_priority=50 ;;
            i7-4820k:*) cpu_priority=60 ;;
            i7-3820:*) cpu_priority=70 ;;
            i5-4590:*) cpu_priority=100 ;;
            i5-4570:*) cpu_priority=110 ;;
            i5-4460:*) cpu_priority=120 ;;
            i3-4130:*) cpu_priority=130 ;;
            g3220:*) cpu_priority=140 ;;
            i7-4790:*) cpu_priority=150 ;;
            *) cpu_priority=900 ;;
        esac
        # The ordinary home-pool default is 8 GiB.  Explicit --memory-size
        # requests still filter the candidate set before this tie-breaker.
        case "$MEM_TOTAL_MB" in
            8192) memory_priority=0 ;;
            4096) memory_priority=1 ;;
            12288) memory_priority=2 ;;
            16384) memory_priority=3 ;;
            *) memory_priority=9 ;;
        esac
        printf '%s\n' "$((cpu_priority * 10 + memory_priority))"
    )
}

hardware_profile_component_candidates() {
    local cpu_request=${1:-} board_request=${2:-} memory_request=${3:-}
    local memory_total_request=${4:-}
    local include_fallback=${5:-1}
    local row key _cpu _board _memory _lifecycle

    for row in "${HARDWARE_COMBINATIONS[@]}"; do
        IFS='|' read -r key _cpu _board _memory _lifecycle <<<"$row"
        if [[ "$_lifecycle" == legacy-compatibility && "$include_fallback" != 1 ]]; then
            continue
        fi
        hardware_profile_matches_components "$key" "$cpu_request" \
            "$board_request" "$memory_request" "$memory_total_request" && \
            printf '%s\n' "$key"
    done
    return 0
}

hardware_profile_component_contract() {
    local requested=${1:-}
    (
        hardware_profile_load "$requested" || exit
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$CPU_PROFILE" "$BOARD_PROFILE" "$MEMORY_PROFILE" \
            "$CPU_CORES" "$CPU_THREADS_PER_CORE" "$CPU_VCPUS" \
            "$CPU_BASE_MHZ" "$CPU_MAX_MHZ" "$CPU_L1_CACHE_KB" \
            "$CPU_L2_CACHE_KB" "$CPU_L3_CACHE_KB" "$CPU_L2_ASSOC" \
            "$CPU_L3_ASSOC" "$MEM_RANK" "$MEM_DEVICE_WIDTH" \
            "$MEM_VOLTAGE_MV" "$MEM_MODEL_LIST" "$MEM_MODULE_MB_LIST" \
            "$MEM_DEVICE_WIDTH_LIST" "$MEM_CHANNEL_MODE" "$MEM_RANK_LIST" \
            "$MEM_MODULE_MFR_JEP106_LIST" "$MEM_DRAM_MFR_JEP106_LIST" \
            "$BOARD_RELEASE_YEAR" "$BOARD_SERIAL_POLICY"
    )
}

HARDWARE_COMPONENT_CONTRACT_ERROR=
hardware_profile_component_contract_validate() {
    local requested=${1:-} expected version=${HARDWARE_COMPONENT_CONTRACT_VERSION-}
    local exp_cpu exp_board exp_memory exp_cores exp_threads exp_vcpus
    local exp_base exp_max exp_l1 exp_l2 exp_l3 exp_l2assoc exp_l3assoc
    local exp_rank exp_device_width exp_voltage exp_model_list
    local exp_module_list exp_device_width_list exp_channel_mode exp_rank_list
    local exp_module_jep106_list exp_dram_jep106_list exp_board_release_year
    local exp_board_serial_policy
    local field present=0 actual expected_value

    HARDWARE_COMPONENT_CONTRACT_ERROR=
    expected=$(hardware_profile_component_contract "$requested") || {
        HARDWARE_COMPONENT_CONTRACT_ERROR="PLATFORM=${requested:-<empty>} 没有组件合同"
        return 1
    }
    IFS='|' read -r exp_cpu exp_board exp_memory exp_cores exp_threads \
        exp_vcpus exp_base exp_max exp_l1 exp_l2 exp_l3 exp_l2assoc \
        exp_l3assoc exp_rank exp_device_width exp_voltage exp_model_list \
        exp_module_list exp_device_width_list exp_channel_mode exp_rank_list \
        exp_module_jep106_list exp_dram_jep106_list exp_board_release_year \
        exp_board_serial_policy <<<"$expected"

    case "$version" in
        '')
            for field in CPU_PROFILE BOARD_PROFILE MEMORY_PROFILE CPU_CORES \
                    CPU_THREADS_PER_CORE CPU_VCPUS CPU_BASE_MHZ CPU_MAX_MHZ \
                    CPU_L1_CACHE_KB CPU_L2_CACHE_KB CPU_L3_CACHE_KB \
                    CPU_L2_ASSOC CPU_L3_ASSOC MEM_RANK MEM_DEVICE_WIDTH \
                    MEM_VOLTAGE_MV MEM_MODEL_LIST MEM_MODULE_MB_LIST \
                    MEM_DEVICE_WIDTH_LIST MEM_CHANNEL_MODE MEM_RANK_LIST \
                    MEM_MODULE_MFR_JEP106_LIST MEM_DRAM_MFR_JEP106_LIST \
                    BOARD_RELEASE_YEAR BOARD_SERIAL_POLICY; do
                [[ ! -v $field ]] || present=$((present + 1))
            done
            (( present == 0 )) || {
                HARDWARE_COMPONENT_CONTRACT_ERROR='组件字段存在但缺少 HARDWARE_COMPONENT_CONTRACT_VERSION'
                return 1
            }
            return 0
            ;;
        1|2|3) ;;
        *)
            HARDWARE_COMPONENT_CONTRACT_ERROR="不支持 HARDWARE_COMPONENT_CONTRACT_VERSION=$version"
            return 1
            ;;
    esac

    local -a fields=(
        CPU_PROFILE BOARD_PROFILE MEMORY_PROFILE CPU_CORES
        CPU_THREADS_PER_CORE CPU_VCPUS CPU_BASE_MHZ CPU_MAX_MHZ
        CPU_L1_CACHE_KB CPU_L2_CACHE_KB CPU_L3_CACHE_KB CPU_L2_ASSOC
        CPU_L3_ASSOC MEM_RANK MEM_DEVICE_WIDTH MEM_VOLTAGE_MV
    )
    local -a values=(
        "$exp_cpu" "$exp_board" "$exp_memory" "$exp_cores" "$exp_threads"
        "$exp_vcpus" "$exp_base" "$exp_max" "$exp_l1" "$exp_l2" "$exp_l3"
        "$exp_l2assoc" "$exp_l3assoc" "$exp_rank" "$exp_device_width"
        "$exp_voltage"
    )
    if [[ "$version" == 2 ]]; then
        fields+=(MEM_MODEL_LIST MEM_MODULE_MB_LIST MEM_DEVICE_WIDTH_LIST \
            MEM_CHANNEL_MODE)
        values+=("$exp_model_list" "$exp_module_list" \
            "$exp_device_width_list" "$exp_channel_mode")
    elif [[ "$version" == 3 ]]; then
        fields+=(MEM_MODEL_LIST MEM_MODULE_MB_LIST MEM_DEVICE_WIDTH_LIST \
            MEM_CHANNEL_MODE MEM_RANK_LIST MEM_MODULE_MFR_JEP106_LIST \
            MEM_DRAM_MFR_JEP106_LIST BOARD_RELEASE_YEAR BOARD_SERIAL_POLICY)
        values+=("$exp_model_list" "$exp_module_list" \
            "$exp_device_width_list" "$exp_channel_mode" "$exp_rank_list" \
            "$exp_module_jep106_list" "$exp_dram_jep106_list" \
            "$exp_board_release_year" "$exp_board_serial_policy")
    fi
    local i
    for ((i = 0; i < ${#fields[@]}; i += 1)); do
        field=${fields[i]}
        expected_value=${values[i]}
        if [[ ! -v $field ]]; then
            HARDWARE_COMPONENT_CONTRACT_ERROR="$field 是组件合同 v${version} 必填字段"
            return 1
        fi
        actual=${!field}
        if [[ "$actual" != "$expected_value" ]]; then
            HARDWARE_COMPONENT_CONTRACT_ERROR="$field=$actual 与平台审核值 $expected_value 不一致"
            return 1
        fi
    done
}

hardware_profile_print_catalog() {
    local include_fallback=${1:-0} filter=${2:-active}
    local row key lifecycle layout parts

    printf 'PROFILE\tCPU/TOPOLOGY\tBOARD\tCHIPSET\tMEMORY\tTPM\tNEW_VM_POLICY\tCOMPONENT_KEYS\n'
    for row in "${HARDWARE_COMBINATIONS[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        lifecycle=$(hardware_profile_lifecycle_class "$key") || lifecycle=invalid
        case "$filter" in
            archived) [[ "$lifecycle" == archived ]] || continue ;;
            active)
                if [[ ( "$lifecycle" == legacy-compatibility ||
                        "$lifecycle" == archived ) &&
                      "$include_fallback" != 1 ]]; then
                    continue
                fi
                ;;
            *) echo "未知平台目录过滤器: $filter" >&2; return 2 ;;
        esac
        hardware_profile_load "$key" || return
        layout=${MEM_MODULE_MB_LIST//,/+}
        parts=${MEM_MODEL_LIST//,/ + }
        printf '%s\t%s %sC/%sT\t%s %s\t%s\t%s %s@%s %sMiB/%s [%s]\t%s\t%s\t%s/%s/%s\n' \
            "$key" "$CPU_MODEL" "$CPU_CORES" "$CPU_VCPUS" \
            "$BOARD_BRAND" "$BOARD_MODEL" "$BOARD_CHIPSET" "$parts" \
            "$MEM_FAMILY" "$MEM_SPEED" "$layout" "$MEM_CHANNEL_MODE" \
            "$MEM_TOTAL_MB" "$BOARD_TPM_VERSION" "$lifecycle" \
            "$CPU_PROFILE" "$BOARD_PROFILE" "$MEMORY_PROFILE"
    done
}

cpu_profile_print_catalog() {
    local include_fallback=${1:-0}
    local row key model _brand tsc _part base max _family _upgrade _chars
    local cores threads _l1 _l2 l3 _l2assoc _l3assoc generation socket
    local memory max_speed _root _revision _pcie lifecycle new_count legacy_count platform

    printf 'CPU_PROFILE\tQEMU_MODEL\tTOPOLOGY\tBASE/MAX_MHZ\tL3_KIB\tGEN\tSOCKET\tMEMORY\tPOLICY\n'
    for row in "${CPU_PROFILES[@]}"; do
        IFS='|' read -r key model _brand tsc _part base max _family _upgrade \
            _chars cores threads _l1 _l2 l3 _l2assoc _l3assoc generation \
            socket memory max_speed _root _revision _pcie <<<"$row"
        new_count=0
        legacy_count=0
        while IFS= read -r platform; do
            [[ -n "$platform" ]] && new_count=$((new_count + 1))
        done < <(hardware_profile_component_candidates "$key" '' '' '' 0)
        for platform in "${HARDWARE_LEGACY_COMPAT_PROFILE_KEYS[@]}"; do
            hardware_combination_load "$platform" >/dev/null 2>&1 || continue
            [[ "$CPU_PROFILE" == "$key" ]] && legacy_count=$((legacy_count + 1))
        done
        lifecycle="new:${new_count}/legacy:${legacy_count}"
        if (( new_count == 0 )) && [[ "$include_fallback" != 1 ]]; then
            continue
        fi
        printf '%s\t%s\t%sC/%sT\t%s/%s\t%s\t%s\t%s\t%s@%s\t%s\n' \
            "$key" "$model" "$cores" "$((cores * threads))" "$base" \
            "$max" "$l3" "$generation" "$socket" "$memory" "$max_speed" \
            "$lifecycle"
    done
}

board_profile_print_catalog() {
    local include_fallback=${1:-0}
    local row key brand model revision chipset bios date tpm slots max_gb
    local nvme_gen nvme_lanes _xhci_vendor _xhci _xhci_rev
    local _main _aux _type _width _length
    local socket memory max_speed candidate_count
    printf 'BOARD_PROFILE\tBOARD\tCHIPSET/BIOS\tSOCKET/MEMORY\tDIMM\tTPM\tNATIVE_M2\n'
    for row in "${BOARD_PROFILES[@]}"; do
        IFS='|' read -r key brand model revision chipset bios date tpm slots \
            max_gb nvme_gen nvme_lanes _xhci_vendor _xhci _xhci_rev _main \
            _aux _type _width _length socket memory max_speed <<<"$row"
        if [[ "$include_fallback" != 1 ]]; then
            candidate_count=$(hardware_profile_component_candidates '' "$key" '' '' 0 | \
                awk 'NF { count++ } END { print count + 0 }')
            (( candidate_count > 0 )) || continue
        fi
        printf '%s\t%s %s rev %s\t%s %s %s\t%s %s@%s\t%s/%sGiB\t%s\tGen%sx%s\n' \
            "$key" "$brand" "$model" "$revision" "$chipset" "$bios" \
            "$date" "$socket" "$memory" "$max_speed" "$slots" "$max_gb" \
            "$tpm" "$nvme_gen" "$nvme_lanes"
    done
}

memory_profile_print_catalog() {
    local include_fallback=${1:-0}
    local row key brand model_list speed family _type width module_list slots
    local _form rank_list device_width_list voltage channel_mode module_jep dram_jep
    local layout parts candidate_count
    printf 'MEMORY_PROFILE\tPARTS\tFAMILY/SPEED\tLAYOUT\tCHANNEL\tRANK/DEVICE\tJEP106(MODULE/DRAM)\tVOLTAGE_MV\n'
    for row in "${MEMORY_PROFILES[@]}"; do
        IFS='|' read -r key brand model_list speed family _type width \
            module_list slots _form rank_list device_width_list voltage \
            channel_mode module_jep dram_jep <<<"$row"
        if [[ "$include_fallback" != 1 ]]; then
            candidate_count=$(hardware_profile_component_candidates '' '' "$key" '' 0 | \
                awk 'NF { count++ } END { print count + 0 }')
            (( candidate_count > 0 )) || continue
        fi
        layout=${module_list//,/+}
        parts=${model_list//,/ + }
        printf '%s\t%s %s\t%s@%s\t%sMiB/%s-bit\t%s\t%sR x%s\t%s/%s\t%s\n' \
            "$key" "$brand" "$parts" "$family" "$speed" "$layout" \
            "$width" "$channel_mode" "$rank_list" "$device_width_list" \
            "$module_jep" "$dram_jep" "$voltage"
    done
}

optical_drive_profile_print_catalog() {
    local row key brand model firmware interface form_factor serial_policy

    printf 'OPTICAL_PROFILE\tBRAND/MODEL\tFIRMWARE\tINTERFACE/FORM\tSERIAL\n'
    for row in "${OPTICAL_DRIVE_PROFILES[@]}"; do
        IFS='|' read -r key brand model firmware interface form_factor \
            serial_policy <<<"$row"
        printf '%s\t%s %s\t%s\t%s/%s\t%s\n' \
            "$key" "$brand" "$model" "$firmware" "$interface" \
            "$form_factor" "$serial_policy"
    done
}

_hardware_profile_materialize_catalog

# Audited physical-board xHCI facts and the fixed virtual-controller placement.
# create-vm persists these values for profile consistency, but start-vm must not
# project the physical PCI ID onto qemu-xhci: USBXHCI.SYS treats that ID as a
# hardware behavior contract and enables vendor/device-specific workarounds.
hardware_xhci_identity_for_platform() {
    local requested=${1:-} identity

    identity=$(
        hardware_profile_load "$requested" || exit
        printf '%s|%s|%s|pcie.0|0x6\n' \
            "$BOARD_XHCI_VENDOR_ID" "$BOARD_XHCI_DEVICE_ID" \
            "$BOARD_XHCI_REVISION"
    ) || return
    printf '%s\n' "$identity"
}

ssd_profile_keys() {
    local row key
    for row in "${SSD_PROFILES[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        printf '%s\n' "$key"
    done
}

ssd_default_profile_keys() {
    printf '%s\n' "${SSD_DEFAULT_PROFILE_KEYS[@]}"
}

ssd_explicit_profile_keys() {
    printf '%s\n' "${SSD_EXPLICIT_PROFILE_KEYS[@]}"
}

ssd_auto_profile_keys() {
    printf '%s\n' "${SSD_AUTO_PROFILE_KEYS[@]}"
}

ssd_profile_is_default() {
    local requested=${1:-} key

    for key in "${SSD_DEFAULT_PROFILE_KEYS[@]}"; do
        [[ "$key" == "$requested" ]] && return 0
    done
    return 1
}

ssd_profile_is_auto() {
    local requested=${1:-} key

    for key in "${SSD_AUTO_PROFILE_KEYS[@]}"; do
        [[ "$key" == "$requested" ]] && return 0
    done
    return 1
}

# CPU-and-board-bound storage compatibility.  A native M.2 link or one audited
# passive X79 adapter may provide the board-side path, while CPU PCIe generation
# remains the upper bound.  Missing drive metadata retains the historical Gen3
# x4 interpretation for old callers.
hardware_storage_combination_allowed() {
    local platform=${1:-} interface=${2:-}
    local drive_gen=${3:-} drive_lanes=${4:-} form_factor=${5:-}
    local combination= cpu_key board_key cpu_row= board_row=
    local cpu_pcie_gen board_gen board_lanes adapter_row adapter_board
    local adapter_slot adapter_gen adapter_lanes adapter_form adapter_kind

    hardware_profile_is_catalog_key "$platform" || return 1
    [[ "$interface" == sata ]] && return 0
    [[ "$interface" == nvme ]] || return 1

    : "${drive_gen:=3}"
    : "${drive_lanes:=4}"
    : "${form_factor:=m.2-2280}"
    [[ "$drive_gen" =~ ^[1-9][0-9]*$ &&
       "$drive_lanes" =~ ^[1-9][0-9]*$ &&
       "$form_factor" == m.2-2280 ]] || return 1

    combination=${_HARDWARE_COMBINATION_ROW_BY_KEY["$platform"]-}
    [[ -n "$combination" ]] || return 1
    IFS='|' read -r _ cpu_key board_key _ _ <<<"$combination"
    cpu_row=${_HARDWARE_CPU_ROW_BY_KEY["$cpu_key"]-}
    board_row=${_HARDWARE_BOARD_ROW_BY_KEY["$board_key"]-}
    [[ -n "$cpu_row" && -n "$board_row" ]] || return 1
    cpu_pcie_gen=${cpu_row##*|}
    IFS='|' read -r _ _ _ _ _ _ _ _ _ _ board_gen board_lanes _ \
        <<<"$board_row"
    if (( board_gen < drive_gen || board_lanes < drive_lanes )); then
        board_gen=0
        board_lanes=0
        for adapter_row in "${PCIE_NVME_ADAPTER_PROFILES[@]}"; do
            IFS='|' read -r adapter_board adapter_slot adapter_gen \
                adapter_lanes adapter_form adapter_kind <<<"$adapter_row"
            [[ "$adapter_board" == "$board_key" &&
               "$adapter_form" == "$form_factor" &&
               "$adapter_kind" == passive ]] || continue
            if (( adapter_gen > board_gen )); then
                board_gen=$adapter_gen
                board_lanes=$adapter_lanes
            fi
        done
    fi
    (( cpu_pcie_gen >= drive_gen && board_gen >= drive_gen &&
       board_lanes >= drive_lanes ))
}

# Lower number wins.  Explicit --ssd-profile bypasses this preference but is
# still checked for topology compatibility.  The implicit path prefers the
# QEMU controller identity that really advertises PCIe Gen3 x4, then any other
# reviewed NVMe tier, and finally SATA as the old-board fallback.
hardware_storage_preference_tier() {
    local interface=${1:-} drive_gen=${2:-0} drive_lanes=${3:-0}

    if [[ "$interface" == nvme && "$drive_gen" == 3 && "$drive_lanes" == 4 ]]; then
        printf '0\n'
    elif [[ "$interface" == nvme ]]; then
        printf '10\n'
    else
        printf '20\n'
    fi
}

hardware_profile_is_catalog_key() {
    local requested=${1:-}

    [[ -n "$requested" && -v "_HARDWARE_COMBINATION_ROW_BY_KEY[$requested]" ]]
}

ssd_profile_load() {
    local requested=$1 row key matched=""
    for row in "${SSD_PROFILES[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        if [[ "$key" == "$requested" ]]; then
            matched=$row
            break
        fi
    done
    if [[ -z "$matched" ]]; then
        echo "未知 SSD profile: $requested" >&2
        echo "用 --list-ssd-profiles 查看允许的型号" >&2
        return 2
    fi
    IFS='|' read -r SSD_PROFILE SSD_BRAND SSD_MODEL SSD_INTERFACE \
        SSD_SIZE_BYTES SSD_FIRMWARE_REV SSD_CONTROLLER_PROFILE \
        SSD_FORM_FACTOR SSD_PCIE_GEN SSD_PCIE_LANES \
        SSD_LOGICAL_BLOCK_SIZE SSD_PHYSICAL_BLOCK_SIZE <<<"$matched"
    [[ "$SSD_SIZE_BYTES" == "$SSD_REQUIRED_SIZE_BYTES" ]] || {
        echo "SSD profile 容量不符合 G-11 精确 512GB 合同: $requested/$SSD_SIZE_BYTES" >&2
        return 2
    }
}

ssd_profile_print_catalog() {
    local row key brand model interface size_bytes firmware controller
    local form_factor pcie_gen pcie_lanes logical_block_size physical_block_size
    local auto_random
    for row in "${SSD_PROFILES[@]}"; do
        IFS='|' read -r key brand model interface size_bytes firmware controller \
            form_factor pcie_gen pcie_lanes logical_block_size \
            physical_block_size <<<"$row"
        if ssd_profile_is_auto "$key"; then
            auto_random=1
        else
            auto_random=0
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$key" "$brand" "$interface" "$size_bytes" "$firmware" \
            "$controller" "$form_factor" "$pcie_gen" "$pcie_lanes" \
            "$model" "$logical_block_size" "$physical_block_size" \
            "$auto_random"
    done
}

hardware_profile_validate_catalog() {
    local row key brand seen='|' selection_seen='|' selection_key found
    local selection_class
    local -a selection_keys=()

    # Validate normalized component catalogs and the explicit combination
    # matrix in a subshell so audit calls never overwrite the caller's loaded
    # vm.conf variables.
    if ! (
        local model brand_string tsc part base max family upgrade chars cores
        local threads l1 l2 l3 l2assoc l3assoc generation socket mem_family
        local max_speed root_device root_revision cpu_pcie_generation
        local board revision chipset bios bios_date tpm board_slots max_gb
        local nvme_gen nvme_lanes xhci_vendor xhci_device xhci_revision
        local main_slot aux_slot
        local aux_type aux_width aux_length release_year serial_policy
        local mem_model_list mem_type mem_width module_list slots form rank_list
        local device_width_list voltage channel_mode module_jep_list dram_jep_list
        local cpu_key board_key memory_key module device_width rank mem_total
        local part index
        local used_cpu='|' used_board='|' used_memory='|' flat flat_count=0
        local seen_model='|' seen_chipset='|' used_chipset='|' seen_host_bridge='|'
        local presentation_key lpc_vendor lpc_device lpc_revision
        local host_cpu host_key host_vendor host_device host_revision
        local -a parts modules ranks device_widths module_jeps dram_jeps
        local -A active_cpu_seen=() active_board_seen=() default_cpu_seen=()
        local -A active_memory_brand_seen=()
        local -A active_cpu_board_capacity_brand_seen=()
        local -A active_board_capacity_seen=() active_cpu_capacity_seen=()
        local capacity expected_brand_count brand_count memory_brand
        local new_count=0 explicit_count=0 archived_count=0 legacy_count=0

        seen='|'
        for row in "${CPU_PROFILES[@]}"; do
            IFS='|' read -r key model brand_string tsc part base max family \
                upgrade chars cores threads l1 l2 l3 l2assoc l3assoc \
                generation socket mem_family max_speed root_device \
                root_revision cpu_pcie_generation <<<"$row"
            [[ -n "$cpu_pcie_generation" && "$seen" != *"|$key|"* ]] || {
                echo "重复或字段不完整的 CPU profile: $key" >&2
                exit 1
            }
            seen+="$key|"
            [[ "$seen_model" != *"|$model|"* ]] || {
                echo "重复 QEMU CPU model: $model" >&2
                exit 1
            }
            seen_model+="$model|"
            [[ "$key" =~ ^[a-z0-9][a-z0-9-]*$ &&
               "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ &&
               -n "$brand_string" && -n "$part" &&
               "$tsc" =~ ^[1-9][0-9]+$ && "$base" =~ ^[1-9][0-9]*$ &&
               "$max" =~ ^[1-9][0-9]*$ && "$family" =~ ^[1-9][0-9]*$ &&
               "$upgrade" =~ ^0x[0-9A-Fa-f]{2}$ &&
               "$chars" =~ ^0x[0-9A-Fa-f]{2}$ &&
               "$cores" =~ ^[1-9][0-9]*$ && "$threads" =~ ^[1-9][0-9]*$ &&
               "$l1" =~ ^[1-9][0-9]*$ && "$l2" =~ ^[1-9][0-9]*$ &&
               "$l3" =~ ^[1-9][0-9]*$ &&
               ( "$l2assoc" == 5 || "$l2assoc" == 7 ) &&
               ( "$l3assoc" == 8 || "$l3assoc" == 9 || "$l3assoc" == 10 ||
                 "$l3assoc" == 14 ) &&
               ( "$generation" == 2 || "$generation" == 3 ||
                 "$generation" == 4 || "$generation" == 6 ||
                 "$generation" == 8 ) &&
               ( "$mem_family" == DDR3 || "$mem_family" == DDR4 ) &&
               "$max_speed" =~ ^[1-9][0-9]*$ &&
               "$root_device" =~ ^0x[0-9A-Fa-f]{4}$ &&
               "$root_revision" =~ ^0x[0-9A-Fa-f]{2}$ &&
               ( "$cpu_pcie_generation" == 2 ||
                 "$cpu_pcie_generation" == 3 ) ]] || {
                echo "CPU profile 字段非法: $key" >&2
                exit 1
            }
            (( max >= base && cores * threads >= 2 && cores * threads <= 12 )) || {
                echo "CPU topology/frequency 未经审核: $key" >&2
                exit 1
            }
        done

        for row in "${CPU_HOST_BRIDGE_PRESENTATION_PROFILES[@]}"; do
            IFS='|' read -r host_cpu host_key host_vendor host_device \
                host_revision <<<"$row"
            [[ -n "$host_revision" &&
               "$seen_host_bridge" != *"|$host_cpu|"* ]] || {
                echo "重复或字段不完整的 CPU host bridge identity: $host_cpu" >&2
                exit 1
            }
            seen_host_bridge+="$host_cpu|"
            [[ -v "_HARDWARE_CPU_ROW_BY_KEY[$host_cpu]" &&
               "$host_vendor" == 0x8086 &&
               "$host_device" =~ ^0x[0-9A-F]{4}$ &&
               "$host_revision" =~ ^0x[0-9A-F]{2}$ ]] || {
                echo "CPU host bridge identity 未经审核: $row" >&2
                exit 1
            }
            case "$row" in
                'i7-3820|SandyBridge-E|0x8086|0x3C00|0x07'|\
                'i7-3930k|SandyBridge-E|0x8086|0x3C00|0x07'|\
                'i7-4820k|IvyBridge-E|0x8086|0x0E00|0x04'|\
                'i7-4930k|IvyBridge-E|0x8086|0x0E00|0x04'|\
                'i7-4960x|IvyBridge-E|0x8086|0x0E00|0x04') ;;
                *)
                    echo "CPU host bridge identity 不在 X79 闭集: $row" >&2
                    exit 1
                    ;;
            esac
        done
        (( ${#CPU_HOST_BRIDGE_PRESENTATION_PROFILES[@]} == 5 )) || {
            echo "CPU host bridge identity 必须精确覆盖五款活跃 X79 CPU" >&2
            exit 1
        }

        for row in "${CHIPSET_PRESENTATION_PROFILES[@]}"; do
            IFS='|' read -r chipset presentation_key lpc_vendor lpc_device \
                lpc_revision <<<"$row"
            [[ -n "$lpc_revision" && "$seen_chipset" != *"|$chipset|"* ]] || {
                echo "重复或字段不完整的芯片组 identity: $chipset" >&2
                exit 1
            }
            seen_chipset+="$chipset|"
            [[ "$chipset" =~ ^(H81|H97|B150|B360|X79)$ &&
               "$presentation_key" == "$chipset" &&
               "$lpc_vendor" == 0x8086 &&
               "$lpc_device" =~ ^0x[0-9A-F]{4}$ &&
               "$lpc_revision" =~ ^0x[0-9A-F]{2}$ ]] || {
                echo "芯片组 LPC identity 未经审核: $row" >&2
                exit 1
            }
        done
        (( ${#CHIPSET_PRESENTATION_PROFILES[@]} == 5 )) || {
            echo "芯片组 identity 目录必须精确覆盖 H81/H97/B150/B360/X79" >&2
            exit 1
        }

        seen='|'
        for row in "${BOARD_PROFILES[@]}"; do
            IFS='|' read -r key brand board revision chipset bios bios_date tpm \
                board_slots max_gb nvme_gen nvme_lanes xhci_vendor \
                xhci_device xhci_revision main_slot aux_slot aux_type \
                aux_width aux_length socket mem_family max_speed release_year \
                serial_policy <<<"$row"
            [[ -n "$serial_policy" && "$seen" != *"|$key|"* ]] || {
                echo "重复或字段不完整的主板 profile: $key" >&2
                exit 1
            }
            seen+="$key|"
            [[ "$key" =~ ^[a-z0-9][a-z0-9-]*$ && -n "$brand" &&
               -n "$board" && -n "$revision" && -n "$chipset" &&
               -n "$bios" && "$bios_date" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}$ &&
               ( "$tpm" == none || "$tpm" == 1.2 || "$tpm" == 2.0 ) &&
               ( "$board_slots" == 2 || "$board_slots" == 4 ||
                 "$board_slots" == 8 ) &&
               "$max_gb" =~ ^[1-9][0-9]*$ &&
               "$nvme_gen" =~ ^[0-9]+$ && "$nvme_lanes" =~ ^[0-9]+$ &&
               "$xhci_vendor" =~ ^0x[0-9A-Fa-f]{4}$ &&
               "$xhci_device" =~ ^0x[0-9A-Fa-f]{4}$ &&
               "$xhci_revision" =~ ^0x[0-9A-Fa-f]{2}$ &&
               -n "$main_slot" && -n "$aux_slot" &&
               "$aux_type" =~ ^[0-9]+$ && "$aux_width" =~ ^[0-9]+$ &&
               "$aux_length" =~ ^[0-9]+$ &&
               ( "$mem_family" == DDR3 || "$mem_family" == DDR4 ) &&
               "$max_speed" =~ ^[1-9][0-9]*$ &&
               "$release_year" =~ ^20[0-9]{2}$ &&
               ( "$serial_policy" == asus || "$serial_policy" == msi ||
                 "$serial_policy" == gigabyte || "$serial_policy" == asrock ||
                 "$serial_policy" == ecs ) ]] || {
                echo "主板 profile 字段非法: $key" >&2
                exit 1
            }
            if (( nvme_gen == 0 || nvme_lanes == 0 )); then
                (( nvme_gen == 0 && nvme_lanes == 0 )) || {
                    echo "主板 M.2 链路字段必须成对: $key" >&2
                    exit 1
                }
            fi
            case "$brand:$serial_policy" in
                'ASUSTeK COMPUTER INC.:asus'|'ASUS:asus'|Gigabyte:gigabyte|MSI:msi|ASRock:asrock|ECS:ecs) ;;
                *)
                    echo "主板厂商与序列策略不匹配: $key/$brand/$serial_policy" >&2
                    exit 1
                    ;;
            esac
            chipset_presentation_load "$chipset" || exit
            used_chipset+="$chipset|"
        done
        for row in "${CHIPSET_PRESENTATION_PROFILES[@]}"; do
            IFS='|' read -r chipset _ <<<"$row"
            [[ "$used_chipset" == *"|$chipset|"* ]] || {
                echo "孤立芯片组 identity: $chipset" >&2
                exit 1
            }
        done

        seen='|'
        for row in "${MEMORY_PROFILES[@]}"; do
            IFS='|' read -r key brand mem_model_list max_speed mem_family \
                mem_type mem_width module_list slots form rank_list \
                device_width_list voltage channel_mode module_jep_list \
                dram_jep_list \
                <<<"$row"
            [[ -n "$dram_jep_list" && "$seen" != *"|$key|"* ]] || {
                echo "重复或字段不完整的内存 profile: $key" >&2
                exit 1
            }
            seen+="$key|"
            [[ "$key" =~ ^[a-z0-9][a-z0-9-]*$ && -n "$brand" &&
               -n "$mem_model_list" && "$max_speed" =~ ^[1-9][0-9]*$ &&
               ( "$mem_family" == DDR3 || "$mem_family" == DDR4 ) &&
               ( "$mem_type" == 0x18 || "$mem_type" == 0x1A ) &&
               "$mem_width" == 64 &&
               ( "$slots" == 2 || "$slots" == 3 || "$slots" == 4 ) &&
               "$form" == DIMM &&
               ( "$voltage" == 1200 || "$voltage" == 1500 ) &&
               ( "$channel_mode" == dual-channel || "$channel_mode" == flex ||
                 "$channel_mode" == triple-channel ||
                 "$channel_mode" == quad-channel ) ]] || {
                echo "内存 profile 字段非法: $key" >&2
                exit 1
            }
            IFS=',' read -r -a parts <<<"$mem_model_list"
            IFS=',' read -r -a modules <<<"$module_list"
            IFS=',' read -r -a ranks <<<"$rank_list"
            IFS=',' read -r -a device_widths <<<"$device_width_list"
            IFS=',' read -r -a module_jeps <<<"$module_jep_list"
            IFS=',' read -r -a dram_jeps <<<"$dram_jep_list"
            (( ${#parts[@]} == slots && ${#modules[@]} == slots &&
               ${#ranks[@]} == slots && ${#device_widths[@]} == slots &&
               ${#module_jeps[@]} == slots && ${#dram_jeps[@]} == slots )) || {
                echo "内存逐槽列表数量与插槽数不匹配: $key" >&2
                exit 1
            }
            mem_total=0
            for ((index = 0; index < slots; index += 1)); do
                part=${parts[index]}
                module=${modules[index]}
                rank=${ranks[index]}
                device_width=${device_widths[index]}
                [[ "$part" =~ ^[A-Za-z0-9][A-Za-z0-9./_-]*$ &&
                   ${#part} -le 18 &&
                   ( "$module" == 2048 || "$module" == 4096 ) &&
                   ( "$rank" == 1 || "$rank" == 2 ) &&
                   ( "$device_width" == 8 || "$device_width" == 16 ) &&
                   "${module_jeps[index]}" =~ ^[0-9A-F]{4}$ &&
                   "${module_jeps[index]}" != 0000 &&
                   "${dram_jeps[index]}" =~ ^[0-9A-F]{4}$ ]] || {
                    echo "内存逐槽字段非法: $key/slot$index" >&2
                    exit 1
                }
                case "$module:$rank:$device_width" in
                    2048:1:16|2048:1:8|4096:1:8|4096:2:8) ;;
                    *)
                        echo "内存容量/rank/device-width 未经审核: $key/slot$index" >&2
                        exit 1
                        ;;
                esac
                mem_total=$((mem_total + module))
            done
            case "$channel_mode" in
                dual-channel|triple-channel|quad-channel)
                    case "$channel_mode:$slots" in
                        dual-channel:2|triple-channel:3|quad-channel:4) ;;
                        *)
                            echo "内存通道数必须等于已安装条数: $key/$channel_mode/$slots" >&2
                            exit 1
                            ;;
                    esac
                    for ((index = 1; index < slots; index += 1)); do
                        [[ "${modules[0]}" == "${modules[index]}" &&
                           "${parts[0]}" == "${parts[index]}" &&
                           "${ranks[0]}" == "${ranks[index]}" &&
                           "${device_widths[0]}" == "${device_widths[index]}" &&
                           "${module_jeps[0]}" == "${module_jeps[index]}" &&
                           "${dram_jeps[0]}" == "${dram_jeps[index]}" ]] || {
                            echo "多通道 profile 必须逐条同容量/料号/几何: $key" >&2
                            exit 1
                        }
                    done
                    (( mem_total == slots * modules[0] )) || {
                        echo "多通道 profile 容量合计异常: $key" >&2
                        exit 1
                    }
                    ;;
                flex)
                    [[ "$mem_family" == DDR3 && "$module_list" == 4096,2048 &&
                       "$mem_total" == 6144 ]] || {
                        echo "Flex profile 必须是审核过的 4+2 GiB 两条布局: $key" >&2
                        exit 1
                    }
                    ;;
            esac
        done

        seen='|'
        for row in "${HARDWARE_COMBINATIONS[@]}"; do
            IFS='|' read -r key cpu_key board_key memory_key lifecycle <<<"$row"
            [[ -n "$lifecycle" && "$seen" != *"|$key|"* ]] || {
                echo "重复或字段不完整的平台组合: $key" >&2
                exit 1
            }
            seen+="$key|"
            case "$lifecycle" in
                new) new_count=$((new_count + 1)) ;;
                explicit-new) explicit_count=$((explicit_count + 1)) ;;
                archived) archived_count=$((archived_count + 1)) ;;
                legacy-compatibility) legacy_count=$((legacy_count + 1)) ;;
                *) echo "平台生命周期无效: $key/$lifecycle" >&2; exit 1 ;;
            esac
            hardware_profile_load "$key" || exit
            [[ "$CPU_SOCKET" == "$BOARD_CPU_SOCKET" &&
               "$CPU_MEMORY_FAMILY" == "$BOARD_MEMORY_FAMILY" &&
               "$MEM_FAMILY" == "$CPU_MEMORY_FAMILY" ]] || {
                echo "CPU/主板/内存代际或 socket 不兼容: $key" >&2
                exit 1
            }
            (( MEM_SPEED <= CPU_MAX_MEMORY_SPEED &&
               MEM_SPEED <= BOARD_MAX_MEMORY_SPEED &&
               MEM_SLOTS <= MEM_BOARD_SLOTS &&
               MEM_TOTAL_MB <= MEM_MAX_CAPACITY_GB * 1024 )) || {
                echo "内存频率/插槽/容量与平台不兼容: $key" >&2
                exit 1
            }
            if [[ "$lifecycle" == archived ]]; then
                [[ "$MEM_TOTAL_MB" == 6144 || "$BOARD_CHIPSET" != X79 ]] || {
                    echo "归档平台必须是已取消的 6G 档或旧非 X79 新建池: $key" >&2
                    exit 1
                }
            fi
            [[ "$lifecycle" == archived || "$lifecycle" == legacy-compatibility ||
               "$CPU_GENERATION" == 2 || "$CPU_GENERATION" == 3 ||
               "$CPU_GENERATION" == 4 ]] || {
                echo "未经审核的 CPU 代际不能进入 G-11 新建池: $key" >&2
                exit 1
            }
            if [[ "$lifecycle" != legacy-compatibility && "$lifecycle" != archived ]]; then
                case "$MEM_TOTAL_MB:$MEM_CHANNEL_MODE" in
                    4096:dual-channel|8192:dual-channel)
                        (( MEM_BOARD_SLOTS >= 4 && MEM_SLOTS == 2 )) || {
                            echo "4G/8G 新建档必须在四通道主板安装双通道两条: $key" >&2
                            exit 1
                        }
                        ;;
                    12288:triple-channel)
                        (( MEM_BOARD_SLOTS >= 4 && MEM_SLOTS == 3 )) || {
                            echo "12G 新建档必须在四通道主板安装三条 4G: $key" >&2
                            exit 1
                        }
                        ;;
                    16384:quad-channel)
                        (( MEM_BOARD_SLOTS >= 4 && MEM_SLOTS == 4 )) || {
                            echo "16G 新建档必须在四通道主板安装四条 4G: $key" >&2
                            exit 1
                        }
                        ;;
                    *)
                        echo "新建内存档位/通道不符合 4/8/12/16 合同: $key" >&2
                        exit 1
                        ;;
                esac
                [[ "$BOARD_CHIPSET" == X79 ]] || {
                    echo "新建池主板必须统一为消费级四通道 X79: $key" >&2
                    exit 1
                }
                active_cpu_seen["$cpu_key"]=1
                active_board_seen["$board_key"]=1
                active_board_capacity_seen["$board_key:$MEM_TOTAL_MB"]=1
                active_cpu_capacity_seen["$cpu_key:$MEM_TOTAL_MB"]=1
                active_memory_brand_seen["$MEM_BRAND"]=1
                active_cpu_board_capacity_brand_seen["$cpu_key:$board_key:$MEM_TOTAL_MB:$MEM_BRAND"]=1
                [[ "$lifecycle" != new ]] || default_cpu_seen["$cpu_key"]=1
            fi
            used_cpu+="$cpu_key|"
            used_board+="$board_key|"
            used_memory+="$memory_key|"
            flat=$(hardware_profile_flat_row "$key") || exit
            [[ "$flat" == "${HARDWARE_PROFILES[flat_count]}" ]] || {
                echo "兼容平台视图与组件目录漂移: $key" >&2
                exit 1
            }
            flat_count=$((flat_count + 1))
        done
        (( flat_count == ${#HARDWARE_PROFILES[@]} )) || {
            echo "兼容平台视图数量错误" >&2
            exit 1
        }
        (( new_count == 260 && explicit_count == 0 && archived_count == 261 &&
           legacy_count == 3 )) || {
            echo "平台生命周期数量必须是 new=260/explicit=0/archived=261/legacy=3" >&2
            exit 1
        }
        (( ${#active_cpu_seen[@]} == 5 && ${#active_board_seen[@]} == 3 &&
           ${#default_cpu_seen[@]} == 5 )) || {
            echo "新建池必须是 5 款消费级 X79 CPU（4C/8T 或 6C/12T）/3 块四通道家用主板" >&2
            exit 1
        }
        for cpu_key in "${X79_CONSUMER_CPU_KEYS[@]}"; do
            [[ -v "active_cpu_seen[$cpu_key]" ]] || {
                echo "X79 家用 CPU 未进入普通新建池: $cpu_key" >&2
                exit 1
            }
        done
        for board_key in "${!active_board_seen[@]}"; do
            [[ -v "active_board_capacity_seen[$board_key:4096]" &&
               -v "active_board_capacity_seen[$board_key:8192]" &&
               -v "active_board_capacity_seen[$board_key:12288]" &&
               -v "active_board_capacity_seen[$board_key:16384]" ]] || {
                echo "四通道主板缺少 4G/8G/12G/16G 完整档位: $board_key" >&2
                exit 1
            }
        done
        for cpu_key in "${!active_cpu_seen[@]}"; do
            [[ -v "_HARDWARE_CPU_HOST_BRIDGE_ROW_BY_KEY[$cpu_key]" ]] || {
                echo "新建 X79 CPU 缺少 DMI2 host bridge identity: $cpu_key" >&2
                exit 1
            }
            [[ -v "active_cpu_capacity_seen[$cpu_key:4096]" &&
               -v "active_cpu_capacity_seen[$cpu_key:8192]" &&
               -v "active_cpu_capacity_seen[$cpu_key:12288]" &&
               -v "active_cpu_capacity_seen[$cpu_key:16384]" ]] || {
                echo "新建 CPU 缺少 4G/8G/12G/16G 完整档位: $cpu_key" >&2
                exit 1
            }
        done
        (( ${#active_memory_brand_seen[@]} == 5 )) &&
            [[ -v 'active_memory_brand_seen[Kingston]' &&
               -v 'active_memory_brand_seen[Samsung]' &&
               -v 'active_memory_brand_seen[Micron]' &&
               -v 'active_memory_brand_seen[Elpida]' &&
               -v 'active_memory_brand_seen[SK hynix]' ]] || {
            echo "新建内存池必须覆盖 Kingston/Samsung/Micron/Elpida/SK hynix 五个大牌" >&2
            exit 1
        }
        for cpu_key in "${X79_CONSUMER_CPU_KEYS[@]}"; do
            for board_key in asus-p9x79 gigabyte-x79-up4 asrock-x79-extreme4; do
                for capacity in 4096 8192 12288 16384; do
                    brand_count=0
                    for memory_brand in Samsung Micron Kingston 'SK hynix' Elpida; do
                        [[ -v "active_cpu_board_capacity_brand_seen[$cpu_key:$board_key:$capacity:$memory_brand]" ]] &&
                            brand_count=$((brand_count + 1))
                    done
                    expected_brand_count=4
                    if [[ "$cpu_key" == i7-4820k ||
                          "$cpu_key" == i7-4930k ||
                          "$cpu_key" == i7-4960x ]] &&
                            [[ "$board_key" != asrock-x79-extreme4 &&
                               "$capacity" != 4096 ]]; then
                        expected_brand_count=5
                    fi
                    (( brand_count == expected_brand_count )) || {
                        echo "X79 CPU/主板/容量品牌覆盖异常: $cpu_key/$board_key/${capacity}MiB=$brand_count（应为 $expected_brand_count）" >&2
                        exit 1
                    }
                done
            done
        done

        for row in "${CPU_PROFILES[@]}"; do
            IFS='|' read -r key _ <<<"$row"
            [[ "$used_cpu" == *"|$key|"* ]] || {
                echo "孤立 CPU profile: $key" >&2
                exit 1
            }
        done
        for row in "${BOARD_PROFILES[@]}"; do
            IFS='|' read -r key _ <<<"$row"
            [[ "$used_board" == *"|$key|"* ]] || {
                echo "孤立主板 profile: $key" >&2
                exit 1
            }
        done
        for row in "${MEMORY_PROFILES[@]}"; do
            IFS='|' read -r key _ <<<"$row"
            [[ "$used_memory" == *"|$key|"* ]] || {
                echo "孤立内存 profile: $key" >&2
                exit 1
            }
        done
    ); then
        return 1
    fi

    seen='|'
    local model interface size firmware controller form_factor pcie_gen pcie_lanes
    local logical_block_size physical_block_size
    for row in "${SSD_PROFILES[@]}"; do
        IFS='|' read -r key brand model interface size firmware controller \
            form_factor pcie_gen pcie_lanes logical_block_size \
            physical_block_size <<<"$row"
        [[ "$seen" != *"|$key|"* ]] || { echo "重复 SSD profile: $key" >&2; return 1; }
        seen+="$key|"
        [[ "$size" == "$SSD_REQUIRED_SIZE_BYTES" && "$key" == *-512gb &&
           -n "$model" && -n "$firmware" ]] || {
            echo "根流程 SSD 必须是精确 512GB profile: $key/$size" >&2
            return 1
        }
        [[ ${#model} -le 40 && ${#firmware} -le 8 &&
           "$model" != *','* && "$firmware" != *','* ]] || {
            echo "SSD ATA/NVMe Identify 字段无效: $key" >&2
            return 1
        }
        [[ "$logical_block_size" == 512 &&
           ( "$physical_block_size" == 512 || "$physical_block_size" == 4096 ) ]] &&
                (( size % physical_block_size == 0 )) || {
            echo "SSD 扇区规格未经审核: $key/$logical_block_size/$physical_block_size" >&2
            return 1
        }
        case "$interface|$controller|$brand" in
            nvme\|samsung\|Samsung|\
            nvme\|wd\|Western\ Digital|\
            sata\|ahci\|Samsung|\
            sata\|ahci\|Crucial|\
            sata\|ahci\|Kingston|\
            sata\|ahci\|Intel|\
            sata\|ahci\|Western\ Digital) ;;
            *) echo "SSD 接口/控制器不匹配: $key" >&2; return 1 ;;
        esac
        case "$interface|$form_factor|$pcie_gen|$pcie_lanes" in
            nvme\|m.2-2280\|3\|4|sata\|2.5-inch\|0\|0) ;;
            *) echo "SSD 形态/PCIe 链路不匹配: $key" >&2; return 1 ;;
        esac
    done
    for selection_class in default explicit; do
        if [[ "$selection_class" == default ]]; then
            selection_keys=("${SSD_DEFAULT_PROFILE_KEYS[@]}")
        else
            selection_keys=("${SSD_EXPLICIT_PROFILE_KEYS[@]}")
        fi
        for selection_key in "${selection_keys[@]}"; do
            [[ "$selection_seen" != *"|$selection_key|"* ]] || {
                echo "重复或跨层 SSD profile: $selection_key" >&2
                return 1
            }
            selection_seen+="$selection_key|"
            found=0
            for row in "${SSD_PROFILES[@]}"; do
                IFS='|' read -r key _ <<<"$row"
                if [[ "$key" == "$selection_key" ]]; then
                    found=1
                    IFS='|' read -r _ _ _ _ size _ _ _ _ _ <<<"$row"
                    [[ "$size" == "$SSD_REQUIRED_SIZE_BYTES" ]] || return 1
                    break
                fi
            done
            (( found )) || {
                echo "$selection_class SSD profile 不存在: $selection_key" >&2
                return 1
            }
        done
    done
    for row in "${SSD_PROFILES[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        [[ "$selection_seen" == *"|$key|"* ]] || {
            echo "SSD profile 未进入默认或显式审核 key 集: $key" >&2
            return 1
        }
    done

    local auto_seen='|' auto_key auto_found auto_count=0
    for auto_key in "${SSD_AUTO_PROFILE_KEYS[@]}"; do
        [[ "$auto_seen" != *"|$auto_key|"* ]] || {
            echo "自动 SSD 候选重复: $auto_key" >&2
            return 1
        }
        auto_seen+="$auto_key|"
        auto_found=0
        for row in "${SSD_PROFILES[@]}"; do
            IFS='|' read -r key _ <<<"$row"
            [[ "$key" == "$auto_key" ]] || continue
            auto_found=1
            break
        done
        (( auto_found )) || {
            echo "自动 SSD profile 不存在: $auto_key" >&2
            return 1
        }
        auto_count=$((auto_count + 1))
    done
    (( auto_count == ${#SSD_PROFILES[@]} )) || {
        echo "自动 SSD 池必须覆盖完整审核目录" >&2
        return 1
    }
    for row in "${SSD_PROFILES[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        [[ "$auto_seen" == *"|$key|"* ]] || {
            echo "SSD profile 未进入自动兼容筛选池: $key" >&2
            return 1
        }
    done

    local adapter_seen='|' adapter_board adapter_slot adapter_gen
    local adapter_lanes adapter_form adapter_kind adapter_board_row
    local adapter_board_nvme_gen adapter_board_nvme_lanes
    for row in "${PCIE_NVME_ADAPTER_PROFILES[@]}"; do
        IFS='|' read -r adapter_board adapter_slot adapter_gen adapter_lanes \
            adapter_form adapter_kind <<<"$row"
        [[ "$adapter_seen" != *"|$adapter_board|"* ]] || {
            echo "同一主板重复定义 NVMe 转接路径: $adapter_board" >&2
            return 1
        }
        adapter_seen+="$adapter_board|"
        adapter_board_row=${_HARDWARE_BOARD_ROW_BY_KEY["$adapter_board"]-}
        [[ -n "$adapter_board_row" && -n "$adapter_slot" &&
           "$adapter_gen" == 3 && "$adapter_lanes" == 4 &&
           "$adapter_form" == m.2-2280 && "$adapter_kind" == passive ]] || {
            echo "NVMe 转接路径未经审核: $row" >&2
            return 1
        }
        IFS='|' read -r _ _ _ _ _ _ _ _ _ _ adapter_board_nvme_gen \
            adapter_board_nvme_lanes _ <<<"$adapter_board_row"
        (( adapter_board_nvme_gen == 0 && adapter_board_nvme_lanes == 0 )) || {
            echo "原生 M.2 主板不应重复添加被动转接路径: $adapter_board" >&2
            return 1
        }
    done
    (( ${#PCIE_NVME_ADAPTER_PROFILES[@]} == 3 )) || {
        echo "X79 NVMe 转接路径必须精确覆盖三块新增主板" >&2
        return 1
    }

    local odd_model odd_firmware odd_interface odd_form_factor odd_serial
    seen='|'
    found=0
    for row in "${OPTICAL_DRIVE_PROFILES[@]}"; do
        IFS='|' read -r key brand odd_model odd_firmware odd_interface \
            odd_form_factor odd_serial <<<"$row"
        [[ "$seen" != *"|$key|"* ]] || {
            echo "重复光驱 profile: $key" >&2
            return 1
        }
        seen+="$key|"
        [[ "$key" =~ ^[a-z0-9][a-z0-9-]*$ &&
           "$brand" == 'LG Electronics' &&
           "$odd_model" == 'HL-DT-ST DVDRAM GH24NS50' &&
           "$odd_firmware" == XP02 &&
           "$odd_interface" == sata-atapi &&
           "$odd_form_factor" == 5.25-inch &&
           "$odd_serial" == none &&
           ${#odd_model} -le 40 && ${#odd_firmware} -le 8 ]] || {
            echo "光驱 profile 未经审核或字段非法: $key" >&2
            return 1
        }
        [[ "$key" != "$OPTICAL_DRIVE_DEFAULT_PROFILE" ]] || found=1
    done
    (( ${#OPTICAL_DRIVE_PROFILES[@]} == 1 && found == 1 )) || {
        echo "可选光驱目录必须唯一且包含默认 profile" >&2
        return 1
    }
    if ! (
        for key in $(hardware_profile_keys); do
            hardware_profile_load "$key" || exit
            [[ "$ODD_PROFILE" == "$OPTICAL_DRIVE_DEFAULT_PROFILE" ]] || {
                echo "平台没有绑定默认可选光驱 profile: $key" >&2
                exit 1
            }
        done
    ); then
        return 1
    fi

    local platform interface compatible_count
    for platform in $(hardware_profile_keys); do
        compatible_count=0
        for default_key in "${SSD_AUTO_PROFILE_KEYS[@]}"; do
            for row in "${SSD_PROFILES[@]}"; do
                IFS='|' read -r key _ _ interface _ _ _ form_factor \
                    pcie_gen pcie_lanes _ _ <<<"$row"
                [[ "$key" == "$default_key" ]] || continue
                hardware_storage_combination_allowed "$platform" "$interface" \
                    "$pcie_gen" "$pcie_lanes" "$form_factor" \
                    && compatible_count=$((compatible_count + 1))
                break
            done
        done
        (( compatible_count > 0 )) || {
            echo "平台没有可用的默认 SSD: $platform" >&2
            return 1
        }
    done
}

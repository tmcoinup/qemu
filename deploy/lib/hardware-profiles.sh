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
# memory-family|max-memory-MT/s|GPU-root-port-device|GPU-root-port-revision
#
# Intel specifications (official):
#   https://www.intel.com/content/www/us/en/products/sku/77773/intel-pentium-processor-g3220-3m-cache-3-00-ghz/specifications.html
#   https://www.intel.com/content/www/us/en/products/sku/77480/intel-core-i34130-processor-3m-cache-3-40-ghz/specifications.html
#   https://www.intel.com/content/www/us/en/products/sku/80817/intel-core-i54460-processor-6m-cache-up-to-3-40-ghz/specifications.html
#   https://www.intel.com/content/www/us/en/products/sku/75043/intel-core-i54570-processor-6m-cache-up-to-3-60-ghz/specifications.html
#   https://www.intel.com/content/www/us/en/products/sku/80815/intel-core-i54590-processor-6m-cache-up-to-3-70-ghz/specifications.html
#   https://www.intel.com/content/www/us/en/products/sku/80806/intel-core-i74790-processor-8m-cache-up-to-4-00-ghz/specifications.html
CPU_PROFILES=(
    "g3220|Intel-Pentium-G3220|Intel(R) Pentium(R) CPU G3220 @ 3.00GHz|3000000000|BX80646G3220|3000|3000|11|0x2D|0xEC|2|1|128|512|3072|7|9|4|LGA1150|DDR3|1333|0x0C01|0x06"
    "i3-4130|Core-i3-4130|Intel(R) Core(TM) i3-4130 CPU @ 3.40GHz|3400000000|BX80646I34130|3400|3400|206|0x2D|0xFC|2|2|128|512|3072|7|9|4|LGA1150|DDR3|1600|0x0C01|0x06"
    "i5-4460|Core-i5-4460|Intel(R) Core(TM) i5-4460 CPU @ 3.20GHz|3200000000|BX80646I54460|3200|3400|205|0x2D|0xEC|4|1|256|1024|6144|7|9|4|LGA1150|DDR3|1600|0x0C01|0x06"
    "i5-4570|Core-i5-4570|Intel(R) Core(TM) i5-4570 CPU @ 3.20GHz|3200000000|SR14E|3200|3600|205|0x2D|0xEC|4|1|256|1024|6144|7|9|4|LGA1150|DDR3|1600|0x0C01|0x06"
    "i5-4590|Core-i5-4590|Intel(R) Core(TM) i5-4590 CPU @ 3.30GHz|3300000000|SR1QJ|3300|3700|205|0x2D|0xEC|4|1|256|1024|6144|7|9|4|LGA1150|DDR3|1600|0x0C01|0x06"
    "i7-4790|Core-i7-4790|Intel(R) Core(TM) i7-4790 CPU @ 3.60GHz|3600000000|BX80646I74790|3600|4000|198|0x2D|0xFC|4|2|256|1024|8192|7|9|4|LGA1150|DDR3|1600|0x0C01|0x06"
    "i5-6500|Core-i5-6500|Intel(R) Core(TM) i5-6500 CPU @ 3.20GHz|3200000000|SR2L6|3200|3600|205|0x32|0xEC|4|1|256|1024|6144|5|9|6|LGA1151|DDR4|2133|0x1901|0x07"
    "i3-8100|Core-i3-8100|Intel(R) Core(TM) i3-8100 CPU @ 3.60GHz|3600000000|SR3N5|3600|3600|206|0x32|0xEC|4|1|256|1024|6144|5|9|8|LGA1151-300|DDR4|2400|0x1901|0x07"
)

# Board fields:
# key|brand|model|revision|chipset|BIOS|BIOS-date|TPM|DIMM-slots|max-GiB|
# native-M.2-gen|native-M.2-lanes|xHCI-device|xHCI-revision|main-slot|
# auxiliary-slot|aux-type|aux-width|aux-length|socket|memory-family|max-MT/s|
# release-year|serial-policy
#
# Official board specifications, manuals and BIOS pages:
#   https://www.asus.com/motherboards-components/motherboards/business/h81mk/techspec/
#   https://www.asus.com/supportonly/h81m-k/helpdesk_bios/
#   https://www.asus.com/uk/supportonly/h81m-c/helpdesk_bios/
#   https://dlcdnet.asus.com/pub/ASUS/mb/LGA1150/H81M-C/E8447_H81M-C.pdf
#   https://www.gigabyte.com/Motherboard/GA-H81M-S1-rev-21/sp
#   https://www.gigabyte.com/Motherboard/GA-H81M-S1-rev-21/support
#   https://storage-asset.msi.com/datasheet/original/mb/global/H81M-P33.pdf
#   https://nl.msi.com/Motherboard/H81M-P33/support
#   https://www.gigabyte.com/Motherboard/GA-H97-D3H-rev-10/support
#   https://www.gigabyte.com/Motherboard/GA-B150M-D3H-rev-10/support
#   https://www.asus.com/supportonly/prime%20b360m-a/helpdesk_bios/
BOARD_PROFILES=(
    "asus-h81m-k|ASUSTeK COMPUTER INC.|H81M-K|Rev X.0x|H81|3802|01/23/2024|none|2|16|0|0|0x8C31|0x05|PCIEX16|PCIEX1_1|171|8|3|LGA1150|DDR3|1600|2013|asus"
    "asus-h81m-c|ASUSTeK COMPUTER INC.|H81M-C|Rev X.0x|H81|3602|04/14/2018|none|2|16|0|0|0x8C31|0x05|PCIEX16|PCIEX1_1|171|8|3|LGA1150|DDR3|1600|2013|asus"
    "gigabyte-h81m-s1|Gigabyte|GA-H81M-S1|2.1|H81|FH|08/13/2015|none|2|16|0|0|0x8C31|0x05|PCIEX16|PCIEX1_1|171|8|3|LGA1150|DDR3|1600|2015|gigabyte"
    "msi-h81m-p33|MSI|H81M-P33 (MS-7817)|1.0|H81|1.A|07/17/2018|none|2|16|0|0|0x8C31|0x05|PCI_E2|PCI_E1|171|8|3|LGA1150|DDR3|1600|2013|msi"
    "gigabyte-h97-d3h|Gigabyte|GA-H97-D3H|1.0|H97|F7|09/19/2015|1.2|4|32|2|2|0x8CB1|0x01|PCIEX16|PCIEX1_1|171|8|3|LGA1150|DDR3|1600|2014|gigabyte"
    "gigabyte-b150m-d3h|Gigabyte|GA-B150M-D3H|1.0|B150|F21|12/12/2016|2.0|4|64|3|4|0xA12F|0x01|PCIEX16|PCIEX4|177|10|4|LGA1151|DDR4|2133|2015|gigabyte"
    "asus-prime-b360m-a|ASUS|PRIME B360M-A|1.xx|B360|3202|07/24/2021|2.0|4|64|3|4|0xA36D|0x01|PCIEX16|PCIEX1_1|177|8|3|LGA1151-300|DDR4|2666|2018|asus"
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
#   https://www.micron.com/products/obsolete/obsolete-udimm/part-catalog
#   https://product.skhynix.com/products/dram/module/module_info.jsp
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
    "kvr21n15s8-2x4|Kingston|KVR21N15S8/4,KVR21N15S8/4|2133|DDR4|0x1A|64|4096,4096|2|DIMM|1,1|8,8|1200|dual-channel|0198,0198|0000,0000"
    "kvr24n17s8-2x4|Kingston|KVR24N17S8/4,KVR24N17S8/4|2400|DDR4|0x1A|64|4096,4096|2|DIMM|1,1|8,8|1200|dual-channel|0198,0198|0000,0000"
)

# platform|CPU-key|board-key|memory-key|lifecycle
# lifecycle=new participates in the normal low-end random pool; explicit-new
# is the reviewed two-slot i7 tier (normally selected by an operator, or only
# after all five low-end CPUs are conclusively unavailable); legacy-
# compatibility is existing-VM/last-resort fallback only.
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
)

# Compatibility view consumed by the existing legality/start/test code.  It is
# generated from the normalized catalogs below; no hardware fact is duplicated.
HARDWARE_PROFILES=()
HARDWARE_NEW_PROFILE_KEYS=()
HARDWARE_EXPLICIT_NEW_PROFILE_KEYS=()
HARDWARE_LEGACY_COMPAT_PROFILE_KEYS=()

# key|brand|ATA Identify model|interface|visible bytes|firmware|controller|
# form-factor|PCIe-generation|PCIe-lanes|logical-sector-bytes|physical-sector-bytes
#
# Samsung firmware source:
#   https://semiconductor.samsung.com/consumer-storage/support/tools/
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
    wd-black-pcie-512gb
    samsung-970-pro-512gb
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

hardware_profile_keys() {
    local row key
    for row in "${HARDWARE_COMBINATIONS[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        printf '%s\n' "$key"
    done
}

hardware_profile_new_keys() {
    printf '%s\n' "${HARDWARE_NEW_PROFILE_KEYS[@]}"
}

hardware_profile_explicit_new_keys() {
    printf '%s\n' "${HARDWARE_EXPLICIT_NEW_PROFILE_KEYS[@]}"
}

hardware_profile_legacy_compat_keys() {
    printf '%s\n' "${HARDWARE_LEGACY_COMPAT_PROFILE_KEYS[@]}"
}

hardware_profile_lifecycle_class() {
    local requested=${1:-} row key _cpu _board _memory lifecycle

    for row in "${HARDWARE_COMBINATIONS[@]}"; do
        IFS='|' read -r key _cpu _board _memory lifecycle <<<"$row"
        [[ "$key" == "$requested" ]] || continue
        printf '%s\n' "$lifecycle"
        return 0
    done
    return 1
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
    local requested=${1:-} row key matched=
    for row in "${CPU_PROFILES[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        [[ "$key" == "$requested" ]] || continue
        matched=$row
        break
    done
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
        GPU_ROOT_PORT_DEVICE_ID GPU_ROOT_PORT_REVISION <<<"$matched"
    CPU_VCPUS=$((CPU_CORES * CPU_THREADS_PER_CORE))
}

board_profile_load() {
    local requested=${1:-} row key matched=
    for row in "${BOARD_PROFILES[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        [[ "$key" == "$requested" ]] || continue
        matched=$row
        break
    done
    [[ -n "$matched" ]] || {
        echo "未知主板 profile: ${requested:-<empty>}" >&2
        return 2
    }
    IFS='|' read -r BOARD_PROFILE BOARD_BRAND BOARD_MODEL BOARD_REVISION \
        BOARD_CHIPSET BIOS_VER BIOS_DATE BOARD_TPM_VERSION MEM_BOARD_SLOTS \
        MEM_MAX_CAPACITY_GB BOARD_NVME_PCIE_GEN BOARD_NVME_PCIE_LANES \
        BOARD_XHCI_DEVICE_ID BOARD_XHCI_REVISION PCIE_MAIN_SLOT \
        PCIE_AUX_SLOT PCIE_AUX_TYPE PCIE_AUX_WIDTH PCIE_AUX_LENGTH \
        BOARD_CPU_SOCKET BOARD_MEMORY_FAMILY BOARD_MAX_MEMORY_SPEED \
        BOARD_RELEASE_YEAR BOARD_SERIAL_POLICY \
        <<<"$matched"
}

memory_profile_load() {
    local requested=${1:-} row key matched= module
    local -a modules
    for row in "${MEMORY_PROFILES[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        [[ "$key" == "$requested" ]] || continue
        matched=$row
        break
    done
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

hardware_combination_load() {
    local requested=${1:-} row key matched=
    for row in "${HARDWARE_COMBINATIONS[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        [[ "$key" == "$requested" ]] || continue
        matched=$row
        break
    done
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
    board_profile_load "$BOARD_PROFILE" || return
    memory_profile_load "$MEMORY_PROFILE" || return
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
    HARDWARE_LEGACY_COMPAT_PROFILE_KEYS=()
    for row in "${HARDWARE_COMBINATIONS[@]}"; do
        IFS='|' read -r platform _cpu _board _memory lifecycle <<<"$row"
        flat=$(hardware_profile_flat_row "$platform") || return
        HARDWARE_PROFILES+=("$flat")
        case "$lifecycle" in
            new) HARDWARE_NEW_PROFILE_KEYS+=("$platform") ;;
            explicit-new) HARDWARE_EXPLICIT_NEW_PROFILE_KEYS+=("$platform") ;;
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
    local memory_request=${4:-} row key cpu board memory lifecycle

    for row in "${HARDWARE_COMBINATIONS[@]}"; do
        IFS='|' read -r key cpu board memory lifecycle <<<"$row"
        [[ "$key" == "$requested" ]] || continue
        [[ "$lifecycle" == new || "$lifecycle" == explicit-new ]] || return 1
        [[ -z "$cpu_request" || "$cpu" == "$cpu_request" ]] || return 1
        [[ -z "$board_request" || "$board" == "$board_request" ]] || return 1
        [[ -z "$memory_request" || "$memory" == "$memory_request" ]] || return 1
        return 0
    done
    return 1
}

hardware_profile_component_candidates() {
    local cpu_request=${1:-} board_request=${2:-} memory_request=${3:-}
    local row key _cpu _board _memory _lifecycle

    for row in "${HARDWARE_COMBINATIONS[@]}"; do
        IFS='|' read -r key _cpu _board _memory _lifecycle <<<"$row"
        hardware_profile_matches_components "$key" "$cpu_request" \
            "$board_request" "$memory_request" && printf '%s\n' "$key"
    done
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
    local row key lifecycle layout parts

    printf 'PROFILE\tCPU/TOPOLOGY\tBOARD\tCHIPSET\tMEMORY\tTPM\tNEW_VM_POLICY\tCOMPONENT_KEYS\n'
    for row in "${HARDWARE_COMBINATIONS[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        hardware_profile_load "$key" || return
        lifecycle=$(hardware_profile_lifecycle_class "$key") || lifecycle=invalid
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
    local row key model _brand tsc _part base max _family _upgrade _chars
    local cores threads _l1 _l2 l3 _l2assoc _l3assoc generation socket
    local memory max_speed _root _revision lifecycle new_count legacy_count platform

    printf 'CPU_PROFILE\tQEMU_MODEL\tTOPOLOGY\tBASE/MAX_MHZ\tL3_KIB\tGEN\tSOCKET\tMEMORY\tPOLICY\n'
    for row in "${CPU_PROFILES[@]}"; do
        IFS='|' read -r key model _brand tsc _part base max _family _upgrade \
            _chars cores threads _l1 _l2 l3 _l2assoc _l3assoc generation \
            socket memory max_speed _root _revision <<<"$row"
        new_count=0
        legacy_count=0
        while IFS= read -r platform; do
            [[ -n "$platform" ]] && new_count=$((new_count + 1))
        done < <(hardware_profile_component_candidates "$key" '' '')
        for platform in "${HARDWARE_LEGACY_COMPAT_PROFILE_KEYS[@]}"; do
            hardware_combination_load "$platform" >/dev/null 2>&1 || continue
            [[ "$CPU_PROFILE" == "$key" ]] && legacy_count=$((legacy_count + 1))
        done
        lifecycle="new:${new_count}/legacy:${legacy_count}"
        printf '%s\t%s\t%sC/%sT\t%s/%s\t%s\t%s\t%s\t%s@%s\t%s\n' \
            "$key" "$model" "$cores" "$((cores * threads))" "$base" \
            "$max" "$l3" "$generation" "$socket" "$memory" "$max_speed" \
            "$lifecycle"
    done
}

board_profile_print_catalog() {
    local row key brand model revision chipset bios date tpm slots max_gb
    local nvme_gen nvme_lanes _xhci _xhci_rev _main _aux _type _width _length
    local socket memory max_speed
    printf 'BOARD_PROFILE\tBOARD\tCHIPSET/BIOS\tSOCKET/MEMORY\tDIMM\tTPM\tNATIVE_M2\n'
    for row in "${BOARD_PROFILES[@]}"; do
        IFS='|' read -r key brand model revision chipset bios date tpm slots \
            max_gb nvme_gen nvme_lanes _xhci _xhci_rev _main _aux _type \
            _width _length socket memory max_speed <<<"$row"
        printf '%s\t%s %s rev %s\t%s %s %s\t%s %s@%s\t%s/%sGiB\t%s\tGen%sx%s\n' \
            "$key" "$brand" "$model" "$revision" "$chipset" "$bios" \
            "$date" "$socket" "$memory" "$max_speed" "$slots" "$max_gb" \
            "$tpm" "$nvme_gen" "$nvme_lanes"
    done
}

memory_profile_print_catalog() {
    local row key brand model_list speed family _type width module_list slots
    local _form rank_list device_width_list voltage channel_mode module_jep dram_jep
    local layout parts
    printf 'MEMORY_PROFILE\tPARTS\tFAMILY/SPEED\tLAYOUT\tCHANNEL\tRANK/DEVICE\tJEP106(MODULE/DRAM)\tVOLTAGE_MV\n'
    for row in "${MEMORY_PROFILES[@]}"; do
        IFS='|' read -r key brand model_list speed family _type width \
            module_list slots _form rank_list device_width_list voltage \
            channel_mode module_jep dram_jep <<<"$row"
        layout=${module_list//,/+}
        parts=${model_list//,/ + }
        printf '%s\t%s %s\t%s@%s\t%sMiB/%s-bit\t%s\t%sR x%s\t%s/%s\t%s\n' \
            "$key" "$brand" "$parts" "$family" "$speed" "$layout" \
            "$width" "$channel_mode" "$rank_list" "$device_width_list" \
            "$module_jep" "$dram_jep" "$voltage"
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
        printf '0x8086|%s|%s|pcie.0|0x6\n' \
            "$BOARD_XHCI_DEVICE_ID" "$BOARD_XHCI_REVISION"
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

# Board-bound storage compatibility.  Compare a drive's advertised endpoint
# link with the board's native M.2 capability instead of treating DDR3/DDR4 or
# the generic "nvme" interface name as a topology.  Missing link metadata is
# interpreted as the historical Samsung path (Gen3 x4), preserving old callers.
hardware_storage_combination_allowed() {
    local platform=${1:-} interface=${2:-}
    local drive_gen=${3:-} drive_lanes=${4:-} form_factor=${5:-}
    local row key board_gen board_lanes

    hardware_profile_is_catalog_key "$platform" || return 1
    [[ "$interface" == sata ]] && return 0
    [[ "$interface" == nvme ]] || return 1

    : "${drive_gen:=3}"
    : "${drive_lanes:=4}"
    : "${form_factor:=m.2-2280}"
    [[ "$drive_gen" =~ ^[1-9][0-9]*$ &&
       "$drive_lanes" =~ ^[1-9][0-9]*$ &&
       "$form_factor" == m.2-2280 ]] || return 1

    for row in "${HARDWARE_PROFILES[@]}"; do
        IFS='|' read -r key _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ \
            board_gen board_lanes <<<"$row"
        [[ "$key" == "$platform" ]] || continue
        (( board_gen >= drive_gen && board_lanes >= drive_lanes ))
        return
    done
    return 1
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
    local requested=${1:-} row key

    for row in "${HARDWARE_PROFILES[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        [[ "$key" == "$requested" ]] && return 0
    done
    return 1
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
    for row in "${SSD_PROFILES[@]}"; do
        IFS='|' read -r key brand model interface size_bytes firmware controller \
            form_factor pcie_gen pcie_lanes logical_block_size \
            physical_block_size <<<"$row"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$key" "$brand" "$interface" "$size_bytes" "$firmware" \
            "$controller" "$form_factor" "$pcie_gen" "$pcie_lanes" \
            "$model" "$logical_block_size" "$physical_block_size"
    done
}

hardware_profile_validate_catalog() {
    local row key brand seen='|' default_seen='|' default_key found

    # Validate normalized component catalogs and the explicit combination
    # matrix in a subshell so audit calls never overwrite the caller's loaded
    # vm.conf variables.
    if ! (
        local model brand_string tsc part base max family upgrade chars cores
        local threads l1 l2 l3 l2assoc l3assoc generation socket mem_family
        local max_speed root_device root_revision
        local board revision chipset bios bios_date tpm board_slots max_gb
        local nvme_gen nvme_lanes xhci_device xhci_revision main_slot aux_slot
        local aux_type aux_width aux_length release_year serial_policy
        local mem_model_list mem_type mem_width module_list slots form rank_list
        local device_width_list voltage channel_mode module_jep_list dram_jep_list
        local cpu_key board_key memory_key module device_width rank mem_total
        local part index
        local used_cpu='|' used_board='|' used_memory='|' flat flat_count=0
        local seen_model='|'
        local -a parts modules ranks device_widths module_jeps dram_jeps
        local -A active_cpu_seen=() active_board_seen=() default_cpu_seen=()
        local -A active_memory_brand_seen=()

        seen='|'
        for row in "${CPU_PROFILES[@]}"; do
            IFS='|' read -r key model brand_string tsc part base max family \
                upgrade chars cores threads l1 l2 l3 l2assoc l3assoc \
                generation socket mem_family max_speed root_device \
                root_revision <<<"$row"
            [[ -n "$root_revision" && "$seen" != *"|$key|"* ]] || {
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
               "$l3assoc" == 9 &&
               ( "$generation" == 4 || "$generation" == 6 || "$generation" == 8 ) &&
               ( "$mem_family" == DDR3 || "$mem_family" == DDR4 ) &&
               "$max_speed" =~ ^[1-9][0-9]*$ &&
               "$root_device" =~ ^0x[0-9A-Fa-f]{4}$ &&
               "$root_revision" =~ ^0x[0-9A-Fa-f]{2}$ ]] || {
                echo "CPU profile 字段非法: $key" >&2
                exit 1
            }
            (( max >= base && cores * threads >= 2 && cores * threads <= 8 )) || {
                echo "CPU topology/frequency 未经审核: $key" >&2
                exit 1
            }
        done

        seen='|'
        for row in "${BOARD_PROFILES[@]}"; do
            IFS='|' read -r key brand board revision chipset bios bios_date tpm \
                board_slots max_gb nvme_gen nvme_lanes xhci_device \
                xhci_revision main_slot aux_slot aux_type aux_width aux_length \
                socket mem_family max_speed release_year serial_policy <<<"$row"
            [[ -n "$serial_policy" && "$seen" != *"|$key|"* ]] || {
                echo "重复或字段不完整的主板 profile: $key" >&2
                exit 1
            }
            seen+="$key|"
            [[ "$key" =~ ^[a-z0-9][a-z0-9-]*$ && -n "$brand" &&
               -n "$board" && -n "$revision" && -n "$chipset" &&
               -n "$bios" && "$bios_date" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}$ &&
               ( "$tpm" == none || "$tpm" == 1.2 || "$tpm" == 2.0 ) &&
               ( "$board_slots" == 2 || "$board_slots" == 4 ) &&
               "$max_gb" =~ ^[1-9][0-9]*$ &&
               "$nvme_gen" =~ ^[0-9]+$ && "$nvme_lanes" =~ ^[0-9]+$ &&
               "$xhci_device" =~ ^0x[0-9A-Fa-f]{4}$ &&
               "$xhci_revision" =~ ^0x[0-9A-Fa-f]{2}$ &&
               -n "$main_slot" && -n "$aux_slot" &&
               "$aux_type" =~ ^[0-9]+$ && "$aux_width" =~ ^[0-9]+$ &&
               "$aux_length" =~ ^[0-9]+$ &&
               ( "$mem_family" == DDR3 || "$mem_family" == DDR4 ) &&
               "$max_speed" =~ ^[1-9][0-9]*$ &&
               "$release_year" =~ ^20[0-9]{2}$ &&
               ( "$serial_policy" == asus || "$serial_policy" == msi ||
                 "$serial_policy" == gigabyte ) ]] || {
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
                'ASUSTeK COMPUTER INC.:asus'|'ASUS:asus'|Gigabyte:gigabyte|MSI:msi) ;;
                *)
                    echo "主板厂商与序列策略不匹配: $key/$brand/$serial_policy" >&2
                    exit 1
                    ;;
            esac
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
               "$mem_width" == 64 && "$slots" == 2 && "$form" == DIMM &&
               ( "$voltage" == 1200 || "$voltage" == 1500 ) &&
               ( "$channel_mode" == dual-channel || "$channel_mode" == flex ) ]] || {
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
                dual-channel)
                    [[ "${modules[0]}" == "${modules[1]}" &&
                       "${parts[0]}" == "${parts[1]}" &&
                       "${ranks[0]}" == "${ranks[1]}" &&
                       "${device_widths[0]}" == "${device_widths[1]}" &&
                       "${module_jeps[0]}" == "${module_jeps[1]}" &&
                       "${dram_jeps[0]}" == "${dram_jeps[1]}" ]] || {
                        echo "双通道 profile 必须是同容量同料号两条: $key" >&2
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
                new|explicit-new|legacy-compatibility) ;;
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
            [[ "$lifecycle" == legacy-compatibility || "$CPU_GENERATION" == 4 ]] || {
                echo "非 Haswell 平台不能进入 G-11 新建池: $key" >&2
                exit 1
            }
            if [[ "$lifecycle" != legacy-compatibility ]]; then
                (( MEM_BOARD_SLOTS == 2 && MEM_SLOTS == 2 )) || {
                    echo "新建池只允许两槽主板/两条内存: $key" >&2
                    exit 1
                }
                active_cpu_seen["$cpu_key"]=1
                active_board_seen["$board_key"]=1
                active_memory_brand_seen["$MEM_BRAND"]=1
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
        (( ${#active_cpu_seen[@]} == 6 && ${#active_board_seen[@]} == 4 &&
           ${#default_cpu_seen[@]} == 5 )) || {
            echo "新建池必须是 6 CPU（5 默认+1 显式）/4 块两槽主板" >&2
            exit 1
        }
        [[ -v active_cpu_seen[i7-4790] && ! -v default_cpu_seen[i7-4790] ]] || {
            echo "i7-4790 只能是显式高配，不能进入低端默认随机池" >&2
            exit 1
        }
        (( ${#active_memory_brand_seen[@]} == 4 )) &&
            [[ -v 'active_memory_brand_seen[Kingston]' &&
               -v 'active_memory_brand_seen[Samsung]' &&
               -v 'active_memory_brand_seen[Micron]' &&
               -v 'active_memory_brand_seen[SK hynix]' ]] || {
            echo "新建内存池必须覆盖 Kingston/Samsung/Micron/SK hynix 四厂" >&2
            exit 1
        }

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
    for default_key in "${SSD_DEFAULT_PROFILE_KEYS[@]}"; do
        [[ "$default_seen" != *"|$default_key|"* ]] || {
            echo "重复默认 SSD profile: $default_key" >&2
            return 1
        }
        default_seen+="$default_key|"
        found=0
        for row in "${SSD_PROFILES[@]}"; do
            IFS='|' read -r key _ <<<"$row"
            if [[ "$key" == "$default_key" ]]; then
                found=1
                IFS='|' read -r _ _ _ _ size _ _ _ _ _ <<<"$row"
                [[ "$size" == "$SSD_REQUIRED_SIZE_BYTES" ]] || return 1
                break
            fi
        done
        (( found )) || { echo "默认 SSD profile 不存在: $default_key" >&2; return 1; }
    done
    for row in "${SSD_PROFILES[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        [[ "$default_seen" == *"|$key|"* ]] || {
            echo "SSD profile 未进入默认审核 key 集: $key" >&2
            return 1
        }
    done

    local platform interface compatible_count
    for platform in $(hardware_profile_keys); do
        compatible_count=0
        for default_key in "${SSD_DEFAULT_PROFILE_KEYS[@]}"; do
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

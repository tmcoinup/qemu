#!/usr/bin/env bash
# Verified hardware identity catalog used by deploy/create-vm.sh.
# This file is deliberately side-effect free so tests and operators can source it.

# platform|cpu-model|tsc-hz|board-brand|board-model|board-revision|chipset|
# bios-version|bios-date|tpm-version|mem-brand|mem-model|mem-speed|mem-family|
# smbios-mem-type|width|module-MiB|populated-slots|form-factor|board-slots|
# maximum-memory-GiB|native-M.2-PCIe-generation|native-M.2-lanes
#
# BIOS sources (official vendor support pages):
#   https://www.gigabyte.com/Motherboard/GA-H97-D3H-rev-10/support
#   https://www.gigabyte.com/Motherboard/GA-B150M-D3H-rev-10/support
#   https://www.asus.com/supportonly/prime%20b360m-a/helpdesk_bios/
# Memory parts are desktop UDIMMs, not similarly named SO-DIMMs.
# TPM is conservative and board-bound: H97 uses its LPC TPM 1.2 header; the
# B150 firmware exposes TPM 2.0/PTT; B360 BIOS 3202 is Windows-11/PTT ready.
HARDWARE_PROFILES=(
    "i5-4590|Core-i5-4590|3300000000|Gigabyte|GA-H97-D3H|1.0|H97|F7|09/19/2015|1.2|Kingston|KVR16N11S8/4|1600|DDR3|0x18|64|4096|2|DIMM|4|32|2|2"
    "i5-6500|Core-i5-6500|3200000000|Gigabyte|GA-B150M-D3H|1.0|B150|F21|12/12/2016|2.0|Kingston|KVR21N15S8/4|2133|DDR4|0x1A|64|4096|2|DIMM|4|64|3|4"
    "i3-8100|Core-i3-8100|3600000000|ASUS|PRIME B360M-A|1.xx|B360|3202|07/24/2021|2.0|Kingston|KVR24N17S8/4|2400|DDR4|0x1A|64|4096|2|DIMM|4|64|3|4"
)

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
    for row in "${HARDWARE_PROFILES[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        printf '%s\n' "$key"
    done
}

hardware_profile_load() {
    local requested=$1 row key matched=""
    for row in "${HARDWARE_PROFILES[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        if [[ "$key" == "$requested" ]]; then
            matched=$row
            break
        fi
    done
    if [[ -z "$matched" ]]; then
        echo "未知平台: $requested" >&2
        return 2
    fi
    IFS='|' read -r PLATFORM CPU_MODEL TSC_FREQ BOARD_BRAND BOARD_MODEL \
        BOARD_REVISION BOARD_CHIPSET BIOS_VER BIOS_DATE BOARD_TPM_VERSION \
        MEM_BRAND MEM_MODEL MEM_SPEED MEM_FAMILY MEM_TYPE_BYTE MEM_WIDTH \
        MEM_MODULE_MB MEM_SLOTS MEM_FORM_FACTOR MEM_BOARD_SLOTS \
        MEM_MAX_CAPACITY_GB BOARD_NVME_PCIE_GEN BOARD_NVME_PCIE_LANES \
        <<<"$matched"
    MEM_TOTAL_MB=$((MEM_MODULE_MB * MEM_SLOTS))
}

# Guest-visible xHCI PCI identity belonging to each audited platform.  Keep
# this separate from CPU runtime details: create-vm persists the exact tuple,
# and start-vm reuses that immutable identity on every later boot.
hardware_xhci_identity_for_platform() {
    local requested=${1:-} device_id

    case "$requested" in
        i5-4590) device_id=0x8CB1 ;;
        i5-6500) device_id=0xA12F ;;
        i3-8100) device_id=0xA36D ;;
        *)
            echo "未知平台的 xHCI identity: ${requested:-<empty>}" >&2
            return 2
            ;;
    esac

    printf '0x8086|%s|0x01|pcie.0|0x6\n' "$device_id"
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
    local row key cpu tsc brand board revision chipset bios bios_date tpm
    local mem_brand mem_model mem_speed mem_family mem_type mem_width
    local module_mb slots form board_slots max_capacity_gb nvme_gen nvme_lanes
    local seen='|' default_key found
    for row in "${HARDWARE_PROFILES[@]}"; do
        IFS='|' read -r key cpu tsc brand board revision chipset bios bios_date tpm \
            mem_brand mem_model mem_speed mem_family mem_type mem_width \
            module_mb slots form board_slots max_capacity_gb nvme_gen nvme_lanes \
            <<<"$row"
        [[ "$seen" != *"|$key|"* ]] || { echo "重复平台: $key" >&2; return 1; }
        seen+="$key|"
        [[ "$tsc" =~ ^[1-9][0-9]+$ && "$bios_date" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}$ ]] || return 1
        [[ "$mem_speed" =~ ^[0-9]+$ && "$mem_width" == 64 ]] || return 1
        [[ "$module_mb" == 4096 && "$slots" == 2 && "$form" == DIMM \
            && "$board_slots" == 4 ]] || return 1
        case "$key|$chipset|$mem_family|$mem_model|$tpm|$max_capacity_gb|$nvme_gen|$nvme_lanes" in
            "i5-4590|H97|DDR3|KVR16N11S8/4|1.2|32|2|2"|\
            "i5-6500|B150|DDR4|KVR21N15S8/4|2.0|64|3|4"|\
            "i3-8100|B360|DDR4|KVR24N17S8/4|2.0|64|3|4") ;;
            *) echo "平台组合未经白名单核验: $key" >&2; return 1 ;;
        esac
    done

    seen='|'
    local model interface size firmware controller form_factor pcie_gen pcie_lanes
    local logical_block_size physical_block_size
    for row in "${SSD_PROFILES[@]}"; do
        IFS='|' read -r key brand model interface size firmware controller \
            form_factor pcie_gen pcie_lanes logical_block_size \
            physical_block_size <<<"$row"
        [[ "$seen" != *"|$key|"* ]] || { echo "重复 SSD profile: $key" >&2; return 1; }
        seen+="$key|"
        [[ "$size" == 512110190592 && "$key" == *-512gb &&
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
        found=0
        for row in "${SSD_PROFILES[@]}"; do
            IFS='|' read -r key _ <<<"$row"
            if [[ "$key" == "$default_key" ]]; then
                found=1
                IFS='|' read -r _ _ _ _ size _ _ _ _ _ <<<"$row"
                [[ "$size" == 512110190592 ]] || return 1
                break
            fi
        done
        (( found )) || { echo "默认 SSD profile 不存在: $default_key" >&2; return 1; }
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

#!/usr/bin/env bash
# shellcheck shell=bash
#
# vGPU identity catalog.
#
# The first two fields deliberately describe different things:
#   * key          — the consumer GPU identity advertised to the guest
#   * mdev_profile — the NVIDIA mediated-device resource allocated on host
#
# Each identity carries the matching legacy RTX-host resource: 1 GiB cards use
# nvidia-256 and 2 GiB cards use nvidia-257.  start-vm.sh may replace that host
# resource with an equal-sized VGPU_RESOURCE_PROFILE/VGPU_RESOURCE_FB_MB pair
# (for example V100-1Q/1024 or V100-2Q/2048).  In the production B path the
# system PCI identity still comes from the host mdev; the row below is the
# protected user-mode catalog projection.  None of these fields changes the
# physical GPU identity, clocks, framebuffer, or scheduler share.

# Schema 2 keeps every selectable consumer identity as one atomic row.  AIB
# board metadata is joined by key below and is part of the canonical digest;
# callers must never combine a board tuple from one row with memory/clocks from
# another row.
VGPU_PROFILE_CATALOG_SCHEMA=2

# key|mdev_profile|name|vid|did|subvid|subdid|rev|vram_mb|vbios|core_mhz|boost_mhz|memory_mhz|bus_bits|bandwidth_mbps|ram_type|ram_maker|memory_type_nvapi|memory_maker_nvapi|cuda_cores|shader_subpipes|rop_count|tmu_count|architecture|implementation|chip_revision|pcie_width
VGPU_PROFILE_CATALOG=(
    "gtx750ti_2gb|nvidia-257|NVIDIA GeForce GTX 750 Ti|0x10DE|0x1380|0x10DE|0x1380|0xA2|2048|Version 82.07.41.00.32|1020|1085|1350|128|86400|GDDR5|Samsung|8|1|640|5|16|40|0x110|7|0x12|16"
    "gt1030_2gb|nvidia-257|NVIDIA GeForce GT 1030|0x10DE|0x1D01|0x1043|0x85F9|0xA1|2048|Version 86.08.46.00.81|1227|1468|1502|64|48100|GDDR5|Samsung|8|1|384|3|16|24|0x130|8|0x11|4"
    "gtx1050_2gb|nvidia-257|NVIDIA GeForce GTX 1050|0x10DE|0x1C81|0x1028|0x11C0|0xA1|2048|Version 86.07.39.40.F4|1354|1455|1752|128|112000|GDDR5|Samsung|8|1|640|5|32|40|0x130|7|0x11|16"
    # Manufacturer pages establish the public model/P/N, capacity, bus and
    # advertised clocks for these discontinued cards.  They do not establish
    # a unique physical-card S/N or every production subsystem/VBIOS batch.
    # The low-level tuples below are G-11 catalog projections; read and bind
    # the actual subsystem/VBIOS/S/N during receiving instead of treating this
    # catalog as physical-board evidence.
    "gt740_1gb|nvidia-256|NVIDIA GeForce GT 740|0x10DE|0x0FC8|0x1462|0x8A9E|0xA1|1024|Version 80.07.D9.00.52|1006|1006|1250|128|80000|GDDR5|Samsung|8|1|384|4|16|32|0x100|7|0x11|16"
    "gt740_asus_1gb|nvidia-256|NVIDIA GeForce GT 740|0x10DE|0x0FC8|0x1043|0x8694|0xA1|1024|Version 80.07.D9.00.14|1033|1033|1250|128|80000|GDDR5|SK hynix|8|6|384|4|16|32|0x100|7|0x11|16"
    "gt740_gigabyte_1gb|nvidia-256|NVIDIA GeForce GT 740|0x10DE|0x0FC8|0x1458|0x368D|0xA1|1024|Version 80.07.D9.00.2A|1072|1072|1250|128|80000|GDDR5|Samsung|8|1|384|4|16|32|0x100|7|0x11|16"
    "gt740_zotac_1gb|nvidia-256|NVIDIA GeForce GT 740|0x10DE|0x0FC8|0x19DA|0x4291|0xA1|1024|Version 80.07.D9.00.3A|993|993|1250|128|80000|GDDR5|Micron|8|10|384|4|16|32|0x100|7|0x11|16"
    # ASUS GT730-1GD5-BRK is the GK208/GDDR5/64-bit card.  Do not mix this
    # identity with the older GF108 128-bit or DDR3 products sold as GT 730.
    "gt730_1gb|nvidia-256|NVIDIA GeForce GT 730|0x10DE|0x1287|0x1043|0x84E4|0xA1|1024|Version 80.28.6A.00.0B|902|902|1253|64|40100|GDDR5|Samsung|8|1|384|2|8|16|0x100|8|0x11|8"
    "gt730_msi_1gb|nvidia-256|NVIDIA GeForce GT 730|0x10DE|0x1287|0x1462|0x8A9F|0xA1|1024|Version 80.28.78.00.48|1006|1006|1250|64|40000|GDDR5|SK hynix|8|6|384|2|8|16|0x100|8|0x11|8"
    "gt730_gigabyte_1gb|nvidia-256|NVIDIA GeForce GT 730|0x10DE|0x1287|0x1458|0x3693|0xA1|1024|Version 80.28.7A.00.26|1006|1006|1253|64|40100|GDDR5|Samsung|8|1|384|2|8|16|0x100|8|0x11|8"
    "gt730_zotac_1gb|nvidia-256|NVIDIA GeForce GT 730|0x10DE|0x1287|0x19DA|0x730B|0xA1|1024|Version 80.28.7A.00.16|902|902|1253|64|40100|GDDR5|SK hynix|8|6|384|2|8|16|0x100|8|0x11|8"
    # NVIDIA's retail name is GTX 750 (device 1381), never RTX 750.  These
    # four 1 GiB rows are distinct from the existing GTX 750 Ti/1380 rows.
    "gtx750_asus_1gb|nvidia-256|NVIDIA GeForce GTX 750|0x10DE|0x1381|0x1043|0x8644|0xA2|1024|Version 82.07.25.00.09|1059|1137|1350|128|86400|GDDR5|Samsung|8|1|512|4|16|32|0x110|7|0x12|16"
    "gtx750_msi_1gb|nvidia-256|NVIDIA GeForce GTX 750|0x10DE|0x1381|0x1462|0x3107|0xA2|1024|Version 82.07.25.00.36|1085|1163|1253|128|80200|GDDR5|SK hynix|8|6|512|4|16|32|0x110|7|0x12|16"
    "gtx750_gigabyte_1gb|nvidia-256|NVIDIA GeForce GTX 750|0x10DE|0x1381|0x1458|0x362E|0xA2|1024|Version 82.07.32.40.6D|1059|1137|1250|128|80000|GDDR5|Elpida|8|3|512|4|16|32|0x110|7|0x12|16"
    "gtx750_zotac_1gb|nvidia-256|NVIDIA GeForce GTX 750|0x10DE|0x1381|0x19DA|0x288B|0xA2|1024|Version 82.07.32.00.2F|1033|1111|1253|128|80200|GDDR5|Samsung|8|1|512|4|16|32|0x110|7|0x12|16"
    "gtx750ti_asus_2gb|nvidia-257|NVIDIA GeForce GTX 750 Ti|0x10DE|0x1380|0x1043|0x84BB|0xA2|2048|Version 82.07.32.00.20|1072|1150|1350|128|86400|GDDR5|Samsung|8|1|640|5|16|40|0x110|7|0x12|16"
    "gtx750ti_msi_2gb|nvidia-257|NVIDIA GeForce GTX 750 Ti|0x10DE|0x1380|0x1462|0x8A9B|0xA2|2048|Version 82.07.25.00.1F|1059|1137|1350|128|86400|GDDR5|SK hynix|8|6|640|5|16|40|0x110|7|0x12|16"
    "gtx750ti_gigabyte_2gb|nvidia-257|NVIDIA GeForce GTX 750 Ti|0x10DE|0x1380|0x1458|0x362D|0xA2|2048|Version 82.07.55.00.05|1033|1111|1350|128|86400|GDDR5|Micron|8|10|640|5|16|40|0x110|7|0x12|16"
    "gt1030_galax_2gb|nvidia-257|NVIDIA GeForce GT 1030|0x10DE|0x1D01|0x10DE|0x11C7|0xA1|2048|Version 86.08.0C.00.2B|1253|1506|1502|64|48100|GDDR5|Samsung|8|1|384|3|16|24|0x130|8|0x11|4"
    "gt1030_asus_2gb|nvidia-257|NVIDIA GeForce GT 1030|0x10DE|0x1D01|0x1043|0x85F4|0xA1|2048|Version 86.08.0C.00.1A|1228|1468|1502|64|48100|GDDR5|SK hynix|8|6|384|3|16|24|0x130|8|0x11|4"
    "gt1030_msi_2gb|nvidia-257|NVIDIA GeForce GT 1030|0x10DE|0x1D01|0x1462|0x8C98|0xA1|2048|Version 86.08.0C.00.18|1266|1519|1502|64|48100|GDDR5|Micron|8|10|384|3|16|24|0x130|8|0x11|4"
    # PCI-SIG assigns 0x7377 to Shenzhen Colorful Yugong.  The matching
    # GTX1050 Gaming 2G V5 VBIOS record supplies 1C81/7377:0000/A1,
    # 86.07.39.80.02 and the reference 1354/1455/1752 MHz clock tuple.
    "gtx1050_colorful_2gb|nvidia-257|NVIDIA GeForce GTX 1050|0x10DE|0x1C81|0x7377|0x0000|0xA1|2048|Version 86.07.39.80.02|1354|1455|1752|128|112000|GDDR5|Samsung|8|1|640|5|32|40|0x130|7|0x11|16"
    "gtx1050_msi_2gb|nvidia-257|NVIDIA GeForce GTX 1050|0x10DE|0x1C81|0x1462|0x3354|0xA1|2048|Version 86.07.39.00.70|1418|1531|1752|128|112000|GDDR5|Micron|8|10|640|5|32|40|0x130|7|0x11|16"
    "gtx1050_gigabyte_2gb|nvidia-257|NVIDIA GeForce GTX 1050|0x10DE|0x1C81|0x1458|0x372D|0xA1|2048|Version 86.07.39.00.72|1380|1493|1752|128|112000|GDDR5|SK hynix|8|6|640|5|32|40|0x130|7|0x11|16"
    # EVGA publishes 02G-P4-3753-KR as 1176/1255 MHz, 5400 MHz effective,
    # 2 GiB GDDR5/128-bit/86.4 GB/s and 640 CUDA cores.  As with the existing
    # rows, the low-level subsystem/VBIOS tuple is an atomic protected-user-
    # mode catalog projection, never a firmware-flash or physical-S/N claim.
    # https://www.evga.com/products/Specs/GPU.aspx?pn=7eac3c86-1a83-4df9-8a8b-5c55264d2bd0
    "gtx750ti_evga_sc_2gb|nvidia-257|NVIDIA GeForce GTX 750 Ti|0x10DE|0x1380|0x3842|0x3753|0xA2|2048|Version 82.07.25.00.50|1176|1255|1350|128|86400|GDDR5|Samsung|8|1|640|5|16|40|0x110|7|0x12|16"
)

# Equal-size G-11 hosts use one framebuffer tier.  R580 on a supported V100 can
# instead publish both reviewed tiers in mixed-size mode.  The default random
# choice remains 2 GiB; an explicit 1 GiB request uses only the four Maxwell
# GTX 750 rows.  Kepler identities remain readable for old
# immutable vm.conf files, but cannot enter a new production-driver selection:
# the locked GRID 538.33/R535 branch post-dates Kepler's R470 support ceiling.
VGPU_DEFAULT_PROFILE_KEYS=(
    gtx750ti_2gb
    gt1030_2gb
    gtx1050_2gb
    gtx750ti_asus_2gb
    gtx750ti_msi_2gb
    gtx750ti_gigabyte_2gb
    gt1030_galax_2gb
    gt1030_asus_2gb
    gt1030_msi_2gb
    gtx1050_colorful_2gb
    gtx1050_msi_2gb
    gtx1050_gigabyte_2gb
)
VGPU_TIER_1024_PROFILE_KEYS=(
    gtx750_asus_1gb
    gtx750_msi_1gb
    gtx750_gigabyte_1gb
    gtx750_zotac_1gb
)
VGPU_EXPLICIT_PROFILE_KEYS=(
    gtx750ti_evga_sc_2gb
)
VGPU_LEGACY_PROFILE_KEYS=(
    gt740_1gb
    gt740_asus_1gb
    gt740_gigabyte_1gb
    gt740_zotac_1gb
    gt730_1gb
    gt730_msi_1gb
    gt730_gigabyte_1gb
    gt730_zotac_1gb
)

# Direct3D/NVAPI capability contract keyed by the consumer PCI device ID.
# All current G-11 models predate hardware RT/Tensor cores and have an expected
# DXR tier of zero.  The system NVAPI projection consumes the core counts for
# every NVAPI caller.  Direct D3D12 feature queries remain a property of the
# signed display transport and are audited separately; this table must never
# be described as changing ID3D12Device behavior.  A new device ID cannot enter
# the selectable catalog until it receives an explicit row here.
# device-id|D3D12-raytracing-tier|RT-cores|Tensor-cores
VGPU_CAPABILITY_CATALOG=(
    "0x0FC8|0|0|0"  # GT 740
    "0x1287|0|0|0"  # GT 730
    "0x1380|0|0|0"  # GTX 750 Ti
    "0x1381|0|0|0"  # GTX 750
    "0x1C81|0|0|0"  # GTX 1050
    "0x1D01|0|0|0"  # GT 1030
)

vgpu_profile_capability_load() {
    local requested=${1:-} row key did matched= capability_did

    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        IFS='|' read -r key _ _ _ did _ <<<"$row"
        [[ "$key" == "$requested" ]] || continue
        matched=$did
        break
    done
    [[ -n "$matched" ]] || {
        printf '未知 vGPU profile capability: %s\n' \
            "${requested:-<empty>}" >&2
        return 2
    }
    did=${matched^^}
    matched=
    for row in "${VGPU_CAPABILITY_CATALOG[@]}"; do
        IFS='|' read -r capability_did _ <<<"$row"
        [[ "${capability_did^^}" == "$did" ]] || continue
        matched=$row
        break
    done
    [[ -n "$matched" ]] || {
        printf 'vGPU profile 缺少 D3D12 capability: %s/%s\n' \
            "$requested" "$did" >&2
        return 2
    }
    IFS='|' read -r GPU_CAPABILITY_PCI_DEVICE_ID \
        GPU_D3D12_RAYTRACING_TIER GPU_RAY_TRACING_CORES \
        GPU_TENSOR_CORES <<<"$matched"
}

vgpu_profile_capability_contract() {
    local requested=${1:-}

    (
        vgpu_profile_capability_load "$requested" || exit
        printf '%s|%s|%s|%s\n' "$GPU_CAPABILITY_PCI_DEVICE_ID" \
            "$GPU_D3D12_RAYTRACING_TIER" "$GPU_RAY_TRACING_CORES" \
            "$GPU_TENSOR_CORES"
    )
}

# Private R535/GPU-Z 2.70 RAM-maker values accepted by this branch.  The
# user-facing name, private NVAPI label and numeric value are kept together so
# registry writers and query tools cannot disagree about enum rendering.
# display_name|nvapi_name|nvapi_value
VGPU_MEMORY_MAKER_CATALOG=(
    "Samsung|Samsung|1"
    "Elpida|Elpida|3"
    "SK hynix|Hynix|6"
    "Micron|Micron|10"
)

# The unmodified GRID 538.33 package exposes a different native subsystem for
# the two reviewed RTX6000 resource sizes.  B/name-only keeps that transport
# identity intact: nvidia-256 is RTX6000-1Q (1325), while nvidia-257 is
# RTX6000-2Q (1326).  The independently reviewed V100/R535 1Q path keeps its
# physical V100 transport (1DB1/125A) even though its host mdev alias is also
# nvidia-256.  Accept an optional exact host resource name to disambiguate it;
# unverified V100 2Q identities remain fail-closed.
vgpu_profile_native_grid_pnp_id() {
    local mdev_profile=$1 resource_profile=${2:-}

    case "$mdev_profile|$resource_profile" in
        'nvidia-256|V100X-1Q')
            printf '%s\n' 'PCI\VEN_10DE&DEV_1DB1&SUBSYS_125A10DE'
            ;;
        'nvidia-256|'|'nvidia-256|nvidia-256')
            printf '%s\n' 'PCI\VEN_10DE&DEV_1E30&SUBSYS_132510DE'
            ;;
        'nvidia-257|'|'nvidia-257|nvidia-257')
            printf '%s\n' 'PCI\VEN_10DE&DEV_1E30&SUBSYS_132610DE'
            ;;
        *)
            printf 'vGPU B/native transport 没有受支持的 mdev/resource/PnP 映射: %s/%s\n' \
                "$mdev_profile" "${resource_profile:-default}" >&2
            return 1
            ;;
    esac
}

# NVAPI/GPU-Z and NV2080_CTRL_FB_GET_INFO_V2 use different numeric domains
# for the memory maker.  Samsung and Hynix happen to match; Micron is 10 in
# the private NVAPI projection but 0x0F in NVIDIA's RM control ABI.
vgpu_profile_rm_memory_vendor_value() {
    case "$1|$2" in
        'Samsung|1') printf '%s\n' 1 ;;
        'Elpida|3') printf '%s\n' 3 ;;
        'SK hynix|6') printf '%s\n' 6 ;;
        'Micron|10') printf '%s\n' 15 ;;
        *)
            printf 'vGPU profile 显存厂商没有受支持的 RM enum 映射: %s=%s\n' \
                "$1" "$2" >&2
            return 1
            ;;
    esac
}

vgpu_profile_validate_rm_fb_identity_values() {
    local bus_width=$1 ram_type=$2 memory_vendor=$3
    case "$bus_width" in
        32|64|96|128|160|192|256|320|352|384|448|512) ;;
        *) return 1 ;;
    esac
    case "$ram_type" in
        0|1|2|3|4|5|6|7|8|9|12|13|14|15|16|17|18|19|20) ;;
        *) return 1 ;;
    esac
    case "$memory_vendor" in
        1|2|3|4|5|6|7|8|9|15|4294967295) ;;
        *) return 1 ;;
    esac
}

# B mode keeps the system PCI identity supplied by the host mdev.  These board
# identities are consumed by the protected user-mode identity projection and
# the authoritative query tool.  They are included in the schema-2 digest.
# key|board_brand|board_model|board_identity|serial_policy|identity_scope
VGPU_PROFILE_BOARD_METADATA=(
    "gtx750ti_2gb|NVIDIA|Reference|subsystem=0x10DE:0x1380|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gt1030_2gb|ASUS|OEM 85F9|subsystem=0x1043:0x85F9|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx1050_2gb|Dell|OEM|subsystem=0x1028:0x11C0|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gt740_1gb|MSI|N740-1GD5|subsystem=0x1462:0x8A9E|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gt740_asus_1gb|ASUS|GT740-OC-1GD5|subsystem=0x1043:0x8694|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gt740_gigabyte_1gb|Gigabyte|GV-N740D5OC-1GI|subsystem=0x1458:0x368D|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gt740_zotac_1gb|ZOTAC|ZT-71002-10L|subsystem=0x19DA:0x4291|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gt730_1gb|ASUS|GT730-1GD5-BRK|subsystem=0x1043:0x84E4|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gt730_msi_1gb|MSI|N730K-1GD5LP-OC|subsystem=0x1462:0x8A9F|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gt730_gigabyte_1gb|Gigabyte|GV-N730D5OC-1GI|subsystem=0x1458:0x3693|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gt730_zotac_1gb|ZOTAC|ZT-71102-10L|subsystem=0x19DA:0x730B|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx750_asus_1gb|ASUS|GTX750-PHOC-1GD5|subsystem=0x1043:0x8644|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx750_msi_1gb|MSI|N750-GAMING-1GD5-OC|subsystem=0x1462:0x3107|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx750_gigabyte_1gb|Gigabyte|GV-N750OC-1GI|subsystem=0x1458:0x362E|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx750_zotac_1gb|ZOTAC|ZT-70701-10M|subsystem=0x19DA:0x288B|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx750ti_asus_2gb|ASUS|OC|subsystem=0x1043:0x84BB|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx750ti_msi_2gb|MSI|OC|subsystem=0x1462:0x8A9B|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx750ti_gigabyte_2gb|Gigabyte|OC|subsystem=0x1458:0x362D|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gt1030_galax_2gb|GALAX|EXOC White|subsystem=0x10DE:0x11C7|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gt1030_asus_2gb|ASUS|Silent|subsystem=0x1043:0x85F4|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gt1030_msi_2gb|MSI|LP OCV1|subsystem=0x1462:0x8C98|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx1050_colorful_2gb|Colorful|GTX1050 Gaming 2G V5|subsystem=0x7377:0x0000|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx1050_msi_2gb|MSI|Gaming X|subsystem=0x1462:0x3354|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx1050_gigabyte_2gb|Gigabyte|OC|subsystem=0x1458:0x372D|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx750ti_evga_sc_2gb|EVGA|02G-P4-3753-KR|subsystem=0x3842:0x3753|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
)

vgpu_profile_validate_board_metadata_catalog() {
    local row pipes key board_brand board_model board_identity serial_policy identity_scope
    local profile_row profile_key profile_subvid profile_subdid
    local expected_brand expected_identity found
    local seen_keys='|' seen_identities='|'

    for row in "${VGPU_PROFILE_BOARD_METADATA[@]}"; do
        pipes=${row//[^|]/}
        if ((${#pipes} != 5)); then
            printf '非法 vGPU board metadata（必须恰好 6 个字段）: %s\n' \
                "$row" >&2
            return 1
        fi
        IFS='|' read -r key board_brand board_model board_identity serial_policy \
            identity_scope <<<"$row"
        if ! [[ "$key" =~ ^[a-z0-9_]+$ ]] ||
                [[ -z "$board_brand" || -z "$board_model" ||
                   -z "$board_identity" ||
                   -z "$serial_policy" || -z "$identity_scope" ]]; then
            printf 'vGPU board metadata 含空值或非法 key: %s\n' "$row" >&2
            return 1
        fi
        if [[ "$seen_keys" == *"|$key|"* ||
              "$seen_identities" == *"|$board_identity|"* ]]; then
            printf '重复 vGPU board metadata key 或 board identity: %s\n' \
                "$row" >&2
            return 1
        fi

        found=0
        for profile_row in "${VGPU_PROFILE_CATALOG[@]}"; do
            IFS='|' read -r profile_key _ _ _ _ profile_subvid \
                profile_subdid _ <<<"$profile_row"
            if [[ "$profile_key" == "$key" ]]; then
                found=1
                break
            fi
        done
        if ((found == 0)); then
            printf 'vGPU board metadata 引用了不存在的 profile: %s\n' \
                "$key" >&2
            return 1
        fi

        case "$profile_subvid:$board_brand" in
            0x10DE:NVIDIA|0x10DE:GALAX|0x1043:ASUS|0x1028:Dell|\
            0x1462:MSI|0x1458:Gigabyte|0x19DA:ZOTAC|0x7377:Colorful|\
            0x3842:EVGA)
                expected_brand=$board_brand
                ;;
            *)
                printf 'vGPU profile subvendor 没有受支持的板卡品牌映射: %s=%s\n' \
                    "$key" "$profile_subvid" >&2
                return 1
                ;;
        esac
        expected_identity="subsystem=$profile_subvid:$profile_subdid"
        if [[ "$board_brand" != "$expected_brand" ||
              "$board_identity" != "$expected_identity" ]]; then
            printf 'vGPU board metadata 与 profile subsystem 不一致: %s\n' \
                "$row" >&2
            return 1
        fi
        if [[ "$serial_policy" != not-exposed ]]; then
            printf 'vGPU board serial-policy 必须是 not-exposed: %s\n' \
                "$row" >&2
            return 1
        fi
        if [[ "$identity_scope" != \
                'B:system-pci=host-mdev,catalog=protected-user-mode' ]]; then
            printf 'vGPU board identity-scope 必须保持 B host-mdev/app-local 边界: %s\n' \
                "$row" >&2
            return 1
        fi
        seen_keys+="$key|"
        seen_identities+="$board_identity|"
    done

    if ((${#VGPU_PROFILE_BOARD_METADATA[@]} != ${#VGPU_PROFILE_CATALOG[@]})); then
        printf 'vGPU board metadata 必须与 profile catalog 一一对应\n' >&2
        return 1
    fi
    for profile_row in "${VGPU_PROFILE_CATALOG[@]}"; do
        IFS='|' read -r profile_key _ <<<"$profile_row"
        if [[ "$seen_keys" != *"|$profile_key|"* ]]; then
            printf 'vGPU profile 缺少 board metadata: %s\n' "$profile_key" >&2
            return 1
        fi
    done
}

vgpu_profile_load_board_metadata() {
    local requested=$1 row key board_brand board_model board_identity
    local serial_policy identity_scope

    for row in "${VGPU_PROFILE_BOARD_METADATA[@]}"; do
        IFS='|' read -r key board_brand board_model board_identity serial_policy \
            identity_scope <<<"$row"
        if [[ "$key" == "$requested" ]]; then
            GPU_BOARD_BRAND=$board_brand
            GPU_BOARD_MODEL=$board_model
            GPU_BOARD_IDENTITY=$board_identity
            GPU_SERIAL_POLICY=$serial_policy
            GPU_IDENTITY_SCOPE=$identity_scope
            return 0
        fi
    done

    printf 'vGPU profile 缺少 board metadata: %s\n' "$requested" >&2
    return 1
}

vgpu_profile_validate_memory_maker_metadata() {
    local display_name=$1 numeric_value=$2 row catalog_display nvapi_name catalog_value
    local matches=0

    for row in "${VGPU_MEMORY_MAKER_CATALOG[@]}"; do
        IFS='|' read -r catalog_display nvapi_name catalog_value <<<"$row"
        if [[ "$catalog_display" == "$display_name" &&
              "$catalog_value" == "$numeric_value" ]]; then
            ((matches += 1))
        fi
    done
    if ((matches != 1)); then
        printf 'vGPU profile 显存厂商没有唯一 enum 映射: %s=%s\n' \
            "$display_name" "$numeric_value" >&2
        return 1
    fi
    vgpu_profile_rm_memory_vendor_value "$display_name" "$numeric_value" \
        >/dev/null
}

vgpu_profile_load_memory_maker_metadata() {
    local display_name=$1 numeric_value=$2 row catalog_display nvapi_name catalog_value

    vgpu_profile_validate_memory_maker_metadata \
        "$display_name" "$numeric_value" || return 1
    for row in "${VGPU_MEMORY_MAKER_CATALOG[@]}"; do
        IFS='|' read -r catalog_display nvapi_name catalog_value <<<"$row"
        if [[ "$catalog_display" == "$display_name" &&
              "$catalog_value" == "$numeric_value" ]]; then
            GPU_MEMORY_MAKER_NVAPI_NAME=$nvapi_name
            break
        fi
    done
    GPU_MEMORY_VENDOR_RM=$(
        vgpu_profile_rm_memory_vendor_value "$display_name" "$numeric_value"
    ) || return 1
}

vgpu_profile_validate_catalog() {
    local row key mdev name vid did subvid subdid rev vram vbios
    local core boost memory bus bandwidth ram_type ram_maker
    local memory_type_nvapi memory_maker_nvapi cuda_cores shader_subpipes
    local rop_count tmu_count architecture implementation chip_revision pcie_width
    local raw_memory_khz derived_bandwidth bandwidth_difference rm_memory_vendor
    local seen_keys='|' seen_pci='|' seen_capability_dids='|'
    local capability_did dxr_tier rt_cores tensor_cores

    for row in "${VGPU_CAPABILITY_CATALOG[@]}"; do
        IFS='|' read -r capability_did dxr_tier rt_cores tensor_cores \
            <<<"$row"
        capability_did=${capability_did^^}
        [[ "$capability_did" =~ ^0X[0-9A-F]{4}$ &&
           "$seen_capability_dids" != *"|$capability_did|"* &&
           "$dxr_tier" == 0 && "$rt_cores" == 0 &&
           "$tensor_cores" == 0 ]] || {
            printf 'vGPU D3D12 capability 未经审核: %s\n' "$row" >&2
            return 1
        }
        seen_capability_dids+="$capability_did|"
    done
    ((${#VGPU_CAPABILITY_CATALOG[@]} == 6)) || {
        printf '当前 vGPU capability 目录必须精确覆盖六个 device ID\n' >&2
        return 1
    }

    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        IFS='|' read -r key mdev name vid did subvid subdid rev vram vbios \
            core boost memory bus bandwidth ram_type ram_maker \
            memory_type_nvapi memory_maker_nvapi cuda_cores shader_subpipes \
            rop_count tmu_count architecture implementation chip_revision pcie_width \
            <<<"$row"
        if [[ -z "$key" || -z "$name" ]]; then
            printf '非法 vGPU profile（key/name 不能为空）: %s\n' "$row" >&2
            return 1
        fi
        case "$vram:$mdev" in
            1024:nvidia-256|2048:nvidia-257) ;;
            *)
                printf '非法 vGPU profile（仅允许 nvidia-256/1024MB 或 nvidia-257/2048MB）: %s\n' \
                    "$row" >&2
                return 1
                ;;
        esac
        if ! [[ "$vram" =~ ^[1-9][0-9]*$ ]]; then
            printf 'vGPU profile 显存容量必须是正整数: %s\n' "$row" >&2
            return 1
        fi
        if [[ "$seen_keys" == *"|$key|"* ||
              "$seen_pci" == *"|$vid:$did:$subvid:$subdid|"* ]]; then
            printf '重复 vGPU profile key 或完整 PCI subsystem tuple: %s\n' "$row" >&2
            return 1
        fi
        if ! [[ "$core" =~ ^[1-9][0-9]*$ && "$boost" =~ ^[1-9][0-9]*$ &&
                "$memory" =~ ^[1-9][0-9]*$ && "$bus" =~ ^[1-9][0-9]*$ &&
                "$bandwidth" =~ ^[1-9][0-9]*$ ]]; then
            printf 'vGPU profile 频率/位宽/带宽必须是正整数: %s\n' "$row" >&2
            return 1
        fi
        if (( boost < core )); then
            printf 'vGPU profile boost 频率不能低于 core 频率: %s\n' "$row" >&2
            return 1
        fi
        if [[ "$ram_type" != GDDR5 || "$memory_type_nvapi" != 8 ]] ||
                ! vgpu_profile_validate_memory_maker_metadata \
                    "$ram_maker" "$memory_maker_nvapi"; then
            printf 'vGPU profile 显存身份必须来自受支持 GDDR5/RAM-maker 目录: %s\n' "$row" >&2
            return 1
        fi
        rm_memory_vendor=$(
            vgpu_profile_rm_memory_vendor_value \
                "$ram_maker" "$memory_maker_nvapi"
        ) || return 1
        if ! vgpu_profile_validate_rm_fb_identity_values \
                "$bus" "$memory_type_nvapi" "$rm_memory_vendor"; then
            printf 'vGPU profile 显存身份不能映射为安全 RM FB 合同: %s\n' \
                "$row" >&2
            return 1
        fi
        # GPU-Z 2.70 renders a GDDR5 NVAPI memory-domain value at half of
        # its raw clock.  The shim therefore publishes display MHz * 2000
        # kHz, and theoretical decimal MB/s is raw_kHz * 2 * bus / 8000.
        # Keep every catalog row coherent within one percent so adding a new
        # model cannot silently reintroduce an Unknown/implausible bandwidth.
        raw_memory_khz=$((memory * 2000))
        derived_bandwidth=$((raw_memory_khz * 2 * bus / 8000))
        bandwidth_difference=$((derived_bandwidth - bandwidth))
        (( bandwidth_difference >= 0 )) || \
            bandwidth_difference=$((-bandwidth_difference))
        if (( bandwidth_difference * 100 > bandwidth )); then
            printf 'vGPU profile 显存频率/位宽/带宽不一致（容差 1%%，推导 %s MB/s）: %s\n' \
                "$derived_bandwidth" "$row" >&2
            return 1
        fi
        if ! [[ "$cuda_cores" =~ ^[1-9][0-9]*$ &&
                "$shader_subpipes" =~ ^[1-9][0-9]*$ &&
                "$rop_count" =~ ^[1-9][0-9]*$ &&
                "$tmu_count" =~ ^[1-9][0-9]*$ &&
                "$implementation" =~ ^[1-9][0-9]*$ &&
                "$pcie_width" =~ ^[1-9][0-9]*$ &&
                "$architecture" =~ ^0x[0-9A-Fa-f]+$ &&
                "$chip_revision" =~ ^0x[0-9A-Fa-f]+$ ]]; then
            printf 'vGPU profile 核心/架构/PCIe 身份字段非法: %s\n' "$row" >&2
            return 1
        fi
        if (( tmu_count != shader_subpipes * 8 )); then
            printf 'vGPU profile TMU 必须等于 shader subpipes * 8: %s\n' \
                "$row" >&2
            return 1
        fi
        if (( tmu_count > 1000000 )); then
            printf 'vGPU profile TMU 超出 1..1000000: %s\n' "$row" >&2
            return 1
        fi
        case "$pcie_width" in
            1|2|4|8|16|32) ;;
            *)
                printf 'vGPU profile PCIe width 必须是 1/2/4/8/16/32: %s\n' \
                    "$row" >&2
                return 1
                ;;
        esac
        vgpu_profile_capability_load "$key" || return 1
        [[ "${GPU_CAPABILITY_PCI_DEVICE_ID^^}" == "${did^^}" &&
           "$GPU_D3D12_RAYTRACING_TIER" == 0 &&
           "$GPU_RAY_TRACING_CORES" == 0 &&
           "$GPU_TENSOR_CORES" == 0 ]] || {
            printf 'vGPU profile 与 D3D12 capability 不一致: %s\n' "$key" >&2
            return 1
        }
        seen_keys+="$key|"
        seen_pci+="$vid:$did:$subvid:$subdid|"
    done

    vgpu_profile_validate_board_metadata_catalog &&
        vgpu_profile_validate_selection_policy_catalog
}

vgpu_profile_keys() {
    local row key
    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        printf '%s\n' "$key"
    done
}

vgpu_profile_default_keys() {
    printf '%s\n' "${VGPU_DEFAULT_PROFILE_KEYS[@]}"
}

# Normalize the operator-facing capacity selector.  The catalog and vm.conf
# remain MiB-based; accepting the short 1G/2G spellings keeps the create/clone
# workflow compatible with the V-11 style capacity choice.
vgpu_profile_normalize_vram_mb() {
    local requested=${1:-}

    requested=${requested,,}
    requested=${requested//[[:space:]]/}
    case "$requested" in
        1|1g|1gb|1gib|1024|1024m|1024mb|1024mib)
            printf '%s\n' 1024
            ;;
        2|2g|2gb|2gib|2048|2048m|2048mb|2048mib)
            printf '%s\n' 2048
            ;;
        *)
            printf 'vGPU 显存档位只支持 1024 MB 或 2048 MB，当前: %s\n' \
                "${1:-<empty>}" >&2
            return 2
            ;;
    esac
}

vgpu_profile_default_keys_for_vram() {
    local requested=${1:-} normalized

    normalized=$(vgpu_profile_normalize_vram_mb "$requested") || return
    case "$normalized" in
        1024) printf '%s\n' "${VGPU_TIER_1024_PROFILE_KEYS[@]}" ;;
        2048) printf '%s\n' "${VGPU_DEFAULT_PROFILE_KEYS[@]}" ;;
    esac
}

vgpu_profile_explicit_keys() {
    printf '%s\n' "${VGPU_EXPLICIT_PROFILE_KEYS[@]}"
}

vgpu_profile_legacy_keys() {
    printf '%s\n' "${VGPU_LEGACY_PROFILE_KEYS[@]}"
}

vgpu_profile_is_default() {
    local requested=${1:-} key

    for key in "${VGPU_DEFAULT_PROFILE_KEYS[@]}"; do
        [[ "$key" == "$requested" ]] && return 0
    done
    return 1
}

vgpu_profile_is_default_for_vram() {
    local requested=${1:-} tier=${2:-} key

    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        [[ "$key" == "$requested" ]] && return 0
    done < <(vgpu_profile_default_keys_for_vram "$tier")
    return 1
}

vgpu_profile_is_legacy() {
    local requested=${1:-} key

    for key in "${VGPU_LEGACY_PROFILE_KEYS[@]}"; do
        [[ "$key" == "$requested" ]] && return 0
    done
    return 1
}

vgpu_profile_validate_selection_policy_catalog() {
    local key row profile_key found policy
    local seen='|'
    local -a keys=()

    for policy in default tier-1024 explicit legacy; do
        case "$policy" in
            default) keys=("${VGPU_DEFAULT_PROFILE_KEYS[@]}") ;;
            tier-1024) keys=("${VGPU_TIER_1024_PROFILE_KEYS[@]}") ;;
            explicit) keys=("${VGPU_EXPLICIT_PROFILE_KEYS[@]}") ;;
            legacy) keys=("${VGPU_LEGACY_PROFILE_KEYS[@]}") ;;
        esac
        for key in "${keys[@]}"; do
            [[ "$seen" != *"|$key|"* ]] || {
                printf '重复或跨层 vGPU profile: %s\n' "$key" >&2
                return 1
            }
            found=0
            for row in "${VGPU_PROFILE_CATALOG[@]}"; do
                profile_key=${row%%|*}
                if [[ "$profile_key" == "$key" ]]; then
                    found=1
                    break
                fi
            done
            ((found == 1)) || {
                printf '%s vGPU profile 不存在: %s\n' "$policy" "$key" >&2
                return 1
            }
            seen+="$key|"
        done
    done
    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        profile_key=${row%%|*}
        [[ "$seen" == *"|$profile_key|"* ]] || {
            printf 'vGPU profile 未进入默认或显式审核 key 集: %s\n' \
                "$profile_key" >&2
            return 1
        }
    done
}

_vgpu_profile_random_index() {
    local count=${1:-0}
    local raw range limit

    ((count > 0)) || {
        printf 'vGPU random selection requires a non-empty catalog\n' >&2
        return 2
    }

    # Reject the incomplete tail before taking the modulus.  That keeps every
    # audited profile equiprobable instead of giving the first rows a tiny
    # modulo advantage.  /dev/urandom is preferred; Bash RANDOM is only the
    # availability fallback and receives the same rejection treatment.
    if [[ -r /dev/urandom ]]; then
        range=4294967296
        limit=$((range - (range % count)))
        while :; do
            raw=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null) || raw=
            raw=${raw//[[:space:]]/}
            [[ "$raw" =~ ^[0-9]+$ ]] || break
            if ((raw < limit)); then
                printf '%s\n' "$((raw % count))"
                return 0
            fi
        done
    fi

    range=1073741824
    limit=$((range - (range % count)))
    while :; do
        raw=$(((RANDOM << 15) | RANDOM))
        if ((raw < limit)); then
            printf '%s\n' "$((raw % count))"
            return 0
        fi
    done
}

vgpu_profile_pick_random() {
    local index key

    vgpu_profile_validate_catalog || return
    ((${#VGPU_DEFAULT_PROFILE_KEYS[@]} > 0)) || {
        printf 'vGPU default profile catalog is empty\n' >&2
        return 1
    }
    index=$(_vgpu_profile_random_index "${#VGPU_DEFAULT_PROFILE_KEYS[@]}") || return
    if ! [[ "$index" =~ ^[0-9]+$ ]] ||
            ((index >= ${#VGPU_DEFAULT_PROFILE_KEYS[@]})); then
        printf 'vGPU random selector returned an invalid index: %s\n' \
            "$index" >&2
        return 1
    fi
    key=${VGPU_DEFAULT_PROFILE_KEYS[$index]}
    vgpu_profile_load "$key"
}

# Capacity is a hard pre-selection constraint: first build the reviewed
# same-sized default pool, then choose one atomic row from it.  Never pick a
# card first and rewrite only GPU_VRAM_MB afterwards, because that would split
# the mdev resource, board identity and memory metadata contract.
vgpu_profile_pick_random_vram() {
    local requested=${1:-} normalized index key
    local -a candidates=()

    vgpu_profile_validate_catalog || return
    normalized=$(vgpu_profile_normalize_vram_mb "$requested") || return
    mapfile -t candidates < <(vgpu_profile_default_keys_for_vram "$normalized")
    ((${#candidates[@]} > 0)) || {
        printf 'vGPU 默认审核池没有 %sMB 候选\n' "$normalized" >&2
        return 1
    }
    index=$(_vgpu_profile_random_index "${#candidates[@]}") || return
    if ! [[ "$index" =~ ^[0-9]+$ ]] || ((index >= ${#candidates[@]})); then
        printf 'vGPU capacity selector returned an invalid index: %s\n' \
            "$index" >&2
        return 1
    fi
    key=${candidates[$index]}
    vgpu_profile_load "$key"
}

# Canonical digest used by the portable guest bundle and the read-only
# per-boot SMBIOS claim.  Hash the literal catalog rows, including their
# ordering and trailing newline, so a host and a prebuilt guest EXE cannot
# silently disagree about what a profile key means.
vgpu_profile_catalog_sha256() {
    {
        printf 'VGPU_PROFILE_CATALOG_SCHEMA=%s\n' \
            "$VGPU_PROFILE_CATALOG_SCHEMA"
        printf 'profile|%s\n' "${VGPU_PROFILE_CATALOG[@]}"
        printf 'board|%s\n' "${VGPU_PROFILE_BOARD_METADATA[@]}"
        printf 'memory-maker|%s\n' "${VGPU_MEMORY_MAKER_CATALOG[@]}"
    } | sha256sum | awk '{print toupper($1)}'
}

vgpu_profile_load() {
    local requested=$1 row key

    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        IFS='|' read -r \
            key VGPU_MDEV_PROFILE GPU_NAME GPU_PCI_VID GPU_PCI_DID \
            GPU_SUB_VID GPU_SUB_DID GPU_REV GPU_VRAM_MB GPU_VBIOS \
            GPU_CORE_MHZ GPU_BOOST_MHZ GPU_MEMORY_MHZ \
            GPU_MEMORY_BUS_BITS GPU_MEMORY_BANDWIDTH_MBPS \
            GPU_MEMORY_TYPE GPU_MEMORY_MAKER \
            GPU_MEMORY_TYPE_NVAPI GPU_MEMORY_MAKER_NVAPI \
            GPU_CUDA_CORES GPU_SHADER_SUBPIPES GPU_ROP_COUNT GPU_TMU_COUNT \
            GPU_ARCHITECTURE GPU_IMPLEMENTATION GPU_CHIP_REVISION \
            GPU_PCIE_WIDTH <<<"$row"
        if [[ "$key" == "$requested" ]]; then
            GPU_PROFILE=$key
            vgpu_profile_load_board_metadata "$key"
            vgpu_profile_load_memory_maker_metadata \
                "$GPU_MEMORY_MAKER" "$GPU_MEMORY_MAKER_NVAPI" || return 1
            return
        fi
    done

    printf '未知 vGPU identity profile: %s（可选: %s）\n' \
        "$requested" "$(vgpu_profile_keys | paste -sd, -)" >&2
    return 1
}

vgpu_profile_print_catalog() {
    local row
    printf '%-25s %-28s %-7s %-15s %-10s %-10s %-11s %s\n' \
        PROFILE NAME VRAM CLOCKS BOARD VRAM-MAKER SERIAL MDEV
    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        IFS='|' read -r \
            GPU_PROFILE VGPU_MDEV_PROFILE GPU_NAME _ _ _ _ _ \
            GPU_VRAM_MB _ GPU_CORE_MHZ GPU_BOOST_MHZ GPU_MEMORY_MHZ \
            _ _ _ GPU_MEMORY_MAKER _ _ _ _ _ _ _ _ _ _ <<<"$row"
        vgpu_profile_load_board_metadata "$GPU_PROFILE" || return 1
        printf '%-25s %-28s %4s MB %4s/%4s/%4s MHz %-10s %-10s %-11s %s\n' \
            "$GPU_PROFILE" "$GPU_NAME" "$GPU_VRAM_MB" \
            "$GPU_CORE_MHZ" "$GPU_BOOST_MHZ" "$GPU_MEMORY_MHZ" \
            "$GPU_BOARD_BRAND" "$GPU_MEMORY_MAKER" \
            "$GPU_SERIAL_POLICY" "$VGPU_MDEV_PROFILE"
    done
}

# Stable tab-separated projection for management UIs.  Unlike the aligned
# human-readable table above, every row has an invariant column count and the
# model/board brand are separate fields, so callers never have to infer an AIB
# vendor from spacing or from the profile key.
vgpu_profile_print_tsv_catalog() {
    local active_selector=${1:-2048} row auto_random

    if [[ "$active_selector" != mixed ]]; then
        active_selector=$(vgpu_profile_normalize_vram_mb "$active_selector") || return
    fi

    printf 'PROFILE\tMODEL\tBOARD_BRAND\tBOARD_MODEL\tVRAM_MIB\tVRAM_MAKER\tMDEV\tAUTO_RANDOM\n'
    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        IFS='|' read -r \
            GPU_PROFILE VGPU_MDEV_PROFILE GPU_NAME _ _ _ _ _ \
            GPU_VRAM_MB _ _ _ _ _ _ _ GPU_MEMORY_MAKER \
            _ _ _ _ _ _ _ _ _ _ <<<"$row"
        vgpu_profile_load_board_metadata "$GPU_PROFILE" || return 1
        if [[ "$active_selector" == mixed ]] && {
                vgpu_profile_is_default_for_vram "$GPU_PROFILE" 1024 ||
                vgpu_profile_is_default_for_vram "$GPU_PROFILE" 2048
            }; then
            auto_random=1
        elif [[ "$active_selector" != mixed ]] &&
                vgpu_profile_is_default_for_vram "$GPU_PROFILE" "$active_selector"; then
            auto_random=1
        else
            auto_random=0
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$GPU_PROFILE" "$GPU_NAME" "$GPU_BOARD_BRAND" \
            "$GPU_BOARD_MODEL" "$GPU_VRAM_MB" "$GPU_MEMORY_MAKER" \
            "$VGPU_MDEV_PROFILE" "$auto_random"
    done
}

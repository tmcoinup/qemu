#!/usr/bin/env bash
# shellcheck shell=bash
#
# vGPU identity catalog.
#
# The first two fields deliberately describe different things:
#   * key          — the consumer GPU identity advertised to the guest
#   * mdev_profile — the NVIDIA mediated-device resource allocated on host
#
# Every identity in this catalog carries the legacy RTX-host default of a
# 2 GiB nvidia-257 mdev.  start-vm.sh may replace that host resource with
# VGPU_RESOURCE_PROFILE/VGPU_RESOURCE_FB_MB (for example V100-2Q/2048) while
# retaining all guest-visible fields below.  These fields do not change the
# physical GPU clocks or scheduler share.

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
)

# Private R535/GPU-Z 2.70 RAM-maker values accepted by this branch.  The
# user-facing name, private NVAPI label and numeric value are kept together so
# registry writers and query tools cannot disagree about enum rendering.
# display_name|nvapi_name|nvapi_value
VGPU_MEMORY_MAKER_CATALOG=(
    "Samsung|Samsung|1"
    "SK hynix|Hynix|6"
    "Micron|Micron|10"
)

# NVAPI/GPU-Z and NV2080_CTRL_FB_GET_INFO_V2 use different numeric domains
# for the memory maker.  Samsung and Hynix happen to match; Micron is 10 in
# the private NVAPI projection but 0x0F in NVIDIA's RM control ABI.
vgpu_profile_rm_memory_vendor_value() {
    case "$1|$2" in
        'Samsung|1') printf '%s\n' 1 ;;
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
    "gtx750ti_asus_2gb|ASUS|OC|subsystem=0x1043:0x84BB|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx750ti_msi_2gb|MSI|OC|subsystem=0x1462:0x8A9B|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx750ti_gigabyte_2gb|Gigabyte|OC|subsystem=0x1458:0x362D|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gt1030_galax_2gb|GALAX|EXOC White|subsystem=0x10DE:0x11C7|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gt1030_asus_2gb|ASUS|Silent|subsystem=0x1043:0x85F4|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gt1030_msi_2gb|MSI|LP OCV1|subsystem=0x1462:0x8C98|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx1050_colorful_2gb|Colorful|GTX1050 Gaming 2G V5|subsystem=0x7377:0x0000|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx1050_msi_2gb|MSI|Gaming X|subsystem=0x1462:0x3354|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
    "gtx1050_gigabyte_2gb|Gigabyte|OC|subsystem=0x1458:0x372D|not-exposed|B:system-pci=host-mdev,catalog=protected-user-mode"
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
            0x1462:MSI|0x1458:Gigabyte|0x7377:Colorful)
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
    local seen_keys='|' seen_pci='|'

    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        IFS='|' read -r key mdev name vid did subvid subdid rev vram vbios \
            core boost memory bus bandwidth ram_type ram_maker \
            memory_type_nvapi memory_maker_nvapi cuda_cores shader_subpipes \
            rop_count tmu_count architecture implementation chip_revision pcie_width \
            <<<"$row"
        if [[ -z "$key" || -z "$name" || "$mdev" != nvidia-257 || "$vram" != 2048 ]]; then
            printf '非法 vGPU profile（仅允许 nvidia-257/2048MB）: %s\n' "$row" >&2
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
        seen_keys+="$key|"
        seen_pci+="$vid:$did:$subvid:$subdid|"
    done

    vgpu_profile_validate_board_metadata_catalog
}

vgpu_profile_keys() {
    local row key
    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        printf '%s\n' "$key"
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
    local index row key

    vgpu_profile_validate_catalog || return
    ((${#VGPU_PROFILE_CATALOG[@]} > 0)) || {
        printf 'vGPU profile catalog is empty\n' >&2
        return 1
    }
    index=$(_vgpu_profile_random_index "${#VGPU_PROFILE_CATALOG[@]}") || return
    if ! [[ "$index" =~ ^[0-9]+$ ]] ||
            ((index >= ${#VGPU_PROFILE_CATALOG[@]})); then
        printf 'vGPU random selector returned an invalid index: %s\n' \
            "$index" >&2
        return 1
    fi
    row=${VGPU_PROFILE_CATALOG[$index]}
    key=${row%%|*}
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

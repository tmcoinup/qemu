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

# key|mdev_profile|name|vid|did|subvid|subdid|rev|vram_mb|vbios|core_mhz|boost_mhz|memory_mhz|bus_bits|bandwidth_mbps|ram_type|ram_maker
VGPU_PROFILE_CATALOG=(
    "gtx750ti_2gb|nvidia-257|NVIDIA GeForce GTX 750 Ti|0x10DE|0x1380|0x10DE|0x1380|0xA2|2048|Version 82.07.41.00.32|1020|1085|1350|128|86400|GDDR5|Samsung"
    "gt1030_2gb|nvidia-257|NVIDIA GeForce GT 1030|0x10DE|0x1D01|0x1043|0x85F9|0xA1|2048|Version 86.08.46.00.81|1227|1468|1502|64|48100|GDDR5|Samsung"
    "gtx1050_2gb|nvidia-257|NVIDIA GeForce GTX 1050|0x10DE|0x1C81|0x1028|0x11C0|0xA1|2048|Version 86.07.48.00.38|1354|1455|1752|128|112000|GDDR5|Samsung"
)

vgpu_profile_validate_catalog() {
    local row key mdev name vid did subvid subdid rev vram vbios
    local core boost memory bus bandwidth ram_type ram_maker
    local seen_keys='|' seen_pci='|'

    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        IFS='|' read -r key mdev name vid did subvid subdid rev vram vbios \
            core boost memory bus bandwidth ram_type ram_maker <<<"$row"
        if [[ -z "$key" || -z "$name" || "$mdev" != nvidia-257 || "$vram" != 2048 ]]; then
            printf '非法 vGPU profile（仅允许 nvidia-257/2048MB）: %s\n' "$row" >&2
            return 1
        fi
        if [[ "$seen_keys" == *"|$key|"* || "$seen_pci" == *"|$vid:$did|"* ]]; then
            printf '重复 vGPU profile key 或 PCI ID: %s\n' "$row" >&2
            return 1
        fi
        if ! [[ "$core" =~ ^[1-9][0-9]*$ && "$boost" =~ ^[1-9][0-9]*$ &&
                "$memory" =~ ^[1-9][0-9]*$ && "$bus" =~ ^[1-9][0-9]*$ &&
                "$bandwidth" =~ ^[1-9][0-9]*$ ]]; then
            printf 'vGPU profile 频率/位宽/带宽必须是正整数: %s\n' "$row" >&2
            return 1
        fi
        seen_keys+="$key|"
        seen_pci+="$vid:$did|"
    done
}

vgpu_profile_keys() {
    local row key
    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        printf '%s\n' "$key"
    done
}

vgpu_profile_load() {
    local requested=$1 row key

    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        IFS='|' read -r \
            key VGPU_MDEV_PROFILE GPU_NAME GPU_PCI_VID GPU_PCI_DID \
            GPU_SUB_VID GPU_SUB_DID GPU_REV GPU_VRAM_MB GPU_VBIOS \
            GPU_CORE_MHZ GPU_BOOST_MHZ GPU_MEMORY_MHZ \
            GPU_MEMORY_BUS_BITS GPU_MEMORY_BANDWIDTH_MBPS \
            GPU_MEMORY_TYPE GPU_MEMORY_MAKER <<<"$row"
        if [[ "$key" == "$requested" ]]; then
            GPU_PROFILE=$key
            return 0
        fi
    done

    printf '未知 vGPU identity profile: %s（可选: %s）\n' \
        "$requested" "$(vgpu_profile_keys | paste -sd, -)" >&2
    return 1
}

vgpu_profile_print_catalog() {
    local row
    printf '%-14s %-28s %-7s %-15s %s\n' \
        PROFILE NAME VRAM CLOCKS MDEV
    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        IFS='|' read -r \
            GPU_PROFILE VGPU_MDEV_PROFILE GPU_NAME _ _ _ _ _ \
            GPU_VRAM_MB _ GPU_CORE_MHZ GPU_BOOST_MHZ GPU_MEMORY_MHZ \
            _ _ _ _ <<<"$row"
        printf '%-14s %-28s %4s MB %4s/%4s/%4s MHz %s\n' \
            "$GPU_PROFILE" "$GPU_NAME" "$GPU_VRAM_MB" \
            "$GPU_CORE_MHZ" "$GPU_BOOST_MHZ" "$GPU_MEMORY_MHZ" \
            "$VGPU_MDEV_PROFILE"
    done
}

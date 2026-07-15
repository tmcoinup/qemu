#!/usr/bin/env bash
# Shared fail-closed checks for the verified host 535 / guest 538.33 assets.
# The filenames are historical and must not be used as proof of driver version.

VGPU_DRIVER_EXE_NAME=553.24.exe
VGPU_DRIVER_ZIP_NAME=553.24-display-driver.zip
VGPU_DRIVER_EXE_SHA256=aaa3080c0b7e3a6fbe825a05725f4171c75072faa8b667d97556c1605a219ddd
VGPU_DRIVER_ZIP_SHA256=a3d7ad8b8082d6ac6214565b4766b5190a819bc9b7574765b14897e0db809690
VGPU_DRIVER_VERSION=31.0.15.3833

vgpu_verify_driver_asset() {
    local path=$1 expected=$2 actual

    if [[ ! -f "$path" ]]; then
        echo "[driver-assets] missing: $path" >&2
        return 1
    fi
    actual=$(sha256sum "$path" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        echo "[driver-assets] REFUSE: unexpected SHA256 for $path" >&2
        echo "  expected (verified 538.33): $expected" >&2
        echo "  actual:                     $actual" >&2
        echo "  The legacy 553.24 filename does not mean a real 553.24 package is compatible." >&2
        return 1
    fi
}

# Usage: vgpu_verify_driver_assets exe | all
vgpu_verify_driver_assets() {
    local scope=${1:-all}
    local stage_dir=${STAGE_DIR:-${IMAGE_ROOT:-/home/ubuntu/images}/staging}
    local exe="$stage_dir/$VGPU_DRIVER_EXE_NAME"
    local zip="$stage_dir/$VGPU_DRIVER_ZIP_NAME"
    local driver_ver

    vgpu_verify_driver_asset "$exe" "$VGPU_DRIVER_EXE_SHA256" || return
    if [[ "$scope" == exe ]]; then
        echo "[driver-assets] verified 538.33 installer: $exe"
        return 0
    fi
    if [[ "$scope" != all ]]; then
        echo "[driver-assets] unknown verification scope: $scope" >&2
        return 2
    fi

    vgpu_verify_driver_asset "$zip" "$VGPU_DRIVER_ZIP_SHA256" || return
    driver_ver=$(unzip -p "$zip" Display.Driver/nvgridsw.inf 2>/dev/null \
        | tr -d '\r' | awk -F'= *' '/^DriverVer *=/ && !found {print $2; found=1}')
    if [[ "$driver_ver" != "01/25/2024, $VGPU_DRIVER_VERSION" ]]; then
        echo "[driver-assets] REFUSE: nvgridsw.inf DriverVer is '$driver_ver'" >&2
        echo "  expected: 01/25/2024, $VGPU_DRIVER_VERSION" >&2
        return 1
    fi
    echo "[driver-assets] verified 538.33 installer and Display.Driver archive"
}

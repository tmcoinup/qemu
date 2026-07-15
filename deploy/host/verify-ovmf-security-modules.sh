#!/usr/bin/env bash
# Verify security modules in the final firmware volume, rather than trusting
# intermediate .efi files left in the build tree.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 OVMF_CODE.fd" >&2
    exit 2
fi

firmware=$1
if [[ ! -f "$firmware" ]]; then
    echo "[verify] ERROR: firmware not found: $firmware" >&2
    exit 1
fi
if ! command -v virt-fw-dump >/dev/null 2>&1; then
    echo "[verify] ERROR: virt-fw-dump is required (Ubuntu package: python3-virt-firmware)" >&2
    exit 1
fi

if ! modules=$(virt-fw-dump --modules -i "$firmware" 2>&1); then
    echo "[verify] ERROR: cannot inspect firmware: $firmware" >&2
    echo "$modules" >&2
    exit 1
fi

required_modules=(
    Tcg2ConfigPei
    Tcg2Pei
    Tcg2PlatformPei
    Tcg2ConfigDxe
    Tcg2Dxe
    Tcg2PlatformDxe
    TcgMor
    Hash2DxeCrypto
    RngDxe
)

missing=()
for module in "${required_modules[@]}"; do
    if grep -Eq "name=${module}([[:space:]]*)$" <<<"$modules"; then
        echo "[verify] OK: $module"
    else
        echo "[verify] MISSING: $module" >&2
        missing+=("$module")
    fi
done

if ((${#missing[@]})); then
    echo "[verify] ERROR: firmware is missing ${#missing[@]} required security module(s): ${missing[*]}" >&2
    exit 1
fi

if grep -Eq 'name=VirtioRngDxe([[:space:]]*)$' <<<"$modules"; then
    echo "[verify] OK: VirtioRngDxe retained alongside generic RngDxe"
fi

echo "[verify] PASS: core TCG2, TcgMor, Hash2DxeCrypto and RngDxe are present in $firmware"

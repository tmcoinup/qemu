#!/usr/bin/env bash
# Shared fail-closed checks for the verified host 535 / guest 538.33 assets.
# The filenames are historical and must not be used as proof of driver version.

VGPU_DRIVER_EXE_NAME=553.24.exe
VGPU_DRIVER_ZIP_NAME=553.24-display-driver.zip
VGPU_DRIVER_EXE_SHA256=aaa3080c0b7e3a6fbe825a05725f4171c75072faa8b667d97556c1605a219ddd
VGPU_DRIVER_ZIP_SHA256=a3d7ad8b8082d6ac6214565b4766b5190a819bc9b7574765b14897e0db809690
VGPU_DRIVER_VERSION=31.0.15.3833

# Validate one already-tokenized QEMU argv.  Keeping the parser separate makes
# the security decision unit-testable without adding a production environment
# switch that could forge /proc.  Usage:
#   vgpu_driver_install_argv_is_safe VM_ID DISK VM_UUID "${argv[@]}"
vgpu_driver_install_argv_is_safe() {
    local vm_id=$1 disk=$2 vm_uuid=${3,,}
    shift 3
    local -a argv=( "$@" )
    local arg value
    local name_ok=0 disk_ok=0 vga_ok=0 mdev_ok=0 window_ok=0 forbidden=0
    local i

    ((${#argv[@]} > 0)) || return 1
    [[ "${argv[0]##*/}" == qemu-system-x86_64 ]] || return 1
    for ((i = 1; i < ${#argv[@]}; i += 1)); do
        arg=${argv[i]}
        case "$arg" in
            -name|-drive|-device|-display)
                ((i + 1 < ${#argv[@]})) || return 1
                value=${argv[++i]}
                ;;
            *)
                continue
                ;;
        esac
        case "$arg" in
            -name)
                [[ "$value" == "vm${vm_id}" ]] && name_ok=1
                ;;
            -drive)
                [[ "$value" == *"file=${disk},"* ]] && disk_ok=1
                ;;
            -device)
                if [[ "$value" == "VGA,id=driver-install-vga,bus=pcie.0,addr=0x2" ]]; then
                    vga_ok=1
                elif [[ "$value" == vfio-pci* ]]; then
                    if [[ "$value" == vfio-pci-nohotplug,* &&
                          "$value" == *"sysfsdev=/sys/bus/mdev/devices/${vm_uuid}"* &&
                          "$value" == *",display=off,"* &&
                          "$value" == *",enable-migration=off,"* &&
                          "$value" == *",bus=gpu-root-port,"* &&
                          "$value" == *",addr=0x0,"* &&
                          "$value" == *",rombar=0"* ]]; then
                        mdev_ok=1
                    fi
                    [[ "$value" != *",display=on"* &&
                       "$value" != *",ramfb=on"* &&
                       "$value" != *",x-pci-vendor-id="* &&
                       "$value" != *",x-pci-device-id="* ]] || forbidden=1
                fi
                ;;
            -display)
                case "$value" in
                    sdl,gl=off,*|gtk,gl=off,*) window_ok=1 ;;
                esac
                ;;
        esac
    done
    ((name_ok && disk_ok && vga_ok && mdev_ok && window_ok && !forbidden))
}

# Refuse all guest writes unless exactly one live QEMU process for this VM uses
# the isolated GRID-install topology.  /proc is authoritative for the complete
# QEMU lifetime; a normal display=on VM cannot transition into this mode.
# vm-storage.sh must already be sourced and initialized by the caller.
vgpu_require_safe_driver_install_topology() {
    local vm_id=$1 conf disk expected_uuid pid cmdline_path matched=0 matched_pid=""
    local VM_UUID=""
    local -a argv=()

    conf=$(vm_storage_config_path "$vm_id") || return
    disk=$(vm_storage_disk_path "$vm_id") || return
    [[ -f "$conf" && ! -L "$conf" && -f "$disk" && ! -L "$disk" ]] || {
        echo "[driver-assets] vm${vm_id} config/disk is missing or unsafe" >&2
        return 1
    }
    # shellcheck source=/dev/null
    source "$conf"
    expected_uuid=${VM_UUID,,}
    [[ "$expected_uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
        echo "[driver-assets] vm${vm_id} has an invalid VM_UUID" >&2
        return 1
    }

    for cmdline_path in /proc/[0-9]*/cmdline; do
        [[ -r "$cmdline_path" ]] || continue
        argv=()
        mapfile -d '' -t argv <"$cmdline_path" 2>/dev/null || continue
        vgpu_driver_install_argv_is_safe \
            "$vm_id" "$disk" "$expected_uuid" "${argv[@]}" || continue
        pid=${cmdline_path#/proc/}
        pid=${pid%/cmdline}
        matched=$((matched + 1))
        matched_pid=$pid
    done
    if ((matched != 1)); then
        echo "[driver-assets] REFUSE: vm${vm_id} 未运行唯一的安全 GRID 安装拓扑" >&2
        echo "[driver-assets] 先运行: ./deploy/scripts/vmctl.sh driver-install ${vm_id}" >&2
        echo "[driver-assets] 要求: 标准 VGA + native mdev display=off + spoof=off + rombar=0" >&2
        return 1
    fi
    echo "[driver-assets] verified isolated GRID-install topology for vm${vm_id} (qemu pid=${matched_pid})"
}

vgpu_valid_ipv4() {
    local address=$1 octet
    local -a octets=()

    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<<"$address"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" == 0 || "$octet" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

# Resolve a guest IPv4 only when it is bound to the requested VM's configured
# MAC on br0.  This applies to explicit --ip too: otherwise a caller could
# modify vm3 while invalidating vm1's monitor marker (the historical default).
# vm-storage.sh must already be sourced and initialized by the caller.
vgpu_resolve_bound_guest_ip() {
    local vm_id=$1 override=${2:-} conf vm_mac resolved_ip observed_mac
    local VM_MAC=""

    conf=$(vm_storage_config_path "$vm_id") || return
    [[ -f "$conf" && ! -L "$conf" ]] || {
        echo "[driver-assets] missing or unsafe vm${vm_id} config: $conf" >&2
        return 1
    }
    # shellcheck source=/dev/null
    source "$conf"
    vm_mac=${VM_MAC,,}
    [[ "$vm_mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || {
        echo "[driver-assets] vm${vm_id} has an invalid VM_MAC" >&2
        return 1
    }

    if [[ -n "$override" ]]; then
        vgpu_valid_ipv4 "$override" || {
            echo "[driver-assets] invalid guest IPv4 override: $override" >&2
            return 1
        }
        observed_mac=$(ip -4 neigh show dev br0 2>/dev/null | awk \
            -v wanted_ip="$override" \
            '$1 == wanted_ip {
                for (i = 1; i < NF; i++) {
                    if ($i == "lladdr") { print tolower($(i + 1)); exit }
                }
            }')
        [[ "$observed_mac" == "$vm_mac" ]] || {
            echo "[driver-assets] REFUSE: $override is not bound to vm${vm_id} VM_MAC on br0" >&2
            return 1
        }
        printf '%s\n' "$override"
        return 0
    fi

    resolved_ip=$(ip -4 neigh show dev br0 2>/dev/null | awk \
        -v wanted_mac="$vm_mac" \
        '$1 ~ /^[0-9]/ {
            for (i = 1; i < NF; i++) {
                if ($i == "lladdr" && tolower($(i + 1)) == wanted_mac) {
                    print $1
                    exit
                }
            }
        }')
    [[ -n "$resolved_ip" ]] || {
        echo "[driver-assets] no br0 IPv4 neighbor for vm${vm_id} VM_MAC" >&2
        return 1
    }
    printf '%s\n' "$resolved_ip"
}

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

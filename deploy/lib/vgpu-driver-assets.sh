#!/usr/bin/env bash
# Shared fail-closed checks for the reviewed production-signed stacks:
#
#   host 535.161.05 -> guest 538.33 / 31.0.15.3833
#   host 580.159.01 -> guest 582.53 / 32.0.15.8253
#
# The legacy R535 filenames are historical and must not be used as proof of
# driver version.  Keep the VGPU_DRIVER_* names as the R535 archive contract:
# older production-migration tooling imports them directly.

VGPU_DRIVER_EXE_NAME=553.24.exe
VGPU_DRIVER_ZIP_NAME=553.24-display-driver.zip
VGPU_DRIVER_EXE_SHA256=aaa3080c0b7e3a6fbe825a05725f4171c75072faa8b667d97556c1605a219ddd
VGPU_DRIVER_ZIP_SHA256=a3d7ad8b8082d6ac6214565b4766b5190a819bc9b7574765b14897e0db809690
VGPU_DRIVER_VERSION=31.0.15.3833

VGPU_R580_DRIVER_EXE_NAME=582.53_grid_win10_win11_server2022_server_2025_dch_64bit_international.exe
VGPU_R580_DRIVER_EXE_SHA256=6f1210b459efc7f29db930103533c3de9b93c2afdfa8d7b4871640c6b8638c0b
VGPU_R580_DRIVER_VERSION=32.0.15.8253
VGPU_R580_PAYLOAD_ARCHIVE_NAME=r580-582.53-official-payload.zip
VGPU_R580_PAYLOAD_SETUP_SHA256=4eded69953267cf82a7218c3f797292b35e0926f761aa733a1de3b54cdf96d69
VGPU_R580_PAYLOAD_INF_DRIVER_VER='04/15/2026, 32.0.15.8253'
VGPU_R580_PAYLOAD_SETUP_VERSION=582.53

VGPU_SELECTED_HOST_DRIVER=""
VGPU_SELECTED_DRIVER_BRANCH=""
VGPU_SELECTED_DRIVER_LABEL=""
VGPU_SELECTED_DRIVER_EXE_NAME=""
VGPU_SELECTED_DRIVER_EXE_SHA256=""
VGPU_SELECTED_DRIVER_VERSION=""
VGPU_SELECTED_DRIVER_ZIP_NAME=""
VGPU_SELECTED_DRIVER_ZIP_SHA256=""
VGPU_SELECTED_DRIVER_PAYLOAD_ARCHIVE_NAME=""
VGPU_SELECTED_DRIVER_SETUP_SHA256=""
VGPU_SELECTED_DRIVER_INF_DRIVER_VER=""
VGPU_SELECTED_DRIVER_SETUP_VERSION=""
VGPU_SELECTED_DRIVER_NEEDS_R535_MONITOR=0

vgpu_select_driver_stack() {
    local version_file=/sys/module/nvidia/version
    local host_version=${1:-}

    if [[ -z "$host_version" ]]; then
        [[ -r "$version_file" ]] || {
            echo "[driver-assets] NVIDIA host module is not loaded" >&2
            return 1
        }
        IFS= read -r host_version <"$version_file" || true
    fi
    case "$host_version" in
        535.161.05)
            VGPU_SELECTED_HOST_DRIVER=$host_version
            VGPU_SELECTED_DRIVER_BRANCH=R535
            VGPU_SELECTED_DRIVER_LABEL='GRID 538.33'
            VGPU_SELECTED_DRIVER_EXE_NAME=$VGPU_DRIVER_EXE_NAME
            VGPU_SELECTED_DRIVER_EXE_SHA256=$VGPU_DRIVER_EXE_SHA256
            VGPU_SELECTED_DRIVER_VERSION=$VGPU_DRIVER_VERSION
            VGPU_SELECTED_DRIVER_ZIP_NAME=$VGPU_DRIVER_ZIP_NAME
            VGPU_SELECTED_DRIVER_ZIP_SHA256=$VGPU_DRIVER_ZIP_SHA256
            VGPU_SELECTED_DRIVER_PAYLOAD_ARCHIVE_NAME=""
            VGPU_SELECTED_DRIVER_SETUP_SHA256=$VGPU_DRIVER_EXE_SHA256
            VGPU_SELECTED_DRIVER_INF_DRIVER_VER=""
            VGPU_SELECTED_DRIVER_SETUP_VERSION=""
            VGPU_SELECTED_DRIVER_NEEDS_R535_MONITOR=1
            ;;
        580.159.01)
            VGPU_SELECTED_HOST_DRIVER=$host_version
            VGPU_SELECTED_DRIVER_BRANCH=R580
            VGPU_SELECTED_DRIVER_LABEL='GRID 582.53'
            VGPU_SELECTED_DRIVER_EXE_NAME=$VGPU_R580_DRIVER_EXE_NAME
            VGPU_SELECTED_DRIVER_EXE_SHA256=$VGPU_R580_DRIVER_EXE_SHA256
            VGPU_SELECTED_DRIVER_VERSION=$VGPU_R580_DRIVER_VERSION
            VGPU_SELECTED_DRIVER_ZIP_NAME=""
            VGPU_SELECTED_DRIVER_ZIP_SHA256=""
            VGPU_SELECTED_DRIVER_PAYLOAD_ARCHIVE_NAME=$VGPU_R580_PAYLOAD_ARCHIVE_NAME
            VGPU_SELECTED_DRIVER_SETUP_SHA256=$VGPU_R580_PAYLOAD_SETUP_SHA256
            VGPU_SELECTED_DRIVER_INF_DRIVER_VER=$VGPU_R580_PAYLOAD_INF_DRIVER_VER
            VGPU_SELECTED_DRIVER_SETUP_VERSION=$VGPU_R580_PAYLOAD_SETUP_VERSION
            VGPU_SELECTED_DRIVER_NEEDS_R535_MONITOR=0
            ;;
        *)
            echo "[driver-assets] unsupported NVIDIA host driver: ${host_version:-unknown}" >&2
            echo "[driver-assets] reviewed pairs: 535.161.05/538.33 or 580.159.01/582.53" >&2
            return 1
            ;;
    esac
}

vgpu_validate_r580_payload_archive() {
    local archive=$1 setup_sha driver_ver setup_version

    [[ -f "$archive" && ! -L "$archive" ]] || return 1
    command -v unzip >/dev/null 2>&1 || {
        echo "[driver-assets] unzip is required to validate the R580 payload cache" >&2
        return 1
    }
    setup_sha=$(unzip -p "$archive" setup.exe 2>/dev/null | sha256sum | awk '{print $1}') || return
    [[ -n "$VGPU_SELECTED_DRIVER_SETUP_SHA256" &&
       "$setup_sha" == "$VGPU_SELECTED_DRIVER_SETUP_SHA256" ]] || {
        echo "[driver-assets] REFUSE: R580 payload contains an unexpected setup.exe" >&2
        return 1
    }
    driver_ver=$(unzip -p "$archive" Display.Driver/nvgridsw.inf 2>/dev/null |
        tr -d '\r' | awk -F'= *' '/^DriverVer *=/ && !found {print $2; found=1}') || return
    [[ -n "$VGPU_SELECTED_DRIVER_INF_DRIVER_VER" &&
       "$driver_ver" == "$VGPU_SELECTED_DRIVER_INF_DRIVER_VER" ]] || {
        echo "[driver-assets] REFUSE: R580 payload nvgridsw.inf DriverVer is '$driver_ver'" >&2
        echo "  expected: $VGPU_SELECTED_DRIVER_INF_DRIVER_VER" >&2
        return 1
    }
    setup_version=$(unzip -p "$archive" setup.cfg 2>/dev/null |
        tr -d '\r' | sed -n 's/.*<setup[^>]* version="\([^"]*\)".*/\1/p' | head -n 1) || return
    [[ -n "$VGPU_SELECTED_DRIVER_SETUP_VERSION" &&
       "$setup_version" == "$VGPU_SELECTED_DRIVER_SETUP_VERSION" ]] || {
        echo "[driver-assets] REFUSE: R580 payload setup.cfg version is '$setup_version'" >&2
        return 1
    }
}

# NVIDIA's reviewed silent-install command applies to the inner setup.exe, not
# the 713 MB PackageLauncher SFX.  Build a host-side ZIP cache from the exact
# reviewed outer package, then validate the signed payload identity by its
# setup.exe hash and nvgridsw.inf version.  The resulting archive hash is
# computed at runtime because ZIP encoder metadata is not a vendor artifact.
#
# Output (stdout): absolute_archive_path<TAB>sha256
vgpu_prepare_selected_driver_payload() {
    local stage_dir=${STAGE_DIR:-${IMAGE_ROOT:-/home/ubuntu/images}/staging}
    local source archive archive_sha scratch payload temporary

    [[ "$VGPU_SELECTED_DRIVER_BRANCH" == R580 ]] || {
        echo "[driver-assets] expanded payload preparation is R580-only" >&2
        return 1
    }
    source="$stage_dir/$VGPU_SELECTED_DRIVER_EXE_NAME"
    archive="$stage_dir/$VGPU_SELECTED_DRIVER_PAYLOAD_ARCHIVE_NAME"
    [[ -d "$stage_dir" && ! -L "$stage_dir" ]] || {
        echo "[driver-assets] unsafe/missing staging directory: $stage_dir" >&2
        return 1
    }
    vgpu_verify_driver_asset "$source" "$VGPU_SELECTED_DRIVER_EXE_SHA256" \
        "$VGPU_SELECTED_DRIVER_LABEL" || return

    if [[ -e "$archive" || -L "$archive" ]]; then
        vgpu_validate_r580_payload_archive "$archive" || {
            echo "[driver-assets] refusing invalid existing R580 payload cache: $archive" >&2
            return 1
        }
    else
        command -v 7z >/dev/null 2>&1 || {
            echo "[driver-assets] 7z is required to expand the reviewed R580 package" >&2
            return 1
        }
        command -v zip >/dev/null 2>&1 || {
            echo "[driver-assets] zip is required to package the reviewed R580 payload" >&2
            return 1
        }
        scratch=$(mktemp -d "$stage_dir/.r580-payload.XXXXXX") || return
        payload="$scratch/payload"
        temporary="$scratch/$VGPU_SELECTED_DRIVER_PAYLOAD_ARCHIVE_NAME"
        install -d -m 0700 "$payload"
        (
            set -e
            trap 'find "$scratch" -depth -delete 2>/dev/null || true' EXIT
            echo "[driver-assets] expanding exact R580 PackageLauncher payload" >&2
            7z x -y -o"$payload" "$source" >/dev/null
            [[ $(sha256sum "$payload/setup.exe" | awk '{print $1}') == \
               "$VGPU_SELECTED_DRIVER_SETUP_SHA256" ]]
            (
                cd "$payload"
                zip -1 -q -r "$temporary" .
            )
            vgpu_validate_r580_payload_archive "$temporary"
            chmod 0644 "$temporary"
            mv -T -- "$temporary" "$archive"
            echo "[driver-assets] published reviewed R580 inner payload cache" >&2
        ) || {
            find "$scratch" -depth -delete 2>/dev/null || true
            return 1
        }
    fi
    archive_sha=$(sha256sum "$archive" | awk '{print $1}') || return
    printf '%s\t%s\n' "$archive" "$archive_sha"
}

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
    case "${argv[0]##*/}" in
        qemu-system-x86_64|qemu-system-x86_64.g11.real) ;;
        *) return 1 ;;
    esac
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
                    sdl,gl=off,*|gtk,gl=off,*|none) window_ok=1 ;;
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
    local path=$1 expected=$2 label=${3:-reviewed} actual

    if [[ ! -f "$path" ]]; then
        echo "[driver-assets] missing: $path" >&2
        return 1
    fi
    actual=$(sha256sum "$path" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        echo "[driver-assets] REFUSE: unexpected SHA256 for $path" >&2
        echo "  expected (${label}): $expected" >&2
        echo "  actual:              $actual" >&2
        return 1
    fi
}

# Usage: vgpu_verify_driver_assets exe | all
vgpu_verify_driver_assets() {
    local scope=${1:-all}
    local host_version_override=${2:-}
    local stage_dir=${STAGE_DIR:-${IMAGE_ROOT:-/home/ubuntu/images}/staging}
    local exe zip
    local driver_ver

    vgpu_select_driver_stack "$host_version_override" || return
    exe="$stage_dir/$VGPU_SELECTED_DRIVER_EXE_NAME"
    vgpu_verify_driver_asset "$exe" "$VGPU_SELECTED_DRIVER_EXE_SHA256" \
        "$VGPU_SELECTED_DRIVER_LABEL" || return
    if [[ "$scope" == exe ]]; then
        echo "[driver-assets] verified ${VGPU_SELECTED_DRIVER_LABEL} installer for host ${VGPU_SELECTED_HOST_DRIVER}: $exe"
        return 0
    fi
    if [[ "$scope" != all ]]; then
        echo "[driver-assets] unknown verification scope: $scope" >&2
        return 2
    fi

    [[ "$VGPU_SELECTED_DRIVER_BRANCH" == R535 &&
       -n "$VGPU_SELECTED_DRIVER_ZIP_NAME" ]] || {
        echo "[driver-assets] Display.Driver archive workflow is R535-only" >&2
        return 1
    }
    zip="$stage_dir/$VGPU_SELECTED_DRIVER_ZIP_NAME"
    vgpu_verify_driver_asset "$zip" "$VGPU_SELECTED_DRIVER_ZIP_SHA256" \
        "$VGPU_SELECTED_DRIVER_LABEL" || return
    driver_ver=$(unzip -p "$zip" Display.Driver/nvgridsw.inf 2>/dev/null \
        | tr -d '\r' | awk -F'= *' '/^DriverVer *=/ && !found {print $2; found=1}')
    if [[ "$driver_ver" != "01/25/2024, $VGPU_DRIVER_VERSION" ]]; then
        echo "[driver-assets] REFUSE: nvgridsw.inf DriverVer is '$driver_ver'" >&2
        echo "  expected: 01/25/2024, $VGPU_DRIVER_VERSION" >&2
        return 1
    fi
    echo "[driver-assets] verified ${VGPU_SELECTED_DRIVER_LABEL} installer and Display.Driver archive"
}

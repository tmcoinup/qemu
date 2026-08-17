#!/usr/bin/env bash
# shellcheck shell=bash
#
# Audited, production-signed consumer-driver compatibility catalog.
#
# GPU marketing identities remain in vgpu-profiles.sh.  A row here means only
# that the exact, unmodified vendor package contains a production-signed INF
# for one canonical GPU profile.  Runtime use still requires a separate,
# content-addressed Code-0 qualification produced on this host stack.

SIGNED_CONSUMER_CATALOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vgpu-profiles.sh
source "$SIGNED_CONSUMER_CATALOG_DIR/vgpu-profiles.sh"

SIGNED_CONSUMER_CONTRACT_NAME='signed-consumer-v2'
SIGNED_CONSUMER_BACKEND_ABI='g11-vfio-outer-pci-v1'
SIGNED_CONSUMER_QUALIFICATION_PURPOSE='g11-signed-consumer-qualification'
SIGNED_CONSUMER_PRODUCTION_STATUS_ENABLED='production-enabled'
SIGNED_CONSUMER_PRODUCTION_STATUS_QUARANTINED='quarantined-runtime-instability'

SIGNED_CONSUMER_DRIVER_KEYS=(
    nvidia-53758-dch-whql-gtx1050-dell
    nvidia-53758-dch-whql-gtx750ti-asus
)

signed_consumer_driver_keys() {
    printf '%s\n' "${SIGNED_CONSUMER_DRIVER_KEYS[@]}"
}

signed_consumer_driver_load() {
    local requested=$1

    unset SC_DRIVER_KEY SC_GPU_PROFILE SC_INSTALLER_NAME SC_INSTALLER_BYTES \
        SC_INSTALLER_SHA256 SC_INF_NAME SC_INF_SHA256 SC_INF_MODEL_LINE \
        SC_CATALOG_NAME SC_CATALOG_SHA256 SC_CATALOG_SIGNER_THUMBPRINT \
        SC_KERNEL_NAME SC_KERNEL_SHA256 SC_KERNEL_SIGNER_THUMBPRINT \
        SC_DRIVER_VERSION SC_BASELINE_PNP_PREFIX SC_BASELINE_DRIVER_VERSION \
        SC_PRODUCTION_STATUS SC_PRODUCTION_REASON \
        SC_GUEST_STATE_ROOT SC_PACKAGE_BUILDER SC_GUEST_VALIDATOR \
        SC_PACKAGE_BUILDER_SHA256 SC_GUEST_VALIDATOR_SHA256 \
        SC_EVIDENCE_DRIVER_REL SC_EVIDENCE_INSTALLER_REL

    case "$requested" in
        nvidia-53758-dch-whql-gtx1050-dell)
            SC_DRIVER_KEY=$requested
            SC_GPU_PROFILE=gtx1050_2gb
            SC_INSTALLER_NAME='537.58-desktop-win10-win11-64bit-international-dch-whql.exe'
            SC_INSTALLER_BYTES=675738080
            SC_INSTALLER_SHA256='D6345ABE590E151796ABC424D6661508735AB86CFF58FB644F23D270E89DCB93'
            SC_INF_NAME='nvddig.inf'
            SC_INF_SHA256='C2860E03D30F7BA610F9726765354E75CABB624791AECEA61478066D9EAD50F1'
            SC_INF_MODEL_LINE='%NVIDIA_DEV.1C81.11C0.1028% = Section029, PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028'
            SC_CATALOG_NAME='nv_disp.cat'
            SC_CATALOG_SHA256='08AD09F3B13E78D40B674914178B51090EABF99DF3FD1571C7DCBB367D8B430B'
            SC_CATALOG_SIGNER_THUMBPRINT='B878D8EB696CF3D4505E2F6641C57AF9062EC51A'
            SC_KERNEL_NAME='nvlddmkm.sys'
            SC_KERNEL_SHA256='19DBE8ED10DA6052EBFF22B70F51B710C8233ABB237BD544163025B1313EB5F2'
            SC_KERNEL_SIGNER_THUMBPRINT='01DF5BFEFA251B27AC1933E4E4CB61F21C44D57B'
            SC_DRIVER_VERSION='31.0.15.3758'
            SC_BASELINE_PNP_PREFIX='PCI\VEN_10DE&DEV_1E30'
            SC_BASELINE_DRIVER_VERSION='31.0.15.3833'
            SC_PRODUCTION_STATUS=$SIGNED_CONSUMER_PRODUCTION_STATUS_QUARANTINED
            SC_PRODUCTION_REASON='VM9 对照验收发现 31.0.15.3758 触发 host Xid 43 与 guest TDR/驱动卸载；原生 31.0.15.3833 路径稳定'
            # Implementation and evidence locations are properties of the
            # audited driver row, not of a VM number.  A future row must name
            # its own production validator explicitly; merely adding hashes
            # must never make an unsupported driver deployable.
            SC_PACKAGE_BUILDER='package-nvidia-53758-experiment.sh'
            SC_GUEST_VALIDATOR='nvidia-53758-isolated-experiment.ps1'
            SC_EVIDENCE_DRIVER_REL='candidates/official-driver-audit-20260719/extracted/nvidia-537.58-audit/Display.Driver'
            SC_EVIDENCE_INSTALLER_REL="candidates/official-driver-audit-20260719/downloads/$SC_INSTALLER_NAME"
            # Kept for backwards-compatible proof import.  It is selected by
            # the driver row, never by a VM number.
            SC_GUEST_STATE_ROOT='QemuNvidia53758Experiment'
            ;;
        nvidia-53758-dch-whql-gtx750ti-asus)
            SC_DRIVER_KEY=$requested
            SC_GPU_PROFILE=gtx750ti_asus_2gb
            SC_INSTALLER_NAME='537.58-desktop-win10-win11-64bit-international-dch-whql.exe'
            SC_INSTALLER_BYTES=675738080
            SC_INSTALLER_SHA256='D6345ABE590E151796ABC424D6661508735AB86CFF58FB644F23D270E89DCB93'
            SC_INF_NAME='nv_dispig.inf'
            SC_INF_SHA256='1B7B9F3A5A13A4FEC0074BCEA8A1DD64336CEF228041B1124B8E31D41CDED957'
            SC_INF_MODEL_LINE='%NVIDIA_DEV.1380%           = Section010, PCI\VEN_10DE&DEV_1380'
            SC_CATALOG_NAME='nv_disp.cat'
            SC_CATALOG_SHA256='08AD09F3B13E78D40B674914178B51090EABF99DF3FD1571C7DCBB367D8B430B'
            SC_CATALOG_SIGNER_THUMBPRINT='B878D8EB696CF3D4505E2F6641C57AF9062EC51A'
            SC_KERNEL_NAME='nvlddmkm.sys'
            SC_KERNEL_SHA256='19DBE8ED10DA6052EBFF22B70F51B710C8233ABB237BD544163025B1313EB5F2'
            SC_KERNEL_SIGNER_THUMBPRINT='01DF5BFEFA251B27AC1933E4E4CB61F21C44D57B'
            SC_DRIVER_VERSION='31.0.15.3758'
            SC_BASELINE_PNP_PREFIX='PCI\VEN_10DE&DEV_1E30'
            SC_BASELINE_DRIVER_VERSION='31.0.15.3833'
            SC_PRODUCTION_STATUS=$SIGNED_CONSUMER_PRODUCTION_STATUS_QUARANTINED
            SC_PRODUCTION_REASON='VM9 对照验收发现 31.0.15.3758 触发 host Xid 43 与 guest TDR/驱动卸载；原生 31.0.15.3833 路径稳定'
            SC_PACKAGE_BUILDER='package-nvidia-53758-experiment.sh'
            SC_GUEST_VALIDATOR='nvidia-53758-isolated-experiment.ps1'
            SC_EVIDENCE_DRIVER_REL='candidates/official-driver-audit-20260719/extracted/nvidia-537.58-audit/Display.Driver'
            SC_EVIDENCE_INSTALLER_REL="candidates/official-driver-audit-20260719/downloads/$SC_INSTALLER_NAME"
            SC_GUEST_STATE_ROOT='QemuNvidia53758Experiment'
            ;;
        *)
            printf '未知 signed-consumer driver key: %s（可选: %s）\n' \
                "$requested" "$(signed_consumer_driver_keys | paste -sd, -)" >&2
            return 1
            ;;
    esac

    SC_PACKAGE_BUILDER_SHA256=$(sha256sum -- \
        "$SIGNED_CONSUMER_CATALOG_DIR/../$SC_PACKAGE_BUILDER" |
        awk '{print toupper($1)}') || return 1
    SC_GUEST_VALIDATOR_SHA256=$(sha256sum -- \
        "$SIGNED_CONSUMER_CATALOG_DIR/../guest/$SC_GUEST_VALIDATOR" |
        awk '{print toupper($1)}') || return 1
}

signed_consumer_driver_is_production_enabled() {
    [[ "${SC_PRODUCTION_STATUS:-}" == \
        "$SIGNED_CONSUMER_PRODUCTION_STATUS_ENABLED" ]]
}

signed_consumer_driver_assert_production_enabled() {
    signed_consumer_driver_is_production_enabled && return 0
    printf 'signed-consumer driver %s 已禁止进入生产路径（%s）：%s\n' \
        "${SC_DRIVER_KEY:-<none>}" "${SC_PRODUCTION_STATUS:-missing-status}" \
        "${SC_PRODUCTION_REASON:-未记录原因}" >&2
    return 1
}

# Qualification tooling is deliberately separate from production selection.
# A quarantined row remains auditable and may be reproduced only by the
# explicit disposable-clone experiment; it can never become a production
# default merely because the original WHQL bytes are still present.
signed_consumer_driver_audited_default_for_profile() {
    local profile=$1 key count=0 selected=''
    for key in "${SIGNED_CONSUMER_DRIVER_KEYS[@]}"; do
        signed_consumer_driver_load "$key" || return 1
        if [[ "$SC_GPU_PROFILE" == "$profile" ]]; then
            selected=$key
            ((count += 1))
        fi
    done
    if ((count == 0)); then
        printf 'GPU profile %s 尚无 production-signed consumer driver 资格条目\n' \
            "$profile" >&2
        return 1
    fi
    if ((count != 1)); then
        printf 'GPU profile %s 有多个 driver 条目；必须显式选择 --driver-key\n' \
            "$profile" >&2
        return 1
    fi
    printf '%s\n' "$selected"
}

signed_consumer_driver_default_for_profile() {
    local profile=$1 key count=0 selected='' quarantined=0
    for key in "${SIGNED_CONSUMER_DRIVER_KEYS[@]}"; do
        signed_consumer_driver_load "$key" || return 1
        [[ "$SC_GPU_PROFILE" == "$profile" ]] || continue
        if signed_consumer_driver_is_production_enabled; then
            selected=$key
            ((count += 1))
        else
            ((quarantined += 1))
        fi
    done
    if ((count == 0)); then
        if ((quarantined > 0)); then
            printf 'GPU profile %s 的审核 driver 已被运行时稳定性隔离；无 production-enabled 条目\n' \
                "$profile" >&2
        else
            printf 'GPU profile %s 尚无 production-signed consumer driver 资格条目\n' \
                "$profile" >&2
        fi
        return 1
    fi
    if ((count != 1)); then
        printf 'GPU profile %s 有多个 production-enabled driver 条目；必须显式选择 --driver-key\n' \
            "$profile" >&2
        return 1
    fi
    printf '%s\n' "$selected"
}

signed_consumer_profile_row() {
    local requested=$1 row key
    for row in "${VGPU_PROFILE_CATALOG[@]}"; do
        IFS='|' read -r key _ <<<"$row"
        if [[ "$key" == "$requested" ]]; then
            printf '%s\n' "$row"
            return 0
        fi
    done
    printf '未知 vGPU profile: %s\n' "$requested" >&2
    return 1
}

signed_consumer_profile_sha256() {
    local row
    row=$(signed_consumer_profile_row "$1") || return 1
    printf '%s\n' "$row" | sha256sum | awk '{print toupper($1)}'
}

signed_consumer_profile_load_canonical() {
    local requested=$1
    vgpu_profile_load "$requested" || return 1
    SC_CANONICAL_GPU_PROFILE=$GPU_PROFILE
    SC_CANONICAL_GPU_NAME=$GPU_NAME
    SC_CANONICAL_PCI_VID=${GPU_PCI_VID^^}
    SC_CANONICAL_PCI_DID=${GPU_PCI_DID^^}
    SC_CANONICAL_SUB_VID=${GPU_SUB_VID^^}
    SC_CANONICAL_SUB_DID=${GPU_SUB_DID^^}
    SC_CANONICAL_REV=${GPU_REV^^}
    SC_CANONICAL_MDEV_PROFILE=$VGPU_MDEV_PROFILE
    SC_CANONICAL_FB_MB=$GPU_VRAM_MB
    SC_CANONICAL_PCIE_WIDTH=$GPU_PCIE_WIDTH
    printf -v SC_CANONICAL_TARGET_PNP \
        'PCI\\VEN_%04X&DEV_%04X&SUBSYS_%04X%04X' \
        "$((SC_CANONICAL_PCI_VID))" "$((SC_CANONICAL_PCI_DID))" \
        "$((SC_CANONICAL_SUB_DID))" "$((SC_CANONICAL_SUB_VID))"
}

signed_consumer_profile_assert_config() {
    local requested=$1 config_name=$2 config_vid=$3 config_did=$4
    local config_subvid=$5 config_subdid=$6 config_mdev=$7
    signed_consumer_profile_load_canonical "$requested" || return 1
    [[ "$config_name" == "$SC_CANONICAL_GPU_NAME" &&
       "${config_vid^^}" == "$SC_CANONICAL_PCI_VID" &&
       "${config_did^^}" == "$SC_CANONICAL_PCI_DID" &&
       "${config_subvid^^}" == "$SC_CANONICAL_SUB_VID" &&
       "${config_subdid^^}" == "$SC_CANONICAL_SUB_DID" &&
       "$config_mdev" == "$SC_CANONICAL_MDEV_PROFILE" ]] || {
        printf 'vm.conf GPU 字段与 canonical profile %s 不一致\n' "$requested" >&2
        return 1
    }
}

signed_consumer_driver_assert_profile() {
    local model_hardware_id
    [[ "${SC_DRIVER_KEY:-}" && "${SC_GPU_PROFILE:-}" == "${SC_CANONICAL_GPU_PROFILE:-}" ]] || {
        printf 'signed-consumer driver %s 不适用于 GPU profile %s\n' \
            "${SC_DRIVER_KEY:-<none>}" "${SC_CANONICAL_GPU_PROFILE:-<none>}" >&2
        return 1
    }
    model_hardware_id=${SC_INF_MODEL_LINE##*, }
    [[ "$model_hardware_id" =~ ^PCI\\VEN_[0-9A-F]{4}\&DEV_[0-9A-F]{4}(&SUBSYS_[0-9A-F]{8})?$ &&
       ( "$SC_CANONICAL_TARGET_PNP" == "$model_hardware_id" ||
         ( "${SC_CANONICAL_TARGET_PNP:0:${#model_hardware_id}}" == "$model_hardware_id" &&
           "${SC_CANONICAL_TARGET_PNP:${#model_hardware_id}:1}" == '&' ) ) ]] || {
        printf 'driver catalog model row 与 canonical GPU tuple 不一致\n' >&2
        return 1
    }
}

signed_consumer_host_driver_sha256() {
    local path=${1:-/proc/driver/nvidia/version}
    [[ -r "$path" ]] || return 1
    sha256sum -- "$path" | awk '{print toupper($1)}'
}

# Digest the loaded host implementation that can materially change mdev
# behavior even when /proc/driver/nvidia/version stays textually identical.
# Availability counters are deliberately excluded because they change as VMs
# start and stop; the physical PCI facts and selected type's immutable
# name/description/API are included.
signed_consumer_host_stack_sha256() {
    local mdev_profile=$1 framebuffer_mb=$2 module_path module_sha kernel_release
    local modinfo_bin=''
    local path value
    local -a pci_rows=() mdev_rows=()

    [[ "$mdev_profile" =~ ^[A-Za-z0-9._-]+$ &&
       "$framebuffer_mb" =~ ^[1-9][0-9]*$ ]] || return 1
    for path in /usr/sbin/modinfo /sbin/modinfo; do
        if [[ -x "$path" ]]; then modinfo_bin=$path; break; fi
    done
    [[ -n "$modinfo_bin" ]] || modinfo_bin=$(command -v modinfo 2>/dev/null || true)
    [[ -x "$modinfo_bin" ]] || return 1
    module_path=$("$modinfo_bin" -n nvidia 2>/dev/null) || return 1
    [[ "$module_path" == /* && -f "$module_path" && ! -L "$module_path" ]] \
        || return 1
    module_sha=$(sha256sum -- "$module_path" | awk '{print toupper($1)}') \
        || return 1
    kernel_release=$(uname -r) || return 1

    shopt -s nullglob
    for path in /sys/bus/pci/drivers/nvidia/[0-9A-Fa-f]*:*; do
        [[ -r "$path/vendor" && -r "$path/device" &&
           -r "$path/subsystem_vendor" && -r "$path/subsystem_device" ]] \
            || continue
        pci_rows+=("$(basename -- "$path")|$(<"$path/vendor")|$(<"$path/device")|$(<"$path/subsystem_vendor")|$(<"$path/subsystem_device")")
    done
    for path in /sys/class/mdev_bus/*/mdev_supported_types/"$mdev_profile"; do
        [[ -d "$path" && -r "$path/name" && -r "$path/description" &&
           -r "$path/device_api" ]] || continue
        value="$(basename -- "$(dirname -- "$(dirname -- "$path")")")|$(<"$path/name")|$(<"$path/description")|$(<"$path/device_api")"
        mdev_rows+=("$value")
    done
    shopt -u nullglob
    ((${#pci_rows[@]} > 0 && ${#mdev_rows[@]} > 0)) || return 1

    {
        printf 'kernel=%s\nmoduleSha256=%s\nmdevProfile=%s\nframebufferMb=%s\n' \
            "$kernel_release" "$module_sha" "$mdev_profile" "$framebuffer_mb"
        printf 'pci=%s\n' "${pci_rows[@]}" | sort
        printf 'mdev=%s\n' "${mdev_rows[@]}" | sort
    } | sha256sum | awk '{print toupper($1)}'
}

signed_consumer_qemu_sha256() {
    local path=$1
    [[ -f "$path" && ! -L "$path" && -x "$path" ]] || return 1
    sha256sum -- "$path" | awk '{print toupper($1)}'
}

signed_consumer_qualification_id() {
    local profile_sha=$1 qemu_sha=$2 host_driver_sha=$3 host_stack_sha=$4
    [[ "$profile_sha" =~ ^[0-9A-F]{64}$ &&
       "$qemu_sha" =~ ^[0-9A-F]{64}$ &&
       "$host_driver_sha" =~ ^[0-9A-F]{64}$ &&
       "$host_stack_sha" =~ ^[0-9A-F]{64}$ ]] || return 1
    printf '%s\n' \
        "schema=2" \
        "backend=$SIGNED_CONSUMER_BACKEND_ABI" \
        "driver=$SC_DRIVER_KEY" \
        "profile=$SC_CANONICAL_GPU_PROFILE" \
        "profileSha256=$profile_sha" \
        "targetPnpId=$SC_CANONICAL_TARGET_PNP" \
        "driverVersion=$SC_DRIVER_VERSION" \
        "infSha256=$SC_INF_SHA256" \
        "catalogSha256=$SC_CATALOG_SHA256" \
        "kernelSha256=$SC_KERNEL_SHA256" \
        "installerSha256=$SC_INSTALLER_SHA256" \
        "packageBuilder=$SC_PACKAGE_BUILDER" \
        "packageBuilderSha256=$SC_PACKAGE_BUILDER_SHA256" \
        "guestValidator=$SC_GUEST_VALIDATOR" \
        "guestValidatorSha256=$SC_GUEST_VALIDATOR_SHA256" \
        "qemuSha256=$qemu_sha" \
        "hostDriverSha256=$host_driver_sha" \
        "hostStackSha256=$host_stack_sha" \
        "mdevProfile=$SC_CANONICAL_MDEV_PROFILE" \
        "framebufferMb=$SC_CANONICAL_FB_MB" |
        sha256sum | awk '{print toupper($1)}'
}

signed_consumer_catalog_validate() {
    local key profile_sha
    vgpu_profile_validate_catalog || return 1
    for key in "${SIGNED_CONSUMER_DRIVER_KEYS[@]}"; do
        signed_consumer_driver_load "$key" || return 1
        case "$SC_PRODUCTION_STATUS" in
            "$SIGNED_CONSUMER_PRODUCTION_STATUS_ENABLED") ;;
            "$SIGNED_CONSUMER_PRODUCTION_STATUS_QUARANTINED")
                [[ -n "$SC_PRODUCTION_REASON" ]] || return 1
                ;;
            *) return 1 ;;
        esac
        signed_consumer_profile_load_canonical "$SC_GPU_PROFILE" || return 1
        signed_consumer_driver_assert_profile || return 1
        profile_sha=$(signed_consumer_profile_sha256 "$SC_GPU_PROFILE") || return 1
        [[ "$profile_sha" =~ ^[0-9A-F]{64}$ &&
           "$SC_INSTALLER_SHA256" =~ ^[0-9A-F]{64}$ &&
           "$SC_INF_SHA256" =~ ^[0-9A-F]{64}$ &&
           "$SC_CATALOG_SHA256" =~ ^[0-9A-F]{64}$ &&
           "$SC_KERNEL_SHA256" =~ ^[0-9A-F]{64}$ &&
           "$SC_CATALOG_SIGNER_THUMBPRINT" =~ ^[0-9A-F]{40}$ &&
           "$SC_KERNEL_SIGNER_THUMBPRINT" =~ ^[0-9A-F]{40}$ &&
           "$SC_PACKAGE_BUILDER_SHA256" =~ ^[0-9A-F]{64}$ &&
           "$SC_GUEST_VALIDATOR_SHA256" =~ ^[0-9A-F]{64}$ &&
           "$SC_PACKAGE_BUILDER" =~ ^[A-Za-z0-9._-]+$ &&
           "$SC_GUEST_VALIDATOR" =~ ^[A-Za-z0-9._-]+$ &&
           "$SC_EVIDENCE_DRIVER_REL" != /* &&
           "$SC_EVIDENCE_DRIVER_REL" != *'..'* &&
           "$SC_EVIDENCE_INSTALLER_REL" != /* &&
           "$SC_EVIDENCE_INSTALLER_REL" != *'..'* &&
           -x "$SIGNED_CONSUMER_CATALOG_DIR/../$SC_PACKAGE_BUILDER" &&
           ! -L "$SIGNED_CONSUMER_CATALOG_DIR/../$SC_PACKAGE_BUILDER" &&
           -f "$SIGNED_CONSUMER_CATALOG_DIR/../guest/$SC_GUEST_VALIDATOR" &&
           ! -L "$SIGNED_CONSUMER_CATALOG_DIR/../guest/$SC_GUEST_VALIDATOR" ]] \
            || return 1
    done
}

#!/usr/bin/env bash
# Unit coverage for the per-instance vGPU storage resolver. No real VM files are
# read or modified.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
STORAGE_LIB="$REPO_ROOT/deploy/lib/vm-storage.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 label=$3
    [[ "$actual" == "$expected" ]] || \
        fail "$label: expected '$expected', got '$actual'"
}

reset_storage_env() {
    unset IMAGE_ROOT ISO_DIR VM_ROOT VMS_DIR VM_INSTANCES_DIR VM_CONFIG_DIR VM_DISK_DIR VM_BASE_DIR
    unset VM_INSTANCE_DIR VM_INSTANCE_ID VM_STORAGE_COMPAT_FALLBACK
    unset VM_SHARED_DIR VM_CONTROL_DIR
    unset VM_NVRAM_DIR VM_RUN_DIR VM_LOG_DIR VM_ASSET_DIR
    unset VM_DISK_ARCHIVE_DIR VM_BASE_ARCHIVE_DIR VM_NVRAM_BACKUP_DIR
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

(
    reset_storage_env
    IMAGE_ROOT="$TMP_DIR/image root"
    # shellcheck source=../../../lib/vm-storage.sh
    source "$STORAGE_LIB"
    vm_storage_init
    assert_eq "$IMAGE_ROOT/vms" "$VM_ROOT" "IMAGE_ROOT-derived VM_ROOT"
    assert_eq "$VM_ROOT" "$VM_INSTANCES_DIR" "instances directory"
    assert_eq "$VM_ROOT/legacy/configs" "$VM_CONFIG_DIR" "config directory"
    assert_eq "$VM_ROOT/legacy/disks" "$VM_DISK_DIR" "disk directory"
    assert_eq "$VM_ROOT/shared/bases" "$VM_BASE_DIR" "base directory"
    assert_eq "$VM_ROOT/legacy/nvram" "$VM_NVRAM_DIR" "NVRAM directory"
    assert_eq "$VM_ROOT/control" "$VM_RUN_DIR" "control directory"
    assert_eq "$IMAGE_ROOT/iso" "$ISO_DIR" "ISO directory"
    assert_eq "$VM_INSTANCES_DIR/7/vm.conf" \
        "$(vm_storage_config_path 7)" "fresh config path"
    assert_eq "$VM_INSTANCES_DIR/7/disk.qcow2" \
        "$(vm_storage_disk_path 7)" "fresh disk path"
    assert_eq "$VM_INSTANCES_DIR/7/nvram.fd" \
        "$(vm_storage_nvram_path 7)" "fresh NVRAM path"
    assert_eq "$VM_INSTANCES_DIR/7/log/qemu.log" \
        "$(vm_storage_log_path 7)" "fresh log path"
    assert_eq "$VM_INSTANCES_DIR/7/run/qemu.pid" \
        "$(vm_storage_run_path 7 pid)" "fresh runtime path"
    assert_eq "$VM_INSTANCES_DIR/7/run/start.lock" \
        "$(vm_storage_run_path 7 start.lock)" "in-bundle start lock"
    assert_eq "$VM_INSTANCES_DIR/7/run/disk.lock" \
        "$(vm_storage_run_path 7 disk.lock)" "in-bundle disk lock"
    assert_eq "$VM_INSTANCES_DIR/7/run/tpm.lock" \
        "$(vm_storage_run_path 7 tpm.lock)" "in-bundle TPM lock"
    assert_eq "$VM_INSTANCES_DIR/7/run/optical.lock" \
        "$(vm_storage_run_path 7 optical.lock)" "in-bundle optical lock"
    assert_eq "$VM_INSTANCES_DIR/7/run/usb-directory.lock" \
        "$(vm_storage_run_path 7 usb-directory.lock)" "in-bundle USB lock"
    assert_eq "$VM_BASE_DIR/win10-base.qcow2" \
        "$(vm_storage_base_path)" "fresh base path"
    assert_eq "$VM_BASE_DIR/win10-ltsc-v2.qcow2" \
        "$(vm_storage_base_path win10-ltsc-v2)" "named base path"
    if vm_storage_base_path '../escape' >"$TMP_DIR/base-name.out" \
            2>"$TMP_DIR/base-name.err"; then
        fail "unsafe base name was accepted"
    fi
    grep -Fq 'invalid base name' "$TMP_DIR/base-name.err" \
        || fail "unsafe base-name refusal was not clear"
    mkdir -p "$VM_BASE_DIR"
    touch "$VM_BASE_DIR/win10-ltsc-v2.qcow2" \
        "$VM_BASE_DIR/win11-vgpu-v1.qcow2"
    assert_eq $'win10-ltsc-v2\nwin11-vgpu-v1' \
        "$(vm_storage_list_base_names)" "managed base listing"
)

(
    reset_storage_env
    VM_ROOT="$TMP_DIR/legacy/vms"
    VM_STORAGE_COMPAT_FALLBACK=1
    mkdir -p "$VM_ROOT" "$VM_ROOT/disks" "$VM_ROOT/bases" "$VM_ROOT/nvram"
    VM_DISK_DIR="$VM_ROOT/disks"
    VM_BASE_DIR="$VM_ROOT/bases"
    VM_NVRAM_DIR="$VM_ROOT/nvram"
    touch "$VM_ROOT/win10-vm1.qcow2" "$VM_ROOT/win10-base.qcow2" \
        "$VM_ROOT/vm1_VARS.fd"
    source "$STORAGE_LIB"
    vm_storage_init
    assert_eq "$VM_ROOT/win10-vm1.qcow2" \
        "$(vm_storage_disk_path 1)" "legacy disk fallback"
    assert_eq "$VM_ROOT/win10-base.qcow2" \
        "$(vm_storage_base_path)" "legacy base fallback"
    assert_eq "$VM_ROOT/vm1_VARS.fd" \
        "$(vm_storage_nvram_path 1)" "legacy NVRAM fallback"

    touch "$VM_DISK_DIR/win10-vm1.qcow2"
    if vm_storage_disk_path 1 >"$TMP_DIR/conflict.out" 2>"$TMP_DIR/conflict.err"; then
        fail "different legacy/canonical disks were not rejected"
    fi
    grep -Fq 'ambiguous vm1 disk' "$TMP_DIR/conflict.err" \
        || fail "disk conflict did not explain the ambiguity"

    rm -f "$VM_ROOT/win10-vm1.qcow2"
    ln -s "$VM_DISK_DIR/win10-vm1.qcow2" "$VM_ROOT/win10-vm1.qcow2"
    assert_eq "$VM_DISK_DIR/win10-vm1.qcow2" \
        "$(vm_storage_disk_path 1)" "same-file compatibility symlink"

    mkdir -p "$VM_INSTANCES_DIR/1"
    touch "$VM_INSTANCES_DIR/1/disk.qcow2"
    if vm_storage_disk_path 1 >/dev/null 2>"$TMP_DIR/three-way.err"; then
        fail "instance/categorized disk conflict was not rejected"
    fi
    grep -Fq 'ambiguous vm1 disk' "$TMP_DIR/three-way.err" \
        || fail "three-generation conflict did not explain the ambiguity"
)

(
    reset_storage_env
    VM_ROOT="$TMP_DIR/custom/vms"
    VM_DISK_DIR="$TMP_DIR/custom/all storage"
    source "$STORAGE_LIB"
    vm_storage_init
    assert_eq "$VM_DISK_DIR" "$VM_INSTANCES_DIR" \
        "explicit legacy VM_DISK_DIR instance root"
    assert_eq "$VM_DISK_DIR" "$VM_BASE_DIR" "explicit legacy VM_DISK_DIR base"
    assert_eq "$VM_DISK_DIR" "$VM_NVRAM_DIR" "explicit legacy VM_DISK_DIR NVRAM"
)

(
    reset_storage_env
    IMAGE_ROOT="$TMP_DIR/iso-test"
    mkdir -p "$IMAGE_ROOT" "$IMAGE_ROOT/iso"
    touch "$IMAGE_ROOT/win10-ltsc.iso"
    source "$STORAGE_LIB"
    vm_storage_init
    assert_eq "$IMAGE_ROOT/win10-ltsc.iso" \
        "$(vm_storage_iso_path win10-ltsc.iso)" "legacy ISO fallback"
    touch "$ISO_DIR/win10-ltsc.iso"
    if vm_storage_iso_path win10-ltsc.iso >/dev/null 2>"$TMP_DIR/iso.err"; then
        fail "different legacy/canonical ISOs were not rejected"
    fi
    if vm_storage_disk_path '../1' >/dev/null 2>&1; then
        fail "invalid VM id was accepted by the resolver"
    fi
)

(
    reset_storage_env
    VM_ROOT="$TMP_DIR/unsafe/vms"
    mkdir -p "$VM_ROOT" "$TMP_DIR/unsafe/outside"
    ln -s "$TMP_DIR/unsafe/outside" "$VM_ROOT/9"
    source "$STORAGE_LIB"
    vm_storage_init
    if vm_storage_prepare_instance 9 >/dev/null 2>"$TMP_DIR/unsafe.err"; then
        fail "instance preparation followed a VM directory symlink"
    fi
    grep -Fq 'instance directory is unsafe' "$TMP_DIR/unsafe.err" \
        || fail "unsafe instance directory refusal was not clear"
)

(
    reset_storage_env
    IMAGE_ROOT="$TMP_DIR/namespace-guard"
    mkdir -p "$IMAGE_ROOT/vms/instances/vm3"
    touch "$IMAGE_ROOT/vms/instances/vm3/vm.conf"
    source "$STORAGE_LIB"
    vm_storage_init

    vm_storage_namespace_migration_required 3 \
        || fail "old G-11 bundle did not trigger the namespace guard"
    if vm_storage_require_namespace_ready 3 \
            >"$TMP_DIR/namespace-guard.out" \
            2>"$TMP_DIR/namespace-guard.err"; then
        fail "mutating lifecycle guard accepted a duplicate vm3"
    fi
    grep -Fq 'refusing a duplicate vm3' "$TMP_DIR/namespace-guard.err" \
        || fail "namespace guard refusal was not clear"
    [[ ! -e "$IMAGE_ROOT/vms/3" ]] \
        || fail "namespace guard created the numeric destination"

    vm_storage_select_legacy_instance_dir 3 \
        "$IMAGE_ROOT/vms/instances/vm3"
    vm_storage_require_namespace_ready 3 \
        || fail "explicitly selected old bundle was incorrectly rejected"
)

(
    reset_storage_env
    IMAGE_ROOT="$TMP_DIR/v11-collision"
    mkdir -p "$IMAGE_ROOT/vms/4"
    touch "$IMAGE_ROOT/vms/4/profile"
    source "$STORAGE_LIB"
    vm_storage_init

    if vm_storage_require_namespace_ready 4 \
            >"$TMP_DIR/v11-collision.out" \
            2>"$TMP_DIR/v11-collision.err"; then
        fail "V-11-marked numeric directory was accepted as G-11"
    fi
    grep -Fq 'contains V-11 state' "$TMP_DIR/v11-collision.err" \
        || fail "V-11 collision refusal was not clear"
)

(
    reset_storage_env
    IMAGE_ROOT="$TMP_DIR/historical-root"
    mkdir -p "$IMAGE_ROOT/vms/G-11"
    source "$STORAGE_LIB"
    vm_storage_init

    if vm_storage_select_root "$IMAGE_ROOT/vms/G-11" \
            >"$TMP_DIR/historical-root.out" \
            2>"$TMP_DIR/historical-root.err"; then
        fail "--vms-dir accepted the obsolete G-11 namespace as a new root"
    fi
    grep -Fq 'old G-11 source cannot be selected' \
        "$TMP_DIR/historical-root.err" \
        || fail "historical root refusal was not clear"
)

echo "PASS: per-instance VM storage paths, three-generation fallback, and conflicts"

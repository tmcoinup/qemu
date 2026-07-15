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
    unset IMAGE_ROOT ISO_DIR VM_ROOT VM_INSTANCES_DIR VM_CONFIG_DIR VM_DISK_DIR VM_BASE_DIR
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
    assert_eq "$VM_ROOT/instances" "$VM_INSTANCES_DIR" "instances directory"
    assert_eq "$VM_ROOT/configs" "$VM_CONFIG_DIR" "config directory"
    assert_eq "$VM_ROOT/disks" "$VM_DISK_DIR" "disk directory"
    assert_eq "$VM_ROOT/bases" "$VM_BASE_DIR" "base directory"
    assert_eq "$VM_ROOT/nvram" "$VM_NVRAM_DIR" "NVRAM directory"
    assert_eq "$IMAGE_ROOT/iso" "$ISO_DIR" "ISO directory"
    assert_eq "$VM_INSTANCES_DIR/vm7/vm.conf" \
        "$(vm_storage_config_path 7)" "fresh config path"
    assert_eq "$VM_INSTANCES_DIR/vm7/disk.qcow2" \
        "$(vm_storage_disk_path 7)" "fresh disk path"
    assert_eq "$VM_INSTANCES_DIR/vm7/nvram.fd" \
        "$(vm_storage_nvram_path 7)" "fresh NVRAM path"
    assert_eq "$VM_INSTANCES_DIR/vm7/log/qemu.log" \
        "$(vm_storage_log_path 7)" "fresh log path"
    assert_eq "$VM_INSTANCES_DIR/vm7/run/qemu.pid" \
        "$(vm_storage_run_path 7 pid)" "fresh runtime path"
    assert_eq "$VM_RUN_DIR/vm7.start.lock" \
        "$(vm_storage_run_path 7 start.lock)" "global start lock"
    assert_eq "$VM_RUN_DIR/vm7.disk.lock" \
        "$(vm_storage_run_path 7 disk.lock)" "global disk lock"
    assert_eq "$VM_BASE_DIR/win10-base.qcow2" \
        "$(vm_storage_base_path)" "fresh base path"
)

(
    reset_storage_env
    VM_ROOT="$TMP_DIR/legacy/vms"
    mkdir -p "$VM_ROOT" "$VM_ROOT/disks" "$VM_ROOT/bases" "$VM_ROOT/nvram"
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

    mkdir -p "$VM_INSTANCES_DIR/vm1"
    touch "$VM_INSTANCES_DIR/vm1/disk.qcow2"
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
    mkdir -p "$VM_ROOT/instances" "$TMP_DIR/unsafe/outside"
    ln -s "$TMP_DIR/unsafe/outside" "$VM_ROOT/instances/vm9"
    source "$STORAGE_LIB"
    vm_storage_init
    if vm_storage_prepare_instance 9 >/dev/null 2>"$TMP_DIR/unsafe.err"; then
        fail "instance preparation followed a VM directory symlink"
    fi
    grep -Fq 'instance directory is unsafe' "$TMP_DIR/unsafe.err" \
        || fail "unsafe instance directory refusal was not clear"
)

echo "PASS: per-instance VM storage paths, three-generation fallback, and conflicts"

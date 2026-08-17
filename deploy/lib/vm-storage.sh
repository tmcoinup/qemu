#!/usr/bin/env bash
# Canonical storage layout for the G-11 deploy/scripts vGPU workflow.
#
# As on V-11, the default instance parent is IMAGE_ROOT/vms and one VM uses a
# numeric directory below it.  G-11 and V-11 remain independent branches: a
# V-11-marked numeric directory is rejected instead of being silently merged
# into a G-11 VM.  Use --vms-dir/VM_ROOT when both layouts must coexist.

vm_storage_init() {
    local disk_dir_was_set=0

    [[ -n "${VM_DISK_DIR:-}" ]] && disk_dir_was_set=1
    : "${IMAGE_ROOT:=/home/ubuntu/images}"
    if [[ -n "${VM_ROOT:-}" && -n "${VMS_DIR:-}" &&
          "${VM_ROOT%/}" != "${VMS_DIR%/}" ]]; then
        echo "[vm-storage] VM_ROOT and VMS_DIR select different roots" >&2
        return 2
    fi
    if [[ -z "${VM_ROOT:-}" ]]; then
        VM_ROOT=${VMS_DIR:-$IMAGE_ROOT/vms}
    fi
    if [[ "$VM_ROOT" != / && "$VM_ROOT" == */ ]]; then
        VM_ROOT=${VM_ROOT%/}
    fi
    : "${VMS_DIR:=$VM_ROOT}"
    : "${ISO_DIR:=$IMAGE_ROOT/iso}"
    : "${STAGE_DIR:=$IMAGE_ROOT/staging}"
    if [[ -z "${VM_INSTANCES_DIR:-}" ]]; then
        if ((disk_dir_was_set)); then
            # Compatibility for callers that historically selected a separate
            # disk mount with VM_DISK_DIR.  New data still gets one numeric
            # directory per instance on that mount.
            VM_INSTANCES_DIR=$VM_DISK_DIR
        else
            # One G-11 VM is one complete numeric bundle below VM_ROOT.
            VM_INSTANCES_DIR=$VM_ROOT
        fi
    fi
    : "${VM_SHARED_DIR:=$VM_ROOT/shared}"
    : "${VM_CONFIG_DIR:=$VM_ROOT/legacy/configs}"
    : "${VM_DISK_DIR:=$VM_ROOT/legacy/disks}"

    # Preserve the historical meaning of an explicitly supplied VM_DISK_DIR:
    # it used to contain disks, base images and per-VM NVRAM together.
    if [[ -z "${VM_BASE_DIR:-}" ]]; then
        if ((disk_dir_was_set)); then
            VM_BASE_DIR=$VM_DISK_DIR
        else
            VM_BASE_DIR=$VM_SHARED_DIR/bases
        fi
    fi
    if [[ -z "${VM_NVRAM_DIR:-}" ]]; then
        if ((disk_dir_was_set)); then
            VM_NVRAM_DIR=$VM_DISK_DIR
        else
            VM_NVRAM_DIR=$VM_ROOT/legacy/nvram
        fi
    fi

    # VM_RUN_DIR is retained as an API name for lifecycle helpers, but this is
    # a global coordination directory, not a place for VM runtime state.
    : "${VM_CONTROL_DIR:=${VM_RUN_DIR:-$VM_ROOT/control}}"
    : "${VM_RUN_DIR:=$VM_CONTROL_DIR}"
    : "${VM_LOG_DIR:=$VM_ROOT/legacy/log}"
    : "${VM_ASSET_DIR:=$VM_SHARED_DIR/assets}"
    : "${VM_DISK_ARCHIVE_DIR:=$VM_DISK_DIR/archive}"
    : "${VM_BASE_ARCHIVE_DIR:=$VM_BASE_DIR/archive}"
    : "${VM_NVRAM_BACKUP_DIR:=$VM_NVRAM_DIR/backups}"
    : "${VM_STORAGE_COMPAT_FALLBACK:=0}"

    export IMAGE_ROOT ISO_DIR STAGE_DIR VM_ROOT VMS_DIR VM_INSTANCES_DIR
    export VM_INSTANCE_DIR VM_INSTANCE_ID VM_STORAGE_COMPAT_FALLBACK
    export VM_SHARED_DIR VM_CONFIG_DIR VM_DISK_DIR VM_BASE_DIR
    export VM_NVRAM_DIR VM_CONTROL_DIR VM_RUN_DIR VM_LOG_DIR VM_ASSET_DIR
    export VM_DISK_ARCHIVE_DIR VM_BASE_ARCHIVE_DIR VM_NVRAM_BACKUP_DIR
}

vm_storage_prepare() {
    vm_storage_init
    vm_storage_validate_root_path "$VM_ROOT" "VM root" || return
    if [[ -z "${VM_INSTANCE_DIR:-}" &&
          ( -L "$VM_INSTANCES_DIR" ||
            ( -e "$VM_INSTANCES_DIR" && ! -d "$VM_INSTANCES_DIR" ) ) ]]; then
        echo "[vm-storage] instances root must be a real directory: $VM_INSTANCES_DIR" >&2
        return 1
    fi
    mkdir -p "$ISO_DIR" "$VM_BASE_DIR" "$VM_RUN_DIR" \
        "$VM_ASSET_DIR" "$VM_BASE_ARCHIVE_DIR"
    if [[ -z "${VM_INSTANCE_DIR:-}" ]]; then
        mkdir -p "$VM_INSTANCES_DIR"
    fi
}

vm_storage_id_is_supported() {
    local id=${1:-}
    [[ "$id" =~ ^[1-9][0-9]*$ && ${#id} -le 10 ]] || return 1
    ((10#$id <= 2147483647))
}

vm_storage_validate_id() {
    vm_storage_id_is_supported "${1:-}" || {
        echo "invalid VM id for storage path (expected 1..2147483647): ${1:-<empty>}" >&2
        return 2
    }
}

vm_storage_validate_path_text() {
    local path=${1:-} label=${2:-path}

    [[ -n "$path" && "$path" == /* && "$path" != / ]] || {
        echo "[vm-storage] $label must be an absolute non-root path: ${path:-<empty>}" >&2
        return 2
    }
    case "$path" in
        *$'\n'*|*$'\r'*|*,*|*'#'*)
            echo "[vm-storage] $label contains a character unsupported by QEMU/swtpm: $path" >&2
            return 2
            ;;
    esac
}

# Validate an absolute directory path without creating it.  The final path may
# be absent, but every existing ancestor must be a real (non-symlink)
# directory.  This is used by --vms-dir before vm_storage_prepare creates it.
vm_storage_validate_root_path() {
    local path=${1:-} label=${2:-directory}
    local probe next canonical lexical

    vm_storage_validate_path_text "$path" "$label" || return
    path=${path%/}
    probe=$path
    while [[ ! -e "$probe" && ! -L "$probe" ]]; do
        next=${probe%/*}
        [[ -n "$next" && "$next" != "$probe" ]] || next=/
        probe=$next
    done
    [[ -d "$probe" && ! -L "$probe" ]] || {
        echo "[vm-storage] $label has an unsafe existing component: $probe" >&2
        return 2
    }
    canonical=$(realpath -e -- "$probe") || return
    lexical=$(realpath -ms -- "$probe") || return
    [[ "$canonical" == "$lexical" ]] || {
        echo "[vm-storage] $label may not traverse a symbolic-link component: $path" >&2
        return 2
    }
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -d "$path" && ! -L "$path" ]] || {
            echo "[vm-storage] $label must be a real directory: $path" >&2
            return 2
        }
    fi
}

vm_storage_root_is_historical() {
    local root=${1:-} image_root=${IMAGE_ROOT:-/home/ubuntu/images}

    root=${root%/}
    image_root=${image_root%/}
    [[ "$root" == "$image_root/vms/G-11" ||
       "$root" == "$image_root/vms/instances" ]]
}

# Select the complete managed root.  Unlike --instances-dir this moves shared
# bases, assets and global coordination into the same caller-selected tree.
vm_storage_select_root() {
    local requested=${1:-} canonical

    vm_storage_validate_root_path "$requested" "VMS directory" || return
    canonical=$(realpath -ms -- "${requested%/}") || return
    if vm_storage_root_is_historical "$canonical"; then
        echo "[vm-storage] an old G-11 source cannot be selected as the new VMS root: $canonical" >&2
        echo "  migrate it to ${IMAGE_ROOT:-/home/ubuntu/images}/vms or choose a separate new root" >&2
        return 2
    fi
    VM_ROOT=$canonical
    VMS_DIR=$canonical
    unset VM_INSTANCE_DIR VM_INSTANCE_ID VM_INSTANCES_DIR
    unset VM_SHARED_DIR VM_CONFIG_DIR VM_DISK_DIR VM_BASE_DIR VM_NVRAM_DIR
    unset VM_CONTROL_DIR VM_RUN_DIR VM_LOG_DIR VM_ASSET_DIR
    unset VM_DISK_ARCHIVE_DIR VM_BASE_ARCHIVE_DIR VM_NVRAM_BACKUP_DIR
    VM_STORAGE_COMPAT_FALLBACK=0
    export VM_ROOT VMS_DIR VM_STORAGE_COMPAT_FALLBACK
}

# Bind this process to one exact VM bundle.  The parent must already exist so
# a mistyped or unmounted path cannot silently create a large VM on /.
vm_storage_select_instance_dir() {
    local id=${1:-} requested=${2:-} parent basename
    local canonical_parent lexical_parent

    vm_storage_validate_id "$id" || return
    vm_storage_validate_path_text "$requested" "VM directory" || return
    requested=${requested%/}
    basename=${requested%/}
    basename=${basename##*/}
    [[ "$basename" == "$id" ]] || {
        echo "[vm-storage] VM directory basename must be $id: $requested" >&2
        return 2
    }
    parent=${requested%/}
    parent=${parent%/*}
    [[ -n "$parent" ]] || parent=/
    if [[ ! -d "$parent" || -L "$parent" ]]; then
        echo "[vm-storage] VM directory parent must be an existing real directory: $parent" >&2
        return 2
    fi
    canonical_parent=$(realpath -e -- "$parent") || {
        echo "[vm-storage] cannot resolve VM directory parent: $parent" >&2
        return 2
    }
    lexical_parent=$(realpath -ms -- "$parent") || return
    [[ "$canonical_parent" == "$lexical_parent" ]] || {
        echo "[vm-storage] VM directory may not traverse a symbolic-link component: $requested" >&2
        return 2
    }
    if [[ -e "$requested" || -L "$requested" ]]; then
        [[ -d "$requested" && ! -L "$requested" ]] || {
            echo "[vm-storage] VM directory must be a real directory: $requested" >&2
            return 2
        }
    fi

    VM_INSTANCE_DIR=$canonical_parent/$id
    VM_INSTANCE_ID=$id
    VM_STORAGE_COMPAT_FALLBACK=0
    export VM_INSTANCE_DIR VM_INSTANCE_ID VM_STORAGE_COMPAT_FALLBACK
}

# Bind stop/migration recovery to one of the two historical vm<ID> paths.
# Normal CLI callers must use vm_storage_select_instance_dir and a numeric
# basename, so this compatibility function cannot create new legacy bundles.
vm_storage_select_legacy_instance_dir() {
    local id=${1:-} requested=${2:-} parent canonical_parent lexical_parent
    local namespaced pre_namespace

    vm_storage_validate_id "$id" || return
    vm_storage_validate_path_text "$requested" "legacy VM directory" || return
    requested=${requested%/}
    namespaced=$(vm_storage_g11_namespace_instance_dir "$id") || return
    pre_namespace=$(vm_storage_pre_namespace_instance_dir "$id") || return
    [[ "$requested" == "$namespaced" || "$requested" == "$pre_namespace" ]] || {
        echo "[vm-storage] unsupported legacy VM directory: $requested" >&2
        return 2
    }
    [[ -d "$requested" && ! -L "$requested" ]] || {
        echo "[vm-storage] legacy VM directory must be a real directory: $requested" >&2
        return 2
    }
    parent=${requested%/*}
    canonical_parent=$(realpath -e -- "$parent") || return
    lexical_parent=$(realpath -ms -- "$parent") || return
    [[ "$canonical_parent" == "$lexical_parent" ]] || {
        echo "[vm-storage] legacy VM directory traverses a symbolic link: $requested" >&2
        return 2
    }
    VM_INSTANCE_DIR=$canonical_parent/${requested##*/}
    VM_INSTANCE_ID=$id
    VM_STORAGE_COMPAT_FALLBACK=0
    export VM_INSTANCE_DIR VM_INSTANCE_ID VM_STORAGE_COMPAT_FALLBACK
}

# Select an instance pool; numeric <ID> is appended by the resolver.  This is
# retained for compatibility; --vms-dir is preferred when the complete root
# (including shared/control) should move together.
vm_storage_select_instances_dir() {
    local requested=${1:-} canonical lexical

    vm_storage_validate_path_text "$requested" "instances directory" || return
    requested=${requested%/}
    [[ -d "$requested" && ! -L "$requested" ]] || {
        echo "[vm-storage] instances directory must be an existing real directory: $requested" >&2
        return 2
    }
    canonical=$(realpath -e -- "$requested") || return
    lexical=$(realpath -ms -- "$requested") || return
    [[ "$canonical" == "$lexical" ]] || {
        echo "[vm-storage] instances directory may not traverse a symbolic-link component: $requested" >&2
        return 2
    }
    unset VM_INSTANCE_DIR VM_INSTANCE_ID
    VM_INSTANCES_DIR=$canonical
    VM_STORAGE_COMPAT_FALLBACK=0
    export VM_INSTANCES_DIR VM_STORAGE_COMPAT_FALLBACK
}

vm_storage_instance_dir() {
    local id=$1
    vm_storage_validate_id "$id" || return
    if [[ -n "${VM_INSTANCE_DIR:-}" ]]; then
        if [[ "${VM_INSTANCE_ID:-}" != "$id" ]]; then
            echo "[vm-storage] selected VM directory belongs to vm${VM_INSTANCE_ID:-<unset>}, not vm$id" >&2
            return 2
        fi
        printf '%s\n' "$VM_INSTANCE_DIR"
        return 0
    fi
    printf '%s/%s\n' "$VM_INSTANCES_DIR" "$1"
}

# G-11 layouts used before numeric VM directories became canonical.  They are
# read only by the migration guard/tool and are never normal write targets.
vm_storage_g11_namespace_instance_dir() {
    vm_storage_validate_id "$1" || return
    printf '%s/vms/G-11/vm%s\n' "$IMAGE_ROOT" "$1"
}

vm_storage_pre_namespace_instance_dir() {
    vm_storage_validate_id "$1" || return
    printf '%s/vms/instances/vm%s\n' "$IMAGE_ROOT" "$1"
}

vm_storage_namespace_migration_required() {
    local id=$1 selected legacy

    selected=$(vm_storage_instance_dir "$id") || return
    # An explicit/custom instance parent is independent of the default old
    # trees and must not be blocked by an unrelated VM with the same ID.
    [[ "$selected" == "${IMAGE_ROOT%/}/vms/$id" ]] || return 1
    for legacy in \
        "$(vm_storage_g11_namespace_instance_dir "$id")" \
        "$(vm_storage_pre_namespace_instance_dir "$id")"; do
        [[ "$selected" != "$legacy" ]] || continue
        if [[ -e "$legacy/vm.conf" || -L "$legacy/vm.conf" ||
              -e "$legacy/disk.qcow2" || -L "$legacy/disk.qcow2" ||
              -e "$legacy/nvram.fd" || -L "$legacy/nvram.fd" ||
              -e "$legacy/tpm" || -L "$legacy/tpm" ]]; then
            return 0
        fi
    done
    return 1
}

vm_storage_v11_collision() {
    local id=$1 selected

    selected=$(vm_storage_instance_dir "$id") || return
    [[ -d "$selected" && ! -L "$selected" ]] || return 1
    [[ -e "$selected/profile" || -L "$selected/profile" ||
       -e "$selected/ovmf-vars.fd" || -L "$selected/ovmf-vars.fd" ||
       -e "$selected/tpm-state" || -L "$selected/tpm-state" ||
       -e "$selected/tpm12-state" || -L "$selected/tpm12-state" ]]
}

# Every mutating lifecycle entry point uses this guard.  Otherwise a direct
# create-vm/create-disk call could bypass start-vm's check and create a second
# G-11 VM with the same ID while the complete old bundle still exists.
vm_storage_require_namespace_ready() {
    local id=$1 selected legacy rc found_legacy=0

    selected=$(vm_storage_instance_dir "$id") || return
    if vm_storage_root_is_historical "$VM_ROOT"; then
        echo "[vm-storage] refusing to create numeric data inside an old G-11 source root" >&2
        echo "  selected: $VM_ROOT" >&2
        echo "  run: ./deploy/scripts/migrate-g11-layout.sh --check" >&2
        return 1
    fi
    if vm_storage_v11_collision "$id"; then
        echo "[vm-storage] numeric directory contains V-11 state; refusing to mix branches" >&2
        echo "  directory: $selected" >&2
        echo "  choose an unused ID or a separate root with --vms-dir" >&2
        return 1
    fi
    if vm_storage_namespace_migration_required "$id"; then
        :
    else
        rc=$?
        ((rc == 1)) && return 0
        return "$rc"
    fi
    echo "[vm-storage] old G-11 bundle still needs namespace migration; refusing a duplicate vm$id" >&2
    for legacy in \
        "$(vm_storage_g11_namespace_instance_dir "$id")" \
        "$(vm_storage_pre_namespace_instance_dir "$id")"; do
        if [[ -e "$legacy/vm.conf" || -e "$legacy/disk.qcow2" ||
              -e "$legacy/nvram.fd" || -e "$legacy/tpm" || -L "$legacy" ]]; then
            echo "  old: $legacy" >&2
            found_legacy=1
        fi
    done
    ((found_legacy)) || echo "  old: <unresolved legacy bundle>" >&2
    echo "  new: $selected" >&2
    echo "  run: ./deploy/scripts/migrate-g11-layout.sh --check" >&2
    return 1
}

vm_storage_instance_log_dir() {
    local instance
    instance=$(vm_storage_instance_dir "$1") || return
    printf '%s/log\n' "$instance"
}

vm_storage_instance_run_dir() {
    local instance
    instance=$(vm_storage_instance_dir "$1") || return
    printf '%s/run\n' "$instance"
}

vm_storage_instance_disk_backup_dir() {
    local instance
    instance=$(vm_storage_instance_dir "$1") || return
    printf '%s/backups/disks\n' "$instance"
}

vm_storage_instance_nvram_backup_dir() {
    local instance
    instance=$(vm_storage_instance_dir "$1") || return
    printf '%s/backups/nvram\n' "$instance"
}

vm_storage_validate_instance_tree() {
    local id=$1 instance candidate
    vm_storage_validate_id "$id" || return
    instance=$(vm_storage_instance_dir "$id") || return
    for candidate in \
        "$instance" "$instance/log" "$instance/run" \
        "$instance/backups" "$instance/backups/disks" \
        "$instance/backups/nvram"; do
        if [[ -L "$candidate" || ( -e "$candidate" && ! -d "$candidate" ) ]]; then
            echo "[vm-storage] instance directory is unsafe: $candidate" >&2
            return 1
        fi
    done
    if [[ -z "${VM_INSTANCE_DIR:-}" &&
          ( -L "$VM_INSTANCES_DIR" ||
            ( -e "$VM_INSTANCES_DIR" && ! -d "$VM_INSTANCES_DIR" ) ) ]]; then
        echo "[vm-storage] instances root must be a real directory: $VM_INSTANCES_DIR" >&2
        return 1
    fi
}

vm_storage_prepare_instance() {
    local id=$1 instance
    instance=$(vm_storage_instance_dir "$id") || return
    vm_storage_validate_instance_tree "$id" || return
    mkdir -p "$instance" \
        "$(vm_storage_instance_log_dir "$id")" \
        "$(vm_storage_instance_run_dir "$id")" \
        "$(vm_storage_instance_disk_backup_dir "$id")" \
        "$(vm_storage_instance_nvram_backup_dir "$id")"
}

vm_storage_config_preferred_path() {
    local instance
    instance=$(vm_storage_instance_dir "$1") || return
    printf '%s/vm.conf\n' "$instance"
}

vm_storage_config_categorized_path() {
    vm_storage_validate_id "$1" || return
    printf '%s/vm%s.conf\n' "$VM_CONFIG_DIR" "$1"
}

vm_storage_disk_preferred_path() {
    local instance
    instance=$(vm_storage_instance_dir "$1") || return
    printf '%s/disk.qcow2\n' "$instance"
}

vm_storage_disk_categorized_path() {
    vm_storage_validate_id "$1" || return
    printf '%s/win10-vm%s.qcow2\n' "$VM_DISK_DIR" "$1"
}

vm_storage_disk_legacy_path() {
    vm_storage_validate_id "$1" || return
    printf '%s/win10-vm%s.qcow2\n' "$VM_ROOT" "$1"
}

vm_storage_nvram_preferred_path() {
    local instance
    instance=$(vm_storage_instance_dir "$1") || return
    printf '%s/nvram.fd\n' "$instance"
}

vm_storage_nvram_categorized_path() {
    vm_storage_validate_id "$1" || return
    printf '%s/vm%s_VARS.fd\n' "$VM_NVRAM_DIR" "$1"
}

vm_storage_nvram_legacy_path() {
    vm_storage_validate_id "$1" || return
    printf '%s/vm%s_VARS.fd\n' "$VM_ROOT" "$1"
}

vm_storage_base_preferred_path() {
    printf '%s/win10-base.qcow2\n' "$VM_BASE_DIR"
}

vm_storage_base_legacy_path() {
    printf '%s/win10-base.qcow2\n' "$VM_ROOT"
}

_vm_storage_resolve_many() {
    local label=$1 preferred=$2 candidate first_existing=""
    shift 2

    for candidate in "$preferred" "$@"; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        if [[ -z "$first_existing" ]]; then
            first_existing=$candidate
        elif [[ ! "$candidate" -ef "$first_existing" ]]; then
            echo "[vm-storage] ambiguous $label: multiple paths exist" >&2
            echo "  first: $first_existing" >&2
            echo "  other: $candidate" >&2
            echo "  Stop and reconcile them before continuing; no path was selected." >&2
            return 1
        fi
    done

    if [[ -e "$preferred" || -L "$preferred" ]]; then
        printf '%s\n' "$preferred"
    elif [[ -n "$first_existing" ]]; then
        printf '%s\n' "$first_existing"
    else
        printf '%s\n' "$preferred"
    fi
}

_vm_storage_resolve() {
    local preferred=$1 legacy=$2 label=$3
    _vm_storage_resolve_many "$label" "$preferred" "$legacy"
}

vm_storage_config_path() {
    local preferred categorized
    vm_storage_validate_instance_tree "$1" || return
    preferred=$(vm_storage_config_preferred_path "$1") || return
    if [[ "${VM_STORAGE_COMPAT_FALLBACK:-0}" == 0 ]]; then
        printf '%s\n' "$preferred"
        return 0
    fi
    categorized=$(vm_storage_config_categorized_path "$1") || return
    _vm_storage_resolve_many "vm$1 config" "$preferred" "$categorized"
}

# Existing categorized and flat files remain usable until the storage migrator
# is run.  A new file always resolves into the selected numeric bundle.
vm_storage_disk_path() {
    local preferred categorized legacy
    vm_storage_validate_instance_tree "$1" || return
    preferred=$(vm_storage_disk_preferred_path "$1") || return
    if [[ "${VM_STORAGE_COMPAT_FALLBACK:-0}" == 0 ]]; then
        printf '%s\n' "$preferred"
        return 0
    fi
    categorized=$(vm_storage_disk_categorized_path "$1") || return
    legacy=$(vm_storage_disk_legacy_path "$1") || return
    _vm_storage_resolve_many "vm$1 disk" "$preferred" "$categorized" "$legacy"
}

vm_storage_nvram_path() {
    local preferred categorized legacy
    vm_storage_validate_instance_tree "$1" || return
    preferred=$(vm_storage_nvram_preferred_path "$1") || return
    if [[ "${VM_STORAGE_COMPAT_FALLBACK:-0}" == 0 ]]; then
        printf '%s\n' "$preferred"
        return 0
    fi
    categorized=$(vm_storage_nvram_categorized_path "$1") || return
    legacy=$(vm_storage_nvram_legacy_path "$1") || return
    _vm_storage_resolve_many "vm$1 NVRAM" "$preferred" "$categorized" "$legacy"
}

vm_storage_log_preferred_path() {
    local log_dir
    log_dir=$(vm_storage_instance_log_dir "$1") || return
    printf '%s/qemu.log\n' "$log_dir"
}

vm_storage_log_categorized_path() {
    vm_storage_validate_id "$1" || return
    printf '%s/vm%s.log\n' "$VM_LOG_DIR" "$1"
}

vm_storage_log_path() {
    local preferred categorized
    vm_storage_validate_instance_tree "$1" || return
    preferred=$(vm_storage_log_preferred_path "$1") || return
    if [[ "${VM_STORAGE_COMPAT_FALLBACK:-0}" == 0 ]]; then
        printf '%s\n' "$preferred"
        return 0
    fi
    categorized=$(vm_storage_log_categorized_path "$1") || return
    _vm_storage_resolve_many "vm$1 log" "$preferred" "$categorized"
}

vm_storage_run_preferred_path() {
    local id=$1 kind=$2 run_dir filename
    vm_storage_validate_id "$id" || return
    case "$kind" in
        pid) filename=qemu.pid ;;
        qmp) filename=qmp.sock ;;
        mon) filename=monitor.sock ;;
        mdev) filename=mdev.uuid ;;
        monitor-edid) filename=monitor-edid.sha256 ;;
        start.lock) filename=start.lock ;;
        disk.lock) filename=disk.lock ;;
        tpm.lock) filename=tpm.lock ;;
        *) echo "invalid VM runtime file kind: $kind" >&2; return 2 ;;
    esac
    run_dir=$(vm_storage_instance_run_dir "$id") || return
    printf '%s/%s\n' "$run_dir" "$filename"
}

vm_storage_run_legacy_path() {
    local id=$1 kind=$2
    vm_storage_validate_id "$id" || return
    case "$kind" in
        pid|qmp|mon|mdev|monitor-edid|start.lock|disk.lock|tpm.lock) ;;
        *) echo "invalid VM runtime file kind: $kind" >&2; return 2 ;;
    esac
    printf '%s/vm%s.%s\n' "$VM_RUN_DIR" "$id" "$kind"
}

vm_storage_run_path() {
    local preferred legacy
    vm_storage_validate_instance_tree "$1" || return
    preferred=$(vm_storage_run_preferred_path "$1" "$2") || return
    if [[ "${VM_STORAGE_COMPAT_FALLBACK:-0}" == 0 ]]; then
        printf '%s\n' "$preferred"
        return 0
    fi
    legacy=$(vm_storage_run_legacy_path "$1" "$2") || return
    _vm_storage_resolve_many "vm$1 runtime $2" "$preferred" "$legacy"
}

vm_storage_base_path() {
    local preferred legacy
    preferred=$(vm_storage_base_preferred_path)
    legacy=$(vm_storage_base_legacy_path)
    _vm_storage_resolve "$preferred" "$legacy" "base image"
}

vm_storage_iso_path() {
    local name=${1:-}
    local preferred legacy

    [[ -n "$name" && "$name" == "${name##*/}" ]] || {
        echo "invalid ISO basename: ${name:-<empty>}" >&2
        return 2
    }
    preferred="$ISO_DIR/$name"
    legacy="$IMAGE_ROOT/$name"
    _vm_storage_resolve "$preferred" "$legacy" "ISO $name"
}

# Read qcow2 metadata without guessing.  Callers use the exported shell
# variables below so an empty backing filename is distinguishable from a
# metadata/JSON failure.  A file named *.qcow2 that auto-detects as raw is
# rejected: treating it as standalone would make move/clone safety fail open.
vm_storage_read_qcow2_metadata() {
    local qemu_img=${1:-} image=${2:-} info_json jq_bin

    [[ -n "$qemu_img" && -x "$qemu_img" && -n "$image" ]] || {
        echo "[vm-storage] qemu-img executable and image path are required" >&2
        return 2
    }
    jq_bin=$(command -v jq || true)
    [[ -n "$jq_bin" && -x "$jq_bin" ]] || {
        echo "[vm-storage] jq is required to validate qcow2 metadata" >&2
        return 1
    }
    if ! info_json=$("$qemu_img" info --output=json -- "$image" 2>/dev/null); then
        echo "[vm-storage] qemu-img could not inspect: $image" >&2
        return 1
    fi
    if ! "$jq_bin" -e '
        type == "object" and
        (.format | type == "string") and
        (."virtual-size" | type == "number" and . > 0 and floor == .) and
        ((."backing-filename" == null) or (."backing-filename" | type == "string")) and
        ((."full-backing-filename" == null) or (."full-backing-filename" | type == "string")) and
        ((."format-specific".data."data-file" == null) or
            (."format-specific".data."data-file" | type == "string"))
    ' <<<"$info_json" >/dev/null 2>&1; then
        echo "[vm-storage] invalid qemu-img JSON metadata: $image" >&2
        return 1
    fi

    VM_STORAGE_QCOW2_FORMAT=$("$jq_bin" -r '.format' <<<"$info_json")
    VM_STORAGE_QCOW2_VIRTUAL_SIZE=$("$jq_bin" -r '."virtual-size" | tostring' \
        <<<"$info_json")
    VM_STORAGE_QCOW2_BACKING=$("$jq_bin" -r '."backing-filename" // ""' <<<"$info_json")
    VM_STORAGE_QCOW2_FULL_BACKING=$("$jq_bin" -r '."full-backing-filename" // ""' <<<"$info_json")
    VM_STORAGE_QCOW2_DATA_FILE=$("$jq_bin" -r \
        '."format-specific".data."data-file" // ""' <<<"$info_json")
    if [[ "$VM_STORAGE_QCOW2_FORMAT" != qcow2 ]]; then
        echo "[vm-storage] expected qcow2, detected $VM_STORAGE_QCOW2_FORMAT: $image" >&2
        return 1
    fi
    export VM_STORAGE_QCOW2_FORMAT VM_STORAGE_QCOW2_VIRTUAL_SIZE
    export VM_STORAGE_QCOW2_BACKING
    export VM_STORAGE_QCOW2_FULL_BACKING VM_STORAGE_QCOW2_DATA_FILE
}

# Validate the complete backing chain for a managed qcow2.  The returned
# arrays contain normalized filesystem paths for every layer (top first) and
# every external data-file.  Protocol filenames are deliberately unsupported:
# lifecycle tools must fail closed rather than treating file:/, json:, nbd:,
# etc. as ordinary relative host paths.
vm_storage_read_qcow2_chain_metadata() {
    local qemu_img=${1:-} image=${2:-} chain_json jq_bin count idx
    local raw_filename layer_path layer_full data_file data_path

    [[ -n "$qemu_img" && -x "$qemu_img" && -n "$image" ]] || {
        echo "[vm-storage] qemu-img executable and image path are required" >&2
        return 2
    }
    jq_bin=$(command -v jq || true)
    [[ -n "$jq_bin" && -x "$jq_bin" ]] || {
        echo "[vm-storage] jq is required to validate qcow2 backing chains" >&2
        return 1
    }
    if ! chain_json=$("$qemu_img" info --backing-chain --output=json -- "$image" \
            2>/dev/null); then
        echo "[vm-storage] qemu-img could not inspect complete chain: $image" >&2
        return 1
    fi
    if ! "$jq_bin" -e '
        type == "array" and length > 0 and
        (.[0].format == "qcow2") and
        all(.[];
            type == "object" and
            (.filename | type == "string") and
            (.format | type == "string") and
            ((."backing-filename" == null) or
                (."backing-filename" | type == "string")) and
            ((."full-backing-filename" == null) or
                (."full-backing-filename" | type == "string")) and
            ((."format-specific".data."data-file" == null) or
                (."format-specific".data."data-file" | type == "string")))
    ' <<<"$chain_json" >/dev/null 2>&1; then
        echo "[vm-storage] invalid qemu-img backing-chain JSON: $image" >&2
        return 1
    fi

    VM_STORAGE_QCOW2_FORMAT=qcow2
    VM_STORAGE_QCOW2_BACKING=$("$jq_bin" -r \
        '.[0]."backing-filename" // ""' <<<"$chain_json")
    VM_STORAGE_QCOW2_FULL_BACKING=$("$jq_bin" -r \
        '.[0]."full-backing-filename" // ""' <<<"$chain_json")
    VM_STORAGE_QCOW2_DATA_FILE=$("$jq_bin" -r \
        '.[0]."format-specific".data."data-file" // ""' <<<"$chain_json")
    VM_STORAGE_QCOW2_CHAIN_FILES=()
    VM_STORAGE_QCOW2_CHAIN_DATA_FILES=()

    count=$("$jq_bin" -r 'length' <<<"$chain_json")
    for ((idx = 0; idx < count; idx++)); do
        raw_filename=$("$jq_bin" -r ".[${idx}].filename" <<<"$chain_json")
        layer_full=$("$jq_bin" -r \
            ".[${idx}].\"full-backing-filename\" // \"\"" <<<"$chain_json")
        if [[ -n "$layer_full" && "$layer_full" != /* ]]; then
            echo "[vm-storage] unsupported backing reference/protocol: $layer_full" >&2
            return 1
        fi

        if ((idx == 0)); then
            layer_path=$(readlink -m -- "$image")
        elif [[ "$raw_filename" == /* ]]; then
            layer_path=$(readlink -m -- "$raw_filename")
        else
            echo "[vm-storage] unsupported non-filesystem chain layer: $raw_filename" >&2
            return 1
        fi
        VM_STORAGE_QCOW2_CHAIN_FILES+=("$layer_path")

        data_file=$("$jq_bin" -r \
            ".[${idx}].\"format-specific\".data.\"data-file\" // \"\"" \
            <<<"$chain_json")
        [[ -n "$data_file" ]] || continue
        if [[ "$data_file" == /* ]]; then
            data_path=$(readlink -m -- "$data_file")
        elif [[ "$data_file" == *:* ]]; then
            echo "[vm-storage] unsupported external data-file reference: $data_file" >&2
            return 1
        else
            data_path=$(readlink -m -- "$(dirname "$layer_path")/$data_file")
        fi
        VM_STORAGE_QCOW2_CHAIN_DATA_FILES+=("$data_path")
    done

    export VM_STORAGE_QCOW2_FORMAT VM_STORAGE_QCOW2_BACKING
    export VM_STORAGE_QCOW2_FULL_BACKING VM_STORAGE_QCOW2_DATA_FILE
}

vm_storage_resolved_data_file_path() {
    local image=${1:-} data_file=${VM_STORAGE_QCOW2_DATA_FILE:-}

    [[ -n "$image" ]] || return 2
    [[ -n "$data_file" ]] || return 0
    if [[ "$data_file" == /* ]]; then
        readlink -m -- "$data_file"
    elif [[ "$data_file" == *:* ]]; then
        echo "[vm-storage] unsupported external data-file reference: $data_file" >&2
        return 1
    else
        readlink -m -- "$(dirname "$image")/$data_file"
    fi
}

vm_storage_resolved_backing_path() {
    local image=${1:-} backing=${VM_STORAGE_QCOW2_BACKING:-}
    local full=${VM_STORAGE_QCOW2_FULL_BACKING:-}

    [[ -n "$image" ]] || return 2
    if [[ -n "$full" ]]; then
        if [[ "$full" != /* ]]; then
            echo "[vm-storage] unsupported non-filesystem backing reference: $full" >&2
            return 1
        fi
        readlink -m -- "$full"
    elif [[ "$backing" == /* ]]; then
        readlink -m -- "$backing"
    elif [[ -n "$backing" ]]; then
        if [[ "$backing" == *:* ]]; then
            echo "[vm-storage] unsupported backing reference/protocol: $backing" >&2
            return 1
        fi
        readlink -m -- "$(dirname "$image")/$backing"
    fi
}

# Print the minimal set of existing managed directory roots, NUL-delimited.
# Custom VM_DISK_DIR/VM_BASE_DIR values may live outside IMAGE_ROOT, so safety
# scans must not assume /home/ubuntu/images contains every managed qcow2.
vm_storage_qcow2_scan_roots() {
    local candidate canonical parent covered
    local -a selected=() next=()

    for candidate in \
        "$IMAGE_ROOT" "$VM_ROOT" "$VM_INSTANCES_DIR" "${VM_INSTANCE_DIR:-}" \
        "$VM_DISK_DIR" "$VM_BASE_DIR" \
        "$VM_DISK_ARCHIVE_DIR" "$VM_BASE_ARCHIVE_DIR"; do
        [[ -d "$candidate" ]] || continue
        canonical=$(readlink -f -- "$candidate")
        covered=0
        for parent in "${selected[@]}"; do
            if [[ "$canonical" == "$parent" || "$canonical" == "$parent/"* ]]; then
                covered=1
                break
            fi
        done
        ((covered)) && continue

        # If a later candidate is a parent of an earlier one, replace the
        # narrower entry so every file is scanned once.
        next=()
        for parent in "${selected[@]}"; do
            [[ "$parent" == "$canonical/"* ]] || next+=("$parent")
        done
        next+=("$canonical")
        selected=("${next[@]}")
    done

    if ((${#selected[@]})); then
        printf '%s\0' "${selected[@]}"
    fi
}

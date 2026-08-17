#!/usr/bin/env bash
# Move historical G-11 layouts into V-11-style numeric directories below one
# caller-selected VMS root.  Existing numeric destinations are never merged.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"

usage() {
    cat <<'EOF'
usage: ./deploy/scripts/migrate-g11-layout.sh [--check|--apply] [--vms-dir ABS]

  --check  Read-only inventory and safety checks (default).
  --apply  After every G-11 VM is stopped, atomically move either generation:
             IMAGE_ROOT/vms/G-11/vmN -> VMS/N
             IMAGE_ROOT/vms/instances/vmN -> VMS/N
             legacy shared data       -> VMS/shared

VMS defaults to /home/ubuntu/images/vms and may be selected with --vms-dir.
G11_NAMESPACED_ROOT and G11_LEGACY_ROOT override the two source roots.
An existing VMS/N destination blocks migration and is never overwritten.
EOF
}

APPLY=0
MODE_SET=0
VMS_DIR_CLI=""
while (($#)); do
    case "$1" in
        --check|--dry-run)
            (( MODE_SET == 0 )) || { usage >&2; exit 2; }
            MODE_SET=1
            shift
            ;;
        --apply)
            (( MODE_SET == 0 )) || { usage >&2; exit 2; }
            MODE_SET=1
            APPLY=1
            shift
            ;;
        --vms-dir)
            (($# >= 2)) || { usage >&2; exit 2; }
            [[ -z "$VMS_DIR_CLI" ]] || { usage >&2; exit 2; }
            VMS_DIR_CLI=$2
            shift 2
            ;;
        --vms-dir=*)
            [[ -z "$VMS_DIR_CLI" ]] || { usage >&2; exit 2; }
            VMS_DIR_CLI=${1#*=}
            [[ -n "$VMS_DIR_CLI" ]] || { usage >&2; exit 2; }
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
if [[ -n "$VMS_DIR_CLI" ]]; then
    vm_storage_select_root "$VMS_DIR_CLI"
fi

vm_storage_init
OLD_ROOT=${G11_LEGACY_ROOT:-$IMAGE_ROOT/vms}
NAMESPACED_ROOT=${G11_NAMESPACED_ROOT:-$IMAGE_ROOT/vms/G-11}
NEW_ROOT=$VM_ROOT
OLD_INSTANCES=$OLD_ROOT/instances
OLD_CONTROL=$OLD_ROOT/run
NAMESPACED_CONTROL=$NAMESPACED_ROOT/control

[[ "$OLD_ROOT" == /* && "$NEW_ROOT" == /* &&
   "$OLD_ROOT" != / && "$NEW_ROOT" != / &&
   "$NAMESPACED_ROOT" == /* && "$NAMESPACED_ROOT" != / &&
   "$NAMESPACED_ROOT" != "$NEW_ROOT" ]] || {
    echo "[g11-layout] invalid source/target roots" >&2
    exit 2
}

validate_namespace_path() {
    local label=$1 path=$2 probe canonical lexical next

    vm_storage_validate_path_text "$path" "$label" || return
    probe=${path%/}
    while [[ ! -e "$probe" && ! -L "$probe" ]]; do
        next=${probe%/*}
        [[ -n "$next" && "$next" != "$probe" ]] || next=/
        probe=$next
    done
    [[ -d "$probe" && ! -L "$probe" ]] || {
        echo "[g11-layout] $label has an unsafe existing component: $probe" >&2
        return 2
    }
    canonical=$(realpath -e -- "$probe") || return
    lexical=$(realpath -ms -- "$probe") || return
    [[ "$canonical" == "$lexical" ]] || {
        echo "[g11-layout] $label may not traverse a symbolic-link component: $path" >&2
        return 2
    }
}

validate_namespace_path "old G-11 root" "$OLD_ROOT" || exit 2
validate_namespace_path "namespaced G-11 root" "$NAMESPACED_ROOT" || exit 2
validate_namespace_path "new G-11 root" "$NEW_ROOT" || exit 2
validate_namespace_path "old G-11 control path" "$OLD_CONTROL" || exit 2
validate_namespace_path "namespaced G-11 control path" "$NAMESPACED_CONTROL" || exit 2
validate_namespace_path "new G-11 control path" "$VM_RUN_DIR" || exit 2

declare -a SOURCES=() DESTS=()
declare -a EMPTY_SHARED_TREES=()
declare -a MOVED_SOURCES=() MOVED_DESTS=()
declare -a MOVED_HISTORY_SOURCES=() MOVED_HISTORY_DESTS=()
declare -a CREATED_TARGET_CONTAINERS=()
declare -A MOVING_QCOW2_PATHS=() MOVING_QCOW2_TARGETS=()
declare -A PLANNED_DESTINATIONS=()
BLOCKED=0

remember_missing_target_container() {
    local path=$1

    [[ -e "$path" || -L "$path" ]] ||
        CREATED_TARGET_CONTAINERS+=( "$path" )
}

# Lock every existing historical generation plus the numeric target before
# apply-mode inventory.  Check mode stays strictly read-only.
if (( APPLY )); then
    # Root may be required to inspect historical TPM/backups.  Remember only
    # absent target containers before creating anything so sudo cleanup never
    # changes ownership of a pre-existing custom/V-11 namespace.
    for target_container in \
        "$NEW_ROOT" "$VM_SHARED_DIR" "$VM_RUN_DIR" \
        "$VM_RUN_DIR/.storage.lock" "$VM_RUN_DIR/history" \
        "$VM_RUN_DIR/history/pre-g11-layout" \
        "$VM_RUN_DIR/history/g11-namespace" \
        "$VM_RUN_DIR/history/from-g11-namespace"; do
        remember_missing_target_container "$target_container"
    done
    mkdir -p -- "$VM_RUN_DIR"
    if [[ -d "$OLD_CONTROL" && ! -L "$OLD_CONTROL" ]]; then
        exec {OLD_STORAGE_LOCK_FD}>"$OLD_CONTROL/.storage.lock"
        if ! flock -n -x "$OLD_STORAGE_LOCK_FD"; then
            echo "[g11-layout] pre-namespace G-11 storage lock is busy; no VM data moved" >&2
            exit 1
        fi
    fi
    if [[ -d "$NAMESPACED_CONTROL" && ! -L "$NAMESPACED_CONTROL" ]]; then
        exec {NAMESPACED_STORAGE_LOCK_FD}>"$NAMESPACED_CONTROL/.storage.lock"
        if ! flock -n -x "$NAMESPACED_STORAGE_LOCK_FD"; then
            echo "[g11-layout] G-11 namespace storage lock is busy; no VM data moved" >&2
            exit 1
        fi
    fi
    exec {NEW_STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
    if ! flock -n -x "$NEW_STORAGE_LOCK_FD"; then
        echo "[g11-layout] target VMS storage lock is busy; no VM data moved" >&2
        exit 1
    fi
fi

add_directory_move() {
    local source=$1 destination=$2 label=$3 allow_empty_tree=${4:-0}
    local payload_marker

    [[ -e "$source" || -L "$source" ]] || return 0
    if [[ ! -d "$source" || -L "$source" ]]; then
        echo "[g11-layout] BLOCKED: $label source is not a real directory: $source" >&2
        BLOCKED=1
        return 0
    fi
    if (( allow_empty_tree )); then
        if ! payload_marker=$(find -P "$source" -mindepth 1 \
                ! -type d -printf x -quit); then
            echo "[g11-layout] BLOCKED: cannot inspect $label source: $source" >&2
            BLOCKED=1
            return 0
        fi
        if [[ -z "$payload_marker" ]]; then
            # Historical setup versions sometimes created an empty
            # shared/{bases,assets}/archive skeleton before real data was
            # written to the other generation.  It carries no VM payload and
            # must not turn that real source into a false destination clash.
            EMPTY_SHARED_TREES+=( "$source" )
            return 0
        fi
    fi
    if ! validate_namespace_path "$label destination" "$destination"; then
        echo "[g11-layout] BLOCKED: $label destination path is unsafe" >&2
        BLOCKED=1
        return 0
    fi
    if [[ -e "$destination" || -L "$destination" ]]; then
        if [[ -L "$destination" ]]; then
            echo "[g11-layout] BLOCKED: $label destination is a symbolic link" >&2
            echo "  destination: $destination" >&2
            BLOCKED=1
            return 0
        fi
        if [[ "$source" -ef "$destination" ]]; then
            echo "[g11-layout] BLOCKED: $label source/destination alias the same directory" >&2
            echo "  source:      $source" >&2
            echo "  destination: $destination" >&2
            BLOCKED=1
            return 0
        fi
        echo "[g11-layout] BLOCKED: $label destination already exists" >&2
        echo "  source:      $source" >&2
        echo "  destination: $destination" >&2
        BLOCKED=1
        return 0
    fi
    if [[ -n "${PLANNED_DESTINATIONS[$destination]+planned}" ]]; then
        echo "[g11-layout] BLOCKED: two historical sources map to one destination" >&2
        echo "  first:       ${PLANNED_DESTINATIONS[$destination]}" >&2
        echo "  other:       $source" >&2
        echo "  destination: $destination" >&2
        BLOCKED=1
        return 0
    fi
    PLANNED_DESTINATIONS[$destination]=$source
    SOURCES+=( "$source" )
    DESTS+=( "$destination" )
}

if [[ -e "$OLD_INSTANCES" || -L "$OLD_INSTANCES" ]]; then
    if [[ ! -d "$OLD_INSTANCES" || -L "$OLD_INSTANCES" ]]; then
        echo "[g11-layout] BLOCKED: old instances root is unsafe: $OLD_INSTANCES" >&2
        BLOCKED=1
    else
        exec {INSTANCE_FIND_FD}< <(
            find -P "$OLD_INSTANCES" -mindepth 1 -maxdepth 1 -print0
        )
        INSTANCE_FIND_PID=$!
        while IFS= read -r -d '' source <&"$INSTANCE_FIND_FD"; do
            name=${source##*/}
            if [[ ! "$name" =~ ^vm([1-9][0-9]*)$ ]]; then
                echo "[g11-layout] BLOCKED: unexpected entry in old instances root: $source" >&2
                BLOCKED=1
                continue
            fi
            id=${BASH_REMATCH[1]}
            if ! vm_storage_id_is_supported "$id"; then
                echo "[g11-layout] BLOCKED: unsupported VM id in: $source" >&2
                BLOCKED=1
                continue
            fi
            add_directory_move "$source" "$NEW_ROOT/$id" "pre-namespace vm bundle"
        done
        exec {INSTANCE_FIND_FD}<&-
        if ! wait "$INSTANCE_FIND_PID"; then
            echo "[g11-layout] BLOCKED: cannot enumerate old instances root: $OLD_INSTANCES" >&2
            BLOCKED=1
        fi
    fi
fi

if [[ -e "$NAMESPACED_ROOT" || -L "$NAMESPACED_ROOT" ]]; then
    if [[ ! -d "$NAMESPACED_ROOT" || -L "$NAMESPACED_ROOT" ]]; then
        echo "[g11-layout] BLOCKED: namespaced G-11 root is unsafe: $NAMESPACED_ROOT" >&2
        BLOCKED=1
    else
        exec {NAMESPACE_FIND_FD}< <(
            find -P "$NAMESPACED_ROOT" -mindepth 1 -maxdepth 1 -print0
        )
        NAMESPACE_FIND_PID=$!
        while IFS= read -r -d '' source <&"$NAMESPACE_FIND_FD"; do
            name=${source##*/}
            case "$name" in
                vm[1-9]*)
                    if [[ "$name" =~ ^vm([1-9][0-9]*)$ ]]; then
                        id=${BASH_REMATCH[1]}
                        if vm_storage_id_is_supported "$id"; then
                            add_directory_move "$source" "$NEW_ROOT/$id" \
                                "G-11 namespace vm bundle"
                        else
                            echo "[g11-layout] BLOCKED: unsupported VM id in: $source" >&2
                            BLOCKED=1
                        fi
                    else
                        echo "[g11-layout] BLOCKED: invalid VM entry: $source" >&2
                        BLOCKED=1
                    fi
                    ;;
                shared|control|legacy) ;;
                *)
                    echo "[g11-layout] BLOCKED: unexpected G-11 namespace entry: $source" >&2
                    BLOCKED=1
                    ;;
            esac
        done
        exec {NAMESPACE_FIND_FD}<&-
        if ! wait "$NAMESPACE_FIND_PID"; then
            echo "[g11-layout] BLOCKED: cannot enumerate $NAMESPACED_ROOT" >&2
            BLOCKED=1
        fi
    fi
fi

add_directory_move "$NAMESPACED_ROOT/shared/bases" "$VM_BASE_DIR" \
    "G-11 namespace shared bases" 1
add_directory_move "$NAMESPACED_ROOT/shared/assets" "$VM_ASSET_DIR" \
    "G-11 namespace shared assets" 1
add_directory_move "$NAMESPACED_ROOT/legacy" "$NEW_ROOT/legacy" \
    "G-11 namespace legacy compatibility data"
add_directory_move "$NAMESPACED_CONTROL/history" \
    "$VM_RUN_DIR/history/from-g11-namespace" \
    "G-11 namespace migration history"
add_directory_move "$OLD_ROOT/bases" "$VM_BASE_DIR" \
    "pre-namespace shared bases" 1
add_directory_move "$OLD_ROOT/assets" "$VM_ASSET_DIR" \
    "pre-namespace shared assets" 1

echo "[g11-layout] numeric target directories (never overwritten or merged):"
find "$NEW_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended -regex '.*/[1-9][0-9]*' \
    -printf '  %p\n' 2>/dev/null | sort || true
echo "[g11-layout] unified VMS target: $NEW_ROOT"
if ((${#SOURCES[@]})); then
    echo "[g11-layout] planned atomic directory moves:"
    for index in "${!SOURCES[@]}"; do
        printf '  %s\n    -> %s\n' "${SOURCES[$index]}" "${DESTS[$index]}"
    done
else
    echo "[g11-layout] no old G-11 bundle/shared directories need moving"
fi
if ((${#EMPTY_SHARED_TREES[@]})); then
    echo "[g11-layout] verified empty shared skeletons (removed only on --apply):"
    printf '  %s\n' "${EMPTY_SHARED_TREES[@]}"
fi

# Historical control directories contain global coordination only.  Per-VM
# runtime files already live in the bundle; flat zero-byte locks are discarded
# after the bundle moves because current locks live in N/run.
declare -a CONTROL_HISTORY=() CONTROL_HISTORY_DESTS=() CONTROL_LOCKS=()
inventory_control() {
    local control=$1 label=$2 history_bucket=$3
    local entry name

    [[ -e "$control" || -L "$control" ]] || return 0
    if [[ ! -d "$control" || -L "$control" ]]; then
        echo "[g11-layout] BLOCKED: $label is unsafe: $control" >&2
        BLOCKED=1
        return 0
    fi
    exec {CONTROL_FIND_FD}< <(
        find -P "$control" -mindepth 1 -maxdepth 1 -print0
    )
    CONTROL_FIND_PID=$!
    while IFS= read -r -d '' entry <&"$CONTROL_FIND_FD"; do
        name=${entry##*/}
        case "$name" in
            .storage.lock)
                if [[ ! -f "$entry" || -L "$entry" ||
                      "$(stat -c %s -- "$entry")" != 0 ]]; then
                    echo "[g11-layout] BLOCKED: unsafe/non-empty old lock: $entry" >&2
                    BLOCKED=1
                else
                    CONTROL_LOCKS+=( "$entry" )
                fi
                ;;
            vm*.start.lock|vm*.disk.lock|vm*.tpm.lock)
                if [[ ! "$name" =~ ^vm([1-9][0-9]*)\.(start|disk|tpm)\.lock$ ]] ||
                        ! vm_storage_id_is_supported "${BASH_REMATCH[1]:-}"; then
                    echo "[g11-layout] BLOCKED: invalid old lock name: $entry" >&2
                    BLOCKED=1
                elif [[ ! -f "$entry" || -L "$entry" ||
                        "$(stat -c %s -- "$entry")" != 0 ]]; then
                    echo "[g11-layout] BLOCKED: unsafe/non-empty old lock: $entry" >&2
                    BLOCKED=1
                else
                    CONTROL_LOCKS+=( "$entry" )
                fi
                ;;
            storage-migration-*.tsv)
                if [[ ! -f "$entry" || -L "$entry" ]]; then
                    echo "[g11-layout] BLOCKED: unsafe migration history: $entry" >&2
                    BLOCKED=1
                else
                    CONTROL_HISTORY+=( "$entry" )
                    CONTROL_HISTORY_DESTS+=(
                        "$VM_RUN_DIR/history/$history_bucket/$name"
                    )
                fi
                ;;
            history)
                if [[ "$control" != "$NAMESPACED_CONTROL" ]]; then
                    echo "[g11-layout] BLOCKED: unexpected history directory: $entry" >&2
                    BLOCKED=1
                fi
                # Namespaced history is already in the atomic move plan.
                ;;
            *)
                echo "[g11-layout] BLOCKED: unexpected $label entry: $entry" >&2
                BLOCKED=1
                ;;
        esac
    done
    exec {CONTROL_FIND_FD}<&-
    if ! wait "$CONTROL_FIND_PID"; then
        echo "[g11-layout] BLOCKED: cannot enumerate $control" >&2
        BLOCKED=1
    fi
}

inventory_control "$OLD_CONTROL" "pre-namespace control directory" \
    pre-g11-layout
inventory_control "$NAMESPACED_CONTROL" "G-11 namespace control directory" \
    g11-namespace

# A relative symlink changes meaning when its containing directory moves; an
# absolute symlink would also violate the one-VM/one-bundle boundary.  Reject
# every symlink in a planned tree rather than guessing which ones are benign.
for source in "${SOURCES[@]}"; do
    exec {LINK_FIND_FD}< <(find -P "$source" -type l -print0)
    LINK_FIND_PID=$!
    while IFS= read -r -d '' link <&"$LINK_FIND_FD"; do
        echo "[g11-layout] BLOCKED: planned directory contains a symbolic link: $link" >&2
        BLOCKED=1
    done
    exec {LINK_FIND_FD}<&-
    if ! wait "$LINK_FIND_PID"; then
        echo "[g11-layout] BLOCKED: cannot verify symlinks below $source" >&2
        BLOCKED=1
    fi
done

# A directory rename changes every absolute layer path.  Managed G-11 disks
# and bases must therefore be standalone qcow2 images before publication.
if ((${#SOURCES[@]})); then
    : "${QEMU_IMG:=$here/../build/qemu-img}"
    [[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img || true)
    if [[ -z "$QEMU_IMG" || ! -x "$QEMU_IMG" ]]; then
        echo "[g11-layout] BLOCKED: qemu-img is required for qcow2 checks" >&2
        BLOCKED=1
    else
        for source in "${SOURCES[@]}"; do
            exec {QCOW_FIND_FD}< <(
                find -P "$source" \( -type f -o -type l \) \
                    \( -name '*.qcow2' -o -name '*.qcow2.*' \) -print0
            )
            QCOW_FIND_PID=$!
            while IFS= read -r -d '' image <&"$QCOW_FIND_FD"; do
                if ! image_key=$(realpath -ms -- "$image"); then
                    echo "[g11-layout] BLOCKED: cannot normalize planned qcow2 path: $image" >&2
                    BLOCKED=1
                    continue
                fi
                MOVING_QCOW2_PATHS["$image_key"]=1
                MOVING_QCOW2_TARGETS["$image_key"]=1
                if ! image_real=$(readlink -f -- "$image" 2>/dev/null); then
                    echo "[g11-layout] BLOCKED: cannot resolve planned qcow2 path: $image" >&2
                    BLOCKED=1
                    continue
                fi
                MOVING_QCOW2_TARGETS["$image_real"]=1

                if [[ ! -f "$image" || -L "$image" ]] ||
                        ! vm_storage_read_qcow2_metadata "$QEMU_IMG" "$image" ||
                        [[ -n "$VM_STORAGE_QCOW2_BACKING" ||
                           -n "$VM_STORAGE_QCOW2_DATA_FILE" ]]; then
                    echo "[g11-layout] BLOCKED: image is not a safe standalone qcow2: $image" >&2
                    BLOCKED=1
                fi
            done
            exec {QCOW_FIND_FD}<&-
            if ! wait "$QCOW_FIND_PID"; then
                echo "[g11-layout] BLOCKED: cannot enumerate qcow2 files below $source" >&2
                BLOCKED=1
            fi
        done
    fi
fi

# An image outside the move set may still name one of the old absolute paths
# as a backing layer or external data-file.  Renaming that target would break
# the outside image, including an image kept in a V-11 numeric directory.
# Inspect every qcow2-like path below IMAGE_ROOT and every explicitly managed
# disk/base root.  Fail closed on find, permission, path-resolution, or
# complete-chain metadata errors.
qcow2_path_matches_moving_target() {
    local candidate=${1:-} key real

    if ! key=$(realpath -ms -- "$candidate"); then
        return 2
    fi
    [[ -z "${MOVING_QCOW2_TARGETS[$key]+moving}" ]] || return 0

    if [[ -e "$candidate" || -L "$candidate" ]]; then
        if ! real=$(readlink -f -- "$candidate" 2>/dev/null); then
            return 2
        fi
        [[ -z "${MOVING_QCOW2_TARGETS[$real]+moving}" ]] || return 0
    fi
    return 1
}

declare -a QCOW_SCAN_ROOTS=()
add_qcow_scan_root() {
    local candidate=${1:-} canonical parent covered=0
    local -a next=()

    [[ -n "$candidate" ]] || return 0
    [[ -e "$candidate" || -L "$candidate" ]] || return 0
    if [[ ! -d "$candidate" ]]; then
        echo "[g11-layout] BLOCKED: qcow2 scan root is not a directory: $candidate" >&2
        BLOCKED=1
        return 0
    fi
    if ! canonical=$(readlink -f -- "$candidate" 2>/dev/null); then
        echo "[g11-layout] BLOCKED: cannot resolve qcow2 scan root: $candidate" >&2
        BLOCKED=1
        return 0
    fi
    for parent in "${QCOW_SCAN_ROOTS[@]}"; do
        if [[ "$canonical" == "$parent" || "$canonical" == "$parent/"* ]]; then
            covered=1
            break
        fi
    done
    ((covered)) && return 0
    for parent in "${QCOW_SCAN_ROOTS[@]}"; do
        [[ "$parent" == "$canonical/"* ]] || next+=( "$parent" )
    done
    next+=( "$canonical" )
    QCOW_SCAN_ROOTS=( "${next[@]}" )
}

if ((${#MOVING_QCOW2_PATHS[@]})); then
    for scan_candidate in \
        "$IMAGE_ROOT" "$OLD_ROOT" "$NAMESPACED_ROOT" \
        "$VM_ROOT" "$VM_INSTANCES_DIR" \
        "${VM_INSTANCE_DIR:-}" "$VM_DISK_DIR" "$VM_BASE_DIR" \
        "$VM_DISK_ARCHIVE_DIR" "$VM_BASE_ARCHIVE_DIR"; do
        add_qcow_scan_root "$scan_candidate"
    done
    if ((${#QCOW_SCAN_ROOTS[@]} == 0)); then
        echo "[g11-layout] BLOCKED: no accessible qcow2 scan root" >&2
        BLOCKED=1
    else
        for scan_root in "${QCOW_SCAN_ROOTS[@]}"; do
        exec {QCOW_SCAN_FD}< <(
            find -L "$scan_root" \( -type f -o -type l \) \
                \( -name '*.qcow2' -o -name '*.qcow2.*' \) -print0
        )
        QCOW_SCAN_PID=$!
        while IFS= read -r -d '' image <&"$QCOW_SCAN_FD"; do
            if ! image_key=$(realpath -ms -- "$image"); then
                echo "[g11-layout] BLOCKED: cannot normalize scanned qcow2 path: $image" >&2
                BLOCKED=1
                continue
            fi
            [[ -z "${MOVING_QCOW2_PATHS[$image_key]+moving}" ]] || continue

            # This also catches a pathname reached through an outside symlink
            # directory: its lexical name is outside the move set, but its
            # resolved target would disappear from the old location.
            if ! image_real=$(readlink -f -- "$image" 2>/dev/null); then
                echo "[g11-layout] BLOCKED: cannot resolve scanned qcow2 path: $image" >&2
                BLOCKED=1
                continue
            fi
            if [[ -n "${MOVING_QCOW2_TARGETS[$image_real]+moving}" ]]; then
                echo "[g11-layout] BLOCKED: outside qcow2 path resolves to a planned file" >&2
                echo "  path:   $image" >&2
                echo "  target: $image_real" >&2
                BLOCKED=1
                continue
            fi

            if ! vm_storage_read_qcow2_chain_metadata "$QEMU_IMG" "$image"; then
                echo "[g11-layout] BLOCKED: cannot prove outside qcow2 chain safety" >&2
                echo "  image: $image" >&2
                BLOCKED=1
                continue
            fi
            for dependency in "${VM_STORAGE_QCOW2_CHAIN_FILES[@]:1}"; do
                if qcow2_path_matches_moving_target "$dependency"; then
                    echo "[g11-layout] BLOCKED: outside qcow2 chain depends on a planned file" >&2
                    echo "  image:      $image" >&2
                    echo "  dependency: $dependency" >&2
                    BLOCKED=1
                    break
                else
                    match_status=$?
                    if ((match_status == 2)); then
                        echo "[g11-layout] BLOCKED: cannot resolve outside qcow2 dependency" >&2
                        echo "  image:      $image" >&2
                        echo "  dependency: $dependency" >&2
                        BLOCKED=1
                        break
                    fi
                fi
            done
            for data_file in "${VM_STORAGE_QCOW2_CHAIN_DATA_FILES[@]}"; do
                if qcow2_path_matches_moving_target "$data_file"; then
                    echo "[g11-layout] BLOCKED: outside qcow2 chain uses a data-file that would move" >&2
                    echo "  image:     $image" >&2
                    echo "  data-file: $data_file" >&2
                    BLOCKED=1
                    break
                else
                    match_status=$?
                    if ((match_status == 2)); then
                        echo "[g11-layout] BLOCKED: cannot resolve outside qcow2 data-file" >&2
                        echo "  image:     $image" >&2
                        echo "  data-file: $data_file" >&2
                        BLOCKED=1
                        break
                    fi
                fi
            done
        done
        exec {QCOW_SCAN_FD}<&-
        if ! wait "$QCOW_SCAN_PID"; then
            echo "[g11-layout] BLOCKED: cannot enumerate every qcow2 below $scan_root" >&2
            BLOCKED=1
        fi
        done
    fi
fi

# Every source must be closed and on the same filesystem as its destination.
if ((${#SOURCES[@]})); then
    if ! command -v lsof >/dev/null 2>&1; then
        echo "[g11-layout] BLOCKED: lsof is required for open-file checks" >&2
        BLOCKED=1
    fi
    for index in "${!SOURCES[@]}"; do
        source=${SOURCES[$index]}
        destination=${DESTS[$index]}
        if command -v lsof >/dev/null 2>&1; then
            lsof_output=""
            if lsof_output=$(lsof -t +D "$source" 2>&1); then
                if [[ -n "$lsof_output" ]]; then
                    echo "[g11-layout] BLOCKED: a process has files open below $source" >&2
                    echo "  holders: $lsof_output" >&2
                    BLOCKED=1
                fi
            else
                lsof_status=$?
                # lsof returns 1 with empty output when there are no matches.
                # Any diagnostic or different status means the proof failed.
                if [[ -n "$lsof_output" || "$lsof_status" != 1 ]]; then
                    echo "[g11-layout] BLOCKED: cannot prove no files are open below $source" >&2
                    [[ -z "$lsof_output" ]] ||
                        echo "  lsof: $lsof_output" >&2
                    BLOCKED=1
                fi
            fi
        fi
        destination_parent=${destination%/*}
        while [[ ! -e "$destination_parent" ]]; do
            next_parent=${destination_parent%/*}
            [[ -n "$next_parent" && "$next_parent" != "$destination_parent" ]] ||
                next_parent=/
            destination_parent=$next_parent
        done
        source_device=$(stat -c %d -- "$source")
        destination_device=$(stat -c %d -- "$destination_parent")
        if [[ "$source_device" != "$destination_device" ]]; then
            echo "[g11-layout] BLOCKED: cross-filesystem move is not atomic" >&2
            echo "  source:      $source" >&2
            echo "  destination: $destination" >&2
            BLOCKED=1
        fi
    done
fi

# Independent process inspection catches QEMU/swtpm/NBD users even if lsof is
# missing metadata or a process opened then unlinked a path.
for proc in /proc/[0-9]*; do
    [[ -r "$proc/cmdline" ]] || continue
    exe=$(readlink -f -- "$proc/exe" 2>/dev/null || true)
    case "${exe##*/}" in
        qemu-system-*|swtpm|qemu-nbd) ;;
        *) continue ;;
    esac
    mapfile -d '' -t argv <"$proc/cmdline" 2>/dev/null || continue
    for argument in "${argv[@]}"; do
        if [[ "$argument" == *"$OLD_INSTANCES/"* ||
              "$argument" == *"$NAMESPACED_ROOT/"* ||
              "$argument" == *"$NEW_ROOT/"* ]]; then
            echo "[g11-layout] BLOCKED: ${exe##*/} pid=${proc##*/} uses G-11 storage" >&2
            BLOCKED=1
            break
        fi
    done
done

# Refuse a late history collision before any bundle directory is renamed.
if ((${#CONTROL_HISTORY[@]})); then
    for index in "${!CONTROL_HISTORY[@]}"; do
        source=${CONTROL_HISTORY[$index]}
        destination=${CONTROL_HISTORY_DESTS[$index]}
        if ! validate_namespace_path "migration history destination" "$destination"; then
            echo "[g11-layout] BLOCKED: migration history path is unsafe" >&2
            BLOCKED=1
            continue
        fi
        if [[ -e "$destination" || -L "$destination" ]]; then
            echo "[g11-layout] BLOCKED: migration history destination exists: $destination" >&2
            BLOCKED=1
        fi
    done
fi

if (( BLOCKED )); then
    if (( APPLY )); then
        echo "[g11-layout] no VM data moved; empty coordination paths/lock files may have been created" >&2
    else
        echo "[g11-layout] no files changed; stop/fix every blocker and run --check again" >&2
    fi
    if (( EUID != 0 )); then
        echo "[g11-layout] hint: root-owned TPM/backup data must be checked through runtime sudo" >&2
        echo "  sudo -v" >&2
        if [[ -n "$VMS_DIR_CLI" ]]; then
            printf '  sudo %q --check --vms-dir %q\n' \
                "$0" "$VMS_DIR_CLI" >&2
        else
            printf '  sudo %q --check\n' "$0" >&2
        fi
        echo "  never store the sudo password in this repository" >&2
    fi
    exit 1
fi
if (( ! APPLY )); then
    echo "[g11-layout] CHECK OK: no files changed"
    echo "[g11-layout] after stopping every G-11 VM, run: $0 --apply"
    exit 0
fi

rollback_moves() {
    local index
    trap - ERR INT TERM
    echo "[g11-layout] move failed; rolling back completed directory renames" >&2
    for ((index = ${#MOVED_HISTORY_SOURCES[@]} - 1; index >= 0; index--)); do
        if [[ -e "${MOVED_HISTORY_DESTS[$index]}" &&
              ! -e "${MOVED_HISTORY_SOURCES[$index]}" ]]; then
            mkdir -p -- "${MOVED_HISTORY_SOURCES[$index]%/*}"
            mv -T -- "${MOVED_HISTORY_DESTS[$index]}" \
                "${MOVED_HISTORY_SOURCES[$index]}" || true
        fi
    done
    for ((index = ${#MOVED_SOURCES[@]} - 1; index >= 0; index--)); do
        if [[ -e "${MOVED_DESTS[$index]}" &&
              ! -e "${MOVED_SOURCES[$index]}" ]]; then
            mkdir -p -- "${MOVED_SOURCES[$index]%/*}"
            mv -T -- "${MOVED_DESTS[$index]}" "${MOVED_SOURCES[$index]}" || true
        fi
    done
    exit 1
}
trap rollback_moves ERR INT TERM

for index in "${!SOURCES[@]}"; do
    source=${SOURCES[$index]}
    destination=${DESTS[$index]}
    mkdir -p -- "${destination%/*}"
    mv -T -- "$source" "$destination"
    MOVED_SOURCES+=( "$source" )
    MOVED_DESTS+=( "$destination" )
    echo "[g11-layout] moved: $source -> $destination"
done

# Recheck under the apply locks immediately before removing directory-only
# skeletons.  A late file/symlink causes rollback instead of data loss.
for source in "${EMPTY_SHARED_TREES[@]}"; do
    if ! payload_marker=$(find -P "$source" -mindepth 1 \
            ! -type d -printf x -quit); then
        echo "[g11-layout] empty shared skeleton became unreadable: $source" >&2
        false
    fi
    if [[ -n "$payload_marker" ]]; then
        echo "[g11-layout] empty shared skeleton gained payload; refusing removal: $source" >&2
        false
    fi
    find -P "$source" -depth -type d -exec rmdir -- {} +
    echo "[g11-layout] removed empty shared skeleton: $source"
done

# Preserve useful old migration manifests; empty lock files are disposable.
if ((${#CONTROL_HISTORY[@]})); then
    for index in "${!CONTROL_HISTORY[@]}"; do
        source=${CONTROL_HISTORY[$index]}
        destination=${CONTROL_HISTORY_DESTS[$index]}
        mkdir -p -- "${destination%/*}"
        mv -T -- "$source" "$destination"
        MOVED_HISTORY_SOURCES+=( "$source" )
        MOVED_HISTORY_DESTS+=( "$destination" )
    done
fi
for source in "${CONTROL_LOCKS[@]}"; do
    [[ "$source" == "$OLD_CONTROL/.storage.lock" ||
       "$source" == "$NAMESPACED_CONTROL/.storage.lock" ]] || rm -f -- "$source"
done
rm -f -- "$OLD_CONTROL/.storage.lock" "$NAMESPACED_CONTROL/.storage.lock"
rmdir -- "$OLD_CONTROL" "$NAMESPACED_CONTROL" 2>/dev/null || true
rmdir -- "$OLD_INSTANCES" 2>/dev/null || true
rmdir -- "$NAMESPACED_ROOT/shared" 2>/dev/null || true
rmdir -- "$NAMESPACED_ROOT" 2>/dev/null || true

# Root privileges may be necessary to inspect root-owned TPM/backup content.
# When invoked through sudo, keep only the newly created namespace/control
# containers usable by the original operator; moved VM payload keeps its
# existing ownership and modes.
if (( EUID == 0 )) &&
        [[ "${SUDO_UID:-}" =~ ^[1-9][0-9]*$ &&
           "${SUDO_GID:-}" =~ ^[0-9]+$ ]]; then
    for created_path in "${CREATED_TARGET_CONTAINERS[@]}"; do
        [[ -e "$created_path" || -L "$created_path" ]] || continue
        chown --no-dereference "$SUDO_UID:$SUDO_GID" "$created_path"
    done
    echo "[g11-layout] new namespace/control ownership restored to uid=$SUDO_UID gid=$SUDO_GID"
fi
trap - ERR INT TERM

echo "[g11-layout] APPLY OK: G-11 data now uses $NEW_ROOT"
echo "[g11-layout] verify each VM with: ./deploy/scripts/start-vm.sh ID --print-paths"

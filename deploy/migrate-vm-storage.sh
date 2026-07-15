#!/usr/bin/env bash
# Bundle vGPU data per VM without touching unrelated numeric-instance dirs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
vm_storage_init

APPLY=0
case "${1:---check}" in
    --check|--dry-run) ;;
    --apply) APPLY=1 ;;
    -h|--help)
        cat <<'EOF'
usage: migrate-vm-storage.sh [--check|--apply]

Default --check only prints the complete move plan and safety blockers.
--apply requires every production vGPU VM to be stopped, verifies that no
source file is open and then uses same-filesystem atomic renames.
EOF
        exit 0
        ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "too many arguments" >&2; exit 2; }

declare -a SOURCES=() DESTS=()
declare -A DEST_SEEN=() SOURCE_DEST=() VM_IDS=()
BLOCKED=0

# In apply mode, take the cooperative global lock before inventory so no
# current launcher/create/delete/promote operation can change the plan between
# validation and publication.  Check mode remains completely non-mutating.
if ((APPLY)); then
    mkdir -p "$VM_RUN_DIR"
    exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
    if ! flock -n -x "$STORAGE_LOCK_FD"; then
        echo "[storage-migrate] another VM/storage operation holds $VM_RUN_DIR/.storage.lock" >&2
        exit 1
    fi
fi

add_move() {
    local src=$1 dst=$2 source_key
    [[ -e "$src" || -L "$src" ]] || return 0
    source_key=$(readlink -m -- "$src")
    if [[ -n "${SOURCE_DEST[$source_key]+planned}" ]]; then
        if [[ "${SOURCE_DEST[$source_key]}" == "$dst" ]]; then
            return 0
        fi
        echo "[storage-migrate] BLOCKED: one source maps to multiple destinations: $src" >&2
        BLOCKED=1
        return 0
    fi
    if [[ -e "$dst" || -L "$dst" ]]; then
        if [[ "$src" -ef "$dst" ]]; then
            return 0
        fi
        echo "[storage-migrate] BLOCKED: destination already exists" >&2
        echo "  source:      $src" >&2
        echo "  destination: $dst" >&2
        BLOCKED=1
        return 0
    fi
    if [[ -n "${DEST_SEEN[$dst]+present}" ]]; then
        echo "[storage-migrate] BLOCKED: duplicate destination in plan: $dst" >&2
        BLOCKED=1
        return 0
    fi
    SOURCE_DEST[$source_key]=$dst
    DEST_SEEN[$dst]=1
    SOURCES+=("$src")
    DESTS+=("$dst")
}

plan_config() {
    local src=$1 name=${1##*/} id
    [[ "$name" =~ ^vm([1-9][0-9]*)\.conf$ ]] || return 0
    id=${BASH_REMATCH[1]}
    VM_IDS[$id]=1
    add_move "$src" "$(vm_storage_config_preferred_path "$id")"
}

plan_disk() {
    local src=$1 name=${1##*/} id
    [[ "$name" =~ ^win10-vm([1-9][0-9]*)\.qcow2$ ]] || return 0
    id=${BASH_REMATCH[1]}
    VM_IDS[$id]=1
    add_move "$src" "$(vm_storage_disk_preferred_path "$id")"
}

plan_disk_backup() {
    local src=$1 name=${1##*/} id
    [[ "$name" =~ ^win10-vm([1-9][0-9]*)\.qcow2\..+$ ]] || return 0
    id=${BASH_REMATCH[1]}
    VM_IDS[$id]=1
    add_move "$src" "$(vm_storage_instance_disk_backup_dir "$id")/$name"
}

plan_nvram() {
    local src=$1 name=${1##*/} id
    [[ "$name" =~ ^vm([1-9][0-9]*)_VARS\.fd$ ]] || return 0
    id=${BASH_REMATCH[1]}
    VM_IDS[$id]=1
    add_move "$src" "$(vm_storage_nvram_preferred_path "$id")"
}

plan_nvram_backup() {
    local src=$1 name=${1##*/} id
    [[ "$name" =~ ^vm([1-9][0-9]*)_VARS\.fd\..+$ ]] || return 0
    id=${BASH_REMATCH[1]}
    VM_IDS[$id]=1
    add_move "$src" "$(vm_storage_instance_nvram_backup_dir "$id")/$name"
}

plan_log() {
    local src=$1 name=${1##*/} id
    [[ "$name" =~ ^vm([1-9][0-9]*)\.log$ ]] || return 0
    id=${BASH_REMATCH[1]}
    VM_IDS[$id]=1
    add_move "$src" "$(vm_storage_log_preferred_path "$id")"
}

shopt -s nullglob
for src in "$VM_CONFIG_DIR"/vm*.conf; do plan_config "$src"; done
for src in \
    "$VM_ROOT"/win10-vm*.qcow2 \
    "$VM_DISK_DIR"/win10-vm*.qcow2; do
    plan_disk "$src"
done
for src in \
    "$VM_ROOT"/win10-vm*.qcow2.* \
    "$VM_DISK_ARCHIVE_DIR"/win10-vm*.qcow2.*; do
    plan_disk_backup "$src"
done
if [[ -e "$VM_ROOT/win10-base.qcow2" ]]; then
    add_move "$VM_ROOT/win10-base.qcow2" \
        "$VM_BASE_DIR/win10-base.qcow2"
fi
for src in "$VM_ROOT"/win10-base.qcow2.*; do
    add_move "$src" "$VM_BASE_ARCHIVE_DIR/${src##*/}"
done
for src in \
    "$VM_ROOT"/vm*_VARS.fd \
    "$VM_NVRAM_DIR"/vm*_VARS.fd; do
    plan_nvram "$src"
done
for src in \
    "$VM_ROOT"/vm*_VARS.fd.* \
    "$VM_NVRAM_DIR"/vm*_VARS.fd.* \
    "$VM_NVRAM_BACKUP_DIR"/vm*_VARS.fd.*; do
    plan_nvram_backup "$src"
done
for src in "$VM_LOG_DIR"/vm*.log; do plan_log "$src"; done
for src in "$IMAGE_ROOT"/*.iso; do
    add_move "$src" "$ISO_DIR/${src##*/}"
done

# A base-only or ISO-only migration must still lock every known production VM
# against older launchers that use only vmN.start.lock.
for path in \
    "$VM_CONFIG_DIR"/vm*.conf \
    "$VM_DISK_DIR"/win10-vm*.qcow2 \
    "$VM_NVRAM_DIR"/vm*_VARS.fd \
    "$VM_RUN_DIR"/vm*.start.lock \
    "$VM_RUN_DIR"/vm*.disk.lock \
    "$VM_INSTANCES_DIR"/vm*; do
    name=${path##*/}
    if [[ "$name" =~ ^vm([1-9][0-9]*)\.(conf|start\.lock)$ ||
          "$name" =~ ^vm([1-9][0-9]*)\.disk\.lock$ ||
          "$name" =~ ^vm([1-9][0-9]*)_VARS\.fd$ ||
          "$name" =~ ^win10-vm([1-9][0-9]*)\.qcow2$ ||
          "$name" =~ ^vm([1-9][0-9]*)$ ]]; then
        VM_IDS[${BASH_REMATCH[1]}]=1
    fi
done
shopt -u nullglob

echo "[storage-migrate] target layout"
printf '  ISO       %s\n' "$ISO_DIR"
printf '  instances %s/vmN\n' "$VM_INSTANCES_DIR"
printf '  bases     %s\n' "$VM_BASE_DIR"
printf '  control   %s\n' "$VM_RUN_DIR"
printf '  assets    %s\n' "$VM_ASSET_DIR"

if ((${#SOURCES[@]} == 0)); then
    if ((BLOCKED)); then
        echo "[storage-migrate] no moves planned because path conflicts must be resolved" >&2
    else
        echo "[storage-migrate] no legacy/categorized VM files found; instance layout is current"
    fi
    exit "$BLOCKED"
fi

echo "[storage-migrate] planned atomic moves (${#SOURCES[@]})"
for i in "${!SOURCES[@]}"; do
    printf '  %s\n    -> %s\n' "${SOURCES[$i]}" "${DESTS[$i]}"
done

# Any root vGPU QEMU using this VM_ROOT blocks migration. Match the executable,
# structured -name argument and a path argument independently; a test tree or
# another VM_ROOT must not be blocked by an unrelated QEMU.
for proc in /proc/[0-9]*; do
    [[ -r "$proc/cmdline" ]] || continue
    exe=$(readlink -f "$proc/exe" 2>/dev/null || true)
    [[ "${exe##*/}" == qemu-system-x86_64 ]] || continue
    mapfile -d '' -t argv <"$proc/cmdline" || true
    is_vgpu=0
    uses_root=0
    for ((j = 0; j < ${#argv[@]}; j++)); do
        arg=${argv[$j]}
        if [[ "$arg" == -name && $((j + 1)) -lt ${#argv[@]} &&
              "${argv[$((j + 1))]}" =~ ^vm[1-9][0-9]*([,].*)?$ ]]; then
            is_vgpu=1
        elif [[ "$arg" =~ ^-name=vm[1-9][0-9]*([,].*)?$ ]]; then
            is_vgpu=1
        fi
        [[ "$arg" == *"$VM_ROOT/"* ]] && uses_root=1
    done
    if ((is_vgpu && uses_root)); then
        echo "[storage-migrate] BLOCKED: production vGPU QEMU pid=${proc##*/} uses $VM_ROOT" >&2
        BLOCKED=1
    fi
done

# Open qcow2/NVRAM/ISO descriptors are an independent safety signal, including
# a QEMU started by an older launcher that does not hold the new storage lock.
if command -v lsof >/dev/null 2>&1; then
    for src in "${SOURCES[@]}"; do
        holders=$(lsof -t -- "$src" 2>/dev/null | paste -sd, - || true)
        if [[ -n "$holders" ]]; then
            echo "[storage-migrate] BLOCKED: open file (pids=$holders): $src" >&2
            BLOCKED=1
        fi
    done
else
    echo "[storage-migrate] BLOCKED: lsof is required for holder checks" >&2
    BLOCKED=1
fi

if [[ -L "$VM_INSTANCES_DIR" ||
      ( -e "$VM_INSTANCES_DIR" && ! -d "$VM_INSTANCES_DIR" ) ]]; then
    echo "[storage-migrate] BLOCKED: instances root must be a real directory: $VM_INSTANCES_DIR" >&2
    BLOCKED=1
fi

for id in "${!VM_IDS[@]}"; do
    instance=$(vm_storage_instance_dir "$id")
    if [[ -L "$instance" || ( -e "$instance" && ! -d "$instance" ) ]]; then
        echo "[storage-migrate] BLOCKED: instance path must be a real directory: $instance" >&2
        BLOCKED=1
    fi
    for child in \
        "$instance/log" "$instance/run" "$instance/backups" \
        "$instance/backups/disks" "$instance/backups/nvram"; do
        if [[ -L "$child" || ( -e "$child" && ! -d "$child" ) ]]; then
            echo "[storage-migrate] BLOCKED: instance subdirectory is unsafe: $child" >&2
            BLOCKED=1
        fi
    done

    # Runtime state is never renamed.  A stopped/clean VM has none of these;
    # stale state must be cleared with stop-vm.sh before storage paths move.
    for kind in pid qmp mon mdev; do
        for runtime_path in \
            "$(vm_storage_run_preferred_path "$id" "$kind")" \
            "$(vm_storage_run_legacy_path "$id" "$kind")"; do
            if [[ -e "$runtime_path" || -L "$runtime_path" ]]; then
                echo "[storage-migrate] BLOCKED: VM runtime state must be cleaned first: $runtime_path" >&2
                BLOCKED=1
            fi
        done
    done
done

# Moving a qcow2 changes the base directory used to resolve a relative backing
# filename.  Moving a file that another overlay depends on also breaks that
# overlay.  Production images are expected to be standalone clones, so fail
# closed instead of attempting an implicit rebase during a storage rename.
declare -A MOVING_PATHS=() MOVING_QCOW2=()
for i in "${!SOURCES[@]}"; do
    src=${SOURCES[$i]}
    source_key=$(readlink -m -- "$src")
    MOVING_PATHS["$source_key"]=1
    real_src=$(readlink -f -- "$src" 2>/dev/null || true)
    [[ -n "$real_src" ]] && MOVING_PATHS["$real_src"]=1
    if [[ -L "$src" ]]; then
        echo "[storage-migrate] BLOCKED: source symlink move is not supported: $src" >&2
        BLOCKED=1
        continue
    fi
    case "${src##*/}" in
        *.qcow2|*.qcow2.*)
            MOVING_QCOW2["$source_key"]=1
            [[ -n "$real_src" ]] && MOVING_QCOW2["$real_src"]=1
            ;;
    esac
done

if ((${#MOVING_PATHS[@]})); then
    QEMU_IMG="$here/../build/qemu-img"
    [[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img || true)
    if [[ -z "$QEMU_IMG" || ! -x "$QEMU_IMG" || ! -x "$(command -v jq || true)" ]]; then
        echo "[storage-migrate] BLOCKED: qemu-img and jq are required for backing-file checks" >&2
        BLOCKED=1
    else
        exec {QCOW2_FIND_FD}< <(
            while IFS= read -r -d '' scan_root; do
                find -L "$scan_root" \( -type f -o -type l \) \
                    \( -name '*.qcow2' -o -name '*.qcow2.*' \) -print0 || exit 1
            done < <(vm_storage_qcow2_scan_roots)
        )
        QCOW2_FIND_PID=$!
        while IFS= read -r -d '' image <&"$QCOW2_FIND_FD"; do
            image_key=$(readlink -m -- "$image")
            if ! vm_storage_read_qcow2_chain_metadata "$QEMU_IMG" "$image"; then
                echo "[storage-migrate] BLOCKED: cannot prove qcow2 backing safety" >&2
                echo "  image: $image" >&2
                BLOCKED=1
                continue
            fi

            if [[ -n "${MOVING_QCOW2[$image_key]+moving}" &&
                  -n "$VM_STORAGE_QCOW2_BACKING" ]]; then
                echo "[storage-migrate] BLOCKED: planned qcow2 has a backing file" >&2
                echo "  image:   $image" >&2
                echo "  backing: $VM_STORAGE_QCOW2_BACKING" >&2
                BLOCKED=1
            fi
            if [[ -n "${MOVING_QCOW2[$image_key]+moving}" &&
                  -n "$VM_STORAGE_QCOW2_DATA_FILE" ]]; then
                echo "[storage-migrate] BLOCKED: planned qcow2 has an external data-file" >&2
                echo "  image:     $image" >&2
                echo "  data-file: $VM_STORAGE_QCOW2_DATA_FILE" >&2
                BLOCKED=1
            fi

            for dependency in "${VM_STORAGE_QCOW2_CHAIN_FILES[@]:1}"; do
                dependency_moves=0
                if [[ -n "${MOVING_PATHS[$dependency]+moving}" ]]; then
                    dependency_moves=1
                else
                    real_dependency=$(readlink -f -- "$dependency" 2>/dev/null || true)
                    if [[ -n "$real_dependency" &&
                          -n "${MOVING_PATHS[$real_dependency]+moving}" ]]; then
                        dependency_moves=1
                    fi
                fi
                if ((dependency_moves)); then
                    echo "[storage-migrate] BLOCKED: image chain depends on a planned file that would move" >&2
                    echo "  image:      $image" >&2
                    echo "  dependency: $dependency" >&2
                    BLOCKED=1
                    break
                fi
            done

            for data_file in "${VM_STORAGE_QCOW2_CHAIN_DATA_FILES[@]}"; do
                data_file_moves=0
                if [[ -n "${MOVING_PATHS[$data_file]+moving}" ]]; then
                    data_file_moves=1
                else
                    real_data_file=$(readlink -f -- "$data_file" 2>/dev/null || true)
                    if [[ -n "$real_data_file" &&
                          -n "${MOVING_PATHS[$real_data_file]+moving}" ]]; then
                        data_file_moves=1
                    fi
                fi
                if ((data_file_moves)); then
                    echo "[storage-migrate] BLOCKED: image chain uses a data-file that would move" >&2
                    echo "  image:     $image" >&2
                    echo "  data-file: $data_file" >&2
                    BLOCKED=1
                    break
                fi
            done
        done
        exec {QCOW2_FIND_FD}<&-
        if ! wait "$QCOW2_FIND_PID"; then
            echo "[storage-migrate] BLOCKED: could not enumerate managed qcow2 files" >&2
            BLOCKED=1
        fi
    fi
fi

# Prove every rename stays on one filesystem before apply creates directories.
for i in "${!SOURCES[@]}"; do
    parent=$(dirname "${DESTS[$i]}")
    probe=$parent
    while [[ ! -e "$probe" && ! -L "$probe" ]]; do
        next_probe=$(dirname "$probe")
        [[ "$next_probe" != "$probe" ]] || break
        probe=$next_probe
    done
    if [[ -L "$probe" || ! -d "$probe" ]]; then
        echo "[storage-migrate] BLOCKED: destination ancestor is unsafe: $probe" >&2
        BLOCKED=1
        continue
    fi
    src_dev=$(stat -Lc %d -- "${SOURCES[$i]}")
    dst_dev=$(stat -Lc %d -- "$probe")
    if [[ "$src_dev" != "$dst_dev" ]]; then
        echo "[storage-migrate] BLOCKED: cross-filesystem move refused" >&2
        echo "  source:      ${SOURCES[$i]}" >&2
        echo "  destination: ${DESTS[$i]}" >&2
        BLOCKED=1
    fi
done

if ((BLOCKED)); then
    echo "[storage-migrate] no files moved; stop/fix every blocker and rerun" >&2
    exit 1
fi

if ((!APPLY)); then
    echo "[storage-migrate] CHECK ONLY: no files moved; rerun with --apply after all VMs are stopped"
    exit 0
fi

# Older launchers and lifecycle tools coordinate through stable global per-VM
# locks.  Take both before creating any destination directory.
declare -a INSTANCE_LOCK_FDS=()
for id in $(printf '%s\n' "${!VM_IDS[@]}" | sort -n); do
    start_lock=$(vm_storage_run_preferred_path "$id" start.lock)
    disk_lock=$(vm_storage_run_preferred_path "$id" disk.lock)
    exec {fd}>"$start_lock"
    if ! flock -n "$fd"; then
        echo "[storage-migrate] vm${id} start lock is busy; no files moved" >&2
        exit 1
    fi
    INSTANCE_LOCK_FDS+=("$fd")
    exec {fd}>"$disk_lock"
    if ! flock -n -x "$fd"; then
        echo "[storage-migrate] vm${id} disk lock is busy; no files moved" >&2
        exit 1
    fi
    INSTANCE_LOCK_FDS+=("$fd")
done

declare -a CREATED_DIRS=()
declare -A CREATED_DIR_SEEN=()
for dst in "${DESTS[@]}"; do
    parent=$(dirname "$dst")
    probe=$parent
    while [[ ! -e "$probe" && ! -L "$probe" ]]; do
        if [[ -z "${CREATED_DIR_SEEN[$probe]+created}" ]]; then
            CREATED_DIR_SEEN[$probe]=1
            CREATED_DIRS+=("$probe")
        fi
        next_probe=$(dirname "$probe")
        [[ "$next_probe" != "$probe" ]] || break
        probe=$next_probe
    done
    mkdir -p "$parent"
done

for i in "${!SOURCES[@]}"; do
    src=${SOURCES[$i]}
    dst=${DESTS[$i]}
    src_dev=$(stat -c %d -- "$src")
    dst_dev=$(stat -c %d -- "$(dirname "$dst")")
    if [[ "$src_dev" != "$dst_dev" ]]; then
        echo "[storage-migrate] cross-filesystem move refused: $src -> $dst" >&2
        exit 1
    fi
done

MANIFEST="$VM_RUN_DIR/storage-migration-$(date +%Y%m%d-%H%M%S)-$$.tsv"
{
    printf '# source\tdestination\n'
    for i in "${!SOURCES[@]}"; do
        printf '%s\t%s\n' "${SOURCES[$i]}" "${DESTS[$i]}"
    done
} >"$MANIFEST"

declare -a MOVED_INDEXES=() SOURCE_IDENTITIES=()
for i in "${!SOURCES[@]}"; do
    SOURCE_IDENTITIES[$i]=$(stat -Lc '%d:%i' -- "${SOURCES[$i]}")
done
ROLLBACK_NEEDED=1
rollback_migration() {
    local n idx src dst current_identity dir
    echo "[storage-migrate] move failed/interrupted; rolling back completed renames" >&2
    for ((n = ${#MOVED_INDEXES[@]} - 1; n >= 0; n--)); do
        idx=${MOVED_INDEXES[$n]}
        src=${SOURCES[$idx]}
        dst=${DESTS[$idx]}
        if [[ ! -e "$src" && ! -L "$src" && ( -e "$dst" || -L "$dst" ) ]]; then
            current_identity=$(stat -Lc '%d:%i' -- "$dst" 2>/dev/null || true)
            if [[ "$current_identity" == "${SOURCE_IDENTITIES[$idx]}" ]] &&
                    mv -T -- "$dst" "$src"; then
                echo "  rollback: $dst -> $src" >&2
            else
                echo "  ROLLBACK FAILED: $dst -> $src (see $MANIFEST)" >&2
            fi
        elif [[ ( -e "$src" || -L "$src" ) && ! -e "$dst" && ! -L "$dst" ]]; then
            current_identity=$(stat -Lc '%d:%i' -- "$src" 2>/dev/null || true)
            if [[ "$current_identity" != "${SOURCE_IDENTITIES[$idx]}" ]]; then
                echo "  ROLLBACK FAILED: source identity changed: $src" >&2
            fi
        else
            echo "  ROLLBACK SKIPPED: unexpected paths for $src <- $dst" >&2
        fi
    done
    for dir in "${CREATED_DIRS[@]}"; do
        rmdir -- "$dir" 2>/dev/null || true
    done
}
trap 'rc=$?; trap - EXIT; ((ROLLBACK_NEEDED)) && rollback_migration; exit "$rc"' EXIT

for i in "${!SOURCES[@]}"; do
    if [[ ! -e "${SOURCES[$i]}" && ! -L "${SOURCES[$i]}" ]]; then
        echo "[storage-migrate] source disappeared before move: ${SOURCES[$i]}" >&2
        exit 1
    fi
    if [[ -e "${DESTS[$i]}" || -L "${DESTS[$i]}" ]]; then
        echo "[storage-migrate] destination appeared before move: ${DESTS[$i]}" >&2
        exit 1
    fi
    if [[ "$(stat -Lc '%d:%i' -- "${SOURCES[$i]}")" != "${SOURCE_IDENTITIES[$i]}" ]]; then
        echo "[storage-migrate] source identity changed before move: ${SOURCES[$i]}" >&2
        exit 1
    fi
    echo "[storage-migrate] mv ${SOURCES[$i]} -> ${DESTS[$i]}"
    MOVED_INDEXES+=("$i")
    mv -T -- "${SOURCES[$i]}" "${DESTS[$i]}"
done
ROLLBACK_NEEDED=0
trap - EXIT

for id in "${!VM_IDS[@]}"; do
    vm_storage_prepare_instance "$id"
done

# Remove only empty directories from the two deprecated layouts.  Unknown or
# user-created files keep their parent directory intact.
for legacy_dir in \
    "$VM_DISK_ARCHIVE_DIR" "$VM_NVRAM_BACKUP_DIR" \
    "$VM_CONFIG_DIR" "$VM_DISK_DIR" "$VM_NVRAM_DIR" "$VM_LOG_DIR"; do
    rmdir -- "$legacy_dir" 2>/dev/null || true
done

echo "[storage-migrate] complete; manifest: $MANIFEST"
echo "[storage-migrate] unmanaged numeric instance dirs and $VM_ROOT/_base were not touched"

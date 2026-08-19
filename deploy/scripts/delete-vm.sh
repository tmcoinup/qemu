#!/usr/bin/env bash
#
# delete-vm.sh — 删除一个 VM 的所有 host 文件。
#
# 用法:
#   ./deploy/scripts/delete-vm.sh <vm_id>                         # y/N 确认
#   ./deploy/scripts/delete-vm.sh <vm_id> -y                      # 跳过确认
#   ./deploy/scripts/delete-vm.sh <vm_id> --vms-dir /mnt/my-vms  # 指定根
#
# 删的:
#   $VM_INSTANCES_DIR/N/              # 配置、磁盘、NVRAM、TPM、日志、runtime、备份
#   旧 configs/disks/nvram/log 路径    # 迁移期兼容
#   /dev/shm/nv-shmem-vmN             # ivshmem 后端
#
# 不动:
#   $VM_BASE_DIR/*.qcow2              # 所有具名公共 baseline 及其证明
#
# 安全保护：检测到 QEMU 还在跑会拒绝删，先用规范 stop 入口停机。
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/vgpu-mdev.sh
source "$here/lib/vgpu-mdev.sh"

VM_ID=""
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)  ASSUME_YES=1; shift ;;
        --vms-dir)
            [[ $# -ge 2 ]] || { echo "--vms-dir 需要一个绝对路径" >&2; exit 2; }
            [[ -z "${VMS_DIR_CLI:-}" ]] || { echo "--vms-dir 只能指定一次" >&2; exit 2; }
            VMS_DIR_CLI=$2
            shift 2
            ;;
        --vms-dir=*)
            [[ -z "${VMS_DIR_CLI:-}" ]] || { echo "--vms-dir 只能指定一次" >&2; exit 2; }
            VMS_DIR_CLI=${1#*=}
            [[ -n "$VMS_DIR_CLI" ]] || { echo "--vms-dir 需要一个绝对路径" >&2; exit 2; }
            shift
            ;;
        -h|--help) sed -n '3,21p' "$0"; exit 0 ;;
        [0-9]*)    VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ "$VM_ID" =~ ^[1-9][0-9]*$ ]] || {
    echo "usage: $0 <vm_id> [-y] [--vms-dir ABS]" >&2
    exit 2
}
if [[ -n "${VMS_DIR_CLI:-}" ]]; then
    vm_storage_select_root "$VMS_DIR_CLI"
fi
vm_storage_init
vm_storage_require_namespace_ready "$VM_ID"
INSTANCE_DIR=$(vm_storage_instance_dir "$VM_ID")
INSTANCE_PREEXISTED=0
[[ -d "$INSTANCE_DIR" && ! -L "$INSTANCE_DIR" ]] && INSTANCE_PREEXISTED=1
if ! vm_storage_validate_instance_tree "$VM_ID"; then
    echo "[delete-vm] 实例目录包含 symlink/非目录，拒绝沿路径删除" >&2
    exit 1
fi

vm_storage_validate_root_path "$VM_ROOT" "VM root"
mkdir -p "$VM_RUN_DIR"
exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -s "$STORAGE_LOCK_FD"
vm_storage_prepare_instance "$VM_ID"
START_LOCK=$(vm_storage_run_path "$VM_ID" start.lock)
exec {START_LOCK_FD}>"$START_LOCK"
if ! flock -n "$START_LOCK_FD"; then
    echo "[delete-vm] !! vm${VM_ID} 正在启动或运行，先执行 ./deploy/scripts/stop-vm.sh ${VM_ID}" >&2
    exit 1
fi
DISK_LOCK=$(vm_storage_run_path "$VM_ID" disk.lock)
exec {DISK_LOCK_FD}>"$DISK_LOCK"
if ! flock -n -x "$DISK_LOCK_FD"; then
    echo "[delete-vm] !! vm${VM_ID} 的磁盘正在创建或执行其它生命周期操作" >&2
    exit 1
fi
TPM_LOCK=$(vm_storage_run_path "$VM_ID" tpm.lock)
exec {TPM_LOCK_FD}>"$TPM_LOCK"
if ! flock -n -x "$TPM_LOCK_FD"; then
    echo "[delete-vm] !! vm${VM_ID} 的 TPM 生命周期操作仍在进行" >&2
    exit 1
fi

# Refuse to remove a flat lock inode that an older G-11 tool still holds.
declare -a LEGACY_LOCK_FDS=()
for legacy_kind in start.lock disk.lock tpm.lock; do
    legacy_lock=$(vm_storage_run_legacy_path "$VM_ID" "$legacy_kind")
    [[ -e "$legacy_lock" || -L "$legacy_lock" ]] || continue
    [[ -f "$legacy_lock" && ! -L "$legacy_lock" ]] || {
        echo "[delete-vm] 旧锁路径不安全，拒绝删除: $legacy_lock" >&2
        exit 1
    }
    exec {legacy_fd}<>"$legacy_lock"
    if ! flock -n -x "$legacy_fd"; then
        echo "[delete-vm] 旧版生命周期操作仍持锁，先完成迁移/停止操作: $legacy_lock" >&2
        exit 1
    fi
    LEGACY_LOCK_FDS+=("$legacy_fd")
done

# QEMU 还在跑 → 拒绝
VM_PATTERN="qemu-system-x86_64.*-name[[:space:]]+vm${VM_ID}([,[:space:]]|$)"
if pgrep -f "$VM_PATTERN" >/dev/null; then
    echo "[delete-vm] !! vm${VM_ID} QEMU 还在跑，先：" >&2
    echo "             ./deploy/scripts/stop-vm.sh ${VM_ID}" >&2
    exit 1
fi

# 收集要删的文件
declare -a TARGETS=()
declare -A TARGET_SEEN=()
add_target() {
    local f=$1
    [[ -e "$f" || -L "$f" ]] || return 0
    [[ -z "${TARGET_SEEN[$f]+present}" ]] || return 0
    TARGET_SEEN[$f]=1
    TARGETS+=("$f")
}

add_target "$(vm_storage_config_preferred_path "$VM_ID")"
add_target "$(vm_storage_config_categorized_path "$VM_ID")"
for suffix in pid qmp mon mdev monitor-edid; do
    add_target "$(vm_storage_run_preferred_path "$VM_ID" "$suffix")"
    add_target "$(vm_storage_run_legacy_path "$VM_ID" "$suffix")"
done
for suffix in start.lock disk.lock tpm.lock; do
    # Lock files from the former flat control layout are migration residue.
    # Current locks live in N/run and move atomically with the bundle below.
    add_target "$(vm_storage_run_legacy_path "$VM_ID" "$suffix")"
done
add_target "$(vm_storage_log_preferred_path "$VM_ID")"
add_target "$(vm_storage_log_categorized_path "$VM_ID")"
add_target "$(vm_storage_disk_preferred_path "$VM_ID")"
add_target "$(vm_storage_disk_categorized_path "$VM_ID")"
add_target "$(vm_storage_disk_legacy_path "$VM_ID")"
add_target "$(vm_storage_nvram_preferred_path "$VM_ID")"
add_target "$(vm_storage_nvram_categorized_path "$VM_ID")"
add_target "$(vm_storage_nvram_legacy_path "$VM_ID")"
add_target "/dev/shm/nv-shmem-vm${VM_ID}"

shopt -s nullglob
for f in \
    "$(vm_storage_instance_disk_backup_dir "$VM_ID")/"* \
    "$(vm_storage_instance_nvram_backup_dir "$VM_ID")/"* \
    "$VM_DISK_ARCHIVE_DIR/win10-vm${VM_ID}.qcow2."* \
    "$VM_ROOT/win10-vm${VM_ID}.qcow2."* \
    "$VM_NVRAM_DIR/vm${VM_ID}_VARS.fd."* \
    "$VM_NVRAM_BACKUP_DIR/vm${VM_ID}_VARS.fd."* \
    "$VM_ROOT/vm${VM_ID}_VARS.fd."*; do
    add_target "$f"
done
shopt -u nullglob

# Deleting a qcow2 pathname that another overlay records as its backing file
# would corrupt that other VM.  Scan every managed root (including explicit
# VM_DISK_DIR/VM_BASE_DIR paths outside IMAGE_ROOT) and fail closed on either a
# dependency or unreadable metadata.
declare -a DELETE_QCOW2=()
declare -A DELETE_QCOW2_KEYS=()
declare -A DELETE_QCOW2_SEEN=()
add_delete_qcow2() {
    local image=$1 real_target

    [[ -z "${DELETE_QCOW2_SEEN[$image]+present}" ]] || return 0
    DELETE_QCOW2_SEEN[$image]=1
    DELETE_QCOW2+=("$image")
    DELETE_QCOW2_KEYS["$(readlink -m -- "$image")"]=1
    real_target=$(readlink -f -- "$image" 2>/dev/null || true)
    [[ -n "$real_target" ]] && DELETE_QCOW2_KEYS["$real_target"]=1
}
for f in "${TARGETS[@]}"; do
    case "${f##*/}" in
        *.qcow2|*.qcow2.*)
            add_delete_qcow2 "$f"
            ;;
    esac
done
while IFS= read -r -d '' f; do
    add_delete_qcow2 "$f"
done < <(
    find -P "$INSTANCE_DIR" -type f \
        \( -name '*.qcow2' -o -name '*.qcow2.*' \) -print0
)

if ((${#DELETE_QCOW2[@]})); then
    : "${QEMU_IMG:=$here/../build/qemu-img}"
    [[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img || true)
    [[ -n "$QEMU_IMG" && -x "$QEMU_IMG" ]] || {
        echo "[delete-vm] 找不到 qemu-img，无法验证 backing 依赖" >&2
        exit 1
    }

    if ! command -v lsof >/dev/null 2>&1; then
        echo "[delete-vm] 缺少 lsof，无法确认待删除磁盘未被打开" >&2
        exit 1
    fi
    for f in "${DELETE_QCOW2[@]}"; do
        holders=$(lsof -t -- "$f" 2>/dev/null | paste -sd, - || true)
        if [[ -n "$holders" ]]; then
            echo "[delete-vm] 磁盘仍被进程打开，拒绝删除: $f (pids=$holders)" >&2
            exit 1
        fi
    done

    exec {QCOW2_FIND_FD}< <(
        while IFS= read -r -d '' scan_root; do
            find -L "$scan_root" \( -type f -o -type l \) \
                \( -name '*.qcow2' -o -name '*.qcow2.*' \) -print0 || exit 1
        done < <(vm_storage_qcow2_scan_roots)
    )
    QCOW2_FIND_PID=$!
    while IFS= read -r -d '' image <&"$QCOW2_FIND_FD"; do
        is_target=0
        for target in "${DELETE_QCOW2[@]}"; do
            if [[ "$image" -ef "$target" ]]; then
                is_target=1
                break
            fi
        done
        ((is_target)) && continue

        if ! vm_storage_read_qcow2_chain_metadata "$QEMU_IMG" "$image"; then
            echo "[delete-vm] 无法证明完整 backing/data-file chain 安全" >&2
            echo "  image: $image" >&2
            exit 1
        fi
        for dependency in "${VM_STORAGE_QCOW2_CHAIN_FILES[@]:1}"; do
            dependent=0
            if [[ -n "${DELETE_QCOW2_KEYS[$dependency]+target}" ]]; then
                dependent=1
            else
                real_dependency=$(readlink -f -- "$dependency" 2>/dev/null || true)
                if [[ -n "$real_dependency" &&
                      -n "${DELETE_QCOW2_KEYS[$real_dependency]+target}" ]]; then
                    dependent=1
                fi
            fi
            if ((dependent)); then
                echo "[delete-vm] 其它 overlay chain 依赖待删除磁盘，拒绝删除" >&2
                echo "  overlay:    $image" >&2
                echo "  dependency: $dependency" >&2
                exit 1
            fi
        done
        for data_file in "${VM_STORAGE_QCOW2_CHAIN_DATA_FILES[@]}"; do
            data_dependent=0
            if [[ -n "${DELETE_QCOW2_KEYS[$data_file]+target}" ]]; then
                data_dependent=1
            else
                real_data_file=$(readlink -f -- "$data_file" 2>/dev/null || true)
                if [[ -n "$real_data_file" &&
                      -n "${DELETE_QCOW2_KEYS[$real_data_file]+target}" ]]; then
                    data_dependent=1
                fi
            fi
            if ((data_dependent)); then
                echo "[delete-vm] 其它 qcow2 chain 把待删除磁盘当 external data-file，拒绝删除" >&2
                echo "  image:     $image" >&2
                echo "  data-file: $data_file" >&2
                exit 1
            fi
        done
    done
    exec {QCOW2_FIND_FD}<&-
    if ! wait "$QCOW2_FIND_PID"; then
        echo "[delete-vm] 无法枚举托管 qcow2，拒绝删除" >&2
        exit 1
    fi
fi

remove_instance_bundle() {
    local tombstone attempt

    [[ -d "$INSTANCE_DIR" && ! -L "$INSTANCE_DIR" ]] || return 0
    for attempt in {1..32}; do
        tombstone="${INSTANCE_DIR}.deleting.$$.$RANDOM"
        [[ -e "$tombstone" || -L "$tombstone" ]] || break
    done
    [[ ! -e "$tombstone" && ! -L "$tombstone" ]] || {
        echo "[delete-vm] 无法分配安全的同目录删除暂存名" >&2
        return 1
    }

    # The held lock files move with the old generation.  A concurrent future
    # start can only create a fresh numeric bundle and will never be touched by
    # the recursive removal of this exact tombstone path.
    mv -T -- "$INSTANCE_DIR" "$tombstone" || return
    if rm -rf -- "$tombstone" 2>/dev/null; then
        echo "  rm -r $INSTANCE_DIR"
    elif sudo -n rm -rf -- "$tombstone" 2>/dev/null; then
        echo "  rm -r (sudo) $INSTANCE_DIR"
    elif [[ -n "${SUDO_PASSWORD:-}" ]] &&
            printf '%s\n' "$SUDO_PASSWORD" |
                sudo -S -p '' rm -rf -- "$tombstone" 2>/dev/null; then
        echo "  rm -r (sudo) $INSTANCE_DIR"
    else
        echo "[delete-vm] 实例已隔离但未能完全删除: $tombstone" >&2
        return 1
    fi
}

cleanup_ephemeral_instance() {
    local unexpected

    (( INSTANCE_PREEXISTED == 0 )) || return 0
    [[ -d "$INSTANCE_DIR" && ! -L "$INSTANCE_DIR" ]] || return 0
    unexpected=$(find -P "$INSTANCE_DIR" -type f \
        ! -path "$INSTANCE_DIR/run/start.lock" \
        ! -path "$INSTANCE_DIR/run/disk.lock" \
        ! -path "$INSTANCE_DIR/run/tpm.lock" -print -quit 2>/dev/null || true)
    [[ -z "$unexpected" ]] || return 0
    remove_instance_bundle >/dev/null 2>&1 || true
}
trap cleanup_ephemeral_instance EXIT

if (( ${#TARGETS[@]} == 0 && INSTANCE_PREEXISTED == 0 )); then
    echo "[delete-vm] vm${VM_ID} 没找到任何文件，没事可干"
    exit 0
fi

echo "[delete-vm] 将删除 vm${VM_ID} 文件:"
total=0
if (( INSTANCE_PREEXISTED )); then
    bundle_size=$(du -sb -- "$INSTANCE_DIR" 2>/dev/null | awk '{print $1}')
    bundle_size=${bundle_size:-0}
    total=$((total + bundle_size))
    printf "  %10s  %s/  (完整 VM bundle)\n" \
        "$(numfmt --to=iec-i --suffix=B "$bundle_size")" "$INSTANCE_DIR"
fi
for f in "${TARGETS[@]}"; do
    [[ "$f" == "$INSTANCE_DIR" || "$f" == "$INSTANCE_DIR/"* ]] && continue
    size=$(stat -c%s "$f" 2>/dev/null || echo 0)
    total=$((total + size))
    printf "  %10s  %s\n" "$(numfmt --to=iec-i --suffix=B $size)" "$f"
done
printf "  %10s  (合计)\n" "$(numfmt --to=iec-i --suffix=B $total)"

if (( ! ASSUME_YES )); then
    read -rp $'\n确认删除？(y/N) ' ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "[delete-vm] 取消"; exit 0; }
fi

# 只释放该 VM 的 recovery record 指向的 mdev；绝不遍历其它 VM。
MDEV_FILE=$(vm_storage_run_path "$VM_ID" mdev)
MDEV_UUID=""
if [[ -f "$MDEV_FILE" ]]; then
    read -r MDEV_UUID <"$MDEV_FILE" || true
    if [[ ! "$MDEV_UUID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
        echo "[delete-vm] 非法 mdev recovery record，拒绝猜测或释放: $MDEV_FILE" >&2
        exit 1
    fi
    MDEV_IN_USE=0
    for proc in /proc/[0-9]*; do
        [[ -r "$proc/cmdline" ]] || continue
        exe=$(readlink -f "$proc/exe" 2>/dev/null || true)
        [[ "${exe##*/}" == qemu-system-x86_64 ]] || continue
        if tr '\0' '\n' <"$proc/cmdline" 2>/dev/null | \
                grep -Fq "/sys/bus/mdev/devices/$MDEV_UUID"; then
            MDEV_IN_USE=1
            break
        fi
    done
    if ((MDEV_IN_USE)); then
        echo "[delete-vm] mdev $MDEV_UUID 仍被进程使用，拒绝释放" >&2
        exit 1
    fi
    echo "[delete-vm] releasing vm${VM_ID} mdev $MDEV_UUID"
    mdev_release "$MDEV_UUID" || {
        echo "[delete-vm] mdev 释放失败；未删除任何 VM 文件" >&2
        exit 1
    }
fi

# 删文件 (先 user 权限，失败 fall back sudo — qcow2/VARS 可能被 root 写过)
DELETE_FAILURE=0
for f in "${TARGETS[@]}"; do
    [[ "$f" == "$INSTANCE_DIR" || "$f" == "$INSTANCE_DIR/"* ]] && continue
    if rm -f "$f" 2>/dev/null; then
        echo "  rm $f"
    elif sudo -n rm -f "$f" 2>/dev/null; then
        echo "  rm (sudo) $f"
    elif [[ -n "${SUDO_PASSWORD:-}" ]] &&
            printf '%s\n' "$SUDO_PASSWORD" |
                sudo -S -p '' rm -f "$f" 2>/dev/null; then
        echo "  rm (sudo) $f"
    else
        echo "  !! 删除失败: $f"
        DELETE_FAILURE=1
    fi
done

(( DELETE_FAILURE == 0 )) || {
    echo "[delete-vm] 外部兼容文件未全部删除；保留主 VM bundle" >&2
    exit 1
}
remove_instance_bundle
trap - EXIT

echo
echo "[delete-vm] vm${VM_ID} 清理完成"
echo "  下一步: ./deploy/scripts/start-vm.sh ${VM_ID}               # 从公共 base 自动重建并启动"
echo "      或: ./deploy/scripts/start-vm.sh ${VM_ID} --install     # 自动建空盘并装 Windows"

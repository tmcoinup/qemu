#!/usr/bin/env bash
#
# delete-vm.sh — 删除一个 VM 的所有 host 文件。
#
# 用法:
#   ./delete-vm.sh <vm_id>            # 列出要删的，y/N 确认
#   ./delete-vm.sh <vm_id> -y         # 跳过确认
#
# 删的:
#   $VM_INSTANCES_DIR/vmN/            # 配置、磁盘、NVRAM、日志、runtime、备份
#   旧 configs/disks/nvram/log 路径    # 迁移期兼容
#   /dev/shm/nv-shmem-vmN             # ivshmem 后端
#
# 不动:
#   $VM_BASE_DIR/win10-base.qcow2     # 公共 baseline
#
# 安全保护：检测到 QEMU 还在跑会拒绝删，先 ./stop-vm.sh <vm_id>。
#
set -euo pipefail
here="$(dirname "$(readlink -f "$0")")"
cd "$here"

export SUDO_PASSWORD="${SUDO_PASSWORD:-123456}"
export VM_ROOT="${VM_ROOT:-${IMAGE_ROOT:-/home/ubuntu/images}/vms}"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/vgpu-mdev.sh
source "$here/lib/vgpu-mdev.sh"
vm_storage_init

VM_ID=""
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)  ASSUME_YES=1; shift ;;
        -h|--help) sed -n '3,21p' "$0"; exit 0 ;;
        [0-9]*)    VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ "$VM_ID" =~ ^[1-9][0-9]*$ ]] || {
    echo "usage: $0 <vm_id> [-y]" >&2
    exit 2
}
INSTANCE_DIR=$(vm_storage_instance_dir "$VM_ID")
if ! vm_storage_validate_instance_tree "$VM_ID"; then
    echo "[delete-vm] 实例目录包含 symlink/非目录，拒绝沿路径删除" >&2
    exit 1
fi

mkdir -p "$VM_RUN_DIR"
exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -s "$STORAGE_LOCK_FD"
START_LOCK=$(vm_storage_run_path "$VM_ID" start.lock)
exec {START_LOCK_FD}>"$START_LOCK"
if ! flock -n "$START_LOCK_FD"; then
    echo "[delete-vm] !! vm${VM_ID} 正在启动或运行，先执行 stop-vm.sh ${VM_ID}" >&2
    exit 1
fi
DISK_LOCK=$(vm_storage_run_path "$VM_ID" disk.lock)
exec {DISK_LOCK_FD}>"$DISK_LOCK"
if ! flock -n -x "$DISK_LOCK_FD"; then
    echo "[delete-vm] !! vm${VM_ID} 的磁盘正在创建或执行其它生命周期操作" >&2
    exit 1
fi

# QEMU 还在跑 → 拒绝
VM_PATTERN="qemu-system-x86_64.*-name[[:space:]]+vm${VM_ID}([,[:space:]]|$)"
if pgrep -f "$VM_PATTERN" >/dev/null; then
    echo "[delete-vm] !! vm${VM_ID} QEMU 还在跑，先：" >&2
    echo "             ./stop-vm.sh ${VM_ID}" >&2
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
for f in "${TARGETS[@]}"; do
    case "${f##*/}" in
        *.qcow2|*.qcow2.*)
            DELETE_QCOW2+=("$f")
            DELETE_QCOW2_KEYS["$(readlink -m -- "$f")"]=1
            real_target=$(readlink -f -- "$f" 2>/dev/null || true)
            [[ -n "$real_target" ]] && DELETE_QCOW2_KEYS["$real_target"]=1
            ;;
    esac
done

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

if (( ${#TARGETS[@]} == 0 )); then
    echo "[delete-vm] vm${VM_ID} 没找到任何文件，没事可干"
    exit 0
fi

echo "[delete-vm] 将删除 vm${VM_ID} 文件:"
total=0
for f in "${TARGETS[@]}"; do
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
for f in "${TARGETS[@]}"; do
    if rm -f "$f" 2>/dev/null; then
        echo "  rm $f"
    elif echo "$SUDO_PASSWORD" | sudo -S -p '' rm -f "$f" 2>/dev/null; then
        echo "  rm (sudo) $f"
    else
        echo "  !! 删除失败: $f"
    fi
done

# Remove only directories that became empty after deleting the known VM
# payload.  Unknown files are preserved and reported instead of using a broad
# rm -rf on an instance directory.
if [[ -d "$INSTANCE_DIR" && ! -L "$INSTANCE_DIR" ]]; then
    find "$INSTANCE_DIR" -depth -type d -empty -delete 2>/dev/null || true
    if [[ -e "$INSTANCE_DIR" ]]; then
        echo "[delete-vm] 保留含未知文件的实例目录: $INSTANCE_DIR" >&2
    fi
fi

echo
echo "[delete-vm] vm${VM_ID} 清理完成"
echo "  下一步: ./start-vm.sh ${VM_ID}               # 从公共 base 自动重建并启动"
echo "      或: ./start-vm.sh ${VM_ID} --install     # 自动建空盘并装 Windows"

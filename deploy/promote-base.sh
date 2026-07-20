#!/usr/bin/env bash
#
# promote-base.sh — 把 VM 系统盘转换成 $VM_BASE_DIR/win10-base.qcow2。
#
# 跑前提:
#   guest 已优雅 shutdown (./stop-vm.sh <vm_id>)
#   guest 内 driver/license/service 全部 working
#
# 跑完后所有 ./delete-vm.sh + ./start-vm.sh 都从这个干净 baseline 复制起，
# 不再需要 setup-guest 装 driver/license。
#
# 用法:
#   ./promote-base.sh           # vm1
#   ./promote-base.sh <vm_id>
#   ./promote-base.sh -y        # 跳过确认
#
set -euo pipefail
here="$(dirname "$(readlink -f "$0")")"
cd "$here"

# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
vm_storage_init
VM_ID=1
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) sed -n '3,15p' "$0"; exit 0 ;;
        [0-9]*) VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ "$VM_ID" =~ ^[1-9][0-9]*$ ]] || {
    echo "VM_ID 必须是正整数: $VM_ID" >&2
    exit 2
}
vm_storage_validate_instance_tree "$VM_ID"

mkdir -p "$VM_RUN_DIR"
exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
if ! flock -n -x "$STORAGE_LOCK_FD"; then
    echo "[promote-base] 其它 VM 正在运行或有存储操作；制作公共 base 前请全部停止" >&2
    exit 1
fi
mkdir -p "$VM_BASE_DIR" "$VM_BASE_ARCHIVE_DIR"
START_LOCK=$(vm_storage_run_path "$VM_ID" start.lock)
exec {START_LOCK_FD}>"$START_LOCK"
if ! flock -n "$START_LOCK_FD"; then
    echo "[promote-base] vm${VM_ID} 正在启动或运行，不能制作 base" >&2
    exit 1
fi

VM_DISK=$(vm_storage_disk_path "$VM_ID")
BASE=$(vm_storage_base_path)
[[ -f "$VM_DISK" ]] || { echo "missing $VM_DISK" >&2; exit 1; }

: "${QEMU_IMG:=$here/../build/qemu-img}"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img || true)
[[ -x "$QEMU_IMG" ]] || { echo "找不到 qemu-img" >&2; exit 1; }

if ! vm_storage_read_qcow2_metadata "$QEMU_IMG" "$VM_DISK"; then
    echo "[promote-base] 源磁盘不是可验证的 qcow2: $VM_DISK" >&2
    exit 1
fi
"$QEMU_IMG" check -q "$VM_DISK"
if [[ -f "$BASE" ]]; then
    if ! vm_storage_read_qcow2_metadata "$QEMU_IMG" "$BASE"; then
        echo "[promote-base] 现有 base 不是可验证的 qcow2: $BASE" >&2
        exit 1
    fi
    if [[ -n "$VM_STORAGE_QCOW2_BACKING" ||
          -n "$VM_STORAGE_QCOW2_DATA_FILE" ]]; then
        echo "[promote-base] 现有 base 不是 standalone，拒绝移动到 archive" >&2
        echo "  backing:  $VM_STORAGE_QCOW2_BACKING" >&2
        echo "  data-file: $VM_STORAGE_QCOW2_DATA_FILE" >&2
        exit 1
    fi
    "$QEMU_IMG" check -q "$BASE"
fi

# 安全保护
if pgrep -f "qemu-system-x86_64.*-name[[:space:]]+vm${VM_ID}([,[:space:]]|$)" >/dev/null; then
    echo "[promote-base] !! vm${VM_ID} QEMU 还在跑，先：" >&2
    echo "  ./stop-vm.sh ${VM_ID}" >&2
    exit 1
fi
if ! command -v lsof >/dev/null 2>&1; then
    echo "[promote-base] 缺少 lsof，无法确认源磁盘/base 未被打开" >&2
    exit 1
fi
for held_path in "$VM_DISK" "$BASE"; do
    [[ -e "$held_path" ]] || continue
    holders=$(lsof -t -- "$held_path" 2>/dev/null | paste -sd, - || true)
    if [[ -n "$holders" ]]; then
        echo "[promote-base] 文件仍被进程打开，拒绝制作 base: $held_path (pids=$holders)" >&2
        exit 1
    fi
done

# Replacing a pathname that an overlay uses as its backing file can silently
# change that VM's data semantics even when every QEMU is stopped.  Inspect all
# qcow2-like files under IMAGE_ROOT and refuse publication if any depend on the
# current base.  Metadata failures also block because dependency safety cannot
# then be proven.
base_key=$(readlink -m -- "$BASE")
base_real=$(readlink -f -- "$BASE" 2>/dev/null || true)
exec {QCOW2_FIND_FD}< <(
    while IFS= read -r -d '' scan_root; do
        find -L "$scan_root" \( -type f -o -type l \) \
            \( -name '*.qcow2' -o -name '*.qcow2.*' \) -print0 || exit 1
    done < <(vm_storage_qcow2_scan_roots)
)
QCOW2_FIND_PID=$!
while IFS= read -r -d '' image <&"$QCOW2_FIND_FD"; do
    [[ -e "$BASE" && "$image" -ef "$BASE" ]] && continue
    if ! vm_storage_read_qcow2_chain_metadata "$QEMU_IMG" "$image"; then
        echo "[promote-base] 无法证明完整 backing/data-file chain 安全，拒绝替换" >&2
        echo "  image: $image" >&2
        exit 1
    fi
    for dependency in "${VM_STORAGE_QCOW2_CHAIN_FILES[@]:1}"; do
        real_dependency=$(readlink -f -- "$dependency" 2>/dev/null || true)
        if [[ "$dependency" == "$base_key" ||
              ( -n "$base_real" && "$real_dependency" == "$base_real" ) ]]; then
            echo "[promote-base] 现有 overlay 依赖目标 base 路径，拒绝替换" >&2
            echo "  overlay: $image" >&2
            echo "  backing: $dependency" >&2
            exit 1
        fi
    done
    for data_file in "${VM_STORAGE_QCOW2_CHAIN_DATA_FILES[@]}"; do
        real_data_file=$(readlink -f -- "$data_file" 2>/dev/null || true)
        if [[ "$data_file" == "$base_key" ||
              ( -n "$base_real" && "$real_data_file" == "$base_real" ) ]]; then
            echo "[promote-base] 现有 qcow2 把目标 base 当 external data-file，拒绝替换" >&2
            echo "  image:     $image" >&2
            echo "  data-file: $data_file" >&2
            exit 1
        fi
    done
done
exec {QCOW2_FIND_FD}<&-
if ! wait "$QCOW2_FIND_PID"; then
    echo "[promote-base] 无法枚举托管 qcow2，拒绝替换" >&2
    exit 1
fi

base_dev=$(stat -c %d -- "$(dirname "$BASE")")
archive_dev=$(stat -c %d -- "$VM_BASE_ARCHIVE_DIR")
if [[ "$base_dev" != "$archive_dev" ]]; then
    echo "[promote-base] base 与 archive 不在同一文件系统，拒绝非原子替换" >&2
    exit 1
fi

vm_size=$(stat -c%s "$VM_DISK")
echo "[promote-base] 把 $VM_DISK ($(numfmt --to=iec-i --suffix=B $vm_size)) 复制为 $BASE"
if [[ -f "$BASE" ]]; then
    base_size=$(stat -c%s "$BASE")
    echo "  (现有 $BASE = $(numfmt --to=iec-i --suffix=B $base_size) → 归档后原子替换)"
fi

if (( ! ASSUME_YES )); then
    read -rp "确认？(y/N) " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "[promote-base] 取消"; exit 0; }
fi

# qemu-img convert 而不是 cp，让新 base 是 standalone qcow2（不含 dirty
# 状态、不依赖 backing file）。先生成并校验临时文件；只有成功后才归档旧 base，
# 避免 convert 失败导致有效 base 消失。
BASE_TMP="$(dirname "$BASE")/.$(basename "$BASE").partial.$$.$RANDOM"
BASE_BACKUP=""
cleanup_promote() {
    rm -f -- "$BASE_TMP"
    if [[ ! -e "$BASE" && -n "$BASE_BACKUP" && -e "$BASE_BACKUP" ]]; then
        mv -T -- "$BASE_BACKUP" "$BASE" || true
    fi
}
trap cleanup_promote EXIT

echo "[promote-base] qemu-img convert (compact + standalone)..."
"$QEMU_IMG" convert -O qcow2 -c "$VM_DISK" "$BASE_TMP"
"$QEMU_IMG" check -q "$BASE_TMP"
if ! vm_storage_read_qcow2_metadata "$QEMU_IMG" "$BASE_TMP" ||
        [[ -n "$VM_STORAGE_QCOW2_BACKING" ||
           -n "$VM_STORAGE_QCOW2_DATA_FILE" ]]; then
    echo "[promote-base] convert 结果不是有效 standalone qcow2，拒绝发布" >&2
    exit 1
fi

if [[ -f "$BASE" ]]; then
    BASE_BACKUP="$VM_BASE_ARCHIVE_DIR/win10-base-$(date +%Y%m%d-%H%M%S)-$$.qcow2"
    mv -T -- "$BASE" "$BASE_BACKUP"
    echo "[promote-base] 旧 base 已归档 → $BASE_BACKUP"
fi
if ! mv -T -- "$BASE_TMP" "$BASE"; then
    echo "[promote-base] 发布新 base 失败，正在恢复旧 base" >&2
    cleanup_promote
    exit 1
fi
trap - EXIT
new_size=$(stat -c%s "$BASE")
echo "[promote-base] 新 base = $(numfmt --to=iec-i --suffix=B $new_size) (compact)"

ls -la "$BASE" "$VM_DISK" ${BASE_BACKUP:+"$BASE_BACKUP"} 2>/dev/null
echo
echo "[promote-base] 完成。下次:"
echo "  ./delete-vm.sh ${VM_ID} -y      # 删 vm${VM_ID} (不动 base)"
echo "  ./start-vm.sh ${VM_ID}          # 缺盘时 create-disk 会从 bases/ 自动复制"

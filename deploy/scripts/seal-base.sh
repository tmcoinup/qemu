#!/usr/bin/env bash
#
# seal-base.sh — 把 VM 系统盘封装成一个有名字的公共基础镜像。
#
# 跑前提:
#   guest 已通过 deploy/scripts/stop-vm.sh 优雅 shutdown
#   guest 内 driver/license/service 全部 working
#
# 默认先离线清理源盘中的 WeGame/Tencent 跨克隆身份缓存，再把源盘转换成
# standalone base。需要保留源盘登录态时必须显式传 --no-clean。
#
# 跑完并注入 portable 后，用 clone-from-base.sh 按名字从这个干净 baseline
# 复制；不再需要 setup-guest 重装 driver/license。
#
# 用法:
#   ./deploy/scripts/seal-base.sh <源_vm_id> <base_name>
#   ./deploy/scripts/seal-base.sh 1 win10-ltsc-v1 -y
#   ./deploy/scripts/seal-base.sh 1 win10-ltsc-v1 --no-clean
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
vm_storage_init

usage() {
    cat <<'EOF'
usage: ./deploy/scripts/seal-base.sh SOURCE_VM_ID BASE_NAME [-y|--yes] [--no-clean]

BASE_NAME 只能包含字母、数字、下划线和短横线，不要写 .qcow2。
例如 BASE_NAME=win10-ltsc-v1 会产出 win10-ltsc-v1.qcow2。

封装前默认离线清理源 Windows 盘中的 WeGame/Tencent
QIMEI、登录态、SDK/设备缓存和对应注册表键；清理失败则拒绝产出 base。
只有明确需要原样保留这些身份时才使用 --no-clean。
EOF
}

VM_ID=""
BASE_NAME=""
ASSUME_YES=0
CLEAN_WEGAME=1
declare -a POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1; shift ;;
        --no-clean) CLEAN_WEGAME=0; shift ;;
        -h|--help) usage; exit 0 ;;
        --*) echo "unknown arg: $1" >&2; exit 2 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

if ((${#POSITIONAL[@]} != 2)); then
    usage >&2
    exit 2
fi
VM_ID=${POSITIONAL[0]}
BASE_NAME=${POSITIONAL[1]}
vm_storage_validate_id "$VM_ID"
vm_storage_validate_base_name "$BASE_NAME"
vm_storage_require_namespace_ready "$VM_ID"
vm_storage_validate_instance_tree "$VM_ID"

vm_storage_validate_root_path "$VM_ROOT" "VM root"
mkdir -p "$VM_RUN_DIR"
exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
if ! flock -n -x "$STORAGE_LOCK_FD"; then
    echo "[seal-base] 其它 VM 正在运行或有存储操作；制作公共 base 前请全部停止" >&2
    exit 1
fi
vm_storage_prepare_instance "$VM_ID"
mkdir -p "$VM_BASE_DIR" "$VM_BASE_ARCHIVE_DIR"
START_LOCK=$(vm_storage_run_path "$VM_ID" start.lock)
exec {START_LOCK_FD}>"$START_LOCK"
if ! flock -n "$START_LOCK_FD"; then
    echo "[seal-base] vm${VM_ID} 正在启动或运行，不能制作 base" >&2
    exit 1
fi

VM_DISK=$(vm_storage_disk_path "$VM_ID")
BASE=$(vm_storage_base_path "$BASE_NAME")
ATTESTATION="${BASE}.vgpu-portable.json"
[[ -f "$VM_DISK" ]] || { echo "missing $VM_DISK" >&2; exit 1; }
[[ ! -L "$BASE" ]] || {
    echo "[seal-base] base 路径不能是符号链接: $BASE" >&2
    exit 1
}
if [[ -e "$BASE" && ! -f "$BASE" ]]; then
    echo "[seal-base] base 路径不是普通文件: $BASE" >&2
    exit 1
fi
if [[ -e "$ATTESTATION" || -L "$ATTESTATION" ]]; then
    [[ -f "$ATTESTATION" && ! -L "$ATTESTATION" ]] || {
        echo "[seal-base] portable 证明不是普通文件: $ATTESTATION" >&2
        exit 1
    }
    [[ -f "$BASE" ]] || {
        echo "[seal-base] 发现没有对应 base 的孤立 portable 证明: $ATTESTATION" >&2
        echo "  请先人工核对并移走该文件，脚本不会猜测其归属。" >&2
        exit 1
    }
fi
CLEANER="$here/scripts/host-clean-tencent.sh"
if (( CLEAN_WEGAME )); then
    [[ -x "$CLEANER" ]] || {
        echo "[seal-base] 缺少 WeGame/Tencent 清理器: $CLEANER" >&2
        exit 1
    }
fi

: "${QEMU_IMG:=$here/../build/qemu-img}"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img || true)
[[ -x "$QEMU_IMG" ]] || { echo "找不到 qemu-img" >&2; exit 1; }

if ! vm_storage_read_qcow2_metadata "$QEMU_IMG" "$VM_DISK"; then
    echo "[seal-base] 源磁盘不是可验证的 qcow2: $VM_DISK" >&2
    exit 1
fi
"$QEMU_IMG" check -q "$VM_DISK"
if [[ -f "$BASE" ]]; then
    if ! vm_storage_read_qcow2_metadata "$QEMU_IMG" "$BASE"; then
        echo "[seal-base] 现有 base 不是可验证的 qcow2: $BASE" >&2
        exit 1
    fi
    if [[ -n "$VM_STORAGE_QCOW2_BACKING" ||
          -n "$VM_STORAGE_QCOW2_DATA_FILE" ]]; then
        echo "[seal-base] 现有 base 不是 standalone，拒绝移动到 archive" >&2
        echo "  backing:  $VM_STORAGE_QCOW2_BACKING" >&2
        echo "  data-file: $VM_STORAGE_QCOW2_DATA_FILE" >&2
        exit 1
    fi
    "$QEMU_IMG" check -q "$BASE"
fi

# 安全保护
if pgrep -f "qemu-system-x86_64.*-name[[:space:]]+vm${VM_ID}([,[:space:]]|$)" >/dev/null; then
    echo "[seal-base] !! vm${VM_ID} QEMU 还在跑，先：" >&2
    echo "  ./deploy/scripts/stop-vm.sh ${VM_ID}" >&2
    exit 1
fi
if ! command -v lsof >/dev/null 2>&1; then
    echo "[seal-base] 缺少 lsof，无法确认源磁盘/base 未被打开" >&2
    exit 1
fi
for held_path in "$VM_DISK" "$BASE"; do
    [[ -e "$held_path" ]] || continue
    holders=$(lsof -t -- "$held_path" 2>/dev/null | paste -sd, - || true)
    if [[ -n "$holders" ]]; then
        echo "[seal-base] 文件仍被进程打开，拒绝制作 base: $held_path (pids=$holders)" >&2
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
            \( -name '*.qcow2' -o -name '*.qcow2.*' \) \
            ! -name '*.vgpu-portable.json' -print0 || exit 1
    done < <(vm_storage_qcow2_scan_roots)
)
QCOW2_FIND_PID=$!
while IFS= read -r -d '' image <&"$QCOW2_FIND_FD"; do
    [[ -e "$BASE" && "$image" -ef "$BASE" ]] && continue
    if ! vm_storage_read_qcow2_chain_metadata "$QEMU_IMG" "$image"; then
        echo "[seal-base] 无法证明完整 backing/data-file chain 安全，拒绝替换" >&2
        echo "  image: $image" >&2
        exit 1
    fi
    for dependency in "${VM_STORAGE_QCOW2_CHAIN_FILES[@]:1}"; do
        real_dependency=$(readlink -f -- "$dependency" 2>/dev/null || true)
        if [[ "$dependency" == "$base_key" ||
              ( -n "$base_real" && "$real_dependency" == "$base_real" ) ]]; then
            echo "[seal-base] 现有 overlay 依赖目标 base 路径，拒绝替换" >&2
            echo "  overlay: $image" >&2
            echo "  backing: $dependency" >&2
            exit 1
        fi
    done
    for data_file in "${VM_STORAGE_QCOW2_CHAIN_DATA_FILES[@]}"; do
        real_data_file=$(readlink -f -- "$data_file" 2>/dev/null || true)
        if [[ "$data_file" == "$base_key" ||
              ( -n "$base_real" && "$real_data_file" == "$base_real" ) ]]; then
            echo "[seal-base] 现有 qcow2 把目标 base 当 external data-file，拒绝替换" >&2
            echo "  image:     $image" >&2
            echo "  data-file: $data_file" >&2
            exit 1
        fi
    done
done
exec {QCOW2_FIND_FD}<&-
if ! wait "$QCOW2_FIND_PID"; then
    echo "[seal-base] 无法枚举托管 qcow2，拒绝替换" >&2
    exit 1
fi

base_dev=$(stat -c %d -- "$(dirname "$BASE")")
archive_dev=$(stat -c %d -- "$VM_BASE_ARCHIVE_DIR")
if [[ "$base_dev" != "$archive_dev" ]]; then
    echo "[seal-base] base 与 archive 不在同一文件系统，拒绝非原子替换" >&2
    exit 1
fi

vm_size=$(stat -c%s "$VM_DISK")
echo "[seal-base] 把 $VM_DISK ($(numfmt --to=iec-i --suffix=B $vm_size)) 复制为 $BASE"
if (( CLEAN_WEGAME )); then
    echo "  默认清理: WeGame/Tencent QIMEI、登录态、SDK/设备缓存和注册表键"
    echo "  注意: 清理会写入源盘；失败时不会发布基础镜像"
else
    echo "  警告: --no-clean 已选择，源盘的 WeGame/Tencent 身份会原样进入基础镜像"
fi
if [[ -f "$BASE" ]]; then
    base_size=$(stat -c%s "$BASE")
    echo "  (现有 $BASE = $(numfmt --to=iec-i --suffix=B $base_size) → 归档后原子替换)"
fi

if (( ! ASSUME_YES )); then
    read -rp "确认？(y/N) " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "[seal-base] 取消"; exit 0; }
fi

# 与 V-11 的 seal 行为保持一致：先清理源盘，再 convert。清理器拒绝 dirty/
# hibernated NTFS，不使用 ntfsfix/remove_hiberfile，也不触碰 BCD 或驱动。
if (( CLEAN_WEGAME )); then
    echo "[seal-base] 清理源盘的 WeGame/Tencent 跨克隆身份..."
    if (( EUID == 0 )); then
        "$CLEANER" "$VM_ID" --disk "$VM_DISK"
    else
        command -v sudo >/dev/null 2>&1 || {
            echo "[seal-base] 清理需要 root，且找不到 sudo" >&2
            exit 1
        }
        sudo -- "$CLEANER" "$VM_ID" --disk "$VM_DISK"
    fi
    "$QEMU_IMG" check -q "$VM_DISK"
    echo "[seal-base] WeGame/Tencent 跨克隆身份清理完成"
else
    echo "[seal-base] --no-clean：跳过 WeGame/Tencent 身份清理"
fi

# qemu-img convert 而不是 cp，让新 base 是 standalone qcow2（不含 dirty
# 状态、不依赖 backing file）。先生成并校验临时文件；只有成功后才归档旧 base，
# 避免 convert 失败导致有效 base 消失。
BASE_TMP="$(dirname "$BASE")/.$(basename "$BASE").partial.$$.$RANDOM"
BASE_BACKUP=""
BASE_BACKUP_ATTESTATION=""
ATTESTATION_MOVED=0
cleanup_seal() {
    rm -f -- "$BASE_TMP"
    if [[ ! -e "$BASE" && -n "$BASE_BACKUP" && -e "$BASE_BACKUP" ]]; then
        mv -T -- "$BASE_BACKUP" "$BASE" || true
    fi
    if ((ATTESTATION_MOVED)) && [[ -f "$BASE" && ! -e "$ATTESTATION" &&
          -n "$BASE_BACKUP_ATTESTATION" && -e "$BASE_BACKUP_ATTESTATION" ]]; then
        mv -T -- "$BASE_BACKUP_ATTESTATION" "$ATTESTATION" || true
    fi
}
trap cleanup_seal EXIT

echo "[seal-base] qemu-img convert (compact + standalone)..."
"$QEMU_IMG" convert -O qcow2 -c "$VM_DISK" "$BASE_TMP"
"$QEMU_IMG" check -q "$BASE_TMP"
if ! vm_storage_read_qcow2_metadata "$QEMU_IMG" "$BASE_TMP" ||
        [[ -n "$VM_STORAGE_QCOW2_BACKING" ||
           -n "$VM_STORAGE_QCOW2_DATA_FILE" ]]; then
    echo "[seal-base] convert 结果不是有效 standalone qcow2，拒绝发布" >&2
    exit 1
fi

if [[ -f "$BASE" ]]; then
    BASE_BACKUP="$VM_BASE_ARCHIVE_DIR/${BASE_NAME}-$(date +%Y%m%d-%H%M%S)-$$.qcow2"
    BASE_BACKUP_ATTESTATION="${BASE_BACKUP}.vgpu-portable.json"
    if [[ -f "$ATTESTATION" ]]; then
        mv -T -- "$ATTESTATION" "$BASE_BACKUP_ATTESTATION"
        ATTESTATION_MOVED=1
    fi
    mv -T -- "$BASE" "$BASE_BACKUP"
    echo "[seal-base] 旧 base 已归档 → $BASE_BACKUP"
    if ((ATTESTATION_MOVED)); then
        echo "[seal-base] 旧 portable 证明已随同归档 → $BASE_BACKUP_ATTESTATION"
    fi
fi
if ! mv -T -- "$BASE_TMP" "$BASE"; then
    echo "[seal-base] 发布新 base 失败，正在恢复旧 base" >&2
    cleanup_seal
    exit 1
fi
trap - EXIT
new_size=$(stat -c%s "$BASE")
echo "[seal-base] 新 base = $(numfmt --to=iec-i --suffix=B $new_size) (compact)"

ls -la "$BASE" "$VM_DISK" ${BASE_BACKUP:+"$BASE_BACKUP"} 2>/dev/null
echo
echo "[seal-base] 基础镜像封装完成。继续生成 G-11 portable 证明后再克隆:"
echo "  ./deploy/package-vgpu-one-click.sh"
echo "  sudo ./deploy/install-vgpu-portable-to-base.sh --base-name $BASE_NAME"
echo "  ./deploy/scripts/clone-from-base.sh $BASE_NAME NEW_VM_ID --start"
echo "源 vm${VM_ID} 不会自动删除；验收新 base 后再按需运行 vmctl delete。"

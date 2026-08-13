#!/usr/bin/env bash
# 离线重排 VMate 实例盘：减少宿主文件碎片和 backing COW 写放大。
# 转换始终在同目录 staging 文件上完成，结构检查与逐字节逻辑对比
# 通过后才用 rename(2) 原子替换。实例锁与 start/stop 共用，优化期间无法启动 VM。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/sv-instance-lock.sh
source "$SCRIPT_DIR/lib/sv-instance-lock.sh"
# shellcheck source=lib/sv-qemu-process.sh
source "$SCRIPT_DIR/lib/sv-qemu-process.sh"
# shellcheck source=lib/qcow2-performance.sh
source "$SCRIPT_DIR/lib/qcow2-performance.sh"

VMS_DIR="${VMS_DIR:-/home/ubuntu/images/vms}"
QEMU_IMG="${QEMU_IMG:-$REPO_ROOT/build/qemu-img}"
KEEP_BACKUP=0
OPTIMIZE_ALL=0
POSITIONAL=()

usage() {
    cat <<EOF
用法：
  ${0##*/} INSTANCE [INSTANCE ...] [--keep-backup]
  ${0##*/} --all [--keep-backup]

选项：
  --vms-dir=PATH   实例根目录（默认 $VMS_DIR）
  --qemu-img=PATH  指定本分支 qemu-img
  --keep-backup    成功后保留 disk.qcow2.preopt-*（约双倍占用）
  --all            处理实例根目录下全部数字实例
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --all) OPTIMIZE_ALL=1 ;;
        --keep-backup) KEEP_BACKUP=1 ;;
        --vms-dir=*) VMS_DIR="${1#*=}" ;;
        --qemu-img=*) QEMU_IMG="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        --*) echo "ERROR: 未知选项: $1" >&2; exit 2 ;;
        *) POSITIONAL+=("$1") ;;
    esac
    shift
done

if (( EUID == 0 )); then
    echo "ERROR: 请使用实际 VM 用户运行，不要用 root" >&2
    exit 1
fi
if (( OPTIMIZE_ALL == 1 && ${#POSITIONAL[@]} > 0 )); then
    echo "ERROR: --all 不能与实例号同时使用" >&2
    exit 2
fi
if (( OPTIMIZE_ALL == 0 && ${#POSITIONAL[@]} == 0 )); then
    usage >&2
    exit 2
fi
for command_name in awk chgrp du flock lsof numfmt python3 readlink sort stat sync; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "ERROR: 缺少必需命令: $command_name" >&2
        exit 1
    }
done
if [[ "$QEMU_IMG" != */* ]]; then
    QEMU_IMG="$(command -v -- "$QEMU_IMG" 2>/dev/null || true)"
fi
[[ -n "$QEMU_IMG" && -x "$QEMU_IMG" ]] || {
    echo "ERROR: 找不到可执行 qemu-img: ${QEMU_IMG:-empty}" >&2
    exit 1
}
QEMU_IMG="$(readlink -e -- "$QEMU_IMG")"
METADATA_HELPER="$SCRIPT_DIR/lib/qcow2-metadata.py"
[[ -f "$METADATA_HELPER" ]] || {
    echo "ERROR: 缺少 qcow2 metadata 验证器" >&2
    exit 1
}
[[ -d "$VMS_DIR" && ! -L "$VMS_DIR" ]] || {
    echo "ERROR: VMS_DIR 必须是真实目录: $VMS_DIR" >&2
    exit 1
}
VMS_DIR="$(readlink -e -- "$VMS_DIR")"

INSTANCES=()
if (( OPTIMIZE_ALL )); then
    shopt -s nullglob
    for disk in "$VMS_DIR"/[1-9]*/disk.qcow2; do
        instance="$(basename "$(dirname "$disk")")"
        [[ "$instance" =~ ^[1-9][0-9]{0,9}$ ]] && INSTANCES+=("$instance")
    done
    shopt -u nullglob
else
    INSTANCES=("${POSITIONAL[@]}")
fi
(( ${#INSTANCES[@]} > 0 )) || {
    echo "ERROR: 没有发现可优化的实例盘" >&2
    exit 1
}
mapfile -t INSTANCES < <(printf '%s\n' "${INSTANCES[@]}" | sort -n -u)
for instance in "${INSTANCES[@]}"; do
    [[ "$instance" =~ ^[1-9][0-9]{0,9}$ ]] || {
        echo "ERROR: 实例号非法: $instance" >&2
        exit 2
    }
done

ACTIVE_DISK=""
ACTIVE_TEMP=""
ACTIVE_BACKUP=""
ACTIVE_NEW_INODE=""
ACTIVE_LOCK_FD=""

cleanup_active_transaction() {
    local status=$? disk_inode="" backup_inode=""
    trap - EXIT HUP INT TERM
    set +e
    if [[ -n "$ACTIVE_BACKUP" && -f "$ACTIVE_BACKUP" && \
          ! -L "$ACTIVE_BACKUP" ]]; then
        backup_inode="$(stat -c '%d:%i' -- "$ACTIVE_BACKUP" 2>/dev/null)"
        if [[ -f "$ACTIVE_DISK" && ! -L "$ACTIVE_DISK" ]]; then
            disk_inode="$(stat -c '%d:%i' -- "$ACTIVE_DISK" 2>/dev/null)"
        fi
        if [[ -n "$ACTIVE_NEW_INODE" && \
              "$disk_inode" == "$ACTIVE_NEW_INODE" ]]; then
            echo "WARN: 优化事务中断，正在恢复原镜像: $ACTIVE_DISK" >&2
            mv -fT -- "$ACTIVE_BACKUP" "$ACTIVE_DISK"
            sync -f -- "$(dirname "$ACTIVE_DISK")" 2>/dev/null || true
        elif [[ -n "$disk_inode" && "$disk_inode" == "$backup_inode" ]]; then
            # rename 尚未发生，backup 只是源 inode 的临时附加链接。
            rm -- "$ACTIVE_BACKUP"
        else
            echo "WARN: 目标 inode 已改变，不自动覆盖；原盘保留在 $ACTIVE_BACKUP" >&2
        fi
    fi
    if [[ -n "$ACTIVE_TEMP" && -f "$ACTIVE_TEMP" ]]; then
        rm -- "$ACTIVE_TEMP"
    fi
    if [[ -n "$ACTIVE_LOCK_FD" ]]; then
        flock -u "$ACTIVE_LOCK_FD" 2>/dev/null || true
        eval "exec ${ACTIVE_LOCK_FD}>&-"
    fi
    exit "$status"
}
trap cleanup_active_transaction EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

extent_count() {
    local image="$1" last
    command -v filefrag >/dev/null 2>&1 || { printf 'unknown\n'; return; }
    last="$(filefrag -v "$image" 2>/dev/null | tail -n 1 || true)"
    if [[ "$last" =~ :[[:space:]]+([0-9]+)[[:space:]]+extents?[[:space:]]+found$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf 'unknown\n'
    fi
}

validate_target_layout() {
    local image="$1" expected_size="$2" expected_backing="$3" info
    info="$("$QEMU_IMG" info --output=json "$image")" || return 1
    printf '%s' "$info" | python3 "$METADATA_HELPER" validate - \
        "$expected_size" "${expected_backing:--}" "$VMATE_QCOW2_CLUSTER_SIZE"
}

optimize_instance() {
    local instance="$1" vm_dir disk lock_path source_info source_fields
    local source_fingerprint virtual_size backing_recorded backing_resolved
    local backing_format allocated available required reserve old_extents new_extents
    local temp backup timestamp lock_fd
    local -a fields=() convert_args=()

    vm_dir="$VMS_DIR/$instance"
    disk="$vm_dir/disk.qcow2"
    [[ -d "$vm_dir" && ! -L "$vm_dir" && -f "$disk" && ! -L "$disk" ]] || {
        echo "ERROR: 实例 $instance 缺少真实普通 disk.qcow2" >&2
        return 1
    }
    [[ "$(stat -c '%u' -- "$vm_dir")" == "$EUID" && \
       "$(stat -c '%u' -- "$disk")" == "$EUID" && \
       "$(stat -c '%h' -- "$disk")" == 1 ]] || {
        echo "ERROR: 实例 $instance 目录/镜像 owner 不属于当前用户，或镜像存在外部硬链接" >&2
        return 1
    }
    lock_path="$(sv_instance_lock_path "$instance")" || {
        echo "ERROR: 无法定位实例 $instance 生命周期锁" >&2
        return 1
    }
    exec {lock_fd}>"$lock_path"
    ACTIVE_LOCK_FD="$lock_fd"
    if ! flock -n "$lock_fd"; then
        echo "ERROR: 实例 $instance 正在启动、运行、停止或执行其它离线操作" >&2
        return 1
    fi
    if sv_qemu_instance_pids "$instance" >/dev/null 2>&1; then
        echo "ERROR: 实例 $instance 的 QEMU 仍在运行" >&2
        return 1
    fi
    if [[ -n "$(lsof "$disk" 2>/dev/null || true)" ]]; then
        echo "ERROR: 实例 $instance 系统盘仍被进程打开" >&2
        return 1
    fi

    echo ""
    echo "==> 优化实例 $instance: $disk"
    "$QEMU_IMG" check -q -f qcow2 "$disk"
    source_info="$("$QEMU_IMG" info --output=json "$disk")"
    source_fields="$(printf '%s' "$source_info" | \
        python3 "$METADATA_HELPER" inspect -)"
    mapfile -t fields <<<"$source_fields"
    (( ${#fields[@]} == 4 )) || {
        echo "ERROR: 实例 $instance 镜像元数据不完整" >&2
        return 1
    }
    virtual_size="${fields[0]}"
    backing_recorded="${fields[1]}"
    backing_resolved="${fields[2]}"
    backing_format="${fields[3]}"
    [[ "$backing_recorded" == "__VMATE_QCOW2_NONE__" ]] && backing_recorded=""
    [[ "$backing_resolved" == "__VMATE_QCOW2_NONE__" ]] && backing_resolved=""
    [[ "$backing_format" == "__VMATE_QCOW2_NONE__" ]] && backing_format=""
    source_fingerprint="$(stat -c '%d:%i:%s:%y' -- "$disk")"
    allocated="$(du -B1 "$disk" | awk 'NR == 1 {print $1}')"
    available="$((
        $(stat -f -c '%S' -- "$vm_dir") * $(stat -f -c '%a' -- "$vm_dir")
    ))"
    reserve=$((16 * 1024 * 1024 * 1024))
    required=$((allocated + allocated / 5 + reserve))
    if (( available < required )); then
        echo "ERROR: 实例 $instance 优化空间不足" >&2
        echo "       可用=$available bytes，需要至少=$required bytes" >&2
        return 1
    fi
    old_extents="$(extent_count "$disk")"
    echo ">> 布局:       cluster=${VMATE_QCOW2_CLUSTER_SIZE}, extended_l2=on, metadata preallocation"
    echo ">> 空间门禁: $(numfmt --to=iec --suffix=B "$required") / 可用 $(numfmt --to=iec --suffix=B "$available")"
    echo ">> 优化前:     $(numfmt --to=iec --suffix=B "$allocated"), extents=$old_extents"

    temp="$(mktemp -- "$vm_dir/.disk.qcow2.optimize.XXXXXX")"
    ACTIVE_DISK="$disk"
    ACTIVE_TEMP="$temp"
    convert_args=(convert -p -f qcow2 -O qcow2 -t none \
        -o "$VMATE_QCOW2_CREATE_OPTIONS")
    if [[ -n "$backing_recorded" ]]; then
        [[ "$backing_format" == qcow2 && -f "$backing_resolved" ]] || {
            echo "ERROR: 实例 $instance backing 不完整" >&2
            return 1
        }
        convert_args+=(-b "$backing_recorded" -F qcow2)
    fi
    convert_args+=("$(basename "$disk")" "$(basename "$temp")")
    (cd "$vm_dir"; "$QEMU_IMG" "${convert_args[@]}")
    chmod --reference="$disk" -- "$temp"
    chgrp --reference="$disk" -- "$temp"
    sync -f -- "$temp"
    "$QEMU_IMG" check -q -f qcow2 "$temp"
    validate_target_layout "$temp" "$virtual_size" "$backing_resolved"
    "$QEMU_IMG" compare -p -f qcow2 -F qcow2 "$disk" "$temp"
    [[ "$(stat -c '%d:%i:%s:%y' -- "$disk")" == "$source_fingerprint" ]] || {
        echo "ERROR: 实例 $instance 源盘在转换期间发生变化" >&2
        return 1
    }

    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup="${disk}.preopt-${timestamp}-$$"
    [[ ! -e "$backup" && ! -L "$backup" ]] || {
        echo "ERROR: 回滚备份路径已存在: $backup" >&2
        return 1
    }
    ACTIVE_BACKUP="$backup"
    ACTIVE_NEW_INODE="$(stat -c '%d:%i' -- "$temp")"
    ln -- "$disk" "$backup"
    mv -fT -- "$temp" "$disk"
    ACTIVE_TEMP=""
    sync -f -- "$vm_dir"
    "$QEMU_IMG" check -q -f qcow2 "$disk"
    validate_target_layout "$disk" "$virtual_size" "$backing_resolved"

    allocated="$(du -B1 "$disk" | awk 'NR == 1 {print $1}')"
    new_extents="$(extent_count "$disk")"
    if (( KEEP_BACKUP )); then
        echo ">> 回滚备份: $backup"
    else
        rm -- "$backup"
        ACTIVE_BACKUP=""
        sync -f -- "$vm_dir"
    fi
    echo ">> 优化后:     $(numfmt --to=iec --suffix=B "$allocated"), extents=$new_extents"
    echo ">> 实例 $instance: 结构检查与逻辑内容对比均通过"

    ACTIVE_DISK=""
    ACTIVE_TEMP=""
    ACTIVE_BACKUP=""
    ACTIVE_NEW_INODE=""
    flock -u "$lock_fd"
    eval "exec ${lock_fd}>&-"
    ACTIVE_LOCK_FD=""
}

for instance in "${INSTANCES[@]}"; do
    optimize_instance "$instance"
done

trap - EXIT HUP INT TERM
echo ""
echo "全部 qcow2 优化完成: ${INSTANCES[*]}"

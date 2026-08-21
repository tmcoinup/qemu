#!/usr/bin/env bash
# create-disk.sh — 创建 VM 主盘 qcow2。
#
# 默认行为保留历史兼容：
#   $VM_BASE_DIR/win10-base.qcow2 存在 → 复制该默认 base
#   不存在                              → 建空 qcow2（用于从 ISO 装 Windows）
# 多基础镜像必须用 --base-name NAME 精确选择。
#
# 强制空盘: ./deploy/scripts/create-disk.sh <vm_id> --blank
# 强制从指定 base: ./deploy/scripts/create-disk.sh <vm_id> --from-base --base-name NAME
# V-11 式增量盘: ./deploy/scripts/create-disk.sh <vm_id> --from-base --base-name NAME --linked
# 或使用和 V-11 一致的明确路径：--base /path/NAME.qcow2
#
# 空盘容量优先取 SIZE_BYTES，其次取显式 CLI GB，再其次读取
# vm.conf 的 SSD_SIZE_BYTES；旧配置没有容量字段时仍回退 512 GB。
#
# 用法:
#   ./deploy/scripts/create-disk.sh <vm_id>            # 默认从 base 复制
#   ./deploy/scripts/create-disk.sh <vm_id> --blank    # 强制空盘
#   ./deploy/scripts/create-disk.sh <vm_id> --from-base --base-name win10-ltsc-v1
#   ./deploy/scripts/create-disk.sh <vm_id> 1024       # 空盘 1TB
#   SIZE_BYTES=123456 ./deploy/scripts/create-disk.sh 1 # 精确字节数
#
# 环境变量:
#   VM_ROOT/VMS_DIR  /home/ubuntu/images/vms
#   VM_INSTANCES_DIR $VM_ROOT
#   VM_BASE_DIR      $VM_ROOT/_base
#   SIZE_BYTES       精确字节数（覆盖 CLI 的 GB 参数）

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/disk-headroom.sh
source "$here/lib/disk-headroom.sh"
vm_storage_init

usage() {
    cat <<'EOF'
usage: ./deploy/scripts/create-disk.sh VM_ID [SIZE_GB] [options]

Options:
  --from-base          Clone a standalone base; fail if it is missing
  --base-name NAME     Select the managed base name (default: win10-base)
  --base IMAGE         Select an exact standalone qcow2 path
  --linked             Create a small V-11-style qcow2 overlay (base inode is
                       pinned inside the VM directory)
  --full-copy          Create an independent standalone copy (historical default
                       for direct create-disk callers)
  --blank              Create an empty disk; cannot use --base/--base-name
  -h, --help           Show this help
EOF
}

VM_ID=""
SIZE_GB=512
SIZE_GB_SET=0
FORCE_BLANK=0
REQUIRE_BASE=0
BASE_NAME=win10-base
BASE_NAME_SET=0
BASE_PATH=""
BASE_PATH_SET=0
CLONE_MODE=copy
CLONE_MODE_SET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --blank) FORCE_BLANK=1; shift ;;
        --from-base|--require-base) REQUIRE_BASE=1; shift ;;
        --base-name)
            (($# >= 2)) || { echo "--base-name 需要名称" >&2; exit 2; }
            ((BASE_NAME_SET == 0)) || { echo "--base-name 只能指定一次" >&2; exit 2; }
            BASE_NAME=$2
            BASE_NAME_SET=1
            shift 2
            ;;
        --base-name=*)
            ((BASE_NAME_SET == 0)) || { echo "--base-name 只能指定一次" >&2; exit 2; }
            BASE_NAME=${1#*=}
            BASE_NAME_SET=1
            shift
            ;;
        --base)
            (($# >= 2)) || { echo "--base 需要 qcow2 路径" >&2; exit 2; }
            ((BASE_PATH_SET == 0)) || { echo "--base 只能指定一次" >&2; exit 2; }
            BASE_PATH=$2
            BASE_PATH_SET=1
            shift 2
            ;;
        --base=*)
            ((BASE_PATH_SET == 0)) || { echo "--base 只能指定一次" >&2; exit 2; }
            BASE_PATH=${1#*=}
            BASE_PATH_SET=1
            shift
            ;;
        --linked)
            ((CLONE_MODE_SET == 0)) || {
                echo "--linked/--full-copy 只能指定一次" >&2
                exit 2
            }
            CLONE_MODE=linked
            CLONE_MODE_SET=1
            shift
            ;;
        --full-copy)
            ((CLONE_MODE_SET == 0)) || {
                echo "--linked/--full-copy 只能指定一次" >&2
                exit 2
            }
            CLONE_MODE=copy
            CLONE_MODE_SET=1
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                if [[ -z "$VM_ID" ]]; then
                    VM_ID="$1"
                elif [[ $SIZE_GB_SET -eq 0 ]]; then
                    SIZE_GB="$1"
                    SIZE_GB_SET=1
                else
                    echo "too many positional args: $1" >&2
                    exit 2
                fi
                shift
            else
                echo "unknown arg: $1" >&2
                exit 2
            fi
            ;;
    esac
done
if [[ -z "$VM_ID" || ! "$VM_ID" =~ ^[1-9][0-9]*$ ]]; then
    usage >&2
    exit 2
fi
vm_storage_require_namespace_ready "$VM_ID"
vm_storage_validate_base_name "$BASE_NAME"
((BASE_NAME_SET == 0 || BASE_PATH_SET == 0)) || {
    echo "--base 与 --base-name 不能同时使用" >&2
    exit 2
}
if ((FORCE_BLANK && REQUIRE_BASE)); then
    echo "--blank 与 --from-base 不能同时使用" >&2
    exit 2
fi
if ((FORCE_BLANK && (BASE_NAME_SET || BASE_PATH_SET))); then
    echo "--blank 与 --base/--base-name 不能同时使用" >&2
    exit 2
fi
if ((FORCE_BLANK && CLONE_MODE_SET)); then
    echo "--blank 与 --linked/--full-copy 不能同时使用" >&2
    exit 2
fi
if [[ ! "$SIZE_GB" =~ ^[1-9][0-9]*$ ]]; then
    echo "size_gb 必须是正整数: $SIZE_GB" >&2
    exit 2
fi
if [[ -n "${SIZE_BYTES:-}" && ! "$SIZE_BYTES" =~ ^[1-9][0-9]*$ ]]; then
    echo "SIZE_BYTES 必须是正整数: $SIZE_BYTES" >&2
    exit 2
fi

: "${QEMU_IMG:=$here/../build/qemu-img}"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img || true)
[[ -x "$QEMU_IMG" ]] || { echo "找不到 qemu-img" >&2; exit 1; }

vm_storage_validate_root_path "$VM_ROOT" "VM root"
mkdir -p "$VM_RUN_DIR"
exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -s "$STORAGE_LOCK_FD"
vm_storage_prepare
vm_storage_prepare_instance "$VM_ID"

# 直接调用 create-disk.sh 时也要尊重随机硬件 profile 的精确
# 厂标容量。只在调用者没有用 SIZE_BYTES/CLI 显式覆盖时读取。
if [[ -z "${SIZE_BYTES:-}" && "$SIZE_GB_SET" == 0 ]]; then
    PROFILE_CONF=$(vm_storage_config_path "$VM_ID")
    if [[ -r "$PROFILE_CONF" ]]; then
        PROFILE_SIZE_BYTES=$(
            unset SSD_SIZE_BYTES
            # shellcheck source=/dev/null
            source "$PROFILE_CONF"
            printf '%s' "${SSD_SIZE_BYTES:-}"
        )
        if [[ -n "$PROFILE_SIZE_BYTES" ]]; then
            [[ "$PROFILE_SIZE_BYTES" =~ ^[1-9][0-9]*$ ]] || {
                echo "vm.conf 中 SSD_SIZE_BYTES 必须是正整数: $PROFILE_SIZE_BYTES" >&2
                exit 2
            }
            SIZE_BYTES=$PROFILE_SIZE_BYTES
        fi
    fi
fi
SIZE="${SIZE_BYTES:-$((SIZE_GB * 1000000000))}"
[[ "$SIZE" =~ ^[1-9][0-9]*$ ]] || {
    echo "请求的磁盘容量必须是正整数: $SIZE" >&2
    exit 2
}

qcow2_virtual_size() {
    local image=$1 info_json jq_bin
    jq_bin=$(command -v jq || true)
    [[ -n "$jq_bin" ]] || {
        echo "[create-disk] 读取 qcow2 容量需要 jq" >&2
        return 1
    }
    info_json=$("$QEMU_IMG" info --output=json -- "$image") || return
    "$jq_bin" -er '
        ."virtual-size" |
        select(type == "number" and . > 0 and floor == .) |
        tostring
    ' <<<"$info_json"
}
DISK_LOCK=$(vm_storage_run_path "$VM_ID" disk.lock)
exec {DISK_LOCK_FD}>"$DISK_LOCK"
if ! flock -n -x "$DISK_LOCK_FD"; then
    echo "[create-disk] vm${VM_ID} 的磁盘正在被创建或删除" >&2
    exit 1
fi
TARGET=$(vm_storage_disk_path "$VM_ID")
if ((BASE_PATH_SET)); then
    [[ "$BASE_PATH" == /* && "$BASE_PATH" != / &&
       "${BASE_PATH,,}" == *.qcow2 ]] || {
        echo "[create-disk] --base 必须是绝对 .qcow2 路径" >&2
        exit 2
    }
    [[ -f "$BASE_PATH" && ! -L "$BASE_PATH" ]] || {
        echo "[create-disk] --base 必须是普通非符号链接文件: $BASE_PATH" >&2
        exit 1
    }
    BASE=$(realpath -e -- "$BASE_PATH") || exit 1
    BASE_NAME=$(basename -- "$BASE")
    BASE_NAME=${BASE_NAME%.qcow2}
    vm_storage_validate_base_name "$BASE_NAME" || exit 2
else
    BASE=$(vm_storage_base_path "$BASE_NAME")
fi

if [[ -e "$TARGET" || -L "$TARGET" ]]; then
    echo "⚠️  $TARGET 已存在。删除请 ./deploy/scripts/delete-vm.sh ${VM_ID} -y" >&2
    exit 1
fi
if [[ -L "$BASE" && ! -e "$BASE" && $FORCE_BLANK -eq 0 ]]; then
    echo "[create-disk] base 是失效符号链接，拒绝退回空盘: $BASE" >&2
    exit 1
fi
if ((REQUIRE_BASE)) && [[ ! -f "$BASE" ]]; then
    echo "[create-disk] 要求从公共 base 创建，但文件不存在: $BASE" >&2
    exit 1
fi

mkdir -p "$(dirname "$TARGET")"
disk_headroom_guard "$TARGET"
TARGET_TMP="$(dirname "$TARGET")/.$(basename "$TARGET").partial.$$.$RANDOM"
BASE_PIN=""
BASE_PIN_TMP=""
BASE_PIN_CREATED=0
BASE_PIN_CREATED_ID=""
cleanup_create_disk() {
    rm -f -- "$TARGET_TMP"
    [[ -z "$BASE_PIN_TMP" ]] || rm -f -- "$BASE_PIN_TMP"
    if ((BASE_PIN_CREATED)) && [[ -n "$BASE_PIN" && -f "$BASE_PIN" &&
            ! -L "$BASE_PIN" && ! -e "$TARGET" && ! -L "$TARGET" &&
            "$(stat -Lc '%d:%i' -- "$BASE_PIN")" == "$BASE_PIN_CREATED_ID" ]]; then
        rm -f -- "$BASE_PIN"
    fi
}
trap cleanup_create_disk EXIT

publish_target() {
    if [[ -e "$TARGET" || -L "$TARGET" ]]; then
        echo "[create-disk] 发布前目标已出现，拒绝覆盖: $TARGET" >&2
        return 1
    fi
    mv -T -- "$TARGET_TMP" "$TARGET"
    trap - EXIT
}

# Path A：base 存在且没显式 --blank → V-11 式增量盘或独立完整复制。
if [[ -f "$BASE" && $FORCE_BLANK -eq 0 ]]; then
    if ! vm_storage_read_qcow2_metadata "$QEMU_IMG" "$BASE"; then
        echo "[create-disk] base 元数据无效，未创建 VM 磁盘: $BASE" >&2
        exit 1
    fi
    if [[ -n "$VM_STORAGE_QCOW2_BACKING" ||
          -n "$VM_STORAGE_QCOW2_DATA_FILE" ]]; then
        echo "[create-disk] base 必须是 standalone qcow2，不能有 backing/data-file" >&2
        echo "  base:    $BASE" >&2
        echo "  backing: $VM_STORAGE_QCOW2_BACKING" >&2
        echo "  data:    $VM_STORAGE_QCOW2_DATA_FILE" >&2
        exit 1
    fi
    BASE_SIZE=$(qcow2_virtual_size "$BASE") || {
        echo "[create-disk] 无法读取 baseline 虚拟容量: $BASE" >&2
        exit 1
    }
    if (( SIZE < BASE_SIZE )); then
        echo "[create-disk] profile 容量 ${SIZE} 字节小于 baseline ${BASE_SIZE} 字节，拒绝安全性不明的缩容" >&2
        echo "[create-disk] 请使用 --blank 重新安装，或准备不大于 profile 容量的 baseline" >&2
        exit 1
    fi
    "$QEMU_IMG" check -q "$BASE"

    if [[ "$CLONE_MODE" == linked ]]; then
        BASE_PIN=$(vm_storage_instance_base_pin_path "$VM_ID") || exit 1
        [[ ! -e "$BASE_PIN" && ! -L "$BASE_PIN" ]] || {
            echo "[create-disk] 实例内母盘 pin 已存在，拒绝覆盖: $BASE_PIN" >&2
            exit 1
        }
        BASE_PIN_TMP="$(dirname "$BASE_PIN")/.$(basename "$BASE_PIN").partial.$$.$RANDOM"
        if ! ln -- "$BASE" "$BASE_PIN_TMP"; then
            echo "[create-disk] 无法建立 V-11 式母盘 hard-link pin" >&2
            echo "  base: $BASE" >&2
            echo "  VM:   $(dirname "$BASE_PIN")" >&2
            echo "  基础镜像与 VM 必须位于支持 hard link 的同一文件系统；" >&2
            echo "  需要完整独立盘时显式使用 --full-copy。" >&2
            exit 1
        fi
        [[ -f "$BASE_PIN_TMP" && ! -L "$BASE_PIN_TMP" &&
           "$BASE_PIN_TMP" -ef "$BASE" ]] || {
            echo "[create-disk] 母盘 pin 未固定到所选 base inode" >&2
            exit 1
        }
        mv -T -- "$BASE_PIN_TMP" "$BASE_PIN"
        BASE_PIN_TMP=""
        BASE_PIN_CREATED_ID=$(stat -Lc '%d:%i' -- "$BASE_PIN")
        BASE_PIN_CREATED=1

        echo "[create-disk] 从 baseline '$BASE_NAME' 创建 V-11 式增量盘"
        echo "  base: $BASE"
        echo "  pin:  $BASE_PIN"
        echo "  disk: $TARGET"
        (
            cd -- "$(dirname "$TARGET_TMP")"
            "$QEMU_IMG" create -q -f qcow2 -F qcow2 \
                -b "$(basename "$BASE_PIN")" "$(basename "$TARGET_TMP")"
        )
        if (( SIZE > BASE_SIZE )); then
            echo "[create-disk] 扩展增量盘虚拟容量：${BASE_SIZE} → ${SIZE} 字节"
            "$QEMU_IMG" resize "$TARGET_TMP" "$SIZE"
        fi
        "$QEMU_IMG" check -q "$TARGET_TMP"
        if ! vm_storage_read_qcow2_metadata "$QEMU_IMG" "$TARGET_TMP" ||
                [[ "$VM_STORAGE_QCOW2_BACKING" != "$(basename "$BASE_PIN")" ||
                   -n "$VM_STORAGE_QCOW2_DATA_FILE" ]]; then
            echo "[create-disk] 增量盘 backing 元数据不符合实例内相对 pin 合同" >&2
            exit 1
        fi
        RESOLVED_BACKING=$(vm_storage_resolved_backing_path "$TARGET_TMP") || exit 1
        [[ "$RESOLVED_BACKING" == "$BASE_PIN" &&
           -f "$BASE_PIN" && ! -L "$BASE_PIN" && "$BASE_PIN" -ef "$BASE" ]] || {
            echo "[create-disk] 增量盘没有绑定到所选母盘 pin" >&2
            echo "  expected: $BASE_PIN" >&2
            echo "  actual:   ${RESOLVED_BACKING:-<missing>}" >&2
            exit 1
        }
        TARGET_SIZE=$(qcow2_virtual_size "$TARGET_TMP") || {
            echo "[create-disk] 无法校验增量盘虚拟容量" >&2
            exit 1
        }
        if (( TARGET_SIZE != SIZE )); then
            echo "[create-disk] 增量盘容量校验失败: ${TARGET_SIZE} != ${SIZE}" >&2
            exit 1
        fi
        publish_target
        BASE_PIN_CREATED=0
        if ! "$QEMU_IMG" info "$TARGET" | sed -n '1,10p'; then
            echo "[create-disk] 警告：增量盘已发布，但最终 info 展示失败: $TARGET" >&2
        fi
        echo
        echo "✅ 已创建增量盘；disk.qcow2 只保存 VM 写入，.base.qcow2 固定旧母盘 inode。"
        echo "   更新母盘后，已有 VM 不变；只有新克隆使用新母盘。"
        echo "   下一步: ./deploy/scripts/start-vm.sh $VM_ID"
        exit 0
    fi

    echo "[create-disk] 从 baseline '$BASE_NAME' 复制：$BASE → $TARGET"
    cp --reflink=auto -- "$BASE" "$TARGET_TMP"
    # A shared baseline is commonly made 0444 to prevent accidental edits.
    # The private copy must still be writable for qemu-img resize and the VM.
    chmod u+rw -- "$TARGET_TMP"
    if (( SIZE > BASE_SIZE )); then
        echo "[create-disk] 扩展复制品虚拟容量：${BASE_SIZE} → ${SIZE} 字节"
        "$QEMU_IMG" resize "$TARGET_TMP" "$SIZE"
    fi
    "$QEMU_IMG" check -q "$TARGET_TMP"
    if ! vm_storage_read_qcow2_metadata "$QEMU_IMG" "$TARGET_TMP" ||
            [[ -n "$VM_STORAGE_QCOW2_BACKING" ||
               -n "$VM_STORAGE_QCOW2_DATA_FILE" ]]; then
        echo "[create-disk] 复制结果不是有效 standalone qcow2，拒绝发布" >&2
        exit 1
    fi
    TARGET_SIZE=$(qcow2_virtual_size "$TARGET_TMP") || {
        echo "[create-disk] 无法校验复制品虚拟容量" >&2
        exit 1
    }
    if (( TARGET_SIZE != SIZE )); then
        echo "[create-disk] 复制品容量校验失败: ${TARGET_SIZE} != ${SIZE}" >&2
        exit 1
    fi
    publish_target
    if ! "$QEMU_IMG" info "$TARGET" | sed -n '1,8p'; then
        echo "[create-disk] 警告：磁盘已发布，但最终 info 展示失败: $TARGET" >&2
    fi
    echo
    echo "✅ 已从 baseline 创建。下一步:"
    echo "   ./deploy/scripts/start-vm.sh $VM_ID            # 直接进 Windows (driver+service 已就绪)"
    exit 0
fi

# Path B：建空 qcow2 (装 Windows from ISO)
echo "[create-disk] 建空盘：$TARGET"
if (( SIZE % 1000000000 == 0 )); then
    echo "  规格: $((SIZE / 1000000000)) GB (SSD 厂标)  = ${SIZE} 字节"
else
    echo "  规格: ${SIZE} 字节（profile 精确容量）"
fi
"$QEMU_IMG" create -f qcow2 -o cluster_size=64k,preallocation=metadata "$TARGET_TMP" "$SIZE"
"$QEMU_IMG" check -q "$TARGET_TMP"
if ! vm_storage_read_qcow2_metadata "$QEMU_IMG" "$TARGET_TMP" ||
        [[ -n "$VM_STORAGE_QCOW2_BACKING" ||
           -n "$VM_STORAGE_QCOW2_DATA_FILE" ]]; then
    echo "[create-disk] 新建结果不是有效 standalone qcow2，拒绝发布" >&2
    exit 1
fi
TARGET_SIZE=$(qcow2_virtual_size "$TARGET_TMP") || {
    echo "[create-disk] 无法校验新建空盘虚拟容量" >&2
    exit 1
}
if (( TARGET_SIZE != SIZE )); then
    echo "[create-disk] 新建空盘容量校验失败: ${TARGET_SIZE} != ${SIZE}" >&2
    exit 1
fi
publish_target
if ! "$QEMU_IMG" info "$TARGET" | sed -n '1,8p'; then
    echo "[create-disk] 警告：磁盘已发布，但最终 info 展示失败: $TARGET" >&2
fi
echo
echo "✅ 已建空盘。下一步:"
echo "   ./deploy/scripts/start-vm.sh $VM_ID --install   # 默认 ISO $ISO_DIR/win10.iso"

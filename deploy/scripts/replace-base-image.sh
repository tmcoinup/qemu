#!/usr/bin/env bash
# 为已有实例更换基础镜像，同时保留硬件 profile、OVMF/TPM 与 Guest 计算机名称。
#
# 用法：
#   replace-base-image.sh <BASE_QCOW2> <INSTANCE>
#       [--image-root=PATH] [--vms-dir=PATH] [--qemu-img=PATH]
#
# 中文注释：该入口只交换 disk.qcow2 与 .base.qcow2。profile、ovmf-vars.fd、
# swtpm 状态和 VMate metadata 从不进入移动列表；提交前后还会比较硬件文件摘要。

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: 更换基础镜像必须以 root 运行" >&2
    exit 1
fi

CLI_IMAGE_ROOT=""
CLI_VMS_DIR=""
CLI_QEMU_IMG=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image-root=*) CLI_IMAGE_ROOT="${1#*=}" ;;
        --vms-dir=*) CLI_VMS_DIR="${1#*=}" ;;
        --qemu-img=*) CLI_QEMU_IMG="${1#*=}" ;;
        --*) echo "ERROR: 未知 flag: $1" >&2; exit 2 ;;
        *) POSITIONAL+=("$1") ;;
    esac
    shift
done

BASE_ARG="${POSITIONAL[0]:-}"
INSTANCE="${POSITIONAL[1]:-}"
if (( ${#POSITIONAL[@]} != 2 )); then
    echo "usage: $0 <BASE_QCOW2> <INSTANCE> [--vms-dir=PATH] [--qemu-img=PATH]" >&2
    exit 2
fi
[[ "$INSTANCE" =~ ^[1-9][0-9]{0,9}$ ]] || {
    echo "ERROR: INSTANCE 必须是 1..9999999999 的正整数" >&2
    exit 2
}

IMAGE_ROOT="${CLI_IMAGE_ROOT:-${IMAGE_ROOT:-/home/ubuntu/images}}"
IMAGE_ROOT="${IMAGE_ROOT%/}"
[[ -n "$IMAGE_ROOT" ]] || IMAGE_ROOT=/
VMS_DIR="${CLI_VMS_DIR:-${VMS_DIR:-$IMAGE_ROOT/vms}}"
VMS_DIR="${VMS_DIR%/}"
[[ -n "$VMS_DIR" ]] || VMS_DIR=/

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/clone-lifecycle.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/base-image.sh"

# 对持久 TPM 身份目录生成稳定内容摘要；不存在与空目录也必须可区分。
# 中文注释：换镜像不应初始化、迁移或重写 TPM。这里把目录结构与全部普通文件
# 内容纳入提交前后校验，并拒绝符号链接及其它特殊节点，避免“路径没移动”却无法
# 证明 EK/NVRAM 状态保持不变。
replace_tpm_identity_digest() {
    local vm_dir="${1:-}" identity_name identity_path entry
    {
        for identity_name in tpm-state tpm12-state tpm-ca tpm-config; do
            identity_path="$vm_dir/$identity_name"
            if [[ ! -e "$identity_path" && ! -L "$identity_path" ]]; then
                printf 'absent\0%s\0' "$identity_name"
                continue
            fi
            [[ -d "$identity_path" && ! -L "$identity_path" ]] || {
                echo "ERROR: TPM 身份路径必须是真实目录: $identity_path" >&2
                return 1
            }
            while IFS= read -r -d '' entry; do
                [[ ! -L "$entry" && ( -d "$entry" || -f "$entry" ) ]] || {
                    echo "ERROR: TPM 身份目录包含链接或特殊节点: $entry" >&2
                    return 1
                }
            done < <(find -P "$identity_path" -xdev -print0)
            printf 'directory\0%s\0' "$identity_name"
            (
                cd "$identity_path"
                find -P . -xdev -type d -printf 'd\0%P\0' | sort -z
                find -P . -xdev -type f -print0 | sort -z | xargs -0 -r sha256sum --
            )
        done
    } | sha256sum | awk '{print $1}'
}

[[ -n "$BASE_ARG" && -f "$BASE_ARG" && ! -L "$BASE_ARG" ]] || {
    echo "ERROR: 新基础镜像必须是真实普通文件: ${BASE_ARG:-empty}" >&2
    exit 1
}
BASE_FILE="$(readlink -e -- "$BASE_ARG")" || {
    echo "ERROR: 无法解析新基础镜像: $BASE_ARG" >&2
    exit 1
}

QEMU_IMG="${CLI_QEMU_IMG:-${QEMU_IMG:-$REPO_ROOT/build/qemu-img}}"
if [[ "$QEMU_IMG" != */* ]]; then
    QEMU_IMG="$(command -v -- "$QEMU_IMG" 2>/dev/null || true)"
fi
[[ -n "$QEMU_IMG" && -f "$QEMU_IMG" && -x "$QEMU_IMG" ]] || {
    echo "ERROR: 找不到指定的 qemu-img" >&2
    exit 1
}
QEMU_IMG="$(readlink -e -- "$QEMU_IMG")"

ORIG_USER="${SUDO_USER:-}"
if [[ -z "$ORIG_USER" && -n "${PKEXEC_UID:-}" ]]; then
    ORIG_USER="$(id -nu "$PKEXEC_UID" 2>/dev/null || true)"
fi
[[ -n "$ORIG_USER" ]] || {
    echo "ERROR: 无法识别实际 VM 用户；请由该用户通过 sudo 调用" >&2
    exit 1
}
ORIG_UID="$(id -u "$ORIG_USER" 2>/dev/null)" || {
    echo "ERROR: 无法解析 VM 用户: $ORIG_USER" >&2
    exit 1
}
ORIG_GID="$(id -g "$ORIG_USER" 2>/dev/null)" || {
    echo "ERROR: 无法解析 VM 用户组: $ORIG_USER" >&2
    exit 1
}
[[ "$ORIG_UID" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: 更换镜像不能使用 root 作为最终 VM 用户" >&2
    exit 1
}

# portable 传输副本沿用 clone 的稳定 FD 密封流程；此后所有 backing 都引用同一 inode。
BASE_PUBLISH_HELPER="$SCRIPT_DIR/lib/seal-base-publish.py"
base_image_adopt_portable_copy "$QEMU_IMG" "$BASE_PUBLISH_HELPER" "$BASE_FILE"
if [[ -n "${BASE_IMAGE_ADOPTED_FROM_UID:-}" &&
      "$BASE_IMAGE_ADOPTED_FROM_UID" != "$ORIG_UID" ]]; then
    echo "ERROR: 基础镜像导入用户与目标 VM 用户不一致" >&2
    exit 1
fi
BASE_FINGERPRINT="$(stat -c '%d:%i:%s:%y' -- "$BASE_FILE")"
BASE_BYTES="$BASE_IMAGE_VIRTUAL_SIZE"

VM_DIR="$VMS_DIR/$INSTANCE"
DISK="$VM_DIR/disk.qcow2"
PROFILE="$VM_DIR/profile"
OVMF_VARS="$VM_DIR/ovmf-vars.fd"
BASE_PIN="$VM_DIR/.base.qcow2"
GUEST_NAME_HELPER="$SCRIPT_DIR/host-preserve-guest-name.sh"

[[ -d "$VMS_DIR" && ! -L "$VMS_DIR" &&
   "$(stat -c '%u' -- "$VMS_DIR")" == "$ORIG_UID" ]] || {
    echo "ERROR: VMS_DIR 必须是最终 VM 用户拥有的真实目录: $VMS_DIR" >&2
    exit 1
}
[[ -d "$VM_DIR" && ! -L "$VM_DIR" &&
   "$(stat -c '%u' -- "$VM_DIR")" == "$ORIG_UID" ]] || {
    echo "ERROR: VM_DIR 必须是最终 VM 用户拥有的真实目录: $VM_DIR" >&2
    exit 1
}
for required in "$DISK" "$PROFILE" "$OVMF_VARS"; do
    [[ -f "$required" && ! -L "$required" ]] || {
        echo "ERROR: 保持身份所需文件缺失或不是普通文件: $required" >&2
        exit 1
    }
done
[[ -x "$GUEST_NAME_HELPER" && ! -L "$GUEST_NAME_HELPER" ]] || {
    echo "ERROR: 缺少 Guest 计算机名称保持工具: $GUEST_NAME_HELPER" >&2
    exit 1
}
if [[ -f "$BASE_PIN" && "$BASE_PIN" -ef "$BASE_FILE" ]]; then
    echo "ERROR: 目标镜像与当前实例基础镜像相同" >&2
    exit 1
fi

# profile 是数据而不是 shell 输入；只接受唯一、未加引号的十进制容量行。
mapfile -t PROFILE_SIZE_LINES < <(sed -n '/^BOOT_STORAGE_SIZE_BYTES=/p' "$PROFILE")
(( ${#PROFILE_SIZE_LINES[@]} == 1 )) || {
    echo "ERROR: profile 必须包含唯一 BOOT_STORAGE_SIZE_BYTES" >&2
    exit 1
}
PROFILE_BYTES="${PROFILE_SIZE_LINES[0]#BOOT_STORAGE_SIZE_BYTES=}"
[[ "$PROFILE_BYTES" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: profile 的 BOOT_STORAGE_SIZE_BYTES 非法" >&2
    exit 1
}
[[ "$PROFILE_BYTES" == "$BASE_BYTES" ]] || {
    echo "ERROR: 新镜像容量 $BASE_BYTES 与现有硬件启动盘容量 $PROFILE_BYTES 不一致" >&2
    echo "       为保持磁盘型号、序列号及完整硬件身份，已拒绝更换" >&2
    exit 1
}

command -v flock >/dev/null 2>&1 || {
    echo "ERROR: 更换镜像需要 util-linux 的 flock" >&2
    exit 1
}
INSTANCE_LOCK="$(clone_lifecycle_user_lock_path \
    "$ORIG_USER" "$SCRIPT_DIR/lib/sv-instance-lock.sh" "$INSTANCE")" || {
    echo "ERROR: 无法建立实例生命周期锁" >&2
    exit 1
}
exec 8<"$INSTANCE_LOCK"
if ! flock -n 8; then
    echo "ERROR: instance $INSTANCE 正在启动、运行、停止或执行其它维护操作" >&2
    exit 1
fi

PROFILE_BEFORE="$(sha256sum -- "$PROFILE" | awk '{print $1}')"
OVMF_BEFORE="$(sha256sum -- "$OVMF_VARS" | awk '{print $1}')"
PROFILE_INODE_BEFORE="$(stat -c '%d:%i' -- "$PROFILE")"
OVMF_INODE_BEFORE="$(stat -c '%d:%i' -- "$OVMF_VARS")"
TPM_BEFORE="$(replace_tpm_identity_digest "$VM_DIR")" || {
    echo "ERROR: 无法建立现有 TPM 身份摘要，已拒绝更换镜像" >&2
    exit 1
}
DISK_BEFORE="$(stat -c '%d:%i' -- "$DISK")"
PIN_BEFORE=""
if [[ -e "$BASE_PIN" || -L "$BASE_PIN" ]]; then
    [[ -f "$BASE_PIN" && ! -L "$BASE_PIN" ]] || {
        echo "ERROR: 当前 base pin 不是普通文件: $BASE_PIN" >&2
        exit 1
    }
    PIN_BEFORE="$(stat -c '%d:%i' -- "$BASE_PIN")"
fi

# 在创建新 overlay 前先从旧盘读取真实 Guest 名称；失败不会产生任何系统盘副作用。
GUEST_OUTPUT="$("$GUEST_NAME_HELPER" read "$DISK")" || {
    echo "ERROR: 无法读取旧 Guest 计算机名称，原系统盘保持不变" >&2
    exit 1
}
mapfile -t GUEST_NAME_LINES < <(
    sed -n 's/^VMATE_GUEST_NAME=//p' <<<"$GUEST_OUTPUT"
)
(( ${#GUEST_NAME_LINES[@]} == 1 )) || {
    echo "ERROR: Guest 名称工具没有返回唯一结果，原系统盘保持不变" >&2
    exit 1
}
GUEST_NAME="${GUEST_NAME_LINES[0]}"

STAGE="$(mktemp -d -- "$VM_DIR/.image-replace.XXXXXX")"
NEW_DISK="$STAGE/new-disk.qcow2"
NEW_PIN="$STAGE/.base.qcow2"
OLD_DISK="$STAGE/old-disk.qcow2"
OLD_PIN="$STAGE/old-base.qcow2"
OLD_DISK_MOVED=0
OLD_PIN_MOVED=0
NEW_DISK_MOVED=0
NEW_PIN_MOVED=0
NEW_DISK_FINGERPRINT=""
NEW_PIN_FINGERPRINT=""
TRANSACTION_COMMITTED=0

replace_cleanup() {
    local status=$?
    local final_conflict=0
    local rollback_failed=0
    trap - EXIT
    set +e
    if [[ "$TRANSACTION_COMMITTED" != 1 ]]; then
        # 中文注释：只有目标仍是本事务刚放入的 inode 时才允许移除。
        # 若外部进程绕过生命周期锁改写路径，则保留暂存旧盘供人工恢复，绝不误删。
        if [[ "$NEW_DISK_MOVED" == 1 && ( -e "$DISK" || -L "$DISK" ) &&
              ( ! -f "$DISK" || -L "$DISK" ||
                "$(stat -c '%d:%i' -- "$DISK" 2>/dev/null)" != "$NEW_DISK_FINGERPRINT" ) ]]; then
            echo "ERROR: 回滚时发现系统盘路径已被外部替换；旧盘保留在 $OLD_DISK" >&2
            final_conflict=1
        fi
        if [[ "$NEW_PIN_MOVED" == 1 && ( -e "$BASE_PIN" || -L "$BASE_PIN" ) &&
              ( ! -f "$BASE_PIN" || -L "$BASE_PIN" ||
                "$(stat -c '%d:%i' -- "$BASE_PIN" 2>/dev/null)" != "$NEW_PIN_FINGERPRINT" ) ]]; then
            echo "ERROR: 回滚时发现 base pin 路径已被外部替换；旧 pin 保留在 $OLD_PIN" >&2
            final_conflict=1
        fi

        if [[ "$final_conflict" == 0 ]]; then
            if [[ "$NEW_DISK_MOVED" == 1 && ( -e "$DISK" || -L "$DISK" ) ]]; then
                rm -- "$DISK"
            fi
            if [[ "$NEW_PIN_MOVED" == 1 && ( -e "$BASE_PIN" || -L "$BASE_PIN" ) ]]; then
                rm -- "$BASE_PIN"
            fi
            if [[ "$OLD_PIN_MOVED" == 1 ]]; then
                if [[ -f "$OLD_PIN" && ! -L "$OLD_PIN" &&
                      ! -e "$BASE_PIN" && ! -L "$BASE_PIN" ]]; then
                    mv -T -- "$OLD_PIN" "$BASE_PIN" || rollback_failed=1
                else
                    rollback_failed=1
                fi
            fi
            if [[ "$OLD_DISK_MOVED" == 1 ]]; then
                if [[ -f "$OLD_DISK" && ! -L "$OLD_DISK" &&
                      ! -e "$DISK" && ! -L "$DISK" ]]; then
                    mv -T -- "$OLD_DISK" "$DISK" || rollback_failed=1
                else
                    rollback_failed=1
                fi
            fi
        else
            rollback_failed=1
        fi

        for path in "$NEW_DISK" "$NEW_PIN"; do
            [[ ! -e "$path" && ! -L "$path" ]] || rm -- "$path"
        done
        if [[ -e "$OLD_DISK" || -L "$OLD_DISK" || -e "$OLD_PIN" || -L "$OLD_PIN" ]]; then
            echo "ERROR: 自动回滚未能完成；旧系统盘恢复材料已保留在 $STAGE" >&2
            rollback_failed=1
        fi
    else
        # 中文注释：事务已经完整校验并落盘后，暂存旧盘不再是恢复必需品。
        for path in "$NEW_DISK" "$NEW_PIN" "$OLD_DISK" "$OLD_PIN"; do
            [[ ! -e "$path" && ! -L "$path" ]] || rm -- "$path"
        done
    fi
    rmdir -- "$STAGE" 2>/dev/null || true
    flock -u 8 2>/dev/null || true
    exec 8<&-
    if [[ "$rollback_failed" == 1 && "$status" == 0 ]]; then
        status=1
    fi
    exit "$status"
}
trap replace_cleanup EXIT

ln -T -- "$BASE_FILE" "$NEW_PIN"
(
    cd "$STAGE"
    "$QEMU_IMG" create -q -f qcow2 -F qcow2 -b .base.qcow2 \
        "$(basename "$NEW_DISK")"
)
base_image_require_overlay_qcow2 "$QEMU_IMG" "$NEW_DISK" "$NEW_PIN" "$BASE_BYTES"

APPLY_OUTPUT="$("$GUEST_NAME_HELPER" apply "$NEW_DISK" "$GUEST_NAME")" || {
    echo "ERROR: 无法把原 Guest 计算机名称注入新系统盘，原系统盘保持不变" >&2
    exit 1
}
grep -qF "VMATE_GUEST_NAME=$GUEST_NAME" <<<"$APPLY_OUTPUT" || {
    echo "ERROR: 新系统盘没有确认 Guest 计算机名称" >&2
    exit 1
}
base_image_require_overlay_qcow2 "$QEMU_IMG" "$NEW_DISK" "$NEW_PIN" "$BASE_BYTES"
[[ "$(stat -c '%d:%i:%s:%y' -- "$NEW_PIN")" == "$BASE_FINGERPRINT" ]] || {
    echo "ERROR: 新 base pin 在准备期间发生变化" >&2
    exit 1
}
NEW_DISK_FINGERPRINT="$(stat -c '%d:%i' -- "$NEW_DISK")"
NEW_PIN_FINGERPRINT="$(stat -c '%d:%i' -- "$NEW_PIN")"

# Guest 离线处理耗时较长；提交前重新证明旧盘与两个硬件身份文件仍是原对象。
[[ "$(stat -c '%d:%i' -- "$DISK")" == "$DISK_BEFORE" ]] || {
    echo "ERROR: 当前系统盘在更换准备期间被替换" >&2
    exit 1
}
[[ -f "$PROFILE" && ! -L "$PROFILE" && -f "$OVMF_VARS" && ! -L "$OVMF_VARS" &&
   "$(stat -c '%d:%i' -- "$PROFILE")" == "$PROFILE_INODE_BEFORE" &&
   "$(stat -c '%d:%i' -- "$OVMF_VARS")" == "$OVMF_INODE_BEFORE" &&
   "$(sha256sum -- "$PROFILE" | awk '{print $1}')" == "$PROFILE_BEFORE" &&
   "$(sha256sum -- "$OVMF_VARS" | awk '{print $1}')" == "$OVMF_BEFORE" ]] || {
    echo "ERROR: 硬件 profile 或 OVMF NVRAM 在更换准备期间发生变化" >&2
    exit 1
}
[[ "$(replace_tpm_identity_digest "$VM_DIR")" == "$TPM_BEFORE" ]] || {
    echo "ERROR: TPM 身份在更换准备期间发生变化" >&2
    exit 1
}
if [[ -n "$PIN_BEFORE" ]]; then
    [[ "$(stat -c '%d:%i' -- "$BASE_PIN")" == "$PIN_BEFORE" ]] || {
        echo "ERROR: 当前 base pin 在更换准备期间被替换" >&2
        exit 1
    }
fi

mv -T -- "$DISK" "$OLD_DISK"
OLD_DISK_MOVED=1
if [[ -n "$PIN_BEFORE" ]]; then
    mv -T -- "$BASE_PIN" "$OLD_PIN"
    OLD_PIN_MOVED=1
fi
mv -T -- "$NEW_PIN" "$BASE_PIN"
NEW_PIN_MOVED=1
mv -T -- "$NEW_DISK" "$DISK"
NEW_DISK_MOVED=1

chown -- "$ORIG_UID:$ORIG_GID" "$DISK"
chmod 0600 -- "$DISK"
base_image_require_overlay_qcow2 "$QEMU_IMG" "$DISK" "$BASE_PIN" "$BASE_BYTES"
clone_lifecycle_validate_base_pin "$BASE_PIN" "$BASE_FINGERPRINT"
[[ -f "$PROFILE" && ! -L "$PROFILE" && -f "$OVMF_VARS" && ! -L "$OVMF_VARS" &&
   "$(stat -c '%d:%i' -- "$PROFILE")" == "$PROFILE_INODE_BEFORE" &&
   "$(stat -c '%d:%i' -- "$OVMF_VARS")" == "$OVMF_INODE_BEFORE" &&
   "$(sha256sum -- "$PROFILE" | awk '{print $1}')" == "$PROFILE_BEFORE" &&
   "$(sha256sum -- "$OVMF_VARS" | awk '{print $1}')" == "$OVMF_BEFORE" ]] || {
    echo "ERROR: 提交后硬件身份文件摘要不一致，正在回滚系统盘" >&2
    exit 1
}
[[ "$(replace_tpm_identity_digest "$VM_DIR")" == "$TPM_BEFORE" ]] || {
    echo "ERROR: 提交后 TPM 身份摘要不一致，正在回滚系统盘" >&2
    exit 1
}
sync -f "$VM_DIR" 2>/dev/null || sync
TRANSACTION_COMMITTED=1

rm -- "$OLD_DISK"
[[ ! -e "$OLD_PIN" ]] || rm -- "$OLD_PIN"
rmdir -- "$STAGE"
printf 'VMATE_GUEST_NAME=%s\n' "$GUEST_NAME"
echo ">> instance $INSTANCE 基础镜像已更换；profile、OVMF/TPM 与 Guest 计算机名称保持不变"

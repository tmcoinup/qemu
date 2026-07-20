#!/usr/bin/env bash
# clone-from-base 的实例锁、路径门禁和原子发布辅助函数。
#
# clone 本身以 root 执行，但 start-vm/stop-vm 通常以 sudo 的原始用户执行。
# 生命周期锁因此必须由原始用户调用 sv_instance_lock_path 计算和预建，否则 root
# 会落到 /run/user/0（或 /tmp/qemu-stealth-0），与实际 VM 生命周期锁完全分叉。

if [[ "${_CLONE_LIFECYCLE_LOADED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317 # source guard 兼容直接执行诊断。
    return 0 2>/dev/null || exit 0
fi
_CLONE_LIFECYCLE_LOADED=1

# clone 与最终 start 必须使用同一套 patched QEMU 能力契约。检查在原始用户视角
# 运行，避免 root 可以执行二进制、普通 VM 用户却无法执行的假通过。
clone_lifecycle_require_qemu_caps() {
    local original_user="${1:-}" qemu="${2:-}" qemu_img="${3:-}"
    local portability_library="${4:-}"

    [[ -n "$original_user" && -n "$qemu" && -n "$qemu_img" &&
       -f "$portability_library" && ! -L "$portability_library" ]] || {
        echo "ERROR: clone QEMU 能力预检参数非法" >&2
        return 1
    }
    command -v sudo >/dev/null 2>&1 || {
        echo "ERROR: clone 需要 sudo 以最终 VM 用户身份检查 QEMU 能力" >&2
        return 1
    }
    if ! sudo -u "$original_user" -- env \
            QEMU="$qemu" \
            QEMU_IMG="$qemu_img" \
            QEMU_CAP_CHECK=1 \
            SDL=1 \
            FB_SHM=1 \
            STABLE_DISPLAY=0 \
            GPU_DISPLAY=sdl \
            GPU_ZEROCOPY=1 \
            GPU_RENDERNODE= \
            GUEST_NUMLOCK=1 \
            bash "$portability_library"; then
        echo "ERROR: clone 使用的 QEMU 未通过最终启动能力预检" >&2
        return 1
    fi
}

# 以目标用户身份调用现有锁路径函数，并保证锁文件是该用户拥有的 0600 普通文件。
# 调用方仍须以 root 打开固定 FD 并 flock；这里不代替锁，只建立与 start/stop 相同
# 的路径契约。锁目录和已有锁文件的 owner/type 校验全部复用 sv-instance-lock.sh。
clone_lifecycle_user_lock_path() {
    local original_user="${1:-}" lock_library="${2:-}" instance="${3:-}"

    [[ -n "$original_user" && -f "$lock_library" && ! -L "$lock_library" ]] || {
        echo "ERROR: clone 实例锁参数或锁库非法" >&2
        return 1
    }
    [[ "$instance" =~ ^[1-9][0-9]{0,9}$ ]] || {
        echo "ERROR: clone 实例号不满足锁路径约束: ${instance:-empty}" >&2
        return 1
    }
    command -v sudo >/dev/null 2>&1 || {
        echo "ERROR: clone 需要 sudo 以原始用户身份建立实例锁" >&2
        return 1
    }

    # shellcheck disable=SC2016 # 单引号脚本必须在 sudo 降权后的 Bash 中展开 UID。
    sudo -u "$original_user" -- bash -c '
        set -euo pipefail
        lock_library="$1"
        instance="$2"
        source "$lock_library"
        lock_path="$(sv_instance_lock_path "$instance")"

        if [[ ! -e "$lock_path" && ! -L "$lock_path" ]]; then
            # noclobber 处理并发首建；即使另一个 start/clone 抢先创建，后面的
            # owner/type 校验也会决定能否安全复用。
            ( umask 077; set -o noclobber; : >"$lock_path" ) 2>/dev/null || true
        fi
        [[ -f "$lock_path" && ! -L "$lock_path" ]] || {
            echo "ERROR: 实例锁不是普通文件: $lock_path" >&2
            exit 1
        }
        [[ "$(stat -c "%u" -- "$lock_path")" == "$UID" ]] || {
            echo "ERROR: 实例锁不属于目标用户: $lock_path" >&2
            exit 1
        }
        chmod 0600 -- "$lock_path"
        [[ "$(stat -c "%a" -- "$lock_path")" == 600 ]] || {
            echo "ERROR: 无法把实例锁收紧到 0600: $lock_path" >&2
            exit 1
        }
        printf "%s\n" "$lock_path"
    ' clone-lock "$lock_library" "$instance"
}

# 在 mkdir/写入之前拒绝实例路径本身及三个受保护文件的符号链接。`-e` 对
# dangling symlink 返回 false，所以每一项都必须单独检查 `-L`。disk 与 OVMF
# 是本次 clone 的新产物，任何已有目录项都拒绝；profile 允许 UI 预写的普通文件。
clone_lifecycle_validate_instance_paths() {
    local vm_dir="${1:-}" disk="${2:-}" profile="${3:-}" ovmf_vars="${4:-}"

    [[ -n "$vm_dir" && -n "$disk" && -n "$profile" && -n "$ovmf_vars" ]] || {
        echo "ERROR: clone 实例路径不完整" >&2
        return 1
    }
    if [[ -L "$vm_dir" ]]; then
        echo "ERROR: VM_DIR 不能是符号链接（含 dangling）: $vm_dir" >&2
        return 1
    fi
    if [[ -e "$vm_dir" && ! -d "$vm_dir" ]]; then
        echo "ERROR: VM_DIR 已存在但不是目录: $vm_dir" >&2
        return 1
    fi
    if [[ -L "$disk" ]]; then
        echo "ERROR: disk.qcow2 不能是符号链接（含 dangling）: $disk" >&2
        return 1
    fi
    if [[ -e "$disk" ]]; then
        echo "ERROR: disk.qcow2 已存在，拒绝覆盖: $disk" >&2
        return 1
    fi
    if [[ -L "$profile" ]]; then
        echo "ERROR: profile 不能是符号链接（含 dangling）: $profile" >&2
        return 1
    fi
    if [[ -e "$profile" && ! -f "$profile" ]]; then
        echo "ERROR: profile 已存在但不是普通文件: $profile" >&2
        return 1
    fi
    if [[ -L "$ovmf_vars" ]]; then
        echo "ERROR: ovmf-vars.fd 不能是符号链接（含 dangling）: $ovmf_vars" >&2
        return 1
    fi
    if [[ -e "$ovmf_vars" ]]; then
        echo "ERROR: ovmf-vars.fd 已存在，拒绝覆盖: $ovmf_vars" >&2
        return 1
    fi
}

# 建立单一用户拥有的 VMS 根目录，并原子创建实例叶子。已有实例目录只允许其
# owner 继续使用，避免不同 UID 对同一磁盘路径拿到两把互不相干的 per-user 锁。
# 目录在任何 staging 文件落地前收紧到 0700；已有 profile 可以由 UI 以 root
# 预写，但必须是唯一目录项的普通文件，成功提交时再精确归还给最终 VM 用户。
clone_lifecycle_prepare_instance_dir() {
    local original_user="${1:-}" original_uid="${2:-}" original_gid="${3:-}"
    local vms_dir="${4:-}" vm_dir="${5:-}" disk="${6:-}"
    local profile="${7:-}" ovmf_vars="${8:-}"

    CLONE_LIFECYCLE_VM_DIR_CREATED=0
    [[ -n "$original_user" &&
       "$original_uid" =~ ^[1-9][0-9]*$ &&
       "$original_gid" =~ ^[0-9]+$ ]] || {
        echo "ERROR: clone 实例目录 owner 参数非法" >&2
        return 1
    }

    mkdir -p -- "$(dirname "$vms_dir")" || return 1
    if [[ ! -e "$vms_dir" && ! -L "$vms_dir" ]]; then
        if ! mkdir -- "$vms_dir"; then
            echo "ERROR: 无法原子创建 VMS_DIR（可能被并发创建）: $vms_dir" >&2
            return 1
        fi
        chown -- "$original_uid:$original_gid" "$vms_dir" || return 1
    elif [[ ! -d "$vms_dir" || -L "$vms_dir" ]]; then
        echo "ERROR: VMS_DIR 必须是真实目录: $vms_dir" >&2
        return 1
    fi
    if [[ "$(stat -c '%u' -- "$vms_dir")" != "$original_uid" ]]; then
        echo "ERROR: VMS_DIR 必须由最终 VM 用户 $original_user 拥有: $vms_dir" >&2
        return 1
    fi

    clone_lifecycle_validate_instance_paths \
        "$vm_dir" "$disk" "$profile" "$ovmf_vars" || return 1
    if [[ -d "$vm_dir" ]]; then
        if [[ "$(stat -c '%u' -- "$vm_dir")" != "$original_uid" ]] ||
           ! sudo -u "$original_user" -- test -w "$vm_dir" ||
           ! sudo -u "$original_user" -- test -x "$vm_dir"; then
            echo "ERROR: 已有 VM_DIR 必须由 $original_user 拥有且可写/可遍历: $vm_dir" >&2
            return 1
        fi
        chmod 0700 -- "$vm_dir" || return 1
    elif mkdir -m 0700 -- "$vm_dir"; then
        # shellcheck disable=SC2034 # 调用方读取该状态决定失败清理与目录 owner。
        CLONE_LIFECYCLE_VM_DIR_CREATED=1
    else
        echo "ERROR: 无法原子创建 VM_DIR（可能被并发创建）: $vm_dir" >&2
        return 1
    fi
    clone_lifecycle_validate_instance_paths \
        "$vm_dir" "$disk" "$profile" "$ovmf_vars" || return 1
    if [[ "$(stat -c '%a' -- "$vm_dir")" != 700 ]]; then
        echo "ERROR: 无法把 VM_DIR 收紧到 0700: $vm_dir" >&2
        return 1
    fi
    if [[ -f "$profile" ]]; then
        if [[ "$(stat -c '%h' -- "$profile")" != 1 ]]; then
            echo "ERROR: 已有 profile 存在其它硬链接，拒绝接管: $profile" >&2
            return 1
        fi
        case "$(stat -c '%u' -- "$profile")" in
            0|"$original_uid") ;;
            *)
                echo "ERROR: 已有 profile 必须属于 root 或 $original_user: $profile" >&2
                return 1
                ;;
        esac
    fi
}

# 只改变本次事务的四个精确输出，不递归接管已有实例中的其它文件。VM_DIR 和
# profile 即使由 UI 预建或内容无需替换，也必须满足 start-vm 的 0700/0600
# 所有权契约后才能提交成功。
clone_lifecycle_assign_output_ownership() {
    local original_uid="${1:-}" original_gid="${2:-}"
    local vm_dir_created="${3:-}" profile_mode="${4:-}"
    local vm_dir="${5:-}" disk="${6:-}" profile="${7:-}" ovmf_vars="${8:-}"
    local path
    local -a owned_paths=("$vm_dir" "$disk" "$profile" "$ovmf_vars")

    [[ "$original_uid" =~ ^[1-9][0-9]*$ &&
       "$original_gid" =~ ^[0-9]+$ ]] || {
        echo "ERROR: clone 输出 owner 参数非法" >&2
        return 1
    }
    [[ "$vm_dir_created" == 0 || "$vm_dir_created" == 1 ]] || {
        echo "ERROR: clone VM_DIR 创建状态非法: $vm_dir_created" >&2
        return 1
    }
    case "$profile_mode" in
        created|replaced|none) ;;
        *)
            echo "ERROR: clone profile 发布状态非法: $profile_mode" >&2
            return 1
            ;;
    esac

    for path in "${owned_paths[@]}"; do
        if [[ "$path" == "$vm_dir" ]]; then
            [[ -d "$path" && ! -L "$path" ]] || {
                echo "ERROR: clone 输出目录在提交前被替换: $path" >&2
                return 1
            }
        elif [[ ! -f "$path" || -L "$path" ]]; then
            echo "ERROR: clone 输出文件在提交前被替换: $path" >&2
            return 1
        fi
    done
    chown -- "$original_uid:$original_gid" "${owned_paths[@]}" || return 1
    chmod 0700 -- "$vm_dir" || return 1
    chmod 0600 -- "$disk" "$profile" "$ovmf_vars" || return 1
    for path in "${owned_paths[@]}"; do
        [[ "$(stat -c '%u:%g' -- "$path")" == \
           "$original_uid:$original_gid" ]] || {
            echo "ERROR: clone 输出 owner 校验失败: $path" >&2
            return 1
        }
    done
    [[ "$(stat -c '%a' -- "$vm_dir")" == 700 ]] || {
        echo "ERROR: clone 输出目录 mode 校验失败: $vm_dir" >&2
        return 1
    }
    for path in "$disk" "$profile" "$ovmf_vars"; do
        [[ "$(stat -c '%a' -- "$path")" == 600 ]] || {
            echo "ERROR: clone 输出文件 mode 校验失败: $path" >&2
            return 1
        }
    done
}

# 把 root-owned base inode 钉在实例目录内。overlay 后续只引用这个本地 hard-link，
# 因而原 base 仓库目录项被移动/删除不会改变既有实例的 backing。hard-link 也保证
# 不复制数十 GB 数据；base 与 VMS_DIR 不在同一文件系统时必须明确失败。
clone_lifecycle_prepare_base_pin() {
    local original_user="${1:-}" base="${2:-}" vm_dir="${3:-}"
    local base_pin="${4:-}" expected_fingerprint="${5:-}"
    local actual_fingerprint

    CLONE_LIFECYCLE_BASE_PIN_TMP=""
    CLONE_LIFECYCLE_BASE_PIN_PUBLISHED=0
    [[ -n "$original_user" && -f "$base" && ! -L "$base" &&
       -d "$vm_dir" && ! -L "$vm_dir" && -n "$base_pin" &&
       -n "$expected_fingerprint" ]] || {
        echo "ERROR: clone base pin 参数非法" >&2
        return 1
    }
    if [[ -e "$base_pin" || -L "$base_pin" ]]; then
        echo "ERROR: clone base pin 已存在，拒绝覆盖: $base_pin" >&2
        return 1
    fi

    CLONE_LIFECYCLE_BASE_PIN_TMP="$(mktemp -- "$vm_dir/.base.qcow2.clone.XXXXXX")"
    rm -- "$CLONE_LIFECYCLE_BASE_PIN_TMP"
    if ! ln -T -- "$base" "$CLONE_LIFECYCLE_BASE_PIN_TMP"; then
        echo "ERROR: base 与 VMS_DIR 必须位于同一文件系统，无法建立生命周期 pin" >&2
        return 1
    fi
    actual_fingerprint="$(
        stat -c '%d:%i:%s:%y' -- "$CLONE_LIFECYCLE_BASE_PIN_TMP"
    )"
    if [[ "$actual_fingerprint" != "$expected_fingerprint" ]]; then
        echo "ERROR: base 在建立生命周期 pin 前被替换或修改" >&2
        return 1
    fi

    # shellcheck disable=SC2034 # 调用方 EXIT trap 读取该全局状态。
    CLONE_LIFECYCLE_BASE_PIN_PUBLISHED=1
    clone_lifecycle_publish_no_replace \
        "$CLONE_LIFECYCLE_BASE_PIN_TMP" "$base_pin" || return 1
    clone_lifecycle_validate_base_pin "$base_pin" "$expected_fingerprint" ||
        return 1
}

# 提交前复核 pin 仍指向 seal 后的 root-owned 0444 inode；fingerprint 不含 ctime，
# 因为建立 hard-link 会合法更新 inode ctime。
clone_lifecycle_validate_base_pin() {
    local base_pin="${1:-}" expected_fingerprint="${2:-}"
    local actual_fingerprint

    [[ -f "$base_pin" && ! -L "$base_pin" ]] || {
        echo "ERROR: 实例 base pin 不是普通文件: ${base_pin:-empty}" >&2
        return 1
    }
    [[ "$(stat -c '%u:%a' -- "$base_pin")" == 0:444 ]] || {
        echo "ERROR: 实例 base pin 不再是 root-owned 0444: $base_pin" >&2
        return 1
    }
    actual_fingerprint="$(stat -c '%d:%i:%s:%y' -- "$base_pin")"
    [[ "$actual_fingerprint" == "$expected_fingerprint" ]] || {
        echo "ERROR: 实例 base pin 在 clone 事务中被替换或修改: $base_pin" >&2
        return 1
    }
}

# 用同文件系统 hard-link 原子发布已经完整写好的临时普通文件。link(2) 自带
# O_EXCL 语义：目标无论是普通文件还是 dangling symlink，只要目录项已存在就
# 失败，绝不会覆盖或跟随它。调用方在整个事务提交后再删除临时 hard-link。
clone_lifecycle_publish_no_replace() {
    local temporary="${1:-}" target="${2:-}"

    [[ -f "$temporary" && ! -L "$temporary" ]] || {
        echo "ERROR: 待发布 clone 临时文件非法: ${temporary:-empty}" >&2
        return 1
    }
    if [[ -e "$target" || -L "$target" ]]; then
        echo "ERROR: clone 发布目标已存在，拒绝覆盖: $target" >&2
        return 1
    fi
    if ! ln -T -- "$temporary" "$target"; then
        echo "ERROR: 无法原子发布 clone 文件: $target" >&2
        return 1
    fi
    [[ "$temporary" -ef "$target" ]] || {
        echo "ERROR: clone 发布后的 inode 校验失败: $target" >&2
        clone_lifecycle_remove_published_file "$temporary" "$target"
        return 1
    }
}

# 回滚时只删除仍与本次临时文件指向同一 inode 的普通目标，避免错误清理并发置换
# 后的未知目录项。生命周期锁会阻止正常 start/stop/clone 并发；该检查再防御非协作写入。
clone_lifecycle_remove_published_file() {
    local temporary="${1:-}" target="${2:-}"

    if [[ -f "$temporary" && ! -L "$temporary" &&
          -f "$target" && ! -L "$target" && "$temporary" -ef "$target" ]]; then
        rm -- "$target"
    fi
}

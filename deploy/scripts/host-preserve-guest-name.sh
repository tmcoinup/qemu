#!/usr/bin/env bash
# 离线读取或写入 qcow2 Guest 计算机名称。
#
# 用法：
#   host-preserve-guest-name.sh read  <DISK>
#   host-preserve-guest-name.sh apply <DISK> <COMPUTER_NAME>
#
# read 只读挂载旧系统盘；apply 只处理尚未发布的新 overlay。Windows 写入三份
# unattend.xml，Linux 更新 /etc/hostname 与 /etc/hosts。任一识别、读取或写入失败
# 都返回非零，调用方不得提交换盘事务。

set -euo pipefail

guest_name_log() {
    printf '[guest-name] %s\n' "$*" >&2
}

guest_name_die() {
    guest_name_log "ERROR: $*"
    return 1
}

guest_name_validate_portable() {
    local name="${1:-}"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || {
        guest_name_die "计算机名称必须为 1..63 位字母、数字、点、下划线或短横线"
        return 1
    }
}

guest_name_validate_windows() {
    local name="${1:-}"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,14}$ &&
       ! "$name" =~ ^[0-9]+$ && ! "$name" =~ -$ ]] || {
        guest_name_die "现有计算机名称不符合 Windows 1..15 位 NetBIOS 规则: $name"
        return 1
    }
}

guest_name_windows_hive() {
    local mount_root="${1:-}"
    local candidate

    for candidate in \
        "$mount_root/Windows/System32/config/SYSTEM" \
        "$mount_root/WINDOWS/system32/config/system"; do
        if [[ -f "$candidate" && ! -L "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

guest_name_read_windows() {
    local mount_root="${1:-}" hive
    hive="$(guest_name_windows_hive "$mount_root")" || {
        guest_name_die "Windows SYSTEM hive 不存在"
        return 1
    }
    HIVE="$hive" python3 - <<'PY'
import os
import hivex

hive = hivex.Hivex(os.environ["HIVE"])
node = hive.root()

def walk(start, parts):
    current = start
    for part in parts:
        current = hive.node_get_child(current, part)
        if current is None:
            raise RuntimeError("SYSTEM hive 缺少 " + "\\".join(parts))
    return current

select = walk(node, ["Select"])
current_value = hive.node_get_value(select, "Current")
if current_value is None:
    raise RuntimeError("SYSTEM hive 缺少 Select\\Current")
current = hive.value_dword(current_value)
if current < 1 or current > 999:
    raise RuntimeError(f"SYSTEM Select\\Current 非法: {current}")
name_node = walk(
    node,
    [f"ControlSet{current:03d}", "Control", "ComputerName", "ComputerName"],
)
name_value = hive.node_get_value(name_node, "ComputerName")
if name_value is None:
    raise RuntimeError("SYSTEM hive 缺少 ComputerName")
name = hive.value_string(name_value).strip().rstrip("\x00")
if not name:
    raise RuntimeError("SYSTEM hive 的 ComputerName 为空")
print(name)
PY
}

guest_name_read_linux() {
    local mount_root="${1:-}" name
    local hostname_file="$mount_root/etc/hostname"
    [[ -f "$hostname_file" && ! -L "$hostname_file" ]] || {
        guest_name_die "Linux /etc/hostname 不存在或不是普通文件"
        return 1
    }
    IFS= read -r name <"$hostname_file" || true
    name="${name//$'\r'/}"
    guest_name_validate_portable "$name" || return 1
    printf '%s\n' "$name"
}

guest_name_write_windows_unattend() {
    local mount_root="${1:-}" name="${2:-}" template="${3:-}"
    local destination_dir destination

    guest_name_validate_windows "$name" || return 1
    [[ -f "$template" && ! -L "$template" ]] || {
        guest_name_die "Windows unattend 模板不存在: $template"
        return 1
    }
    grep -q '<ComputerName>[^<]*</ComputerName>' "$template" || {
        guest_name_die "Windows unattend 模板缺少 ComputerName"
        return 1
    }

    destination_dir="$mount_root/Windows/Panther/Unattend"
    destination="$destination_dir/unattend.xml"
    mkdir -p -- "$destination_dir" "$mount_root/Windows/System32/Sysprep"
    sed "s|<ComputerName>[^<]*</ComputerName>|<ComputerName>${name}</ComputerName>|" \
        "$template" >"$destination"
    cp -- "$destination" "$mount_root/unattend.xml"
    cp -- "$destination" "$mount_root/Windows/System32/Sysprep/unattend.xml"
    grep -qF "<ComputerName>${name}</ComputerName>" "$destination" || {
        guest_name_die "Windows ComputerName 注入结果校验失败"
        return 1
    }
}

guest_name_write_linux() {
    local mount_root="${1:-}" name="${2:-}"
    local hostname_file="$mount_root/etc/hostname" hosts_file="$mount_root/etc/hosts"

    guest_name_validate_portable "$name" || return 1
    [[ -f "$hostname_file" && ! -L "$hostname_file" ]] || {
        guest_name_die "Linux /etc/hostname 不存在或不是普通文件"
        return 1
    }
    printf '%s\n' "$name" >"$hostname_file"
    if [[ -f "$hosts_file" && ! -L "$hosts_file" ]]; then
        HOSTS_FILE="$hosts_file" GUEST_NAME="$name" python3 - <<'PY'
import os

path = os.environ["HOSTS_FILE"]
name = os.environ["GUEST_NAME"]
with open(path, "r", encoding="utf-8", errors="surrogateescape") as source:
    lines = source.readlines()

updated = []
replaced = False
for line in lines:
    fields = line.split()
    if fields and fields[0] == "127.0.1.1":
        newline = "\n" if line.endswith("\n") else ""
        updated.append(f"127.0.1.1\t{name}{newline}")
        replaced = True
    else:
        updated.append(line)
if not replaced:
    if updated and not updated[-1].endswith("\n"):
        updated[-1] += "\n"
    updated.append(f"127.0.1.1\t{name}\n")
with open(path, "w", encoding="utf-8", errors="surrogateescape") as target:
    target.writelines(updated)
PY
    fi
}

guest_name_partition_kind() {
    local mount_root="${1:-}"
    if guest_name_windows_hive "$mount_root" >/dev/null; then
        printf '%s\n' windows
    elif [[ -f "$mount_root/etc/hostname" && ! -L "$mount_root/etc/hostname" ]]; then
        printf '%s\n' linux
    else
        return 1
    fi
}

guest_name_mount_system_partition() {
    local mode="${1:-}" device="${2:-}" mount_root="${3:-}"
    local partition filesystem options kind

    for partition in "${device}"p{1..16}; do
        [[ -b "$partition" ]] || continue
        filesystem="$(blkid -o value -s TYPE "$partition" 2>/dev/null || true)"
        case "$filesystem" in
            ntfs)
                if [[ "$mode" == read ]]; then
                    options=ro
                else
                    options=rw,remove_hiberfile
                fi
                mount -t ntfs-3g -o "$options" "$partition" "$mount_root" 2>/dev/null || continue
                ;;
            ext2|ext3|ext4|xfs|btrfs)
                options=ro
                [[ "$mode" == apply ]] && options=rw
                mount -t "$filesystem" -o "$options" "$partition" "$mount_root" 2>/dev/null || continue
                ;;
            *)
                continue
                ;;
        esac
        if kind="$(guest_name_partition_kind "$mount_root")"; then
            GUEST_NAME_PARTITION="$partition"
            GUEST_NAME_KIND="$kind"
            return 0
        fi
        umount -- "$mount_root" 2>/dev/null || return 1
    done
    guest_name_die "没有找到受支持的 Windows 或 Linux 系统分区"
}

guest_name_main() {
    local mode="${1:-}" disk="${2:-}" requested_name="${3:-}"
    local script_dir mount_root result

    [[ "$mode" == read || "$mode" == apply ]] || {
        guest_name_die "用法: $0 <read|apply> <DISK> [COMPUTER_NAME]"
        return 2
    }
    [[ $EUID -eq 0 ]] || {
        guest_name_die "必须以 root 运行"
        return 1
    }
    [[ -f "$disk" && ! -L "$disk" ]] || {
        guest_name_die "磁盘必须是真实普通文件: $disk"
        return 1
    }
    [[ "$mode" == read || -n "$requested_name" ]] || {
        guest_name_die "apply 缺少 COMPUTER_NAME"
        return 2
    }
    command -v qemu-nbd >/dev/null || {
        guest_name_die "缺少 qemu-nbd"
        return 1
    }
    command -v blkid >/dev/null || {
        guest_name_die "缺少 blkid"
        return 1
    }
    command -v ntfs-3g >/dev/null || {
        guest_name_die "缺少 ntfs-3g"
        return 1
    }
    python3 -c 'import hivex' 2>/dev/null || {
        guest_name_die "缺少 python3-hivex"
        return 1
    }

    script_dir="$(cd "$(dirname "$0")" && pwd)"
    _NBD_PINNED="${NBD:+1}"
    : "${NBD:=/dev/nbd0}"
    # shellcheck source=/dev/null
    source "$script_dir/lib/nbd-lock.sh"
    modprobe nbd max_part=16 2>/dev/null || true
    mount_root="$(mktemp -d /tmp/vmate-guest-name.XXXXXX)"
    cleanup_guest_name() {
        umount -- "$mount_root" 2>/dev/null || true
        nbd_disconnect_if_owned
        rmdir -- "$mount_root" 2>/dev/null || true
    }
    trap cleanup_guest_name EXIT

    if [[ "$mode" == read ]]; then
        # 中文注释：旧系统盘只用于读取名称，NBD 后端也必须以 read-only 打开，
        # 不能仅依赖文件系统的 ro 挂载选项来约束块设备写入。
        nbd_guard_disk "$disk"
        if ! _nbd_dev_is_free "$NBD"; then
            if [[ "$_NBD_PINNED" == 1 ]]; then
                guest_name_die "显式指定的 NBD 已被占用: $NBD"
                return 1
            fi
            NBD="$(nbd_pick_free)" || {
                guest_name_die "没有空闲 NBD 设备"
                return 1
            }
        fi
        qemu-nbd --read-only --connect="$NBD" --format=qcow2 "$disk"
        _NBD_CONNECTED=1
        _NBD_DEV="$NBD"
    else
        nbd_connect NBD "$disk"
    fi
    sleep 1
    guest_name_mount_system_partition "$mode" "$NBD" "$mount_root"
    guest_name_log "system=$GUEST_NAME_KIND partition=$GUEST_NAME_PARTITION"

    if [[ "$mode" == read ]]; then
        if [[ "$GUEST_NAME_KIND" == windows ]]; then
            result="$(guest_name_read_windows "$mount_root")"
            guest_name_validate_windows "$result"
        else
            result="$(guest_name_read_linux "$mount_root")"
        fi
    else
        if [[ "$GUEST_NAME_KIND" == windows ]]; then
            : "${UNATTEND:=$script_dir/../autounattend/autounattend.xml}"
            guest_name_write_windows_unattend "$mount_root" "$requested_name" "$UNATTEND"
        else
            guest_name_write_linux "$mount_root" "$requested_name"
        fi
        result="$requested_name"
    fi
    sync -f "$mount_root" 2>/dev/null || sync
    printf 'VMATE_GUEST_NAME=%s\n' "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    guest_name_main "$@"
fi

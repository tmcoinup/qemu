#!/usr/bin/bash
# Install the root-owned, narrowly authorized G-11 mdev lifecycle helper.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_admin="$here/vgpu-mdev-admin.sh"
source_identity="$here/update-vgpu-mdev-identity.py"
source_profile="$here/profile_override.toml"
install_dir=/usr/local/libexec
installed_admin="$install_dir/qemu-vgpu-mdev-admin"
installed_identity="$install_dir/qemu-vgpu-mdev-identity.py"
sudoers_file=/etc/sudoers.d/qemu-vgpu-mdev-admin
print_only=0
uninstall=0
requested_user=

usage() {
    echo "usage: $0 [--print] [--user USER] [--uninstall]" >&2
    exit 2
}

while (($#)); do
    case "$1" in
        --print) print_only=1 ;;
        --uninstall) uninstall=1 ;;
        --user)
            shift
            [[ $# -gt 0 ]] || usage
            requested_user=$1
            ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
    shift
done
((print_only == 0 || uninstall == 0)) || usage

invoking_user=${requested_user:-${SUDO_USER:-$(id -un)}}
[[ "$invoking_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || {
    echo "不安全的调用用户名: $invoking_user" >&2
    exit 1
}
id "$invoking_user" >/dev/null 2>&1 || {
    echo "调用用户不存在: $invoking_user" >&2
    exit 1
}

sudoers_line="${invoking_user} ALL=(root) NOPASSWD:NOSETENV: ${installed_admin} check, ${installed_admin} identity-set *, ${installed_admin} identity-remove *, ${installed_admin} mdev-create *, ${installed_admin} mdev-remove *, ${installed_admin} console-interval *, ${installed_admin} gpu-clocks *"

if ((print_only)); then
    echo "admin_helper=$installed_admin"
    echo "identity_helper=$installed_identity"
    echo "sudoers=$sudoers_file"
    echo "packages=python3 util-linux sudo"
    echo "$sudoers_line"
    exit 0
fi

((EUID == 0)) || {
    echo "安装/卸载 G-11 mdev helper 需要 root；请通过 sudo 运行一次" >&2
    exit 1
}

if ((uninstall)); then
    rm -f -- "$sudoers_file" "$installed_admin" "$installed_identity"
    echo "G-11 mdev helper 已卸载；现有 VM 和 mdev 未被修改"
    exit 0
fi

[[ -f "$source_admin" && ! -L "$source_admin" && -r "$source_admin" ]] || {
    echo "mdev admin helper 源文件缺失或不安全: $source_admin" >&2
    exit 1
}
[[ -f "$source_identity" && ! -L "$source_identity" && -r "$source_identity" ]] || {
    echo "identity helper 源文件缺失或不安全: $source_identity" >&2
    exit 1
}
[[ -f "$source_profile" && ! -L "$source_profile" && -r "$source_profile" ]] || {
    echo "profile override 模板缺失或不安全: $source_profile" >&2
    exit 1
}

for required in python3 flock install mktemp visudo; do
    command -v "$required" >/dev/null 2>&1 || {
        echo "缺少安装依赖: $required（Ubuntu 包：python3 util-linux sudo）" >&2
        exit 1
    }
done

tmp_sudoers=$(mktemp)
transaction_dir=
stage_admin=
stage_identity=
stage_sudoers=
transaction_started=0
transaction_committed=0
config_created=0
had_admin=0
had_identity=0
had_sudoers=0
cleanup() {
    local status=$?
    rm -f -- "$tmp_sudoers"
    [[ -z "$stage_admin" ]] || rm -f -- "$stage_admin"
    [[ -z "$stage_identity" ]] || rm -f -- "$stage_identity"
    [[ -z "$stage_sudoers" ]] || rm -f -- "$stage_sudoers"
    if ((transaction_started && !transaction_committed)); then
        if ((had_admin)); then
            install -o root -g root -m 0755 \
                "$transaction_dir/admin.before" "$installed_admin" || true
        else
            rm -f -- "$installed_admin"
        fi
        if ((had_identity)); then
            install -o root -g root -m 0755 \
                "$transaction_dir/identity.before" "$installed_identity" || true
        else
            rm -f -- "$installed_identity"
        fi
        if ((had_sudoers)); then
            install -o root -g root -m 0440 \
                "$transaction_dir/sudoers.before" "$sudoers_file" || true
        else
            rm -f -- "$sudoers_file"
        fi
        ((config_created == 0)) || rm -f -- /etc/vgpu_unlock/profile_override.toml
        echo "G-11 mdev helper 安装失败；已恢复安装前状态" >&2
    fi
    if [[ -n "$transaction_dir" ]]; then
        rm -f -- "$transaction_dir/admin.before" \
            "$transaction_dir/identity.before" \
            "$transaction_dir/sudoers.before"
        rmdir -- "$transaction_dir" 2>/dev/null || true
    fi
    return "$status"
}
trap cleanup EXIT
printf '%s\n' "$sudoers_line" >"$tmp_sudoers"
chmod 0440 "$tmp_sudoers"
visudo -cf "$tmp_sudoers" >/dev/null

install -d -o root -g root -m 0755 "$install_dir" /etc/sudoers.d /etc/vgpu_unlock
transaction_dir=$(mktemp -d /var/tmp/qemu-vgpu-mdev-admin.XXXXXXXX)
if [[ -e "$installed_admin" ]]; then
    cp -a -- "$installed_admin" "$transaction_dir/admin.before"
    had_admin=1
fi
if [[ -e "$installed_identity" ]]; then
    cp -a -- "$installed_identity" "$transaction_dir/identity.before"
    had_identity=1
fi
if [[ -e "$sudoers_file" ]]; then
    cp -a -- "$sudoers_file" "$transaction_dir/sudoers.before"
    had_sudoers=1
fi
transaction_started=1

if [[ ! -e /etc/vgpu_unlock/profile_override.toml ]]; then
    install -o root -g root -m 0644 "$source_profile" \
        /etc/vgpu_unlock/profile_override.toml
    config_created=1
fi

# Stage in each destination filesystem, then rename into place. The EXIT
# handler restores the entire previous set if any validation below fails.
stage_admin=$(mktemp "$install_dir/.qemu-vgpu-mdev-admin.XXXXXXXX")
stage_identity=$(mktemp "$install_dir/.qemu-vgpu-mdev-identity.XXXXXXXX")
stage_sudoers=$(mktemp /etc/sudoers.d/.qemu-vgpu-mdev-admin.XXXXXXXX)
install -o root -g root -m 0755 "$source_admin" "$stage_admin"
install -o root -g root -m 0755 "$source_identity" "$stage_identity"
install -o root -g root -m 0440 "$tmp_sudoers" "$stage_sudoers"
bash -n "$stage_admin"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' \
    "$stage_identity"
visudo -cf "$stage_sudoers" >/dev/null
mv -fT -- "$stage_identity" "$installed_identity"
stage_identity=
mv -fT -- "$stage_admin" "$installed_admin"
stage_admin=
mv -fT -- "$stage_sudoers" "$sudoers_file"
stage_sudoers=
visudo -cf "$sudoers_file" >/dev/null

cmp -s "$source_admin" "$installed_admin"
cmp -s "$source_identity" "$installed_identity"
"$installed_admin" check >/dev/null
transaction_committed=1

echo "G-11 mdev admin helper installed: $installed_admin"
echo "G-11 identity generator installed: $installed_identity"
echo "passwordless sudoers installed for user $invoking_user: $sudoers_file"

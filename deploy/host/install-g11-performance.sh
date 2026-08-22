#!/usr/bin/env bash
# Install the fixed, root-owned G-11 performance helper and its narrow sudo rule.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_helper="$here/g11-performance.sh"
install_dir=/usr/local/libexec
installed_helper="$install_dir/qemu-g11-performance"
sudoers_file=/etc/sudoers.d/qemu-g11-performance
print_only=0

if [[ "${1:-}" == --print ]]; then
    print_only=1
    shift
fi
[[ $# == 0 ]] || {
    echo "usage: $0 [--print]" >&2
    exit 2
}

invoking_user=${SUDO_USER:-$(id -un)}
[[ "$invoking_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || {
    echo "不安全的调用用户名: $invoking_user" >&2
    exit 1
}
id "$invoking_user" >/dev/null 2>&1 || {
    echo "调用用户不存在: $invoking_user" >&2
    exit 1
}
[[ -f "$source_helper" && ! -L "$source_helper" && -r "$source_helper" ]] || {
    echo "G-11 performance helper 不可读: $source_helper" >&2
    exit 1
}

sudoers_line="${invoking_user} ALL=(root) NOPASSWD:NOSETENV: ${installed_helper} apply, ${installed_helper} restore"
if ((print_only)); then
    echo "helper=$installed_helper"
    echo "sudoers=$sudoers_file"
    echo "packages=util-linux sudo"
    echo "$sudoers_line"
    exit 0
fi

for required_command in install cmp flock visudo; do
    command -v "$required_command" >/dev/null 2>&1 || {
        echo "缺少依赖: $required_command（Ubuntu/Debian: sudo apt install util-linux sudo coreutils）" >&2
        exit 1
    }
done

tmp_file=$(mktemp)
cleanup() { rm -f -- "$tmp_file"; }
trap cleanup EXIT
printf '%s\n' "$sudoers_line" >"$tmp_file"
chmod 0440 "$tmp_file"
visudo_prefix=()
((EUID == 0)) || visudo_prefix=(sudo)
"${visudo_prefix[@]}" visudo -cf "$tmp_file" >/dev/null

if ((EUID == 0)); then
    install -d -o root -g root -m 0755 "$install_dir" /etc/sudoers.d
    install -o root -g root -m 0755 "$source_helper" "$installed_helper"
    install -o root -g root -m 0440 "$tmp_file" "$sudoers_file"
    visudo -cf "$sudoers_file" >/dev/null
else
    command -v sudo >/dev/null 2>&1 || {
        echo "安装需要 root，且系统没有 sudo" >&2
        exit 1
    }
    sudo install -d -o root -g root -m 0755 "$install_dir" /etc/sudoers.d
    sudo install -o root -g root -m 0755 "$source_helper" "$installed_helper"
    sudo install -o root -g root -m 0440 "$tmp_file" "$sudoers_file"
    sudo visudo -cf "$sudoers_file" >/dev/null
fi

echo "G-11 performance helper installed: $installed_helper"
echo "sudoers installed for user $invoking_user: $sudoers_file"


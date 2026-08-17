#!/usr/bin/env bash
# Install the CPU isolation helper as a root-owned executable and grant only
# the invoking user permission to run its validated apply/release commands.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_helper="$here/cpu-isolate.sh"
install_dir=/usr/local/libexec
installed_helper="$install_dir/qemu-cpu-isolate"
sudoers_file=/etc/sudoers.d/qemu-cpu-isolation
print_only=0
dependency_packages=()

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
[[ -r "$source_helper" ]] || {
    echo "CPU helper 不可读: $source_helper" >&2
    exit 1
}

sudoers_line="${invoking_user} ALL=(root) NOPASSWD: ${installed_helper} apply *, ${installed_helper} release *, ${installed_helper} oom-protect *"
if ((print_only)); then
    echo "helper=$installed_helper"
    echo "sudoers=$sudoers_file"
    echo "packages=python3 util-linux diffutils sudo"
    echo "$sudoers_line"
    exit 0
fi

command -v python3 >/dev/null 2>&1 || dependency_packages+=(python3)
if ! command -v taskset >/dev/null 2>&1 ||
        ! command -v flock >/dev/null 2>&1; then
    dependency_packages+=(util-linux)
fi
command -v cmp >/dev/null 2>&1 || dependency_packages+=(diffutils)
command -v visudo >/dev/null 2>&1 || dependency_packages+=(sudo)

if ((${#dependency_packages[@]})); then
    ((EUID == 0)) || {
        echo "安装 CPU 隔离依赖需要 root" >&2
        exit 1
    }
    command -v apt-get >/dev/null 2>&1 || {
        echo "缺少依赖且宿主没有 apt-get: ${dependency_packages[*]}" >&2
        exit 1
    }
    echo "Installing CPU isolation dependencies: ${dependency_packages[*]}"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
            --no-install-recommends "${dependency_packages[@]}"; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            --no-install-recommends "${dependency_packages[@]}"
    fi
fi

for required_command in python3 taskset flock cmp visudo install; do
    command -v "$required_command" >/dev/null 2>&1 || {
        echo "CPU isolation dependency is still missing: $required_command" >&2
        exit 1
    }
done

tmp_file=$(mktemp)
cleanup() {
    rm -f -- "$tmp_file"
}
trap cleanup EXIT
printf '%s\n' "$sudoers_line" >"$tmp_file"

if [[ $EUID -eq 0 ]]; then
    install -d -o root -g root -m 0755 "$install_dir"
    install -o root -g root -m 0755 "$source_helper" "$installed_helper"
    visudo -cf "$tmp_file"
    install -o root -g root -m 0440 "$tmp_file" "$sudoers_file"
    visudo -cf "$sudoers_file"
else
    command -v sudo >/dev/null 2>&1 || {
        echo "安装需要 root，且系统没有 sudo" >&2
        exit 1
    }
    sudo install -d -o root -g root -m 0755 "$install_dir"
    sudo install -o root -g root -m 0755 "$source_helper" "$installed_helper"
    sudo visudo -cf "$tmp_file"
    sudo install -o root -g root -m 0440 "$tmp_file" "$sudoers_file"
    sudo visudo -cf "$sudoers_file"
fi

echo "CPU isolation helper installed: $installed_helper"
echo "sudoers installed for user $invoking_user: $sudoers_file"

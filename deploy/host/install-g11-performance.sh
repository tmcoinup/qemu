#!/usr/bin/env bash
# Install the fixed, root-owned G-11 performance helper and its narrow sudo rule.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_helper="$here/g11-performance.sh"
install_dir=/usr/local/libexec
installed_helper="$install_dir/qemu-g11-performance"
sudoers_file=/etc/sudoers.d/qemu-g11-performance
service_name=qemu-g11-performance.service
service_file="/etc/systemd/system/$service_name"
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
    echo "service=$service_file"
    echo "packages=util-linux sudo systemd"
    echo "$sudoers_line"
    echo "systemctl enable $service_name"
    exit 0
fi

for required_command in install cmp flock stat systemctl visudo; do
    command -v "$required_command" >/dev/null 2>&1 || {
        echo "缺少依赖: $required_command（Ubuntu/Debian: sudo apt install util-linux sudo coreutils）" >&2
        exit 1
    }
done

tmp_file=$(mktemp)
tmp_service=$(mktemp)
cleanup() { rm -f -- "$tmp_file" "$tmp_service"; }
trap cleanup EXIT
printf '%s\n' "$sudoers_line" >"$tmp_file"
chmod 0440 "$tmp_file"
cat >"$tmp_service" <<'EOF'
[Unit]
Description=G-11 latency-first host performance policy
After=systemd-modules-load.service systemd-sysctl.service
Before=qemu-vm-server.service libvirt-guests.service
ConditionFileIsExecutable=/usr/local/libexec/qemu-g11-performance

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/qemu-g11-performance apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$tmp_service"
visudo_prefix=()
((EUID == 0)) || visudo_prefix=(sudo)
"${visudo_prefix[@]}" visudo -cf "$tmp_file" >/dev/null

if ((EUID == 0)); then
    install -d -o root -g root -m 0755 "$install_dir" /etc/sudoers.d \
        /etc/systemd/system
    install -o root -g root -m 0755 "$source_helper" "$installed_helper"
    install -o root -g root -m 0440 "$tmp_file" "$sudoers_file"
    install -o root -g root -m 0644 "$tmp_service" "$service_file"
    visudo -cf "$sudoers_file" >/dev/null
    systemctl daemon-reload
    systemctl enable "$service_name" >/dev/null
else
    command -v sudo >/dev/null 2>&1 || {
        echo "安装需要 root，且系统没有 sudo" >&2
        exit 1
    }
    sudo install -d -o root -g root -m 0755 "$install_dir" /etc/sudoers.d \
        /etc/systemd/system
    sudo install -o root -g root -m 0755 "$source_helper" "$installed_helper"
    sudo install -o root -g root -m 0440 "$tmp_file" "$sudoers_file"
    sudo install -o root -g root -m 0644 "$tmp_service" "$service_file"
    sudo visudo -cf "$sudoers_file" >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable "$service_name" >/dev/null
fi

if [[ "$(stat -c '%u:%g:%a:%h' -- "$installed_helper")" != 0:0:755:1 ]] || \
        ! cmp -s -- "$source_helper" "$installed_helper"; then
    echo "G-11 performance helper 安装后内容或权限不一致" >&2
    exit 1
fi
if [[ "$(stat -c '%u:%g:%a:%h' -- "$service_file")" != 0:0:644:1 ]] || \
        ! cmp -s -- "$tmp_service" "$service_file"; then
    echo "G-11 performance systemd unit 安装后内容或权限不一致" >&2
    exit 1
fi
systemctl is-enabled --quiet "$service_name" || {
    echo "G-11 performance systemd unit 未启用" >&2
    exit 1
}

echo "G-11 performance helper installed: $installed_helper"
echo "sudoers installed for user $invoking_user: $sudoers_file"
echo "boot persistence enabled: $service_name"

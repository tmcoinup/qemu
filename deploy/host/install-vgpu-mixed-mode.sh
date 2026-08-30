#!/usr/bin/env bash
# Install the root-owned V100/R580 heterogeneous-mode boot and reset guard.
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_helper="$here/vgpu-mixed-mode.sh"
installed_helper=/usr/local/libexec/qemu-vgpu-mixed-mode
service_file=/etc/systemd/system/vmate-vgpu-mixed-mode.service
timer_file=/etc/systemd/system/vmate-vgpu-mixed-mode.timer
manager_dropin=/etc/systemd/system/nvidia-vgpu-mgr.service.d/30-vmate-v100-mixed-mode.conf
backup_root=/var/backups/vmate-vgpu-mixed-mode

die() {
    echo "[install-vgpu-mixed-mode] $*" >&2
    exit 1
}

usage() {
    echo "usage: $0 --bdf DDDD:BB:SS.F" >&2
    exit 2
}

(( EUID == 0 )) || die "must run as root"
(( $# == 2 )) && [[ "$1" == --bdf ]] || usage
bdf=${2,,}
[[ "$bdf" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || usage
[[ -f "$source_helper" && ! -L "$source_helper" && -x "$source_helper" ]] || \
    die "source helper is missing or unsafe: $source_helper"
bash -n "$source_helper"

install -d -o root -g root -m 0755 /usr/local/libexec \
    /etc/systemd/system/nvidia-vgpu-mgr.service.d
install -d -o root -g root -m 0700 "$backup_root"
backup_dir=$(mktemp -d "$backup_root/transaction.XXXXXXXX")
for path in "$installed_helper" "$service_file" "$timer_file" "$manager_dropin"; do
    if [[ -e "$path" || -L "$path" ]]; then
        cp -a -- "$path" "$backup_dir/$(basename -- "$path").before"
    fi
done

stage_helper=$(mktemp /usr/local/libexec/.qemu-vgpu-mixed-mode.XXXXXXXX)
stage_service=$(mktemp /etc/systemd/system/.vmate-vgpu-mixed-mode.service.XXXXXXXX)
stage_timer=$(mktemp /etc/systemd/system/.vmate-vgpu-mixed-mode.timer.XXXXXXXX)
stage_dropin=$(mktemp /etc/systemd/system/nvidia-vgpu-mgr.service.d/.vmate-mixed.XXXXXXXX)
cleanup() {
    rm -f -- "$stage_helper" "$stage_service" "$stage_timer" "$stage_dropin"
}
trap cleanup EXIT

install -o root -g root -m 0755 "$source_helper" "$stage_helper"
{
    echo '[Unit]'
    echo 'Description=VMate V100 R580 heterogeneous vGPU mode guard'
    echo 'Requires=nvidia-vgpu-mgr.service'
    echo 'After=nvidia-vgpu-mgr.service'
    echo 'Before=libvirtd.service virtqemud.service'
    echo
    echo '[Service]'
    echo 'Type=oneshot'
    printf 'ExecStart=%s apply %s\n' "$installed_helper" "$bdf"
} >"$stage_service"
{
    echo '[Unit]'
    echo 'Description=Retry VMate V100 heterogeneous vGPU mode after GPU resets'
    echo
    echo '[Timer]'
    echo 'OnBootSec=15s'
    echo 'OnUnitActiveSec=30s'
    echo 'AccuracySec=5s'
    echo 'Unit=vmate-vgpu-mixed-mode.service'
    echo
    echo '[Install]'
    echo 'WantedBy=timers.target'
} >"$stage_timer"
{
    echo '[Unit]'
    echo 'Wants=vmate-vgpu-mixed-mode.service'
    echo 'Before=vmate-vgpu-mixed-mode.service'
} >"$stage_dropin"
chmod 0644 "$stage_service" "$stage_timer" "$stage_dropin"
chown root:root "$stage_service" "$stage_timer" "$stage_dropin"
bash -n "$stage_helper"

mv -fT -- "$stage_helper" "$installed_helper"
stage_helper=
mv -fT -- "$stage_service" "$service_file"
stage_service=
mv -fT -- "$stage_timer" "$timer_file"
stage_timer=
mv -fT -- "$stage_dropin" "$manager_dropin"
stage_dropin=
systemctl daemon-reload
systemctl enable --now vmate-vgpu-mixed-mode.timer
systemctl start vmate-vgpu-mixed-mode.service
"$installed_helper" status "$bdf"

echo "V100/R580 mixed-size guard installed for $bdf"
echo "backup=$backup_dir"

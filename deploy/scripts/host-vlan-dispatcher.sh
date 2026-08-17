#!/usr/bin/env bash
# Installed into NetworkManager dispatcher.d; NetworkManager invokes it as root.
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
helper=/usr/local/libexec/qemu-g11-vlan-bridge

case "${2:-}" in
    up|dhcp4-change|connectivity-change)
        [[ -x "$helper" && -f /etc/qemu/g11-vlan.conf ]] || exit 0
        "$helper" ensure >/dev/null 2>&1 || \
            logger -t qemu-g11-vlan "failed to restore VLAN-aware br0 after NetworkManager event" 2>/dev/null || true
        ;;
esac
exit 0

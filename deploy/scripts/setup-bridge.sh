#!/bin/bash
# ---------------------------------------------------------------------------
# setup-bridge.sh
#
# Host-side one-shot: create br0, optionally enslave a physical uplink so the
# guest gets a real LAN IP (DHCP from the upstream router), write
# /etc/qemu/bridge.conf, and arrange for qemu-bridge-helper to have the
# capabilities it needs.
#
# Must run as root.
#
# Env:
#   BR=br0              bridge name (default br0)
#   UPLINK=<iface>      physical NIC to enslave (default: unset = isolated
#                       bridge with host-side static IP 192.168.76.1/24).
#                       Set UPLINK=enp5s0 to put the guest on your real LAN.
#                       Disruptive: will move the IP+default route from the
#                       uplink onto the bridge via NetworkManager.
#   HOST_IP=            host IP on the bridge when UPLINK is unset
#                       (default 192.168.76.1/24)
#
# Examples:
#   sudo deploy/scripts/setup-bridge.sh                       # isolated br0
#   sudo UPLINK=enp5s0 deploy/scripts/setup-bridge.sh         # LAN bridge
#   sudo BR=br1 UPLINK=wlo1 deploy/scripts/setup-bridge.sh    # wifi master
#
# Idempotent: safe to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail

BR="${BR:-br0}"
UPLINK="${UPLINK:-}"
HOST_IP="${HOST_IP:-192.168.76.1/24}"

if [[ $(id -u) -ne 0 ]]; then
    echo "ERROR: must run as root (sudo)." >&2
    exit 1
fi

# -----------------------------------------------------------------------
# Make sure the apt package that ships qemu-bridge-helper is present.
# On Debian/Ubuntu it's part of qemu-system-common.
# -----------------------------------------------------------------------
if ! dpkg -s qemu-system-common >/dev/null 2>&1 \
   && ! [[ -x /usr/lib/qemu/qemu-bridge-helper \
        || -x /usr/libexec/qemu-bridge-helper ]]; then
    echo ">> installing qemu-system-common (needed for qemu-bridge-helper)"
    apt-get update -qq
    apt-get install -y qemu-system-common
fi

# -----------------------------------------------------------------------
# Kernel modules. Bridge networking needs both.
# -----------------------------------------------------------------------
for mod in tun bridge; do
    if ! lsmod | grep -q "^$mod\b"; then
        if modprobe "$mod" 2>/dev/null; then
            echo ">> modprobe $mod"
        else
            echo "WARN: failed to modprobe $mod; bridge networking may not work." >&2
        fi
    fi
done
# Ensure they reload on reboot
install -d /etc/modules-load.d
cat > /etc/modules-load.d/qemu-stealth.conf <<EOF
tun
bridge
EOF

# -----------------------------------------------------------------------
# Locate qemu-bridge-helper candidates.
#
# There are up to THREE paths we care about:
#   /usr/lib/qemu/qemu-bridge-helper        -> apt qemu-system-common
#   /usr/libexec/qemu-bridge-helper         -> some distros
#   /usr/local/libexec/qemu-bridge-helper   -> path baked into a source-built
#                                              QEMU with default prefix
# The source-built qemu-system-x86_64 consults the path it was compiled
# against; if that path doesn't exist, `-netdev bridge,helper=<path>`
# must override it. We solve both: give every candidate cap_net_admin
# AND symlink the source-default path to the apt helper so `-netdev
# bridge` with no explicit helper= still works.
# -----------------------------------------------------------------------
HELPER_CANDIDATES=(
    /usr/lib/qemu/qemu-bridge-helper
    /usr/libexec/qemu-bridge-helper
    /usr/local/libexec/qemu-bridge-helper
)
# Also pick up an in-tree build, if present, so the in-tree binary gets caps too
REPO_HELPER="$(cd "$(dirname "$0")/../.." && pwd)/build/qemu-bridge-helper"
if [[ -x "$REPO_HELPER" ]]; then
    HELPER_CANDIDATES+=("$REPO_HELPER")
fi

HELPER=""
for h in "${HELPER_CANDIDATES[@]}"; do
    if [[ -x "$h" && -f "$h" && ! -L "$h" ]]; then
        HELPER="$h"
        break
    fi
done

if [[ -z "$HELPER" ]]; then
    echo "ERROR: no qemu-bridge-helper found. Install it:" >&2
    echo "       sudo apt install qemu-system-common" >&2
    exit 1
fi

echo ">> primary helper: $HELPER"

# Symlink /usr/local/libexec/qemu-bridge-helper if it is the path the
# source-built QEMU expects but doesn't exist yet. /usr/local/libexec is
# the default for `./configure --prefix=/usr/local` source builds.
SRCBUILD_HELPER=/usr/local/libexec/qemu-bridge-helper
if [[ ! -e "$SRCBUILD_HELPER" ]]; then
    mkdir -p /usr/local/libexec
    ln -sf "$HELPER" "$SRCBUILD_HELPER"
    echo ">> symlinked $SRCBUILD_HELPER -> $HELPER"
fi

# -----------------------------------------------------------------------
# /etc/qemu/bridge.conf  (QEMU ACL for qemu-bridge-helper)
# -----------------------------------------------------------------------
mkdir -p /etc/qemu
if ! grep -q "^allow $BR\$" /etc/qemu/bridge.conf 2>/dev/null; then
    echo "allow $BR" >> /etc/qemu/bridge.conf
    echo ">> appended 'allow $BR' to /etc/qemu/bridge.conf"
else
    echo ">> /etc/qemu/bridge.conf already allows $BR"
fi
# 644 (not 640): the launcher's pre-flight grep runs as the unprivileged
# user; 640 silently fails the check and aborts with "bridge.conf missing
# 'allow br0'". The file only lists permitted bridge names — nothing
# sensitive — so world-readable is fine.
chmod 644 /etc/qemu/bridge.conf

# -----------------------------------------------------------------------
# Capability on every concrete qemu-bridge-helper binary (not the symlink).
# Preferred: cap_net_admin+ep (no full root). Falls back to suid if setcap
# is missing.
# -----------------------------------------------------------------------
_grant() {
    local h="$1"
    if command -v setcap >/dev/null 2>&1; then
        if ! getcap "$h" 2>/dev/null | grep -q cap_net_admin; then
            setcap cap_net_admin+ep "$h"
            echo ">> set cap_net_admin+ep on $h"
        else
            echo ">> $h already has cap_net_admin"
        fi
    else
        if [[ ! -u "$h" ]]; then
            chmod u+s "$h"
            echo ">> set suid on $h (fallback, setcap unavailable)"
        fi
    fi
}
for h in "${HELPER_CANDIDATES[@]}"; do
    [[ -x "$h" && -f "$h" && ! -L "$h" ]] && _grant "$h"
done

# -----------------------------------------------------------------------
# Bridge interface.
# Prefer NetworkManager if the host is managed by it (nmcli present AND
# NetworkManager.service active). Otherwise fall back to iproute2.
# -----------------------------------------------------------------------
use_nm=0
if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    use_nm=1
fi

if (( use_nm )); then
    echo ">> using NetworkManager to manage $BR"

    # Create the bridge connection if missing
    if ! nmcli -t -f NAME con show | grep -Fxq "$BR"; then
        nmcli con add type bridge ifname "$BR" con-name "$BR" \
            stp no ipv4.method manual ipv4.addresses "$HOST_IP" \
            ipv6.method ignore autoconnect yes
        echo ">> created NM bridge connection '$BR' ($HOST_IP)"
    else
        echo ">> NM bridge '$BR' already exists"
    fi

    if [[ -n "$UPLINK" ]]; then
        # Enslave uplink: create a bridge-slave connection, then bring bridge
        # up. On Ubuntu 22.04+ netplan hands the physical NIC to NM via a
        # connection named `netplan-<iface>`; that connection has a higher
        # priority on auto-activation than our new slave, so the slave
        # reports success but the device stays owned by netplan (bridge
        # never gets an IP). We explicitly deactivate and disable
        # autoconnect on any conflicting existing connection before
        # handing the device over.
        for c in $(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="$UPLINK" '$2==d && $1!~/bridge-slave/ {print $1}'); do
            echo ">> releasing existing connection '$c' on $UPLINK"
            nmcli con down "$c" || true
            nmcli con modify "$c" connection.autoconnect no
        done

        slave="$BR-slave-$UPLINK"
        if ! nmcli -t -f NAME con show | grep -Fxq "$slave"; then
            nmcli con add type bridge-slave ifname "$UPLINK" master "$BR" \
                con-name "$slave" autoconnect yes
            echo ">> created NM bridge-slave '$slave'"
        else
            echo ">> NM bridge-slave '$slave' already exists"
        fi

        # Switch bridge IP method to auto (DHCP from upstream) when enslaving
        nmcli con modify "$BR" ipv4.method auto ipv4.addresses ""
        nmcli con down "$BR" 2>/dev/null || true
        nmcli con up "$slave"
        nmcli con up "$BR"
        echo ">> bridge $BR up with uplink $UPLINK (DHCP from LAN)"
    else
        nmcli con up "$BR" || true
        echo ">> bridge $BR up (isolated, host IP $HOST_IP)"
    fi
else
    echo ">> NetworkManager not in use; falling back to iproute2"
    if ! ip link show "$BR" &>/dev/null; then
        ip link add name "$BR" type bridge
        echo ">> created bridge $BR"
    fi
    ip link set "$BR" up

    if [[ -n "$UPLINK" ]]; then
        ip link set "$UPLINK" master "$BR"
        # Move addresses from uplink to bridge
        addrs=$(ip -4 -o addr show dev "$UPLINK" | awk '{print $4}')
        for a in $addrs; do
            ip addr del "$a" dev "$UPLINK" 2>/dev/null || true
            ip addr add "$a" dev "$BR"
        done
        echo ">> enslaved $UPLINK under $BR (non-persistent; consider netplan/NM)"
    else
        if ! ip -4 addr show dev "$BR" | grep -q "$HOST_IP"; then
            ip addr add "$HOST_IP" dev "$BR"
        fi
        echo ">> bridge $BR up with $HOST_IP (isolated)"
    fi
fi

echo ""
echo ">> done. Launch a guest with:"
echo "      BRIDGE=$BR INSTANCE=1 deploy/scripts/win10-ryzen3-stealth.sh"
